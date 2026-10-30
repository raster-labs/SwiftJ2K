// SPDX-License-Identifier: Apache-2.0
//
// JPIPWebSocketServer.swift
// SwiftJ2KJPIP
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/JPIP/JPIPWebSocketServer.swift
//
/// # JPIPWebSocketServer
///
/// RFC 6455 WebSocket server implementation for the JPIP protocol over real POSIX TCP sockets.
///
/// Provides HTTP/1.1 `101 Switching Protocols` upgrade handling (`Sec-WebSocket-Protocol: jpip`),
/// concurrent session management, normative VBAS data-bin responses, live server-initiated
/// data-bin push over upgraded TCP sockets, and connection health monitoring.

import Foundation
@_exported import SwiftJ2K
@_exported import SwiftJ2K3D

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - WebSocket Connection

/// Represents an individual WebSocket connection to a client.
public actor JPIPWebSocketConnection {
    /// Unique connection identifier.
    nonisolated public let connectionID: String

    /// The session bound to this connection, if any.
    public private(set) var sessionID: String?

    /// Current connection state.
    public private(set) var state: JPIPWebSocketConnectionState

    /// Last activity timestamp for health monitoring.
    public private(set) var lastActivity: Date

    /// Last keepalive pong received timestamp.
    public private(set) var lastPongReceived: Date?

    /// Measured round-trip latency in seconds.
    public private(set) var latency: TimeInterval?

    /// Total frames sent on this connection.
    public private(set) var framesSent: Int

    /// Total frames received on this connection.
    public private(set) var framesReceived: Int

    /// Total bytes sent on this connection.
    public private(set) var bytesSent: Int

    /// Total bytes received on this connection.
    public private(set) var bytesReceived: Int

    /// Pending ping timestamp for latency measurement.
    private var pendingPingTime: Date?

    /// Creates a new WebSocket connection.
    public init(connectionID: String) {
        self.connectionID = connectionID
        self.state = .connected
        self.lastActivity = Date()
        self.framesSent = 0
        self.framesReceived = 0
        self.bytesSent = 0
        self.bytesReceived = 0
    }

    /// Binds a session to this connection.
    public func bindSession(_ sessionID: String) {
        self.sessionID = sessionID
        updateActivity()
    }

    /// Updates the last activity timestamp.
    public func updateActivity() {
        lastActivity = Date()
    }

    /// Records that a frame was sent.
    public func recordFrameSent(size: Int) {
        framesSent += 1
        bytesSent += size
        updateActivity()
    }

    /// Records that a frame was received.
    public func recordFrameReceived(size: Int) {
        framesReceived += 1
        bytesReceived += size
        updateActivity()
    }

    /// Records a ping being sent for latency measurement.
    public func recordPingSent() {
        pendingPingTime = Date()
    }

    /// Records a pong being received and calculates latency.
    public func recordPongReceived() {
        lastPongReceived = Date()
        if let pingTime = pendingPingTime {
            latency = Date().timeIntervalSince(pingTime)
            pendingPingTime = nil
        }
    }

    /// Checks if the connection is healthy based on timeout.
    public func isHealthy(timeout: TimeInterval) -> Bool {
        guard state == .connected else { return false }
        return Date().timeIntervalSince(lastActivity) < timeout
    }

    /// Closes the connection.
    public func close() {
        state = .disconnected
        sessionID = nil
    }

    /// Gets connection info for monitoring.
    public func getInfo() -> ConnectionInfo {
        ConnectionInfo(
            connectionID: connectionID,
            sessionID: sessionID,
            state: state,
            lastActivity: lastActivity,
            latency: latency,
            framesSent: framesSent,
            framesReceived: framesReceived,
            bytesSent: bytesSent,
            bytesReceived: bytesReceived
        )
    }

    /// Connection information for monitoring.
    public struct ConnectionInfo: Sendable {
        public let connectionID: String
        public let sessionID: String?
        public let state: JPIPWebSocketConnectionState
        public let lastActivity: Date
        public let latency: TimeInterval?
        public let framesSent: Int
        public let framesReceived: Int
        public let bytesSent: Int
        public let bytesReceived: Int
    }
}

// MARK: - WebSocket Server Configuration

/// Configuration for the WebSocket JPIP server.
public struct JPIPWebSocketServerConfiguration: Sendable {
    /// Maximum concurrent WebSocket connections.
    public let maxConnections: Int

    /// Connection health check interval in seconds.
    public let healthCheckInterval: TimeInterval

    /// Connection timeout in seconds (no activity).
    public let connectionTimeout: TimeInterval

    /// Keepalive ping interval in seconds.
    public let keepaliveInterval: TimeInterval

    /// Whether to allow HTTP upgrade to WebSocket.
    public let allowUpgrade: Bool

    /// Maximum frame payload size in bytes.
    public let maxFrameSize: Int

    /// Whether to enable server push for data bins.
    public let enableServerPush: Bool

    /// Creates a new server configuration.
    public init(
        maxConnections: Int = 100,
        healthCheckInterval: TimeInterval = 30.0,
        connectionTimeout: TimeInterval = 300.0,
        keepaliveInterval: TimeInterval = 30.0,
        allowUpgrade: Bool = true,
        maxFrameSize: Int = 16 * 1024 * 1024,
        enableServerPush: Bool = true
    ) {
        self.maxConnections = maxConnections
        self.healthCheckInterval = healthCheckInterval
        self.connectionTimeout = connectionTimeout
        self.keepaliveInterval = keepaliveInterval
        self.allowUpgrade = allowUpgrade
        self.maxFrameSize = maxFrameSize
        self.enableServerPush = enableServerPush
    }
}

// MARK: - WebSocket Server

/// A JPIP server supporting both RFC 6455 WebSocket transport and HTTP/1.1 fallback on a real TCP port.
public actor JPIPWebSocketServer {
    /// The configured port (`0` requests an ephemeral OS-assigned port).
    nonisolated public let port: Int

    /// The actual bound TCP port once `start()` completes.
    public var listeningPort: Int {
        get async { await jpipServer.listeningPort }
    }

    /// Server configuration.
    nonisolated public let configuration: JPIPWebSocketServerConfiguration

    /// Active WebSocket connections.
    private var connections: [String: JPIPWebSocketConnection]

    /// Active upgraded TCP sockets keyed by `connectionID`.
    private var liveSockets: [String: JPIPTCPConnection]

    /// Session-to-connection mapping.
    private var sessionConnections: [String: String]

    /// The underlying JPIP server for TCP listening and JPIP request processing.
    private let jpipServer: JPIPServer

    /// Message encoder for frame serialisation.
    private let encoder: JPIPWebSocketMessageEncoder

    /// Whether the server is running.
    private var isRunning: Bool

    /// Server statistics.
    public private(set) var statistics: Statistics

    /// Server statistics.
    public struct Statistics: Sendable {
        public var totalConnections: Int = 0
        public var activeConnections: Int = 0
        public var upgradeRequests: Int = 0
        public var successfulUpgrades: Int = 0
        public var failedUpgrades: Int = 0
        public var framesSent: Int = 0
        public var framesReceived: Int = 0
        public var dataBinsPushed: Int = 0
        public var keepalivePingsSent: Int = 0
        public var timeoutDisconnections: Int = 0
        public var totalBytesSent: Int = 0
        public var totalBytesReceived: Int = 0
    }

    /// Creates a new WebSocket JPIP server.
    public init(
        port: Int = 8080,
        configuration: JPIPWebSocketServerConfiguration = .init(),
        jpipConfiguration: JPIPServer.Configuration = .init()
    ) {
        self.port = port
        self.configuration = configuration
        self.connections = [:]
        self.liveSockets = [:]
        self.sessionConnections = [:]
        self.jpipServer = JPIPServer(
            port: port,
            configuration: jpipConfiguration
        )
        self.encoder = JPIPWebSocketMessageEncoder()
        self.isRunning = false
        self.statistics = Statistics()
    }

    /// Starts the real TCP HTTP/1.1 + RFC 6455 WebSocket listener.
    public func start() async throws {
        guard !isRunning else {
            throw J2KError.invalidState("WebSocket server is already running")
        }

        await jpipServer.setWebSocketDelegate(self)
        do {
            try await jpipServer.start()
            isRunning = true
        } catch {
            await jpipServer.setWebSocketDelegate(nil)
            throw error
        }
    }

    /// Stops the WebSocket server and closes all active sockets and sessions.
    public func stop() async throws {
        guard isRunning else {
            throw J2KError.invalidState("WebSocket server is not running")
        }

        for (_, sock) in liveSockets {
            sock.close()
        }
        liveSockets.removeAll()

        for (_, connection) in connections {
            await connection.close()
        }
        connections.removeAll()
        sessionConnections.removeAll()

        await jpipServer.setWebSocketDelegate(nil)
        try await jpipServer.stop()
        isRunning = false
        statistics.activeConnections = 0
    }

    /// Registers an image or `.jp3d` file for serving.
    public func registerImage(name: String, at url: URL) async throws {
        try await jpipServer.registerImage(name: name, at: url)
    }

    /// Registers an in-memory codestream, JP2/JPH container, or Part 10 `.jp3d` volume for serving.
    public func registerImageData(name: String, data: Data) async {
        await jpipServer.registerImageData(name: name, data: data)
    }

    // MARK: - WebSocket Upgrade Handling

    /// Result of a WebSocket upgrade request.
    public struct UpgradeResult: Sendable {
        /// The connection ID if upgrade succeeded.
        public let connectionID: String?

        /// Error message if upgrade failed.
        public let error: String?

        /// Whether the upgrade succeeded.
        public var isSuccess: Bool { connectionID != nil }
    }

    package func acceptLiveSocketUpgrade(
        headers: [String: String],
        socket: JPIPTCPConnection
    ) async -> UpgradeResult {
        let result = await handleUpgradeRequest(headers: headers)
        if let cid = result.connectionID {
            liveSockets[cid] = socket
        }
        return result
    }

    private static func headerValue(_ name: String, in headers: [String: String]) -> String? {
        if let exact = headers[name] { return exact }
        return headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Validates an HTTP upgrade request to WebSocket and registers the connection.
    public func handleUpgradeRequest(
        headers: [String: String]
    ) async -> UpgradeResult {
        statistics.upgradeRequests += 1

        guard isRunning else {
            statistics.failedUpgrades += 1
            return UpgradeResult(connectionID: nil, error: "Server is not running")
        }

        guard configuration.allowUpgrade else {
            statistics.failedUpgrades += 1
            return UpgradeResult(connectionID: nil, error: "WebSocket upgrade not allowed")
        }

        guard connections.count < configuration.maxConnections else {
            statistics.failedUpgrades += 1
            return UpgradeResult(connectionID: nil, error: "Maximum connections reached")
        }

        guard let upgrade = Self.headerValue("Upgrade", in: headers),
              upgrade.lowercased() == "websocket" else {
            statistics.failedUpgrades += 1
            return UpgradeResult(connectionID: nil, error: "Invalid upgrade header")
        }

        guard let connectionHeader = Self.headerValue("Connection", in: headers),
              connectionHeader.lowercased().contains("upgrade") else {
            statistics.failedUpgrades += 1
            return UpgradeResult(connectionID: nil, error: "Invalid connection header")
        }

        let subprotocol = Self.headerValue("Sec-WebSocket-Protocol", in: headers) ?? ""
        let hasJPIPProtocol = subprotocol.lowercased().contains("jpip")

        let connectionID = UUID().uuidString
        let wsConnection = JPIPWebSocketConnection(connectionID: connectionID)

        connections[connectionID] = wsConnection
        statistics.totalConnections += 1
        statistics.activeConnections = connections.count
        statistics.successfulUpgrades += 1

        if hasJPIPProtocol {
            await wsConnection.updateActivity()
        }

        return UpgradeResult(connectionID: connectionID, error: nil)
    }

    /// Builds WebSocket upgrade response headers.
    public func buildUpgradeResponseHeaders(
        acceptKey: String
    ) -> [String: String] {
        [
            "Upgrade": "websocket",
            "Connection": "Upgrade",
            "Sec-WebSocket-Accept": acceptKey,
            "Sec-WebSocket-Protocol": "jpip"
        ]
    }

    // MARK: - Frame Handling

    /// Handles a received WebSocket frame from a client connection.
    public func handleFrame(
        _ frame: JPIPWebSocketFrame,
        from connectionID: String
    ) async throws -> JPIPWebSocketFrame? {
        guard isRunning else {
            throw J2KError.invalidState("Server is not running")
        }

        guard let connection = connections[connectionID] else {
            throw J2KError.invalidParameter(
                "Unknown connection: \(connectionID)"
            )
        }

        guard frame.payload.count <= configuration.maxFrameSize else {
            return JPIPWebSocketFrame(
                type: .error,
                payload: Data("Frame payload exceeds maxFrameSize (\(configuration.maxFrameSize))".utf8),
                requestID: frame.requestID
            )
        }

        await connection.recordFrameReceived(size: frame.payload.count + 9)
        statistics.framesReceived += 1
        statistics.totalBytesReceived += frame.payload.count + 9

        switch frame.type {
        case .request:
            return try await handleRequestFrame(
                frame, connection: connection
            )
        case .ping:
            let pong = handlePingFrame(frame)
            let serialized = pong.serialize()
            await connection.recordFrameSent(size: serialized.count)
            statistics.framesSent += 1
            statistics.totalBytesSent += serialized.count
            return pong
        case .pong:
            await connection.recordPongReceived()
            return nil
        case .control:
            return try await handleControlFrame(
                frame, connection: connection
            )
        default:
            return nil
        }
    }

    private func handleRequestFrame(
        _ frame: JPIPWebSocketFrame,
        connection: JPIPWebSocketConnection
    ) async throws -> JPIPWebSocketFrame {
        guard let request = encoder.decodeRequest(from: frame) else {
            let errorPayload = Data("Invalid request format".utf8)
            return JPIPWebSocketFrame(
                type: .error,
                payload: errorPayload,
                requestID: frame.requestID
            )
        }

        let rawResponse = try await jpipServer.handleRequest(request)
        var wsHeaders = rawResponse.headers
        wsHeaders["X-JPIP-Transport"] = "websocket"
        let response = JPIPResponse(
            channelID: rawResponse.channelID,
            data: rawResponse.data,
            statusCode: rawResponse.statusCode,
            headers: wsHeaders
        )

        if request.cnew != nil, let channelID = response.channelID {
            await connection.bindSession(channelID)
            sessionConnections[channelID] = connection.connectionID
        }

        let responseFrame = encoder.encodeResponse(
            response,
            requestID: frame.requestID ?? 0
        )

        let serialized = responseFrame.serialize()
        await connection.recordFrameSent(size: serialized.count)
        statistics.framesSent += 1
        statistics.totalBytesSent += serialized.count

        return responseFrame
    }

    private func handlePingFrame(
        _ frame: JPIPWebSocketFrame
    ) -> JPIPWebSocketFrame {
        JPIPWebSocketFrame(
            type: .pong,
            payload: frame.payload,
            requestID: frame.requestID
        )
    }

    private func handleControlFrame(
        _ frame: JPIPWebSocketFrame,
        connection: JPIPWebSocketConnection
    ) async throws -> JPIPWebSocketFrame? {
        guard let command = String(data: frame.payload, encoding: .utf8) else {
            return nil
        }

        if command.hasPrefix("close-session:") {
            let sessionID = String(command.dropFirst("close-session:".count))
            await jpipServer.closeSession(sessionID)
            sessionConnections.removeValue(forKey: sessionID)
            return JPIPWebSocketFrame(
                type: .control,
                payload: Data("session-closed:\(sessionID)".utf8),
                requestID: frame.requestID
            )
        }

        return nil
    }

    // MARK: - Server Push

    /// Pushes a data bin to a specific connection (delivering an unmasked RFC 6455 binary frame
    /// over the upgraded TCP socket when live).
    public func pushDataBin(
        _ dataBin: JPIPDataBin,
        to connectionID: String
    ) async -> Data? {
        guard configuration.enableServerPush else { return nil }
        guard let connection = connections[connectionID] else { return nil }

        let frame = encoder.encodeDataBin(dataBin)
        let serialized = frame.serialize()

        if let sock = liveSockets[connectionID], sock.isOpen {
            try? sock.writeWebSocketFrame(
                opcode: .binary,
                payload: serialized,
                masked: false
            )
        }

        await connection.recordFrameSent(size: serialized.count)
        statistics.framesSent += 1
        statistics.dataBinsPushed += 1
        statistics.totalBytesSent += serialized.count

        return serialized
    }

    /// Pushes a data bin to the connection bound to `sessionID`.
    public func pushDataBinToSession(
        _ dataBin: JPIPDataBin,
        sessionID: String
    ) async -> Int {
        guard configuration.enableServerPush else { return 0 }
        guard let connectionID = sessionConnections[sessionID] else { return 0 }

        if await pushDataBin(dataBin, to: connectionID) != nil {
            return 1
        }
        return 0
    }

    // MARK: - Connection Health

    /// Sends keepalive pings to all active connections.
    public func sendKeepalivePings() async -> [(String, Data)] {
        var pings: [(String, Data)] = []

        let pingFrame = JPIPWebSocketFrame(
            type: .ping,
            payload: Data("keepalive".utf8)
        )
        let serialized = pingFrame.serialize()

        for (connectionID, connection) in connections {
            guard await connection.state == .connected else { continue }
            if let sock = liveSockets[connectionID], sock.isOpen {
                try? sock.writeWebSocketFrame(
                    opcode: .binary,
                    payload: serialized,
                    masked: false
                )
            }
            await connection.recordPingSent()
            await connection.recordFrameSent(size: serialized.count)
            pings.append((connectionID, serialized))
            statistics.keepalivePingsSent += 1
        }

        return pings
    }

    /// Closes connections that have exceeded `configuration.connectionTimeout`.
    public func performHealthCheck() async -> [String] {
        var closedIDs: [String] = []

        for (connectionID, connection) in connections {
            let healthy = await connection.isHealthy(
                timeout: configuration.connectionTimeout
            )
            if !healthy {
                liveSockets.removeValue(forKey: connectionID)?.close()
                let sessionID = await connection.sessionID
                await connection.close()
                connections.removeValue(forKey: connectionID)

                if let sessionID = sessionID {
                    sessionConnections.removeValue(forKey: sessionID)
                    await jpipServer.closeSession(sessionID)
                }

                closedIDs.append(connectionID)
                statistics.timeoutDisconnections += 1
            }
        }

        statistics.activeConnections = connections.count
        return closedIDs
    }

    /// Closes a specific WebSocket connection.
    public func closeConnection(_ connectionID: String) async {
        liveSockets.removeValue(forKey: connectionID)?.close()
        guard let connection = connections.removeValue(forKey: connectionID) else {
            return
        }

        if let sessionID = await connection.sessionID {
            sessionConnections.removeValue(forKey: sessionID)
            await jpipServer.closeSession(sessionID)
        }

        await connection.close()
        statistics.activeConnections = connections.count
    }

    // MARK: - Monitoring

    public func getActiveConnectionCount() -> Int {
        connections.count
    }

    public func getConnectionInfos() async -> [JPIPWebSocketConnection.ConnectionInfo] {
        var infos: [JPIPWebSocketConnection.ConnectionInfo] = []
        for (_, connection) in connections {
            infos.append(await connection.getInfo())
        }
        return infos
    }

    public func getJPIPStatistics() async -> JPIPServer.Statistics {
        await jpipServer.getStatistics()
    }

    public func listRegisteredImages() async -> [String] {
        await jpipServer.listRegisteredImages()
    }
}
