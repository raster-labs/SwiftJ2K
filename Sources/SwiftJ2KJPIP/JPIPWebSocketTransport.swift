// SPDX-License-Identifier: Apache-2.0
//
// JPIPWebSocketTransport.swift
// SwiftJ2KJPIP
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/JPIP/JPIPWebSocketTransport.swift
//
/// # JPIPWebSocketTransport
///
/// RFC 6455 WebSocket transport layer for the JPIP protocol over real POSIX TCP sockets.
///
/// Provides WebSocket frame encapsulation, binary/text message support,
/// RFC 6455 HTTP/1.1 `101 Switching Protocols` handshake (`Sec-WebSocket-Protocol: jpip`),
/// full-duplex multiplexed request/response correlation, server-push data-bin reception,
/// and automatic reconnection with exponential backoff.

import Foundation
import Dispatch
@_exported import SwiftJ2K
@_exported import SwiftJ2K3D

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - WebSocket Frame Types

/// Represents an application-level JPIP frame carried inside an RFC 6455 WebSocket binary message.
public struct JPIPWebSocketFrame: Sendable {
    /// The type of WebSocket frame.
    public let type: FrameType

    /// The frame payload data.
    public let payload: Data

    /// Optional request ID for multiplexed request/response correlation.
    public let requestID: UInt32?

    /// Frame timestamp for latency measurement.
    public let timestamp: Date

    /// Types of WebSocket frames used in JPIP transport.
    public enum FrameType: UInt8, Sendable {
        /// JPIP request message.
        case request = 0x01

        /// JPIP response message.
        case response = 0x02

        /// Data bin delivery (binary).
        case dataBin = 0x03

        /// Keepalive ping.
        case ping = 0x04

        /// Keepalive pong.
        case pong = 0x05

        /// Session control (create, close, etc.).
        case control = 0x06

        /// Error message.
        case error = 0x07

        /// Server push notification.
        case push = 0x08
    }

    /// Creates a new WebSocket frame.
    public init(
        type: FrameType,
        payload: Data,
        requestID: UInt32? = nil,
        timestamp: Date = Date()
    ) {
        self.type = type
        self.payload = payload
        self.requestID = requestID
        self.timestamp = timestamp
    }

    /// Serializes the frame to binary data for WebSocket transmission.
    ///
    /// Frame format:
    /// - Byte 0: Frame type (`UInt8`)
    /// - Bytes 1-4: Request ID (`UInt32`, big-endian, 0 if none)
    /// - Bytes 5-8: Payload length (`UInt32`, big-endian)
    /// - Bytes 9+: Payload data
    public func serialize() -> Data {
        var data = Data(capacity: 9 + payload.count)
        data.append(type.rawValue)

        let reqID = requestID ?? 0
        data.append(UInt8((reqID >> 24) & 0xFF))
        data.append(UInt8((reqID >> 16) & 0xFF))
        data.append(UInt8((reqID >> 8) & 0xFF))
        data.append(UInt8(reqID & 0xFF))

        let length = UInt32(clamping: payload.count)
        data.append(UInt8((length >> 24) & 0xFF))
        data.append(UInt8((length >> 16) & 0xFF))
        data.append(UInt8((length >> 8) & 0xFF))
        data.append(UInt8(length & 0xFF))

        data.append(payload)
        return data
    }

    /// Deserializes a frame from binary data.
    public static func deserialize(from data: Data) -> JPIPWebSocketFrame? {
        guard data.count >= 9 else { return nil }
        let base = data.startIndex

        guard let frameType = FrameType(rawValue: data[base]) else {
            return nil
        }

        let reqID = (UInt32(data[base + 1]) << 24)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 8)
            | UInt32(data[base + 4])

        let length = (UInt32(data[base + 5]) << 24)
            | (UInt32(data[base + 6]) << 16)
            | (UInt32(data[base + 7]) << 8)
            | UInt32(data[base + 8])

        let (endOffset, overflow) = Int(9).addingReportingOverflow(Int(length))
        guard !overflow, data.count >= endOffset else { return nil }

        let payload = Data(data[(base + 9)..<(base + endOffset)])

        return JPIPWebSocketFrame(
            type: frameType,
            payload: payload,
            requestID: reqID == 0 ? nil : reqID
        )
    }
}

// MARK: - WebSocket Message Encoding

/// Encodes and decodes JPIP messages for WebSocket transport.
public struct JPIPWebSocketMessageEncoder: Sendable {
    /// Creates a new message encoder.
    public init() {}

    /// Encodes a JPIP request as a WebSocket frame.
    public func encodeRequest(
        _ request: JPIPRequest,
        requestID: UInt32
    ) -> JPIPWebSocketFrame {
        let queryItems = request.buildQueryItems()
        let orderedKeys = queryItems.keys.sorted()
        let queryString = orderedKeys.compactMap { key -> String? in
            guard let val = queryItems[key] else { return nil }
            return "\(key)=\(val)"
        }.joined(separator: "&")
        let payload = Data(queryString.utf8)

        return JPIPWebSocketFrame(
            type: .request,
            payload: payload,
            requestID: requestID
        )
    }

    /// Decodes a JPIP request from a WebSocket frame.
    public func decodeRequest(from frame: JPIPWebSocketFrame) -> JPIPRequest? {
        guard frame.type == .request else { return nil }
        guard let queryString = String(data: frame.payload, encoding: .utf8),
              !queryString.isEmpty else {
            return nil
        }

        let parsed = JPIPRequest.parseHTTPTarget("/jpip?\(queryString)")
        guard !parsed.target.isEmpty
                || parsed.cid != nil
                || parsed.tid != nil
                || parsed.cclose != nil else {
            return nil
        }
        return parsed
    }

    /// Encodes a JPIP response as a WebSocket frame.
    public func encodeResponse(
        _ response: JPIPResponse,
        requestID: UInt32
    ) -> JPIPWebSocketFrame {
        var payload = Data()

        let status = UInt16(clamping: max(0, response.statusCode))
        payload.append(UInt8((status >> 8) & 0xFF))
        payload.append(UInt8(status & 0xFF))

        let headerString = response.headers
            .sorted { $0.key < $1.key }
            .map { "\($0.key):\($0.value)" }
            .joined(separator: "\n")
        let headerData = Data(headerString.utf8)
        let headerLen = UInt16(clamping: headerData.count)
        payload.append(UInt8((headerLen >> 8) & 0xFF))
        payload.append(UInt8(headerLen & 0xFF))
        payload.append(headerData.prefix(Int(headerLen)))

        payload.append(response.data)

        return JPIPWebSocketFrame(
            type: .response,
            payload: payload,
            requestID: requestID
        )
    }

    /// Decodes a JPIP response from a WebSocket frame.
    public func decodeResponse(from frame: JPIPWebSocketFrame) -> JPIPResponse? {
        guard frame.type == .response else { return nil }
        let data = frame.payload
        guard data.count >= 4 else { return nil }
        let base = data.startIndex

        let statusCode = (Int(data[base]) << 8) | Int(data[base + 1])
        let headerLen = (Int(data[base + 2]) << 8) | Int(data[base + 3])

        guard data.count >= 4 + headerLen else { return nil }

        let headerData = data[(base + 4)..<(base + 4 + headerLen)]
        let headerString = String(data: headerData, encoding: .utf8) ?? ""
        var headers: [String: String] = [:]
        for line in headerString.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[String(parts[0])] = String(parts[1])
            }
        }

        let responseData = Data(data[(base + 4 + headerLen)..<data.endIndex])
        let channelID = JPIPResponseParser.extractChannelID(from: headers)

        return JPIPResponse(
            channelID: channelID,
            data: responseData,
            statusCode: statusCode,
            headers: headers
        )
    }

    /// Encodes a data bin as a binary WebSocket frame for efficient delivery.
    ///
    /// Preserves `isComplete`, `msgOffset`, `aux`, and `codestreamID` while remaining
    /// byte-compatible with the compact 6-byte header when extended offsets are zero.
    public func encodeDataBin(
        _ dataBin: JPIPDataBin,
        requestID: UInt32? = nil
    ) -> JPIPWebSocketFrame {
        var flags: UInt8 = dataBin.isComplete ? 0x01 : 0x00
        let hasMsgOffset = dataBin.msgOffset > 0
        let hasAux = dataBin.aux != nil
        let hasCodestreamID = dataBin.codestreamID > 0
        if hasMsgOffset { flags |= 0x02 }
        if hasAux { flags |= 0x04 }
        if hasCodestreamID { flags |= 0x08 }

        var payload = Data(capacity: 18 + dataBin.data.count)
        payload.append(UInt8(clamping: dataBin.binClass.rawValue))

        let binID = UInt32(clamping: max(0, dataBin.binID))
        payload.append(UInt8((binID >> 24) & 0xFF))
        payload.append(UInt8((binID >> 16) & 0xFF))
        payload.append(UInt8((binID >> 8) & 0xFF))
        payload.append(UInt8(binID & 0xFF))

        payload.append(flags)

        if hasMsgOffset {
            let off = UInt32(clamping: dataBin.msgOffset)
            payload.append(UInt8((off >> 24) & 0xFF))
            payload.append(UInt8((off >> 16) & 0xFF))
            payload.append(UInt8((off >> 8) & 0xFF))
            payload.append(UInt8(off & 0xFF))
        }
        if let auxVal = dataBin.aux {
            let a = UInt32(clamping: max(0, auxVal))
            payload.append(UInt8((a >> 24) & 0xFF))
            payload.append(UInt8((a >> 16) & 0xFF))
            payload.append(UInt8((a >> 8) & 0xFF))
            payload.append(UInt8(a & 0xFF))
        }
        if hasCodestreamID {
            let cs = UInt32(clamping: dataBin.codestreamID)
            payload.append(UInt8((cs >> 24) & 0xFF))
            payload.append(UInt8((cs >> 16) & 0xFF))
            payload.append(UInt8((cs >> 8) & 0xFF))
            payload.append(UInt8(cs & 0xFF))
        }

        payload.append(dataBin.data)

        return JPIPWebSocketFrame(
            type: .dataBin,
            payload: payload,
            requestID: requestID
        )
    }

    /// Decodes a data bin from a binary WebSocket frame.
    public func decodeDataBin(from frame: JPIPWebSocketFrame) -> JPIPDataBin? {
        guard frame.type == .dataBin else { return nil }
        let data = frame.payload
        guard data.count >= 6 else { return nil }
        let base = data.startIndex

        guard let binClass = JPIPDataBinClass(rawValue: Int(data[base])) else {
            return nil
        }

        let binID = (Int(data[base + 1]) << 24)
            | (Int(data[base + 2]) << 16)
            | (Int(data[base + 3]) << 8)
            | Int(data[base + 4])

        let flags = data[base + 5]
        let isComplete = (flags & 0x01) != 0
        var cursor = base + 6

        var msgOffset = 0
        if (flags & 0x02) != 0 {
            guard cursor + 4 <= data.endIndex else { return nil }
            msgOffset = (Int(data[cursor]) << 24)
                | (Int(data[cursor + 1]) << 16)
                | (Int(data[cursor + 2]) << 8)
                | Int(data[cursor + 3])
            cursor += 4
        }

        var aux: Int?
        if (flags & 0x04) != 0 {
            guard cursor + 4 <= data.endIndex else { return nil }
            aux = (Int(data[cursor]) << 24)
                | (Int(data[cursor + 1]) << 16)
                | (Int(data[cursor + 2]) << 8)
                | Int(data[cursor + 3])
            cursor += 4
        }

        var codestreamID = 0
        if (flags & 0x08) != 0 {
            guard cursor + 4 <= data.endIndex else { return nil }
            codestreamID = (Int(data[cursor]) << 24)
                | (Int(data[cursor + 1]) << 16)
                | (Int(data[cursor + 2]) << 8)
                | Int(data[cursor + 3])
            cursor += 4
        }

        let binData = Data(data[cursor..<data.endIndex])

        return JPIPDataBin(
            binClass: binClass,
            binID: binID,
            data: binData,
            isComplete: isComplete,
            codestreamID: codestreamID,
            msgOffset: msgOffset,
            aux: aux
        )
    }
}

// MARK: - Connection State

/// Represents the state of a WebSocket connection.
public enum JPIPWebSocketConnectionState: String, Sendable {
    /// Not connected.
    case disconnected

    /// Connection is being established.
    case connecting

    /// Connected and ready for communication.
    case connected

    /// Connection is being closed.
    case closing

    /// Connection failed and waiting for reconnection.
    case reconnecting
}

// MARK: - Reconnection Configuration

/// Configuration for automatic reconnection with exponential backoff.
public struct JPIPWebSocketReconnectionConfig: Sendable {
    /// Whether automatic reconnection is enabled.
    public let enabled: Bool

    /// Initial delay before first reconnection attempt (seconds).
    public let initialDelay: TimeInterval

    /// Maximum delay between reconnection attempts (seconds).
    public let maxDelay: TimeInterval

    /// Multiplier for exponential backoff.
    public let backoffMultiplier: Double

    /// Maximum number of reconnection attempts (`nil` = unlimited).
    public let maxAttempts: Int?

    /// Jitter factor (`0.0` to `1.0`) to randomise backoff delays.
    public let jitterFactor: Double

    /// Creates a new reconnection configuration.
    public init(
        enabled: Bool = true,
        initialDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 60.0,
        backoffMultiplier: Double = 2.0,
        maxAttempts: Int? = 10,
        jitterFactor: Double = 0.1
    ) {
        self.enabled = enabled
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.backoffMultiplier = backoffMultiplier
        self.maxAttempts = maxAttempts
        self.jitterFactor = max(0.0, min(1.0, jitterFactor))
    }

    /// Default configuration with exponential backoff.
    public static let `default` = JPIPWebSocketReconnectionConfig()

    /// Configuration with no automatic reconnection.
    public static let disabled = JPIPWebSocketReconnectionConfig(enabled: false)

    /// Calculates the delay for a given attempt number (`0`-based).
    public func delay(forAttempt attempt: Int) -> TimeInterval {
        let baseDelay = initialDelay * pow(backoffMultiplier, Double(attempt))
        let clampedDelay = min(baseDelay, maxDelay)
        let jitter = clampedDelay * jitterFactor * Double.random(in: -1.0...1.0)
        return max(0, clampedDelay + jitter)
    }
}

// MARK: - WebSocket Transport

/// RFC 6455 WebSocket transport layer for JPIP protocol communication over real TCP sockets.
public actor JPIPWebSocketTransport {
    /// The WebSocket URL to connect to (`ws://host:port/path`).
    private let url: URL

    /// Current connection state.
    public private(set) var connectionState: JPIPWebSocketConnectionState

    /// Reconnection configuration.
    private let reconnectionConfig: JPIPWebSocketReconnectionConfig

    /// Message encoder/decoder.
    private let encoder: JPIPWebSocketMessageEncoder

    /// Current reconnection attempt count.
    private var reconnectionAttempts: Int

    /// Next request ID for multiplexing.
    private var nextRequestID: UInt32

    /// Pending responses keyed by request ID (when response arrives ahead of registration).
    private var pendingResponses: [UInt32: JPIPResponse]

    /// Pending response continuations for async/await multiplexed requests.
    private var pendingContinuations: [UInt32: CheckedContinuation<JPIPResponse, any Error>]

    /// Received data bins pushed by the server.
    private var receivedDataBins: [JPIPDataBin]

    /// Keepalive interval in seconds.
    private let keepaliveInterval: TimeInterval

    /// Last ping timestamp for latency measurement.
    private var lastPingTime: Date?

    /// Measured round-trip latency in seconds.
    public private(set) var measuredLatency: TimeInterval?

    /// Active upgraded RFC 6455 TCP socket.
    private var tcpConnection: JPIPTCPConnection?

    /// Monotonic connection generation to isolate reader loops across reconnects.
    private var connectionGeneration: UInt64 = 0

    /// Transport statistics.
    public private(set) var statistics: Statistics

    /// Transport statistics.
    public struct Statistics: Sendable {
        /// Total frames sent.
        public var framesSent: Int = 0

        /// Total frames received.
        public var framesReceived: Int = 0

        /// Total bytes sent.
        public var bytesSent: Int = 0

        /// Total bytes received.
        public var bytesReceived: Int = 0

        /// Total reconnection attempts.
        public var reconnectionAttempts: Int = 0

        /// Total successful reconnections.
        public var successfulReconnections: Int = 0

        /// Total data bins received via push.
        public var dataBinsPushed: Int = 0

        /// Total keepalive pings sent.
        public var keepalivePingsSent: Int = 0
    }

    /// Creates a new WebSocket transport.
    public init(
        url: URL,
        reconnectionConfig: JPIPWebSocketReconnectionConfig = .default,
        keepaliveInterval: TimeInterval = 30.0
    ) {
        self.url = url
        self.connectionState = .disconnected
        self.reconnectionConfig = reconnectionConfig
        self.encoder = JPIPWebSocketMessageEncoder()
        self.reconnectionAttempts = 0
        self.nextRequestID = 1
        self.pendingResponses = [:]
        self.pendingContinuations = [:]
        self.receivedDataBins = []
        self.keepaliveInterval = keepaliveInterval
        self.tcpConnection = nil
        self.statistics = Statistics()
    }

    /// Establishes the real TCP RFC 6455 WebSocket connection (`Sec-WebSocket-Protocol: jpip`).
    public func connect() async throws {
        guard connectionState == .disconnected
                || connectionState == .reconnecting else {
            throw J2KError.invalidState(
                "Cannot connect: already in state \(connectionState.rawValue)"
            )
        }

        let scheme = (url.scheme ?? "ws").lowercased()
        guard scheme == "ws" || scheme == "wss" else {
            throw J2KError.invalidParameter("Unsupported WebSocket URL scheme '\(scheme)'")
        }
        if scheme == "wss" {
            throw J2KError.unsupportedFeature(
                "TLS WebSocket (wss://) requires external TLS termination; use ws:// over TCP."
            )
        }
        guard let host = url.host, !host.isEmpty else {
            throw J2KError.invalidParameter("WebSocket URL missing host: \(url)")
        }
        let port = url.port ?? 80
        let rawPath = url.path.isEmpty ? "/jpip" : url.path
        let pathAndQuery = url.query.map { "\(rawPath)?\($0)" } ?? rawPath
        let hostHeader = url.port != nil ? "\(host):\(port)" : host

        connectionState = .connecting

        let openedConn: JPIPTCPConnection
        do {
            openedConn = try await Self.openAndHandshakeOffPool(
                host: host,
                port: port,
                pathAndQuery: pathAndQuery,
                hostHeader: hostHeader
            )
        } catch {
            connectionState = .disconnected
            throw error
        }

        connectionGeneration &+= 1
        let gen = connectionGeneration
        self.tcpConnection = openedConn
        self.connectionState = .connected
        self.reconnectionAttempts = 0

        let transportRef = self
        let readerQueue = DispatchQueue(
            label: "com.rasterlab.swiftj2k.jpip.wsreader.\(gen)",
            qos: .userInitiated
        )
        readerQueue.async {
            Self.runReaderLoop(connection: openedConn, generation: gen, transport: transportRef)
        }
    }

    nonisolated private static func openAndHandshakeOffPool(
        host: String,
        port: Int,
        pathAndQuery: String,
        hostHeader: String
    ) async throws -> JPIPTCPConnection {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let conn = try JPIPTCPConnection.connect(host: host, port: port, timeoutSeconds: 10)
                    do {
                        _ = try conn.performWebSocketClientHandshake(
                            pathAndQuery: pathAndQuery,
                            hostHeader: hostHeader,
                            subprotocol: "jpip"
                        )
                        conn.setReceiveTimeout(seconds: 0)
                        continuation.resume(returning: conn)
                    } catch {
                        conn.close()
                        continuation.resume(throwing: error)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    nonisolated private static func runReaderLoop(
        connection: JPIPTCPConnection,
        generation: UInt64,
        transport: JPIPWebSocketTransport
    ) {
        while connection.isOpen {
            let wireFrame: JPIPRFC6455WireFrame
            do {
                wireFrame = try connection.readWebSocketFrame(requireMasked: false)
            } catch {
                break
            }

            switch wireFrame.opcode {
            case .close:
                connection.close()
            case .ping:
                try? connection.writeWebSocketFrame(
                    opcode: .pong,
                    payload: wireFrame.payload,
                    masked: true
                )
            case .pong:
                let appPong = JPIPWebSocketFrame.deserialize(from: wireFrame.payload)
                    ?? JPIPWebSocketFrame(type: .pong, payload: wireFrame.payload)
                let sema = DispatchSemaphore(value: 0)
                Task {
                    await transport.handlePong(appPong)
                    sema.signal()
                }
                sema.wait()
            case .binary, .text:
                if let appFrame = JPIPWebSocketFrame.deserialize(from: wireFrame.payload) {
                    let sema = DispatchSemaphore(value: 0)
                    Task {
                        await transport.handleReceivedFrame(appFrame)
                        sema.signal()
                    }
                    sema.wait()
                }
            case .continuation:
                break
            }
        }

        let sema = DispatchSemaphore(value: 0)
        Task {
            await transport.handleSocketClosed(generation: generation)
            sema.signal()
        }
        sema.wait()
    }

    private func handleSocketClosed(generation: UInt64) {
        guard generation == connectionGeneration else { return }
        tcpConnection?.close()
        tcpConnection = nil
        if connectionState == .connected || connectionState == .connecting {
            connectionState = .disconnected
        }
        for (_, continuation) in pendingContinuations {
            continuation.resume(
                throwing: J2KError.networkError("WebSocket connection closed by peer")
            )
        }
        pendingContinuations.removeAll()
        pendingResponses.removeAll()
    }

    /// Closes the WebSocket connection cleanly with an RFC 6455 close control frame.
    public func disconnect(code: Int = 1000) async {
        guard connectionState == .connected
                || connectionState == .connecting else {
            return
        }

        connectionState = .closing
        connectionGeneration &+= 1

        if let conn = tcpConnection {
            let codeU16 = UInt16(clamping: max(1000, min(4999, code)))
            let closePayload = Data([UInt8((codeU16 >> 8) & 0xFF), UInt8(codeU16 & 0xFF)])
            try? conn.writeWebSocketFrame(opcode: .close, payload: closePayload, masked: true)
            conn.close()
            tcpConnection = nil
        }

        for (_, continuation) in pendingContinuations {
            continuation.resume(
                throwing: J2KError.networkError("Connection closed")
            )
        }
        pendingContinuations.removeAll()
        pendingResponses.removeAll()

        connectionState = .disconnected
    }

    /// Sends a JPIP request as a masked RFC 6455 binary frame and awaits the matching `requestID` response.
    public func sendRequest(_ request: JPIPRequest) async throws -> JPIPResponse {
        guard connectionState == .connected,
              let conn = tcpConnection,
              conn.isOpen else {
            throw J2KError.networkError(
                "WebSocket not connected (state: \(connectionState.rawValue))"
            )
        }

        let requestID = nextRequestID
        nextRequestID = nextRequestID == UInt32.max ? 1 : (nextRequestID + 1)

        let frame = encoder.encodeRequest(request, requestID: requestID)
        let serialized = frame.serialize()

        statistics.framesSent += 1
        statistics.bytesSent += serialized.count

        if let response = pendingResponses.removeValue(forKey: requestID) {
            return response
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuations[requestID] = continuation
            do {
                try conn.writeWebSocketFrame(
                    opcode: .binary,
                    payload: serialized,
                    masked: true
                )
            } catch {
                pendingContinuations.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    /// Sends a keepalive ping frame over the live WebSocket connection.
    public func sendPing() async throws {
        guard connectionState == .connected else { return }

        let frame = JPIPWebSocketFrame(
            type: .ping,
            payload: Data("ping".utf8)
        )

        let serialized = frame.serialize()
        lastPingTime = Date()
        if let conn = tcpConnection, conn.isOpen {
            try conn.writeWebSocketFrame(opcode: .binary, payload: serialized, masked: true)
        }
        statistics.framesSent += 1
        statistics.bytesSent += serialized.count
        statistics.keepalivePingsSent += 1
    }

    /// Handles a received pong message for latency measurement.
    public func handlePong(_ frame: JPIPWebSocketFrame) {
        guard frame.type == .pong, let pingTime = lastPingTime else { return }
        measuredLatency = Date().timeIntervalSince(pingTime)
        statistics.framesReceived += 1
        statistics.bytesReceived += frame.payload.count
    }

    /// Handles a received frame from the WebSocket connection.
    public func handleReceivedFrame(_ frame: JPIPWebSocketFrame) {
        if frame.type == .pong {
            handlePong(frame)
            return
        }

        statistics.framesReceived += 1
        statistics.bytesReceived += frame.payload.count + 9

        switch frame.type {
        case .response:
            handleResponseFrame(frame)
        case .dataBin:
            handleDataBinFrame(frame)
        case .pong:
            break
        case .push:
            handlePushFrame(frame)
        case .error:
            handleErrorFrame(frame)
        default:
            break
        }
    }

    private func handleResponseFrame(_ frame: JPIPWebSocketFrame) {
        guard let response = encoder.decodeResponse(from: frame) else { return }

        if let requestID = frame.requestID,
           let continuation = pendingContinuations.removeValue(forKey: requestID) {
            continuation.resume(returning: response)
        } else if let requestID = frame.requestID {
            pendingResponses[requestID] = response
        }
    }

    private func handleDataBinFrame(_ frame: JPIPWebSocketFrame) {
        guard let dataBin = encoder.decodeDataBin(from: frame) else { return }
        receivedDataBins.append(dataBin)
        statistics.dataBinsPushed += 1
    }

    private func handlePushFrame(_ frame: JPIPWebSocketFrame) {
        if let dataBin = encoder.decodeDataBin(from: JPIPWebSocketFrame(
            type: .dataBin,
            payload: frame.payload,
            requestID: frame.requestID
        )) {
            receivedDataBins.append(dataBin)
            statistics.dataBinsPushed += 1
        }
    }

    private func handleErrorFrame(_ frame: JPIPWebSocketFrame) {
        if let requestID = frame.requestID,
           let continuation = pendingContinuations.removeValue(forKey: requestID) {
            let message = String(data: frame.payload, encoding: .utf8)
                ?? "Unknown WebSocket error"
            continuation.resume(
                throwing: J2KError.networkError(message)
            )
        }
    }

    /// Retrieves and clears all received data bins.
    public func drainReceivedDataBins() -> [JPIPDataBin] {
        let bins = receivedDataBins
        receivedDataBins.removeAll()
        return bins
    }

    /// Attempts reconnection using exponential backoff.
    public func attemptReconnection() async throws {
        guard reconnectionConfig.enabled else {
            throw J2KError.networkError("Reconnection is disabled")
        }

        if let maxAttempts = reconnectionConfig.maxAttempts,
           reconnectionAttempts >= maxAttempts {
            throw J2KError.networkError(
                "Max reconnection attempts reached (\(maxAttempts))"
            )
        }

        if let conn = tcpConnection {
            conn.close()
            tcpConnection = nil
        }

        connectionState = .reconnecting
        let delay = reconnectionConfig.delay(forAttempt: reconnectionAttempts)
        reconnectionAttempts += 1
        statistics.reconnectionAttempts += 1

        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        try await connect()
        statistics.successfulReconnections += 1
    }

    /// Gets the current reconnection attempt count.
    public var currentReconnectionAttempts: Int {
        reconnectionAttempts
    }

    /// Resets reconnection attempt count (e.g., after successful connection).
    public func resetReconnectionAttempts() {
        reconnectionAttempts = 0
    }

    /// Gets the keepalive interval.
    public var currentKeepaliveInterval: TimeInterval {
        keepaliveInterval
    }
}
