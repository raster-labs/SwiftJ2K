// SPDX-License-Identifier: Apache-2.0
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
    // 1D synthesis filter L2 norms for the 9/7 irreversible filter (ISO/IEC 15444-1 Table E.1 / OpenJPEG).
    private static let low97Norms: [Double] = [
        1.000000, 1.442108, 2.043878, 2.889184, 4.084699,
        5.775812, 8.168186, 11.55147, 16.33632, 23.10293, 32.67264
    ]
    private static let high97Norms: [Double] = [
        1.000000, 0.989014, 1.380672, 1.946500, 2.751011,
        3.890112, 5.501351, 7.780085, 11.00269, 15.56017, 22.00538
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

    /// 2D synthesis L2 norm weight for a subband at decomposition level `nb` (`1...levels`).
    static func synthesisWeight(orientation: BandOrientation, decompositionLevel nb: Int, reversible: Bool) -> Double {
        let clamped = max(1, min(nb, 10))
        let lows = reversible ? low53Norms : low97Norms
        let highs = reversible ? high53Norms : high97Norms
        switch orientation {
        case .ll: return lows[clamped] * lows[clamped]
        case .hl, .lh: return lows[clamped - 1] * highs[clamped]
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
                // Smooth exponential mapping: Q=0.9 -> ~1.0, Q=0.75 -> ~2.2, Q=0.5 -> ~6.0, Q=0.25 -> ~18.0, Q=0.0 -> ~64.0
                qScale = pow(64.0, 1.0 - clamped) * 0.5
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
        var hulls: [[HullPoint]] = []
        hulls.reserveCapacity(blockCount)

        for b in 0..<blockCount {
            let bytes = blockPassBytes[b]
            let reductions = blockPassDistortionReductions[b]
            var hull: [HullPoint] = [HullPoint(passes: 0, bytes: 0, reduction: 0.0, slope: .infinity)]
            for p in 0..<bytes.count {
                let passCount = p + 1
                let r = bytes[p]
                let d = reductions[p]
                while hull.count >= 1 {
                    let last = hull[hull.count - 1]
                    let deltaR = r - last.bytes
                    let deltaD = d - last.reduction
                    if deltaD <= 0 && deltaR > 0 { break }
                    let slope = deltaR > 0 ? (deltaD / Double(deltaR)) : (deltaD > 0 ? 1e18 : 0.0)
                    if hull.count > 1 && slope >= hull[hull.count - 1].slope {
                        hull.removeLast()
                    } else {
                        hull.append(HullPoint(passes: passCount, bytes: r, reduction: d, slope: slope))
                        break
                    }
                }
            }
            hulls.append(hull)
        }

        var result = [[Int]](repeating: [Int](repeating: 0, count: layerCount), count: blockCount)
        var minPasses = [Int](repeating: 0, count: blockCount)

        for (layerIdx, budget) in layerByteBudgets.enumerated() {
            // Check if including all passes of all blocks fits within budget:
            var maxBytes = 0
            for b in 0..<blockCount {
                maxBytes += blockPassBytes[b].last ?? 0
            }
            if budget >= maxBytes {
                for b in 0..<blockCount {
                    let all = blockPassBytes[b].count
                    result[b][layerIdx] = all
                    minPasses[b] = all
                }
                continue
            }

            // Bisection over Lagrange threshold lambda >= 0:
            var lowLambda = 0.0
            var highLambda = 1e12
            for _ in 0..<48 {
                let mid = 0.5 * (lowLambda + highLambda)
                var totalBytes = 0
                for b in 0..<blockCount {
                    let hull = hulls[b]
                    var chosen = hull[0]
                    for pt in hull where pt.passes >= minPasses[b] {
                        if pt.passes == minPasses[b] || pt.slope >= mid {
                            chosen = pt
                        }
                    }
                    totalBytes += chosen.bytes
                }
                if totalBytes > budget {
                    lowLambda = mid
                } else {
                    highLambda = mid
                }
            }

            var currentBytes = 0
            var selectedIdx = [Int](repeating: 0, count: blockCount)
            for b in 0..<blockCount {
                let hull = hulls[b]
                var chosenIdx = 0
                for (idx, pt) in hull.enumerated() where pt.passes >= minPasses[b] {
                    if pt.passes == minPasses[b] || pt.slope >= highLambda {
                        chosenIdx = idx
                    }
                }
                selectedIdx[b] = chosenIdx
                currentBytes += hull[chosenIdx].bytes
            }

            // Greedily fill any remaining byte slack with highest-slope next hull steps:
            while currentBytes < budget {
                var bestBlock = -1
                var bestSlope = -1.0
                for b in 0..<blockCount {
                    let nextIdx = selectedIdx[b] + 1
                    if nextIdx < hulls[b].count {
                        let nextPt = hulls[b][nextIdx]
                        let curPt = hulls[b][selectedIdx[b]]
                        if currentBytes + (nextPt.bytes - curPt.bytes) <= budget && nextPt.slope > bestSlope {
                            bestSlope = nextPt.slope
                            bestBlock = b
                        }
                    }
                }
                if bestBlock >= 0 {
                    let curPt = hulls[bestBlock][selectedIdx[bestBlock]]
                    selectedIdx[bestBlock] += 1
                    let nextPt = hulls[bestBlock][selectedIdx[bestBlock]]
                    currentBytes += (nextPt.bytes - curPt.bytes)
                } else {
                    break
                }
            }

            // Ensure at least the LL block has 1 pass if budget > 0 and nothing was selected yet:
            if layerIdx == layerCount - 1 && budget > 0 && currentBytes == 0 && !blockPassBytes[0].isEmpty {
                result[0][layerIdx] = max(minPasses[0], 1)
                minPasses[0] = result[0][layerIdx]
            } else {
                for b in 0..<blockCount {
                    let passes = max(minPasses[b], hulls[b][selectedIdx[b]].passes)
                    result[b][layerIdx] = passes
                    minPasses[b] = passes
                }
            }
        }

        return result
    }
}
