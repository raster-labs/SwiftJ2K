// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The common packet/marker sink. Noncopyable sinks retain exclusive buffer ownership.
protocol CodestreamByteSink: ~Copyable {
    mutating func writeUInt16Checked(_ value: UInt16) throws
    mutating func writeBytesChecked(_ bytes: [UInt8]) throws
}

extension CodestreamByteSink where Self: ~Copyable {
    mutating func writeSegment(marker: UInt16, payload: [UInt8]) throws {
        guard payload.count <= Int(UInt16.max) - 2 else {
            throw CodecError(.internalFailure, "Marker segment payload exceeds the 16-bit length field.")
        }
        try writeUInt16Checked(marker)
        try writeUInt16Checked(UInt16(payload.count + 2))
        try writeBytesChecked(payload)
    }
}

/// Exclusively owned compressed-byte storage with admission BEFORE each allocation.
///
/// Unlike Array.append, growth cannot choose an unaccounted capacity or make a COW
/// copy. The budget covers requested byte-buffer capacity, including both old and
/// new buffers during growth; allocator bookkeeping/size-class padding and process
/// RSS are separate measurements. No borrowed pointer is stored or escapes. This
/// synchronous, non-Sendable, noncopyable owner frees its allocation on every exit.
struct BoundedByteWriter: ~Copyable, CodestreamByteSink {
    private var storage: UnsafeMutableRawPointer?
    private(set) var count = 0
    private(set) var capacity = 0
    private(set) var peakAllocationBytes = 0
    private var maximumBytes: Int
    private var maximumAllocationBytes: Int

    init(reserving capacity: Int, maximumBytes: Int, maximumAllocationBytes: Int) throws {
        self.maximumBytes = maximumBytes
        self.maximumAllocationBytes = maximumAllocationBytes
        storage = nil
        guard capacity >= 0, maximumBytes >= 0, maximumAllocationBytes >= 0,
              capacity <= maximumBytes, capacity <= maximumAllocationBytes else {
            throw CodecError(.resourceLimitExceeded, "Output buffer reservation exceeds its admission budget.")
        }
        if capacity > 0 {
            guard let allocation = malloc(capacity) else {
                throw CodecError(.resourceLimitExceeded, "Output buffer allocation failed.")
            }
            storage = allocation
            self.capacity = capacity
            peakAllocationBytes = capacity
            StorageTelemetry.recordStage("bounded-byte-buffer", bytes: capacity)
        }
    }

    deinit { free(storage) }

    var allocatedBytes: Int { capacity }

    mutating func reserveCapacity(_ required: Int) throws {
        guard required >= count else { return }
        try ensureRoom(for: required - count)
    }

    /// The caller supplies the bytes available after all OTHER live buffers are
    /// admitted. Reset the peak because that surrounding live set may have changed.
    mutating func updateBudget(maximumBytes: Int, maximumAllocationBytes: Int) throws {
        guard maximumBytes >= count, maximumAllocationBytes >= capacity else {
            throw CodecError(.resourceLimitExceeded, "Output buffer exceeds the updated admission budget.")
        }
        self.maximumBytes = maximumBytes
        self.maximumAllocationBytes = maximumAllocationBytes
        peakAllocationBytes = capacity
    }

    private mutating func ensureRoom(for additional: Int) throws {
        guard additional >= 0 else {
            throw CodecError(.internalFailure, "Negative output buffer growth.")
        }
        let needed = try checkedAdd(count, additional)
        guard needed <= maximumBytes else {
            throw CodecError(.resourceLimitExceeded, "Output buffer growth exceeds the compressed-byte limit.")
        }
        guard needed > capacity else { return }
        // The old allocation remains live until its initialised prefix is copied.
        // Prefer amortised growth, but fall back to the exact requirement under a
        // tight budget. Neither choice is permitted to allocate before admission.
        let availableForNew = maximumAllocationBytes - capacity
        guard needed <= availableForNew else {
            throw CodecError(.resourceLimitExceeded, "Output buffer growth exceeds the live-allocation budget.")
        }
        let doubled = capacity.multipliedReportingOverflow(by: 2)
        let preferred = doubled.overflow ? maximumBytes : max(16, doubled.partialValue)
        let newCapacity = max(needed, min(preferred, min(maximumBytes, availableForNew)))
        let growthPeak = try checkedAdd(capacity, newCapacity)
        guard let replacement = malloc(newCapacity) else {
            throw CodecError(.resourceLimitExceeded, "Output buffer allocation failed.")
        }
        if count > 0 {
            guard let storage else {
                free(replacement)
                throw CodecError(.internalFailure, "Output buffer lost its storage.")
            }
            replacement.copyMemory(from: storage, byteCount: count)
        }
        free(storage)
        storage = replacement
        capacity = newCapacity
        peakAllocationBytes = max(peakAllocationBytes, growthPeak)
        StorageTelemetry.recordStage("bounded-byte-buffer", bytes: newCapacity)
    }

    mutating func writeUInt8Checked(_ value: UInt8) throws {
        try ensureRoom(for: 1)
        guard let storage else { throw CodecError(.internalFailure, "Missing output storage.") }
        storage.storeBytes(of: value, toByteOffset: count, as: UInt8.self)
        count += 1
    }

    mutating func writeUInt16Checked(_ value: UInt16) throws {
        try ensureRoom(for: 2)
        try writeUInt8Checked(UInt8(value >> 8))
        try writeUInt8Checked(UInt8(value & 0xff))
    }

    mutating func writeUInt32Checked(_ value: UInt32) throws {
        try ensureRoom(for: 4)
        try writeUInt16Checked(UInt16(value >> 16))
        try writeUInt16Checked(UInt16(value & 0xffff))
    }

    mutating func writeBytesChecked(_ bytes: [UInt8]) throws {
        try ensureRoom(for: bytes.count)
        if !bytes.isEmpty {
            guard let storage else { throw CodecError(.internalFailure, "Missing output storage.") }
            bytes.withUnsafeBytes { source in
                if let base = source.baseAddress {
                    storage.advanced(by: count).copyMemory(from: base, byteCount: bytes.count)
                }
            }
        }
        count += bytes.count
    }

    /// Copies directly from another owned writer without materialising an Array.
    mutating func writeBytesChecked(from other: borrowing BoundedByteWriter) throws {
        try ensureRoom(for: other.count)
        if other.count > 0 {
            guard let storage, let source = other.storage else {
                throw CodecError(.internalFailure, "Missing output storage.")
            }
            storage.advanced(by: count).copyMemory(from: source, byteCount: other.count)
        }
        count += other.count
    }

    /// The caller must admit `count` additional bytes before publishing this copy.
    /// Data copies synchronously; no pointer to the mutable owner escapes.
    func copyData() throws -> Data {
        if count == 0 { return Data() }
        guard let storage else { throw CodecError(.internalFailure, "Missing output storage.") }
        return Data(bytes: storage, count: count)
    }
}
