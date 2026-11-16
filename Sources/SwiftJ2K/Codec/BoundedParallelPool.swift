// SPDX-License-Identifier: MIT
import Dispatch
import Foundation
import Synchronization

/// Narrow pointer wrapper used strictly within synchronous scoped borrows (`withUnsafeBufferPointer`)
/// where parallel workers read from immutable memory (`MEM-08`, `CONC-03`).
internal struct UnsafeSendableBuffer<Element>: @unchecked Sendable {
    internal let base: UnsafePointer<Element>?
    internal let count: Int

    @inline(__always)
    internal init(_ buffer: UnsafeBufferPointer<Element>) {
        self.base = buffer.baseAddress
        self.count = buffer.count
    }

    @inline(__always)
    internal var baseAddress: UnsafePointer<Element> { base! }

    @inline(__always)
    internal subscript(index: Int) -> Element {
        base![index]
    }
}

/// Narrow mutable pointer wrapper used strictly within synchronous scoped borrows
/// (`withUnsafeMutableBufferPointer`) where each job writes to provably disjoint index ranges
/// (`MEM-08`, `CONC-03`).
internal struct UnsafeSendableMutableBuffer<Element>: @unchecked Sendable {
    internal let base: UnsafeMutablePointer<Element>?
    internal let count: Int

    @inline(__always)
    internal init(_ buffer: UnsafeMutableBufferPointer<Element>) {
        self.base = buffer.baseAddress
        self.count = buffer.count
    }

    @inline(__always)
    internal var baseAddress: UnsafeMutablePointer<Element> { base! }

    @inline(__always)
    internal subscript(index: Int) -> Element {
        get { base![index] }
        nonmutating set { base![index] = newValue }
    }
}

/// Narrow raw pointer wrapper used strictly within synchronous scoped borrows (`withUnsafeBytes`)
/// where parallel workers read from immutable memory (`MEM-08`, `CONC-03`).
internal struct UnsafeSendableRawPointer: @unchecked Sendable {
    internal let baseAddress: UnsafeRawPointer
    internal let count: Int

    @inline(__always)
    internal init(baseAddress: UnsafeRawPointer, count: Int) {
        self.baseAddress = baseAddress
        self.count = count
    }
}

/// Narrow mutable raw pointer wrapper used strictly within synchronous scoped borrows
/// (`destination.write`) where each job writes to provably disjoint row byte ranges (`MEM-08`, `CONC-03`).
internal struct UnsafeSendableMutableRawPointer: @unchecked Sendable {
    internal let baseAddress: UnsafeMutableRawPointer
    internal let count: Int

    @inline(__always)
    internal init(baseAddress: UnsafeMutableRawPointer, count: Int) {
        self.baseAddress = baseAddress
        self.count = count
    }
}

/// Thread-safe error capture box retaining the earliest thrown error across parallel workers.
internal final class FirstErrorBox: Sendable {
    private let mutex = Mutex<(any Error)?>(nil)
    private let hasErrorFlag = Atomic<Bool>(false)

    internal init() {}

    @inline(__always)
    internal var hasError: Bool {
        hasErrorFlag.load(ordering: .relaxed)
    }

    internal func storeIfFirst(_ error: any Error) {
        mutex.withLock { slot in
            if slot == nil {
                slot = error
                hasErrorFlag.store(true, ordering: .releasing)
            } else if error is CancellationError, !(slot is CancellationError) {
                slot = error
            }
        }
    }

    internal func rethrowIfNeeded() throws {
        if hasErrorFlag.load(ordering: .acquiring) {
            let err = mutex.withLock { $0 }
            if let err {
                throw err
            }
        }
    }
}

/// Bounded work-stealing parallel executor honoring `ResourceLimits.maximumWorkers`.
///
/// Provides both:
/// - **Structured Swift Concurrency** (`forEachAsync`) via bounded `withThrowingTaskGroup`
///   for `async` operations (`Encoder.encode`, `Decoder.decode`, `Transcoder.transcode`).
/// - **Zero-hop synchronous parallelism** (`forEach`) via bounded `DispatchQueue.concurrentPerform`
///   with `@TaskLocal` context propagation for synchronous operations (`*Synchronously`) and
///   in-place SIMD kernels.
internal enum BoundedParallelPool {
    @TaskLocal internal static var isInsideParallelRegion: Bool = false

    private struct TaskLocalSnapshot: @unchecked Sendable {
        let tracker: AcceleratedCodec.ExecutionTracker?
        let forceMetalDispatch: Bool
        let workerLimit: Int
        let forceUnavailable: Bool
        let forceMetalUnavailable: Bool
        let storageRecorder: StorageTelemetry.Recorder?
        let entropyRecorder: EntropyAllocationTelemetry.Recorder?
        let sharedMutation: SharedPathMutation
        let hasTestOverrides: Bool

        @inline(__always)
        init() {
            self.tracker = AcceleratedCodec.activeTracker
            self.forceMetalDispatch = AcceleratedCodec.forceMetalDispatchTaskLocal
            self.workerLimit = AcceleratedCodec.activeWorkerLimit
            self.forceUnavailable = AccelerationRuntime.forceUnavailable
            self.forceMetalUnavailable = AccelerationRuntime.forceMetalUnavailable
            self.storageRecorder = StorageTelemetry.recorder
            self.entropyRecorder = EntropyAllocationTelemetry.recorder
            self.sharedMutation = SharedPathMutation.active
            self.hasTestOverrides =
                forceMetalDispatch ||
                forceUnavailable ||
                forceMetalUnavailable ||
                storageRecorder != nil ||
                entropyRecorder != nil ||
                sharedMutation != .none
        }

        @inline(__always)
        func run(_ body: () -> Void) {
            if !hasTestOverrides {
                BoundedParallelPool.$isInsideParallelRegion.withValue(true) {
                    AcceleratedCodec.$activeWorkerLimit.withValue(workerLimit) {
                        if let tracker {
                            AcceleratedCodec.$activeTracker.withValue(tracker, operation: body)
                        } else {
                            body()
                        }
                    }
                }
                return
            }
            BoundedParallelPool.$isInsideParallelRegion.withValue(true) {
                AcceleratedCodec.$activeTracker.withValue(tracker) {
                    AcceleratedCodec.$forceMetalDispatchTaskLocal.withValue(forceMetalDispatch) {
                        AcceleratedCodec.$activeWorkerLimit.withValue(workerLimit) {
                            AccelerationRuntime.$forceUnavailable.withValue(forceUnavailable) {
                                AccelerationRuntime.$forceMetalUnavailable.withValue(forceMetalUnavailable) {
                                    StorageTelemetry.$recorder.withValue(storageRecorder) {
                                        EntropyAllocationTelemetry.$recorder.withValue(entropyRecorder) {
                                            SharedPathMutation.$active.withValue(sharedMutation, operation: body)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @inline(__always)
    internal static func effectiveWorkers(requested: Int, jobCount: Int) -> Int {
        if isInsideParallelRegion || requested <= 1 || jobCount <= 1 {
            return 1
        }
        return min(requested, jobCount)
    }

    @inline(__always)
    internal static func forEachNonThrowing(
        jobCount: Int,
        maxWorkers: Int,
        body: @Sendable (_ jobIndex: Int) -> Void
    ) {
        forEachNonThrowing(jobCount: jobCount, maxWorkers: maxWorkers) { jobIndex, _ in
            body(jobIndex)
        }
    }

    /// Executes `0..<jobCount` across at most `maxWorkers` synchronous threads to completion without
    /// cancellation checks, guaranteeing every index in `0..<jobCount` runs exactly once.
    /// Required for non-throwing in-place SIMD kernels and `Array(unsafeUninitializedCapacity:)` initializers.
    internal static func forEachNonThrowing(
        jobCount: Int,
        maxWorkers: Int,
        body: @Sendable (_ jobIndex: Int, _ workerIndex: Int) -> Void
    ) {
        guard jobCount > 0 else { return }
        let workers = effectiveWorkers(requested: maxWorkers, jobCount: jobCount)
        if workers <= 1 {
            for index in 0..<jobCount {
                body(index, 0)
            }
            return
        }

        let snapshot = TaskLocalSnapshot()
        let cursor = Atomic<Int>(0)

        DispatchQueue.concurrentPerform(iterations: workers) { workerIndex in
            snapshot.run {
                while true {
                    let job = cursor.wrappingAdd(1, ordering: .relaxed).oldValue
                    if job >= jobCount { break }
                    body(job, workerIndex)
                }
            }
        }
    }

    @inline(__always)
    internal static func forEach(
        jobCount: Int,
        maxWorkers: Int,
        body: @Sendable (_ jobIndex: Int) throws -> Void
    ) throws {
        try forEach(jobCount: jobCount, maxWorkers: maxWorkers) { jobIndex, _ in
            try body(jobIndex)
        }
    }

    /// Executes `0..<jobCount` across at most `maxWorkers` synchronous threads.
    /// When `effectiveWorkers <= 1`, executes inline on the calling thread with zero overhead.
    internal static func forEach(
        jobCount: Int,
        maxWorkers: Int,
        body: @Sendable (_ jobIndex: Int, _ workerIndex: Int) throws -> Void
    ) throws {
        guard jobCount > 0 else { return }
        let workers = effectiveWorkers(requested: maxWorkers, jobCount: jobCount)
        if workers <= 1 {
            for index in 0..<jobCount {
                try body(index, 0)
            }
            return
        }

        try Task.checkCancellation()
        let parentCancelled = Task.isCancelled
        if parentCancelled {
            throw CancellationError()
        }

        let snapshot = TaskLocalSnapshot()
        let cursor = Atomic<Int>(0)
        let errorBox = FirstErrorBox()

        DispatchQueue.concurrentPerform(iterations: workers) { workerIndex in
            if errorBox.hasError { return }
            snapshot.run {
                while !errorBox.hasError {
                    let job = cursor.wrappingAdd(1, ordering: .relaxed).oldValue
                    if job >= jobCount { break }
                    do {
                        try body(job, workerIndex)
                    } catch {
                        errorBox.storeIfFirst(error)
                        break
                    }
                }
            }
        }

        try errorBox.rethrowIfNeeded()
        try Task.checkCancellation()
    }

    /// Executes `0..<jobCount` across at most `maxWorkers` child tasks using Swift Structured
    /// Concurrency (`withThrowingTaskGroup`), automatically propagating `@TaskLocal` values and
    /// cooperative task cancellation.
    internal static func forEachAsync(
        jobCount: Int,
        maxWorkers: Int,
        body: @escaping @Sendable (_ jobIndex: Int, _ workerIndex: Int) throws -> Void
    ) async throws {
        guard jobCount > 0 else { return }
        let workers = effectiveWorkers(requested: maxWorkers, jobCount: jobCount)
        if workers <= 1 {
            try Task.checkCancellation()
            for index in 0..<jobCount {
                try body(index, 0)
            }
            return
        }

        try Task.checkCancellation()
        let cursor = Atomic<Int>(0)
        let abortFlag = Atomic<Bool>(false)

        try await $isInsideParallelRegion.withValue(true) {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for workerIndex in 0..<workers {
                    group.addTask {
                        while !abortFlag.load(ordering: .relaxed) {
                            try Task.checkCancellation()
                            let job = cursor.wrappingAdd(1, ordering: .relaxed).oldValue
                            if job >= jobCount { break }
                            do {
                                try body(job, workerIndex)
                            } catch {
                                abortFlag.store(true, ordering: .releasing)
                                throw error
                            }
                        }
                    }
                }
                do {
                    try await group.waitForAll()
                } catch {
                    abortFlag.store(true, ordering: .releasing)
                    group.cancelAll()
                    throw error
                }
            }
        }
    }
}
