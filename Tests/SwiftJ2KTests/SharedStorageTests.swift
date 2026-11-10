// SPDX-License-Identifier: MIT
//
// Milestone 3: shared-storage evidence for the scalar lossless path
// (MEMORY_CONTRACT MEM-10, MEM-12, MEM-13 and TESTING TEST-09). Each test
// binds a task-local telemetry recorder so that concurrent tests cannot
// pollute its counts, and the mutation tests bind a task-local path mutation.
import Foundation
import Synchronization
import Testing
@testable import SwiftJ2K

// MARK: - A caller-owned provider whose whole allocation starts as sentinel bytes

/// Every byte, including prefix and row padding, starts as 0xA5. The decoder
/// must overwrite exactly the sample bytes and nothing else; the encoder must
/// read exactly the sample bytes. Borrows are counted.
final class SentinelStorage: WritableImageStorage, @unchecked Sendable {
    let allocationID = UUID()
    let byteCount: Int
    static let sentinel: UInt8 = 0xA5
    private let allocation: UnsafeMutableRawPointer
    private enum Phase: Sendable { case available, writing(StorageWriteLease), sealed, invalid }
    private let phase: Mutex<Phase>
    let borrows = Mutex((writes: 0, reads: 0))

    init(byteCount: Int) {
        self.byteCount = byteCount
        allocation = .allocate(byteCount: byteCount, alignment: 2)
        allocation.initializeMemory(as: UInt8.self, repeating: Self.sentinel, count: byteCount)
        phase = Mutex(.available)
    }
    deinit { allocation.deallocate() }

    private let engaged = Atomic<Bool>(false)
    private func locked<R>(_ body: (inout Phase) throws -> R) throws -> R {
        guard !engaged.load(ordering: .acquiring) else {
            throw CodecError(.storageUnavailable, "Sentinel provider is already borrowed.")
        }
        guard let result = try phase.withLockIfAvailable({ state -> R in
            engaged.store(true, ordering: .releasing)
            defer { engaged.store(false, ordering: .releasing) }
            return try body(&state)
        }) else {
            throw CodecError(.storageUnavailable, "Sentinel provider is already borrowed.")
        }
        return result
    }
    func reserveWrite() throws -> StorageWriteLease {
        try locked { phase in
            guard case .available = phase else { throw CodecError(.storageUnavailable, "Sentinel provider is unavailable.") }
            let lease = StorageWriteLease(); phase = .writing(lease); return lease
        }
    }
    func withUnsafeMutableBytes<R>(lease: StorageWriteLease, _ body: (UnsafeMutableRawBufferPointer) throws -> R) throws -> R {
        try locked { phase in
            guard case .writing(let current) = phase, current == lease else {
                throw CodecError(.storageUnavailable, "Sentinel provider lease is invalid.")
            }
            borrows.withLock { $0.writes += 1 }
            return try body(UnsafeMutableRawBufferPointer(start: allocation, count: byteCount))
        }
    }
    func finishAndSeal(lease: StorageWriteLease) throws -> any ReadOnlyImageStorage {
        try locked { phase in
            guard case .writing(let current) = phase, current == lease else {
                throw CodecError(.storageUnavailable, "Sentinel provider lease is invalid.")
            }
            phase = .sealed
            return SentinelReadOwner(owner: self)
        }
    }
    func abortAndInvalidate(lease: StorageWriteLease) throws {
        try locked { phase in
            guard case .writing(let current) = phase, current == lease else {
                throw CodecError(.storageUnavailable, "Sentinel provider lease is invalid.")
            }
            phase = .invalid
        }
    }
    /// Readers are concurrent (MEM-05): the phase is checked under the lock,
    /// and because a sealed provider never leaves that state the borrow itself
    /// runs outside it.
    func read<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R {
        let sealed = phase.withLock { if case .sealed = $0 { return true }; return false }
        guard sealed else { throw CodecError(.storageUnavailable, "Sentinel provider is not sealed.") }
        borrows.withLock { $0.reads += 1 }
        return try body(UnsafeRawBufferPointer(start: allocation, count: byteCount))
    }
    var isInvalid: Bool { phase.withLock { if case .invalid = $0 { return true }; return false } }
}

struct SentinelReadOwner: ReadOnlyImageStorage {
    let owner: SentinelStorage
    var byteCount: Int { owner.byteCount }
    var allocationID: UUID { owner.allocationID }
    func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) throws -> R { try owner.read(body) }
}

/// A padded layout: `prefix` bytes before the plane, `padding` bytes after each row.
struct PaddedLayout {
    let width: Int, height: Int, bits: Int, prefix: Int, padding: Int
    var rowBytes: Int { width * 2 + padding }
    var byteCount: Int { prefix + rowBytes * height }
    func descriptor() throws -> ImageDescriptor {
        try ImageDescriptor.greyscale16(width: width, height: height, meaningfulBits: bits, rowBytes: rowBytes, offset: prefix)
    }
    /// Counts bytes that are neither prefix nor padding nor a sample, i.e. none:
    /// returns the number of prefix and padding bytes that no longer hold the sentinel.
    func disturbedNonSampleBytes(_ bytes: UnsafeRawBufferPointer) -> Int {
        var disturbed = 0
        for i in 0..<prefix where bytes[i] != SentinelStorage.sentinel { disturbed += 1 }
        for y in 0..<height {
            let row = prefix + y * rowBytes
            for p in (width * 2)..<rowBytes where bytes[row + p] != SentinelStorage.sentinel { disturbed += 1 }
        }
        return disturbed
    }
    func sample(_ bytes: UnsafeRawBufferPointer, x: Int, y: Int) -> UInt16 {
        let at = prefix + y * rowBytes + x * 2
        return UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }
}

private func fixture(_ name: String) -> Fixtures.Entry { Fixtures.manifest.fixtures.first { $0.name == name }! }

// MARK: - Decode into caller storage

@Test(arguments: [("g12_129x67_gradient", "opj", 6, 10), ("g16_17x9_alternating", "kdu", 2, 4), ("g12_129x67_gradient", "kdu_l3", 0, 0)])
func decodeWritesOnlySampleBytesOfTheCallerAllocation(name: String, variant: String, prefix: Int, padding: Int) async throws {
    let entry = fixture(name)
    let expected = try Fixtures.samples(entry)
    let layout = PaddedLayout(width: entry.width, height: entry.height, bits: entry.meaningfulBits, prefix: prefix, padding: padding)
    let owner = SentinelStorage(byteCount: layout.byteCount)
    let destination = try ImageDestination(descriptor: try layout.descriptor(), storage: owner)
    let recorder = StorageTelemetry.Recorder()
    let decoded = try await StorageTelemetry.$recorder.withValue(recorder) {
        try await Decoder().decode(try Fixtures.bytes("\(name).\(variant).j2k"), into: destination)
    }
    // Identity, instrumentation and report agree.
    #expect(decoded.image.storage.allocationID == owner.allocationID)
    #expect(owner.borrows.withLock { $0.writes } == 1)
    let counts = recorder.counts
    #expect(counts.pixelAllocations == 0 && counts.pixelBytes == 0, "\(counts)")
    #expect(counts.workspaceAllocations == 1 && counts.workspaceBytes == entry.width * entry.height * 4, "\(counts)")
    #expect(decoded.report.pixelAllocationCount == 0 && decoded.report.copyEvents.isEmpty)
    #expect(decoded.report.peakWorkspaceBytes! >= counts.workspaceBytes)
    // Samples exact, everything else still sentinel.
    try owner.read { bytes in
        #expect(layout.disturbedNonSampleBytes(bytes) == 0)
        var mismatches = 0
        for y in 0..<entry.height {
            for x in 0..<entry.width where layout.sample(bytes, x: x, y: y) != expected[y * entry.width + x] { mismatches += 1 }
        }
        #expect(mismatches == 0)
    }
    // The sealed image refuses a second writer and reads through the same owner.
    #expect(throws: CodecError.self) { try owner.reserveWrite() }
    #expect(try decoded.image.sampleUInt16(x: entry.width - 1, y: entry.height - 1) == expected[expected.count - 1])
}

@Test func allocatingDecodeUsesTheSameFinalOutputPathWithOneAllocation() async throws {
    let entry = fixture("g16_64x64_random")
    let recorder = StorageTelemetry.Recorder()
    let decoded = try await StorageTelemetry.$recorder.withValue(recorder) {
        try await Decoder().decode(try Fixtures.bytes("g16_64x64_random.opj.j2k"))
    }
    let counts = recorder.counts
    #expect(counts.pixelAllocations == 1 && counts.pixelBytes == 64 * 64 * 2, "\(counts)")
    #expect(counts.workspaceAllocations == 1, "\(counts)")
    #expect(decoded.report.pixelAllocationCount == 1 && decoded.report.peakPixelBytes == 64 * 64 * 2)
    try expectSamples(decoded.image, equal: try Fixtures.samples(entry), width: 64, height: 64)
}

// MARK: - Encode from sealed caller storage, then decode with a different stride

@Test func roundTripThroughCallerStorageWithDifferentStridesOnEachSide() async throws {
    let entry = fixture("g12_129x67_gradient")
    let expected = try Fixtures.samples(entry)
    let source = PaddedLayout(width: 129, height: 67, bits: 12, prefix: 2, padding: 6)
    let owner = SentinelStorage(byteCount: source.byteCount)
    let destination = try ImageDestination(descriptor: try source.descriptor(), storage: owner)
    let decoder = try Decoder()
    let first = try await decoder.decode(try Fixtures.bytes("g12_129x67_gradient.opj_b32.j2k"), into: destination)

    // Encode straight from the sealed caller owner: one read borrow, no pixel allocation.
    let recorder = StorageTelemetry.Recorder()
    let readsBefore = owner.borrows.withLock { $0.reads }
    let encoded = try await StorageTelemetry.$recorder.withValue(recorder) { try await Encoder().encode(first.image) }
    #expect(owner.borrows.withLock { $0.reads } == readsBefore + 1)
    #expect(recorder.counts.pixelAllocations == 0 && recorder.counts.workspaceAllocations == 1, "\(recorder.counts)")
    #expect(encoded.report.pixelAllocationCount == 0 && encoded.report.copyEvents.isEmpty)

    // The padded source produces the same bytes as a packed copy of the samples.
    let packed = try makeImage(expected, width: 129, height: 67, bits: 12)
    #expect(try await Encoder().encode(packed).data == encoded.data, "padding or prefix reached the codestream")

    // Decode the result into a second caller owner with a different stride and prefix.
    let target = PaddedLayout(width: 129, height: 67, bits: 12, prefix: 10, padding: 2)
    let second = SentinelStorage(byteCount: target.byteCount)
    let decoded = try await decoder.decode(encoded.data, into: try ImageDestination(descriptor: try target.descriptor(), storage: second))
    #expect(decoded.image.storage.allocationID == second.allocationID)
    try second.read { bytes in
        #expect(target.disturbedNonSampleBytes(bytes) == 0)
        var mismatches = 0
        for y in 0..<67 { for x in 0..<129 where target.sample(bytes, x: x, y: y) != expected[y * 129 + x] { mismatches += 1 } }
        #expect(mismatches == 0)
    }
}

@Test func bothCopyPoliciesUseTheSharedPathAndReportNoCopy() async throws {
    let entry = fixture("g16_17x9_alternating")
    let data = try Fixtures.bytes("g16_17x9_alternating.opj_n1.j2k")
    for policy in [CopyPolicy.requireSharedStorage, .allowCopy] {
        let layout = PaddedLayout(width: 17, height: 9, bits: 16, prefix: 4, padding: 6)
        let owner = SentinelStorage(byteCount: layout.byteCount)
        let destination = try ImageDestination(descriptor: try layout.descriptor(), storage: owner)
        let decoded = try await Decoder().decode(data, into: destination, options: .init(copyPolicy: policy))
        #expect(decoded.report.copyEvents.isEmpty && decoded.image.storage.allocationID == owner.allocationID)
        let encoded = try await Encoder().encode(decoded.image, options: .init(copyPolicy: policy))
        #expect(encoded.report.copyEvents.isEmpty)
        try expectSamples(try await Decoder().decode(encoded.data).image, equal: try Fixtures.samples(entry), width: 17, height: 9)
    }
}

// MARK: - Mutation testing: the checks above must be load-bearing (TEST-09)

/// Runs the padded decode and encode checks under a path mutation and returns
/// how many of the expectations would fail. The counts are reported by the
/// assertions below rather than recorded as issues.
private func failuresUnderMutation(_ mutation: SharedPathMutation) async throws -> Int {
    let entry = fixture("g12_129x67_gradient")
    let expected = try Fixtures.samples(entry)
    let layout = PaddedLayout(width: 129, height: 67, bits: 12, prefix: 2, padding: 6)
    let owner = SentinelStorage(byteCount: layout.byteCount)
    let destination = try ImageDestination(descriptor: try layout.descriptor(), storage: owner)
    let packed = try makeImage(expected, width: 129, height: 67, bits: 12)
    let reference = try await Encoder().encode(packed).data
    var failures = 0
    let decoded = try await SharedPathMutation.$active.withValue(mutation) {
        try await Decoder().decode(try Fixtures.bytes("g12_129x67_gradient.opj.j2k"), into: destination)
    }
    try owner.read { bytes in
        if layout.disturbedNonSampleBytes(bytes) != 0 { failures += 1 }
        var mismatches = 0
        for y in 0..<67 { for x in 0..<129 where layout.sample(bytes, x: x, y: y) != expected[y * 129 + x] { mismatches += 1 } }
        if mismatches != 0 { failures += 1 }
    }
    // The encoder under the same mutation reads the (correctly written) padded image.
    let good = try await Decoder().decode(try Fixtures.bytes("g12_129x67_gradient.opj.j2k"),
                                          into: try ImageDestination(descriptor: try layout.descriptor(), storage: SentinelStorage(byteCount: layout.byteCount)))
    do {
        let mutated = try await SharedPathMutation.$active.withValue(mutation) { try await Encoder().encode(good.image).data }
        if mutated != reference { failures += 1 }
    } catch let error as CodecError {
        // Reading padding or swapped bytes as samples trips the precision check.
        #expect(error.category == .invalidArgument)
        failures += 1
    }
    _ = decoded
    return failures
}

@Test func mutationsOfStrideAndByteOrderAreCaughtByTheSharedStorageChecks() async throws {
    let baseline = try await failuresUnderMutation(.none)
    let stride = try await failuresUnderMutation(.ignoreRowStride)
    let order = try await failuresUnderMutation(.wrongByteOrder)
    #expect(baseline == 0, "unmutated path failed \(baseline) checks")
    #expect(stride == 3, "ignoring the row stride failed \(stride) of 3 checks")
    #expect(order == 2, "wrong byte order failed \(order) of 3 checks (padding stays untouched)")
}

// MARK: - Ownership rules on the codec path

@Test func refusedLayoutLeavesDestinationReusableAndCancelledWorkInvalidatesIt() async throws {
    let layout = PaddedLayout(width: 17, height: 9, bits: 12, prefix: 0, padding: 2)   // precision mismatch
    let owner = SentinelStorage(byteCount: layout.byteCount)
    let destination = try ImageDestination(descriptor: try layout.descriptor(), storage: owner)
    do {
        _ = try await Decoder().decode(try Fixtures.bytes("g16_17x9_alternating.kdu.j2k"), into: destination)
        Issue.record("precision mismatch accepted")
    } catch let error as CodecError { #expect(error.category == .incompatibleImageLayout) }
    #expect(owner.borrows.withLock { $0.writes } == 0 && !owner.isInvalid)
    // The refused destination is still usable for a compatible decode.
    let good = try await Decoder().decode(try Fixtures.bytes("g12_5x3_ramp_extremes.kdu.j2k"),
                                          into: try ImageDestination(descriptor: .greyscale16(width: 5, height: 3, meaningfulBits: 12), storage: OwnedImageStorage(byteCount: 30)))
    #expect(good.image.descriptor.width == 5)

    // Cancellation after admission invalidates the caller's destination and publishes nothing.
    let big = PaddedLayout(width: 256, height: 256, bits: 16, prefix: 0, padding: 0)
    let cancelledOwner = SentinelStorage(byteCount: big.byteCount)
    let cancelled = try ImageDestination(descriptor: try big.descriptor(), storage: cancelledOwner)
    let progress: @Sendable (ProgressUpdate) -> Void = { update in
        guard update.phase == .processing, update.completedUnits > 0 else { return }
        withUnsafeCurrentTask { $0?.cancel() }
    }
    let cancelledDecode = Task { try await Decoder().decode(try Fixtures.bytes("g16_256x256_smooth.opj_b32.j2k"), into: cancelled, options: .init(progress: progress)) }
    do {
        _ = try await cancelledDecode.value
        Issue.record("cancelled decode published")
    } catch is CancellationError {}
    #expect(cancelledOwner.isInvalid)
    // Since Milestone 4 every tile is decoded inside the single write borrow, so the
    // borrow has begun; cancellation must still leave the owner invalid and unpublished.
    #expect(cancelledOwner.borrows.withLock { $0.writes } == 1)
    #expect(throws: CodecError.self) { try cancelled.writeUInt16 { _, _ in 0 } }
}

@Test func cancelledEncodeLeavesTheSourceIntactAndPublishesNothing() async throws {
    let entry = fixture("g16_256x256_smooth")
    let image = try makeImage(try Fixtures.samples(entry), width: 256, height: 256, bits: 16)
    let progress: @Sendable (ProgressUpdate) -> Void = { update in
        guard update.phase == .processing, update.completedUnits > 0 else { return }
        withUnsafeCurrentTask { $0?.cancel() }
    }
    let cancelledEncode = Task { try await Encoder().encode(image, options: .init(progress: progress)) }
    do {
        _ = try await cancelledEncode.value
        Issue.record("cancelled encode returned output")
    } catch is CancellationError {}
    // The sealed source is untouched and still encodes correctly afterwards.
    let encoded = try await Encoder().encode(image)
    try expectSamples(try await Decoder().decode(encoded.data).image, equal: try Fixtures.samples(entry), width: 256, height: 256)
}

@Test func concurrentReadersOfOneCallerOwnerAgreeWhileAMutationAttemptFails() async throws {
    let entry = fixture("g16_64x64_random")
    let layout = PaddedLayout(width: 64, height: 64, bits: 16, prefix: 8, padding: 8)
    let owner = SentinelStorage(byteCount: layout.byteCount)
    let image = try await Decoder().decode(try Fixtures.bytes("g16_64x64_random.kdu.j2k"),
                                           into: try ImageDestination(descriptor: try layout.descriptor(), storage: owner)).image
    let results = try await withThrowingTaskGroup(of: Data.self) { group in
        for _ in 0..<6 { group.addTask { try await Encoder().encode(image).data } }
        group.addTask {
            // A writer cannot be obtained on a sealed owner while readers run.
            #expect(throws: CodecError.self) { try owner.reserveWrite() }
            return Data()
        }
        return try await group.reduce(into: [Data]()) { if !$1.isEmpty { $0.append($1) } }
    }
    #expect(results.count == 6 && results.allSatisfy { $0 == results[0] })
    try expectSamples(try await Decoder().decode(results[0]).image, equal: try Fixtures.samples(entry), width: 64, height: 64)
}
