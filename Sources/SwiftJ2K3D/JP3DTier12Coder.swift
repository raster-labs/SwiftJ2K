// SPDX-License-Identifier: Apache-2.0
//
// JP3DTier12Coder.swift
// SwiftJ2K3D
//
// Normative ITU-T Rec. T.809 (05/2011) | ISO/IEC 15444-10:2011 (JP3D) 3D tile
// geometry, 3D octree tag-tree (Clause B.9.1), separable 3D 5-3 reversible and
// 9-7 irreversible wavelet transforms (Annex D), 3D quantisation (Annex E),
// Maxshift ROI (Annex F), 3D EBCOT Tier-1 bit-plane coding (Annex C, Table C.1),
// reconciled Part 10 + Part 15 HTJ2K block coding (zcb = 0, ITU-T T.814 Clause 7),
// 3D Tier-2 packet coding across all five normative progression orders
// (LRCP, RLCP, RPCL, PCRL, CPRL; Table A.5 / Clause B.10.1), and wavelet-domain
// EBCOT <-> HTJ2K lossless transcoding.

import Foundation
import SwiftJ2K

// MARK: - Checked Arithmetic Helpers

@inline(__always)
package func jp3dCheckedAdd(_ a: Int, _ b: Int, label: String = "JP3D integer addition") throws -> Int {
    let (res, ov) = a.addingReportingOverflow(b)
    guard !ov else {
        throw CodecError(.resourceLimitExceeded, "\(label) overflowed Int (\(a) + \(b)).")
    }
    return res
}

@inline(__always)
package func jp3dCheckedMul(_ a: Int, _ b: Int, label: String = "JP3D integer multiplication") throws -> Int {
    let (res, ov) = a.multipliedReportingOverflow(by: b)
    guard !ov else {
        throw CodecError(.resourceLimitExceeded, "\(label) overflowed Int (\(a) * \(b)).")
    }
    return res
}

@inline(__always)
package func jp3dFloorDiv(_ a: Int, _ b: Int) -> Int {
    precondition(b > 0)
    let q = a / b
    let r = a % b
    return (r != 0 && ((r < 0) != (b < 0))) ? (q - 1) : q
}

@inline(__always)
package func jp3dCeilDiv(_ a: Int, _ b: Int) -> Int {
    precondition(b > 0)
    return -jp3dFloorDiv(-a, b)
}

@inline(__always)
package func jp3dCeilDivPow2(_ a: Int, _ shift: Int) -> Int {
    guard shift > 0 else { return a }
    if shift >= Int.bitWidth - 1 {
        return a <= 0 ? 0 : 1
    }
    return jp3dCeilDiv(a, 1 << shift)
}

@inline(__always)
package func jp3dFloorDivPow2(_ a: Int, _ shift: Int) -> Int {
    guard shift > 0 else { return a }
    if shift >= Int.bitWidth - 1 {
        return a < 0 ? -1 : 0
    }
    return a >> shift
}

// MARK: - 3D Octree Tag-Tree (ITU-T T.809 Clause B.9.1)

/// Three-dimensional octree tag-tree grouping up to `2 x 2 x 2` nodes at each parent level
/// in `(x, y, z)` raster order (`x` fastest, `y` middle, `z` slowest).
package struct JP3DTagTree: Sendable {
    private struct Node: Sendable {
        var value: Int32 = 9999
        var low: Int32 = 0
        var known: Bool = false
        var parent: Int32 = -1
    }

    package let width: Int
    package let height: Int
    package let depth: Int
    private var nodes: [Node]

    package static func nodeCount(width: Int, height: Int, depth: Int) throws -> Int {
        guard width >= 0, height >= 0, depth >= 0 else {
            throw CodecError(.malformedInput, "Negative 3D tag-tree dimensions.")
        }
        let wh = try jp3dCheckedMul(width, height, label: "3D tag-tree leaf area")
        let leaves = try jp3dCheckedMul(wh, depth, label: "3D tag-tree leaf volume")
        if leaves == 0 { return 0 }
        var total = 0
        var w = width, h = height, d = depth
        while true {
            let levelCount = try jp3dCheckedMul(try jp3dCheckedMul(w, h), d, label: "3D tag-tree level nodes")
            total = try jp3dCheckedAdd(total, levelCount, label: "3D tag-tree total nodes")
            if levelCount <= 1 { break }
            w = (w + 1) >> 1
            h = (h + 1) >> 1
            d = (d + 1) >> 1
        }
        return total
    }

    package init(width: Int, height: Int, depth: Int) throws {
        self.width = width
        self.height = height
        self.depth = depth
        let total = try Self.nodeCount(width: width, height: height, depth: depth)
        if total == 0 {
            self.nodes = []
            return
        }
        var levelDims: [(w: Int, h: Int, d: Int, offset: Int)] = []
        var w = width, h = height, d = depth, offset = 0
        while true {
            levelDims.append((w, h, d, offset))
            let count = w * h * d
            offset += count
            if count <= 1 { break }
            w = (w + 1) >> 1
            h = (h + 1) >> 1
            d = (d + 1) >> 1
        }
        var built = [Node](repeating: Node(), count: total)
        for lvl in 0..<(levelDims.count - 1) {
            let cur = levelDims[lvl]
            let nxt = levelDims[lvl + 1]
            for z in 0..<cur.d {
                for y in 0..<cur.h {
                    for x in 0..<cur.w {
                        let childIdx = cur.offset + x + y * cur.w + z * cur.w * cur.h
                        let parentIdx = nxt.offset + (x >> 1) + (y >> 1) * nxt.w + (z >> 1) * nxt.w * nxt.h
                        built[childIdx].parent = Int32(parentIdx)
                    }
                }
            }
        }
        self.nodes = built
    }

    package func value(leaf: Int) -> Int32 {
        nodes[leaf].value
    }

    package mutating func setValue(leaf: Int, value: Int32) throws {
        guard leaf >= 0, leaf < width * height * depth, value >= 0 else {
            throw CodecError(.internalFailure, "3D tag-tree leaf index or value out of range.")
        }
        var idx = leaf
        while idx >= 0 {
            if nodes[idx].value > value {
                nodes[idx].value = value
            }
            idx = Int(nodes[idx].parent)
        }
    }

    private func chainToRoot(from leaf: Int) -> [Int] {
        var path: [Int] = []
        var idx = leaf
        while idx >= 0 {
            path.append(idx)
            idx = Int(nodes[idx].parent)
        }
        return path
    }

    package mutating func encode(writer: inout PacketBitWriter, leaf: Int, threshold: Int32) throws {
        guard leaf >= 0, leaf < width * height * depth else {
            throw CodecError(.internalFailure, "3D tag-tree leaf index out of range.")
        }
        let path = chainToRoot(from: leaf)
        var low: Int32 = 0
        for idx in path.reversed() {
            if nodes[idx].low > low {
                low = nodes[idx].low
            }
            while low < threshold {
                if low >= nodes[idx].value {
                    if !nodes[idx].known {
                        writer.writeBit(true)
                        nodes[idx].known = true
                    }
                    break
                }
                writer.writeBit(false)
                low += 1
            }
            nodes[idx].low = low
        }
    }

    package mutating func decode(reader: inout PacketBitReader, leaf: Int, threshold: Int32) throws -> Bool {
        guard leaf >= 0, leaf < width * height * depth else {
            throw CodecError(.malformedInput, "3D tag-tree leaf index out of range.")
        }
        let path = chainToRoot(from: leaf)
        var low: Int32 = 0
        for idx in path.reversed() {
            if nodes[idx].low > low {
                low = nodes[idx].low
            }
            while low < threshold && low < nodes[idx].value {
                if try reader.readBit() {
                    nodes[idx].value = low
                    nodes[idx].known = true
                } else {
                    low += 1
                }
            }
            nodes[idx].low = low
        }
        return nodes[leaf].value < threshold
    }
}

// MARK: - 3D Tile, Resolution, Morton Sub-Band, Precinct & Code-Block Geometry (Annex B)

package struct JP3DCodeBlockGeometry: Sendable, Equatable {
    package let x0: Int, y0: Int, z0: Int
    package let width: Int, height: Int, depth: Int
    package var voxelCount: Int { width * height * depth }
}

package struct JP3DPrecinctBandGeometry: Sendable {
    package let bandIndex: Int
    package let blocksWide: Int
    package let blocksHigh: Int
    package let blocksDeep: Int
    package let blocks: [JP3DCodeBlockGeometry]
}

package struct JP3DPrecinctGeometry: Sendable {
    package let px: Int, py: Int, pz: Int
    package let bands: [JP3DPrecinctBandGeometry]
    package var blockCount: Int { bands.reduce(0) { $0 + $1.blocks.count } }
}

package struct JP3DBandGeometry: Sendable {
    /// Normative Morton sub-band index (`0 = LLL`, `1 = HLL`, `2 = LHL`, `3 = HHL`,
    /// `4 = LLH`, `5 = HLH`, `6 = LHH`, `7 = HHH`).
    package let bandNumber: Int
    /// ITU-T T.809 Table C.1 XY context orientation (`bandNumber & 3`: `0->.ll, 1->.hl, 2->.lh, 3->.hh`).
    package let orientation: BandOrientation
    package let x0: Int, x1: Int
    package let y0: Int, y1: Int
    package let z0: Int, z1: Int
    /// Origin inside the tile-component's nested 3D wavelet buffer `(tileW x tileH x tileD)`.
    package let bufX: Int, bufY: Int, bufZ: Int
    /// Reversible sub-band log2 gain (`x0b + y0b + z0b` in `0...3`).
    package let gain: Int
    /// Sequential sub-band index into the `QCD`/`QCC` parameter array.
    package let quantizationIndex: Int

    package var width: Int { x1 - x0 }
    package var height: Int { y1 - y0 }
    package var depth: Int { z1 - z0 }
    package var isEmpty: Bool { width <= 0 || height <= 0 || depth <= 0 }
}

package struct JP3DResolutionGeometry: Sendable {
    package let index: Int
    package let x0: Int, x1: Int
    package let y0: Int, y1: Int
    package let z0: Int, z1: Int
    package let decompX: Int, decompY: Int, decompZ: Int
    package let axisActiveX: Bool, axisActiveY: Bool, axisActiveZ: Bool
    package let ppx: Int, ppy: Int, ppz: Int
    package let precinctsWide: Int, precinctsHigh: Int, precinctsDeep: Int
    package let bands: [JP3DBandGeometry]
    package let precincts: [JP3DPrecinctGeometry]

    package var width: Int { x1 - x0 }
    package var height: Int { y1 - y0 }
    package var depth: Int { z1 - z0 }
}

package struct JP3DTileComponentGeometry: Sendable {
    package let x0: Int, x1: Int
    package let y0: Int, y1: Int
    package let z0: Int, z1: Int
    package let levelsX: Int, levelsY: Int, levelsZ: Int
    package let maxLevels: Int
    package let resolutions: [JP3DResolutionGeometry]

    package var width: Int { x1 - x0 }
    package var height: Int { y1 - y0 }
    package var depth: Int { z1 - z0 }

    /// Expected total sub-band count across all resolutions (`1 + sum_{r=1..NL} activeDetailBands(r)`).
    package var totalSubbands: Int {
        resolutions.reduce(0) { $0 + $1.bands.count }
    }
}

package struct JP3DTileGeometryFootprint: Sendable {
    package let resolutionCount: Int
    package let bandCount: Int
    package let precinctCount: Int
    package let precinctBandCount: Int
    package let codeBlockCount: Int
    package let tagTreeNodeCount: Int
    package let geometryBytes: Int
    package let decodeStateBytes: Int
    package let encodeStateBytes: Int

    package var totalBytes: Int {
        let (s1, o1) = geometryBytes.addingReportingOverflow(decodeStateBytes)
        let (s2, o2) = s1.addingReportingOverflow(encodeStateBytes)
        return (o1 || o2) ? Int.max : s2
    }
}

package enum JP3DGeometryBuilder {
    /// Computes the normative Morton sub-band count for arbitrary `(levelsX, levelsY, levelsZ)`.
    package static func totalSubbandCount(levelsX: Int, levelsY: Int, levelsZ: Int) -> Int {
        let nl = max(levelsX, max(levelsY, levelsZ))
        if nl == 0 { return 1 }
        var total = 1 // r = 0: LLL
        for r in 1...nl {
            let step = nl - r
            let ax = step < levelsX ? 2 : 1
            let ay = step < levelsY ? 2 : 1
            let az = step < levelsZ ? 2 : 1
            total += (ax * ay * az - 1)
        }
        return total
    }

    /// Maps Morton sub-band index `0...7` to ITU-T T.809 Table C.1 XY context orientation.
    @inline(__always)
    package static func bandOrientation(for bandNumber: Int) -> BandOrientation {
        switch bandNumber & 3 {
        case 0: return .ll
        case 1: return .hl
        case 2: return .lh
        default: return .hh
        }
    }

    /// Preflights exact 3D resolution, sub-band, precinct, code-block and octree tag-tree node
    /// counts and nested array/state memory footprints using checked scalar arithmetic BEFORE
    /// allocating any geometry or Tier-2 state arrays.
    package static func preflightTileComponentGeometry(
        x0: Int, x1: Int,
        y0: Int, y1: Int,
        z0: Int, z1: Int,
        cod: JP3DCODInfo,
        maximumWorkspaceBytes: Int? = nil,
        includeDecodeState: Bool = false,
        includeEncodeState: Bool = false
    ) throws -> JP3DTileGeometryFootprint {
        guard x1 > x0, y1 > y0, z1 > z0 else {
            throw CodecError(.malformedInput, "Empty 3D tile-component bounds (\(x0)..<\(x1), \(y0)..<\(y1), \(z0)..<\(z1)).")
        }
        let lx = cod.levelsX, ly = cod.levelsY, lz = cod.levelsZ
        guard (0...32).contains(lx), (0...32).contains(ly), (0...32).contains(lz) else {
            throw CodecError(.malformedInput, "3D decomposition levels (\(lx), \(ly), \(lz)) out of range 0...32.")
        }
        let nl = max(lx, max(ly, lz))
        let rawXCB = cod.codeBlockWidthExponent
        let rawYCB = cod.codeBlockHeightExponent
        let rawZCB = cod.codeBlockDepthExponent
        guard (0...10).contains(rawXCB), (0...10).contains(rawYCB), (0...10).contains(rawZCB),
              rawXCB + rawYCB + rawZCB <= 18 else {
            throw CodecError(
                .malformedInput,
                "Invalid 3D code-block exponents (\(rawXCB), \(rawYCB), \(rawZCB)); sum must not exceed 18."
            )
        }
        if (cod.codeBlockStyle & 0x40) != 0 {
            guard rawZCB == 0, rawXCB >= 2, rawYCB >= 2, rawXCB + rawYCB <= 12 else {
                throw CodecError(
                    .malformedInput,
                    "HTJ2K-in-JP3D requires zcb == 0 and 2 <= xcb, ycb with xcb + ycb <= 12 (got \(rawXCB), \(rawYCB), \(rawZCB))."
                )
            }
        }

        let resolutionCount = nl + 1
        var bandCount = 0
        var precinctCount = 0
        var precinctBandCount = 0
        var codeBlockCount = 0
        var tagTreeNodeCount = 0
        var blockScratchBytes = 0
        let arrayHeader = 32
        let tagNodeStride = 16

        @inline(__always)
        func checkRunningFootprint() throws -> (geom: Int, dec: Int, enc: Int) {
            let resBytes = try jp3dCheckedMul(resolutionCount, MemoryLayout<JP3DResolutionGeometry>.stride + 2 * arrayHeader)
            let bandBytes = try jp3dCheckedMul(bandCount, MemoryLayout<JP3DBandGeometry>.stride)
            let prcBytes = try jp3dCheckedMul(precinctCount, MemoryLayout<JP3DPrecinctGeometry>.stride + arrayHeader)
            let pbBytes = try jp3dCheckedMul(precinctBandCount, MemoryLayout<JP3DPrecinctBandGeometry>.stride + arrayHeader)
            let cbBytes = try jp3dCheckedMul(codeBlockCount, MemoryLayout<JP3DCodeBlockGeometry>.stride)
            let g1 = try jp3dCheckedAdd(MemoryLayout<JP3DTileComponentGeometry>.stride + arrayHeader, resBytes)
            let g2 = try jp3dCheckedAdd(bandBytes, prcBytes)
            let g3 = try jp3dCheckedAdd(pbBytes, cbBytes)
            let geomBytes = try jp3dCheckedAdd(g1, try jp3dCheckedAdd(g2, g3))

            // Decode state holds `result` + `wireState` (`2 * CodeBlockContribution` per block) + `trees` (2 octree tag-trees per precinct-band).
            let decContrib = try jp3dCheckedMul(codeBlockCount, 2 * MemoryLayout<CodeBlockContribution>.stride + 2 * MemoryLayout<Bool>.stride)
            let decArrays = try jp3dCheckedAdd(
                try jp3dCheckedMul(precinctCount, 3 * arrayHeader),
                try jp3dCheckedMul(precinctBandCount, 4 * arrayHeader)
            )
            let treeBytes = try jp3dCheckedMul(tagTreeNodeCount, tagNodeStride)
            // Packet parsing holds a per-block order entry with pass-count and
            // length arrays. These arrays exist before segment-byte admission.
            let maximumBlockPasses = 3 * JP3DBitPlaneCoder.maximumExtendedBitPlanes - 2
            let packetOrderBytes = try jp3dCheckedMul(codeBlockCount,
                2 * maximumBlockPasses * MemoryLayout<Int>.stride + 3 * arrayHeader + 2 * MemoryLayout<Int>.stride)
            let nestedStateBytes = try jp3dCheckedAdd(
                try jp3dCheckedMul(resolutionCount, 5 * (arrayHeader + MemoryLayout<[Int]>.stride)),
                try jp3dCheckedMul(precinctBandCount, 2 * (arrayHeader + MemoryLayout<[Bool]>.stride)))
            let decBytes = try jp3dCheckedAdd(blockScratchBytes, try jp3dCheckedAdd(decContrib,
                try jp3dCheckedAdd(decArrays, try jp3dCheckedAdd(treeBytes,
                    try jp3dCheckedAdd(packetOrderBytes, nestedStateBytes)))))

            // Each retained block has per-pass offsets/termination offsets and a
            // per-layer count array, including empty blocks. Layer counts must
            // never disappear from admission just because packet order is lazy.
            let perBlockMetadata = try jp3dCheckedAdd(
                try jp3dCheckedMul(maximumBlockPasses * 2, MemoryLayout<Int>.stride),
                try jp3dCheckedMul(max(1, cod.numLayers), MemoryLayout<Int>.stride))
            let encEntries = try jp3dCheckedMul(
                codeBlockCount,
                try jp3dCheckedAdd(MemoryLayout<JP3DTier2Coder.BlockEncodingEntry>.stride + 4 * arrayHeader,
                    perBlockMetadata)
            )
            let encBytes = try jp3dCheckedAdd(blockScratchBytes, try jp3dCheckedAdd(encEntries,
                try jp3dCheckedAdd(decArrays, try jp3dCheckedAdd(treeBytes, packetOrderBytes))))

            if let limit = maximumWorkspaceBytes {
                var active = geomBytes
                if includeDecodeState {
                    active = try jp3dCheckedAdd(active, decBytes)
                }
                if includeEncodeState {
                    active = try jp3dCheckedAdd(active, encBytes)
                }
                guard active <= limit else {
                    throw CodecError(
                        .resourceLimitExceeded,
                        "3D tile-component geometry/Tier-2 state requires \(active) bytes, exceeding workspace budget of \(limit) bytes."
                    )
                }
            }
            return (geomBytes, decBytes, encBytes)
        }

        for r in 0...nl {
            let stepsFromFull = nl - r
            let dx = min(stepsFromFull, lx)
            let dy = min(stepsFromFull, ly)
            let dz = min(stepsFromFull, lz)
            let rx0 = jp3dCeilDivPow2(x0, dx), rx1 = jp3dCeilDivPow2(x1, dx)
            let ry0 = jp3dCeilDivPow2(y0, dy), ry1 = jp3dCeilDivPow2(y1, dy)
            let rz0 = jp3dCeilDivPow2(z0, dz), rz1 = jp3dCeilDivPow2(z1, dz)

            let step = nl - r
            let activeX = r > 0 && (step < lx)
            let activeY = r > 0 && (step < ly)
            let activeZ = r > 0 && (step < lz)

            let (ppx, ppy, ppz) = cod.precinctExponents(forResolution: r)
            guard (0...15).contains(ppx), (0...15).contains(ppy), (0...15).contains(ppz) else {
                throw CodecError(.malformedInput, "3D precinct exponents (\(ppx), \(ppy), \(ppz)) out of range 0...15.")
            }

            let tlprcx = jp3dFloorDivPow2(rx0, ppx) << ppx
            let tlprcy = jp3dFloorDivPow2(ry0, ppy) << ppy
            let tlprcz = jp3dFloorDivPow2(rz0, ppz) << ppz
            let brprcx = jp3dCeilDivPow2(rx1, ppx) << ppx
            let brprcy = jp3dCeilDivPow2(ry1, ppy) << ppy
            let brprcz = jp3dCeilDivPow2(rz1, ppz) << ppz

            let prcW = rx1 > rx0 ? max(1, (brprcx - tlprcx) >> ppx) : 0
            let prcH = ry1 > ry0 ? max(1, (brprcy - tlprcy) >> ppy) : 0
            let prcD = rz1 > rz0 ? max(1, (brprcz - tlprcz) >> ppz) : 0
            let totalPrecincts = try jp3dCheckedMul(try jp3dCheckedMul(prcW, prcH), prcD, label: "3D precinct count")
            guard totalPrecincts <= (1 << 22) else {
                throw CodecError(.resourceLimitExceeded, "3D precinct count \(totalPrecincts) exceeds safety ceiling.")
            }

            var bandBoxes: [(x0: Int, x1: Int, y0: Int, y1: Int, z0: Int, z1: Int)] = []
            if r == 0 {
                bandBoxes.append((rx0, rx1, ry0, ry1, rz0, rz1))
            } else {
                for bandNo in 1...7 {
                    let x0b = bandNo & 1
                    let y0b = (bandNo >> 1) & 1
                    let z0b = (bandNo >> 2) & 1
                    if (x0b == 1 && !activeX) || (y0b == 1 && !activeY) || (z0b == 1 && !activeZ) {
                        continue
                    }
                    let bx0 = activeX ? jp3dCeilDivPow2(x0 - (1 << dx) * x0b, dx + 1) : rx0
                    let bx1 = activeX ? jp3dCeilDivPow2(x1 - (1 << dx) * x0b, dx + 1) : rx1
                    let by0 = activeY ? jp3dCeilDivPow2(y0 - (1 << dy) * y0b, dy + 1) : ry0
                    let by1 = activeY ? jp3dCeilDivPow2(y1 - (1 << dy) * y0b, dy + 1) : ry1
                    let bz0 = activeZ ? jp3dCeilDivPow2(z0 - (1 << dz) * z0b, dz + 1) : rz0
                    let bz1 = activeZ ? jp3dCeilDivPow2(z1 - (1 << dz) * z0b, dz + 1) : rz1
                    bandBoxes.append((bx0, bx1, by0, by1, bz0, bz1))
                }
            }

            bandCount = try jp3dCheckedAdd(bandCount, bandBoxes.count)
            precinctCount = try jp3dCheckedAdd(precinctCount, totalPrecincts)
            precinctBandCount = try jp3dCheckedAdd(
                precinctBandCount,
                try jp3dCheckedMul(totalPrecincts, bandBoxes.count)
            )
            // Early budget check BEFORE iterating over precincts at resolution r!
            _ = try checkRunningFootprint()

            let cbgExpX = activeX ? max(0, ppx - 1) : ppx
            let cbgExpY = activeY ? max(0, ppy - 1) : ppy
            let cbgExpZ = activeZ ? max(0, ppz - 1) : ppz
            let tlcbgX = activeX ? jp3dCeilDivPow2(tlprcx, 1) : tlprcx
            let tlcbgY = activeY ? jp3dCeilDivPow2(tlprcy, 1) : tlprcy
            let tlcbgZ = activeZ ? jp3dCeilDivPow2(tlprcz, 1) : tlprcz
            let xcb = min(rawXCB, cbgExpX)
            let ycb = min(rawYCB, cbgExpY)
            let zcb = min(rawZCB, cbgExpZ)

            for pz in 0..<prcD {
                for py in 0..<prcH {
                    for px in 0..<prcW {
                        let cbgX0 = tlcbgX + px * (1 << cbgExpX)
                        let cbgY0 = tlcbgY + py * (1 << cbgExpY)
                        let cbgZ0 = tlcbgZ + pz * (1 << cbgExpZ)
                        let cbgX1 = cbgX0 + (1 << cbgExpX)
                        let cbgY1 = cbgY0 + (1 << cbgExpY)
                        let cbgZ1 = cbgZ0 + (1 << cbgExpZ)

                        for box in bandBoxes {
                            let px0 = max(cbgX0, box.x0), px1 = min(cbgX1, box.x1)
                            let py0 = max(cbgY0, box.y0), py1 = min(cbgY1, box.y1)
                            let pz0 = max(cbgZ0, box.z0), pz1 = min(cbgZ1, box.z1)
                            guard px1 > px0, py1 > py0, pz1 > pz0 else { continue }
                            let tlcblkX = jp3dFloorDivPow2(px0, xcb) << xcb
                            let tlcblkY = jp3dFloorDivPow2(py0, ycb) << ycb
                            let tlcblkZ = jp3dFloorDivPow2(pz0, zcb) << zcb
                            let brcblkX = jp3dCeilDivPow2(px1, xcb) << xcb
                            let brcblkY = jp3dCeilDivPow2(py1, ycb) << ycb
                            let brcblkZ = jp3dCeilDivPow2(pz1, zcb) << zcb
                            let cbW = max(1, (brcblkX - tlcblkX) >> xcb)
                            let cbH = max(1, (brcblkY - tlcblkY) >> ycb)
                            let cbD = max(1, (brcblkZ - tlcblkZ) >> zcb)
                            let blockCount = try jp3dCheckedMul(try jp3dCheckedMul(cbW, cbH), cbD, label: "3D code-block count")
                            let sampleW = min(1 << xcb, px1 - px0)
                            let sampleH = min(1 << ycb, py1 - py0)
                            let sampleD = min(1 << zcb, pz1 - pz0)
                            let blockSamples = try jp3dCheckedMul(try jp3dCheckedMul(sampleW, sampleH), sampleD)
                            let paddedStates = try jp3dCheckedMul(
                                try jp3dCheckedMul(sampleW + 2, sampleH + 2), sampleD)
                            // One live block: gathered coefficients, magnitudes,
                            // sign/refinement flags and returned coefficients, plus
                            // padded state planes. Tile-wide wavelet planes are separate.
                            let blockBytes = try jp3dCheckedAdd(
                                try jp3dCheckedMul(blockSamples, 32),
                                try jp3dCheckedAdd(try jp3dCheckedMul(paddedStates, 2), 512))
                            blockScratchBytes = max(blockScratchBytes, blockBytes)
                            codeBlockCount = try jp3dCheckedAdd(codeBlockCount, blockCount, label: "Total 3D code-blocks")
                            guard codeBlockCount <= (1 << 24) else {
                                throw CodecError(.resourceLimitExceeded, "3D tile code-block count \(codeBlockCount) exceeds safety ceiling.")
                            }
                            let treeNodes = try JP3DTagTree.nodeCount(width: cbW, height: cbH, depth: cbD)
                            tagTreeNodeCount = try jp3dCheckedAdd(
                                tagTreeNodeCount,
                                try jp3dCheckedMul(treeNodes, 2, label: "3D tag-tree pair nodes"),
                                label: "Total 3D tag-tree nodes"
                            )
                        }
                        if ((px + py * prcW + pz * prcW * prcH) & 63) == 63 {
                            _ = try checkRunningFootprint()
                        }
                    }
                }
            }
            _ = try checkRunningFootprint()
        }

        let totals = try checkRunningFootprint()
        return JP3DTileGeometryFootprint(
            resolutionCount: resolutionCount,
            bandCount: bandCount,
            precinctCount: precinctCount,
            precinctBandCount: precinctBandCount,
            codeBlockCount: codeBlockCount,
            tagTreeNodeCount: tagTreeNodeCount,
            geometryBytes: totals.geom,
            decodeStateBytes: includeDecodeState ? totals.dec : 0,
            encodeStateBytes: includeEncodeState ? totals.enc : 0
        )
    }

    /// Builds complete 3D tile-component geometry with checked bounds before allocation.
    package static func makeTileComponentGeometry(
        x0: Int, x1: Int,
        y0: Int, y1: Int,
        z0: Int, z1: Int,
        cod: JP3DCODInfo
    ) throws -> JP3DTileComponentGeometry {
        guard x1 > x0, y1 > y0, z1 > z0 else {
            throw CodecError(.malformedInput, "Empty 3D tile-component bounds (\(x0)..<\(x1), \(y0)..<\(y1), \(z0)..<\(z1)).")
        }
        let lx = cod.levelsX, ly = cod.levelsY, lz = cod.levelsZ
        guard (0...32).contains(lx), (0...32).contains(ly), (0...32).contains(lz) else {
            throw CodecError(.malformedInput, "3D decomposition levels (\(lx), \(ly), \(lz)) out of range 0...32.")
        }
        let nl = max(lx, max(ly, lz))

        // Validate code-block exponents (`shift = 0` in Part 10: Table A.9).
        let rawXCB = cod.codeBlockWidthExponent
        let rawYCB = cod.codeBlockHeightExponent
        let rawZCB = cod.codeBlockDepthExponent
        guard (0...10).contains(rawXCB), (0...10).contains(rawYCB), (0...10).contains(rawZCB),
              rawXCB + rawYCB + rawZCB <= 18 else {
            throw CodecError(
                .malformedInput,
                "Invalid 3D code-block exponents (\(rawXCB), \(rawYCB), \(rawZCB)); sum must not exceed 18."
            )
        }
        // Reconciled HT-in-JP3D requires zcb == 0 (depth 1 slices mapped to T.814 2D quads) and xcb,ycb in 2...10 with xcb+ycb <= 12.
        if (cod.codeBlockStyle & 0x40) != 0 {
            guard rawZCB == 0, rawXCB >= 2, rawYCB >= 2, rawXCB + rawYCB <= 12 else {
                throw CodecError(
                    .malformedInput,
                    "HTJ2K-in-JP3D requires zcb == 0 and 2 <= xcb, ycb with xcb + ycb <= 12 (got \(rawXCB), \(rawYCB), \(rawZCB))."
                )
            }
        }

        // Precompute resolution bounds r = 0...nl.
        var resBounds: [(x0: Int, x1: Int, y0: Int, y1: Int, z0: Int, z1: Int, dx: Int, dy: Int, dz: Int)] = []
        resBounds.reserveCapacity(nl + 1)
        for r in 0...nl {
            let stepsFromFull = nl - r
            let dx = min(stepsFromFull, lx)
            let dy = min(stepsFromFull, ly)
            let dz = min(stepsFromFull, lz)
            resBounds.append((
                x0: jp3dCeilDivPow2(x0, dx), x1: jp3dCeilDivPow2(x1, dx),
                y0: jp3dCeilDivPow2(y0, dy), y1: jp3dCeilDivPow2(y1, dy),
                z0: jp3dCeilDivPow2(z0, dz), z1: jp3dCeilDivPow2(z1, dz),
                dx: dx, dy: dy, dz: dz
            ))
        }

        var resolutions: [JP3DResolutionGeometry] = []
        resolutions.reserveCapacity(nl + 1)
        var qIndex = 0
        var totalBlocks = 0

        for r in 0...nl {
            let rb = resBounds[r]
            let step = nl - r
            let activeX = r > 0 && (step < lx)
            let activeY = r > 0 && (step < ly)
            let activeZ = r > 0 && (step < lz)

            let (ppx, ppy, ppz) = cod.precinctExponents(forResolution: r)
            guard (0...15).contains(ppx), (0...15).contains(ppy), (0...15).contains(ppz) else {
                throw CodecError(.malformedInput, "3D precinct exponents (\(ppx), \(ppy), \(ppz)) out of range 0...15.")
            }

            let tlprcx = jp3dFloorDivPow2(rb.x0, ppx) << ppx
            let tlprcy = jp3dFloorDivPow2(rb.y0, ppy) << ppy
            let tlprcz = jp3dFloorDivPow2(rb.z0, ppz) << ppz
            let brprcx = jp3dCeilDivPow2(rb.x1, ppx) << ppx
            let brprcy = jp3dCeilDivPow2(rb.y1, ppy) << ppy
            let brprcz = jp3dCeilDivPow2(rb.z1, ppz) << ppz

            let prcW = rb.x1 > rb.x0 ? max(1, (brprcx - tlprcx) >> ppx) : 0
            let prcH = rb.y1 > rb.y0 ? max(1, (brprcy - tlprcy) >> ppy) : 0
            let prcD = rb.z1 > rb.z0 ? max(1, (brprcz - tlprcz) >> ppz) : 0
            let totalPrecincts = try jp3dCheckedMul(try jp3dCheckedMul(prcW, prcH), prcD, label: "3D precinct count")
            guard totalPrecincts <= (1 << 22) else {
                throw CodecError(.resourceLimitExceeded, "3D precinct count \(totalPrecincts) exceeds safety ceiling.")
            }

            let cbgExpX = activeX ? max(0, ppx - 1) : ppx
            let cbgExpY = activeY ? max(0, ppy - 1) : ppy
            let cbgExpZ = activeZ ? max(0, ppz - 1) : ppz
            let tlcbgX = activeX ? jp3dCeilDivPow2(tlprcx, 1) : tlprcx
            let tlcbgY = activeY ? jp3dCeilDivPow2(tlprcy, 1) : tlprcy
            let tlcbgZ = activeZ ? jp3dCeilDivPow2(tlprcz, 1) : tlprcz

            let xcb = min(rawXCB, cbgExpX)
            let ycb = min(rawYCB, cbgExpY)
            let zcb = min(rawZCB, cbgExpZ)

            var bands: [JP3DBandGeometry] = []
            if r == 0 {
                bands.append(JP3DBandGeometry(
                    bandNumber: 0,
                    orientation: .ll,
                    x0: rb.x0, x1: rb.x1,
                    y0: rb.y0, y1: rb.y1,
                    z0: rb.z0, z1: rb.z1,
                    bufX: 0, bufY: 0, bufZ: 0,
                    gain: 0,
                    quantizationIndex: qIndex
                ))
                qIndex += 1
            } else {
                let prevRB = resBounds[r - 1]
                let lowW = prevRB.x1 - prevRB.x0
                let lowH = prevRB.y1 - prevRB.y0
                let lowD = prevRB.z1 - prevRB.z0
                for bandNo in 1...7 {
                    let x0b = bandNo & 1
                    let y0b = (bandNo >> 1) & 1
                    let z0b = (bandNo >> 2) & 1
                    if (x0b == 1 && !activeX) || (y0b == 1 && !activeY) || (z0b == 1 && !activeZ) {
                        continue
                    }
                    let bx0 = activeX ? jp3dCeilDivPow2(x0 - (1 << rb.dx) * x0b, rb.dx + 1) : rb.x0
                    let bx1 = activeX ? jp3dCeilDivPow2(x1 - (1 << rb.dx) * x0b, rb.dx + 1) : rb.x1
                    let by0 = activeY ? jp3dCeilDivPow2(y0 - (1 << rb.dy) * y0b, rb.dy + 1) : rb.y0
                    let by1 = activeY ? jp3dCeilDivPow2(y1 - (1 << rb.dy) * y0b, rb.dy + 1) : rb.y1
                    let bz0 = activeZ ? jp3dCeilDivPow2(z0 - (1 << rb.dz) * z0b, rb.dz + 1) : rb.z0
                    let bz1 = activeZ ? jp3dCeilDivPow2(z1 - (1 << rb.dz) * z0b, rb.dz + 1) : rb.z1

                    bands.append(JP3DBandGeometry(
                        bandNumber: bandNo,
                        orientation: bandOrientation(for: bandNo),
                        x0: bx0, x1: bx1,
                        y0: by0, y1: by1,
                        z0: bz0, z1: bz1,
                        bufX: x0b == 1 ? lowW : 0,
                        bufY: y0b == 1 ? lowH : 0,
                        bufZ: z0b == 1 ? lowD : 0,
                        gain: x0b + y0b + z0b,
                        quantizationIndex: qIndex
                    ))
                    qIndex += 1
                }
            }

            var precincts: [JP3DPrecinctGeometry] = []
            precincts.reserveCapacity(totalPrecincts)
            for pz in 0..<prcD {
                for py in 0..<prcH {
                    for px in 0..<prcW {
                        let cbgX0 = tlcbgX + px * (1 << cbgExpX)
                        let cbgY0 = tlcbgY + py * (1 << cbgExpY)
                        let cbgZ0 = tlcbgZ + pz * (1 << cbgExpZ)
                        let cbgX1 = cbgX0 + (1 << cbgExpX)
                        let cbgY1 = cbgY0 + (1 << cbgExpY)
                        let cbgZ1 = cbgZ0 + (1 << cbgExpZ)

                        var pBands: [JP3DPrecinctBandGeometry] = []
                        pBands.reserveCapacity(bands.count)
                        for (bIdx, band) in bands.enumerated() {
                            let px0 = max(cbgX0, band.x0), px1 = min(cbgX1, band.x1)
                            let py0 = max(cbgY0, band.y0), py1 = min(cbgY1, band.y1)
                            let pz0 = max(cbgZ0, band.z0), pz1 = min(cbgZ1, band.z1)
                            guard px1 > px0, py1 > py0, pz1 > pz0 else {
                                pBands.append(JP3DPrecinctBandGeometry(
                                    bandIndex: bIdx, blocksWide: 0, blocksHigh: 0, blocksDeep: 0, blocks: []
                                ))
                                continue
                            }
                            let tlcblkX = jp3dFloorDivPow2(px0, xcb) << xcb
                            let tlcblkY = jp3dFloorDivPow2(py0, ycb) << ycb
                            let tlcblkZ = jp3dFloorDivPow2(pz0, zcb) << zcb
                            let brcblkX = jp3dCeilDivPow2(px1, xcb) << xcb
                            let brcblkY = jp3dCeilDivPow2(py1, ycb) << ycb
                            let brcblkZ = jp3dCeilDivPow2(pz1, zcb) << zcb

                            let cbW = max(1, (brcblkX - tlcblkX) >> xcb)
                            let cbH = max(1, (brcblkY - tlcblkY) >> ycb)
                            let cbD = max(1, (brcblkZ - tlcblkZ) >> zcb)
                            let blockCount = try jp3dCheckedMul(try jp3dCheckedMul(cbW, cbH), cbD, label: "3D code-block count")
                            totalBlocks = try jp3dCheckedAdd(totalBlocks, blockCount, label: "Total 3D code-blocks")
                            guard totalBlocks <= (1 << 24) else {
                                throw CodecError(.resourceLimitExceeded, "3D tile code-block count \(totalBlocks) exceeds safety ceiling.")
                            }

                            var blocks: [JP3DCodeBlockGeometry] = []
                            blocks.reserveCapacity(blockCount)
                            for cz in 0..<cbD {
                                for cy in 0..<cbH {
                                    for cx in 0..<cbW {
                                        let gx0 = tlcblkX + cx * (1 << xcb)
                                        let gy0 = tlcblkY + cy * (1 << ycb)
                                        let gz0 = tlcblkZ + cz * (1 << zcb)
                                        let bx0 = max(gx0, px0), bx1 = min(gx0 + (1 << xcb), px1)
                                        let by0 = max(gy0, py0), by1 = min(gy0 + (1 << ycb), py1)
                                        let bz0 = max(gz0, pz0), bz1 = min(gz0 + (1 << zcb), pz1)
                                        blocks.append(JP3DCodeBlockGeometry(
                                            x0: bx0, y0: by0, z0: bz0,
                                            width: max(0, bx1 - bx0),
                                            height: max(0, by1 - by0),
                                            depth: max(0, bz1 - bz0)
                                        ))
                                    }
                                }
                            }
                            pBands.append(JP3DPrecinctBandGeometry(
                                bandIndex: bIdx,
                                blocksWide: cbW,
                                blocksHigh: cbH,
                                blocksDeep: cbD,
                                blocks: blocks
                            ))
                        }
                        precincts.append(JP3DPrecinctGeometry(px: px, py: py, pz: pz, bands: pBands))
                    }
                }
            }

            resolutions.append(JP3DResolutionGeometry(
                index: r,
                x0: rb.x0, x1: rb.x1,
                y0: rb.y0, y1: rb.y1,
                z0: rb.z0, z1: rb.z1,
                decompX: rb.dx, decompY: rb.dy, decompZ: rb.dz,
                axisActiveX: activeX, axisActiveY: activeY, axisActiveZ: activeZ,
                ppx: ppx, ppy: ppy, ppz: ppz,
                precinctsWide: prcW, precinctsHigh: prcH, precinctsDeep: prcD,
                bands: bands,
                precincts: precincts
            ))
        }
        StorageTelemetry.recordStage(
            "jp3d-tile-geometry",
            bytes: totalBlocks * MemoryLayout<JP3DCodeBlockGeometry>.stride
        )

        return JP3DTileComponentGeometry(
            x0: x0, x1: x1,
            y0: y0, y1: y1,
            z0: z0, z1: z1,
            levelsX: lx, levelsY: ly, levelsZ: lz,
            maxLevels: nl,
            resolutions: resolutions
        )
    }
}

// MARK: - 3D EBCOT Tier-1 Bit-Plane Coder (ITU-T T.809 Annex C)

package enum JP3DBitPlaneCoder {
    /// Maximum coefficients per 3D code-block (`xcb + ycb + zcb <= 18` -> `2^18 = 262,144`).
    package static let maximum3DCoefficients = 1 << 18
    package static let maximumExtendedBitPlanes = 62

    private enum EncodeCoder {
        case mq(MQEncoder)
        case raw(RawEncoder)
    }

    private enum DecodeCoder {
        case mq(MQDecoder)
        case raw(RawDecoder)
    }

    /// Encodes a 3D code-block (`width x height x depth`, stored `x` fastest, `y` middle, `z` slowest)
    /// per ITU-T Rec. T.809 Annex C:
    /// - outer scan across slices `z = 0..<depth`,
    /// - 4-row vertical stripes `y` across columns `x` within each Z slice,
    /// - independent 8-neighbour XY `StatePlane` per Z slice,
    /// - single shared 19-state `ContextSet` and `MQEncoder`/`RawEncoder` across the entire 3D code-block.
    package static func encode3D(
        coefficients: [Int64],
        width: Int,
        height: Int,
        depth: Int,
        orientation: BandOrientation,
        magnitudeBitPlanes mb: Int,
        style: CodeBlockStyle = .default,
        maxPasses: Int? = nil,
        qualityLayers: Int = 1,
        maximumOutputBytes: Int = Int.max,
        budget: EntropyOutputBudget? = nil
    ) throws -> CodeBlockEncoding {
        let wh = try jp3dCheckedMul(width, height, label: "3D code-block slice area")
        let count = try jp3dCheckedMul(wh, depth, label: "3D code-block volume")
        guard width > 0, height > 0, depth > 0,
              count <= maximum3DCoefficients,
              coefficients.count == count,
              mb >= 1, mb <= maximumExtendedBitPlanes else {
            throw CodecError(.internalFailure, "3D code-block geometry (\(width)x\(height)x\(depth)) or Mb=\(mb) out of range.")
        }

        var magnitudes = [UInt64](repeating: 0, count: count)
        var negFlags = [Bool](repeating: false, count: count)
        var maximum: UInt64 = 0
        for i in 0..<count {
            let value = coefficients[i]
            let neg = value < 0
            let mag = neg ? UInt64(bitPattern: 0 &- value) : UInt64(value)
            if mag > maximum { maximum = mag }
            magnitudes[i] = mag
            negFlags[i] = neg
        }

        let bitPlanes = maximum == 0 ? 0 : (UInt64.bitWidth - maximum.leadingZeroBitCount)
        guard bitPlanes <= mb else {
            throw CodecError(.invalidArgument, "3D wavelet coefficient requires \(bitPlanes) bit-planes, exceeding band Mb=\(mb).")
        }
        let layers = max(1, qualityLayers)
        if bitPlanes == 0 || (maxPasses != nil && maxPasses! <= 0) {
            return CodeBlockEncoding(
                data: [],
                passCount: 0,
                zeroBitPlanes: mb,
                layerPassCounts: [Int](repeating: 0, count: layers)
            )
        }
        guard maximumOutputBytes > 0 else {
            throw CodecError(.resourceLimitExceeded, "Encoded 3D code-block exceeds output byte budget.")
        }

        let totalAvailablePasses = 3 * bitPlanes - 2
        let targetPasses = min(totalAvailablePasses, maxPasses ?? totalAvailablePasses)

        // When multiple quality layers are requested and terminateAll is not already set,
        // partition passes monotonically across layers. Notice that MQ codeword segments
        // need NOT terminate between layers in JPEG 2000 (ISO/IEC 15444-1 B.10.7): a single
        // continuous MQ segment is split at monotonically non-decreasing `passByteOffsets`!
        let tables = ContextTables(orientation: orientation)
        var sliceStates = [StatePlane](repeating: StatePlane(width: width, height: height), count: depth)
        var contexts = ContextSet()

        var committedData: [UInt8] = []
        var activeCoder: EncodeCoder? = nil
        var succeeded = false
        defer {
            if !succeeded {
                switch activeCoder {
                case .mq(var mq):
                    mq.releaseAllReservedBudget()
                case .raw(var raw):
                    raw.releaseAllReservedBudget()
                case nil:
                    break
                }
                if !committedData.isEmpty {
                    budget?.release(committedData.count, countsTowardCompressedOutput: true)
                }
            }
        }
        var passByteOffsets: [Int] = []
        var passTerminatedBytes: [Int] = []
        passByteOffsets.reserveCapacity(targetPasses)
        passTerminatedBytes.reserveCapacity(targetPasses)

        var passIndex = 0

        func beginPass() {
            if activeCoder == nil {
                let remCap = max(1, maximumOutputBytes - committedData.count)
                if style.passIsRaw(passIndex) {
                    activeCoder = .raw(RawEncoder(maximumOutputBytes: remCap, budget: budget))
                } else {
                    activeCoder = .mq(MQEncoder(
                        capacityHint: min(remCap, max(8, count * 2)),
                        maximumOutputBytes: remCap,
                        budget: budget
                    ))
                }
            }
        }

        func finishPass() throws {
            let isLastPass = (passIndex + 1 == targetPasses)
            let terminates = style.passTerminates(passIndex) || isLastPass
            switch activeCoder! {
            case .mq(var mq):
                if mq.overflowed {
                    activeCoder = .mq(mq)
                    throw CodecError(.resourceLimitExceeded, "Encoded 3D code-block exceeds output byte budget.")
                }
                let termLen = committedData.count + mq.terminatedByteCount()
                if terminates {
                    activeCoder = nil
                    var seg = mq.finish()
                    if mq.overflowed || committedData.count + seg.count > maximumOutputBytes {
                        mq.releaseAllReservedBudget()
                        throw CodecError(.resourceLimitExceeded, "Encoded 3D code-block exceeds output byte budget.")
                    }
                    if committedData.isEmpty {
                        committedData = seg
                    } else if !seg.isEmpty {
                        let mergeBytes = try jp3dCheckedAdd(committedData.count, seg.count, label: "3D EBCOT segment concatenation")
                        if let budget {
                            do {
                                try budget.reserve(mergeBytes, countsTowardCompressedOutput: false, site: "jp3d-ebcot-segment-merge")
                            } catch {
                                mq.releaseAllReservedBudget()
                                throw error
                            }
                            budget.recordActualAllocation(mergeBytes, site: "jp3d-ebcot-segment-merge")
                        }
                        committedData.reserveCapacity(mergeBytes)
                        committedData.append(contentsOf: seg)
                        seg = []
                        mq.discardFinishedStorage()
                        budget?.release(mergeBytes, countsTowardCompressedOutput: false)
                    }
                    mq.discardFinishedStorage()
                    passByteOffsets.append(committedData.count)
                    passTerminatedBytes.append(committedData.count)
                } else {
                    passByteOffsets.append(committedData.count + mq.emittedByteCount)
                    passTerminatedBytes.append(termLen)
                    activeCoder = .mq(mq)
                }
            case .raw(var raw):
                if raw.overflowed {
                    activeCoder = .raw(raw)
                    throw CodecError(.resourceLimitExceeded, "Encoded 3D code-block exceeds output byte budget.")
                }
                if terminates {
                    activeCoder = nil
                    var seg = raw.finish()
                    if raw.overflowed || committedData.count + seg.count > maximumOutputBytes {
                        raw.releaseAllReservedBudget()
                        throw CodecError(.resourceLimitExceeded, "Encoded 3D code-block exceeds output byte budget.")
                    }
                    if committedData.isEmpty {
                        committedData = seg
                    } else if !seg.isEmpty {
                        let mergeBytes = try jp3dCheckedAdd(committedData.count, seg.count, label: "3D EBCOT segment concatenation")
                        if let budget {
                            do {
                                try budget.reserve(mergeBytes, countsTowardCompressedOutput: false, site: "jp3d-ebcot-segment-merge")
                            } catch {
                                raw.releaseAllReservedBudget()
                                throw error
                            }
                            budget.recordActualAllocation(mergeBytes, site: "jp3d-ebcot-segment-merge")
                        }
                        committedData.reserveCapacity(mergeBytes)
                        committedData.append(contentsOf: seg)
                        seg = []
                        raw.discardFinishedStorage()
                        budget?.release(mergeBytes, countsTowardCompressedOutput: false)
                    }
                    raw.discardFinishedStorage()
                    passByteOffsets.append(committedData.count)
                    passTerminatedBytes.append(committedData.count)
                } else {
                    let cur = committedData.count + raw.emittedByteCount
                    passByteOffsets.append(cur)
                    passTerminatedBytes.append(cur)
                    activeCoder = .raw(raw)
                }
            }
            if style.reset {
                contexts = ContextSet()
            }
            passIndex += 1
        }

        planes: for plane in stride(from: bitPlanes - 1, through: 0, by: -1) {
            let mask = UInt64(1) << UInt64(plane)
            if plane != bitPlanes - 1 {
                if passIndex == targetPasses { break planes }
                beginPass()
                encodeSigPass3D(
                    mask: mask, width: width, height: height, depth: depth,
                    magnitudes: magnitudes, negFlags: negFlags,
                    sliceStates: &sliceStates, tables: tables, contexts: &contexts,
                    coder: &activeCoder!, causal: style.causal
                )
                try finishPass()

                if passIndex == targetPasses { break planes }
                beginPass()
                encodeRefPass3D(
                    mask: mask, width: width, height: height, depth: depth,
                    magnitudes: magnitudes, sliceStates: &sliceStates,
                    contexts: &contexts, coder: &activeCoder!, causal: style.causal
                )
                try finishPass()
            }

            if passIndex == targetPasses { break planes }
            beginPass()
            guard case .mq(var mq) = activeCoder! else {
                throw CodecError(.internalFailure, "3D cleanup pass requires MQ arithmetic coder.")
            }
            encodeCleanupPass3D(
                mask: mask, width: width, height: height, depth: depth,
                magnitudes: magnitudes, negFlags: negFlags,
                sliceStates: &sliceStates, tables: tables, contexts: &contexts,
                encoder: &mq, causal: style.causal, segmentationSymbols: style.segmentationSymbols
            )
            activeCoder = .mq(mq)
            try finishPass()
            for z in 0..<depth {
                sliceStates[z].clearVisited()
            }
        }

        for i in 0..<passByteOffsets.count {
            if passByteOffsets[i] > committedData.count {
                passByteOffsets[i] = committedData.count
            }
            if i > 0 && passByteOffsets[i] < passByteOffsets[i - 1] {
                passByteOffsets[i] = passByteOffsets[i - 1]
            }
        }
        if !passByteOffsets.isEmpty {
            passByteOffsets[passByteOffsets.count - 1] = committedData.count
        }

        let layerPassCounts = distributePassesAcrossLayers(totalPasses: passIndex, layers: layers)
        succeeded = true

        return CodeBlockEncoding(
            data: committedData,
            passCount: passIndex,
            zeroBitPlanes: mb - bitPlanes,
            passByteOffsets: passByteOffsets,
            passTerminatedBytes: passTerminatedBytes,
            layerPassCounts: layerPassCounts
        )
    }

    /// Distributes `totalPasses` monotonically across `layers` quality layers so progressive
    /// layer prefix decodes refine quality monotonically from coarse MSBs to exact LSBs.
    package static func distributePassesAcrossLayers(totalPasses: Int, layers: Int) -> [Int] {
        guard layers > 1 else { return [totalPasses] }
        guard totalPasses > 0 else { return [Int](repeating: 0, count: layers) }
        var counts = [Int](repeating: 0, count: layers)
        var assigned = 0
        for l in 0..<layers {
            let targetCumulative = ((l + 1) * totalPasses + layers - 1) / layers
            let clamped = min(totalPasses, max(assigned, targetCumulative))
            counts[l] = clamped - assigned
            assigned = clamped
        }
        if assigned < totalPasses {
            counts[layers - 1] += (totalPasses - assigned)
        }
        return counts
    }

    /// Decodes a 3D code-block (`width x height x depth`) per ITU-T Rec. T.809 Annex C.
    package static func decode3D(
        segments: [CodewordSegment],
        width: Int,
        height: Int,
        depth: Int,
        orientation: BandOrientation,
        zeroBitPlanes: Int,
        passCount: Int,
        magnitudeBitPlanes mb: Int,
        style: CodeBlockStyle,
        midpointReconstruction: Bool = false
    ) throws -> [Int64] {
        let wh = try jp3dCheckedMul(width, height, label: "3D decode code-block slice area")
        let count = try jp3dCheckedMul(wh, depth, label: "3D decode code-block volume")
        guard width > 0, height > 0, depth > 0,
              count <= maximum3DCoefficients,
              mb >= 1, mb <= maximumExtendedBitPlanes else {
            throw CodecError(.malformedInput, "3D code-block geometry (\(width)x\(height)x\(depth)) or Mb=\(mb) out of range.")
        }
        if passCount == 0 {
            return [Int64](repeating: 0, count: count)
        }
        let bitPlanes = mb - zeroBitPlanes
        guard zeroBitPlanes >= 0, bitPlanes >= 1, passCount <= 3 * bitPlanes - 2 else {
            throw CodecError(
                .malformedInput,
                "3D code-block signals invalid passCount=\(passCount) or zeroBitPlanes=\(zeroBitPlanes) for Mb=\(mb)."
            )
        }
        guard segments.reduce(0, { $0 + $1.passes }) == passCount else {
            throw CodecError(.malformedInput, "3D codeword segments do not match signalled pass count \(passCount).")
        }

        let tables = ContextTables(orientation: orientation)
        var sliceStates = [StatePlane](repeating: StatePlane(width: width, height: height), count: depth)
        var contexts = ContextSet()
        var magnitudes = [UInt64](repeating: 0, count: count)
        var lastUpdatedPlanes = [Int8](repeating: -1, count: count)
        var coder: DecodeCoder? = nil
        var segmentIndex = 0
        var passIndex = 0

        func beginPassIfNeeded() throws {
            guard passIndex == 0 || style.passTerminates(passIndex - 1) else { return }
            guard segmentIndex < segments.count else {
                throw CodecError(.malformedInput, "Missing codeword segment for 3D coding pass \(passIndex).")
            }
            let seg = segments[segmentIndex]
            segmentIndex += 1
            coder = style.passIsRaw(passIndex)
                ? .raw(RawDecoder(bytes: seg.data))
                : .mq(try MQDecoder(bytes: seg.data, start: 0, end: seg.data.count))
        }

        func endPass() {
            passIndex += 1
            if style.reset {
                contexts = ContextSet()
            }
        }

        planes: for plane in stride(from: bitPlanes - 1, through: 0, by: -1) {
            let mask = UInt64(1) << UInt64(plane)
            let planeInt8 = Int8(plane)
            if plane != bitPlanes - 1 {
                if passIndex == passCount { break planes }
                try beginPassIfNeeded()
                decodeSigPass3D(
                    mask: mask, plane: planeInt8, width: width, height: height, depth: depth,
                    magnitudes: &magnitudes, lastPlanes: &lastUpdatedPlanes,
                    sliceStates: &sliceStates, tables: tables, contexts: &contexts,
                    coder: &coder!, causal: style.causal
                )
                endPass()

                if passIndex == passCount { break planes }
                try beginPassIfNeeded()
                decodeRefPass3D(
                    mask: mask, plane: planeInt8, width: width, height: height, depth: depth,
                    magnitudes: &magnitudes, lastPlanes: &lastUpdatedPlanes,
                    sliceStates: &sliceStates, contexts: &contexts,
                    coder: &coder!, causal: style.causal
                )
                endPass()
            }

            if passIndex == passCount { break planes }
            try beginPassIfNeeded()
            guard case .mq(var mq) = coder! else {
                throw CodecError(.malformedInput, "3D cleanup pass fell inside a raw bypass segment.")
            }
            decodeCleanupPass3D(
                mask: mask, plane: planeInt8, width: width, height: height, depth: depth,
                magnitudes: &magnitudes, lastPlanes: &lastUpdatedPlanes,
                sliceStates: &sliceStates, tables: tables, contexts: &contexts,
                decoder: &mq, causal: style.causal
            )
            if style.segmentationSymbols {
                var sym = 0
                for _ in 0..<4 {
                    sym = (sym << 1) | (mq.decode(context: &contexts.contexts[Int(ContextLabel.uniform)]) ? 1 : 0)
                }
                guard sym == 0b1010 else {
                    throw CodecError(.malformedInput, "3D segmentation symbol mismatch (0x\(String(sym, radix: 16)) != 0xa).")
                }
            }
            coder = .mq(mq)
            endPass()
            for z in 0..<depth {
                sliceStates[z].clearVisited()
            }
        }

        var out = [Int64](repeating: 0, count: count)
        for z in 0..<depth {
            let zBase = z * wh
            let st = sliceStates[z]
            for y in 0..<height {
                let yBase = zBase + y * width
                for x in 0..<width {
                    let j = yBase + x
                    var mag = magnitudes[j]
                    if midpointReconstruction && lastUpdatedPlanes[j] > 0 {
                        mag |= UInt64(1) << UInt64(lastUpdatedPlanes[j] - 1)
                    }
                    let signedMag = Int64(bitPattern: mag)
                    out[j] = (st.flags[st.index(x: x, y: y)] & CoefficientFlag.negative) != 0 ? -signedMag : signedMag
                }
            }
        }
        return out
    }

    // MARK: - Private 3D Pass Loops

    @inline(__always)
    private static func refinementLabel(flags: UInt8, at i: Int, states: borrowing StatePlane, ignoreBelow: Bool) -> UInt8 {
        if flags & CoefficientFlag.refined != 0 { return ContextLabel.refinementSubsequent }
        return states.hasSignificantNeighbour(at: i, ignoreBelow: ignoreBelow)
            ? ContextLabel.refinementFirstWithNeighbours
            : ContextLabel.refinementFirstNoNeighbours
    }

    @inline(__always)
    private static func runLengthEligible(x: Int, stripe: Int, states: borrowing StatePlane, causal: Bool) -> Bool {
        for k in 0..<4 {
            let i = states.index(x: x, y: stripe + k)
            if states.flags[i] & (CoefficientFlag.significant | CoefficientFlag.visited) != 0 { return false }
            if states.hasSignificantNeighbour(at: i, ignoreBelow: causal && k == 3) { return false }
        }
        return true
    }

    private static func encodeSigPass3D(
        mask: UInt64, width: Int, height: Int, depth: Int,
        magnitudes: borrowing [UInt64], negFlags: borrowing [Bool],
        sliceStates: inout [StatePlane], tables: ContextTables, contexts: inout ContextSet,
        coder: inout EncodeCoder, causal: Bool
    ) {
        let wh = width * height
        for z in 0..<depth {
            let zBase = z * wh
            for stripe in stride(from: 0, to: height, by: 4) {
                let stripeEnd = min(stripe + 4, height)
                for x in 0..<width {
                    for y in stripe..<stripeEnd {
                        let i = sliceStates[z].index(x: x, y: y)
                        let flags = sliceStates[z].flags[i]
                        if flags & (CoefficientFlag.significant | CoefficientFlag.visited) != 0 { continue }
                        let ignoreBelow = causal && y == stripeEnd - 1
                        let key = sliceStates[z].significanceKey(at: i, ignoreBelow: ignoreBelow)
                        if key == 0 { continue }
                        let flatIdx = zBase + y * width + x
                        let sig = (magnitudes[flatIdx] & mask) != 0
                        let neg = negFlags[flatIdx]
                        switch coder {
                        case .mq(var mq):
                            mq.encode(sig, context: &contexts.contexts[Int(tables.significance[key])])
                            if sig {
                                let entry = sliceStates[z].signEntry(at: i, ignoreBelow: ignoreBelow)
                                mq.encode(neg != (entry & 1 == 1), context: &contexts.contexts[Int(entry >> 1)])
                                sliceStates[z].flags[i] = CoefficientFlag.significant | CoefficientFlag.visited | (neg ? CoefficientFlag.negative : 0)
                            } else {
                                sliceStates[z].flags[i] = flags | CoefficientFlag.visited
                            }
                            coder = .mq(mq)
                        case .raw(var raw):
                            raw.encode(sig)
                            if sig {
                                raw.encode(neg)
                                sliceStates[z].flags[i] = CoefficientFlag.significant | CoefficientFlag.visited | (neg ? CoefficientFlag.negative : 0)
                            } else {
                                sliceStates[z].flags[i] = flags | CoefficientFlag.visited
                            }
                            coder = .raw(raw)
                        }
                    }
                }
            }
        }
    }

    private static func encodeRefPass3D(
        mask: UInt64, width: Int, height: Int, depth: Int,
        magnitudes: borrowing [UInt64], sliceStates: inout [StatePlane],
        contexts: inout ContextSet, coder: inout EncodeCoder, causal: Bool
    ) {
        let wh = width * height
        for z in 0..<depth {
            let zBase = z * wh
            for stripe in stride(from: 0, to: height, by: 4) {
                let stripeEnd = min(stripe + 4, height)
                for x in 0..<width {
                    for y in stripe..<stripeEnd {
                        let i = sliceStates[z].index(x: x, y: y)
                        let flags = sliceStates[z].flags[i]
                        guard flags & (CoefficientFlag.significant | CoefficientFlag.visited) == CoefficientFlag.significant else { continue }
                        let bit = (magnitudes[zBase + y * width + x] & mask) != 0
                        switch coder {
                        case .mq(var mq):
                            let label = refinementLabel(flags: flags, at: i, states: sliceStates[z], ignoreBelow: causal && y == stripeEnd - 1)
                            mq.encode(bit, context: &contexts.contexts[Int(label)])
                            coder = .mq(mq)
                        case .raw(var raw):
                            raw.encode(bit)
                            coder = .raw(raw)
                        }
                        sliceStates[z].flags[i] = flags | CoefficientFlag.visited | CoefficientFlag.refined
                    }
                }
            }
        }
    }

    private static func encodeCleanupPass3D(
        mask: UInt64, width: Int, height: Int, depth: Int,
        magnitudes: borrowing [UInt64], negFlags: borrowing [Bool],
        sliceStates: inout [StatePlane], tables: ContextTables, contexts: inout ContextSet,
        encoder: inout MQEncoder, causal: Bool, segmentationSymbols: Bool
    ) {
        let wh = width * height
        for z in 0..<depth {
            let zBase = z * wh
            for stripe in stride(from: 0, to: height, by: 4) {
                let stripeEnd = min(stripe + 4, height)
                for x in 0..<width {
                    var y = stripe
                    if stripeEnd - stripe == 4, runLengthEligible(x: x, stripe: stripe, states: sliceStates[z], causal: causal) {
                        var first = -1
                        for k in 0..<4 where (magnitudes[zBase + (stripe + k) * width + x] & mask) != 0 {
                            first = k
                            break
                        }
                        encoder.encode(first >= 0, context: &contexts.contexts[Int(ContextLabel.runLength)])
                        if first < 0 { continue }
                        encoder.encode(first & 2 != 0, context: &contexts.contexts[Int(ContextLabel.uniform)])
                        encoder.encode(first & 1 != 0, context: &contexts.contexts[Int(ContextLabel.uniform)])
                        let firstY = stripe + first
                        let flatIdx = zBase + firstY * width + x
                        let i = sliceStates[z].index(x: x, y: firstY)
                        let neg = negFlags[flatIdx]
                        let entry = sliceStates[z].signEntry(at: i, ignoreBelow: causal && first == 3)
                        encoder.encode(neg != (entry & 1 == 1), context: &contexts.contexts[Int(entry >> 1)])
                        sliceStates[z].flags[i] = CoefficientFlag.significant | CoefficientFlag.visited | (neg ? CoefficientFlag.negative : 0)
                        y = firstY + 1
                    }
                    while y < stripeEnd {
                        let i = sliceStates[z].index(x: x, y: y)
                        if sliceStates[z].flags[i] & (CoefficientFlag.significant | CoefficientFlag.visited) == 0 {
                            let ignoreBelow = causal && y == stripeEnd - 1
                            let key = sliceStates[z].significanceKey(at: i, ignoreBelow: ignoreBelow)
                            let flatIdx = zBase + y * width + x
                            let sig = (magnitudes[flatIdx] & mask) != 0
                            encoder.encode(sig, context: &contexts.contexts[Int(tables.significance[key])])
                            if sig {
                                let neg = negFlags[flatIdx]
                                let entry = sliceStates[z].signEntry(at: i, ignoreBelow: ignoreBelow)
                                encoder.encode(neg != (entry & 1 == 1), context: &contexts.contexts[Int(entry >> 1)])
                                sliceStates[z].flags[i] = CoefficientFlag.significant | CoefficientFlag.visited | (neg ? CoefficientFlag.negative : 0)
                            }
                        }
                        y += 1
                    }
                }
            }
        }
        if segmentationSymbols {
            encoder.encode(true, context: &contexts.contexts[Int(ContextLabel.uniform)])
            encoder.encode(false, context: &contexts.contexts[Int(ContextLabel.uniform)])
            encoder.encode(true, context: &contexts.contexts[Int(ContextLabel.uniform)])
            encoder.encode(false, context: &contexts.contexts[Int(ContextLabel.uniform)])
        }
    }

    private static func decodeSigPass3D(
        mask: UInt64, plane: Int8, width: Int, height: Int, depth: Int,
        magnitudes: inout [UInt64], lastPlanes: inout [Int8],
        sliceStates: inout [StatePlane], tables: ContextTables, contexts: inout ContextSet,
        coder: inout DecodeCoder, causal: Bool
    ) {
        let wh = width * height
        for z in 0..<depth {
            let zBase = z * wh
            for stripe in stride(from: 0, to: height, by: 4) {
                let stripeEnd = min(stripe + 4, height)
                for x in 0..<width {
                    for y in stripe..<stripeEnd {
                        let i = sliceStates[z].index(x: x, y: y)
                        let flags = sliceStates[z].flags[i]
                        if flags & (CoefficientFlag.significant | CoefficientFlag.visited) != 0 { continue }
                        let ignoreBelow = causal && y == stripeEnd - 1
                        let key = sliceStates[z].significanceKey(at: i, ignoreBelow: ignoreBelow)
                        if key == 0 { continue }
                        let flatIdx = zBase + y * width + x
                        switch coder {
                        case .mq(var mq):
                            if mq.decode(context: &contexts.contexts[Int(tables.significance[key])]) {
                                magnitudes[flatIdx] |= mask
                                lastPlanes[flatIdx] = plane
                                let entry = sliceStates[z].signEntry(at: i, ignoreBelow: ignoreBelow)
                                let neg = mq.decode(context: &contexts.contexts[Int(entry >> 1)]) != (entry & 1 == 1)
                                sliceStates[z].flags[i] = CoefficientFlag.significant | CoefficientFlag.visited | (neg ? CoefficientFlag.negative : 0)
                            } else {
                                sliceStates[z].flags[i] = flags | CoefficientFlag.visited
                            }
                            coder = .mq(mq)
                        case .raw(var raw):
                            if raw.decode() {
                                magnitudes[flatIdx] |= mask
                                lastPlanes[flatIdx] = plane
                                let neg = raw.decode()
                                sliceStates[z].flags[i] = CoefficientFlag.significant | CoefficientFlag.visited | (neg ? CoefficientFlag.negative : 0)
                            } else {
                                sliceStates[z].flags[i] = flags | CoefficientFlag.visited
                            }
                            coder = .raw(raw)
                        }
                    }
                }
            }
        }
    }

    private static func decodeRefPass3D(
        mask: UInt64, plane: Int8, width: Int, height: Int, depth: Int,
        magnitudes: inout [UInt64], lastPlanes: inout [Int8],
        sliceStates: inout [StatePlane], contexts: inout ContextSet,
        coder: inout DecodeCoder, causal: Bool
    ) {
        let wh = width * height
        for z in 0..<depth {
            let zBase = z * wh
            for stripe in stride(from: 0, to: height, by: 4) {
                let stripeEnd = min(stripe + 4, height)
                for x in 0..<width {
                    for y in stripe..<stripeEnd {
                        let i = sliceStates[z].index(x: x, y: y)
                        let flags = sliceStates[z].flags[i]
                        guard flags & (CoefficientFlag.significant | CoefficientFlag.visited) == CoefficientFlag.significant else { continue }
                        let flatIdx = zBase + y * width + x
                        let bit: Bool
                        switch coder {
                        case .mq(var mq):
                            let label = refinementLabel(flags: flags, at: i, states: sliceStates[z], ignoreBelow: causal && y == stripeEnd - 1)
                            bit = mq.decode(context: &contexts.contexts[Int(label)])
                            coder = .mq(mq)
                        case .raw(var raw):
                            bit = raw.decode()
                            coder = .raw(raw)
                        }
                        if bit { magnitudes[flatIdx] |= mask }
                        lastPlanes[flatIdx] = plane
                        sliceStates[z].flags[i] = flags | CoefficientFlag.visited | CoefficientFlag.refined
                    }
                }
            }
        }
    }

    private static func decodeCleanupPass3D(
        mask: UInt64, plane: Int8, width: Int, height: Int, depth: Int,
        magnitudes: inout [UInt64], lastPlanes: inout [Int8],
        sliceStates: inout [StatePlane], tables: ContextTables, contexts: inout ContextSet,
        decoder: inout MQDecoder, causal: Bool
    ) {
        let wh = width * height
        for z in 0..<depth {
            let zBase = z * wh
            for stripe in stride(from: 0, to: height, by: 4) {
                let stripeEnd = min(stripe + 4, height)
                for x in 0..<width {
                    var y = stripe
                    if stripeEnd - stripe == 4, runLengthEligible(x: x, stripe: stripe, states: sliceStates[z], causal: causal) {
                        guard decoder.decode(context: &contexts.contexts[Int(ContextLabel.runLength)]) else { continue }
                        let high = decoder.decode(context: &contexts.contexts[Int(ContextLabel.uniform)]) ? 2 : 0
                        let low = decoder.decode(context: &contexts.contexts[Int(ContextLabel.uniform)]) ? 1 : 0
                        let first = high + low
                        let firstY = stripe + first
                        let flatIdx = zBase + firstY * width + x
                        magnitudes[flatIdx] |= mask
                        lastPlanes[flatIdx] = plane
                        let i = sliceStates[z].index(x: x, y: firstY)
                        let entry = sliceStates[z].signEntry(at: i, ignoreBelow: causal && first == 3)
                        let neg = decoder.decode(context: &contexts.contexts[Int(entry >> 1)]) != (entry & 1 == 1)
                        sliceStates[z].flags[i] = CoefficientFlag.significant | CoefficientFlag.visited | (neg ? CoefficientFlag.negative : 0)
                        y = firstY + 1
                    }
                    while y < stripeEnd {
                        let i = sliceStates[z].index(x: x, y: y)
                        if sliceStates[z].flags[i] & (CoefficientFlag.significant | CoefficientFlag.visited) == 0 {
                            let ignoreBelow = causal && y == stripeEnd - 1
                            let key = sliceStates[z].significanceKey(at: i, ignoreBelow: ignoreBelow)
                            if decoder.decode(context: &contexts.contexts[Int(tables.significance[key])]) {
                                let flatIdx = zBase + y * width + x
                                magnitudes[flatIdx] |= mask
                                lastPlanes[flatIdx] = plane
                                let entry = sliceStates[z].signEntry(at: i, ignoreBelow: ignoreBelow)
                                let neg = decoder.decode(context: &contexts.contexts[Int(entry >> 1)]) != (entry & 1 == 1)
                                sliceStates[z].flags[i] = CoefficientFlag.significant | CoefficientFlag.visited | (neg ? CoefficientFlag.negative : 0)
                            }
                        }
                        y += 1
                    }
                }
            }
        }
    }
}

// MARK: - Separable 3D Wavelet Transform & Quantisation (Annexes D & E)

package enum JP3DWaveletEngine {
    // ISO/IEC 15444-1 Annex F Table F.4 / ITU-T T.809 Annex D 9-7 lifting parameters
    private static let alpha = -1.586134342059924
    private static let beta  = -0.052980118572961
    private static let gamma =  0.882911075530934
    private static let delta =  0.443506852043971
    private static let kNorm =  1.230174104914001
    private static let invK  =  1.0 / 1.230174104914001          // ~ 0.812893066115961
    private static let halfK =  0.5 * 1.230174104914001          // ~ 0.6150870524570005

    // MARK: - 1D Reversible 5-3 Lifting (`Int64`, exact for 1...38-bit samples)

    package static func forward53_1D(_ line: inout [Int64], length n: Int, cas: Int) {
        guard n > 0 else { return }
        if n == 1 {
            if cas != 0 {
                line[0] *= 2
            }
            return
        }
        let sn = (n + 1 - cas) >> 1
        let dn = n - sn
        var s = [Int64](repeating: 0, count: sn)
        var d = [Int64](repeating: 0, count: dn)
        for i in 0..<sn { s[i] = line[2 * i + cas] }
        for i in 0..<dn { d[i] = line[2 * i + 1 - cas] }

        @inline(__always)
        func sExt(_ idx: Int) -> Int64 {
            s[max(0, min(sn - 1, idx))]
        }
        @inline(__always)
        func dExt(_ idx: Int) -> Int64 {
            d[max(0, min(dn - 1, idx))]
        }

        if cas == 0 {
            for i in 0..<dn {
                d[i] -= (sExt(i) + sExt(i + 1)) >> 1
            }
            for i in 0..<sn {
                s[i] += (dExt(i - 1) + dExt(i) + 2) >> 2
            }
        } else {
            for i in 0..<dn {
                d[i] -= (sExt(i - 1) + sExt(i)) >> 1
            }
            for i in 0..<sn {
                s[i] += (dExt(i) + dExt(i + 1) + 2) >> 2
            }
        }
        for i in 0..<sn { line[i] = s[i] }
        for i in 0..<dn { line[sn + i] = d[i] }
    }

    package static func inverse53_1D(_ line: inout [Int64], length n: Int, cas: Int) {
        guard n > 0 else { return }
        if n == 1 {
            if cas != 0 {
                line[0] >>= 1
            }
            return
        }
        let sn = (n + 1 - cas) >> 1
        let dn = n - sn
        var s = [Int64](line[0..<sn])
        var d = [Int64](line[sn..<n])

        @inline(__always)
        func sExt(_ idx: Int) -> Int64 {
            s[max(0, min(sn - 1, idx))]
        }
        @inline(__always)
        func dExt(_ idx: Int) -> Int64 {
            d[max(0, min(dn - 1, idx))]
        }

        if cas == 0 {
            for i in 0..<sn {
                s[i] -= (dExt(i - 1) + dExt(i) + 2) >> 2
            }
            for i in 0..<dn {
                d[i] += (sExt(i) + sExt(i + 1)) >> 1
            }
        } else {
            for i in 0..<sn {
                s[i] -= (dExt(i) + dExt(i + 1) + 2) >> 2
            }
            for i in 0..<dn {
                d[i] += (sExt(i - 1) + sExt(i)) >> 1
            }
        }
        for i in 0..<sn { line[2 * i + cas] = s[i] }
        for i in 0..<dn { line[2 * i + 1 - cas] = d[i] }
    }

    // MARK: - 1D Irreversible 9-7 Lifting (`Double`, `1/K` and `K/2` sub-band scaling)

    package static func forward97_1D(_ line: inout [Double], length n: Int, cas: Int) {
        guard n > 1 else { return }
        let sn = (n + 1 - cas) >> 1
        let dn = n - sn
        var s = [Double](repeating: 0, count: sn)
        var d = [Double](repeating: 0, count: dn)
        for i in 0..<sn { s[i] = line[2 * i + cas] }
        for i in 0..<dn { d[i] = line[2 * i + 1 - cas] }

        @inline(__always)
        func sExt(_ idx: Int) -> Double {
            s[max(0, min(sn - 1, idx))]
        }
        @inline(__always)
        func dExt(_ idx: Int) -> Double {
            d[max(0, min(dn - 1, idx))]
        }

        if cas == 0 {
            for i in 0..<dn { d[i] += alpha * (sExt(i) + sExt(i + 1)) }
            for i in 0..<sn { s[i] += beta * (dExt(i - 1) + dExt(i)) }
            for i in 0..<dn { d[i] += gamma * (sExt(i) + sExt(i + 1)) }
            for i in 0..<sn { s[i] += delta * (dExt(i - 1) + dExt(i)) }
        } else {
            for i in 0..<dn { d[i] += alpha * (sExt(i - 1) + sExt(i)) }
            for i in 0..<sn { s[i] += beta * (dExt(i) + dExt(i + 1)) }
            for i in 0..<dn { d[i] += gamma * (sExt(i - 1) + sExt(i)) }
            for i in 0..<sn { s[i] += delta * (dExt(i) + dExt(i + 1)) }
        }
        for i in 0..<sn { line[i] = s[i] * invK }
        for i in 0..<dn { line[sn + i] = d[i] * halfK }
    }

    package static func inverse97_1D(_ line: inout [Double], length n: Int, cas: Int) {
        guard n > 1 else { return }
        let sn = (n + 1 - cas) >> 1
        let dn = n - sn
        var s = [Double](repeating: 0, count: sn)
        var d = [Double](repeating: 0, count: dn)
        for i in 0..<sn { s[i] = line[i] * kNorm }
        for i in 0..<dn { d[i] = line[sn + i] * (2.0 * invK) }

        @inline(__always)
        func sExt(_ idx: Int) -> Double {
            s[max(0, min(sn - 1, idx))]
        }
        @inline(__always)
        func dExt(_ idx: Int) -> Double {
            d[max(0, min(dn - 1, idx))]
        }

        if cas == 0 {
            for i in 0..<sn { s[i] -= delta * (dExt(i - 1) + dExt(i)) }
            for i in 0..<dn { d[i] -= gamma * (sExt(i) + sExt(i + 1)) }
            for i in 0..<sn { s[i] -= beta * (dExt(i - 1) + dExt(i)) }
            for i in 0..<dn { d[i] -= alpha * (sExt(i) + sExt(i + 1)) }
        } else {
            for i in 0..<sn { s[i] -= delta * (dExt(i) + dExt(i + 1)) }
            for i in 0..<dn { d[i] -= gamma * (sExt(i - 1) + sExt(i)) }
            for i in 0..<sn { s[i] -= beta * (dExt(i) + dExt(i + 1)) }
            for i in 0..<dn { d[i] -= alpha * (sExt(i - 1) + sExt(i)) }
        }
        for i in 0..<sn { line[2 * i + cas] = s[i] }
        for i in 0..<dn { line[2 * i + 1 - cas] = d[i] }
    }

    // MARK: - 4-Lane SIMD Parallel 1D 5-3 & 9-7 Lifting (`SIMD4<Int64>` / `SIMD4<Double>`)

    private static func forward53_1D_SIMD4(_ line: inout [SIMD4<Int64>], length n: Int, cas: Int) {
        guard n > 0 else { return }
        if n == 1 {
            if cas != 0 {
                line[0] &+= line[0]
            }
            return
        }
        let sn = (n + 1 - cas) >> 1
        let dn = n - sn
        var s = [SIMD4<Int64>](repeating: .zero, count: sn)
        var d = [SIMD4<Int64>](repeating: .zero, count: dn)
        for i in 0..<sn { s[i] = line[2 * i + cas] }
        for i in 0..<dn { d[i] = line[2 * i + 1 - cas] }

        @inline(__always)
        func sExt(_ idx: Int) -> SIMD4<Int64> {
            s[max(0, min(sn - 1, idx))]
        }
        @inline(__always)
        func dExt(_ idx: Int) -> SIMD4<Int64> {
            d[max(0, min(dn - 1, idx))]
        }
        let one = SIMD4<Int64>(repeating: 1)
        let two = SIMD4<Int64>(repeating: 2)

        if cas == 0 {
            for i in 0..<dn {
                d[i] &-= (sExt(i) &+ sExt(i + 1)) &>> one
            }
            for i in 0..<sn {
                s[i] &+= (dExt(i - 1) &+ dExt(i) &+ two) &>> two
            }
        } else {
            for i in 0..<dn {
                d[i] &-= (sExt(i - 1) &+ sExt(i)) &>> one
            }
            for i in 0..<sn {
                s[i] &+= (dExt(i) &+ dExt(i + 1) &+ two) &>> two
            }
        }
        for i in 0..<sn { line[i] = s[i] }
        for i in 0..<dn { line[sn + i] = d[i] }
    }

    private static func inverse53_1D_SIMD4(_ line: inout [SIMD4<Int64>], length n: Int, cas: Int) {
        guard n > 0 else { return }
        let one = SIMD4<Int64>(repeating: 1)
        let two = SIMD4<Int64>(repeating: 2)
        if n == 1 {
            if cas != 0 {
                line[0] &>>= one
            }
            return
        }
        let sn = (n + 1 - cas) >> 1
        let dn = n - sn
        var s = [SIMD4<Int64>](line[0..<sn])
        var d = [SIMD4<Int64>](line[sn..<n])

        @inline(__always)
        func sExt(_ idx: Int) -> SIMD4<Int64> {
            s[max(0, min(sn - 1, idx))]
        }
        @inline(__always)
        func dExt(_ idx: Int) -> SIMD4<Int64> {
            d[max(0, min(dn - 1, idx))]
        }

        if cas == 0 {
            for i in 0..<sn {
                s[i] &-= (dExt(i - 1) &+ dExt(i) &+ two) &>> two
            }
            for i in 0..<dn {
                d[i] &+= (sExt(i) &+ sExt(i + 1)) &>> one
            }
        } else {
            for i in 0..<sn {
                s[i] &-= (dExt(i) &+ dExt(i + 1) &+ two) &>> two
            }
            for i in 0..<dn {
                d[i] &+= (sExt(i - 1) &+ sExt(i)) &>> one
            }
        }
        for i in 0..<sn { line[2 * i + cas] = s[i] }
        for i in 0..<dn { line[2 * i + 1 - cas] = d[i] }
    }

    private static func forward97_1D_SIMD4(_ line: inout [SIMD4<Double>], length n: Int, cas: Int) {
        guard n > 1 else { return }
        let sn = (n + 1 - cas) >> 1
        let dn = n - sn
        var s = [SIMD4<Double>](repeating: .zero, count: sn)
        var d = [SIMD4<Double>](repeating: .zero, count: dn)
        for i in 0..<sn { s[i] = line[2 * i + cas] }
        for i in 0..<dn { d[i] = line[2 * i + 1 - cas] }

        @inline(__always)
        func sExt(_ idx: Int) -> SIMD4<Double> {
            s[max(0, min(sn - 1, idx))]
        }
        @inline(__always)
        func dExt(_ idx: Int) -> SIMD4<Double> {
            d[max(0, min(dn - 1, idx))]
        }

        let vAlpha = SIMD4<Double>(repeating: alpha)
        let vBeta  = SIMD4<Double>(repeating: beta)
        let vGamma = SIMD4<Double>(repeating: gamma)
        let vDelta = SIMD4<Double>(repeating: delta)
        let vInvK  = SIMD4<Double>(repeating: invK)
        let vHalfK = SIMD4<Double>(repeating: halfK)

        if cas == 0 {
            for i in 0..<dn { d[i] += vAlpha * (sExt(i) + sExt(i + 1)) }
            for i in 0..<sn { s[i] += vBeta * (dExt(i - 1) + dExt(i)) }
            for i in 0..<dn { d[i] += vGamma * (sExt(i) + sExt(i + 1)) }
            for i in 0..<sn { s[i] += vDelta * (dExt(i - 1) + dExt(i)) }
        } else {
            for i in 0..<dn { d[i] += vAlpha * (sExt(i - 1) + sExt(i)) }
            for i in 0..<sn { s[i] += vBeta * (dExt(i) + dExt(i + 1)) }
            for i in 0..<dn { d[i] += vGamma * (sExt(i - 1) + sExt(i)) }
            for i in 0..<sn { s[i] += vDelta * (dExt(i) + dExt(i + 1)) }
        }
        for i in 0..<sn { line[i] = s[i] * vInvK }
        for i in 0..<dn { line[sn + i] = d[i] * vHalfK }
    }

    private static func inverse97_1D_SIMD4(_ line: inout [SIMD4<Double>], length n: Int, cas: Int) {
        guard n > 1 else { return }
        let sn = (n + 1 - cas) >> 1
        let dn = n - sn
        let vKNorm   = SIMD4<Double>(repeating: kNorm)
        let vTwoInvK = SIMD4<Double>(repeating: 2.0 * invK)
        var s = [SIMD4<Double>](repeating: .zero, count: sn)
        var d = [SIMD4<Double>](repeating: .zero, count: dn)
        for i in 0..<sn { s[i] = line[i] * vKNorm }
        for i in 0..<dn { d[i] = line[sn + i] * vTwoInvK }

        @inline(__always)
        func sExt(_ idx: Int) -> SIMD4<Double> {
            s[max(0, min(sn - 1, idx))]
        }
        @inline(__always)
        func dExt(_ idx: Int) -> SIMD4<Double> {
            d[max(0, min(dn - 1, idx))]
        }

        let vAlpha = SIMD4<Double>(repeating: alpha)
        let vBeta  = SIMD4<Double>(repeating: beta)
        let vGamma = SIMD4<Double>(repeating: gamma)
        let vDelta = SIMD4<Double>(repeating: delta)

        if cas == 0 {
            for i in 0..<sn { s[i] -= vDelta * (dExt(i - 1) + dExt(i)) }
            for i in 0..<dn { d[i] -= vGamma * (sExt(i) + sExt(i + 1)) }
            for i in 0..<sn { s[i] -= vBeta * (dExt(i - 1) + dExt(i)) }
            for i in 0..<dn { d[i] -= vAlpha * (sExt(i) + sExt(i + 1)) }
        } else {
            for i in 0..<sn { s[i] -= vDelta * (dExt(i) + dExt(i + 1)) }
            for i in 0..<dn { d[i] -= vGamma * (sExt(i - 1) + sExt(i)) }
            for i in 0..<sn { s[i] -= vBeta * (dExt(i) + dExt(i + 1)) }
            for i in 0..<dn { d[i] -= vAlpha * (sExt(i - 1) + sExt(i)) }
        }
        for i in 0..<sn { line[2 * i + cas] = s[i] }
        for i in 0..<dn { line[2 * i + 1 - cas] = d[i] }
    }

    // MARK: - Separable 3D Forward & Inverse DWT

    @discardableResult
    package static func forward53_3D(
        buffer: inout [Int64],
        geometry: JP3DTileComponentGeometry,
        useSIMD: Bool = false
    ) -> Bool {
        let w = geometry.width, h = geometry.height, wh = w * h
        let nl = geometry.maxLevels
        guard nl > 0 else { return false }
        let maxDim = max(w, max(h, geometry.depth))
        var scratch = [Int64](repeating: 0, count: maxDim)
        var simdScratch = useSIMD ? [SIMD4<Int64>](repeating: .zero, count: maxDim) : []
        var usedSIMD = false

        for r in stride(from: nl, through: 1, by: -1) {
            let res = geometry.resolutions[r]
            let rw = res.width, rh = res.height, rd = res.depth
            if res.axisActiveX {
                let casX = res.x0 & 1
                for z in 0..<rd {
                    var y = 0
                    if useSIMD {
                        while y + 4 <= rh {
                            let b0 = z * wh + y * w
                            let b1 = b0 + w
                            let b2 = b1 + w
                            let b3 = b2 + w
                            for x in 0..<rw {
                                simdScratch[x] = SIMD4<Int64>(buffer[b0 + x], buffer[b1 + x], buffer[b2 + x], buffer[b3 + x])
                            }
                            forward53_1D_SIMD4(&simdScratch, length: rw, cas: casX)
                            for x in 0..<rw {
                                let v = simdScratch[x]
                                buffer[b0 + x] = v[0]
                                buffer[b1 + x] = v[1]
                                buffer[b2 + x] = v[2]
                                buffer[b3 + x] = v[3]
                            }
                            usedSIMD = true
                            y += 4
                        }
                    }
                    while y < rh {
                        let base = z * wh + y * w
                        for x in 0..<rw { scratch[x] = buffer[base + x] }
                        forward53_1D(&scratch, length: rw, cas: casX)
                        for x in 0..<rw { buffer[base + x] = scratch[x] }
                        y += 1
                    }
                }
            }
            if res.axisActiveY {
                let casY = res.y0 & 1
                for z in 0..<rd {
                    var x = 0
                    if useSIMD {
                        while x + 4 <= rw {
                            let base = z * wh + x
                            for y in 0..<rh {
                                let off = base + y * w
                                simdScratch[y] = SIMD4<Int64>(buffer[off], buffer[off + 1], buffer[off + 2], buffer[off + 3])
                            }
                            forward53_1D_SIMD4(&simdScratch, length: rh, cas: casY)
                            for y in 0..<rh {
                                let off = base + y * w
                                let v = simdScratch[y]
                                buffer[off] = v[0]
                                buffer[off + 1] = v[1]
                                buffer[off + 2] = v[2]
                                buffer[off + 3] = v[3]
                            }
                            usedSIMD = true
                            x += 4
                        }
                    }
                    while x < rw {
                        let base = z * wh + x
                        for y in 0..<rh { scratch[y] = buffer[base + y * w] }
                        forward53_1D(&scratch, length: rh, cas: casY)
                        for y in 0..<rh { buffer[base + y * w] = scratch[y] }
                        x += 1
                    }
                }
            }
            if res.axisActiveZ {
                let casZ = res.z0 & 1
                for y in 0..<rh {
                    var x = 0
                    if useSIMD {
                        while x + 4 <= rw {
                            let base = y * w + x
                            for z in 0..<rd {
                                let off = base + z * wh
                                simdScratch[z] = SIMD4<Int64>(buffer[off], buffer[off + 1], buffer[off + 2], buffer[off + 3])
                            }
                            forward53_1D_SIMD4(&simdScratch, length: rd, cas: casZ)
                            for z in 0..<rd {
                                let off = base + z * wh
                                let v = simdScratch[z]
                                buffer[off] = v[0]
                                buffer[off + 1] = v[1]
                                buffer[off + 2] = v[2]
                                buffer[off + 3] = v[3]
                            }
                            usedSIMD = true
                            x += 4
                        }
                    }
                    while x < rw {
                        let base = y * w + x
                        for z in 0..<rd { scratch[z] = buffer[base + z * wh] }
                        forward53_1D(&scratch, length: rd, cas: casZ)
                        for z in 0..<rd { buffer[base + z * wh] = scratch[z] }
                        x += 1
                    }
                }
            }
        }
        return usedSIMD
    }

    /// Inverse 3D 5-3 DWT. When `skipLastXYLevels > 0`, stops XY reconstruction `skipLastXYLevels`
    /// steps before full XY resolution while completing all Z-axis inverse DWT steps so Z depth
    /// remains full-resolution (matching the R2 reduced-resolution contract).
    @discardableResult
    package static func inverse53_3D(
        buffer: inout [Int64],
        geometry: JP3DTileComponentGeometry,
        skipLastXYLevels: Int = 0,
        useSIMD: Bool = false
    ) -> Bool {
        let w = geometry.width, h = geometry.height, wh = w * h
        let nl = geometry.maxLevels
        guard nl > 0 else { return false }
        let maxRForXY = max(0, nl - max(0, skipLastXYLevels))
        let maxDim = max(w, max(h, geometry.depth))
        var scratch = [Int64](repeating: 0, count: maxDim)
        var simdScratch = useSIMD ? [SIMD4<Int64>](repeating: .zero, count: maxDim) : []
        var usedSIMD = false

        // Track current reconstructed XY extent when XY stops early while Z continues.
        var curW = geometry.resolutions[0].width
        var curH = geometry.resolutions[0].height

        for r in 1...nl {
            let res = geometry.resolutions[r]
            let doXY = r <= maxRForXY
            let targetW = doXY ? res.width : curW
            let targetH = doXY ? res.height : curH
            let rd = res.depth

            if res.axisActiveZ {
                let casZ = res.z0 & 1
                for y in 0..<targetH {
                    var x = 0
                    if useSIMD {
                        while x + 4 <= targetW {
                            let base = y * w + x
                            for z in 0..<rd {
                                let off = base + z * wh
                                simdScratch[z] = SIMD4<Int64>(buffer[off], buffer[off + 1], buffer[off + 2], buffer[off + 3])
                            }
                            inverse53_1D_SIMD4(&simdScratch, length: rd, cas: casZ)
                            for z in 0..<rd {
                                let off = base + z * wh
                                let v = simdScratch[z]
                                buffer[off] = v[0]
                                buffer[off + 1] = v[1]
                                buffer[off + 2] = v[2]
                                buffer[off + 3] = v[3]
                            }
                            usedSIMD = true
                            x += 4
                        }
                    }
                    while x < targetW {
                        let base = y * w + x
                        for z in 0..<rd { scratch[z] = buffer[base + z * wh] }
                        inverse53_1D(&scratch, length: rd, cas: casZ)
                        for z in 0..<rd { buffer[base + z * wh] = scratch[z] }
                        x += 1
                    }
                }
            }
            if doXY && res.axisActiveY {
                let casY = res.y0 & 1
                for z in 0..<rd {
                    var x = 0
                    if useSIMD {
                        while x + 4 <= targetW {
                            let base = z * wh + x
                            for y in 0..<targetH {
                                let off = base + y * w
                                simdScratch[y] = SIMD4<Int64>(buffer[off], buffer[off + 1], buffer[off + 2], buffer[off + 3])
                            }
                            inverse53_1D_SIMD4(&simdScratch, length: targetH, cas: casY)
                            for y in 0..<targetH {
                                let off = base + y * w
                                let v = simdScratch[y]
                                buffer[off] = v[0]
                                buffer[off + 1] = v[1]
                                buffer[off + 2] = v[2]
                                buffer[off + 3] = v[3]
                            }
                            usedSIMD = true
                            x += 4
                        }
                    }
                    while x < targetW {
                        let base = z * wh + x
                        for y in 0..<targetH { scratch[y] = buffer[base + y * w] }
                        inverse53_1D(&scratch, length: targetH, cas: casY)
                        for y in 0..<targetH { buffer[base + y * w] = scratch[y] }
                        x += 1
                    }
                }
                curH = targetH
            }
            if doXY && res.axisActiveX {
                let casX = res.x0 & 1
                for z in 0..<rd {
                    var y = 0
                    if useSIMD {
                        while y + 4 <= targetH {
                            let b0 = z * wh + y * w
                            let b1 = b0 + w
                            let b2 = b1 + w
                            let b3 = b2 + w
                            for x in 0..<targetW {
                                simdScratch[x] = SIMD4<Int64>(buffer[b0 + x], buffer[b1 + x], buffer[b2 + x], buffer[b3 + x])
                            }
                            inverse53_1D_SIMD4(&simdScratch, length: targetW, cas: casX)
                            for x in 0..<targetW {
                                let v = simdScratch[x]
                                buffer[b0 + x] = v[0]
                                buffer[b1 + x] = v[1]
                                buffer[b2 + x] = v[2]
                                buffer[b3 + x] = v[3]
                            }
                            usedSIMD = true
                            y += 4
                        }
                    }
                    while y < targetH {
                        let base = z * wh + y * w
                        for x in 0..<targetW { scratch[x] = buffer[base + x] }
                        inverse53_1D(&scratch, length: targetW, cas: casX)
                        for x in 0..<targetW { buffer[base + x] = scratch[x] }
                        y += 1
                    }
                }
                curW = targetW
            }
        }
        return usedSIMD
    }

    @discardableResult
    package static func forward97_3D(
        buffer: inout [Double],
        geometry: JP3DTileComponentGeometry,
        useSIMD: Bool = false
    ) -> Bool {
        let w = geometry.width, h = geometry.height, wh = w * h
        let nl = geometry.maxLevels
        guard nl > 0 else { return false }
        let maxDim = max(w, max(h, geometry.depth))
        var scratch = [Double](repeating: 0, count: maxDim)
        var simdScratch = useSIMD ? [SIMD4<Double>](repeating: .zero, count: maxDim) : []
        var usedSIMD = false

        for r in stride(from: nl, through: 1, by: -1) {
            let res = geometry.resolutions[r]
            let rw = res.width, rh = res.height, rd = res.depth
            if res.axisActiveX {
                let casX = res.x0 & 1
                for z in 0..<rd {
                    var y = 0
                    if useSIMD && rw > 1 {
                        while y + 4 <= rh {
                            let b0 = z * wh + y * w
                            let b1 = b0 + w
                            let b2 = b1 + w
                            let b3 = b2 + w
                            for x in 0..<rw {
                                simdScratch[x] = SIMD4<Double>(buffer[b0 + x], buffer[b1 + x], buffer[b2 + x], buffer[b3 + x])
                            }
                            forward97_1D_SIMD4(&simdScratch, length: rw, cas: casX)
                            for x in 0..<rw {
                                let v = simdScratch[x]
                                buffer[b0 + x] = v[0]
                                buffer[b1 + x] = v[1]
                                buffer[b2 + x] = v[2]
                                buffer[b3 + x] = v[3]
                            }
                            usedSIMD = true
                            y += 4
                        }
                    }
                    while y < rh {
                        let base = z * wh + y * w
                        for x in 0..<rw { scratch[x] = buffer[base + x] }
                        forward97_1D(&scratch, length: rw, cas: casX)
                        for x in 0..<rw { buffer[base + x] = scratch[x] }
                        y += 1
                    }
                }
            }
            if res.axisActiveY {
                let casY = res.y0 & 1
                for z in 0..<rd {
                    var x = 0
                    if useSIMD && rh > 1 {
                        while x + 4 <= rw {
                            let base = z * wh + x
                            for y in 0..<rh {
                                let off = base + y * w
                                simdScratch[y] = SIMD4<Double>(buffer[off], buffer[off + 1], buffer[off + 2], buffer[off + 3])
                            }
                            forward97_1D_SIMD4(&simdScratch, length: rh, cas: casY)
                            for y in 0..<rh {
                                let off = base + y * w
                                let v = simdScratch[y]
                                buffer[off] = v[0]
                                buffer[off + 1] = v[1]
                                buffer[off + 2] = v[2]
                                buffer[off + 3] = v[3]
                            }
                            usedSIMD = true
                            x += 4
                        }
                    }
                    while x < rw {
                        let base = z * wh + x
                        for y in 0..<rh { scratch[y] = buffer[base + y * w] }
                        forward97_1D(&scratch, length: rh, cas: casY)
                        for y in 0..<rh { buffer[base + y * w] = scratch[y] }
                        x += 1
                    }
                }
            }
            if res.axisActiveZ {
                let casZ = res.z0 & 1
                for y in 0..<rh {
                    var x = 0
                    if useSIMD && rd > 1 {
                        while x + 4 <= rw {
                            let base = y * w + x
                            for z in 0..<rd {
                                let off = base + z * wh
                                simdScratch[z] = SIMD4<Double>(buffer[off], buffer[off + 1], buffer[off + 2], buffer[off + 3])
                            }
                            forward97_1D_SIMD4(&simdScratch, length: rd, cas: casZ)
                            for z in 0..<rd {
                                let off = base + z * wh
                                let v = simdScratch[z]
                                buffer[off] = v[0]
                                buffer[off + 1] = v[1]
                                buffer[off + 2] = v[2]
                                buffer[off + 3] = v[3]
                            }
                            usedSIMD = true
                            x += 4
                        }
                    }
                    while x < rw {
                        let base = y * w + x
                        for z in 0..<rd { scratch[z] = buffer[base + z * wh] }
                        forward97_1D(&scratch, length: rd, cas: casZ)
                        for z in 0..<rd { buffer[base + z * wh] = scratch[z] }
                        x += 1
                    }
                }
            }
        }
        return usedSIMD
    }

    @discardableResult
    package static func inverse97_3D(
        buffer: inout [Double],
        geometry: JP3DTileComponentGeometry,
        skipLastXYLevels: Int = 0,
        useSIMD: Bool = false
    ) -> Bool {
        let w = geometry.width, h = geometry.height, wh = w * h
        let nl = geometry.maxLevels
        guard nl > 0 else { return false }
        let maxRForXY = max(0, nl - max(0, skipLastXYLevels))
        let maxDim = max(w, max(h, geometry.depth))
        var scratch = [Double](repeating: 0, count: maxDim)
        var simdScratch = useSIMD ? [SIMD4<Double>](repeating: .zero, count: maxDim) : []
        var usedSIMD = false

        var curW = geometry.resolutions[0].width
        var curH = geometry.resolutions[0].height

        for r in 1...nl {
            let res = geometry.resolutions[r]
            let doXY = r <= maxRForXY
            let targetW = doXY ? res.width : curW
            let targetH = doXY ? res.height : curH
            let rd = res.depth

            if res.axisActiveZ {
                let casZ = res.z0 & 1
                for y in 0..<targetH {
                    var x = 0
                    if useSIMD && rd > 1 {
                        while x + 4 <= targetW {
                            let base = y * w + x
                            for z in 0..<rd {
                                let off = base + z * wh
                                simdScratch[z] = SIMD4<Double>(buffer[off], buffer[off + 1], buffer[off + 2], buffer[off + 3])
                            }
                            inverse97_1D_SIMD4(&simdScratch, length: rd, cas: casZ)
                            for z in 0..<rd {
                                let off = base + z * wh
                                let v = simdScratch[z]
                                buffer[off] = v[0]
                                buffer[off + 1] = v[1]
                                buffer[off + 2] = v[2]
                                buffer[off + 3] = v[3]
                            }
                            usedSIMD = true
                            x += 4
                        }
                    }
                    while x < targetW {
                        let base = y * w + x
                        for z in 0..<rd { scratch[z] = buffer[base + z * wh] }
                        inverse97_1D(&scratch, length: rd, cas: casZ)
                        for z in 0..<rd { buffer[base + z * wh] = scratch[z] }
                        x += 1
                    }
                }
            }
            if doXY && res.axisActiveY {
                let casY = res.y0 & 1
                for z in 0..<rd {
                    var x = 0
                    if useSIMD && targetH > 1 {
                        while x + 4 <= targetW {
                            let base = z * wh + x
                            for y in 0..<targetH {
                                let off = base + y * w
                                simdScratch[y] = SIMD4<Double>(buffer[off], buffer[off + 1], buffer[off + 2], buffer[off + 3])
                            }
                            inverse97_1D_SIMD4(&simdScratch, length: targetH, cas: casY)
                            for y in 0..<targetH {
                                let off = base + y * w
                                let v = simdScratch[y]
                                buffer[off] = v[0]
                                buffer[off + 1] = v[1]
                                buffer[off + 2] = v[2]
                                buffer[off + 3] = v[3]
                            }
                            usedSIMD = true
                            x += 4
                        }
                    }
                    while x < targetW {
                        let base = z * wh + x
                        for y in 0..<targetH { scratch[y] = buffer[base + y * w] }
                        inverse97_1D(&scratch, length: targetH, cas: casY)
                        for y in 0..<targetH { buffer[base + y * w] = scratch[y] }
                        x += 1
                    }
                }
                curH = targetH
            }
            if doXY && res.axisActiveX {
                let casX = res.x0 & 1
                for z in 0..<rd {
                    var y = 0
                    if useSIMD && targetW > 1 {
                        while y + 4 <= targetH {
                            let b0 = z * wh + y * w
                            let b1 = b0 + w
                            let b2 = b1 + w
                            let b3 = b2 + w
                            for x in 0..<targetW {
                                simdScratch[x] = SIMD4<Double>(buffer[b0 + x], buffer[b1 + x], buffer[b2 + x], buffer[b3 + x])
                            }
                            inverse97_1D_SIMD4(&simdScratch, length: targetW, cas: casX)
                            for x in 0..<targetW {
                                let v = simdScratch[x]
                                buffer[b0 + x] = v[0]
                                buffer[b1 + x] = v[1]
                                buffer[b2 + x] = v[2]
                                buffer[b3 + x] = v[3]
                            }
                            usedSIMD = true
                            y += 4
                        }
                    }
                    while y < targetH {
                        let base = z * wh + y * w
                        for x in 0..<targetW { scratch[x] = buffer[base + x] }
                        inverse97_1D(&scratch, length: targetW, cas: casX)
                        for x in 0..<targetW { buffer[base + x] = scratch[x] }
                        y += 1
                    }
                }
                curW = targetW
            }
        }
        return usedSIMD
    }
}

// MARK: - 3D Quantisation & QCD Parameter Representation (Annex E)

package struct JP3DQuantizationParameters: Sendable, Equatable {
    package static func == (lhs: JP3DQuantizationParameters, rhs: JP3DQuantizationParameters) -> Bool {
        guard lhs.style == rhs.style, lhs.guardBits == rhs.guardBits, lhs.steps.count == rhs.steps.count else {
            return false
        }
        for i in 0..<lhs.steps.count {
            if lhs.steps[i].exponent != rhs.steps[i].exponent || lhs.steps[i].mantissa != rhs.steps[i].mantissa {
                return false
            }
        }
        return true
    }

    /// Computes exact 3D sub-band count across `(levelsX, levelsY, levelsZ)` in ITU-T T.809 Morton order.
    package static func totalSubbandCount(levelsX: Int, levelsY: Int, levelsZ: Int) -> Int {
        let nl = max(levelsX, max(levelsY, levelsZ))
        guard nl >= 1 else { return 1 }
        var total = 1
        for r in 1...nl {
            let step = nl - r
            let activeAxes = (step < levelsX ? 1 : 0) + (step < levelsY ? 1 : 0) + (step < levelsZ ? 1 : 0)
            total += (1 << activeAxes) - 1
        }
        return total
    }

    /// `0 = none (reversible)`, `1 = scalar derived`, `2 = scalar expounded`.
    package let style: UInt8
    /// Guard bits `G` (`0...7`, typically `2`).
    package let guardBits: Int
    /// Per-subband `(epsilon, mu)` entries (`1` entry for `style == 1`, `numSubbands` for `0` and `2`).
    package let steps: [(exponent: Int, mantissa: Int)]

    package init(style: UInt8, guardBits: Int, steps: [(exponent: Int, mantissa: Int)]) {
        self.style = style
        self.guardBits = guardBits
        self.steps = steps
    }

    package var isReversible: Bool { style == 0 }

    /// Expands `scalarDerived` (`style == 1`) or returns the `(eps, mu)` step for `band` at `resolution`.
    package func step(for band: JP3DBandGeometry, resolution: Int, maxLevels: Int) -> (exponent: Int, mantissa: Int) {
        if steps.isEmpty {
            return (exponent: 8 + band.gain, mantissa: 0)
        }
        if style == 1 {
            let base = steps[0]
            let dec = rOffsetForDerived(resolution: resolution)
            return (exponent: max(0, base.exponent - dec), mantissa: base.mantissa)
        }
        let idx = min(band.quantizationIndex, steps.count - 1)
        return steps[idx]
    }

    @inline(__always)
    private func rOffsetForDerived(resolution: Int) -> Int {
        resolution <= 1 ? 0 : (resolution - 1)
    }

    /// Computes normative sub-band `Mb = G + eps_b - 1 + roiShift` strictly from wire `QCD`/`QCC` and `RGN`
    /// parameters (ITU-T Rec. T.809 Annex E / ISO/IEC 15444-1 Eq. E-2), with zero private bit-plane lifts.
    package func magnitudeBitPlanes(
        for band: JP3DBandGeometry,
        resolution: Int,
        maxLevels: Int,
        componentBitDepth: Int,
        usesReversibleMCT: Bool = false,
        roiShift: Int = 0
    ) -> Int {
        _ = componentBitDepth
        _ = usesReversibleMCT
        let s = step(for: band, resolution: resolution, maxLevels: maxLevels)
        let mb = max(1, guardBits + s.exponent - 1)
        return min(JP3DBitPlaneCoder.maximumExtendedBitPlanes, mb + max(0, roiShift))
    }

    /// Computes irreversible reconstruction step size $\Delta_b = 2^{R_b - \varepsilon_b} (1 + \mu_b / 2048)$
    /// where $R_b = B_c$ for 9-7 (`dwt_getgain == 0` under `1/K` & `K/2` normalisation).
    package func stepSize(
        for band: JP3DBandGeometry,
        resolution: Int,
        maxLevels: Int,
        componentBitDepth: Int
    ) -> Double {
        if style == 0 { return 1.0 }
        let s = step(for: band, resolution: resolution, maxLevels: maxLevels)
        let rb = componentBitDepth // R_b = B for 9-7 under 1/K, K/2 normalisation
        let frac = 1.0 + Double(s.mantissa) / 2048.0
        return scalbn(frac, rb - s.exponent)
    }

    /// Builds normative reversible (`qstyle = 0`) `QCD` parameters for `(levelsX, levelsY, levelsZ)`.
    /// Maximises wire-representable `Mb = G + eps_b - 1` (`G <= 7, eps_b <= 31 -> Mb <= 37`) without private lifts.
    package static func makeReversible(
        maxBitDepth: Int,
        levelsX: Int,
        levelsY: Int,
        levelsZ: Int,
        usesReversibleMCT: Bool = false
    ) -> JP3DQuantizationParameters {
        let nl = max(levelsX, max(levelsY, levelsZ))
        let effPrecision = maxBitDepth + (usesReversibleMCT ? 1 : 0)
        let maxGain = (levelsX > 0 ? 1 : 0) + (levelsY > 0 ? 1 : 0) + (levelsZ > 0 ? 1 : 0)
        // Desired Mb for band with `gain` is `effPrecision + gain + 1` (equivalent to G = 2, eps = effPrecision + gain).
        // When `effPrecision + maxGain > 31`, raise G up to 7 so wire `Mb = G + eps - 1` reaches up to 37 honestly.
        let maxDesiredMb = min(37, effPrecision + maxGain + 1)
        let guardBits = min(7, max(2, maxDesiredMb - 31 + 1))

        var steps: [(exponent: Int, mantissa: Int)] = []
        // r = 0: LLL (gain = 0)
        let lllMb = min(37, effPrecision + 1)
        steps.append((exponent: min(31, max(0, lllMb - guardBits + 1)), mantissa: 0))
        if nl >= 1 {
            for r in 1...nl {
                let step = nl - r
                let ax = step < levelsX
                let ay = step < levelsY
                let az = step < levelsZ
                for bandNo in 1...7 {
                    let x0b = bandNo & 1
                    let y0b = (bandNo >> 1) & 1
                    let z0b = (bandNo >> 2) & 1
                    if (x0b == 1 && !ax) || (y0b == 1 && !ay) || (z0b == 1 && !az) { continue }
                    let gain = x0b + y0b + z0b
                    let desiredMb = min(37, effPrecision + gain + 1)
                    let exp = min(31, max(0, desiredMb - guardBits + 1))
                    steps.append((exponent: exp, mantissa: 0))
                }
            }
        }
        return JP3DQuantizationParameters(style: 0, guardBits: guardBits, steps: steps)
    }

    /// Builds normative scalar-expounded (`qstyle = 2`) `QCD` parameters for 9-7 irreversible encoding.
    /// Maps requested `targetPSNR` or `targetBitrate` to a well-calibrated base quantisation step size.
    package static func makeIrreversible(
        maxBitDepth: Int,
        levelsX: Int,
        levelsY: Int,
        levelsZ: Int,
        baseStepScale: Double = 1.0
    ) -> JP3DQuantizationParameters {
        let nl = max(levelsX, max(levelsY, levelsZ))
        let guardBits = 2
        let clampedScale = max(1.0 / 64.0, min(4096.0, baseStepScale))

        func encodeStep(_ delta: Double) -> (exponent: Int, mantissa: Int) {
            let safeDelta = max(1e-9, delta)
            // delta = 2^(B - eps) * (1 + mu / 2048) => log2(delta) = B - eps + log2(1 + mu/2048)
            let logVal = log2(safeDelta)
            let fl = Int(floor(logVal))
            let eps = max(0, min(31, maxBitDepth - fl))
            let scaled = safeDelta / scalbn(1.0, maxBitDepth - eps)
            let mu = max(0, min(2047, Int(((scaled - 1.0) * 2048.0).rounded())))
            return (exponent: eps, mantissa: mu)
        }

        // Under 1/K (low-pass) and K/2 (high-pass) scaling, the L2 synthesis energy gain of a
        // high-pass axis is ~2x relative to low-pass, so unit norm-weighted step size scales by
        // 1 / 2^(x0b + y0b + z0b) on high-pass bands (giving higher eps on high-pass bands, matching openjp3d!).
        var steps: [(exponent: Int, mantissa: Int)] = []
        steps.append(encodeStep(clampedScale))
        if nl >= 1 {
            for r in 1...nl {
                let step = nl - r
                let ax = step < levelsX
                let ay = step < levelsY
                let az = step < levelsZ
                for bandNo in 1...7 {
                    let x0b = bandNo & 1
                    let y0b = (bandNo >> 1) & 1
                    let z0b = (bandNo >> 2) & 1
                    if (x0b == 1 && !ax) || (y0b == 1 && !ay) || (z0b == 1 && !az) { continue }
                    let gain = x0b + y0b + z0b
                    let bandDelta = clampedScale / Double(1 << gain)
                    steps.append(encodeStep(bandDelta))
                }
            }
        }
        return JP3DQuantizationParameters(style: 2, guardBits: guardBits, steps: steps)
    }

    /// Derives `baseStepScale` (in LSB units of `maxBitDepth`) from `JP3DCompressionMode`.
    package static func baseStepScale(for mode: JP3DCompressionMode, bitDepth: Int) -> Double {
        let peak = Double((UInt64(1) << UInt64(min(30, max(1, bitDepth)))) - 1)
        switch mode {
        case .lossless, .losslessHTJ2K:
            return 1.0
        case .visuallyLossless:
            // High-fidelity step (~0.75 LSB at 8-bit, scaled gently with bit depth)
            return max(0.5, peak / 340.0)
        case .lossy(let psnr), .lossyHTJ2K(let psnr):
            // Uniform quantisation MSE ~ Delta^2 / 12 => Delta ~ sqrt(12) * peak * 10^(-PSNR / 20)
            let clampedPSNR = max(10.0, min(90.0, psnr))
            let delta = 3.464101615 * peak * pow(10.0, -clampedPSNR / 20.0)
            return max(0.25, delta)
        case .targetBitrate(let bpp):
            let ratio = max(0.05, min(Double(bitDepth), Double(bpp))) / Double(max(1, bitDepth))
            // Fine step at high bpp, coarser step at low bpp
            return max(0.5, pow(2.0, (1.0 - ratio) * 4.5))
        }
    }
}

// MARK: - 3D Tier-2 Packet Sequencer, Packet Header Coder & Tile Codec (Clause B.10)

package struct JP3DPacketAddress: Sendable, Hashable {
    package let layer: Int
    package let resolution: Int
    package let component: Int
    package let precinct: Int
}

package struct JP3DIndexedPacket: Sendable {
    package let address: JP3DPacketAddress
    package let byteRange: Range<Int>
}

package enum JP3DTier2Coder {
    /// Maps public `JP3DProgressionOrder` to normative ITU-T T.809 Table A.5 progression code `0...4`:
    /// - `.lrcps` -> `0` (`LRCP`)
    /// - `.rlcps` -> `1` (`RLCP`)
    /// - `.slrcp` -> `2` (`RPCL`, resolution-position(Z,Y,X)-component-layer)
    /// - `.pcrls` -> `3` (`PCRL`, position(Z,Y,X)-component-resolution-layer)
    /// - `.cprls` -> `4` (`CPRL`, component-position(Z,Y,X)-resolution-layer)
    @inline(__always)
    package static func progressionCode(for order: JP3DProgressionOrder) -> UInt8 {
        switch order {
        case .lrcps: return 0
        case .rlcps: return 1
        case .slrcp: return 2
        case .pcrls: return 3
        case .cprls: return 4
        }
    }

    @inline(__always)
    package static func progressionOrder(for code: UInt8) -> JP3DProgressionOrder {
        switch code {
        case 0: return .lrcps
        case 1: return .rlcps
        case 2: return .slrcp
        case 3: return .pcrls
        case 4: return .cprls
        default: return .lrcps
        }
    }

    /// Streams the exact normative 3D packet order per ITU-T Rec. T.809 Clause B.10.1 without materialising
    /// an `O(totalLayers * totalPrecincts)` `[JP3DPacketAddress]` or `Set<JP3DPacketAddress>` table.
    ///
    /// - `LRCP` (`0`) and `RLCP` (`1`) execute in `O(1)` heap memory.
    /// - `RPCL` (`2`), `PCRL` (`3`), and `CPRL` (`4`) step spatial coordinates in `O(1)` scalars and track
    ///   visited `(component, resolution, precinct)` tuples in a pre-admitted `O(totalPrecincts)` boolean table
    ///   independent of `totalLayers`.
    /// - Returning `false` from `body` terminates iteration immediately.
    package static func forEachPacketAddress(
        geometries: [JP3DTileComponentGeometry],
        progression: UInt8,
        totalLayers: Int,
        admitWorkspaceBytes: ((Int) throws -> Void)? = nil,
        body: (JP3DPacketAddress) throws -> Bool
    ) throws {
        let compCount = geometries.count
        guard compCount > 0, totalLayers > 0 else { return }
        var totalPrecincts = 0
        var totalResolutions = 0
        var maxNL = 0
        for geom in geometries {
            totalResolutions = try jp3dCheckedAdd(totalResolutions, geom.resolutions.count)
            maxNL = max(maxNL, geom.maxLevels)
            for res in geom.resolutions {
                totalPrecincts = try jp3dCheckedAdd(totalPrecincts, res.precincts.count, label: "3D tile precinct count")
            }
        }
        guard totalPrecincts > 0 else { return }
        _ = try jp3dCheckedMul(totalPrecincts, totalLayers, label: "3D tile packet count")

        func precinctAt(component c: Int, resolution r: Int, x: Int, y: Int, z: Int) -> Int? {
            let geom = geometries[c]
            guard r <= geom.maxLevels else { return nil }
            let res = geom.resolutions[r]
            guard res.precinctsWide > 0, res.precinctsHigh > 0, res.precinctsDeep > 0 else { return nil }

            let rpx = res.ppx + res.decompX
            let rpy = res.ppy + res.decompY
            let rpz = res.ppz + res.decompZ
            guard rpx < 31, rpy < 31, rpz < 31 else { return nil }
            let stepX = 1 << rpx, stepY = 1 << rpy, stepZ = 1 << rpz

            let startsX = (x % stepX == 0) || (x == geom.x0 && ((res.x0 << res.decompX) % stepX != 0))
            let startsY = (y % stepY == 0) || (y == geom.y0 && ((res.y0 << res.decompY) % stepY != 0))
            let startsZ = (z % stepZ == 0) || (z == geom.z0 && ((res.z0 << res.decompZ) % stepZ != 0))
            guard startsX, startsY, startsZ else { return nil }

            let rx = jp3dCeilDivPow2(x, res.decompX)
            let ry = jp3dCeilDivPow2(y, res.decompY)
            let rz = jp3dCeilDivPow2(z, res.decompZ)

            let px = jp3dFloorDivPow2(rx, res.ppx) - jp3dFloorDivPow2(res.x0, res.ppx)
            let py = jp3dFloorDivPow2(ry, res.ppy) - jp3dFloorDivPow2(res.y0, res.ppy)
            let pz = jp3dFloorDivPow2(rz, res.ppz) - jp3dFloorDivPow2(res.z0, res.ppz)
            guard px >= 0, px < res.precinctsWide,
                  py >= 0, py < res.precinctsHigh,
                  pz >= 0, pz < res.precinctsDeep else { return nil }
            return px + py * res.precinctsWide + pz * res.precinctsWide * res.precinctsHigh
        }

        @inline(__always)
        func nextGridPosition(_ v: Int, step: Int) -> Int {
            let s = max(1, step)
            let rem = ((v % s) + s) % s
            return v + (s - rem)
        }

        switch progression {
        case 0: // LRCP — O(1) memory
            for l in 0..<totalLayers {
                for r in 0...maxNL {
                    for c in 0..<compCount where r <= geometries[c].maxLevels {
                        for p in 0..<geometries[c].resolutions[r].precincts.count {
                            if !(try body(JP3DPacketAddress(layer: l, resolution: r, component: c, precinct: p))) {
                                return
                            }
                        }
                    }
                }
            }
        case 1: // RLCP — O(1) memory
            for r in 0...maxNL {
                for l in 0..<totalLayers {
                    for c in 0..<compCount where r <= geometries[c].maxLevels {
                        for p in 0..<geometries[c].resolutions[r].precincts.count {
                            if !(try body(JP3DPacketAddress(layer: l, resolution: r, component: c, precinct: p))) {
                                return
                            }
                        }
                    }
                }
            }
        case 2, 3, 4: // RPCL, PCRL, CPRL (spatial step across Z outer, Y middle, X inner)
            let visitedElements = try jp3dCheckedMul(
                totalPrecincts,
                MemoryLayout<Bool>.stride,
                label: "3D spatial progression visited table"
            )
            let visitedBytes = try jp3dCheckedAdd(visitedElements,
                try jp3dCheckedAdd(32,
                    try jp3dCheckedAdd(
                        try jp3dCheckedMul(compCount, 32 + MemoryLayout<[[Bool]]>.stride),
                        try jp3dCheckedMul(totalResolutions, 32 + MemoryLayout<[Bool]>.stride))))
            try admitWorkspaceBytes?(visitedBytes)
            var visitedCRP: [[[Bool]]] = geometries.map { geom in
                geom.resolutions.map { res in
                    [Bool](repeating: false, count: res.precincts.count)
                }
            }
            var emittedCRPCount = 0

            var stepX = Int.max, stepY = Int.max, stepZ = Int.max
            var minX = Int.max, maxX = Int.min
            var minY = Int.max, maxY = Int.min
            var minZ = Int.max, maxZ = Int.min
            for geom in geometries {
                minX = min(minX, geom.x0); maxX = max(maxX, geom.x1)
                minY = min(minY, geom.y0); maxY = max(maxY, geom.y1)
                minZ = min(minZ, geom.z0); maxZ = max(maxZ, geom.z1)
                for res in geom.resolutions {
                    let sx = (res.ppx + res.decompX) < 31 ? (1 << (res.ppx + res.decompX)) : (1 << 30)
                    let sy = (res.ppy + res.decompY) < 31 ? (1 << (res.ppy + res.decompY)) : (1 << 30)
                    let sz = (res.ppz + res.decompZ) < 31 ? (1 << (res.ppz + res.decompZ)) : (1 << 30)
                    stepX = min(stepX, sx)
                    stepY = min(stepY, sy)
                    stepZ = min(stepZ, sz)
                }
            }

            func emitCRP(_ c: Int, _ r: Int, _ x: Int, _ y: Int, _ z: Int) throws -> Bool {
                guard let p = precinctAt(component: c, resolution: r, x: x, y: y, z: z) else { return true }
                guard !visitedCRP[c][r][p] else { return true }
                visitedCRP[c][r][p] = true
                emittedCRPCount += 1
                for l in 0..<totalLayers {
                    if !(try body(JP3DPacketAddress(layer: l, resolution: r, component: c, precinct: p))) {
                        return false
                    }
                }
                return true
            }

            if stepX < Int.max, stepY < Int.max, stepZ < Int.max, minX < maxX, minY < maxY, minZ < maxZ {
                if progression == 2 { // RPCL
                    for r in 0...maxNL {
                        var z = minZ
                        while z < maxZ {
                            var y = minY
                            while y < maxY {
                                var x = minX
                                while x < maxX {
                                    for c in 0..<compCount where r <= geometries[c].maxLevels {
                                        if !(try emitCRP(c, r, x, y, z)) { return }
                                    }
                                    x = nextGridPosition(x, step: stepX)
                                }
                                y = nextGridPosition(y, step: stepY)
                            }
                            z = nextGridPosition(z, step: stepZ)
                        }
                    }
                } else if progression == 3 { // PCRL
                    var z = minZ
                    while z < maxZ {
                        var y = minY
                        while y < maxY {
                            var x = minX
                            while x < maxX {
                                for c in 0..<compCount {
                                    for r in 0...geometries[c].maxLevels {
                                        if !(try emitCRP(c, r, x, y, z)) { return }
                                    }
                                }
                                x = nextGridPosition(x, step: stepX)
                            }
                            y = nextGridPosition(y, step: stepY)
                        }
                        z = nextGridPosition(z, step: stepZ)
                    }
                } else { // CPRL
                    for c in 0..<compCount {
                        var z = minZ
                        while z < maxZ {
                            var y = minY
                            while y < maxY {
                                var x = minX
                                while x < maxX {
                                    for r in 0...geometries[c].maxLevels {
                                        if !(try emitCRP(c, r, x, y, z)) { return }
                                    }
                                    x = nextGridPosition(x, step: stepX)
                                }
                                y = nextGridPosition(y, step: stepY)
                            }
                            z = nextGridPosition(z, step: stepZ)
                        }
                    }
                }
            }

            // Safety completion pass in LRCP order if any edge precinct was skipped by large shifts (rpx >= 31).
            if emittedCRPCount < totalPrecincts {
                for l in 0..<totalLayers {
                    for r in 0...maxNL {
                        for c in 0..<compCount where r <= geometries[c].maxLevels {
                            for p in 0..<geometries[c].resolutions[r].precincts.count where !visitedCRP[c][r][p] {
                                if !(try body(JP3DPacketAddress(layer: l, resolution: r, component: c, precinct: p))) {
                                    return
                                }
                            }
                        }
                    }
                }
            }
        default:
            throw CodecError(.malformedInput, "Unknown 3D progression order \(progression).")
        }
    }

    /// Generates the exact normative 3D packet order per ITU-T Rec. T.809 Clause B.10.1.
    /// Pre-admits the `O(totalPrecincts * totalLayers)` address buffer when `admitWorkspaceBytes` is supplied.
    package static func packetSequence(
        geometries: [JP3DTileComponentGeometry],
        progression: UInt8,
        totalLayers: Int,
        admitWorkspaceBytes: ((Int) throws -> Void)? = nil
    ) throws -> [JP3DPacketAddress] {
        let compCount = geometries.count
        guard compCount > 0, totalLayers > 0 else { return [] }
        var totalPrecincts = 0
        for geom in geometries {
            for res in geom.resolutions {
                totalPrecincts = try jp3dCheckedAdd(totalPrecincts, res.precincts.count, label: "3D tile precinct count")
            }
        }
        guard totalPrecincts > 0 else { return [] }
        let expected = try jp3dCheckedMul(totalPrecincts, totalLayers, label: "3D tile packet count")
        let sequenceBytes = try jp3dCheckedMul(
            expected,
            MemoryLayout<JP3DPacketAddress>.stride,
            label: "3D packet address sequence buffer"
        )
        try admitWorkspaceBytes?(sequenceBytes)
        var sequence: [JP3DPacketAddress] = []
        sequence.reserveCapacity(expected)
        try forEachPacketAddress(
            geometries: geometries,
            progression: progression,
            totalLayers: totalLayers,
            admitWorkspaceBytes: admitWorkspaceBytes
        ) { addr in
            sequence.append(addr)
            return true
        }
        return sequence
    }

    // MARK: - 3D Packet Encoding & Decoding

    package struct BlockEncodingEntry: Sendable {
        package let encoding: CodeBlockEncoding
        package let isHT: Bool
        /// Index of the first non-placeholder HT cleanup pass (`3 * P0`, default `0`).
        package let firstHTCleanupPass: Int

        package init(encoding: CodeBlockEncoding, isHT: Bool = false, firstHTCleanupPass: Int = 0) {
            self.encoding = encoding
            self.isHT = isHT
            self.firstHTCleanupPass = max(0, firstHTCleanupPass)
        }
    }

    /// Computes ITU-T T.814 Annex B (`B.1`–`B.3`) packet-header codeword segment pass chunks for an HT code-block.
    package static func htSegmentPassCountsForEncoding(
        start: Int,
        count: Int,
        firstCleanupPass: Int = 0
    ) -> [Int] {
        guard count > 0 else { return [] }
        // Pure placeholder-pass packet before `firstCleanupPass`: single zero-length segment of `count` passes.
        if start + count <= firstCleanupPass {
            return [count]
        }
        var chunks: [Int] = []
        var index = start
        var remaining = count
        var current = 0
        while remaining > 0 {
            current += 1
            remaining -= 1
            let terminates: Bool
            if index < firstCleanupPass {
                // Trailing placeholder passes in the same packet as `firstCleanupPass` merge with `firstCleanupPass` (Clause B.2).
                terminates = false
            } else if index == firstCleanupPass {
                terminates = true
            } else {
                // After `firstCleanupPass` (`3 * P0`), every HT cleanup pass (`index % 3 == 0`) and
                // every HT MagRef pass (`index % 3 == 2`) terminates its codeword segment.
                terminates = (index % 3 == 0) || (index % 3 == 2)
            }
            if terminates || remaining == 0 {
                chunks.append(current)
                current = 0
            }
            index += 1
        }
        return chunks
    }

    private struct PrecinctTrees3D {
        var inclusion: [JP3DTagTree]
        var msb: [JP3DTagTree]
    }

    private struct BlockProgressState {
        var included = false
        var lblock = 3
        var emittedPasses = 0
        var emittedBytes = 0
    }

    /// Encodes all packets of a 3D tile into a contiguous tile-part bitstream while reserving both
    /// packet-header bytes (`countsTowardCompressedOutput: true`) and transient duplicate body-copy
    /// overlap bytes (`countsTowardCompressedOutput: false`) BEFORE appending to `out`.
    ///
    /// Callers holding `encodings` must clear `encodings` before releasing `bodyOverlapBytes`.
    package static func encodePacketsWithOverlap(
        geometries: [JP3DTileComponentGeometry],
        cod: JP3DCODInfo,
        componentCODs: [JP3DCODInfo]? = nil,
        encodings: [[[[[BlockEncodingEntry]]]]],
        budget: EntropyOutputBudget? = nil,
        admitEncodedBytes: ((Int) throws -> Void)? = nil,
        cancellation: () throws -> Void
    ) throws -> (data: Data, bodyOverlapBytes: Int) {
        let totalLayers = max(1, cod.numLayers)

        var trees: [[[PrecinctTrees3D]]] = []
        var progress: [[[[[BlockProgressState]]]]] = []
        trees.reserveCapacity(geometries.count)
        progress.reserveCapacity(geometries.count)

        for (c, geom) in geometries.enumerated() {
            var compTrees: [[PrecinctTrees3D]] = []
            var compProg: [[[[BlockProgressState]]]] = []
            compTrees.reserveCapacity(geom.resolutions.count)
            compProg.reserveCapacity(geom.resolutions.count)
            for (r, res) in geom.resolutions.enumerated() {
                var resTrees: [PrecinctTrees3D] = []
                var resProg: [[[BlockProgressState]]] = []
                resTrees.reserveCapacity(res.precincts.count)
                resProg.reserveCapacity(res.precincts.count)
                for (p, prc) in res.precincts.enumerated() {
                    var incList: [JP3DTagTree] = []
                    var msbList: [JP3DTagTree] = []
                    var prcProg: [[BlockProgressState]] = []
                    incList.reserveCapacity(prc.bands.count)
                    msbList.reserveCapacity(prc.bands.count)
                    prcProg.reserveCapacity(prc.bands.count)
                    for (b, pb) in prc.bands.enumerated() {
                        var inc = try JP3DTagTree(width: pb.blocksWide, height: pb.blocksHigh, depth: pb.blocksDeep)
                        var msb = try JP3DTagTree(width: pb.blocksWide, height: pb.blocksHigh, depth: pb.blocksDeep)
                        var bandProg: [BlockProgressState] = []
                        bandProg.reserveCapacity(pb.blocks.count)
                        for k in 0..<pb.blocks.count {
                            let enc = encodings[c][r][p][b][k].encoding
                            let firstLayer = enc.layerPassCounts.firstIndex(where: { $0 > 0 }) ?? totalLayers
                            try inc.setValue(leaf: k, value: Int32(firstLayer))
                            try msb.setValue(leaf: k, value: Int32(enc.zeroBitPlanes))
                            bandProg.append(BlockProgressState())
                        }
                        incList.append(inc)
                        msbList.append(msb)
                        prcProg.append(bandProg)
                    }
                    resTrees.append(PrecinctTrees3D(inclusion: incList, msb: msbList))
                    resProg.append(prcProg)
                }
                compTrees.append(resTrees)
                compProg.append(resProg)
            }
            trees.append(compTrees)
            progress.append(compProg)
        }

        var out = Data()
        var sopSeq: UInt16 = 0
        var reservedHeaderBytes = 0
        var reservedBodyOverlapBytes = 0
        var reservedSeqScratchBytes = 0
        var succeeded = false
        defer {
            if reservedSeqScratchBytes > 0 {
                budget?.release(reservedSeqScratchBytes, countsTowardCompressedOutput: false)
            }
            if !succeeded {
                if reservedHeaderBytes > 0 {
                    budget?.release(reservedHeaderBytes, countsTowardCompressedOutput: true)
                }
                if reservedBodyOverlapBytes > 0 {
                    budget?.release(reservedBodyOverlapBytes, countsTowardCompressedOutput: false)
                }
            }
        }

        try forEachPacketAddress(
            geometries: geometries,
            progression: cod.progressionOrderByte,
            totalLayers: totalLayers,
            admitWorkspaceBytes: { bytes in
                guard bytes > 0 else { return }
                if let budget {
                    try budget.reserve(bytes, countsTowardCompressedOutput: false, site: "jp3d-tier2-seq-visited")
                    budget.recordActualAllocation(bytes, site: "jp3d-tier2-seq-visited")
                    reservedSeqScratchBytes += bytes
                }
            }
        ) { addr in
            try cancellation()
            let c = addr.component, r = addr.resolution, p = addr.precinct, l = addr.layer
            let compCOD = (componentCODs != nil && c < componentCODs!.count) ? componentCODs![c] : cod
            let compStyle = CodeBlockStyle(bits: compCOD.codeBlockStyle)
            let prc = geometries[c].resolutions[r].precincts[p]

            let anyIncluded = prc.bands.enumerated().contains { b, pb in
                pb.blocks.indices.contains { k in
                    let enc = encodings[c][r][p][b][k].encoding
                    return (l < enc.layerPassCounts.count ? enc.layerPassCounts[l] : 0) > 0
                }
            }

            var header = PacketBitWriter(budget: budget)
            var headerBytes: [UInt8] = []
            defer {
                headerBytes = []
                header.releaseScratch()
            }
            header.writeBit(anyIncluded)
            var bodySlices: [ArraySlice<UInt8>] = []

            if anyIncluded {
                for (b, pb) in prc.bands.enumerated() where !pb.blocks.isEmpty {
                    for k in 0..<pb.blocks.count {
                        let entry = encodings[c][r][p][b][k]
                        let enc = entry.encoding
                        var st = progress[c][r][p][b][k]
                        let newPasses = l < enc.layerPassCounts.count ? enc.layerPassCounts[l] : 0
                        let firstInclusion = !st.included

                        if firstInclusion {
                            try trees[c][r][p].inclusion[b].encode(writer: &header, leaf: k, threshold: Int32(l + 1))
                            guard newPasses > 0 else {
                                progress[c][r][p][b][k] = st
                                continue
                            }
                            st.included = true
                            try trees[c][r][p].msb[b].encode(
                                writer: &header,
                                leaf: k,
                                threshold: Int32(enc.zeroBitPlanes) + 1
                            )
                        } else {
                            header.writeBit(newPasses > 0)
                            guard newPasses > 0 else {
                                progress[c][r][p][b][k] = st
                                continue
                            }
                        }

                        try Tier2.writePassCount(newPasses, &header)
                        let chunks: [Int]
                        if entry.isHT {
                            chunks = htSegmentPassCountsForEncoding(
                                start: st.emittedPasses,
                                count: newPasses,
                                firstCleanupPass: entry.firstHTCleanupPass
                            )
                        } else {
                            let ebcotStyle = CodeBlockStyle(bits: compCOD.codeBlockStyle & ~0xC0)
                            chunks = Tier2.segmentPassCounts(start: st.emittedPasses, count: newPasses, style: ebcotStyle)
                        }
                        var chunkRanges: [Range<Int>] = []
                        chunkRanges.reserveCapacity(chunks.count)
                        var passCursor = st.emittedPasses
                        var byteCursor = st.emittedBytes
                        for chunk in chunks {
                            passCursor += chunk
                            let endByte = (passCursor - 1 < enc.passByteOffsets.count)
                                ? enc.passByteOffsets[passCursor - 1]
                                : enc.data.count
                            let clampedEnd = max(byteCursor, min(enc.data.count, endByte))
                            chunkRanges.append(byteCursor..<clampedEnd)
                            byteCursor = clampedEnd
                        }

                        for (chunkIdx, (chunk, range)) in zip(chunks, chunkRanges).enumerated() {
                            let segLen = range.count
                            var needed = segLen > 0 ? (Int.bitWidth - segLen.leadingZeroBitCount) : 1
                            if firstInclusion && chunkIdx == 0 && compStyle.ht && compStyle.htMixed {
                                if entry.isHT {
                                    // ISO/IEC 15444-15 Clause B.10.6: mixed HT block signals lblock > 3 and MSB == 0.
                                    needed += 1
                                    while st.lblock < 4 || st.lblock + Tier2.floorLog2(chunk) < needed {
                                        header.writeBit(true)
                                        st.lblock += 1
                                    }
                                    continue
                                }
                            }
                            while st.lblock + Tier2.floorLog2(chunk) < needed {
                                header.writeBit(true)
                                st.lblock += 1
                            }
                        }
                        header.writeBit(false)

                        for (chunk, range) in zip(chunks, chunkRanges) {
                            header.writeBits(range.count, count: st.lblock + Tier2.floorLog2(chunk))
                            bodySlices.append(enc.data[range])
                        }

                        st.emittedPasses = passCursor
                        st.emittedBytes = byteCursor
                        progress[c][r][p][b][k] = st
                    }
                }
            }

            headerBytes = header.finish()
            guard !header.allocationRejected else {
                throw CodecError(.resourceLimitExceeded, "3D packet-header staging exceeds its live allocation budget.")
            }
            let packetOverhead = (cod.usesSOP ? 6 : 0) + headerBytes.count + (cod.usesEPH ? 2 : 0)
            let packetBodyBytes = bodySlices.reduce(0) { $0 + $1.count }

            if let budget {
                if packetOverhead > 0 {
                    try budget.reserve(packetOverhead, countsTowardCompressedOutput: true, site: "jp3d-tier2-packet-header")
                    reservedHeaderBytes += packetOverhead
                }
                if packetBodyBytes > 0 {
                    try budget.reserve(packetBodyBytes, countsTowardCompressedOutput: false, site: "jp3d-tier2-packet-body-overlap")
                    reservedBodyOverlapBytes += packetBodyBytes
                }
                let packetTotal = packetOverhead + packetBodyBytes
                if packetTotal > 0 {
                    budget.recordActualAllocation(packetTotal, site: "jp3d-tier2-packet-emit")
                }
            } else {
                try admitEncodedBytes?(packetOverhead)
            }

            let previousOutputBytes = out.count
            let packetBytes = try jp3dCheckedAdd(packetOverhead, packetBodyBytes, label: "3D packet output")
            let nextOutputBytes = try jp3dCheckedAdd(previousOutputBytes, packetBytes, label: "3D tile packet output")
            // Data may relocate its previous allocation while growing. The new
            // packet bytes were admitted above; retain an additional old-buffer lease.
            try budget?.reserve(previousOutputBytes, countsTowardCompressedOutput: false, site: "jp3d-tier2-output-growth")
            defer { budget?.release(previousOutputBytes, countsTowardCompressedOutput: false, site: "jp3d-tier2-output-growth") }
            out.reserveCapacity(nextOutputBytes)
            if cod.usesSOP {
                out.append(contentsOf: [
                    0xFF, 0x91, 0x00, 0x04,
                    UInt8(sopSeq >> 8), UInt8(sopSeq & 0xFF)
                ])
                sopSeq &+= 1
            }
            out.append(contentsOf: headerBytes)
            if cod.usesEPH {
                out.append(contentsOf: [0xFF, 0x92])
            }
            for slice in bodySlices where !slice.isEmpty {
                out.append(contentsOf: slice)
            }
            return true
        }

        StorageTelemetry.recordStage("jp3d-tier2-packet-output", bytes: out.count)
        succeeded = true
        return (out, reservedBodyOverlapBytes)
    }

    /// Encodes all packets of a 3D tile into a contiguous tile-part bitstream.
    package static func encodePackets(
        geometries: [JP3DTileComponentGeometry],
        cod: JP3DCODInfo,
        componentCODs: [JP3DCODInfo]? = nil,
        encodings: [[[[[BlockEncodingEntry]]]]],
        budget: EntropyOutputBudget? = nil,
        admitEncodedBytes: ((Int) throws -> Void)? = nil,
        cancellation: () throws -> Void
    ) throws -> Data {
        let (out, overlap) = try encodePacketsWithOverlap(
            geometries: geometries,
            cod: cod,
            componentCODs: componentCODs,
            encodings: encodings,
            budget: budget,
            admitEncodedBytes: admitEncodedBytes,
            cancellation: cancellation
        )
        if overlap > 0 {
            budget?.release(overlap, countsTowardCompressedOutput: false)
        }
        return out
    }

    /// Decodes packets of a 3D tile (with optional layer/resolution filtering, truncation tolerance,
    /// per-component `COD`/`COC` styles, ITU-T T.814 Annex B `3 * P0` / `MULTIHT` segment parsing,
    /// pre-allocation workspace admission, and optional packet byte-range indexing for JPIP Class 0
    /// precinct data-bin extraction).
    package static func decodePackets(
        geometries: [JP3DTileComponentGeometry],
        cod: JP3DCODInfo,
        componentCODs: [JP3DCODInfo]? = nil,
        bytes: [UInt8],
        maxQualityLayers: Int? = nil,
        maxResolutionIndex: Int? = nil,
        tolerateTruncation: Bool = false,
        recordPacketRanges: Bool = false,
        admitWorkspaceBytes: ((Int) throws -> Void)? = nil,
        cancellation: () throws -> Void
    ) throws -> (contributions: [[[[[CodeBlockContribution]]]]], packets: [JP3DIndexedPacket], wasTruncated: Bool) {
        try admitWorkspaceBytes?(try jp3dCheckedAdd(bytes.count, 32, label: "3D packet input copy"))
        StorageTelemetry.recordStage("jp3d-packet-input-copy", bytes: bytes.count)
        return try decodePackets(
            geometries: geometries,
            cod: cod,
            componentCODs: componentCODs,
            data: Data(bytes),
            maxQualityLayers: maxQualityLayers,
            maxResolutionIndex: maxResolutionIndex,
            tolerateTruncation: tolerateTruncation,
            recordPacketRanges: recordPacketRanges,
            admitWorkspaceBytes: admitWorkspaceBytes,
            cancellation: cancellation
        )
    }

    package static func decodePackets(
        geometries: [JP3DTileComponentGeometry],
        cod: JP3DCODInfo,
        componentCODs: [JP3DCODInfo]? = nil,
        data: Data,
        maxQualityLayers: Int? = nil,
        maxResolutionIndex: Int? = nil,
        tolerateTruncation: Bool = false,
        recordPacketRanges: Bool = false,
        admitWorkspaceBytes: ((Int) throws -> Void)? = nil,
        cancellation: () throws -> Void
    ) throws -> (contributions: [[[[[CodeBlockContribution]]]]], packets: [JP3DIndexedPacket], wasTruncated: Bool) {
        let totalLayers = max(1, cod.numLayers)
        var totalPrecincts = 0
        for geom in geometries {
            for res in geom.resolutions {
                totalPrecincts = try jp3dCheckedAdd(totalPrecincts, res.precincts.count, label: "3D tile precinct count")
            }
        }
        let expectedPacketCount = try jp3dCheckedMul(totalPrecincts, totalLayers, label: "3D tile packet count")

        var result: [[[[[CodeBlockContribution]]]]] = geometries.map { geom in
            geom.resolutions.map { res in
                res.precincts.map { prc in
                    prc.bands.map { [CodeBlockContribution](repeating: CodeBlockContribution(), count: $0.blocks.count) }
                }
            }
        }
        var wireState = result
        // Track whether a non-zero HT cleanup segment has been observed yet per block (ITU-T T.814 Clause B.3).
        var wireHasHTCleanup: [[[[[Bool]]]]] = geometries.map { geom in
            geom.resolutions.map { res in
                res.precincts.map { prc in
                    prc.bands.map { [Bool](repeating: false, count: $0.blocks.count) }
                }
            }
        }
        var outHasHTCleanup = wireHasHTCleanup

        var trees: [[[PrecinctTrees3D]]] = try geometries.map { geom in
            try geom.resolutions.map { res in
                try res.precincts.map { prc in
                    PrecinctTrees3D(
                        inclusion: try prc.bands.map { try JP3DTagTree(width: $0.blocksWide, height: $0.blocksHigh, depth: $0.blocksDeep) },
                        msb: try prc.bands.map { try JP3DTagTree(width: $0.blocksWide, height: $0.blocksHigh, depth: $0.blocksDeep) }
                    )
                }
            }
        }

        let dataBase = data.startIndex
        var cursor = 0
        let end = data.count
        var indexedPackets: [JP3DIndexedPacket] = []
        var visitedPacketCount = 0
        var wasTruncated = false

        @inline(__always)
        func appendEmptySegment(_ segments: inout [CodewordSegment]) throws {
            // Keep a growth allowance with the retained segment table: old and
            // replacement capacities can coexist during Array growth.
            let tableBytes = try jp3dCheckedAdd(segments.isEmpty ? 64 : 0,
                try jp3dCheckedMul(3, MemoryLayout<CodewordSegment>.stride))
            try admitWorkspaceBytes?(tableBytes)
            segments.append(CodewordSegment())
        }

        try forEachPacketAddress(
            geometries: geometries,
            progression: cod.progressionOrderByte,
            totalLayers: totalLayers,
            admitWorkspaceBytes: admitWorkspaceBytes
        ) { addr in
            try cancellation()
            let keepLayer = maxQualityLayers.map { addr.layer < max(1, $0) } ?? true
            let keepRes = maxResolutionIndex.map { addr.resolution <= $0 } ?? true
            let keepPacket = keepLayer && keepRes
            if !keepLayer && cod.progressionOrderByte == 0 {
                return false
            }
            if cursor >= end {
                if tolerateTruncation {
                    wasTruncated = true
                    return false
                }
                throw CodecError(
                    .malformedInput,
                    "Truncated 3D tile packet stream at packet \(visitedPacketCount) of \(expectedPacketCount)."
                )
            }
            let packetStart = cursor

            let c = addr.component, r = addr.resolution, p = addr.precinct
            let compCOD = (componentCODs != nil && c < componentCODs!.count) ? componentCODs![c] : cod
            let compStyle = CodeBlockStyle(bits: compCOD.codeBlockStyle)
            let compEbcotStyle = CodeBlockStyle(bits: compCOD.codeBlockStyle & ~0xC0)
            let prc = geometries[c].resolutions[r].precincts[p]

            do {
                if cod.usesSOP {
                    if cursor + 6 <= end, data[dataBase + cursor] == 0xFF, data[dataBase + cursor + 1] == 0x91 {
                        cursor += 6
                    } else if tolerateTruncation {
                        wasTruncated = true
                        return false
                    }
                }
                var reader = PacketBitReader(data: data, start: cursor, end: end)
                var order: [(band: Int, block: Int, chunks: [Int], lengths: [Int])] = []

                if try reader.readBit() {
                    for (b, pb) in prc.bands.enumerated() where !pb.blocks.isEmpty {
                        for k in 0..<pb.blocks.count {
                            var st = wireState[c][r][p][b][k]
                            var hasCleanup = wireHasHTCleanup[c][r][p][b][k]
                            let included: Bool
                            if st.included {
                                included = try reader.readBit()
                            } else {
                                included = try trees[c][r][p].inclusion[b].decode(
                                    reader: &reader,
                                    leaf: k,
                                    threshold: Int32(addr.layer + 1)
                                )
                            }
                            guard included else { continue }
                            let firstInclusion = !st.included
                            if firstInclusion {
                                var threshold: Int32 = 1
                                while try !trees[c][r][p].msb[b].decode(reader: &reader, leaf: k, threshold: threshold) {
                                    threshold += 1
                                    guard threshold <= 80 else {
                                        throw CodecError(.malformedInput, "3D zero bit-plane count exceeds 80.")
                                    }
                                }
                                st.included = true
                                st.zeroBitPlanes = Int(trees[c][r][p].msb[b].value(leaf: k))
                                if compStyle.ht && !compStyle.htMixed {
                                    st.isHT = true
                                }
                            }
                            let newPasses = try Tier2.readPassCount(&reader)
                            while try reader.readBit() {
                                st.lblock += 1
                                guard st.lblock <= 40 else {
                                    throw CodecError(.malformedInput, "3D Lblock indicator exceeds 40.")
                                }
                            }

                            var preReadFirstMSB: Int? = nil
                            if firstInclusion && compStyle.ht && compStyle.htMixed {
                                // ITU-T T.814 Clause B.3 / B.10.6: in MIXED mode, an HT block has `Lblock > 3`
                                // on first inclusion and the MSB (first bit) of its first length field equal to `0`.
                                if st.lblock <= 3 {
                                    st.isHT = false
                                } else {
                                    let msbBit = try reader.readBit() ? 1 : 0
                                    preReadFirstMSB = msbBit
                                    st.isHT = (msbBit == 0)
                                }
                            }

                            @inline(__always)
                            func readFirstLength(width w: Int) throws -> Int {
                                guard w >= 1 else { return 0 }
                                if let msb = preReadFirstMSB {
                                    let low = w > 1 ? (try reader.readBits(w - 1)) : 0
                                    return (msb << (w - 1)) | low
                                }
                                return try reader.readBits(w)
                            }

                            var chunks: [Int] = []
                            var lengths: [Int] = []

                            if st.isHT {
                                if !hasCleanup {
                                    // ITU-T T.814 Clause B.3: before first non-zero HT cleanup pass (`3 * P0` placeholder awareness).
                                    let endPasses = st.passes + newPasses
                                    let rem = endPasses % 3
                                    if rem == 1 || (rem == 2 && newPasses == 1) || (rem == 0 && newPasses <= 2) {
                                        let w1 = st.lblock + Tier2.floorLog2(newPasses)
                                        let len0 = try readFirstLength(width: w1)
                                        if len0 > 0 {
                                            guard rem == 1 else {
                                                throw CodecError(
                                                    .malformedInput,
                                                    "HTJ2K non-zero first cleanup segment encountered at non-cleanup pass alignment (endPasses=\(endPasses))."
                                                )
                                            }
                                            hasCleanup = true
                                        }
                                        chunks = [newPasses]
                                        lengths = [len0]
                                    } else if rem == 2 {
                                        // `newPasses >= 2`: Possibility 1 (all placeholders, length 0) vs Possibility 2 (`c0 = newPasses - 1` + `1` SigProp).
                                        let c0 = newPasses - 1
                                        let w1 = st.lblock + Tier2.floorLog2(newPasses)
                                        let w2 = st.lblock + Tier2.floorLog2(c0)
                                        let len0 = try readFirstLength(width: w2)
                                        if len0 == 0 {
                                            if w1 > w2 {
                                                let extra = try reader.readBits(w1 - w2)
                                                guard extra == 0 else {
                                                    throw CodecError(.malformedInput, "Malformed HTJ2K placeholder length field in packet header.")
                                                }
                                            }
                                            chunks = [newPasses]
                                            lengths = [0]
                                        } else {
                                            hasCleanup = true
                                            let len1 = try reader.readBits(st.lblock)
                                            chunks = [c0, 1]
                                            lengths = [len0, len1]
                                        }
                                    } else {
                                        // `rem == 0 && newPasses >= 3`: Possibility 1 (all placeholders, length 0) vs Possibility 2 (`c0 = newPasses - 2` + `2` SigProp/MagRef).
                                        let c0 = newPasses - 2
                                        let w1 = st.lblock + Tier2.floorLog2(newPasses)
                                        let w2 = st.lblock + Tier2.floorLog2(c0)
                                        let len0 = try readFirstLength(width: w2)
                                        if len0 == 0 {
                                            if w1 > w2 {
                                                let extra = try reader.readBits(w1 - w2)
                                                guard extra == 0 else {
                                                    throw CodecError(.malformedInput, "Malformed HTJ2K placeholder length field in packet header.")
                                                }
                                            }
                                            chunks = [newPasses]
                                            lengths = [0]
                                        } else {
                                            hasCleanup = true
                                            let len1 = try reader.readBits(st.lblock + 1)
                                            chunks = [c0, 2]
                                            lengths = [len0, len1]
                                        }
                                    }
                                } else {
                                    // Subsequent packets after first HT cleanup pass: every `index % 3 == 0` (MULTIHT cleanup)
                                    // and `index % 3 == 2` (HT MagRef) terminates a codeword segment.
                                    chunks = htSegmentPassCountsForEncoding(
                                        start: st.passes,
                                        count: newPasses,
                                        firstCleanupPass: 0
                                    )
                                    for (idx, chunk) in chunks.enumerated() {
                                        let bitCount = st.lblock + Tier2.floorLog2(chunk)
                                        let len = idx == 0 ? (try readFirstLength(width: bitCount)) : (try reader.readBits(bitCount))
                                        lengths.append(len)
                                    }
                                }
                            } else {
                                chunks = Tier2.segmentPassCounts(start: st.passes, count: newPasses, style: compEbcotStyle)
                                for (idx, chunk) in chunks.enumerated() {
                                    let bitCount = st.lblock + Tier2.floorLog2(chunk)
                                    let len = idx == 0 ? (try readFirstLength(width: bitCount)) : (try reader.readBits(bitCount))
                                    lengths.append(len)
                                }
                            }

                            order.append((b, k, chunks, lengths))
                            wireState[c][r][p][b][k] = st
                            wireHasHTCleanup[c][r][p][b][k] = hasCleanup
                            if keepPacket {
                                var outSt = result[c][r][p][b][k]
                                if !outSt.included {
                                    outSt.included = true
                                    outSt.zeroBitPlanes = st.zeroBitPlanes
                                    outSt.isHT = st.isHT
                                }
                                outSt.lblock = st.lblock
                                result[c][r][p][b][k] = outSt
                            }
                        }
                    }
                }

                try reader.alignToByte()
                cursor = reader.position
                if cod.usesEPH {
                    guard cursor + 2 <= end, data[dataBase + cursor] == 0xFF, data[dataBase + cursor + 1] == 0x92 else {
                        throw CodecError(.malformedInput, "Missing EPH (0xFF92) marker after 3D packet header.")
                    }
                    cursor += 2
                }
                // Validate the complete packet body before moving retained
                // contributions out of result. A truncated packet must not erase
                // a previously complete contribution when tolerated below.
                var completeBodyBytes = 0
                for entry in order {
                    for length in entry.lengths {
                        guard length >= 0, length <= end - cursor - completeBodyBytes else {
                            throw CodecError(.malformedInput, "3D packet body exceeds tile-part data.")
                        }
                        completeBodyBytes += length
                    }
                }
                for entry in order {
                    var wSt = wireState[c][r][p][entry.band][entry.block]
                    var outSt = result[c][r][p][entry.band][entry.block]
                    if keepPacket {
                        // Transfer ownership before mutating a continued segment;
                        // retaining it in result forces a full payload COW copy.
                        result[c][r][p][entry.band][entry.block] = CodeBlockContribution()
                    }
                    var outSeenCleanup = outHasHTCleanup[c][r][p][entry.band][entry.block]
                    for (chunk, length) in zip(entry.chunks, entry.lengths) {
                        guard length >= 0, cursor + length <= end else {
                            throw CodecError(.malformedInput, "3D code-block segment length \(length) exceeds tile-part data.")
                        }
                        if keepPacket {
                            if outSt.isHT {
                                if !outSeenCleanup {
                                    if length == 0 {
                                        // Leading placeholder passes (`L = 0`)
                                        if outSt.segments.isEmpty {
                                            try appendEmptySegment(&outSt.segments)
                                        }
                                    } else {
                                        // First non-zero HT cleanup segment starts its own `CodewordSegment`
                                        try appendEmptySegment(&outSt.segments)
                                        outSeenCleanup = true
                                    }
                                } else {
                                    // After first HT cleanup (`outSt.passes` is `3 * P0 + 1` or greater):
                                    // `pStart % 3 == 0` -> new MULTIHT cleanup segment
                                    // `pStart % 3 == 1` -> new HT refinement segment (`SigProp` [+ `MagRef`])
                                    // `pStart % 3 == 2` -> continuation (`MagRef`) of previous `SigProp` refinement segment!
                                    let pStart = outSt.passes
                                    if outSt.segments.isEmpty || (pStart % 3) != 2 {
                                        try appendEmptySegment(&outSt.segments)
                                    }
                                }
                            } else {
                                let lastTerm = outSt.passes == 0 || compEbcotStyle.passTerminates(outSt.passes - 1)
                                if lastTerm || outSt.segments.isEmpty {
                                    try appendEmptySegment(&outSt.segments)
                                }
                            }
                            if length > 0 {
                                let priorCount = outSt.segments[outSt.segments.count - 1].data.count
                                let newCount = try jp3dCheckedAdd(priorCount, length, label: "3D segment buffer workspace")
                                // A retained allowance of three payload lengths
                                // covers the old and doubled replacement capacity.
                                // Two heap headers cover that growth overlap too.
                                let priorAllowance = priorCount == 0 ? 0 : max(8, priorCount)
                                let addedAllowance = max(8, newCount) - priorAllowance
                                let segHeapBytes = try jp3dCheckedAdd(priorCount == 0 ? 64 : 0,
                                    try jp3dCheckedMul(3, addedAllowance, label: "3D segment growth overlap"))
                                try admitWorkspaceBytes?(segHeapBytes)
                                StorageTelemetry.recordStage("jp3d-segment-buffer-append", bytes: newCount)
                                outSt.segments[outSt.segments.count - 1].data.append(
                                    contentsOf: data[(dataBase + cursor)..<(dataBase + cursor + length)]
                                )
                            }
                            outSt.segments[outSt.segments.count - 1].passes += chunk
                            outSt.passes += chunk
                        }
                        wSt.passes += chunk
                        cursor += length
                    }
                    wireState[c][r][p][entry.band][entry.block] = wSt
                    if keepPacket {
                        result[c][r][p][entry.band][entry.block] = outSt
                        outHasHTCleanup[c][r][p][entry.band][entry.block] = outSeenCleanup
                    }
                }
                if recordPacketRanges {
                    try admitWorkspaceBytes?(try jp3dCheckedAdd(indexedPackets.isEmpty ? 64 : 0,
                        try jp3dCheckedMul(3, MemoryLayout<JP3DIndexedPacket>.stride)))
                    indexedPackets.append(JP3DIndexedPacket(address: addr, byteRange: packetStart..<cursor))
                }
                visitedPacketCount += 1
            } catch {
                if error is CancellationError { throw error }
                if let ce = error as? CodecError, ce.category == .resourceLimitExceeded { throw ce }
                if tolerateTruncation {
                    wasTruncated = true
                    return false
                }
                throw error
            }
            return true
        }

        if !wasTruncated && maxQualityLayers == nil && maxResolutionIndex == nil && cursor < end {
            if tolerateTruncation {
                wasTruncated = true
            } else {
                throw CodecError(
                    .malformedInput,
                    "Trailing unconsumed bytes (\(end - cursor)) in 3D tile packet stream."
                )
            }
        }

        return (result, indexedPackets, wasTruncated)
    }
}

// MARK: - Complete Normative 3D Tile Encoder, Decoder & Wavelet-Domain Transcoder

package enum JP3DNormativeTileCodec {
    /// Encodes all components of one 3D tile `(x0..<x1, y0..<y1, z0..<z1)` into a normative
    /// ITU-T T.809 (or reconciled Part 10 + Part 15 HT-in-JP3D) tile-part payload.
    ///
    /// `componentVoxels[c]` holds `(x1-x0)*(y1-y0)*(z1-z0)` signed/unsigned integer voxel samples in `Int64`
    /// (`x` fastest, `y` middle, `z` slowest) BEFORE unsigned level shift.
    package static func encodeTile(
        componentVoxels: [[Int64]],
        componentBitDepths: [Int],
        componentSigned: [Bool],
        x0: Int, x1: Int,
        y0: Int, y1: Int,
        z0: Int, z1: Int,
        cod: JP3DCODInfo,
        qcd: JP3DQuantizationParameters,
        componentCODs: [JP3DCODInfo]? = nil,
        componentQCDs: [JP3DQuantizationParameters]? = nil,
        htConfiguration: JP3DHTJ2KConfiguration? = nil,
        targetBitrateBPP: Float? = nil,
        useAccelerated: Bool = false,
        entropyBudget: EntropyOutputBudget? = nil,
        remainingOutputLimit: (() -> Int)? = nil,
        admitEncodedBytes: ((Int) throws -> Void)? = nil,
        cancellation: () throws -> Void
    ) throws -> (data: Data, usedAccelerated: Bool) {
        let compCount = componentVoxels.count
        guard compCount > 0,
              componentBitDepths.count == compCount,
              componentSigned.count == compCount else {
            throw CodecError(.invalidArgument, "Mismatched component arrays for 3D tile encoding.")
        }

        let cods = (0..<compCount).map { c in
            (componentCODs != nil && c < componentCODs!.count) ? componentCODs![c] : cod
        }
        let qcds = (0..<compCount).map { c in
            (componentQCDs != nil && c < componentQCDs!.count) ? componentQCDs![c] : qcd
        }
        let geometries = try (0..<compCount).map { c in
            try JP3DGeometryBuilder.makeTileComponentGeometry(
                x0: x0, x1: x1, y0: y0, y1: y1, z0: z0, z1: z1, cod: cods[c]
            )
        }
        let tileW = geometries[0].width, tileH = geometries[0].height, tileD = geometries[0].depth
        let tileWH = tileW * tileH
        let voxelCount = tileWH * tileD

        let useMCT = cod.multipleComponentTransform == 1 && compCount >= 3
        let allReversible = (0..<compCount).allSatisfy { cods[$0].isLossless && qcds[$0].isReversible }
        var usedSIMD = false

        var allEncodings: [[[[[JP3DTier2Coder.BlockEncodingEntry]]]]] = []
        allEncodings.reserveCapacity(compCount)
        var totalRetainedCompressedBytes = 0
        var activeBodyOverlapBytes = 0
        var succeeded = false
        defer {
            if !succeeded {
                if activeBodyOverlapBytes > 0 {
                    entropyBudget?.release(activeBodyOverlapBytes, countsTowardCompressedOutput: false)
                }
                if totalRetainedCompressedBytes > 0 {
                    entropyBudget?.release(totalRetainedCompressedBytes, countsTowardCompressedOutput: true)
                }
            }
        }

        if allReversible {
            // 1. Level-shift unsigned components by -2^(B_c - 1) in Int64.
            var planes = componentVoxels
            for c in 0..<compCount {
                guard planes[c].count == voxelCount else {
                    throw CodecError(.invalidArgument, "3D tile component \(c) voxel count mismatch.")
                }
                if !componentSigned[c] {
                    let shift = Int64(1) << Int64(componentBitDepths[c] - 1)
                    var i = 0
                    if useAccelerated && voxelCount >= 4 {
                        let vShift = SIMD4<Int64>(repeating: shift)
                        while i + 4 <= voxelCount {
                            let v = SIMD4<Int64>(planes[c][i], planes[c][i + 1], planes[c][i + 2], planes[c][i + 3]) &- vShift
                            planes[c][i] = v[0]; planes[c][i + 1] = v[1]; planes[c][i + 2] = v[2]; planes[c][i + 3] = v[3]
                            i += 4
                        }
                        usedSIMD = true
                    }
                    while i < voxelCount {
                        planes[c][i] -= shift
                        i += 1
                    }
                }
            }
            // 2. Optional Reversible Component Transform (RCT) on components 0, 1, 2.
            if useMCT {
                var i = 0
                if useAccelerated && voxelCount >= 4 {
                    let one = SIMD4<Int64>(repeating: 1)
                    let two = SIMD4<Int64>(repeating: 2)
                    while i + 4 <= voxelCount {
                        let r = SIMD4<Int64>(planes[0][i], planes[0][i + 1], planes[0][i + 2], planes[0][i + 3])
                        let g = SIMD4<Int64>(planes[1][i], planes[1][i + 1], planes[1][i + 2], planes[1][i + 3])
                        let b = SIMD4<Int64>(planes[2][i], planes[2][i + 1], planes[2][i + 2], planes[2][i + 3])
                        let y0 = (r &+ (g &<< one) &+ b) &>> two
                        let u0 = b &- g
                        let v0 = r &- g
                        for lane in 0..<4 {
                            planes[0][i + lane] = y0[lane]
                            planes[1][i + lane] = u0[lane]
                            planes[2][i + lane] = v0[lane]
                        }
                        i += 4
                    }
                    usedSIMD = true
                }
                while i < voxelCount {
                    let r = planes[0][i], g = planes[1][i], b = planes[2][i]
                    let y0 = (r + (g << 1) + b) >> 2
                    let u0 = b - g
                    let v0 = r - g
                    planes[0][i] = y0
                    planes[1][i] = u0
                    planes[2][i] = v0
                    i += 1
                }
            }
            // 3. Forward separable 3D 5-3 DWT + Tier-1 block coding.
            for c in 0..<compCount {
                try cancellation()
                if JP3DWaveletEngine.forward53_3D(buffer: &planes[c], geometry: geometries[c], useSIMD: useAccelerated) {
                    usedSIMD = true
                }
                let compCOD = cods[c]
                let compIsHT = (compCOD.codeBlockStyle & 0x40) != 0
                let compIsMixed = (compCOD.codeBlockStyle & 0xC0) == 0xC0
                let compStyle = CodeBlockStyle(bits: compCOD.codeBlockStyle & ~0xC0)
                let (compEnc, compBytes, blkSIMD) = try encodeWaveletSubbands(
                    waveletBuffer: planes[c],
                    tileW: tileW, tileWH: tileWH,
                    geometry: geometries[c],
                    cod: cod,
                    componentCOD: compCOD,
                    qcd: qcds[c],
                    componentBitDepth: componentBitDepths[c],
                    usesReversibleMCT: useMCT && c < 3,
                    isHT: compIsHT,
                    isMixedHT: compIsMixed,
                    htConfiguration: htConfiguration,
                    ebcotStyle: compStyle,
                    maxPassesLimit: nil,
                    useAccelerated: useAccelerated,
                    entropyBudget: entropyBudget,
                    remainingOutputLimit: remainingOutputLimit,
                    admitEncodedBytes: admitEncodedBytes,
                    cancellation: cancellation
                )
                totalRetainedCompressedBytes += compBytes
                if blkSIMD { usedSIMD = true }
                allEncodings.append(compEnc)
            }
        } else {
            // Per-component reversible/irreversible (supports HETEROGENEOUS COC filters as well as standard 9-7 ICT).
            var floatPlanes = [[Double]](repeating: [], count: compCount)
            for c in 0..<compCount {
                guard componentVoxels[c].count == voxelCount else {
                    throw CodecError(.invalidArgument, "3D tile component \(c) voxel count mismatch.")
                }
                let shift = componentSigned[c] ? 0.0 : Double(Int64(1) << Int64(componentBitDepths[c] - 1))
                var fp = [Double](repeating: 0, count: voxelCount)
                for i in 0..<voxelCount {
                    fp[i] = Double(componentVoxels[c][i]) - shift
                }
                floatPlanes[c] = fp
            }
            if useMCT {
                var i = 0
                if useAccelerated && voxelCount >= 4 {
                    let cYR = SIMD4<Double>(repeating: 0.299), cYG = SIMD4<Double>(repeating: 0.587), cYB = SIMD4<Double>(repeating: 0.114)
                    let cCbR = SIMD4<Double>(repeating: -0.16875), cCbG = SIMD4<Double>(repeating: -0.33126), cCbB = SIMD4<Double>(repeating: 0.5)
                    let cCrR = SIMD4<Double>(repeating: 0.5), cCrG = SIMD4<Double>(repeating: -0.41869), cCrB = SIMD4<Double>(repeating: -0.08131)
                    while i + 4 <= voxelCount {
                        let r = SIMD4<Double>(floatPlanes[0][i], floatPlanes[0][i + 1], floatPlanes[0][i + 2], floatPlanes[0][i + 3])
                        let g = SIMD4<Double>(floatPlanes[1][i], floatPlanes[1][i + 1], floatPlanes[1][i + 2], floatPlanes[1][i + 3])
                        let b = SIMD4<Double>(floatPlanes[2][i], floatPlanes[2][i + 1], floatPlanes[2][i + 2], floatPlanes[2][i + 3])
                        let y0 = cYR * r + cYG * g + cYB * b
                        let cb = cCbR * r + cCbG * g + cCbB * b
                        let cr = cCrR * r + cCrG * g + cCrB * b
                        for lane in 0..<4 {
                            floatPlanes[0][i + lane] = y0[lane]
                            floatPlanes[1][i + lane] = cb[lane]
                            floatPlanes[2][i + lane] = cr[lane]
                        }
                        i += 4
                    }
                    usedSIMD = true
                }
                while i < voxelCount {
                    let r = floatPlanes[0][i], g = floatPlanes[1][i], b = floatPlanes[2][i]
                    floatPlanes[0][i] =  0.299 * r + 0.587 * g + 0.114 * b
                    floatPlanes[1][i] = -0.16875 * r - 0.33126 * g + 0.5 * b
                    floatPlanes[2][i] =  0.5 * r - 0.41869 * g - 0.08131 * b
                    i += 1
                }
            }
            for c in 0..<compCount {
                try cancellation()
                let geom = geometries[c]
                let compCOD = cods[c]
                let compQCD = qcds[c]
                var qPlane = [Int64](repeating: 0, count: voxelCount)
                if compCOD.isLossless && compQCD.isReversible && !useMCT {
                    let shift = componentSigned[c] ? Int64(0) : (Int64(1) << Int64(componentBitDepths[c] - 1))
                    for i in 0..<voxelCount {
                        qPlane[i] = componentVoxels[c][i] - shift
                    }
                    if JP3DWaveletEngine.forward53_3D(buffer: &qPlane, geometry: geom, useSIMD: useAccelerated) {
                        usedSIMD = true
                    }
                } else {
                    if JP3DWaveletEngine.forward97_3D(buffer: &floatPlanes[c], geometry: geom, useSIMD: useAccelerated) {
                        usedSIMD = true
                    }
                    for res in geom.resolutions {
                        for band in res.bands where !band.isEmpty {
                            let delta = compQCD.stepSize(
                                for: band,
                                resolution: res.index,
                                maxLevels: geom.maxLevels,
                                componentBitDepth: componentBitDepths[c]
                            )
                            let invDelta = 1.0 / max(1e-12, delta)
                            let mb = compQCD.magnitudeBitPlanes(
                                for: band,
                                resolution: res.index,
                                maxLevels: geom.maxLevels,
                                componentBitDepth: componentBitDepths[c]
                            )
                            let maxAllowedMag: Int64 = mb >= 62 ? (Int64.max / 2) : ((Int64(1) << Int64(mb)) - 1)
                            for bz in 0..<band.depth {
                                let zOff = (band.bufZ + bz) * tileWH
                                for by in 0..<band.height {
                                    let yOff = zOff + (band.bufY + by) * tileW + band.bufX
                                    for bx in 0..<band.width {
                                        let val = floatPlanes[c][yOff + bx] * invDelta
                                        let mag = min(maxAllowedMag, Int64(floor(abs(val))))
                                        qPlane[yOff + bx] = val < 0 ? -mag : mag
                                    }
                                }
                            }
                        }
                    }
                }
                let compIsHT = (compCOD.codeBlockStyle & 0x40) != 0
                let compIsMixed = (compCOD.codeBlockStyle & 0xC0) == 0xC0
                let compStyle = CodeBlockStyle(bits: compCOD.codeBlockStyle & ~0xC0)
                let (compEnc, compBytes, blkSIMD) = try encodeWaveletSubbands(
                    waveletBuffer: qPlane,
                    tileW: tileW, tileWH: tileWH,
                    geometry: geom,
                    cod: cod,
                    componentCOD: compCOD,
                    qcd: compQCD,
                    componentBitDepth: componentBitDepths[c],
                    usesReversibleMCT: false,
                    isHT: compIsHT,
                    isMixedHT: compIsMixed,
                    htConfiguration: htConfiguration,
                    ebcotStyle: compStyle,
                    maxPassesLimit: nil,
                    useAccelerated: useAccelerated,
                    entropyBudget: entropyBudget,
                    remainingOutputLimit: remainingOutputLimit,
                    admitEncodedBytes: admitEncodedBytes,
                    cancellation: cancellation
                )
                totalRetainedCompressedBytes += compBytes
                if blkSIMD { usedSIMD = true }
                allEncodings.append(compEnc)
            }
        }

        let tier1RetainedBytes = totalRetainedCompressedBytes
        var (firstPackets, firstBodyOverlap) = try JP3DTier2Coder.encodePacketsWithOverlap(
            geometries: geometries,
            cod: cod,
            componentCODs: cods,
            encodings: allEncodings,
            budget: entropyBudget,
            admitEncodedBytes: admitEncodedBytes,
            cancellation: cancellation
        )
        let firstHeaderBytes = max(0, firstPackets.count - firstBodyOverlap)
        if entropyBudget != nil {
            totalRetainedCompressedBytes += firstHeaderBytes
            activeBodyOverlapBytes = firstBodyOverlap
        }
        var encodedPackets = firstPackets
        firstPackets = Data()

        // If targetBitrateBPP is specified and produced bytes exceed budget, trim trailing coding passes proportionally.
        let anyHT = cods.contains { ($0.codeBlockStyle & 0x40) != 0 }
        var usedReencoded = false
        var reencodedBodyOverlap = 0
        if let bpp = targetBitrateBPP, bpp > 0, !anyHT {
            let maxBytes = max(32, Int(ceil(Double(bpp) * Double(voxelCount * compCount) / 8.0)))
            if encodedPackets.count > maxBytes {
                var trimScratchBytes = tier1RetainedBytes
                for c in geometries.indices {
                    let footprint = try JP3DGeometryBuilder.preflightTileComponentGeometry(
                        x0: x0, x1: x1, y0: y0, y1: y1, z0: z0, z1: z1,
                        cod: cods[c], includeEncodeState: true)
                    trimScratchBytes = try jp3dCheckedAdd(trimScratchBytes, footprint.encodeStateBytes)
                }
                try entropyBudget?.reserve(trimScratchBytes, countsTowardCompressedOutput: false, site: "jp3d-rate-control-copy")
                defer { entropyBudget?.release(trimScratchBytes, countsTowardCompressedOutput: false, site: "jp3d-rate-control-copy") }
                var trimmed = allEncodings
                let keepRatio = max(0.15, Double(maxBytes) / Double(encodedPackets.count))
                for c in 0..<trimmed.count {
                    for r in 0..<trimmed[c].count {
                        for p in 0..<trimmed[c][r].count {
                            for b in 0..<trimmed[c][r][p].count {
                                for k in 0..<trimmed[c][r][p][b].count {
                                    var enc = trimmed[c][r][p][b][k].encoding
                                    if enc.passCount > 1 {
                                        let kept = max(1, Int(floor(Double(enc.passCount) * keepRatio)))
                                        if kept < enc.passCount {
                                            let newEnd = enc.passTerminatedBytes[kept - 1]
                                            enc.data = Array(enc.data.prefix(min(enc.data.count, newEnd)))
                                            enc.passCount = kept
                                            enc.passByteOffsets = Array(enc.passByteOffsets.prefix(kept))
                                            if !enc.passByteOffsets.isEmpty {
                                                enc.passByteOffsets[kept - 1] = enc.data.count
                                            }
                                            enc.layerPassCounts = JP3DBitPlaneCoder.distributePassesAcrossLayers(
                                                totalPasses: kept,
                                                layers: max(1, cod.numLayers)
                                            )
                                            trimmed[c][r][p][b][k] = JP3DTier2Coder.BlockEncodingEntry(encoding: enc, isHT: false)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                let (reencoded, reOverlap) = try JP3DTier2Coder.encodePacketsWithOverlap(
                    geometries: geometries,
                    cod: cod,
                    componentCODs: cods,
                    encodings: trimmed,
                    budget: entropyBudget,
                    admitEncodedBytes: nil,
                    cancellation: cancellation
                )
                let reHeaderBytes = max(0, reencoded.count - reOverlap)
                if entropyBudget != nil {
                    totalRetainedCompressedBytes += reHeaderBytes
                    activeBodyOverlapBytes += reOverlap
                }
                trimmed.removeAll(keepingCapacity: false)
                if reencoded.count <= encodedPackets.count {
                    encodedPackets = reencoded
                    usedReencoded = true
                    reencodedBodyOverlap = reOverlap
                    if entropyBudget != nil {
                        if firstHeaderBytes > 0 {
                            entropyBudget?.release(firstHeaderBytes, countsTowardCompressedOutput: true)
                            totalRetainedCompressedBytes -= firstHeaderBytes
                        }
                        if firstBodyOverlap > 0 {
                            entropyBudget?.release(firstBodyOverlap, countsTowardCompressedOutput: false)
                            activeBodyOverlapBytes -= firstBodyOverlap
                        }
                    }
                } else if entropyBudget != nil {
                    if reHeaderBytes > 0 {
                        entropyBudget?.release(reHeaderBytes, countsTowardCompressedOutput: true)
                        totalRetainedCompressedBytes -= reHeaderBytes
                    }
                    if reOverlap > 0 {
                        entropyBudget?.release(reOverlap, countsTowardCompressedOutput: false)
                        activeBodyOverlapBytes -= reOverlap
                    }
                }
            }
        }

        // Release Tier-1 block encodings BEFORE releasing the Tier-2 duplicate body-copy overlap reservation.
        allEncodings.removeAll(keepingCapacity: false)
        if let entropyBudget {
            if activeBodyOverlapBytes > 0 {
                entropyBudget.release(activeBodyOverlapBytes, countsTowardCompressedOutput: false)
                activeBodyOverlapBytes = 0
            }
            let keptBodyBytes = usedReencoded ? reencodedBodyOverlap : firstBodyOverlap
            if tier1RetainedBytes > keptBodyBytes {
                let excessCompressed = tier1RetainedBytes - keptBodyBytes
                entropyBudget.release(excessCompressed, countsTowardCompressedOutput: true)
                totalRetainedCompressedBytes -= excessCompressed
            }
        }

        succeeded = true
        return (encodedPackets, usedSIMD)
    }

    private static func encodeWaveletSubbands(
        waveletBuffer: [Int64],
        tileW: Int, tileWH: Int,
        geometry: JP3DTileComponentGeometry,
        cod: JP3DCODInfo,
        componentCOD: JP3DCODInfo,
        qcd: JP3DQuantizationParameters,
        componentBitDepth: Int,
        usesReversibleMCT: Bool,
        isHT: Bool,
        isMixedHT: Bool,
        htConfiguration: JP3DHTJ2KConfiguration?,
        ebcotStyle: CodeBlockStyle,
        maxPassesLimit: Int?,
        useAccelerated: Bool,
        entropyBudget: EntropyOutputBudget?,
        remainingOutputLimit: (() -> Int)?,
        admitEncodedBytes: ((Int) throws -> Void)?,
        cancellation: () throws -> Void
    ) throws -> (encodings: [[[[JP3DTier2Coder.BlockEncodingEntry]]]], retainedBytes: Int, usedSIMD: Bool) {
        _ = componentCOD
        let layers = max(1, cod.numLayers)
        var usedSIMD = false
        var resList: [[[[JP3DTier2Coder.BlockEncodingEntry]]]] = []
        resList.reserveCapacity(geometry.resolutions.count)
        var retainedTier1Bytes = 0
        var succeeded = false
        defer {
            if !succeeded && retainedTier1Bytes > 0 {
                entropyBudget?.release(retainedTier1Bytes, countsTowardCompressedOutput: true)
            }
        }

        @inline(__always)
        func runHTCleanup(coeffs32: [Int32], width: Int, height: Int, bandShift: Int, maxOut: Int) throws -> [UInt8] {
            if useAccelerated {
                usedSIMD = true
                return try SIMDHTBlockCoder.encodeCleanup(
                    coefficients: coeffs32,
                    width: width,
                    height: height,
                    bandShift: bandShift,
                    maximumOutputBytes: maxOut,
                    budget: entropyBudget
                )
            }
            return try HTBlockEncoder.encodeCleanup(
                coefficients: coeffs32,
                width: width,
                height: height,
                bandShift: bandShift,
                maximumOutputBytes: maxOut,
                budget: entropyBudget
            )
        }

        @inline(__always)
        func concatenateHTSegments(_ segments: [[UInt8]], blockMaxOut: Int) throws -> [UInt8] {
            let totalLen = segments.reduce(0) { $0 + $1.count }
            guard totalLen <= blockMaxOut else {
                throw CodecError(.resourceLimitExceeded, "Encoded 3D HT code-block exceeds output byte budget.")
            }
            if segments.count == 1 { return segments[0] }
            if totalLen > 0, let entropyBudget {
                try entropyBudget.reserve(totalLen, countsTowardCompressedOutput: false, site: "jp3d-ht-segment-concat")
                entropyBudget.recordActualAllocation(totalLen, site: "jp3d-ht-segment-concat")
            }
            var allBytes: [UInt8] = []
            allBytes.reserveCapacity(totalLen)
            for seg in segments where !seg.isEmpty {
                allBytes.append(contentsOf: seg)
            }
            return allBytes
        }

        for res in geometry.resolutions {
            var prcList: [[[JP3DTier2Coder.BlockEncodingEntry]]] = []
            prcList.reserveCapacity(res.precincts.count)
            for prc in res.precincts {
                var bandList: [[JP3DTier2Coder.BlockEncodingEntry]] = []
                bandList.reserveCapacity(prc.bands.count)
                for pb in prc.bands {
                    let band = res.bands[pb.bandIndex]
                    let mb = qcd.magnitudeBitPlanes(
                        for: band,
                        resolution: res.index,
                        maxLevels: geometry.maxLevels,
                        componentBitDepth: componentBitDepth,
                        usesReversibleMCT: usesReversibleMCT
                    )
                    var blkList: [JP3DTier2Coder.BlockEncodingEntry] = []
                    blkList.reserveCapacity(pb.blocks.count)
                    for blk in pb.blocks {
                        try cancellation()
                        let count = blk.voxelCount
                        if count == 0 {
                            let empty = CodeBlockEncoding(
                                data: [], passCount: 0, zeroBitPlanes: mb,
                                layerPassCounts: [Int](repeating: 0, count: layers)
                            )
                            blkList.append(JP3DTier2Coder.BlockEncodingEntry(encoding: empty, isHT: isHT && !isMixedHT))
                            continue
                        }
                        var coeffs64 = [Int64](repeating: 0, count: count)
                        var dst = 0
                        var maxMag: UInt64 = 0
                        for cz in 0..<blk.depth {
                            let zOff = (band.bufZ + (blk.z0 - band.z0) + cz) * tileWH
                            for cy in 0..<blk.height {
                                let yOff = zOff + (band.bufY + (blk.y0 - band.y0) + cy) * tileW + band.bufX + (blk.x0 - band.x0)
                                var cx = 0
                                if useAccelerated && blk.width >= 4 {
                                    usedSIMD = true
                                    while cx + 4 <= blk.width {
                                        let v = SIMD4<Int64>(
                                            waveletBuffer[yOff + cx],
                                            waveletBuffer[yOff + cx + 1],
                                            waveletBuffer[yOff + cx + 2],
                                            waveletBuffer[yOff + cx + 3]
                                        )
                                        coeffs64[dst] = v[0]
                                        coeffs64[dst + 1] = v[1]
                                        coeffs64[dst + 2] = v[2]
                                        coeffs64[dst + 3] = v[3]
                                        let m0 = max(v[0].magnitude, v[1].magnitude)
                                        let m1 = max(v[2].magnitude, v[3].magnitude)
                                        let m = max(m0, m1)
                                        if m > maxMag { maxMag = m }
                                        dst += 4
                                        cx += 4
                                    }
                                }
                                while cx < blk.width {
                                    let val = waveletBuffer[yOff + cx]
                                    coeffs64[dst] = val
                                    let mag = val.magnitude
                                    if mag > maxMag { maxMag = mag }
                                    dst += 1
                                    cx += 1
                                }
                            }
                        }

                        var useHTForBlock = isHT
                        if isHT, let htCfg = htConfiguration {
                            switch htCfg.blockMode {
                            case .ht:
                                useHTForBlock = true
                            case .legacy:
                                useHTForBlock = !isMixedHT ? true : false
                            case .adaptive:
                                if isMixedHT {
                                    let nonZero = coeffs64.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
                                    useHTForBlock = count > 0 && (Double(nonZero) / Double(count) > 0.25)
                                } else {
                                    useHTForBlock = true
                                }
                            }
                        }
                        // HTBlockEncoder supports Int32 magnitudes < 2^30 (Mb <= 30) and planar code-blocks (depth == 1, width <= 64, height <= 64).
                        if useHTForBlock {
                            let maxAllowedHTMag = Int64(1) << 30
                            let fitsHTRange = blk.depth == 1
                                && blk.width <= 64
                                && blk.height <= 64
                                && mb <= 30
                                && coeffs64.allSatisfy { $0 > -maxAllowedHTMag && $0 < maxAllowedHTMag }
                            if !fitsHTRange {
                                if isMixedHT {
                                    useHTForBlock = false
                                } else {
                                    throw CodecError(
                                        .unsupportedFeature,
                                        "HTJ2K-in-JP3D HTONLY requires planar <=64x64x1 code-blocks and Mb <= 30 (got \(blk.width)x\(blk.height)x\(blk.depth), Mb=\(mb)); use HTMIXED for >26-bit precision."
                                    )
                                }
                            }
                        }

                        let blockMaxOut: Int
                        if let remainingOutputLimit {
                            let rem = remainingOutputLimit()
                            guard rem > 0 || maxMag == 0 else {
                                throw CodecError(.resourceLimitExceeded, "Encoded 3D code-block exceeds output byte budget.")
                            }
                            blockMaxOut = max(1, rem)
                        } else {
                            blockMaxOut = Int.max
                        }

                        if useHTForBlock {
                            if maxMag == 0 {
                                let empty = CodeBlockEncoding(
                                    data: [],
                                    passCount: 0,
                                    zeroBitPlanes: mb,
                                    layerPassCounts: [Int](repeating: 0, count: layers)
                                )
                                blkList.append(JP3DTier2Coder.BlockEncodingEntry(encoding: empty, isHT: true))
                                continue
                            }
                            let activePlanes = UInt64.bitWidth - maxMag.leadingZeroBitCount
                            guard activePlanes <= mb else {
                                throw CodecError(.invalidArgument, "3D HTJ2K coefficient requires \(activePlanes) bit-planes, exceeding band Mb=\(mb).")
                            }

                            var coeffs32 = [Int32](repeating: 0, count: count)
                            for i in 0..<count {
                                guard let v32 = Int32(exactly: coeffs64[i]) else {
                                    throw CodecError(.invalidArgument, "HTJ2K coefficient exceeds 32-bit signed range.")
                                }
                                coeffs32[i] = v32
                            }

                            let desiredHTPasses = max(1, htConfiguration?.passCount ?? 1)
                            var blockReservedBytes = 0
                            var blockConcatOverlap = 0
                            var blockSucceeded = false
                            defer {
                                if blockConcatOverlap > 0 {
                                    entropyBudget?.release(blockConcatOverlap, countsTowardCompressedOutput: false)
                                }
                                if !blockSucceeded && blockReservedBytes > 0 {
                                    entropyBudget?.release(blockReservedBytes, countsTowardCompressedOutput: true)
                                }
                            }
                            let enc: CodeBlockEncoding

                            if desiredHTPasses >= 4 && layers >= 2 && mb >= 2 && maxMag >= 2 {
                                // MULTIHT (ITU-T T.814 Clauses 7.1–7.6 & Annex B):
                                // Set 0 (`sSkip = 0`, `p_0 = 1`) in Layer 0 (`HT Cleanup` + `HT SigProp` + `HT MagRef`),
                                // Set 1 (`sSkip = 1`, `p_1 = 0`) in Layer `layers - 1` (`HT Cleanup` at full precision).
                                var cup0 = try runHTCleanup(
                                    coeffs32: coeffs32,
                                    width: blk.width,
                                    height: blk.height,
                                    bandShift: 1,
                                    maxOut: blockMaxOut
                                )
                                blockReservedBytes += cup0.count
                                let remAfterCup0 = max(1, blockMaxOut - cup0.count)
                                guard blockMaxOut - cup0.count >= 0 else {
                                    throw CodecError(.resourceLimitExceeded, "Encoded 3D HT code-block exceeds output byte budget.")
                                }
                                var ref0 = try HTBlockEncoder.encodeRefinement(
                                    coefficients: coeffs64,
                                    width: blk.width,
                                    height: blk.height,
                                    cleanupBandShift: 1,
                                    includeMagRef: true,
                                    causal: ebcotStyle.causal,
                                    maximumOutputBytes: min(2046, remAfterCup0),
                                    budget: entropyBudget
                                )
                                blockReservedBytes += ref0.count
                                guard cup0.count + ref0.count <= blockMaxOut else {
                                    throw CodecError(.resourceLimitExceeded, "Encoded 3D HT code-block exceeds output byte budget.")
                                }
                                let remAfterSet0 = max(1, blockMaxOut - cup0.count - ref0.count)
                                var cup1 = try runHTCleanup(
                                    coeffs32: coeffs32,
                                    width: blk.width,
                                    height: blk.height,
                                    bandShift: 0,
                                    maxOut: remAfterSet0
                                )
                                blockReservedBytes += cup1.count
                                let off0 = cup0.count
                                let off2 = cup0.count + ref0.count
                                let allBytes = try concatenateHTSegments([cup0, ref0, cup1], blockMaxOut: blockMaxOut)
                                blockConcatOverlap = allBytes.count
                                cup0 = []
                                ref0 = []
                                cup1 = []
                                if blockConcatOverlap > 0 {
                                    entropyBudget?.release(blockConcatOverlap, countsTowardCompressedOutput: false)
                                    blockConcatOverlap = 0
                                }
                                let off3 = allBytes.count
                                var layerCounts = [Int](repeating: 0, count: layers)
                                layerCounts[0] = 3
                                layerCounts[layers - 1] += 1
                                enc = CodeBlockEncoding(
                                    data: allBytes,
                                    passCount: 4,
                                    zeroBitPlanes: mb - 2,
                                    passByteOffsets: [off0, off2, off2, off3],
                                    passTerminatedBytes: [off0, off2, off2, off3],
                                    layerPassCounts: layerCounts
                                )
                            } else if (desiredHTPasses == 2 || desiredHTPasses == 3) && mb >= 2 && maxMag >= 2 {
                                // Single HT set with HT SigProp (+ optional HT MagRef) refinement segment (`Lcup` + `Lref`).
                                var cup = try runHTCleanup(
                                    coeffs32: coeffs32,
                                    width: blk.width,
                                    height: blk.height,
                                    bandShift: 1,
                                    maxOut: blockMaxOut
                                )
                                blockReservedBytes += cup.count
                                guard cup.count <= blockMaxOut else {
                                    throw CodecError(.resourceLimitExceeded, "Encoded 3D HT code-block exceeds output byte budget.")
                                }
                                let includeMagRef = (desiredHTPasses >= 3)
                                let remForRef = max(0, blockMaxOut - cup.count)
                                var ref = try HTBlockEncoder.encodeRefinement(
                                    coefficients: coeffs64,
                                    width: blk.width,
                                    height: blk.height,
                                    cleanupBandShift: 1,
                                    includeMagRef: includeMagRef,
                                    causal: ebcotStyle.causal,
                                    maximumOutputBytes: min(2046, remForRef),
                                    budget: entropyBudget
                                )
                                blockReservedBytes += ref.count
                                let cupLen = cup.count
                                let allBytes = try concatenateHTSegments([cup, ref], blockMaxOut: blockMaxOut)
                                blockConcatOverlap = allBytes.count
                                cup = []
                                ref = []
                                if blockConcatOverlap > 0 {
                                    entropyBudget?.release(blockConcatOverlap, countsTowardCompressedOutput: false)
                                    blockConcatOverlap = 0
                                }
                                let totalP = includeMagRef ? 3 : 2
                                let offsets = includeMagRef
                                    ? [cupLen, allBytes.count, allBytes.count]
                                    : [cupLen, allBytes.count]
                                var layerCounts = [Int](repeating: 0, count: layers)
                                if layers == 1 {
                                    layerCounts[0] = totalP
                                } else {
                                    layerCounts[0] = 1
                                    layerCounts[layers - 1] = totalP - 1
                                }
                                enc = CodeBlockEncoding(
                                    data: allBytes,
                                    passCount: totalP,
                                    zeroBitPlanes: mb - 2,
                                    passByteOffsets: offsets,
                                    passTerminatedBytes: offsets,
                                    layerPassCounts: layerCounts
                                )
                            } else {
                                let coded = try runHTCleanup(
                                    coeffs32: coeffs32,
                                    width: blk.width,
                                    height: blk.height,
                                    bandShift: 0,
                                    maxOut: blockMaxOut
                                )
                                blockReservedBytes += coded.count
                                var layerCounts = [Int](repeating: 0, count: layers)
                                if !coded.isEmpty {
                                    layerCounts[0] = 1
                                }
                                enc = CodeBlockEncoding(
                                    data: coded,
                                    passCount: coded.isEmpty ? 0 : 1,
                                    zeroBitPlanes: coded.isEmpty ? mb : (mb - 1),
                                    layerPassCounts: layerCounts
                                )
                            }
                            if entropyBudget == nil {
                                try admitEncodedBytes?(enc.data.count)
                            }
                            blockSucceeded = true
                            retainedTier1Bytes += enc.data.count
                            if !enc.data.isEmpty {
                                StorageTelemetry.recordStage("jp3d-tier1-block-output", bytes: enc.data.count)
                            }
                            blkList.append(JP3DTier2Coder.BlockEncodingEntry(encoding: enc, isHT: true))
                        } else {
                            let enc = try JP3DBitPlaneCoder.encode3D(
                                coefficients: coeffs64,
                                width: blk.width,
                                height: blk.height,
                                depth: blk.depth,
                                orientation: band.orientation,
                                magnitudeBitPlanes: mb,
                                style: ebcotStyle,
                                maxPasses: maxPassesLimit,
                                qualityLayers: layers,
                                maximumOutputBytes: blockMaxOut,
                                budget: entropyBudget
                            )
                            if entropyBudget == nil {
                                try admitEncodedBytes?(enc.data.count)
                            }
                            retainedTier1Bytes += enc.data.count
                            if !enc.data.isEmpty {
                                StorageTelemetry.recordStage("jp3d-tier1-block-output", bytes: enc.data.count)
                            }
                            blkList.append(JP3DTier2Coder.BlockEncodingEntry(encoding: enc, isHT: false))
                        }
                    }
                    bandList.append(blkList)
                }
                prcList.append(bandList)
            }
            resList.append(prcList)
        }
        succeeded = true
        return (resList, retainedTier1Bytes, usedSIMD)
    }

    /// Decodes a normative ITU-T T.809 (or reconciled HT-in-JP3D) tile-part bitstream into
    /// reconstructed integer voxel arrays `componentVoxels[c]` of dimensions `(outWidth x outHeight x tileDepth)`.
    ///
    /// Preserves the R2 `resolutionLevel` contract: `resolutionLevel = K` reduces XY dimensions by `2^K`
    /// while keeping Z at full `tileDepth`.
    package static func decodeTile(
        tileData: Data,
        siz: JP3DSIZInfo,
        cod: JP3DCODInfo,
        qcd: JP3DQuantizationParameters,
        componentCODs: [JP3DCODInfo]? = nil,
        componentQCDs: [JP3DQuantizationParameters]? = nil,
        roiShifts: [Int] = [],
        allowMultiHT: Bool = true,
        disablePart1DCShiftAndClamp: Bool = false,
        x0: Int, x1: Int,
        y0: Int, y1: Int,
        z0: Int, z1: Int,
        maxQualityLayers: Int? = nil,
        resolutionLevel: Int = 0,
        tolerateTruncation: Bool = false,
        useAccelerated: Bool = false,
        admitWorkspaceBytes: ((Int) throws -> Void)? = nil,
        beforeTier1Allocation: (() throws -> Void)? = nil,
        cancellation: () throws -> Void
    ) throws -> (components: [[Int64]], outWidth: Int, outHeight: Int, outDepth: Int, wasTruncated: Bool, usedAccelerated: Bool) {
        let compCount = siz.componentCount
        let cods = (0..<compCount).map { c in
            (componentCODs != nil && c < componentCODs!.count) ? componentCODs![c] : cod
        }
        let qcds = (0..<compCount).map { c in
            (componentQCDs != nil && c < componentQCDs!.count) ? componentQCDs![c] : qcd
        }
        let geometries = try (0..<compCount).map { c in
            try JP3DGeometryBuilder.makeTileComponentGeometry(
                x0: x0, x1: x1, y0: y0, y1: y1, z0: z0, z1: z1, cod: cods[c]
            )
        }
        let tileW = geometries[0].width, tileH = geometries[0].height, tileD = geometries[0].depth
        let tileWH = tileW * tileH
        let voxelCount = tileWH * tileD
        var usedSIMD = false

        // Only apply a uniform Tier-2 resolution filter when every component has `levelsZ == 0` and identical `maxLevels`.
        let minXYLevels = cods.map { min($0.levelsX, $0.levelsY) }.min() ?? 0
        let allZZero = cods.allSatisfy { $0.levelsZ == 0 }
        let allSameNL = Set(geometries.map(\.maxLevels)).count <= 1
        let uniformSkip = min(max(0, resolutionLevel), minXYLevels)
        let maxResFilter: Int? = (allZZero && allSameNL && uniformSkip > 0) ? (geometries[0].maxLevels - uniformSkip) : nil

        var (contributions, _, packetWasTruncated) = try JP3DTier2Coder.decodePackets(
            geometries: geometries,
            cod: cod,
            componentCODs: cods,
            data: tileData,
            maxQualityLayers: maxQualityLayers,
            maxResolutionIndex: maxResFilter,
            tolerateTruncation: tolerateTruncation,
            recordPacketRanges: false,
            admitWorkspaceBytes: admitWorkspaceBytes,
            cancellation: cancellation
        )
        try beforeTier1Allocation?()
        let useMCT = cod.multipleComponentTransform == 1 && compCount >= 3

        // Decode Tier-1 code-blocks into integer wavelet sub-band buffers `[Int64]`.
        var intSubbandPlanes: [[Int64]] = []
        intSubbandPlanes.reserveCapacity(compCount)

        for c in 0..<compCount {
            let geom = geometries[c]
            let compCOD = cods[c]
            let compQCD = qcds[c]
            let compReversible = compCOD.isLossless && compQCD.isReversible
            let useMidpoint = !compReversible && (maxQualityLayers != nil || packetWasTruncated)
            let ebcotStyle = CodeBlockStyle(bits: compCOD.codeBlockStyle & ~0xC0)

            var wBuf = [Int64](repeating: 0, count: voxelCount)
            let compBitDepth = siz.bitDepth(forComponent: c)
            let roiShift = c < roiShifts.count ? roiShifts[c] : 0

            for (r, res) in geom.resolutions.enumerated() {
                if let maxR = maxResFilter, r > maxR { continue }
                for (p, prc) in res.precincts.enumerated() {
                    for (b, pb) in prc.bands.enumerated() {
                        let band = res.bands[pb.bandIndex]
                        let mb = compQCD.magnitudeBitPlanes(
                            for: band,
                            resolution: r,
                            maxLevels: geom.maxLevels,
                            componentBitDepth: compBitDepth,
                            usesReversibleMCT: compReversible && useMCT && c < 3,
                            roiShift: roiShift
                        )
                        for (k, blk) in pb.blocks.enumerated() {
                            try cancellation()
                            let contrib = contributions[c][r][p][b][k]
                            guard contrib.included, contrib.passes > 0, blk.voxelCount > 0 else { continue }

                            let decodedBlock: [Int64]
                            if contrib.isHT {
                                guard blk.depth == 1, !contrib.segments.isEmpty else {
                                    throw CodecError(.malformedInput, "Malformed HTJ2K-in-JP3D code-block contribution.")
                                }
                                let segInputs = contrib.segments.map {
                                    HTSegmentInput(data: $0.data, passes: $0.passes)
                                }
                                decodedBlock = try HTBlockDecoder.decodeHTCodeBlock(
                                    segments: segInputs,
                                    zeroBitPlanes: contrib.zeroBitPlanes,
                                    totalPasses: contrib.passes,
                                    width: blk.width,
                                    height: blk.height,
                                    kMax: mb,
                                    causal: (compCOD.codeBlockStyle & 0x08) != 0,
                                    allowMultiHT: allowMultiHT,
                                    midpointReconstruction: useMidpoint
                                )
                            } else {
                                decodedBlock = try JP3DBitPlaneCoder.decode3D(
                                    segments: contrib.segments,
                                    width: blk.width,
                                    height: blk.height,
                                    depth: blk.depth,
                                    orientation: band.orientation,
                                    zeroBitPlanes: contrib.zeroBitPlanes,
                                    passCount: contrib.passes,
                                    magnitudeBitPlanes: mb,
                                    style: ebcotStyle,
                                    midpointReconstruction: useMidpoint
                                )
                            }

                            var src = 0
                            for cz in 0..<blk.depth {
                                let zOff = (band.bufZ + (blk.z0 - band.z0) + cz) * tileWH
                                for cy in 0..<blk.height {
                                    let yOff = zOff + (band.bufY + (blk.y0 - band.y0) + cy) * tileW + band.bufX + (blk.x0 - band.x0)
                                    for cx in 0..<blk.width {
                                        var v = decodedBlock[src]
                                        src += 1
                                        // Maxshift ROI descaling (ITU-T T.809 Annex F / T.800 Annex H)
                                        if roiShift > 0 && v != 0 {
                                            let threshold = Int64(1) << Int64(roiShift)
                                            let mag = v < 0 ? -v : v
                                            if mag >= threshold {
                                                let descaled = mag >> Int64(roiShift)
                                                v = v < 0 ? -descaled : descaled
                                            }
                                        }
                                        wBuf[yOff + cx] = v
                                    }
                                }
                            }
                        }
                    }
                }
            }
            contributions[c] = []
            intSubbandPlanes.append(wBuf)
        }
        contributions.removeAll(keepingCapacity: false)

        let outW = jp3dDownsampleDimension(tileW, resolutionLevel: resolutionLevel)
        let outH = jp3dDownsampleDimension(tileH, resolutionLevel: resolutionLevel)
        let outD = tileD

        var reconstructedComponents = [[Int64]](
            repeating: [Int64](repeating: 0, count: outW * outH * outD),
            count: compCount
        )

        let allReversible = (0..<compCount).allSatisfy { cods[$0].isLossless && qcds[$0].isReversible }

        if allReversible {
            var compDwtDims: [(w: Int, h: Int, extraReduce: Int)] = []
            compDwtDims.reserveCapacity(compCount)
            for c in 0..<compCount {
                try cancellation()
                let geom = geometries[c]
                let skip = min(max(0, resolutionLevel), min(cods[c].levelsX, cods[c].levelsY))
                if JP3DWaveletEngine.inverse53_3D(
                    buffer: &intSubbandPlanes[c],
                    geometry: geom,
                    skipLastXYLevels: skip,
                    useSIMD: useAccelerated
                ) {
                    usedSIMD = true
                }
                let resIdx = geom.maxLevels - skip
                compDwtDims.append((
                    w: geom.resolutions[resIdx].width,
                    h: geom.resolutions[resIdx].height,
                    extraReduce: max(0, resolutionLevel - skip)
                ))
            }
            if useMCT {
                let dwtW = compDwtDims[0].w
                let dwtH = compDwtDims[0].h
                let two = SIMD4<Int64>(repeating: 2)
                for z in 0..<outD {
                    for y in 0..<dwtH {
                        let base = z * tileWH + y * tileW
                        var x = 0
                        if useAccelerated && dwtW >= 4 {
                            while x + 4 <= dwtW {
                                let idx = base + x
                                let y0 = SIMD4<Int64>(intSubbandPlanes[0][idx], intSubbandPlanes[0][idx + 1], intSubbandPlanes[0][idx + 2], intSubbandPlanes[0][idx + 3])
                                let u0 = SIMD4<Int64>(intSubbandPlanes[1][idx], intSubbandPlanes[1][idx + 1], intSubbandPlanes[1][idx + 2], intSubbandPlanes[1][idx + 3])
                                let v0 = SIMD4<Int64>(intSubbandPlanes[2][idx], intSubbandPlanes[2][idx + 1], intSubbandPlanes[2][idx + 2], intSubbandPlanes[2][idx + 3])
                                let g = y0 &- ((u0 &+ v0) &>> two)
                                let r = v0 &+ g
                                let b = u0 &+ g
                                for lane in 0..<4 {
                                    intSubbandPlanes[0][idx + lane] = r[lane]
                                    intSubbandPlanes[1][idx + lane] = g[lane]
                                    intSubbandPlanes[2][idx + lane] = b[lane]
                                }
                                x += 4
                            }
                            usedSIMD = true
                        }
                        while x < dwtW {
                            let idx = base + x
                            let y0 = intSubbandPlanes[0][idx]
                            let u0 = intSubbandPlanes[1][idx]
                            let v0 = intSubbandPlanes[2][idx]
                            let g = y0 - ((u0 + v0) >> 2)
                            let r = v0 + g
                            let b = u0 + g
                            intSubbandPlanes[0][idx] = r
                            intSubbandPlanes[1][idx] = g
                            intSubbandPlanes[2][idx] = b
                            x += 1
                        }
                    }
                }
            }
            for c in 0..<compCount {
                let dwtW = compDwtDims[c].w
                let dwtH = compDwtDims[c].h
                let extraReduce = compDwtDims[c].extraReduce
                let compDepth = siz.bitDepth(forComponent: c)
                let compSigned = siz.isSigned(forComponent: c)
                // ITU-T T.801 Annex J disables the Part 1 DC level shift and per-wire-component clamp when MCO applies.
                let shift: Int64 = (disablePart1DCShiftAndClamp || compSigned) ? 0 : (Int64(1) << Int64(compDepth - 1))
                let minVal: Int64 = disablePart1DCShiftAndClamp
                    ? (Int64.min / 2)
                    : (compSigned ? -(Int64(1) << Int64(compDepth - 1)) : 0)
                let maxVal: Int64 = disablePart1DCShiftAndClamp
                    ? (Int64.max / 2)
                    : (compSigned
                        ? ((Int64(1) << Int64(compDepth - 1)) - 1)
                        : ((Int64(1) << Int64(compDepth)) - 1))

                var outPlane = [Int64](repeating: 0, count: outW * outH * outD)
                let strideStep = extraReduce >= 30 ? max(1, max(dwtW, dwtH)) : (1 << extraReduce)
                if strideStep == 1 && useAccelerated && outW >= 4 {
                    let vShift = SIMD4<Int64>(repeating: shift)
                    for z in 0..<outD {
                        for oy in 0..<outH {
                            let sy = min(dwtH - 1, oy)
                            let srcBase = z * tileWH + sy * tileW
                            let dstBase = z * (outW * outH) + oy * outW
                            var ox = 0
                            while ox + 4 <= outW {
                                let raw = SIMD4<Int64>(
                                    intSubbandPlanes[c][srcBase + ox],
                                    intSubbandPlanes[c][srcBase + ox + 1],
                                    intSubbandPlanes[c][srcBase + ox + 2],
                                    intSubbandPlanes[c][srcBase + ox + 3]
                                ) &+ vShift
                                for lane in 0..<4 {
                                    outPlane[dstBase + ox + lane] = max(minVal, min(maxVal, raw[lane]))
                                }
                                ox += 4
                            }
                            while ox < outW {
                                let raw = intSubbandPlanes[c][srcBase + min(dwtW - 1, ox)] + shift
                                outPlane[dstBase + ox] = max(minVal, min(maxVal, raw))
                                ox += 1
                            }
                        }
                    }
                    usedSIMD = true
                } else {
                    for z in 0..<outD {
                        for oy in 0..<outH {
                            let sy = min(dwtH - 1, oy * strideStep)
                            for ox in 0..<outW {
                                let sx = min(dwtW - 1, ox * strideStep)
                                let raw = intSubbandPlanes[c][z * tileWH + sy * tileW + sx] + shift
                                outPlane[z * (outW * outH) + oy * outW + ox] = max(minVal, min(maxVal, raw))
                            }
                        }
                    }
                }
                reconstructedComponents[c] = outPlane
            }
        } else {
            // Per-component inverse 5-3 or 9-7 (supports HETEROGENEOUS COC filters and standard 9-7 ICT).
            var floatPlanes: [[Double]] = []
            floatPlanes.reserveCapacity(compCount)
            var compDwtDims: [(w: Int, h: Int, extraReduce: Int, skip: Int)] = []
            compDwtDims.reserveCapacity(compCount)

            for c in 0..<compCount {
                let geom = geometries[c]
                let compCOD = cods[c]
                let compQCD = qcds[c]
                let compDepth = siz.bitDepth(forComponent: c)
                let skip = min(max(0, resolutionLevel), min(compCOD.levelsX, compCOD.levelsY))
                let resIdx = geom.maxLevels - skip
                let dwtW = geom.resolutions[resIdx].width
                let dwtH = geom.resolutions[resIdx].height
                compDwtDims.append((w: dwtW, h: dwtH, extraReduce: max(0, resolutionLevel - skip), skip: skip))

                var fp = [Double](repeating: 0, count: voxelCount)
                if compCOD.isLossless && compQCD.isReversible && !useMCT {
                    if JP3DWaveletEngine.inverse53_3D(
                        buffer: &intSubbandPlanes[c],
                        geometry: geom,
                        skipLastXYLevels: skip,
                        useSIMD: useAccelerated
                    ) {
                        usedSIMD = true
                    }
                    for i in 0..<voxelCount {
                        fp[i] = Double(intSubbandPlanes[c][i])
                    }
                } else {
                    for res in geom.resolutions {
                        for band in res.bands where !band.isEmpty {
                            let delta = compQCD.stepSize(
                                for: band,
                                resolution: res.index,
                                maxLevels: geom.maxLevels,
                                componentBitDepth: compDepth
                            )
                            for bz in 0..<band.depth {
                                let zOff = (band.bufZ + bz) * tileWH
                                for by in 0..<band.height {
                                    let yOff = zOff + (band.bufY + by) * tileW + band.bufX
                                    for bx in 0..<band.width {
                                        let q = intSubbandPlanes[c][yOff + bx]
                                        if q > 0 {
                                            fp[yOff + bx] = (Double(q) + 0.5) * delta
                                        } else if q < 0 {
                                            fp[yOff + bx] = (Double(q) - 0.5) * delta
                                        }
                                    }
                                }
                            }
                        }
                    }
                    try cancellation()
                    if JP3DWaveletEngine.inverse97_3D(
                        buffer: &fp,
                        geometry: geom,
                        skipLastXYLevels: skip,
                        useSIMD: useAccelerated
                    ) {
                        usedSIMD = true
                    }
                    if skip > 0 {
                        let normScale = pow(1.230174104914001, Double(2 * skip))
                        for z in 0..<outD {
                            for y in 0..<dwtH {
                                let base = z * tileWH + y * tileW
                                for x in 0..<dwtW {
                                    fp[base + x] *= normScale
                                }
                            }
                        }
                    }
                }
                floatPlanes.append(fp)
            }
            if useMCT {
                let dwtW = compDwtDims[0].w
                let dwtH = compDwtDims[0].h
                for z in 0..<outD {
                    for y in 0..<dwtH {
                        let base = z * tileWH + y * tileW
                        var x = 0
                        if useAccelerated && dwtW >= 4 {
                            let c1402 = SIMD4<Double>(repeating: 1.402)
                            let c0344 = SIMD4<Double>(repeating: 0.34413)
                            let c0714 = SIMD4<Double>(repeating: 0.71414)
                            let c1772 = SIMD4<Double>(repeating: 1.772)
                            while x + 4 <= dwtW {
                                let idx = base + x
                                let y0 = SIMD4<Double>(floatPlanes[0][idx], floatPlanes[0][idx + 1], floatPlanes[0][idx + 2], floatPlanes[0][idx + 3])
                                let cb = SIMD4<Double>(floatPlanes[1][idx], floatPlanes[1][idx + 1], floatPlanes[1][idx + 2], floatPlanes[1][idx + 3])
                                let cr = SIMD4<Double>(floatPlanes[2][idx], floatPlanes[2][idx + 1], floatPlanes[2][idx + 2], floatPlanes[2][idx + 3])
                                let r = y0 + c1402 * cr
                                let g = y0 - c0344 * cb - c0714 * cr
                                let b = y0 + c1772 * cb
                                for lane in 0..<4 {
                                    floatPlanes[0][idx + lane] = r[lane]
                                    floatPlanes[1][idx + lane] = g[lane]
                                    floatPlanes[2][idx + lane] = b[lane]
                                }
                                x += 4
                            }
                            usedSIMD = true
                        }
                        while x < dwtW {
                            let idx = base + x
                            let y0 = floatPlanes[0][idx]
                            let cb = floatPlanes[1][idx]
                            let cr = floatPlanes[2][idx]
                            floatPlanes[0][idx] = y0 + 1.402 * cr
                            floatPlanes[1][idx] = y0 - 0.34413 * cb - 0.71414 * cr
                            floatPlanes[2][idx] = y0 + 1.772 * cb
                            x += 1
                        }
                    }
                }
            }
            for c in 0..<compCount {
                let dwtW = compDwtDims[c].w
                let dwtH = compDwtDims[c].h
                let extraReduce = compDwtDims[c].extraReduce
                let compDepth = siz.bitDepth(forComponent: c)
                let compSigned = siz.isSigned(forComponent: c)
                let shift = (disablePart1DCShiftAndClamp || compSigned) ? 0.0 : Double(Int64(1) << Int64(compDepth - 1))
                let minVal: Int64 = disablePart1DCShiftAndClamp
                    ? (Int64.min / 2)
                    : (compSigned ? -(Int64(1) << Int64(compDepth - 1)) : 0)
                let maxVal: Int64 = disablePart1DCShiftAndClamp
                    ? (Int64.max / 2)
                    : (compSigned
                        ? ((Int64(1) << Int64(compDepth - 1)) - 1)
                        : ((Int64(1) << Int64(compDepth)) - 1))
                var outPlane = [Int64](repeating: 0, count: outW * outH * outD)
                let strideStep = extraReduce >= 30 ? max(1, max(dwtW, dwtH)) : (1 << extraReduce)
                for z in 0..<outD {
                    for oy in 0..<outH {
                        let sy = min(dwtH - 1, oy * strideStep)
                        for ox in 0..<outW {
                            let sx = min(dwtW - 1, ox * strideStep)
                            let val = (floatPlanes[c][z * tileWH + sy * tileW + sx] + shift).rounded()
                            let clamped = Int64(max(Double(minVal), min(Double(maxVal), val)))
                            outPlane[z * (outW * outH) + oy * outW + ox] = clamped
                        }
                    }
                }
                reconstructedComponents[c] = outPlane
            }
        }

        return (reconstructedComponents, outW, outH, outD, packetWasTruncated, usedSIMD)
    }

    /// Transcodes a normative 3D tile directly in the **wavelet sub-band domain** (`EBCOT <-> HTJ2K`)
    /// WITHOUT executing inverse/forward 3D DWT or materialising `J2KVolume` pixel buffers!
    /// Re-partitions `zcb > 0` 3D EBCOT sub-bands into `zcb == 0` (`W x H x 1`) HT code-blocks and vice versa.
    package static func transcodeTileWaveletDomain(
        tileData: Data,
        siz: JP3DSIZInfo,
        sourceCOD: JP3DCODInfo,
        targetCOD: JP3DCODInfo,
        qcd: JP3DQuantizationParameters,
        sourceComponentCODs: [JP3DCODInfo]? = nil,
        targetComponentCODs: [JP3DCODInfo]? = nil,
        componentQCDs: [JP3DQuantizationParameters]? = nil,
        roiShifts: [Int] = [],
        allowSourceMultiHT: Bool = true,
        htConfiguration: JP3DHTJ2KConfiguration?,
        x0: Int, x1: Int,
        y0: Int, y1: Int,
        z0: Int, z1: Int,
        useAccelerated: Bool = false,
        admitWorkspaceBytes: ((Int) throws -> Void)? = nil,
        entropyBudget: EntropyOutputBudget? = nil,
        remainingOutputLimit: (() -> Int)? = nil,
        admitEncodedBytes: ((Int) throws -> Void)? = nil,
        cancellation: () throws -> Void
    ) throws -> (data: Data, peakWorkspaceBytes: Int, usedAccelerated: Bool) {
        let compCount = siz.componentCount
        let srcCODs = (0..<compCount).map { c in
            (sourceComponentCODs != nil && c < sourceComponentCODs!.count) ? sourceComponentCODs![c] : sourceCOD
        }
        let dstCODs = (0..<compCount).map { c in
            (targetComponentCODs != nil && c < targetComponentCODs!.count) ? targetComponentCODs![c] : targetCOD
        }
        let qcds = (0..<compCount).map { c in
            (componentQCDs != nil && c < componentQCDs!.count) ? componentQCDs![c] : qcd
        }
        let srcGeoms = try (0..<compCount).map { c in
            try JP3DGeometryBuilder.makeTileComponentGeometry(
                x0: x0, x1: x1, y0: y0, y1: y1, z0: z0, z1: z1, cod: srcCODs[c]
            )
        }
        let dstGeoms = try (0..<compCount).map { c in
            try JP3DGeometryBuilder.makeTileComponentGeometry(
                x0: x0, x1: x1, y0: y0, y1: y1, z0: z0, z1: z1, cod: dstCODs[c]
            )
        }
        let tileW = srcGeoms[0].width, tileH = srcGeoms[0].height, tileD = srcGeoms[0].depth
        let tileWH = tileW * tileH
        let voxelCount = try jp3dCheckedMul(tileWH, tileD, label: "3D transcode tile volume")
        let planeWorkspaceBytes = try jp3dCheckedMul(voxelCount, MemoryLayout<Int64>.stride, label: "3D transcode wavelet workspace")

        var (contributions, _, _) = try JP3DTier2Coder.decodePackets(
            geometries: srcGeoms,
            cod: sourceCOD,
            componentCODs: srcCODs,
            data: tileData,
            recordPacketRanges: false,
            admitWorkspaceBytes: admitWorkspaceBytes,
            cancellation: cancellation
        )
        let useMCT = sourceCOD.multipleComponentTransform == 1 && compCount >= 3
        var usedSIMD = false

        var targetEncodings: [[[[[JP3DTier2Coder.BlockEncodingEntry]]]]] = []
        targetEncodings.reserveCapacity(compCount)
        var totalRetainedCompressedBytes = 0
        var activeBodyOverlapBytes = 0
        var succeeded = false
        defer {
            if !succeeded {
                if activeBodyOverlapBytes > 0 {
                    entropyBudget?.release(activeBodyOverlapBytes, countsTowardCompressedOutput: false)
                }
                if totalRetainedCompressedBytes > 0 {
                    entropyBudget?.release(totalRetainedCompressedBytes, countsTowardCompressedOutput: true)
                }
            }
        }

        for c in 0..<compCount {
            let srcGeom = srcGeoms[c]
            let dstGeom = dstGeoms[c]
            let srcCompCOD = srcCODs[c]
            let dstCompCOD = dstCODs[c]
            let compQCD = qcds[c]
            let srcEbcotStyle = CodeBlockStyle(bits: srcCompCOD.codeBlockStyle & ~0xC0)
            let dstIsHT = (dstCompCOD.codeBlockStyle & 0x40) != 0
            let dstIsMixedHT = (dstCompCOD.codeBlockStyle & 0xC0) == 0xC0
            let dstEbcotStyle = CodeBlockStyle(bits: dstCompCOD.codeBlockStyle & ~0xC0)

            var wBuf = [Int64](repeating: 0, count: voxelCount)
            let compDepth = siz.bitDepth(forComponent: c)
            let roiShift = c < roiShifts.count ? roiShifts[c] : 0

            for (r, res) in srcGeom.resolutions.enumerated() {
                for (p, prc) in res.precincts.enumerated() {
                    for (b, pb) in prc.bands.enumerated() {
                        let band = res.bands[pb.bandIndex]
                        let mb = compQCD.magnitudeBitPlanes(
                            for: band,
                            resolution: r,
                            maxLevels: srcGeom.maxLevels,
                            componentBitDepth: compDepth,
                            usesReversibleMCT: srcCompCOD.isLossless && compQCD.isReversible && useMCT && c < 3,
                            roiShift: roiShift
                        )
                        for (k, blk) in pb.blocks.enumerated() {
                            try cancellation()
                            let contrib = contributions[c][r][p][b][k]
                            guard contrib.included, contrib.passes > 0, blk.voxelCount > 0 else { continue }
                            let decodedBlock: [Int64]
                            if contrib.isHT {
                                let segInputs = contrib.segments.map {
                                    HTSegmentInput(data: $0.data, passes: $0.passes)
                                }
                                decodedBlock = try HTBlockDecoder.decodeHTCodeBlock(
                                    segments: segInputs,
                                    zeroBitPlanes: contrib.zeroBitPlanes,
                                    totalPasses: contrib.passes,
                                    width: blk.width,
                                    height: blk.height,
                                    kMax: mb,
                                    causal: (srcCompCOD.codeBlockStyle & 0x08) != 0,
                                    allowMultiHT: allowSourceMultiHT,
                                    midpointReconstruction: false
                                )
                            } else {
                                decodedBlock = try JP3DBitPlaneCoder.decode3D(
                                    segments: contrib.segments,
                                    width: blk.width,
                                    height: blk.height,
                                    depth: blk.depth,
                                    orientation: band.orientation,
                                    zeroBitPlanes: contrib.zeroBitPlanes,
                                    passCount: contrib.passes,
                                    magnitudeBitPlanes: mb,
                                    style: srcEbcotStyle
                                )
                            }
                            var srcIdx = 0
                            for cz in 0..<blk.depth {
                                let zOff = (band.bufZ + (blk.z0 - band.z0) + cz) * tileWH
                                for cy in 0..<blk.height {
                                    let yOff = zOff + (band.bufY + (blk.y0 - band.y0) + cy) * tileW + band.bufX + (blk.x0 - band.x0)
                                    for cx in 0..<blk.width {
                                        wBuf[yOff + cx] = decodedBlock[srcIdx]
                                        srcIdx += 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
            contributions[c] = []

            let (reencodedComp, compBytes, blkSIMD) = try encodeWaveletSubbands(
                waveletBuffer: wBuf,
                tileW: tileW, tileWH: tileWH,
                geometry: dstGeom,
                cod: targetCOD,
                componentCOD: dstCompCOD,
                qcd: compQCD,
                componentBitDepth: compDepth,
                usesReversibleMCT: dstCompCOD.isLossless && compQCD.isReversible && useMCT && c < 3,
                isHT: dstIsHT,
                isMixedHT: dstIsMixedHT,
                htConfiguration: htConfiguration,
                ebcotStyle: dstEbcotStyle,
                maxPassesLimit: nil,
                useAccelerated: useAccelerated,
                entropyBudget: entropyBudget,
                remainingOutputLimit: remainingOutputLimit,
                admitEncodedBytes: admitEncodedBytes,
                cancellation: cancellation
            )
            totalRetainedCompressedBytes += compBytes
            if blkSIMD { usedSIMD = true }
            targetEncodings.append(reencodedComp)
        }

        let tier1RetainedBytes = totalRetainedCompressedBytes
        let (outTile, bodyOverlap) = try JP3DTier2Coder.encodePacketsWithOverlap(
            geometries: dstGeoms,
            cod: targetCOD,
            componentCODs: dstCODs,
            encodings: targetEncodings,
            budget: entropyBudget,
            admitEncodedBytes: admitEncodedBytes,
            cancellation: cancellation
        )
        let headerBytes = max(0, outTile.count - bodyOverlap)
        if entropyBudget != nil {
            totalRetainedCompressedBytes += headerBytes
            activeBodyOverlapBytes = bodyOverlap
        }
        targetEncodings.removeAll(keepingCapacity: false)
        if let entropyBudget {
            if activeBodyOverlapBytes > 0 {
                entropyBudget.release(activeBodyOverlapBytes, countsTowardCompressedOutput: false)
                activeBodyOverlapBytes = 0
            }
            if tier1RetainedBytes > bodyOverlap {
                let excess = tier1RetainedBytes - bodyOverlap
                entropyBudget.release(excess, countsTowardCompressedOutput: true)
                totalRetainedCompressedBytes -= excess
            }
        }
        let peakWS = try jp3dCheckedAdd(planeWorkspaceBytes, outTile.count, label: "3D transcode tile peak")
        succeeded = true
        return (outTile, peakWS, usedSIMD)
    }
}
