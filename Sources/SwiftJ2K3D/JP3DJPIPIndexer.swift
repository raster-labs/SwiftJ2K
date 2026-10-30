// SPDX-License-Identifier: Apache-2.0
//
// JP3DJPIPIndexer.swift
// SwiftJ2K3D
//
// Normative 3D JPIP data-bin indexing and Part 10 JP3D codestream reconstruction
// combining ITU-T Rec. T.809 (05/2011) | ISO/IEC 15444-10 (JP3D) and
// ITU-T Rec. T.808 (12/2022) | ISO/IEC 15444-9 (JPIP) Annex A data-bins.

import Foundation
import SwiftJ2K

/// One indexed 3D JP3D precinct data-bin (`Class 0`).
package struct JP3DJPIPIndexedPrecinct: Sendable {
    package let tileIndex: Int
    package let componentIndex: Int
    package let resolutionLevel: Int
    package let precinctInResolution: Int
    package let sequenceInTileComponent: Int
    package let inClassID: Int
    package let refX0: Int, refX1: Int
    package let refY0: Int, refY1: Int
    package let refZ0: Int, refZ1: Int
    package let layerPackets: [Data]

    package var concatenatedData: Data {
        var total = 0
        for p in layerPackets { total += p.count }
        var out = Data()
        out.reserveCapacity(total)
        for p in layerPackets { out.append(p) }
        return out
    }
}

/// One indexed 3D JP3D tile (`Class 2` tile-header and `Class 4` tile data-bins).
package struct JP3DJPIPIndexedTile: Sendable {
    package let tileIndex: Int
    package let refX0: Int, refX1: Int
    package let refY0: Int, refY1: Int
    package let refZ0: Int, refZ1: Int
    package let tileHeaderMarkers: Data
    package let completeTilePartsData: Data
}

/// Complete JPIP data-bin index of a Part 10 JP3D volumetric codestream.
package struct JP3DJPIPIndexedCodestream: Sendable {
    package let width: Int
    package let height: Int
    package let depth: Int
    package let originX: Int
    package let originY: Int
    package let originZ: Int
    package let tileCount: Int
    package let componentCount: Int
    package let levelsX: Int
    package let levelsY: Int
    package let levelsZ: Int
    package let maxLevels: Int
    package let totalLayers: Int
    package let isReversibleLossless: Bool
    package let isHTJ2K: Bool
    package let mainHeader: Data
    package let tiles: [JP3DJPIPIndexedTile]
    package let precincts: [JP3DJPIPIndexedPrecinct]
}

package enum JP3DJPIPIndexer {
    /// Checks whether `data` starts with a Part 10 JP3D codestream (`SOC` + `SIZ` + `CAP`/`NSI` with `0xFF54` in main header).
    package static func isJP3DCodestream(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 16, bytes[0] == 0xFF, bytes[1] == 0x4F else {
            return false
        }
        var cursor = 2
        while cursor + 2 <= bytes.count {
            let m = UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1])
            if m == 0xFF54 { return true } // NSI
            if m == 0xFF90 || m == 0xFFD9 { return false }
            cursor += 2
            if (0xFF30...0xFF3F).contains(m) { continue }
            guard cursor + 2 <= bytes.count else { return false }
            let segLen = Int(UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1]))
            guard segLen >= 2, cursor + segLen <= bytes.count else { return false }
            cursor += segLen
        }
        return false
    }

    /// Indexes a Part 10 JP3D codestream into `Class 6`, `Class 2`, `Class 4`, and `Class 0` 3D precinct data-bins.
    package static func index(
        _ data: Data,
        limits: ResourceLimits = .default
    ) throws -> JP3DJPIPIndexedCodestream {
        let parser = JP3DCodestreamParser()
        let parsed = try parser.parse(data, limits: limits)
        let bytes = [UInt8](data)

        // Locate first SOT for exact mainHeader bytes.
        var cursor = 2
        var firstSOT: Int?
        while cursor + 2 <= bytes.count {
            let m = UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1])
            if m == 0xFF90 {
                firstSOT = cursor
                break
            }
            cursor += 2
            if (0xFF30...0xFF3F).contains(m) { continue }
            guard cursor + 2 <= bytes.count else { break }
            let segLen = Int(UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1]))
            guard segLen >= 2, cursor + segLen <= bytes.count else { break }
            cursor += segLen
        }
        guard let mainHeaderEnd = firstSOT else {
            throw CodecError(.malformedInput, "JP3D codestream has no SOT marker.")
        }
        let mainHeader = Data(bytes[0..<mainHeaderEnd])

        // Scan raw tile-parts for Class 2 / Class 4 slices.
        struct RawPart {
            let tileIndex: Int
            let partIndex: Int
            let sotStart: Int
            let headerRange: Range<Int>
            let dataRange: Range<Int>
            let partEnd: Int
        }
        var rawPartsByTile: [Int: [RawPart]] = [:]
        cursor = mainHeaderEnd
        while cursor + 2 <= bytes.count {
            let m = UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1])
            if m == 0xFFD9 { break }
            guard m == 0xFF90, cursor + 12 <= bytes.count else {
                throw CodecError(.malformedInput, "Malformed SOT in JP3D codestream.")
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
                partEnd = (bytes.count >= 2 && bytes[bytes.count - 2] == 0xFF && bytes[bytes.count - 1] == 0xD9)
                    ? (bytes.count - 2) : bytes.count
            } else {
                guard psot >= 14, UInt64(sotStart) + UInt64(psot) <= UInt64(bytes.count) else {
                    throw CodecError(.malformedInput, "Invalid SOT Psot in JP3D codestream.")
                }
                partEnd = sotStart + Int(psot)
            }
            var hc = sotStart + 12
            var sodPos: Int?
            while hc + 2 <= partEnd {
                let hm = UInt16(bytes[hc]) << 8 | UInt16(bytes[hc + 1])
                if hm == 0xFF93 {
                    sodPos = hc
                    break
                }
                hc += 2
                if (0xFF30...0xFF3F).contains(hm) { continue }
                guard hc + 2 <= partEnd else { break }
                let sl = Int(UInt16(bytes[hc]) << 8 | UInt16(bytes[hc + 1]))
                guard sl >= 2, hc + sl <= partEnd else { break }
                hc += sl
            }
            guard let foundSOD = sodPos else {
                throw CodecError(.malformedInput, "Missing SOD in JP3D tile-part.")
            }
            rawPartsByTile[isot, default: []].append(
                RawPart(
                    tileIndex: isot,
                    partIndex: tpsot,
                    sotStart: sotStart,
                    headerRange: (sotStart + 12)..<foundSOD,
                    dataRange: (foundSOD + 2)..<partEnd,
                    partEnd: partEnd
                )
            )
            cursor = partEnd
        }

        let siz = parsed.siz
        let cod = parsed.cod
        let tilingConfig = JP3DTilingConfiguration(
            tileSizeX: siz.tileSizeX,
            tileSizeY: siz.tileSizeY,
            tileSizeZ: siz.tileSizeZ
        )
        let allTiles = tilingConfig.allTiles(
            volumeWidth: siz.width,
            volumeHeight: siz.height,
            volumeDepth: siz.depth
        )
        let totalTiles = allTiles.count
        let compCount = siz.componentCount
        let totalLayers = max(1, cod.numLayers)
        let maxNL = max(cod.levelsX, max(cod.levelsY, cod.levelsZ))

        var indexedTiles: [JP3DJPIPIndexedTile] = []
        indexedTiles.reserveCapacity(totalTiles)
        var indexedPrecincts: [JP3DJPIPIndexedPrecinct] = []

        for tileIdx in 0..<totalTiles {
            let tileRegion = allTiles[tileIdx].region
            let bounds = (
                x0: tileRegion.x.lowerBound, x1: tileRegion.x.upperBound,
                y0: tileRegion.y.lowerBound, y1: tileRegion.y.upperBound,
                z0: tileRegion.z.lowerBound, z1: tileRegion.z.upperBound
            )
            let parts = (rawPartsByTile[tileIdx] ?? []).sorted { $0.partIndex < $1.partIndex }
            var thMarkers = Data()
            var fullTile = Data()
            var tileBitstream: [UInt8] = []
            for p in parts {
                thMarkers.append(contentsOf: bytes[p.headerRange])
                fullTile.append(contentsOf: bytes[p.sotStart..<p.partEnd])
                tileBitstream.append(contentsOf: bytes[p.dataRange])
            }
            indexedTiles.append(
                JP3DJPIPIndexedTile(
                    tileIndex: tileIdx,
                    refX0: bounds.x0, refX1: bounds.x1,
                    refY0: bounds.y0, refY1: bounds.y1,
                    refZ0: bounds.z0, refZ1: bounds.z1,
                    tileHeaderMarkers: thMarkers,
                    completeTilePartsData: fullTile
                )
            )
            guard !tileBitstream.isEmpty else { continue }

            var geometries: [JP3DTileComponentGeometry] = []
            geometries.reserveCapacity(compCount)
            for _ in 0..<compCount {
                geometries.append(
                    try JP3DGeometryBuilder.makeTileComponentGeometry(
                        x0: bounds.x0, x1: bounds.x1,
                        y0: bounds.y0, y1: bounds.y1,
                        z0: bounds.z0, z1: bounds.z1,
                        cod: cod
                    )
                )
            }

            let decoded = try JP3DTier2Coder.decodePackets(
                geometries: geometries,
                cod: cod,
                bytes: tileBitstream,
                tolerateTruncation: true,
                cancellation: {}
            )

            // Organize packets by [c][r][p][l]
            var perPrc: [[[[Data]]]] = geometries.map { g in
                g.resolutions.map { r in
                    Array(repeating: [Data](repeating: Data(), count: totalLayers), count: r.precincts.count)
                }
            }
            for pkt in decoded.packets {
                let a = pkt.address
                if a.component < perPrc.count,
                   a.resolution < perPrc[a.component].count,
                   a.precinct < perPrc[a.component][a.resolution].count,
                   a.layer < totalLayers {
                    perPrc[a.component][a.resolution][a.precinct][a.layer] = Data(tileBitstream[pkt.byteRange])
                }
            }

            for c in 0..<compCount {
                let geom = geometries[c]
                var seqBase = 0
                for r in 0..<geom.resolutions.count {
                    let res = geom.resolutions[r]
                    let firstPX = jp3dFloorDivPow2(res.x0, res.ppx)
                    let firstPY = jp3dFloorDivPow2(res.y0, res.ppy)
                    let firstPZ = jp3dFloorDivPow2(res.z0, res.ppz)
                    for p in 0..<res.precincts.count {
                        let prc = res.precincts[p]
                        let rx0 = max(res.x0, (firstPX + prc.px) << res.ppx)
                        let rx1 = min(res.x1, (firstPX + prc.px + 1) << res.ppx)
                        let ry0 = max(res.y0, (firstPY + prc.py) << res.ppy)
                        let ry1 = min(res.y1, (firstPY + prc.py + 1) << res.ppy)
                        let rz0 = max(res.z0, (firstPZ + prc.pz) << res.ppz)
                        let rz1 = min(res.z1, (firstPZ + prc.pz + 1) << res.ppz)
                        let gx0 = max(bounds.x0, rx0 << res.decompX)
                        let gx1 = min(bounds.x1, rx1 << res.decompX)
                        let gy0 = max(bounds.y0, ry0 << res.decompY)
                        let gy1 = min(bounds.y1, ry1 << res.decompY)
                        let gz0 = max(bounds.z0, rz0 << res.decompZ)
                        let gz1 = min(bounds.z1, rz1 << res.decompZ)

                        let s = seqBase + p
                        let inClassID = tileIdx + (c + s * compCount) * totalTiles
                        indexedPrecincts.append(
                            JP3DJPIPIndexedPrecinct(
                                tileIndex: tileIdx,
                                componentIndex: c,
                                resolutionLevel: r,
                                precinctInResolution: p,
                                sequenceInTileComponent: s,
                                inClassID: inClassID,
                                refX0: gx0, refX1: gx1,
                                refY0: gy0, refY1: gy1,
                                refZ0: gz0, refZ1: gz1,
                                layerPackets: perPrc[c][r][p]
                            )
                        )
                    }
                    seqBase += res.precincts.count
                }
            }
        }

        let isLossless = cod.isLossless && parsed.isLosslessQuantization
        let isHT = (cod.codeBlockStyle & 0x40) != 0 || parsed.hasHTJ2KCAPMarker
        return JP3DJPIPIndexedCodestream(
            width: siz.width,
            height: siz.height,
            depth: siz.depth,
            originX: siz.originX,
            originY: siz.originY,
            originZ: siz.originZ,
            tileCount: totalTiles,
            componentCount: compCount,
            levelsX: cod.levelsX,
            levelsY: cod.levelsY,
            levelsZ: cod.levelsZ,
            maxLevels: maxNL,
            totalLayers: totalLayers,
            isReversibleLossless: isLossless,
            isHTJ2K: isHT,
            mainHeader: mainHeader,
            tiles: indexedTiles,
            precincts: indexedPrecincts
        )
    }

    /// Reconstructs a valid Part 10 JP3D codestream from `Class 6` main header,
    /// `Class 2` tile-header bins, and `Class 0` 3D precinct data-bins.
    package static func reassembleJPP3D(
        mainHeader: Data,
        tileHeaders: [Int: Data],
        precinctBins: [Int: Data],
        limits: ResourceLimits = .default
    ) throws -> Data {
        // Synthesize minimal header+empty-tile0 codestream to parse main header parameters.
        var probe = Data(mainHeader)
        let th0 = tileHeaders[0] ?? Data()
        let psot0 = UInt32(14 + th0.count)
        probe.append(contentsOf: [
            0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00,
            UInt8((psot0 >> 24) & 0xFF), UInt8((psot0 >> 16) & 0xFF),
            UInt8((psot0 >> 8) & 0xFF), UInt8(psot0 & 0xFF),
            0x00, 0x01
        ])
        probe.append(th0)
        probe.append(contentsOf: [0xFF, 0x93, 0xFF, 0xD9])

        let parsed = try JP3DCodestreamParser().parse(probe, limits: limits)
        let siz = parsed.siz
        let cod = parsed.cod
        let compCount = siz.componentCount
        let tilingConfig = JP3DTilingConfiguration(
            tileSizeX: siz.tileSizeX,
            tileSizeY: siz.tileSizeY,
            tileSizeZ: siz.tileSizeZ
        )
        let allTiles = tilingConfig.allTiles(
            volumeWidth: siz.width,
            volumeHeight: siz.height,
            volumeDepth: siz.depth
        )
        let totalTiles = allTiles.count
        let totalLayers = max(1, cod.numLayers)
        let style = CodeBlockStyle(bits: cod.codeBlockStyle)

        var out = Data()
        out.append(mainHeader)

        for tileIdx in 0..<totalTiles {
            let tileRegion = allTiles[tileIdx].region
            let bounds = (
                x0: tileRegion.x.lowerBound, x1: tileRegion.x.upperBound,
                y0: tileRegion.y.lowerBound, y1: tileRegion.y.upperBound,
                z0: tileRegion.z.lowerBound, z1: tileRegion.z.upperBound
            )
            let thData = tileHeaders[tileIdx] ?? Data()
            var geometries: [JP3DTileComponentGeometry] = []
            geometries.reserveCapacity(compCount)
            for _ in 0..<compCount {
                geometries.append(
                    try JP3DGeometryBuilder.makeTileComponentGeometry(
                        x0: bounds.x0, x1: bounds.x1,
                        y0: bounds.y0, y1: bounds.y1,
                        z0: bounds.z0, z1: bounds.z1,
                        cod: cod
                    )
                )
            }

            var perPrecinctLayerPackets: [[[[Data?]]]] = []
            perPrecinctLayerPackets.reserveCapacity(compCount)
            var anyPresent = false

            for c in 0..<compCount {
                let geom = geometries[c]
                var compLayers: [[[Data?]]] = []
                compLayers.reserveCapacity(geom.resolutions.count)
                var seqBase = 0

                for r in 0..<geom.resolutions.count {
                    let res = geom.resolutions[r]
                    var resLayers: [[Data?]] = []
                    resLayers.reserveCapacity(res.precincts.count)

                    for p in 0..<res.precincts.count {
                        let s = seqBase + p
                        let inClassID = tileIdx + (c + s * compCount) * totalTiles
                        var layerSlices = [Data?](repeating: nil, count: totalLayers)

                        if let rawBin = precinctBins[inClassID], !rawBin.isEmpty {
                            anyPresent = true
                            let binBytes = [UInt8](rawBin)
                            let prc = res.precincts[p]
                            var blocksState: [[CodeBlockContribution]] = prc.bands.map {
                                [CodeBlockContribution](repeating: CodeBlockContribution(), count: $0.blocks.count)
                            }
                            var incTrees = try prc.bands.map {
                                try JP3DTagTree(width: $0.blocksWide, height: $0.blocksHigh, depth: $0.blocksDeep)
                            }
                            var msbTrees = try prc.bands.map {
                                try JP3DTagTree(width: $0.blocksWide, height: $0.blocksHigh, depth: $0.blocksDeep)
                            }

                            var pCursor = 0
                            let pEnd = binBytes.count
                            layerLoop: for layer in 0..<totalLayers {
                                if pCursor >= pEnd { break }
                                let pktStart = pCursor
                                do {
                                    if cod.usesSOP {
                                        if pCursor + 6 <= pEnd,
                                           binBytes[pCursor] == 0xFF, binBytes[pCursor + 1] == 0x91 {
                                            pCursor += 6
                                        } else {
                                            break layerLoop
                                        }
                                    }
                                    var reader = PacketBitReader(bytes: binBytes, start: pCursor, end: pEnd)
                                    var bodyLen = 0
                                    if try reader.readBit() {
                                        for (b, pb) in prc.bands.enumerated() where !pb.blocks.isEmpty {
                                            for k in 0..<pb.blocks.count {
                                                var st = blocksState[b][k]
                                                let included: Bool
                                                if st.included {
                                                    included = try reader.readBit()
                                                } else {
                                                    included = try incTrees[b].decode(
                                                        reader: &reader, leaf: k, threshold: Int32(layer + 1)
                                                    )
                                                }
                                                guard included else { continue }
                                                let firstInc = !st.included
                                                if firstInc {
                                                    var thresh: Int32 = 1
                                                    while try !msbTrees[b].decode(reader: &reader, leaf: k, threshold: thresh) {
                                                        thresh += 1
                                                        guard thresh <= 80 else {
                                                            throw CodecError(.malformedInput, "Invalid 3D zero bit-planes.")
                                                        }
                                                    }
                                                    st.included = true
                                                    st.zeroBitPlanes = Int(msbTrees[b].value(leaf: k))
                                                    if style.ht && !style.htMixed { st.isHT = true }
                                                }
                                                let newPasses = try Tier2.readPassCount(&reader)
                                                while try reader.readBit() {
                                                    st.lblock += 1
                                                    guard st.lblock <= 40 else {
                                                        throw CodecError(.malformedInput, "Invalid 3D Lblock.")
                                                    }
                                                }
                                                let phStyle = st.isHT
                                                    ? CodeBlockStyle(bits: cod.codeBlockStyle | 0x40)
                                                    : CodeBlockStyle(bits: cod.codeBlockStyle & ~0xC0)
                                                var chunks = Tier2.segmentPassCounts(
                                                    start: st.passes, count: newPasses, style: phStyle
                                                )
                                                if firstInc && style.ht && style.htMixed {
                                                    let fc = chunks[0]
                                                    let fb = st.lblock + Tier2.floorLog2(fc)
                                                    let fl = try reader.readBits(fb)
                                                    st.isHT = st.lblock > 3 && fb >= 1 && ((fl >> (fb - 1)) == 0)
                                                    let rStyle = st.isHT
                                                        ? CodeBlockStyle(bits: cod.codeBlockStyle | 0x40)
                                                        : CodeBlockStyle(bits: cod.codeBlockStyle & ~0xC0)
                                                    chunks = Tier2.segmentPassCounts(
                                                        start: st.passes, count: newPasses, style: rStyle
                                                    )
                                                    bodyLen = try jp3dCheckedAdd(bodyLen, fl)
                                                    st.passes += chunks[0]
                                                    if chunks[0] == fc {
                                                        for ch in chunks.dropFirst() {
                                                            let sl = try reader.readBits(st.lblock + Tier2.floorLog2(ch))
                                                            bodyLen = try jp3dCheckedAdd(bodyLen, sl)
                                                            st.passes += ch
                                                        }
                                                    }
                                                } else {
                                                    for ch in chunks {
                                                        let sl = try reader.readBits(st.lblock + Tier2.floorLog2(ch))
                                                        bodyLen = try jp3dCheckedAdd(bodyLen, sl)
                                                        st.passes += ch
                                                    }
                                                }
                                                blocksState[b][k] = st
                                            }
                                        }
                                    }
                                    try reader.alignToByte()
                                    var afterHeader = reader.position
                                    if cod.usesEPH {
                                        guard afterHeader + 2 <= pEnd,
                                              binBytes[afterHeader] == 0xFF,
                                              binBytes[afterHeader + 1] == 0x92 else {
                                            break layerLoop
                                        }
                                        afterHeader += 2
                                    }
                                    guard afterHeader + bodyLen <= pEnd else {
                                        break layerLoop
                                    }
                                    pCursor = afterHeader + bodyLen
                                    layerSlices[layer] = Data(binBytes[pktStart..<pCursor])
                                } catch {
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

            if !anyPresent && tileHeaders[tileIdx] == nil {
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

            let sequence = try JP3DTier2Coder.packetSequence(
                geometries: geometries,
                progression: cod.progressionOrderByte,
                totalLayers: totalLayers
            )

            var tileBitstream = Data()
            var sopSeq: UInt16 = 0
            for addr in sequence {
                if let pkt = perPrecinctLayerPackets[addr.component][addr.resolution][addr.precinct][addr.layer] {
                    if cod.usesSOP, pkt.count >= 6, pkt[pkt.startIndex] == 0xFF, pkt[pkt.startIndex + 1] == 0x91 {
                        tileBitstream.append(contentsOf: [
                            0xFF, 0x91, 0x00, 0x04,
                            UInt8((sopSeq >> 8) & 0xFF), UInt8(sopSeq & 0xFF)
                        ])
                        tileBitstream.append(pkt.dropFirst(6))
                    } else {
                        if cod.usesSOP {
                            tileBitstream.append(contentsOf: [
                                0xFF, 0x91, 0x00, 0x04,
                                UInt8((sopSeq >> 8) & 0xFF), UInt8(sopSeq & 0xFF)
                            ])
                        }
                        tileBitstream.append(pkt)
                    }
                } else {
                    if cod.usesSOP {
                        tileBitstream.append(contentsOf: [
                            0xFF, 0x91, 0x00, 0x04,
                            UInt8((sopSeq >> 8) & 0xFF), UInt8(sopSeq & 0xFF)
                        ])
                    }
                    tileBitstream.append(0x00)
                    if cod.usesEPH {
                        tileBitstream.append(contentsOf: [0xFF, 0x92])
                    }
                }
                sopSeq &+= 1
            }

            let totalPartLen = 12 + thData.count + 2 + tileBitstream.count
            let psot: UInt32 = totalPartLen <= Int(UInt32.max) ? UInt32(totalPartLen) : 0
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
