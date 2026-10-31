// SPDX-License-Identifier: Apache-2.0
import Synchronization

/// Counters of the allocations this module makes for pixels and algorithm
/// workspace, so that a shared-storage claim can be checked against
/// instrumentation rather than address equality alone (MEM-13). A test binds
/// a `Recorder` to the current task; every allocation made by that task or
/// its children is counted there. Without a recorder nothing is recorded.
/// Counters hold sizes only, never contents or addresses.
package struct StorageTelemetry: Sendable {
    package struct AllocationEvent: Sendable, Equatable {
        package let stage: String
        package let bytes: Int
        package init(stage: String, bytes: Int) {
            self.stage = stage
            self.bytes = bytes
        }
    }

    package struct Counts: Sendable, Equatable {
        package var pixelAllocations = 0
        package var pixelBytes = 0
        package var workspaceAllocations = 0
        package var workspaceBytes = 0
        package init() {}
    }

    fileprivate struct State: Sendable {
        var counts = Counts()
        var events: [AllocationEvent] = []
        var parserEvents: [AllocationEvent] = []
    }

    package final class Recorder: Sendable {
        private let state = Mutex(State())
        package init() {}
        package var counts: Counts { state.withLock { $0.counts } }
        package var events: [AllocationEvent] { state.withLock { $0.events } }
        package var parserEvents: [AllocationEvent] { state.withLock { $0.parserEvents } }
        package func reset() { state.withLock { $0 = State() } }
        fileprivate func add(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }
    }

    @TaskLocal package static var recorder: Recorder?

    /// An `OwnedImageStorage` allocation: the only pixel allocation this module makes.
    package static func recordPixelAllocation(bytes: Int) {
        recorder?.add {
            $0.counts.pixelAllocations += 1
            $0.counts.pixelBytes += bytes
            $0.events.append(AllocationEvent(stage: "pixel", bytes: bytes))
        }
    }

    /// A codec workspace allocation (coefficient plane, joined tile-part data).
    package static func recordWorkspaceAllocation(bytes: Int) {
        recorder?.add {
            $0.counts.workspaceAllocations += 1
            $0.counts.workspaceBytes += bytes
        }
    }

    /// Records a bounded stage allocation after admission passes and before the buffer is created.
    package static func recordStage(_ stage: String, bytes: Int) {
        recorder?.add {
            $0.events.append(AllocationEvent(stage: stage, bytes: bytes))
        }
    }

    /// Records a bounded parser-structure allocation after admission passes and before array construction.
    package static func recordParserAllocation(stage: String, bytes: Int) {
        recorder?.add {
            $0.parserEvents.append(AllocationEvent(stage: stage, bytes: bytes))
        }
    }
}

/// Test-only mutations of the shared-storage path (TESTING TEST-09). A
/// mutation that changes nothing would show the evidence is decorative, so a
/// test binds one to its task, counts the expectations that fail, and lets the
/// binding end. The value is task-local: it cannot leak into other operations,
/// and no public option selects it.
enum SharedPathMutation: Sendable, Equatable {
    case none
    /// Write and read samples packed, ignoring the caller's row stride.
    case ignoreRowStride
    /// Use the opposite byte order from the descriptor.
    case wrongByteOrder

    @TaskLocal static var active: SharedPathMutation = .none
}

/// Allocation-site telemetry for Tier-1/Tier-2 entropy and packet buffers so tests can prove
/// atomic pre-allocation budget admission/rejection precedes actual buffer allocation.
package struct EntropyAllocationTelemetry: Sendable {
    package enum EventKind: String, Sendable, Equatable {
        case reserveRequested
        case reserveAdmitted
        case reserveRejected
        case bufferAllocated
        case unusedReleased
    }

    package struct Event: Sendable, Equatable {
        package let sequence: Int
        package let kind: EventKind
        package let site: String
        package let bytes: Int
    }

    package final class Recorder: Sendable {
        private struct State: Sendable {
            var nextSeq = 0
            var events: [Event] = []
        }
        private let state = Mutex(State())
        package init() {}
        package var events: [Event] { state.withLock { $0.events } }
        package func record(_ kind: EventKind, site: String, bytes: Int) {
            state.withLock { st in
                let seq = st.nextSeq
                st.nextSeq += 1
                st.events.append(Event(sequence: seq, kind: kind, site: site, bytes: bytes))
            }
        }
    }

    @TaskLocal package static var recorder: Recorder?
}

/// Atomic pre-allocation byte budget hook shared across concurrent Tier-1/Tier-2 workers.
package struct EntropyOutputBudget: Sendable {
    private let reserveImpl: @Sendable (_ bytes: Int, _ countsTowardCompressedOutput: Bool, _ site: String) throws -> Void
    private let releaseImpl: @Sendable (_ bytes: Int, _ countsTowardCompressedOutput: Bool, _ site: String) -> Void

    package init(
        reserve: @escaping @Sendable (_ bytes: Int, _ countsTowardCompressedOutput: Bool, _ site: String) throws -> Void,
        release: @escaping @Sendable (_ bytes: Int, _ countsTowardCompressedOutput: Bool, _ site: String) -> Void
    ) {
        self.reserveImpl = reserve
        self.releaseImpl = release
    }

    package init(
        reserveBytes: @escaping @Sendable (_ bytes: Int, _ countsTowardCompressedOutput: Bool) -> Bool,
        releaseBytes: @escaping @Sendable (_ bytes: Int, _ countsTowardCompressedOutput: Bool) -> Void
    ) {
        self.reserveImpl = { bytes, countsTowardCompressed, site in
            guard reserveBytes(bytes, countsTowardCompressed) else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Entropy output allocation (\(bytes) bytes at \(site)) exceeds resource budget."
                )
            }
        }
        self.releaseImpl = { bytes, countsTowardCompressed, _ in
            releaseBytes(bytes, countsTowardCompressed)
        }
    }

    package func reserve(_ bytes: Int, countsTowardCompressedOutput: Bool = true, site: String = "jp3d-reserve") throws {
        guard bytes > 0 else { return }
        EntropyAllocationTelemetry.recorder?.record(.reserveRequested, site: site, bytes: bytes)
        do {
            try reserveImpl(bytes, countsTowardCompressedOutput, site)
            EntropyAllocationTelemetry.recorder?.record(.reserveAdmitted, site: site, bytes: bytes)
        } catch {
            EntropyAllocationTelemetry.recorder?.record(.reserveRejected, site: site, bytes: bytes)
            throw error
        }
    }

    package func recordActualAllocation(_ bytes: Int, site: String) {
        guard bytes > 0 else { return }
        EntropyAllocationTelemetry.recorder?.record(.bufferAllocated, site: site, bytes: bytes)
    }

    /// Replaces a growing entropy buffer with an exact-length retained array before
    /// releasing its unused reservation. `removeLast` alone retains the old capacity.
    package func compactOutput(_ bytes: inout [UInt8], reservedBytes: inout Int, site: String) throws {
        let count = bytes.count
        guard reservedBytes > count else { return }
        if count == 0 {
            bytes = []
        } else {
            try reserve(count, countsTowardCompressedOutput: false, site: site)
            defer { release(count, countsTowardCompressedOutput: false, site: site) }
            recordActualAllocation(count, site: site)
            let compact = [UInt8](unsafeUninitializedCapacity: count) { destination, initialised in
                // Both pointers remain within synchronous scoped borrows. The new
                // buffer is distinct and every element is initialised before return.
                bytes.withUnsafeBufferPointer { source in
                    if let src = source.baseAddress, let dst = destination.baseAddress {
                        dst.initialize(from: src, count: count)
                    }
                }
                initialised = count
            }
            bytes = compact
        }
        release(reservedBytes - count, countsTowardCompressedOutput: true, site: site)
        reservedBytes = count
    }

    package func release(_ bytes: Int, countsTowardCompressedOutput: Bool = true, site: String = "jp3d-release") {
        guard bytes > 0 else { return }
        releaseImpl(bytes, countsTowardCompressedOutput, site)
        EntropyAllocationTelemetry.recorder?.record(.unusedReleased, site: site, bytes: bytes)
    }
}
