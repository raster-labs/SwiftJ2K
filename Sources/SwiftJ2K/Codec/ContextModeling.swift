// SPDX-License-Identifier: Apache-2.0
//
// EBCOT context formation (ISO/IEC 15444-1 Annex D, Tables D.1–D.4).
//
// Provenance: adapted from Raster-Lab/J2KSwift at commit
// 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca,
// Sources/J2KCodec/J2KContextModeling.swift (MIT; relicensed Apache-2.0 under
// POL-07). Retained: the 19-label numbering, the three 45-entry significance
// look-up tables, the packed sign-context table with its XOR bit, the
// magnitude-refinement label rule and the initial context states (label 0 →
// state 4, run-length → 3, uniform → 46). Removed: the unaligned 32-bit
// neighbour loads over raw pointers and the inline 19-field tuple; the
// successor pads the state plane by one coefficient on every side so that
// neighbour reads need no bounds arithmetic and stay ordinary array indexing.

/// Wavelet subband orientation, which selects the significance table.
package enum BandOrientation: Sendable, Equatable {
    case ll, hl, lh, hh
}

/// Per-coefficient state flags kept in a padded `[UInt8]` plane.
package enum CoefficientFlag {
    package static let significant: UInt8 = 1 << 0
    package static let visited: UInt8 = 1 << 1      // coded in the current bit-plane
    package static let negative: UInt8 = 1 << 2     // sign of a significant coefficient
    package static let refined: UInt8 = 1 << 3      // has had a magnitude-refinement bit
}

/// Context labels. Only the grouping matters to the bitstream; the numbers
/// select adaptive states inside `ContextSet`.
package enum ContextLabel {
    package static let significanceBase: UInt8 = 0    // 0...8
    package static let signBase: UInt8 = 9            // 9...13
    package static let refinementFirstNoNeighbours: UInt8 = 14
    package static let refinementFirstWithNeighbours: UInt8 = 15
    package static let refinementSubsequent: UInt8 = 16
    package static let runLength: UInt8 = 17
    package static let uniform: UInt8 = 18
    package static let count = 19
}

/// The 19 adaptive MQ contexts of one code-block, with Table D.7 initial states.
package struct ContextSet: Sendable {
    package var contexts: [MQContext]

    @inline(__always)
    package init() {
        contexts = [MQContext](repeating: MQContext(), count: ContextLabel.count)
        contexts[0] = MQContext(stateIndex: 4)
        contexts[Int(ContextLabel.runLength)] = MQContext(stateIndex: 3)
        contexts[Int(ContextLabel.uniform)] = MQContext(stateIndex: 46)
    }
}

/// Significance and sign context tables for one subband orientation.
package struct ContextTables: Sendable {
    /// Indexed by `h * 15 + v * 5 + d` with h, v ∈ 0...2 and d ∈ 0...4.
    package let significance: [UInt8]

    private static let llAndLH = ContextTables(make: .lh)
    private static let hl = ContextTables(make: .hl)
    private static let hh = ContextTables(make: .hh)

    @inline(__always)
    package init(orientation: BandOrientation) {
        switch orientation {
        case .ll, .lh: self = Self.llAndLH
        case .hl: self = Self.hl
        case .hh: self = Self.hh
        }
    }

    private init(make orientation: BandOrientation) {
        var table = [UInt8](repeating: 0, count: 45)
        for h in 0...2 {
            for v in 0...2 {
                for d in 0...4 {
                    let label: UInt8
                    switch orientation {
                    case .ll, .lh:
                        label = Self.horizontallyDominant(h: h, v: v, d: d)
                    case .hl:
                        // Table D.1 swaps the roles of the horizontal and vertical
                        // neighbours for the horizontally high-pass band.
                        label = Self.horizontallyDominant(h: v, v: h, d: d)
                    case .hh:
                        label = Self.diagonallyDominant(hv: h + v, d: d)
                    }
                    table[h * 15 + v * 5 + d] = label
                }
            }
        }
        significance = table
    }

    private static func horizontallyDominant(h: Int, v: Int, d: Int) -> UInt8 {
        if h == 2 { return 8 }
        if h == 1 {
            if v >= 1 { return 7 }
            return d >= 1 ? 6 : 5
        }
        if v == 2 { return 4 }
        if v == 1 { return 3 }
        if d >= 2 { return 2 }
        return d == 1 ? 1 : 0
    }

    private static func diagonallyDominant(hv: Int, d: Int) -> UInt8 {
        if d >= 3 { return 8 }
        if d == 2 { return hv >= 1 ? 7 : 6 }
        if d == 1 {
            if hv >= 2 { return 5 }
            return hv == 1 ? 4 : 3
        }
        if hv >= 2 { return 2 }
        return hv == 1 ? 1 : 0
    }

    /// Table D.3 packed as `(label << 1) | xorBit`, indexed by
    /// `(hContribution + 1) * 3 + (vContribution + 1)`.
    static let sign: [UInt8] = {
        var table = [UInt8](repeating: 0, count: 9)
        for hIndex in 0..<3 {
            for vIndex in 0..<3 {
                var h = hIndex - 1, v = vIndex - 1
                let xorBit = h < 0 || (h == 0 && v < 0)
                if h < 0 { h = -h; v = -v }
                if h == 0 && v < 0 { v = -v }
                let label: UInt8
                if h == 0 {
                    label = v == 0 ? 9 : 10
                } else {
                    label = v > 0 ? 13 : (v < 0 ? 11 : 12)
                }
                table[hIndex * 3 + vIndex] = label << 1 | (xorBit ? 1 : 0)
            }
        }
        return table
    }()
}

/// Neighbourhood queries over the padded state plane. The plane has width
/// `stride = width + 2` and one zero row above and below, so index arithmetic
/// for the eight neighbours never leaves the array.
package struct StatePlane: Sendable {
    package let width: Int
    package let height: Int
    package let stride: Int
    package var flags: [UInt8]

    package init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.stride = width + 2
        self.flags = [UInt8](repeating: 0, count: (width + 2) * (height + 2))
    }

    /// Index of coefficient (x, y) inside the padded plane.
    @inline(__always)
    package func index(x: Int, y: Int) -> Int { (y + 1) * stride + x + 1 }

    /// Significance-table key for the coefficient at padded index `i`.
    /// `ignoreBelow` implements vertically causal context formation (D.7):
    /// the row below is treated as insignificant.
    @inline(__always)
    package func significanceKey(at i: Int, ignoreBelow: Bool) -> Int {
        let s = CoefficientFlag.significant
        let h = Int(flags[i - 1] & s) + Int(flags[i + 1] & s)
        var v = Int(flags[i - stride] & s)
        var d = Int(flags[i - stride - 1] & s) + Int(flags[i - stride + 1] & s)
        if !ignoreBelow {
            v += Int(flags[i + stride] & s)
            d += Int(flags[i + stride - 1] & s) + Int(flags[i + stride + 1] & s)
        }
        return h * 15 + v * 5 + d
    }

    /// Packed sign-context entry for the coefficient at padded index `i`.
    @inline(__always)
    package func signEntry(at i: Int, ignoreBelow: Bool) -> UInt8 {
        @inline(__always) func contribution(_ f: UInt8) -> Int {
            guard f & CoefficientFlag.significant != 0 else { return 0 }
            return f & CoefficientFlag.negative != 0 ? -1 : 1
        }
        var h = contribution(flags[i - 1]) + contribution(flags[i + 1])
        var v = contribution(flags[i - stride]) + (ignoreBelow ? 0 : contribution(flags[i + stride]))
        h = max(-1, min(1, h)); v = max(-1, min(1, v))
        return ContextTables.sign[(h + 1) * 3 + (v + 1)]
    }

    /// Whether any considered neighbour of padded index `i` is significant.
    @inline(__always)
    package func hasSignificantNeighbour(at i: Int, ignoreBelow: Bool) -> Bool {
        let s = CoefficientFlag.significant
        var union = flags[i - 1] | flags[i + 1] | flags[i - stride] | flags[i - stride - 1] | flags[i - stride + 1]
        if !ignoreBelow { union |= flags[i + stride] | flags[i + stride - 1] | flags[i + stride + 1] }
        return union & s != 0
    }

    /// Clears the per-bit-plane visited flag on every coefficient.
    @inline(__always)
    package mutating func clearVisited() {
        let mask = ~CoefficientFlag.visited
        for i in flags.indices { flags[i] &= mask }
    }
}
