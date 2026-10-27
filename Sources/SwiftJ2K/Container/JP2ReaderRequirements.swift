// SPDX-License-Identifier: Apache-2.0
//
// Adapted from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   Sources/J2KFileFormat/J2KReaderRequirements.swift
//
// Changes for the SwiftJ2K contract:
// - Preserves raw UInt16 standard feature codes alongside named ISO/IEC 15444-2
//   Table M.14 and ISO/IEC 15444-15 Annex A features so valid Kakadu/OpenJPEG
//   JPX and JPH files with extended standard feature codes (e.g. SF=8, 20, 31, 45)
//   parse without failing.
// - Replaces unchecked Data subscripting with bounds-checked [UInt8] range reads.

import Foundation

/// Reader Requirements box (`'rreq'`, `0x72726571`, ISO/IEC 15444-2 Annex M.11.1 & ISO/IEC 15444-15 Annex A).
public struct JP2ReaderRequirementsBox: Sendable, Equatable {
    /// Named standard feature codes from ISO/IEC 15444-2 Table M.14 and ISO/IEC 15444-15 Annex A.
    public enum StandardFeature: UInt16, Sendable, Equatable {
        case codestreamContainsNoExtensions   = 1
        case multipleCompositionLayers        = 2
        case profile0Codestream               = 3
        case profile1Codestream               = 4
        case uncompressedOrReversible         = 5
        case irreversibleCodestream           = 6
        case reversibleColourTransform        = 7
        case irreversibleColourTransform      = 8
        case nonSubsampledCodestream          = 9
        case codestreamContiguous             = 12
        case singleTileCodestream             = 13
        case noRegionOfInterest               = 15
        case sRGBEnumeratedColourSpace        = 18
        case eSRGBEnumeratedColourSpace       = 20
        case greyscaleEnumeratedColourSpace   = 21
        case sYCCEnumeratedColourSpace        = 22
        case restrictedICCProfile             = 31
        case anyICCProfile                    = 32
        case opacityChannel                   = 41
        case premultipliedOpacityChannel      = 42
        case compositingLayerSingleCodestream = 45
        case htj2kCodestream                  = 67
        case htj2kLosslessCodestream          = 68
    }

    public struct StandardFeatureEntry: Sendable, Equatable {
        public let code: UInt16
        public let mask: UInt64

        public var knownFeature: StandardFeature? {
            StandardFeature(rawValue: code)
        }

        public init(code: UInt16, mask: UInt64) {
            self.code = code
            self.mask = mask
        }

        public init(feature: StandardFeature, mask: UInt64) {
            self.code = feature.rawValue
            self.mask = mask
        }
    }

    public struct VendorFeatureEntry: Sendable, Equatable {
        public let uuid: [UInt8] // 16 bytes
        public let mask: UInt64

        public init(uuid: [UInt8], mask: UInt64) throws {
            guard uuid.count == 16 else {
                throw CodecError(.invalidArgument, "Reader requirements vendor UUID must be 16 bytes.")
            }
            self.uuid = uuid
            self.mask = mask
        }
    }

    public let maskLength: UInt8
    public let fuam: UInt64
    public let dcm: UInt64
    public let standardFeatures: [StandardFeatureEntry]
    public let vendorFeatures: [VendorFeatureEntry]

    public init(
        maskLength: UInt8 = 2,
        fuam: UInt64 = 0xFFFF,
        dcm: UInt64 = 0xFFFF,
        standardFeatures: [StandardFeatureEntry],
        vendorFeatures: [VendorFeatureEntry] = []
    ) throws {
        guard maskLength == 1 || maskLength == 2 || maskLength == 4 || maskLength == 8 else {
            throw CodecError(.invalidArgument, "Reader requirements maskLength must be 1, 2, 4, or 8.")
        }
        guard standardFeatures.count <= Int(UInt16.max),
              vendorFeatures.count <= Int(UInt16.max) else {
            throw CodecError(.invalidArgument, "Reader requirements feature count exceeds 65535.")
        }
        self.maskLength = maskLength
        self.fuam = fuam
        self.dcm = dcm
        self.standardFeatures = standardFeatures
        self.vendorFeatures = vendorFeatures
    }

    static func parse(bytes: [UInt8], range: Range<Int>) throws -> JP2ReaderRequirementsBox {
        let len = range.count
        let start = range.lowerBound
        guard len >= 1 else {
            throw CodecError(.malformedInput, "Truncated 'rreq' box (empty payload).")
        }
        let ml = bytes[start]
        guard ml == 1 || ml == 2 || ml == 4 || ml == 8 else {
            throw CodecError(.malformedInput, "Invalid 'rreq' mask length \(ml) (must be 1, 2, 4, or 8).")
        }
        let mlInt = Int(ml)
        let minBeforeNSF = 1 + 2 * mlInt + 2
        guard len >= minBeforeNSF else {
            throw CodecError(.malformedInput, "Truncated 'rreq' box header (length \(len) < \(minBeforeNSF)).")
        }
        var cursor = start + 1
        let fuam = readMask(bytes, at: &cursor, length: mlInt)
        let dcm = readMask(bytes, at: &cursor, length: mlInt)
        let nsf = Int(JP2BoxReader.readUInt16(bytes, at: cursor))
        cursor += 2

        let sfEntryBytes = 2 + mlInt
        let sfTotal = try checkedMultiply(nsf, sfEntryBytes)
        let afterSF = try checkedAdd(cursor, sfTotal)
        let minWithNVF = try checkedAdd(afterSF, 2)
        guard minWithNVF <= range.upperBound else {
            throw CodecError(.malformedInput, "Truncated 'rreq' standard features table (NSF=\(nsf)).")
        }

        var stdFeatures: [StandardFeatureEntry] = []
        stdFeatures.reserveCapacity(nsf)
        for _ in 0..<nsf {
            let sf = JP2BoxReader.readUInt16(bytes, at: cursor)
            cursor += 2
            let sm = readMask(bytes, at: &cursor, length: mlInt)
            stdFeatures.append(StandardFeatureEntry(code: sf, mask: sm))
        }

        let nvf = Int(JP2BoxReader.readUInt16(bytes, at: cursor))
        cursor += 2
        let vfEntryBytes = 16 + mlInt
        let vfTotal = try checkedMultiply(nvf, vfEntryBytes)
        let afterVF = try checkedAdd(cursor, vfTotal)
        guard afterVF <= range.upperBound else {
            throw CodecError(.malformedInput, "Truncated 'rreq' vendor features table (NVF=\(nvf)).")
        }

        var vndFeatures: [VendorFeatureEntry] = []
        vndFeatures.reserveCapacity(nvf)
        for _ in 0..<nvf {
            let uuid = Array(bytes[cursor..<(cursor + 16)])
            cursor += 16
            let vm = readMask(bytes, at: &cursor, length: mlInt)
            vndFeatures.append(try VendorFeatureEntry(uuid: uuid, mask: vm))
        }

        return try JP2ReaderRequirementsBox(
            maskLength: ml,
            fuam: fuam,
            dcm: dcm,
            standardFeatures: stdFeatures,
            vendorFeatures: vndFeatures
        )
    }

    func serialise() -> [UInt8] {
        let mlInt = Int(maskLength)
        var out: [UInt8] = []
        out.reserveCapacity(1 + 2 * mlInt + 2 + standardFeatures.count * (2 + mlInt) + 2 + vendorFeatures.count * (16 + mlInt))
        out.append(maskLength)
        Self.writeMask(&out, fuam, length: mlInt)
        Self.writeMask(&out, dcm, length: mlInt)
        JP2BoxWriter.appendUInt16(&out, UInt16(standardFeatures.count))
        for entry in standardFeatures {
            JP2BoxWriter.appendUInt16(&out, entry.code)
            Self.writeMask(&out, entry.mask, length: mlInt)
        }
        JP2BoxWriter.appendUInt16(&out, UInt16(vendorFeatures.count))
        for entry in vendorFeatures {
            out.append(contentsOf: entry.uuid)
            Self.writeMask(&out, entry.mask, length: mlInt)
        }
        return out
    }

    static func defaultJPX(
        isLossless: Bool,
        isHTJ2K: Bool,
        colour: ColourInterpretation,
        hasAlpha: Bool
    ) throws -> JP2ReaderRequirementsBox {
        var entries: [StandardFeatureEntry] = []
        var bit: UInt64 = 0x8000
        func add(_ feature: StandardFeature) {
            entries.append(StandardFeatureEntry(feature: feature, mask: bit))
            if bit > 1 { bit >>= 1 }
        }
        add(isLossless ? .uncompressedOrReversible : .irreversibleCodestream)
        add(.compositingLayerSingleCodestream)
        if colour == .rgb {
            add(.sRGBEnumeratedColourSpace)
        } else if colour == .greyscale {
            add(.greyscaleEnumeratedColourSpace)
        }
        add(isHTJ2K ? .htj2kCodestream : .codestreamContainsNoExtensions)
        add(.codestreamContiguous)
        if hasAlpha {
            add(.opacityChannel)
        }
        return try JP2ReaderRequirementsBox(
            maskLength: 2,
            fuam: 0xFF00,
            dcm: 0x00FF,
            standardFeatures: entries
        )
    }

    private static func readMask(_ bytes: [UInt8], at cursor: inout Int, length: Int) -> UInt64 {
        var val: UInt64 = 0
        for _ in 0..<length {
            val = (val << 8) | UInt64(bytes[cursor])
            cursor += 1
        }
        return val
    }

    private static func writeMask(_ out: inout [UInt8], _ value: UInt64, length: Int) {
        for i in stride(from: (length - 1) * 8, through: 0, by: -8) {
            out.append(UInt8((value >> i) & 0xFF))
        }
    }
}
