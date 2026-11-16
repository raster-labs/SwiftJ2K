// SPDX-License-Identifier: MIT
//
// Scalar quantisation, dequantisation, L2 synthesis norms, and PCRD-opt
// rate-distortion layer formation (ISO/IEC 15444-1 Annex E and Annex J).

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum Quantization {
    // 1D synthesis filter L2 norms for the K-scaled 9/7 irreversible filter in `Wavelet97`
    // (ISO/IEC 15444-1 Annex F.3.8.2 / F.4.8.2 with K = 1.230174104914001).
    private static let low97Norms: [Double] = [
        1.00000000, 1.40210817, 2.03037186, 2.90116256, 4.11528518,
        5.82451086, 8.23875993, 11.65195465, 16.47856065, 23.30427764, 32.95725156
    ]
    private static let high97Norms: [Double] = [
        1.00000000, 0.72126138, 0.98347130, 1.44196240, 2.07376042,
        2.94732488, 4.17358946, 5.90430233, 8.35063902, 11.80983285, 16.70171276
    ]

    // 1D synthesis filter L2 norms for the 5/3 reversible filter.
    private static let low53Norms: [Double] = [
        1.000000, 1.224745, 1.658312, 2.318405, 3.269174,
        4.619929, 6.532012, 9.237186, 13.06325, 18.47418, 26.12642
    ]
    private static let high53Norms: [Double] = [
        1.000000, 0.847791, 0.960143, 1.329215, 1.872665,
        2.646166, 3.741668, 5.291290, 7.482924, 10.58250, 14.96581
    ]

    /// Inverse ICT synthesis column L2 norms (`sqrt(1 + 1 + 1)`, `sqrt(1.772^2 + 0.344136^2)`, `sqrt(1.402^2 + 0.714136^2)`).
    static let ictColumnNorms: [Double] = [
        1.7320508075688772,
        1.8051076381468226,
        1.5734021184986373
    ]

    /// Inverse RCT synthesis column L2 norms (`sqrt(3)`, `sqrt(11/16)`, `sqrt(11/16)`).
    static let rctColumnNorms: [Double] = [
        1.7320508075688772,
        0.82915619758885,
        0.82915619758885
    ]

    /// 2D synthesis L2 norm weight for a subband at decomposition level `nb` (`1...levels`).
    static func synthesisWeight(orientation: BandOrientation, decompositionLevel nb: Int, reversible: Bool) -> Double {
        let clamped = max(1, min(nb, 10))
        let lows = reversible ? low53Norms : low97Norms
        let highs = reversible ? high53Norms : high97Norms
        switch orientation {
        case .ll: return lows[clamped] * lows[clamped]
        case .hl, .lh: return lows[clamped] * highs[clamped]
        case .hh: return highs[clamped] * highs[clamped]
        }
    }

    /// Computes the reconstruction step size `Delta_b` from the `QCD`/`QCC`
    /// `(exponent, mantissa)` pair and nominal subband dynamic range `Rb = precision + gain`
    /// per ISO/IEC 15444-1 Eq. E-3: `Delta_b = 2^(Rb - eps_b) * (1 + mu_b / 2048)`.
    @inline(__always)
    static func stepSize(exponent: Int, mantissa: Int, precision: Int, gain: Int) -> Double {
        let rb = precision + gain
        let scale = pow(2.0, Double(rb - exponent))
        return scale * (1.0 + Double(mantissa) / 2048.0)
    }

    /// Encodes a positive step size `Delta_b` and nominal dynamic range `Rb = precision + gain`
    /// into a `(exponent, mantissa)` pair per ISO/IEC 15444-1 Eq. E-3.
    static func encodeStepSize(_ delta: Double, precision: Int, gain: Int) -> (exponent: Int, mantissa: Int) {
        let rb = precision + gain
        let safeDelta = max(delta, 1e-9)
        let logVal = floor(log2(safeDelta))
        let eps = max(0, min(31, rb - Int(logVal)))
        let normalized = safeDelta / pow(2.0, Double(rb - eps))
        let mu = max(0, min(2047, Int(((normalized - 1.0) * 2048.0).rounded())))
        return (eps, mu)
    }

    /// Builds a `QuantizationSegment` for 9/7 irreversible encoding.
    /// When `quality` (`0.0...1.0`) or `baseStepSize` is provided, scales the default
    /// L2-norm-weighted step sizes (`1 / synthesisWeight`) accordingly.
    static func makeIrreversibleQuantization(
        levels: Int,
        precision: Int,
        guardBits: Int,
        derived: Bool,
        quality: Double?,
        baseStepSize: Double?
    ) -> QuantizationSegment {
        // Quality scale factor:
        // At quality = 1.0 (or default OpenJPEG/Kakadu baseline when rate control truncates passes),
        // scale = 1.0 (Delta_b = 1 / synthesisWeight).
        // For lower quality Q in 0.0..<1.0, scale increases smoothly to coarse step sizes.
        let qScale: Double
        if let baseStepSize, baseStepSize > 0 {
            // Explicit base step size in sample units (1.0 corresponds to 1 / synthesisWeight)
            qScale = baseStepSize
        } else if let q = quality {
            let clamped = max(0.0, min(1.0, q))
            if clamped >= 0.999 {
                qScale = 0.5
            } else {
                // Bit-depth-proportional perceptual step scaling (ISO/IEC 15444-1 Annex E.1):
                // at 8-bit: Q=0.90 -> ~2.60, Q=0.75 -> ~8.39, Q=0.50 -> ~20.38, Q=0.0 -> ~49.5;
                // scales proportionally with sample dynamic range `2^(precision - 8)` for 9..16-bit medical scans.
                let rangeScale = Double(1 << max(0, min(20, precision - 8)))
                let base8 = 49.5 * pow(1.0 - clamped, 1.28)
                qScale = max(0.5, base8 * rangeScale)
            }
        } else {
            // Default lossy baseline when no quality/bitrate is specified: high quality (qScale = 1.0)
            qScale = 1.0
        }

        if derived {
            let llWeight = synthesisWeight(orientation: .ll, decompositionLevel: max(1, levels), reversible: false)
            let delta0 = qScale / llWeight
            let (eps0, mu0) = encodeStepSize(delta0, precision: precision, gain: 0)
            return QuantizationSegment(style: .scalarDerived, guardBits: guardBits,
                                       exponents: [eps0], mantissas: [mu0])
        }

        var exponents: [Int] = []
        var mantissas: [Int] = []
        exponents.reserveCapacity(1 + 3 * levels)
        mantissas.reserveCapacity(1 + 3 * levels)

        // Band 0: LL at level `levels`
        let llWeight = levels == 0 ? 1.0 : synthesisWeight(orientation: .ll, decompositionLevel: levels, reversible: false)
        let (eps0, mu0) = encodeStepSize(qScale / llWeight, precision: precision, gain: 0)
        exponents.append(eps0)
        mantissas.append(mu0)

        // Resolutions 1...levels (decomposition levels `nb = levels - r + 1` down to 1)
        if levels >= 1 {
            for r in 1...levels {
                let nb = levels - r + 1
                for (orientation, gain) in [(BandOrientation.hl, 1), (.lh, 1), (.hh, 2)] {
                    let w = synthesisWeight(orientation: orientation, decompositionLevel: nb, reversible: false)
                    let (eps, mu) = encodeStepSize(qScale / w, precision: precision, gain: gain)
                    exponents.append(eps)
                    mantissas.append(mu)
                }
            }
        }

        return QuantizationSegment(style: .scalarExpounded, guardBits: guardBits,
                                   exponents: exponents, mantissas: mantissas)
    }

    // MARK: - PCRD-opt Rate-Distortion Pass Selection

    /// Given all code-blocks in a tile with their per-pass cumulative byte lengths `passBytes`
    /// and cumulative distortion reductions `passDistortionReductions`, computes for each target
    /// byte budget `layerByteBudgets[l]` the monotonically increasing cumulative pass count
    /// `layerCumulativePasses[blockIndex][l]` using Lagrange multiplier bisection (PCRD-opt).
    static func allocatePassesPCRD(
        blockPassBytes: [[Int]],
        blockPassDistortionReductions: [[Double]],
        layerByteBudgets: [Int]
    ) -> [[Int]] {
        let blockCount = blockPassBytes.count
        let layerCount = layerByteBudgets.count
        guard blockCount > 0, layerCount > 0 else { return [] }

        // Build the convex hull of R-D points for each code-block:
        // Point 0 is (passes: 0, bytes: 0, distReduction: 0, slope: +inf).
        struct HullPoint {
            let passes: Int
            let bytes: Int
            let reduction: Double
            let slope: Double
        }
        struct HullStep {
            let slope: Double
            let block: Int32
            let hullIdx: Int32
            let deltaBytes: Int
        }

        var hulls: [[HullPoint]] = []
        hulls.reserveCapacity(blockCount)
        var steps: [HullStep] = []
        steps.reserveCapacity(blockCount * 4)
        var maxBytes = 0

        for b in 0..<blockCount {
            let bytes = blockPassBytes[b]
            let reductions = blockPassDistortionReductions[b]
            maxBytes += bytes.last ?? 0
            var hull: [HullPoint] = []
            hull.reserveCapacity(bytes.count + 1)
            hull.append(HullPoint(passes: 0, bytes: 0, reduction: 0.0, slope: .infinity))
            for p in 0..<bytes.count {
                let passCount = p + 1
                let r = bytes[p]
                let d = reductions[p]
                while hull.count >= 1 {
                    let last = hull[hull.count - 1]
                    let deltaR = r - last.bytes
                    let deltaD = d - last.reduction
                    if deltaD <= 0 { break }
                    let slope = deltaR > 0 ? (deltaD / Double(deltaR)) : 1e300
                    if hull.count > 1 && slope >= hull[hull.count - 1].slope {
                        hull.removeLast()
                    } else {
                        hull.append(HullPoint(passes: passCount, bytes: r, reduction: d, slope: slope))
                        break
                    }
                }
            }
            if hull.count > 1 {
                for idx in 1..<hull.count {
                    let dBytes = max(0, hull[idx].bytes - hull[idx - 1].bytes)
                    steps.append(HullStep(
                        slope: hull[idx].slope,
                        block: Int32(b),
                        hullIdx: Int32(idx),
                        deltaBytes: dBytes
                    ))
                }
            }
            hulls.append(hull)
        }

        steps.sort { lhs, rhs in
            if lhs.slope != rhs.slope { return lhs.slope > rhs.slope }
            if lhs.block != rhs.block { return lhs.block < rhs.block }
            return lhs.hullIdx < rhs.hullIdx
        }

        var result = [[Int]](repeating: [Int](repeating: 0, count: layerCount), count: blockCount)
        var minHullIdx = [Int32](repeating: 0, count: blockCount)
        var minBytes = 0

        for (layerIdx, budget) in layerByteBudgets.enumerated() {
            if budget >= maxBytes {
                for b in 0..<blockCount {
                    let all = blockPassBytes[b].count
                    result[b][layerIdx] = all
                    minHullIdx[b] = Int32(hulls[b].count - 1)
                }
                minBytes = maxBytes
                continue
            }

            var selectedHullIdx = minHullIdx
            var currentBytes = minBytes

            steps.withUnsafeBufferPointer { stepBuf in
                selectedHullIdx.withUnsafeMutableBufferPointer { selBuf in
                    guard let sBase = stepBuf.baseAddress, let selBase = selBuf.baseAddress else { return }
                    let stepCount = stepBuf.count
                    for i in 0..<stepCount {
                        let st = sBase[i]
                        let b = Int(st.block)
                        if st.hullIdx == selBase[b] &+ 1 {
                            let nextBytes = currentBytes + st.deltaBytes
                            if nextBytes <= budget {
                                selBase[b] = st.hullIdx
                                currentBytes = nextBytes
                            }
                        }
                    }
                }
            }

            // Ensure at least the LL block has 1 pass if budget > 0 and nothing was selected yet:
            if layerIdx == layerCount - 1 && budget > 0 && currentBytes == 0 && !blockPassBytes[0].isEmpty {
                let prevPasses = hulls[0][Int(minHullIdx[0])].passes
                result[0][layerIdx] = max(prevPasses, 1)
            } else {
                for b in 0..<blockCount {
                    let hIdx = max(minHullIdx[b], selectedHullIdx[b])
                    minHullIdx[b] = hIdx
                    result[b][layerIdx] = hulls[b][Int(hIdx)].passes
                }
                minBytes = currentBytes
            }
        }

        return result
    }
}
