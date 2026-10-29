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

/// Reader Requirements box (`'rreq'`, `0x72726571`, ISO/IEC 15444-2 Annex M.6 / M.11.1 & ISO/IEC 15444-15 Annex A).
public struct JP2ReaderRequirementsBox: Sendable, Equatable {
    /// Named standard feature codes (`SF^i`) from ISO/IEC 15444-2 (ITU-T T.801) Table M.14
    /// and ISO/IEC 15444-15 (HTJ2K / JPH) Annex A.
    public enum StandardFeature: UInt16, Sendable, Equatable, CaseIterable {
        case codestreamContainsNoExtensions   = 1
        case multipleCompositionLayers        = 2
        case profile0Codestream               = 3
        case profile1Codestream               = 4
        case unrestrictedJPEG2000Part1        = 5
        case unrestrictedJPEG2000Part2        = 6
        case dctCodestream                    = 7
        case noOpacity                        = 8
        case opacityChannel                   = 9
        case premultipliedOpacityChannel      = 10
        case chromaKeyOpacity                 = 11
        case codestreamContiguous             = 12
        case fragmentedCodestreamInternal     = 13
        case fragmentedCodestreamExternal     = 14
        case noCompositingRequired            = 18
        case multipleUncompositedLayers       = 19
        case compositingLayerSingleCodestream = 20
        case multipleCodestreamsPerLayer      = 21
        case noScalingRequired                = 31
        case scalingRequired                  = 32
        case graphicArtsReproduction          = 41
        case vendorColourSpace                = 42
        case restrictedICCProfile             = 43
        case anyICCProfile                    = 44
        case sRGBEnumeratedColourSpace        = 45
        case greyscaleEnumeratedColourSpace   = 46
        case biLevel1EnumeratedColourSpace    = 47
        case biLevel2EnumeratedColourSpace    = 48
        case yCbCr1EnumeratedColourSpace      = 49
        case yCbCr2EnumeratedColourSpace      = 50
        case yCbCr3EnumeratedColourSpace      = 51
        case photoYCCEnumeratedColourSpace    = 52
        case ycckEnumeratedColourSpace        = 53
        case cmyEnumeratedColourSpace         = 54
        case cmykEnumeratedColourSpace        = 55
        case cieLabEnumeratedColourSpace      = 56
        case cieJabEnumeratedColourSpace      = 59
        case eSRGBEnumeratedColourSpace       = 60
        case rommRGBEnumeratedColourSpace     = 61
        case gisMetadata                      = 67
        case sYCCEnumeratedColourSpace        = 70
        case htj2kCodestream                  = 86
    }

    /// Standard features implemented by SwiftJ2K's container and codestream decoders.
    public static let swiftJ2KSupportedFeatures: Set<StandardFeature> = [
        .codestreamContainsNoExtensions,
        .profile0Codestream,
        .profile1Codestream,
        .unrestrictedJPEG2000Part1,
        .noOpacity,
        .opacityChannel,
        .premultipliedOpacityChannel,
        .codestreamContiguous,
        .noCompositingRequired,
        .compositingLayerSingleCodestream,
        .noScalingRequired,
        .restrictedICCProfile,
        .anyICCProfile,
        .sRGBEnumeratedColourSpace,
        .greyscaleEnumeratedColourSpace,
        .biLevel1EnumeratedColourSpace,
        .biLevel2EnumeratedColourSpace,
        .yCbCr1EnumeratedColourSpace,
        .yCbCr2EnumeratedColourSpace,
        .yCbCr3EnumeratedColourSpace,
        .eSRGBEnumeratedColourSpace,
        .rommRGBEnumeratedColourSpace,
        .sYCCEnumeratedColourSpace,
        .htj2kCodestream
    ]

    /// Result of evaluating a reader's feature capabilities against `DCM` and `FUAM`
    /// under ISO/IEC 15444-2 Annex M.6.
    public struct SupportEvaluation: Sendable, Equatable {
        /// `true` when the reader satisfies `DCM` (`Decode Completely Mask`).
        public let canDecodeCompletely: Bool
        /// `true` when the reader satisfies `FUAM` (`Fully Understand Aspects Mask`).
        public let understandsAllAspects: Bool
        /// Bitwise union of masks for all features supported by the reader.
        public let satisfiedMask: UInt64
        /// Bits in `DCM` that remain unsatisfied by the reader's capabilities.
        public let unsatisfiedDecodeMask: UInt64
        /// Bits in `FUAM` that remain unsatisfied by the reader's capabilities.
        public let unsatisfiedUnderstandMask: UInt64
        /// Standard feature codes contributing to unsatisfied `DCM` clauses.
        public let unsupportedRequiredFeatures: [UInt16]
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

    /// Evaluates whether a reader supporting `supportedFeatures` and `supportedVendorUUIDs`
    /// can completely decode (`DCM`) and fully understand (`FUAM`) the container under
    /// ISO/IEC 15444-2 (ITU-T T.801) Annex M.6.
    public func evaluate(
        supportedFeatures: Set<StandardFeature> = Self.swiftJ2KSupportedFeatures,
        supportedVendorUUIDs: Set<[UInt8]> = []
    ) -> SupportEvaluation {
        var satisfiedMask: UInt64 = 0
        var definedMask: UInt64 = 0
        for entry in standardFeatures {
            definedMask |= entry.mask
            if let feature = entry.knownFeature, supportedFeatures.contains(feature) {
                satisfiedMask |= entry.mask
            }
        }
        for vendor in vendorFeatures {
            definedMask |= vendor.mask
            if supportedVendorUUIDs.contains(vendor.uuid) {
                satisfiedMask |= vendor.mask
            }
        }

        // Note on Kakadu v8.4.1 JPX output compatibility:
        // Kakadu's `jpx_target` allocates `NSF` high bits in `FUAM` and the immediately adjacent
        // `NSF` lower bits in `DCM` (`dcm == fuam >> NSF`), while populating `SM^i` only in the
        // `FUAM` bit positions (`definedMask == fuam`, `(dcm & definedMask) == 0`). When that exact
        // 1-to-1 shifted layout is present, bit `(b - NSF)` in `DCM` represents the same feature
        // requirement as bit `b` in `FUAM`. Any unsupported feature in `FUAM` leaves its projected
        // `DCM` bit unsatisfied; inconsistent masks (e.g. `NSF != fuam.nonzeroBitCount` or
        // `definedMask != fuam`) do not match and remain unsatisfied as required by T.801 M.6.
        let nsf = standardFeatures.count
        let isKakaduShiftedDCM = nsf > 0
            && nsf < 64
            && vendorFeatures.isEmpty
            && fuam != 0
            && definedMask == fuam
            && (dcm & definedMask) == 0
            && fuam.nonzeroBitCount == nsf
            && (fuam >> nsf) == dcm

        let effectiveDecodeMask: UInt64 = isKakaduShiftedDCM
            ? (satisfiedMask | (satisfiedMask >> nsf))
            : satisfiedMask

        let unsatisfiedDecode = dcm & ~effectiveDecodeMask
        let unsatisfiedUnderstand = fuam & ~satisfiedMask

        var unsupportedRequired: [UInt16] = []
        if unsatisfiedDecode != 0 {
            let probeMask = isKakaduShiftedDCM ? unsatisfiedUnderstand : unsatisfiedDecode
            for entry in standardFeatures {
                let isSupported = entry.knownFeature.map(supportedFeatures.contains) ?? false
                if !isSupported && (entry.mask & probeMask) != 0 && !unsupportedRequired.contains(entry.code) {
                    unsupportedRequired.append(entry.code)
                }
            }
        }

        return SupportEvaluation(
            canDecodeCompletely: unsatisfiedDecode == 0,
            understandsAllAspects: unsatisfiedUnderstand == 0 && unsatisfiedDecode == 0,
            satisfiedMask: satisfiedMask,
            unsatisfiedDecodeMask: unsatisfiedDecode,
            unsatisfiedUnderstandMask: unsatisfiedUnderstand,
            unsupportedRequiredFeatures: unsupportedRequired
        )
    }

    static func defaultJPX(
        isLossless: Bool,
        isHTJ2K: Bool,
        colour: ColourInterpretation,
        hasAlpha: Bool,
        isPremultipliedAlpha: Bool = false,
        hasRestrictedICC: Bool = false
    ) throws -> JP2ReaderRequirementsBox {
        _ = isLossless // T.801 SF=5 covers both reversible and irreversible Part 1 codestreams.
        var entries: [StandardFeatureEntry] = []
        var fuam: UInt64 = 0
        var dcm: UInt64 = 0
        var nextBit: UInt64 = 0x8000

        func allocateBit() -> UInt64 {
            let b = nextBit
            nextBit >>= 1
            return b
        }

        func addRequired(_ feature: StandardFeature) {
            let b = allocateBit()
            fuam |= b
            dcm |= b
            entries.append(StandardFeatureEntry(feature: feature, mask: b))
        }

        addRequired(isHTJ2K ? .htj2kCodestream : .unrestrictedJPEG2000Part1)
        if !isHTJ2K {
            addRequired(.codestreamContainsNoExtensions)
        }
        addRequired(.codestreamContiguous)
        addRequired(.noCompositingRequired)
        addRequired(.compositingLayerSingleCodestream)
        addRequired(.noScalingRequired)
        if hasAlpha {
            addRequired(isPremultipliedAlpha ? .premultipliedOpacityChannel : .opacityChannel)
        } else {
            addRequired(.noOpacity)
        }

        let fallbackEnumFeature: StandardFeature = (colour == .rgb)
            ? .sRGBEnumeratedColourSpace
            : .greyscaleEnumeratedColourSpace

        if hasRestrictedICC {
            // Two colour specifications are written (Restricted ICC + enumerated fallback):
            // understanding all aspects (`FUAM`) requires both bits, while complete decoding
            // (`DCM`) requires either Restricted ICC OR the enumerated colourspace (shared bit).
            let iccUnderstandBit = allocateBit()
            let enumUnderstandBit = allocateBit()
            let sharedDecodeBit = allocateBit()
            fuam |= iccUnderstandBit | enumUnderstandBit | sharedDecodeBit
            dcm |= sharedDecodeBit
            entries.append(StandardFeatureEntry(feature: .restrictedICCProfile, mask: iccUnderstandBit | sharedDecodeBit))
            entries.append(StandardFeatureEntry(feature: fallbackEnumFeature, mask: enumUnderstandBit | sharedDecodeBit))
        } else {
            addRequired(fallbackEnumFeature)
        }

        return try JP2ReaderRequirementsBox(
            maskLength: 2,
            fuam: fuam,
            dcm: dcm,
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
