// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import SwiftJ2KJPIP

@Suite("R3 blocking-worker result publication")
struct CodexR3WorkerHandoffTests {
    @Test func workerCreatedConnectionsPublishBeforeCloseAndReuse() async throws {
        let peer = try WorkerHandoffPeer()
        let transport = JPIPTransport(baseURL: peer.url)
        do {
            // Reproduce the sanitizer's exact lifetime: construct on the HTTP
            // worker, acquire on the caller, immediately close for Connection:close.
            for _ in 0..<32 {
                let response = try await transport.send(JPIPRequest(target: "close"),
                    maxBodyBytes: 64, maximumStorageBytes: 65_536)
                #expect(response.data == Data([42]))
            }
            #expect(peer.acceptedCount == 32)
            for _ in 0..<3 {
                let response = try await transport.send(JPIPRequest(target: "reuse"),
                    maxBodyBytes: 64, maximumStorageBytes: 65_536)
                #expect(response.data == Data([42]))
            }
            #expect(peer.acceptedCount == 33)
            // The server advertises keep-alive but closes this socket. The next
            // request must publish the retry worker's new connection correctly.
            _ = try await transport.send(JPIPRequest(target: "stale"),
                maxBodyBytes: 64, maximumStorageBytes: 65_536)
            let retried = try await transport.send(JPIPRequest(target: "reuse"),
                maxBodyBytes: 64, maximumStorageBytes: 65_536)
            #expect(retried.data == Data([42]))
            #expect(peer.acceptedCount == 34)
        } catch {
            await transport.close()
            peer.close()
            await peer.waitForCompletion()
            throw error
        }
        await transport.close()
        peer.close()
        await peer.waitForCompletion()
    }

    @Test func workerErrorAndCancellationDoNotPublishAReusableConnection() async throws {
        let peer = try WorkerHandoffPeer()
        let transport = JPIPTransport(baseURL: peer.url)
        var cancelledRequest: Task<JPIPResponse, any Error>?
        do {
            do {
                _ = try await transport.send(JPIPRequest(target: "oversized"),
                    maxBodyBytes: 64, maximumStorageBytes: 65_536)
                Issue.record("Expected announced-body admission failure")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }
            #expect(peer.acceptedCount == 1)
            _ = try await transport.send(JPIPRequest(target: "reuse"),
                maxBodyBytes: 64, maximumStorageBytes: 65_536)
            #expect(peer.acceptedCount == 2)
            let request = Task {
                defer { peer.requestFinished() }
                return try await transport.send(JPIPRequest(target: "cancel"),
                    maxBodyBytes: 64, maximumStorageBytes: 65_536)
            }
            cancelledRequest = request
            if !(await peer.waitForCancellationRequest()) {
                _ = try await request.value
                throw J2KError.invalidState("Silent request finished before reaching the peer")
            }
            request.cancel()
            await #expect(throws: CancellationError.self) { _ = try await request.value }
            let recovered = try await transport.send(JPIPRequest(target: "close"),
                maxBodyBytes: 64, maximumStorageBytes: 65_536)
            #expect(recovered.data == Data([42]))
            #expect(peer.acceptedCount == 3)
        } catch {
            cancelledRequest?.cancel()
            await transport.close()
            peer.close()
            _ = try? await cancelledRequest?.value
            await peer.waitForCompletion()
            throw error
        }
        await transport.close()
        peer.close()
        await peer.waitForCompletion()
    }
}

/// Dedicated peer workers own all blocking I/O. Mutex protects owner publication,
/// counters and continuation registration; continuations resume outside that lock.
private final class WorkerHandoffPeer: @unchecked Sendable {
    private struct State {
        var connections: [JPIPTCPConnection] = []
        var accepted = 0
        var workers = 1
        var closed = false
        var sawCancel = false
        var requestEnded = false
        var cancelWaiter: CheckedContinuation<Void, Never>?
        var completionWaiter: CheckedContinuation<Void, Never>?
    }
    let listener: JPIPTCPListener
    private let state = Mutex(State())
    var url: URL { URL(string: "http://127.0.0.1:\(listener.boundPort)/jpip")! }
    var acceptedCount: Int { state.withLock { $0.accepted } }

    init() throws {
        listener = try JPIPTCPListener(host: "127.0.0.1", port: 0)
        let peer = self
        Thread.detachNewThread {
            defer { peer.finishedWorker() }
            while peer.listener.isOpen {
                // Explicit fixture close and the close/stale response branches own
                // accepted-socket lifetime; idle timeouts must not defeat reuse.
                guard let connection = try? peer.listener.acceptConnection(timeoutSeconds: 0) else { continue }
                let admitted = peer.state.withLock { state in
                    guard !state.closed else { return false }
                    state.connections.append(connection)
                    state.accepted += 1
                    state.workers += 1
                    return true
                }
                guard admitted else { connection.close(); break }
                Thread.detachNewThread {
                    defer { connection.close(); peer.finishedWorker() }
                    while connection.isOpen {
                        guard let request = try? connection.readHTTPRequest() else { return }
                        if request.target.contains("cancel") {
                            let waiter = peer.state.withLock { state in
                                state.sawCancel = true
                                let waiter = state.cancelWaiter
                                state.cancelWaiter = nil
                                return waiter
                            }
                            waiter?.resume()
                            continue // No response: the client must cancel this read.
                        }
                        if request.target.contains("oversized") {
                            try? connection.writeAll(Data("HTTP/1.1 200 OK\r\nContent-Length: 2048\r\nConnection: close\r\n\r\n".utf8))
                            return
                        }
                        let close = request.target.contains("close")
                        guard (try? connection.writeHTTPResponse(statusCode: 200, reasonPhrase: "OK",
                            headers: ["Connection": close ? "close" : "keep-alive"], body: Data([42]))) != nil else { return }
                        if close || request.target.contains("stale") { return }
                    }
                }
            }
        }
    }

    private func finishedWorker() {
        let waiter = state.withLock { state in
            state.workers -= 1
            guard state.workers == 0 else { return Optional<CheckedContinuation<Void, Never>>.none }
            let waiter = state.completionWaiter
            state.completionWaiter = nil
            return waiter
        }
        waiter?.resume()
    }
    func requestFinished() {
        let waiter = state.withLock { state in
            state.requestEnded = true
            let waiter = state.cancelWaiter
            state.cancelWaiter = nil
            return waiter
        }
        waiter?.resume()
    }
    func waitForCancellationRequest() async -> Bool {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.sawCancel || state.closed || state.requestEnded { return true }
                state.cancelWaiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
        return state.withLock { $0.sawCancel }
    }
    func waitForCompletion() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.workers == 0 { return true }
                state.completionWaiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }
    func close() {
        listener.close()
        let (connections, cancelWaiter) = state.withLock { state in
            state.closed = true
            let waiter = state.cancelWaiter
            state.cancelWaiter = nil
            return (state.connections, waiter)
        }
        cancelWaiter?.resume()
        for connection in connections { connection.close() }
    }
}
