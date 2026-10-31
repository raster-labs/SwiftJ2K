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

/// Package-only observation points for deterministic connection-lifetime tests.
/// Observers never execute while a socket/budget lock or timer callback is held.
package enum JPIPWebSocketLifecycleEvent: Sendable, Equatable {
    case beforeTimeoutCleanup, afterTimeoutCleanup
    case beforeCancellationCleanup, afterCancellationCleanup
    case beforeWriteCleanup, afterWriteCleanup
    case beforeReaderFinalClose, afterReaderFinalClose
    case beforeHandshakePublication, beforeHandshakeFailure
}

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

        // Borrow the message's slice until the response/bin decoder has admitted
        // its final owning payload; do not copy the whole application frame here.
        let payload = data[(base + 9)..<(base + endOffset)]

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

        let responseData = data.subdata(in: (base + 4 + headerLen)..<data.endIndex)
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

        let binData = data.subdata(in: cursor..<data.endIndex)

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

/// Shared by the actor and the blocking socket reader. Every mutable field is
/// protected by `lock`; no borrowed pointer or collection escapes that lock.
/// Reservations precede payload/descriptor allocation and remain live until the
/// actor has consumed a message or transferred an owning result to its caller.
package final class JPIPWebSocketReadBudget: @unchecked Sendable {
    private struct RequestLimit {
        let body: Int
        let storage: Int
        var consumedBody = 0
        var completed = false
    }
    private let lock = NSCondition()
    private var readEnabled = false
    private var allowsIdleReads = false
    private var closed = false
    private var bodyLimit = 128 * 1024 * 1024
    private var storageLimit = 512 * 1024 * 1024
    private var requests: [UInt32: RequestLimit] = [:]
    private var readingBytes = 0
    private var retainedFragmentBytes = 0
    private var queuedPayloadBytes = 0
    private var queuedCount = 0
    private var deliveredStorageBytes = 0
    private var peakBytes = 0
    private var payloadAllocations = 0

    private static func add(_ a: Int, _ b: Int) throws -> Int {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard a >= 0, b >= 0, !overflow else {
            throw CodecError(.resourceLimitExceeded, "WebSocket receive storage overflow.")
        }
        return sum
    }

    private func queuedBytes(payload: Int? = nil, count: Int? = nil) throws -> Int {
        let (descriptors, overflow) = (count ?? queuedCount).multipliedReportingOverflow(
            by: 2 * MemoryLayout<JPIPDataBin>.stride)
        guard !overflow else { throw CodecError(.resourceLimitExceeded, "WebSocket push descriptors overflow.") }
        return try Self.add(payload ?? queuedPayloadBytes, descriptors)
    }

    private var activeStorageLimit: Int {
        requests.values.reduce(storageLimit) { $1.completed ? $0 : min($0, $1.storage) }
    }

    private func remainingBody(for requestID: UInt32?) -> Int {
        if let requestID, let request = requests[requestID], !request.completed {
            return request.body - request.consumedBody
        }
        var remaining = bodyLimit
        var hasActiveRequest = false
        for request in requests.values where !request.completed {
            hasActiveRequest = true
            remaining = min(remaining, request.body - request.consumedBody)
        }
        // Idle legacy pushes share a bounded queue. During a request, only new
        // wire bytes consume its allowance; older queued owners consume storage.
        return hasActiveRequest ? remaining : max(0, bodyLimit - queuedPayloadBytes)
    }

    private func admit(_ reading: Int, queue: Int? = nil, delivered: Int? = nil) throws {
        let total = try Self.add(reading, Self.add(queue ?? queuedBytes(), delivered ?? deliveredStorageBytes))
        guard total <= activeStorageLimit else {
            throw CodecError(.resourceLimitExceeded, "WebSocket frame, decoded response and queued pushes exceed remaining storage before allocation.")
        }
        peakBytes = max(peakBytes, total)
    }

    package func configure(maxBodyBytes: Int, maximumStorageBytes: Int, allowBackgroundPush: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        guard maxBodyBytes >= 0, maximumStorageBytes > 0 else {
            throw CodecError(.invalidArgument, "WebSocket receive limits must be nonnegative with positive storage.")
        }
        bodyLimit = maxBodyBytes
        storageLimit = maximumStorageBytes
        try admit(readingBytes)
        allowsIdleReads = allowBackgroundPush
        readEnabled = allowsIdleReads || requests.values.contains { !$0.completed }
        lock.broadcast()
    }

    package func beginRequest(
        _ id: UInt32, maxBodyBytes: Int, maximumStorageBytes: Int, pauseAfterResponse: Bool = true
    ) throws {
        lock.lock(); defer { lock.unlock() }
        guard maxBodyBytes >= 0, maximumStorageBytes > 0 else {
            throw CodecError(.invalidArgument, "WebSocket receive limits must be nonnegative with positive storage.")
        }
        // Results of the preceding request now belong to its caller. The new
        // allowance is supplied after that caller accounts for retained owners.
        if requests.isEmpty {
            deliveredStorageBytes = 0
            peakBytes = 0
            payloadAllocations = 0
        }
        bodyLimit = maxBodyBytes
        storageLimit = maximumStorageBytes
        allowsIdleReads = !pauseAfterResponse
        // Queued owners still consume storage, but their bytes belong to an
        // earlier transfer round. The caller has already charged that round.
        requests[id] = RequestLimit(body: maxBodyBytes, storage: maximumStorageBytes)
        do { try admit(readingBytes) }
        catch { requests.removeValue(forKey: id); throw error }
        readEnabled = true
        lock.broadcast()
    }

    package func endRequest(_ id: UInt32) {
        lock.lock(); defer { lock.unlock() }
        requests.removeValue(forKey: id)
        readEnabled = allowsIdleReads || requests.values.contains { !$0.completed }
        lock.broadcast()
    }

    /// The reader cannot allocate background pushes while its caller owns the
    /// completed response and is parsing/reconstructing under a new live budget.
    package func pauseAfterResponse(_ id: UInt32) {
        lock.lock(); defer { lock.unlock() }
        requests[id]?.completed = true
        readEnabled = allowsIdleReads || requests.values.contains { !$0.completed }
    }

    package func waitUntilReadAllowed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        while !readEnabled && !closed { lock.wait() }
        return !closed
    }

    package func close() {
        lock.lock(); defer { lock.unlock() }
        closed = true
        lock.broadcast()
    }

    /// Called from the socket reader after length bytes but before reading even
    /// the small application prefix. Fragment append may retain old/new buffers.
    package func admitFrame(fragmentedBytes: Int, payloadBytes: Int, control: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        let next = try Self.add(fragmentedBytes, payloadBytes)
        if !control {
            let envelopeLimit = try Self.add(remainingBody(for: nil), 9 + 4 + Int(UInt16.max))
            guard next <= envelopeLimit else {
                throw CodecError(.resourceLimitExceeded, "WebSocket announced message exceeds remaining body allowance before payload allocation.")
            }
        }
        var transient = next
        if !control && fragmentedBytes > 0 { transient = try Self.add(transient, next) }
        transient = try Self.add(transient, min(payloadBytes, 27) + min(next, 27) + 14)
        try admit(transient)
        readingBytes = transient
        retainedFragmentBytes = fragmentedBytes
    }

    /// At most 27 bytes suffice for the application header and optional bin
    /// fields. Validate the declared body before allocating/reading its remainder.
    package func admitApplicationPrefix(_ prefix: Data, announcedBytes: Int, final: Bool) throws {
        guard prefix.count >= 9 else { return }
        let b = prefix.startIndex
        func u32(_ p: Int) -> UInt32 {
            UInt32(prefix[b + p]) << 24 | UInt32(prefix[b + p + 1]) << 16
                | UInt32(prefix[b + p + 2]) << 8 | UInt32(prefix[b + p + 3])
        }
        let request = u32(1)
        let declared = Int(u32(5))
        let messageLength = try Self.add(9, declared)
        guard announcedBytes <= messageLength, !final || announcedBytes == messageLength else {
            throw J2KError.invalidData("WebSocket application length does not match its message.")
        }
        let body: Int
        if prefix[b] == JPIPWebSocketFrame.FrameType.response.rawValue {
            guard prefix.count >= 13 else { return }
            let headers = Int(prefix[b + 11]) << 8 | Int(prefix[b + 12])
            guard declared >= 4 + headers else { throw J2KError.invalidData("Truncated WebSocket response header.") }
            body = declared - 4 - headers
        } else if prefix[b] == JPIPWebSocketFrame.FrameType.dataBin.rawValue
                    || prefix[b] == JPIPWebSocketFrame.FrameType.push.rawValue {
            guard prefix.count >= 15 else { return }
            let flags = prefix[b + 14]
            let header = 6 + ((flags & 0x02) == 0 ? 0 : 4)
                + ((flags & 0x04) == 0 ? 0 : 4) + ((flags & 0x08) == 0 ? 0 : 4)
            guard declared >= header else { throw J2KError.invalidData("Truncated WebSocket data-bin header.") }
            body = declared - header
        } else { body = declared }
        lock.lock(); defer { lock.unlock() }
        guard body <= remainingBody(for: request == 0 ? nil : request) else {
            throw CodecError(.resourceLimitExceeded, "WebSocket declared body exceeds remaining allowance before payload allocation.")
        }
    }

    package func willAllocatePayload() {
        lock.lock(); defer { lock.unlock() }
        payloadAllocations += 1
    }

    package func didReadMessage(bytes: Int, retainedFragments: Int) {
        lock.lock(); defer { lock.unlock() }
        readingBytes = bytes + retainedFragments
        retainedFragmentBytes = retainedFragments
    }

    package func finishMessage() {
        lock.lock(); defer { lock.unlock() }
        readingBytes = retainedFragmentBytes
    }

    package func resetReading() {
        lock.lock(); defer { lock.unlock() }
        readingBytes = 0
        retainedFragmentBytes = 0
    }

    private func consumeBody(_ count: Int, requestID: UInt32?) throws {
        guard count <= remainingBody(for: requestID) else {
            throw CodecError(.resourceLimitExceeded, "WebSocket response and push bodies exceed remaining allowance.")
        }
        if let requestID, var request = requests[requestID], !request.completed {
            request.consumedBody += count
            requests[requestID] = request
        } else {
            for id in Array(requests.keys) where requests[id]?.completed == false { requests[id]?.consumedBody += count }
        }
    }

    package func reserveResponse(bodyBytes: Int, decodedStorageBytes: Int, requestID: UInt32?) throws {
        lock.lock(); defer { lock.unlock() }
        let delivered = try Self.add(deliveredStorageBytes, decodedStorageBytes)
        try admit(readingBytes, delivered: delivered)
        try consumeBody(bodyBytes, requestID: requestID)
        deliveredStorageBytes = delivered
    }

    package func admitControlReply(payloadBytes: Int) throws {
        lock.lock(); defer { lock.unlock() }
        let copies = try Self.add(payloadBytes, Self.add(payloadBytes, 14))
        try admit(Self.add(readingBytes, copies))
    }

    package static func responseStorageBytes(bodyBytes: Int, headerBytes: Int, headerCount: Int) throws -> Int {
        let (descriptors, overflow) = headerCount.multipliedReportingOverflow(
            by: 2 * (MemoryLayout<(String, String)>.stride + MemoryLayout<Substring>.stride))
        guard !overflow, headerBytes >= 0, headerBytes <= Int(UInt16.max) else {
            throw CodecError(.resourceLimitExceeded, "WebSocket decoded header storage overflow.")
        }
        let splitScratch = headerCount == 0 ? 0 : 4 * MemoryLayout<Substring>.stride
        return try add(bodyBytes, add(3 * headerBytes,
            add(descriptors, add(splitScratch, 2 * MemoryLayout<(UInt32, JPIPResponse)>.stride))))
    }

    package func reservePush(payloadBytes: Int, requestID: UInt32?) throws {
        lock.lock(); defer { lock.unlock() }
        let payload = try Self.add(queuedPayloadBytes, payloadBytes)
        let count = try Self.add(queuedCount, 1)
        let priorDescriptors = try queuedBytes() - queuedPayloadBytes
        // Growing the array can retain its old descriptors while allocating the
        // replacement. Data owners are shared; only the new payload is copied.
        let growingQueue = try Self.add(queuedBytes(payload: payload, count: count), priorDescriptors)
        try admit(readingBytes, queue: growingQueue)
        try consumeBody(payloadBytes, requestID: requestID)
        queuedPayloadBytes = payload
        queuedCount = count
    }

    package func drainPushes() {
        lock.lock(); defer { lock.unlock() }
        queuedPayloadBytes = 0
        queuedCount = 0
    }

    package var snapshot: (
        peakStorageBytes: Int, payloadAllocationCount: Int, queuedBins: Int,
        queuedStorageBytes: Int, retainedStorageBytes: Int
    ) {
        lock.lock(); defer { lock.unlock() }
        let queued = (try? queuedBytes()) ?? Int.max
        let retained = (try? Self.add(readingBytes, Self.add(queued, deliveredStorageBytes))) ?? Int.max
        return (peakBytes, payloadAllocations, queuedCount, queued, retained)
    }

    package var configuredLimits: (body: Int, storage: Int, backgroundPush: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (bodyLimit, storageLimit, allowsIdleReads)
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
    private var pendingErrors: [UInt32: J2KError]

    /// Pending response continuations for async/await multiplexed requests.
    private var pendingContinuations: [UInt32: CheckedContinuation<JPIPResponse, any Error>]

    /// Received data bins pushed by the server.
    private var receivedDataBins: [JPIPDataBin]

    private var readBudget = JPIPWebSocketReadBudget()
    private var unconsumedHandshakePeakBytes = 0
    private var unaccountedPushPayloadBytes = 0

    /// Keepalive interval in seconds.
    private let keepaliveInterval: TimeInterval

    /// Per-request / handshake timeout in seconds.
    private let requestTimeout: TimeInterval

    /// Last ping timestamp for latency measurement.
    private var lastPingTime: Date?

    /// Measured round-trip latency in seconds.
    public private(set) var measuredLatency: TimeInterval?

    /// Active upgraded RFC 6455 TCP socket.
    private var tcpConnection: JPIPTCPConnection?

    /// Monotonic connection generation to isolate reader loops across reconnects.
    private var connectionGeneration: UInt64 = 0
    private var pendingConnect: (generation: UInt64, token: JPIPSocketCancellationToken)?
    private var lifecycleObserver: (@Sendable (JPIPWebSocketLifecycleEvent, UInt64) async -> Void)?

    package func setLifecycleObserver(
        _ observer: (@Sendable (JPIPWebSocketLifecycleEvent, UInt64) async -> Void)?
    ) {
        lifecycleObserver = observer
    }

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
        keepaliveInterval: TimeInterval = 30.0,
        requestTimeout: TimeInterval = 30.0
    ) {
        self.url = url
        self.connectionState = .disconnected
        self.reconnectionConfig = reconnectionConfig
        self.encoder = JPIPWebSocketMessageEncoder()
        self.reconnectionAttempts = 0
        self.nextRequestID = 1
        self.pendingResponses = [:]
        self.pendingErrors = [:]
        self.pendingContinuations = [:]
        self.receivedDataBins = []
        self.keepaliveInterval = keepaliveInterval
        self.requestTimeout = max(0.001, requestTimeout)
        self.tcpConnection = nil
        self.statistics = Statistics()
    }

    /// Establishes the real TCP RFC 6455 WebSocket connection (`Sec-WebSocket-Protocol: jpip`).
    public func connect() async throws {
        try await connect(deadline: nil, allowBackgroundPush: true)
    }

    package func connect(
        deadline: ContinuousClock.Instant?,
        maxBodyBytes: Int = 128 * 1024 * 1024,
        maximumStorageBytes: Int = 512 * 1024 * 1024,
        allowBackgroundPush: Bool = false
    ) async throws {
        try Task.checkCancellation()
        let remainingDeadline = try deadline.map { try JPIPTransport.remainingSeconds(until: $0) }

        guard connectionState == .disconnected
                || connectionState == .reconnecting else {
            throw J2KError.invalidState(
                "Cannot connect: already in state \(connectionState.rawValue)"
            )
        }
        let nextBudget = JPIPWebSocketReadBudget()
        try nextBudget.configure(maxBodyBytes: maxBodyBytes, maximumStorageBytes: maximumStorageBytes,
                                 allowBackgroundPush: allowBackgroundPush)
        for bin in receivedDataBins { try nextBudget.reservePush(payloadBytes: bin.data.count, requestID: nil) }

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

        // Retire the old generation before replacing any owners or suspending.
        // A duplicate old-reader close must already be stale during this handshake.
        connectionGeneration &+= 1
        let gen = connectionGeneration
        let observer = lifecycleObserver
        readBudget.close()
        readBudget = nextBudget
        connectionState = .connecting

        let handshakeTimeout = remainingDeadline.map { max(0.001, min(self.requestTimeout, $0)) } ?? self.requestTimeout
        let cancelToken = JPIPSocketCancellationToken()
        pendingConnect = (gen, cancelToken)
        var deadlineTimedOut = false
        let watchdog = remainingDeadline.map { remaining in
            JPIPDeadlineWatchdog(after: remaining) { cancelToken.cancel() }
        }
        defer {
            watchdog?.cancel()
            if pendingConnect?.generation == gen { pendingConnect = nil }
        }

        let openedConn: JPIPTCPConnection
        let handshakePeakBytes: Int
        do {
            (openedConn, handshakePeakBytes) = try await withTaskCancellationHandler {
                try await Self.openAndHandshakeOffPool(
                    host: host,
                    port: port,
                    pathAndQuery: pathAndQuery,
                    hostHeader: hostHeader,
                    timeoutInterval: handshakeTimeout,
                    maximumStorageBytes: maximumStorageBytes,
                    cancelToken: cancelToken
                )
            } onCancel: {
                cancelToken.cancel()
            }
        } catch {
            if let observer { await observer(.beforeHandshakeFailure, gen) }
            nextBudget.close()
            if gen == connectionGeneration, readBudget === nextBudget {
                connectionGeneration &+= 1
                connectionState = .disconnected
            }
            if Task.isCancelled {
                throw CancellationError()
            }
            if let deadline, ContinuousClock.now >= deadline {
                deadlineTimedOut = true
            }
            if deadlineTimedOut {
                throw CodecError(.resourceLimitExceeded, "JPIP WebSocket handshake deadline elapsed.")
            }
            if cancelToken.cancelled {
                throw CancellationError()
            }
            throw error
        }

        if let observer { await observer(.beforeHandshakePublication, gen) }
        guard gen == connectionGeneration, readBudget === nextBudget,
              connectionState == .connecting else {
            openedConn.close()
            nextBudget.close()
            throw CancellationError()
        }
        if Task.isCancelled {
            openedConn.close()
            nextBudget.close()
            connectionGeneration &+= 1
            connectionState = .disconnected
            throw CancellationError()
        }
        if let deadline, ContinuousClock.now > deadline {
            openedConn.close()
            nextBudget.close()
            connectionGeneration &+= 1
            connectionState = .disconnected
            throw CodecError(.resourceLimitExceeded, "JPIP WebSocket handshake deadline elapsed.")
        }
        unconsumedHandshakePeakBytes = max(unconsumedHandshakePeakBytes, handshakePeakBytes)
        openedConn.setReceiveTimeout(interval: self.requestTimeout)
        openedConn.setSendTimeout(interval: self.requestTimeout)

        self.tcpConnection = openedConn
        self.connectionState = .connected
        self.reconnectionAttempts = 0

        let transportRef = self
        let budget = nextBudget
        // A parked reader owns its OS thread, never a global/cooperative worker.
        Thread.detachNewThread {
            Self.runReaderLoop(connection: openedConn, generation: gen, transport: transportRef, budget: budget,
                               observer: observer)
        }
    }

    nonisolated private static func openAndHandshakeOffPool(
        host: String,
        port: Int,
        pathAndQuery: String,
        hostHeader: String,
        timeoutInterval: TimeInterval,
        maximumStorageBytes: Int,
        cancelToken: JPIPSocketCancellationToken
    ) async throws -> (JPIPTCPConnection, Int) {
        try await JPIPBlockingWorker.run {
            if cancelToken.cancelled { throw CancellationError() }
            let connection: JPIPTCPConnection
            do {
                connection = try JPIPTCPConnection.connect(
                    host: host, port: port, timeoutInterval: timeoutInterval,
                    cancellationToken: cancelToken)
            } catch {
                if cancelToken.cancelled { throw CancellationError() }
                throw error
            }
            do {
                let handshake = try connection.performWebSocketClientHandshake(
                    pathAndQuery: pathAndQuery, hostHeader: hostHeader, subprotocol: "jpip",
                    maxHeaderBytes: 65_536, maxBodyBytes: 0, maximumStorageBytes: maximumStorageBytes)
                if cancelToken.cancelled { throw CancellationError() }
                connection.setReceiveTimeout(seconds: 0)
                return (connection, handshake.peakWorkspaceBytes)
            } catch {
                connection.close()
                if cancelToken.cancelled { throw CancellationError() }
                throw error
            }
        }
    }

    nonisolated private static func runReaderLoop(
        connection: JPIPTCPConnection,
        generation: UInt64,
        transport: JPIPWebSocketTransport,
        budget: JPIPWebSocketReadBudget,
        observer: (@Sendable (JPIPWebSocketLifecycleEvent, UInt64) async -> Void)?
    ) {
        var terminalError: (any Error)?
        while connection.isOpen {
            guard budget.waitUntilReadAllowed() else { break }
            do {
                let wireFrame = try connection.readWebSocketFrame(requireMasked: false, budget: budget)
                switch wireFrame.opcode {
                case .close:
                    connection.close()
                case .ping:
                    try budget.admitControlReply(payloadBytes: wireFrame.payload.count)
                    try? connection.writeWebSocketFrame(opcode: .pong, payload: wireFrame.payload, masked: true)
                case .pong:
                    let appPong = JPIPWebSocketFrame.deserialize(from: wireFrame.payload)
                        ?? JPIPWebSocketFrame(type: .pong, payload: wireFrame.payload)
                    performActorCallAndWait {
                        await transport.handleNetworkPong(appPong, generation: generation)
                    }
                case .binary, .text:
                    if let appFrame = JPIPWebSocketFrame.deserialize(from: wireFrame.payload) {
                        performActorCallAndWait {
                            await transport.handleNetworkFrame(appFrame, generation: generation)
                        }
                    }
                case .continuation:
                    break
                }
            } catch {
                terminalError = error
                break
            }
            // The handler task is joined and the source message's lexical scope
            // has ended before returning an owning decoded response to its caller.
            budget.finishMessage()
            performActorCallAndWait { await transport.publishResponses(generation: generation) }
        }

        budget.resetReading()
        budget.close()
        let closingError = terminalError
        performActorCallAndWait {
            if let observer { await observer(.beforeReaderFinalClose, generation) }
            await transport.handleSocketClosed(generation: generation, error: closingError)
            if let observer { await observer(.afterReaderFinalClose, generation) }
        }
    }

    nonisolated private static func performActorCallAndWait(_ action: @escaping @Sendable () async -> Void) {
        let work = Task { await action() }
        let sema = DispatchSemaphore(value: 0)
        Task { await work.value; sema.signal() }
        sema.wait()
    }

    private func handleSocketClosed(generation: UInt64, error: (any Error)? = nil) {
        guard generation == connectionGeneration else { return }
        // Retire before resuming a caller, which may immediately reconnect.
        connectionGeneration &+= 1
        pendingConnect?.token.cancel()
        pendingConnect = nil
        readBudget.close()
        tcpConnection?.close()
        tcpConnection = nil
        if connectionState == .connected || connectionState == .connecting {
            connectionState = .disconnected
        }
        for (_, continuation) in pendingContinuations {
            continuation.resume(
                throwing: error ?? J2KError.networkError("WebSocket connection closed by peer")
            )
        }
        pendingContinuations.removeAll()
        pendingResponses.removeAll()
        pendingErrors.removeAll()
    }

    /// Closes the WebSocket connection cleanly with an RFC 6455 close control frame.
    public func disconnect(code: Int = 1000) async {
        guard connectionState == .connected
                || connectionState == .connecting || connectionState == .reconnecting else {
            return
        }

        connectionState = .closing
        connectionGeneration &+= 1
        pendingConnect?.token.cancel()
        pendingConnect = nil
        readBudget.close()

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
        pendingErrors.removeAll()

        connectionState = .disconnected
    }

    /// Sends a JPIP request as a masked RFC 6455 binary frame and awaits the matching `requestID` response
    /// with structured task cancellation and bounded request-timeout enforcement.
    public func sendRequest(
        _ request: JPIPRequest,
        timeout: TimeInterval? = nil
    ) async throws -> JPIPResponse {
        try await sendRequest(request, timeout: timeout, maxBodyBytes: 128 * 1024 * 1024,
                              maximumStorageBytes: 512 * 1024 * 1024, pauseAfterResponse: false)
    }

    /// Resource-bounded facade requests pause further reads before handing the
    /// decoded response to the caller. Legacy push clients retain bounded idle reads.
    package func sendRequest(
        _ request: JPIPRequest,
        timeout: TimeInterval? = nil,
        maxBodyBytes: Int,
        maximumStorageBytes: Int,
        pauseAfterResponse: Bool = true
    ) async throws -> JPIPResponse {
        try Task.checkCancellation()

        guard connectionState == .connected,
              let conn = tcpConnection,
              conn.isOpen else {
            throw J2KError.networkError(
                "WebSocket not connected (state: \(connectionState.rawValue))"
            )
        }

        let requestID = nextRequestID
        nextRequestID = nextRequestID == UInt32.max ? 1 : (nextRequestID + 1)
        let originBudget = readBudget
        let generation = connectionGeneration
        let observer = lifecycleObserver
        try originBudget.beginRequest(requestID, maxBodyBytes: maxBodyBytes, maximumStorageBytes: maximumStorageBytes,
                                    pauseAfterResponse: pauseAfterResponse)
        defer { originBudget.endRequest(requestID) }

        let frame = encoder.encodeRequest(request, requestID: requestID)
        let serialized = frame.serialize()

        statistics.framesSent += 1
        statistics.bytesSent += serialized.count

        if let response = pendingResponses.removeValue(forKey: requestID) {
            return response
        }

        let effectiveTimeout = max(0.001, timeout ?? requestTimeout)
        guard effectiveTimeout.isFinite else {
            throw J2KError.invalidParameter("WebSocket timeout must be finite.")
        }
        let cancelToken = JPIPSocketCancellationToken()
        guard cancelToken.bind(connection: conn) else { throw CancellationError() }
        let transportRef = self
        let timeoutWatchdog = JPIPDeadlineWatchdog(after: effectiveTimeout) {
            // Closing the socket does not depend on actor/cooperative scheduling.
            cancelToken.cancel()
            originBudget.close()
            Task {
                await Self.finishRequestFailure(transport: transportRef, generation: generation,
                    budget: originBudget, connection: conn,
                    error: CodecError(.resourceLimitExceeded, "JPIP WebSocket request \(requestID) timed out after \(effectiveTimeout) seconds."),
                    before: .beforeTimeoutCleanup, after: .afterTimeoutCleanup, observer: observer)
            }
        }
        defer { timeoutWatchdog.cancel() }

        // Register the response continuation before scheduling the blocking send. The
        // POSIX write runs off the actor so its deadline and cancellation can close the
        // socket even when a peer never drains its receive buffer. Join that writer on
        // every exit; its connection/data owners cannot outlive operation cleanup.
        var writer: Task<Void, Never>?
        do {
            let response: JPIPResponse = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    pendingContinuations[requestID] = continuation
                    writer = Task {
                        do {
                            try await Self.writeRequestOffPool(connection: conn, payload: serialized)
                        } catch {
                            await Self.finishRequestFailure(transport: transportRef, generation: generation,
                                budget: originBudget, connection: conn, error: error,
                                before: .beforeWriteCleanup, after: .afterWriteCleanup, observer: observer)
                        }
                    }
                }
            } onCancel: {
                cancelToken.cancel()
                originBudget.close()
                Task {
                    await Self.finishRequestFailure(transport: transportRef, generation: generation,
                        budget: originBudget, connection: conn, error: CancellationError(),
                        before: .beforeCancellationCleanup, after: .afterCancellationCleanup, observer: observer)
                }
            }
            await writer?.value
            try Task.checkCancellation()
            if timeoutWatchdog.isExpired {
                throw CodecError(.resourceLimitExceeded, "JPIP WebSocket request deadline elapsed.")
            }
            return response
        } catch {
            await writer?.value
            if Task.isCancelled { throw CancellationError() }
            if timeoutWatchdog.isExpired {
                throw CodecError(.resourceLimitExceeded, "JPIP WebSocket request deadline elapsed.")
            }
            throw error
        }
    }

    nonisolated private static func writeRequestOffPool(
        connection: JPIPTCPConnection, payload: Data
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            Thread.detachNewThread {
                do {
                    try connection.writeWebSocketFrame(opcode: .binary, payload: payload, masked: true)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    package var pendingRequestCount: Int {
        pendingContinuations.count + pendingResponses.count
    }

    /// The finite writer is joined by sendRequest. Timeout/cancellation actor
    /// callbacks and the reader's terminal notification may finish later: each
    /// retains only its original owners, and stale callbacks cannot change a
    /// later generation. Watchdog cancellation joins its synchronous action only.
    nonisolated private static func finishRequestFailure(
        transport: JPIPWebSocketTransport, generation: UInt64,
        budget: JPIPWebSocketReadBudget, connection: JPIPTCPConnection, error: any Error,
        before: JPIPWebSocketLifecycleEvent, after: JPIPWebSocketLifecycleEvent,
        observer: (@Sendable (JPIPWebSocketLifecycleEvent, UInt64) async -> Void)?
    ) async {
        budget.close()
        connection.close()
        if let observer { await observer(before, generation) }
        await transport.failOriginatingConnection(generation: generation, budget: budget,
                                                  connection: connection, error: error)
        if let observer { await observer(after, generation) }
    }

    private func failOriginatingConnection(
        generation: UInt64, budget: JPIPWebSocketReadBudget,
        connection: JPIPTCPConnection, error: any Error
    ) {
        guard generation == connectionGeneration, readBudget === budget,
              tcpConnection === connection else { return }
        handleSocketClosed(generation: generation, error: error)
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

    private func handleNetworkPong(_ frame: JPIPWebSocketFrame, generation: UInt64) {
        guard generation == connectionGeneration else { return }
        handlePong(frame)
    }

    private func handleNetworkFrame(_ frame: JPIPWebSocketFrame, generation: UInt64) {
        guard generation == connectionGeneration else { return }
        do { try handleReceivedFrameBounded(frame) }
        catch { handleSocketClosed(generation: generation, error: error) }
    }

    /// Handles a received frame from the WebSocket connection.
    public func handleReceivedFrame(_ frame: JPIPWebSocketFrame) {
        do {
            try handleReceivedFrameBounded(frame)
            publishResponses(generation: connectionGeneration)
        }
        catch { handleSocketClosed(generation: connectionGeneration, error: error) }
    }

    package func handleReceivedFrameBounded(_ frame: JPIPWebSocketFrame) throws {
        if frame.type == .pong {
            handlePong(frame)
            return
        }

        statistics.framesReceived += 1
        statistics.bytesReceived += frame.payload.count + 9

        switch frame.type {
        case .response:
            try handleResponseFrame(frame)
        case .dataBin:
            try handleDataBinFrame(frame)
        case .pong:
            break
        case .push:
            try handlePushFrame(frame)
        case .error:
            try handleErrorFrame(frame)
        default:
            break
        }
    }

    private func handleResponseFrame(_ frame: JPIPWebSocketFrame) throws {
        // An unsolicited response has no consumer and must not allocate decoded
        // payload/header storage merely to be discarded.
        guard let requestID = frame.requestID, pendingContinuations[requestID] != nil else { return }
        let data = frame.payload
        guard data.count >= 4 else { throw J2KError.invalidData("Truncated WebSocket response.") }
        let base = data.startIndex
        let headerBytes = Int(data[base + 2]) << 8 | Int(data[base + 3])
        guard headerBytes <= data.count - 4 else { throw J2KError.invalidData("Truncated WebSocket response headers.") }
        let bodyBytes = data.count - 4 - headerBytes
        var headerCount = headerBytes == 0 ? 0 : 1
        for byte in data[(base + 4)..<(base + 4 + headerBytes)] where byte == 0x0A { headerCount += 1 }
        // The header byte block is borrowed; the decoded String, key/value
        // strings and dictionary descriptors coexist with the owning body copy.
        let decodedStorage = try JPIPWebSocketReadBudget.responseStorageBytes(
            bodyBytes: bodyBytes, headerBytes: headerBytes, headerCount: headerCount)
        try readBudget.reserveResponse(bodyBytes: bodyBytes, decodedStorageBytes: decodedStorage, requestID: requestID)
        guard let response = encoder.decodeResponse(from: frame) else { return }

        pendingResponses[requestID] = response
        readBudget.pauseAfterResponse(requestID)
    }

    private func publishResponses(generation: UInt64) {
        guard generation == connectionGeneration else { return }
        for (requestID, response) in pendingResponses {
            pendingContinuations.removeValue(forKey: requestID)?.resume(returning: response)
        }
        pendingResponses.removeAll()
        for (requestID, error) in pendingErrors {
            pendingContinuations.removeValue(forKey: requestID)?.resume(throwing: error)
        }
        pendingErrors.removeAll()
    }

    private func handleDataBinFrame(_ frame: JPIPWebSocketFrame) throws {
        let data = frame.payload
        guard data.count >= 6,
              JPIPDataBinClass(rawValue: Int(data[data.startIndex])) != nil else {
            throw J2KError.invalidData("Malformed pushed WebSocket data bin.")
        }
        let flags = data[data.startIndex + 5]
        let header = 6 + ((flags & 0x02) == 0 ? 0 : 4)
            + ((flags & 0x04) == 0 ? 0 : 4) + ((flags & 0x08) == 0 ? 0 : 4)
        guard data.count >= header else { throw J2KError.invalidData("Truncated pushed WebSocket data bin.") }
        let (unaccounted, overflow) = unaccountedPushPayloadBytes.addingReportingOverflow(data.count - header)
        guard !overflow else {
            throw CodecError(.resourceLimitExceeded, "Cumulative WebSocket pushed payload overflow before append.")
        }
        try readBudget.reservePush(payloadBytes: data.count - header, requestID: frame.requestID)
        guard let dataBin = encoder.decodeDataBin(from: frame) else { return }
        unaccountedPushPayloadBytes = unaccounted
        receivedDataBins.append(dataBin)
        statistics.dataBinsPushed += 1
    }

    private func handlePushFrame(_ frame: JPIPWebSocketFrame) throws {
        try handleDataBinFrame(JPIPWebSocketFrame(
            type: .dataBin,
            payload: frame.payload,
            requestID: frame.requestID
        ))
    }

    private func handleErrorFrame(_ frame: JPIPWebSocketFrame) throws {
        if let requestID = frame.requestID, pendingContinuations[requestID] != nil {
            let storage = try JPIPWebSocketReadBudget.responseStorageBytes(
                bodyBytes: frame.payload.count, headerBytes: 0, headerCount: 0)
            try readBudget.reserveResponse(bodyBytes: frame.payload.count, decodedStorageBytes: storage, requestID: requestID)
            readBudget.pauseAfterResponse(requestID)
            let message = String(data: frame.payload, encoding: .utf8)
                ?? "Unknown WebSocket error"
            pendingErrors[requestID] = J2KError.networkError(message)
        }
    }

    /// Retrieves and clears all received data bins.
    public func drainReceivedDataBins() -> [JPIPDataBin] {
        let bins = receivedDataBins
        receivedDataBins.removeAll()
        readBudget.drainPushes()
        return bins
    }

    package func configureReceiveLimits(maxBodyBytes: Int, maximumStorageBytes: Int) throws {
        try readBudget.configure(maxBodyBytes: maxBodyBytes, maximumStorageBytes: maximumStorageBytes,
                                 allowBackgroundPush: true)
    }

    /// Consume only in the operation that established this connection, before
    /// combining its peak with that operation's retained client owners. Separate
    /// from the per-request ledger, whose high water resets in beginRequest.
    package func takeHandshakeReceivePeakBytes() -> Int {
        let peak = unconsumedHandshakePeakBytes
        unconsumedHandshakePeakBytes = 0
        return peak
    }

    /// Payload accepted since the previous charge. Draining retained bins does
    /// not clear this transfer counter; cnew/probe rounds may leave them queued.
    package func takeUnaccountedPushPayloadBytes() -> Int {
        let count = unaccountedPushPayloadBytes
        unaccountedPushPayloadBytes = 0
        return count
    }

    /// Request-local high water plus currently retained transport-owned storage.
    package var receiveStorageSnapshot: (
        peakStorageBytes: Int, payloadAllocationCount: Int, queuedBins: Int,
        queuedStorageBytes: Int, retainedStorageBytes: Int
    ) {
        readBudget.snapshot
    }

    /// Attempts reconnection using exponential backoff.
    public func attemptReconnection() async throws {
        let receiveLimits = readBudget.configuredLimits
        guard reconnectionConfig.enabled else {
            throw J2KError.networkError("Reconnection is disabled")
        }

        if let maxAttempts = reconnectionConfig.maxAttempts,
           reconnectionAttempts >= maxAttempts {
            throw J2KError.networkError(
                "Max reconnection attempts reached (\(maxAttempts))"
            )
        }

        handleSocketClosed(generation: connectionGeneration,
            error: J2KError.networkError("WebSocket reconnecting"))
        let retryGeneration = connectionGeneration
        connectionState = .reconnecting
        let delay = reconnectionConfig.delay(forAttempt: reconnectionAttempts)
        reconnectionAttempts += 1
        statistics.reconnectionAttempts += 1

        do {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        } catch {
            if retryGeneration == connectionGeneration { connectionState = .disconnected }
            throw error
        }
        guard retryGeneration == connectionGeneration, connectionState == .reconnecting else {
            throw CancellationError()
        }

        try await connect(deadline: nil, maxBodyBytes: receiveLimits.body,
                          maximumStorageBytes: receiveLimits.storage, allowBackgroundPush: receiveLimits.backgroundPush)
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
