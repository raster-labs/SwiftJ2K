// SPDX-License-Identifier: Apache-2.0
//
// Multiple component transformations (ISO/IEC 15444-1 Annex G):
// - Annex G.2: Reversible Colour Transformation (RCT) for 5/3 wavelet coding;
// - Annex G.3: Irreversible Colour Transformation (ICT) for 9/7 wavelet coding.

enum ColourTransform {
    // MARK: - Annex G.2 Reversible Colour Transformation (RCT)

    /// Forward RCT in-place on the first three components (R, G, B -> Y, Cb, Cr)
    /// stored as contiguous planes of `pixelCount` samples each.
    static func forwardRCT(_ workspace: inout [Int32], pixelCount: Int) {
        let gBase = pixelCount
        let bBase = pixelCount * 2
        for i in 0..<pixelCount {
            let r = Int64(workspace[i])
            let g = Int64(workspace[gBase + i])
            let b = Int64(workspace[bBase + i])
            let y  = (r + 2 * g + b) >> 2
            let cb = b - g
            let cr = r - g
            workspace[i]         = Int32(truncatingIfNeeded: y)
            workspace[gBase + i] = Int32(truncatingIfNeeded: cb)
            workspace[bBase + i] = Int32(truncatingIfNeeded: cr)
        }
    }

    /// Inverse RCT in-place on the first three components (Y, Cb, Cr -> R, G, B).
    static func inverseRCT(_ workspace: inout [Int32], pixelCount: Int) {
        let cbBase = pixelCount
        let crBase = pixelCount * 2
        for i in 0..<pixelCount {
            let y  = Int64(workspace[i])
            let cb = Int64(workspace[cbBase + i])
            let cr = Int64(workspace[crBase + i])
            let g = y - ((cb + cr) >> 2)
            let r = cr + g
            let b = cb + g
            workspace[i]          = Int32(truncatingIfNeeded: r)
            workspace[cbBase + i] = Int32(truncatingIfNeeded: g)
            workspace[crBase + i] = Int32(truncatingIfNeeded: b)
        }
    }

    // MARK: - Annex G.3 Irreversible Colour Transformation (ICT)

    /// Forward ICT in-place on the first three components (R, G, B -> Y, Cb, Cr)
    /// per ISO/IEC 15444-1 Eq. G-3.
    static func forwardICT(_ workspace: inout [Double], pixelCount: Int) {
        let gBase = pixelCount
        let bBase = pixelCount * 2
        for i in 0..<pixelCount {
            let r = workspace[i]
            let g = workspace[gBase + i]
            let b = workspace[bBase + i]
            let y  =  0.299    * r + 0.587    * g + 0.114    * b
            let cb = -0.168736 * r - 0.331264 * g + 0.5      * b
            let cr =  0.5      * r - 0.418688 * g - 0.081312 * b
            workspace[i]         = y
            workspace[gBase + i] = cb
            workspace[bBase + i] = cr
        }
    }

    /// Inverse ICT in-place on the first three components (Y, Cb, Cr -> R, G, B)
    /// per ISO/IEC 15444-1 Eq. G-4.
    static func inverseICT(_ workspace: inout [Double], pixelCount: Int) {
        let cbBase = pixelCount
        let crBase = pixelCount * 2
        for i in 0..<pixelCount {
            let y  = workspace[i]
            let cb = workspace[cbBase + i]
            let cr = workspace[crBase + i]
            let r = y                        + 1.402    * cr
            let g = y - 0.344136 * cb - 0.714136 * cr
            let b = y + 1.772    * cb
            workspace[i]          = r
            workspace[cbBase + i] = g
            workspace[crBase + i] = b
        }
    }

    static func forwardRCT(planes: inout [[Int32]]) {
        guard planes.count >= 3 else { return }
        let count = min(planes[0].count, min(planes[1].count, planes[2].count))
        var rPlane = planes[0], gPlane = planes[1], bPlane = planes[2]
        for i in 0..<count {
            let r = Int64(rPlane[i])
            let g = Int64(gPlane[i])
            let b = Int64(bPlane[i])
            rPlane[i] = Int32(truncatingIfNeeded: (r + 2 * g + b) >> 2)
            gPlane[i] = Int32(truncatingIfNeeded: b - g)
            bPlane[i] = Int32(truncatingIfNeeded: r - g)
        }
        planes[0] = rPlane; planes[1] = gPlane; planes[2] = bPlane
    }

    static func inverseRCT(planes: inout [[Int32]]) {
        guard planes.count >= 3 else { return }
        let count = min(planes[0].count, min(planes[1].count, planes[2].count))
        var yPlane = planes[0], cbPlane = planes[1], crPlane = planes[2]
        for i in 0..<count {
            let yv  = Int64(yPlane[i])
            let cbv = Int64(cbPlane[i])
            let crv = Int64(crPlane[i])
            let g = yv - ((cbv + crv) >> 2)
            let r = crv + g
            let b = cbv + g
            yPlane[i]  = Int32(truncatingIfNeeded: r)
            cbPlane[i] = Int32(truncatingIfNeeded: g)
            crPlane[i] = Int32(truncatingIfNeeded: b)
        }
        planes[0] = yPlane; planes[1] = cbPlane; planes[2] = crPlane
    }

    static func forwardICT(planes: inout [[Double]]) {
        guard planes.count >= 3 else { return }
        let count = min(planes[0].count, min(planes[1].count, planes[2].count))
        var rPlane = planes[0], gPlane = planes[1], bPlane = planes[2]
        for i in 0..<count {
            let r = rPlane[i]
            let g = gPlane[i]
            let b = bPlane[i]
            rPlane[i] =  0.299    * r + 0.587    * g + 0.114    * b
            gPlane[i] = -0.168736 * r - 0.331264 * g + 0.5      * b
            bPlane[i] =  0.5      * r - 0.418688 * g - 0.081312 * b
        }
        planes[0] = rPlane; planes[1] = gPlane; planes[2] = bPlane
    }

    static func inverseICT(planes: inout [[Double]]) {
        guard planes.count >= 3 else { return }
        let count = min(planes[0].count, min(planes[1].count, planes[2].count))
        var yPlane = planes[0], cbPlane = planes[1], crPlane = planes[2]
        for i in 0..<count {
            let yv  = yPlane[i]
            let cbv = cbPlane[i]
            let crv = crPlane[i]
            yPlane[i]  = yv                        + 1.402    * crv
            cbPlane[i] = yv - 0.344136 * cbv - 0.714136 * crv
            crPlane[i] = yv + 1.772    * cbv
        }
        planes[0] = yPlane; planes[1] = cbPlane; planes[2] = crPlane
    }
}
