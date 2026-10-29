// SPDX-License-Identifier: Apache-2.0
//
// JP3DSliceStackCodec.swift
// SwiftJ2K3D
//
// Migrated from Raster-Lab/J2KSwift Sources/J2K3D/JP3DSliceStackCodec.swift
// at commit 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca.
//
// Changes relative to the predecessor:
//   - Delegated per-slice 2D encoding, decoding, and lossless transcoding to
//     SwiftJ2K's Part 1 and Part 15 (HTJ2K) pipelines via Slice2DBridge and Transcoder.
//   - Encoded Z-delta residual slices as signed 16-bit values so small negative
//     inter-slice residuals do not wrap across 65535, while preserving backward
//     compatibility with unsigned v2 residual streams on decode.
//   - Added transcodeTile(_:toHTJ2K:limits:executionPolicy:) for wavelet-domain
//     slice-stack transcoding without inverse/forward DWT or Z-delta reconstruction.
//   - Hardened J3DS header parsing with checked integer arithmetic.

import Foundation
import Synchronization
import SwiftJ2K

/// Cooperative cancellation and monotonic deadline guard for volumetric operations.
internal struct VolumeWorkGuard: Sendable {
    private let deadline: ContinuousClock.Instant?

    init(limits: ResourceLimits?) {
        if let limits {
            self.deadline = ContinuousClock.now.advanced(by: .seconds(limits.deadlineSeconds))
        } else {
            self.deadline = nil
        }
    }

    func check() throws {
        try Task.checkCancellation()
        if let deadline, ContinuousClock.now > deadline {
            throw CodecError(.resourceLimitExceeded, "Volumetric operation deadline elapsed.")
        }
    }
}

/// Package-scoped concurrency and live-budget telemetry used by tests to observe peak in-flight worker tasks and simultaneous memory reservations.
package enum VolumeConcurrencyTelemetry {
    /// Cancellation-safe single-open async phase barrier for deterministic multi-worker test coordination without timing sleeps.
    package final class PhaseGate: Sendable {
        private struct State: Sendable {
            var isOpen = false
            var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        }
        private let state = Mutex(State())

        package init() {}

        package var isOpen: Bool {
            state.withLock { $0.isOpen }
        }

        package func open() {
            let continuations: [CheckedContinuation<Void, Never>] = state.withLock { st in
                guard !st.isOpen else { return [] }
                st.isOpen = true
                let all = Array(st.waiters.values)
                st.waiters.removeAll()
                return all
            }
            for cont in continuations {
                cont.resume()
            }
        }

        package func wait() async {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    let resumeNow = state.withLock { st -> Bool in
                        if st.isOpen || Task.isCancelled {
                            return true
                        }
                        st.waiters[id] = cont
                        return false
                    }
                    if resumeNow {
                        cont.resume()
                    }
                }
            } onCancel: {
                let removed = state.withLock { st in
                    st.waiters.removeValue(forKey: id)
                }
                removed?.resume()
            }
        }
    }

    /// Cancellation-safe N-party rendezvous barrier built atop `PhaseGate`.
    package final class RendezvousBarrier: Sendable {
        private let targetParties: Int
        private let arrivedCount = Mutex(0)
        private let gate = PhaseGate()

        package init(parties: Int) {
            self.targetParties = max(1, parties)
        }

        package func arriveAndWait() async {
            let reached = arrivedCount.withLock { count -> Bool in
                count += 1
                return count >= targetParties
            }
            if reached {
                gate.open()
            } else {
                await gate.wait()
            }
        }

        package func open() {
            gate.open()
        }
    }

    package struct Snapshot: Sendable, Equatable {
        package let currentInFlight: Int
        package let liveScratchBytes: Int
        package let liveTransientBytes: Int
        package let liveOutputBytes: Int
        package let retainedBytes: Int
        package let releasedOutputBytes: Int

        package init(
            currentInFlight: Int,
            liveScratchBytes: Int,
            liveTransientBytes: Int,
            liveOutputBytes: Int,
            retainedBytes: Int,
            releasedOutputBytes: Int = 0
        ) {
            self.currentInFlight = currentInFlight
            self.liveScratchBytes = liveScratchBytes
            self.liveTransientBytes = liveTransientBytes
            self.liveOutputBytes = liveOutputBytes
            self.retainedBytes = retainedBytes
            self.releasedOutputBytes = releasedOutputBytes
        }
    }

    package final class Recorder: Sendable {
        /// Pure value-only leaf state (`Recorder.state` never holds object references or invokes external closures/locks).
        private struct State: Sendable {
            var current = 0
            var peak = 0
            var totalStarted = 0
            var liveScratchBytes = 0
            var peakScratchBytes = 0
            var liveTransientBytes = 0
            var peakTransientBytes = 0
            var liveOutputBytes = 0
            var peakOutputBytes = 0
            var retainedBytes = 0
            var releasedOutputBytes = 0
            var peakLiveWorkspaceBytes = 0
            var lastBudgetRevision: UInt64 = 0
            var staleBudgetUpdatesIgnored = 0
            var postDelaySnapshots: [Int: Snapshot] = [:]
        }
        private let state = Mutex(State())
        /// Cycle-free value-only authoritative state box (`StateStorage` holds only primitive counters and never retains `JP3DLiveBudgetTracker` or `Recorder`).
        private let attachedStateStorage = Mutex<JP3DLiveBudgetTracker.StateStorage?>(nil)
        private let artificialDelayMilliseconds: Int
        private let workerDelayForTile: (@Sendable (Int) -> Int)?
        private let parentConsumeDelayMilliseconds: Int
        private let parentConsumeDelayForStep: (@Sendable (Int) -> Int)?
        private let onWorkerEnter: (@Sendable (_ tileIndex: Int?, _ recorder: Recorder) async throws -> Void)?
        private let onWorkerExit: (@Sendable (_ tileIndex: Int?) -> Void)?
        private let onChildTaskReturned: (@Sendable (_ tileIndex: Int) -> Void)?
        private let onBeforeParentConsume: (@Sendable (_ step: Int, _ recorder: Recorder) async throws -> Void)?

        package init(
            artificialDelayMilliseconds: Int = 0,
            workerDelayForTile: (@Sendable (Int) -> Int)? = nil,
            parentConsumeDelayMilliseconds: Int = 0,
            parentConsumeDelayForStep: (@Sendable (Int) -> Int)? = nil,
            onWorkerEnter: (@Sendable (_ tileIndex: Int?, _ recorder: Recorder) async throws -> Void)? = nil,
            onWorkerExit: (@Sendable (_ tileIndex: Int?) -> Void)? = nil,
            onChildTaskReturned: (@Sendable (_ tileIndex: Int) -> Void)? = nil,
            onBeforeParentConsume: (@Sendable (_ step: Int, _ recorder: Recorder) async throws -> Void)? = nil
        ) {
            self.artificialDelayMilliseconds = max(0, artificialDelayMilliseconds)
            self.workerDelayForTile = workerDelayForTile
            self.parentConsumeDelayMilliseconds = max(0, parentConsumeDelayMilliseconds)
            self.parentConsumeDelayForStep = parentConsumeDelayForStep
            self.onWorkerEnter = onWorkerEnter
            self.onWorkerExit = onWorkerExit
            self.onChildTaskReturned = onChildTaskReturned
            self.onBeforeParentConsume = onBeforeParentConsume
        }

        package var currentInFlight: Int { state.withLock { $0.current } }
        package var peakInFlight: Int { state.withLock { $0.peak } }
        package var totalTasksStarted: Int { state.withLock { $0.totalStarted } }
        package var liveScratchBytes: Int { state.withLock { $0.liveScratchBytes } }
        package var peakScratchBytes: Int { state.withLock { $0.peakScratchBytes } }
        package var liveTransientBytes: Int { state.withLock { $0.liveTransientBytes } }
        package var peakTransientBytes: Int { state.withLock { $0.peakTransientBytes } }
        package var liveOutputBytes: Int { state.withLock { $0.liveOutputBytes } }
        package var peakOutputBytes: Int { state.withLock { $0.peakOutputBytes } }
        package var retainedBytes: Int { state.withLock { $0.retainedBytes } }
        package var releasedOutputBytes: Int { state.withLock { $0.releasedOutputBytes } }
        package var peakLiveWorkspaceBytes: Int { state.withLock { $0.peakLiveWorkspaceBytes } }
        package var lastBudgetRevision: UInt64 { state.withLock { $0.lastBudgetRevision } }
        package var staleBudgetUpdatesIgnored: Int { state.withLock { $0.staleBudgetUpdatesIgnored } }

        package var authoritativeLiveScratchBytes: Int? {
            attachedStateStorage.withLock { $0 }?.currentScratchBytes
        }
        package var authoritativeLiveOutputBytes: Int? {
            attachedStateStorage.withLock { $0 }?.currentOutputBytes
        }
        package var authoritativeLiveTransientBytes: Int? {
            attachedStateStorage.withLock { $0 }?.currentTransientBytes
        }
        package var authoritativeRetainedBytes: Int? {
            attachedStateStorage.withLock { $0 }?.currentRetainedBytes
        }
        package var authoritativeReleasedOutputBytes: Int? {
            attachedStateStorage.withLock { $0 }?.currentReleasedOutputBytes
        }

        package func currentSnapshot() -> Snapshot {
            state.withLock { s in
                Snapshot(
                    currentInFlight: s.current,
                    liveScratchBytes: s.liveScratchBytes,
                    liveTransientBytes: s.liveTransientBytes,
                    liveOutputBytes: s.liveOutputBytes,
                    retainedBytes: s.retainedBytes,
                    releasedOutputBytes: s.releasedOutputBytes
                )
            }
        }

        package func snapshotAfterEnterDelay(forTile tileIndex: Int) -> Snapshot? {
            state.withLock { $0.postDelaySnapshots[tileIndex] }
        }

        internal func attachBudgetStateStorage(_ storage: JP3DLiveBudgetTracker.StateStorage) {
            attachedStateStorage.withLock { $0 = storage }
        }

        package func allocateBudgetRevision() -> UInt64 {
            JP3DLiveBudgetTracker.allocateRevision()
        }

        internal func enter(tileIndex: Int? = nil) async throws {
            state.withLock {
                $0.current += 1
                $0.totalStarted += 1
                if $0.current > $0.peak {
                    $0.peak = $0.current
                }
            }
            let delayMs: Int
            if let tileIndex, let workerDelayForTile {
                delayMs = max(0, workerDelayForTile(tileIndex))
            } else {
                delayMs = artificialDelayMilliseconds
            }
            if delayMs > 0 {
                try await Task.sleep(for: .milliseconds(delayMs))
            }
            if let onWorkerEnter {
                try await onWorkerEnter(tileIndex, self)
            }
            if let tileIndex {
                state.withLock { s in
                    s.postDelaySnapshots[tileIndex] = Snapshot(
                        currentInFlight: s.current,
                        liveScratchBytes: s.liveScratchBytes,
                        liveTransientBytes: s.liveTransientBytes,
                        liveOutputBytes: s.liveOutputBytes,
                        retainedBytes: s.retainedBytes,
                        releasedOutputBytes: s.releasedOutputBytes
                    )
                }
            }
        }

        internal func beforeParentConsume(step: Int) async throws {
            let delayMs = max(0, parentConsumeDelayForStep?(step) ?? parentConsumeDelayMilliseconds)
            if delayMs > 0 {
                try await Task.sleep(for: .milliseconds(delayMs))
            }
            if let onBeforeParentConsume {
                try await onBeforeParentConsume(step, self)
            }
        }

        internal func exit(tileIndex: Int? = nil) {
            state.withLock {
                $0.current = max(0, $0.current - 1)
            }
            onWorkerExit?(tileIndex)
        }

        internal func recordChildTaskReturned(tileIndex: Int) {
            onChildTaskReturned?(tileIndex)
        }

        package func recordBudgetUpdate(
            revision: UInt64,
            liveScratch: Int = 0,
            liveTransient: Int,
            liveOutput: Int = 0,
            retained: Int,
            releasedOutput: Int = 0
        ) {
            state.withLock {
                if liveScratch > $0.peakScratchBytes {
                    $0.peakScratchBytes = liveScratch
                }
                if liveTransient > $0.peakTransientBytes {
                    $0.peakTransientBytes = liveTransient
                }
                if liveOutput > $0.peakOutputBytes {
                    $0.peakOutputBytes = liveOutput
                }
                let combined = liveTransient + retained
                if combined > $0.peakLiveWorkspaceBytes {
                    $0.peakLiveWorkspaceBytes = combined
                }
                if revision >= $0.lastBudgetRevision {
                    $0.lastBudgetRevision = revision
                    $0.liveScratchBytes = liveScratch
                    $0.liveTransientBytes = liveTransient
                    $0.liveOutputBytes = liveOutput
                    $0.retainedBytes = retained
                    $0.releasedOutputBytes = releasedOutput
                } else {
                    $0.staleBudgetUpdatesIgnored += 1
                }
            }
        }
    }

    @TaskLocal package static var recorder: Recorder?
}

/// Thread-safe live workspace, in-flight/queued child-output, and retained-output admission tracker across sequential or concurrent JP3D workers.
internal final class JP3DLiveBudgetTracker: Sendable {
    internal typealias PublishInterceptor = @Sendable (_ revision: UInt64, _ publish: @escaping @Sendable () -> Void) -> Void

    private static let revisionGenerator = Atomic<UInt64>(0)

    internal static func allocateRevision() -> UInt64 {
        revisionGenerator.wrappingAdd(1, ordering: .relaxed).newValue
    }

    fileprivate struct State: Sendable {
        var liveScratchBytes = 0
        var liveOutputBytes = 0
        var retainedBytes = 0
        var releasedOutputBytes = 0
        var revision: UInt64 = 0
    }

    /// Cycle-free value-only authoritative state container shared with `VolumeConcurrencyTelemetry.Recorder`.
    /// Holds only primitive integer counters (`State`), never retaining `JP3DLiveBudgetTracker` or `Recorder`.
    internal final class StateStorage: Sendable {
        fileprivate let state = Mutex(State())

        internal var currentScratchBytes: Int { state.withLock { $0.liveScratchBytes } }
        internal var currentOutputBytes: Int { state.withLock { $0.liveOutputBytes } }
        internal var currentTransientBytes: Int { state.withLock { $0.liveScratchBytes + $0.liveOutputBytes } }
        internal var currentRetainedBytes: Int { state.withLock { $0.retainedBytes } }
        internal var currentReleasedOutputBytes: Int { state.withLock { $0.releasedOutputBytes } }
    }

    private struct PublishedSnapshot: Sendable {
        let revision: UInt64
        let scratch: Int
        let output: Int
        let retained: Int
        let releasedOutput: Int
    }

    internal struct TransientLease: Sendable {
        fileprivate let owner: JP3DLiveBudgetTracker?
        fileprivate let bytes: Int

        internal func release() {
            owner?.releaseScratch(bytes)
        }
    }

    /// Scoped lease holding both newly added output bytes and the temporary copy-overlap scratch bytes
    /// (`extraTransientBytes`) in shared `JP3DLiveBudgetTracker` state across buffer construction/copy/append.
    /// Calling `complete()` releases only the temporary copy-overlap scratch bytes; calling `rollback()` (or
    /// dropping the lease without `complete()`, e.g. on thrown error or task cancellation) releases both the
    /// copy-overlap scratch bytes and the uncommitted output growth bytes.
    internal final class GrowthLease: Sendable {
        private enum Disposition: Sendable {
            case active
            case completed
            case rolledBack
        }

        private let reservation: OutputReservation
        private let owner: JP3DLiveBudgetTracker?
        private let addedOutputBytes: Int
        private let heldScratchBytes: Int
        private let disposition = Mutex(Disposition.active)

        fileprivate init(
            reservation: OutputReservation,
            owner: JP3DLiveBudgetTracker?,
            addedOutputBytes: Int,
            heldScratchBytes: Int
        ) {
            self.reservation = reservation
            self.owner = owner
            self.addedOutputBytes = max(0, addedOutputBytes)
            self.heldScratchBytes = max(0, heldScratchBytes)
        }

        internal func complete() {
            let shouldComplete = disposition.withLock { st -> Bool in
                guard st == .active else { return false }
                st = .completed
                return true
            }
            guard shouldComplete else { return }
            if heldScratchBytes > 0 {
                owner?.releaseScratch(heldScratchBytes)
            }
        }

        internal func rollback() {
            let shouldRollback = disposition.withLock { st -> Bool in
                guard st == .active else { return false }
                st = .rolledBack
                return true
            }
            guard shouldRollback else { return }
            let removedOutput = reservation.subtractReservedBytes(addedOutputBytes)
            owner?.rollbackOutputGrowth(outputBytes: removedOutput, scratchBytes: heldScratchBytes)
        }

        deinit {
            rollback()
        }
    }

    /// RAII reservation accompanying an encoded tile `Data` payload across child-task return
    /// until the parent task atomically promotes it to `retainedBytes` or discards it on error/cancellation.
    internal final class OutputReservation: Sendable {
        private let owner: JP3DLiveBudgetTracker?
        private let bytesMutex: Mutex<Int>

        fileprivate init(owner: JP3DLiveBudgetTracker?, initialBytes: Int) {
            self.owner = owner
            self.bytesMutex = Mutex(max(0, initialBytes))
        }

        internal var reservedBytes: Int {
            bytesMutex.withLock { $0 }
        }

        fileprivate func subtractReservedBytes(_ amount: Int) -> Int {
            guard amount > 0 else { return 0 }
            return bytesMutex.withLock { current -> Int in
                let removed = min(current, amount)
                current -= removed
                return removed
            }
        }

        internal func beginGrowth(
            by additionalBytes: Int,
            extraTransientBytes: Int = 0,
            checkCompressedLimit: Bool = true,
            stage: String,
            message: String
        ) throws -> GrowthLease {
            let clampedAdded = max(0, additionalBytes)
            let clampedExtra = max(0, extraTransientBytes)
            guard (clampedAdded > 0 || clampedExtra > 0), let owner else {
                return GrowthLease(
                    reservation: self,
                    owner: nil,
                    addedOutputBytes: 0,
                    heldScratchBytes: 0
                )
            }
            try owner.beginOutputGrowth(
                additionalBytes: clampedAdded,
                extraTransientBytes: clampedExtra,
                checkCompressedLimit: checkCompressedLimit,
                stage: stage,
                message: message
            )
            if clampedAdded > 0 {
                bytesMutex.withLock { $0 += clampedAdded }
            }
            return GrowthLease(
                reservation: self,
                owner: owner,
                addedOutputBytes: clampedAdded,
                heldScratchBytes: clampedExtra
            )
        }

        internal func withGrowth<R>(
            by additionalBytes: Int,
            extraTransientBytes: Int = 0,
            checkCompressedLimit: Bool = true,
            stage: String,
            message: String,
            _ body: () throws -> R
        ) throws -> R {
            let lease = try beginGrowth(
                by: additionalBytes,
                extraTransientBytes: extraTransientBytes,
                checkCompressedLimit: checkCompressedLimit,
                stage: stage,
                message: message
            )
            do {
                let result = try body()
                lease.complete()
                return result
            } catch {
                lease.rollback()
                throw error
            }
        }

        internal func withGrowth<R>(
            by additionalBytes: Int,
            extraTransientBytes: Int = 0,
            checkCompressedLimit: Bool = true,
            stage: String,
            message: String,
            _ body: () async throws -> R
        ) async throws -> R {
            let lease = try beginGrowth(
                by: additionalBytes,
                extraTransientBytes: extraTransientBytes,
                checkCompressedLimit: checkCompressedLimit,
                stage: stage,
                message: message
            )
            do {
                let result = try await body()
                lease.complete()
                return result
            } catch {
                lease.rollback()
                throw error
            }
        }

        internal func promoteToRetained(stage: String) {
            let toPromote = bytesMutex.withLock { current -> Int in
                let taken = current
                current = 0
                return taken
            }
            guard toPromote > 0 else { return }
            owner?.promoteOutputToRetained(toPromote, stage: stage)
        }

        internal func release() {
            let toRelease = bytesMutex.withLock { current -> Int in
                let taken = current
                current = 0
                return taken
            }
            guard toRelease > 0 else { return }
            owner?.releaseOutput(toRelease)
        }

        deinit {
            release()
        }
    }

    private let baseBytes: Int
    private let limits: ResourceLimits?
    private let telemetryRecorder: VolumeConcurrencyTelemetry.Recorder?
    internal let stateStorage = StateStorage()
    private let publishInterceptor = Mutex<PublishInterceptor?>(nil)

    internal init(baseBytes: Int, limits: ResourceLimits?) {
        self.baseBytes = max(0, baseBytes)
        self.limits = limits
        let rec = VolumeConcurrencyTelemetry.recorder
        self.telemetryRecorder = rec
        if let rec {
            rec.attachBudgetStateStorage(self.stateStorage)
            let initialRev = Self.allocateRevision()
            stateStorage.state.withLock { $0.revision = initialRev }
            rec.recordBudgetUpdate(
                revision: initialRev,
                liveScratch: 0,
                liveTransient: 0,
                liveOutput: 0,
                retained: 0,
                releasedOutput: 0
            )
        }
    }

    internal func setTestPublishInterceptor(_ interceptor: PublishInterceptor?) {
        publishInterceptor.withLock { $0 = interceptor }
    }

    internal var currentRetainedBytes: Int {
        stateStorage.currentRetainedBytes
    }

    internal var currentReleasedOutputBytes: Int {
        stateStorage.currentReleasedOutputBytes
    }

    internal var currentScratchBytes: Int {
        stateStorage.currentScratchBytes
    }

    internal var currentTransientBytes: Int {
        stateStorage.currentTransientBytes
    }

    internal var currentOutputBytes: Int {
        stateStorage.currentOutputBytes
    }

    internal var currentRevision: UInt64 {
        stateStorage.state.withLock { $0.revision }
    }

    /// Assigns a strictly increasing revision under `JP3DLiveBudgetTracker.state` and, in normal execution
    /// (`interceptor == nil`), publishes directly to the pure-value leaf `Recorder.state` lock (`Tracker.state -> Recorder.state`
    /// 2-node DAG, zero external callbacks or reentrancy) so telemetry observation order matches state mutation order.
    private func commitSnapshot(
        _ st: inout State,
        recorder: VolumeConcurrencyTelemetry.Recorder?,
        interceptor: PublishInterceptor?
    ) -> PublishedSnapshot {
        let rev = Self.allocateRevision()
        st.revision = rev
        let snap = PublishedSnapshot(
            revision: rev,
            scratch: st.liveScratchBytes,
            output: st.liveOutputBytes,
            retained: st.retainedBytes,
            releasedOutput: st.releasedOutputBytes
        )
        if interceptor == nil {
            recorder?.recordBudgetUpdate(
                revision: snap.revision,
                liveScratch: snap.scratch,
                liveTransient: snap.scratch + snap.output,
                liveOutput: snap.output,
                retained: snap.retained,
                releasedOutput: snap.releasedOutput
            )
        }
        return snap
    }

    private func completeInterceptedPublish(
        _ snap: PublishedSnapshot,
        recorder: VolumeConcurrencyTelemetry.Recorder?,
        interceptor: PublishInterceptor?
    ) {
        guard let interceptor, let recorder else { return }
        interceptor(snap.revision) {
            recorder.recordBudgetUpdate(
                revision: snap.revision,
                liveScratch: snap.scratch,
                liveTransient: snap.scratch + snap.output,
                liveOutput: snap.output,
                retained: snap.retained,
                releasedOutput: snap.releasedOutput
            )
        }
    }

    internal func reserveTransient(
        _ bytes: Int,
        checkCompressedLimit: Bool = false,
        stage: String,
        message: String
    ) throws -> TransientLease {
        guard bytes > 0 else { return TransientLease(owner: nil, bytes: 0) }
        let recorder = VolumeConcurrencyTelemetry.recorder ?? telemetryRecorder
        let interceptor = publishInterceptor.withLock { $0 }
        let snap = try stateStorage.state.withLock { st -> PublishedSnapshot in
            let (nextScratch, ov1) = st.liveScratchBytes.addingReportingOverflow(bytes)
            let (nextTransient, ov2) = nextScratch.addingReportingOverflow(st.liveOutputBytes)
            let (liveWorkspace, ov3) = nextTransient.addingReportingOverflow(st.retainedBytes)
            let (liveTotal, ov4) = baseBytes.addingReportingOverflow(liveWorkspace)
            let (committedOut, ov5) = st.retainedBytes.addingReportingOverflow(st.liveOutputBytes)
            let (projectedCompressed, ov6) = committedOut.addingReportingOverflow(bytes)
            guard !ov1, !ov2, !ov3, !ov4, !ov5, !ov6 else {
                throw CodecError(.resourceLimitExceeded, message)
            }
            if let limits {
                if checkCompressedLimit && projectedCompressed > limits.maximumCompressedBytes {
                    throw CodecError(.resourceLimitExceeded, message)
                }
                guard liveWorkspace <= limits.maximumWorkspaceBytes,
                      liveTotal <= limits.maximumMemoryBytes else {
                    throw CodecError(.resourceLimitExceeded, message)
                }
            }
            st.liveScratchBytes = nextScratch
            return commitSnapshot(&st, recorder: recorder, interceptor: interceptor)
        }
        completeInterceptedPublish(snap, recorder: recorder, interceptor: interceptor)
        StorageTelemetry.recordParserAllocation(stage: stage, bytes: bytes)
        return TransientLease(owner: self, bytes: bytes)
    }

    internal func makeOutputReservation(
        initialBytes: Int,
        checkCompressedLimit: Bool = true,
        stage: String,
        message: String
    ) throws -> OutputReservation {
        let clampedInitial = max(0, initialBytes)
        if clampedInitial > 0 {
            try beginOutputGrowth(
                additionalBytes: clampedInitial,
                extraTransientBytes: 0,
                checkCompressedLimit: checkCompressedLimit,
                stage: stage,
                message: message
            )
        }
        return OutputReservation(owner: self, initialBytes: clampedInitial)
    }

    fileprivate func beginOutputGrowth(
        additionalBytes: Int,
        extraTransientBytes: Int,
        checkCompressedLimit: Bool,
        stage: String,
        message: String
    ) throws {
        let clampedAdded = max(0, additionalBytes)
        let clampedExtra = max(0, extraTransientBytes)
        guard clampedAdded > 0 || clampedExtra > 0 else { return }
        let recorder = VolumeConcurrencyTelemetry.recorder ?? telemetryRecorder
        let interceptor = publishInterceptor.withLock { $0 }
        let snap = try stateStorage.state.withLock { st -> PublishedSnapshot in
            let (nextOutput, ov1) = st.liveOutputBytes.addingReportingOverflow(clampedAdded)
            let (nextScratch, ov2) = st.liveScratchBytes.addingReportingOverflow(clampedExtra)
            let (nextTransient, ov3) = nextScratch.addingReportingOverflow(nextOutput)
            let (peakWorkspace, ov4) = nextTransient.addingReportingOverflow(st.retainedBytes)
            let (peakTotal, ov5) = baseBytes.addingReportingOverflow(peakWorkspace)
            let (projectedCompressed, ov6) = st.retainedBytes.addingReportingOverflow(nextOutput)
            guard !ov1, !ov2, !ov3, !ov4, !ov5, !ov6 else {
                throw CodecError(.resourceLimitExceeded, message)
            }
            if let limits {
                if checkCompressedLimit && projectedCompressed > limits.maximumCompressedBytes {
                    throw CodecError(.resourceLimitExceeded, message)
                }
                guard peakWorkspace <= limits.maximumWorkspaceBytes,
                      peakTotal <= limits.maximumMemoryBytes else {
                    throw CodecError(.resourceLimitExceeded, message)
                }
            }
            st.liveOutputBytes = nextOutput
            st.liveScratchBytes = nextScratch
            return commitSnapshot(&st, recorder: recorder, interceptor: interceptor)
        }
        completeInterceptedPublish(snap, recorder: recorder, interceptor: interceptor)
        if clampedAdded > 0 {
            StorageTelemetry.recordParserAllocation(stage: stage, bytes: clampedAdded)
        }
    }

    fileprivate func rollbackOutputGrowth(outputBytes: Int, scratchBytes: Int) {
        let clampedOut = max(0, outputBytes)
        let clampedScratch = max(0, scratchBytes)
        guard clampedOut > 0 || clampedScratch > 0 else { return }
        let recorder = VolumeConcurrencyTelemetry.recorder ?? telemetryRecorder
        let interceptor = publishInterceptor.withLock { $0 }
        let snap = stateStorage.state.withLock { st -> PublishedSnapshot in
            st.liveOutputBytes = max(0, st.liveOutputBytes - clampedOut)
            st.liveScratchBytes = max(0, st.liveScratchBytes - clampedScratch)
            return commitSnapshot(&st, recorder: recorder, interceptor: interceptor)
        }
        completeInterceptedPublish(snap, recorder: recorder, interceptor: interceptor)
    }

    fileprivate func promoteOutputToRetained(_ bytes: Int, stage: String) {
        guard bytes > 0 else { return }
        let recorder = VolumeConcurrencyTelemetry.recorder ?? telemetryRecorder
        let interceptor = publishInterceptor.withLock { $0 }
        let snap = stateStorage.state.withLock { st -> PublishedSnapshot in
            let promoted = min(bytes, st.liveOutputBytes)
            st.liveOutputBytes -= promoted
            st.retainedBytes += promoted
            return commitSnapshot(&st, recorder: recorder, interceptor: interceptor)
        }
        completeInterceptedPublish(snap, recorder: recorder, interceptor: interceptor)
        StorageTelemetry.recordParserAllocation(stage: stage, bytes: bytes)
    }

    fileprivate func releaseOutput(_ bytes: Int) {
        guard bytes > 0 else { return }
        let recorder = VolumeConcurrencyTelemetry.recorder ?? telemetryRecorder
        let interceptor = publishInterceptor.withLock { $0 }
        let snap = stateStorage.state.withLock { st -> PublishedSnapshot in
            let released = min(bytes, st.liveOutputBytes)
            st.liveOutputBytes -= released
            st.releasedOutputBytes += released
            return commitSnapshot(&st, recorder: recorder, interceptor: interceptor)
        }
        completeInterceptedPublish(snap, recorder: recorder, interceptor: interceptor)
    }

    private func releaseScratch(_ bytes: Int) {
        guard bytes > 0 else { return }
        let recorder = VolumeConcurrencyTelemetry.recorder ?? telemetryRecorder
        let interceptor = publishInterceptor.withLock { $0 }
        let snap = stateStorage.state.withLock { st -> PublishedSnapshot in
            st.liveScratchBytes = max(0, st.liveScratchBytes - bytes)
            return commitSnapshot(&st, recorder: recorder, interceptor: interceptor)
        }
        completeInterceptedPublish(snap, recorder: recorder, interceptor: interceptor)
    }
}

/// Encoded volumetric tile payload paired with its active live-budget reservation across child-task return.
internal struct JP3DEncodedTileOutput: Sendable {
    internal let data: Data
    internal let reservation: JP3DLiveBudgetTracker.OutputReservation
}

@inline(__always)
internal func jp3dValidateResolutionLevel(_ resolutionLevel: Int) throws {
    guard (0...32).contains(resolutionLevel) else {
        throw J2KError.invalidParameter(
            "Resolution level \(resolutionLevel) out of valid range 0...32"
        )
    }
}

@inline(__always)
internal func jp3dDownsampleDimension(_ n: Int, resolutionLevel: Int) -> Int {
    guard resolutionLevel > 0 else { return max(1, n) }
    guard resolutionLevel < 31 else { return 1 }
    let scale = 1 << resolutionLevel
    let (sum, ov) = n.addingReportingOverflow(scale - 1)
    if ov {
        return max(1, (n / scale) + ((n % scale) != 0 ? 1 : 0))
    }
    return max(1, sum / scale)
}

@inline(__always)
internal func jp3dDownsampleOrigin(_ coord: Int, resolutionLevel: Int, roundUp: Bool) -> Int {
    guard resolutionLevel > 0 else { return coord }
    guard resolutionLevel < 31 else { return (roundUp && coord > 0) ? 1 : 0 }
    let scale = 1 << resolutionLevel
    if roundUp {
        let (sum, ov) = coord.addingReportingOverflow(scale - 1)
        if ov {
            return (coord / scale) + ((coord % scale) != 0 ? 1 : 0)
        }
        return sum / scale
    } else {
        return coord / scale
    }
}

/// Encodes and decodes a 3D tile by delegating each Z-slice to the 2D `SwiftJ2K` codec.
internal struct JP3DSliceStackCodec: Sendable {
    static let magic: [UInt8] = [0x4A, 0x33, 0x44, 0x53] // "J3DS"
    static let formatVersion: UInt8 = 2
    /// Version 1 header size: magic(4) + version(1) + compCount(2) + tileW(4) + tileH(4) + tileD(4) + bitDepth(1) + signed(1) = 21.
    static let v1HeaderSize = 21
    /// Version 2 header size: magic(4) + version(1) + flags(1) + compCount(2) + tileW(4) + tileH(4) + tileD(4) + bitDepth(1) + signed(1) = 22.
    static let v2HeaderSize = 22
    private static let zDeltaGainThreshold: Double = 0.85
    private static let zDeltaAutoMinSlicePixels: Int = 50_000

    init() {}

    /// Returns `true` if `data` starts with the `"J3DS"` slice-stack magic bytes.
    static func isSliceStackTile(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let s = data.startIndex
        return data[s] == magic[0]
            && data[s + 1] == magic[1]
            && data[s + 2] == magic[2]
            && data[s + 3] == magic[3]
    }

    /// Alias for ``isSliceStackTile(_:)``.
    static func hasMagic(_ data: Data) -> Bool {
        isSliceStackTile(data)
    }

    /// Returns `true` if the slice-stack tile payload uses HTJ2K (Part 15) coding.
    static func usesHTJ2K(_ data: Data) -> Bool {
        guard isSliceStackTile(data), data.count >= v1HeaderSize else { return false }
        let s = data.startIndex
        if data.count >= 32 && data[s + 4] == 0 {
            return (data[s + 11] & 0x01) != 0
        }
        if data[s + 4] >= 2 && (data[s + 5] & 0x80) != 0 {
            return true
        }
        let headerEnd = data[s + 4] >= 2 ? v2HeaderSize : v1HeaderSize
        guard data.count >= headerEnd + 6 else { return false }
        let scanUpper = min(data.count - 1, headerEnd + 256)
        for i in (headerEnd + 4)..<scanUpper {
            if data[s + i] == 0xFF && data[s + i + 1] == 0x50 {
                return true
            }
        }
        return false
    }

    /// Peeks the encoded quality-layer count from the first 2D slice's COD marker in a J3DS tile.
    static func peekQualityLayers(_ data: Data) -> Int? {
        guard isSliceStackTile(data), data.count >= 28 else { return nil }
        let s = data.startIndex
        let version = data[s + 4]
        guard version == 1 || version == 2 else { return nil }
        let headerEnd = version >= 2 ? v2HeaderSize : v1HeaderSize
        guard data.count >= headerEnd + 6 else { return nil }
        var pos = headerEnd
        let sliceLen = (Int(data[s + pos]) << 24)
            | (Int(data[s + pos + 1]) << 16)
            | (Int(data[s + pos + 2]) << 8)
            | Int(data[s + pos + 3])
        pos += 4
        let sliceEnd = min(data.count, pos + max(0, sliceLen))
        guard pos + 2 <= sliceEnd, data[s + pos] == 0xFF, data[s + pos + 1] == 0x4F else {
            return nil
        }
        pos += 2
        while pos + 4 <= sliceEnd {
            let mHi = data[s + pos]
            let mLo = data[s + pos + 1]
            pos += 2
            guard mHi == 0xFF else { return nil }
            if mLo == 0x90 || mLo == 0xD9 { break }
            if (0x30...0x3F).contains(mLo) { continue }
            guard pos + 2 <= sliceEnd else { return nil }
            let segLen = (Int(data[s + pos]) << 8) | Int(data[s + pos + 1])
            guard segLen >= 2, pos + segLen <= sliceEnd else { return nil }
            if mLo == 0x52, segLen >= 6 {
                let layers = (Int(data[s + pos + 4]) << 8) | Int(data[s + pos + 5])
                return max(1, layers)
            }
            pos += segLen
        }
        return nil
    }

    /// Returns `true` when the tile dimensions and bit depth can be handled by the slice-stack path.
    static func canEncode(
        tileWidth: Int,
        tileHeight: Int,
        bitDepth: Int
    ) -> Bool {
        tileWidth >= 4 && tileHeight >= 4 && bitDepth >= 1 && bitDepth <= 16
    }

    // MARK: - Encode

    func encodeTile(
        componentSamples: [[Float]],
        tileWidth: Int,
        tileHeight: Int,
        tileDepth: Int,
        bitDepth: Int,
        signed: Bool,
        levelsX: Int,
        levelsY: Int,
        levelsZ: Int = 0,
        compressionMode: JP3DCompressionMode,
        qualityLayers: Int,
        zDeltaPolicy: JP3DZDeltaMode = .auto,
        budget: JP3DLiveBudgetTracker? = nil,
        limits: ResourceLimits = .default,
        executionPolicy: ExecutionPolicy = .automatic
    ) throws -> JP3DEncodedTileOutput {
        let componentCount = componentSamples.count
        let slicePixelCount = tileWidth * tileHeight
        let clampedBitDepth = max(1, min(16, bitDepth))
        let minVal = signed ? -(1 << (clampedBitDepth - 1)) : 0
        let maxVal = signed ? ((1 << (clampedBitDepth - 1)) - 1) : ((1 << clampedBitDepth) - 1)

        var intSlicesPerComp: [[[Int32]]] = []
        intSlicesPerComp.reserveCapacity(componentCount)
        for comp in 0..<componentCount {
            let flat = componentSamples[comp]
            var compSlices: [[Int32]] = []
            compSlices.reserveCapacity(tileDepth)
            for z in 0..<tileDepth {
                let zOffset = z * slicePixelCount
                var slice = [Int32](repeating: 0, count: slicePixelCount)
                for i in 0..<slicePixelCount {
                    let v = Int(flat[zOffset + i].rounded())
                    slice[i] = Int32(max(minVal, min(maxVal, v)))
                }
                compSlices.append(slice)
            }
            intSlicesPerComp.append(compSlices)
        }

        return try encodeIntSlices(
            intSlicesPerComp: intSlicesPerComp,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            tileDepth: tileDepth,
            clampedBitDepth: clampedBitDepth,
            signed: signed,
            levelsX: levelsX,
            levelsY: levelsY,
            levelsZ: levelsZ,
            compressionMode: compressionMode,
            qualityLayers: qualityLayers,
            zDeltaPolicy: zDeltaPolicy,
            budget: budget,
            limits: limits,
            executionPolicy: executionPolicy
        )
    }

    /// Exact integer-preserving slice-stack tile encode for `1...16`-bit voxels without `Float` intermediates.
    func encodeTileInteger(
        componentSamples: [[Int64]],
        tileWidth: Int,
        tileHeight: Int,
        tileDepth: Int,
        bitDepth: Int,
        signed: Bool,
        levelsX: Int,
        levelsY: Int,
        levelsZ: Int = 0,
        compressionMode: JP3DCompressionMode,
        qualityLayers: Int,
        zDeltaPolicy: JP3DZDeltaMode = .auto,
        budget: JP3DLiveBudgetTracker? = nil,
        limits: ResourceLimits = .default,
        executionPolicy: ExecutionPolicy = .automatic
    ) throws -> JP3DEncodedTileOutput {
        let componentCount = componentSamples.count
        let slicePixelCount = tileWidth * tileHeight
        let clampedBitDepth = max(1, min(16, bitDepth))
        let minVal: Int64 = signed ? -(Int64(1) << (clampedBitDepth - 1)) : 0
        let maxVal: Int64 = signed ? ((Int64(1) << (clampedBitDepth - 1)) - 1) : ((Int64(1) << clampedBitDepth) - 1)

        var intSlicesPerComp: [[[Int32]]] = []
        intSlicesPerComp.reserveCapacity(componentCount)
        for comp in 0..<componentCount {
            let flat = componentSamples[comp]
            var compSlices: [[Int32]] = []
            compSlices.reserveCapacity(tileDepth)
            for z in 0..<tileDepth {
                let zOffset = z * slicePixelCount
                var slice = [Int32](repeating: 0, count: slicePixelCount)
                for i in 0..<slicePixelCount {
                    let v = max(minVal, min(maxVal, flat[zOffset + i]))
                    slice[i] = Int32(v)
                }
                compSlices.append(slice)
            }
            intSlicesPerComp.append(compSlices)
        }

        return try encodeIntSlices(
            intSlicesPerComp: intSlicesPerComp,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            tileDepth: tileDepth,
            clampedBitDepth: clampedBitDepth,
            signed: signed,
            levelsX: levelsX,
            levelsY: levelsY,
            levelsZ: levelsZ,
            compressionMode: compressionMode,
            qualityLayers: qualityLayers,
            zDeltaPolicy: zDeltaPolicy,
            budget: budget,
            limits: limits,
            executionPolicy: executionPolicy
        )
    }

    private func encodeIntSlices(
        intSlicesPerComp: [[[Int32]]],
        tileWidth: Int,
        tileHeight: Int,
        tileDepth: Int,
        clampedBitDepth: Int,
        signed: Bool,
        levelsX: Int,
        levelsY: Int,
        levelsZ: Int,
        compressionMode: JP3DCompressionMode,
        qualityLayers: Int,
        zDeltaPolicy: JP3DZDeltaMode,
        budget: JP3DLiveBudgetTracker?,
        limits: ResourceLimits,
        executionPolicy: ExecutionPolicy
    ) throws -> JP3DEncodedTileOutput {
        let componentCount = intSlicesPerComp.count
        let slicePixelCount = tileWidth * tileHeight

        let useZDelta: UInt8
        let zDeltaSizeAllowed: Bool
        switch zDeltaPolicy {
        case .never:
            zDeltaSizeAllowed = false
        case .always:
            zDeltaSizeAllowed = true
        case .auto:
            zDeltaSizeAllowed = slicePixelCount >= Self.zDeltaAutoMinSlicePixels
        }

        if zDeltaSizeAllowed
            && compressionMode.isLossless
            && tileDepth >= 2
            && levelsZ > 0
            && shouldUseZDelta(slicesPerComp: intSlicesPerComp, slicePixelCount: slicePixelCount) {
            useZDelta = 1
        } else {
            useZDelta = 0
        }

        let tracker = budget ?? JP3DLiveBudgetTracker(baseBytes: 0, limits: limits)
        let headerBytes = Self.v2HeaderSize
        let outReservation = try tracker.makeOutputReservation(
            initialBytes: headerBytes,
            checkCompressedLimit: true,
            stage: "jp3d-j3ds-tile-output",
            message: "Volumetric J3DS encoded tile payload exceeds operation resource limits."
        )

        var out = Data(capacity: headerBytes)
        out.append(contentsOf: Self.magic)
        out.append(Self.formatVersion)
        let zDeltaFlags: UInt8 = useZDelta | (compressionMode.isHTJ2K ? 0x80 : 0x00)
        out.append(zDeltaFlags)
        appendUInt16BE(&out, UInt16(componentCount))
        appendUInt32BE(&out, UInt32(tileWidth))
        appendUInt32BE(&out, UInt32(tileHeight))
        appendUInt32BE(&out, UInt32(tileDepth))
        out.append(UInt8(clampedBitDepth))
        out.append(signed ? 1 : 0)

        do {
            for comp in 0..<componentCount {
                let compSlices = intSlicesPerComp[comp]
                for z in 0..<tileDepth {
                    let sliceSamples: [Int32]
                    let sliceBitDepth: Int
                    let sliceSigned: Bool

                    if useZDelta == 1 && z >= 1 {
                        let prev = compSlices[z - 1]
                        let cur = compSlices[z]
                        var residual = [Int32](repeating: 0, count: slicePixelCount)
                        for i in 0..<slicePixelCount {
                            let diff = Int16(truncatingIfNeeded: Int(cur[i]) &- Int(prev[i]))
                            residual[i] = Int32(diff)
                        }
                        sliceSamples = residual
                        sliceBitDepth = 16
                        sliceSigned = true
                    } else {
                        sliceSamples = compSlices[z]
                        sliceBitDepth = clampedBitDepth
                        sliceSigned = signed
                    }

                    let sliceCodestream = try encodeSlice(
                        samples: sliceSamples,
                        width: tileWidth,
                        height: tileHeight,
                        bitDepth: sliceBitDepth,
                        signed: sliceSigned,
                        levelsX: levelsX,
                        levelsY: levelsY,
                        compressionMode: compressionMode,
                        qualityLayers: qualityLayers,
                        limits: limits,
                        executionPolicy: executionPolicy
                    )
                    let addedBytes = 4 + sliceCodestream.count
                    let oldCount = out.count
                    try outReservation.withGrowth(
                        by: addedBytes,
                        extraTransientBytes: oldCount,
                        checkCompressedLimit: true,
                        stage: "jp3d-j3ds-tile-output",
                        message: "Volumetric J3DS encoded tile payload exceeds operation resource limits."
                    ) {
                        var grown = Data(capacity: oldCount + addedBytes)
                        grown.append(out)
                        appendUInt32BE(&grown, UInt32(sliceCodestream.count))
                        grown.append(sliceCodestream)
                        out = grown
                    }
                }
            }
        } catch {
            outReservation.release()
            throw error
        }

        return JP3DEncodedTileOutput(data: out, reservation: outReservation)
    }

    // MARK: - Decode

    func decodeTile(
        _ data: Data,
        expectedComponents: Int,
        expectedWidth: Int,
        expectedHeight: Int,
        expectedDepth: Int,
        maxQualityLayers: Int? = nil,
        resolutionLevel: Int = 0,
        zRange: Range<Int>? = nil,
        xyROI: (x: Range<Int>, y: Range<Int>)? = nil,
        limits: ResourceLimits = .default,
        executionPolicy: ExecutionPolicy = .automatic
    ) throws -> [[Float]] {
        let intComponents = try decodeTileInteger(
            data,
            expectedComponents: expectedComponents,
            expectedWidth: expectedWidth,
            expectedHeight: expectedHeight,
            expectedDepth: expectedDepth,
            maxQualityLayers: maxQualityLayers,
            resolutionLevel: resolutionLevel,
            zRange: zRange,
            xyROI: xyROI,
            limits: limits,
            executionPolicy: executionPolicy
        )
        return intComponents.map { comp in
            comp.map { Float($0) }
        }
    }

    func decodeTileInteger(
        _ data: Data,
        expectedComponents: Int,
        expectedWidth: Int,
        expectedHeight: Int,
        expectedDepth: Int,
        maxQualityLayers: Int? = nil,
        resolutionLevel: Int = 0,
        zRange: Range<Int>? = nil,
        xyROI: (x: Range<Int>, y: Range<Int>)? = nil,
        limits: ResourceLimits = .default,
        executionPolicy: ExecutionPolicy = .automatic
    ) throws -> [[Int64]] {
        try jp3dValidateResolutionLevel(resolutionLevel)
        var offset = 0
        guard data.count >= Self.v1HeaderSize else {
            throw J2KError.decodingError("J3DS tile header truncated (\(data.count) bytes)")
        }
        for b in Self.magic {
            guard data[data.startIndex + offset] == b else {
                throw J2KError.decodingError("Invalid J3DS magic in tile payload")
            }
            offset += 1
        }
        let version = data[data.startIndex + offset]
        offset += 1
        guard version == 1 || version == 2 else {
            throw J2KError.decodingError("Unsupported J3DS tile version \(version)")
        }
        let zDeltaMode: UInt8
        if version >= 2 {
            guard data.count >= Self.v2HeaderSize else {
                throw J2KError.decodingError("J3DS v2 tile header truncated (\(data.count) bytes)")
            }
            zDeltaMode = data[data.startIndex + offset] & 0x7F
            offset += 1
        } else {
            zDeltaMode = 0
        }

        let compCount = Int(readUInt16BE(data, at: &offset))
        let tileW = Int(readUInt32BE(data, at: &offset))
        let tileH = Int(readUInt32BE(data, at: &offset))
        let tileD = Int(readUInt32BE(data, at: &offset))
        let bitDepth = Int(data[data.startIndex + offset]); offset += 1
        let signed = data[data.startIndex + offset] != 0; offset += 1

        guard compCount > 0 && tileW > 0 && tileH > 0 && tileD > 0 else {
            throw J2KError.decodingError("Invalid J3DS tile dimensions")
        }
        let (wh, o1) = tileW.multipliedReportingOverflow(by: tileH)
        let (_, o2) = wh.multipliedReportingOverflow(by: tileD)
        guard !o1 && !o2, bitDepth >= 1 && bitDepth <= 38 else {
            throw J2KError.decodingError("J3DS tile dimensions or bit depth out of range")
        }

        let outW: Int
        let outH: Int
        let roiX: Range<Int>?
        let roiY: Range<Int>?
        if let roi = xyROI, resolutionLevel == 0 {
            let clampedX = max(0, roi.x.lowerBound)..<min(tileW, roi.x.upperBound)
            let clampedY = max(0, roi.y.lowerBound)..<min(tileH, roi.y.upperBound)
            roiX = clampedX
            roiY = clampedY
            outW = max(1, clampedX.count)
            outH = max(1, clampedY.count)
        } else {
            roiX = nil
            roiY = nil
            outW = jp3dDownsampleDimension(tileW, resolutionLevel: resolutionLevel)
            outH = jp3dDownsampleDimension(tileH, resolutionLevel: resolutionLevel)
        }
        let outSlicePixels = outW * outH
        let fullSlicePixels = tileW * tileH
        let clampedBitDepth = max(1, min(16, bitDepth))

        let zStart = max(0, min(tileD, zRange?.lowerBound ?? 0))
        let zEnd = max(zStart, min(tileD, zRange?.upperBound ?? tileD))
        let outD = (zRange != nil) ? (zEnd - zStart) : tileD
        let zRequiredMin = (zDeltaMode == 1) ? 0 : zStart
        let zRequiredMax = zEnd

        var sliceTable = [[Range<Int>]]()
        sliceTable.reserveCapacity(compCount)
        for _ in 0..<compCount {
            var compRanges = [Range<Int>]()
            compRanges.reserveCapacity(tileD)
            for _ in 0..<tileD {
                guard offset + 4 <= data.count else {
                    throw J2KError.decodingError("Truncated J3DS slice length")
                }
                let sliceLen = Int(readUInt32BE(data, at: &offset))
                let (endPos, ov) = offset.addingReportingOverflow(sliceLen)
                guard !ov, sliceLen >= 0, endPos <= data.count else {
                    throw J2KError.decodingError("Truncated J3DS slice payload (\(sliceLen) bytes)")
                }
                compRanges.append((data.startIndex + offset)..<(data.startIndex + endPos))
                offset = endPos
            }
            sliceTable.append(compRanges)
        }

        var result = [[Int64]](
            repeating: [Int64](repeating: 0, count: outSlicePixels * outD),
            count: compCount
        )

        for comp in 0..<compCount {
            let compRanges = sliceTable[comp]
            let decodeSliceCount = max(0, zRequiredMax - zRequiredMin)
            var decodedSlices = [[Int32]](repeating: [], count: decodeSliceCount)
            var decodedSignedFlags = [Bool](repeating: signed, count: decodeSliceCount)

            for idx in 0..<decodeSliceCount {
                let z = zRequiredMin + idx
                let sliceData = data.subdata(in: compRanges[z])
                let (samples, w, h, _, sliceSigned) = try Slice2DBridge.decodeSlice(
                    data: sliceData,
                    maxQualityLayers: maxQualityLayers,
                    limits: limits,
                    executionPolicy: executionPolicy
                )
                decodedSignedFlags[idx] = sliceSigned
                if zDeltaMode == 1 {
                    decodedSlices[idx] = samples
                } else if let rx = roiX, let ry = roiY {
                    decodedSlices[idx] = Self.cropSlice(
                        samples, srcW: w, srcH: h, xRange: rx, yRange: ry
                    )
                } else if w == outW && h == outH {
                    decodedSlices[idx] = samples
                } else {
                    decodedSlices[idx] = Self.downsampleSlice(
                        samples, srcW: w, srcH: h, dstW: outW, dstH: outH
                    )
                }
            }

            if zDeltaMode == 1 {
                var prevSlice = [Int32](repeating: 0, count: fullSlicePixels)
                for z in 0..<zRequiredMax {
                    let rawSlice = decodedSlices[z]
                    let isResidualSigned = decodedSignedFlags[z]
                    let count = min(fullSlicePixels, rawSlice.count)
                    var reconstructed = [Int32](repeating: 0, count: fullSlicePixels)
                    if z == 0 {
                        for i in 0..<count {
                            reconstructed[i] = rawSlice[i]
                        }
                    } else if isResidualSigned {
                        if signed {
                            let shift = 32 - clampedBitDepth
                            for i in 0..<count {
                                let sum = Int(prevSlice[i]) &+ Int(rawSlice[i])
                                reconstructed[i] = Int32(bitPattern: UInt32(truncatingIfNeeded: sum) << shift) >> shift
                            }
                        } else {
                            let mask = (1 << clampedBitDepth) - 1
                            for i in 0..<count {
                                let sum = Int(prevSlice[i]) &+ Int(rawSlice[i])
                                reconstructed[i] = Int32(sum & mask)
                            }
                        }
                    } else if clampedBitDepth <= 8 && !signed {
                        for i in 0..<count {
                            let r = UInt8(truncatingIfNeeded: rawSlice[i])
                            let p = UInt8(truncatingIfNeeded: prevSlice[i])
                            reconstructed[i] = Int32(p &+ r)
                        }
                    } else {
                        for i in 0..<count {
                            let r = UInt16(truncatingIfNeeded: rawSlice[i])
                            let p = UInt16(truncatingIfNeeded: prevSlice[i])
                            let u = p &+ r
                            if signed {
                                reconstructed[i] = Int32(Int16(bitPattern: u))
                            } else {
                                let maxVal = (1 << clampedBitDepth) - 1
                                reconstructed[i] = Int32(Int(u) & maxVal)
                            }
                        }
                    }
                    prevSlice = reconstructed

                    if z >= zStart && z < zEnd {
                        let outSlice: [Int32]
                        if let rx = roiX, let ry = roiY {
                            outSlice = Self.cropSlice(
                                reconstructed, srcW: tileW, srcH: tileH,
                                xRange: rx, yRange: ry
                            )
                        } else if outW == tileW && outH == tileH {
                            outSlice = reconstructed
                        } else {
                            outSlice = Self.downsampleSlice(
                                reconstructed, srcW: tileW, srcH: tileH,
                                dstW: outW, dstH: outH
                            )
                        }
                        let dstBase = (z - zStart) * outSlicePixels
                        let copyCount = min(outSlicePixels, outSlice.count)
                        for i in 0..<copyCount {
                            result[comp][dstBase + i] = Int64(outSlice[i])
                        }
                    }
                }
            } else {
                for idx in 0..<decodeSliceCount {
                    let slice = decodedSlices[idx]
                    let dstBase = idx * outSlicePixels
                    let count = min(outSlicePixels, slice.count)
                    for i in 0..<count {
                        result[comp][dstBase + i] = Int64(slice[i])
                    }
                }
            }
        }

        return result
    }

    // MARK: - Lossless Wavelet-Domain Slice-Stack Transcoding

    /// Transcodes each 2D slice codestream in a `J3DS` tile payload between Part 1 and HTJ2K
    /// directly in the wavelet coefficient domain without inverse/forward DWT or Z-delta reconstruction.
    func transcodeTile(
        _ data: Data,
        toHTJ2K: Bool,
        limits: ResourceLimits = .default,
        executionPolicy: ExecutionPolicy = .automatic
    ) async throws -> Data {
        var offset = 0
        guard data.count >= Self.v1HeaderSize else {
            throw J2KError.decodingError("J3DS tile header truncated (\(data.count) bytes)")
        }
        for b in Self.magic {
            guard data[data.startIndex + offset] == b else {
                throw J2KError.decodingError("Invalid J3DS magic in tile payload")
            }
            offset += 1
        }
        let version = data[data.startIndex + offset]
        offset += 1
        guard version == 1 || version == 2 else {
            throw J2KError.decodingError("Unsupported J3DS tile version \(version)")
        }
        let zDeltaMode: UInt8
        if version >= 2 {
            guard data.count >= Self.v2HeaderSize else {
                throw J2KError.decodingError("J3DS v2 tile header truncated (\(data.count) bytes)")
            }
            zDeltaMode = data[data.startIndex + offset] & 0x7F
            offset += 1
        } else {
            zDeltaMode = 0
        }
        let compCount = Int(readUInt16BE(data, at: &offset))
        let tileW = Int(readUInt32BE(data, at: &offset))
        let tileH = Int(readUInt32BE(data, at: &offset))
        let tileD = Int(readUInt32BE(data, at: &offset))
        let bitDepth = data[data.startIndex + offset]; offset += 1
        let signed = data[data.startIndex + offset]; offset += 1

        var out = Data()
        out.reserveCapacity(data.count)
        out.append(contentsOf: Self.magic)
        out.append(Self.formatVersion)
        let transcodedFlags: UInt8 = (zDeltaMode & 0x7F) | (toHTJ2K ? 0x80 : 0x00)
        out.append(transcodedFlags)
        appendUInt16BE(&out, UInt16(compCount))
        appendUInt32BE(&out, UInt32(tileW))
        appendUInt32BE(&out, UInt32(tileH))
        appendUInt32BE(&out, UInt32(tileD))
        out.append(bitDepth)
        out.append(signed)

        let transcoder = try Transcoder()
        let target: TranscodeTarget = toHTJ2K ? .htj2k : .jpeg2000
        let options = TranscodeOptions(resourceLimits: limits, executionPolicy: executionPolicy)

        for _ in 0..<compCount {
            for _ in 0..<tileD {
                guard offset + 4 <= data.count else {
                    throw J2KError.decodingError("Truncated J3DS slice length")
                }
                let sliceLen = Int(readUInt32BE(data, at: &offset))
                let (endPos, ov) = offset.addingReportingOverflow(sliceLen)
                guard !ov, sliceLen >= 0, endPos <= data.count else {
                    throw J2KError.decodingError("Truncated J3DS slice payload")
                }
                let sliceData = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + endPos))
                offset = endPos

                let transcodedSlice = try await transcoder.transcode(sliceData, to: target, options: options).data
                appendUInt32BE(&out, UInt32(transcodedSlice.count))
                out.append(transcodedSlice)
            }
        }
        return out
    }

    // MARK: - Private Helpers

    private func shouldUseZDelta(
        slicesPerComp: [[[Int32]]],
        slicePixelCount: Int
    ) -> Bool {
        guard let comp0 = slicesPerComp.first, comp0.count >= 2, slicePixelCount > 0 else {
            return false
        }
        let s0 = comp0[0]
        let s1 = comp0[1]
        var mean: Int64 = 0
        for i in 0..<slicePixelCount {
            mean &+= Int64(s1[i])
        }
        mean /= Int64(slicePixelCount)
        var rawEnergy: Int64 = 0
        var deltaEnergy: Int64 = 0
        for i in 0..<slicePixelCount {
            rawEnergy &+= abs(Int64(s1[i]) - mean)
            deltaEnergy &+= abs(Int64(s1[i]) - Int64(s0[i]))
        }
        guard rawEnergy > 0 else { return false }
        return Double(deltaEnergy) < Double(rawEnergy) * Self.zDeltaGainThreshold
    }

    private func encodeSlice(
        samples: [Int32],
        width: Int,
        height: Int,
        bitDepth: Int,
        signed: Bool,
        levelsX: Int,
        levelsY: Int,
        compressionMode: JP3DCompressionMode,
        qualityLayers: Int,
        limits: ResourceLimits,
        executionPolicy: ExecutionPolicy
    ) throws -> Data {
        let levels = min(levelsX, levelsY)

        switch compressionMode {
        case .lossless:
            return try Slice2DBridge.encodeSlice(
                samples: samples,
                width: width,
                height: height,
                bitDepth: bitDepth,
                signed: signed,
                levels: levels,
                qualityLayers: qualityLayers,
                useHTJ2K: false,
                lossless: true,
                quality: nil,
                targetBitsPerPixel: nil,
                useReversibleWavelet: true,
                limits: limits,
                executionPolicy: executionPolicy
            )
        case .losslessHTJ2K:
            return try Slice2DBridge.encodeSlice(
                samples: samples,
                width: width,
                height: height,
                bitDepth: bitDepth,
                signed: signed,
                levels: levels,
                qualityLayers: 1,
                useHTJ2K: true,
                lossless: true,
                quality: nil,
                targetBitsPerPixel: nil,
                useReversibleWavelet: true,
                limits: limits,
                executionPolicy: executionPolicy
            )
        case .lossy(let psnr):
            let quality = min(0.99, max(0.05, (psnr - 20.0) / 40.0))
            return try Slice2DBridge.encodeSlice(
                samples: samples,
                width: width,
                height: height,
                bitDepth: bitDepth,
                signed: signed,
                levels: levels,
                qualityLayers: qualityLayers,
                useHTJ2K: false,
                lossless: false,
                quality: quality,
                targetBitsPerPixel: nil,
                useReversibleWavelet: false,
                limits: limits,
                executionPolicy: executionPolicy
            )
        case .lossyHTJ2K(let psnr):
            // Pre-quantise samples to a step size proportional to PSNR and encode with reversible HTJ2K
            // so the slice codestream is a valid Part 15 HTJ2K codestream (CAP 0xFF50 + HT cleanup pass).
            var minSample = Int32.max
            var maxSample = Int32.min
            for v in samples {
                if v < minSample { minSample = v }
                if v > maxSample { maxSample = v }
            }
            let actualRange = max(1, Int(maxSample) - Int(minSample))
            let qStep = max(2, min(64, Int((Double(actualRange) / pow(10.0, psnr / 20.0)).rounded())))
            let minVal = signed ? -(1 << (bitDepth - 1)) : 0
            let maxVal = signed ? ((1 << (bitDepth - 1)) - 1) : ((1 << bitDepth) - 1)
            var quantisedSamples = [Int32](repeating: 0, count: samples.count)
            let halfStep = qStep / 2
            for i in 0..<samples.count {
                let v = Int(samples[i])
                let q = v >= 0
                    ? ((v + halfStep) / qStep) * qStep
                    : -(((-v + halfStep) / qStep) * qStep)
                quantisedSamples[i] = Int32(max(minVal, min(maxVal, q)))
            }
            return try Slice2DBridge.encodeSlice(
                samples: quantisedSamples,
                width: width,
                height: height,
                bitDepth: bitDepth,
                signed: signed,
                levels: levels,
                qualityLayers: 1,
                useHTJ2K: true,
                lossless: true,
                quality: nil,
                targetBitsPerPixel: nil,
                useReversibleWavelet: true,
                limits: limits,
                executionPolicy: executionPolicy
            )
        case .targetBitrate(let bpv):
            let clampedBPV = max(0.05, min(Double(bitDepth), bpv))
            return try Slice2DBridge.encodeSlice(
                samples: samples,
                width: width,
                height: height,
                bitDepth: bitDepth,
                signed: signed,
                levels: levels,
                qualityLayers: qualityLayers,
                useHTJ2K: false,
                lossless: false,
                quality: nil,
                targetBitsPerPixel: clampedBPV,
                useReversibleWavelet: false,
                limits: limits,
                executionPolicy: executionPolicy
            )
        case .visuallyLossless:
            return try Slice2DBridge.encodeSlice(
                samples: samples,
                width: width,
                height: height,
                bitDepth: bitDepth,
                signed: signed,
                levels: levels,
                qualityLayers: qualityLayers,
                useHTJ2K: false,
                lossless: false,
                quality: 0.92,
                targetBitsPerPixel: nil,
                useReversibleWavelet: false,
                limits: limits,
                executionPolicy: executionPolicy
            )
        }
    }

    private static func cropSlice(
        _ slice: [Int32],
        srcW: Int,
        srcH: Int,
        xRange: Range<Int>,
        yRange: Range<Int>
    ) -> [Int32] {
        let dstW = max(1, xRange.count)
        let dstH = max(1, yRange.count)
        var out = [Int32](repeating: 0, count: dstW * dstH)
        for dy in 0..<dstH {
            let sy = min(srcH - 1, max(0, yRange.lowerBound + dy))
            let srcRow = sy * srcW
            let dstRow = dy * dstW
            for dx in 0..<dstW {
                let sx = min(srcW - 1, max(0, xRange.lowerBound + dx))
                let idx = srcRow + sx
                if idx < slice.count {
                    out[dstRow + dx] = slice[idx]
                }
            }
        }
        return out
    }

    private static func downsampleSlice(
        _ slice: [Int32],
        srcW: Int,
        srcH: Int,
        dstW: Int,
        dstH: Int
    ) -> [Int32] {
        var out = [Int32](repeating: 0, count: dstW * dstH)
        let scaleX = max(1, srcW / dstW)
        let scaleY = max(1, srcH / dstH)
        for dy in 0..<dstH {
            let sy = min(srcH - 1, dy * scaleY)
            for dx in 0..<dstW {
                let sx = min(srcW - 1, dx * scaleX)
                let idx = sy * srcW + sx
                if idx < slice.count {
                    out[dy * dstW + dx] = slice[idx]
                }
            }
        }
        return out
    }

    private func appendUInt16BE(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private func appendUInt32BE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private func readUInt16BE(_ data: Data, at offset: inout Int) -> UInt16 {
        let s = data.startIndex + offset
        let hi = UInt16(data[s])
        let lo = UInt16(data[s + 1])
        offset += 2
        return (hi << 8) | lo
    }

    private func readUInt32BE(_ data: Data, at offset: inout Int) -> UInt32 {
        let s = data.startIndex + offset
        let b0 = UInt32(data[s])
        let b1 = UInt32(data[s + 1])
        let b2 = UInt32(data[s + 2])
        let b3 = UInt32(data[s + 3])
        offset += 4
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}

// MARK: - Exact Integer Lossless 3D Tile Payload Codec ("J3DI")

/// Encodes and decodes exact `Int64` 3D reversible 5/3 wavelet coefficients for `1...38`-bit lossless tiles.
internal enum JP3DLosslessIntegerTileCodec {
    static let magic: [UInt8] = [0x4A, 0x33, 0x44, 0x49] // "J3DI"
    static let formatVersion: UInt8 = 1
    static let headerSize = 25

    static func hasMagic(_ data: Data) -> Bool {
        guard data.count >= headerSize else { return false }
        let s = data.startIndex
        return data[s] == magic[0]
            && data[s + 1] == magic[1]
            && data[s + 2] == magic[2]
            && data[s + 3] == magic[3]
    }

    static func usesHTJ2K(_ data: Data) -> Bool {
        guard hasMagic(data) else { return false }
        let version = data[data.startIndex + 4]
        guard version == formatVersion else { return false }
        return (data[data.startIndex + 5] & 0x80) != 0
    }

    static func encodeTile(
        componentSamples: [[Int64]],
        tileWidth: Int,
        tileHeight: Int,
        tileDepth: Int,
        bitDepth: Int,
        signed: Bool,
        levelsX: Int,
        levelsY: Int,
        levelsZ: Int,
        isHTJ2K: Bool,
        budget: JP3DLiveBudgetTracker? = nil,
        work: VolumeWorkGuard? = nil
    ) throws -> JP3DEncodedTileOutput {
        try work?.check()
        let componentCount = componentSamples.count
        guard componentCount > 0, tileWidth > 0, tileHeight > 0, tileDepth > 0 else {
            throw J2KError.invalidParameter("Invalid J3DI tile dimensions")
        }
        let (wh, ov1) = tileWidth.multipliedReportingOverflow(by: tileHeight)
        let (voxelsPerComp, ov2) = wh.multipliedReportingOverflow(by: tileDepth)
        let (totalVoxels, ov3) = voxelsPerComp.multipliedReportingOverflow(by: componentCount)
        guard !ov1, !ov2, !ov3 else {
            throw J2KError.invalidDimensions("J3DI tile voxel count overflows Int")
        }

        let maxDim = max(tileWidth, max(tileHeight, tileDepth))
        let (coeffBufferBytes, cOv1) = totalVoxels.multipliedReportingOverflow(by: MemoryLayout<Int64>.stride)
        let (dwtPlaneBytes, cOv2) = voxelsPerComp.multipliedReportingOverflow(by: MemoryLayout<Int64>.stride)
        let (lineScratchBytes, cOv3) = maxDim.multipliedReportingOverflow(by: 32)
        let (dwtScratchBytes, cOv4) = dwtPlaneBytes.addingReportingOverflow(lineScratchBytes)
        let (dwtTotal1, cOv5) = coeffBufferBytes.addingReportingOverflow(dwtScratchBytes)
        let (dwtWorkspaceBytes, cOv6) = dwtTotal1.addingReportingOverflow(128)
        guard !cOv1, !cOv2, !cOv3, !cOv4, !cOv5, !cOv6 else {
            throw J2KError.invalidDimensions("J3DI wavelet workspace overflows Int")
        }
        let dwtLease = try budget?.reserveTransient(
            dwtWorkspaceBytes,
            stage: "jp3d-j3di-dwt-workspace",
            message: "Volumetric J3DI wavelet transform workspace exceeds operation resource limits."
        )
        defer { dwtLease?.release() }

        var transformedPerComp: [[Int64]] = []
        transformedPerComp.reserveCapacity(componentCount)
        var effectiveLX = 0
        var effectiveLY = 0
        var effectiveLZ = 0
        var requiresInt64 = false

        for comp in 0..<componentCount {
            try work?.check()
            let fwd = try JP3DWaveletTransform.forwardLosslessInt64(
                data: componentSamples[comp],
                width: tileWidth,
                height: tileHeight,
                depth: tileDepth,
                levelsX: levelsX,
                levelsY: levelsY,
                levelsZ: levelsZ
            )
            effectiveLX = fwd.levelsX
            effectiveLY = fwd.levelsY
            effectiveLZ = fwd.levelsZ
            if !requiresInt64 {
                for c in fwd.coefficients where c < Int64(Int32.min) || c > Int64(Int32.max) {
                    requiresInt64 = true
                    break
                }
            }
            transformedPerComp.append(fwd.coefficients)
        }

        try work?.check()
        let bytesPerCoeff = requiresInt64 ? 8 : 4
        let (payloadBytes, ov4) = totalVoxels.multipliedReportingOverflow(by: bytesPerCoeff)
        let (totalBytes, ov5) = payloadBytes.addingReportingOverflow(headerSize)
        guard !ov4, !ov5 else {
            throw J2KError.invalidDimensions("J3DI tile byte count overflows Int")
        }
        let tracker = budget ?? JP3DLiveBudgetTracker(baseBytes: 0, limits: nil)
        let outReservation = try tracker.makeOutputReservation(
            initialBytes: totalBytes,
            checkCompressedLimit: true,
            stage: "jp3d-j3di-tile-output",
            message: "Volumetric J3DI encoded tile payload exceeds operation resource limits."
        )

        var out = Data(capacity: totalBytes)
        out.append(contentsOf: magic)
        out.append(formatVersion)
        let flags: UInt8 = (isHTJ2K ? 0x80 : 0x00) | (requiresInt64 ? 0x01 : 0x00)
        out.append(flags)
        appendUInt16BE(&out, UInt16(componentCount))
        appendUInt32BE(&out, UInt32(tileWidth))
        appendUInt32BE(&out, UInt32(tileHeight))
        appendUInt32BE(&out, UInt32(tileDepth))
        out.append(UInt8(clamping: effectiveLX))
        out.append(UInt8(clamping: effectiveLY))
        out.append(UInt8(clamping: effectiveLZ))
        out.append(UInt8(clamping: bitDepth))
        out.append(signed ? 1 : 0)

        out.count = totalBytes
        let coeffOffset = headerSize
        out.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var bytePos = coeffOffset
            if requiresInt64 {
                for coeffs in transformedPerComp {
                    for v in coeffs {
                        let u = UInt64(bitPattern: v)
                        base[bytePos] = UInt8(truncatingIfNeeded: u >> 56)
                        base[bytePos + 1] = UInt8(truncatingIfNeeded: u >> 48)
                        base[bytePos + 2] = UInt8(truncatingIfNeeded: u >> 40)
                        base[bytePos + 3] = UInt8(truncatingIfNeeded: u >> 32)
                        base[bytePos + 4] = UInt8(truncatingIfNeeded: u >> 24)
                        base[bytePos + 5] = UInt8(truncatingIfNeeded: u >> 16)
                        base[bytePos + 6] = UInt8(truncatingIfNeeded: u >> 8)
                        base[bytePos + 7] = UInt8(truncatingIfNeeded: u)
                        bytePos += 8
                    }
                }
            } else {
                for coeffs in transformedPerComp {
                    for v in coeffs {
                        let u = UInt32(bitPattern: Int32(v))
                        base[bytePos] = UInt8(truncatingIfNeeded: u >> 24)
                        base[bytePos + 1] = UInt8(truncatingIfNeeded: u >> 16)
                        base[bytePos + 2] = UInt8(truncatingIfNeeded: u >> 8)
                        base[bytePos + 3] = UInt8(truncatingIfNeeded: u)
                        bytePos += 4
                    }
                }
            }
        }

        return JP3DEncodedTileOutput(data: out, reservation: outReservation)
    }

    static func decodeTileInteger(
        _ data: Data,
        expectedComponents: Int,
        resolutionLevel: Int = 0
    ) throws -> [[Int64]] {
        try jp3dValidateResolutionLevel(resolutionLevel)
        guard hasMagic(data) else {
            throw J2KError.decodingError("Invalid J3DI magic in tile payload")
        }
        var offset = 4
        let version = data[data.startIndex + offset]; offset += 1
        guard version == formatVersion else {
            throw J2KError.decodingError("Unsupported J3DI version \(version)")
        }
        let flags = data[data.startIndex + offset]; offset += 1
        let usesInt64 = (flags & 0x01) != 0

        let compCount = Int(readUInt16BE(data, at: &offset))
        let tileW = Int(readUInt32BE(data, at: &offset))
        let tileH = Int(readUInt32BE(data, at: &offset))
        let tileD = Int(readUInt32BE(data, at: &offset))
        let levelsX = Int(data[data.startIndex + offset]); offset += 1
        let levelsY = Int(data[data.startIndex + offset]); offset += 1
        let levelsZ = Int(data[data.startIndex + offset]); offset += 1
        let bitDepth = Int(data[data.startIndex + offset]); offset += 1
        _ = data[data.startIndex + offset]; offset += 1 // signed

        guard compCount > 0, compCount == expectedComponents,
              tileW > 0, tileH > 0, tileD > 0,
              levelsX <= 32, levelsY <= 32, levelsZ <= 32,
              (1...38).contains(bitDepth) else {
            throw J2KError.decodingError("Invalid J3DI header parameters")
        }
        let (wh, ov1) = tileW.multipliedReportingOverflow(by: tileH)
        let (voxelsPerComp, ov2) = wh.multipliedReportingOverflow(by: tileD)
        let (totalVoxels, ov3) = voxelsPerComp.multipliedReportingOverflow(by: compCount)
        let bytesPerCoeff = usesInt64 ? 8 : 4
        let (payloadBytes, ov4) = totalVoxels.multipliedReportingOverflow(by: bytesPerCoeff)
        let (requiredTotal, ov5) = payloadBytes.addingReportingOverflow(headerSize)
        guard !ov1, !ov2, !ov3, !ov4, !ov5, data.count >= requiredTotal else {
            throw J2KError.decodingError("Truncated J3DI coefficient payload (\(data.count) bytes, expected \(requiredTotal))")
        }

        let outW = jp3dDownsampleDimension(tileW, resolutionLevel: resolutionLevel)
        let outH = jp3dDownsampleDimension(tileH, resolutionLevel: resolutionLevel)

        var result: [[Int64]] = []
        result.reserveCapacity(compCount)

        for comp in 0..<compCount {
            var coeffs = [Int64](repeating: 0, count: voxelsPerComp)
            let compByteOffset = headerSize + comp * voxelsPerComp * bytesPerCoeff
            data.withUnsafeBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return }
                let compPtr = base + compByteOffset
                if usesInt64 {
                    for i in 0..<voxelsPerComp {
                        var word: UInt64 = 0
                        for b in 0..<8 {
                            word = (word << 8) | UInt64(compPtr.load(fromByteOffset: i * 8 + b, as: UInt8.self))
                        }
                        coeffs[i] = Int64(bitPattern: word)
                    }
                } else {
                    for i in 0..<voxelsPerComp {
                        var word: UInt32 = 0
                        for b in 0..<4 {
                            word = (word << 8) | UInt32(compPtr.load(fromByteOffset: i * 4 + b, as: UInt8.self))
                        }
                        coeffs[i] = Int64(Int32(bitPattern: word))
                    }
                }
            }

            let fullReconstructed = try JP3DWaveletTransform.inverseLosslessInt64(
                coefficients: coeffs,
                width: tileW,
                height: tileH,
                depth: tileD,
                levelsX: levelsX,
                levelsY: levelsY,
                levelsZ: levelsZ
            )

            if outW == tileW && outH == tileH {
                result.append(fullReconstructed)
            } else {
                var downsampled = [Int64](repeating: 0, count: outW * outH * tileD)
                let sliceStride = tileW * tileH
                let outSliceStride = outW * outH
                for z in 0..<tileD {
                    for dy in 0..<outH {
                        let sy = min(tileH - 1, (dy * tileH) / max(1, outH))
                        for dx in 0..<outW {
                            let sx = min(tileW - 1, (dx * tileW) / max(1, outW))
                            downsampled[z * outSliceStride + dy * outW + dx] =
                                fullReconstructed[z * sliceStride + sy * tileW + sx]
                        }
                    }
                }
                result.append(downsampled)
            }
        }

        return result
    }

    static func transcodeTile(_ data: Data, toHTJ2K: Bool) throws -> Data {
        guard hasMagic(data) else {
            throw J2KError.decodingError("Invalid J3DI magic in tile payload")
        }
        let version = data[data.startIndex + 4]
        guard version == formatVersion else {
            throw J2KError.decodingError("Unsupported J3DI version \(version)")
        }
        var out = Data(data)
        let existingFlags = out[out.startIndex + 5]
        let newFlags = toHTJ2K ? (existingFlags | 0x80) : (existingFlags & ~0x80)
        out[out.startIndex + 5] = newFlags
        return out
    }

    private static func appendUInt16BE(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private static func appendUInt32BE(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private static func readUInt16BE(_ data: Data, at offset: inout Int) -> UInt16 {
        let s = data.startIndex + offset
        let hi = UInt16(data[s])
        let lo = UInt16(data[s + 1])
        offset += 2
        return (hi << 8) | lo
    }

    private static func readUInt32BE(_ data: Data, at offset: inout Int) -> UInt32 {
        let s = data.startIndex + offset
        let b0 = UInt32(data[s])
        let b1 = UInt32(data[s + 1])
        let b2 = UInt32(data[s + 2])
        let b3 = UInt32(data[s + 3])
        offset += 4
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
