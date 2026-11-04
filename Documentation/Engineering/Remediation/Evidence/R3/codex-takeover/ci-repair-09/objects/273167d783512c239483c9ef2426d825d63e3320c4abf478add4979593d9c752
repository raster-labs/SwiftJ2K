// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import SwiftJ2K

/// Publishes a finite blocking worker's owning result through an explicit lock.
/// The handoff is created before the thread starts. The producer finishes all
/// result construction, stores under the mutex, and only then signals completion.
/// The consumer acquires the same mutex after awaiting that signal, before using
/// any returned owner (including an unchecked-Sendable socket's lock objects).
/// The continuation carries no result references and supplies only a wake-up.
package enum JPIPBlockingWorker {
    package static func run<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let handoff = JPIPWorkerHandoff<Value>()
        await withCheckedContinuation { (completion: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                handoff.publish(Result(catching: operation))
                completion.resume()
            }
        }
        return try handoff.take()
    }
}

private final class JPIPWorkerHandoff<Value: Sendable>: Sendable {
    private let result = Mutex<Result<Value, any Error>?>(nil)

    func publish(_ completed: Result<Value, any Error>) {
        result.withLock { $0 = completed }
    }

    func take() throws -> Value {
        let completed = result.withLock { stored in
            let completed = stored
            stored = nil
            return completed
        }
        guard let completed else {
            throw CodecError(.internalFailure, "JPIP worker completed without publishing its result.")
        }
        return try completed.get()
    }
}
