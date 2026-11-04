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
    /// Response-body and accepted push-payload bytes in the most recent transfer.
    public private(set) var lastWireResponseByteCount: Int = 0
    /// Number of newly delivered VBAS data-bin increments in the most recent wire response.
    public private(set) var lastWireNewlyDeliveredBins: Int = 0
    /// EOR reason code from the most recent wire response stream, if any.
    public private(set) var lastEORReason: JPIPEORReason?
    /// Measured peak client cache workspace bytes (`payload + entry metadata`) across the active session.
    package private(set) var lastPeakWorkspaceBytes: Int = 0
    /// Cumulative response-body and accepted push-payload bytes across the active session.
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
    private var transferBudget = JPIPTransferBudget(.default)
    /// Consumed by the next session only; a reused connection cannot attribute
    /// an earlier handshake's temporary storage to a later operation.
    private var pendingConnectionWorkspacePeak = 0
    private var transferInProgress = false
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
        try await connect(deadline: nil)
    }

    package func connect(deadline: ContinuousClock.Instant?, limits: ResourceLimits? = nil) async throws {
        if let deadline {
            _ = try JPIPTransport.remainingSeconds(until: deadline)
        }
        state = .connecting
        pendingConnectionWorkspacePeak = 0

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
                let retained = try await liveCacheStorageBytes()
                let connectionLimits = limits ?? .default
                try await ws.connect(deadline: deadline,
                    maxBodyBytes: connectionLimits.maximumCompressedBytes,
                    maximumStorageBytes: JPIPAdmission.remaining(connectionLimits, retaining: retained))
                pendingConnectionWorkspacePeak = try JPIPAdmission.add(retained, await ws.takeHandshakeReceivePeakBytes())
                self.wsTransport = ws
                self.httpTransport = nil
            } catch let codecErr as CodecError {
                state = .failed("\(codecErr)")
                throw codecErr
            } catch let cancelErr as CancellationError {
                state = .failed("cancelled")
                throw cancelErr
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
                try await Self.probeTCPReachability(host: host, port: port, deadline: deadline)
                self.httpTransport = JPIPTransport(baseURL: serverURL)
                self.wsTransport = nil
            } catch let codecErr as CodecError {
                state = .failed("\(codecErr)")
                throw codecErr
            } catch let cancelErr as CancellationError {
                state = .failed("cancelled")
                throw cancelErr
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

    nonisolated private static func probeTCPReachability(
        host: String,
        port: Int,
        deadline: ContinuousClock.Instant? = nil
    ) async throws {
        let rem = try deadline.map { try JPIPTransport.remainingSeconds(until: $0) }
        let timeout = rem.map { max(0.001, min(10.0, $0)) } ?? 10.0
        let cancelToken = JPIPSocketCancellationToken()
        let watchdog = rem.map { seconds in
            JPIPDeadlineWatchdog(after: seconds) { cancelToken.cancel() }
        }
        defer { watchdog?.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    Thread.detachNewThread {
                        do {
                            let probe = try JPIPTCPConnection.connect(
                                host: host,
                                port: port,
                                timeoutInterval: timeout,
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
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            if let deadline, ContinuousClock.now >= deadline {
                throw CodecError(.resourceLimitExceeded, "JPIP 3D TCP connection deadline elapsed.")
            }
            throw error
        }
    }

    /// Disconnects from the server, sends `cclose` if a channel is active, and releases session resources.
    public func disconnect() async {
        cancelAllRequests()
        if let cid = channelID, !transferInProgress {
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
        pendingConnectionWorkspacePeak = 0
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
    package func createSession(
        volumeID: String,
        limits: ResourceLimits?,
        deadline: ContinuousClock.Instant? = nil
    ) async throws {
        guard !transferInProgress else {
            throw CodecError(.invalidArgument, "A 3D JPIP transfer is already active on this client.")
        }
        transferInProgress = true
        defer { transferInProgress = false }
        try Task.checkCancellation()
        if let deadline {
            _ = try JPIPTransport.remainingSeconds(until: deadline)
        }
        guard case .connected = state else {
            throw JP3DClientError.notConnected
        }

        transferBudget = JPIPTransferBudget(limits ?? .default)
        cumulativeSessionWireBytes = 0
        transferBudget.workspace.observe(pendingConnectionWorkspacePeak)
        lastPeakWorkspaceBytes = pendingConnectionWorkspacePeak
        pendingConnectionWorkspacePeak = 0
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
            response = try await sendJPIPRequest(cnewReq, limits: limits, deadline: deadline)
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
        await cacheManager.clear()

        if !response.data.isEmpty {
            let parsed = try await parseWireResponse(response, limits: limits, retainingAdditionalBytes: 0, deadline: deadline)
            lastEORReason = parsed.eor?.reason
            try await admitAndStoreWireBins(parsed.bins, limits: limits,
                retainingAdditionalBytes: JPIPAdmission.add(JPIPAdmission.response(response), parsed.eorBody?.count ?? 0))
            lastWireNewlyDeliveredBins = parsed.bins.count
        } else {
            lastWireNewlyDeliveredBins = 0
        }
        lastWireResponseByteCount = transferBudget.cumulativeWireBytes

        let suffix = response.channelID ?? String(UUID().uuidString.prefix(8))
        let identifierBytes = try JPIPAdmission.add(9,
            JPIPAdmission.add(JPIPAdmission.multiply(volumeID.utf8.count, 2),
                JPIPAdmission.add(JPIPAdmission.multiply(suffix.utf8.count, 2), 3 * MemoryLayout<String>.stride)))
        let retained = try await JPIPAdmission.add(liveCacheStorageBytes(), JPIPAdmission.response(response))
        try JPIPAdmission.admit(JPIPAdmission.add(retained, identifierBytes),
            limits: limits ?? transferBudget.limits, peak: transferBudget.workspace)
        lastPeakWorkspaceBytes = max(lastPeakWorkspaceBytes, transferBudget.workspace.peak)
        self.activeVolumeID = volumeID
        self.channelID = response.channelID
        self.sessionID = "session-\(volumeID)-\(suffix)"
    }

    // MARK: - Region Requests

    /// Requests normative JPIP delivery of a 3D volumetric region over HTTP/1.1 or WebSocket.
    public func requestRegion(_ region: JP3DStreamingRegion) async throws -> [JP3DDataBin] {
        try await requestRegion(region, limits: nil)
    }

    /// Requests normative JPIP delivery of a 3D volumetric region with optional resource-limit admission.
    package func requestRegion(
        _ region: JP3DStreamingRegion,
        limits: ResourceLimits?,
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> [JP3DDataBin] {
        try Task.checkCancellation()
        if let deadline {
            _ = try JPIPTransport.remainingSeconds(until: deadline)
        }
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
            limits: limits,
            deadline: deadline
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

    /// Admits every retained cache, returned-fragment and snapshot buffer before
    /// materialising the verification snapshot. Payload aliases are conservatively
    /// counted separately: an earlier fragment may coexist with its assembled bin.
    package func verificationCacheSnapshot(
        limits: ResourceLimits, retainingAdditionalBytes: Int
    ) async throws -> (bins: [JPIPDataBin], retainedWorkspaceBytes: Int) {
        let retained = try await JPIPAdmission.add(liveCacheStorageBytes(),
            JPIPAdmission.add(retainingAdditionalBytes, vbasCache.snapshotStorageBytes()))
        guard retained < limits.maximumWorkspaceBytes, retained < limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Retained 3D JPIP buffers leave no verification workspace before snapshot allocation.")
        }
        lastPeakWorkspaceBytes = max(lastPeakWorkspaceBytes, retained)
        return (vbasCache.allDataBins(), retained)
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

    private func liveCacheStorageBytes() async throws -> Int {
        let spatialCount = await cacheManager.entryCount
        let spatialPayload = await cacheManager.memoryUsed
        let spatial = try JPIPAdmission.add(spatialPayload, JPIPAdmission.multiply(spatialCount,
            MemoryLayout<JP3DPrecinct3D>.stride + MemoryLayout<JP3DCacheEntry>.stride))
        let received = try receivedBins.reduce(JPIPAdmission.multiply(receivedBins.count, MemoryLayout<JP3DDataBin>.stride)) {
            try JPIPAdmission.add($0, $1.data.count)
        }
        let queued = await wsTransport?.receiveStorageSnapshot.queuedStorageBytes ?? 0
        let identifiers = try JPIPAdmission.add(JPIPAdmission.string(sessionID),
            JPIPAdmission.add(JPIPAdmission.string(channelID), JPIPAdmission.string(activeVolumeID)))
        return try JPIPAdmission.add(vbasCache.retainedStorageBytes(),
            JPIPAdmission.add(identifiers, JPIPAdmission.add(queued, JPIPAdmission.add(spatial, received))))
    }

    private func sendJPIPRequest(
        _ request: JPIPRequest, limits: ResourceLimits?, deadline: ContinuousClock.Instant? = nil,
        retainingAdditionalBytes: Int = 0
    ) async throws -> JPIPResponse {
        try Task.checkCancellation()
        let rem = try deadline.map { try JPIPTransport.remainingSeconds(until: $0) }
        let retained = try await JPIPAdmission.add(liveCacheStorageBytes(), retainingAdditionalBytes)
        let queueBefore = await wsTransport?.receiveStorageSnapshot.queuedStorageBytes ?? 0
        let effectiveLimits = limits ?? transferBudget.limits
        let maxBody = try JPIPAdmission.responseBodyLimit(limits: effectiveLimits, retaining: retained,
            cumulativeWireBytes: transferBudget.cumulativeWireBytes)
        let remainingStorage = try JPIPAdmission.remaining(effectiveLimits, retaining: retained)
        let response: JPIPResponse
        if let server = directServer {
            response = try await server.handleRequest(request)
        } else if let ws = wsTransport {
            response = try await ws.sendRequest(request, timeout: rem,
                maxBodyBytes: maxBody, maximumStorageBytes: remainingStorage)
        } else if let http = httpTransport {
            response = try await http.send(request, maxBodyBytes: maxBody, deadline: deadline, maximumStorageBytes: remainingStorage)
        } else { throw JP3DClientError.notConnected }
        if let deadline { _ = try JPIPTransport.remainingSeconds(until: deadline) }
        let queueAfter = await wsTransport?.receiveStorageSnapshot.queuedStorageBytes ?? 0
        if let wsTransport {
            let receivePeak = await wsTransport.receiveStorageSnapshot.peakStorageBytes
            transferBudget.workspace.observe(try JPIPAdmission.add(retained - queueBefore, receivePeak))
        } else if let httpTransport {
            let receivePeak = await httpTransport.receiveAdmissionSnapshot().peakBytes
            transferBudget.workspace.observe(try JPIPAdmission.add(retained, receivePeak))
        }
        let pushedPayload = await wsTransport?.takeUnaccountedPushPayloadBytes() ?? 0
        try transferBudget.received(response.data.count, pushedPayloadBytes: pushedPayload,
            retaining: JPIPAdmission.add(retained - queueBefore, JPIPAdmission.add(queueAfter, response.retainedHeaderStorageBytes)))
        cumulativeSessionWireBytes = transferBudget.cumulativeWireBytes
        lastPeakWorkspaceBytes = max(lastPeakWorkspaceBytes, transferBudget.workspace.peak)
        return response
    }

    private func parseWireResponse(
        _ response: JPIPResponse, limits: ResourceLimits?, retainingAdditionalBytes: Int,
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> JPIPParsedStream {
        let limits = limits ?? transferBudget.limits
        let retained = try await JPIPAdmission.add(liveCacheStorageBytes(),
            JPIPAdmission.add(retainingAdditionalBytes, JPIPAdmission.response(response)))
        let budget = transferBudget
        let parsed = try JPIPWireCodec.decodeStream(response.data,
            maxPayloadBytes: limits.maximumCompressedBytes,
            maximumStorageBytes: JPIPAdmission.remaining(limits, retaining: retained),
            workspaceObserver: { budget.workspace.observe(retained + $0) }, deadline: deadline)
        lastPeakWorkspaceBytes = max(lastPeakWorkspaceBytes, budget.workspace.peak)
        return parsed
    }

    private func admitAndStoreWireBins(
        _ bins: [JPIPDataBin], limits: ResourceLimits?, retainingAdditionalBytes: Int = 0,
        additionalDescriptorBytes: Int = 0
    ) async throws {
        guard !bins.isEmpty else { return }
        let limits = limits ?? transferBudget.limits
        let otherCaches = try await liveCacheStorageBytes() - vbasCache.retainedStorageBytes()
        let external = try JPIPAdmission.add(otherCaches,
            JPIPAdmission.add(retainingAdditionalBytes,
                JPIPAdmission.add(JPIPAdmission.bins(bins), additionalDescriptorBytes)))
        try vbasCache.addAdmitted(bins, limits: limits,
            retainingExternalBytes: external, peak: transferBudget.workspace)
        lastPeakWorkspaceBytes = max(lastPeakWorkspaceBytes, transferBudget.workspace.peak)
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
        limits: ResourceLimits?,
        deadline: ContinuousClock.Instant? = nil
    ) async throws -> [JP3DDataBin] {
        guard !transferInProgress else {
            throw CodecError(.invalidArgument, "A 3D JPIP transfer is already active on this client.")
        }
        transferInProgress = true
        defer { transferInProgress = false }
        var accumulatedNew: [JPIPDataBin] = []
        let initialWireBytes = transferBudget.cumulativeWireBytes
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
            let probeResp = try await sendJPIPRequest(probeReq, limits: limits, deadline: deadline,
                retainingAdditionalBytes: JPIPAdmission.bins(accumulatedNew))
            if probeResp.statusCode == 200 && !probeResp.data.isEmpty {
                let accumulatedStorage = try JPIPAdmission.bins(accumulatedNew)
                let parsedProbe = try await parseWireResponse(probeResp, limits: limits,
                    retainingAdditionalBytes: accumulatedStorage, deadline: deadline)
                lastEORReason = parsedProbe.eor?.reason
                let descriptors = try JPIPAdmission.multiply(JPIPAdmission.add(accumulatedNew.count, parsedProbe.bins.count),
                    2 * MemoryLayout<JPIPDataBin>.stride)
                try await admitAndStoreWireBins(parsedProbe.bins, limits: limits,
                    retainingAdditionalBytes: JPIPAdmission.add(accumulatedStorage, JPIPAdmission.add(JPIPAdmission.response(probeResp), parsedProbe.eorBody?.count ?? 0)),
                    additionalDescriptorBytes: descriptors)
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
            var modelStorage = 0
            if channelID == nil && vbasCache.statistics.entryCount > 0 {
                modelStorage = try JPIPAdmission.multiply(vbasCache.statistics.entryCount, 128)
                let sortedDescriptors = try JPIPAdmission.multiply(vbasCache.statistics.entryCount, MemoryLayout<JPIPCacheModel.CacheEntry>.stride)
                let live = try await JPIPAdmission.add(liveCacheStorageBytes(), JPIPAdmission.bins(accumulatedNew))
                try JPIPAdmission.admit(JPIPAdmission.add(live, JPIPAdmission.add(modelStorage, sortedDescriptors)),
                    limits: limits ?? transferBudget.limits, peak: transferBudget.workspace)
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
                    let ox = try JPIPAdmission.multiply(fullXLo, fx) / dims.width
                    let oy = try JPIPAdmission.multiply(fullYLo, fy) / dims.height
                    let oz = try JPIPAdmission.multiply(fullZLo, fz) / dims.depth
                    let endX = max(ox + 1, try JPIPAdmission.add(JPIPAdmission.multiply(fullXHi, fx), dims.width - 1) / dims.width)
                    let endY = max(oy + 1, try JPIPAdmission.add(JPIPAdmission.multiply(fullYHi, fy), dims.height - 1) / dims.height)
                    let endZ = max(oz + 1, try JPIPAdmission.add(JPIPAdmission.multiply(fullZHi, fz), dims.depth - 1) / dims.depth)
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
                response = try await sendJPIPRequest(jpipReq, limits: limits, deadline: deadline,
                    retainingAdditionalBytes: JPIPAdmission.add(JPIPAdmission.bins(accumulatedNew), modelStorage))
            } catch let codecErr as CodecError {
                throw codecErr
            } catch let cancelErr as CancellationError {
                throw cancelErr
            } catch {
                throw JP3DClientError.networkError("3D JPIP request failed: \(error)")
            }

            jpipReq.model = nil
            modelStorage = 0
            if response.statusCode == 404 {
                throw JP3DClientError.unknownVolume(volumeID)
            }
            guard response.statusCode == 200 else {
                throw JP3DClientError.serverError("Server returned HTTP \(response.statusCode)")
            }

            let accumulatedStorage = try JPIPAdmission.bins(accumulatedNew)
            let parsed = try await parseWireResponse(response, limits: limits,
                retainingAdditionalBytes: accumulatedStorage, deadline: deadline)
            lastEORReason = parsed.eor?.reason
            let descriptors = try JPIPAdmission.multiply(JPIPAdmission.add(accumulatedNew.count, parsed.bins.count),
                2 * MemoryLayout<JPIPDataBin>.stride)
            try await admitAndStoreWireBins(parsed.bins, limits: limits,
                retainingAdditionalBytes: JPIPAdmission.add(accumulatedStorage, JPIPAdmission.add(JPIPAdmission.response(response), parsed.eorBody?.count ?? 0)),
                additionalDescriptorBytes: descriptors)
            accumulatedNew.append(contentsOf: parsed.bins)

            if let ws = wsTransport {
                let pushed = await ws.drainReceivedDataBins()
                if !pushed.isEmpty {
                    try await admitAndStoreWireBins(pushed, limits: limits,
                        retainingAdditionalBytes: JPIPAdmission.add(JPIPAdmission.response(response),
                            JPIPAdmission.add(JPIPAdmission.bins(accumulatedNew),
                                JPIPAdmission.multiply(parsed.bins.count, MemoryLayout<JPIPDataBin>.stride))),
                        additionalDescriptorBytes: JPIPAdmission.multiply(JPIPAdmission.add(accumulatedNew.count, pushed.count),
                            2 * MemoryLayout<JPIPDataBin>.stride))
                    accumulatedNew.append(contentsOf: pushed)
                }
            }

            if parsed.eor?.reason != .byteLimitReached || parsed.bins.isEmpty {
                break
            }
        }

        let totalWireBytes = transferBudget.cumulativeWireBytes - initialWireBytes
        lastWireResponseByteCount = totalWireBytes
        lastWireNewlyDeliveredBins = accumulatedNew.count

        // Map newly delivered VBAS bins (or already-cached bins when stateful delta satisfied the window)
        // to `JP3DDataBin` carrying real normative data-bin bytes.
        let effectiveLimits = limits ?? transferBudget.limits
        let retainedBeforeMapping = try await JPIPAdmission.add(liveCacheStorageBytes(), JPIPAdmission.bins(accumulatedNew))
        let snapshotBytes = accumulatedNew.isEmpty ? try vbasCache.snapshotStorageBytes() : 0
        try JPIPAdmission.admit(JPIPAdmission.add(retainedBeforeMapping, snapshotBytes),
            limits: effectiveLimits, peak: transferBudget.workspace)
        let sourceBins = accumulatedNew.isEmpty ? vbasCache.allDataBins() : accumulatedNew
        let sourcePayload = try sourceBins.reduce(0) { try JPIPAdmission.add($0, $1.data.count) }
        let mappingDescriptors = try JPIPAdmission.multiply(sourceBins.count,
            3 * (MemoryLayout<JP3DPrecinct3D>.stride + MemoryLayout<JP3DCacheEntry>.stride)
                + 3 * MemoryLayout<JP3DDataBin>.stride)
        let spatialGrowth = try JPIPAdmission.multiply(await cacheManager.entryCount,
            2 * (MemoryLayout<JP3DPrecinct3D>.stride + MemoryLayout<JP3DCacheEntry>.stride))
        let receivedGrowth = try JPIPAdmission.multiply(receivedBins.count, MemoryLayout<JP3DDataBin>.stride)
        let mappingStorage = try JPIPAdmission.add(JPIPAdmission.multiply(sourcePayload, 2),
            JPIPAdmission.add(mappingDescriptors, JPIPAdmission.add(receivedGrowth, spatialGrowth)))
        try JPIPAdmission.admit(JPIPAdmission.add(retainedBeforeMapping,
            JPIPAdmission.add(snapshotBytes, mappingStorage)), limits: effectiveLimits, peak: transferBudget.workspace)
        lastPeakWorkspaceBytes = max(lastPeakWorkspaceBytes, transferBudget.workspace.peak)
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

        var combinedReceived: [JP3DDataBin] = []
        combinedReceived.reserveCapacity(try JPIPAdmission.add(receivedBins.count, out.count))
        combinedReceived.append(contentsOf: receivedBins)
        combinedReceived.append(contentsOf: out)
        receivedBins = combinedReceived
        statistics = JP3DStreamingStatistics(
            bytesDelivered: try JPIPAdmission.add(statistics.bytesDelivered, totalWireBytes),
            binsDelivered: try JPIPAdmission.add(statistics.binsDelivered, out.count),
            averageBandwidthBPS: statistics.averageBandwidthBPS,
            elapsedSeconds: statistics.elapsedSeconds
        )
        return out
    }
}
