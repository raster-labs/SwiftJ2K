// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization

package protocol JPIPTransportRequestOwner: AnyObject, Sendable {
    func cancelForTransportClose()
    func waitForCompletion() async
    var isFinished: Bool { get }
}

/// Completion-only broadcast; joining never consumes the sender's owning result.
package final class JPIPRequestCompletion: Sendable {
    private struct State {
        var finished = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let state = Mutex(State())
    package var isFinished: Bool { state.withLock { $0.finished } }

    package func finish() {
        let waiters = state.withLock { state in
            guard !state.finished else { return [CheckedContinuation<Void, Never>]() }
            state.finished = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    package func wait() async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state in
                if state.finished { return true }
                state.waiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}

/// The token owns any connecting/current socket; completion acknowledges all
/// finite worker I/O and locked result publication. Opaque DNS may still delay
/// that worker: close joins it and makes no universal resolver-latency promise.
package final class JPIPHTTPRequestOwner: JPIPTransportRequestOwner, Sendable {
    private struct State { var began = false; var cancelled = false }
    private let state = Mutex(State())
    private let completion = JPIPRequestCompletion()
    private let cancellation = Mutex(())
    package let token = JPIPSocketCancellationToken()
    package var isFinished: Bool { completion.isFinished }

    package func beginWorker() -> Bool {
        state.withLock { state in
            guard !state.cancelled, !state.began else { return false }
            state.began = true
            return true
        }
    }

    package func cancelForTransportClose() {
        let neverStarted = state.withLock { state in
            state.cancelled = true
            return !state.began
        }
        // Concurrent task/watchdog/transport cancellation must also acknowledge
        // a preceding token.cancel's captured connection.close before returning.
        cancellation.withLock { _ in token.cancel() }
        if neverStarted { completion.finish() }
    }
    package func workerFinished() { completion.finish() }
    package func waitForCompletion() async { await completion.wait() }
}

/// Internal deterministic lifecycle observations. Production observers are nil.
package enum JPIPTransportLifecycleEvent: Hashable, Sendable {
    case registered, beforePublication, closeJoining, closeJoined
}
