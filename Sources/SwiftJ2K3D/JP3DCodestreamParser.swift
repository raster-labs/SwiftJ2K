// SPDX-License-Identifier: Apache-2.0
//
// JP3DCodestreamParser.swift
// SwiftJ2K3D
//
// Migrated from Raster-Lab/J2KSwift Sources/J2K3D/JP3DCodestreamParser.swift
// at commit 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca.
//
// Changes relative to the predecessor:
//   - Hardened marker segment bounds and tile-part length validation with checked
//     integer arithmetic so crafted or truncated SIZ, NSI, COD, QCD, RGN, COM, CAP, CPF,
//     or SOT segments throw J2KError.decodingError instead of trapping.
//   - Implemented normative ITU-T T.809 (05/2011) | ISO/IEC 15444-10 main-header and
//     tile-part marker parsing: SIZ (Lsiz = 38 + 3*Csiz, Rsiz = 0x4000, heterogeneous Ssiz^i),
//     mandatory CAP (0xFF50, Pcap^10 = 0x0040_0000 and reconciled T.814 Pcap^15 = 0x0002_0000),
//     NSI (0xFF54, Lnsi = 19 + Csiz, Ndim = 3, Zsiz/ZOsiz/ZTsiz/ZTOsiz/ZRsiz^i),
//     3D COD (0xFF52, Lcod = 17 [+ 2*(NL+1)], shift=0 xcb/ycb/zcb, dwtX/Y/Z, 3D precincts),
//     COC (0xFF53), Morton-order 3D QCD (0xFF5C, styles 0/1/2), QCC (0xFF5D), RGN (0xFF5E),
//     COM (0xFF64), and multi-tile-part SOT..SOD concatenation.

import Foundation
import SwiftJ2K

/// Metadata parsed from JP3D `SIZ` (`0xFF51`) and `NSI` (`0xFF54`) marker segments.
public struct JP3DSIZInfo: Sendable {
    /// Volume width (`Xsiz - XOsiz`).
    public let width: Int
    /// Volume height (`Ysiz - YOsiz`).
    public let height: Int
    /// Volume depth (`Zsiz - ZOsiz`).
    public let depth: Int
    /// Tile width (`XTsiz`).
    public let tileSizeX: Int
    /// Tile height (`YTsiz`).
    public let tileSizeY: Int
    /// Tile depth (`ZTsiz`).
    public let tileSizeZ: Int
    /// Number of components (`Csiz`).
    public let componentCount: Int
    /// Primary component bit depth (1-based: `(Ssiz^0 & 0x7F) + 1`).
    public let bitDepth: Int
    /// Whether the primary component is signed (`(Ssiz^0 & 0x80) != 0`).
    public let signed: Bool

    /// Profile / capabilities indicator (`Rsiz`, `0x4000` when `CAP` is present).
    public let rsiz: UInt16
    /// Reference grid horizontal origin (`XOsiz`).
    public let originX: Int
    /// Reference grid vertical origin (`YOsiz`).
    public let originY: Int
    /// Reference grid axial origin (`ZOsiz`, from `NSI`).
    public let originZ: Int
    /// Tile grid horizontal origin (`XTOsiz`).
    public let tileOriginX: Int
    /// Tile grid vertical origin (`YTOsiz`).
    public let tileOriginY: Int
    /// Tile grid axial origin (`ZTOsiz`, from `NSI`).
    public let tileOriginZ: Int
    /// Per-component bit depths (`1...38`).
    public let componentBitDepths: [Int]
    /// Per-component signedness flags.
    public let componentSigned: [Bool]
    /// Per-component horizontal sample separation (`XRsiz^i`).
    public let componentSubsamplingX: [Int]
    /// Per-component vertical sample separation (`YRsiz^i`).
    public let componentSubsamplingY: [Int]
    /// Per-component axial sample separation (`ZRsiz^i`, from `NSI`).
    public let componentSubsamplingZ: [Int]

    public init(
        width: Int,
        height: Int,
        depth: Int,
        tileSizeX: Int,
        tileSizeY: Int,
        tileSizeZ: Int,
        componentCount: Int,
        bitDepth: Int,
        signed: Bool
    ) {
        self.width = width
        self.height = height
        self.depth = depth
        self.tileSizeX = tileSizeX
        self.tileSizeY = tileSizeY
        self.tileSizeZ = tileSizeZ
        self.componentCount = componentCount
        self.bitDepth = bitDepth
        self.signed = signed
        self.rsiz = 0x4000
        self.originX = 0
        self.originY = 0
        self.originZ = 0
        self.tileOriginX = 0
        self.tileOriginY = 0
        self.tileOriginZ = 0
        let count = max(1, componentCount)
        self.componentBitDepths = [Int](repeating: bitDepth, count: count)
        self.componentSigned = [Bool](repeating: signed, count: count)
        self.componentSubsamplingX = [Int](repeating: 1, count: count)
        self.componentSubsamplingY = [Int](repeating: 1, count: count)
        self.componentSubsamplingZ = [Int](repeating: 1, count: count)
    }

    package init(
        width: Int,
        height: Int,
        depth: Int,
        tileSizeX: Int,
        tileSizeY: Int,
        tileSizeZ: Int,
        componentCount: Int,
        bitDepth: Int,
        signed: Bool,
        rsiz: UInt16,
        originX: Int,
        originY: Int,
        originZ: Int,
        tileOriginX: Int,
        tileOriginY: Int,
        tileOriginZ: Int,
        componentBitDepths: [Int],
        componentSigned: [Bool],
        componentSubsamplingX: [Int],
        componentSubsamplingY: [Int],
        componentSubsamplingZ: [Int]
    ) {
        self.width = width
        self.height = height
        self.depth = depth
        self.tileSizeX = tileSizeX
        self.tileSizeY = tileSizeY
        self.tileSizeZ = tileSizeZ
        self.componentCount = componentCount
        self.bitDepth = bitDepth
        self.signed = signed
        self.rsiz = rsiz
        self.originX = originX
        self.originY = originY
        self.originZ = originZ
        self.tileOriginX = tileOriginX
        self.tileOriginY = tileOriginY
        self.tileOriginZ = tileOriginZ
        self.componentBitDepths = componentBitDepths
        self.componentSigned = componentSigned
        self.componentSubsamplingX = componentSubsamplingX
        self.componentSubsamplingY = componentSubsamplingY
        self.componentSubsamplingZ = componentSubsamplingZ
    }

    package func bitDepth(forComponent index: Int) -> Int {
        guard index >= 0, index < componentBitDepths.count else { return bitDepth }
        return componentBitDepths[index]
    }

    package func isSigned(forComponent index: Int) -> Bool {
        guard index >= 0, index < componentSigned.count else { return signed }
        return componentSigned[index]
    }

    package func withNSI(
        depth: Int,
        originZ: Int,
        tileSizeZ: Int,
        tileOriginZ: Int,
        subsamplingZ: [Int]
    ) -> JP3DSIZInfo {
        JP3DSIZInfo(
            width: width,
            height: height,
            depth: depth,
            tileSizeX: tileSizeX,
            tileSizeY: tileSizeY,
            tileSizeZ: tileSizeZ,
            componentCount: componentCount,
            bitDepth: bitDepth,
            signed: signed,
            rsiz: rsiz,
            originX: originX,
            originY: originY,
            originZ: originZ,
            tileOriginX: tileOriginX,
            tileOriginY: tileOriginY,
            tileOriginZ: tileOriginZ,
            componentBitDepths: componentBitDepths,
            componentSigned: componentSigned,
            componentSubsamplingX: componentSubsamplingX,
            componentSubsamplingY: componentSubsamplingY,
            componentSubsamplingZ: subsamplingZ
        )
    }
}

/// Coding parameters parsed from a JP3D `COD` (`0xFF52`) marker segment.
public struct JP3DCODInfo: Sendable {
    /// Decomposition levels along X (`NLX`).
    public let levelsX: Int
    /// Decomposition levels along Y (`NLY`).
    public let levelsY: Int
    /// Decomposition levels along Z (`NLZ`).
    public let levelsZ: Int
    /// Whether lossless reversible 5-3 wavelet transform was used across all axes (`dwtX == 1 && dwtY == 1 && dwtZ == 1`).
    public let isLossless: Bool
    /// Code-block style byte (bit 6 `0x40` indicates HTJ2K block coding).
    public let codeBlockStyle: UInt8

    /// Coding style flags (`Scod`: bit 0 = custom 3D precincts, bit 1 = SOP, bit 2 = EPH).
    public let scod: UInt8
    /// ITU-T T.809 Table A.8 progression order code (`0 = LRCP, 1 = RLCP, 2 = RPCL, 3 = PCRL, 4 = CPRL`).
    public let progressionOrderByte: UInt8
    /// Number of quality layers (`>= 1`).
    public let numLayers: Int
    /// Multiple component transformation flag (`0` = none, `1` = RCT/ICT on components `0..2`).
    public let multipleComponentTransform: UInt8
    /// Code-block width exponent `xcb` (actual power-of-two exponent `0...10`, nominal width `2^xcb`).
    public let codeBlockWidthExponent: Int
    /// Code-block height exponent `ycb` (actual power-of-two exponent `0...10`, nominal height `2^ycb`).
    public let codeBlockHeightExponent: Int
    /// Code-block depth exponent `zcb` (actual power-of-two exponent `0...10`, nominal depth `2^zcb`; `0` for HTJ2K).
    public let codeBlockDepthExponent: Int
    /// X-axis wavelet kernel (`1` = 5-3 reversible, `0` = 9-7 irreversible).
    public let dwtX: UInt8
    /// Y-axis wavelet kernel (`1` = 5-3 reversible, `0` = 9-7 irreversible).
    public let dwtY: UInt8
    /// Z-axis wavelet kernel (`1` = 5-3 reversible, `0` = 9-7 irreversible).
    public let dwtZ: UInt8
    /// Per-resolution 3D precinct exponents `(PPx, PPy, PPz)` when `(scod & 0x01) != 0`.
    public let precinctSizes: [(ppx: Int, ppy: Int, ppz: Int)]

    public init(
        levelsX: Int,
        levelsY: Int,
        levelsZ: Int,
        isLossless: Bool,
        codeBlockStyle: UInt8 = 0
    ) {
        self.levelsX = levelsX
        self.levelsY = levelsY
        self.levelsZ = levelsZ
        self.isLossless = isLossless
        self.codeBlockStyle = codeBlockStyle
        self.scod = 0
        self.progressionOrderByte = 0
        self.numLayers = 1
        self.multipleComponentTransform = 0
        let isHT = (codeBlockStyle & 0x40) != 0
        self.codeBlockWidthExponent = 6
        self.codeBlockHeightExponent = 6
        self.codeBlockDepthExponent = isHT ? 0 : 2
        let w: UInt8 = isLossless ? 1 : 0
        self.dwtX = w
        self.dwtY = w
        self.dwtZ = w
        self.precinctSizes = []
    }

    package init(
        levelsX: Int,
        levelsY: Int,
        levelsZ: Int,
        isLossless: Bool,
        codeBlockStyle: UInt8,
        scod: UInt8,
        progressionOrderByte: UInt8,
        numLayers: Int,
        multipleComponentTransform: UInt8,
        codeBlockWidthExponent: Int,
        codeBlockHeightExponent: Int,
        codeBlockDepthExponent: Int,
        dwtX: UInt8,
        dwtY: UInt8,
        dwtZ: UInt8,
        precinctSizes: [(ppx: Int, ppy: Int, ppz: Int)] = []
    ) {
        self.levelsX = levelsX
        self.levelsY = levelsY
        self.levelsZ = levelsZ
        self.isLossless = isLossless
        self.codeBlockStyle = codeBlockStyle
        self.scod = scod
        self.progressionOrderByte = progressionOrderByte
        self.numLayers = max(1, numLayers)
        self.multipleComponentTransform = multipleComponentTransform
        self.codeBlockWidthExponent = codeBlockWidthExponent
        self.codeBlockHeightExponent = codeBlockHeightExponent
        self.codeBlockDepthExponent = codeBlockDepthExponent
        self.dwtX = dwtX
        self.dwtY = dwtY
        self.dwtZ = dwtZ
        self.precinctSizes = precinctSizes
    }

    package var usesCustomPrecincts: Bool { (scod & 0x01) != 0 }
    package var usesSOP: Bool { (scod & 0x02) != 0 }
    package var usesEPH: Bool { (scod & 0x04) != 0 }

    package func precinctExponents(forResolution r: Int) -> (ppx: Int, ppy: Int, ppz: Int) {
        if usesCustomPrecincts, r >= 0, r < precinctSizes.count {
            return precinctSizes[r]
        }
        return (15, 15, 15)
    }

    /// Merges a component-specific `COC` (`0xFF53`) override onto a `COD` base (`ITU-T T.809` Clause A.2.3),
    /// preserving tile-wide `SGcod` parameters (`progressionOrderByte`, `numLayers`, `multipleComponentTransform`,
    /// `SOP`/`EPH` bits `1..2` of `Scod`) while overriding `SPcoc` and custom precinct bit `0`.
    package func applying(coc: JP3DCODInfo) -> JP3DCODInfo {
        let mergedScod = (scod & 0x06) | (coc.scod & 0x01)
        return JP3DCODInfo(
            levelsX: coc.levelsX,
            levelsY: coc.levelsY,
            levelsZ: coc.levelsZ,
            isLossless: coc.isLossless,
            codeBlockStyle: coc.codeBlockStyle,
            scod: mergedScod,
            progressionOrderByte: progressionOrderByte,
            numLayers: numLayers,
            multipleComponentTransform: multipleComponentTransform,
            codeBlockWidthExponent: coc.codeBlockWidthExponent,
            codeBlockHeightExponent: coc.codeBlockHeightExponent,
            codeBlockDepthExponent: coc.codeBlockDepthExponent,
            dwtX: coc.dwtX,
            dwtY: coc.dwtY,
            dwtZ: coc.dwtZ,
            precinctSizes: coc.precinctSizes
        )
    }
}

/// First-tile-part (`TPsot == 0`) functional marker overrides for one tile (`ITU-T T.809` Clauses A.2.2–A.2.6).
package struct JP3DTileHeaderOverrides: Sendable {
    package var cod: JP3DCODInfo?
    package var coc: [Int: JP3DCODInfo] = [:]
    package var qcd: JP3DQuantizationParameters?
    package var qcdExplicitSubbandCount: Int?
    package var qcc: [Int: (params: JP3DQuantizationParameters, explicitSubbandCount: Int?)] = [:]
    package var rgnAllComponents: Int?
    package var rgnByComponent: [Int: Int] = [:]

    package init() {}

    package var hasAnyFunctionalOverride: Bool {
        cod != nil || !coc.isEmpty || qcd != nil || !qcc.isEmpty || rgnAllComponents != nil || !rgnByComponent.isEmpty
    }
}

/// Normative ITU-T T.809 Table A.1 / ITU-T T.801 `CBD` (`0xFF78`) + `MCT` (`0xFF74`) + `MCC` (`0xFF75`) + `MCO` (`0xFF77`)
/// reversible `19 + (B - 19)` multi-component synthesis descriptor for extreme-range `35...38`-bit lossless volumes
/// whose wavelet sub-band magnitudes exceed the single-component `G + eps_b - 1 <= 37` Part 10 `QCD` ceiling.
package struct JP3DPart2BitSplitDescriptor: Sendable, Equatable {
    package static let defaultSplitLowBits = 19

    package let logicalComponentBitDepths: [Int]
    package let logicalComponentSigned: [Bool]
    package let rawMarkerSegments: Data

    package init(
        logicalComponentBitDepths: [Int],
        logicalComponentSigned: [Bool],
        rawMarkerSegments: Data
    ) {
        self.logicalComponentBitDepths = logicalComponentBitDepths
        self.logicalComponentSigned = logicalComponentSigned
        self.rawMarkerSegments = rawMarkerSegments
    }

    package var logicalComponentCount: Int { logicalComponentBitDepths.count }

    /// Builds normative `CBD` (`0xFF78`), `MCT` (`0xFF74`), `MCC` (`0xFF75`), and `MCO` (`0xFF77`) main-header marker segments
    /// mapping `2 * N` codestream components `(lo_19bit_unsigned, hi_(B-19)bit)` into `N` reconstructed `B`-bit output components
    /// via integer decorrelation matrix `[1, 2^19]`.
    package static func buildMarkerSegments(
        logicalBitDepths: [Int],
        logicalSigned: [Bool]
    ) -> JP3DPart2BitSplitDescriptor {
        let n = logicalBitDepths.count
        var buf = Data()

        func appendU16(_ v: UInt16) {
            buf.append(UInt8((v >> 8) & 0xFF))
            buf.append(UInt8(v & 0xFF))
        }
        func appendU32(_ v: UInt32) {
            buf.append(UInt8((v >> 24) & 0xFF))
            buf.append(UInt8((v >> 16) & 0xFF))
            buf.append(UInt8((v >> 8) & 0xFF))
            buf.append(UInt8(v & 0xFF))
        }

        // 1. CBD (0xFF78, ITU-T T.801 A.3.7): Lcbd = 4 + N, Ncbd = N (bit 15 = 0 => explicit BDcbd^i)
        appendU16(0xFF78)
        appendU16(UInt16(4 + n))
        appendU16(UInt16(n))
        for i in 0..<n {
            let depth = max(1, min(38, logicalBitDepths[i]))
            let sgn = i < logicalSigned.count ? logicalSigned[i] : false
            buf.append((sgn ? 0x80 : 0x00) | UInt8(depth - 1))
        }

        // 2. MCT (0xFF74, ITU-T T.801 A.3.8): Lmct = 16, Zmct = 0, Imct = 0x0501 (Int32 decorrelation array #1),
        //    Ymct = 0, SPmct = [Int32(1), Int32(524288)] (1 x 2 synthesis matrix `[1, 2^19]`).
        appendU16(0xFF74)
        appendU16(16)
        appendU16(0)
        appendU16(0x0501)
        appendU16(0)
        appendU32(1)
        appendU32(524_288)

        // 3. MCC (0xFF75, ITU-T T.801 A.3.9): stage Imcc = 1, Qmcc = N collections, each 11 bytes:
        //    Xmcc = 0x09 (reversible matrix decorrelation), Nmcc = 2 (`2*c`, `2*c+1`), Mmcc = 1 (`c`), Tmcc = 0x000001 (array #1).
        let lmcc = 9 + 11 * n
        appendU16(0xFF75)
        appendU16(UInt16(lmcc))
        appendU16(0)      // Zmcc = 0
        buf.append(1)     // Imcc = 1
        appendU16(0)      // Ymcc = 0
        appendU16(UInt16(n)) // Qmcc = N
        for c in 0..<n {
            buf.append(0x09) // Xmcc: reversible matrix decorrelation
            appendU16(2)     // Nmcc = 2 (8-bit indices)
            buf.append(UInt8(2 * c))
            buf.append(UInt8(2 * c + 1))
            appendU16(1)     // Mmcc = 1 (8-bit index)
            buf.append(UInt8(c))
            buf.append(0x00) // Tmcc (24 bits): reversible=0, offset=0, decorrelation=1
            buf.append(0x00)
            buf.append(0x01)
        }

        // 4. MCO (0xFF77, ITU-T T.801 A.3.10): Lmco = 4, Nmco = 1, Imco^1 = 1
        appendU16(0xFF77)
        appendU16(4)
        buf.append(1)
        buf.append(1)

        return JP3DPart2BitSplitDescriptor(
            logicalComponentBitDepths: logicalBitDepths,
            logicalComponentSigned: logicalSigned,
            rawMarkerSegments: buf
        )
    }
}

/// Encoded data for a single tile parsed from the codestream.
public struct JP3DParsedTile: Sendable {
    /// The tile index (as written in the SOT marker).
    public let tileIndex: Int
    /// Raw encoded data for this tile (after the SOD marker; concatenated in `TPsot` order across tile-parts).
    public let data: Data

    public init(tileIndex: Int, data: Data) {
        self.tileIndex = tileIndex
        self.data = data
    }
}

/// Complete parsed representation of a JP3D codestream.
public struct JP3DParsedCodestream: Sendable {
    /// Volume and tile geometry from `SIZ` and `NSI`.
    public let siz: JP3DSIZInfo
    /// Coding parameters from `COD`.
    public let cod: JP3DCODInfo
    /// Whether quantisation is lossless (`QCD` style `== 0`).
    public let isLosslessQuantization: Bool
    /// Per-tile encoded data, ordered by tile index.
    public let tiles: [JP3DParsedTile]
    /// Whether a main-header `CAP` (`0xFF50`) marker was present.
    public let hasCAPMarker: Bool
    /// Raw 32-bit `Pcap` capability mask when `CAP` (`0xFF50`) was present.
    public let pcap: UInt32?
    /// `Ccap^10` capability word when `Pcap^10` (`0x0040_0000`) was set.
    public let ccap10: UInt16?
    /// `Ccap^15` capability word when `Pcap^15` (`0x0002_0000`) was set.
    public let ccap15: UInt16?
    /// Whether normative Part 10 `CAP` (`Pcap^10 = 0x0040_0000`) was present.
    public let hasPart10CAPMarker: Bool
    /// Whether Part 15 HTJ2K `CAP` (`Pcap^15 = 0x0002_0000`) was present.
    public let hasHTJ2KCAPMarker: Bool
    /// Whether normative Part 10 `NSI` (`0xFF54`) was present.
    public let hasNSIMarker: Bool
    /// Optional physical voxel spacing and origin parsed from a `"SJ2K3D_GEOM_V1"` `COM` marker segment.
    public let geometry: JP3DVolumeGeometry?
    /// Main-header `COM` (`0xFF64`) marker segments in codestream order.
    public let comments: [JP3DCommentSegment]
    /// Parsed 3D quantisation parameters from `QCD`.
    package let qcd: JP3DQuantizationParameters
    /// Per-component Maxshift ROI shifts from `RGN` (`0xFF5E`).
    package let roiShifts: [Int]
    /// Main-header `COC` (`0xFF53`) component overrides.
    package let mainCOC: [Int: JP3DCODInfo]
    /// Main-header `QCC` (`0xFF5D`) component overrides.
    package let mainQCC: [Int: JP3DQuantizationParameters]
    /// Main-header `RGN` (`0xFF5E`) all-components (`Crgn == 65535`) shift.
    package let mainRGNAllComponents: Int?
    /// Main-header `RGN` (`0xFF5E`) per-component shifts.
    package let mainRGNByComponent: [Int: Int]
    /// First-tile-part (`TPsot == 0`) functional marker overrides keyed by tile index.
    package let tileOverrides: [Int: JP3DTileHeaderOverrides]
    /// Optional Part 2 `CBD`/`MCT`/`MCC`/`MCO` reversible bit-split synthesis descriptor.
    package let part2BitSplit: JP3DPart2BitSplitDescriptor?
    /// Total bytes retained across parsed tile subdata buffers.
    internal let retainedTileBytes: Int

    /// Total payload bytes across all parsed `COM` marker segments.
    public var commentPayloadBytes: Int {
        comments.reduce(0) { $0 + $1.payload.count }
    }

    public init(
        siz: JP3DSIZInfo,
        cod: JP3DCODInfo,
        isLosslessQuantization: Bool,
        tiles: [JP3DParsedTile],
        hasCAPMarker: Bool = false,
        geometry: JP3DVolumeGeometry? = nil,
        comments: [JP3DCommentSegment] = []
    ) {
        self.siz = siz
        self.cod = cod
        self.isLosslessQuantization = isLosslessQuantization
        self.tiles = tiles
        self.hasCAPMarker = hasCAPMarker
        self.pcap = hasCAPMarker ? 0x0040_0000 : nil
        self.ccap10 = hasCAPMarker ? 0 : nil
        self.ccap15 = nil
        self.hasPart10CAPMarker = hasCAPMarker
        self.hasHTJ2KCAPMarker = false
        self.hasNSIMarker = false
        self.geometry = geometry
        self.comments = comments
        self.qcd = isLosslessQuantization
            ? .makeReversible(maxBitDepth: siz.bitDepth, levelsX: cod.levelsX, levelsY: cod.levelsY, levelsZ: cod.levelsZ)
            : .makeIrreversible(maxBitDepth: siz.bitDepth, levelsX: cod.levelsX, levelsY: cod.levelsY, levelsZ: cod.levelsZ)
        self.roiShifts = [Int](repeating: 0, count: max(1, siz.componentCount))
        self.mainCOC = [:]
        self.mainQCC = [:]
        self.mainRGNAllComponents = nil
        self.mainRGNByComponent = [:]
        self.tileOverrides = [:]
        self.part2BitSplit = nil
        self.retainedTileBytes = tiles.reduce(0) { $0 + 32 + $1.data.count + MemoryLayout<JP3DParsedTile>.stride }
    }

    internal init(
        siz: JP3DSIZInfo,
        cod: JP3DCODInfo,
        isLosslessQuantization: Bool,
        tiles: [JP3DParsedTile],
        hasCAPMarker: Bool,
        retainedTileBytes: Int,
        geometry: JP3DVolumeGeometry? = nil,
        comments: [JP3DCommentSegment] = [],
        pcap: UInt32? = nil,
        ccap10: UInt16? = nil,
        ccap15: UInt16? = nil,
        hasNSIMarker: Bool = false,
        qcd: JP3DQuantizationParameters? = nil,
        roiShifts: [Int] = [],
        mainCOC: [Int: JP3DCODInfo] = [:],
        mainQCC: [Int: JP3DQuantizationParameters] = [:],
        mainRGNAllComponents: Int? = nil,
        mainRGNByComponent: [Int: Int] = [:],
        tileOverrides: [Int: JP3DTileHeaderOverrides] = [:],
        part2BitSplit: JP3DPart2BitSplitDescriptor? = nil
    ) {
        self.siz = siz
        self.cod = cod
        self.isLosslessQuantization = isLosslessQuantization
        self.tiles = tiles
        self.hasCAPMarker = hasCAPMarker
        self.pcap = pcap
        self.ccap10 = ccap10
        self.ccap15 = ccap15
        self.hasPart10CAPMarker = ((pcap ?? 0) & 0x0040_0000) != 0
        self.hasHTJ2KCAPMarker = ((pcap ?? 0) & 0x0002_0000) != 0
        self.hasNSIMarker = hasNSIMarker
        self.retainedTileBytes = retainedTileBytes
        self.geometry = geometry
        self.comments = comments
        self.qcd = qcd ?? (isLosslessQuantization
            ? .makeReversible(maxBitDepth: siz.bitDepth, levelsX: cod.levelsX, levelsY: cod.levelsY, levelsZ: cod.levelsZ)
            : .makeIrreversible(maxBitDepth: siz.bitDepth, levelsX: cod.levelsX, levelsY: cod.levelsY, levelsZ: cod.levelsZ))
        self.roiShifts = roiShifts.isEmpty ? [Int](repeating: 0, count: max(1, siz.componentCount)) : roiShifts
        self.mainCOC = mainCOC
        self.mainQCC = mainQCC
        self.mainRGNAllComponents = mainRGNAllComponents
        self.mainRGNByComponent = mainRGNByComponent
        self.tileOverrides = tileOverrides
        self.part2BitSplit = part2BitSplit
    }

    /// Effective tile-wide `COD` (`Tile COD ?? Main COD`) supplying `SGcod` parameters (`progressionOrderByte`,
    /// `numLayers`, `multipleComponentTransform`, `SOP`, `EPH`) for `tileIndex`.
    package func effectiveTileCOD(tileIndex: Int) -> JP3DCODInfo {
        tileOverrides[tileIndex]?.cod ?? cod
    }

    /// Effective `COD`/`COC` parameters for `(tileIndex, component)` following `ITU-T T.809` Clauses A.2.2–A.2.3:
    /// `Tile-part COC > Tile-part COD > Main COC > Main COD`.
    package func effectiveCOD(tileIndex: Int, component: Int) -> JP3DCODInfo {
        let tileOv = tileOverrides[tileIndex]
        var base = tileOv?.cod ?? cod
        if tileOv?.cod == nil, let mCOC = mainCOC[component] {
            base = base.applying(coc: mCOC)
        }
        if let tCOC = tileOv?.coc[component] {
            base = base.applying(coc: tCOC)
        }
        return base
    }

    /// Effective `QCD`/`QCC` parameters for `(tileIndex, component)` following `ITU-T T.809` Clauses A.2.5–A.2.6:
    /// `Tile-part QCC > Tile-part QCD > Main QCC > Main QCD`.
    package func effectiveQCD(tileIndex: Int, component: Int) -> JP3DQuantizationParameters {
        if let tQCC = tileOverrides[tileIndex]?.qcc[component]?.params {
            return tQCC
        }
        if let tQCD = tileOverrides[tileIndex]?.qcd {
            return tQCD
        }
        if let mQCC = mainQCC[component] {
            return mQCC
        }
        return qcd
    }

    /// Effective Maxshift ROI binary shift for `(tileIndex, component)` following `ITU-T T.809` Clause A.2.4:
    /// `Tile-part RGN (Crgn != 65535) > Tile-part RGN (Crgn == 65535) > Main RGN (Crgn != 65535) > Main RGN (Crgn == 65535)`.
    package func effectiveROIShift(tileIndex: Int, component: Int) -> Int {
        if let tComp = tileOverrides[tileIndex]?.rgnByComponent[component] {
            return tComp
        }
        if let tAll = tileOverrides[tileIndex]?.rgnAllComponents {
            return tAll
        }
        if let mComp = mainRGNByComponent[component] {
            return mComp
        }
        if let mAll = mainRGNAllComponents {
            return mAll
        }
        return component < roiShifts.count ? roiShifts[component] : 0
    }

    /// Whether every effective `(tile, component)` pair in the codestream uses lossless reversible coding.
    package var isFullyReversible: Bool {
        let tileIndices = tiles.isEmpty ? [0] : tiles.map(\.tileIndex)
        for t in tileIndices {
            for c in 0..<siz.componentCount {
                let cCOD = effectiveCOD(tileIndex: t, component: c)
                let cQCD = effectiveQCD(tileIndex: t, component: c)
                if !cCOD.isLossless || !cQCD.isReversible {
                    return false
                }
            }
        }
        return true
    }

    /// Whether `CAP Ccap^15` permits more than one HT set per code-block (`MULTIHT`, bit 13 == `1`).
    package var allowsMultiHTSets: Bool {
        guard let c15 = ccap15 else { return true }
        return (c15 & 0x2000) != 0
    }

    /// Reconstructed logical output component count (accounting for Part 2 `CBD` synthesis when present).
    package var logicalComponentCount: Int {
        part2BitSplit?.logicalComponentCount ?? siz.componentCount
    }

    /// Reconstructed logical bit depth for output component `c`.
    package func logicalBitDepth(forComponent c: Int) -> Int {
        if let split = part2BitSplit, c >= 0, c < split.logicalComponentBitDepths.count {
            return split.logicalComponentBitDepths[c]
        }
        return siz.bitDepth(forComponent: c)
    }

    /// Reconstructed logical signedness for output component `c`.
    package func logicalIsSigned(forComponent c: Int) -> Bool {
        if let split = part2BitSplit, c >= 0, c < split.logicalComponentSigned.count {
            return split.logicalComponentSigned[c]
        }
        return siz.isSigned(forComponent: c)
    }

    /// Compute the tile grid for this codestream.
    public var tileGrid: (tilesX: Int, tilesY: Int, tilesZ: Int) {
        let tx = max(1, (siz.originX + siz.width - siz.tileOriginX + siz.tileSizeX - 1) / siz.tileSizeX)
        let ty = max(1, (siz.originY + siz.height - siz.tileOriginY + siz.tileSizeY - 1) / siz.tileSizeY)
        let tz = max(1, (siz.originZ + siz.depth - siz.tileOriginZ + siz.tileSizeZ - 1) / siz.tileSizeZ)
        return (tx, ty, tz)
    }
}

/// Parses an ITU-T T.809 | ISO/IEC 15444-10 (JP3D) codestream (with optional reconciled T.814 HTJ2K signalling).
public struct JP3DCodestreamParser: Sendable {
    /// Creates a new codestream parser.
    public init() {}

    // MARK: - Public API

    /// Parses a JP3D codestream from raw data.
    public func parse(_ data: Data) throws -> JP3DParsedCodestream {
        try parse(data, limits: nil, work: nil, copyTilePayloads: true)
    }

    /// Parses a JP3D codestream under bounded `ResourceLimits` and deadline checks before copying tile payloads.
    internal func parse(
        _ data: Data,
        limits: ResourceLimits?,
        work: VolumeWorkGuard? = nil,
        copyTilePayloads: Bool = true
    ) throws -> JP3DParsedCodestream {
        try work?.check()
        if let limits {
            guard data.count <= limits.maximumCompressedBytes,
                  data.count <= limits.maximumMemoryBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Codestream size \(data.count) exceeds compressed or memory limit"
                )
            }
        }

        var offset = 0

        let socMarker = try readUInt16BE(data, at: &offset)
        guard socMarker == 0xFF4F else {
            throw J2KError.decodingError(
                "Missing SOC marker at start of codestream (got 0x\(String(socMarker, radix: 16)))"
            )
        }

        // ITU-T T.809 Annex A.2: SIZ must immediately follow SOC.
        let firstMarker = try readUInt16BE(data, at: &offset)
        guard firstMarker == 0xFF51 else {
            throw J2KError.decodingError(
                "Expected SIZ (0xFF51) immediately after SOC, got 0x\(String(firstMarker, radix: 16))"
            )
        }
        let initialSIZ = try parseSIZ(data, at: &offset)
        var sizInfo: JP3DSIZInfo = initialSIZ.siz
        let sizHadLegacyTail = initialSIZ.hadLegacyTail
        try validateDimensionsAgainstLimits(sizInfo, limits: limits)

        var codInfo: JP3DCODInfo?
        var codWasLegacyShort = false
        var qcdParams: JP3DQuantizationParameters?
        var qcdExplicitSubbandCount: Int?
        var mainCOC: [Int: JP3DCODInfo] = [:]
        var mainQCC: [Int: (params: JP3DQuantizationParameters, explicitSubbandCount: Int?)] = [:]
        var mainRGNAllComponents: Int?
        var mainRGNByComponent: [Int: Int] = [:]
        var tileOverrides: [Int: JP3DTileHeaderOverrides] = [:]
        var sawAnyRGN = false
        var sawAnyTileFunctionalOrPPT = false
        var hasCAP = false
        var parsedPcap: UInt32?
        var parsedCcap10: UInt16?
        var parsedCcap15: UInt16?
        var hasNSI = false
        var roiShifts = [Int](repeating: 0, count: sizInfo.componentCount)
        var parsedCBD: (depths: [Int], signed: [Bool], raw: Data)?
        var parsedMCTValid = false
        var parsedMCTRaw = Data()
        var parsedMCCValidCount: Int?
        var parsedMCCRaw = Data()
        var parsedMCOValid = false
        var parsedMCORaw = Data()
        var parsedGeometry: JP3DVolumeGeometry?
        var parsedComments: [JP3DCommentSegment] = []
        var totalCommentMetadataBytes = 0
        var tilePartsByTile: [Int: [(tpIndex: Int, seq: Int, data: Data)]] = [:]
        var tilePartSeq = 0
        var retainedTileBytes = 0
        var foundEOC = false
        var enteredTileParts = false
        var mainHeaderMarkersAfterSIZ = 0

        while offset < data.count {
            try work?.check()
            guard offset + 2 <= data.count else {
                throw J2KError.decodingError("Trailing truncated marker byte at end of codestream")
            }
            let markerStart = offset
            let marker = try readUInt16BE(data, at: &offset)

            if enteredTileParts && marker != 0xFF90 && marker != 0xFFD9 {
                throw J2KError.decodingError(
                    "Unexpected main-header marker 0x\(String(marker, radix: 16)) after first SOT"
                )
            }

            switch marker {
            case 0xFF51: // Duplicate SIZ
                throw J2KError.decodingError("Duplicate SIZ (0xFF51) marker in main header")

            case 0xFF50: // CAP (ITU-T T.801 / T.809 / T.814)
                guard !hasCAP else {
                    throw J2KError.decodingError("Duplicate CAP (0xFF50) marker in main header")
                }
                guard mainHeaderMarkersAfterSIZ == 0 else {
                    throw J2KError.decodingError("CAP (0xFF50) marker must immediately follow SIZ (0xFF51)")
                }
                let cap = try parseCAP(data, at: &offset)
                hasCAP = true
                parsedPcap = cap.pcap
                parsedCcap10 = cap.ccap10
                parsedCcap15 = cap.ccap15

            case 0xFF54: // NSI (ITU-T T.809 Annex A.3.1, Table A.5)
                guard !hasNSI else {
                    throw J2KError.decodingError("Duplicate NSI (0xFF54) marker in main header")
                }
                guard !sizHadLegacyTail else {
                    throw J2KError.decodingError("Malformed SIZ segment length combined with NSI (0xFF54)")
                }
                sizInfo = try parseNSI(data, at: &offset, baseSIZ: sizInfo)
                hasNSI = true
                try validateDimensionsAgainstLimits(sizInfo, limits: limits)

            case 0xFF52: // COD
                guard codInfo == nil else {
                    throw J2KError.decodingError("Duplicate COD (0xFF52) marker in main header")
                }
                let parsedCOD = try parseCOD(data, at: &offset, requireNormative3D: hasNSI)
                codInfo = parsedCOD.cod
                codWasLegacyShort = parsedCOD.wasLegacyShort

            case 0xFF53: // COC (ITU-T T.809 Clause A.2.3)
                let parsedCOC = try parseCOC(data, at: &offset, componentCount: sizInfo.componentCount, requireNormative3D: hasNSI)
                guard mainCOC[parsedCOC.component] == nil else {
                    throw J2KError.decodingError("Duplicate main-header COC (0xFF53) for component \(parsedCOC.component)")
                }
                mainCOC[parsedCOC.component] = parsedCOC.coc

            case 0xFF5C: // QCD
                guard qcdParams == nil else {
                    throw J2KError.decodingError("Duplicate QCD (0xFF5C) marker in main header")
                }
                let parsedQCD = try parseQCD(data, at: &offset)
                qcdParams = parsedQCD.params
                qcdExplicitSubbandCount = parsedQCD.explicitSubbandCount

            case 0xFF5D: // QCC (ITU-T T.809 Clause A.2.6)
                let parsedQCC = try parseQCC(data, at: &offset, componentCount: sizInfo.componentCount)
                guard mainQCC[parsedQCC.component] == nil else {
                    throw J2KError.decodingError("Duplicate main-header QCC (0xFF5D) for component \(parsedQCC.component)")
                }
                mainQCC[parsedQCC.component] = (parsedQCC.params, parsedQCC.explicitSubbandCount)

            case 0xFF5E: // RGN (Maxshift ROI, ITU-T T.809 Clause A.2.4)
                let rgn = try parseRGN(data, at: &offset, componentCount: sizInfo.componentCount)
                sawAnyRGN = true
                if let comp = rgn.component {
                    mainRGNByComponent[comp] = rgn.shift
                    roiShifts[comp] = rgn.shift
                } else {
                    mainRGNAllComponents = rgn.shift
                    for c in 0..<sizInfo.componentCount where mainRGNByComponent[c] == nil {
                        roiShifts[c] = rgn.shift
                    }
                }

            case 0xFF78: // CBD (ITU-T T.809 Table A.1 / ITU-T T.801 A.3.7)
                guard parsedCBD == nil else {
                    throw J2KError.decodingError("Duplicate CBD (0xFF78) marker in main header")
                }
                parsedCBD = try parseCBD(data, markerStart: markerStart, at: &offset, codestreamComponents: sizInfo.componentCount)

            case 0xFF74: // MCT (ITU-T T.809 Table A.1 / ITU-T T.801 A.3.8)
                guard !parsedMCTValid else {
                    throw J2KError.decodingError("Duplicate MCT (0xFF74) marker in main header")
                }
                parsedMCTRaw = try parsePart2BitSplitMCT(data, markerStart: markerStart, at: &offset)
                parsedMCTValid = true

            case 0xFF75: // MCC (ITU-T T.809 Table A.1 / ITU-T T.801 A.3.9)
                guard parsedMCCValidCount == nil else {
                    throw J2KError.decodingError("Duplicate MCC (0xFF75) marker in main header")
                }
                let mcc = try parsePart2BitSplitMCC(data, markerStart: markerStart, at: &offset, codestreamComponents: sizInfo.componentCount)
                parsedMCCValidCount = mcc.logicalCount
                parsedMCCRaw = mcc.raw

            case 0xFF77: // MCO (ITU-T T.809 Table A.1 / ITU-T T.801 A.3.10)
                guard !parsedMCOValid else {
                    throw J2KError.decodingError("Duplicate MCO (0xFF77) marker in main header")
                }
                parsedMCORaw = try parsePart2BitSplitMCO(data, markerStart: markerStart, at: &offset)
                parsedMCOValid = true

            case 0xFF59: // CPF
                let len = Int(try readUInt16BE(data, at: &offset))
                guard len >= 4, (len % 2) == 0, offset + (len - 2) <= data.count else {
                    throw J2KError.decodingError("CPF marker has invalid length \(len)")
                }
                offset += len - 2

            case 0xFF64: // COM – parse comment and optional SJ2K3D_GEOM_V1 volume geometry
                let len = Int(try readUInt16BE(data, at: &offset))
                guard len >= 4, offset + (len - 2) <= data.count else {
                    throw J2KError.decodingError("COM marker has invalid length \(len)")
                }
                let rcom = try readUInt16BE(data, at: &offset)
                let payloadLen = len - 4
                let (nextMetaBytes, metaOv) = totalCommentMetadataBytes.addingReportingOverflow(payloadLen)
                guard !metaOv else {
                    throw J2KError.decodingError("COM metadata byte count overflows integer arithmetic")
                }
                if let limits {
                    guard nextMetaBytes <= limits.maximumMetadataBytes,
                          nextMetaBytes <= limits.maximumMemoryBytes else {
                        throw CodecError(
                            .resourceLimitExceeded,
                            "Volumetric COM metadata (\(nextMetaBytes) bytes) exceeds maximumMetadataBytes (\(limits.maximumMetadataBytes))"
                        )
                    }
                }
                totalCommentMetadataBytes = nextMetaBytes
                let payloadStart = data.startIndex + offset
                let payload = Data(data[payloadStart..<(payloadStart + payloadLen)])
                offset += payloadLen
                if rcom == 0, let decodedGeom = try JP3DVolumeGeometry.decodePayload(payload) {
                    parsedGeometry = decodedGeom
                }
                parsedComments.append(JP3DCommentSegment(registration: rcom, payload: payload))

            case 0xFF90: // SOT
                enteredTileParts = true
                let part = try parseSOTAndData(
                    data,
                    sotMarkerStart: markerStart,
                    at: &offset,
                    componentCount: sizInfo.componentCount,
                    is3D: hasNSI,
                    limits: limits,
                    retainedTileBytes: &retainedTileBytes,
                    tileOverrides: &tileOverrides,
                    sawAnyRGN: &sawAnyRGN,
                    sawAnyTileFunctionalOrPPT: &sawAnyTileFunctionalOrPPT,
                    copyTilePayloads: copyTilePayloads
                )
                tilePartsByTile[part.tileIndex, default: []].append(
                    (tpIndex: part.tilePartIndex, seq: tilePartSeq, data: part.data)
                )
                tilePartSeq += 1

            case 0xFFD9: // EOC
                foundEOC = true

            case 0xFF55, 0xFF57, 0xFF58, 0xFF60, 0xFF61, 0xFF63: // TLM, PLM, PLT, PPM, PPT, CRG
                if marker == 0xFF61 {
                    sawAnyTileFunctionalOrPPT = true
                }
                let len = Int(try readUInt16BE(data, at: &offset))
                guard len >= 2, offset + (len - 2) <= data.count else {
                    throw J2KError.decodingError("Marker 0x\(String(marker, radix: 16)) has invalid length \(len)")
                }
                offset += len - 2

            default:
                throw J2KError.decodingError("Unexpected or malformed marker 0x\(String(marker, radix: 16)) at offset \(markerStart)")
            }

            if !enteredTileParts && marker != 0xFFD9 {
                mainHeaderMarkersAfterSIZ += 1
            }

            if foundEOC { break }
        }

        guard let cod = codInfo else {
            throw J2KError.decodingError("Codestream missing COD marker")
        }
        guard let qcd = qcdParams else {
            throw J2KError.decodingError("Codestream missing QCD marker")
        }
        if tilePartsByTile.isEmpty {
            throw J2KError.decodingError("Codestream contains no tile data")
        }

        // Validate optional Part 2 CBD/MCT/MCC/MCO reversible bit-split synthesis group.
        var part2Descriptor: JP3DPart2BitSplitDescriptor?
        let anyPart2MCTMarkers = (parsedCBD != nil) || parsedMCTValid || (parsedMCCValidCount != nil) || parsedMCOValid
        if anyPart2MCTMarkers {
            guard let cbd = parsedCBD,
                  parsedMCTValid,
                  let mccLogical = parsedMCCValidCount,
                  parsedMCOValid,
                  cbd.depths.count == mccLogical else {
                throw J2KError.decodingError("Incomplete or mismatched Part 2 CBD/MCT/MCC/MCO marker set in main header")
            }
            if let pcap = parsedPcap {
                guard (pcap & 0x4000_0000) != 0 || (sizInfo.rsiz & 0x8010) != 0 else {
                    throw J2KError.decodingError("Part 2 CBD/MCT/MCC/MCO markers present without Pcap^2 or Part 2 Rsiz signalling")
                }
            }
            var rawAll = Data()
            rawAll.append(cbd.raw)
            rawAll.append(parsedMCTRaw)
            rawAll.append(parsedMCCRaw)
            rawAll.append(parsedMCORaw)
            part2Descriptor = JP3DPart2BitSplitDescriptor(
                logicalComponentBitDepths: cbd.depths,
                logicalComponentSigned: cbd.signed,
                rawMarkerSegments: rawAll
            )
        }

        let mainQCCParams: [Int: JP3DQuantizationParameters] = mainQCC.mapValues(\.params)

        // Assemble multi-tile-part data per tile index in `TPsot` (then arrival) order.
        var parsedTiles: [JP3DParsedTile] = []
        parsedTiles.reserveCapacity(tilePartsByTile.count)
        for tileIndex in tilePartsByTile.keys.sorted() {
            guard var parts = tilePartsByTile[tileIndex] else { continue }
            if parts.count == 1 {
                parsedTiles.append(JP3DParsedTile(tileIndex: tileIndex, data: parts[0].data))
            } else {
                parts.sort { a, b in
                    if a.tpIndex != b.tpIndex { return a.tpIndex < b.tpIndex }
                    return a.seq < b.seq
                }
                let totalLen = parts.reduce(0) { $0 + $1.data.count }
                var combined = Data(capacity: totalLen)
                for p in parts {
                    combined.append(p.data)
                }
                parsedTiles.append(JP3DParsedTile(tileIndex: tileIndex, data: combined))
            }
        }

        let assembled = JP3DParsedCodestream(
            siz: sizInfo,
            cod: cod,
            isLosslessQuantization: qcd.isReversible,
            tiles: parsedTiles,
            hasCAPMarker: hasCAP,
            retainedTileBytes: retainedTileBytes,
            geometry: parsedGeometry,
            comments: parsedComments,
            pcap: parsedPcap,
            ccap10: parsedCcap10,
            ccap15: parsedCcap15,
            hasNSIMarker: hasNSI,
            qcd: qcd,
            roiShifts: roiShifts,
            mainCOC: mainCOC,
            mainQCC: mainQCCParams,
            mainRGNAllComponents: mainRGNAllComponents,
            mainRGNByComponent: mainRGNByComponent,
            tileOverrides: tileOverrides,
            part2BitSplit: part2Descriptor
        )

        // Cross-marker normative consistency checks across all effective `(tile, component)` pairs (ITU-T T.809 & T.814):
        if hasNSI {
            guard !codWasLegacyShort else {
                throw J2KError.decodingError("Normative Part 10 codestream with NSI cannot use 2D short COD length")
            }
            if (sizInfo.rsiz & 0x4000) != 0 {
                guard let pcap = parsedPcap, (pcap & 0x0040_0000) != 0 else {
                    throw J2KError.decodingError("SIZ Rsiz signals CAP (0x4000), but CAP with Pcap^10 (0x0040_0000) is missing")
                }
            }
            let hasAnyCODOverride = !mainCOC.isEmpty || tileOverrides.values.contains(where: { $0.cod != nil || !$0.coc.isEmpty })
            if !hasAnyCODOverride, let explicitBands = qcdExplicitSubbandCount {
                let expectedBands = JP3DQuantizationParameters.totalSubbandCount(
                    levelsX: cod.levelsX,
                    levelsY: cod.levelsY,
                    levelsZ: cod.levelsZ
                )
                guard explicitBands == expectedBands else {
                    throw J2KError.decodingError(
                        "QCD sub-band entry count (\(explicitBands)) does not match 3D DWT sub-band count (\(expectedBands)) for NL=(\(cod.levelsX),\(cod.levelsY),\(cod.levelsZ))"
                    )
                }
            }
        }
        if let pcap = parsedPcap, (pcap & 0x0040_0000) != 0 {
            guard hasNSI else {
                throw J2KError.decodingError("CAP signals Part 10 (Pcap^10 = 0x0040_0000), but mandatory NSI (0xFF54) is missing")
            }
        }

        if let ccap15 = parsedCcap15 {
            // ITU-T T.814 Table A.2 & Clauses A.3.2–A.3.6:
            if (ccap15 & 0x1000) == 0 && sawAnyRGN {
                throw J2KError.decodingError("CAP Ccap^15 signals RGNFREE (bit 12 == 0), but RGN marker is present")
            }
            if (ccap15 & 0x0800) == 0 && sawAnyTileFunctionalOrPPT {
                throw J2KError.decodingError("CAP Ccap^15 signals HOMOGENEOUS (bit 11 == 0), but tile-part functional override or PPT is present")
            }
        }

        for tile in parsedTiles {
            let tIdx = tile.tileIndex
            let tileSGcod = assembled.effectiveTileCOD(tileIndex: tIdx)
            for c in 0..<sizInfo.componentCount {
                let effCOD = assembled.effectiveCOD(tileIndex: tIdx, component: c)
                let effQCD = assembled.effectiveQCD(tileIndex: tIdx, component: c)
                let top2 = effCOD.codeBlockStyle & 0xC0
                if top2 == 0x80 {
                    throw J2KError.decodingError("Invalid code-block style 0x\(String(effCOD.codeBlockStyle, radix: 16)): bit 7 set without HT bit 6")
                }
                if hasNSI {
                    let cbExpSum = effCOD.codeBlockWidthExponent + effCOD.codeBlockHeightExponent + effCOD.codeBlockDepthExponent
                    guard effCOD.codeBlockWidthExponent >= 0,
                          effCOD.codeBlockHeightExponent >= 0,
                          effCOD.codeBlockDepthExponent >= 0,
                          cbExpSum <= 18 else {
                        throw J2KError.decodingError(
                            "3D COD/COC code-block exponents (\(effCOD.codeBlockWidthExponent),\(effCOD.codeBlockHeightExponent),\(effCOD.codeBlockDepthExponent)) violate ITU-T T.809 xcb+ycb+zcb <= 18"
                        )
                    }
                    if (effCOD.codeBlockStyle & 0x40) != 0 && effCOD.codeBlockDepthExponent != 0 {
                        throw J2KError.decodingError(
                            "HTJ2K-in-JP3D requires planar 3D code-blocks (zcb == 0), got zcb=\(effCOD.codeBlockDepthExponent)"
                        )
                    }
                    if effQCD.style != 1 {
                        let expectedBands = JP3DQuantizationParameters.totalSubbandCount(
                            levelsX: effCOD.levelsX,
                            levelsY: effCOD.levelsY,
                            levelsZ: effCOD.levelsZ
                        )
                        guard effQCD.steps.count >= expectedBands else {
                            throw J2KError.decodingError(
                                "Effective QCD/QCC sub-band entry count (\(effQCD.steps.count)) is smaller than 3D DWT sub-band count (\(expectedBands)) on tile \(tIdx) component \(c)"
                            )
                        }
                    }
                }
                if let ccap15 = parsedCcap15 {
                    let htMode = (ccap15 >> 14) & 0x03
                    if htMode == 0 && (effCOD.codeBlockStyle & 0x40) == 0 {
                        throw J2KError.decodingError("CAP Ccap^15 signals HTONLY, but effective COD/COC on tile \(tIdx) component \(c) omits HT bit 0x40")
                    }
                    if htMode == 2 && (effCOD.codeBlockStyle & 0x80) != 0 {
                        throw J2KError.decodingError("CAP Ccap^15 signals HTDECLARED, but effective COD/COC on tile \(tIdx) component \(c) sets bit 7 (0xC0 mixed)")
                    }
                    if (ccap15 & 0x0020) == 0 && (effCOD.codeBlockStyle & 0x40) != 0 && !effCOD.isLossless {
                        throw J2KError.decodingError("CAP Ccap^15 signals HTREV (bit 5 == 0), but HT tile \(tIdx) component \(c) uses irreversible wavelet")
                    }
                } else if hasNSI && top2 != 0 {
                    throw J2KError.decodingError("COD/COC sets HTJ2K bits (0x\(String(effCOD.codeBlockStyle, radix: 16))) without Part 15 CAP (Pcap^15)")
                }
            }
            if tileSGcod.multipleComponentTransform == 1 && sizInfo.componentCount >= 3 {
                let c0 = assembled.effectiveCOD(tileIndex: tIdx, component: 0)
                let c1 = assembled.effectiveCOD(tileIndex: tIdx, component: 1)
                let c2 = assembled.effectiveCOD(tileIndex: tIdx, component: 2)
                guard c0.isLossless == c1.isLossless, c1.isLossless == c2.isLossless,
                      c0.levelsX == c1.levelsX, c1.levelsX == c2.levelsX,
                      c0.levelsY == c1.levelsY, c1.levelsY == c2.levelsY,
                      c0.levelsZ == c1.levelsZ, c1.levelsZ == c2.levelsZ else {
                    throw J2KError.decodingError("MCT enabled on tile \(tIdx), but components 0..2 have incompatible wavelet filter or decomposition levels")
                }
            }
        }

        return assembled
    }

    // MARK: - Private Marker Parsers

    private func validateDimensionsAgainstLimits(_ siz: JP3DSIZInfo, limits: ResourceLimits?) throws {
        let (wh, o1) = siz.width.multipliedReportingOverflow(by: siz.height)
        let (voxels, o2) = wh.multipliedReportingOverflow(by: siz.depth)
        guard !o1, !o2 else {
            throw J2KError.decodingError("Volumetric dimensions overflow integer arithmetic")
        }
        guard let limits else { return }
        let maxDim = limits.maximumDimension
        guard siz.width <= maxDim,
              siz.height <= maxDim,
              siz.depth <= maxDim else {
            throw CodecError(
                .resourceLimitExceeded,
                "Codestream dimensions (\(siz.width)x\(siz.height)x\(siz.depth)) exceed limit \(maxDim)"
            )
        }
        guard siz.depth <= limits.maximumFrames else {
            throw CodecError(
                .resourceLimitExceeded,
                "Codestream depth \(siz.depth) exceeds frame limit \(limits.maximumFrames)"
            )
        }
        guard voxels <= limits.maximumPixels else {
            throw CodecError(
                .resourceLimitExceeded,
                "Volumetric voxel count \(voxels) exceeds limit \(limits.maximumPixels)"
            )
        }
    }

    private func parseSIZ(_ data: Data, at offset: inout Int) throws -> (siz: JP3DSIZInfo, hadLegacyTail: Bool) {
        let len = Int(try readUInt16BE(data, at: &offset))
        guard len >= 41 else {
            throw J2KError.decodingError("SIZ segment length \(len) too small (min 41)")
        }
        let segEnd = offset + len - 2
        guard segEnd <= data.count else {
            throw J2KError.decodingError("SIZ segment length \(len) exceeds codestream size")
        }

        let rsiz = try readUInt16BE(data, at: &offset)
        let xsiz = Int(try readUInt32BE(data, at: &offset))
        let ysiz = Int(try readUInt32BE(data, at: &offset))
        let xosiz = Int(try readUInt32BE(data, at: &offset))
        let yosiz = Int(try readUInt32BE(data, at: &offset))
        let xtsiz = Int(try readUInt32BE(data, at: &offset))
        let ytsiz = Int(try readUInt32BE(data, at: &offset))
        let xtosiz = Int(try readUInt32BE(data, at: &offset))
        let ytosiz = Int(try readUInt32BE(data, at: &offset))
        let numComponents = Int(try readUInt16BE(data, at: &offset))

        guard numComponents > 0, numComponents <= 16384 else {
            throw J2KError.decodingError("SIZ: invalid component count \(numComponents)")
        }
        let normativeLen = 38 + 3 * numComponents
        let legacyLen = normativeLen + 8
        guard len == normativeLen || len == legacyLen else {
            throw J2KError.decodingError(
                "SIZ: invalid segment length \(len) for \(numComponents) component(s) (expected \(normativeLen))"
            )
        }

        guard xsiz > xosiz, ysiz > yosiz, xosiz >= 0, yosiz >= 0 else {
            throw J2KError.decodingError("SIZ: invalid reference grid (\(xsiz)x\(ysiz), origin \(xosiz),\(yosiz))")
        }
        let width = xsiz - xosiz
        let height = ysiz - yosiz
        guard xtsiz > 0, ytsiz > 0, xtosiz >= 0, ytosiz >= 0,
              xtosiz <= xosiz, ytosiz <= yosiz,
              xtosiz + xtsiz > xosiz, ytosiz + ytsiz > yosiz else {
            throw J2KError.decodingError("SIZ: invalid tile grid (\(xtsiz)x\(ytsiz), origin \(xtosiz),\(ytosiz))")
        }

        var compBitDepths: [Int] = []
        var compSigned: [Bool] = []
        var subX: [Int] = []
        var subY: [Int] = []
        compBitDepths.reserveCapacity(numComponents)
        compSigned.reserveCapacity(numComponents)
        subX.reserveCapacity(numComponents)
        subY.reserveCapacity(numComponents)

        for c in 0..<numComponents {
            guard offset + 3 <= segEnd else {
                throw J2KError.decodingError("SIZ: truncated component \(c) descriptor")
            }
            let ssiz = data[data.startIndex + offset]
            let xrsiz = Int(data[data.startIndex + offset + 1])
            let yrsiz = Int(data[data.startIndex + offset + 2])
            offset += 3
            let bd = Int(ssiz & 0x7F) + 1
            guard bd >= 1, bd <= 38 else {
                throw J2KError.decodingError("SIZ: invalid bit depth \(bd) on component \(c)")
            }
            guard xrsiz >= 1, yrsiz >= 1 else {
                throw J2KError.decodingError("SIZ: zero sample separation (\(xrsiz),\(yrsiz)) on component \(c)")
            }
            compBitDepths.append(bd)
            compSigned.append((ssiz & 0x80) != 0)
            subX.append(xrsiz)
            subY.append(yrsiz)
        }

        var depth = 1
        var tileSizeZ = 1
        let hadLegacyTail = (len == legacyLen)
        if hadLegacyTail {
            let rawDepth = Int(try readUInt32BE(data, at: &offset))
            let rawTileZ = Int(try readUInt32BE(data, at: &offset))
            guard rawDepth > 0 else {
                throw J2KError.decodingError("SIZ: non-positive legacy depth \(rawDepth)")
            }
            depth = rawDepth
            tileSizeZ = rawTileZ > 0 ? rawTileZ : rawDepth
        }
        offset = segEnd

        let siz = JP3DSIZInfo(
            width: width,
            height: height,
            depth: depth,
            tileSizeX: xtsiz,
            tileSizeY: ytsiz,
            tileSizeZ: tileSizeZ,
            componentCount: numComponents,
            bitDepth: compBitDepths[0],
            signed: compSigned[0],
            rsiz: rsiz,
            originX: xosiz,
            originY: yosiz,
            originZ: 0,
            tileOriginX: xtosiz,
            tileOriginY: ytosiz,
            tileOriginZ: 0,
            componentBitDepths: compBitDepths,
            componentSigned: compSigned,
            componentSubsamplingX: subX,
            componentSubsamplingY: subY,
            componentSubsamplingZ: [Int](repeating: 1, count: numComponents)
        )
        return (siz, hadLegacyTail)
    }

    private func parseCAP(_ data: Data, at offset: inout Int) throws -> (pcap: UInt32, ccap10: UInt16?, ccap15: UInt16?) {
        let len = Int(try readUInt16BE(data, at: &offset))
        guard len >= 6, offset + (len - 2) <= data.count else {
            throw J2KError.decodingError("CAP marker has invalid or truncated length \(len)")
        }
        let segEnd = offset + len - 2
        let pcap = try readUInt32BE(data, at: &offset)
        let expectedLen = 6 + 2 * pcap.nonzeroBitCount
        guard len == expectedLen else {
            throw J2KError.decodingError(
                "CAP marker length \(len) does not match Pcap=0x\(String(pcap, radix: 16)) popcount (expected \(expectedLen))"
            )
        }
        var ccap10: UInt16?
        var ccap15: UInt16?
        for k in 1...32 {
            let mask = UInt32(1) << UInt32(32 - k)
            if (pcap & mask) != 0 {
                let word = try readUInt16BE(data, at: &offset)
                if k == 10 {
                    ccap10 = word
                } else if k == 15 {
                    // ITU-T T.814 Table A.2:
                    //   bits 15..14: 00 = HTONLY, 01 = reserved (0x4000), 10 = HTDECLARED (0x8000), 11 = MIXED (0xC000)
                    //   bit  13:     MULTIHT (0 = SINGLEHT, 1 = MULTIHT)
                    //   bit  12:     RGN     (0 = RGNFREE,  1 = RGN permitted)
                    //   bit  11:     HETEROGENEOUS (0 = HOMOGENEOUS, 1 = HETEROGENEOUS)
                    //   bits 10..6:  reserved, must be 00000 (mask 0x07C0)
                    //   bit  5:      HTIRV   (0 = HTREV,    1 = HTIRV)
                    //   bits 4..0:   MAGB_P parameter P
                    let rawMode = (word >> 14) & 0x03
                    guard rawMode != 1 else {
                        throw J2KError.decodingError("CAP Ccap^15 bits 14-15 carry reserved value 1 (0x4000)")
                    }
                    guard (word & 0x07C0) == 0 else {
                        throw J2KError.decodingError("CAP Ccap^15 reserved bits 6-10 must be zero")
                    }
                    ccap15 = word
                }
            }
        }
        offset = segEnd
        return (pcap, ccap10, ccap15)
    }

    private func parseNSI(_ data: Data, at offset: inout Int, baseSIZ: JP3DSIZInfo) throws -> JP3DSIZInfo {
        let len = Int(try readUInt16BE(data, at: &offset))
        let expectedLen = 19 + baseSIZ.componentCount
        guard len == expectedLen, offset + (len - 2) <= data.count else {
            throw J2KError.decodingError(
                "NSI (0xFF54) invalid length \(len) for \(baseSIZ.componentCount) component(s) (expected \(expectedLen))"
            )
        }
        let segEnd = offset + len - 2
        let ndim = Int(data[data.startIndex + offset])
        offset += 1
        guard ndim == 3 else {
            throw J2KError.decodingError("NSI (0xFF54) unsupported dimensionality Ndim=\(ndim) (expected 3)")
        }
        let zsiz = Int(try readUInt32BE(data, at: &offset))
        let zosiz = Int(try readUInt32BE(data, at: &offset))
        let ztsiz = Int(try readUInt32BE(data, at: &offset))
        let ztosiz = Int(try readUInt32BE(data, at: &offset))
        guard zsiz > zosiz, zosiz >= 0, ztsiz > 0, ztosiz >= 0,
              ztosiz <= zosiz, ztosiz + ztsiz > zosiz else {
            throw J2KError.decodingError(
                "NSI (0xFF54) invalid Z grid (Zsiz=\(zsiz), ZOsiz=\(zosiz), ZTsiz=\(ztsiz), ZTOsiz=\(ztosiz))"
            )
        }
        var zrsizList: [Int] = []
        zrsizList.reserveCapacity(baseSIZ.componentCount)
        for c in 0..<baseSIZ.componentCount {
            let zrsiz = Int(data[data.startIndex + offset])
            offset += 1
            guard zrsiz >= 1 else {
                throw J2KError.decodingError("NSI (0xFF54) zero ZRsiz on component \(c)")
            }
            zrsizList.append(zrsiz)
        }
        offset = segEnd
        return baseSIZ.withNSI(
            depth: zsiz - zosiz,
            originZ: zosiz,
            tileSizeZ: ztsiz,
            tileOriginZ: ztosiz,
            subsamplingZ: zrsizList
        )
    }

    private func parseCOD(
        _ data: Data,
        at offset: inout Int,
        requireNormative3D: Bool
    ) throws -> (cod: JP3DCODInfo, wasLegacyShort: Bool) {
        let len = Int(try readUInt16BE(data, at: &offset))
        guard len >= 12 else {
            throw J2KError.decodingError("COD segment length \(len) too small (min 12)")
        }
        let segEnd = offset + len - 2
        guard segEnd <= data.count else {
            throw J2KError.decodingError("COD segment length \(len) exceeds codestream size")
        }

        // Normative ITU-T T.809 3D COD: Lcod == 17 (or 17 + 2 * (maxLevels + 1) with custom 3D precincts).
        if len >= 17 || requireNormative3D {
            guard len >= 17 else {
                throw J2KError.decodingError("Normative 3D COD segment length \(len) too small (expected >= 17)")
            }
            let scod = data[data.startIndex + offset]; offset += 1
            guard (scod & 0xF8) == 0 else {
                throw J2KError.decodingError("COD: Scod carries reserved high bits (0x\(String(scod, radix: 16)))")
            }
            let prog = data[data.startIndex + offset]; offset += 1
            guard prog <= 4 else {
                throw J2KError.decodingError("COD: invalid progression order \(prog) (expected 0...4)")
            }
            let numLayers = Int(try readUInt16BE(data, at: &offset))
            guard numLayers >= 1 else {
                throw J2KError.decodingError("COD: number of layers must be >= 1")
            }
            let mct = data[data.startIndex + offset]; offset += 1
            guard mct <= 1 else {
                throw J2KError.decodingError("COD: unsupported MCT value \(mct)")
            }
            let nlx = Int(data[data.startIndex + offset]); offset += 1
            let nly = Int(data[data.startIndex + offset]); offset += 1
            let nlz = Int(data[data.startIndex + offset]); offset += 1
            guard nlx <= 32, nly <= 32, nlz <= 32 else {
                throw J2KError.decodingError("COD: decomposition levels (\(nlx),\(nly),\(nlz)) exceed maximum 32")
            }
            let xcb = Int(data[data.startIndex + offset]); offset += 1
            let ycb = Int(data[data.startIndex + offset]); offset += 1
            let zcb = Int(data[data.startIndex + offset]); offset += 1
            guard xcb <= 10, ycb <= 10, zcb <= 10, (xcb + ycb + zcb) <= 18 else {
                throw J2KError.decodingError(
                    "COD: invalid 3D code-block exponents (\(xcb),\(ycb),\(zcb)) (max 10 each, sum <= 18)"
                )
            }
            let cbStyle = data[data.startIndex + offset]; offset += 1
            let dwtX = data[data.startIndex + offset]; offset += 1
            let dwtY = data[data.startIndex + offset]; offset += 1
            let dwtZ = data[data.startIndex + offset]; offset += 1
            guard dwtX <= 1, dwtY <= 1, dwtZ <= 1 else {
                throw J2KError.decodingError("COD: invalid wavelet transform IDs (\(dwtX),\(dwtY),\(dwtZ))")
            }
            guard dwtX == dwtY, dwtY == dwtZ else {
                throw J2KError.decodingError("COD: mixed reversible/irreversible wavelet kernels across axes are unsupported")
            }

            let maxLevels = max(nlx, max(nly, nlz))
            var precincts: [(ppx: Int, ppy: Int, ppz: Int)] = []
            if (scod & 0x01) != 0 {
                let expectedLen = 17 + 2 * (maxLevels + 1)
                guard len == expectedLen else {
                    throw J2KError.decodingError(
                        "COD: custom precinct length \(len) does not match expected \(expectedLen) for maxLevels=\(maxLevels)"
                    )
                }
                precincts.reserveCapacity(maxLevels + 1)
                for _ in 0...maxLevels {
                    let word = Int(try readUInt16BE(data, at: &offset))
                    guard (word & 0xF000) == 0 else {
                        throw J2KError.decodingError("COD: 3D precinct word carries non-zero reserved bits 12..15")
                    }
                    let ppx = word & 0x0F
                    let ppy = (word >> 4) & 0x0F
                    let ppz = (word >> 8) & 0x0F
                    precincts.append((ppx: ppx, ppy: ppy, ppz: ppz))
                }
            } else {
                guard len == 17 else {
                    throw J2KError.decodingError("COD: unexpected length \(len) without custom precincts (expected 17)")
                }
            }
            offset = segEnd
            let lossless = (dwtX == 1 && dwtY == 1 && dwtZ == 1)
            return (
                JP3DCODInfo(
                    levelsX: nlx,
                    levelsY: nly,
                    levelsZ: nlz,
                    isLossless: lossless,
                    codeBlockStyle: cbStyle,
                    scod: scod,
                    progressionOrderByte: prog,
                    numLayers: numLayers,
                    multipleComponentTransform: mct,
                    codeBlockWidthExponent: xcb,
                    codeBlockHeightExponent: ycb,
                    codeBlockDepthExponent: zcb,
                    dwtX: dwtX,
                    dwtY: dwtY,
                    dwtZ: dwtZ,
                    precinctSizes: precincts
                ),
                false
            )
        }

        // Legacy short COD fallback (Lcod == 12 or 14, allowed only for isolated legacy "J3DS"/"J3DI" streams without NSI).
        guard len == 12 || len == 14 else {
            throw J2KError.decodingError("COD: invalid segment length \(len)")
        }
        let scod = data[data.startIndex + offset]; offset += 1
        let prog = data[data.startIndex + offset]; offset += 1
        let numLayers = Int(try readUInt16BE(data, at: &offset))
        guard numLayers >= 1 else {
            throw J2KError.decodingError("COD: number of layers must be >= 1")
        }
        let mct = data[data.startIndex + offset]; offset += 1
        let levelsX = Int(data[data.startIndex + offset]); offset += 1
        let levelsY: Int
        let levelsZ: Int
        if len == 14 {
            levelsY = Int(data[data.startIndex + offset]); offset += 1
            levelsZ = Int(data[data.startIndex + offset]); offset += 1
        } else {
            levelsY = levelsX
            levelsZ = levelsX
        }
        guard levelsX <= 32, levelsY <= 32, levelsZ <= 32 else {
            throw J2KError.decodingError("COD: decomposition levels exceed maximum (32)")
        }
        let xcb = Int(data[data.startIndex + offset]) + 2; offset += 1
        let ycb = Int(data[data.startIndex + offset]) + 2; offset += 1
        let cbStyle = data[data.startIndex + offset]; offset += 1
        let dwtByte = data[data.startIndex + offset]; offset += 1
        guard dwtByte <= 1 else {
            throw J2KError.decodingError("COD: invalid wavelet filter byte \(dwtByte)")
        }
        let isLossless = (dwtByte == 1)
        offset = segEnd
        return (
            JP3DCODInfo(
                levelsX: levelsX,
                levelsY: levelsY,
                levelsZ: levelsZ,
                isLossless: isLossless,
                codeBlockStyle: cbStyle,
                scod: scod,
                progressionOrderByte: min(4, prog),
                numLayers: numLayers,
                multipleComponentTransform: mct,
                codeBlockWidthExponent: min(10, xcb),
                codeBlockHeightExponent: min(10, ycb),
                codeBlockDepthExponent: 0,
                dwtX: dwtByte,
                dwtY: dwtByte,
                dwtZ: dwtByte,
                precinctSizes: []
            ),
            true
        )
    }

    private func parseCOC(
        _ data: Data,
        at offset: inout Int,
        componentCount: Int,
        requireNormative3D: Bool
    ) throws -> (component: Int, coc: JP3DCODInfo) {
        let len = Int(try readUInt16BE(data, at: &offset))
        let compBytes = componentCount < 257 ? 1 : 2
        let minLen = (requireNormative3D ? 13 : 8) + compBytes
        guard len >= minLen, offset + (len - 2) <= data.count else {
            throw J2KError.decodingError("COC segment length \(len) invalid or truncated")
        }
        let segEnd = offset + len - 2
        let comp: Int
        if compBytes == 1 {
            comp = Int(data[data.startIndex + offset]); offset += 1
        } else {
            comp = Int(try readUInt16BE(data, at: &offset))
        }
        guard comp < componentCount else {
            throw J2KError.decodingError("COC component index \(comp) out of range (0..<\(componentCount))")
        }

        // Normative ITU-T T.809 3D COC (Clause A.2.3, Table A.10–A.11):
        // Lcoc = (13 + compBytes) without custom precincts, or (13 + compBytes + 2 * (maxLevels + 1)) with custom precincts.
        if len >= 13 + compBytes || requireNormative3D {
            let scoc = data[data.startIndex + offset]; offset += 1
            guard (scoc & 0xFE) == 0 else {
                throw J2KError.decodingError("COC: Scoc carries reserved bits (0x\(String(scoc, radix: 16)))")
            }
            let nlx = Int(data[data.startIndex + offset]); offset += 1
            let nly = Int(data[data.startIndex + offset]); offset += 1
            let nlz = Int(data[data.startIndex + offset]); offset += 1
            guard nlx <= 32, nly <= 32, nlz <= 32 else {
                throw J2KError.decodingError("COC: decomposition levels (\(nlx),\(nly),\(nlz)) exceed maximum 32")
            }
            let xcb = Int(data[data.startIndex + offset]); offset += 1
            let ycb = Int(data[data.startIndex + offset]); offset += 1
            let zcb = Int(data[data.startIndex + offset]); offset += 1
            guard xcb <= 10, ycb <= 10, zcb <= 10, (xcb + ycb + zcb) <= 18 else {
                throw J2KError.decodingError(
                    "COC: invalid 3D code-block exponents (\(xcb),\(ycb),\(zcb)) (max 10 each, sum <= 18)"
                )
            }
            let cbStyle = data[data.startIndex + offset]; offset += 1
            let dwtX = data[data.startIndex + offset]; offset += 1
            let dwtY = data[data.startIndex + offset]; offset += 1
            let dwtZ = data[data.startIndex + offset]; offset += 1
            guard dwtX <= 1, dwtY <= 1, dwtZ <= 1 else {
                throw J2KError.decodingError("COC: invalid wavelet transform IDs (\(dwtX),\(dwtY),\(dwtZ))")
            }
            guard dwtX == dwtY, dwtY == dwtZ else {
                throw J2KError.decodingError("COC: mixed reversible/irreversible wavelet kernels across axes are unsupported")
            }
            let maxLevels = max(nlx, max(nly, nlz))
            var precincts: [(ppx: Int, ppy: Int, ppz: Int)] = []
            let baseLen = 13 + compBytes
            if (scoc & 0x01) != 0 {
                let expectedLen = baseLen + 2 * (maxLevels + 1)
                guard len == expectedLen else {
                    throw J2KError.decodingError(
                        "COC: custom precinct length \(len) does not match expected \(expectedLen) for maxLevels=\(maxLevels)"
                    )
                }
                precincts.reserveCapacity(maxLevels + 1)
                for _ in 0...maxLevels {
                    let word = Int(try readUInt16BE(data, at: &offset))
                    guard (word & 0xF000) == 0 else {
                        throw J2KError.decodingError("COC: 3D precinct word carries non-zero reserved bits 12..15")
                    }
                    precincts.append((ppx: word & 0x0F, ppy: (word >> 4) & 0x0F, ppz: (word >> 8) & 0x0F))
                }
            } else {
                guard len == baseLen else {
                    throw J2KError.decodingError("COC: unexpected length \(len) without custom precincts (expected \(baseLen))")
                }
            }
            offset = segEnd
            return (
                comp,
                JP3DCODInfo(
                    levelsX: nlx,
                    levelsY: nly,
                    levelsZ: nlz,
                    isLossless: (dwtX == 1 && dwtY == 1 && dwtZ == 1),
                    codeBlockStyle: cbStyle,
                    scod: scoc & 0x01,
                    progressionOrderByte: 0,
                    numLayers: 1,
                    multipleComponentTransform: 0,
                    codeBlockWidthExponent: xcb,
                    codeBlockHeightExponent: ycb,
                    codeBlockDepthExponent: zcb,
                    dwtX: dwtX,
                    dwtY: dwtY,
                    dwtZ: dwtZ,
                    precinctSizes: precincts
                )
            )
        }

        // Legacy 2D-length COC fallback (only when `requireNormative3D == false`)
        let scoc = data[data.startIndex + offset]; offset += 1
        let nl = Int(data[data.startIndex + offset]); offset += 1
        guard nl <= 32 else {
            throw J2KError.decodingError("COC: decomposition levels exceed maximum (32)")
        }
        let xcb = min(10, Int(data[data.startIndex + offset]) + 2); offset += 1
        let ycb = min(10, Int(data[data.startIndex + offset]) + 2); offset += 1
        let cbStyle = data[data.startIndex + offset]; offset += 1
        let dwtByte = data[data.startIndex + offset]; offset += 1
        guard dwtByte <= 1 else {
            throw J2KError.decodingError("COC: invalid wavelet filter byte \(dwtByte)")
        }
        offset = segEnd
        return (
            comp,
            JP3DCODInfo(
                levelsX: nl,
                levelsY: nl,
                levelsZ: nl,
                isLossless: dwtByte == 1,
                codeBlockStyle: cbStyle,
                scod: scoc & 0x01,
                progressionOrderByte: 0,
                numLayers: 1,
                multipleComponentTransform: 0,
                codeBlockWidthExponent: xcb,
                codeBlockHeightExponent: ycb,
                codeBlockDepthExponent: 0,
                dwtX: dwtByte,
                dwtY: dwtByte,
                dwtZ: dwtByte,
                precinctSizes: []
            )
        )
    }

    private func parseQCD(
        _ data: Data,
        at offset: inout Int
    ) throws -> (params: JP3DQuantizationParameters, explicitSubbandCount: Int?) {
        let len = Int(try readUInt16BE(data, at: &offset))
        guard len >= 4 else {
            throw J2KError.decodingError("QCD segment length \(len) too small (min 4)")
        }
        let segEnd = offset + len - 2
        guard segEnd <= data.count else {
            throw J2KError.decodingError("QCD segment truncated")
        }
        return try parseQuantizationBody(data, at: &offset, segEnd: segEnd, label: "QCD")
    }

    private func parseQCC(
        _ data: Data,
        at offset: inout Int,
        componentCount: Int
    ) throws -> (component: Int, params: JP3DQuantizationParameters, explicitSubbandCount: Int?) {
        let len = Int(try readUInt16BE(data, at: &offset))
        let compBytes = componentCount < 257 ? 1 : 2
        guard len >= 4 + compBytes, offset + (len - 2) <= data.count else {
            throw J2KError.decodingError("QCC segment length \(len) invalid or truncated")
        }
        let segEnd = offset + len - 2
        let comp: Int
        if compBytes == 1 {
            comp = Int(data[data.startIndex + offset]); offset += 1
        } else {
            comp = Int(try readUInt16BE(data, at: &offset))
        }
        guard comp < componentCount else {
            throw J2KError.decodingError("QCC component index \(comp) out of range (0..<\(componentCount))")
        }
        let parsed = try parseQuantizationBody(data, at: &offset, segEnd: segEnd, label: "QCC")
        return (comp, parsed.params, parsed.explicitSubbandCount)
    }

    private func parseQuantizationBody(
        _ data: Data,
        at offset: inout Int,
        segEnd: Int,
        label: String
    ) throws -> (params: JP3DQuantizationParameters, explicitSubbandCount: Int?) {
        let sqcd = data[data.startIndex + offset]
        offset += 1
        let style = sqcd & 0x1F
        let guardBits = Int(sqcd >> 5)
        let remBytes = segEnd - offset

        switch style {
        case 0: // No quantisation (reversible 5-3): 1 byte per sub-band (eps_b in bits 7..3)
            guard remBytes >= 1 else {
                throw J2KError.decodingError("\(label) style 0 contains no sub-band exponents")
            }
            var steps: [(exponent: Int, mantissa: Int)] = []
            steps.reserveCapacity(remBytes)
            for _ in 0..<remBytes {
                let sp = data[data.startIndex + offset]
                offset += 1
                let eps = Int(sp >> 3)
                steps.append((exponent: eps, mantissa: 0))
            }
            return (JP3DQuantizationParameters(style: 0, guardBits: guardBits, steps: steps), remBytes)

        case 1: // Scalar derived: single 16-bit base step (eps_0 in bits 15..11, mu_0 in bits 10..0)
            guard remBytes == 2 else {
                throw J2KError.decodingError("\(label) style 1 has invalid payload byte count \(remBytes)")
            }
            let word = Int(try readUInt16BE(data, at: &offset))
            let eps = (word >> 11) & 0x1F
            let mu = word & 0x07FF
            return (JP3DQuantizationParameters(style: 1, guardBits: guardBits, steps: [(eps, mu)]), nil)

        case 2: // Scalar expounded: 2 bytes per sub-band
            guard remBytes >= 2, (remBytes % 2) == 0 else {
                throw J2KError.decodingError("\(label) style 2 has invalid byte count \(remBytes)")
            }
            let bandCount = remBytes / 2
            var steps: [(exponent: Int, mantissa: Int)] = []
            steps.reserveCapacity(bandCount)
            for _ in 0..<bandCount {
                let word = Int(try readUInt16BE(data, at: &offset))
                let eps = (word >> 11) & 0x1F
                let mu = word & 0x07FF
                steps.append((exponent: eps, mantissa: mu))
            }
            return (JP3DQuantizationParameters(style: 2, guardBits: guardBits, steps: steps), bandCount)

        default:
            throw J2KError.decodingError("\(label): unsupported quantisation style \(style)")
        }
    }

    private func parseRGN(_ data: Data, at offset: inout Int, componentCount: Int) throws -> (component: Int?, shift: Int) {
        let len = Int(try readUInt16BE(data, at: &offset))
        // ITU-T T.800 Table A.25 uses 1-byte Crgn when Csiz < 257 (Lrgn = 5);
        // ITU-T T.809 Clause A.2.4 / Table A.12 also permits 2-byte Crgn (Lrgn = 6, including Crgn = 65535 for all components).
        guard (len == 5 && componentCount < 257) || len == 6,
              offset + (len - 2) <= data.count else {
            throw J2KError.decodingError("RGN segment length \(len) invalid")
        }
        let comp: Int?
        if len == 5 {
            let raw = Int(data[data.startIndex + offset]); offset += 1
            guard raw < componentCount else {
                throw J2KError.decodingError("RGN component index \(raw) out of range")
            }
            comp = raw
        } else {
            let raw = Int(try readUInt16BE(data, at: &offset))
            if raw == 65_535 {
                comp = nil
            } else {
                guard raw < componentCount else {
                    throw J2KError.decodingError("RGN component index \(raw) out of range")
                }
                comp = raw
            }
        }
        let srgn = data[data.startIndex + offset]; offset += 1
        guard srgn == 0 else {
            throw J2KError.decodingError("RGN style \(srgn) unsupported (only Maxshift 0 is supported)")
        }
        let shift = Int(data[data.startIndex + offset]); offset += 1
        guard shift <= 37 else {
            throw J2KError.decodingError("RGN shift \(shift) exceeds maximum 37")
        }
        return (comp, shift)
    }

    private func parseCBD(
        _ data: Data,
        markerStart: Int,
        at offset: inout Int,
        codestreamComponents: Int
    ) throws -> (depths: [Int], signed: [Bool], raw: Data) {
        let len = Int(try readUInt16BE(data, at: &offset))
        guard len >= 5, offset + (len - 2) <= data.count else {
            throw J2KError.decodingError("CBD (0xFF78) segment length \(len) invalid or truncated")
        }
        let segEnd = offset + len - 2
        let ncbd = Int(try readUInt16BE(data, at: &offset))
        let count = ncbd & 0x3FFF
        let shared = (ncbd & 0x8000) != 0
        guard count >= 1, codestreamComponents == 2 * count else {
            throw J2KError.decodingError("CBD (0xFF78) output component count \(count) unsupported for \(codestreamComponents) codestream components")
        }
        let expectedLen = 4 + (shared ? 1 : count)
        guard len == expectedLen else {
            throw J2KError.decodingError("CBD (0xFF78) length \(len) does not match Ncbd=\(ncbd)")
        }
        var depths: [Int] = []
        var signedFlags: [Bool] = []
        depths.reserveCapacity(count)
        signedFlags.reserveCapacity(count)
        if shared {
            let b = data[data.startIndex + offset]; offset += 1
            let d = Int(b & 0x7F) + 1
            guard (1...38).contains(d) else {
                throw J2KError.decodingError("CBD (0xFF78) bit depth \(d) out of supported 1...38 range")
            }
            let s = (b & 0x80) != 0
            depths = [Int](repeating: d, count: count)
            signedFlags = [Bool](repeating: s, count: count)
        } else {
            for _ in 0..<count {
                let b = data[data.startIndex + offset]; offset += 1
                let d = Int(b & 0x7F) + 1
                guard (1...38).contains(d) else {
                    throw J2KError.decodingError("CBD (0xFF78) bit depth \(d) out of supported 1...38 range")
                }
                depths.append(d)
                signedFlags.append((b & 0x80) != 0)
            }
        }
        offset = segEnd
        let raw = Data(data[(data.startIndex + markerStart)..<(data.startIndex + segEnd)])
        return (depths, signedFlags, raw)
    }

    private func parsePart2BitSplitMCT(_ data: Data, markerStart: Int, at offset: inout Int) throws -> Data {
        let len = Int(try readUInt16BE(data, at: &offset))
        guard len == 16, offset + (len - 2) <= data.count else {
            throw J2KError.decodingError("MCT (0xFF74) unsupported length \(len)")
        }
        let segEnd = offset + len - 2
        let zmct = try readUInt16BE(data, at: &offset)
        let imct = try readUInt16BE(data, at: &offset)
        let ymct = try readUInt16BE(data, at: &offset)
        let c0 = try readUInt32BE(data, at: &offset)
        let c1 = try readUInt32BE(data, at: &offset)
        guard zmct == 0, imct == 0x0501, ymct == 0, c0 == 1, c1 == 524_288 else {
            throw J2KError.decodingError("MCT (0xFF74) unsupported Part 2 transform parameters")
        }
        offset = segEnd
        return Data(data[(data.startIndex + markerStart)..<(data.startIndex + segEnd)])
    }

    private func parsePart2BitSplitMCC(
        _ data: Data,
        markerStart: Int,
        at offset: inout Int,
        codestreamComponents: Int
    ) throws -> (logicalCount: Int, raw: Data) {
        let len = Int(try readUInt16BE(data, at: &offset))
        guard len >= 20, offset + (len - 2) <= data.count else {
            throw J2KError.decodingError("MCC (0xFF75) segment length \(len) invalid or truncated")
        }
        let segEnd = offset + len - 2
        let zmcc = try readUInt16BE(data, at: &offset)
        let imcc = data[data.startIndex + offset]; offset += 1
        let ymcc = try readUInt16BE(data, at: &offset)
        let qmcc = Int(try readUInt16BE(data, at: &offset))
        guard zmcc == 0, imcc == 1, ymcc == 0, qmcc >= 1,
              codestreamComponents == 2 * qmcc,
              len == 9 + 11 * qmcc else {
            throw J2KError.decodingError("MCC (0xFF75) unsupported Part 2 collection layout")
        }
        for c in 0..<qmcc {
            let xmcc = data[data.startIndex + offset]; offset += 1
            let nmcc = try readUInt16BE(data, at: &offset)
            let in0 = Int(data[data.startIndex + offset]); offset += 1
            let in1 = Int(data[data.startIndex + offset]); offset += 1
            let mmcc = try readUInt16BE(data, at: &offset)
            let out0 = Int(data[data.startIndex + offset]); offset += 1
            let t0 = data[data.startIndex + offset]; offset += 1
            let t1 = data[data.startIndex + offset]; offset += 1
            let t2 = data[data.startIndex + offset]; offset += 1
            guard xmcc == 0x09, nmcc == 2, in0 == 2 * c, in1 == 2 * c + 1,
                  mmcc == 1, out0 == c, t0 == 0, t1 == 0, t2 == 1 else {
                throw J2KError.decodingError("MCC (0xFF75) unsupported Part 2 component binding on collection \(c)")
            }
        }
        offset = segEnd
        return (qmcc, Data(data[(data.startIndex + markerStart)..<(data.startIndex + segEnd)]))
    }

    private func parsePart2BitSplitMCO(_ data: Data, markerStart: Int, at offset: inout Int) throws -> Data {
        let len = Int(try readUInt16BE(data, at: &offset))
        guard len == 4, offset + (len - 2) <= data.count else {
            throw J2KError.decodingError("MCO (0xFF77) unsupported length \(len)")
        }
        let segEnd = offset + len - 2
        let nmco = data[data.startIndex + offset]; offset += 1
        let stage0 = data[data.startIndex + offset]; offset += 1
        guard nmco == 1, stage0 == 1 else {
            throw J2KError.decodingError("MCO (0xFF77) unsupported Part 2 stage ordering")
        }
        offset = segEnd
        return Data(data[(data.startIndex + markerStart)..<(data.startIndex + segEnd)])
    }

    private func parseSOTAndData(
        _ data: Data,
        sotMarkerStart: Int,
        at offset: inout Int,
        componentCount: Int,
        is3D: Bool,
        limits: ResourceLimits?,
        retainedTileBytes: inout Int,
        tileOverrides: inout [Int: JP3DTileHeaderOverrides],
        sawAnyRGN: inout Bool,
        sawAnyTileFunctionalOrPPT: inout Bool,
        copyTilePayloads: Bool
    ) throws -> (tileIndex: Int, tilePartIndex: Int, data: Data) {
        let len = Int(try readUInt16BE(data, at: &offset))
        guard len == 10 else {
            throw J2KError.decodingError("SOT segment length \(len) invalid (expected 10)")
        }
        guard offset + 8 <= data.count else {
            throw J2KError.decodingError("SOT segment truncated")
        }
        let tileIndex = Int(try readUInt16BE(data, at: &offset))
        let psot = Int(try readUInt32BE(data, at: &offset))
        let tpIndex = Int(data[data.startIndex + offset]); offset += 1
        let tnCount = Int(data[data.startIndex + offset]); offset += 1
        if tnCount > 0 && tpIndex >= tnCount {
            throw J2KError.decodingError("SOT[\(tileIndex)]: TPsot (\(tpIndex)) >= TNsot (\(tnCount))")
        }
        if psot != 0 && psot < 14 {
            throw J2KError.decodingError("SOT[\(tileIndex)]: invalid non-zero Psot \(psot) (< 14)")
        }

        // Consume optional tile-part header markers until SOD (0xFF93).
        var foundSOD = false
        var localOverrides = tileOverrides[tileIndex] ?? JP3DTileHeaderOverrides()
        var addedOverrideBytes = 0

        while offset + 2 <= data.count {
            let m = try readUInt16BE(data, at: &offset)
            if m == 0xFF93 { // SOD
                foundSOD = true
                break
            }
            switch m {
            case 0xFF52: // Tile-part COD (ITU-T T.809 Clause A.2.2: first tile-part TPsot == 0 only)
                guard tpIndex == 0 else {
                    throw J2KError.decodingError("SOT[\(tileIndex)]: COD override is only permitted in first tile-part (TPsot == 0)")
                }
                guard localOverrides.cod == nil else {
                    throw J2KError.decodingError("SOT[\(tileIndex)]: duplicate COD in tile-part header")
                }
                let parsedCOD = try parseCOD(data, at: &offset, requireNormative3D: is3D)
                if is3D && parsedCOD.wasLegacyShort {
                    throw J2KError.decodingError("SOT[\(tileIndex)]: normative Part 10 tile COD cannot use 2D short length")
                }
                localOverrides.cod = parsedCOD.cod
                sawAnyTileFunctionalOrPPT = true
                addedOverrideBytes += MemoryLayout<JP3DCODInfo>.stride

            case 0xFF53: // Tile-part COC (ITU-T T.809 Clause A.2.3: TPsot == 0 only)
                guard tpIndex == 0 else {
                    throw J2KError.decodingError("SOT[\(tileIndex)]: COC override is only permitted in first tile-part (TPsot == 0)")
                }
                let parsedCOC = try parseCOC(data, at: &offset, componentCount: componentCount, requireNormative3D: is3D)
                guard localOverrides.coc[parsedCOC.component] == nil else {
                    throw J2KError.decodingError("SOT[\(tileIndex)]: duplicate COC for component \(parsedCOC.component)")
                }
                localOverrides.coc[parsedCOC.component] = parsedCOC.coc
                sawAnyTileFunctionalOrPPT = true
                addedOverrideBytes += MemoryLayout<JP3DCODInfo>.stride + 16

            case 0xFF5C: // Tile-part QCD (ITU-T T.809 Clause A.2.5: TPsot == 0 only)
                guard tpIndex == 0 else {
                    throw J2KError.decodingError("SOT[\(tileIndex)]: QCD override is only permitted in first tile-part (TPsot == 0)")
                }
                guard localOverrides.qcd == nil else {
                    throw J2KError.decodingError("SOT[\(tileIndex)]: duplicate QCD in tile-part header")
                }
                let parsedQCD = try parseQCD(data, at: &offset)
                localOverrides.qcd = parsedQCD.params
                localOverrides.qcdExplicitSubbandCount = parsedQCD.explicitSubbandCount
                sawAnyTileFunctionalOrPPT = true
                addedOverrideBytes += parsedQCD.params.steps.count * 16 + 32

            case 0xFF5D: // Tile-part QCC (ITU-T T.809 Clause A.2.6: TPsot == 0 only)
                guard tpIndex == 0 else {
                    throw J2KError.decodingError("SOT[\(tileIndex)]: QCC override is only permitted in first tile-part (TPsot == 0)")
                }
                let parsedQCC = try parseQCC(data, at: &offset, componentCount: componentCount)
                guard localOverrides.qcc[parsedQCC.component] == nil else {
                    throw J2KError.decodingError("SOT[\(tileIndex)]: duplicate QCC for component \(parsedQCC.component)")
                }
                localOverrides.qcc[parsedQCC.component] = (parsedQCC.params, parsedQCC.explicitSubbandCount)
                sawAnyTileFunctionalOrPPT = true
                addedOverrideBytes += parsedQCC.params.steps.count * 16 + 48

            case 0xFF5E: // Tile-part RGN (ITU-T T.809 Clause A.2.4: TPsot == 0 only)
                guard tpIndex == 0 else {
                    throw J2KError.decodingError("SOT[\(tileIndex)]: RGN override is only permitted in first tile-part (TPsot == 0)")
                }
                let rgn = try parseRGN(data, at: &offset, componentCount: componentCount)
                sawAnyRGN = true
                sawAnyTileFunctionalOrPPT = true
                if let comp = rgn.component {
                    localOverrides.rgnByComponent[comp] = rgn.shift
                } else {
                    localOverrides.rgnAllComponents = rgn.shift
                }
                addedOverrideBytes += 24

            case 0xFF58, 0xFF61, 0xFF64: // PLT, PPT, COM
                if m == 0xFF61 {
                    sawAnyTileFunctionalOrPPT = true
                }
                let mLen = Int(try readUInt16BE(data, at: &offset))
                guard mLen >= 2, offset + (mLen - 2) <= data.count else {
                    throw J2KError.decodingError("Tile-part marker 0x\(String(m, radix: 16)) truncated")
                }
                offset += mLen - 2
            default:
                throw J2KError.decodingError(
                    "SOT[\(tileIndex)]: unexpected marker 0x\(String(m, radix: 16)) before SOD (0xFF93)"
                )
            }
        }
        guard foundSOD else {
            throw J2KError.decodingError("SOT[\(tileIndex)]: truncated before SOD (0xFF93)")
        }

        if localOverrides.hasAnyFunctionalOverride {
            tileOverrides[tileIndex] = localOverrides
        }

        let tileHeaderBytes = offset - sotMarkerStart
        let dataLength: Int
        if psot > 0 {
            guard psot >= tileHeaderBytes else {
                throw J2KError.decodingError(
                    "SOT[\(tileIndex)]: Psot (\(psot)) smaller than tile-part header (\(tileHeaderBytes))"
                )
            }
            dataLength = psot - tileHeaderBytes
        } else {
            dataLength = nextTileBoundaryOffset(in: data, from: offset) - offset
        }

        let (endOffset, overflow) = offset.addingReportingOverflow(dataLength)
        guard !overflow, dataLength >= 0, endOffset <= data.count else {
            throw J2KError.decodingError(
                "SOT[\(tileIndex)]: declared data length \(dataLength) exceeds available bytes"
            )
        }

        let copyLength = copyTilePayloads ? dataLength : min(dataLength, 32)
        let recordOverhead = 32 + MemoryLayout<JP3DParsedTile>.stride + addedOverrideBytes
        let (tileEntryBytes, ov1) = copyLength.addingReportingOverflow(recordOverhead)
        let (nextRetained, ov2) = retainedTileBytes.addingReportingOverflow(tileEntryBytes)
        let (liveTotal, ov3) = data.count.addingReportingOverflow(nextRetained)
        guard !ov1, !ov2, !ov3 else {
            throw CodecError(.resourceLimitExceeded, "Volumetric codestream tile buffers overflow memory limits.")
        }
        if let limits {
            guard nextRetained <= limits.maximumWorkspaceBytes,
                  liveTotal <= limits.maximumMemoryBytes else {
                throw CodecError(
                    .resourceLimitExceeded,
                    "Volumetric codestream tile buffer copies (\(nextRetained) B) exceed workspace or memory limits."
                )
            }
        }
        retainedTileBytes = nextRetained
        StorageTelemetry.recordParserAllocation(stage: "jp3d-tile-subdata", bytes: tileEntryBytes)

        let tileData = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + copyLength))
        offset = endOffset

        return (tileIndex: tileIndex, tilePartIndex: tpIndex, data: tileData)
    }

    /// Scans for the next `SOT` (`0xFF90` with `Lsot == 10`) or `EOC` (`0xFFD9`) when `Psot == 0`,
    /// without misinterpreting bit-stuffed `0xFF 0x00..0x8F` bytes or in-stream `SOP`/`EPH` (`0xFF91`/`0xFF92`).
    private func nextTileBoundaryOffset(in data: Data, from start: Int) -> Int {
        var i = start
        while i < data.count - 1 {
            if data[data.startIndex + i] == 0xFF {
                let low = data[data.startIndex + i + 1]
                if low == 0xD9 {
                    return i
                }
                if low == 0x90, i + 4 <= data.count {
                    let lsot = (UInt16(data[data.startIndex + i + 2]) << 8) | UInt16(data[data.startIndex + i + 3])
                    if lsot == 10 {
                        return i
                    }
                }
            }
            i += 1
        }
        return data.count
    }

    // MARK: - Byte Reading Helpers

    private func readUInt16BE(_ data: Data, at offset: inout Int) throws -> UInt16 {
        guard offset + 2 <= data.count else {
            throw J2KError.decodingError("Codestream truncated reading UInt16 at offset \(offset)")
        }
        let hi = UInt16(data[data.startIndex + offset])
        let lo = UInt16(data[data.startIndex + offset + 1])
        offset += 2
        return (hi << 8) | lo
    }

    private func readUInt32BE(_ data: Data, at offset: inout Int) throws -> UInt32 {
        guard offset + 4 <= data.count else {
            throw J2KError.decodingError("Codestream truncated reading UInt32 at offset \(offset)")
        }
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        offset += 4
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
