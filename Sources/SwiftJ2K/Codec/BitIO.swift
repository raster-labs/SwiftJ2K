// SPDX-License-Identifier: Apache-2.0
//
// Byte and bit readers/writers for JPEG 2000 codestream syntax.
//
// Provenance: new implementation for SwiftJ2K Milestone 2. The packet-header
// bit-stuffing rule follows ISO/IEC 15444-1 B.10.1. The predecessor's
// J2KBitReader/J2KBitWriter (Raster-Lab/J2KSwift 7acc9ae4, Sources/J2KCore)
// were inspected but not copied: they carry a Data-slice normalising copy and
// public cross-module surface that the successor does not need.
import Foundation

/// Big-endian byte reader over a retained byte array. Every read is bounds
/// checked and throws `malformedInput` rather than trapping (API-09).
struct ByteReader {
    let bytes: [UInt8]
    private(set) var position: Int

    init(_ bytes: [UInt8], position: Int = 0) {
        self.bytes = bytes
        self.position = position
    }

    var remaining: Int { bytes.count - position }
    var isAtEnd: Bool { position >= bytes.count }

    mutating func readUInt8() throws -> UInt8 {
        guard position < bytes.count else { throw truncated() }
        let value = bytes[position]
        position += 1
        return value
    }

    mutating func readUInt16() throws -> UInt16 {
        guard position + 2 <= bytes.count else { throw truncated() }
        let value = UInt16(bytes[position]) << 8 | UInt16(bytes[position + 1])
        position += 2
        return value
    }

    mutating func readUInt32() throws -> UInt32 {
        guard position + 4 <= bytes.count else { throw truncated() }
        var value: UInt32 = 0
        for index in 0..<4 { value = value << 8 | UInt32(bytes[position + index]) }
        position += 4
        return value
    }

    func peekUInt16() -> UInt16? {
        guard position + 2 <= bytes.count else { return nil }
        return UInt16(bytes[position]) << 8 | UInt16(bytes[position + 1])
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, position + count <= bytes.count else { throw truncated() }
        position += count
    }

    mutating func seek(to newPosition: Int) throws {
        guard newPosition >= 0, newPosition <= bytes.count else { throw truncated() }
        position = newPosition
    }

    private func truncated() -> CodecError {
        CodecError(.malformedInput, "Codestream ends before the expected field at byte \(position).")
    }
}

/// Array-backed marker sink for the existing encoder and small marker payloads.
/// `maximumBytes` limits length only; it is not an allocation budget. Transcoding
/// uses BoundedByteWriter for buffers that grow under a live-memory ceiling.
struct ByteWriter: CodestreamByteSink {
    private(set) var bytes: [UInt8] = []
    private(set) var maximumBytes: Int

    init(capacity: Int = 0, maximumBytes: Int = Int.max) {
        self.maximumBytes = maximumBytes
        if capacity > 0 {
            bytes.reserveCapacity(min(capacity, maximumBytes))
        }
    }

    var count: Int { bytes.count }

    mutating func ensureRoom(for additional: Int) throws {
        let needed = try checkedAdd(bytes.count, additional)
        guard needed <= maximumBytes else {
            throw CodecError(.resourceLimitExceeded, "Output buffer growth exceeds the byte budget.")
        }
    }

    mutating func writeUInt8(_ value: UInt8) { bytes.append(value) }
    mutating func writeUInt16(_ value: UInt16) {
        bytes.append(UInt8(value >> 8)); bytes.append(UInt8(value & 0xFF))
    }
    mutating func writeUInt32(_ value: UInt32) {
        bytes.append(UInt8(value >> 24)); bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF)); bytes.append(UInt8(value & 0xFF))
    }
    mutating func writeBytes(_ other: [UInt8]) { bytes.append(contentsOf: other) }
    mutating func writeBytes(_ other: ArraySlice<UInt8>) { bytes.append(contentsOf: other) }

    mutating func writeUInt8Checked(_ value: UInt8) throws {
        try ensureRoom(for: 1)
        bytes.append(value)
    }
    mutating func writeUInt16Checked(_ value: UInt16) throws {
        try ensureRoom(for: 2)
        bytes.append(UInt8(value >> 8)); bytes.append(UInt8(value & 0xFF))
    }
    mutating func writeUInt32Checked(_ value: UInt32) throws {
        try ensureRoom(for: 4)
        bytes.append(UInt8(value >> 24)); bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF)); bytes.append(UInt8(value & 0xFF))
    }
    mutating func writeBytesChecked(_ other: [UInt8]) throws {
        try ensureRoom(for: other.count)
        bytes.append(contentsOf: other)
    }

    /// Writes a marker segment with its length field (Lxxx includes itself).
    mutating func writeSegment(marker: UInt16, payload: [UInt8]) throws {
        guard payload.count + 2 <= Int(UInt16.max) else {
            throw CodecError(.internalFailure, "Marker segment payload exceeds the 16-bit length field.")
        }
        try ensureRoom(for: 4 + payload.count)
        writeUInt16(marker)
        writeUInt16(UInt16(payload.count + 2))
        writeBytes(payload)
    }
}

/// Packet-header bit reader (ISO/IEC 15444-1 B.10.1). Bits are consumed MSB
/// first; after a 0xFF byte the next byte carries only seven data bits.
struct PacketBitReader {
    private let bytes: [UInt8]
    private let end: Int
    private(set) var position: Int
    private var current: UInt8 = 0
    private var bitsLeft = 0
    private var previousWasFF = false

    init(bytes: [UInt8], start: Int, end: Int) {
        self.bytes = bytes
        self.position = start
        self.end = end
    }

    mutating func readBit() throws -> Bool {
        if bitsLeft == 0 {
            guard position < end else {
                throw CodecError(.malformedInput, "Packet header ends before its last field.")
            }
            let byte = bytes[position]
            position += 1
            bitsLeft = previousWasFF ? 7 : 8
            previousWasFF = byte == 0xFF
            current = byte
        }
        bitsLeft -= 1
        return (current >> UInt8(bitsLeft)) & 1 == 1
    }

    mutating func readBits(_ count: Int) throws -> Int {
        guard count >= 0, count <= 31 else {
            throw CodecError(.malformedInput, "Packet header field width \(count) is not representable.")
        }
        var value = 0
        for _ in 0..<count { value = value << 1 | (try readBit() ? 1 : 0) }
        return value
    }

    /// Discards the remaining bits of the current byte. If the last byte read
    /// was 0xFF, the single stuffed byte that follows it is consumed too.
    mutating func alignToByte() throws {
        bitsLeft = 0
        if previousWasFF {
            guard position < end else {
                throw CodecError(.malformedInput, "Packet header is missing its stuffed byte after 0xFF.")
            }
            position += 1
            previousWasFF = false
        }
    }
}

/// Packet-header bit writer, the inverse of `PacketBitReader`.
struct PacketBitWriter {
    private(set) var bytes: [UInt8] = []
    private var current: UInt8 = 0
    private var bitsUsed = 0
    private var limit = 8

    mutating func writeBit(_ bit: Bool) {
        if bit { current |= 1 << UInt8(limit - 1 - bitsUsed) }
        bitsUsed += 1
        if bitsUsed == limit { emit() }
    }

    mutating func writeBits(_ value: Int, count: Int) {
        for shift in stride(from: count - 1, through: 0, by: -1) {
            writeBit((value >> shift) & 1 == 1)
        }
    }

    private mutating func emit() {
        bytes.append(current)
        limit = current == 0xFF ? 7 : 8
        current = 0
        bitsUsed = 0
    }

    /// Flushes the partial byte. A trailing 0xFF is followed by one stuffed
    /// byte so that a reader cannot mistake the tail for a marker.
    mutating func finish() -> [UInt8] {
        if bitsUsed > 0 { emit() }
        if limit == 7 {
            bytes.append(0)
            limit = 8
        }
        return bytes
    }
}
