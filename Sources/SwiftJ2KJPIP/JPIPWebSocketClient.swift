// SPDX-License-Identifier: Apache-2.0
//
// JPIPWebSocketClient.swift
// SwiftJ2KJPIP
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/JPIP/JPIPWebSocketClient.swift
//
/// # JPIPWebSocketClient
///
/// RFC 6455 WebSocket-based JPIP client implementation.
///
/// Provides session management over a real persistent WebSocket TCP connection
/// with multiplexed request/response correlation, normative ITU-T T.808 VBAS
/// data-bin caching and codestream reassembly, server-push data-bin ingestion,
/// and optional fallback to HTTP/1.1 JPIP transport on WebSocket failure.

import Foundation
@_exported import SwiftJ2K
@_exported import SwiftJ2K3D

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - WebSocket Client Configuration

/// Configuration for the WebSocket JPIP client.
public struct JPIPWebSocketClientConfiguration: Sendable {
    /// Whether to enable automatic fallback to HTTP on WebSocket failure.
    public let enableHTTPFallback: Bool

    /// Reconnection configuration.
    public let reconnectionConfig: JPIPWebSocketReconnectionConfig

    /// Keepalive ping interval in seconds.
    public let keepaliveInterval: TimeInterval

    /// Request timeout in seconds.
    public let requestTimeout: TimeInterval

    /// Maximum number of concurrent requests via multiplexing.
    public let maxConcurrentRequests: Int

    /// Whether to accept server push data bins.
    public let acceptServerPush: Bool

    /// Creates a new client configuration.
    public init(
        enableHTTPFallback: Bool = true,
        reconnectionConfig: JPIPWebSocketReconnectionConfig = .default,
        keepaliveInterval: TimeInterval = 30.0,
        requestTimeout: TimeInterval = 30.0,
        maxConcurrentRequests: Int = 16,
        acceptServerPush: Bool = true
    ) {
        self.enableHTTPFallback = enableHTTPFallback
        self.reconnectionConfig = reconnectionConfig
        self.keepaliveInterval = keepaliveInterval
        self.requestTimeout = requestTimeout
        self.maxConcurrentRequests = maxConcurrentRequests
        self.acceptServerPush = acceptServerPush
    }
}

// MARK: - WebSocket Client

/// A JPIP client that communicates over RFC 6455 WebSocket transport (with optional HTTP/1.1 fallback).
public actor JPIPWebSocketClient {
    /// The server URL (`ws://` or `wss://`).
    nonisolated public let serverURL: URL

    /// Client configuration.
    nonisolated public let configuration: JPIPWebSocketClientConfiguration

    /// WebSocket transport layer.
    private let webSocketTransport: JPIPWebSocketTransport

    /// HTTP fallback transport (lazy-initialised on failure).
    private var httpTransport: JPIPTransport?

    /// Whether currently using HTTP fallback.
    public private(set) var isUsingHTTPFallback: Bool

    /// Active session.
    private var session: JPIPSession?

    /// Number of in-flight requests.
    private var inFlightRequests: Int

    /// Data-bin reassembler for codestream/image reconstruction.
    private let dataBinGenerator = JPIPDataBinGenerator()

    /// Client statistics.
    public private(set) var statistics: Statistics

    /// Client statistics.
    public struct Statistics: Sendable {
        public var webSocketRequests: Int = 0
        public var httpFallbackRequests: Int = 0
        public var pushedDataBins: Int = 0
        public var fallbackActivations: Int = 0
        public var sessionsCreated: Int = 0
    }

    /// Creates a new WebSocket JPIP client.
    public init(
        serverURL: URL,
        configuration: JPIPWebSocketClientConfiguration = .init()
    ) {
        self.serverURL = serverURL
        self.configuration = configuration
        self.webSocketTransport = JPIPWebSocketTransport(
            url: serverURL,
            reconnectionConfig: configuration.reconnectionConfig,
            keepaliveInterval: configuration.keepaliveInterval
        )
        self.httpTransport = nil
        self.isUsingHTTPFallback = false
        self.inFlightRequests = 0
        self.statistics = Statistics()
    }

    /// Connects to the JPIP server via RFC 6455 WebSocket (or activates HTTP fallback when enabled).
    public func connect() async throws {
        do {
            try await webSocketTransport.connect()
            isUsingHTTPFallback = false
        } catch {
            if configuration.enableHTTPFallback {
                try activateHTTPFallback()
            } else {
                throw error
            }
        }
    }

    /// Creates a new JPIP session over WebSocket (or HTTP fallback).
    public func createSession(target: String) async throws -> JPIPSession {
        let sessionID = UUID().uuidString
        let newSession = JPIPSession(sessionID: sessionID)
        await newSession.setTarget(target)

        var request = JPIPRequest(target: target)
        request.cnew = isUsingHTTPFallback ? .http : .webSocket

        let response = try await sendRequest(request)
        guard response.statusCode == 200 else {
            throw J2KError.networkError("JPIP session creation failed with status \(response.statusCode)")
        }

        if let channelID = response.channelID {
            await newSession.setChannelID(channelID)
            await newSession.activate()
        }
        if let tid = JPIPResponseParser.extractTargetID(from: response.headers) {
            await newSession.setTargetID(tid)
        }
        if !response.data.isEmpty,
           let parsed = try? JPIPWireCodec.decodeStream(response.data) {
            for bin in parsed.bins {
                await newSession.recordDataBin(bin)
            }
        }

        self.session = newSession
        statistics.sessionsCreated += 1
        return newSession
    }

    /// Sends a JPIP request, using WebSocket or HTTP fallback.
    public func sendRequest(_ request: JPIPRequest) async throws -> JPIPResponse {
        guard inFlightRequests < configuration.maxConcurrentRequests else {
            throw J2KError.invalidState(
                "Too many concurrent requests (\(configuration.maxConcurrentRequests) max)"
            )
        }

        inFlightRequests += 1
        defer { inFlightRequests -= 1 }

        if !isUsingHTTPFallback {
            do {
                let response = try await webSocketTransport.sendRequest(request)
                statistics.webSocketRequests += 1
                return response
            } catch {
                if configuration.enableHTTPFallback {
                    try activateHTTPFallback()
                    return try await sendViaHTTP(request)
                }
                throw error
            }
        } else {
            return try await sendViaHTTP(request)
        }
    }

    /// Sends a JPIP stream request, decodes its normative VBAS stream, and merges all received
    /// (and server-pushed) data bins into the active session cache.
    public func sendStreamRequest(
        _ request: JPIPRequest
    ) async throws -> (response: JPIPResponse, stream: JPIPParsedStream) {
        var effective = request
        if effective.cid == nil, effective.cnew == nil, effective.model == nil,
           let currentSession = session,
           let cid = await currentSession.channelID {
            effective.cid = cid
        }

        let response = try await sendRequest(effective)
        guard response.statusCode == 200 else {
            throw J2KError.networkError("JPIP WebSocket request failed with HTTP \(response.statusCode)")
        }

        let parsed = try JPIPWireCodec.decodeStream(response.data)
        if session == nil {
            let implicit = JPIPSession(sessionID: UUID().uuidString)
            if !effective.target.isEmpty {
                await implicit.setTarget(effective.target)
            }
            if let cid = response.channelID {
                await implicit.setChannelID(cid)
                await implicit.activate()
            }
            session = implicit
        }

        if let currentSession = session {
            if let cid = response.channelID {
                await currentSession.setChannelID(cid)
                await currentSession.activate()
            }
            if let tid = JPIPResponseParser.extractTargetID(from: response.headers) {
                await currentSession.setTargetID(tid)
            }
            for bin in parsed.bins {
                await currentSession.recordDataBin(bin)
            }
            if configuration.acceptServerPush {
                let pushed = await drainPushedDataBins()
                for bin in pushed {
                    await currentSession.recordDataBin(bin)
                }
            }
        }

        return (response, parsed)
    }

    /// Reconstructs the cached codestream or JP2/JP3D stream from accumulated session data bins.
    public func reconstructCachedCodestream() async throws -> Data {
        if configuration.acceptServerPush, let currentSession = session {
            let pushed = await drainPushedDataBins()
            for bin in pushed {
                await currentSession.recordDataBin(bin)
            }
        }
        guard let currentSession = session else {
            throw J2KError.invalidState("No active JPIP WebSocket session cache")
        }
        let bins = await currentSession.cachedDataBins()
        return dataBinGenerator.reassembleCodestream(from: bins)
    }

    /// Requests and decodes a full 2D image over WebSocket (automatically resuming `EOR=0x04` byte-limited responses).
    public func requestImage(
        imageID: String,
        streamType: JPIPStreamType = .jppStream
    ) async throws -> J2KImage {
        if session == nil {
            _ = try await createSession(target: imageID)
        } else if let current = session, await current.target != imageID {
            _ = try await createSession(target: imageID)
        }

        var rounds = 0
        while rounds < 256 {
            rounds += 1
            var req = JPIPRequest(target: "")
            req.cid = await session?.channelID
            if req.cid == nil {
                req = JPIPRequest(target: imageID)
            }
            req.streamType = streamType
            let (_, stream) = try await sendStreamRequest(req)
            if stream.eor?.reason != .byteLimitReached || stream.bins.isEmpty {
                break
            }
        }

        let codestream = try await reconstructCachedCodestream()
        return try await J2KDecoder().decode(codestream)
    }

    private func sendViaHTTP(_ request: JPIPRequest) async throws -> JPIPResponse {
        guard let transport = httpTransport else {
            throw J2KError.networkError("HTTP fallback transport not initialized")
        }
        let response = try await transport.send(request)
        statistics.httpFallbackRequests += 1
        return response
    }

    private func activateHTTPFallback() throws {
        guard configuration.enableHTTPFallback else {
            throw J2KError.networkError("HTTP fallback is disabled")
        }

        let httpURLString = serverURL.absoluteString
            .replacingOccurrences(of: "wss://", with: "https://")
            .replacingOccurrences(of: "ws://", with: "http://")

        guard let httpURL = URL(string: httpURLString) else {
            throw J2KError.invalidParameter(
                "Cannot convert WebSocket URL to HTTP URL"
            )
        }

        httpTransport = JPIPTransport(baseURL: httpURL)
        isUsingHTTPFallback = true
        statistics.fallbackActivations += 1
    }

    /// Retrieves data bins pushed by the server.
    public func drainPushedDataBins() async -> [JPIPDataBin] {
        guard !isUsingHTTPFallback else { return [] }
        let bins = await webSocketTransport.drainReceivedDataBins()
        statistics.pushedDataBins += bins.count
        return bins
    }

    /// Sends a keepalive ping.
    public func sendPing() async throws {
        guard !isUsingHTTPFallback else { return }
        try await webSocketTransport.sendPing()
    }

    /// Gets the measured WebSocket latency.
    public func getLatency() async -> TimeInterval? {
        await webSocketTransport.measuredLatency
    }

    /// Gets the current connection state.
    public func getConnectionState() async -> JPIPWebSocketConnectionState {
        if isUsingHTTPFallback {
            return .connected
        }
        return await webSocketTransport.connectionState
    }

    /// Gets the current session.
    public func getSession() -> JPIPSession? {
        session
    }

    /// Gets the number of in-flight requests.
    public func getInFlightRequestCount() -> Int {
        inFlightRequests
    }

    /// Sends `cclose` if a channel is active, disconnects from the server, and cleans up resources.
    public func close() async throws {
        if let currentSession = session {
            if let cid = await currentSession.channelID {
                var closeReq = JPIPRequest(target: "")
                closeReq.cid = cid
                closeReq.cclose = [cid]
                _ = try? await sendRequest(closeReq)
            }
            try await currentSession.close()
            session = nil
        }

        await webSocketTransport.disconnect()

        if let transport = httpTransport {
            await transport.close()
            httpTransport = nil
        }

        isUsingHTTPFallback = false
    }
}
