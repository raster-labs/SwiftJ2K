// SPDX-License-Identifier: Apache-2.0
import Foundation
import Dispatch
import Testing
import Synchronization
@testable import SwiftJ2KJPIP

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("R3 transport pre-allocation budgets")
struct CodexR3WebSocketBudgetTests {
    @Test func descriptorHeavyHTTPHeaderIsRejectedBeforeTextParsingOrBodyRead() throws {
        let (reader, peer) = try socketPair()
        defer { reader.close(); peer.close() }
        var header = "HTTP/1.1 200 OK\r\n"
        for index in 0..<80 { header += "X\(index):0\r\n" }
        header += "Content-Length:8192\r\n\r\n"
        #expect(header.utf8.count < 4096 / 3)
        // Raw header bytes fit. No body is sent, so a body read would time out.
        // The specific pre-text error proves rejection before allocating String,
        // split-line or dictionary representations dominated by tiny headers.
        try peer.writeAll(Data(header.utf8))
        do {
            _ = try reader.readHTTPResponse(maxBodyBytes: 16_384, maximumStorageBytes: 4096)
            Issue.record("Expected HTTP header descriptor admission failure")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
            #expect(error.message.contains("before text parsing"))
        }
    }

    @Test func oversizedFrameIsDeniedFromLengthWithoutReadingItsPayload() throws {
        let (reader, peer) = try socketPair()
        defer { reader.close(); peer.close() }
        let budget = JPIPWebSocketReadBudget()
        try budget.configure(maxBodyBytes: 1_048_576, maximumStorageBytes: 4096)
        // Deliberately send only a header announcing 8192 bytes. An attempt to
        // buffer/read that payload would time out, rather than produce this error.
        try peer.writeAll(Data([0x82, 0x7E, 0x20, 0x00]))
        do {
            _ = try reader.readWebSocketFrame(requireMasked: false, budget: budget)
            Issue.record("Expected frame rejection from its announced length")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(budget.snapshot.payloadAllocationCount == 0)
    }

    @Test func declaredBodyLimitIsCheckedBeforeOwningMessageAllocation() throws {
        let (reader, peer) = try socketPair()
        defer { reader.close(); peer.close() }
        let budget = JPIPWebSocketReadBudget()
        try budget.configure(maxBodyBytes: 4096, maximumStorageBytes: 65_536)
        // This wire message fits storage, but its declared response body exceeds
        // the compressed/body ceiling. Only the bounded 27-byte prefix is sent.
        var wire = frameHeader(opcode: 0x82, payloadCount: 8192 + 13)
        wire.append(responsePrefix(bodyBytes: 8192))
        wire.append(Data(repeating: 0, count: 14))
        try peer.writeAll(wire)
        do {
            _ = try reader.readWebSocketFrame(requireMasked: false, budget: budget)
            Issue.record("Expected body rejection before the message allocation")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(budget.snapshot.payloadAllocationCount == 0)
    }

    @Test func fragmentedMessageIncludesOldAndNewBuffersBeforeNextPayload() throws {
        let (reader, peer) = try socketPair()
        defer { reader.close(); peer.close() }
        let budget = JPIPWebSocketReadBudget()
        try budget.configure(maxBodyBytes: 4096, maximumStorageBytes: 1000)
        var first = responsePrefix(bodyBytes: 800 - 13)
        first.append(Data(repeating: 0, count: 400 - first.count))
        var wire = frameHeader(opcode: 0x02, payloadCount: first.count)
        wire.append(first)
        // Each 400-byte fragment and the final 800-byte message fit separately.
        // The second fragment's payload is absent: rejection must precede its read.
        wire.append(frameHeader(opcode: 0x80, payloadCount: 400))
        try peer.writeAll(wire)
        do {
            _ = try reader.readWebSocketFrame(requireMasked: false, budget: budget)
            Issue.record("Expected fragment copy overlap rejection")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(budget.snapshot.payloadAllocationCount == 1)
    }

    @Test func queuedPushesReduceTheNextResponseBodyAllowance() throws {
        let (reader, peer) = try socketPair()
        defer { reader.close(); peer.close() }
        let budget = JPIPWebSocketReadBudget()
        try budget.beginRequest(1, maxBodyBytes: 128, maximumStorageBytes: 4096)
        try budget.reservePush(payloadBytes: 96, requestID: nil)
        var wire = frameHeader(opcode: 0x82, payloadCount: 64 + 13)
        wire.append(responsePrefix(bodyBytes: 64))
        wire.append(Data(repeating: 0, count: 14))
        try peer.writeAll(wire)
        do {
            _ = try reader.readWebSocketFrame(requireMasked: false, budget: budget)
            Issue.record("Expected cumulative push/response body rejection")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(budget.snapshot.payloadAllocationCount == 0)
        #expect(budget.snapshot.queuedBins == 1)
    }

    @Test func zeroPayloadPushesAreBoundedByDescriptorsBeforeAppend() async throws {
        let transport = JPIPWebSocketTransport(url: URL(string: "ws://127.0.0.1/jpip")!)
        let twoBins = 6 * MemoryLayout<JPIPDataBin>.stride
        try await transport.configureReceiveLimits(maxBodyBytes: 1024, maximumStorageBytes: twoBins)
        // Independently specified compact bin: class 0, ID 1, complete, zero bytes.
        let frame = JPIPWebSocketFrame(type: .dataBin, payload: Data([0, 0, 0, 0, 1, 1]))
        try await transport.handleReceivedFrameBounded(frame)
        try await transport.handleReceivedFrameBounded(frame)
        do {
            try await transport.handleReceivedFrameBounded(frame)
            Issue.record("Expected descriptor admission before third pushed-bin append")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(await transport.receiveStorageSnapshot.queuedBins == 2)
        #expect(await transport.statistics.dataBinsPushed == 2)
        #expect(await transport.drainReceivedDataBins().count == 2)
        #expect(await transport.receiveStorageSnapshot.queuedBins == 0)
    }

    @Test func readerWaitsAfterResponseAndWakesForNextRequestOrClose() async throws {
        let budget = JPIPWebSocketReadBudget()
        defer { budget.close() }
        try budget.beginRequest(1, maxBodyBytes: 1024, maximumStorageBytes: 4096)
        budget.pauseAfterResponse(1)
        budget.endRequest(1)
        let state = Mutex((entered: false, resumed: false, closed: false))
        Thread.detachNewThread {
            state.withLock { $0.entered = true }
            if budget.waitUntilReadAllowed() { state.withLock { $0.resumed = true } }
        }
        let entered = try await observe { state.withLock { $0.entered } }
        #expect(entered)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!state.withLock { $0.resumed })
        try budget.beginRequest(2, maxBodyBytes: 512, maximumStorageBytes: 2048)
        let resumed = try await observe { state.withLock { $0.resumed } }
        #expect(resumed)
        budget.pauseAfterResponse(2)
        budget.endRequest(2)
        Thread.detachNewThread {
            if !budget.waitUntilReadAllowed() { state.withLock { $0.closed = true } }
        }
        budget.close()
        let closed = try await observe { state.withLock { $0.closed } }
        #expect(closed)
    }

    @Test func priorQueuedPushesRetainStorageWithoutChargingNextBodyAgain() throws {
        let budget = JPIPWebSocketReadBudget()
        try budget.beginRequest(1, maxBodyBytes: 100, maximumStorageBytes: 4096)
        try budget.reservePush(payloadBytes: 96, requestID: 1)
        budget.pauseAfterResponse(1)
        budget.endRequest(1)
        // The shared transfer ledger now has four bytes remaining. Existing
        // queued owners remain live, but three response bytes plus a new push byte are legal.
        try budget.beginRequest(2, maxBodyBytes: 4, maximumStorageBytes: 4096)
        try budget.reserveResponse(bodyBytes: 3, decodedStorageBytes: 3, requestID: 2)
        try budget.reservePush(payloadBytes: 1, requestID: nil)
        #expect(budget.snapshot.queuedBins == 2)
        #expect(budget.snapshot.queuedStorageBytes >= 97)
        do {
            try budget.reservePush(payloadBytes: 1, requestID: 2)
            Issue.record("Expected same-request push to exceed exhausted body allowance")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
    }

    @Test func acceptedPushCounterSurvivesQueueDrainAndChargesEachFrameOnce() async throws {
        let transport = JPIPWebSocketTransport(url: URL(string: "ws://127.0.0.1/jpip")!)
        try await transport.configureReceiveLimits(maxBodyBytes: 1024, maximumStorageBytes: 4096)
        let bin = Data([0, 0, 0, 0, 1, 1, 41, 42])
        try await transport.handleReceivedFrameBounded(JPIPWebSocketFrame(type: .dataBin, payload: bin))
        #expect(await transport.drainReceivedDataBins().count == 1)
        #expect(await transport.takeUnaccountedPushPayloadBytes() == 2)
        #expect(await transport.takeUnaccountedPushPayloadBytes() == 0)
        try await transport.handleReceivedFrameBounded(JPIPWebSocketFrame(type: .push, payload: bin))
        #expect(await transport.takeUnaccountedPushPayloadBytes() == 2)
        #expect(await transport.receiveStorageSnapshot.queuedBins == 1)
        #expect(await transport.takeUnaccountedPushPayloadBytes() == 0)
    }

    @Test func deadlineWatchdogWakesDedicatedReaderAndCancellationDisarmsIt() async throws {
        let budget = JPIPWebSocketReadBudget()
        let exited = Mutex(false)
        Thread.detachNewThread {
            if !budget.waitUntilReadAllowed() { exited.withLock { $0 = true } }
        }
        let watchdog = JPIPDeadlineWatchdog(after: 0.05) { budget.close() }
        defer { watchdog.cancel(); budget.close() }
        let joined = try await observe { exited.withLock { $0 } }
        #expect(joined)
        #expect(watchdog.isExpired)

        let calls = Mutex(0)
        let cancelled = JPIPDeadlineWatchdog(after: 0.05) { calls.withLock { $0 += 1 } }
        cancelled.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!cancelled.isExpired)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func descriptorHeavyHandshakePeakBelongsOnlyToConnectingRequest() async throws {
        let listener = try JPIPTCPListener(host: "127.0.0.1", port: 0)
        let state = Mutex((connection: Optional<JPIPTCPConnection>.none, done: false, error: Optional<String>.none))
        defer {
            listener.close()
            state.withLock { $0.connection }?.close()
        }
        // Scripted extension peer, not an independent interoperability oracle.
        // It emits legal headers followed by independently specified empty-body
        // response frames. Eighty short headers dominate either response's peak.
        Thread.detachNewThread {
            defer { state.withLock { $0.done = true } }
            do {
                guard let connection = try listener.acceptConnection(timeoutSeconds: 2) else { return }
                state.withLock { $0.connection = connection }
                defer { connection.close() }
                guard let request = try connection.readHTTPRequest(),
                      let key = request.header("Sec-WebSocket-Key") else {
                    throw J2KError.invalidData("Test handshake has no key")
                }
                var header = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                header += "Sec-WebSocket-Accept: \(JPIPRFC6455Crypto.computeAcceptKey(for: key))\r\nSec-WebSocket-Protocol: jpip\r\n"
                for index in 0..<80 { header += "X\(index):0\r\n" }
                try connection.writeAll(Data((header + "\r\n").utf8))
                for _ in 0..<2 {
                    let incoming = try connection.readWebSocketFrame(requireMasked: true)
                    guard incoming.payload.count >= 9 else { throw J2KError.invalidData("Short test request") }
                    var reply = Data([0x02])
                    reply.append(incoming.payload[1..<5])
                    reply.append(contentsOf: [0, 0, 0, 4, 0, 200, 0, 0])
                    try connection.writeWebSocketFrame(opcode: .binary, payload: reply, masked: false)
                }
            } catch { state.withLock { $0.error = String(describing: error) } }
        }
        let transport = JPIPTransport(baseURL: URL(string: "ws://127.0.0.1:\(listener.boundPort)/jpip")!)
        do {
            let first = try await transport.send(JPIPRequest(target: "tiny.j2k"), maxBodyBytes: 1,
                deadline: ContinuousClock.now.advanced(by: .seconds(2)), maximumStorageBytes: 65_536)
            #expect(first.data.isEmpty)
            let connecting = await transport.receiveAdmissionSnapshot()
            #expect(connecting.peakBytes > 10_000)
            let second = try await transport.send(JPIPRequest(target: "tiny.j2k"), maxBodyBytes: 1,
                deadline: ContinuousClock.now.advanced(by: .seconds(2)), maximumStorageBytes: 65_536)
            #expect(second.data.isEmpty)
            let reused = await transport.receiveAdmissionSnapshot()
            #expect(reused.peakBytes < connecting.peakBytes)
            #expect(reused.peakBytes < 1024)
            await transport.close()
        } catch {
            await transport.close()
            throw error
        }
        let joined = try await observe { state.withLock { $0.done } }
        #expect(joined)
        #expect(state.withLock { $0.error } == nil)
    }

    private func observe(_ predicate: @Sendable () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    private func socketPair() throws -> (JPIPTCPConnection, JPIPTCPConnection) {
        var descriptors = [Int32](repeating: -1, count: 2)
        #if canImport(Glibc)
        let stream = Int32(SOCK_STREAM.rawValue)
        #else
        let stream = SOCK_STREAM
        #endif
        let result = descriptors.withUnsafeMutableBufferPointer {
            socketpair(AF_UNIX, stream, 0, $0.baseAddress!)
        }
        guard result == 0 else { throw J2KError.networkError("Could not create local test socket pair") }
        return (JPIPTCPConnection(connectedFD: descriptors[0], timeoutSeconds: 1),
                JPIPTCPConnection(connectedFD: descriptors[1], timeoutSeconds: 1))
    }

    private func frameHeader(opcode: UInt8, payloadCount: Int) -> Data {
        if payloadCount < 126 { return Data([opcode, UInt8(payloadCount)]) }
        return Data([opcode, 0x7E, UInt8((payloadCount >> 8) & 0xFF), UInt8(payloadCount & 0xFF)])
    }

    private func responsePrefix(bodyBytes: Int) -> Data {
        let declared = bodyBytes + 4
        return Data([0x02, 0, 0, 0, 1,
                     UInt8((declared >> 24) & 0xFF), UInt8((declared >> 16) & 0xFF),
                     UInt8((declared >> 8) & 0xFF), UInt8(declared & 0xFF),
                     0, 200, 0, 0])
    }
}
