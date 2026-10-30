// SPDX-License-Identifier: Apache-2.0
//
// JPIP.swift
// SwiftJ2KJPIP
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/JPIP/JPIP.swift
//
// Re-engineered in Phase R3 (F04) with normative ITU-T Rec. T.808 (12/2022) V2 |
// ISO/IEC 15444-9 Annex A.2 VBAS data-bin parsing, progressive cache accumulation,
// multi-chunk `len=` EOR `0x04` resumption, `JPIP-cnew` `path=` channel routing,
// Clause C.8.1 stateless `model=` cache signalling, `cclose` channel teardown,
// and progression-aware JPP/JPT codestream/JP2 reconstruction.

import Foundation
@_exported import SwiftJ2K
@_exported import SwiftJ2K3D

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A JPIP client for requesting and receiving JPEG 2000 data over HTTP/1.1.
public actor JPIPClient {
    /// The server URL to connect to.
    public let serverURL: URL

    /// Preferred coding format for JPIP capability negotiation.
    public let codingPreference: JPIPCodingPreference

    /// Session delivery mode (`incremental` stateful data-bin caching or `full` stateless delivery).
    package let deliveryMode: JPIPDeliveryMode

    /// Maximum number of data bins retained in the session cache.
    package let maxCachedDataBins: Int

    /// Maximum byte size retained in the session cache.
    package let maxCacheSizeBytes: Int

    /// The HTTP transport layer.
    private let transport: JPIPTransport

    /// Active session, if any.
    private var session: JPIPSession?

    /// Creates a new JPIP client.
    ///
    /// - Parameters:
    ///   - serverURL: The URL of the JPIP server.
    ///   - codingPreference: Optional coding preference (`none`, `htj2k`, or `legacy`).
    public init(serverURL: URL, codingPreference: JPIPCodingPreference = .none) {
        self.serverURL = serverURL
        self.codingPreference = codingPreference
        self.deliveryMode = .incremental
        self.maxCachedDataBins = 10_000
        self.maxCacheSizeBytes = 100 * 1024 * 1024
        self.transport = JPIPTransport(baseURL: serverURL)
    }

    /// Creates a new JPIP client with explicit ``JPIPSessionConfiguration`` parameters.
    package init(
        serverURL: URL,
        configuration: JPIPSessionConfiguration
    ) {
        self.serverURL = serverURL
        self.codingPreference = configuration.codingPreference
        self.deliveryMode = configuration.deliveryMode
        self.maxCachedDataBins = configuration.maxCachedDataBins
        self.maxCacheSizeBytes = configuration.maxCacheSizeBytes
        self.transport = JPIPTransport(baseURL: serverURL)
    }

    /// Creates a new JPIP client bound explicitly to an injected ``JPIPServer``.
    public init(
        server: JPIPServer,
        serverURL: URL? = nil,
        codingPreference: JPIPCodingPreference = .none
    ) {
        self.serverURL = serverURL ?? URL(string: "http://127.0.0.1:\(max(1, server.port))")!
        self.codingPreference = codingPreference
        self.deliveryMode = .incremental
        self.maxCachedDataBins = 10_000
        self.maxCacheSizeBytes = 100 * 1024 * 1024
        self.transport = JPIPTransport(server: server)
    }

    /// Creates a new JPIP client bound explicitly to an injected ``JPIPServer`` with explicit session configuration.
    package init(
        server: JPIPServer,
        serverURL: URL? = nil,
        configuration: JPIPSessionConfiguration
    ) {
        self.serverURL = serverURL ?? URL(string: "http://127.0.0.1:\(max(1, server.port))")!
        self.codingPreference = configuration.codingPreference
        self.deliveryMode = configuration.deliveryMode
        self.maxCachedDataBins = configuration.maxCachedDataBins
        self.maxCacheSizeBytes = configuration.maxCacheSizeBytes
        self.transport = JPIPTransport(server: server)
    }

    /// Returns statistics for the active session, if any.
    package func getSessionStats() async -> (channelID: String?, cachedBins: Int, cacheSize: Int)? {
        guard let currentSession = self.session else { return nil }
        let cid = await currentSession.channelID
        let stats = await currentSession.getCacheStatistics()
        return (channelID: cid, cachedBins: stats.entryCount, cacheSize: stats.totalSize)
    }

    /// Returns the active session, if any.
    public func getActiveSession() -> JPIPSession? {
        session
    }

    /// Creates a new stateful JPIP channel session for `target`.
    ///
    /// - Parameter target: The target image identifier.
    /// - Returns: A JPIP session.
    /// - Throws: ``J2KError`` if session creation fails.
    public func createSession(target: String) async throws -> JPIPSession {
        let sessionID = UUID().uuidString
        let newSession = JPIPSession(
            sessionID: sessionID,
            maxCacheSizeBytes: maxCacheSizeBytes,
            maxCachedDataBins: maxCachedDataBins
        )
        await newSession.setTarget(target)
        await transport.setChannelPath(nil)

        var request = JPIPRequest(target: target)
        request.cnew = .http
        request.streamType = .jppStream
        request.len = 3
        if codingPreference != .none {
            request.codingPreference = codingPreference
        }

        let response = try await transport.send(request)

        if let channelID = response.channelID ?? JPIPResponseParser.extractChannelID(from: response.headers) {
            await newSession.setChannelID(channelID)
            await newSession.activate()
        }
        if let negotiatedPath = JPIPResponseParser.extractChannelPath(from: response.headers) {
            await newSession.setChannelPath(negotiatedPath)
            await transport.setChannelPath(negotiatedPath)
        }
        if let tid = JPIPResponseParser.extractTargetID(from: response.headers) {
            await newSession.setTargetID(tid)
        }

        // If the server piggybacked initial VBAS data-bins on the `cnew` response, record them!
        if !response.data.isEmpty, Self.isVBASStreamResponse(response) {
            let parsed = try JPIPWireCodec.decodeStream(response.data)
            for bin in parsed.bins {
                await newSession.recordDataBin(bin)
            }
        }

        self.session = newSession
        return newSession
    }

    /// Explicitly closes the active stateful JPIP channel on the server using ITU-T T.808 `cclose`.
    public func closeChannel() async throws {
        guard let currentSession = self.session else { return }
        if let cid = await currentSession.channelID, !cid.isEmpty {
            var closeReq = JPIPRequest(target: "")
            closeReq.cid = cid
            closeReq.cclose = [cid]
            _ = try await transport.send(closeReq)
        }
        try await currentSession.close()
        self.session = nil
        await transport.setChannelPath(nil)
    }

    /// Sends an explicit ``JPIPRequest`` over HTTP/1.1, parses the normative VBAS stream,
    /// records all received data-bins into the active session cache (if any), and returns
    /// both the HTTP response and decoded ``JPIPParsedStream``.
    public func sendStreamRequest(
        _ request: JPIPRequest,
        attachStatelessCacheModel: Bool = false,
        maxBodyBytes: Int = 128 * 1024 * 1024
    ) async throws -> (response: JPIPResponse, stream: JPIPParsedStream) {
        var effectiveReq = request
        if attachStatelessCacheModel, let currentSession = self.session, effectiveReq.model == nil {
            let descriptors = await currentSession.formatCacheModelDescriptors()
            if !descriptors.isEmpty {
                effectiveReq.model = descriptors
            }
        } else if effectiveReq.cid == nil,
                  effectiveReq.cnew == nil,
                  !attachStatelessCacheModel,
                  let currentSession = self.session,
                  let cid = await currentSession.channelID {
            effectiveReq.cid = cid
        }

        let response = try await transport.send(effectiveReq, maxBodyBytes: maxBodyBytes)
        if let cid = response.channelID ?? JPIPResponseParser.extractChannelID(from: response.headers) {
            let targetName = request.target
            let sess = self.session ?? JPIPSession(
                sessionID: UUID().uuidString,
                maxCacheSizeBytes: maxCacheSizeBytes,
                maxCachedDataBins: maxCachedDataBins
            )
            await sess.setTarget(targetName)
            await sess.setChannelID(cid)
            await sess.activate()
            self.session = sess
        }

        let parsed = try JPIPWireCodec.decodeStream(response.data, maxPayloadBytes: maxBodyBytes)
        if let currentSession = self.session {
            for bin in parsed.bins {
                await currentSession.recordDataBin(bin)
            }
        }
        return (response, parsed)
    }

    /// Reassembles the complete JPEG 2000 codestream or JP2 container from the active session's
    /// accumulated data-bins.
    public func reconstructCachedCodestream(
        reconstructContainer: Bool = true,
        limits: ResourceLimits = .default
    ) async throws -> Data {
        guard let currentSession = self.session else {
            throw J2KError.invalidState("No active JPIP session cache to reconstruct.")
        }
        let bins = await currentSession.getAccumulatedDataBins()
        return JPIPDataBinGenerator().reassembleCodestream(
            from: bins,
            reconstructContainer: reconstructContainer,
            limits: limits
        )
    }

    /// Requests an image from the server.
    public func requestImage(imageID: String) async throws -> J2KImage {
        let currentSession = try await getOrCreateSession(target: imageID)

        var request = JPIPRequest(target: imageID)
        if codingPreference != .none {
            request.codingPreference = codingPreference
        }
        if let channelID = await currentSession.channelID {
            request.cid = channelID
        }

        let response = try await transport.send(request)
        return try await decodeImageResponse(response, baseRequest: request, session: currentSession)
    }

    /// Requests a specific region of interest from an image.
    public func requestRegion(
        imageID: String,
        region: (x: Int, y: Int, width: Int, height: Int),
        layers: Int? = nil
    ) async throws -> J2KImage {
        let currentSession = try await getOrCreateSession(target: imageID)

        var request = JPIPRequest.regionRequest(
            target: imageID,
            x: region.x,
            y: region.y,
            width: region.width,
            height: region.height,
            layers: layers
        )
        if codingPreference != .none {
            request.codingPreference = codingPreference
        }
        if let channelID = await currentSession.channelID {
            request.cid = channelID
        }

        let response = try await transport.send(request)
        return try await decodeImageResponse(
            response,
            baseRequest: request,
            session: currentSession,
            maxQualityLayers: layers,
            region: region
        )
    }

    /// Gets the current session or creates a new one.
    private func getOrCreateSession(target: String) async throws -> JPIPSession {
        if let existing = self.session, await existing.target == target {
            return existing
        }
        return try await createSession(target: target)
    }

    /// Requests progressive quality layers for an image.
    public func requestProgressiveQuality(imageID: String, upToLayers: Int) async throws -> J2KImage {
        let currentSession = try await getOrCreateSession(target: imageID)

        var request = JPIPRequest.progressiveQualityRequest(target: imageID, upToLayers: upToLayers)
        if codingPreference != .none {
            request.codingPreference = codingPreference
        }
        if let channelID = await currentSession.channelID {
            request.cid = channelID
        }

        let response = try await transport.send(request)
        return try await decodeImageResponse(
            response,
            baseRequest: request,
            session: currentSession,
            maxQualityLayers: upToLayers
        )
    }

    /// Requests a specific resolution level of an image.
    public func requestResolutionLevel(imageID: String, level: Int, layers: Int? = nil) async throws -> J2KImage {
        let currentSession = try await getOrCreateSession(target: imageID)

        var request = JPIPRequest.resolutionLevelRequest(target: imageID, level: level, layers: layers)
        if codingPreference != .none {
            request.codingPreference = codingPreference
        }
        if let channelID = await currentSession.channelID {
            request.cid = channelID
        }

        let response = try await transport.send(request)
        return try await decodeImageResponse(
            response,
            baseRequest: request,
            session: currentSession,
            maxQualityLayers: layers,
            resolutionLevel: level
        )
    }

    /// Requests specific components of an image.
    public func requestComponents(imageID: String, components: [Int], layers: Int? = nil) async throws -> J2KImage {
        let currentSession = try await getOrCreateSession(target: imageID)

        var request = JPIPRequest.componentRequest(target: imageID, components: components, layers: layers)
        if codingPreference != .none {
            request.codingPreference = codingPreference
        }
        if let channelID = await currentSession.channelID {
            request.cid = channelID
        }

        let response = try await transport.send(request)
        return try await decodeImageResponse(
            response,
            baseRequest: request,
            session: currentSession,
            maxQualityLayers: layers,
            components: components
        )
    }

    /// Requests metadata for an image without transferring image data.
    public func requestMetadata(imageID: String) async throws -> sending [String: Any] {
        let currentSession = try await getOrCreateSession(target: imageID)

        var request = JPIPRequest.metadataRequest(target: imageID)
        if let channelID = await currentSession.channelID {
            request.cid = channelID
        }

        let response = try await transport.send(request)

        var metadata: [String: Any] = [:]
        let currentChannelID = await currentSession.channelID
        metadata["channelID"] = response.channelID ?? currentChannelID ?? "none"
        metadata["statusCode"] = response.statusCode
        metadata["dataSize"] = response.data.count

        if !response.data.isEmpty {
            if Self.isVBASStreamResponse(response),
               let parsed = try? JPIPWireCodec.decodeStream(response.data) {
                for bin in parsed.bins {
                    await currentSession.recordDataBin(bin)
                }
                metadata["dataBinCount"] = parsed.bins.count
                if let mainBin = parsed.bins.first(where: { $0.binClass == .mainHeader }),
                   let info = try? Decoder().inspect(mainBin.data + Data([0xFF, 0xD9])) {
                    metadata["width"] = info.descriptor.width
                    metadata["height"] = info.descriptor.height
                    metadata["components"] = info.descriptor.components.count
                    metadata["bitDepth"] = info.descriptor.meaningfulBits
                }
            } else if let jsonObject = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] {
                for (k, v) in jsonObject {
                    metadata[k] = v
                }
            } else if let text = String(data: response.data, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    let key = String(parts[0])
                    let valStr = String(parts[1])
                    if let intVal = Int(valStr) {
                        metadata[key] = intVal
                    } else if valStr == "true" {
                        metadata[key] = true
                    } else if valStr == "false" {
                        metadata[key] = false
                    } else {
                        metadata[key] = valStr
                    }
                }
            }
        }

        return metadata
    }

    // MARK: - Contract API-13 Bounded Image Delivery

    /// Requests and decodes a JPIP image with pre-allocation resource admission, deadline enforcement,
    /// VBAS data-bin accumulation, and codestream fidelity inspection.
    package func requestDeliveredImage(
        imageID: String,
        viewWindow: JPIPViewWindow?,
        limits: ResourceLimits,
        executionPolicy: ExecutionPolicy,
        metadataPolicy: MetadataPolicy,
        deadline: ContinuousClock.Instant
    ) async throws -> J2KDecoder.DecodedCodestreamInfo {
        @inline(__always)
        func checkDeadline() throws {
            try Task.checkCancellation()
            if ContinuousClock.now > deadline {
                throw CodecError(.resourceLimitExceeded, "JPIP operation deadline elapsed.")
            }
        }

        @inline(__always)
        func checkedAdd(_ a: Int, _ b: Int) throws -> Int {
            let (s, ov) = a.addingReportingOverflow(b)
            guard !ov else {
                throw CodecError(.resourceLimitExceeded, "JPIP storage arithmetic overflow.")
            }
            return s
        }

        func cacheStorageBytes(_ statistics: JPIPCacheModel.Statistics) throws -> Int {
            let (descriptors, overflow) = statistics.entryCount.multipliedReportingOverflow(
                by: MemoryLayout<JPIPCacheModel.CacheEntry>.stride
            )
            let (total, sumOverflow) = statistics.totalSize.addingReportingOverflow(descriptors)
            guard !overflow, !sumOverflow else {
                throw CodecError(.resourceLimitExceeded, "JPIP retained cache storage overflows Int.")
            }
            return total
        }

        try checkDeadline()
        let activeSession: JPIPSession?
        if deliveryMode == .incremental {
            activeSession = try await getOrCreateSession(target: imageID)
        } else {
            activeSession = nil
        }
        try checkDeadline()

        var request = JPIPRequest(target: imageID)
        var regionTuple: (x: Int, y: Int, width: Int, height: Int)? = nil
        if let window = viewWindow {
            if let rx = window.regionOriginX,
               let ry = window.regionOriginY,
               let rw = window.regionWidth,
               let rh = window.regionHeight {
                regionTuple = (x: rx, y: ry, width: rw, height: rh)
                request.roff = (rx, ry)
                request.rsiz = (rw, rh)
            }
            if let comps = window.components {
                request.comps = comps
            }
            if let layers = window.maxQualityLayers {
                request.layers = layers
            }
        }

        if request.streamType == nil {
            request.streamType = .jppStream
        }
        if codingPreference != .none {
            request.codingPreference = codingPreference
        }
        if let currentSession = activeSession, let channelID = await currentSession.channelID {
            request.cid = channelID
            let sessionNeedsSync = await currentSession.needsServerModelSync
            if sessionNeedsSync || maxCachedDataBins == 0 || maxCacheSizeBytes == 0 {
                request.model = ["-*"] + (await currentSession.formatCacheModelDescriptors())
            }
            await currentSession.markPendingWireTransfer()
        }

        let maxWireBytes = min(limits.maximumCompressedBytes, limits.maximumMemoryBytes)
        var probedBins: [JPIPDataBin] = []
        if request.fsiz == nil {
            var cachedMainHdr: Data? = nil
            if let currentSession = activeSession {
                cachedMainHdr = (await currentSession.getAccumulatedDataBins())
                    .first(where: { $0.binClass == .mainHeader && $0.isComplete })?.data
            }
            if (request.roff != nil || request.rsiz != nil) && cachedMainHdr == nil {
                var probeReq = request
                probeReq.roff = nil
                probeReq.rsiz = nil
                probeReq.layers = 1
                probeReq.fsiz = (1, 1)
                probeReq.fsizRoundDirection = "closest"
                let probeResp = try await transport.send(probeReq, maxBodyBytes: maxWireBytes)
                try checkDeadline()
                if !probeResp.data.isEmpty, Self.isVBASStreamResponse(probeResp) {
                    let probeParsed = try JPIPWireCodec.decodeStream(
                        probeResp.data,
                        maxPayloadBytes: limits.maximumCompressedBytes
                    )
                    probedBins = probeParsed.bins
                    var tmpCache = JPIPCacheModel(maxCacheSize: Int.max, maxEntries: Int.max)
                    for b in probedBins { tmpCache.addDataBin(b) }
                    cachedMainHdr = tmpCache.allDataBins().first(where: { $0.binClass == .mainHeader })?.data
                    if activeSession == nil, !probedBins.isEmpty {
                        request.model = tmpCache.formatCacheModelDescriptors()
                    }
                }
            }
            if let mh = cachedMainHdr, let dims = JPIPRequest.extractCodestreamDimensions(fromMainHeader: mh) {
                request.fsiz = dims
            } else {
                request.fsiz = (1_048_576, 1_048_576)
                request.fsizRoundDirection = "round-down"
            }
        }

        let response = try await transport.send(request, maxBodyBytes: maxWireBytes)
        try checkDeadline()

        guard !response.data.isEmpty else {
            throw J2KError.decodingError("JPIP response contains no image data")
        }
        guard response.data.count <= limits.maximumCompressedBytes,
              response.data.count <= limits.maximumMemoryBytes else {
            throw CodecError(
                .resourceLimitExceeded,
                "JPIP response payload (\(response.data.count) bytes) exceeds compressed or memory limit"
            )
        }

        var generationWorkspacePeak = 0
        var pendingSessionBins: [JPIPDataBin] = []
        let codestreamToDecode: Data

        if Self.isVBASStreamResponse(response) {
            var parsed = try JPIPWireCodec.decodeStream(
                response.data,
                maxPayloadBytes: limits.maximumCompressedBytes
            )

            // Snapshot any prior cached bins before mutating `activeSession` so pre-mutation
            // budget checks leave `activeSession` untouched on limit denial, AND small cache
            // eviction bounds (`maxCachedDataBins` / `maxCacheSizeBytes`) can evict old retained
            // entries without losing bins needed to decode the current delivery.
            var assemblyCache = JPIPCacheModel(maxCacheSize: Int.max, maxEntries: Int.max)
            let priorStats: JPIPCacheModel.Statistics
            if let currentSession = activeSession {
                priorStats = await currentSession.getCacheStatistics()
                for priorBin in await currentSession.getAccumulatedDataBins() {
                    assemblyCache.addDataBin(priorBin)
                }
            } else {
                priorStats = JPIPCacheModel.Statistics(hits: 0, misses: 0, totalSize: 0, entryCount: 0, evictions: 0)
            }

            let incomingBins = probedBins + parsed.bins
            let retainedBefore = try cacheStorageBytes(priorStats)
            let incomingPayload = try incomingBins.reduce(0) { try checkedAdd($0, $1.data.count) }
            let (binDescBytes, ov1) = incomingBins.count.multipliedReportingOverflow(
                by: MemoryLayout<JPIPDataBin>.stride
            )
            let maxAdditionalEntries = (activeSession != nil)
                ? max(0, maxCachedDataBins - priorStats.entryCount)
                : 0
            let (cacheDescBytes, ov2) = min(incomingBins.count, maxAdditionalEntries).multipliedReportingOverflow(
                by: MemoryLayout<JPIPCacheModel.CacheEntry>.stride
            )
            guard !ov1, !ov2 else {
                throw CodecError(.resourceLimitExceeded, "JPIP bin descriptor storage overflows Int.")
            }
            let streamWorkspace = try checkedAdd(
                retainedBefore,
                try checkedAdd(incomingPayload, try checkedAdd(binDescBytes, cacheDescBytes))
            )
            guard streamWorkspace <= limits.maximumWorkspaceBytes,
                  try checkedAdd(response.data.count, streamWorkspace) <= limits.maximumMemoryBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "JPIP bin payloads, descriptors and retained cache exceed combined limits."
                )
            }
            generationWorkspacePeak = streamWorkspace

            for bin in incomingBins {
                try checkDeadline()
                assemblyCache.addDataBin(bin)
                pendingSessionBins.append(bin)
            }

            // If server truncated due to server-side `byteLimit` (`0x04`) and caller didn't cap `len`,
            // resume automatically up to completion.
            var resumeRounds = 0
            while parsed.eorReason == .byteLimit && request.len == nil && resumeRounds < 1024 {
                resumeRounds += 1
                try checkDeadline()
                var followReq = request
                followReq.model = nil
                if activeSession == nil {
                    followReq.model = assemblyCache.formatCacheModelDescriptors()
                }
                let nextResp = try await transport.send(followReq, maxBodyBytes: maxWireBytes)
                let nextParsed = try JPIPWireCodec.decodeStream(
                    nextResp.data,
                    maxPayloadBytes: limits.maximumCompressedBytes
                )
                if nextParsed.bins.isEmpty { break }
                for bin in nextParsed.bins {
                    try checkDeadline()
                    assemblyCache.addDataBin(bin)
                    pendingSessionBins.append(bin)
                }
                parsed = nextParsed
            }

            codestreamToDecode = JPIPDataBinGenerator().reassembleCodestream(
                from: assemblyCache.allDataBins(),
                reconstructContainer: true,
                limits: limits
            )
        } else {
            if let currentSession = activeSession, maxCachedDataBins > 0, maxCacheSizeBytes > 0 {
                let cacheStatistics = await currentSession.getCacheStatistics()
                let generated = try JPIPDataBinGenerator().generateDataBins(
                    from: response.data,
                    limits: limits,
                    retainedBytes: cacheStorageBytes(cacheStatistics),
                    maximumAdditionalCacheEntries: max(0, maxCachedDataBins - cacheStatistics.entryCount)
                )
                generationWorkspacePeak = generated.peakWorkspaceBytes
                pendingSessionBins = generated.bins
            }
            codestreamToDecode = response.data
        }

        try checkDeadline()
        let retainedCacheBytes: Int
        if let activeSession {
            if maxCachedDataBins > 0, maxCacheSizeBytes > 0 {
                let prospective = await activeSession.prospectiveCacheStatistics(adding: pendingSessionBins)
                retainedCacheBytes = try cacheStorageBytes(prospective)
            } else {
                retainedCacheBytes = try cacheStorageBytes(await activeSession.getCacheStatistics())
            }
        } else {
            retainedCacheBytes = 0
        }

        let decoded = try J2KDecoder.decodeWithInfo(
            codestreamToDecode,
            maxQualityLayers: viewWindow?.maxQualityLayers,
            resolutionLevel: viewWindow?.resolutionLevel,
            components: viewWindow?.components,
            region: regionTuple,
            limits: limits,
            executionPolicy: executionPolicy,
            metadataPolicy: metadataPolicy,
            retainedExternalBytes: retainedCacheBytes
        )
        try checkDeadline()

        if let currentSession = activeSession {
            if maxCachedDataBins > 0, maxCacheSizeBytes > 0 {
                let evictionsBefore = (await currentSession.getCacheStatistics()).evictions
                await currentSession.markWireTransferSynchronized()
                for bin in pendingSessionBins {
                    await currentSession.recordDataBin(bin)
                }
                let evictionsAfter = (await currentSession.getCacheStatistics()).evictions
                let stillNeedsSync = await currentSession.needsServerModelSync
                if evictionsAfter == evictionsBefore && !stillNeedsSync {
                    await currentSession.markWireTransferSynchronized()
                }
            }
        }

        return decoded.includingAdditionalWorkspacePeak(generationWorkspacePeak)
    }

    /// Records received data bins in the session cache model, reassembles VBAS streams, and decodes the image.
    private func decodeImageResponse(
        _ response: JPIPResponse,
        baseRequest: JPIPRequest,
        session: JPIPSession,
        maxQualityLayers: Int? = nil,
        resolutionLevel: Int? = nil,
        components: [Int]? = nil,
        region: (x: Int, y: Int, width: Int, height: Int)? = nil
    ) async throws -> J2KImage {
        guard !response.data.isEmpty else {
            throw J2KError.decodingError("JPIP response contains no image data")
        }

        let codestreamData: Data
        if Self.isVBASStreamResponse(response) {
            var assemblyCache = JPIPCacheModel(maxCacheSize: Int.max, maxEntries: Int.max)
            for prior in await session.getAccumulatedDataBins() {
                assemblyCache.addDataBin(prior)
            }

            var parsed = try JPIPWireCodec.decodeStream(response.data)
            for bin in parsed.bins {
                assemblyCache.addDataBin(bin)
                await session.recordDataBin(bin)
            }

            var resumeRounds = 0
            while parsed.eorReason == .byteLimit && baseRequest.len == nil && resumeRounds < 1024 {
                resumeRounds += 1
                let nextResp = try await transport.send(baseRequest)
                let nextParsed = try JPIPWireCodec.decodeStream(nextResp.data)
                if nextParsed.bins.isEmpty { break }
                for bin in nextParsed.bins {
                    assemblyCache.addDataBin(bin)
                    await session.recordDataBin(bin)
                }
                parsed = nextParsed
            }

            codestreamData = JPIPDataBinGenerator().reassembleCodestream(
                from: assemblyCache.allDataBins(),
                reconstructContainer: true
            )
        } else {
            let generator = JPIPDataBinGenerator()
            if let bins = try? generator.generateDataBins(from: response.data) {
                for bin in bins {
                    await session.recordDataBin(bin)
                }
            }
            codestreamData = response.data
        }

        return try J2KDecoder.decodeSync(
            codestreamData,
            maxQualityLayers: maxQualityLayers,
            resolutionLevel: resolutionLevel,
            components: components,
            region: region
        )
    }

    package static func isVBASStreamResponse(_ response: JPIPResponse) -> Bool {
        let ct = response.headers.first { $0.key.lowercased() == "content-type" }?.value.lowercased() ?? ""
        if ct.contains("jpp-stream") || ct.contains("jpt-stream") {
            return true
        }
        let d = response.data
        if d.count >= 2 && d[d.startIndex] == 0xFF && d[d.startIndex + 1] == 0x4F {
            return false
        }
        if d.count >= 12
            && d[d.startIndex + 4] == 0x6A
            && d[d.startIndex + 5] == 0x50
            && d[d.startIndex + 6] == 0x20
            && d[d.startIndex + 7] == 0x20 {
            return false
        }
        return !ct.contains("octet-stream")
    }

    /// Closes the client and any active sessions.
    public func close() async throws {
        if let currentSession = self.session {
            try await currentSession.close()
            self.session = nil
        }
        await transport.close()
    }
}
