// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import SwiftJ2KJPIP

@Suite("R3 captured HTTP request close lifecycle")
struct CodexR3TransportCloseTests {
    private enum ProbeFailure: Error, Equatable { case startup, later }

    @Test func lifecycleWaitPropagatesStartupFailureAndReleasesHeldObservers() async throws {
        let probe = TransportLifecycleProbe(gatingFirst: [.beforePublication])
        let held = Task { await probe.observe(.beforePublication, UUID()) }
        try await probe.wait(.beforePublication)
        let installed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let pending = Task {
            try await probe.wait(.registered, onWaiting: {
                installed.continuation.yield(())
                installed.continuation.finish()
            })
        }
        for await _ in installed.stream { break }
        await #expect(throws: ProbeFailure.startup) {
            let _: Void = try await probe.track { throw ProbeFailure.startup }
        }
        // Abort wakes a waiter with the recorded error and releases the held
        // observer without fabricating the .registered arrival it awaited.
        await held.value
        await #expect(throws: ProbeFailure.startup) { try await pending.value }
        let registered = await probe.count(.registered)
        #expect(registered == 0)
        await #expect(throws: ProbeFailure.startup) { try await probe.wait(.registered) }
        await #expect(throws: ProbeFailure.startup) { try await probe.wait(.beforePublication) }
        await #expect(throws: ProbeFailure.later) {
            let _: Void = try await probe.track { throw ProbeFailure.later }
        }
        await #expect(throws: ProbeFailure.startup) { try await probe.wait(.registered) }
    }

    @Test func publicClientCloseCancelsInitialChannelCreationWithoutTaskCancellation() async throws {
        let peer = try TransportClosePeer()
        defer { peer.close() }
        let client = JPIPClient(serverURL: peer.url)
        let creation = Task {
            defer { peer.senderFinished() }
            return try await client.createSession(target: "hold")
        }
        let heldID = await peer.waitForRequest(containing: "target=hold")
        guard let heldID else {
            _ = try await creation.value
            throw J2KError.invalidState("Initial cnew did not reach held-response peer")
        }
        try await client.close()
        await #expect(throws: CancellationError.self) { _ = try await creation.value }
        let active = await client.getActiveSession()
        #expect(active == nil)
        await peer.waitForClosedConnection(heldID)
        peer.close(); await peer.waitForCompletion()
    }

    @Test(arguments: ["fresh", "reused", "retry"])
    func repeatedCloseCancelsAndJoinsHeldHTTPWorker(mode: String) async throws {
        let peer = try TransportClosePeer()
        let transport = JPIPTransport(baseURL: peer.url)
        let gate = HTTPCompletionGate()
        defer { gate.release(); peer.close() }
        do {
            if mode != "fresh" {
                _ = try await transport.send(JPIPRequest(target: mode == "retry" ? "stale" : "warm"))
                if mode == "retry" { await peer.waitForClosedConnection(1) }
            }
            let probe = TransportLifecycleProbe()
            await transport.setRequestLifecycleObserver({ event, id in await probe.observe(event, id) },
                httpWorkerCompleting: { gate.holdOnDedicatedWorker() })
            let request = Task {
                defer { peer.senderFinished() }
                return try await transport.send(JPIPRequest(target: "hold"), maxBodyBytes: 8,
                    deadline: .now.advanced(by: .seconds(2)), maximumStorageBytes: 65_536)
            }
            let heldID = await peer.waitForRequest(containing: "target=hold")
            guard let heldID else {
                _ = try await request.value
                throw J2KError.invalidState("Held HTTP request did not reach peer")
            }
            gate.arm()
            #expect(peer.acceptedCount == (mode == "retry" ? 2 : 1))
            let first = Task { await transport.close() }
            let second = Task { await transport.close() }
            do { try await probe.wait(.closeJoining, count: 2) }
            catch {
                gate.release()
                request.cancel()
                await first.value; await second.value
                _ = try? await request.value
                throw error
            }
            await gate.waitUntilHeld()
            let ownership = await transport.requestOwnershipSnapshot
            let joined = await probe.count(.closeJoined)
            #expect(ownership.registered == 1)
            #expect(ownership.unfinished == 1)
            #expect(joined == 0)
            gate.release()
            await first.value; await second.value
            await #expect(throws: CancellationError.self) { _ = try await request.value }
            await peer.waitForClosedConnection(heldID)
            let finished = await transport.requestOwnershipSnapshot
            #expect(finished.registered == 0)
        } catch {
            gate.release()
            await transport.close()
            peer.close(); await peer.waitForCompletion()
            throw error
        }
        await transport.close()
        peer.close(); await peer.waitForCompletion()
    }

    @Test func closeBeforeHTTPWorkerStartupCannotReconnectAfterJoining() async throws {
        let peer = try TransportClosePeer()
        defer { peer.close() }
        let transport = JPIPTransport(baseURL: peer.url)
        let probe = TransportLifecycleProbe(gatingFirst: [.registered])
        await transport.setRequestLifecycleObserver({ event, id in await probe.observe(event, id) })
        let request = Task {
            try await probe.track {
                try await transport.send(JPIPRequest(target: "unstarted"), maxBodyBytes: 8,
                    deadline: .now.advanced(by: .seconds(2)), maximumStorageBytes: 65_536)
            }
        }
        do {
            try await probe.wait(.registered)
            await transport.close(); await transport.close()
            let before = await transport.requestOwnershipSnapshot
            #expect(before.registered == 1)
            #expect(before.unfinished == 0)
            #expect(peer.acceptedCount == 0)
            await probe.release(.registered)
            await #expect(throws: CancellationError.self) { _ = try await request.value }
            #expect(peer.acceptedCount == 0)
        } catch {
            await probe.release(.registered)
            request.cancel()
            _ = try? await request.value
            await transport.close()
            peer.close(); await peer.waitForCompletion()
            throw error
        }
        peer.close(); await peer.waitForCompletion()
    }

    @Test func staleHTTPResponseAndOldCloseCannotReplaceFreshSocketOrChannel() async throws {
        let peer = try TransportClosePeer()
        defer { peer.close() }
        let transport = JPIPTransport(baseURL: peer.url)
        let probe = TransportLifecycleProbe(gatingFirst: [.beforePublication, .closeJoining])
        await transport.setRequestLifecycleObserver({ event, id in await probe.observe(event, id) })
        let original = Task {
            try await probe.track {
                try await transport.send(JPIPRequest(target: "old"), maxBodyBytes: 8,
                    deadline: .now.advanced(by: .seconds(2)), maximumStorageBytes: 65_536)
            }
        }
        var closing: Task<Void, Never>?
        do {
            try await probe.wait(.beforePublication)
            closing = Task { await transport.close() }
            try await probe.wait(.closeJoining)
            let fresh = try await transport.send(JPIPRequest(target: "fresh"), maxBodyBytes: 8,
                deadline: .now.advanced(by: .seconds(2)), maximumStorageBytes: 65_536)
            #expect(fresh.channelID == "fresh")
            #expect(peer.acceptedCount == 2)
            await probe.release(.beforePublication)
            await #expect(throws: CancellationError.self) { _ = try await original.value }
            await probe.release(.closeJoining)
            await closing?.value
            let path = await transport.getChannelPath()
            #expect(path == "/fresh")
            // This request must reuse the replacement connection: old cleanup
            // must neither restore its closed survivor nor close the fresh one.
            _ = try await transport.send(JPIPRequest(target: "warm"), maxBodyBytes: 8,
                deadline: .now.advanced(by: .seconds(2)), maximumStorageBytes: 65_536)
            #expect(peer.acceptedCount == 2)
        } catch {
            await probe.release(.beforePublication); await probe.release(.closeJoining)
            original.cancel()
            _ = try? await original.value
            await closing?.value
            await transport.close()
            peer.close(); await peer.waitForCompletion()
            throw error
        }
        await transport.close()
        peer.close(); await peer.waitForCompletion()
    }
}

/// Only the dedicated finite HTTP worker blocks here; test tasks wait on an
/// AsyncStream. This establishes close-before-worker-ack order without sleeps.
private final class HTTPCompletionGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var released = false
    private var armed = false
    private let entered = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    func holdOnDedicatedWorker() {
        condition.lock()
        entered.continuation.yield(())
        guard armed else { condition.unlock(); return }
        while !released { condition.wait() }
        condition.unlock()
    }
    func waitUntilHeld() async { for await _ in entered.stream { return } }
    func arm() { condition.lock(); armed = true; condition.unlock() }
    func release() {
        condition.lock(); released = true; condition.broadcast(); condition.unlock()
    }
}

/// Real loopback framing with dedicated accept/read workers; all observations
/// and owner publication use Mutex. Holding a response requires no spin/sleep:
/// the worker reads the next request until client shutdown produces EOF.
private final class TransportClosePeer: @unchecked Sendable {
    private struct State {
        var connections: [Int: JPIPTCPConnection] = [:]
        var closedConnections: Set<Int> = []
        var closeWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
        var workers = 1
        var accepted = 0
        var closed = false
        var completionWaiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    private let requests = AsyncStream<(String, Int)>.makeStream(bufferingPolicy: .unbounded)
    private let listener: JPIPTCPListener
    var url: URL { URL(string: "http://127.0.0.1:\(listener.boundPort)/jpip")! }
    var acceptedCount: Int { state.withLock { $0.accepted } }

    init() throws {
        listener = try JPIPTCPListener(host: "127.0.0.1", port: 0)
        Thread.detachNewThread { [self] in
            defer { finishedWorker(connectionID: nil) }
            while listener.isOpen {
                // This argument configures the accepted socket, not accept polling.
                // Explicit close/join owns the held peer's lifetime, including idle reuse.
                guard let connection = try? listener.acceptConnection(timeoutSeconds: 0) else { continue }
                let id: Int? = state.withLock { state in
                    guard !state.closed else { return nil }
                    state.accepted += 1
                    state.connections[state.accepted] = connection
                    state.workers += 1
                    return state.accepted
                }
                guard let id else { connection.close(); break }
                Thread.detachNewThread { [self] in
                    defer { connection.close(); finishedWorker(connectionID: id) }
                    while connection.isOpen {
                        guard let request = try? connection.readHTTPRequest() else { return }
                        requests.continuation.yield((request.target, id))
                        if request.target.contains("target=hold") { continue }
                        var headers = ["Connection": "keep-alive"]
                        if request.target.contains("target=old") { headers["JPIP-cnew"] = "cid=old,path=/old" }
                        if request.target.contains("target=fresh") { headers["JPIP-cnew"] = "cid=fresh,path=/fresh" }
                        guard (try? connection.writeHTTPResponse(statusCode: 200, reasonPhrase: "OK",
                            headers: headers, body: Data([42]))) != nil else { return }
                        if request.target.contains("target=stale") { return }
                    }
                }
            }
        }
    }

    func senderFinished() { requests.continuation.yield(("sender-finished", 0)) }
    func waitForRequest(containing value: String) async -> Int? {
        for await (target, id) in requests.stream {
            if target.contains(value) { return id }
            if target == "sender-finished" { return nil }
        }
        return nil
    }
    func waitForClosedConnection(_ id: Int) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.closedConnections.contains(id) { return true }
                state.closeWaiters[id, default: []].append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
    private func finishedWorker(connectionID: Int?) {
        let waiters = state.withLock { state in
            state.workers -= 1
            var waiters: [CheckedContinuation<Void, Never>] = []
            if let connectionID {
                state.closedConnections.insert(connectionID)
                state.connections.removeValue(forKey: connectionID)
                waiters += state.closeWaiters.removeValue(forKey: connectionID) ?? []
            }
            if state.workers == 0 {
                waiters += state.completionWaiters
                state.completionWaiters.removeAll()
            }
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }
    func waitForCompletion() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.workers == 0 { return true }
                state.completionWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
    func close() {
        listener.close()
        let connections = state.withLock { state in
            state.closed = true
            return Array(state.connections.values)
        }
        for connection in connections { connection.close() }
        requests.continuation.finish()
    }
}
