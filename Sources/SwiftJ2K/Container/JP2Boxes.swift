// SPDX-License-Identifier: Apache-2.0
//
// Adapted from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   Sources/J2KFileFormat/J2KBoxes.swift
//   Sources/J2KFileFormat/J2KPart2Boxes.swift
//
// Changes for the SwiftJ2K contract:
// - Fixed ihdr BPC encoding to use (bitDepth - 1) | (isSigned ? 0x80 : 0x00)
//   and 0xFF when components vary and a bpcc box is present.
// - Fixed ftyp compatibility list to include 'jp2 ' for JP2 files and 'jph '/'jp2 '
//   for JPH files per ISO/IEC 15444-1 Annex I.5.2 and ISO/IEC 15444-15 Annex A.
// - Fixed resc and resd boxes to use the standard 10-byte ISO/IEC 15444-1 Annex
//   I.5.3.7 layout (VRN, VRD, HRN, HRD, VRE, HRE) instead of the predecessor's
//   non-standard 19-byte layout.
// - Fixed colr precedence signedness (Int8), approximation range (0...4), and
//   pre-allocation ResourceLimits.maximumICCBytes / maximumMetadataBytes checks.
// - Fixed pclr 32..38-bit shift overflow by storing palette entries in Int64.
// - Fixed JP2HeaderSuperbox ('jp2h') parser to parse all child boxes (ihdr, bpcc,
//   colr, pclr, cmap, cdef, res ) rather than discarding everything after ihdr.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - 1. JPEG 2000 Signature Box ('jP  ', ISO/IEC 15444-1 I.5.1)

enum JP2SignatureBox {
    static let expectedPayload: [UInt8] = [0x0D, 0x0A, 0x87, 0x0A]
    static let fullBoxBytes: [UInt8] = [
        0x00, 0x00, 0x00, 0x0C,
        0x6A, 0x50, 0x20, 0x20,
        0x0D, 0x0A, 0x87, 0x0A
    ]

    static func validate(bytes: [UInt8], range: Range<Int>) throws {
        guard range.count == 4,
              bytes[range.lowerBound] == 0x0D,
              bytes[range.lowerBound + 1] == 0x0A,
              bytes[range.lowerBound + 2] == 0x87,
              bytes[range.lowerBound + 3] == 0x0A else {
            throw CodecError(.malformedInput, "Invalid JPEG 2000 signature box ('jP  ') payload.")
        }
    }
}

// MARK: - 2. File Type Box ('ftyp', ISO/IEC 15444-1 I.5.2)

public struct JP2FileTypeBox: Sendable, Equatable {
    public static let brandJP2 = "jp2 "
    public static let brandJPH = "jph "
    public static let brandJPX = "jpx "
    public static let brandJPXB = "jpxb"

    public let brand: String
    public let minorVersion: UInt32
    public let compatibleBrands: [String]

    public init(brand: String, minorVersion: UInt32 = 0, compatibleBrands: [String]) throws {
        guard JP2BoxType(fourCC: brand) != nil,
              compatibleBrands.allSatisfy({ JP2BoxType(fourCC: $0) != nil }) else {
            throw CodecError(.invalidArgument, "File type box brand identifiers must be 4-byte strings.")
        }
        self.brand = brand
        self.minorVersion = minorVersion
        self.compatibleBrands = compatibleBrands
    }

    static func parse(bytes: [UInt8], range: Range<Int>) throws -> JP2FileTypeBox {
        let len = range.count
        guard len >= 8, (len - 8) % 4 == 0 else {
            throw CodecError(.malformedInput, "Invalid 'ftyp' box length \(len).")
        }
        let start = range.lowerBound
        let br = String(bytes[start..<(start + 4)].map { Character(UnicodeScalar($0)) })
        let minV = JP2BoxReader.readUInt32(bytes, at: start + 4)
        let count = (len - 8) / 4
        var cl: [String] = []
        cl.reserveCapacity(count)
        for i in 0..<count {
            let off = start + 8 + i * 4
            cl.append(String(bytes[off..<(off + 4)].map { Character(UnicodeScalar($0)) }))
        }
        return try JP2FileTypeBox(brand: br, minorVersion: minV, compatibleBrands: cl)
    }

    func serialise() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(8 + compatibleBrands.count * 4)
        for scalar in brand.unicodeScalars {
            out.append(UInt8(scalar.value & 0xFF))
        }
        JP2BoxWriter.appendUInt32(&out, minorVersion)
        for cb in compatibleBrands {
            for scalar in cb.unicodeScalars {
                out.append(UInt8(scalar.value & 0xFF))
            }
        }
        return out
    }

    /// Resolves the canonical container format string (`"jp2"`, `"jph"`, `"jpx"`).
    func resolvedFormat() throws -> String {
        if brand == Self.brandJPH {
            return "jph"
        }
        if brand == Self.brandJPX || brand == Self.brandJPXB {
            return "jpx"
        }
        if brand == Self.brandJP2 {
            return "jp2"
        }
        if compatibleBrands.contains(Self.brandJPH) {
            return "jph"
        }
        if compatibleBrands.contains(Self.brandJPX) || compatibleBrands.contains(Self.brandJPXB) {
            return "jpx"
        }
        if compatibleBrands.contains(Self.brandJP2) {
            return "jp2"
        }
        throw CodecError(.unsupportedFormat, "Unsupported JP2 file type brand '\(brand)' (compatible: \(compatibleBrands)).")
    }
}

// MARK: - 3. Component Bit Depth ('ihdr' / 'bpcc' / 'pclr' encoding)

public struct JP2ComponentBitDepth: Sendable, Equatable {
    public let bitDepth: Int
    public let isSigned: Bool

    public init(bitDepth: Int, isSigned: Bool) throws {
        guard bitDepth >= 1 && bitDepth <= 38 else {
            throw CodecError(.invalidArgument, "JP2 component bit depth must lie in 1...38 (got \(bitDepth)).")
        }
        self.bitDepth = bitDepth
        self.isSigned = isSigned
    }

    public init(encodedByte: UInt8) throws {
        let depth = Int(encodedByte & 0x7F) + 1
        let signed = (encodedByte & 0x80) != 0
        guard depth >= 1 && depth <= 38 else {
            throw CodecError(.malformedInput, "Invalid JP2 encoded bit depth \(depth) (byte 0x\(String(encodedByte, radix: 16))).")
        }
        self.bitDepth = depth
        self.isSigned = signed
    }

    public var encodedByte: UInt8 {
        UInt8((bitDepth - 1) & 0x7F) | (isSigned ? 0x80 : 0x00)
    }
}

// MARK: - 4. Image Header Box ('ihdr', ISO/IEC 15444-1 I.5.3.1)

public struct JP2ImageHeaderBox: Sendable, Equatable {
    public let height: UInt32
    public let width: UInt32
    public let numComponents: UInt16
    /// `nil` when `BPC == 0xFF` (component bit depths vary and are given in `'bpcc'`).
    public let uniformBitDepth: JP2ComponentBitDepth?
    public let compressionType: UInt8
    public let unknownColourspace: Bool
    public let hasIntellectualProperty: Bool

    public init(
        height: UInt32,
        width: UInt32,
        numComponents: UInt16,
        uniformBitDepth: JP2ComponentBitDepth?,
        compressionType: UInt8 = 7,
        unknownColourspace: Bool = false,
        hasIntellectualProperty: Bool = false
    ) throws {
        guard height > 0, width > 0 else {
            throw CodecError(.invalidArgument, "JP2 'ihdr' dimensions must be positive.")
        }
        guard numComponents >= 1 && numComponents <= 16384 else {
            throw CodecError(.invalidArgument, "JP2 'ihdr' component count must lie in 1...16384.")
        }
        guard compressionType == 7 else {
            throw CodecError(.unsupportedFormat, "Unsupported JP2 'ihdr' compression type \(compressionType) (expected 7).")
        }
        self.height = height
        self.width = width
        self.numComponents = numComponents
        self.uniformBitDepth = uniformBitDepth
        self.compressionType = compressionType
        self.unknownColourspace = unknownColourspace
        self.hasIntellectualProperty = hasIntellectualProperty
    }

    static func parse(bytes: [UInt8], range: Range<Int>) throws -> JP2ImageHeaderBox {
        guard range.count == 14 else {
            throw CodecError(.malformedInput, "Invalid 'ihdr' box payload length \(range.count) (expected 14).")
        }
        let s = range.lowerBound
        let h = JP2BoxReader.readUInt32(bytes, at: s)
        let w = JP2BoxReader.readUInt32(bytes, at: s + 4)
        let nc = JP2BoxReader.readUInt16(bytes, at: s + 8)
        let bpcByte = bytes[s + 10]
        let c = bytes[s + 11]
        let unkc = bytes[s + 12]
        let ipr = bytes[s + 13]

        guard h > 0, w > 0 else {
            throw CodecError(.malformedInput, "JP2 'ihdr' declares zero width or height (\(w)x\(h)).")
        }
        guard nc >= 1 && nc <= 16384 else {
            throw CodecError(.malformedInput, "JP2 'ihdr' declares invalid component count \(nc).")
        }
        guard c == 7 else {
            throw CodecError(.unsupportedFormat, "Unsupported JP2 'ihdr' compression type \(c) (expected 7).")
        }
        guard unkc <= 1, ipr <= 1 else {
            throw CodecError(.malformedInput, "Invalid 'ihdr' UnkC (\(unkc)) or IPR (\(ipr)) flag.")
        }
        let uniform: JP2ComponentBitDepth? = (bpcByte == 0xFF) ? nil : try JP2ComponentBitDepth(encodedByte: bpcByte)
        return try JP2ImageHeaderBox(
            height: h,
            width: w,
            numComponents: nc,
            uniformBitDepth: uniform,
            compressionType: c,
            unknownColourspace: unkc == 1,
            hasIntellectualProperty: ipr == 1
        )
    }

    func serialise() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(14)
        JP2BoxWriter.appendUInt32(&out, height)
        JP2BoxWriter.appendUInt32(&out, width)
        JP2BoxWriter.appendUInt16(&out, numComponents)
        out.append(uniformBitDepth?.encodedByte ?? 0xFF)
        out.append(compressionType)
        out.append(unknownColourspace ? 1 : 0)
        out.append(hasIntellectualProperty ? 1 : 0)
        return out
    }
}

// MARK: - 5. Bits Per Component Box ('bpcc', ISO/IEC 15444-1 I.5.3.2)

public struct JP2BitsPerComponentBox: Sendable, Equatable {
    public let components: [JP2ComponentBitDepth]

    public init(components: [JP2ComponentBitDepth]) throws {
        guard !components.isEmpty && components.count <= 16384 else {
            throw CodecError(.invalidArgument, "JP2 'bpcc' component list must contain 1...16384 entries.")
        }
        self.components = components
    }

    static func parse(bytes: [UInt8], range: Range<Int>, expectedCount: Int) throws -> JP2BitsPerComponentBox {
        guard range.count == expectedCount else {
            throw CodecError(.malformedInput, "JP2 'bpcc' length (\(range.count)) does not match 'ihdr' component count (\(expectedCount)).")
        }
        var list: [JP2ComponentBitDepth] = []
        list.reserveCapacity(expectedCount)
        for idx in range {
            list.append(try JP2ComponentBitDepth(encodedByte: bytes[idx]))
        }
        return try JP2BitsPerComponentBox(components: list)
    }

    func serialise() -> [UInt8] {
        components.map(\.encodedByte)
    }
}

// MARK: - 6. Colour Specification Box ('colr', ISO/IEC 15444-1 I.5.3.3 & 15444-2 M.11.7)

public struct JP2ColourSpecificationBox: Sendable, Equatable {
    public enum EnumeratedColourSpace: UInt32, Sendable, Equatable {
        case bilevel1   = 0
        case yCbCr1     = 1
        case yCbCr2     = 3
        case yCbCr3     = 4
        case photoYCC   = 9
        case cmy        = 11
        case cmyk       = 12
        case ycck       = 13
        case cieLab     = 14
        case bilevel2   = 15
        case sRGB       = 16
        case greyscale  = 17
        case sYCC       = 18
        case cieJab     = 19
        case eSRGB      = 20
        case rommRGB    = 21
        case yPbPr1125  = 22
        case yPbPr1250  = 23
        case eSYCC      = 24
    }

    public enum Method: Sendable, Equatable {
        case enumerated(UInt32)
        case restrictedICC(Data)
        case anyICC(Data)
        case vendor(uuid: [UInt8], payload: Data)
    }

    public let method: Method
    public let precedence: Int8
    public let approximation: UInt8

    public init(method: Method, precedence: Int8 = 0, approximation: UInt8 = 0) throws {
        guard approximation <= 4 else {
            throw CodecError(.invalidArgument, "JP2 'colr' approximation must lie in 0...4 (got \(approximation)).")
        }
        if case .vendor(let uuid, _) = method, uuid.count != 16 {
            throw CodecError(.invalidArgument, "JP2 'colr' vendor method requires a 16-byte UUID.")
        }
        self.method = method
        self.precedence = precedence
        self.approximation = approximation
    }

    static func parse(
        bytes: [UInt8],
        range: Range<Int>,
        limits: ResourceLimits,
        runningMetadataBytes: inout Int
    ) throws -> JP2ColourSpecificationBox {
        let len = range.count
        guard len >= 3 else {
            throw CodecError(.malformedInput, "Truncated 'colr' box (length \(len) < 3).")
        }
        let s = range.lowerBound
        let meth = bytes[s]
        let prec = Int8(bitPattern: bytes[s + 1])
        let approx = bytes[s + 2]
        guard approx <= 4 else {
            throw CodecError(.malformedInput, "Invalid 'colr' approximation value \(approx).")
        }

        switch meth {
        case 1:
            guard len >= 7 else {
                throw CodecError(.malformedInput, "Truncated enumerated 'colr' box (length \(len) < 7).")
            }
            let enumCS = JP2BoxReader.readUInt32(bytes, at: s + 3)
            return try JP2ColourSpecificationBox(method: .enumerated(enumCS), precedence: prec, approximation: approx)
        case 2, 3:
            let iccLen = len - 3
            guard iccLen > 0 else {
                throw CodecError(.malformedInput, "Empty ICC profile in 'colr' box (METH=\(meth)).")
            }
            guard iccLen <= limits.maximumICCBytes else {
                throw CodecError(.resourceLimitExceeded, "ICC profile in 'colr' box (\(iccLen) bytes) exceeds maximumICCBytes (\(limits.maximumICCBytes)).")
            }
            runningMetadataBytes = try checkedAdd(runningMetadataBytes, iccLen)
            guard runningMetadataBytes <= limits.maximumMetadataBytes else {
                throw CodecError(.resourceLimitExceeded, "Container metadata + ICC profile (\(runningMetadataBytes) bytes) exceeds maximumMetadataBytes (\(limits.maximumMetadataBytes)).")
            }
            let iccData = Data(bytes[(s + 3)..<range.upperBound])
            let m: Method = (meth == 2) ? .restrictedICC(iccData) : .anyICC(iccData)
            return try JP2ColourSpecificationBox(method: m, precedence: prec, approximation: approx)
        case 4:
            guard len >= 19 else {
                throw CodecError(.malformedInput, "Truncated vendor 'colr' box (length \(len) < 19).")
            }
            let payloadLen = len - 3
            runningMetadataBytes = try checkedAdd(runningMetadataBytes, payloadLen)
            guard runningMetadataBytes <= limits.maximumMetadataBytes else {
                throw CodecError(.resourceLimitExceeded, "Vendor 'colr' box exceeds maximumMetadataBytes (\(limits.maximumMetadataBytes)).")
            }
            let uuid = Array(bytes[(s + 3)..<(s + 19)])
            let vendorData = Data(bytes[(s + 19)..<range.upperBound])
            return try JP2ColourSpecificationBox(method: .vendor(uuid: uuid, payload: vendorData), precedence: prec, approximation: approx)
        default:
            throw CodecError(.malformedInput, "Unknown 'colr' specification method \(meth).")
        }
    }

    func serialise() -> [UInt8] {
        var out: [UInt8] = []
        switch method {
        case .enumerated(let enumCS):
            out.reserveCapacity(7)
            out.append(1)
            out.append(UInt8(bitPattern: precedence))
            out.append(approximation)
            JP2BoxWriter.appendUInt32(&out, enumCS)
        case .restrictedICC(let icc):
            out.reserveCapacity(3 + icc.count)
            out.append(2)
            out.append(UInt8(bitPattern: precedence))
            out.append(approximation)
            out.append(contentsOf: icc)
        case .anyICC(let icc):
            out.reserveCapacity(3 + icc.count)
            out.append(3)
            out.append(UInt8(bitPattern: precedence))
            out.append(approximation)
            out.append(contentsOf: icc)
        case .vendor(let uuid, let payload):
            out.reserveCapacity(19 + payload.count)
            out.append(4)
            out.append(UInt8(bitPattern: precedence))
            out.append(approximation)
            out.append(contentsOf: uuid)
            out.append(contentsOf: payload)
        }
        return out
    }
}

// MARK: - 7. Palette Box ('pclr', ISO/IEC 15444-1 I.5.3.4)

public struct JP2PaletteBox: Sendable, Equatable {
    public let numEntries: Int
    public let columns: [JP2ComponentBitDepth]
    /// `values[entryIndex][columnIndex]` stored as `Int64` to support up to 38-bit signed/unsigned palette entries without overflow.
    public let values: [[Int64]]

    public init(columns: [JP2ComponentBitDepth], values: [[Int64]]) throws {
        guard !values.isEmpty && values.count <= 1024 else {
            throw CodecError(.invalidArgument, "JP2 'pclr' entry count must lie in 1...1024.")
        }
        guard !columns.isEmpty && columns.count <= 255 else {
            throw CodecError(.invalidArgument, "JP2 'pclr' column count must lie in 1...255.")
        }
        for row in values {
            guard row.count == columns.count else {
                throw CodecError(.invalidArgument, "JP2 'pclr' row width does not match column count.")
            }
            for (cIdx, col) in columns.enumerated() {
                let v = row[cIdx]
                if col.isSigned {
                    let minVal = -(Int64(1) << (col.bitDepth - 1))
                    let maxVal = (Int64(1) << (col.bitDepth - 1)) - 1
                    guard v >= minVal && v <= maxVal else {
                        throw CodecError(.invalidArgument, "JP2 'pclr' signed value \(v) out of \(col.bitDepth)-bit range.")
                    }
                } else {
                    let maxVal = (Int64(1) << col.bitDepth) - 1
                    guard v >= 0 && v <= maxVal else {
                        throw CodecError(.invalidArgument, "JP2 'pclr' unsigned value \(v) out of \(col.bitDepth)-bit range.")
                    }
                }
            }
        }
        self.numEntries = values.count
        self.columns = columns
        self.values = values
    }

    static func parse(bytes: [UInt8], range: Range<Int>) throws -> JP2PaletteBox {
        let len = range.count
        guard len >= 4 else {
            throw CodecError(.malformedInput, "Truncated 'pclr' box (length \(len) < 4).")
        }
        let s = range.lowerBound
        let ne = Int(JP2BoxReader.readUInt16(bytes, at: s))
        let npc = Int(bytes[s + 2])
        guard ne >= 1 && ne <= 1024, npc >= 1 && npc <= 255 else {
            throw CodecError(.malformedInput, "Invalid 'pclr' NE (\(ne)) or NPC (\(npc)).")
        }
        let headerBytes = 3 + npc
        guard len >= headerBytes else {
            throw CodecError(.malformedInput, "Truncated 'pclr' column bit-depth table.")
        }
        var cols: [JP2ComponentBitDepth] = []
        cols.reserveCapacity(npc)
        var rowBytes = 0
        for i in 0..<npc {
            let col = try JP2ComponentBitDepth(encodedByte: bytes[s + 3 + i])
            cols.append(col)
            rowBytes += (col.bitDepth + 7) / 8
        }
        let expectedTotal = try checkedAdd(headerBytes, try checkedMultiply(ne, rowBytes))
        guard len == expectedTotal else {
            throw CodecError(.malformedInput, "Invalid 'pclr' box payload length \(len) (expected \(expectedTotal)).")
        }

        var cursor = s + headerBytes
        var rows: [[Int64]] = []
        rows.reserveCapacity(ne)
        for _ in 0..<ne {
            var row: [Int64] = []
            row.reserveCapacity(npc)
            for col in cols {
                let byteWidth = (col.bitDepth + 7) / 8
                var raw: UInt64 = 0
                for _ in 0..<byteWidth {
                    raw = (raw << 8) | UInt64(bytes[cursor])
                    cursor += 1
                }
                let mask: UInt64 = (col.bitDepth == 64) ? UInt64.max : ((UInt64(1) << col.bitDepth) - 1)
                raw &= mask
                if col.isSigned {
                    let signBit = UInt64(1) << (col.bitDepth - 1)
                    if (raw & signBit) != 0 {
                        let signedVal = Int64(raw) - (Int64(1) << col.bitDepth)
                        row.append(signedVal)
                    } else {
                        row.append(Int64(raw))
                    }
                } else {
                    row.append(Int64(raw))
                }
            }
            rows.append(row)
        }
        return try JP2PaletteBox(columns: cols, values: rows)
    }

    func serialise() -> [UInt8] {
        let npc = columns.count
        let rowBytes = columns.reduce(0) { $0 + ($1.bitDepth + 7) / 8 }
        var out: [UInt8] = []
        out.reserveCapacity(3 + npc + numEntries * rowBytes)
        JP2BoxWriter.appendUInt16(&out, UInt16(numEntries))
        out.append(UInt8(npc))
        for col in columns {
            out.append(col.encodedByte)
        }
        for row in values {
            for (cIdx, col) in columns.enumerated() {
                let byteWidth = (col.bitDepth + 7) / 8
                let mask: UInt64 = (UInt64(1) << col.bitDepth) - 1
                let raw = UInt64(bitPattern: row[cIdx]) & mask
                for shift in stride(from: (byteWidth - 1) * 8, through: 0, by: -8) {
                    out.append(UInt8((raw >> shift) & 0xFF))
                }
            }
        }
        return out
    }
}

// MARK: - 8. Component Mapping Box ('cmap', ISO/IEC 15444-1 I.5.3.5)

public struct JP2ComponentMappingBox: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let componentIndex: UInt16
        /// `0` = direct use of codestream component, `1` = palette mapping through `'pclr'`.
        public let mappingType: UInt8
        public let paletteColumn: UInt8

        public init(componentIndex: UInt16, mappingType: UInt8, paletteColumn: UInt8) throws {
            guard mappingType == 0 || mappingType == 1 else {
                throw CodecError(.invalidArgument, "JP2 'cmap' mappingType must be 0 (direct) or 1 (palette).")
            }
            if mappingType == 0 && paletteColumn != 0 {
                throw CodecError(.invalidArgument, "JP2 'cmap' direct mapping requires paletteColumn == 0.")
            }
            self.componentIndex = componentIndex
            self.mappingType = mappingType
            self.paletteColumn = paletteColumn
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) throws {
        guard !entries.isEmpty && entries.count <= 16384 else {
            throw CodecError(.invalidArgument, "JP2 'cmap' must contain 1...16384 channel mappings.")
        }
        self.entries = entries
    }

    static func parse(bytes: [UInt8], range: Range<Int>) throws -> JP2ComponentMappingBox {
        let len = range.count
        guard len >= 4 && len % 4 == 0 else {
            throw CodecError(.malformedInput, "Invalid 'cmap' box length \(len) (must be a positive multiple of 4).")
        }
        let count = len / 4
        var list: [Entry] = []
        list.reserveCapacity(count)
        for i in 0..<count {
            let off = range.lowerBound + i * 4
            let cmp = JP2BoxReader.readUInt16(bytes, at: off)
            let mtyp = bytes[off + 2]
            let pcol = bytes[off + 3]
            guard mtyp == 0 || mtyp == 1 else {
                throw CodecError(.malformedInput, "Invalid 'cmap' MTYP \(mtyp) at entry \(i).")
            }
            list.append(try Entry(componentIndex: cmp, mappingType: mtyp, paletteColumn: pcol))
        }
        return try JP2ComponentMappingBox(entries: list)
    }

    func serialise() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(entries.count * 4)
        for entry in entries {
            JP2BoxWriter.appendUInt16(&out, entry.componentIndex)
            out.append(entry.mappingType)
            out.append(entry.paletteColumn)
        }
        return out
    }
}

// MARK: - 9. Channel Definition Box ('cdef', ISO/IEC 15444-1 I.5.3.6)

public struct JP2ChannelDefinitionBox: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let channelIndex: UInt16
        /// `0` = colour, `1` = opacity (straight alpha), `2` = premultiplied opacity, `65535` = unspecified.
        public let channelType: UInt16
        /// `0` = whole image, `1...65534` = 1-based colour channel association, `65535` = unassociated.
        public let association: UInt16

        public init(channelIndex: UInt16, channelType: UInt16, association: UInt16) {
            self.channelIndex = channelIndex
            self.channelType = channelType
            self.association = association
        }
    }

    public let entries: [Entry]

    public init(entries: [Entry]) throws {
        guard !entries.isEmpty && entries.count <= 16384 else {
            throw CodecError(.invalidArgument, "JP2 'cdef' must contain 1...16384 channel descriptions.")
        }
        var seenChannels = Set<UInt16>()
        for entry in entries {
            guard seenChannels.insert(entry.channelIndex).inserted else {
                throw CodecError(.invalidArgument, "Duplicate channel index \(entry.channelIndex) in 'cdef' box.")
            }
            guard entry.channelType <= 2 || entry.channelType == 0xFFFF else {
                throw CodecError(.invalidArgument, "Invalid 'cdef' channel type \(entry.channelType).")
            }
        }
        self.entries = entries
    }

    static func parse(bytes: [UInt8], range: Range<Int>) throws -> JP2ChannelDefinitionBox {
        let len = range.count
        guard len >= 8 else {
            throw CodecError(.malformedInput, "Truncated 'cdef' box (length \(len) < 8).")
        }
        let s = range.lowerBound
        let n = Int(JP2BoxReader.readUInt16(bytes, at: s))
        let expectedLen = try checkedAdd(2, try checkedMultiply(n, 6))
        guard n >= 1, len == expectedLen else {
            throw CodecError(.malformedInput, "Invalid 'cdef' box length \(len) for N=\(n) (expected \(expectedLen)).")
        }
        var list: [Entry] = []
        list.reserveCapacity(n)
        var seen = Set<UInt16>()
        for i in 0..<n {
            let off = s + 2 + i * 6
            let cn = JP2BoxReader.readUInt16(bytes, at: off)
            let typ = JP2BoxReader.readUInt16(bytes, at: off + 2)
            let asoc = JP2BoxReader.readUInt16(bytes, at: off + 4)
            guard seen.insert(cn).inserted else {
                throw CodecError(.malformedInput, "Duplicate channel index \(cn) in 'cdef' box.")
            }
            guard typ <= 2 || typ == 0xFFFF else {
                throw CodecError(.malformedInput, "Invalid 'cdef' channel type \(typ) for channel \(cn).")
            }
            list.append(Entry(channelIndex: cn, channelType: typ, association: asoc))
        }
        return try JP2ChannelDefinitionBox(entries: list)
    }

    func serialise() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(2 + entries.count * 6)
        JP2BoxWriter.appendUInt16(&out, UInt16(entries.count))
        for entry in entries {
            JP2BoxWriter.appendUInt16(&out, entry.channelIndex)
            JP2BoxWriter.appendUInt16(&out, entry.channelType)
            JP2BoxWriter.appendUInt16(&out, entry.association)
        }
        return out
    }
}

// MARK: - 10. Resolution Superbox ('res ') & Capture/Display Resolution ('resc'/'resd', ISO/IEC 15444-1 I.5.3.7)

public struct JP2GridResolution: Sendable, Equatable {
    public let verticalNumerator: UInt16
    public let verticalDenominator: UInt16
    public let horizontalNumerator: UInt16
    public let horizontalDenominator: UInt16
    public let verticalExponent: Int8
    public let horizontalExponent: Int8

    public init(
        verticalNumerator: UInt16,
        verticalDenominator: UInt16 = 1,
        horizontalNumerator: UInt16,
        horizontalDenominator: UInt16 = 1,
        verticalExponent: Int8 = 0,
        horizontalExponent: Int8 = 0
    ) throws {
        guard verticalNumerator > 0, verticalDenominator > 0,
              horizontalNumerator > 0, horizontalDenominator > 0 else {
            throw CodecError(.invalidArgument, "JP2 resolution numerators and denominators must be non-zero.")
        }
        self.verticalNumerator = verticalNumerator
        self.verticalDenominator = verticalDenominator
        self.horizontalNumerator = horizontalNumerator
        self.horizontalDenominator = horizontalDenominator
        self.verticalExponent = verticalExponent
        self.horizontalExponent = horizontalExponent
    }

    public var verticalPixelsPerMetre: Double {
        (Double(verticalNumerator) / Double(verticalDenominator)) * pow(10.0, Double(verticalExponent))
    }

    public var horizontalPixelsPerMetre: Double {
        (Double(horizontalNumerator) / Double(horizontalDenominator)) * pow(10.0, Double(horizontalExponent))
    }

    static func parse(bytes: [UInt8], range: Range<Int>, boxName: String) throws -> JP2GridResolution {
        guard range.count == 10 else {
            throw CodecError(.malformedInput, "Invalid '\(boxName)' payload length \(range.count) (expected 10 bytes per ISO/IEC 15444-1 I.5.3.7).")
        }
        let s = range.lowerBound
        let vrn = JP2BoxReader.readUInt16(bytes, at: s)
        let vrd = JP2BoxReader.readUInt16(bytes, at: s + 2)
        let hrn = JP2BoxReader.readUInt16(bytes, at: s + 4)
        let hrd = JP2BoxReader.readUInt16(bytes, at: s + 6)
        let vre = Int8(bitPattern: bytes[s + 8])
        let hre = Int8(bitPattern: bytes[s + 9])
        guard vrn > 0, vrd > 0, hrn > 0, hrd > 0 else {
            throw CodecError(.malformedInput, "JP2 '\(boxName)' box has zero numerator or denominator.")
        }
        return try JP2GridResolution(
            verticalNumerator: vrn,
            verticalDenominator: vrd,
            horizontalNumerator: hrn,
            horizontalDenominator: hrd,
            verticalExponent: vre,
            horizontalExponent: hre
        )
    }

    func serialise() -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(10)
        JP2BoxWriter.appendUInt16(&out, verticalNumerator)
        JP2BoxWriter.appendUInt16(&out, verticalDenominator)
        JP2BoxWriter.appendUInt16(&out, horizontalNumerator)
        JP2BoxWriter.appendUInt16(&out, horizontalDenominator)
        out.append(UInt8(bitPattern: verticalExponent))
        out.append(UInt8(bitPattern: horizontalExponent))
        return out
    }
}

public struct JP2ResolutionBox: Sendable, Equatable {
    public let capture: JP2GridResolution?
    public let display: JP2GridResolution?

    public init(capture: JP2GridResolution? = nil, display: JP2GridResolution? = nil) throws {
        guard capture != nil || display != nil else {
            throw CodecError(.invalidArgument, "JP2 'res ' superbox must contain at least 'resc' or 'resd'.")
        }
        self.capture = capture
        self.display = display
    }

    static func parse(reader: inout JP2BoxReader) throws -> JP2ResolutionBox {
        var resc: JP2GridResolution?
        var resd: JP2GridResolution?
        while let sub = try reader.nextBox() {
            switch sub.type {
            case .captureResolution:
                guard resc == nil else {
                    throw CodecError(.malformedInput, "Duplicate 'resc' box inside 'res ' superbox.")
                }
                resc = try JP2GridResolution.parse(bytes: reader.bytes, range: sub.payloadRange, boxName: "resc")
            case .displayResolution:
                guard resd == nil else {
                    throw CodecError(.malformedInput, "Duplicate 'resd' box inside 'res ' superbox.")
                }
                resd = try JP2GridResolution.parse(bytes: reader.bytes, range: sub.payloadRange, boxName: "resd")
            default:
                throw CodecError(.malformedInput, "Unexpected box '\(sub.type)' inside 'res ' superbox.")
            }
        }
        guard resc != nil || resd != nil else {
            throw CodecError(.malformedInput, "Empty 'res ' superbox (missing both 'resc' and 'resd').")
        }
        return try JP2ResolutionBox(capture: resc, display: resd)
    }

    func serialise() throws -> [UInt8] {
        var writer = JP2BoxWriter(capacity: 36)
        if let capture {
            try writer.appendBox(type: .captureResolution, payload: capture.serialise())
        }
        if let display {
            try writer.appendBox(type: .displayResolution, payload: display.serialise())
        }
        return writer.bytes
    }
}

// MARK: - 11. JP2 Header Superbox ('jp2h', ISO/IEC 15444-1 I.5.3)

public struct JP2HeaderSuperbox: Sendable, Equatable {
    public let imageHeader: JP2ImageHeaderBox
    public let bitsPerComponent: JP2BitsPerComponentBox?
    public let colourSpecifications: [JP2ColourSpecificationBox]
    public let palette: JP2PaletteBox?
    public let componentMapping: JP2ComponentMappingBox?
    public let channelDefinition: JP2ChannelDefinitionBox?
    public let resolution: JP2ResolutionBox?

    public init(
        imageHeader: JP2ImageHeaderBox,
        bitsPerComponent: JP2BitsPerComponentBox? = nil,
        colourSpecifications: [JP2ColourSpecificationBox],
        palette: JP2PaletteBox? = nil,
        componentMapping: JP2ComponentMappingBox? = nil,
        channelDefinition: JP2ChannelDefinitionBox? = nil,
        resolution: JP2ResolutionBox? = nil
    ) throws {
        if imageHeader.uniformBitDepth == nil {
            guard let bpcc = bitsPerComponent, bpcc.components.count == Int(imageHeader.numComponents) else {
                throw CodecError(.malformedInput, "JP2 'ihdr' with BPC=0xFF requires a matching 'bpcc' box.")
            }
        } else if let bpcc = bitsPerComponent {
            guard bpcc.components.count == Int(imageHeader.numComponents) else {
                throw CodecError(.malformedInput, "JP2 'bpcc' count does not match 'ihdr' component count.")
            }
        }
        if !imageHeader.unknownColourspace && colourSpecifications.isEmpty {
            throw CodecError(.malformedInput, "JP2 'jp2h' requires at least one 'colr' box when UnkC == 0.")
        }
        if (palette != nil) != (componentMapping != nil) {
            throw CodecError(.malformedInput, "JP2 'pclr' and 'cmap' boxes must both be present or both be absent.")
        }
        if let pal = palette, let cmap = componentMapping {
            for entry in cmap.entries {
                guard Int(entry.componentIndex) < Int(imageHeader.numComponents) else {
                    throw CodecError(.malformedInput, "JP2 'cmap' references out-of-range component \(entry.componentIndex).")
                }
                if entry.mappingType == 1 {
                    guard Int(entry.paletteColumn) < pal.columns.count else {
                        throw CodecError(.malformedInput, "JP2 'cmap' references out-of-range palette column \(entry.paletteColumn).")
                    }
                }
            }
        }
        self.imageHeader = imageHeader
        self.bitsPerComponent = bitsPerComponent
        self.colourSpecifications = colourSpecifications
        self.palette = palette
        self.componentMapping = componentMapping
        self.channelDefinition = channelDefinition
        self.resolution = resolution
    }

    static func parse(
        reader: inout JP2BoxReader,
        limits: ResourceLimits,
        runningMetadataBytes: inout Int
    ) throws -> JP2HeaderSuperbox {
        guard let first = try reader.nextBox(), first.type == .imageHeader else {
            throw CodecError(.malformedInput, "First box inside 'jp2h' must be 'ihdr' (ISO/IEC 15444-1 I.5.3.1).")
        }
        let ihdr = try JP2ImageHeaderBox.parse(bytes: reader.bytes, range: first.payloadRange)
        var bpcc: JP2BitsPerComponentBox?
        var colrs: [JP2ColourSpecificationBox] = []
        var pclr: JP2PaletteBox?
        var cmap: JP2ComponentMappingBox?
        var cdef: JP2ChannelDefinitionBox?
        var res: JP2ResolutionBox?

        while let sub = try reader.nextBox() {
            switch sub.type {
            case .imageHeader:
                throw CodecError(.malformedInput, "Duplicate 'ihdr' box inside 'jp2h'.")
            case .bitsPerComponent:
                guard bpcc == nil else {
                    throw CodecError(.malformedInput, "Duplicate 'bpcc' box inside 'jp2h'.")
                }
                bpcc = try JP2BitsPerComponentBox.parse(
                    bytes: reader.bytes,
                    range: sub.payloadRange,
                    expectedCount: Int(ihdr.numComponents)
                )
            case .colourSpecification:
                let colr = try JP2ColourSpecificationBox.parse(
                    bytes: reader.bytes,
                    range: sub.payloadRange,
                    limits: limits,
                    runningMetadataBytes: &runningMetadataBytes
                )
                colrs.append(colr)
            case .palette:
                guard pclr == nil else {
                    throw CodecError(.malformedInput, "Duplicate 'pclr' box inside 'jp2h'.")
                }
                pclr = try JP2PaletteBox.parse(bytes: reader.bytes, range: sub.payloadRange)
            case .componentMapping:
                guard cmap == nil else {
                    throw CodecError(.malformedInput, "Duplicate 'cmap' box inside 'jp2h'.")
                }
                cmap = try JP2ComponentMappingBox.parse(bytes: reader.bytes, range: sub.payloadRange)
            case .channelDefinition:
                guard cdef == nil else {
                    throw CodecError(.malformedInput, "Duplicate 'cdef' box inside 'jp2h'.")
                }
                cdef = try JP2ChannelDefinitionBox.parse(bytes: reader.bytes, range: sub.payloadRange)
            case .resolution:
                guard res == nil else {
                    throw CodecError(.malformedInput, "Duplicate 'res ' box inside 'jp2h'.")
                }
                var resReader = try reader.childReader(for: sub)
                res = try JP2ResolutionBox.parse(reader: &resReader)
            default:
                // Account unknown sub-boxes in jp2h against metadata limits and skip safely.
                runningMetadataBytes = try checkedAdd(runningMetadataBytes, sub.payloadLength)
                guard runningMetadataBytes <= limits.maximumMetadataBytes else {
                    throw CodecError(.resourceLimitExceeded, "Container header metadata exceeds maximumMetadataBytes.")
                }
            }
        }

        return try JP2HeaderSuperbox(
            imageHeader: ihdr,
            bitsPerComponent: bpcc,
            colourSpecifications: colrs,
            palette: pclr,
            componentMapping: cmap,
            channelDefinition: cdef,
            resolution: res
        )
    }

    func serialise() throws -> [UInt8] {
        var writer = JP2BoxWriter(capacity: 128)
        try writer.appendBox(type: .imageHeader, payload: imageHeader.serialise())
        if let bpcc = bitsPerComponent {
            try writer.appendBox(type: .bitsPerComponent, payload: bpcc.serialise())
        }
        for colr in colourSpecifications {
            try writer.appendBox(type: .colourSpecification, payload: colr.serialise())
        }
        if let pclr = palette {
            try writer.appendBox(type: .palette, payload: pclr.serialise())
        }
        if let cmap = componentMapping {
            try writer.appendBox(type: .componentMapping, payload: cmap.serialise())
        }
        if let cdef = channelDefinition {
            try writer.appendBox(type: .channelDefinition, payload: cdef.serialise())
        }
        if let res = resolution {
            try writer.appendBox(type: .resolution, payload: try res.serialise())
        }
        return writer.bytes
    }
}

// MARK: - 12. Ancillary Metadata Boxes ('xml ', 'uuid', 'uinf'/'ulst'/'url ', 'jp2i', 'asoc'/'lbl ')

enum JP2AncillaryMetadataValidator {
    /// Validates a `uuid` box payload (must be at least 16 bytes for the UUID).
    static func validateUUID(bytes: [UInt8], range: Range<Int>) throws {
        guard range.count >= 16 else {
            throw CodecError(.malformedInput, "Truncated 'uuid' box (length \(range.count) < 16).")
        }
    }

    /// Validates a `uinf` superbox (`ulst` + `url `).
    static func validateUUIDInfo(reader: inout JP2BoxReader) throws {
        var hasList = false
        var hasURL = false
        while let sub = try reader.nextBox() {
            switch sub.type {
            case .uuidList:
                guard !hasList, sub.payloadLength >= 2 else {
                    throw CodecError(.malformedInput, "Invalid or duplicate 'ulst' box inside 'uinf'.")
                }
                let nu = Int(JP2BoxReader.readUInt16(reader.bytes, at: sub.payloadRange.lowerBound))
                let expected = try checkedAdd(2, try checkedMultiply(nu, 16))
                guard sub.payloadLength == expected else {
                    throw CodecError(.malformedInput, "Invalid 'ulst' box length \(sub.payloadLength) for NU=\(nu).")
                }
                hasList = true
            case .dataEntryURL:
                guard !hasURL, sub.payloadLength >= 4 else {
                    throw CodecError(.malformedInput, "Invalid or duplicate 'url ' box inside 'uinf'.")
                }
                hasURL = true
            default:
                break
            }
        }
        guard hasList && hasURL else {
            throw CodecError(.malformedInput, "Incomplete 'uinf' superbox (requires both 'ulst' and 'url ').")
        }
    }

    /// Recursively validates an `asoc` (Association) superbox while enforcing `limits.maximumNestingDepth`.
    static func validateAssociation(reader: inout JP2BoxReader) throws {
        while let sub = try reader.nextBox() {
            switch sub.type {
            case .association:
                var nested = try reader.childReader(for: sub)
                try validateAssociation(reader: &nested)
            case .uuidInfo:
                var nested = try reader.childReader(for: sub)
                try validateUUIDInfo(reader: &nested)
            case .uuid:
                try validateUUID(bytes: reader.bytes, range: sub.payloadRange)
            default:
                break
            }
        }
    }
}
