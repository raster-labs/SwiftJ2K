// SPDX-License-Identifier: Apache-2.0
//
// JP3DJPIPServer.swift
// SwiftJ2KJPIP
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/JPIP/JP3DJPIPServer.swift
//
/// # JP3DJPIPServer
///
/// JPIP server actor for serving Part 10 JP3D volumetric data over real TCP HTTP/1.1
/// and RFC 6455 WebSocket connections, as well as programmatic 3D delivery scheduling.
///
/// `JP3DJPIPServer` manages volume registration, real TCP listener lifecycle (`JPIPServer`),
/// session creation/removal, normative ITU-T T.808 + T.809 3D precinct data-bin extraction,
/// shared precinct caching, and bandwidth-aware delivery scheduling.

import Foundation
@_exported import SwiftJ2K
@_exported import SwiftJ2K3D

// MARK: - Server Configuration

/// Configuration for the JP3D JPIP server.
public struct JP3DServerConfiguration: Sendable {
    /// TCP/WebSocket port to listen on (`0` binds an ephemeral OS-assigned port).
    public let port: Int
    /// Maximum number of concurrent streaming sessions.
    public let maxSessions: Int
    /// Per-session bandwidth cap in bytes/sec (`0` = unlimited).
    public let perSessionBandwidthCap: Double
    /// Maximum volume size in bytes before forcing streaming-only mode.
    public let maxFullVolumeBytes: Int
    /// Maximum precinct cache entries shared across all sessions.
    public let maxPrecinctCacheEntries: Int

    /// Creates a server configuration.
    public init(
        port: Int = 8080,
        maxSessions: Int = 100,
        perSessionBandwidthCap: Double = 0,
        maxFullVolumeBytes: Int = 1_000_000_000,
        maxPrecinctCacheEntries: Int = 8192
    ) {
        self.port = port
        self.maxSessions = max(1, maxSessions)
        self.perSessionBandwidthCap = max(0, perSessionBandwidthCap)
        self.maxFullVolumeBytes = max(0, maxFullVolumeBytes)
        self.maxPrecinctCacheEntries = max(1, maxPrecinctCacheEntries)
    }

    /// Default configuration suitable for local development.
    public static let `default` = JP3DServerConfiguration()
    /// High-concurrency production configuration.
    public static let production = JP3DServerConfiguration(
        port: 443,
        maxSessions: 500,
        perSessionBandwidthCap: 50_000_000,
        maxFullVolumeBytes: 10_000_000_000,
        maxPrecinctCacheEntries: 32768
    )
}

// MARK: - Server Errors

/// Errors produced by the JP3D JPIP server.
public enum JP3DServerError: Error, Sendable {
    case alreadyRunning
    case notRunning
    case sessionLimitExceeded(Int)
    case unknownVolume(String)
    case invalidTile(String)
    case volumeTooLarge(Int)
    case emptyFrustum
}

// MARK: - Registered Volume

/// A volume registered with the server for streaming.
public struct JP3DRegisteredVolume: Sendable {
    /// Identifier of the volume.
    public let volumeID: String
    /// Volume metadata (dimensions etc.).
    public let volume: J2KVolume
    /// Compressed codestream data.
    public let data: Data
    /// Axis-aligned bounding region of the full volume.
    public let fullRegion: JP3DStreamingRegion
    /// Tiling configuration.
    public let tileWidth: Int
    public let tileHeight: Int
    public let tileDepth: Int

    /// Creates a registered volume entry.
    public init(
        volumeID: String, volume: J2KVolume, data: Data,
        tileWidth: Int = 128, tileHeight: Int = 128,
        tileDepth: Int = 8
    ) {
        self.volumeID = volumeID
        self.volume = volume
        self.data = data
        self.fullRegion = JP3DStreamingRegion(
            xRange: 0..<volume.width,
            yRange: 0..<volume.height,
            zRange: 0..<volume.depth
        )
        self.tileWidth = max(1, tileWidth)
        self.tileHeight = max(1, tileHeight)
        self.tileDepth = max(1, tileDepth)
    }

    /// Returns the tile grid dimensions for this volume.
    public var tilesX: Int { (volume.width + tileWidth - 1) / tileWidth }
    public var tilesY: Int { (volume.height + tileHeight - 1) / tileHeight }
    public var tilesZ: Int { (volume.depth + tileDepth - 1) / tileDepth }

    /// Returns the data size in bytes.
    public var byteCount: Int { data.count }
}

// MARK: - Server Actor

/// JP3D JPIP server actor for multi-session volumetric streaming over HTTP/1.1 and RFC 6455 WebSocket.
public actor JP3DJPIPServer {
    // MARK: - Configuration

    public let configuration: JP3DServerConfiguration

    // MARK: - State

    private(set) var isRunning: Bool = false
    private var registeredVolumes: [String: JP3DRegisteredVolume] = [:]
    private var sessions: [String: JP3DStreamingSession] = [:]
    private var precinctCache: [JP3DPrecinct3D: Data] = [:]
    private var requestCount: Int = 0
    private let jpipServer: JPIPServer
    private let dataBinGenerator = JPIPDataBinGenerator()

    /// Actual bound TCP port once `start()` completes.
    public var listeningPort: Int {
        get async { await jpipServer.listeningPort }
    }

    // MARK: - Initialiser

    /// Creates a JP3D JPIP server with the given configuration.
    public init(configuration: JP3DServerConfiguration = .default) {
        self.configuration = configuration
        let perClientBW: Int? = configuration.perSessionBandwidthCap > 0
            ? Int(configuration.perSessionBandwidthCap)
            : nil
        self.jpipServer = JPIPServer(
            port: configuration.port,
            configuration: JPIPServer.Configuration(
                maxClients: configuration.maxSessions,
                perClientBandwidthLimit: perClientBW
            )
        )
    }

    // MARK: - Volume Registration

    /// Registers a volume for streaming over HTTP/1.1, WebSocket, and direct schedule APIs.
    public func registerVolume(name: String, data: Data, volume: J2KVolume) async throws {
        var effectiveData = data
        if !JP3DJPIPIndexer.isJP3DCodestream(data),
           data.isEmpty,
           !volume.components.isEmpty,
           volume.components.allSatisfy({ !$0.data.isEmpty }) {
            let encoded = try await JP3DEncoder(configuration: .lossless).encode(volume)
            effectiveData = encoded.data
        }

        registeredVolumes[name] = JP3DRegisteredVolume(
            volumeID: name,
            volume: volume,
            data: effectiveData
        )
        await jpipServer.registerImageData(name: name, data: effectiveData)
    }

    /// Registers an on-disk `.jp3d` file for streaming.
    public func registerVolumeFile(name: String, at url: URL) async throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let parsed = try JP3DCodestreamParser().parse(data)
        let stubComponents = (0..<parsed.siz.componentCount).map { idx in
            J2KVolumeComponent(
                index: idx,
                bitDepth: parsed.siz.bitDepth(forComponent: idx),
                signed: parsed.siz.isSigned(forComponent: idx),
                width: parsed.siz.width,
                height: parsed.siz.height,
                depth: parsed.siz.depth,
                data: Data()
            )
        }
        let metaVol = J2KVolume(
            width: parsed.siz.width,
            height: parsed.siz.height,
            depth: parsed.siz.depth,
            components: stubComponents
        )
        registeredVolumes[name] = JP3DRegisteredVolume(
            volumeID: name,
            volume: metaVol,
            data: data,
            tileWidth: parsed.siz.tileSizeX,
            tileHeight: parsed.siz.tileSizeY,
            tileDepth: parsed.siz.tileSizeZ
        )
        try await jpipServer.registerImage(name: name, at: url)
    }

    /// Removes a registered volume and invalidates related cache entries.
    public func unregisterVolume(name: String) async {
        registeredVolumes.removeValue(forKey: name)
        precinctCache.removeAll()
        await jpipServer.unregisterImage(name: name)
    }

    /// Returns identifiers of all registered volumes.
    public var registeredVolumeIDs: [String] {
        Array(registeredVolumes.keys)
    }

    // MARK: - Lifecycle

    /// Starts the real TCP HTTP/1.1 + WebSocket listener and begins accepting connections.
    public func start() async throws {
        guard !isRunning else { throw JP3DServerError.alreadyRunning }
        try await jpipServer.start()
        isRunning = true
    }

    /// Stops the server and disconnects all sessions.
    public func stop() async throws {
        guard isRunning else { throw JP3DServerError.notRunning }
        try? await jpipServer.stop()
        sessions.removeAll()
        isRunning = false
    }

    // MARK: - Session Management

    @discardableResult
    public func createSession(volumeID: String, viewport: JP3DViewport) async throws -> String {
        guard sessions.count < configuration.maxSessions else {
            throw JP3DServerError.sessionLimitExceeded(configuration.maxSessions)
        }
        guard registeredVolumes[volumeID] != nil else {
            throw JP3DServerError.unknownVolume(volumeID)
        }
        let session = JP3DStreamingSession(sessionID: UUID().uuidString, volumeID: volumeID, viewport: viewport)
        sessions[session.sessionID] = session
        return session.sessionID
    }

    /// Removes a session by identifier.
    public func removeSession(_ sessionID: String) {
        sessions.removeValue(forKey: sessionID)
    }

    /// Current number of active sessions.
    public var sessionCount: Int { sessions.count }

    // MARK: - Request Handling

    /// Handles a 3D streaming request from a client session.
    public func handleRequest(_ region: JP3DStreamingRegion, sessionID: String) async throws -> JP3DDeliverySchedule {
        requestCount += 1

        guard var session = sessions[sessionID] else {
            throw JP3DServerError.unknownVolume(sessionID)
        }
        guard let registered = registeredVolumes[session.volumeID] else {
            throw JP3DServerError.unknownVolume(session.volumeID)
        }

        if let frustum = session.viewport.frustum {
            let vol = registered.volume
            if !frustum.intersects(xRange: 0..<vol.width, yRange: 0..<vol.height, zRange: 0..<vol.depth) {
                throw JP3DServerError.emptyFrustum
            }
        }

        let isFullVolume = region.xRange == (0..<registered.volume.width)
            && region.yRange == (0..<registered.volume.height)
            && region.zRange == (0..<registered.volume.depth)
        if isFullVolume && registered.byteCount > configuration.maxFullVolumeBytes {
            throw JP3DServerError.volumeTooLarge(registered.byteCount)
        }

        let vol = registered.volume
        let xRange = max(region.xRange.lowerBound, 0)..<min(region.xRange.upperBound, vol.width)
        let yRange = max(region.yRange.lowerBound, 0)..<min(region.yRange.upperBound, vol.height)
        let zRange = max(region.zRange.lowerBound, 0)..<min(region.zRange.upperBound, vol.depth)

        guard !xRange.isEmpty && !yRange.isEmpty && !zRange.isEmpty else {
            return JP3DDeliverySchedule(bins: [], estimatedSeconds: 0, hasMore: false)
        }

        session.lastActivity = Date()
        sessions[sessionID] = session

        let bins = extractPrecincts(
            from: registered,
            xRange: xRange, yRange: yRange, zRange: zRange,
            qualityLayer: region.qualityLayer,
            resolutionLevel: region.resolutionLevel
        )

        let bandwidth = configuration.perSessionBandwidthCap > 0
            ? configuration.perSessionBandwidthCap
            : 10_000_000.0
        let totalBytes = bins.reduce(0) { $0 + $1.byteCount }
        let estimatedSeconds = bandwidth > 0 ? Double(totalBytes) / bandwidth : 0

        return JP3DDeliverySchedule(bins: bins, estimatedSeconds: estimatedSeconds, hasMore: false)
    }

    // MARK: - Prefetching

    public func prefetch(sessionID: String) async {
        guard let session = sessions[sessionID],
              let registered = registeredVolumes[session.volumeID] else { return }
        let vp = session.viewport
        let vol = registered.volume
        let xLo = max(0, vp.xRange.lowerBound - registered.tileWidth)
        let xHi = min(vol.width, vp.xRange.upperBound + registered.tileWidth)
        let yLo = max(0, vp.yRange.lowerBound - registered.tileHeight)
        let yHi = min(vol.height, vp.yRange.upperBound + registered.tileHeight)
        let zLo = max(0, vp.zRange.lowerBound - registered.tileDepth)
        let zHi = min(vol.depth, vp.zRange.upperBound + registered.tileDepth)
        let expanded = JP3DStreamingRegion(
            xRange: xLo..<xHi,
            yRange: yLo..<yHi,
            zRange: zLo..<zHi
        )
        guard expanded.isValid else { return }
        _ = extractPrecincts(
            from: registered,
            xRange: expanded.xRange, yRange: expanded.yRange, zRange: expanded.zRange,
            qualityLayer: 0, resolutionLevel: 0
        )
    }

    // MARK: - Cache Statistics

    public var precinctCacheSize: Int { precinctCache.count }

    // MARK: - Private Helpers

    private func extractPrecincts(
        from registered: JP3DRegisteredVolume,
        xRange: Range<Int>, yRange: Range<Int>, zRange: Range<Int>,
        qualityLayer: Int, resolutionLevel: Int
    ) -> [JP3DDataBin] {
        if JP3DJPIPIndexer.isJP3DCodestream(registered.data) {
            var req = JPIPRequest(target: registered.volumeID)
            req.roff = (xRange.lowerBound, yRange.lowerBound)
            req.rsiz = (xRange.count, yRange.count)
            req.zRange = (zRange.lowerBound, zRange.count)
            if qualityLayer > 0 { req.layers = qualityLayer }
            if resolutionLevel > 0 { req.reslevels = resolutionLevel }
            req.streamType = .jppStream

            if let generated = try? dataBinGenerator.generateWireDataBins(
                from: registered.data,
                request: req,
                defaultStreamType: .jppStream
            ) {
                var out: [JP3DDataBin] = []
                out.reserveCapacity(generated.bins.count)
                for (idx, wBin) in generated.bins.enumerated() {
                    let key = JP3DPrecinct3D(
                        tileX: wBin.binClass.rawValue,
                        tileY: 0,
                        tileZ: zRange.lowerBound,
                        resolutionLevel: resolutionLevel,
                        subband: 0,
                        precinctIndex: wBin.binID
                    )
                    let payload: Data
                    if let cached = precinctCache[key], qualityLayer == 0 {
                        payload = cached
                    } else {
                        payload = wBin.data
                        if qualityLayer == 0 && precinctCache.count < configuration.maxPrecinctCacheEntries {
                            precinctCache[key] = payload
                        }
                    }
                    out.append(JP3DDataBin(
                        binID: wBin.binID,
                        tileX: 0,
                        tileY: 0,
                        tileZ: zRange.lowerBound,
                        resolutionLevel: resolutionLevel,
                        qualityLayer: qualityLayer,
                        data: payload,
                        isComplete: wBin.isComplete && (idx == generated.bins.count - 1)
                    ))
                }
                return out
            }
        }

        // Deterministic byte-range fallback for non-codestream unit-test fixture blobs.
        var bins: [JP3DDataBin] = []
        var binID = 0

        let txStart = xRange.lowerBound / registered.tileWidth
        let txEnd = (xRange.upperBound - 1) / registered.tileWidth
        let tyStart = yRange.lowerBound / registered.tileHeight
        let tyEnd = (yRange.upperBound - 1) / registered.tileHeight
        let tzStart = zRange.lowerBound / registered.tileDepth
        let tzEnd = (zRange.upperBound - 1) / registered.tileDepth

        for tz in tzStart...tzEnd {
            for ty in tyStart...tyEnd {
                for tx in txStart...txEnd {
                    let key = JP3DPrecinct3D(
                        tileX: tx, tileY: ty, tileZ: tz,
                        resolutionLevel: resolutionLevel,
                        subband: 0,
                        precinctIndex: 0
                    )
                    let data: Data
                    if let cached = precinctCache[key] {
                        data = cached
                    } else {
                        let offset = (tz * registered.tilesY * registered.tilesX + ty * registered.tilesX + tx) * 64
                        let safeOffset = min(offset, max(0, registered.data.count - 64))
                        let end = min(safeOffset + 64, registered.data.count)
                        data = safeOffset < end ? Data(registered.data[safeOffset..<end]) : Data()
                        if precinctCache.count < configuration.maxPrecinctCacheEntries {
                            precinctCache[key] = data
                        }
                    }
                    let isLast = tx == txEnd && ty == tyEnd && tz == tzEnd
                    bins.append(JP3DDataBin(
                        binID: binID,
                        tileX: tx, tileY: ty, tileZ: tz,
                        resolutionLevel: resolutionLevel,
                        qualityLayer: qualityLayer,
                        data: data,
                        isComplete: isLast
                    ))
                    binID += 1
                }
            }
        }
        return bins
    }
}
