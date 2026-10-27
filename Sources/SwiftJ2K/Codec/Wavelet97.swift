// SPDX-License-Identifier: Apache-2.0
//
// Irreversible 9/7 CDF wavelet transform (ISO/IEC 15444-1 Annex F.3.8.2 and F.4.8.2,
// Table F.4) on an arbitrary reference-grid rectangle (x0..<x1, y0..<y1).

enum Wavelet97 {
    static let alpha: Double = -1.586134342059924
    static let beta: Double  = -0.052980118572961
    static let gamma: Double =  0.882911075530934
    static let delta: Double =  0.443506852043971
    static let k: Double     =  1.230174104914001
    static let invK: Double  =  1.0 / 1.230174104914001

    /// Periodic symmetric extension (ISO/IEC 15444-1 F.3.7).
    @inline(__always)
    private static func pse(_ i: Int, _ i0: Int, _ i1: Int) -> Int {
        let span = 2 * (i1 - i0 - 1)
        var m = (i - i0) % span
        if m < 0 { m += span }
        return i0 + min(m, span - m)
    }

    // MARK: - 1D Lifting (F.3.8.2 and F.4.8.2)

    static func forward1D(_ signal: UnsafeMutableBufferPointer<Double>,
                          i0: Int, i1: Int, scratch: UnsafeMutableBufferPointer<Double>) {
        let count = i1 - i0
        guard count > 0 else { return }
        if count == 1 {
            // ISO/IEC 15444-1 F.3.8.2: length-1 signal with odd origin is scaled by 2;
            // even origin is unchanged.
            if i0 & 1 != 0 {
                signal[0] *= 2.0
            }
            return
        }
        for k in 0..<count { scratch[k] = signal[k] }
        @inline(__always) func x(_ i: Int) -> Double { scratch[pse(i, i0, i1) - i0] }

        // Step 1: odd samples updated by alpha * (left + right)
        for i in i0..<i1 where i & 1 != 0 {
            scratch[i - i0] += alpha * (x(i - 1) + x(i + 1))
        }
        // Step 2: even samples updated by beta * (left + right)
        for i in i0..<i1 where i & 1 == 0 {
            scratch[i - i0] += beta * (x(i - 1) + x(i + 1))
        }
        // Step 3: odd samples updated by gamma * (left + right)
        for i in i0..<i1 where i & 1 != 0 {
            scratch[i - i0] += gamma * (x(i - 1) + x(i + 1))
        }
        // Step 4: even samples updated by delta * (left + right)
        for i in i0..<i1 where i & 1 == 0 {
            scratch[i - i0] += delta * (x(i - 1) + x(i + 1))
        }
        // Step 5 & 6: scale even (low-pass) by 1/K and odd (high-pass) by K,
        // de-interleaving into [low-pass | high-pass].
        let lows = Wavelet53.lowCount(i0, i1)
        var l = 0, h = lows
        for i in i0..<i1 {
            if i & 1 == 0 {
                signal[l] = scratch[i - i0] * invK
                l += 1
            } else {
                signal[h] = scratch[i - i0] * k
                h += 1
            }
        }
    }

    static func inverse1D(_ signal: UnsafeMutableBufferPointer<Double>,
                          i0: Int, i1: Int, scratch: UnsafeMutableBufferPointer<Double>) {
        let count = i1 - i0
        guard count > 0 else { return }
        if count == 1 {
            if i0 & 1 != 0 {
                signal[0] *= 0.5
            }
            return
        }
        // Interleave [low-pass | high-pass] back to reference-grid positions and undo K scaling.
        let lows = Wavelet53.lowCount(i0, i1)
        var l = 0, h = lows
        for i in i0..<i1 {
            if i & 1 == 0 {
                scratch[i - i0] = signal[l] * k
                l += 1
            } else {
                scratch[i - i0] = signal[h] * invK
                h += 1
            }
        }
        @inline(__always) func y(_ i: Int) -> Double { scratch[pse(i, i0, i1) - i0] }

        // Inverse Step 4: even samples -= delta * (left + right)
        for i in i0..<i1 where i & 1 == 0 {
            scratch[i - i0] -= delta * (y(i - 1) + y(i + 1))
        }
        // Inverse Step 3: odd samples -= gamma * (left + right)
        for i in i0..<i1 where i & 1 != 0 {
            scratch[i - i0] -= gamma * (y(i - 1) + y(i + 1))
        }
        // Inverse Step 2: even samples -= beta * (left + right)
        for i in i0..<i1 where i & 1 == 0 {
            scratch[i - i0] -= beta * (y(i - 1) + y(i + 1))
        }
        // Inverse Step 1: odd samples -= alpha * (left + right)
        for i in i0..<i1 where i & 1 != 0 {
            scratch[i - i0] -= alpha * (y(i - 1) + y(i + 1))
        }
        for idx in 0..<count { signal[idx] = scratch[idx] }
    }

    // MARK: - 2D Dyadic Decomposition

    static func forward(plane: inout [Double], stride: Int,
                        x0: Int, x1: Int, y0: Int, y1: Int, levels: Int,
                        cancellation: () throws -> Void) throws {
        guard levels > 0 else { return }
        let maxLine = max(x1 - x0, y1 - y0)
        var line = [Double](repeating: 0, count: maxLine)
        var scratch = [Double](repeating: 0, count: maxLine)
        for level in 0..<levels {
            try cancellation()
            let lx0 = Wavelet53.ceilDivPowerOfTwo(x0, level), lx1 = Wavelet53.ceilDivPowerOfTwo(x1, level)
            let ly0 = Wavelet53.ceilDivPowerOfTwo(y0, level), ly1 = Wavelet53.ceilDivPowerOfTwo(y1, level)
            let w = lx1 - lx0, h = ly1 - ly0
            guard w > 0, h > 0 else { continue }
            line.withUnsafeMutableBufferPointer { lineBuf in
                scratch.withUnsafeMutableBufferPointer { scratchBuf in
                    for y in 0..<h {
                        let base = y * stride
                        for x in 0..<w { lineBuf[x] = plane[base + x] }
                        forward1D(lineBuf, i0: lx0, i1: lx1, scratch: scratchBuf)
                        for x in 0..<w { plane[base + x] = lineBuf[x] }
                    }
                    for x in 0..<w {
                        for y in 0..<h { lineBuf[y] = plane[y * stride + x] }
                        forward1D(lineBuf, i0: ly0, i1: ly1, scratch: scratchBuf)
                        for y in 0..<h { plane[y * stride + x] = lineBuf[y] }
                    }
                }
            }
        }
    }

    static func inverse(plane: inout [Double], stride: Int,
                        x0: Int, x1: Int, y0: Int, y1: Int, levels: Int,
                        cancellation: () throws -> Void) throws {
        guard levels > 0 else { return }
        let maxLine = max(x1 - x0, y1 - y0)
        var line = [Double](repeating: 0, count: maxLine)
        var scratch = [Double](repeating: 0, count: maxLine)
        for level in (0..<levels).reversed() {
            try cancellation()
            let lx0 = Wavelet53.ceilDivPowerOfTwo(x0, level), lx1 = Wavelet53.ceilDivPowerOfTwo(x1, level)
            let ly0 = Wavelet53.ceilDivPowerOfTwo(y0, level), ly1 = Wavelet53.ceilDivPowerOfTwo(y1, level)
            let w = lx1 - lx0, h = ly1 - ly0
            guard w > 0, h > 0 else { continue }
            line.withUnsafeMutableBufferPointer { lineBuf in
                scratch.withUnsafeMutableBufferPointer { scratchBuf in
                    for x in 0..<w {
                        for y in 0..<h { lineBuf[y] = plane[y * stride + x] }
                        inverse1D(lineBuf, i0: ly0, i1: ly1, scratch: scratchBuf)
                        for y in 0..<h { plane[y * stride + x] = lineBuf[y] }
                    }
                    for y in 0..<h {
                        let base = y * stride
                        for x in 0..<w { lineBuf[x] = plane[base + x] }
                        inverse1D(lineBuf, i0: lx0, i1: lx1, scratch: scratchBuf)
                        for x in 0..<w { plane[base + x] = lineBuf[x] }
                    }
                }
            }
        }
    }
}
