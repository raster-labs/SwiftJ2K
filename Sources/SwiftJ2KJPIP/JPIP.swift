// SPDX-License-Identifier: Apache-2.0
//
// JPIP.swift
// SwiftJ2KJPIP
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/JPIP/JPIP.swift
//
//
// JPIP.swift
// J2KSwift
//
/// # JPIP
///
/// JPEG 2000 Interactive Protocol (JPIP) implementation.
///
/// This module provides support for the JPIP protocol, enabling efficient streaming
/// and progressive transmission of JPEG 2000 images over networks.
///
/// ## Overview
///
/// JPIP (ISO/IEC 15444-9) enables interactive access to JPEG 2000 images over HTTP.
/// Clients can request specific regions, resolutions, or quality layers without
/// downloading entire images.
///
/// ## Topics
///
/// ### Client
/// - ``JPIPClient``
///
/// ### Server
/// - ``JPIPServer``
///
/// ### Session Management
/// - ``JPIPSession``
///
/// ### Requests and Responses
/// - ``JPIPRequest``
/// - ``JPIPResponse``
///
/// ### Transport
/// - ``JPIPTransport``

import Foundation
@_exported import SwiftJ2K
@_exported import SwiftJ2K3D

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A JPIP client for requesting and receiving JPEG 2000 data.
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
    ///   - codingPreference: Optional coding preference (`none`, `htj2k`, or `standard`).
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

    /// Creates a new JPIP client bound directly to an in-process ``JPIPServer``.
    ///
    /// - Parameters:
    ///   - server: The in-process JPIP server.
    ///   - serverURL: Optional URL override.
    ///   - codingPreference: Optional coding preference (`none`, `htj2k`, or `standard`).
    public init(
        server: JPIPServer,
        serverURL: URL? = nil,
        codingPreference: JPIPCodingPreference = .none
    ) {
        self.serverURL = serverURL ?? URL(string: "http://localhost:\(server.port)")!
        self.codingPreference = codingPreference
        self.deliveryMode = .incremental
        self.maxCachedDataBins = 10_000
        self.maxCacheSizeBytes = 100 * 1024 * 1024
        self.transport = JPIPTransport(server: server)
    }

    /// Creates a new JPIP client bound directly to an in-process ``JPIPServer`` with explicit session configuration.
    package init(
        server: JPIPServer,
        serverURL: URL? = nil,
        configuration: JPIPSessionConfiguration
    ) {
        self.serverURL = serverURL ?? URL(string: "http://localhost:\(server.port)")!
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

    /// Creates a new session for an image.
    ///
    /// - Parameter target: The target image identifier.
    /// - Returns: A JPIP session.
    /// - Throws: ``J2KError`` if session creation fails.
    public func createSession(target: String) async throws -> JPIPSession {
        // Create a new session ID
        let sessionID = UUID().uuidString
        let newSession = JPIPSession(
            sessionID: sessionID,
            maxCacheSizeBytes: maxCacheSizeBytes,
            maxCachedDataBins: maxCachedDataBins
        )
        await newSession.setTarget(target)

        // Make initial request to establish channel
        var request = JPIPRequest(target: target)
        request.cnew = .http
        if codingPreference != .none {
            request.codingPreference = codingPreference
        }

        let response = try await transport.send(request)

        // Extract and set channel ID
        if let channelID = response.channelID {
            await newSession.setChannelID(channelID)
            await newSession.activate()
        }

        self.session = newSession
        return newSession
    }

    /// Requests an image from the server.
    ///
    /// - Parameter imageID: The identifier of the image to request.
    /// - Returns: The requested image.
    /// - Throws: ``J2KError`` if the request fails.
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
        return try await decodeImageResponse(response, session: currentSession)
    }

    /// Requests a specific region of interest from an image.
    ///
    /// - Parameters:
    ///   - imageID: The identifier of the image.
    ///   - region: The region to request (x, y, width, height).
    ///   - layers: Optional maximum quality layers.
    /// - Returns: The requested image region.
    /// - Throws: ``J2KError`` if the request fails.
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
    ///
    /// - Parameters:
    ///   - imageID: The identifier of the image.
    ///   - upToLayers: The maximum number of quality layers to request.
    /// - Returns: The image with progressive quality.
    /// - Throws: ``J2KError`` if the request fails.
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
            session: currentSession,
            maxQualityLayers: upToLayers
        )
    }

    /// Requests a specific resolution level of an image.
    ///
    /// - Parameters:
    ///   - imageID: The identifier of the image.
    ///   - level: The resolution level (0 = full resolution, higher values = lower resolution).
    ///   - layers: Optional number of quality layers.
    /// - Returns: The image at the specified resolution level.
    /// - Throws: ``J2KError`` if the request fails.
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
            session: currentSession,
            maxQualityLayers: layers,
            resolutionLevel: level
        )
    }

    /// Requests specific components of an image.
    ///
    /// - Parameters:
    ///   - imageID: The identifier of the image.
    ///   - components: Array of component indices to request (e.g., [0, 1] for R and G channels).
    ///   - layers: Optional number of quality layers.
    /// - Returns: The image with only the specified components.
    /// - Throws: ``J2KError`` if the request fails.
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
            session: currentSession,
            maxQualityLayers: layers,
            components: components
        )
    }

    /// Requests metadata for an image without transferring image data.
    ///
    /// - Parameter imageID: The identifier of the image.
    /// - Returns: A dictionary containing the image metadata.
    /// - Throws: ``J2KError`` if the request fails.
    public func requestMetadata(imageID: String) async throws -> sending [String: Any] {
        let currentSession = try await getOrCreateSession(target: imageID)

        var request = JPIPRequest.metadataRequest(target: imageID)

        if let channelID = await currentSession.channelID {
            request.cid = channelID
        }

        let response = try await transport.send(request)

        var metadata: [String: Any] = [:]
        metadata["channelID"] = response.channelID ?? "none"
        metadata["statusCode"] = response.statusCode
        metadata["dataSize"] = response.data.count

        if !response.data.isEmpty {
            if let jsonObject = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] {
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

    /// Requests and decodes a JPIP image with pre-allocation resource admission, deadline enforcement, and codestream fidelity inspection.
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
            if let level = window.resolutionLevel {
                request.reslevels = level
            }
            if let layers = window.maxQualityLayers {
                request.layers = layers
            }
        }

        if codingPreference != .none {
            request.codingPreference = codingPreference
        }
        if let currentSession = activeSession, let channelID = await currentSession.channelID {
            request.cid = channelID
        }

        let response = try await transport.send(request)
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

        func cacheStorageBytes(_ statistics: JPIPCacheModel.Statistics) throws -> Int {
            let (descriptors, overflow) = statistics.entryCount.multipliedReportingOverflow(by: MemoryLayout<JPIPCacheModel.CacheEntry>.stride)
            let (total, sumOverflow) = statistics.totalSize.addingReportingOverflow(descriptors)
            guard !overflow, !sumOverflow else {
                throw CodecError(.resourceLimitExceeded, "JPIP retained cache storage overflows Int.")
            }
            return total
        }
        var generationWorkspacePeak = 0
        if let currentSession = activeSession, maxCachedDataBins > 0, maxCacheSizeBytes > 0 {
            let cacheStatistics = await currentSession.getCacheStatistics()
            let generated = try JPIPDataBinGenerator().generateDataBins(
                from: response.data, limits: limits,
                retainedBytes: cacheStorageBytes(cacheStatistics),
                maximumAdditionalCacheEntries: max(0, maxCachedDataBins - cacheStatistics.entryCount))
            generationWorkspacePeak = generated.peakWorkspaceBytes
            for bin in generated.bins {
                try checkDeadline()
                await currentSession.recordDataBin(bin)
            }
        }

        try checkDeadline()
        let retainedCacheBytes: Int
        if let activeSession {
            retainedCacheBytes = try cacheStorageBytes(await activeSession.getCacheStatistics())
        } else {
            retainedCacheBytes = 0
        }
        let decoded = try J2KDecoder.decodeWithInfo(
            response.data,
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
        return decoded.includingAdditionalWorkspacePeak(generationWorkspacePeak)
    }

    /// Records received data bins in the session cache model and decodes the codestream.
    private func decodeImageResponse(
        _ response: JPIPResponse,
        session: JPIPSession,
        maxQualityLayers: Int? = nil,
        resolutionLevel: Int? = nil,
        components: [Int]? = nil,
        region: (x: Int, y: Int, width: Int, height: Int)? = nil
    ) async throws -> J2KImage {
        guard !response.data.isEmpty else {
            throw J2KError.decodingError("JPIP response contains no image data")
        }

        let generator = JPIPDataBinGenerator()
        if let bins = try? generator.generateDataBins(from: response.data) {
            for bin in bins {
                await session.recordDataBin(bin)
            }
        }

        return try J2KDecoder.decodeSync(
            response.data,
            maxQualityLayers: maxQualityLayers,
            resolutionLevel: resolutionLevel,
            components: components,
            region: region
        )
    }

    /// Closes the client and any active sessions.
    public func close() async throws {
        if let currentSession = self.session {
            try await currentSession.close()
        }
        await transport.close()
    }
}

// Server is now implemented in JPIPServer.swift
