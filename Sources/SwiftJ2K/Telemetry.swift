// SPDX-License-Identifier: Apache-2.0
import Synchronization

/// Counters of the allocations this module makes for pixels and algorithm
/// workspace, so that a shared-storage claim can be checked against
/// instrumentation rather than address equality alone (MEM-13). A test binds
/// a `Recorder` to the current task; every allocation made by that task or
/// its children is counted there. Without a recorder nothing is recorded.
/// Counters hold sizes only, never contents or addresses.
struct StorageTelemetry: Sendable {
    struct AllocationEvent: Sendable, Equatable {
        let stage: String
        let bytes: Int
    }

    struct Counts: Sendable, Equatable {
        var pixelAllocations = 0
        var pixelBytes = 0
        var workspaceAllocations = 0
        var workspaceBytes = 0
    }

    fileprivate struct State: Sendable {
        var counts = Counts()
        var events: [AllocationEvent] = []
    }

    final class Recorder: Sendable {
        private let state = Mutex(State())
        init() {}
        var counts: Counts { state.withLock { $0.counts } }
        var events: [AllocationEvent] { state.withLock { $0.events } }
        func reset() { state.withLock { $0 = State() } }
        fileprivate func add(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }
    }

    @TaskLocal static var recorder: Recorder?

    /// An `OwnedImageStorage` allocation: the only pixel allocation this module makes.
    static func recordPixelAllocation(bytes: Int) {
        recorder?.add {
            $0.counts.pixelAllocations += 1
            $0.counts.pixelBytes += bytes
            $0.events.append(AllocationEvent(stage: "pixel", bytes: bytes))
        }
    }

    /// A codec workspace allocation (coefficient plane, joined tile-part data).
    static func recordWorkspaceAllocation(bytes: Int) {
        recorder?.add {
            $0.counts.workspaceAllocations += 1
            $0.counts.workspaceBytes += bytes
        }
    }

    /// Records a bounded stage allocation after admission passes and before the buffer is created.
    static func recordStage(_ stage: String, bytes: Int) {
        recorder?.add {
            $0.events.append(AllocationEvent(stage: stage, bytes: bytes))
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
