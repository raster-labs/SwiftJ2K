// SPDX-License-Identifier: Apache-2.0
//
// Adapted from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   Sources/J2KFileFormat/J2KBox.swift
//
// Changes for the SwiftJ2K contract:
// - Replaced Data zero-index subscript assumptions with bounds-checked [UInt8]
//   range slices.
// - Fixed LBox == 1 (extended 64-bit box length) validation to require XLBox >= 16
//   and checked integer addition, preventing predecessor infinite loops on XLBox == 0
//   and fatal Range traps on XLBox in 1...15.
// - Added ResourceLimits.maximumNestingDepth enforcement across recursive superboxes.

import Foundation

/// Four-character box type identifier (ISO/IEC 15444-1 Annex I.4, ISO/IEC 15444-2 Annex M, ISO/IEC 15444-15 Annex A).
public struct JP2BoxType: RawRepresentable, Sendable, Equatable, Hashable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init?(fourCC: String) {
        let scalars = Array(fourCC.unicodeScalars)
        guard scalars.count == 4, scalars.allSatisfy({ $0.value <= 0xFF }) else { return nil }
        self.rawValue = (UInt32(scalars[0].value) << 24)
            | (UInt32(scalars[1].value) << 16)
            | (UInt32(scalars[2].value) << 8)
            | UInt32(scalars[3].value)
    }

    public var fourCC: String {
        let bytes: [UInt8] = [
            UInt8((rawValue >> 24) & 0xFF),
            UInt8((rawValue >> 16) & 0xFF),
            UInt8((rawValue >> 8) & 0xFF),
            UInt8(rawValue & 0xFF)
        ]
        return String(bytes.map { Character(UnicodeScalar($0)) })
    }

    public var description: String { fourCC }

    // MARK: - ISO/IEC 15444-1 Annex I & ISO/IEC 15444-15 Annex A Core Boxes
    public static let signature            = JP2BoxType(rawValue: 0x6A502020) // 'jP  '
    public static let fileType             = JP2BoxType(rawValue: 0x66747970) // 'ftyp'
    public static let jp2Header            = JP2BoxType(rawValue: 0x6A703268) // 'jp2h'
    public static let imageHeader          = JP2BoxType(rawValue: 0x69686472) // 'ihdr'
    public static let bitsPerComponent     = JP2BoxType(rawValue: 0x62706363) // 'bpcc'
    public static let colourSpecification  = JP2BoxType(rawValue: 0x636F6C72) // 'colr'
    public static let palette              = JP2BoxType(rawValue: 0x70636C72) // 'pclr'
    public static let componentMapping     = JP2BoxType(rawValue: 0x636D6170) // 'cmap'
    public static let channelDefinition    = JP2BoxType(rawValue: 0x63646566) // 'cdef'
    public static let resolution           = JP2BoxType(rawValue: 0x72657320) // 'res '
    public static let captureResolution    = JP2BoxType(rawValue: 0x72657363) // 'resc'
    public static let displayResolution    = JP2BoxType(rawValue: 0x72657364) // 'resd'
    public static let contiguousCodestream = JP2BoxType(rawValue: 0x6A703263) // 'jp2c'
    public static let ipr                  = JP2BoxType(rawValue: 0x6A703269) // 'jp2i'
    public static let xml                  = JP2BoxType(rawValue: 0x786D6C20) // 'xml '
    public static let uuid                 = JP2BoxType(rawValue: 0x75756964) // 'uuid'
    public static let uuidInfo             = JP2BoxType(rawValue: 0x75696E66) // 'uinf'
    public static let uuidList             = JP2BoxType(rawValue: 0x756C7374) // 'ulst'
    public static let dataEntryURL         = JP2BoxType(rawValue: 0x75726C20) // 'url '
    public static let free                 = JP2BoxType(rawValue: 0x66726565) // 'free'

    // MARK: - ISO/IEC 15444-2 Annex M JPX Boxes
    public static let readerRequirements   = JP2BoxType(rawValue: 0x72726571) // 'rreq'
    public static let association          = JP2BoxType(rawValue: 0x61736F63) // 'asoc'
    public static let label                = JP2BoxType(rawValue: 0x6C626C20) // 'lbl '
    public static let codestreamHeader     = JP2BoxType(rawValue: 0x6A706368) // 'jpch'
    public static let compositingLayerHdr  = JP2BoxType(rawValue: 0x6A706C68) // 'jplh'
    public static let colourGroup          = JP2BoxType(rawValue: 0x63677270) // 'cgrp'
}

/// Validated zero-copy reference to a box header and payload range within a container byte buffer.
struct JP2BoxSlice: Sendable, Equatable {
    let type: JP2BoxType
    let headerOffset: Int
    let headerSize: Int
    let totalLength: Int
    let payloadRange: Range<Int>

    var payloadLength: Int { payloadRange.count }
}

/// Bounds-checked ISO/IEC 15444-1 Annex I.4 box reader with nesting-depth enforcement.
struct JP2BoxReader: Sendable {
    let bytes: [UInt8]
    let range: Range<Int>
    let depth: Int
    let limits: ResourceLimits
    private(set) var offset: Int

    init(bytes: [UInt8], range: Range<Int>? = nil, depth: Int = 1, limits: ResourceLimits) throws {
        let effectiveRange = range ?? (0..<bytes.count)
        guard effectiveRange.lowerBound >= 0,
              effectiveRange.upperBound <= bytes.count,
              effectiveRange.lowerBound <= effectiveRange.upperBound else {
            throw CodecError(.malformedInput, "Container box range is out of bounds.")
        }
        guard depth <= limits.maximumNestingDepth else {
            throw CodecError(.resourceLimitExceeded, "Container box nesting depth (\(depth)) exceeds maximumNestingDepth (\(limits.maximumNestingDepth)).")
        }
        self.bytes = bytes
        self.range = effectiveRange
        self.depth = depth
        self.limits = limits
        self.offset = effectiveRange.lowerBound
    }

    var hasMoreBoxes: Bool {
        offset < range.upperBound
    }

    mutating func nextBox() throws -> JP2BoxSlice? {
        guard offset < range.upperBound else { return nil }
        let remaining = range.upperBound - offset
        guard remaining >= 8 else {
            throw CodecError(.malformedInput, "Truncated JP2 box header at offset \(offset) (\(remaining) bytes remaining).")
        }
        let lbox = Self.readUInt32(bytes, at: offset)
        let tbox = Self.readUInt32(bytes, at: offset + 4)
        let boxType = JP2BoxType(rawValue: tbox)

        let headerSize: Int
        let totalLength: Int

        if lbox == 0 {
            // Box extends to the end of the enclosing container or superbox.
            headerSize = 8
            totalLength = remaining
        } else if lbox == 1 {
            // Extended 64-bit box length (XLBox).
            guard remaining >= 16 else {
                throw CodecError(.malformedInput, "Truncated extended JP2 box header ('\(boxType)') at offset \(offset).")
            }
            let xlbox = Self.readUInt64(bytes, at: offset + 8)
            guard xlbox >= 16 else {
                throw CodecError(.malformedInput, "Invalid extended JP2 box length \(xlbox) (< 16) for '\(boxType)' at offset \(offset).")
            }
            guard xlbox <= UInt64(Int.max) else {
                throw CodecError(.resourceLimitExceeded, "Extended JP2 box length \(xlbox) overflows addressable range.")
            }
            headerSize = 16
            totalLength = Int(xlbox)
        } else if lbox < 8 {
            throw CodecError(.malformedInput, "Invalid JP2 box length \(lbox) (< 8) for '\(boxType)' at offset \(offset).")
        } else {
            headerSize = 8
            totalLength = Int(lbox)
        }

        let boxEnd = try checkedAdd(offset, totalLength)
        guard boxEnd <= range.upperBound else {
            throw CodecError(.malformedInput, "JP2 box '\(boxType)' at offset \(offset) of length \(totalLength) exceeds enclosing boundary (\(range.upperBound)).")
        }
        let payloadStart = try checkedAdd(offset, headerSize)
        let slice = JP2BoxSlice(
            type: boxType,
            headerOffset: offset,
            headerSize: headerSize,
            totalLength: totalLength,
            payloadRange: payloadStart..<boxEnd
        )
        offset = boxEnd
        return slice
    }

    func childReader(for slice: JP2BoxSlice) throws -> JP2BoxReader {
        try JP2BoxReader(bytes: bytes, range: slice.payloadRange, depth: try checkedAdd(depth, 1), limits: limits)
    }

    static func readUInt16(_ bytes: [UInt8], at index: Int) -> UInt16 {
        (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
    }

    static func readUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (UInt32(bytes[index]) << 24)
            | (UInt32(bytes[index + 1]) << 16)
            | (UInt32(bytes[index + 2]) << 8)
            | UInt32(bytes[index + 3])
    }

    static func readUInt64(_ bytes: [UInt8], at index: Int) -> UInt64 {
        let hi = UInt64(readUInt32(bytes, at: index))
        let lo = UInt64(readUInt32(bytes, at: index + 4))
        return (hi << 32) | lo
    }
}

/// Bounds-checked ISO/IEC 15444-1 Annex I.4 box writer.
struct JP2BoxWriter: Sendable {
    private(set) var bytes: [UInt8] = []

    init(capacity: Int = 256) {
        bytes.reserveCapacity(capacity)
    }

    mutating func appendBox(type: JP2BoxType, payload: [UInt8], useExtendedLength: Bool = false) throws {
        let headerSize = (useExtendedLength || payload.count > Int(UInt32.max) - 8) ? 16 : 8
        let totalLength = try checkedAdd(headerSize, payload.count)
        if headerSize == 8 {
            Self.appendUInt32(&bytes, UInt32(totalLength))
            Self.appendUInt32(&bytes, type.rawValue)
        } else {
            Self.appendUInt32(&bytes, 1)
            Self.appendUInt32(&bytes, type.rawValue)
            Self.appendUInt64(&bytes, UInt64(totalLength))
        }
        bytes.append(contentsOf: payload)
    }

    static func appendUInt16(_ out: inout [UInt8], _ value: UInt16) {
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8(value & 0xFF))
    }

    static func appendUInt32(_ out: inout [UInt8], _ value: UInt32) {
        out.append(UInt8((value >> 24) & 0xFF))
        out.append(UInt8((value >> 16) & 0xFF))
        out.append(UInt8((value >> 8) & 0xFF))
        out.append(UInt8(value & 0xFF))
    }

    static func appendUInt64(_ out: inout [UInt8], _ value: UInt64) {
        appendUInt32(&out, UInt32((value >> 32) & 0xFFFF_FFFF))
        appendUInt32(&out, UInt32(value & 0xFFFF_FFFF))
    }
}
