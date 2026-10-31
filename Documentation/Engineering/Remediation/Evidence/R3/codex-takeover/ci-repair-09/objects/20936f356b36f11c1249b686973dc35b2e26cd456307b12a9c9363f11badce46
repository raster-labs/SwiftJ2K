// SPDX-License-Identifier: Apache-2.0
import Foundation
@testable import SwiftJ2KJPIP

/// Cooperative deterministic barriers: no thread blocking or sleeps for order.
actor TransportLifecycleProbe {
    private var counts: [JPIPTransportLifecycleEvent: Int] = [:]
    private var gated: Set<JPIPTransportLifecycleEvent>
    private var held: [JPIPTransportLifecycleEvent: CheckedContinuation<Void, Never>] = [:]
    private var arrivals: [JPIPTransportLifecycleEvent: [(Int, CheckedContinuation<Void, any Error>)]] = [:]
    private var abortError: (any Error)?

    init(gatingFirst events: Set<JPIPTransportLifecycleEvent> = []) { gated = events }

    func observe(_ event: JPIPTransportLifecycleEvent, _ id: UUID) async {
        guard abortError == nil else { return }
        counts[event, default: 0] += 1
        let count = counts[event, default: 0]
        let ready = arrivals[event, default: []].filter { $0.0 <= count }
        arrivals[event] = arrivals[event, default: []].filter { $0.0 > count }
        for (_, waiter) in ready { waiter.resume() }
        if gated.remove(event) != nil {
            await withCheckedContinuation { held[event] = $0 }
        }
    }

    func wait(_ event: JPIPTransportLifecycleEvent, count: Int = 1,
              onWaiting: (@Sendable () -> Void)? = nil) async throws {
        if let abortError { throw abortError }
        if counts[event, default: 0] >= count { return }
        try await withCheckedThrowingContinuation { continuation in
            arrivals[event, default: []].append((count, continuation))
            // A nonblocking test observation proves a waiter is installed before
            // injecting startup failure; production lifecycle callbacks do not use it.
            onWaiting?()
        }
    }
    func count(_ event: JPIPTransportLifecycleEvent) -> Int { counts[event, default: 0] }
    func release(_ event: JPIPTransportLifecycleEvent) { held.removeValue(forKey: event)?.resume() }

    func track<Result: Sendable>(_ operation: @Sendable () async throws -> Result) async throws -> Result {
        do { return try await operation() }
        catch {
            // Unexpected startup failures must fail the owning test, not leave
            // it waiting forever for a lifecycle event that can no longer occur.
            if abortError == nil { abortError = error }
            gated.removeAll()
            let waiting = arrivals.values.flatMap { $0.map { $0.1 } }
            let releasing = Array(held.values)
            arrivals.removeAll(); held.removeAll()
            for waiter in waiting { waiter.resume(throwing: abortError ?? error) }
            for waiter in releasing { waiter.resume() }
            throw error
        }
    }
}
