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
    private var boundedDeliveryInProgress = false

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
        try await createSession(target: target, deadline: nil)
    }

    private func createSession(
        target: String,
        deadline: ContinuousClock.Instant?, budget: JPIPTransferBudget? = nil
    ) async throws -> JPIPSession {
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

        let cachedStorage = try await session?.retainedStorageBytes() ?? 0
        var retained = try JPIPAdmission.add(cachedStorage, await transport.receiveAdmissionSnapshot().queuedBytes)
        let maxBody = try budget?.bodyLimit(retaining: retained) ?? 128 * 1024 * 1024
        let response = try await transport.send(request, maxBodyBytes: maxBody, deadline: deadline,
                maximumStorageBytes: try budget.map { try JPIPAdmission.remaining($0.limits, retaining: retained) })
        let receive = await transport.receiveAdmissionSnapshot()
        retained = try JPIPAdmission.add(cachedStorage, receive.queuedBytes)
        budget?.workspace.observe(try JPIPAdmission.add(cachedStorage, receive.peakBytes))
        let pushedPayload = await transport.takeUnaccountedPushPayloadBytes()
        try budget?.received(response.data.count, pushedPayloadBytes: pushedPayload,
            retaining: JPIPAdmission.add(retained, response.retainedHeaderStorageBytes))
        if let budget {
            let identifiers = try JPIPAdmission.add(JPIPAdmission.string(target), response.retainedHeaderStorageBytes)
            try JPIPAdmission.admit(JPIPAdmission.add(retained,
                JPIPAdmission.add(JPIPAdmission.response(response), identifiers)), limits: budget.limits, peak: budget.workspace)
        }

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
        retained = try JPIPAdmission.add(retained, await newSession.retainedStorageBytes())

        // If the server piggybacked initial VBAS data-bins on the `cnew` response, record them!
        if !response.data.isEmpty, Self.isVBASStreamResponse(response) {
            if let budget {
                let beforeParse = try JPIPAdmission.add(retained, JPIPAdmission.response(response))
                let parsed = try JPIPWireCodec.decodeStream(response.data,
                    maxPayloadBytes: budget.limits.maximumCompressedBytes,
                    maximumStorageBytes: JPIPAdmission.remaining(budget.limits, retaining: beforeParse),
                    workspaceObserver: { budget.workspace.observe(beforeParse + $0) }, deadline: deadline)
                var candidate = await newSession.copyCacheForAdmission()
                try candidate.addAdmitted(parsed.bins, limits: budget.limits,
                    retainingExternalBytes: JPIPAdmission.add(beforeParse, JPIPAdmission.add(JPIPAdmission.bins(parsed.bins), parsed.eorBody?.count ?? 0)),
                    peak: budget.workspace)
                let missing = parsed.bins.contains { !candidate.hasDataBin(binClass: $0.binClass, binID: $0.binID, codestreamID: $0.codestreamID) }
                await newSession.commitPreparedCache(candidate, requiresSync: missing)
            } else {
                let parsed = try JPIPWireCodec.decodeStream(response.data)
                for bin in parsed.bins { await newSession.recordDataBin(bin) }
            }
        }

        self.session = newSession
        return newSession
    }

    /// Explicitly closes the active stateful JPIP channel on the server using ITU-T T.808 `cclose`.
    public func closeChannel() async throws {
        try await closeChannel(deadline: nil)
    }

    private func closeChannel(deadline: ContinuousClock.Instant?, budget: JPIPTransferBudget? = nil) async throws {
        guard let currentSession = self.session else { return }
        if let cid = await currentSession.channelID, !cid.isEmpty {
            var closeReq = JPIPRequest(target: "")
            closeReq.cid = cid
            closeReq.cclose = [cid]
            let cacheBytes = try await currentSession.retainedStorageBytes()
            let retained = try JPIPAdmission.add(cacheBytes, await transport.receiveAdmissionSnapshot().queuedBytes)
            let maxBody = try budget?.bodyLimit(retaining: retained) ?? 128 * 1024 * 1024
            let response = try await transport.send(closeReq, maxBodyBytes: maxBody, deadline: deadline,
                maximumStorageBytes: try budget.map { try JPIPAdmission.remaining($0.limits, retaining: retained) })
            let receive = await transport.receiveAdmissionSnapshot()
            budget?.workspace.observe(try JPIPAdmission.add(cacheBytes, receive.peakBytes))
            let pushedPayload = await transport.takeUnaccountedPushPayloadBytes()
            try budget?.received(response.data.count, pushedPayloadBytes: pushedPayload,
                retaining: JPIPAdmission.add(cacheBytes, JPIPAdmission.add(receive.queuedBytes, response.retainedHeaderStorageBytes)))
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
        return try JPIPDataBinGenerator().reassembleCodestreamThrowing(
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
    private func getOrCreateSession(
        target: String,
        deadline: ContinuousClock.Instant? = nil, budget: JPIPTransferBudget? = nil
    ) async throws -> JPIPSession {
        if let existing = self.session, await existing.target == target {
            return existing
        }
        return try await createSession(target: target, deadline: deadline, budget: budget)
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
        guard !boundedDeliveryInProgress else {
            throw CodecError(.invalidArgument, "A bounded delivery is already active on this JPIP client.")
        }
        boundedDeliveryInProgress = true
        defer { boundedDeliveryInProgress = false }
        let budget = JPIPTransferBudget(limits)
        func checkDeadline() throws {
            try Task.checkCancellation()
            _ = try JPIPTransport.remainingSeconds(until: deadline)
        }
        try checkDeadline()
        let activeSession: JPIPSession?
        if deliveryMode == .incremental {
            if let current = session, await current.needsServerModelSync {
                try await closeChannel(deadline: deadline, budget: budget)
            }
            activeSession = try await getOrCreateSession(target: imageID, deadline: deadline, budget: budget)
        } else { activeSession = nil }
        let priorStorage = try await session?.retainedStorageBytes() ?? 0
        var candidate: JPIPCacheModel? = nil
        var candidateIncomplete = false
        if let activeSession, maxCachedDataBins > 0, maxCacheSizeBytes > 0 {
            candidate = await activeSession.copyCacheForAdmission()
        }
        var assembly = JPIPCacheModel(maxCacheSize: limits.maximumWorkspaceBytes, maxEntries: Int.max)
        if let activeSession {
            let priorCache = await activeSession.copyCacheForAdmission()
            let snapshotBytes = try priorCache.snapshotStorageBytes()
            let retained = try JPIPAdmission.add(priorStorage, candidate?.retainedStorageBytes() ?? 0)
            try JPIPAdmission.admit(JPIPAdmission.add(retained, snapshotBytes), limits: limits, peak: budget.workspace)
            let priorBins = priorCache.allDataBins()
            try assembly.addAdmitted(priorBins, limits: limits,
                retainingExternalBytes: JPIPAdmission.add(retained, snapshotBytes), peak: budget.workspace)
        }
        var modelStorage = 0
        var queuedTransportStorage = await transport.receiveAdmissionSnapshot().queuedBytes
        func liveStorage() throws -> Int {
            try JPIPAdmission.add(JPIPAdmission.add(priorStorage, JPIPAdmission.add(modelStorage, queuedTransportStorage)),
                JPIPAdmission.add(assembly.retainedStorageBytes(), candidate?.retainedStorageBytes() ?? 0))
        }
        // Consume and merge inside a synchronous scope. The wire response and
        // fragment array are released before the next read or reconstruction.
        func consume(_ response: JPIPResponse, pushedPayloadBytes: Int) throws -> (raw: Data?, eor: JPIPEORReason?) {
            let retained = try liveStorage()
            try budget.received(response.data.count, pushedPayloadBytes: pushedPayloadBytes,
                retaining: JPIPAdmission.add(retained, response.retainedHeaderStorageBytes))
            if !Self.isVBASStreamResponse(response) {
                if candidate != nil {
                    let generated = try JPIPDataBinGenerator().generateDataBins(from: response.data,
                        limits: limits, retainedBytes: JPIPAdmission.add(retained, response.retainedHeaderStorageBytes))
                    budget.workspace.observe(generated.peakWorkspaceBytes)
                    let external = try JPIPAdmission.add(JPIPAdmission.add(priorStorage, queuedTransportStorage),
                        JPIPAdmission.add(assembly.retainedStorageBytes(),
                            JPIPAdmission.add(JPIPAdmission.response(response), JPIPAdmission.bins(generated.bins))))
                    try candidate?.addAdmitted(generated.bins, limits: limits,
                        retainingExternalBytes: external, peak: budget.workspace)
                    candidateIncomplete = candidateIncomplete || generated.bins.contains {
                        candidate?.hasDataBin(binClass: $0.binClass, binID: $0.binID, codestreamID: $0.codestreamID) != true
                    }
                }
                return (response.data, nil)
            }
            let beforeParse = try JPIPAdmission.add(retained, JPIPAdmission.response(response))
            let parsed = try JPIPWireCodec.decodeStream(response.data,
                maxPayloadBytes: limits.maximumCompressedBytes,
                maximumStorageBytes: JPIPAdmission.remaining(limits, retaining: beforeParse),
                workspaceObserver: { budget.workspace.observe(beforeParse + $0) }, deadline: deadline)
            let fragments = try JPIPAdmission.add(JPIPAdmission.bins(parsed.bins), parsed.eorBody?.count ?? 0)
            let external = try JPIPAdmission.add(JPIPAdmission.add(priorStorage, queuedTransportStorage),
                JPIPAdmission.add(candidate?.retainedStorageBytes() ?? 0,
                    JPIPAdmission.add(JPIPAdmission.response(response), fragments)))
            try assembly.addAdmitted(parsed.bins, limits: limits, retainingExternalBytes: external, peak: budget.workspace)
            if candidate != nil {
                let candidateExternal = try JPIPAdmission.add(JPIPAdmission.add(priorStorage, queuedTransportStorage),
                    JPIPAdmission.add(assembly.retainedStorageBytes(),
                        JPIPAdmission.add(JPIPAdmission.response(response), fragments)))
                try candidate?.addAdmitted(parsed.bins, limits: limits,
                    retainingExternalBytes: candidateExternal, peak: budget.workspace)
                candidateIncomplete = candidateIncomplete || parsed.bins.contains {
                    candidate?.hasDataBin(binClass: $0.binClass, binID: $0.binID, codestreamID: $0.codestreamID) != true
                }
            }
            return (nil, parsed.eorReason)
        }

        var request = JPIPRequest(target: imageID)
        var regionTuple: (x: Int, y: Int, width: Int, height: Int)?
        if let window = viewWindow {
            if let x = window.regionOriginX, let y = window.regionOriginY,
               let width = window.regionWidth, let height = window.regionHeight {
                regionTuple = (x, y, width, height)
                request.roff = (x, y); request.rsiz = (width, height)
            }
            request.comps = window.components
            request.layers = window.maxQualityLayers
        }
        request.streamType = .jppStream
        if codingPreference != .none { request.codingPreference = codingPreference }
        if let activeSession, let cid = await activeSession.channelID {
            request.cid = cid
            await activeSession.markPendingWireTransfer()
        }
        if (request.roff != nil || request.rsiz != nil),
           assembly.getDataBin(binClass: .mainHeader, binID: 0) == nil {
            var probe = request
            probe.roff = nil; probe.rsiz = nil; probe.layers = 1
            probe.fsiz = (1, 1); probe.fsizRoundDirection = "closest"
            let retainedAtProbe = try liveStorage()
            let response = try await transport.send(probe,
                maxBodyBytes: budget.bodyLimit(retaining: liveStorage()), deadline: deadline,
                maximumStorageBytes: JPIPAdmission.remaining(limits, retaining: liveStorage()))
            let receive = await transport.receiveAdmissionSnapshot()
            budget.workspace.observe(try JPIPAdmission.add(retainedAtProbe - queuedTransportStorage, receive.peakBytes))
            queuedTransportStorage = receive.queuedBytes
            let pushedPayload = await transport.takeUnaccountedPushPayloadBytes()
            _ = try consume(response, pushedPayloadBytes: pushedPayload)
            try checkDeadline()
        }
        if let header = assembly.getDataBin(binClass: .mainHeader, binID: 0),
           let dimensions = JPIPRequest.extractCodestreamDimensions(fromMainHeader: header.data) {
            request.fsiz = dimensions
        } else {
            request.fsiz = (1_048_576, 1_048_576)
            request.fsizRoundDirection = "round-down"
        }
        var rawCodestream: Data?
        var rounds = 0
        repeat {
            try checkDeadline()
            request.model = nil
            modelStorage = 0
            if activeSession == nil, assembly.statistics.entryCount > 0 {
                // String model descriptors are bounded by admitted cache entries.
                let modelBytes = try JPIPAdmission.multiply(assembly.statistics.entryCount, 128)
                let sortedDescriptors = try JPIPAdmission.multiply(assembly.statistics.entryCount, MemoryLayout<JPIPCacheModel.CacheEntry>.stride)
                try JPIPAdmission.admit(JPIPAdmission.add(liveStorage(), JPIPAdmission.add(modelBytes, sortedDescriptors)), limits: limits, peak: budget.workspace)
                modelStorage = modelBytes
                request.model = assembly.formatCacheModelDescriptors()
            }
            let retained = try liveStorage()
            let response = try await transport.send(request,
                maxBodyBytes: budget.bodyLimit(retaining: retained), deadline: deadline,
                maximumStorageBytes: JPIPAdmission.remaining(limits, retaining: retained))
            let receive = await transport.receiveAdmissionSnapshot()
            budget.workspace.observe(try JPIPAdmission.add(retained - queuedTransportStorage, receive.peakBytes))
            queuedTransportStorage = receive.queuedBytes
            request.model = nil
            modelStorage = 0
            let pushedPayload = await transport.takeUnaccountedPushPayloadBytes()
            let result = try consume(response, pushedPayloadBytes: pushedPayload)
            if let raw = result.raw { rawCodestream = raw; break }
            rounds += 1
            if result.eor != .byteLimit || request.len != nil { break }
            guard rounds < 1024 else {
                throw CodecError(.resourceLimitExceeded, "JPIP response resumption limit reached.")
            }
        } while true
        request.model = nil
        let codestream: Data
        if let rawCodestream { codestream = rawCodestream }
        else {
            let retained = try liveStorage()
            let snapshotBytes = try assembly.snapshotStorageBytes()
            let outer = try JPIPAdmission.add(retained, snapshotBytes)
            try JPIPAdmission.admit(outer, limits: limits, peak: budget.workspace)
            let reconstructed = try JPIPDataBinGenerator().reassembleCodestreamBounded(
                from: assembly.allDataBins(), reconstructContainer: true,
                limits: limits.reserving(workspaceBytes: outer, memoryBytes: outer))
            budget.workspace.observe(try JPIPAdmission.add(outer, reconstructed.peakWorkspaceBytes))
            codestream = reconstructed.data
        }
        // Only the old cache and already-admitted commit candidate survive decode.
        assembly.clear()
        try checkDeadline()
        let retainedForDecode = try JPIPAdmission.add(JPIPAdmission.add(priorStorage, queuedTransportStorage), candidate?.retainedStorageBytes() ?? 0)
        let decoded = try J2KDecoder.decodeWithInfo(codestream,
            maxQualityLayers: viewWindow?.maxQualityLayers, resolutionLevel: viewWindow?.resolutionLevel,
            components: viewWindow?.components, region: regionTuple, limits: limits,
            executionPolicy: executionPolicy, metadataPolicy: metadataPolicy,
            retainedExternalBytes: retainedForDecode)
        try checkDeadline()
        if let activeSession, let candidate {
            await activeSession.commitPreparedCache(candidate, requiresSync: candidateIncomplete)
        }
        return decoded.includingAdditionalWorkspacePeak(budget.workspace.peak)
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
