// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import SwiftJ2KJPIP

private enum CleanupScenario: Sendable, CaseIterable, Equatable {
    case timeout, cancellation, duplicateReaderClose
    var before: JPIPWebSocketLifecycleEvent {
        switch self {
        case .timeout: .beforeTimeoutCleanup
        case .cancellation: .beforeCancellationCleanup
        case .duplicateReaderClose: .beforeReaderFinalClose
        }
    }
    var after: JPIPWebSocketLifecycleEvent {
        switch self {
        case .timeout: .afterTimeoutCleanup
        case .cancellation: .afterCancellationCleanup
        case .duplicateReaderClose: .afterReaderFinalClose
        }
    }
}

private enum ObservedRequestResult: Sendable, Equatable {
    case succeeded, cancelled, limited, failed
}

@Suite("R3 WebSocket connection-generation barriers")
struct CodexR3WebSocketLifecycleTests {
    @Test(arguments: CleanupScenario.allCases)
    fileprivate func staleCleanupCannotCloseReplacementHandshake(_ scenario: CleanupScenario) async throws {
        let peer = try LifecyclePeer(first: scenario == .duplicateReaderClose ? .malformedPush : .silent,
                                     holdSecondHandshake: true)
        let probe = LifecycleProbe(before: scenario.before, after: scenario.after)
        let transport = JPIPWebSocketTransport(url: peer.url, reconnectionConfig: .disabled)
        await transport.setLifecycleObserver { event, generation in
            await probe.observe(event, generation: generation)
        }
        let completions = Mutex(0)
        var oldRequest: Task<ObservedRequestResult, Never>?
        var reconnect: Task<Void, any Error>?
        do {
            try await transport.connect(deadline: ContinuousClock.now + .seconds(10))
            let request = Task {
                let result: ObservedRequestResult
                do {
                    _ = try await transport.sendRequest(JPIPRequest(target: "old.j2k"),
                        timeout: scenario == .timeout ? 0.5 : 10,
                        maxBodyBytes: 1024, maximumStorageBytes: 65_536)
                    result = .succeeded
                } catch is CancellationError { result = .cancelled }
                catch let error as CodecError where error.category == .resourceLimitExceeded { result = .limited }
                catch { result = .failed }
                completions.withLock { $0 += 1 }
                return result
            }
            oldRequest = request
            try await eventually { peer.firstRequestReceived }
            if scenario == .cancellation { request.cancel() }
            try await eventually { await probe.isParked }
            let oldResult = await request.value
            switch scenario {
            case .timeout: #expect(oldResult == .limited)
            case .cancellation: #expect(oldResult == .cancelled)
            case .duplicateReaderClose: #expect(oldResult == .failed)
            }
            #expect(await transport.pendingRequestCount == 0)

            let next = Task { try await transport.connect(deadline: ContinuousClock.now + .seconds(10)) }
            reconnect = next
            // B has sent its HTTP request and installed a fresh read budget; its
            // peer deliberately withholds 101 while A's old callback is released.
            try await eventually { peer.secondHandshakeParked }
            await probe.release()
            try await eventually { await probe.cleanupAcknowledged }
            peer.releaseSecondHandshake()
            try await next.value
            let response = try await transport.sendRequest(JPIPRequest(target: "replacement.j2k"),
                timeout: 2, maxBodyBytes: 1024, maximumStorageBytes: 65_536)
            #expect(response.statusCode == 200)
            #expect(response.data == Data([23]))
            #expect(await transport.pendingRequestCount == 0)
            #expect(completions.withLock { $0 } == 1)
            try await eventually { await probe.readerCloseAcknowledged }
        } catch {
            await probe.release()
            peer.releaseSecondHandshake()
            oldRequest?.cancel()
            reconnect?.cancel()
            await transport.disconnect()
            _ = await oldRequest?.value
            _ = try? await reconnect?.value
            peer.close()
            try? await eventually { peer.isFinished }
            throw error
        }
        await transport.disconnect()
        peer.close()
        try await eventually { peer.isFinished }
    }

    @Test(arguments: [false, true])
    func obsoleteHandshakeCannotPublishOrFailReplacementConnection(rejected: Bool) async throws {
        let peer = try LifecyclePeer(first: rejected ? .rejectedHandshake : .echo, holdSecondHandshake: false)
        let probe = LifecycleProbe(before: rejected ? .beforeHandshakeFailure : .beforeHandshakePublication, after: nil)
        let transport = JPIPWebSocketTransport(url: peer.url, reconnectionConfig: .disabled)
        await transport.setLifecycleObserver { event, generation in
            await probe.observe(event, generation: generation)
        }
        let oldConnect = Task { try await transport.connect(deadline: ContinuousClock.now + .seconds(10)) }
        do {
            // A's finite handshake worker has returned success or failure, but
            // its result is held before mutating connection state.
            try await eventually { await probe.isParked }
            await transport.disconnect()
            try await transport.connect(deadline: ContinuousClock.now + .seconds(10))
            let before = try await transport.sendRequest(JPIPRequest(target: "before.j2k"),
                timeout: 2, maxBodyBytes: 1024, maximumStorageBytes: 65_536)
            #expect(before.data == Data([23]))
            await probe.release()
            do {
                try await oldConnect.value
                Issue.record("Obsolete handshake must not publish its closed connection")
            } catch is CancellationError { }
            let after = try await transport.sendRequest(JPIPRequest(target: "after.j2k"),
                timeout: 2, maxBodyBytes: 1024, maximumStorageBytes: 65_536)
            #expect(after.data == Data([23]))
            #expect(await transport.connectionState == .connected)
            #expect(await transport.pendingRequestCount == 0)
        } catch {
            await probe.release()
            oldConnect.cancel()
            await transport.disconnect()
            _ = try? await oldConnect.value
            peer.close()
            try? await eventually { peer.isFinished }
            throw error
        }
        await transport.disconnect()
        peer.close()
        try await eventually { peer.isFinished }
    }

    private func eventually(_ condition: @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        guard await condition() else { throw LifecycleTestError.barrierTimedOut }
    }
}

private enum LifecycleTestError: Error { case barrierTimedOut }

/// A cooperative barrier: waiting releases the actor and never blocks a pool thread.
private actor LifecycleProbe {
    let before: JPIPWebSocketLifecycleEvent
    let after: JPIPWebSocketLifecycleEvent?
    var origin: UInt64?
    var isParked = false
    var cleanupAcknowledged = false
    var readerCloseAcknowledged = false
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?
    init(before: JPIPWebSocketLifecycleEvent, after: JPIPWebSocketLifecycleEvent?) {
        self.before = before; self.after = after
    }
    func observe(_ event: JPIPWebSocketLifecycleEvent, generation: UInt64) async {
        if origin == nil { origin = generation }
        guard origin == generation else { return }
        if event == before {
            isParked = true
            if !released { await withCheckedContinuation { waiting = $0 } }
        }
        if event == after { cleanupAcknowledged = true }
        if event == .afterReaderFinalClose { readerCloseAcknowledged = true }
    }
    func release() {
        released = true
        waiting?.resume()
        waiting = nil
    }
}

/// Only a dedicated peer I/O thread waits on this condition. Tests observe it
/// asynchronously; close() always releases it before joining peer completion.
private final class HandshakeBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private var held = false
    private var released = false
    var reached: Bool { condition.lock(); defer { condition.unlock() }; return held }
    func wait() {
        condition.lock(); defer { condition.unlock() }
        held = true
        while !released { condition.wait() }
    }
    func release() {
        condition.lock(); defer { condition.unlock() }
        released = true
        condition.broadcast()
    }
}

/// Scripted extension peer, not an external interoperability oracle. Every
/// blocking accept/read and handshake barrier owns a dedicated thread. Shared
/// state uses Mutex, and tests acknowledge all worker completion after shutdown.
private final class LifecyclePeer: @unchecked Sendable {
    enum First: Sendable, Equatable { case silent, malformedPush, echo, rejectedHandshake }
    let listener: JPIPTCPListener
    private let gate = HandshakeBarrier()
    private let state = Mutex((connections: [JPIPTCPConnection](), accepted: 0,
                               workers: 1, closed: false, firstRequest: false))
    var url: URL { URL(string: "ws://127.0.0.1:\(listener.boundPort)/jpip")! }
    var firstRequestReceived: Bool { state.withLock { $0.firstRequest } }
    var secondHandshakeParked: Bool { gate.reached }
    var isFinished: Bool { state.withLock { $0.workers == 0 } }

    init(first: First, holdSecondHandshake: Bool) throws {
        listener = try JPIPTCPListener(host: "127.0.0.1", port: 0)
        let peer = self
        Thread.detachNewThread {
            defer { peer.state.withLock { $0.workers -= 1 } }
            while peer.listener.isOpen {
                guard let connection = try? peer.listener.acceptConnection(timeoutSeconds: 1) else { continue }
                let index = peer.state.withLock { state -> Int? in
                    guard !state.closed else { return nil }
                    state.connections.append(connection)
                    state.accepted += 1
                    state.workers += 1
                    return state.accepted
                }
                guard let index else { connection.close(); break }
                Thread.detachNewThread {
                    defer { connection.close(); peer.state.withLock { $0.workers -= 1 } }
                    guard let request = try? connection.readHTTPRequest(),
                          let key = request.header("Sec-WebSocket-Key") else { return }
                    if index == 2 && holdSecondHandshake { peer.gate.wait() }
                    if index == 1 && first == .rejectedHandshake {
                        try? connection.writeHTTPResponse(statusCode: 400, reasonPhrase: "Rejected",
                                                           headers: [:], body: Data())
                        return
                    }
                    guard (try? connection.writeWebSocketServerHandshake(clientKey: key)) != nil else { return }
                    while connection.isOpen {
                        guard let wire = try? connection.readWebSocketFrame(requireMasked: true),
                              wire.opcode != .close,
                              let frame = JPIPWebSocketFrame.deserialize(from: wire.payload),
                              let requestID = frame.requestID else { return }
                        if index == 1 { peer.state.withLock { $0.firstRequest = true } }
                        if index == 1 && first == .silent { continue }
                        if index == 1 && first == .malformedPush {
                            let invalid = JPIPWebSocketFrame(type: .dataBin,
                                payload: Data([0xFF, 0, 0, 0, 1, 1])).serialize()
                            try? connection.writeWebSocketFrame(opcode: .binary, payload: invalid, masked: false)
                            return
                        }
                        let response = JPIPResponse(channelID: nil, data: Data([23]), statusCode: 200, headers: [:])
                        let payload = JPIPWebSocketMessageEncoder().encodeResponse(response, requestID: requestID).serialize()
                        guard (try? connection.writeWebSocketFrame(opcode: .binary, payload: payload, masked: false)) != nil else { return }
                    }
                }
            }
        }
    }
    func releaseSecondHandshake() { gate.release() }
    func close() {
        listener.close()
        gate.release()
        let connections = state.withLock { state in
            state.closed = true
            return state.connections
        }
        for connection in connections { connection.close() }
    }
}
