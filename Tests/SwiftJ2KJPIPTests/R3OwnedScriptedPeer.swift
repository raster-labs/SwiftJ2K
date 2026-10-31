// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
@testable import SwiftJ2KJPIP

/// A scripted test peer with explicitly owned blocking workers and bounded diagnostics.
/// Completion observes the workers' final publication, not physical OS-thread exit.
final class R3OwnedScriptedPeer: Sendable {
    private struct State {
        var closing = false
        var acceptFinished = false
        var workers = 0
        var connections: [Int: JPIPTCPConnection] = [:]
        var phases: Set<String> = []
        var timeline: [String] = []
        var failures: [String] = []
    }

    private let listener: JPIPTCPListener
    private let state = Mutex(State())
    private let origin = ContinuousClock.now

    var port: Int { listener.boundPort }

    init(connections: Int,
         operation: @escaping @Sendable (JPIPTCPConnection, Int, R3OwnedScriptedPeer) throws -> Void) throws {
        precondition(connections > 0)
        listener = try JPIPTCPListener(host: "127.0.0.1", port: 0)
        let acceptThread = Thread { [self] in
            defer {
                mark("accept.finished")
                state.withLock { $0.acceptFinished = true }
            }
            mark("accept.started")
            do {
                for index in 1...connections {
                    // This argument configures accepted-socket idle I/O expiry;
                    // explicit fixture close owns their lifetime instead.
                    guard let connection = try listener.acceptConnection(timeoutSeconds: 0) else { break }
                    let admitted = state.withLock { value in
                        guard !value.closing else { return false }
                        value.connections[index] = connection
                        value.workers += 1
                        return true
                    }
                    guard admitted else { connection.close(); break }
                    mark("accepted.\(index)")
                    let worker = Thread { [self] in
                        defer {
                            mark("worker.finished.\(index)")
                            state.withLock { $0.workers -= 1 }
                        }
                        do { try operation(connection, index, self) }
                        catch { recordFailure("peer.\(index): \(error)") }
                    }
                    worker.qualityOfService = .userInitiated
                    worker.start()
                }
            } catch { recordFailure("accept: \(error)") }
        }
        acceptThread.qualityOfService = .userInitiated
        acceptThread.start()
    }

    deinit { close() }

    func mark(_ phase: String) {
        let elapsed = ContinuousClock.now - origin
        state.withLock {
            $0.phases.insert(phase)
            if $0.timeline.count < 64 { $0.timeline.append("\(elapsed): \(phase)") }
        }
    }

    func recordFailure(_ message: String) {
        state.withLock { if $0.failures.count < 8 { $0.failures.append(message) } }
    }

    /// An operation that fails before its expected request reaches the peer must
    /// fail readiness, rather than leave the test waiting for a fabricated arrival.
    func recordClientFailure(_ error: any Error, before phase: String) {
        state.withLock {
            if !$0.phases.contains(phase), $0.failures.count < 8 {
                $0.failures.append("Client failed before \(phase): \(error)")
            }
        }
    }

    var diagnostics: String {
        state.withLock {
            "phases=[\($0.timeline.joined(separator: "; "))]; errors=[\($0.failures.joined(separator: "; "))]; closing=\($0.closing), acceptFinished=\($0.acceptFinished), workers=\($0.workers)"
        }
    }

    var failures: [String] { state.withLock { $0.failures } }

    /// Startup is protected before callers create their client operation. A
    /// failed readiness wait must also close and observe this peer's workers.
    func waitForStartup() async throws {
        do { try await waitFor("accept.started") }
        catch {
            let stopped = await stopAndObserve()
            throw R3ScriptedPeerFailure("Peer startup failed: \(error); stopped=\(stopped); \(diagnostics)")
        }
    }

    func waitFor(_ phase: String) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while true {
            let observation = state.withLock { ($0.phases.contains(phase), $0.failures.first) }
            if observation.0 { return }
            if let failure = observation.1 {
                throw R3ScriptedPeerFailure("Readiness \(phase) failed: \(failure); \(diagnostics)")
            }
            guard ContinuousClock.now < deadline else {
                throw R3ScriptedPeerFailure("Readiness \(phase) timed out; \(diagnostics)")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func close() {
        let connections = state.withLock { value -> [JPIPTCPConnection] in
            value.closing = true
            let connections = Array(value.connections.values)
            value.connections.removeAll()
            return connections
        }
        listener.close()
        for connection in connections { connection.close() }
    }

    /// Bounded asynchronous observation; a false result remains visible to the
    /// caller. Worker captures keep the owners alive through their final defer.
    func stopAndObserve() async -> Bool {
        close()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while true {
            if state.withLock({ $0.acceptFinished && $0.workers == 0 }) { return true }
            guard ContinuousClock.now < deadline else { mark("stop.observation.timedOut"); return false }
            do { try await Task.sleep(for: .milliseconds(5)) }
            catch { mark("stop.observation.cancelled"); return false }
        }
    }
}

struct R3ScriptedPeerFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
