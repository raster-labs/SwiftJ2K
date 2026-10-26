// SPDX-License-Identifier: Apache-2.0
//
// Tile geometry (ISO/IEC 15444-1 Annex B: tiles, resolutions, subbands,
// precincts and code-blocks on the reference grid), the five progression
// orders (B.12) and tier-2 packet header coding (B.10) with quality layers
// and codeword-segment lengths (B.10.7).
//
// Provenance: new implementation (Milestone 2, generalised in Milestone 4).
// The predecessor's packet writer/reader (Raster-Lab/J2KSwift 7acc9ae4,
// `writePacket` in J2KEncoderPipeline.swift and the packet loop in
// J2KDecoderPipeline.swift) were read for their recorded length-decoding
// defects but are inseparable from HT and multi-layer state; its standalone
// `J2KTier2Coding.swift` MQ-codes packet headers, which B.10 does not permit,
// and was deliberately not migrated.

struct CodeBlockGeometry: Sendable {
    let x0: Int, y0: Int, width: Int, height: Int   // band coordinates (absolute)
}

struct PrecinctBandGeometry: Sendable {
    let bandIndex: Int
    let blocksWide: Int
    let blocksHigh: Int
    let blocks: [CodeBlockGeometry]   // raster order inside the precinct
}

struct PrecinctGeometry: Sendable {
    let bands: [PrecinctBandGeometry]
    var blockCount: Int { bands.reduce(0) { $0 + $1.blocks.count } }
}

struct BandGeometry: Sendable {
    let orientation: BandOrientation
    let x0: Int, x1: Int, y0: Int, y1: Int   // tbx0..tbx1, tby0..tby1
    let planeX: Int, planeY: Int              // origin of the band inside the tile's nested plane
    let gain: Int                             // log2 gain: LL 0, HL/LH 1, HH 2
    let quantizationIndex: Int                // index into the QCD exponent list
    var width: Int { x1 - x0 }
    var height: Int { y1 - y0 }
}

struct ResolutionGeometry: Sendable {
    let index: Int
    let x0: Int, x1: Int, y0: Int, y1: Int   // trx0..trx1, try0..try1
    let ppx: Int, ppy: Int
    let precinctsWide: Int, precinctsHigh: Int
    let bands: [BandGeometry]
    let precincts: [PrecinctGeometry]
    var width: Int { x1 - x0 }
    var height: Int { y1 - y0 }
}

struct TileGeometry: Sendable {
    let x0: Int, x1: Int, y0: Int, y1: Int   // tile-component on the reference grid
    let levels: Int
    let resolutions: [ResolutionGeometry]
    var width: Int { x1 - x0 }
    var height: Int { y1 - y0 }
    var codeBlockCount: Int { resolutions.reduce(0) { $0 + $1.precincts.reduce(0) { $0 + $1.blockCount } } }
}

/// Code-block style bits (Table A.19 and ISO/IEC 15444-15 Table A.4).
struct CodeBlockStyle: Sendable, Equatable {
    let bypass: Bool, reset: Bool, terminateAll: Bool, causal: Bool, predictable: Bool, segmentationSymbols: Bool
    let ht: Bool, htMixed: Bool
    init(bits: UInt8) {
        bypass = bits & 0x01 != 0; reset = bits & 0x02 != 0; terminateAll = bits & 0x04 != 0
        causal = bits & 0x08 != 0; predictable = bits & 0x10 != 0; segmentationSymbols = bits & 0x20 != 0
        ht = bits & 0x40 != 0; htMixed = bits & 0x80 != 0
    }
    static let `default` = CodeBlockStyle(bits: 0)

    /// Whether coding pass `index` (0 = the first cleanup pass) ends a
    /// codeword segment (Table D.9 / D.10).
    func passTerminates(_ index: Int) -> Bool {
        if ht {
            // In Part 15, bit 0 (`bypass`) signals the presence of HT SigProp/MagRef refinement
            // passes in a second codeword segment (`Lref`) after the cleanup pass (`Lcup`).
            return bypass && index == 0
        }
        if terminateAll { return true }
        if bypass { return index == 9 || (index >= 10 && (index - 10) % 3 != 0) }
        return false
    }
    /// Whether coding pass `index` is coded raw under selective bypass.
    func passIsRaw(_ index: Int) -> Bool { !ht && bypass && index >= 10 && (index - 10) % 3 != 2 }
}

/// Bytes of one codeword segment, concatenated across layers.
struct CodewordSegment: Sendable {
    var data: [UInt8] = []
    var passes = 0
}

/// What packets have contributed to one code-block so far.
struct CodeBlockContribution: Sendable {
    var included = false
    var isHT = false
    var lblock = 3
    var zeroBitPlanes = 0
    var passes = 0
    var segments: [CodewordSegment] = []
}

enum Tier2 {
    // MARK: - Geometry (Annex B.3 – B.7)

    struct TileGeometryFootprint: Sendable {
        let resolutionCount: Int
        let bandCount: Int
        let precinctCount: Int
        let precinctBandCount: Int
        let codeBlockCount: Int
        let tagTreeNodeCount: Int
        let geometryBytes: Int
        let decodeStateBytes: Int
        let encodeStateStructBytes: Int
    }

    /// Preflights exact resolution, band, precinct, code-block and tag-tree node
    /// counts and nested array/struct memory footprints using checked scalar
    /// arithmetic without allocating geometry arrays.
    static func preflightTileGeometry(
        x0 tcx0: Int, x1 tcx1: Int, y0 tcy0: Int, y1 tcy1: Int,
        codingStyle cod: CodingStyleSegment
    ) throws -> TileGeometryFootprint {
        let levels = cod.decompositionLevels
        let resolutionCount = levels + 1
        var bandCount = 0
        var precinctCount = 0
        var precinctBandCount = 0
        var codeBlockCount = 0
        var tagTreeNodeCount = 0

        func bandRange(_ c0: Int, _ c1: Int, level nb: Int, high: Bool) -> (Int, Int) {
            let denominator = 1 << nb
            let offset = high ? 1 << (nb - 1) : 0
            return (Wavelet53.ceilDiv(c0 - offset, denominator), Wavelet53.ceilDiv(c1 - offset, denominator))
        }

        for r in 0...levels {
            let shift = levels - r
            let trx0 = Wavelet53.ceilDivPowerOfTwo(tcx0, shift), trx1 = Wavelet53.ceilDivPowerOfTwo(tcx1, shift)
            let try0 = Wavelet53.ceilDivPowerOfTwo(tcy0, shift), try1 = Wavelet53.ceilDivPowerOfTwo(tcy1, shift)
            let bandRects: [(x0: Int, x1: Int, y0: Int, y1: Int)]
            if r == 0 {
                let (bx0, bx1) = bandRange(tcx0, tcx1, level: levels, high: false)
                let (by0, by1) = bandRange(tcy0, tcy1, level: levels, high: false)
                guard bx0 == trx0, bx1 == trx1, by0 == try0, by1 == try1 else {
                    throw CodecError(.internalFailure, "LL band and resolution 0 geometry disagree.")
                }
                bandRects = [(bx0, bx1, by0, by1)]
            } else {
                let nb = levels - r + 1
                let lowW = Wavelet53.lowCount(trx0, trx1), lowH = Wavelet53.lowCount(try0, try1)
                let (hx0, hx1) = bandRange(tcx0, tcx1, level: nb, high: true)
                let (lx0, lx1) = bandRange(tcx0, tcx1, level: nb, high: false)
                let (hy0, hy1) = bandRange(tcy0, tcy1, level: nb, high: true)
                let (ly0, ly1) = bandRange(tcy0, tcy1, level: nb, high: false)
                guard lx1 - lx0 == lowW, hx1 - hx0 == (trx1 - trx0) - lowW,
                      ly1 - ly0 == lowH, hy1 - hy0 == (try1 - try0) - lowH else {
                    throw CodecError(.internalFailure, "Subband and resolution geometry disagree.")
                }
                bandRects = [(hx0, hx1, ly0, ly1), (lx0, lx1, hy0, hy1), (hx0, hx1, hy0, hy1)]
            }
            bandCount = try checkedAdd(bandCount, bandRects.count)

            let (ppx, ppy) = cod.precinctExponents(resolution: r)
            let bandPPX = r == 0 ? ppx : ppx - 1, bandPPY = r == 0 ? ppy : ppy - 1
            let xcb = min(cod.codeBlockWidthExponent, bandPPX), ycb = min(cod.codeBlockHeightExponent, bandPPY)
            let precinctsWide = trx1 > trx0 ? Wavelet53.ceilDiv(trx1, 1 << ppx) - Wavelet53.floorDiv(trx0, 1 << ppx) : 0
            let precinctsHigh = try1 > try0 ? Wavelet53.ceilDiv(try1, 1 << ppy) - Wavelet53.floorDiv(try0, 1 << ppy) : 0
            let resPrecincts = try checkedMultiply(precinctsWide, precinctsHigh)
            guard resPrecincts <= 1 << 24 else {
                throw CodecError(.resourceLimitExceeded, "Precinct count exceeds the parser budget.")
            }
            precinctCount = try checkedAdd(precinctCount, resPrecincts)
            precinctBandCount = try checkedAdd(precinctBandCount, try checkedMultiply(resPrecincts, bandRects.count))

            let firstPrecinctX = Wavelet53.floorDiv(trx0, 1 << ppx), firstPrecinctY = Wavelet53.floorDiv(try0, 1 << ppy)
            for py in 0..<precinctsHigh {
                for px in 0..<precinctsWide {
                    for rect in bandRects {
                        let bx0 = max(rect.x0, (firstPrecinctX + px) << bandPPX)
                        let bx1 = min(rect.x1, (firstPrecinctX + px + 1) << bandPPX)
                        let by0 = max(rect.y0, (firstPrecinctY + py) << bandPPY)
                        let by1 = min(rect.y1, (firstPrecinctY + py + 1) << bandPPY)
                        if bx0 < bx1, by0 < by1 {
                            let firstColumn = Wavelet53.floorDiv(bx0, 1 << xcb), lastColumn = Wavelet53.floorDiv(bx1 - 1, 1 << xcb)
                            let firstRow = Wavelet53.floorDiv(by0, 1 << ycb), lastRow = Wavelet53.floorDiv(by1 - 1, 1 << ycb)
                            let blocksWide = lastColumn - firstColumn + 1
                            let blocksHigh = lastRow - firstRow + 1
                            let pbBlocks = try checkedMultiply(blocksWide, blocksHigh)
                            codeBlockCount = try checkedAdd(codeBlockCount, pbBlocks)
                            let nodes = try TagTree.nodeCount(width: blocksWide, height: blocksHigh)
                            tagTreeNodeCount = try checkedAdd(tagTreeNodeCount, try checkedMultiply(nodes, 2))
                        }
                    }
                }
            }
        }

        let arrayHeader = 32
        let resBytes = try checkedMultiply(resolutionCount, MemoryLayout<ResolutionGeometry>.stride + 2 * arrayHeader)
        let bandBytes = try checkedMultiply(bandCount, MemoryLayout<BandGeometry>.stride)
        let precBytes = try checkedMultiply(precinctCount, MemoryLayout<PrecinctGeometry>.stride + arrayHeader)
        let pbBytes = try checkedMultiply(precinctBandCount, MemoryLayout<PrecinctBandGeometry>.stride + arrayHeader)
        let cbBytes = try checkedMultiply(codeBlockCount, MemoryLayout<CodeBlockGeometry>.stride)
        let geometryBytes = try checkedAdd(
            MemoryLayout<TileGeometry>.stride + arrayHeader,
            try checkedAdd(
                try checkedAdd(resBytes, bandBytes),
                try checkedAdd(try checkedAdd(precBytes, pbBytes), cbBytes)
            )
        )

        let nestedGridHeaders = try checkedAdd(
            arrayHeader,
            try checkedAdd(
                try checkedMultiply(resolutionCount, arrayHeader),
                try checkedAdd(
                    try checkedMultiply(precinctCount, arrayHeader),
                    try checkedMultiply(precinctBandCount, arrayHeader)
                )
            )
        )
        let contributionStructBytes = try checkedMultiply(codeBlockCount, MemoryLayout<CodeBlockContribution>.stride)
        let treeStructBytes = try checkedAdd(
            try checkedMultiply(precinctCount, MemoryLayout<PrecinctTrees>.stride + 2 * arrayHeader),
            try checkedAdd(
                try checkedMultiply(precinctBandCount, 2 * (MemoryLayout<TagTree>.stride + 2 * arrayHeader)),
                try checkedMultiply(tagTreeNodeCount, TagTree.nodeStride)
            )
        )
        let decodeStateBytes = try checkedAdd(
            nestedGridHeaders,
            try checkedAdd(contributionStructBytes, treeStructBytes)
        )

        let encodingStructBytes = try checkedMultiply(codeBlockCount, MemoryLayout<CodeBlockEncoding>.stride)
        let encodeStateStructBytes = try checkedAdd(
            nestedGridHeaders,
            try checkedAdd(encodingStructBytes, try checkedMultiply(tagTreeNodeCount, TagTree.nodeStride))
        )

        return TileGeometryFootprint(
            resolutionCount: resolutionCount,
            bandCount: bandCount,
            precinctCount: precinctCount,
            precinctBandCount: precinctBandCount,
            codeBlockCount: codeBlockCount,
            tagTreeNodeCount: tagTreeNodeCount,
            geometryBytes: geometryBytes,
            decodeStateBytes: decodeStateBytes,
            encodeStateStructBytes: encodeStateStructBytes
        )
    }

    static func makeTileGeometry(x0 tcx0: Int, x1 tcx1: Int, y0 tcy0: Int, y1 tcy1: Int,
                                 codingStyle cod: CodingStyleSegment) throws -> TileGeometry {
        let levels = cod.decompositionLevels
        var resolutions: [ResolutionGeometry] = []
        for r in 0...levels {
            let shift = levels - r
            let trx0 = Wavelet53.ceilDivPowerOfTwo(tcx0, shift), trx1 = Wavelet53.ceilDivPowerOfTwo(tcx1, shift)
            let try0 = Wavelet53.ceilDivPowerOfTwo(tcy0, shift), try1 = Wavelet53.ceilDivPowerOfTwo(tcy1, shift)
            var bands: [BandGeometry] = []
            func bandRange(_ c0: Int, _ c1: Int, level nb: Int, high: Bool) -> (Int, Int) {
                let denominator = 1 << nb
                let offset = high ? 1 << (nb - 1) : 0
                return (Wavelet53.ceilDiv(c0 - offset, denominator), Wavelet53.ceilDiv(c1 - offset, denominator))
            }
            if r == 0 {
                let (bx0, bx1) = bandRange(tcx0, tcx1, level: levels, high: false)
                let (by0, by1) = bandRange(tcy0, tcy1, level: levels, high: false)
                guard bx0 == trx0, bx1 == trx1, by0 == try0, by1 == try1 else {
                    throw CodecError(.internalFailure, "LL band and resolution 0 geometry disagree.")
                }
                bands.append(BandGeometry(orientation: .ll, x0: bx0, x1: bx1, y0: by0, y1: by1,
                                          planeX: 0, planeY: 0, gain: 0, quantizationIndex: 0))
            } else {
                let nb = levels - r + 1
                let lowW = Wavelet53.lowCount(trx0, trx1), lowH = Wavelet53.lowCount(try0, try1)
                let (hx0, hx1) = bandRange(tcx0, tcx1, level: nb, high: true)
                let (lx0, lx1) = bandRange(tcx0, tcx1, level: nb, high: false)
                let (hy0, hy1) = bandRange(tcy0, tcy1, level: nb, high: true)
                let (ly0, ly1) = bandRange(tcy0, tcy1, level: nb, high: false)
                guard lx1 - lx0 == lowW, hx1 - hx0 == (trx1 - trx0) - lowW,
                      ly1 - ly0 == lowH, hy1 - hy0 == (try1 - try0) - lowH else {
                    throw CodecError(.internalFailure, "Subband and resolution geometry disagree.")
                }
                let base = 3 * (r - 1) + 1
                bands.append(BandGeometry(orientation: .hl, x0: hx0, x1: hx1, y0: ly0, y1: ly1,
                                          planeX: lowW, planeY: 0, gain: 1, quantizationIndex: base))
                bands.append(BandGeometry(orientation: .lh, x0: lx0, x1: lx1, y0: hy0, y1: hy1,
                                          planeX: 0, planeY: lowH, gain: 1, quantizationIndex: base + 1))
                bands.append(BandGeometry(orientation: .hh, x0: hx0, x1: hx1, y0: hy0, y1: hy1,
                                          planeX: lowW, planeY: lowH, gain: 2, quantizationIndex: base + 2))
            }
            let (ppx, ppy) = cod.precinctExponents(resolution: r)
            let bandPPX = r == 0 ? ppx : ppx - 1, bandPPY = r == 0 ? ppy : ppy - 1
            let xcb = min(cod.codeBlockWidthExponent, bandPPX), ycb = min(cod.codeBlockHeightExponent, bandPPY)
            let precinctsWide = trx1 > trx0 ? Wavelet53.ceilDiv(trx1, 1 << ppx) - Wavelet53.floorDiv(trx0, 1 << ppx) : 0
            let precinctsHigh = try1 > try0 ? Wavelet53.ceilDiv(try1, 1 << ppy) - Wavelet53.floorDiv(try0, 1 << ppy) : 0
            guard precinctsWide * precinctsHigh <= 1 << 24 else {
                throw CodecError(.resourceLimitExceeded, "Precinct count exceeds the parser budget.")
            }
            let firstPrecinctX = Wavelet53.floorDiv(trx0, 1 << ppx), firstPrecinctY = Wavelet53.floorDiv(try0, 1 << ppy)
            var precincts: [PrecinctGeometry] = []
            for py in 0..<precinctsHigh {
                for px in 0..<precinctsWide {
                    var precinctBands: [PrecinctBandGeometry] = []
                    for (bandIndex, band) in bands.enumerated() {
                        // Precinct rectangle in band coordinates, clipped to the band.
                        let bx0 = max(band.x0, (firstPrecinctX + px) << bandPPX)
                        let bx1 = min(band.x1, (firstPrecinctX + px + 1) << bandPPX)
                        let by0 = max(band.y0, (firstPrecinctY + py) << bandPPY)
                        let by1 = min(band.y1, (firstPrecinctY + py + 1) << bandPPY)
                        var blocks: [CodeBlockGeometry] = []
                        var blocksWide = 0, blocksHigh = 0
                        if bx0 < bx1, by0 < by1 {
                            let firstColumn = Wavelet53.floorDiv(bx0, 1 << xcb), lastColumn = Wavelet53.floorDiv(bx1 - 1, 1 << xcb)
                            let firstRow = Wavelet53.floorDiv(by0, 1 << ycb), lastRow = Wavelet53.floorDiv(by1 - 1, 1 << ycb)
                            blocksWide = lastColumn - firstColumn + 1
                            blocksHigh = lastRow - firstRow + 1
                            for row in firstRow...lastRow {
                                for column in firstColumn...lastColumn {
                                    let x0 = max(bx0, column << xcb), x1 = min(bx1, (column + 1) << xcb)
                                    let y0 = max(by0, row << ycb), y1 = min(by1, (row + 1) << ycb)
                                    blocks.append(CodeBlockGeometry(x0: x0, y0: y0, width: x1 - x0, height: y1 - y0))
                                }
                            }
                        }
                        precinctBands.append(PrecinctBandGeometry(bandIndex: bandIndex, blocksWide: blocksWide,
                                                                  blocksHigh: blocksHigh, blocks: blocks))
                    }
                    precincts.append(PrecinctGeometry(bands: precinctBands))
                }
            }
            resolutions.append(ResolutionGeometry(index: r, x0: trx0, x1: trx1, y0: try0, y1: try1, ppx: ppx, ppy: ppy,
                                                  precinctsWide: precinctsWide, precinctsHigh: precinctsHigh,
                                                  bands: bands, precincts: precincts))
        }
        return TileGeometry(x0: tcx0, x1: tcx1, y0: tcy0, y1: tcy1, levels: levels, resolutions: resolutions)
    }

    // MARK: - Packet sequence (B.12, one component)

    struct PacketAddress: Sendable, Equatable { let layer: Int, resolution: Int, precinct: Int }

    static func packetSequence(geometry: TileGeometry, codingStyle cod: CodingStyleSegment) throws -> [PacketAddress] {
        let layers = cod.layers, levels = geometry.levels
        var sequence: [PacketAddress] = []
        switch cod.progression {
        case 0: // LRCP
            for l in 0..<layers { for r in 0...levels { for p in 0..<geometry.resolutions[r].precincts.count {
                sequence.append(PacketAddress(layer: l, resolution: r, precinct: p)) } } }
        case 1: // RLCP
            for r in 0...levels { for l in 0..<layers { for p in 0..<geometry.resolutions[r].precincts.count {
                sequence.append(PacketAddress(layer: l, resolution: r, precinct: p)) } } }
        case 2, 3, 4: // RPCL, PCRL, CPRL: position-major within a single component
            func precinctIndex(resolution r: Int, x: Int, y: Int) -> Int? {
                let res = geometry.resolutions[r]
                guard res.precinctsWide > 0, res.precinctsHigh > 0 else { return nil }
                let shift = levels - r
                let stepX = 1 << (res.ppx + shift), stepY = 1 << (res.ppy + shift)
                let startsX = x % stepX == 0 || (x == geometry.x0 && (res.x0 << shift) % stepX != 0)
                let startsY = y % stepY == 0 || (y == geometry.y0 && (res.y0 << shift) % stepY != 0)
                guard startsX, startsY else { return nil }
                let rx = Wavelet53.ceilDivPowerOfTwo(x, shift), ry = Wavelet53.ceilDivPowerOfTwo(y, shift)
                let px = Wavelet53.floorDiv(rx, 1 << res.ppx) - Wavelet53.floorDiv(res.x0, 1 << res.ppx)
                let py = Wavelet53.floorDiv(ry, 1 << res.ppy) - Wavelet53.floorDiv(res.y0, 1 << res.ppy)
                guard px >= 0, px < res.precinctsWide, py >= 0, py < res.precinctsHigh else { return nil }
                return py * res.precinctsWide + px
            }
            var stepX = Int.max, stepY = Int.max
            for res in geometry.resolutions {
                stepX = min(stepX, 1 << (res.ppx + levels - res.index))
                stepY = min(stepY, 1 << (res.ppy + levels - res.index))
            }
            // Positions visited: the tile origin, then every multiple of the step (B.12.1.3).
            func positions(_ start: Int, _ end: Int, _ step: Int) -> [Int] {
                var values: [Int] = []
                var v = start
                while v < end { values.append(v); v += step - (((v % step) + step) % step) }
                return values
            }
            let xs = positions(geometry.x0, geometry.x1, stepX)
            let ys = positions(geometry.y0, geometry.y1, stepY)
            var seen = Set<Int>()
            func emit(_ r: Int, _ x: Int, _ y: Int) {
                guard let p = precinctIndex(resolution: r, x: x, y: y), seen.insert(r << 32 | p).inserted else { return }
                for l in 0..<layers { sequence.append(PacketAddress(layer: l, resolution: r, precinct: p)) }
            }
            if cod.progression == 2 {
                for r in 0...levels { for y in ys { for x in xs { emit(r, x, y) } } }
            } else {
                for y in ys { for x in xs { for r in 0...levels { emit(r, x, y) } } }
            }
        default:
            throw CodecError(.malformedInput, "Unknown progression order.")
        }
        let expected = geometry.resolutions.reduce(0) { $0 + $1.precincts.count } * layers
        guard sequence.count == expected else {
            throw CodecError(.internalFailure, "Packet sequence covers \(sequence.count) of \(expected) packets.")
        }
        return sequence
    }

    // MARK: - Pass-count codeword (Table B.4)

    static func readPassCount(_ reader: inout PacketBitReader) throws -> Int {
        if try !reader.readBit() { return 1 }
        if try !reader.readBit() { return 2 }
        let two = try reader.readBits(2)
        if two < 3 { return 3 + two }
        let five = try reader.readBits(5)
        if five < 31 { return 6 + five }
        return 37 + (try reader.readBits(7))
    }

    static func writePassCount(_ passes: Int, _ writer: inout PacketBitWriter) throws {
        switch passes {
        case 1: writer.writeBit(false)
        case 2: writer.writeBits(0b10, count: 2)
        case 3...5: writer.writeBits(0b11, count: 2); writer.writeBits(passes - 3, count: 2)
        case 6...36: writer.writeBits(0b1111, count: 4); writer.writeBits(passes - 6, count: 5)
        case 37...164: writer.writeBits(0b1_1111_1111, count: 9); writer.writeBits(passes - 37, count: 7)
        default: throw CodecError(.internalFailure, "Coding pass count \(passes) is not representable.")
        }
    }

    private static func floorLog2(_ value: Int) -> Int { Int.bitWidth - 1 - value.leadingZeroBitCount }

    /// Splits `count` passes starting at pass index `start` into the chunks
    /// whose lengths a packet header signals (B.10.7.2).
    static func segmentPassCounts(start: Int, count: Int, style: CodeBlockStyle) -> [Int] {
        var chunks: [Int] = []
        var index = start, remaining = count, current = 0
        while remaining > 0 {
            current += 1; remaining -= 1
            if style.passTerminates(index) || remaining == 0 { chunks.append(current); current = 0 }
            index += 1
        }
        return chunks
    }

    // MARK: - Decoding

    /// Per-precinct tag trees survive across layers.
    private struct PrecinctTrees {
        var inclusion: [TagTree]
        var msb: [TagTree]
    }

    /// Reads every packet of the tile. Returns contributions indexed
    /// `[resolution][precinct][band][block]` with codeword segments assembled
    /// across layers.
    static func decodePackets(geometry: TileGeometry, codingStyle cod: CodingStyleSegment,
                              bytes: [UInt8], range: Range<Int>,
                              cancellation: () throws -> Void) throws -> [[[[CodeBlockContribution]]]] {
        let style = CodeBlockStyle(bits: cod.codeBlockStyle)
        var result: [[[[CodeBlockContribution]]]] = geometry.resolutions.map { resolution in
            resolution.precincts.map { precinct in
                precinct.bands.map { [CodeBlockContribution](repeating: CodeBlockContribution(), count: $0.blocks.count) }
            }
        }
        var trees: [[PrecinctTrees]] = geometry.resolutions.map { resolution in
            resolution.precincts.map { precinct in
                PrecinctTrees(inclusion: precinct.bands.map { TagTree(width: $0.blocksWide, height: $0.blocksHigh) },
                              msb: precinct.bands.map { TagTree(width: $0.blocksWide, height: $0.blocksHigh) })
            }
        }
        var cursor = range.lowerBound
        let end = range.upperBound
        for address in try packetSequence(geometry: geometry, codingStyle: cod) {
            try cancellation()
            let resolution = geometry.resolutions[address.resolution]
            let precinct = resolution.precincts[address.precinct]
            if cursor >= end { break }   // a truncated tail: remaining packets are absent
            if cod.usesSOP, cursor + 6 <= end, bytes[cursor] == 0xFF, bytes[cursor + 1] == 0x91 { cursor += 6 }
            var reader = PacketBitReader(bytes: bytes, start: cursor, end: end)
            var order: [(band: Int, block: Int, chunks: [Int], lengths: [Int])] = []
            if try reader.readBit() {
                for (b, precinctBand) in precinct.bands.enumerated() where !precinctBand.blocks.isEmpty {
                    for k in 0..<precinctBand.blocks.count {
                        var state = result[address.resolution][address.precinct][b][k]
                        let included: Bool
                        if state.included {
                            included = try reader.readBit()
                        } else {
                            included = try trees[address.resolution][address.precinct].inclusion[b]
                                .decode(reader: &reader, leaf: k, threshold: Int32(address.layer + 1))
                        }
                        guard included else { continue }
                        let firstInclusion = !state.included
                        if firstInclusion {
                            var threshold: Int32 = 1
                            while try !trees[address.resolution][address.precinct].msb[b].decode(reader: &reader, leaf: k, threshold: threshold) {
                                threshold += 1
                                guard threshold <= 80 else { throw CodecError(.malformedInput, "Zero bit-plane count is not representable.") }
                            }
                            state.included = true
                            state.zeroBitPlanes = Int(trees[address.resolution][address.precinct].msb[b].value(leaf: k))
                            if style.ht && !style.htMixed {
                                state.isHT = true
                            }
                        }
                        let newPasses = try readPassCount(&reader)
                        while try reader.readBit() {
                            state.lblock += 1
                            guard state.lblock <= 40 else { throw CodecError(.malformedInput, "Lblock signalling is not representable.") }
                        }
                        let chunks = segmentPassCounts(start: state.passes, count: newPasses, style: style)
                        var lengths: [Int] = []
                        for (chunkIndex, chunk) in chunks.enumerated() {
                            let bitCount = state.lblock + floorLog2(chunk)
                            let length = try reader.readBits(bitCount)
                            if firstInclusion && chunkIndex == 0 && style.ht && style.htMixed {
                                // ISO/IEC 15444-15 Clause B.10.6: in mixed HT/Part 1 mode, an HT
                                // code-block signals lblock > 3 on first inclusion and has the MSB
                                // of its first length field equal to 0.
                                state.isHT = state.lblock > 3 && bitCount >= 1 && ((length >> (bitCount - 1)) == 0)
                            }
                            lengths.append(length)
                        }
                        order.append((b, k, chunks, lengths))
                        result[address.resolution][address.precinct][b][k] = state
                    }
                }
            }
            try reader.alignToByte()
            cursor = reader.position
            if cod.usesEPH {
                guard cursor + 2 <= end, bytes[cursor] == 0xFF, bytes[cursor + 1] == 0x92 else {
                    throw CodecError(.malformedInput, "EPH marker is missing after a packet header.")
                }
                cursor += 2
            }
            for entry in order {
                var state = result[address.resolution][address.precinct][entry.band][entry.block]
                for (chunk, length) in zip(entry.chunks, entry.lengths) {
                    guard cursor + length <= end else {
                        throw CodecError(.malformedInput, "Code-block data length exceeds the tile-part data.")
                    }
                    if state.isHT {
                        if state.segments.isEmpty || (length > 0 && !state.segments[state.segments.count - 1].data.isEmpty) {
                            state.segments.append(CodewordSegment())
                        }
                    } else {
                        let lastTerminated = state.passes == 0 || style.passTerminates(state.passes - 1)
                        if lastTerminated || state.segments.isEmpty { state.segments.append(CodewordSegment()) }
                    }
                    state.segments[state.segments.count - 1].data.append(contentsOf: bytes[cursor..<cursor + length])
                    state.segments[state.segments.count - 1].passes += chunk
                    state.passes += chunk
                    cursor += length
                }
                result[address.resolution][address.precinct][entry.band][entry.block] = state
            }
        }
        return result
    }

    // MARK: - Encoding (single layer, LRCP, default style)

    /// `encodings` is indexed `[resolution][precinct][band][block]`.
    static func encodePackets<Output: CodestreamByteSink & ~Copyable>(geometry: TileGeometry, encodings: [[[[CodeBlockEncoding]]]],
                              into out: inout Output, cancellation: () throws -> Void) throws {
        for resolution in geometry.resolutions {
            for (p, precinct) in resolution.precincts.enumerated() {
                try cancellation()
                var header = PacketBitWriter()
                let anyIncluded = precinct.bands.enumerated().contains { b, band in
                    band.blocks.indices.contains { encodings[resolution.index][p][b][$0].passCount > 0 }
                }
                header.writeBit(anyIncluded)
                if anyIncluded {
                    for (b, precinctBand) in precinct.bands.enumerated() where !precinctBand.blocks.isEmpty {
                        var inclusion = TagTree(width: precinctBand.blocksWide, height: precinctBand.blocksHigh)
                        var msb = TagTree(width: precinctBand.blocksWide, height: precinctBand.blocksHigh)
                        for k in 0..<precinctBand.blocks.count {
                            let encoding = encodings[resolution.index][p][b][k]
                            try inclusion.setValue(leaf: k, value: encoding.passCount > 0 ? 0 : 1)
                            try msb.setValue(leaf: k, value: Int32(encoding.zeroBitPlanes))
                        }
                        for k in 0..<precinctBand.blocks.count {
                            let encoding = encodings[resolution.index][p][b][k]
                            try inclusion.encode(writer: &header, leaf: k, threshold: 1)
                            guard encoding.passCount > 0 else { continue }
                            try msb.encode(writer: &header, leaf: k, threshold: Int32(encoding.zeroBitPlanes) + 1)
                            try writePassCount(encoding.passCount, &header)
                            var lblock = 3
                            let needed = max(1, Int.bitWidth - encoding.data.count.leadingZeroBitCount)
                            while lblock + floorLog2(encoding.passCount) < needed {
                                header.writeBit(true)
                                lblock += 1
                            }
                            header.writeBit(false)
                            header.writeBits(encoding.data.count, count: lblock + floorLog2(encoding.passCount))
                        }
                    }
                }
                try out.writeBytesChecked(header.finish())
                if anyIncluded {
                    for (b, precinctBand) in precinct.bands.enumerated() where !precinctBand.blocks.isEmpty {
                        for k in 0..<precinctBand.blocks.count {
                            let encoding = encodings[resolution.index][p][b][k]
                            if encoding.passCount > 0 {
                                try out.writeBytesChecked(encoding.data)
                            }
                        }
                    }
                }
            }
        }
    }
}
