// SPDX-License-Identifier: MIT
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
        var gates: Set<String> = []
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

    func openGate(_ name: String) {
        let elapsed = ContinuousClock.now - origin
        state.withLock {
            $0.gates.insert(name)
            if $0.timeline.count < 64 { $0.timeline.append("\(elapsed): gate.open.\(name)") }
        }
    }

    @discardableResult
    func waitForGate(_ name: String, timeout: Duration = .seconds(5)) -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            let ready = state.withLock { $0.closing || $0.gates.contains(name) }
            if ready { return true }
            if ContinuousClock.now >= deadline {
                mark("gate.timeout.\(name)")
                return false
            }
            Thread.sleep(forTimeInterval: 0.002)
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
        await JPIPTestCooperativeQuiescence.settle()
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

/// Waits for the initial full-workspace Swift Testing startup burst of synchronous CPU-bound
/// codec tasks (`SwiftJ2KTests`, `SwiftJ2K3DTests`) on a 3-vCPU runner to drain from the global
/// cooperative FIFO queue before a test starts its operation deadline clock.
/// Called only once before a test creates its client/peer or starts its deadline clock; never
/// called between overlapping child tasks within a test, and never alters any deadline or assertion.
enum JPIPTestCooperativeQuiescence {
    private static let activeHeavyCodecWork = Mutex<Int>(0)
    private enum CFNetworkWarmupState {
        case idle
        case warming([CheckedContinuation<Void, Never>])
        case warm
    }
    private static let warmupState = Mutex<CFNetworkWarmupState>(.idle)
    private static let warmupQueue = DispatchQueue(
        label: "com.rasterlab.swiftj2k.jpip.test-cfnetwork-warmup",
        qos: .userInitiated
    )

    private final class WarmupProtocol: URLProtocol {
        override class func canInit(with request: URLRequest) -> Bool {
            request.url?.host == "jpip-warmup.invalid"
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            if let url = request.url,
               let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil) {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private final class WarmupDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        // SAFETY: finished is mutated at most once under lock before resuming waiters.
        private let lock = NSLock()
        private var finished = false
        private let onFinish: @Sendable () -> Void

        init(onFinish: @escaping @Sendable () -> Void) {
            self.onFinish = onFinish
            super.init()
        }

        func completeOnce() {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            lock.unlock()
            onFinish()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            session.finishTasksAndInvalidate()
        }

        func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
            completeOnce()
        }
    }

    /// Pre-warms CFNetwork's ephemeral `URLSession` XPC/TLS subsystem off the Swift Concurrency
    /// cooperative pool once per test process so cold iOS Simulator `URLSession.init` (~2.4s)
    /// completes before any test stamps its operation deadline clock.
    private static func warmUpCFNetworkOnce() async {
        let alreadyWarm = warmupState.withLock { state -> Bool in
            if case .warm = state { return true }
            return false
        }
        if alreadyWarm { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let shouldStart = warmupState.withLock { state -> Bool in
                switch state {
                case .idle:
                    state = .warming([continuation])
                    return true
                case .warming(var waiters):
                    waiters.append(continuation)
                    state = .warming(waiters)
                    return false
                case .warm:
                    continuation.resume()
                    return false
                }
            }
            guard shouldStart else { return }

            warmupQueue.async {
                let delegate = WarmupDelegate {
                    let waiters = warmupState.withLock { state -> [CheckedContinuation<Void, Never>] in
                        let pending: [CheckedContinuation<Void, Never>]
                        if case .warming(let list) = state {
                            pending = list
                        } else {
                            pending = []
                        }
                        state = .warm
                        return pending
                    }
                    for waiter in waiters {
                        waiter.resume()
                    }
                }
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                queue.qualityOfService = .userInitiated
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [WarmupProtocol.self]
                config.timeoutIntervalForRequest = 5
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: queue)
                if let url = URL(string: "https://jpip-warmup.invalid/warmup") {
                    session.dataTask(with: url).resume()
                } else {
                    session.finishTasksAndInvalidate()
                }
                warmupQueue.asyncAfter(deadline: .now() + .seconds(10)) {
                    delegate.completeOnce()
                }
            }
        }
    }

    static func beginHeavyCodecWork() {
        activeHeavyCodecWork.withLock { $0 += 1 }
    }

    static func endHeavyCodecWork() {
        activeHeavyCodecWork.withLock { $0 = max(0, $0 - 1) }
    }

    static func settle() async {
        await warmUpCFNetworkOnce()
        let maxWait = ContinuousClock.now.advanced(by: .seconds(50))
        var fastRounds = 0
        while fastRounds < 6 && ContinuousClock.now < maxWait {
            if activeHeavyCodecWork.withLock({ $0 > 0 }) {
                fastRounds = 0
                try? await Task.sleep(for: .milliseconds(15))
                continue
            }
            let t0 = ContinuousClock.now
            await Task { }.value
            let hop = ContinuousClock.now - t0
            if hop < .milliseconds(8) && activeHeavyCodecWork.withLock({ $0 == 0 }) {
                fastRounds += 1
                try? await Task.sleep(for: .milliseconds(15))
            } else {
                fastRounds = 0
            }
        }
    }
}
