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

    /// Expands a scalar-derived (`Sqcd = 1`) quantisation segment to `1 + 3 * decompositionLevels`
    /// subband entries per ISO/IEC 15444-1 Eq. E-2: `eps_b = eps_0 - (N_L - n_b) = eps_0 - max(0, r - 1)`.
    func expanded(decompositionLevels: Int) throws -> QuantizationSegment {
        guard style == .scalarDerived, exponents.count == 1, mantissas.count == 1 else {
            return self
        }
        let eps0 = exponents[0]
        let mu0 = mantissas[0]
        var expOut: [Int] = [eps0]
        var manOut: [Int] = [mu0]
        expOut.reserveCapacity(1 + 3 * decompositionLevels)
        manOut.reserveCapacity(1 + 3 * decompositionLevels)
        if decompositionLevels >= 1 {
            for r in 1...decompositionLevels {
                let epsB = eps0 - (r - 1)
                guard epsB >= 0 else {
                    throw CodecError(.malformedInput, "Scalar-derived quantisation exponent underflows below zero.")
                }
                for _ in 0..<3 {
                    expOut.append(epsB)
                    manOut.append(mu0)
                }
            }
        }
        return QuantizationSegment(style: .scalarDerived, guardBits: guardBits,
                                   exponents: expOut, mantissas: manOut)
    }
}

/// RGN marker segment (A.6.3, Table A.25).
struct RegionOfInterestSegment: Sendable, Equatable {
    let component: Int
    let style: UInt8   // 0 = MaxShift (Annex H.1)
    let shift: Int
}

/// One entry in a POC marker segment (A.6.6, Table A.26).
struct ProgressionOrderChangeEntry: Sendable, Equatable {
    let resolutionStart: Int
    let componentStart: Int
    let layerEnd: Int
    let resolutionEnd: Int
    let componentEnd: Int
    let progression: UInt8
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

/// Coding and quantization segments found in a tile-part header, which
/// override the main header for that tile (A.4.2, Table A.5).
struct TileHeaderOverrides: Sendable {
    var codingStyle: CodingStyleSegment?
    var componentCodingStyle: CodingStyleSegment?
    var componentCodingStyles: [Int: CodingStyleSegment] = [:]
    var quantization: QuantizationSegment?
    var componentQuantization: QuantizationSegment?
    var componentQuantizations: [Int: QuantizationSegment] = [:]
    var regionsOfInterest: [Int: RegionOfInterestSegment] = [:]
    var progressionChanges: [ProgressionOrderChangeEntry] = []
}

/// Everything the main header and the tile-part headers declare.
struct ParsedCodestream: Sendable {
    let size: ImageSizeSegment
    let extendedCapabilities: ExtendedCapabilitiesSegment?
    let correspondingProfile: CorrespondingProfileSegment?
    let codingStyle: CodingStyleSegment           // COD merged with any COC for component 0
    let quantization: QuantizationSegment         // QCD merged with any QCC for component 0
    let baseCodingStyle: CodingStyleSegment
    let componentCodingStyles: [Int: CodingStyleSegment]
    let baseQuantization: QuantizationSegment
    let componentQuantizations: [Int: QuantizationSegment]
    let regionsOfInterest: [Int: RegionOfInterestSegment]
    let progressionChanges: [ProgressionOrderChangeEntry]
    let tileParts: [TilePartRecord]
    let tileOverrides: [Int: TileHeaderOverrides]
    let sawEndOfCodestream: Bool
    let mainHeaderMarkers: [UInt16]
    let mainHeaderComments: [[UInt8]]
    let componentRegistration: [UInt8]?
    let commentCount: Int
    let commentPayloadBytes: Int
    let retainedMetadataBytes: Int

    init(
        size: ImageSizeSegment,
        extendedCapabilities: ExtendedCapabilitiesSegment?,
        correspondingProfile: CorrespondingProfileSegment?,
        codingStyle: CodingStyleSegment,
        quantization: QuantizationSegment,
        baseCodingStyle: CodingStyleSegment? = nil,
        componentCodingStyles: [Int: CodingStyleSegment] = [:],
        baseQuantization: QuantizationSegment? = nil,
        componentQuantizations: [Int: QuantizationSegment] = [:],
        regionsOfInterest: [Int: RegionOfInterestSegment] = [:],
        progressionChanges: [ProgressionOrderChangeEntry] = [],
        tileParts: [TilePartRecord],
        tileOverrides: [Int: TileHeaderOverrides],
        sawEndOfCodestream: Bool,
        mainHeaderMarkers: [UInt16],
        mainHeaderComments: [[UInt8]],
        componentRegistration: [UInt8]?,
        commentCount: Int,
        commentPayloadBytes: Int,
        retainedMetadataBytes: Int = 0
    ) {
        self.size = size
        self.extendedCapabilities = extendedCapabilities
        self.correspondingProfile = correspondingProfile
        self.codingStyle = codingStyle
        self.quantization = quantization
        self.baseCodingStyle = baseCodingStyle ?? codingStyle
        self.componentCodingStyles = componentCodingStyles
        self.baseQuantization = baseQuantization ?? quantization
        self.componentQuantizations = componentQuantizations
        self.regionsOfInterest = regionsOfInterest
        self.progressionChanges = progressionChanges
        self.tileParts = tileParts
        self.tileOverrides = tileOverrides
        self.sawEndOfCodestream = sawEndOfCodestream
        self.mainHeaderMarkers = mainHeaderMarkers
        self.mainHeaderComments = mainHeaderComments
        self.componentRegistration = componentRegistration
        self.commentCount = commentCount
        self.commentPayloadBytes = commentPayloadBytes
        self.retainedMetadataBytes = retainedMetadataBytes
    }

    /// Whether the codestream signals Part 15 (HTJ2K) extended capabilities or HT block coding.
    var isHTJ2K: Bool {
        if extendedCapabilities != nil { return true }
        if (codingStyle.codeBlockStyle & 0x40) != 0 { return true }
        for coc in componentCodingStyles.values where (coc.codeBlockStyle & 0x40) != 0 { return true }
        for override in tileOverrides.values {
            if let cod = override.codingStyle, (cod.codeBlockStyle & 0x40) != 0 { return true }
            if let coc = override.componentCodingStyle, (coc.codeBlockStyle & 0x40) != 0 { return true }
            for coc in override.componentCodingStyles.values where (coc.codeBlockStyle & 0x40) != 0 { return true }
        }
        return false
    }

    /// Effective coding style and quantization for a tile and component (COC/QCC beat COD/QCD;
    /// tile-part header segments beat main header segments).
    func effectiveParameters(tile: Int, component: Int = 0) -> (CodingStyleSegment, QuantizationSegment) {
        var cod = component == 0 ? codingStyle : baseCodingStyle
        var qcd = component == 0 ? quantization : baseQuantization
        if component != 0 {
            if let mainCOC = componentCodingStyles[component] { cod = cod.applying(coc: mainCOC) }
            if let mainQCC = componentQuantizations[component] { qcd = mainQCC }
        }
        if let overrides = tileOverrides[tile] {
            if let tileCOD = overrides.codingStyle {
                cod = tileCOD
            }
            if component == 0, let tileCOC = overrides.componentCodingStyle {
                cod = cod.applying(coc: tileCOC)
            } else if let tileCOC = overrides.componentCodingStyles[component] {
                cod = cod.applying(coc: tileCOC)
            }
            if let tileQCD = overrides.quantization { qcd = tileQCD }
            if component == 0, let tileQCC = overrides.componentQuantization {
                qcd = tileQCC
            } else if let tileQCC = overrides.componentQuantizations[component] {
                qcd = tileQCC
            }
        }
        return (cod, qcd)
    }

    /// Effective MaxShift ROI shift for a tile and component (`0` when no `RGN` applies).
    func effectiveROIShift(tile: Int, component: Int) -> Int {
        if let tileRGN = tileOverrides[tile]?.regionsOfInterest[component] {
            return tileRGN.shift
        }
        return regionsOfInterest[component]?.shift ?? 0
    }

    /// Effective POC entries for a tile (tile-part POC entries if present, else main-header POC entries).
    func effectiveProgressionChanges(tile: Int) -> [ProgressionOrderChangeEntry] {
        if let tilePOC = tileOverrides[tile]?.progressionChanges, !tilePOC.isEmpty {
            return tilePOC
        }
        return progressionChanges
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
        var rgn: [Int: RegionOfInterestSegment] = [:]
        var poc: [ProgressionOrderChangeEntry] = []
        var markers: [UInt16] = []
        var mainHeaderComments: [[UInt8]] = []
        var crg: [UInt8]?
        var totalCommentBytes = 0
        var totalCommentCount = 0
        var retainedMetadataBytes = 0

        func admitRetained(
            _ addedBytes: Int,
            liveTransientBytes: Int = 0,
            parserStage: String = "parser-retained-structure",
            emitMainStage: String? = nil,
            message: String
        ) throws {
            guard addedBytes > 0 else { return }
            let nextRetained = try checkedAdd(retainedMetadataBytes, addedBytes)
            let peakLiveWorkspace = try checkedAdd(nextRetained, liveTransientBytes)
            guard peakLiveWorkspace <= limits.maximumWorkspaceBytes,
                  try checkedAdd(bytes.count, peakLiveWorkspace) <= limits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, message)
            }
            retainedMetadataBytes = nextRetained
            StorageTelemetry.recordParserAllocation(stage: parserStage, bytes: addedBytes)
            if let emitMainStage {
                StorageTelemetry.recordStage(emitMainStage, bytes: addedBytes)
            }
        }

        func appendMainMarker(_ marker: UInt16, liveTransientBytes: Int = 0) throws {
            if markers.isEmpty {
                try admitRetained(
                    128,
                    liveTransientBytes: liveTransientBytes,
                    parserStage: "parser-markers",
                    message: "Retained header marker list exceeds workspace or memory limits."
                )
            } else if markers.count % 32 == 0 {
                try admitRetained(
                    64,
                    liveTransientBytes: liveTransientBytes,
                    parserStage: "parser-markers",
                    message: "Retained header marker list exceeds workspace or memory limits."
                )
            }
            markers.append(marker)
        }

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
            try admitRetained(
                try checkedAdd(36, payloadCount),
                parserStage: "comment-metadata",
                emitMainStage: "comment-metadata",
                message: "Retained COM metadata exceeds workspace or memory limits."
            )
            let slice = Array(bytes[reader.position..<(reader.position + payloadCount)])
            try reader.skip(payloadCount)
            return slice
        }

        // Main header: marker segments until the first SOT.
        while true {
            let marker = try reader.readUInt16()
            if marker == Marker.sot { try reader.seek(to: reader.position - 2); break }
            if marker == Marker.com {
                try appendMainMarker(marker)
                if let comment = try parseCommentSegment() {
                    mainHeaderComments.append(comment)
                }
                continue
            }
            switch marker {
            case Marker.ppm:
                _ = try skipSegmentPayload(&reader, marker: marker)
                throw CodecError(.unsupportedFeature, "Packed packet headers (PPM) are not supported.")
            case Marker.tlm, Marker.plm:
                _ = try skipSegmentPayload(&reader, marker: marker)
                try appendMainMarker(marker)
                continue
            default:
                guard marker & 0xFF00 == 0xFF00 else {
                    throw CodecError(.malformedInput, "Expected a marker in the main header.")
                }
                if (0xFF30...0xFF3F).contains(marker) {
                    try appendMainMarker(marker)
                    continue
                }
            }
            let payload = try readSegmentPayload(
                &reader,
                marker: marker,
                limits: limits,
                codestreamBytes: bytes.count,
                retainedBytes: retainedMetadataBytes
            )
            let payloadTransientBytes = try checkedAdd(32, payload.count)
            try appendMainMarker(marker, liveTransientBytes: payloadTransientBytes)
            switch marker {
            case Marker.siz:
                guard size == nil else { throw CodecError(.malformedInput, "Duplicate SIZ marker segment.") }
                let parsedSIZ = try parseSIZ(payload, limits: limits) { csiz in
                    let expandedBytes = try checkedAdd(
                        32,
                        try checkedMultiply(csiz, MemoryLayout<ComponentSignalling>.stride)
                    )
                    try admitRetained(
                        expandedBytes,
                        liveTransientBytes: payloadTransientBytes,
                        parserStage: "siz-components",
                        message: "Retained SIZ component metadata exceeds workspace or memory limits."
                    )
                }
                size = parsedSIZ
            case Marker.cap:
                guard size != nil else { throw CodecError(.malformedInput, "CAP precedes SIZ.") }
                guard cap == nil else { throw CodecError(.malformedInput, "Duplicate CAP marker segment.") }
                cap = try parseCAP(payload)
            case Marker.cpf:
                guard size != nil else { throw CodecError(.malformedInput, "CPF precedes SIZ.") }
                guard cpf == nil else { throw CodecError(.malformedInput, "Duplicate CPF marker segment.") }
                let parsedCPF = try parseCPF(payload) { valueCount in
                    let expandedBytes = try checkedAdd(
                        32,
                        try checkedMultiply(valueCount, MemoryLayout<UInt16>.stride)
                    )
                    try admitRetained(
                        expandedBytes,
                        liveTransientBytes: payloadTransientBytes,
                        parserStage: "cpf-values",
                        message: "Retained CPF metadata exceeds workspace or memory limits."
                    )
                }
                cpf = parsedCPF
            case Marker.cod:
                guard size != nil else { throw CodecError(.malformedInput, "COD precedes SIZ.") }
                guard cod == nil else { throw CodecError(.malformedInput, "Duplicate COD marker segment.") }
                let parsedCOD = try parseCOD(payload) { precinctCount in
                    if precinctCount > 0 {
                        let expandedBytes = try checkedAdd(
                            32,
                            try checkedMultiply(precinctCount, MemoryLayout<(Int, Int)>.stride)
                        )
                        try admitRetained(
                            expandedBytes,
                            liveTransientBytes: payloadTransientBytes,
                            parserStage: "cod-precincts",
                            message: "Retained COD precinct metadata exceeds workspace or memory limits."
                        )
                    }
                }
                cod = parsedCOD
            case Marker.coc:
                guard let size else { throw CodecError(.malformedInput, "COC precedes SIZ.") }
                let (component, segment) = try parseCOC(payload, componentCount: size.components.count) { precinctCount in
                    let expandedBytes = try checkedAdd(
                        96,
                        try checkedMultiply(precinctCount, MemoryLayout<(Int, Int)>.stride)
                    )
                    try admitRetained(
                        expandedBytes,
                        liveTransientBytes: payloadTransientBytes,
                        parserStage: "coc-parameters",
                        message: "Retained COC metadata exceeds workspace or memory limits."
                    )
                }
                coc[component] = segment
            case Marker.qcd:
                guard qcd == nil else { throw CodecError(.malformedInput, "Duplicate QCD marker segment.") }
                let parsedQCD = try parseQuantization(payload) { bandCount, hasMantissas in
                    let totalInts = hasMantissas ? bandCount * 2 : bandCount
                    if totalInts > 0 {
                        let expandedBytes = try checkedAdd(
                            hasMantissas ? 64 : 32,
                            try checkedMultiply(totalInts, MemoryLayout<Int>.stride)
                        )
                        try admitRetained(
                            expandedBytes,
                            liveTransientBytes: payloadTransientBytes,
                            parserStage: "qcd-parameters",
                            message: "Retained QCD quantisation metadata exceeds workspace or memory limits."
                        )
                    }
                }
                qcd = parsedQCD
            case Marker.qcc:
                guard let size else { throw CodecError(.malformedInput, "QCC precedes SIZ.") }
                let (component, segment) = try parseQCC(payload, componentCount: size.components.count) { bandCount, hasMantissas in
                    let totalInts = hasMantissas ? bandCount * 2 : bandCount
                    let expandedBytes = try checkedAdd(
                        hasMantissas ? 128 : 96,
                        try checkedMultiply(totalInts, MemoryLayout<Int>.stride)
                    )
                    try admitRetained(
                        expandedBytes,
                        liveTransientBytes: payloadTransientBytes,
                        parserStage: "qcc-parameters",
                        message: "Retained QCC metadata exceeds workspace or memory limits."
                    )
                }
                qcc[component] = segment
            case Marker.rgn:
                guard let size else { throw CodecError(.malformedInput, "RGN precedes SIZ.") }
                let segment = try parseRGN(payload, componentCount: size.components.count)
                try admitRetained(
                    48,
                    liveTransientBytes: payloadTransientBytes,
                    message: "Retained RGN metadata exceeds workspace or memory limits."
                )
                rgn[segment.component] = segment
            case Marker.poc:
                guard let size else { throw CodecError(.malformedInput, "POC precedes SIZ.") }
                try parsePOC(payload, componentCount: size.components.count, into: &poc) { addedRetained, reallocOverlap in
                    let totalTransient = try checkedAdd(payloadTransientBytes, reallocOverlap)
                    try admitRetained(
                        addedRetained,
                        liveTransientBytes: totalTransient,
                        parserStage: "poc-entries",
                        message: "Retained POC metadata exceeds workspace or memory limits."
                    )
                }
            case Marker.crg:
                guard let size else { throw CodecError(.malformedInput, "CRG precedes SIZ.") }
                guard crg == nil else { throw CodecError(.malformedInput, "Duplicate CRG marker segment.") }
                guard payload.count == 4 * size.components.count else {
                    throw CodecError(.malformedInput, "CRG marker segment length disagrees with component count.")
                }
                try admitRetained(
                    try checkedAdd(32, payload.count),
                    message: "Retained CRG metadata exceeds workspace or memory limits."
                )
                crg = payload
            default:
                throw CodecError(.unsupportedFeature, "Marker segment \(String(marker, radix: 16)) is not supported.")
            }
        }
        guard let size else { throw CodecError(.malformedInput, "Main header has no SIZ marker segment.") }
        guard let baseCOD = cod else { throw CodecError(.malformedInput, "Main header has no COD marker segment.") }
        guard let baseQCD = qcd else { throw CodecError(.malformedInput, "Main header has no QCD marker segment.") }
        var codingStyle = baseCOD
        var quantization = baseQCD
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
            var hasOverrides = tileOverrides[tileIndex] != nil
            var overrides = tileOverrides.removeValue(forKey: tileIndex) ?? TileHeaderOverrides()
            var partComments: [[UInt8]] = []
            while true {
                let tileMarker = try reader.readUInt16()
                if tileMarker == Marker.sod { break }
                switch tileMarker {
                case Marker.cod, Marker.coc, Marker.qcd, Marker.qcc, Marker.rgn:
                    guard partIndex == 0 else {
                        throw CodecError(.malformedInput, "Coding overrides are only allowed in a tile's first tile-part header.")
                    }
                    let payload = try readSegmentPayload(
                        &reader,
                        marker: tileMarker,
                        limits: limits,
                        codestreamBytes: bytes.count,
                        retainedBytes: retainedMetadataBytes
                    )
                    let payloadTransientBytes = try checkedAdd(32, payload.count)
                    if !hasOverrides {
                        try admitRetained(
                            128,
                            liveTransientBytes: payloadTransientBytes,
                            message: "Retained tile-header overrides exceed workspace or memory limits."
                        )
                        hasOverrides = true
                    }
                    switch tileMarker {
                    case Marker.cod:
                        overrides.codingStyle = try parseCOD(payload) { precinctCount in
                            if precinctCount > 0 {
                                let expandedBytes = try checkedAdd(
                                    32,
                                    try checkedMultiply(precinctCount, MemoryLayout<(Int, Int)>.stride)
                                )
                                try admitRetained(
                                    expandedBytes,
                                    liveTransientBytes: payloadTransientBytes,
                                    message: "Retained tile COD precinct metadata exceeds workspace or memory limits."
                                )
                            }
                        }
                    case Marker.coc:
                        let (component, segment) = try parseCOC(payload, componentCount: size.components.count) { precinctCount in
                            let expandedBytes = try checkedAdd(
                                96,
                                try checkedMultiply(precinctCount, MemoryLayout<(Int, Int)>.stride)
                            )
                            try admitRetained(
                                expandedBytes,
                                liveTransientBytes: payloadTransientBytes,
                                message: "Retained tile COC metadata exceeds workspace or memory limits."
                            )
                        }
                        if component == 0 { overrides.componentCodingStyle = segment }
                        overrides.componentCodingStyles[component] = segment
                    case Marker.qcd:
                        overrides.quantization = try parseQuantization(payload) { bandCount, hasMantissas in
                            let totalInts = hasMantissas ? bandCount * 2 : bandCount
                            if totalInts > 0 {
                                let expandedBytes = try checkedAdd(
                                    hasMantissas ? 64 : 32,
                                    try checkedMultiply(totalInts, MemoryLayout<Int>.stride)
                                )
                                try admitRetained(
                                    expandedBytes,
                                    liveTransientBytes: payloadTransientBytes,
                                    parserStage: "tile-qcd-parameters",
                                    message: "Retained tile QCD metadata exceeds workspace or memory limits."
                                )
                            }
                        }
                    case Marker.qcc:
                        let (component, segment) = try parseQCC(payload, componentCount: size.components.count) { bandCount, hasMantissas in
                            let totalInts = hasMantissas ? bandCount * 2 : bandCount
                            let expandedBytes = try checkedAdd(
                                hasMantissas ? 128 : 96,
                                try checkedMultiply(totalInts, MemoryLayout<Int>.stride)
                            )
                            try admitRetained(
                                expandedBytes,
                                liveTransientBytes: payloadTransientBytes,
                                message: "Retained tile QCC metadata exceeds workspace or memory limits."
                            )
                        }
                        if component == 0 { overrides.componentQuantization = segment }
                        overrides.componentQuantizations[component] = segment
                    default:
                        let segment = try parseRGN(payload, componentCount: size.components.count)
                        try admitRetained(
                            48,
                            liveTransientBytes: payloadTransientBytes,
                            message: "Retained tile RGN metadata exceeds workspace or memory limits."
                        )
                        overrides.regionsOfInterest[segment.component] = segment
                    }
                case Marker.poc:
                    let payload = try readSegmentPayload(
                        &reader,
                        marker: tileMarker,
                        limits: limits,
                        codestreamBytes: bytes.count,
                        retainedBytes: retainedMetadataBytes
                    )
                    let payloadTransientBytes = try checkedAdd(32, payload.count)
                    if !hasOverrides {
                        try admitRetained(
                            128,
                            liveTransientBytes: payloadTransientBytes,
                            parserStage: "tile-overrides",
                            message: "Retained tile-header overrides exceed workspace or memory limits."
                        )
                        hasOverrides = true
                    }
                    try parsePOC(payload, componentCount: size.components.count, into: &overrides.progressionChanges) { addedRetained, reallocOverlap in
                        let totalTransient = try checkedAdd(payloadTransientBytes, reallocOverlap)
                        try admitRetained(
                            addedRetained,
                            liveTransientBytes: totalTransient,
                            parserStage: "tile-poc-entries",
                            message: "Retained tile POC metadata exceeds workspace or memory limits."
                        )
                    }
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
            if hasOverrides {
                tileOverrides[tileIndex] = overrides
            }
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
            try admitRetained(
                96,
                parserStage: "tile-part-record",
                message: "Retained tile-part records exceed workspace or memory limits."
            )
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
            baseCodingStyle: baseCOD,
            componentCodingStyles: coc,
            baseQuantization: baseQCD,
            componentQuantizations: qcc,
            regionsOfInterest: rgn,
            progressionChanges: poc,
            tileParts: tileParts,
            tileOverrides: tileOverrides,
            sawEndOfCodestream: sawEOC,
            mainHeaderMarkers: markers,
            mainHeaderComments: mainHeaderComments,
            componentRegistration: crg,
            commentCount: totalCommentCount,
            commentPayloadBytes: totalCommentBytes,
            retainedMetadataBytes: retainedMetadataBytes
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

        let cap = parsed.extendedCapabilities

        func validateCodeBlockStyle(_ codeBlockStyle: UInt8) throws {
            let htBit = (codeBlockStyle & 0x40) != 0
            let mixedBit = (codeBlockStyle & 0x80) != 0
            if mixedBit && !htBit {
                throw CodecError(.malformedInput, "COD/COC sets HT mixed bit (0x80) without HT coding bit (0x40).")
            }
            if htBit {
                guard let cap else {
                    throw CodecError(.malformedInput, "COD/COC enables HTJ2K block coding (0x40) without a Part 15 CAP marker segment.")
                }
                if mixedBit && cap.mode != .mixed {
                    throw CodecError(.malformedInput, "COD/COC enables mixed HT/Part 1 coding (0xC0) when CAP Ccap15 is not HTMIXED.")
                }
            } else if let cap, cap.mode == .htOnly {
                throw CodecError(.malformedInput, "CAP Ccap15 signals HTONLY but COD/COC does not set the HT coding style bit (0x40).")
            }
        }

        // Validate main-header and tile-override code-block style flags directly without allocating
        // intermediate CodingStyleSegment arrays or sorted dictionary-key lists after parser admission.
        try validateCodeBlockStyle(parsed.codingStyle.codeBlockStyle)
        for (comp, coc) in parsed.componentCodingStyles where comp != 0 {
            try validateCodeBlockStyle(coc.codeBlockStyle)
        }
        for overrides in parsed.tileOverrides.values {
            let tileComp0Style = overrides.componentCodingStyle?.codeBlockStyle
                ?? overrides.codingStyle?.codeBlockStyle
                ?? parsed.codingStyle.codeBlockStyle
            try validateCodeBlockStyle(tileComp0Style)
            for (comp, tileCOC) in overrides.componentCodingStyles where comp != 0 {
                try validateCodeBlockStyle(tileCOC.codeBlockStyle)
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

    static func parseCPF(
        _ payload: [UInt8],
        admitValues: (Int) throws -> Void = { _ in }
    ) throws -> CorrespondingProfileSegment {
        guard payload.count >= 2, payload.count % 2 == 0 else {
            throw CodecError(.malformedInput, "CPF marker segment has an invalid length.")
        }
        let valueCount = payload.count / 2
        try admitValues(valueCount)
        var r = ByteReader(payload)
        var values: [UInt16] = []
        values.reserveCapacity(valueCount)
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
        codestreamBytes: Int,
        retainedBytes: Int = 0
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
        let cumulativeWorkspaceBytes = try checkedAdd(retainedBytes, segmentAllocationBytes)
        guard cumulativeWorkspaceBytes <= limits.maximumWorkspaceBytes,
              try checkedAdd(codestreamBytes, cumulativeWorkspaceBytes) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Marker segment \(String(marker, radix: 16)) payload exceeds workspace or memory limits.")
        }
        let start = reader.position
        try reader.skip(payloadCount)
        return Array(reader.bytes[start..<start + payloadCount])
    }

    // MARK: - SIZ

    static func parseSIZ(
        _ payload: [UInt8],
        limits: ResourceLimits,
        admitComponents: (Int) throws -> Void = { _ in }
    ) throws -> ImageSizeSegment {
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
        // Validate every component descriptor in place before admitting and constructing the array.
        let componentsStart = r.position
        for _ in 0..<csiz {
            let ssiz = try r.readUInt8(), xr = Int(try r.readUInt8()), yr = Int(try r.readUInt8())
            let precision = Int(ssiz & 0x7F) + 1
            guard precision <= 38, xr >= 1, yr >= 1 else {
                throw CodecError(.malformedInput, "SIZ component precision or sub-sampling is out of range.")
            }
        }
        try admitComponents(csiz)
        try r.seek(to: componentsStart)
        var components: [ComponentSignalling] = []
        components.reserveCapacity(csiz)
        for _ in 0..<csiz {
            let ssiz = try r.readUInt8(), xr = Int(try r.readUInt8()), yr = Int(try r.readUInt8())
            let precision = Int(ssiz & 0x7F) + 1
            components.append(ComponentSignalling(precision: precision, signed: ssiz & 0x80 != 0,
                                                  horizontalSeparation: xr, verticalSeparation: yr))
        }
        return ImageSizeSegment(capabilities: rsiz, width: xsiz, height: ysiz, originX: xosiz, originY: yosiz,
                                tileWidth: xtsiz, tileHeight: ytsiz, tileOriginX: xtosiz, tileOriginY: ytosiz,
                                components: components)
    }

    // MARK: - COD / COC

    static func parseCOD(
        _ payload: [UInt8],
        admitPrecincts: (Int) throws -> Void = { _ in }
    ) throws -> CodingStyleSegment {
        var r = ByteReader(payload)
        let scod = try r.readUInt8()
        let progression = try r.readUInt8()
        let layers = Int(try r.readUInt16())
        let mct = try r.readUInt8()
        guard layers >= 1 else { throw CodecError(.malformedInput, "COD declares zero layers.") }
        guard progression <= 4 else { throw CodecError(.malformedInput, "COD progression order is out of range.") }
        var segment = try parseCodingParameters(&r, usesPrecincts: scod & 0x01 != 0, admitPrecincts: admitPrecincts)
        segment.usesSOP = scod & 0x02 != 0
        segment.usesEPH = scod & 0x04 != 0
        segment.progression = progression
        segment.layers = layers
        segment.componentTransform = mct
        guard r.isAtEnd else { throw CodecError(.malformedInput, "COD has trailing bytes.") }
        return segment
    }

    static func parseCOC(
        _ payload: [UInt8],
        componentCount: Int,
        admitPrecincts: (Int) throws -> Void = { _ in }
    ) throws -> (Int, CodingStyleSegment) {
        var r = ByteReader(payload)
        let component = componentCount < 257 ? Int(try r.readUInt8()) : Int(try r.readUInt16())
        guard component < componentCount else { throw CodecError(.malformedInput, "COC names a missing component.") }
        let scoc = try r.readUInt8()
        let segment = try parseCodingParameters(&r, usesPrecincts: scoc & 0x01 != 0, admitPrecincts: admitPrecincts)
        guard r.isAtEnd else { throw CodecError(.malformedInput, "COC has trailing bytes.") }
        return (component, segment)
    }

    private static func parseCodingParameters(
        _ r: inout ByteReader,
        usesPrecincts: Bool,
        admitPrecincts: (Int) throws -> Void
    ) throws -> CodingStyleSegment {
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
        let precinctCount = usesPrecincts ? (levels + 1) : 0
        if usesPrecincts {
            guard r.remaining >= precinctCount else {
                throw CodecError(.malformedInput, "COD/COC precinct table is truncated.")
            }
        }
        try admitPrecincts(precinctCount)
        var precincts: [(Int, Int)] = []
        if usesPrecincts {
            precincts.reserveCapacity(precinctCount)
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

    static func parseQuantization(
        _ payload: [UInt8],
        admitBands: (Int, Bool) throws -> Void = { _, _ in }
    ) throws -> QuantizationSegment {
        var r = ByteReader(payload)
        return try parseQuantizationBody(&r, admitBands: admitBands)
    }

    static func parseQCC(
        _ payload: [UInt8],
        componentCount: Int,
        admitBands: (Int, Bool) throws -> Void = { _, _ in }
    ) throws -> (Int, QuantizationSegment) {
        var r = ByteReader(payload)
        let component = componentCount < 257 ? Int(try r.readUInt8()) : Int(try r.readUInt16())
        guard component < componentCount else { throw CodecError(.malformedInput, "QCC names a missing component.") }
        return (component, try parseQuantizationBody(&r, admitBands: admitBands))
    }

    private static func parseQuantizationBody(
        _ r: inout ByteReader,
        admitBands: (Int, Bool) throws -> Void
    ) throws -> QuantizationSegment {
        let sqcd = try r.readUInt8()
        let guardBits = Int(sqcd >> 5)
        guard let style = QuantizationSegment.Style(rawValue: sqcd & 0x1F) else {
            throw CodecError(.malformedInput, "Unknown quantization style.")
        }
        let rem = r.remaining
        let bandCount: Int
        let hasMantissas: Bool
        switch style {
        case .none:
            bandCount = rem
            hasMantissas = false
        case .scalarDerived, .scalarExpounded:
            guard rem % 2 == 0 else {
                throw CodecError(.malformedInput, "Quantization segment has an odd byte count for 16-bit band entries.")
            }
            bandCount = rem / 2
            hasMantissas = true
        }
        guard bandCount >= 1, bandCount <= 97 else {
            throw CodecError(.malformedInput, "Quantization segment has no band entries.")
        }
        try admitBands(bandCount, hasMantissas)
        var exponents: [Int] = []
        exponents.reserveCapacity(bandCount)
        var mantissas: [Int] = []
        if hasMantissas { mantissas.reserveCapacity(bandCount) }
        switch style {
        case .none:
            while !r.isAtEnd { exponents.append(Int(try r.readUInt8() >> 3)) }
        case .scalarDerived, .scalarExpounded:
            while !r.isAtEnd {
                let value = try r.readUInt16()
                exponents.append(Int(value >> 11)); mantissas.append(Int(value & 0x7FF))
            }
        }
        return QuantizationSegment(style: style, guardBits: guardBits, exponents: exponents, mantissas: mantissas)
    }

    // MARK: - RGN / POC

    static func parseRGN(_ payload: [UInt8], componentCount: Int) throws -> RegionOfInterestSegment {
        var r = ByteReader(payload)
        let component = componentCount < 257 ? Int(try r.readUInt8()) : Int(try r.readUInt16())
        guard component < componentCount else {
            throw CodecError(.malformedInput, "RGN names a missing component.")
        }
        let style = try r.readUInt8()
        guard style == 0 else {
            throw CodecError(.unsupportedFeature, "RGN style \(style) is not supported; only MaxShift (Srgn = 0) is part of ISO/IEC 15444-1.")
        }
        let shift = Int(try r.readUInt8())
        guard shift <= 37, r.isAtEnd else {
            throw CodecError(.malformedInput, "RGN shift is out of range or segment has trailing bytes.")
        }
        return RegionOfInterestSegment(component: component, style: style, shift: shift)
    }

    static func parsePOC(
        _ payload: [UInt8],
        componentCount: Int,
        into destination: inout [ProgressionOrderChangeEntry],
        admitGrowth: (_ addedRetainedBytes: Int, _ transientReallocOverlapBytes: Int) throws -> Void = { _, _ in }
    ) throws {
        let entrySize = componentCount < 257 ? 7 : 9
        guard !payload.isEmpty, payload.count % entrySize == 0 else {
            throw CodecError(.malformedInput, "POC marker segment length is not a multiple of entry size \(entrySize).")
        }
        let entryCount = payload.count / entrySize

        // Validate every POC entry directly from the byte slice before admitting or allocating.
        var validator = ByteReader(payload)
        while !validator.isAtEnd {
            let rs = Int(try validator.readUInt8())
            let cs = componentCount < 257 ? Int(try validator.readUInt8()) : Int(try validator.readUInt16())
            let lye = Int(try validator.readUInt16())
            let re = Int(try validator.readUInt8())
            let rawCE = componentCount < 257 ? Int(try validator.readUInt8()) : Int(try validator.readUInt16())
            let ce = (componentCount < 257 && rawCE == 0) ? 256 : rawCE
            let prog = try validator.readUInt8()
            guard rs < re, re <= 33, cs < ce, lye >= 1, prog <= 4 else {
                throw CodecError(.malformedInput, "POC entry bounds or progression order are invalid.")
            }
        }

        let stride = MemoryLayout<ProgressionOrderChangeEntry>.stride
        let oldCount = destination.count
        let newCount = try checkedAdd(oldCount, entryCount)
        let addedEntriesBytes = try checkedMultiply(entryCount, stride)
        let addedRetainedBytes: Int
        let transientReallocOverlapBytes: Int
        if oldCount == 0 {
            addedRetainedBytes = try checkedAdd(32, addedEntriesBytes)
            transientReallocOverlapBytes = 0
        } else {
            // While building the exact-capacity grown buffer (`32 + newCount * stride`),
            // `destination`'s old buffer (`32 + oldCount * stride`, already in retainedMetadataBytes)
            // remains live until `destination = grown` replaces it.
            let oldBufferBytes = try checkedAdd(32, try checkedMultiply(oldCount, stride))
            addedRetainedBytes = addedEntriesBytes
            transientReallocOverlapBytes = oldBufferBytes
        }
        try admitGrowth(addedRetainedBytes, transientReallocOverlapBytes)

        var grown: [ProgressionOrderChangeEntry] = []
        grown.reserveCapacity(newCount)
        if oldCount > 0 {
            grown.append(contentsOf: destination)
        }
        var r = ByteReader(payload)
        while !r.isAtEnd {
            let rs = Int(try r.readUInt8())
            let cs = componentCount < 257 ? Int(try r.readUInt8()) : Int(try validatorCheckedReadUInt(from: &r, twoBytes: componentCount >= 257))
            let lye = Int(try r.readUInt16())
            let re = Int(try r.readUInt8())
            let rawCE = componentCount < 257 ? Int(try r.readUInt8()) : Int(try validatorCheckedReadUInt(from: &r, twoBytes: componentCount >= 257))
            let ce = (componentCount < 257 && rawCE == 0) ? 256 : rawCE
            let prog = try r.readUInt8()
            grown.append(ProgressionOrderChangeEntry(
                resolutionStart: rs, componentStart: cs, layerEnd: lye,
                resolutionEnd: re, componentEnd: ce, progression: prog
            ))
        }
        destination = grown
    }

    @inline(__always)
    private static func validatorCheckedReadUInt(from reader: inout ByteReader, twoBytes: Bool) throws -> UInt16 {
        twoBytes ? try reader.readUInt16() : UInt16(try reader.readUInt8())
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
        var p = ByteWriter(capacity: 2 + 2 * qcd.exponents.count)
        p.writeUInt8(UInt8(qcd.guardBits) << 5 | qcd.style.rawValue)
        switch qcd.style {
        case .none:
            for exponent in qcd.exponents { p.writeUInt8(UInt8(exponent) << 3) }
        case .scalarDerived:
            if let exp0 = qcd.exponents.first, let man0 = qcd.mantissas.first {
                p.writeUInt16(UInt16(exp0) << 11 | UInt16(man0))
            }
        case .scalarExpounded:
            for (exponent, mantissa) in zip(qcd.exponents, qcd.mantissas) {
                p.writeUInt16(UInt16(exponent) << 11 | UInt16(mantissa))
            }
        }
        try w.writeSegment(marker: Marker.qcd, payload: p.bytes)
    }

    static func writeRGN<Output: CodestreamByteSink & ~Copyable>(_ rgn: RegionOfInterestSegment, componentCount: Int, into w: inout Output) throws {
        var p = ByteWriter(capacity: 4)
        if componentCount < 257 {
            p.writeUInt8(UInt8(rgn.component))
        } else {
            p.writeUInt16(UInt16(rgn.component))
        }
        p.writeUInt8(rgn.style)
        p.writeUInt8(UInt8(rgn.shift))
        try w.writeSegment(marker: Marker.rgn, payload: p.bytes)
    }

    static func writePOC<Output: CodestreamByteSink & ~Copyable>(_ entries: [ProgressionOrderChangeEntry], componentCount: Int, into w: inout Output) throws {
        guard !entries.isEmpty else { return }
        var p = ByteWriter(capacity: entries.count * (componentCount < 257 ? 7 : 9))
        for entry in entries {
            p.writeUInt8(UInt8(entry.resolutionStart))
            if componentCount < 257 {
                p.writeUInt8(UInt8(entry.componentStart))
            } else {
                p.writeUInt16(UInt16(entry.componentStart))
            }
            p.writeUInt16(UInt16(entry.layerEnd))
            p.writeUInt8(UInt8(entry.resolutionEnd))
            if componentCount < 257 {
                p.writeUInt8(entry.componentEnd == 256 ? 0 : UInt8(entry.componentEnd))
            } else {
                p.writeUInt16(UInt16(entry.componentEnd))
            }
            p.writeUInt8(entry.progression)
        }
        try w.writeSegment(marker: Marker.poc, payload: p.bytes)
    }
}
