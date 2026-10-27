// SPDX-License-Identifier: Apache-2.0
//
// JPEG 2000 Part 1 codestream syntax (ISO/IEC 15444-1 Annex A): marker
// segment parsing and writing for the main header and tile-part headers.
//
// Provenance: new implementation for SwiftJ2K Milestone 2. The predecessor's
// parser (Raster-Lab/J2KSwift 7acc9ae4, Sources/J2KCodec/J2KDecoderPipeline.swift
// `parseCodestream` and the `parseSIZMarker`/`parseCODMarker`/`parseQCDMarker`/
// `parseSOTMarker` helpers) was read for field order and its recorded
// defect history, but it is bound to a 6,000-line pipeline type that also
// carries HT, GPU and multi-tile state, so it was not copied. Every length and
// count read here is checked before use; malformed input throws
// `malformedInput` and unsupported-but-valid syntax throws `unsupportedFeature`.
import Foundation

enum Marker {
    static let soc: UInt16 = 0xFF4F, sot: UInt16 = 0xFF90, sod: UInt16 = 0xFF93, eoc: UInt16 = 0xFFD9
    static let siz: UInt16 = 0xFF51, cod: UInt16 = 0xFF52, coc: UInt16 = 0xFF53, rgn: UInt16 = 0xFF5E
    static let qcd: UInt16 = 0xFF5C, qcc: UInt16 = 0xFF5D, poc: UInt16 = 0xFF5F
    static let tlm: UInt16 = 0xFF55, plm: UInt16 = 0xFF57, plt: UInt16 = 0xFF58
    static let ppm: UInt16 = 0xFF60, ppt: UInt16 = 0xFF61, sop: UInt16 = 0xFF91, eph: UInt16 = 0xFF92
    static let crg: UInt16 = 0xFF63, com: UInt16 = 0xFF64, cap: UInt16 = 0xFF50, cpf: UInt16 = 0xFF59
}

/// Extended capabilities marker segment `CAP` (ISO/IEC 15444-15 Annex A, Table A.1–A.3).
struct ExtendedCapabilitiesSegment: Sendable, Equatable {
    enum CodingMode: UInt8, Sendable, Equatable {
        case htOnly = 0       // Bits 14–15 = 0: all code-blocks are HT code-blocks
        case htDeclared = 1   // Bits 14–15 = 1: tile-parts are either all HT or all Part 1 per COD/COC
        case mixed = 3        // Bits 14–15 = 3: tile-parts may mix HT and Part 1 code-blocks
    }

    let pcap: UInt32
    let ccap15: UInt16
    let mode: CodingMode
    let multiHT: Bool
    let regionOfInterestPresent: Bool
    let heterogeneousTileParts: Bool
    let irreversible: Bool
    let magbField: Int
    let magnitudeBound: Int

    init(ccap15: UInt16, pcap: UInt32 = 0x0002_0000) throws {
        guard pcap == 0x0002_0000 else {
            throw CodecError(.unsupportedFeature, "CAP marker signals extended capabilities outside Part 15 (HTJ2K).")
        }
        let rawMode = UInt8((ccap15 >> 14) & 0x03)
        guard let mode = CodingMode(rawValue: rawMode) else {
            throw CodecError(.malformedInput, "CAP Ccap15 bits 14–15 carry reserved value 2.")
        }
        let multiField = (ccap15 >> 12) & 0x03
        guard multiField <= 1 else {
            throw CodecError(.malformedInput, "CAP Ccap15 bits 12–13 carry reserved value \(multiField).")
        }
        guard (ccap15 >> 6) & 0x0F == 0 else {
            throw CodecError(.malformedInput, "CAP Ccap15 reserved bits 6–9 must be zero.")
        }
        let magb = Int(ccap15 & 0x1F)
        let bound: Int
        if magb < 27 {
            bound = 8 + magb
        } else if magb < 31 {
            bound = 35 + 4 * (magb - 27)
        } else {
            bound = 74
        }
        self.pcap = pcap
        self.ccap15 = ccap15
        self.mode = mode
        self.multiHT = (multiField == 1)
        self.regionOfInterestPresent = ((ccap15 >> 11) & 0x01) != 0
        self.heterogeneousTileParts = ((ccap15 >> 10) & 0x01) != 0
        self.irreversible = ((ccap15 >> 5) & 0x01) != 0
        self.magbField = magb
        self.magnitudeBound = bound
    }

    /// Builds a Part 15 `HTONLY` / `SINGLEHT` / `HTREV` `CAP` segment for the given quantization segment.
    static func losslessHTOnly(for qcd: QuantizationSegment) throws -> Self {
        let maxExponent = qcd.exponents.max() ?? 0
        let maxMb = qcd.guardBits + maxExponent - 1
        let magb = UInt16(max(0, min(26, maxMb - 8)))
        return try Self(ccap15: magb)
    }
}

/// Corresponding profile marker segment `CPF` (0xFF59).
struct CorrespondingProfileSegment: Sendable, Equatable {
    let values: [UInt16]
}

struct ComponentSignalling: Sendable, Equatable {
    let precision: Int
    let signed: Bool
    let horizontalSeparation: Int
    let verticalSeparation: Int
}

/// SIZ marker segment (A.5.1).
struct ImageSizeSegment: Sendable, Equatable {
    let capabilities: UInt16
    let width: Int, height: Int, originX: Int, originY: Int
    let tileWidth: Int, tileHeight: Int, tileOriginX: Int, tileOriginY: Int
    let components: [ComponentSignalling]
}

/// COD marker segment (A.6.1). A COC segment carries the same fields except
/// progression, layers and the component transform; `applying(coc:)` merges it.
struct CodingStyleSegment: Sendable, Equatable {
    var usesPrecincts: Bool
    var usesSOP: Bool
    var usesEPH: Bool
    var progression: UInt8
    var layers: Int
    var componentTransform: UInt8
    var decompositionLevels: Int
    var codeBlockWidthExponent: Int      // xcb, already including the +2 of the field
    var codeBlockHeightExponent: Int
    var codeBlockStyle: UInt8
    var reversible: Bool                 // 5/3 when true, 9/7 when false
    var precinctExponents: [(Int, Int)]  // (PPx, PPy) per resolution, index 0 = lowest

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.usesPrecincts == rhs.usesPrecincts && lhs.usesSOP == rhs.usesSOP && lhs.usesEPH == rhs.usesEPH
            && lhs.progression == rhs.progression && lhs.layers == rhs.layers
            && lhs.componentTransform == rhs.componentTransform
            && lhs.decompositionLevels == rhs.decompositionLevels
            && lhs.codeBlockWidthExponent == rhs.codeBlockWidthExponent
            && lhs.codeBlockHeightExponent == rhs.codeBlockHeightExponent
            && lhs.codeBlockStyle == rhs.codeBlockStyle && lhs.reversible == rhs.reversible
            && lhs.precinctExponents.count == rhs.precinctExponents.count
            && zip(lhs.precinctExponents, rhs.precinctExponents).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    /// Precinct exponents for resolution `r` (defaults to 15, 15).
    func precinctExponents(resolution r: Int) -> (Int, Int) {
        guard usesPrecincts, r < precinctExponents.count else { return (15, 15) }
        return precinctExponents[r]
    }

    /// Merges a COC segment over this COD segment, preserving COD-only fields.
    func applying(coc: CodingStyleSegment) -> CodingStyleSegment {
        var merged = coc
        merged.usesSOP = usesSOP
        merged.usesEPH = usesEPH
        merged.progression = progression
        merged.layers = layers
        merged.componentTransform = componentTransform
        return merged
    }
}

/// QCD marker segment (A.6.4).
struct QuantizationSegment: Sendable, Equatable {
    enum Style: UInt8, Sendable { case none = 0, scalarDerived = 1, scalarExpounded = 2 }
    let style: Style
    let guardBits: Int
    let exponents: [Int]
    let mantissas: [Int]
}

/// One tile-part's location within the codestream (A.4.2).
struct TilePartRecord: Sendable, Equatable {
    let tileIndex: Int
    let partIndex: Int
    let partCount: Int
    let dataRange: Range<Int>
    let comments: [[UInt8]]

    init(tileIndex: Int, partIndex: Int, partCount: Int, dataRange: Range<Int>, comments: [[UInt8]] = []) {
        self.tileIndex = tileIndex
        self.partIndex = partIndex
        self.partCount = partCount
        self.dataRange = dataRange
        self.comments = comments
    }
}

/// Coding and quantization segments found in a tile's first tile-part
/// header, which override the main header for that tile (A.4.2, Table A.5).
struct TileHeaderOverrides: Sendable {
    var codingStyle: CodingStyleSegment?
    var componentCodingStyle: CodingStyleSegment?
    var quantization: QuantizationSegment?
    var componentQuantization: QuantizationSegment?
}

/// Everything the main header and the tile-part headers declare.
struct ParsedCodestream: Sendable {
    let size: ImageSizeSegment
    let extendedCapabilities: ExtendedCapabilitiesSegment?
    let correspondingProfile: CorrespondingProfileSegment?
    let codingStyle: CodingStyleSegment           // COD merged with any COC for component 0
    let quantization: QuantizationSegment         // QCD merged with any QCC for component 0
    let tileParts: [TilePartRecord]
    let tileOverrides: [Int: TileHeaderOverrides]
    let sawEndOfCodestream: Bool
    let mainHeaderMarkers: [UInt16]
    let mainHeaderComments: [[UInt8]]
    let componentRegistration: [UInt8]?
    let commentCount: Int
    let commentPayloadBytes: Int

    /// Whether the codestream signals Part 15 (HTJ2K) extended capabilities or HT block coding.
    var isHTJ2K: Bool {
        if extendedCapabilities != nil { return true }
        if (codingStyle.codeBlockStyle & 0x40) != 0 { return true }
        for override in tileOverrides.values {
            if let cod = override.codingStyle, (cod.codeBlockStyle & 0x40) != 0 { return true }
            if let coc = override.componentCodingStyle, (coc.codeBlockStyle & 0x40) != 0 { return true }
        }
        return false
    }

    /// Effective coding style and quantization for a tile (COC/QCC beat COD/QCD;
    /// tile-part header segments beat main header segments).
    func effectiveParameters(tile: Int) -> (CodingStyleSegment, QuantizationSegment) {
        var cod = codingStyle, qcd = quantization
        if let overrides = tileOverrides[tile] {
            if let tileCOD = overrides.codingStyle {
                // A tile COD replaces the main COD but not a main COC for this component; the
                // component-specific segment always wins over the general one at the same scope.
                cod = tileCOD
            }
            if let tileCOC = overrides.componentCodingStyle { cod = cod.applying(coc: tileCOC) }
            if let tileQCD = overrides.quantization { qcd = tileQCD }
            if let tileQCC = overrides.componentQuantization { qcd = tileQCC }
        }
        return (cod, qcd)
    }
}

enum CodestreamSyntax {
    /// Parses the main header and every tile-part header. Tile-part data is
    /// located, not interpreted.
    static func parse(
        _ bytes: [UInt8],
        limits: ResourceLimits,
        metadataPolicy: MetadataPolicy = .preserve
    ) throws -> ParsedCodestream {
        var reader = ByteReader(bytes)
        guard try reader.readUInt16() == Marker.soc else {
            throw CodecError(.unsupportedFormat, "Input does not begin with a JPEG 2000 codestream SOC marker.")
        }
        var size: ImageSizeSegment?
        var cap: ExtendedCapabilitiesSegment?
        var cpf: CorrespondingProfileSegment?
        var cod: CodingStyleSegment?
        var coc: [Int: CodingStyleSegment] = [:]
        var qcd: QuantizationSegment?
        var qcc: [Int: QuantizationSegment] = [:]
        var markers: [UInt16] = []
        var mainHeaderComments: [[UInt8]] = []
        var crg: [UInt8]?
        var totalCommentBytes = 0
        var totalCommentCount = 0

        func parseCommentSegment() throws -> [UInt8]? {
            let length = Int(try reader.readUInt16())
            guard length >= 4 else {
                throw CodecError(.malformedInput, "COM marker segment is shorter than 4 bytes.")
            }
            let payloadCount = length - 2
            guard reader.remaining >= payloadCount else {
                throw CodecError(.malformedInput, "COM marker segment extends past the codestream.")
            }
            totalCommentBytes = try checkedAdd(totalCommentBytes, payloadCount)
            guard totalCommentBytes <= limits.maximumMetadataBytes else {
                throw CodecError(.resourceLimitExceeded, "COM marker segments exceed the metadata byte limit.")
            }
            totalCommentCount += 1
            if metadataPolicy == .discardAncillary {
                try reader.skip(payloadCount)
                return nil
            }
            let retainedBytes = try checkedAdd(totalCommentBytes, try checkedMultiply(totalCommentCount, 36))
            guard retainedBytes <= limits.maximumWorkspaceBytes,
                  try checkedAdd(bytes.count, retainedBytes) <= limits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "Retained COM metadata exceeds workspace or memory limits.")
            }
            StorageTelemetry.recordStage("comment-metadata", bytes: 32 + payloadCount)
            let slice = Array(bytes[reader.position..<(reader.position + payloadCount)])
            try reader.skip(payloadCount)
            return slice
        }

        // Main header: marker segments until the first SOT.
        while true {
            let marker = try reader.readUInt16()
            if marker == Marker.sot { try reader.seek(to: reader.position - 2); break }
            if marker == Marker.com {
                markers.append(marker)
                if let comment = try parseCommentSegment() {
                    mainHeaderComments.append(comment)
                }
                continue
            }
            switch marker {
            case Marker.rgn:
                _ = try skipSegmentPayload(&reader, marker: marker)
                throw CodecError(.unsupportedFeature, "Region-of-interest (RGN) coding is not supported.")
            case Marker.poc:
                _ = try skipSegmentPayload(&reader, marker: marker)
                throw CodecError(.unsupportedFeature, "Progression order changes (POC) are not supported.")
            case Marker.ppm:
                _ = try skipSegmentPayload(&reader, marker: marker)
                throw CodecError(.unsupportedFeature, "Packed packet headers (PPM) are not supported.")
            case Marker.tlm, Marker.plm:
                _ = try skipSegmentPayload(&reader, marker: marker)
                markers.append(marker)
                continue
            default:
                guard marker & 0xFF00 == 0xFF00 else {
                    throw CodecError(.malformedInput, "Expected a marker in the main header.")
                }
                if (0xFF30...0xFF3F).contains(marker) {
                    markers.append(marker)
                    continue
                }
            }
            let payload = try readSegmentPayload(&reader, marker: marker, limits: limits, codestreamBytes: bytes.count)
            markers.append(marker)
            switch marker {
            case Marker.siz:
                guard size == nil else { throw CodecError(.malformedInput, "Duplicate SIZ marker segment.") }
                size = try parseSIZ(payload, limits: limits)
            case Marker.cap:
                guard size != nil else { throw CodecError(.malformedInput, "CAP precedes SIZ.") }
                guard cap == nil else { throw CodecError(.malformedInput, "Duplicate CAP marker segment.") }
                cap = try parseCAP(payload)
            case Marker.cpf:
                guard size != nil else { throw CodecError(.malformedInput, "CPF precedes SIZ.") }
                guard cpf == nil else { throw CodecError(.malformedInput, "Duplicate CPF marker segment.") }
                cpf = try parseCPF(payload)
            case Marker.cod:
                guard size != nil else { throw CodecError(.malformedInput, "COD precedes SIZ.") }
                guard cod == nil else { throw CodecError(.malformedInput, "Duplicate COD marker segment.") }
                cod = try parseCOD(payload)
            case Marker.coc:
                guard let size else { throw CodecError(.malformedInput, "COC precedes SIZ.") }
                let (component, segment) = try parseCOC(payload, componentCount: size.components.count)
                coc[component] = segment
            case Marker.qcd:
                guard qcd == nil else { throw CodecError(.malformedInput, "Duplicate QCD marker segment.") }
                qcd = try parseQuantization(payload)
            case Marker.qcc:
                guard let size else { throw CodecError(.malformedInput, "QCC precedes SIZ.") }
                let (component, segment) = try parseQCC(payload, componentCount: size.components.count)
                qcc[component] = segment
            case Marker.crg:
                guard let size else { throw CodecError(.malformedInput, "CRG precedes SIZ.") }
                guard crg == nil else { throw CodecError(.malformedInput, "Duplicate CRG marker segment.") }
                guard payload.count == 4 * size.components.count else {
                    throw CodecError(.malformedInput, "CRG marker segment length disagrees with component count.")
                }
                crg = payload
            default:
                throw CodecError(.unsupportedFeature, "Marker segment \(String(marker, radix: 16)) is not supported.")
            }
        }
        guard let size else { throw CodecError(.malformedInput, "Main header has no SIZ marker segment.") }
        guard var codingStyle = cod else { throw CodecError(.malformedInput, "Main header has no COD marker segment.") }
        guard var quantization = qcd else { throw CodecError(.malformedInput, "Main header has no QCD marker segment.") }
        if let override = coc[0] { codingStyle = codingStyle.applying(coc: override) }
        if let override = qcc[0] { quantization = override }

        // Tile-parts.
        var tileParts: [TilePartRecord] = []
        var tileOverrides: [Int: TileHeaderOverrides] = [:]
        var sawEOC = false
        while !reader.isAtEnd {
            let marker = try reader.readUInt16()
            if marker == Marker.eoc {
                sawEOC = true
                break
            }
            guard marker == Marker.sot else {
                throw CodecError(.malformedInput, "Expected SOT or EOC after tile-part data.")
            }
            let sotStart = reader.position - 2
            guard try reader.readUInt16() == 10 else {
                throw CodecError(.malformedInput, "SOT marker segment has an invalid length.")
            }
            let tileIndex = Int(try reader.readUInt16())
            let psot = Int(try reader.readUInt32())
            let partIndex = Int(try reader.readUInt8())
            let partCount = Int(try reader.readUInt8())
            // Tile-part header markers until SOD.
            var overrides = tileOverrides[tileIndex] ?? TileHeaderOverrides()
            var partComments: [[UInt8]] = []
            while true {
                let tileMarker = try reader.readUInt16()
                if tileMarker == Marker.sod { break }
                switch tileMarker {
                case Marker.cod, Marker.coc, Marker.qcd, Marker.qcc:
                    guard partIndex == 0 else {
                        throw CodecError(.malformedInput, "Coding overrides are only allowed in a tile's first tile-part header.")
                    }
                    let payload = try readSegmentPayload(&reader, marker: tileMarker, limits: limits, codestreamBytes: bytes.count)
                    switch tileMarker {
                    case Marker.cod: overrides.codingStyle = try parseCOD(payload)
                    case Marker.coc:
                        let (component, segment) = try parseCOC(payload, componentCount: size.components.count)
                        if component == 0 { overrides.componentCodingStyle = segment }
                    case Marker.qcd: overrides.quantization = try parseQuantization(payload)
                    default:
                        let (component, segment) = try parseQCC(payload, componentCount: size.components.count)
                        if component == 0 { overrides.componentQuantization = segment }
                    }
                case Marker.rgn:
                    _ = try skipSegmentPayload(&reader, marker: tileMarker)
                    throw CodecError(.unsupportedFeature, "Region-of-interest (RGN) coding is not supported.")
                case Marker.poc:
                    _ = try skipSegmentPayload(&reader, marker: tileMarker)
                    throw CodecError(.unsupportedFeature, "Progression order changes (POC) are not supported.")
                case Marker.ppt:
                    _ = try skipSegmentPayload(&reader, marker: tileMarker)
                    throw CodecError(.unsupportedFeature, "Packed packet headers (PPT) are not supported.")
                case Marker.com:
                    if let comment = try parseCommentSegment() {
                        partComments.append(comment)
                    }
                case Marker.plt:
                    _ = try skipSegmentPayload(&reader, marker: tileMarker)
                default:
                    throw CodecError(.malformedInput, "Unexpected marker \(String(tileMarker, radix: 16)) in a tile-part header.")
                }
            }
            tileOverrides[tileIndex] = overrides
            let dataStart = reader.position
            let dataEnd: Int
            if psot == 0 {
                // Data extends to the EOC marker, or to the end of the stream.
                let tail = bytes.count >= 2 && bytes[bytes.count - 2] == 0xFF && bytes[bytes.count - 1] == 0xD9 ? bytes.count - 2 : bytes.count
                dataEnd = max(dataStart, tail)
            } else {
                guard psot >= dataStart - sotStart, sotStart + psot <= bytes.count else {
                    throw CodecError(.malformedInput, "Tile-part length (Psot) does not fit inside the codestream.")
                }
                dataEnd = sotStart + psot
            }
            tileParts.append(TilePartRecord(tileIndex: tileIndex, partIndex: partIndex,
                                            partCount: partCount, dataRange: dataStart..<dataEnd,
                                            comments: partComments))
            try reader.seek(to: dataEnd)
            guard tileParts.count <= 65535 else {
                throw CodecError(.malformedInput, "Too many tile-parts.")
            }
        }
        guard !tileParts.isEmpty else { throw CodecError(.malformedInput, "Codestream contains no tile-part.") }

        let parsed = ParsedCodestream(
            size: size,
            extendedCapabilities: cap,
            correspondingProfile: cpf,
            codingStyle: codingStyle,
            quantization: quantization,
            tileParts: tileParts,
            tileOverrides: tileOverrides,
            sawEndOfCodestream: sawEOC,
            mainHeaderMarkers: markers,
            mainHeaderComments: mainHeaderComments,
            componentRegistration: crg,
            commentCount: totalCommentCount,
            commentPayloadBytes: totalCommentBytes
        )
        try validateHTSignalling(parsed)
        return parsed
    }

    private static func validateHTSignalling(_ parsed: ParsedCodestream) throws {
        let rsizSignalsCAP = (parsed.size.capabilities & 0x4000) != 0
        if rsizSignalsCAP && parsed.extendedCapabilities == nil {
            throw CodecError(.malformedInput, "SIZ Rsiz sets bit 14 (0x4000) without a CAP marker segment.")
        }
        if !rsizSignalsCAP && parsed.extendedCapabilities != nil {
            throw CodecError(.malformedInput, "CAP marker segment is present without SIZ Rsiz bit 14 (0x4000).")
        }

        // Collect all effective CodingStyleSegments (main header and any tile overrides).
        var styles: [CodingStyleSegment] = [parsed.codingStyle]
        for tileIndex in parsed.tileOverrides.keys.sorted() {
            styles.append(parsed.effectiveParameters(tile: tileIndex).0)
        }

        for style in styles {
            let htBit = (style.codeBlockStyle & 0x40) != 0
            let mixedBit = (style.codeBlockStyle & 0x80) != 0
            if mixedBit && !htBit {
                throw CodecError(.malformedInput, "COD/COC sets HT mixed bit (0x80) without HT coding bit (0x40).")
            }
            if htBit {
                guard let cap = parsed.extendedCapabilities else {
                    throw CodecError(.malformedInput, "COD/COC enables HTJ2K block coding (0x40) without a Part 15 CAP marker segment.")
                }
                if mixedBit && cap.mode != .mixed {
                    throw CodecError(.malformedInput, "COD/COC enables mixed HT/Part 1 coding (0xC0) when CAP Ccap15 is not HTMIXED.")
                }
            }
        }

        if let cap = parsed.extendedCapabilities {
            if cap.mode == .htOnly {
                for style in styles where (style.codeBlockStyle & 0x40) == 0 {
                    throw CodecError(.malformedInput, "CAP Ccap15 signals HTONLY but COD/COC does not set the HT coding style bit (0x40).")
                }
            }
        }
    }

    static func parseCAP(_ payload: [UInt8]) throws -> ExtendedCapabilitiesSegment {
        var r = ByteReader(payload)
        guard payload.count >= 4 else {
            throw CodecError(.malformedInput, "CAP marker segment is shorter than 4 bytes.")
        }
        let pcap = try r.readUInt32()
        let count = pcap.nonzeroBitCount
        guard payload.count == 4 + 2 * count else {
            throw CodecError(.malformedInput, "CAP marker segment length disagrees with Pcap bit count.")
        }
        guard pcap != 0 else {
            throw CodecError(.malformedInput, "CAP marker segment Pcap is zero.")
        }
        guard pcap == 0x0002_0000 else {
            throw CodecError(.unsupportedFeature, "CAP marker signals extended capabilities outside Part 15 (HTJ2K).")
        }
        let ccap15 = try r.readUInt16()
        return try ExtendedCapabilitiesSegment(ccap15: ccap15, pcap: pcap)
    }

    static func parseCPF(_ payload: [UInt8]) throws -> CorrespondingProfileSegment {
        guard payload.count >= 2, payload.count % 2 == 0 else {
            throw CodecError(.malformedInput, "CPF marker segment has an invalid length.")
        }
        var r = ByteReader(payload)
        var values: [UInt16] = []
        values.reserveCapacity(payload.count / 2)
        while !r.isAtEnd {
            values.append(try r.readUInt16())
        }
        return CorrespondingProfileSegment(values: values)
    }

    private static func skipSegmentPayload(_ reader: inout ByteReader, marker: UInt16) throws -> Int {
        let length = Int(try reader.readUInt16())
        guard length >= 2 else { throw CodecError(.malformedInput, "Marker segment length below 2.") }
        let payloadCount = length - 2
        guard reader.remaining >= payloadCount else {
            throw CodecError(.malformedInput, "Marker segment \(String(marker, radix: 16)) is truncated.")
        }
        try reader.skip(payloadCount)
        return payloadCount
    }

    private static func readSegmentPayload(
        _ reader: inout ByteReader,
        marker: UInt16,
        limits: ResourceLimits,
        codestreamBytes: Int
    ) throws -> [UInt8] {
        let length = Int(try reader.readUInt16())
        guard length >= 2 else { throw CodecError(.malformedInput, "Marker segment length below 2.") }
        let payloadCount = length - 2
        guard reader.remaining >= payloadCount else {
            throw CodecError(.malformedInput, "Marker segment \(String(marker, radix: 16)) is truncated.")
        }
        if marker == Marker.crg {
            guard payloadCount <= limits.maximumMetadataBytes else {
                throw CodecError(.resourceLimitExceeded, "CRG marker segment exceeds the metadata byte limit.")
            }
        }
        let segmentAllocationBytes = try checkedAdd(32, payloadCount)
        guard segmentAllocationBytes <= limits.maximumWorkspaceBytes,
              try checkedAdd(codestreamBytes, segmentAllocationBytes) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Marker segment \(String(marker, radix: 16)) payload exceeds workspace or memory limits.")
        }
        let start = reader.position
        try reader.skip(payloadCount)
        return Array(reader.bytes[start..<start + payloadCount])
    }

    // MARK: - SIZ

    static func parseSIZ(_ payload: [UInt8], limits: ResourceLimits) throws -> ImageSizeSegment {
        var r = ByteReader(payload)
        let rsiz = try r.readUInt16()
        let xsiz = Int(try r.readUInt32()), ysiz = Int(try r.readUInt32())
        let xosiz = Int(try r.readUInt32()), yosiz = Int(try r.readUInt32())
        let xtsiz = Int(try r.readUInt32()), ytsiz = Int(try r.readUInt32())
        let xtosiz = Int(try r.readUInt32()), ytosiz = Int(try r.readUInt32())
        let csiz = Int(try r.readUInt16())
        guard csiz >= 1, csiz <= 16384, payload.count == 36 + 3 * csiz else {
            throw CodecError(.malformedInput, "SIZ component count disagrees with the segment length.")
        }
        guard xsiz > xosiz, ysiz > yosiz, xtsiz > 0, ytsiz > 0,
              xtosiz <= xosiz, ytosiz <= yosiz, xtosiz + xtsiz > xosiz, ytosiz + ytsiz > yosiz else {
            throw CodecError(.malformedInput, "SIZ image or tile geometry is inconsistent.")
        }
        let width = xsiz - xosiz, height = ysiz - yosiz
        guard width <= limits.maximumDimension, height <= limits.maximumDimension else {
            throw CodecError(.resourceLimitExceeded, "Declared image dimension exceeds the operation limit.")
        }
        guard try checkedMultiply(width, height) <= limits.maximumPixels else {
            throw CodecError(.resourceLimitExceeded, "Declared pixel count exceeds the operation limit.")
        }
        var components: [ComponentSignalling] = []
        for _ in 0..<csiz {
            let ssiz = try r.readUInt8(), xr = Int(try r.readUInt8()), yr = Int(try r.readUInt8())
            let precision = Int(ssiz & 0x7F) + 1
            guard precision <= 38, xr >= 1, yr >= 1 else {
                throw CodecError(.malformedInput, "SIZ component precision or sub-sampling is out of range.")
            }
            components.append(ComponentSignalling(precision: precision, signed: ssiz & 0x80 != 0,
                                                  horizontalSeparation: xr, verticalSeparation: yr))
        }
        return ImageSizeSegment(capabilities: rsiz, width: xsiz, height: ysiz, originX: xosiz, originY: yosiz,
                                tileWidth: xtsiz, tileHeight: ytsiz, tileOriginX: xtosiz, tileOriginY: ytosiz,
                                components: components)
    }

    // MARK: - COD / COC

    static func parseCOD(_ payload: [UInt8]) throws -> CodingStyleSegment {
        var r = ByteReader(payload)
        let scod = try r.readUInt8()
        let progression = try r.readUInt8()
        let layers = Int(try r.readUInt16())
        let mct = try r.readUInt8()
        guard layers >= 1 else { throw CodecError(.malformedInput, "COD declares zero layers.") }
        guard progression <= 4 else { throw CodecError(.malformedInput, "COD progression order is out of range.") }
        var segment = try parseCodingParameters(&r, usesPrecincts: scod & 0x01 != 0)
        segment.usesSOP = scod & 0x02 != 0
        segment.usesEPH = scod & 0x04 != 0
        segment.progression = progression
        segment.layers = layers
        segment.componentTransform = mct
        guard r.isAtEnd else { throw CodecError(.malformedInput, "COD has trailing bytes.") }
        return segment
    }

    static func parseCOC(_ payload: [UInt8], componentCount: Int) throws -> (Int, CodingStyleSegment) {
        var r = ByteReader(payload)
        let component = componentCount < 257 ? Int(try r.readUInt8()) : Int(try r.readUInt16())
        guard component < componentCount else { throw CodecError(.malformedInput, "COC names a missing component.") }
        let scoc = try r.readUInt8()
        let segment = try parseCodingParameters(&r, usesPrecincts: scoc & 0x01 != 0)
        guard r.isAtEnd else { throw CodecError(.malformedInput, "COC has trailing bytes.") }
        return (component, segment)
    }

    private static func parseCodingParameters(_ r: inout ByteReader, usesPrecincts: Bool) throws -> CodingStyleSegment {
        let levels = Int(try r.readUInt8())
        let xcb = Int(try r.readUInt8() & 0x0F) + 2
        let ycb = Int(try r.readUInt8() & 0x0F) + 2
        let style = try r.readUInt8()
        let transform = try r.readUInt8()
        guard levels <= 32 else { throw CodecError(.malformedInput, "More than 32 decomposition levels.") }
        guard xcb <= 10, ycb <= 10, xcb + ycb <= 12 else {
            throw CodecError(.malformedInput, "Code-block dimensions exceed Table A.18.")
        }
        guard transform == 0 || transform == 1 else {
            throw CodecError(.malformedInput, "Unknown wavelet transform identifier.")
        }
        var precincts: [(Int, Int)] = []
        if usesPrecincts {
            for _ in 0...levels {
                let byte = try r.readUInt8()
                precincts.append((Int(byte & 0x0F), Int(byte >> 4)))
            }
            guard precincts.dropFirst().allSatisfy({ $0.0 >= 1 && $0.1 >= 1 }) else {
                throw CodecError(.malformedInput, "Precinct exponent below 1 at a non-zero resolution.")
            }
        }
        return CodingStyleSegment(usesPrecincts: usesPrecincts, usesSOP: false, usesEPH: false, progression: 0,
                                  layers: 1, componentTransform: 0, decompositionLevels: levels,
                                  codeBlockWidthExponent: xcb, codeBlockHeightExponent: ycb,
                                  codeBlockStyle: style, reversible: transform == 1, precinctExponents: precincts)
    }

    // MARK: - QCD / QCC

    static func parseQuantization(_ payload: [UInt8]) throws -> QuantizationSegment {
        var r = ByteReader(payload)
        return try parseQuantizationBody(&r)
    }

    static func parseQCC(_ payload: [UInt8], componentCount: Int) throws -> (Int, QuantizationSegment) {
        var r = ByteReader(payload)
        let component = componentCount < 257 ? Int(try r.readUInt8()) : Int(try r.readUInt16())
        guard component < componentCount else { throw CodecError(.malformedInput, "QCC names a missing component.") }
        return (component, try parseQuantizationBody(&r))
    }

    private static func parseQuantizationBody(_ r: inout ByteReader) throws -> QuantizationSegment {
        let sqcd = try r.readUInt8()
        let guardBits = Int(sqcd >> 5)
        guard let style = QuantizationSegment.Style(rawValue: sqcd & 0x1F) else {
            throw CodecError(.malformedInput, "Unknown quantization style.")
        }
        var exponents: [Int] = [], mantissas: [Int] = []
        switch style {
        case .none:
            while !r.isAtEnd { exponents.append(Int(try r.readUInt8() >> 3)) }
        case .scalarDerived, .scalarExpounded:
            while !r.isAtEnd {
                let value = try r.readUInt16()
                exponents.append(Int(value >> 11)); mantissas.append(Int(value & 0x7FF))
            }
        }
        guard !exponents.isEmpty, exponents.count <= 97 else {
            throw CodecError(.malformedInput, "Quantization segment has no band entries.")
        }
        return QuantizationSegment(style: style, guardBits: guardBits, exponents: exponents, mantissas: mantissas)
    }

    // MARK: - Writing

    static func writeSIZ<Output: CodestreamByteSink & ~Copyable>(_ size: ImageSizeSegment, into w: inout Output) throws {
        var p = ByteWriter(capacity: 38 + 3 * size.components.count)
        p.writeUInt16(size.capabilities)
        for value in [size.width, size.height, size.originX, size.originY,
                      size.tileWidth, size.tileHeight, size.tileOriginX, size.tileOriginY] {
            guard value >= 0, value <= Int(UInt32.max) else {
                throw CodecError(.internalFailure, "SIZ field does not fit in 32 bits.")
            }
            p.writeUInt32(UInt32(value))
        }
        p.writeUInt16(UInt16(size.components.count))
        for component in size.components {
            p.writeUInt8(UInt8(component.precision - 1) | (component.signed ? 0x80 : 0))
            p.writeUInt8(UInt8(component.horizontalSeparation))
            p.writeUInt8(UInt8(component.verticalSeparation))
        }
        try w.writeSegment(marker: Marker.siz, payload: p.bytes)
    }

    static func writeCAP<Output: CodestreamByteSink & ~Copyable>(_ cap: ExtendedCapabilitiesSegment, into w: inout Output) throws {
        var p = ByteWriter(capacity: 6)
        p.writeUInt32(cap.pcap)
        p.writeUInt16(cap.ccap15)
        try w.writeSegment(marker: Marker.cap, payload: p.bytes)
    }

    static func writeCPF<Output: CodestreamByteSink & ~Copyable>(_ cpf: CorrespondingProfileSegment, into w: inout Output) throws {
        var p = ByteWriter(capacity: 2 * cpf.values.count)
        for value in cpf.values { p.writeUInt16(value) }
        try w.writeSegment(marker: Marker.cpf, payload: p.bytes)
    }

    static func writeCOD<Output: CodestreamByteSink & ~Copyable>(_ cod: CodingStyleSegment, into w: inout Output) throws {
        var p = ByteWriter(capacity: 16)
        p.writeUInt8((cod.usesPrecincts ? 0x01 : 0) | (cod.usesSOP ? 0x02 : 0) | (cod.usesEPH ? 0x04 : 0))
        p.writeUInt8(cod.progression)
        p.writeUInt16(UInt16(cod.layers))
        p.writeUInt8(cod.componentTransform)
        p.writeUInt8(UInt8(cod.decompositionLevels))
        p.writeUInt8(UInt8(cod.codeBlockWidthExponent - 2))
        p.writeUInt8(UInt8(cod.codeBlockHeightExponent - 2))
        p.writeUInt8(cod.codeBlockStyle)
        p.writeUInt8(cod.reversible ? 1 : 0)
        if cod.usesPrecincts {
            for (ppx, ppy) in cod.precinctExponents { p.writeUInt8(UInt8(ppx) | UInt8(ppy) << 4) }
        }
        try w.writeSegment(marker: Marker.cod, payload: p.bytes)
    }

    static func writeQCD<Output: CodestreamByteSink & ~Copyable>(_ qcd: QuantizationSegment, into w: inout Output) throws {
        var p = ByteWriter(capacity: 2 + qcd.exponents.count)
        p.writeUInt8(UInt8(qcd.guardBits) << 5 | qcd.style.rawValue)
        switch qcd.style {
        case .none:
            for exponent in qcd.exponents { p.writeUInt8(UInt8(exponent) << 3) }
        case .scalarDerived, .scalarExpounded:
            for (exponent, mantissa) in zip(qcd.exponents, qcd.mantissas) {
                p.writeUInt16(UInt16(exponent) << 11 | UInt16(mantissa))
            }
        }
        try w.writeSegment(marker: Marker.qcd, payload: p.bytes)
    }
}
