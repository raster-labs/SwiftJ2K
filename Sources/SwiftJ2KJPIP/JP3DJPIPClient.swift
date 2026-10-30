// SPDX-License-Identifier: Apache-2.0
//
// JP3DJPIPClient.swift
// SwiftJ2KJPIP
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/JPIP/JP3DJPIPClient.swift
//
/// # JP3DJPIPClient
///
/// JPIP client actor for 3D-aware progressive delivery of Part 10 JP3D volumetric data
/// over real TCP HTTP/1.1 (`http://`) and RFC 6455 WebSocket (`ws://`) connections.
///
/// `JP3DJPIPClient` manages a real JPIP channel (`cnew`/`cid`/`cclose`), sends 3D view-window
/// requests (`roff`/`rsiz`/`zoff`/`zsiz`/`layers`/`reslevels`), parses normative ITU-T Rec. T.808
/// VBAS data-bin streams (`Class 6` main header, `Class 2` tile header, `Class 0` 3D precincts),
/// merges partial `Msg-Offset` increments into its client cache, and reconstructs valid Part 10
/// `.jp3d` codestreams for full-volume or 3D ROI voxel decoding via `JP3DDecoder` / `JP3DROIDecoder`.

import Foundation
import Dispatch
@_exported import SwiftJ2K
@_exported import SwiftJ2K3D

/// A JPIP view-window request with 3D viewport, quality, and resolution parameters.
public struct JP3DViewWindowRequest: Sendable {
    /// Unique request identifier.
    public let requestID: String
    /// Target viewport.
    public let viewport: JP3DViewport
    /// Desired quality layer.
    public let qualityLayer: Int
    /// Desired resolution level.
    public let resolutionLevel: Int
    /// Requested progression mode.
    public let progressionMode: JP3DProgressionMode
    /// Timestamp when the request was created.
    public let createdAt: Date

    /// Creates a view-window request.
    public init(
        viewport: JP3DViewport,
        qualityLayer: Int = 0,
        resolutionLevel: Int = 0,
        progressionMode: JP3DProgressionMode = .adaptive
    ) {
        self.requestID = UUID().uuidString
        self.viewport = viewport
        self.qualityLayer = max(0, qualityLayer)
        self.resolutionLevel = max(0, resolutionLevel)
        self.progressionMode = progressionMode
        self.createdAt = Date()
    }
}

/// Connection state of the JPIP client.
public enum JP3DClientState: Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

/// Errors produced by the JPIP 3D client.
public enum JP3DClientError: Error, Sendable {
    case notConnected
    case noSession
    case invalidRegion(String)
    case serverError(String)
    case networkError(String)
    case unknownVolume(String)
}

/// 3D JPIP client actor for streaming volumetric data from a JP3D JPIP server over HTTP/1.1 or WebSocket.
public actor JP3DJPIPClient {
    // MARK: - Configuration

    /// Server URL (`ws://` or `http://`).
    public let serverURL: URL
    /// Optional preferred progression mode.
    public private(set) var preferredProgressionMode: JP3DProgressionMode

    // MARK: - State

    private(set) var state: JP3DClientState = .disconnected
    private(set) var sessionID: String?
    private(set) var currentViewport: JP3DViewport?
    /// Active JPIP channel identifier (`cid`) returned by `JPIP-cnew`.
    public private(set) var channelID: String?
    /// Byte length of the most recent wire response body.
    public private(set) var lastWireResponseByteCount: Int = 0
    /// Number of newly delivered VBAS data-bin increments in the most recent wire response.
    public private(set) var lastWireNewlyDeliveredBins: Int = 0
    /// EOR reason code from the most recent wire response stream, if any.
    public private(set) var lastEORReason: JPIPEORReason?
    /// Measured peak client cache workspace bytes (`payload + entry metadata`) across the active session.
    package private(set) var lastPeakWorkspaceBytes: Int = 0
    /// Cumulative raw wire response bytes received across the active session.
    package private(set) var cumulativeSessionWireBytes: Int = 0

    private let directServer: JPIPServer?
    private var httpTransport: JPIPTransport?
    private var wsTransport: JPIPWebSocketTransport?
    private var activeVolumeID: String?
    private var vbasCache: JPIPCacheModel
    private let cacheManager: JP3DCacheManager
    private let dataBinGenerator = JPIPDataBinGenerator()

    private var activeRequests: [String: JP3DViewWindowRequest] = [:]
    private var cancelledRequestIDs: Set<String> = []
    private var receivedBins: [JP3DDataBin] = []
    private var statistics = JP3DStreamingStatistics()
    private var reconnectAttempts: Int = 0

    // MARK: - Initialisers

    /// Creates a JP3D JPIP client connecting over TCP HTTP/1.1 or RFC 6455 WebSocket.
    public init(
        serverURL: URL,
        preferredProgressionMode: JP3DProgressionMode = .adaptive
    ) {
        self.serverURL = serverURL
        self.preferredProgressionMode = preferredProgressionMode
        self.directServer = nil
        self.vbasCache = JPIPCacheModel(maxCacheSize: 256 * 1024 * 1024, maxEntries: 100_000)
        self.cacheManager = JP3DCacheManager()
    }

    /// Creates a JP3D JPIP client bound directly to an in-process ``JPIPServer`` actor.
    package init(
        server: JPIPServer,
        serverURL: URL,
        preferredProgressionMode: JP3DProgressionMode = .adaptive
    ) {
        self.serverURL = serverURL
        self.preferredProgressionMode = preferredProgressionMode
        self.directServer = server
        self.vbasCache = JPIPCacheModel(maxCacheSize: 256 * 1024 * 1024, maxEntries: 100_000)
        self.cacheManager = JP3DCacheManager()
    }

    // MARK: - Connection Management

    /// Establishes a real TCP connection (HTTP/1.1 or RFC 6455 WebSocket) to the JPIP server.
    public func connect() async throws {
        state = .connecting

        if directServer != nil {
            reconnectAttempts = 0
            state = .connected
            return
        }

        let scheme = (serverURL.scheme ?? "http").lowercased()
        switch scheme {
        case "ws", "wss":
            let ws = JPIPWebSocketTransport(url: serverURL)
            do {
                try await ws.connect()
                self.wsTransport = ws
                self.httpTransport = nil
            } catch {
                state = .failed("\(error)")
                throw JP3DClientError.networkError("WebSocket connection failed: \(error)")
            }

        case "http", "https":
            if scheme == "https" {
                state = .failed("TLS HTTPS requires external termination; use http:// over TCP.")
                throw JP3DClientError.networkError("TLS HTTPS requires external termination; use http:// over TCP.")
            }
            guard let host = serverURL.host, !host.isEmpty else {
                state = .failed("Missing host in \(serverURL)")
                throw JP3DClientError.networkError("Missing host in \(serverURL)")
            }
            let port = serverURL.port ?? 80
            do {
                try await Self.probeTCPReachability(host: host, port: port)
                self.httpTransport = JPIPTransport(baseURL: serverURL)
                self.wsTransport = nil
            } catch {
                state = .failed("\(error)")
                throw JP3DClientError.networkError("HTTP TCP connection failed: \(error)")
            }

        default:
            state = .failed("Unsupported URL scheme '\(scheme)'")
            throw JP3DClientError.networkError("Unsupported URL scheme '\(scheme)'")
        }

        reconnectAttempts = 0
        state = .connected
    }

    nonisolated private static func probeTCPReachability(host: String, port: Int) async throws {
        let cancelToken = JPIPSocketCancellationToken()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let probe = try JPIPTCPConnection.connect(
                            host: host,
                            port: port,
                            timeoutInterval: 10.0,
                            cancellationToken: cancelToken
                        )
                        probe.close()
                        continuation.resume(returning: ())
                    } catch {
                        continuation.resume(throwing: cancelToken.cancelled ? CancellationError() : error)
                    }
                }
            }
        } onCancel: {
            cancelToken.cancel()
        }
    }

    /// Disconnects from the server, sends `cclose` if a channel is active, and releases session resources.
    public func disconnect() async {
        cancelAllRequests()
        if let cid = channelID {
            var closeReq = JPIPRequest(target: "")
            closeReq.cid = cid
            closeReq.cclose = [cid]
            _ = try? await sendJPIPRequest(closeReq, limits: nil)
        }
        if let ws = wsTransport {
            await ws.disconnect()
            wsTransport = nil
        }
        if let http = httpTransport {
            await http.close()
            httpTransport = nil
        }
        channelID = nil
        activeVolumeID = nil
        sessionID = nil
        state = .disconnected
        lastEORReason = nil
        lastPeakWorkspaceBytes = 0
        cumulativeSessionWireBytes = 0
        receivedBins.removeAll()
        vbasCache.clear()
        await cacheManager.clear()
    }

    /// Reconnects after a network interruption.
    public func reconnect() async throws {
        reconnectAttempts += 1
        if let ws = wsTransport {
            await ws.disconnect()
            wsTransport = nil
        }
        if let http = httpTransport {
            await http.close()
            httpTransport = nil
        }
        try await connect()
    }

    // MARK: - Session Management

    /// Creates a new JPIP session (`cnew`) on the server for `volumeID`.
    public func createSession(volumeID: String) async throws {
        try await createSession(volumeID: volumeID, limits: nil)
    }

    /// Creates a new JPIP session (`cnew`) on the server for `volumeID` with optional resource-limit admission.
    package func createSession(volumeID: String, limits: ResourceLimits?) async throws {
        try Task.checkCancellation()
        guard case .connected = state else {
            throw JP3DClientError.notConnected
        }

        var cnewReq = JPIPRequest(target: volumeID)
        cnewReq.cnew = (wsTransport != nil) ? .webSocket : .http
        cnewReq.streamType = .jppStream
        // Request initial header payload on session creation so subsequent 3D requests
        // can compute normative `fvsiz` / `rvoff` / `rvsiz` from the cached Class 6 main header.
        if let limits {
            cnewReq.len = min(512, max(0, limits.maximumCompressedBytes))
        } else {
            cnewReq.len = 512
        }

        let response: JPIPResponse
        do {
            response = try await sendJPIPRequest(cnewReq, limits: limits)
        } catch let codecErr as CodecError {
            throw codecErr
        } catch let cancelErr as CancellationError {
            throw cancelErr
        } catch {
            throw JP3DClientError.networkError("Failed to create JPIP 3D session: \(error)")
        }

        if response.statusCode == 404 {
            throw JP3DClientError.unknownVolume(volumeID)
        }
        guard response.statusCode == 200 else {
            throw JP3DClientError.serverError("Server rejected session creation with HTTP \(response.statusCode)")
        }

        vbasCache.clear()
        receivedBins.removeAll()
        lastEORReason = nil
        lastPeakWorkspaceBytes = 0
        cumulativeSessionWireBytes = 0
        await cacheManager.clear()

        if !response.data.isEmpty {
            cumulativeSessionWireBytes = response.data.count
            if let limits, cumulativeSessionWireBytes > limits.maximumCompressedBytes {
                throw CodecError(
                    .resourceLimitExceeded,
                    "3D JPIP session wire payload (\(cumulativeSessionWireBytes) bytes) exceeds compressed limit (\(limits.maximumCompressedBytes) bytes)."
                )
            }
            let parsed = try JPIPWireCodec.decodeStream(response.data)
            lastEORReason = parsed.eor?.reason
            try admitAndStoreWireBins(parsed.bins, limits: limits)
            lastWireResponseByteCount = response.data.count
            lastWireNewlyDeliveredBins = parsed.bins.count
        } else {
            lastWireResponseByteCount = 0
            lastWireNewlyDeliveredBins = 0
        }

        self.activeVolumeID = volumeID
        self.channelID = response.channelID
        let suffix = response.channelID ?? String(UUID().uuidString.prefix(8))
        self.sessionID = "session-\(volumeID)-\(suffix)"
    }

    // MARK: - Region Requests

    /// Requests normative JPIP delivery of a 3D volumetric region over HTTP/1.1 or WebSocket.
    public func requestRegion(_ region: JP3DStreamingRegion) async throws -> [JP3DDataBin] {
        try await requestRegion(region, limits: nil)
    }

    /// Requests normative JPIP delivery of a 3D volumetric region with optional resource-limit admission.
    package func requestRegion(_ region: JP3DStreamingRegion, limits: ResourceLimits?) async throws -> [JP3DDataBin] {
        try Task.checkCancellation()
        guard sessionID != nil, let volumeID = activeVolumeID else {
            throw JP3DClientError.noSession
        }
        guard region.isValid else {
            throw JP3DClientError.invalidRegion("Region is empty or invalid")
        }

        let viewport = JP3DViewport(
            xRange: region.xRange, yRange: region.yRange, zRange: region.zRange
        )
        let req = JP3DViewWindowRequest(
            viewport: viewport,
            qualityLayer: region.qualityLayer,
            resolutionLevel: region.resolutionLevel,
            progressionMode: preferredProgressionMode
        )
        activeRequests[req.requestID] = req
        defer { activeRequests.removeValue(forKey: req.requestID) }

        return try await fetchWireRegionBins(
            volumeID: volumeID,
            region: region,
            requestID: req.requestID,
            limits: limits
        )
    }

    /// Requests a range of Z slices at a specified quality over HTTP/1.1 or WebSocket.
    public func requestSliceRange(zRange: Range<Int>, quality: Int) async throws -> [JP3DDataBin] {
        guard sessionID != nil, let volumeID = activeVolumeID else {
            throw JP3DClientError.noSession
        }
        guard !zRange.isEmpty else {
            throw JP3DClientError.invalidRegion("Z range is empty")
        }
        let region = JP3DStreamingRegion(
            xRange: 0..<Int.max / 2,
            yRange: 0..<Int.max / 2,
            zRange: zRange,
            qualityLayer: quality
        )
        let req = JP3DViewWindowRequest(
            viewport: JP3DViewport(xRange: region.xRange, yRange: region.yRange, zRange: region.zRange),
            qualityLayer: quality,
            progressionMode: .sliceBySliceForward
        )
        activeRequests[req.requestID] = req
        defer { activeRequests.removeValue(forKey: req.requestID) }

        return try await fetchWireRegionBins(
            volumeID: volumeID,
            region: region,
            requestID: req.requestID,
            limits: nil
        )
    }

    /// Reconstructs the Part 10 `.jp3d` codestream from all accumulated normative VBAS data-bins.
    public func reconstructCodestream() throws -> Data {
        try reconstructCodestream(limits: nil)
    }

    /// Reconstructs the Part 10 `.jp3d` codestream with optional resource-limit enforcement.
    package func reconstructCodestream(limits: ResourceLimits?) throws -> Data {
        let bins = vbasCache.allDataBins()
        let codestream: Data
        if let limits {
            codestream = try dataBinGenerator.reassembleCodestreamThrowing(
                from: bins,
                reconstructContainer: false,
                limits: limits
            )
        } else {
            codestream = try dataBinGenerator.reassembleCodestreamThrowing(
                from: bins,
                reconstructContainer: false
            )
        }
        guard !codestream.isEmpty else {
            throw JP3DClientError.serverError("Unable to reconstruct JP3D codestream from cached data-bins")
        }
        return codestream
    }

    /// Requests `region` over JPIP, reconstructs the Part 10 `.jp3d` codestream from received VBAS
    /// data-bins, and decodes the requested 3D sub-volume (or full volume) voxels.
    public func requestVolumeRegion(_ region: JP3DStreamingRegion) async throws -> J2KVolume {
        _ = try await requestRegion(region)
        return try await decodeVolume(region: region)
    }

    /// Decodes the currently cached Part 10 `.jp3d` codestream (full volume when `region == nil`,
    /// or cropped to `region` via `JP3DROIDecoder`).
    public func decodeVolume(region: JP3DStreamingRegion? = nil) async throws -> J2KVolume {
        let codestream = try reconstructCodestream()
        if let r = region,
           r.xRange.upperBound < Int.max / 4,
           r.yRange.upperBound < Int.max / 4 {
            let roiDecoder = JP3DROIDecoder(
                maxQualityLayers: r.qualityLayer,
                resolutionLevel: r.resolutionLevel,
                tolerateErrors: true
            )
            let roi = JP3DRegion(
                x: r.xRange,
                y: r.yRange,
                z: r.zRange
            )
            let decoded = try await roiDecoder.decode(codestream, region: roi)
            return decoded.volume
        }
        let decoder = JP3DDecoder(
            configuration: JP3DDecoderConfiguration(
                maxQualityLayers: region?.qualityLayer ?? 0,
                resolutionLevel: region?.resolutionLevel ?? 0,
                tolerateErrors: true
            )
        )
        return try await decoder.decode(codestream).volume
    }

    /// Returns all currently cached normative JPIP data-bins.
    public func cachedWireDataBins() -> [JPIPDataBin] {
        vbasCache.allDataBins()
    }

    // MARK: - Viewport Management

    public func updateViewport(_ newViewport: JP3DViewport) {
        currentViewport = newViewport
        var toCancel: [String] = []
        for (id, request) in activeRequests where request.viewport.intersection(newViewport) == nil {
            toCancel.append(id)
        }
        for id in toCancel {
            cancelledRequestIDs.insert(id)
            activeRequests.removeValue(forKey: id)
        }
    }

    public func cancelStaleRequests() {
        for id in activeRequests.keys {
            cancelledRequestIDs.insert(id)
        }
        activeRequests.removeAll()
    }

    // MARK: - Private Helpers

    private func cancelAllRequests() {
        for id in activeRequests.keys {
            cancelledRequestIDs.insert(id)
        }
        activeRequests.removeAll()
    }

    private func sendJPIPRequest(
        _ request: JPIPRequest,
        limits: ResourceLimits?
    ) async throws -> JPIPResponse {
        try Task.checkCancellation()
        let maxBody = limits?.maximumCompressedBytes ?? (128 * 1024 * 1024)
        let response: JPIPResponse
        if let server = directServer {
            response = try await server.handleRequest(request)
        } else if let ws = wsTransport {
            response = try await ws.sendRequest(request)
        } else if let http = httpTransport {
            response = try await http.send(request, maxBodyBytes: maxBody)
        } else {
            throw JP3DClientError.notConnected
        }

        if let limits, response.data.count > limits.maximumCompressedBytes {
            throw CodecError(
                .resourceLimitExceeded,
                "3D JPIP response payload (\(response.data.count) bytes) exceeds compressed limit (\(limits.maximumCompressedBytes) bytes)."
            )
        }
        return response
    }

    private func admitAndStoreWireBins(
        _ bins: [JPIPDataBin],
        limits: ResourceLimits?
    ) throws {
        guard !bins.isEmpty else { return }
        let projected = try vbasCache.projectedAllocation(adding: bins)
        let (entryMeta, ov1) = projected.entryCount.multipliedReportingOverflow(
            by: MemoryLayout<JPIPCacheModel.CacheEntry>.stride
        )
        let (totalWorkspaceBytes, ov2) = projected.totalPayloadBytes.addingReportingOverflow(entryMeta)
        guard !ov1, !ov2 else {
            throw CodecError(.resourceLimitExceeded, "3D JPIP cache workspace arithmetic overflow.")
        }
        if let limits {
            guard projected.totalPayloadBytes <= limits.maximumCompressedBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "3D JPIP cached data-bin span (\(projected.totalPayloadBytes) bytes) exceeds compressed limit (\(limits.maximumCompressedBytes) bytes)."
                )
            }
            guard totalWorkspaceBytes <= limits.maximumWorkspaceBytes,
                  totalWorkspaceBytes <= limits.maximumMemoryBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "3D JPIP cache workspace (\(totalWorkspaceBytes) bytes) exceeds workspace/memory limits."
                )
            }
        }
        lastPeakWorkspaceBytes = max(lastPeakWorkspaceBytes, totalWorkspaceBytes)
        for bin in bins {
            vbasCache.addDataBin(bin)
        }
    }

    private func cached3DDimensions() -> (width: Int, height: Int, depth: Int, levelsX: Int, levelsY: Int, levelsZ: Int)? {
        guard let mh = vbasCache.getDataBin(binClass: .mainHeader, binID: 0) else {
            return nil
        }
        return JPIPRequest.extract3DCodestreamDimensions(fromMainHeader: mh.data)
    }

    private func fetchWireRegionBins(
        volumeID: String,
        region: JP3DStreamingRegion,
        requestID: String,
        limits: ResourceLimits?
    ) async throws -> [JP3DDataBin] {
        var accumulatedNew: [JPIPDataBin] = []
        var totalWireBytes = 0
        var rounds = 0

        // Ensure Class 6 main header is cached when resolution discard or unconstrained slice axes
        // need full codestream dimensions to formulate normative `fvsiz` / `rvoff` / `rvsiz`.
        let hasUnconstrainedAxis = region.xRange.upperBound >= Int.max / 4
            || region.yRange.upperBound >= Int.max / 4
            || region.zRange.upperBound >= Int.max / 4
        if cached3DDimensions() == nil && (region.resolutionLevel > 0 || hasUnconstrainedAxis) {
            var probeReq = JPIPRequest(target: channelID == nil ? volumeID : "")
            probeReq.cid = channelID
            probeReq.streamType = .jppStream
            probeReq.len = min(512, limits?.maximumCompressedBytes ?? 512)
            let probeResp = try await sendJPIPRequest(probeReq, limits: limits)
            if probeResp.statusCode == 200 && !probeResp.data.isEmpty {
                let (sumWire, ov) = cumulativeSessionWireBytes.addingReportingOverflow(probeResp.data.count)
                if ov {
                    throw CodecError(.resourceLimitExceeded, "3D JPIP cumulative wire byte count overflow.")
                }
                cumulativeSessionWireBytes = sumWire
                if let limits, cumulativeSessionWireBytes > limits.maximumCompressedBytes {
                    throw CodecError(
                        .resourceLimitExceeded,
                        "3D JPIP cumulative wire payload (\(cumulativeSessionWireBytes) bytes) exceeds compressed limit (\(limits.maximumCompressedBytes) bytes)."
                    )
                }
                totalWireBytes += probeResp.data.count
                let parsedProbe = try JPIPWireCodec.decodeStream(probeResp.data)
                lastEORReason = parsedProbe.eor?.reason
                try admitAndStoreWireBins(parsedProbe.bins, limits: limits)
                accumulatedNew.append(contentsOf: parsedProbe.bins)
            }
        }

        while rounds < 256 {
            try Task.checkCancellation()
            rounds += 1
            if cancelledRequestIDs.contains(requestID) {
                cancelledRequestIDs.remove(requestID)
                return []
            }

            var jpipReq = JPIPRequest(target: channelID == nil ? volumeID : "")
            jpipReq.cid = channelID
            if channelID == nil && !vbasCache.allDataBins().isEmpty {
                jpipReq.model = vbasCache.formatCacheModelField()
            }

            // Populate normative ITU-T Rec. T.808 Clauses C.4.5–C.4.7 + T.809 `fvsiz` / `rvoff` / `rvsiz`.
            if let dims = cached3DDimensions() {
                let fullXLo = max(0, min(dims.width, region.xRange.lowerBound))
                let fullXHi = region.xRange.upperBound >= Int.max / 4
                    ? dims.width
                    : max(fullXLo, min(dims.width, region.xRange.upperBound))
                let fullYLo = max(0, min(dims.height, region.yRange.lowerBound))
                let fullYHi = region.yRange.upperBound >= Int.max / 4
                    ? dims.height
                    : max(fullYLo, min(dims.height, region.yRange.upperBound))
                let fullZLo = max(0, min(dims.depth, region.zRange.lowerBound))
                let fullZHi = region.zRange.upperBound >= Int.max / 4
                    ? dims.depth
                    : max(fullZLo, min(dims.depth, region.zRange.upperBound))

                let frame = JPIPRequest.frameDimensions3D(
                    fullWidth: dims.width,
                    fullHeight: dims.height,
                    fullDepth: dims.depth,
                    levelsX: dims.levelsX,
                    levelsY: dims.levelsY,
                    levelsZ: dims.levelsZ,
                    resolutionLevel: region.resolutionLevel
                )
                let fx = frame[0], fy = frame[1], fz = frame[2]
                jpipReq.fvsiz = frame
                jpipReq.fvsizRoundDirection = "closest"

                if fullXLo >= fullXHi || fullYLo >= fullYHi || fullZLo >= fullZHi {
                    jpipReq.rvoff = [max(0, region.xRange.lowerBound), max(0, region.yRange.lowerBound), max(0, region.zRange.lowerBound)]
                    jpipReq.rvsiz = [max(1, region.xRange.count), max(1, region.yRange.count), max(1, region.zRange.count)]
                } else {
                    let ox = (fullXLo * fx) / max(1, dims.width)
                    let oy = (fullYLo * fy) / max(1, dims.height)
                    let oz = (fullZLo * fz) / max(1, dims.depth)
                    let endX = max(ox + 1, (fullXHi * fx + max(1, dims.width) - 1) / max(1, dims.width))
                    let endY = max(oy + 1, (fullYHi * fy + max(1, dims.height) - 1) / max(1, dims.height))
                    let endZ = max(oz + 1, (fullZHi * fz + max(1, dims.depth) - 1) / max(1, dims.depth))
                    let sx = max(1, min(fx, endX) - ox)
                    let sy = max(1, min(fy, endY) - oy)
                    let sz = max(1, min(fz, endZ) - oz)
                    jpipReq.rvoff = [ox, oy, oz]
                    jpipReq.rvsiz = [sx, sy, sz]
                }
            } else {
                let ox = max(0, region.xRange.lowerBound)
                let oy = max(0, region.yRange.lowerBound)
                let oz = max(0, region.zRange.lowerBound)
                let sx = region.xRange.upperBound >= Int.max / 4 ? 1_048_576 : max(1, region.xRange.count)
                let sy = region.yRange.upperBound >= Int.max / 4 ? 1_048_576 : max(1, region.yRange.count)
                let sz = region.zRange.upperBound >= Int.max / 4 ? 1_048_576 : max(1, region.zRange.count)
                jpipReq.rvoff = [ox, oy, oz]
                jpipReq.rvsiz = [sx, sy, sz]
            }

            if region.qualityLayer > 0 {
                jpipReq.layers = region.qualityLayer
            }
            jpipReq.streamType = .jppStream

            let response: JPIPResponse
            do {
                response = try await sendJPIPRequest(jpipReq, limits: limits)
            } catch let codecErr as CodecError {
                throw codecErr
            } catch let cancelErr as CancellationError {
                throw cancelErr
            } catch {
                throw JP3DClientError.networkError("3D JPIP request failed: \(error)")
            }

            if response.statusCode == 404 {
                throw JP3DClientError.unknownVolume(volumeID)
            }
            guard response.statusCode == 200 else {
                throw JP3DClientError.serverError("Server returned HTTP \(response.statusCode)")
            }

            let (sumWire, ov) = cumulativeSessionWireBytes.addingReportingOverflow(response.data.count)
            if ov {
                throw CodecError(.resourceLimitExceeded, "3D JPIP cumulative wire byte count overflow.")
            }
            cumulativeSessionWireBytes = sumWire
            if let limits, cumulativeSessionWireBytes > limits.maximumCompressedBytes {
                throw CodecError(
                    .resourceLimitExceeded,
                    "3D JPIP cumulative wire payload (\(cumulativeSessionWireBytes) bytes) exceeds compressed limit (\(limits.maximumCompressedBytes) bytes)."
                )
            }

            totalWireBytes += response.data.count
            let parsed = try JPIPWireCodec.decodeStream(response.data)
            lastEORReason = parsed.eor?.reason
            try admitAndStoreWireBins(parsed.bins, limits: limits)
            accumulatedNew.append(contentsOf: parsed.bins)

            if let ws = wsTransport {
                let pushed = await ws.drainReceivedDataBins()
                if !pushed.isEmpty {
                    try admitAndStoreWireBins(pushed, limits: limits)
                    accumulatedNew.append(contentsOf: pushed)
                }
            }

            if parsed.eor?.reason != .byteLimitReached || parsed.bins.isEmpty {
                break
            }
        }

        lastWireResponseByteCount = totalWireBytes
        lastWireNewlyDeliveredBins = accumulatedNew.count

        // Map newly delivered VBAS bins (or already-cached bins when stateful delta satisfied the window)
        // to `JP3DDataBin` carrying real normative data-bin bytes.
        let sourceBins = accumulatedNew.isEmpty ? vbasCache.allDataBins() : accumulatedNew
        var out: [JP3DDataBin] = []
        out.reserveCapacity(sourceBins.count)

        for (idx, wBin) in sourceBins.enumerated() {
            let jp3dBin = JP3DDataBin(
                binID: wBin.binID,
                tileX: 0,
                tileY: 0,
                tileZ: region.zRange.lowerBound,
                resolutionLevel: region.resolutionLevel,
                qualityLayer: region.qualityLayer,
                data: wBin.data,
                isComplete: wBin.isComplete && (idx == sourceBins.count - 1)
            )
            out.append(jp3dBin)
            let key = JP3DPrecinct3D(
                tileX: wBin.binClass.rawValue,
                tileY: 0,
                tileZ: region.zRange.lowerBound,
                resolutionLevel: region.resolutionLevel,
                subband: 0,
                precinctIndex: wBin.binID
            )
            await cacheManager.store(key: key, bin: jp3dBin, region: region)
        }

        receivedBins.append(contentsOf: out)
        statistics = JP3DStreamingStatistics(
            bytesDelivered: statistics.bytesDelivered + totalWireBytes,
            binsDelivered: statistics.binsDelivered + out.count,
            averageBandwidthBPS: statistics.averageBandwidthBPS,
            elapsedSeconds: statistics.elapsedSeconds
        )
        return out
    }
}
