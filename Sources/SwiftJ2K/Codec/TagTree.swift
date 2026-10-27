// SPDX-License-Identifier: Apache-2.0
//
// Tag tree coder for packet headers (ISO/IEC 15444-1 B.10.2).
//
// Provenance: adapted from Raster-Lab/J2KSwift at commit
// 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca, Sources/J2KCodec/J2KTagTree.swift
// (MIT; relicensed Apache-2.0 under POL-07). The quad-tree layout, the
// root-to-leaf "low"/"known" traversal and the threshold semantics are kept.
// Changes: the reader/writer types are the successor's packet bit coders,
// silently ignored out-of-range leaves now throw, and the decoder bounds its
// per-node loop so malformed input cannot spin.

struct TagTree: Sendable {
    private struct Node: Sendable {
        var value: Int32 = Int32.max
        var low: Int32 = 0
        var known = false
        var parent = -1
    }

    static var nodeStride: Int { MemoryLayout<Node>.stride }

    static func nodeCount(width: Int, height: Int) throws -> Int {
        guard width > 0, height > 0 else { return 0 }
        var total = 0
        var w = width, h = height
        while true {
            let levelNodes = try checkedMultiply(w, h)
            total = try checkedAdd(total, levelNodes)
            if levelNodes <= 1 { break }
            w = (w + 1) / 2
            h = (h + 1) / 2
        }
        return total
    }

    private var nodes: [Node]
    private let leafCount: Int
    private var path: [Int] = []

    init(width: Int, height: Int) {
        leafCount = width * height
        guard width > 0, height > 0 else {
            nodes = []
            return
        }
        var widths: [Int] = [], heights: [Int] = []
        var w = width, h = height
        repeat {
            widths.append(w); heights.append(h)
            w = (w + 1) / 2; h = (h + 1) / 2
        } while widths[widths.count - 1] * heights[heights.count - 1] > 1
        var offsets = [0]
        for level in 0..<widths.count { offsets.append(offsets[level] + widths[level] * heights[level]) }
        nodes = [Node](repeating: Node(), count: offsets[offsets.count - 1])
        for level in 0..<(widths.count - 1) {
            let childOffset = offsets[level], parentOffset = offsets[level + 1]
            let cw = widths[level], ch = heights[level], pw = widths[level + 1]
            for cy in 0..<ch {
                for cx in 0..<cw {
                    nodes[childOffset + cy * cw + cx].parent = parentOffset + (cy / 2) * pw + cx / 2
                }
            }
        }
    }

    /// Sets a leaf value and propagates the minimum towards the root.
    mutating func setValue(leaf: Int, value: Int32) throws {
        guard leaf >= 0, leaf < leafCount else {
            throw CodecError(.internalFailure, "Tag tree leaf index is outside the precinct.")
        }
        var index = leaf
        while index >= 0, nodes[index].value > value {
            nodes[index].value = value
            index = nodes[index].parent
        }
    }

    private mutating func buildPath(to leaf: Int) throws {
        guard leaf >= 0, leaf < leafCount, !nodes.isEmpty else {
            throw CodecError(.internalFailure, "Tag tree leaf index is outside the precinct.")
        }
        path.removeAll(keepingCapacity: true)
        var index = leaf
        while index >= 0 {
            path.append(index)
            index = nodes[index].parent
        }
        path.reverse()
    }

    /// Emits the bits that tell a decoder whether `leaf` is below `threshold`.
    mutating func encode(writer: inout PacketBitWriter, leaf: Int, threshold: Int32) throws {
        try buildPath(to: leaf)
        var low: Int32 = 0
        for index in path {
            if low > nodes[index].low { nodes[index].low = low } else { low = nodes[index].low }
            while low < threshold {
                if low >= nodes[index].value {
                    if !nodes[index].known {
                        writer.writeBit(true)
                        nodes[index].known = true
                    }
                    break
                }
                writer.writeBit(false)
                low += 1
            }
            nodes[index].low = low
        }
    }

    /// Returns `true` when the leaf value is known to be below `threshold`.
    mutating func decode(reader: inout PacketBitReader, leaf: Int, threshold: Int32) throws -> Bool {
        try buildPath(to: leaf)
        var low: Int32 = 0
        for index in path {
            if low > nodes[index].low { nodes[index].low = low } else { low = nodes[index].low }
            while low < threshold && low < nodes[index].value {
                if try reader.readBit() {
                    nodes[index].value = low
                } else {
                    low += 1
                }
            }
            nodes[index].low = low
        }
        return nodes[path[path.count - 1]].value < threshold
    }

    /// The decoded value of a leaf, once `decode` has returned `true` for it.
    func value(leaf: Int) -> Int32 { nodes[leaf].value }
}
