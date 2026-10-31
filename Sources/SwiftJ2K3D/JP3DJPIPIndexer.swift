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
        guard data.count <= limits.maximumCompressedBytes, data.count < limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "JP3D JPIP source exceeds its compressed or memory limit.")
        }
        let wsCap = min(limits.maximumWorkspaceBytes, limits.maximumMemoryBytes - data.count)
        @inline(__always)
        func checkedAdmit(_ current: inout Int, delta: Int, cap: Int, label: String) throws {
            guard delta > 0 else { return }
            let next = try jp3dCheckedAdd(current, delta, label: label)
            guard next <= cap else {
                throw CodecError(.resourceLimitExceeded, "\(label) (\(next) bytes) exceeds resource limit (\(cap) bytes).")
            }
            current = next
            StorageTelemetry.recordStage("jp3d-index-live-workspace", bytes: current)
        }
        var retainedIndexBytes = 0
        try checkedAdmit(&retainedIndexBytes, delta: try jp3dCheckedAdd(data.count, 4096), cap: wsCap,
            label: "JP3D JPIP source scanning buffer")
        StorageTelemetry.recordStage("jp3d-index-input-copy", bytes: data.count)
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
        try checkedAdmit(&retainedIndexBytes, delta: mainHeaderEnd, cap: wsCap, label: "JP3D JPIP main header")
        let mainHeader = Data(bytes[0..<mainHeaderEnd])
        var parserHeaderBytes = mainHeaderEnd

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
            parserHeaderBytes = try jp3dCheckedAdd(parserHeaderBytes, foundSOD - sotStart)
            try checkedAdmit(&retainedIndexBytes,
                delta: 3 * MemoryLayout<RawPart>.stride + 256, cap: wsCap,
                label: "JP3D JPIP raw tile-part records and growth")
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

        // Header structures can expand compact marker fields into arrays. Hold a
        // conservative header-derived allowance through parsing and indexing.
        let parserMetadataBytes = try jp3dCheckedAdd(4096, try jp3dCheckedMul(parserHeaderBytes, 64))
        try checkedAdmit(&retainedIndexBytes, delta: parserMetadataBytes, cap: wsCap,
            label: "JP3D JPIP retained parser metadata")
        let parserLimits = try limits.reserving(workspaceBytes: retainedIndexBytes, memoryBytes: retainedIndexBytes)
        let parsed = try JP3DCodestreamParser().parse(data, limits: parserLimits, copyTilePayloads: false)
        try checkedAdmit(&retainedIndexBytes, delta: parsed.retainedTileBytes, cap: wsCap,
            label: "JP3D JPIP parsed tile records")
        let siz = parsed.siz
        let cod = parsed.cod
        let tilingConfig = JP3DTilingConfiguration(
            tileSizeX: siz.tileSizeX,
            tileSizeY: siz.tileSizeY,
            tileSizeZ: siz.tileSizeZ
        )
        let grid = tilingConfig.tileGrid(volumeWidth: siz.width, volumeHeight: siz.height, volumeDepth: siz.depth)
        let tilesXY = try jp3dCheckedMul(grid.tilesX, grid.tilesY)
        let totalTiles = try jp3dCheckedMul(tilesXY, grid.tilesZ)
        guard totalTiles > 0, totalTiles <= 65_536 else {
            throw CodecError(.resourceLimitExceeded, "JP3D JPIP tile grid exceeds the SOT index range.")
        }
        let compCount = siz.componentCount
        var totalLayers = 1
        var maxNL = 0
        for tileIdx in 0..<totalTiles {
            totalLayers = max(totalLayers, parsed.effectiveTileCOD(tileIndex: tileIdx).numLayers)
            for c in 0..<compCount {
                let cc = parsed.effectiveCOD(tileIndex: tileIdx, component: c)
                maxNL = max(maxNL, max(cc.levelsX, max(cc.levelsY, cc.levelsZ)))
            }
        }

        var indexedTiles: [JP3DJPIPIndexedTile] = []
        try checkedAdmit(
            &retainedIndexBytes,
            delta: try jp3dCheckedMul(totalTiles, MemoryLayout<JP3DJPIPIndexedTile>.stride, label: "JP3D JPIP tile table"),
            cap: wsCap,
            label: "JP3D JPIP tile table"
        )
        indexedTiles.reserveCapacity(totalTiles)
        var indexedPrecincts: [JP3DJPIPIndexedPrecinct] = []

        for tileIdx in 0..<totalTiles {
            let tileRegion = tilingConfig.tile(atX: tileIdx % grid.tilesX,
                y: (tileIdx / grid.tilesX) % grid.tilesY, z: tileIdx / tilesXY,
                volumeWidth: siz.width, volumeHeight: siz.height, volumeDepth: siz.depth).region
            let bounds = (
                x0: tileRegion.x.lowerBound, x1: tileRegion.x.upperBound,
                y0: tileRegion.y.lowerBound, y1: tileRegion.y.upperBound,
                z0: tileRegion.z.lowerBound, z1: tileRegion.z.upperBound
            )
            var tileLiveBytes = retainedIndexBytes
            try checkedAdmit(&tileLiveBytes,
                delta: try jp3dCheckedMul(rawPartsByTile[tileIdx]?.count ?? 0, 3 * MemoryLayout<RawPart>.stride),
                cap: wsCap, label: "JP3D JPIP tile-part sorting")
            let parts = (rawPartsByTile[tileIdx] ?? []).sorted { $0.partIndex < $1.partIndex }
            var thBytesCount = 0
            var fullTileBytesCount = 0
            var bitstreamBytesCount = 0
            for p in parts {
                thBytesCount = try jp3dCheckedAdd(thBytesCount, p.headerRange.count, label: "JP3D JPIP tile header bytes")
                fullTileBytesCount = try jp3dCheckedAdd(fullTileBytesCount, p.partEnd - p.sotStart, label: "JP3D JPIP full tile bytes")
                bitstreamBytesCount = try jp3dCheckedAdd(bitstreamBytesCount, p.dataRange.count, label: "JP3D JPIP tile bitstream bytes")
            }
            try checkedAdmit(&retainedIndexBytes, delta: thBytesCount, cap: wsCap, label: "JP3D JPIP retained tile headers")
            try checkedAdmit(&retainedIndexBytes, delta: fullTileBytesCount, cap: wsCap, label: "JP3D JPIP retained tile-parts")
            try checkedAdmit(&tileLiveBytes, delta: try jp3dCheckedAdd(thBytesCount, fullTileBytesCount),
                cap: wsCap, label: "JP3D JPIP retained tile records during sorting")
            try checkedAdmit(&tileLiveBytes, delta: bitstreamBytesCount, cap: wsCap, label: "JP3D JPIP transient tile bitstream")

            var thMarkers = Data()
            thMarkers.reserveCapacity(thBytesCount)
            var fullTile = Data()
            fullTile.reserveCapacity(fullTileBytesCount)
            var tileBitstream = Data()
            tileBitstream.reserveCapacity(bitstreamBytesCount)
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
            try checkedAdmit(&tileLiveBytes,
                delta: try jp3dCheckedMul(compCount, MemoryLayout<JP3DCODInfo>.stride + MemoryLayout<JP3DTileComponentGeometry>.stride + 64),
                cap: wsCap, label: "JP3D JPIP component geometry tables")
            let compCODs = (0..<compCount).map { parsed.effectiveCOD(tileIndex: tileIdx, component: $0) }

            var geometries: [JP3DTileComponentGeometry] = []
            geometries.reserveCapacity(compCount)
            for c in 0..<compCount {
                let remCap = max(0, wsCap - tileLiveBytes)
                let fp = try JP3DGeometryBuilder.preflightTileComponentGeometry(
                    x0: bounds.x0, x1: bounds.x1,
                    y0: bounds.y0, y1: bounds.y1,
                    z0: bounds.z0, z1: bounds.z1,
                    cod: compCODs[c],
                    maximumWorkspaceBytes: remCap,
                    includeDecodeState: true
                )
                try checkedAdmit(&tileLiveBytes, delta: fp.totalBytes, cap: wsCap, label: "JP3D JPIP 3D geometry workspace")
                geometries.append(
                    try JP3DGeometryBuilder.makeTileComponentGeometry(
                        x0: bounds.x0, x1: bounds.x1,
                        y0: bounds.y0, y1: bounds.y1,
                        z0: bounds.z0, z1: bounds.z1,
                        cod: compCODs[c]
                    )
                )
            }

            var tilePrecinctCount = 0
            var tileResolutionCount = 0
            for g in geometries {
                tileResolutionCount = try jp3dCheckedAdd(tileResolutionCount, g.resolutions.count)
                for r in g.resolutions {
                    tilePrecinctCount = try jp3dCheckedAdd(tilePrecinctCount, r.precincts.count, label: "JP3D JPIP tile precinct count")
                }
            }
            let precinctLayerSlots = try jp3dCheckedMul(tilePrecinctCount, tileLayers, label: "JP3D JPIP precinct-layer slots")
            let perPrcTableBytes = try jp3dCheckedAdd(
                try jp3dCheckedMul(precinctLayerSlots, MemoryLayout<Data>.stride),
                try jp3dCheckedMul(try jp3dCheckedAdd(tilePrecinctCount, tileResolutionCount), 64))
            let prcMetaBytes = try jp3dCheckedMul(tilePrecinctCount,
                3 * MemoryLayout<JP3DJPIPIndexedPrecinct>.stride + 64,
                label: "JP3D JPIP precinct descriptor table and growth")
            // Pre-admit retained `perPrc` and precinct descriptors BEFORE running `decodePackets` or allocating `[Data]` tables.
            try checkedAdmit(&tileLiveBytes, delta: perPrcTableBytes, cap: wsCap, label: "JP3D JPIP precinct-layer table")
            try checkedAdmit(&tileLiveBytes, delta: prcMetaBytes, cap: wsCap, label: "JP3D JPIP precinct descriptor table")
            try checkedAdmit(&retainedIndexBytes, delta: perPrcTableBytes + prcMetaBytes, cap: wsCap, label: "JP3D JPIP retained precinct tables")

            var decodeTransientBytes = tileLiveBytes
            let decoded = try JP3DTier2Coder.decodePackets(
                geometries: geometries,
                cod: tileCOD,
                componentCODs: compCODs,
                data: tileBitstream,
                tolerateTruncation: true,
                recordPacketRanges: true,
                admitWorkspaceBytes: { delta in
                    try checkedAdmit(&decodeTransientBytes, delta: delta, cap: wsCap, label: "JP3D JPIP packet indexing workspace")
                },
                cancellation: {}
            )

            // Organize packets by [c][r][p][l] (already pre-admitted above)
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
                    let pktLen = pkt.byteRange.count
                    try checkedAdmit(&decodeTransientBytes, delta: try jp3dCheckedAdd(pktLen, 32), cap: wsCap, label: "JP3D JPIP indexed packet slice")
                    try checkedAdmit(&retainedIndexBytes, delta: try jp3dCheckedAdd(pktLen, 32), cap: wsCap, label: "JP3D JPIP retained packet slice")
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
        limits: ResourceLimits = .default,
        workspaceObserver: (@Sendable (Int) -> Void)? = nil
    ) throws -> Data {
        let wsCap = min(limits.maximumWorkspaceBytes, limits.maximumMemoryBytes)
        var peakWorkspace = 0
        func observeAdmission(_ bytes: Int, stage: String) throws {
            guard bytes <= wsCap else {
                throw CodecError(.resourceLimitExceeded, "Reassembled 3D JPIP live workspace exceeds resource limits.")
            }
            peakWorkspace = max(peakWorkspace, bytes)
            workspaceObserver?(peakWorkspace)
            StorageTelemetry.recordStage(stage, bytes: bytes)
        }
        var headerBytes = mainHeader.count
        var inputBytes = mainHeader.count
        for (tile, header) in tileHeaders {
            guard (0...65_535).contains(tile), header.count <= Int(UInt32.max) - 14 else {
                throw CodecError(.malformedInput, "JP3D tile-header identifier or length is not representable.")
            }
            headerBytes = try jp3dCheckedAdd(headerBytes, header.count)
            inputBytes = try jp3dCheckedAdd(inputBytes, header.count)
        }
        for (id, bin) in precinctBins {
            guard id >= 0 else { throw CodecError(.malformedInput, "Negative JP3D precinct identifier.") }
            inputBytes = try jp3dCheckedAdd(inputBytes, bin.count)
        }
        guard inputBytes <= limits.maximumCompressedBytes else {
            throw CodecError(.resourceLimitExceeded, "JP3D data-bins exceed maximumCompressedBytes.")
        }
        let declaredTiles = try jp3dCheckedAdd(tileHeaders.count, tileHeaders[0] == nil ? 1 : 0)
        let probeBytes = try jp3dCheckedAdd(headerBytes,
            try jp3dCheckedAdd(try jp3dCheckedMul(declaredTiles, 14), 2))
        let fixedScratch = 4096
        let probeAllocation = try jp3dCheckedAdd(probeBytes, fixedScratch)
        // Compact header fields expand into component/quantisation/override arrays.
        // Keep this conservative metadata allowance live through reconstruction.
        let metadataAllowance = try jp3dCheckedAdd(fixedScratch, try jp3dCheckedMul(headerBytes, 64))
        let tileRecordAllowance = try jp3dCheckedMul(declaredTiles, 3 * (MemoryLayout<JP3DParsedTile>.stride + 64))
        let parserPeak = try jp3dCheckedAdd(probeAllocation,
            try jp3dCheckedAdd(metadataAllowance, tileRecordAllowance))
        guard probeBytes <= limits.maximumCompressedBytes else {
            throw CodecError(.resourceLimitExceeded, "JP3D header probe exceeds maximumCompressedBytes.")
        }
        try observeAdmission(parserPeak, stage: "jp3d-reassembly-probe")
        var probe = Data()
        probe.reserveCapacity(probeBytes)
        probe.append(mainHeader)
        func appendProbeTile(_ tile: Int, header: Data) {
            let psot = UInt32(14 + header.count)
            probe.append(contentsOf: [0xFF, 0x90, 0x00, 0x0A,
                UInt8((tile >> 8) & 0xFF), UInt8(tile & 0xFF),
                UInt8((psot >> 24) & 0xFF), UInt8((psot >> 16) & 0xFF),
                UInt8((psot >> 8) & 0xFF), UInt8(psot & 0xFF), 0x00, 0x01])
            probe.append(header)
            probe.append(contentsOf: [0xFF, 0x93])
        }
        appendProbeTile(0, header: tileHeaders[0] ?? Data())
        for (tile, header) in tileHeaders where tile != 0 { appendProbeTile(tile, header: header) }
        probe.append(contentsOf: [0xFF, 0xD9])
        let parserLimits = try limits.reserving(
            workspaceBytes: try jp3dCheckedAdd(probeAllocation, metadataAllowance),
            memoryBytes: try jp3dCheckedAdd(fixedScratch, metadataAllowance))
        let parsed = try JP3DCodestreamParser().parse(probe, limits: parserLimits, copyTilePayloads: false)
        probe = Data()
        let retainedParserBytes = try jp3dCheckedAdd(metadataAllowance,
            max(tileRecordAllowance, parsed.retainedTileBytes))
        let siz = parsed.siz
        let compCount = siz.componentCount
        let tilingConfig = JP3DTilingConfiguration(tileSizeX: siz.tileSizeX,
            tileSizeY: siz.tileSizeY, tileSizeZ: siz.tileSizeZ)
        let grid = tilingConfig.tileGrid(volumeWidth: siz.width, volumeHeight: siz.height, volumeDepth: siz.depth)
        let tilesXY = try jp3dCheckedMul(grid.tilesX, grid.tilesY)
        let totalTiles = try jp3dCheckedMul(tilesXY, grid.tilesZ)
        guard totalTiles > 0, totalTiles <= 65_536, tileHeaders.keys.allSatisfy({ $0 < totalTiles }) else {
            throw CodecError(.malformedInput, "JP3D tile headers lie outside the image tile grid.")
        }
        let outCap = limits.maximumCompressedBytes
        guard try jp3dCheckedAdd(mainHeader.count, 2) <= outCap else {
            throw CodecError(.resourceLimitExceeded, "Reassembled 3D JPIP codestream exceeds resource limits.")
        }
        try observeAdmission(try jp3dCheckedAdd(retainedParserBytes,
            try jp3dCheckedAdd(fixedScratch, mainHeader.count)), stage: "jp3d-reassembly-output")
        var out = Data()
        out.reserveCapacity(mainHeader.count)
        out.append(mainHeader)

        for tileIdx in 0..<totalTiles {
            let tileRegion = tilingConfig.tile(atX: tileIdx % grid.tilesX,
                y: (tileIdx / grid.tilesX) % grid.tilesY, z: tileIdx / tilesXY,
                volumeWidth: siz.width, volumeHeight: siz.height, volumeDepth: siz.depth).region
            let bounds = (
                x0: tileRegion.x.lowerBound, x1: tileRegion.x.upperBound,
                y0: tileRegion.y.lowerBound, y1: tileRegion.y.upperBound,
                z0: tileRegion.z.lowerBound, z1: tileRegion.z.upperBound
            )
            let thData = tileHeaders[tileIdx] ?? Data()
            let tileCOD = parsed.effectiveTileCOD(tileIndex: tileIdx)
            let totalLayers = max(1, tileCOD.numLayers)
            let componentTables = try jp3dCheckedMul(compCount,
                MemoryLayout<JP3DCODInfo>.stride + MemoryLayout<JP3DTileComponentGeometry>.stride + 128)
            let baseWorkspace = try jp3dCheckedAdd(retainedParserBytes,
                try jp3dCheckedAdd(fixedScratch, try jp3dCheckedAdd(out.count, componentTables)))
            try observeAdmission(baseWorkspace, stage: "jp3d-reassembly-component-tables")
            let compCODs = (0..<compCount).map { parsed.effectiveCOD(tileIndex: tileIdx, component: $0) }

            var geometries: [JP3DTileComponentGeometry] = []
            geometries.reserveCapacity(compCount)
            var tileGeomBytes = 0
            for c in 0..<compCount {
                let remCap = max(0, wsCap - baseWorkspace - tileGeomBytes)
                let fp = try JP3DGeometryBuilder.preflightTileComponentGeometry(
                    x0: bounds.x0, x1: bounds.x1,
                    y0: bounds.y0, y1: bounds.y1,
                    z0: bounds.z0, z1: bounds.z1,
                    cod: compCODs[c],
                    maximumWorkspaceBytes: remCap,
                    includeDecodeState: true
                )
                let (nextG, gOv) = tileGeomBytes.addingReportingOverflow(fp.totalBytes)
                guard !gOv, nextG <= wsCap - baseWorkspace else {
                    throw CodecError(.resourceLimitExceeded, "Reassembled 3D JPIP geometry workspace exceeds resource limits.")
                }
                tileGeomBytes = nextG
                try observeAdmission(try jp3dCheckedAdd(baseWorkspace, tileGeomBytes), stage: "jp3d-reassembly-geometry")
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

            var tileLiveWS = try jp3dCheckedAdd(baseWorkspace, tileGeomBytes)
            @inline(__always)
            func admitReassembleWS(_ delta: Int) throws {
                guard delta > 0 else { return }
                let (next, ov) = tileLiveWS.addingReportingOverflow(delta)
                guard !ov, next <= wsCap else {
                    throw CodecError(.resourceLimitExceeded, "Reassembled 3D JPIP workspace (\(ov ? Int.max : next) bytes) exceeds resource limits.")
                }
                try observeAdmission(next, stage: "jp3d-reassembly-live-workspace")
                tileLiveWS = next
            }
            var nestedLayerBytes = 32
            for geom in geometries {
                nestedLayerBytes = try jp3dCheckedAdd(nestedLayerBytes, 64)
                for res in geom.resolutions {
                    nestedLayerBytes = try jp3dCheckedAdd(nestedLayerBytes,
                        try jp3dCheckedAdd(64, try jp3dCheckedMul(res.precincts.count, MemoryLayout<[Int: Data]>.stride + 32)))
                }
            }
            try admitReassembleWS(nestedLayerBytes)

            var perPrecinctLayerPackets: [[[[Int: Data]]]] = []
            perPrecinctLayerPackets.reserveCapacity(compCount)
            var anyPresent = false

            for c in 0..<compCount {
                let geom = geometries[c]
                let compCOD = compCODs[c]
                var compLayers: [[[Int: Data]]] = []
                compLayers.reserveCapacity(geom.resolutions.count)
                var seqBase = 0

                for r in 0..<geom.resolutions.count {
                    let res = geom.resolutions[r]
                    var resLayers: [[Int: Data]] = []
                    resLayers.reserveCapacity(res.precincts.count)

                    for p in 0..<res.precincts.count {
                        let s = seqBase + p
                        let inClassID = tileIdx + (c + s * compCount) * totalTiles
                        var layerSlices: [Int: Data] = [:]

                        if let rawBin = precinctBins[inClassID], !rawBin.isEmpty {
                            anyPresent = true
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
                            var splitTransientWS = tileLiveWS
                            do {
                                let splitPkts = try JP3DTier2Coder.decodePackets(
                                    geometries: [miniGeom],
                                    cod: lrcpTileCOD,
                                    componentCODs: [compCOD],
                                    data: rawBin,
                                    tolerateTruncation: true,
                                    recordPacketRanges: true,
                                    admitWorkspaceBytes: { delta in
                                        guard delta > 0 else { return }
                                        let (next, ov) = splitTransientWS.addingReportingOverflow(delta)
                                        guard !ov, next <= wsCap else {
                                            throw CodecError(.resourceLimitExceeded, "Reassembled 3D JPIP precinct split workspace exceeds resource limits.")
                                        }
                                        try observeAdmission(next, stage: "jp3d-reassembly-split-workspace")
                                        splitTransientWS = next
                                    },
                                    cancellation: {}
                                )
                                for pkt in splitPkts.packets where pkt.address.layer < totalLayers {
                                    let sliceBytes = try jp3dCheckedAdd(pkt.byteRange.count,
                                        3 * (MemoryLayout<Int>.stride + MemoryLayout<Data>.stride) + 96)
                                    // Split contributions and indexed ranges still coexist
                                    // with every retained slice until this scope exits.
                                    splitTransientWS = try jp3dCheckedAdd(splitTransientWS, sliceBytes)
                                    try observeAdmission(splitTransientWS, stage: "jp3d-reassembly-slice-overlap")
                                    try admitReassembleWS(sliceBytes)
                                    layerSlices[pkt.address.layer] = rawBin.subdata(in:
                                        (rawBin.startIndex + pkt.byteRange.lowerBound)..<(rawBin.startIndex + pkt.byteRange.upperBound))
                                }
                            } catch let ce as CodecError where ce.category == .resourceLimitExceeded {
                                throw ce
                            } catch {
                                // Tolerate malformed partial precinct payload during progressive reassembly.
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
                let nextOutput = try jp3dCheckedAdd(out.count, 16)
                try admitReassembleWS(nextOutput)
                StorageTelemetry.recordStage("jp3d-reassembly-output-growth", bytes: nextOutput)
                out.reserveCapacity(nextOutput)
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

            var tileBytes = 0
            try JP3DTier2Coder.forEachPacketAddress(
                geometries: geometries, progression: tileCOD.progressionOrderByte,
                totalLayers: totalLayers, admitWorkspaceBytes: admitReassembleWS
            ) { addr in
                let packet = perPrecinctLayerPackets[addr.component][addr.resolution][addr.precinct][addr.layer]
                let hasSOP = tileCOD.usesSOP && (packet?.count ?? 0) >= 6
                    && packet![packet!.startIndex] == 0xFF && packet![packet!.startIndex + 1] == 0x91
                let bytes = packet.map { $0.count + (tileCOD.usesSOP && !hasSOP ? 6 : 0) }
                    ?? ((tileCOD.usesSOP ? 6 : 0) + 1 + (tileCOD.usesEPH ? 2 : 0))
                tileBytes = try jp3dCheckedAdd(tileBytes, bytes)
                return true
            }
            let totalPartLen = try jp3dCheckedAdd(14, try jp3dCheckedAdd(thData.count, tileBytes))
            let nextOutput = try jp3dCheckedAdd(out.count, try jp3dCheckedAdd(totalPartLen, 2))
            guard totalPartLen <= Int(UInt32.max), nextOutput <= outCap else {
                throw CodecError(.resourceLimitExceeded, "Reassembled 3D JPIP codestream exceeds resource limits.")
            }
            try admitReassembleWS(try jp3dCheckedAdd(tileBytes, 32))
            StorageTelemetry.recordStage("jp3d-reassembly-tile-output", bytes: tileBytes)
            var tileBitstream = Data()
            tileBitstream.reserveCapacity(tileBytes)
            var sopSeq: UInt16 = 0
            try JP3DTier2Coder.forEachPacketAddress(
                geometries: geometries,
                progression: tileCOD.progressionOrderByte,
                totalLayers: totalLayers,
                admitWorkspaceBytes: nil
            ) { addr in
                if let pkt = perPrecinctLayerPackets[addr.component][addr.resolution][addr.precinct][addr.layer] {
                    let hasSOP = tileCOD.usesSOP && pkt.count >= 6 && pkt[pkt.startIndex] == 0xFF && pkt[pkt.startIndex + 1] == 0x91
                    let addedLen = hasSOP ? pkt.count : ((tileCOD.usesSOP ? 6 : 0) + pkt.count)
                    guard out.count + 16 + thData.count + tileBitstream.count + addedLen <= outCap else {
                        throw CodecError(.resourceLimitExceeded, "Reassembled 3D JPIP codestream exceeds resource limits.")
                    }
                    if hasSOP {
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
                    let addedLen = (tileCOD.usesSOP ? 6 : 0) + 1 + (tileCOD.usesEPH ? 2 : 0)
                    guard out.count + 16 + thData.count + tileBitstream.count + addedLen <= outCap else {
                        throw CodecError(.resourceLimitExceeded, "Reassembled 3D JPIP codestream exceeds resource limits.")
                    }
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
                return true
            }

            // Old output, geometry, layer slices and tileBitstream are still live
            // while reserveCapacity creates the new complete output allocation.
            try admitReassembleWS(nextOutput)
            StorageTelemetry.recordStage("jp3d-reassembly-output-growth", bytes: nextOutput)
            out.reserveCapacity(nextOutput)
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
