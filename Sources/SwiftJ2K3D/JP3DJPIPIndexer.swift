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
        let totalLayers = max(1, (0..<max(1, totalTiles)).map { parsed.effectiveTileCOD(tileIndex: $0).numLayers }.max() ?? cod.numLayers)
        let maxNL = (0..<max(1, totalTiles)).flatMap { t in
            (0..<compCount).map { c in
                let cc = parsed.effectiveCOD(tileIndex: t, component: c)
                return max(cc.levelsX, max(cc.levelsY, cc.levelsZ))
            }
        }.max() ?? max(cod.levelsX, max(cod.levelsY, cod.levelsZ))

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

            let tileCOD = parsed.effectiveTileCOD(tileIndex: tileIdx)
            let tileLayers = max(1, tileCOD.numLayers)
            let compCODs = (0..<compCount).map { parsed.effectiveCOD(tileIndex: tileIdx, component: $0) }

            var geometries: [JP3DTileComponentGeometry] = []
            geometries.reserveCapacity(compCount)
            var tileGeomBytes = 0
            for c in 0..<compCount {
                let remCap = max(0, min(limits.maximumWorkspaceBytes, limits.maximumMemoryBytes) - tileGeomBytes)
                let fp = try JP3DGeometryBuilder.preflightTileComponentGeometry(
                    x0: bounds.x0, x1: bounds.x1,
                    y0: bounds.y0, y1: bounds.y1,
                    z0: bounds.z0, z1: bounds.z1,
                    cod: compCODs[c],
                    maximumWorkspaceBytes: remCap,
                    includeDecodeState: true
                )
                let (nextG, gOv) = tileGeomBytes.addingReportingOverflow(fp.totalBytes)
                guard !gOv, nextG <= limits.maximumWorkspaceBytes, nextG <= limits.maximumMemoryBytes else {
                    throw CodecError(.resourceLimitExceeded, "JP3D JPIP indexing 3D geometry exceeds resource limits.")
                }
                tileGeomBytes = nextG
                geometries.append(
                    try JP3DGeometryBuilder.makeTileComponentGeometry(
                        x0: bounds.x0, x1: bounds.x1,
                        y0: bounds.y0, y1: bounds.y1,
                        z0: bounds.z0, z1: bounds.z1,
                        cod: compCODs[c]
                    )
                )
            }

            let decoded = try JP3DTier2Coder.decodePackets(
                geometries: geometries,
                cod: tileCOD,
                componentCODs: compCODs,
                bytes: tileBitstream,
                tolerateTruncation: true,
                cancellation: {}
            )

            // Organize packets by [c][r][p][l]
            var perPrc: [[[[Data]]]] = geometries.map { g in
                g.resolutions.map { r in
                    Array(repeating: [Data](repeating: Data(), count: tileLayers), count: r.precincts.count)
                }
            }
            for pkt in decoded.packets {
                let a = pkt.address
                if a.component < perPrc.count,
                   a.resolution < perPrc[a.component].count,
                   a.precinct < perPrc[a.component][a.resolution].count,
                   a.layer < tileLayers {
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

        let isLossless = parsed.isFullyReversible
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

        var parsed = try JP3DCodestreamParser().parse(probe, limits: limits)
        let siz = parsed.siz
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

        if totalTiles > 1 && tileHeaders.contains(where: { $0.key > 0 && !$0.value.isEmpty }) {
            var fullProbe = Data(mainHeader)
            for tIdx in 0..<totalTiles {
                let th = tileHeaders[tIdx] ?? Data()
                let psot = UInt32(14 + th.count)
                fullProbe.append(contentsOf: [
                    0xFF, 0x90, 0x00, 0x0A,
                    UInt8((tIdx >> 8) & 0xFF), UInt8(tIdx & 0xFF),
                    UInt8((psot >> 24) & 0xFF), UInt8((psot >> 16) & 0xFF),
                    UInt8((psot >> 8) & 0xFF), UInt8(psot & 0xFF),
                    0x00, 0x01
                ])
                fullProbe.append(th)
                fullProbe.append(contentsOf: [0xFF, 0x93])
            }
            fullProbe.append(contentsOf: [0xFF, 0xD9])
            parsed = try JP3DCodestreamParser().parse(fullProbe, limits: limits)
        }

        let outCap = min(limits.maximumCompressedBytes, min(limits.maximumWorkspaceBytes, limits.maximumMemoryBytes))
        guard mainHeader.count + 2 <= outCap else {
            throw CodecError(.resourceLimitExceeded, "Reassembled 3D JPIP codestream exceeds resource limits.")
        }
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
            let tileCOD = parsed.effectiveTileCOD(tileIndex: tileIdx)
            let totalLayers = max(1, tileCOD.numLayers)
            let compCODs = (0..<compCount).map { parsed.effectiveCOD(tileIndex: tileIdx, component: $0) }

            var geometries: [JP3DTileComponentGeometry] = []
            geometries.reserveCapacity(compCount)
            var tileGeomBytes = 0
            for c in 0..<compCount {
                let remCap = max(0, min(limits.maximumWorkspaceBytes, limits.maximumMemoryBytes) - out.count - tileGeomBytes)
                let fp = try JP3DGeometryBuilder.preflightTileComponentGeometry(
                    x0: bounds.x0, x1: bounds.x1,
                    y0: bounds.y0, y1: bounds.y1,
                    z0: bounds.z0, z1: bounds.z1,
                    cod: compCODs[c],
                    maximumWorkspaceBytes: remCap,
                    includeDecodeState: true
                )
                let (nextG, gOv) = tileGeomBytes.addingReportingOverflow(fp.totalBytes)
                guard !gOv, out.count + nextG <= min(limits.maximumWorkspaceBytes, limits.maximumMemoryBytes) else {
                    throw CodecError(.resourceLimitExceeded, "Reassembled 3D JPIP geometry workspace exceeds resource limits.")
                }
                tileGeomBytes = nextG
                geometries.append(
                    try JP3DGeometryBuilder.makeTileComponentGeometry(
                        x0: bounds.x0, x1: bounds.x1,
                        y0: bounds.y0, y1: bounds.y1,
                        z0: bounds.z0, z1: bounds.z1,
                        cod: compCODs[c]
                    )
                )
            }

            let lrcpTileCOD = JP3DCODInfo(
                levelsX: tileCOD.levelsX,
                levelsY: tileCOD.levelsY,
                levelsZ: tileCOD.levelsZ,
                isLossless: tileCOD.isLossless,
                codeBlockStyle: tileCOD.codeBlockStyle,
                scod: tileCOD.scod,
                progressionOrderByte: 0, // LRCP over single precinct -> layer 0..<totalLayers
                numLayers: totalLayers,
                multipleComponentTransform: tileCOD.multipleComponentTransform,
                codeBlockWidthExponent: tileCOD.codeBlockWidthExponent,
                codeBlockHeightExponent: tileCOD.codeBlockHeightExponent,
                codeBlockDepthExponent: tileCOD.codeBlockDepthExponent,
                dwtX: tileCOD.dwtX,
                dwtY: tileCOD.dwtY,
                dwtZ: tileCOD.dwtZ,
                precinctSizes: tileCOD.precinctSizes
            )

            var perPrecinctLayerPackets: [[[[Data?]]]] = []
            perPrecinctLayerPackets.reserveCapacity(compCount)
            var anyPresent = false

            for c in 0..<compCount {
                let geom = geometries[c]
                let compCOD = compCODs[c]
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
                            let miniRes = JP3DResolutionGeometry(
                                index: 0,
                                x0: res.x0, x1: res.x1,
                                y0: res.y0, y1: res.y1,
                                z0: res.z0, z1: res.z1,
                                decompX: res.decompX, decompY: res.decompY, decompZ: res.decompZ,
                                axisActiveX: res.axisActiveX, axisActiveY: res.axisActiveY, axisActiveZ: res.axisActiveZ,
                                ppx: res.ppx, ppy: res.ppy, ppz: res.ppz,
                                precinctsWide: 1, precinctsHigh: 1, precinctsDeep: 1,
                                bands: res.bands,
                                precincts: [res.precincts[p]]
                            )
                            let miniGeom = JP3DTileComponentGeometry(
                                x0: geom.x0, x1: geom.x1,
                                y0: geom.y0, y1: geom.y1,
                                z0: geom.z0, z1: geom.z1,
                                levelsX: 0, levelsY: 0, levelsZ: 0,
                                maxLevels: 0,
                                resolutions: [miniRes]
                            )
                            if let splitPkts = try? JP3DTier2Coder.decodePackets(
                                geometries: [miniGeom],
                                cod: lrcpTileCOD,
                                componentCODs: [compCOD],
                                bytes: binBytes,
                                tolerateTruncation: true,
                                cancellation: {}
                            ) {
                                for pkt in splitPkts.packets where pkt.address.layer < totalLayers {
                                    layerSlices[pkt.address.layer] = Data(binBytes[pkt.byteRange])
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
                guard out.count + 16 <= outCap else {
                    throw CodecError(.resourceLimitExceeded, "Reassembled 3D JPIP codestream exceeds resource limits.")
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

            let sequence = try JP3DTier2Coder.packetSequence(
                geometries: geometries,
                progression: tileCOD.progressionOrderByte,
                totalLayers: totalLayers
            )

            var tileBitstream = Data()
            var sopSeq: UInt16 = 0
            for addr in sequence {
                if let pkt = perPrecinctLayerPackets[addr.component][addr.resolution][addr.precinct][addr.layer] {
                    if tileCOD.usesSOP, pkt.count >= 6, pkt[pkt.startIndex] == 0xFF, pkt[pkt.startIndex + 1] == 0x91 {
                        tileBitstream.append(contentsOf: [
                            0xFF, 0x91, 0x00, 0x04,
                            UInt8((sopSeq >> 8) & 0xFF), UInt8(sopSeq & 0xFF)
                        ])
                        tileBitstream.append(pkt.dropFirst(6))
                    } else {
                        if tileCOD.usesSOP {
                            tileBitstream.append(contentsOf: [
                                0xFF, 0x91, 0x00, 0x04,
                                UInt8((sopSeq >> 8) & 0xFF), UInt8(sopSeq & 0xFF)
                            ])
                        }
                        tileBitstream.append(pkt)
                    }
                } else {
                    if tileCOD.usesSOP {
                        tileBitstream.append(contentsOf: [
                            0xFF, 0x91, 0x00, 0x04,
                            UInt8((sopSeq >> 8) & 0xFF), UInt8(sopSeq & 0xFF)
                        ])
                    }
                    tileBitstream.append(0x00)
                    if tileCOD.usesEPH {
                        tileBitstream.append(contentsOf: [0xFF, 0x92])
                    }
                }
                sopSeq &+= 1
                guard out.count + 16 + thData.count + tileBitstream.count <= outCap else {
                    throw CodecError(.resourceLimitExceeded, "Reassembled 3D JPIP codestream exceeds resource limits.")
                }
            }

            let totalPartLen = 12 + thData.count + 2 + tileBitstream.count
            guard out.count + totalPartLen + 2 <= outCap else {
                throw CodecError(.resourceLimitExceeded, "Reassembled 3D JPIP codestream exceeds resource limits.")
            }
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
