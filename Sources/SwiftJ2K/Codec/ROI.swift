// SPDX-License-Identifier: Apache-2.0
//
// Region of Interest (ROI) MaxShift coding (ISO/IEC 15444-1 Annex H.1,
// RGN marker segment 0xFF5E with Srgn = 0).

enum ROICoding {
    /// Computes a spec-compliant MaxShift value `s >= max_b(M_b)` per ISO/IEC 15444-1 Annex H.1
    /// so that every non-zero foreground coefficient is shifted above the largest possible
    /// background coefficient magnitude.
    static func computeMaxShift(quantization: QuantizationSegment, requestedShift: Int?) -> Int {
        let maxExponent = quantization.exponents.max() ?? 8
        let maxNominalPlanes = max(1, quantization.guardBits + maxExponent - 1)
        if let requestedShift {
            return max(requestedShift, maxNominalPlanes)
        }
        return maxNominalPlanes
    }

    /// Maps an image-space rectangular ROI `(roiX0..<roiX1, roiY0..<roiY1)` into the
    /// subband coordinate space `band.x0..<band.x1, band.y0..<band.y1` at decomposition
    /// level `nb` (`1...levels`, or `levels` for LL), returning the subband-space bounding box
    /// `(bx0..<bx1, by0..<by1)` of wavelet coefficients that contribute to reconstructing the ROI.
    static func subbandROIBounds(
        roiX0: Int, roiX1: Int, roiY0: Int, roiY1: Int,
        band: BandGeometry, decompositionLevel nb: Int, reversible: Bool
    ) -> (x0: Int, x1: Int, y0: Int, y1: Int) {
        guard nb > 0 else {
            return (max(band.x0, roiX0), min(band.x1, roiX1),
                    max(band.y0, roiY0), min(band.y1, roiY1))
        }
        let denom = 1 << nb
        let highX = band.orientation == .hl || band.orientation == .hh
        let highY = band.orientation == .lh || band.orientation == .hh
        let offsetX = highX ? (1 << (nb - 1)) : 0
        let offsetY = highY ? (1 << (nb - 1)) : 0
        // Filter synthesis support margin in subband samples (5/3 support: 1..2, 9/7 support: 2..4)
        let margin = reversible ? 2 : 4
        let sx0 = Wavelet53.floorDiv(roiX0 - offsetX, denom) - margin
        let sx1 = Wavelet53.ceilDiv(roiX1 - offsetX, denom) + margin
        let sy0 = Wavelet53.floorDiv(roiY0 - offsetY, denom) - margin
        let sy1 = Wavelet53.ceilDiv(roiY1 - offsetY, denom) + margin
        return (max(band.x0, sx0), min(band.x1, sx1),
                max(band.y0, sy0), min(band.y1, sy1))
    }

    /// Applies MaxShift decoding (ISO/IEC 15444-1 Annex H.1) to a decoded code-block's
    /// integer magnitudes: any coefficient with `magnitude >= (1 << shift)` belongs to the
    /// foreground ROI and is shifted right by `shift`.
    @inline(__always)
    static func descaleCoefficient(_ value: Int64, shift: Int) -> Int64 {
        guard shift > 0, value != 0 else { return value }
        let threshold = Int64(1) << shift
        let mag = value < 0 ? -value : value
        if mag >= threshold {
            let descaled = mag >> shift
            return value < 0 ? -descaled : descaled
        }
        return value
    }
}
