// SPDX-License-Identifier: Apache-2.0
//
// Normative ITU-T T.808 (12/2022) | ISO/IEC 15444-9 Annex A data-bin indexer
// and codestream reconstructor for 2D JPEG 2000 Part 1 / Part 15 codestreams
// and JP2 containers.

import Foundation

/// One indexed 2D JPEG 2000 precinct data-bin (`Class 0`, ITU-T T.808 Annex A.3.2).
package struct JPIPIndexedPrecinct: Sendable {
    package let tileIndex: Int
    package let componentIndex: Int
    package let resolutionLevel: Int
    package let precinctInResolution: Int
    package let sequenceInTileComponent: Int
    package let inClassID: Int
    package let refX0: Int
    package let refY0: Int
    package let refX1: Int
    package let refY1: Int
    package let layerPackets: [Data]

    package var concatenatedData: Data {
        var total = 0
        for pkt in layerPackets { total += pkt.count }
        var out = Data()
        out.reserveCapacity(total)
        for pkt in layerPackets { out.append(pkt) }
        return out
    }
}

/// One indexed 2D JPEG 2000 tile (`Class 2` tile-header and `Class 4` tile data-bins).
package struct JPIPIndexedTile: Sendable {
    package let tileIndex: Int
    package let refX0: Int
    package let refY0: Int
    package let refX1: Int
    package let refY1: Int
    /// Marker segments strictly between `SOT` (12 bytes) and `SOD` (2 bytes), per ITU-T T.808 Annex A.3.3.
    package let tileHeaderMarkers: Data
    /// Complete concatenated tile-parts (`SOT` + header markers + `SOD` + packet bytes), per ITU-T T.808 Annex A.3.4.
    package let completeTilePartsData: Data
}

/// Complete JPIP data-bin index of a 2D `.j2k`/`.jph` codestream or `.jp2` container.
package struct JPIPIndexedCodestream: Sendable {
    package let width: Int
    package let height: Int
    package let originX: Int
    package let originY: Int
    package let tileCount: Int
    package let componentCount: Int
    package let maxDecompositionLevels: Int
    package let totalLayers: Int
    package let isReversibleLossless: Bool
    package let isHTJ2K: Bool
    package let mainHeader: Data
    package let jp2PrefixBeforeCodestream: Data?
    package let jp2SuffixAfterCodestream: Data?
    package let codestreamByteCount: Int
    package let tiles: [JPIPIndexedTile]
    package let precincts: [JPIPIndexedPrecinct]
}

package enum JPIPCodestreamIndexer {
    private static let jp2Signature: [UInt8] = [
        0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20, 0x0D, 0x0A, 0x87, 0x0A
    ]

    /// Extracts the raw JPEG 2000 codestream slice and optional JP2 prefix/suffix boxes.
    package static func splitContainer(_ fileData: Data) throws -> (
        codestream: [UInt8],
        jp2Prefix: Data?,
        jp2Suffix: Data?
    ) {
        let bytes = [UInt8](fileData)
        if bytes.count >= 2 && bytes[0] == 0xFF && bytes[1] == 0x4F {
            return (bytes, nil, nil)
        }
        guard bytes.count >= jp2Signature.count,
              Array(bytes[0..<jp2Signature.count]) == jp2Signature else {
            throw CodecError(.unsupportedFormat, "Input is neither a raw JPEG 2000 codestream nor a JP2 family container.")
        }

        var cursor = 0
        while cursor + 8 <= bytes.count {
            let lbox = Int(UInt32(bytes[cursor]) << 24
                | UInt32(bytes[cursor + 1]) << 16
                | UInt32(bytes[cursor + 2]) << 8
                | UInt32(bytes[cursor + 3]))
            let tbox = UInt32(bytes[cursor + 4]) << 24
                | UInt32(bytes[cursor + 5]) << 16
                | UInt32(bytes[cursor + 6]) << 8
                | UInt32(bytes[cursor + 7])

            let headerLen: Int
            let boxLen: Int
            if lbox == 0 {
                headerLen = 8
                boxLen = bytes.count - cursor
            } else if lbox == 1 {
                guard cursor + 16 <= bytes.count else {
                    throw CodecError(.malformedInput, "Truncated extended-length JP2 box header.")
                }
                var xl: UInt64 = 0
                for k in 8..<16 { xl = (xl << 8) | UInt64(bytes[cursor + k]) }
                guard xl >= 16, xl <= UInt64(bytes.count - cursor) else {
                    throw CodecError(.malformedInput, "Extended JP2 box length exceeds container bounds.")
                }
                headerLen = 16
                boxLen = Int(xl)
            } else {
                guard lbox >= 8, lbox <= bytes.count - cursor else {
                    throw CodecError(.malformedInput, "JP2 box length \(lbox) is invalid.")
                }
                headerLen = 8
                boxLen = lbox
            }

            // 'jp2c' == 0x6A703263
            if tbox == 0x6A70_3263 {
                let csStart = cursor + headerLen
                let csEnd = cursor + boxLen
                let prefix = Data(bytes[0..<cursor])
                let suffixEnd = bytes.count
                let suffix = csEnd < suffixEnd ? Data(bytes[csEnd..<suffixEnd]) : Data()
                return (Array(bytes[csStart..<csEnd]), prefix, suffix.isEmpty ? nil : suffix)
            }
            cursor += boxLen
        }
        throw CodecError(.malformedInput, "JP2 container does not contain a contiguous codestream ('jp2c') box.")
    }

    /// Scans raw tile-part ranges (`SOT`..end of tile-part) in a codestream.
    private struct RawTilePartSlice {
        let tileIndex: Int
        let partIndex: Int
        let sotStart: Int
        let headerMarkersRange: Range<Int>
        let dataRange: Range<Int>
        let partEnd: Int
    }

    private static func scanRawTileParts(_ bytes: [UInt8]) throws -> (firstSOT: Int, parts: [RawTilePartSlice]) {
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0x4F else {
            throw CodecError(.malformedInput, "Codestream does not start with SOC (0xFF4F).")
        }
        var cursor = 2
        var firstSOT: Int?
        while cursor + 2 <= bytes.count {
            let marker = UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1])
            if marker == Marker.sot {
                firstSOT = cursor
                break
            }
            if marker == Marker.eoc {
                throw CodecError(.malformedInput, "Codestream reached EOC before any SOT marker.")
            }
            cursor += 2
            if (0xFF30...0xFF3F).contains(marker) {
                continue
            }
            guard cursor + 2 <= bytes.count else {
                throw CodecError(.malformedInput, "Truncated main-header marker segment.")
            }
            let segLen = Int(UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1]))
            guard segLen >= 2, cursor + segLen <= bytes.count else {
                throw CodecError(.malformedInput, "Main-header marker segment length exceeds codestream bounds.")
            }
            cursor += segLen
        }

        guard let mainHeaderEnd = firstSOT else {
            throw CodecError(.malformedInput, "Codestream contains no SOT marker.")
        }

        var parts: [RawTilePartSlice] = []
        cursor = mainHeaderEnd
        while cursor + 2 <= bytes.count {
            let marker = UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1])
            if marker == Marker.eoc {
                break
            }
            guard marker == Marker.sot else {
                throw CodecError(.malformedInput, String(format: "Expected SOT (0xFF90) at offset %d, found 0x%04X.", cursor, marker))
            }
            guard cursor + 12 <= bytes.count else {
                throw CodecError(.malformedInput, "Truncated SOT marker segment.")
            }
            let lsot = Int(UInt16(bytes[cursor + 2]) << 8 | UInt16(bytes[cursor + 3]))
            guard lsot == 10 else {
                throw CodecError(.malformedInput, "SOT Lsot must be 10, found \(lsot).")
            }
            let isot = Int(UInt16(bytes[cursor + 4]) << 8 | UInt16(bytes[cursor + 5]))
            let psot = UInt32(bytes[cursor + 6]) << 24
                | UInt32(bytes[cursor + 7]) << 16
                | UInt32(bytes[cursor + 8]) << 8
                | UInt32(bytes[cursor + 9])
            let tpsot = Int(bytes[cursor + 10])
            let sotStart = cursor

            let partEnd: Int
            if psot == 0 {
                if bytes.count >= 2 && bytes[bytes.count - 2] == 0xFF && bytes[bytes.count - 1] == 0xD9 {
                    partEnd = bytes.count - 2
                } else {
                    partEnd = bytes.count
                }
            } else {
                guard psot >= 14, UInt64(sotStart) + UInt64(psot) <= UInt64(bytes.count) else {
                    throw CodecError(.malformedInput, "SOT Psot \(psot) is invalid or exceeds codestream bounds.")
                }
                partEnd = sotStart + Int(psot)
            }

            var hdrCursor = sotStart + 12
            var sodPos: Int?
            while hdrCursor + 2 <= partEnd {
                let m = UInt16(bytes[hdrCursor]) << 8 | UInt16(bytes[hdrCursor + 1])
                if m == Marker.sod {
                    sodPos = hdrCursor
                    break
                }
                hdrCursor += 2
                if (0xFF30...0xFF3F).contains(m) {
                    continue
                }
                guard hdrCursor + 2 <= partEnd else {
                    throw CodecError(.malformedInput, "Truncated tile-part header marker segment.")
                }
                let segLen = Int(UInt16(bytes[hdrCursor]) << 8 | UInt16(bytes[hdrCursor + 1]))
                guard segLen >= 2, hdrCursor + segLen <= partEnd else {
                    throw CodecError(.malformedInput, "Tile-part header marker length exceeds tile-part bounds.")
                }
                hdrCursor += segLen
            }
            guard let foundSOD = sodPos, foundSOD + 2 <= partEnd else {
                throw CodecError(.malformedInput, "Tile-part is missing SOD (0xFF93).")
            }

            parts.append(
                RawTilePartSlice(
                    tileIndex: isot,
                    partIndex: tpsot,
                    sotStart: sotStart,
                    headerMarkersRange: (sotStart + 12)..<foundSOD,
                    dataRange: (foundSOD + 2)..<partEnd,
                    partEnd: partEnd
                )
            )
            cursor = partEnd
        }

        return (mainHeaderEnd, parts)
    }

    /// Indexes a 2D `.j2k`/`.jph` codestream or `.jp2` container into normative ITU-T T.808 data-bins.
    package static func index(
        _ fileData: Data,
        limits: ResourceLimits = .default
    ) throws -> JPIPIndexedCodestream {
        let (bytes, jp2Prefix, jp2Suffix) = try splitContainer(fileData)
        guard bytes.count <= limits.maximumCompressedBytes else {
            throw CodecError(.resourceLimitExceeded, "Codestream exceeds maximumCompressedBytes.")
        }

        let (firstSOT, rawParts) = try scanRawTileParts(bytes)
        let mainHeader = Data(bytes[0..<firstSOT])
        let parsed = try CodestreamSyntax.parse(bytes, limits: limits, metadataPolicy: .preserve)
        let size = parsed.size

        let tilesWide = Wavelet53.ceilDiv(size.width - size.tileOriginX, size.tileWidth)
        let tilesHigh = Wavelet53.ceilDiv(size.height - size.tileOriginY, size.tileHeight)
        let totalTiles = tilesWide * tilesHigh
        let componentCount = size.components.count

        var rawPartsByTile: [Int: [RawTilePartSlice]] = [:]
        for part in rawParts {
            rawPartsByTile[part.tileIndex, default: []].append(part)
        }

        var indexedTiles: [JPIPIndexedTile] = []
        indexedTiles.reserveCapacity(totalTiles)
        var indexedPrecincts: [JPIPIndexedPrecinct] = []

        var maxDecomp = 0
        var maxLayers = 1
        var allReversibleLossless = true

        for tileIdx in 0..<totalTiles {
            let tx = tileIdx % tilesWide
            let ty = tileIdx / tilesWide
            let refX0 = max(size.tileOriginX + tx * size.tileWidth, size.originX)
            let refY0 = max(size.tileOriginY + ty * size.tileHeight, size.originY)
            let refX1 = min(size.tileOriginX + (tx + 1) * size.tileWidth, size.width)
            let refY1 = min(size.tileOriginY + (ty + 1) * size.tileHeight, size.height)

            let sortedParts = (rawPartsByTile[tileIdx] ?? []).sorted { $0.partIndex < $1.partIndex }
            var thMarkers = Data()
            var fullTileParts = Data()
            var concatenatedBitstream: [UInt8] = []
            for p in sortedParts {
                thMarkers.append(contentsOf: bytes[p.headerMarkersRange])
                fullTileParts.append(contentsOf: bytes[p.sotStart..<p.partEnd])
                concatenatedBitstream.append(contentsOf: bytes[p.dataRange])
            }

            indexedTiles.append(
                JPIPIndexedTile(
                    tileIndex: tileIdx,
                    refX0: refX0,
                    refY0: refY0,
                    refX1: refX1,
                    refY1: refY1,
                    tileHeaderMarkers: thMarkers,
                    completeTilePartsData: fullTileParts
                )
            )

            guard !sortedParts.isEmpty else { continue }
            var geometries: [TileGeometry] = []
            var codingStyles: [CodingStyleSegment] = []
            geometries.reserveCapacity(componentCount)
            codingStyles.reserveCapacity(componentCount)
            for c in 0..<componentCount {
                let comp = size.components[c]
                let (cod, qcd) = parsed.effectiveParameters(tile: tileIdx, component: c)
                if !cod.reversible || qcd.style != .none {
                    allReversibleLossless = false
                }
                let tcx0 = Wavelet53.ceilDiv(refX0, comp.horizontalSeparation)
                let tcy0 = Wavelet53.ceilDiv(refY0, comp.verticalSeparation)
                let tcx1 = Wavelet53.ceilDiv(refX1, comp.horizontalSeparation)
                let tcy1 = Wavelet53.ceilDiv(refY1, comp.verticalSeparation)
                let geom = try Tier2.makeTileGeometry(x0: tcx0, x1: tcx1, y0: tcy0, y1: tcy1, codingStyle: cod)
                geometries.append(geom)
                codingStyles.append(cod)
            }
            let baseCOD = parsed.tileOverrides[tileIdx]?.codingStyle ?? parsed.baseCodingStyle
            let tilePOC = parsed.effectiveProgressionChanges(tile: tileIdx)
            maxLayers = max(maxLayers, baseCOD.layers)
            for cs in codingStyles {
                maxDecomp = max(maxDecomp, cs.decompositionLevels)
            }

            // Compute cumulative precinct sequence offset per (component, resolution)
            var seqOffsets: [[Int]] = []
            seqOffsets.reserveCapacity(componentCount)
            for c in 0..<componentCount {
                var offsets: [Int] = []
                var acc = 0
                for res in geometries[c].resolutions {
                    offsets.append(acc)
                    acc += res.precincts.count
                }
                seqOffsets.append(offsets)
            }

            // Slice every packet in progression order
            let styles = codingStyles.map { CodeBlockStyle(bits: $0.codeBlockStyle) }
            var wireState: [[[[[CodeBlockContribution]]]]] = geometries.map { geom in
                geom.resolutions.map { resolution in
                    resolution.precincts.map { precinct in
                        precinct.bands.map {
                            [CodeBlockContribution](repeating: CodeBlockContribution(), count: $0.blocks.count)
                        }
                    }
                }
            }
            var trees: [[[Tier2.PrecinctTrees]]] = geometries.map { geom in
                geom.resolutions.map { resolution in
                    resolution.precincts.map { precinct in
                        Tier2.PrecinctTrees(
                            inclusion: precinct.bands.map { TagTree(width: $0.blocksWide, height: $0.blocksHigh) },
                            msb: precinct.bands.map { TagTree(width: $0.blocksWide, height: $0.blocksHigh) }
                        )
                    }
                }
            }

            // Store per [c][r][p][l]
            var perPrecinctLayerPackets: [[[[Data]]]] = geometries.map { geom in
                geom.resolutions.map { res in
                    Array(repeating: [Data](repeating: Data(), count: baseCOD.layers), count: res.precincts.count)
                }
            }

            let sequence = try Tier2.multiComponentPacketSequence(
                geometries: geometries,
                codingStyle: baseCOD,
                progressionChanges: tilePOC
            )

            var cursor = 0
            let end = concatenatedBitstream.count
            for address in sequence {
                if cursor >= end { break }
                let packetStart = cursor
                let c = address.component
                let r = address.resolution
                let p = address.precinct
                let style = styles[c]
                let precinct = geometries[c].resolutions[r].precincts[p]

                if baseCOD.usesSOP, cursor + 6 <= end,
                   concatenatedBitstream[cursor] == 0xFF, concatenatedBitstream[cursor + 1] == 0x91 {
                    cursor += 6
                }
                var reader = PacketBitReader(bytes: concatenatedBitstream, start: cursor, end: end)
                var bodyLength = 0
                if try reader.readBit() {
                    for (b, precinctBand) in precinct.bands.enumerated() where !precinctBand.blocks.isEmpty {
                        for k in 0..<precinctBand.blocks.count {
                            var state = wireState[c][r][p][b][k]
                            let included: Bool
                            if state.included {
                                included = try reader.readBit()
                            } else {
                                included = try trees[c][r][p].inclusion[b]
                                    .decode(reader: &reader, leaf: k, threshold: Int32(address.layer + 1))
                            }
                            guard included else { continue }
                            let firstInclusion = !state.included
                            if firstInclusion {
                                var threshold: Int32 = 1
                                while try !trees[c][r][p].msb[b].decode(reader: &reader, leaf: k, threshold: threshold) {
                                    threshold += 1
                                    guard threshold <= 80 else {
                                        throw CodecError(.malformedInput, "Zero bit-plane count is not representable.")
                                    }
                                }
                                state.included = true
                                state.zeroBitPlanes = Int(trees[c][r][p].msb[b].value(leaf: k))
                                if style.ht && !style.htMixed { state.isHT = true }
                            }
                            let newPasses = try Tier2.readPassCount(&reader)
                            while try reader.readBit() {
                                state.lblock += 1
                                guard state.lblock <= 40 else {
                                    throw CodecError(.malformedInput, "Lblock signalling is not representable.")
                                }
                            }
                            let chunks = Tier2.segmentPassCounts(start: state.passes, count: newPasses, style: style)
                            for (chunkIndex, chunk) in chunks.enumerated() {
                                let bitCount = state.lblock + Tier2.floorLog2(chunk)
                                let length = try reader.readBits(bitCount)
                                if firstInclusion && chunkIndex == 0 && style.ht && style.htMixed {
                                    state.isHT = state.lblock > 3 && bitCount >= 1 && ((length >> (bitCount - 1)) == 0)
                                }
                                bodyLength = try checkedAdd(bodyLength, length)
                                state.passes += chunk
                            }
                            wireState[c][r][p][b][k] = state
                        }
                    }
                }
                try reader.alignToByte()
                cursor = reader.position
                if baseCOD.usesEPH {
                    guard cursor + 2 <= end,
                          concatenatedBitstream[cursor] == 0xFF,
                          concatenatedBitstream[cursor + 1] == 0x92 else {
                        throw CodecError(.malformedInput, "Missing EPH marker after packet header.")
                    }
                    cursor += 2
                }
                guard cursor + bodyLength <= end else {
                    throw CodecError(.malformedInput, "Packet body exceeds tile-part bitstream bounds.")
                }
                cursor += bodyLength
                perPrecinctLayerPackets[c][r][p][address.layer] = Data(concatenatedBitstream[packetStart..<cursor])
            }

            // Build JPIPIndexedPrecinct records with reference-grid bounding boxes
            for c in 0..<componentCount {
                let comp = size.components[c]
                let geom = geometries[c]
                let levels = geom.levels
                for r in 0..<geom.resolutions.count {
                    let res = geom.resolutions[r]
                    let shift = levels - r
                    let firstPX = Wavelet53.floorDiv(res.x0, 1 << res.ppx)
                    let firstPY = Wavelet53.floorDiv(res.y0, 1 << res.ppy)
                    for p in 0..<res.precincts.count {
                        let px = res.precinctsWide > 0 ? (p % res.precinctsWide) : 0
                        let py = res.precinctsWide > 0 ? (p / res.precinctsWide) : 0
                        let rx0 = max(res.x0, (firstPX + px) << res.ppx)
                        let ry0 = max(res.y0, (firstPY + py) << res.ppy)
                        let rx1 = min(res.x1, (firstPX + px + 1) << res.ppx)
                        let ry1 = min(res.y1, (firstPY + py + 1) << res.ppy)
                        let gx0 = max(refX0, (rx0 << shift) * comp.horizontalSeparation)
                        let gy0 = max(refY0, (ry0 << shift) * comp.verticalSeparation)
                        let gx1 = min(refX1, (rx1 << shift) * comp.horizontalSeparation)
                        let gy1 = min(refY1, (ry1 << shift) * comp.verticalSeparation)

                        let s = seqOffsets[c][r] + p
                        let inClassID = tileIdx + (c + s * componentCount) * totalTiles
                        indexedPrecincts.append(
                            JPIPIndexedPrecinct(
                                tileIndex: tileIdx,
                                componentIndex: c,
                                resolutionLevel: r,
                                precinctInResolution: p,
                                sequenceInTileComponent: s,
                                inClassID: inClassID,
                                refX0: gx0,
                                refY0: gy0,
                                refX1: gx1,
                                refY1: gy1,
                                layerPackets: perPrecinctLayerPackets[c][r][p]
                            )
                        )
                    }
                }
            }
        }

        return JPIPIndexedCodestream(
            width: size.width,
            height: size.height,
            originX: size.originX,
            originY: size.originY,
            tileCount: totalTiles,
            componentCount: componentCount,
            maxDecompositionLevels: maxDecomp,
            totalLayers: maxLayers,
            isReversibleLossless: allReversibleLossless,
            isHTJ2K: parsed.isHTJ2K,
            mainHeader: mainHeader,
            jp2PrefixBeforeCodestream: jp2Prefix,
            jp2SuffixAfterCodestream: jp2Suffix,
            codestreamByteCount: bytes.count,
            tiles: indexedTiles,
            precincts: indexedPrecincts
        )
    }

    /// Reconstructs a valid, decodable JPEG 2000 codestream from normative JPP data-bins
    /// (`Class 6` main header, `Class 2` tile headers, and `Class 0` precinct data-bins),
    /// handling partial/truncated precincts, spatial ROI subsets, resolution subsets, and all
    /// 5 progression orders (`LRCP`, `RLCP`, `RPCL`, `PCRL`, `CPRL`).
    package static func reassembleJPP(
        mainHeader: Data,
        tileHeaders: [Int: Data],
        precinctBins: [Int: Data],
        limits: ResourceLimits = .default,
        workspaceObserver: (@Sendable (Int) -> Void)? = nil
    ) throws -> Data {
        // The caller accounts for its retained data-bins. Admit every additional
        // allocation here, including the probe while the parser owns its metadata.
        let fixedScratch = 4096
        var headerBytes = 0
        for (tid, header) in tileHeaders {
            guard (0...65_535).contains(tid) else {
                throw CodecError(.malformedInput, "Tile-header data-bin identifier is not representable.")
            }
            headerBytes = try checkedAdd(headerBytes, header.count)
            guard try checkedAdd(14, header.count) <= Int(UInt32.max) else {
                throw CodecError(.resourceLimitExceeded, "Reassembled tile-part header is too large.")
            }
        }
        var precinctBytes = 0
        var largestPrecinctBin = 0
        for (id, bin) in precinctBins {
            guard id >= 0 else { throw CodecError(.malformedInput, "Negative precinct data-bin identifier.") }
            precinctBytes = try checkedAdd(precinctBytes, bin.count)
            largestPrecinctBin = max(largestPrecinctBin, bin.count)
        }
        let inputBytes = try checkedAdd(mainHeader.count, try checkedAdd(headerBytes, precinctBytes))
        guard inputBytes <= limits.maximumCompressedBytes else {
            throw CodecError(.resourceLimitExceeded, "Reassembly data-bins exceed maximumCompressedBytes.")
        }
        let probeTiles = try checkedAdd(tileHeaders.count, tileHeaders[0] == nil ? 1 : 0)
        let probeBytes = try checkedAdd(mainHeader.count,
            try checkedAdd(headerBytes, try checkedAdd(try checkedMultiply(probeTiles, 14), 2)))
        let probeAllocation = try checkedAdd(probeBytes, fixedScratch)
        guard probeBytes <= limits.maximumCompressedBytes,
              probeAllocation <= limits.maximumWorkspaceBytes,
              probeAllocation <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Reassembly header probe exceeds the live-storage budget.")
        }
        var peakWorkspace = probeAllocation
        workspaceObserver?(peakWorkspace)
        StorageTelemetry.recordStage("jpip-reassembly-probe", bytes: probeAllocation)
        var probe: [UInt8] = []
        probe.reserveCapacity(probeBytes)
        probe.append(contentsOf: mainHeader)
        func appendProbeTile(_ tid: Int, _ header: Data) {
            let psot = UInt32(14 + header.count)
            probe.append(contentsOf: [
                0xFF, 0x90, 0x00, 0x0A,
                UInt8((tid >> 8) & 0xFF), UInt8(tid & 0xFF),
                UInt8((psot >> 24) & 0xFF), UInt8((psot >> 16) & 0xFF),
                UInt8((psot >> 8) & 0xFF), UInt8(psot & 0xFF),
                0x00, 0x01
            ])
            probe.append(contentsOf: header)
            probe.append(contentsOf: [0xFF, 0x93])
        }
        appendProbeTile(0, tileHeaders[0] ?? Data())
        for (tid, header) in tileHeaders where tid != 0 { appendProbeTile(tid, header) }
        probe.append(contentsOf: [0xFF, 0xD9])

        // parse already charges its input against memory; reserve the fixed
        // scratch there, and the complete probe storage against parser workspace.
        let parserLimits = try limits.reserving(workspaceBytes: probeAllocation, memoryBytes: fixedScratch)
        let parsed = try CodestreamSyntax.parse(probe, limits: parserLimits, metadataPolicy: .preserve)
        // Parser admission has bounded the probe plus every retained/transient
        // structure. The final retained tally plus one whole-probe-sized marker
        // scratch is a conservative upper bound, capped by that admitted limit.
        peakWorkspace = max(peakWorkspace, min(limits.maximumWorkspaceBytes,
            min(limits.maximumMemoryBytes, try checkedAdd(probeAllocation,
                try checkedAdd(parsed.retainedMetadataBytes, probeAllocation)))))
        workspaceObserver?(peakWorkspace)
        probe = []
        let size = parsed.size
        let tilesWide = Wavelet53.ceilDiv(size.width - size.tileOriginX, size.tileWidth)
        let tilesHigh = Wavelet53.ceilDiv(size.height - size.tileOriginY, size.tileHeight)
        let totalTiles = try checkedMultiply(tilesWide, tilesHigh)
        let componentCount = size.components.count
        guard totalTiles > 0, totalTiles <= 65_536, tileHeaders.keys.allSatisfy({ $0 < totalTiles }) else {
            throw CodecError(.malformedInput, "Tile-header data-bin lies outside the image tile grid.")
        }

        func admit(_ bytes: Int) throws {
            guard bytes <= limits.maximumWorkspaceBytes, bytes <= limits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "JPIP reconstruction exceeds the live-storage budget.")
            }
        }
        // The scalar geometry preflight itself has only small fixed band records.
        try admit(try checkedAdd(parsed.retainedMetadataBytes, fixedScratch))
        var maximumTileScratch = 0
        var outputBound = try checkedAdd(mainHeader.count,
            try checkedAdd(headerBytes, try checkedAdd(try checkedMultiply(totalTiles, 14), 2)))
        for tileIdx in 0..<totalTiles {
            let tx = tileIdx % tilesWide, ty = tileIdx / tilesWide
            let tx0 = max(size.tileOriginX + tx * size.tileWidth, size.originX)
            let ty0 = max(size.tileOriginY + ty * size.tileHeight, size.originY)
            let tx1 = min(size.tileOriginX + (tx + 1) * size.tileWidth, size.width)
            let ty1 = min(size.tileOriginY + (ty + 1) * size.tileHeight, size.height)
            let cod = parsed.tileOverrides[tileIdx]?.codingStyle ?? parsed.baseCodingStyle
            var tileGeometry = try checkedMultiply(componentCount,
                MemoryLayout<TileGeometry>.stride + MemoryLayout<CodingStyleSegment>.stride + 128)
            var tileDecodeState = 0
            var tilePrecincts = 0
            var tileResolutions = 0
            var positionCount = 0
            for c in 0..<componentCount {
                let comp = size.components[c]
                let (style, _) = parsed.effectiveParameters(tile: tileIdx, component: c)
                let x0 = Wavelet53.ceilDiv(tx0, comp.horizontalSeparation)
                let y0 = Wavelet53.ceilDiv(ty0, comp.verticalSeparation)
                let x1 = Wavelet53.ceilDiv(tx1, comp.horizontalSeparation)
                let y1 = Wavelet53.ceilDiv(ty1, comp.verticalSeparation)
                let footprint = try Tier2.preflightTileGeometry(x0: x0, x1: x1, y0: y0, y1: y1, codingStyle: style)
                tileGeometry = try checkedAdd(tileGeometry, footprint.geometryBytes)
                tileDecodeState = try checkedAdd(tileDecodeState, footprint.decodeStateBytes)
                tilePrecincts = try checkedAdd(tilePrecincts, footprint.precinctCount)
                tileResolutions = try checkedAdd(tileResolutions, footprint.resolutionCount)
                // Spatial progressions materialise x/y positions. A unit step is
                // the conservative bound, including differing component grids.
                positionCount = try checkedAdd(positionCount, try checkedAdd(x1, y1))
            }
            let packets = try checkedMultiply(tilePrecincts, cod.layers)
            let layerStorage = try checkedAdd(try checkedMultiply(packets, MemoryLayout<Data?>.stride + 32),
                try checkedMultiply(try checkedAdd(tilePrecincts, tileResolutions), 64))
            // Sequence + de-duplication Set, with old/new capacity during growth;
            // spatial progressions additionally retain a precinct Set and positions.
            let sequenceStorage = try checkedAdd(
                try checkedMultiply(packets, 8 * MemoryLayout<Tier2.ComponentPacketAddress>.stride + 64),
                try checkedAdd(try checkedMultiply(tilePrecincts, 128), try checkedMultiply(positionCount, 32)))
            var tileInput = 0
            for (id, bin) in precinctBins where id % totalTiles == tileIdx {
                tileInput = try checkedAdd(tileInput, bin.count)
            }
            let packetOverhead = 1 + (cod.usesSOP ? 6 : 0) + (cod.usesEPH ? 2 : 0)
            let tileOutputBound = try checkedAdd(tileInput, try checkedMultiply(packets, packetOverhead))
            guard try checkedAdd(tileOutputBound, try checkedAdd(tileHeaders[tileIdx]?.count ?? 0, 14)) <= Int(UInt32.max) else {
                throw CodecError(.resourceLimitExceeded, "Reassembled tile-part exceeds its representable length.")
            }
            outputBound = try checkedAdd(outputBound, tileOutputBound)
            let tileScratch = try checkedAdd(tileGeometry, try checkedAdd(tileDecodeState,
                try checkedAdd(layerStorage, try checkedAdd(sequenceStorage,
                    try checkedAdd(tileInput, try checkedMultiply(tileOutputBound, 3))))))
            maximumTileScratch = max(maximumTileScratch, tileScratch)
        }
        // Final output remains live alongside packet slices, raw-bin parsing,
        // packet order, and the growing tile buffer (old + new capacities).
        let reconstructionPeak = try checkedAdd(parsed.retainedMetadataBytes,
            try checkedAdd(fixedScratch, try checkedAdd(largestPrecinctBin,
                try checkedAdd(outputBound, maximumTileScratch))))
        try admit(reconstructionPeak)
        peakWorkspace = max(peakWorkspace, reconstructionPeak)
        workspaceObserver?(peakWorkspace)
        StorageTelemetry.recordStage("jpip-reassembly-peak", bytes: reconstructionPeak)
        StorageTelemetry.recordStage("jpip-reassembly-output", bytes: outputBound)
        var out = Data()
        out.reserveCapacity(outputBound)
        out.append(mainHeader)

        for tileIdx in 0..<totalTiles {
            let tx = tileIdx % tilesWide
            let ty = tileIdx / tilesWide
            let tx0 = max(size.tileOriginX + tx * size.tileWidth, size.originX)
            let ty0 = max(size.tileOriginY + ty * size.tileHeight, size.originY)
            let tx1 = min(size.tileOriginX + (tx + 1) * size.tileWidth, size.width)
            let ty1 = min(size.tileOriginY + (ty + 1) * size.tileHeight, size.height)

            let thData = tileHeaders[tileIdx] ?? Data()

            // All nested geometry, layer arrays and sequence storage were admitted above.
            StorageTelemetry.recordStage("jpip-reassembly-geometry", bytes: maximumTileScratch)
            var geometries: [TileGeometry] = []
            var codingStyles: [CodingStyleSegment] = []
            geometries.reserveCapacity(componentCount)
            codingStyles.reserveCapacity(componentCount)
            for c in 0..<componentCount {
                let comp = size.components[c]
                let (cod, _) = parsed.effectiveParameters(tile: tileIdx, component: c)
                let tcx0 = Wavelet53.ceilDiv(tx0, comp.horizontalSeparation)
                let tcy0 = Wavelet53.ceilDiv(ty0, comp.verticalSeparation)
                let tcx1 = Wavelet53.ceilDiv(tx1, comp.horizontalSeparation)
                let tcy1 = Wavelet53.ceilDiv(ty1, comp.verticalSeparation)
                let geom = try Tier2.makeTileGeometry(x0: tcx0, x1: tcx1, y0: tcy0, y1: tcy1, codingStyle: cod)
                geometries.append(geom)
                codingStyles.append(cod)
            }
            let baseCOD = parsed.tileOverrides[tileIdx]?.codingStyle ?? parsed.baseCodingStyle
            let poc = parsed.effectiveProgressionChanges(tile: tileIdx)

            // Compute sequence offsets and slice each present precinct bin into per-layer packets
            var perPrecinctLayerPackets: [[[[Data?]]]] = []
            perPrecinctLayerPackets.reserveCapacity(componentCount)
            var anyPrecinctPresentInTile = false

            for c in 0..<componentCount {
                let geom = geometries[c]
                let style = CodeBlockStyle(bits: codingStyles[c].codeBlockStyle)
                var compLayers: [[[Data?]]] = []
                compLayers.reserveCapacity(geom.resolutions.count)
                var seqBase = 0

                for r in 0..<geom.resolutions.count {
                    let res = geom.resolutions[r]
                    var resLayers: [[Data?]] = []
                    resLayers.reserveCapacity(res.precincts.count)

                    for p in 0..<res.precincts.count {
                        let s = seqBase + p
                        let inClassID = tileIdx + (c + s * componentCount) * totalTiles
                        var layerSlices = [Data?](repeating: nil, count: baseCOD.layers)

                        if let rawBin = precinctBins[inClassID], !rawBin.isEmpty {
                            anyPrecinctPresentInTile = true
                            let binBytes = [UInt8](rawBin)
                            let precinct = res.precincts[p]
                            var blocksState: [[CodeBlockContribution]] = precinct.bands.map {
                                [CodeBlockContribution](repeating: CodeBlockContribution(), count: $0.blocks.count)
                            }
                            var trees = Tier2.PrecinctTrees(
                                inclusion: precinct.bands.map { TagTree(width: $0.blocksWide, height: $0.blocksHigh) },
                                msb: precinct.bands.map { TagTree(width: $0.blocksWide, height: $0.blocksHigh) }
                            )

                            var pCursor = 0
                            let pEnd = binBytes.count
                            layerLoop: for layer in 0..<baseCOD.layers {
                                if pCursor >= pEnd { break }
                                let pktStart = pCursor
                                do {
                                    if baseCOD.usesSOP {
                                        if pCursor + 6 <= pEnd,
                                           binBytes[pCursor] == 0xFF, binBytes[pCursor + 1] == 0x91 {
                                            pCursor += 6
                                        }
                                    }
                                    var reader = PacketBitReader(bytes: binBytes, start: pCursor, end: pEnd)
                                    var bodyLen = 0
                                    if try reader.readBit() {
                                        for (b, precinctBand) in precinct.bands.enumerated() where !precinctBand.blocks.isEmpty {
                                            for k in 0..<precinctBand.blocks.count {
                                                var st = blocksState[b][k]
                                                let included: Bool
                                                if st.included {
                                                    included = try reader.readBit()
                                                } else {
                                                    included = try trees.inclusion[b]
                                                        .decode(reader: &reader, leaf: k, threshold: Int32(layer + 1))
                                                }
                                                guard included else { continue }
                                                let firstInc = !st.included
                                                if firstInc {
                                                    var thresh: Int32 = 1
                                                    while try !trees.msb[b].decode(reader: &reader, leaf: k, threshold: thresh) {
                                                        thresh += 1
                                                        guard thresh <= 80 else {
                                                            throw CodecError(.malformedInput, "Invalid zero bit-planes.")
                                                        }
                                                    }
                                                    st.included = true
                                                    st.zeroBitPlanes = Int(trees.msb[b].value(leaf: k))
                                                    if style.ht && !style.htMixed { st.isHT = true }
                                                }
                                                let newPasses = try Tier2.readPassCount(&reader)
                                                while try reader.readBit() {
                                                    st.lblock += 1
                                                    guard st.lblock <= 40 else {
                                                        throw CodecError(.malformedInput, "Invalid Lblock.")
                                                    }
                                                }
                                                let chunks = Tier2.segmentPassCounts(
                                                    start: st.passes, count: newPasses, style: style
                                                )
                                                for (ci, chunk) in chunks.enumerated() {
                                                    let bc = st.lblock + Tier2.floorLog2(chunk)
                                                    let segLen = try reader.readBits(bc)
                                                    if firstInc && ci == 0 && style.ht && style.htMixed {
                                                        st.isHT = st.lblock > 3 && bc >= 1 && ((segLen >> (bc - 1)) == 0)
                                                    }
                                                    bodyLen = try checkedAdd(bodyLen, segLen)
                                                    st.passes += chunk
                                                }
                                                blocksState[b][k] = st
                                            }
                                        }
                                    }
                                    try reader.alignToByte()
                                    var afterHeader = reader.position
                                    if baseCOD.usesEPH {
                                        guard afterHeader + 2 <= pEnd,
                                              binBytes[afterHeader] == 0xFF,
                                              binBytes[afterHeader + 1] == 0x92 else {
                                            break layerLoop
                                        }
                                        afterHeader += 2
                                    }
                                    guard afterHeader + bodyLen <= pEnd else {
                                        // Truncated mid-packet by len= byte limit; discard incomplete trailing packet.
                                        break layerLoop
                                    }
                                    pCursor = afterHeader + bodyLen
                                    layerSlices[layer] = Data(binBytes[pktStart..<pCursor])
                                } catch {
                                    // Truncated mid-header by len= byte limit; stop at last complete packet.
                                    break layerLoop
                                }
                            }
                        }
                        resLayers.append(layerSlices)
                    }
                    seqBase += res.precincts.count
                    compLayers.append(resLayers)
                }
                perPrecinctLayerPackets.append(compLayers)
            }

            if !anyPrecinctPresentInTile && tileHeaders[tileIdx] == nil {
                // Omitted tile: emit valid 14-byte empty tile-part (SOT + SOD)
                guard try checkedAdd(out.count, 16) <= limits.maximumCompressedBytes else {
                    throw CodecError(.resourceLimitExceeded, "Reassembled codestream exceeds maximumCompressedBytes.")
                }
                let psot: UInt32 = 14
                out.append(contentsOf: [
                    0xFF, 0x90, 0x00, 0x0A,
                    UInt8((tileIdx >> 8) & 0xFF), UInt8(tileIdx & 0xFF),
                    UInt8((psot >> 24) & 0xFF), UInt8((psot >> 16) & 0xFF),
                    UInt8((psot >> 8) & 0xFF), UInt8(psot & 0xFF),
                    0x00, 0x01,
                    0xFF, 0x93
                ])
                continue
            }

            let sequence = try Tier2.multiComponentPacketSequence(
                geometries: geometries,
                codingStyle: baseCOD,
                progressionChanges: poc
            )

            var tileInputBytes = 0
            for (id, bin) in precinctBins where id % totalTiles == tileIdx {
                tileInputBytes = try checkedAdd(tileInputBytes, bin.count)
            }
            let tileAssemblyBound = try checkedAdd(tileInputBytes,
                try checkedMultiply(sequence.count, 1 + (baseCOD.usesSOP ? 6 : 0) + (baseCOD.usesEPH ? 2 : 0)))
            var tileBitstream = Data()
            tileBitstream.reserveCapacity(tileAssemblyBound)
            var sopSeq: UInt16 = 0
            for address in sequence {
                if let pkt = perPrecinctLayerPackets[address.component][address.resolution][address.precinct][address.layer] {
                    if baseCOD.usesSOP, pkt.count >= 6, pkt[pkt.startIndex] == 0xFF, pkt[pkt.startIndex + 1] == 0x91 {
                        // Rewrite SOP sequence number in tile-part progression order
                        tileBitstream.append(contentsOf: [
                            0xFF, 0x91, 0x00, 0x04,
                            UInt8((sopSeq >> 8) & 0xFF), UInt8(sopSeq & 0xFF)
                        ])
                        tileBitstream.append(pkt.dropFirst(6))
                    } else {
                        if baseCOD.usesSOP {
                            tileBitstream.append(contentsOf: [
                                0xFF, 0x91, 0x00, 0x04,
                                UInt8((sopSeq >> 8) & 0xFF), UInt8(sopSeq & 0xFF)
                            ])
                        }
                        tileBitstream.append(pkt)
                    }
                } else {
                    if baseCOD.usesSOP {
                        tileBitstream.append(contentsOf: [
                            0xFF, 0x91, 0x00, 0x04,
                            UInt8((sopSeq >> 8) & 0xFF), UInt8(sopSeq & 0xFF)
                        ])
                    }
                    tileBitstream.append(0x00)
                    if baseCOD.usesEPH {
                        tileBitstream.append(contentsOf: [0xFF, 0x92])
                    }
                }
                sopSeq &+= 1
            }

            let totalPartLen = try checkedAdd(14, try checkedAdd(thData.count, tileBitstream.count))
            guard totalPartLen <= Int(UInt32.max),
                  try checkedAdd(out.count, try checkedAdd(totalPartLen, 2)) <= limits.maximumCompressedBytes else {
                throw CodecError(.resourceLimitExceeded, "Reassembled codestream exceeds its compressed-output limit.")
            }
            let psot = UInt32(totalPartLen)
            out.append(contentsOf: [
                0xFF, 0x90, 0x00, 0x0A,
                UInt8((tileIdx >> 8) & 0xFF), UInt8(tileIdx & 0xFF),
                UInt8((psot >> 24) & 0xFF), UInt8((psot >> 16) & 0xFF),
                UInt8((psot >> 8) & 0xFF), UInt8(psot & 0xFF),
                0x00, 0x01
            ])
            out.append(thData)
            out.append(contentsOf: [0xFF, 0x93])
            out.append(tileBitstream)
        }

        out.append(contentsOf: [0xFF, 0xD9])
        return out
    }
}
