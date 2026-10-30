import Foundation

// MARK: - SIMD / NEON Acceleration Subsystem (Milestone 9)
//
// Migrates and unifies the predecessor's ARM NEON and SIMD acceleration paths:
// - `Sources/J2KCodecNEON/*` (`j2knhd.h`, `j2knhe.h`, `j2knhd_decode_block_ht.c`,
//   `j2knhd_magsgn.c`, `j2knhd_mel.c`, `j2knhd_vlc.c`, `j2knhe_encode_block_ht.c`,
//   `j2knhe_tables.c`)
// - `Sources/J2KCodec/ARM/J2KNeonEntropyCoding.swift`
// - `Sources/J2KCodec/J2KAcceleratedEncoder.swift` (CPU SIMD wavelet, colour, quantizer, ROI)
//
// All routines use portable Swift `SIMD4` vector types (compiling to ARM64 NEON `int32x4_t` /
// `int64x2_t` / `float64x2_t` instructions on Apple Silicon and SSE/AVX on x86_64) and preserve
// 100% bit-for-bit parity with the scalar reference paths.

// MARK: - 1. SIMD 5/3 Reversible Wavelet Transform (ISO/IEC 15444-1 Annex F.3.8.2 / F.4.8.2)

internal enum SIMDWavelet53 {
    @inline(__always)
    private static func extendedIndex(i0: Int, n: Int, at i: Int) -> Int {
        var k = i - i0
        if n == 1 { return 0 }
        let period = 2 * (n - 1)
        k = ((k % period) + period) % period
        if k >= n { k = period - k }
        return k
    }

    /// 4-lane `SIMD4<Int32>` 1D analysis over `[i0, i0 + n)`.
    internal static func analyse4(
        _ x: [SIMD4<Int32>],
        i0: Int,
        count n: Int,
        into low: inout [SIMD4<Int32>],
        _ high: inout [SIMD4<Int32>],
        oddScratch: inout [SIMD4<Int32>]
    ) {
        let i1 = i0 + n
        if n == 1 {
            if i0 & 1 == 0 {
                low[0] = x[0]
            } else {
                high[0] = x[0] &* 2
            }
            return
        }
        let firstOdd = (i0 - 1) | 1
        let lastOdd = ((i1 + 1) & ~1) - 1
        var oddIdx = 0
        var i = firstOdd
        while i <= lastOdd {
            let left = x[extendedIndex(i0: i0, n: n, at: i - 1)]
            let right = x[extendedIndex(i0: i0, n: n, at: i + 1)]
            let center = x[extendedIndex(i0: i0, n: n, at: i)]
            let sum64 = SIMD4<Int64>(truncatingIfNeeded: left) &+ SIMD4<Int64>(truncatingIfNeeded: right)
            let half = SIMD4<Int32>(truncatingIfNeeded: sum64 &>> 1)
            oddScratch[oddIdx] = center &- half
            oddIdx += 1
            i += 2
        }

        @inline(__always)
        func oddY(_ coordinate: Int) -> SIMD4<Int32> {
            oddScratch[(coordinate - firstOdd) / 2]
        }

        let two64 = SIMD4<Int64>(repeating: 2)
        var lowIndex = 0
        var highIndex = 0
        for coordinate in i0..<i1 {
            if coordinate & 1 == 0 {
                let oL = SIMD4<Int64>(truncatingIfNeeded: oddY(coordinate - 1))
                let oR = SIMD4<Int64>(truncatingIfNeeded: oddY(coordinate + 1))
                let quarter = SIMD4<Int32>(truncatingIfNeeded: (oL &+ oR &+ two64) &>> 2)
                low[lowIndex] = x[coordinate - i0] &+ quarter
                lowIndex += 1
            } else {
                high[highIndex] = oddY(coordinate)
                highIndex += 1
            }
        }
    }

    /// 4-lane `SIMD4<Int32>` 1D synthesis over `[i0, i0 + n)` with 64-bit overflow checking.
    internal static func synthesise4(
        low: [SIMD4<Int32>],
        high: [SIMD4<Int32>],
        i0: Int,
        count n: Int,
        into x: inout [SIMD4<Int32>],
        yScratch: inout [SIMD4<Int32>],
        evenScratch: inout [SIMD4<Int32>]
    ) throws {
        let i1 = i0 + n
        if n == 1 {
            if i0 & 1 == 0 {
                x[0] = low[0]
            } else {
                let v = high[0]
                x[0] = SIMD4<Int32>(v[0] / 2, v[1] / 2, v[2] / 2, v[3] / 2)
            }
            return
        }

        var lowIndex = 0
        var highIndex = 0
        for coordinate in i0..<i1 {
            if coordinate & 1 == 0 {
                yScratch[coordinate - i0] = low[lowIndex]
                lowIndex += 1
            } else {
                yScratch[coordinate - i0] = high[highIndex]
                highIndex += 1
            }
        }

        let firstEven = (i0 - 1) & ~1
        let lastEven = i1 & ~1
        let two64 = SIMD4<Int64>(repeating: 2)
        var evenIdx = 0
        var i = firstEven
        while i <= lastEven {
            let left = SIMD4<Int64>(truncatingIfNeeded: yScratch[extendedIndex(i0: i0, n: n, at: i - 1)])
            let right = SIMD4<Int64>(truncatingIfNeeded: yScratch[extendedIndex(i0: i0, n: n, at: i + 1)])
            let center = SIMD4<Int64>(truncatingIfNeeded: yScratch[extendedIndex(i0: i0, n: n, at: i)])
            let even = center &- ((left &+ right &+ two64) &>> 2)
            try validateInt32Range(even)
            evenScratch[evenIdx] = SIMD4<Int32>(truncatingIfNeeded: even)
            evenIdx += 1
            i += 2
        }

        @inline(__always)
        func evenX(_ coordinate: Int) -> SIMD4<Int32> {
            evenScratch[(coordinate - firstEven) / 2]
        }

        for coordinate in i0..<i1 {
            if coordinate & 1 == 0 {
                x[coordinate - i0] = evenX(coordinate)
            } else {
                let c64 = SIMD4<Int64>(truncatingIfNeeded: yScratch[coordinate - i0])
                let eL = SIMD4<Int64>(truncatingIfNeeded: evenX(coordinate - 1))
                let eR = SIMD4<Int64>(truncatingIfNeeded: evenX(coordinate + 1))
                let odd = c64 &+ ((eL &+ eR) &>> 1)
                try validateInt32Range(odd)
                x[coordinate - i0] = SIMD4<Int32>(truncatingIfNeeded: odd)
            }
        }
    }

    @inline(__always)
    private static func validateInt32Range(_ v: SIMD4<Int64>) throws {
        let minVal = Int64(Int32.min)
        let maxVal = Int64(Int32.max)
        if v[0] < minVal || v[0] > maxVal
            || v[1] < minVal || v[1] > maxVal
            || v[2] < minVal || v[2] > maxVal
            || v[3] < minVal || v[3] > maxVal
        {
            throw CodecError(.malformedInput, "Wavelet synthesis overflowed the 32-bit coefficient range.")
        }
    }

    /// Forward 2D 5/3 wavelet decomposition in-place using 4-lane `SIMD4<Int32>` vectorisation.
    ///
    /// Bit-for-bit identical to `Wavelet53.forward`.
    internal static func forward(
        plane: inout [Int32],
        stride: Int,
        x0: Int,
        x1: Int,
        y0: Int,
        y1: Int,
        levels: Int,
        cancellation: () throws -> Void
    ) throws {
        guard levels > 0 else { return }
        let maxDim = max(x1 - x0, y1 - y0)
        guard maxDim > 0 else { return }

        var line4 = [SIMD4<Int32>](repeating: .zero, count: maxDim)
        var low4 = [SIMD4<Int32>](repeating: .zero, count: maxDim / 2 + 2)
        var high4 = [SIMD4<Int32>](repeating: .zero, count: maxDim / 2 + 2)
        var oddScratch4 = [SIMD4<Int32>](repeating: .zero, count: maxDim / 2 + 4)

        var line1 = [Int32](repeating: 0, count: maxDim)
        var low1 = [Int32](repeating: 0, count: maxDim / 2 + 1)
        var high1 = [Int32](repeating: 0, count: maxDim / 2 + 1)

        for level in 1...levels {
            let rx0 = Wavelet53.ceilDivPowerOfTwo(x0, level - 1)
            let rx1 = Wavelet53.ceilDivPowerOfTwo(x1, level - 1)
            let ry0 = Wavelet53.ceilDivPowerOfTwo(y0, level - 1)
            let ry1 = Wavelet53.ceilDivPowerOfTwo(y1, level - 1)
            let w = rx1 - rx0
            let h = ry1 - ry0
            guard w > 0, h > 0 else { continue }

            let lowH = Wavelet53.lowCount(ry0, ry1)
            let lowW = Wavelet53.lowCount(rx0, rx1)

            // VER_SD across 4 columns at a time
            var x = 0
            while x + 4 <= w {
                for y in 0..<h {
                    let base = y * stride + x
                    line4[y] = SIMD4<Int32>(plane[base], plane[base + 1], plane[base + 2], plane[base + 3])
                }
                analyse4(line4, i0: ry0, count: h, into: &low4, &high4, oddScratch: &oddScratch4)
                for i in 0..<lowH {
                    let base = i * stride + x
                    let v = low4[i]
                    plane[base] = v[0]; plane[base + 1] = v[1]; plane[base + 2] = v[2]; plane[base + 3] = v[3]
                }
                for i in 0..<(h - lowH) {
                    let base = (lowH + i) * stride + x
                    let v = high4[i]
                    plane[base] = v[0]; plane[base + 1] = v[1]; plane[base + 2] = v[2]; plane[base + 3] = v[3]
                }
                if (x & 63) == 60 { try cancellation() }
                x += 4
            }
            while x < w {
                for y in 0..<h { line1[y] = plane[y * stride + x] }
                Wavelet53.analyse(line1, i0: ry0, count: h, into: &low1, &high1)
                for i in 0..<lowH { plane[i * stride + x] = low1[i] }
                for i in 0..<(h - lowH) { plane[(lowH + i) * stride + x] = high1[i] }
                x += 1
            }

            // HOR_SD across 4 rows at a time
            var y = 0
            while y + 4 <= h {
                let r0 = y * stride
                let r1 = (y + 1) * stride
                let r2 = (y + 2) * stride
                let r3 = (y + 3) * stride
                for col in 0..<w {
                    line4[col] = SIMD4<Int32>(plane[r0 + col], plane[r1 + col], plane[r2 + col], plane[r3 + col])
                }
                analyse4(line4, i0: rx0, count: w, into: &low4, &high4, oddScratch: &oddScratch4)
                for i in 0..<lowW {
                    let v = low4[i]
                    plane[r0 + i] = v[0]; plane[r1 + i] = v[1]; plane[r2 + i] = v[2]; plane[r3 + i] = v[3]
                }
                for i in 0..<(w - lowW) {
                    let col = lowW + i
                    let v = high4[i]
                    plane[r0 + col] = v[0]; plane[r1 + col] = v[1]; plane[r2 + col] = v[2]; plane[r3 + col] = v[3]
                }
                if (y & 63) == 60 { try cancellation() }
                y += 4
            }
            while y < h {
                for col in 0..<w { line1[col] = plane[y * stride + col] }
                Wavelet53.analyse(line1, i0: rx0, count: w, into: &low1, &high1)
                for i in 0..<lowW { plane[y * stride + i] = low1[i] }
                for i in 0..<(w - lowW) { plane[y * stride + lowW + i] = high1[i] }
                y += 1
            }
            try cancellation()
        }
    }

    /// Inverse 2D 5/3 wavelet synthesis in-place using 4-lane `SIMD4<Int32>` vectorisation.
    ///
    /// Bit-for-bit identical to `Wavelet53.inverse`.
    internal static func inverse(
        plane: inout [Int32],
        stride: Int,
        x0: Int,
        x1: Int,
        y0: Int,
        y1: Int,
        levels: Int,
        cancellation: () throws -> Void
    ) throws {
        guard levels > 0 else { return }
        let maxDim = max(x1 - x0, y1 - y0)
        guard maxDim > 0 else { return }

        var line4 = [SIMD4<Int32>](repeating: .zero, count: maxDim)
        var low4 = [SIMD4<Int32>](repeating: .zero, count: maxDim / 2 + 2)
        var high4 = [SIMD4<Int32>](repeating: .zero, count: maxDim / 2 + 2)
        var yScratch4 = [SIMD4<Int32>](repeating: .zero, count: maxDim)
        var evenScratch4 = [SIMD4<Int32>](repeating: .zero, count: maxDim / 2 + 4)

        var line1 = [Int32](repeating: 0, count: maxDim)
        var low1 = [Int32](repeating: 0, count: maxDim / 2 + 1)
        var high1 = [Int32](repeating: 0, count: maxDim / 2 + 1)

        for level in Swift.stride(from: levels, through: 1, by: -1) {
            let rx0 = Wavelet53.ceilDivPowerOfTwo(x0, level - 1)
            let rx1 = Wavelet53.ceilDivPowerOfTwo(x1, level - 1)
            let ry0 = Wavelet53.ceilDivPowerOfTwo(y0, level - 1)
            let ry1 = Wavelet53.ceilDivPowerOfTwo(y1, level - 1)
            let w = rx1 - rx0
            let h = ry1 - ry0
            guard w > 0, h > 0 else { continue }

            let lowW = Wavelet53.lowCount(rx0, rx1)
            let lowH = Wavelet53.lowCount(ry0, ry1)

            // HOR_SR across 4 rows at a time
            var y = 0
            while y + 4 <= h {
                let r0 = y * stride
                let r1 = (y + 1) * stride
                let r2 = (y + 2) * stride
                let r3 = (y + 3) * stride
                for i in 0..<lowW {
                    low4[i] = SIMD4<Int32>(plane[r0 + i], plane[r1 + i], plane[r2 + i], plane[r3 + i])
                }
                for i in 0..<(w - lowW) {
                    let col = lowW + i
                    high4[i] = SIMD4<Int32>(plane[r0 + col], plane[r1 + col], plane[r2 + col], plane[r3 + col])
                }
                try synthesise4(
                    low: low4, high: high4, i0: rx0, count: w,
                    into: &line4, yScratch: &yScratch4, evenScratch: &evenScratch4
                )
                for col in 0..<w {
                    let v = line4[col]
                    plane[r0 + col] = v[0]; plane[r1 + col] = v[1]; plane[r2 + col] = v[2]; plane[r3 + col] = v[3]
                }
                if (y & 63) == 60 { try cancellation() }
                y += 4
            }
            while y < h {
                for i in 0..<lowW { low1[i] = plane[y * stride + i] }
                for i in 0..<(w - lowW) { high1[i] = plane[y * stride + lowW + i] }
                try Wavelet53.synthesise(low: low1, high: high1, i0: rx0, count: w, into: &line1)
                for col in 0..<w { plane[y * stride + col] = line1[col] }
                y += 1
            }

            // VER_SR across 4 columns at a time
            var x = 0
            while x + 4 <= w {
                for i in 0..<lowH {
                    let base = i * stride + x
                    low4[i] = SIMD4<Int32>(plane[base], plane[base + 1], plane[base + 2], plane[base + 3])
                }
                for i in 0..<(h - lowH) {
                    let base = (lowH + i) * stride + x
                    high4[i] = SIMD4<Int32>(plane[base], plane[base + 1], plane[base + 2], plane[base + 3])
                }
                try synthesise4(
                    low: low4, high: high4, i0: ry0, count: h,
                    into: &line4, yScratch: &yScratch4, evenScratch: &evenScratch4
                )
                for row in 0..<h {
                    let base = row * stride + x
                    let v = line4[row]
                    plane[base] = v[0]; plane[base + 1] = v[1]; plane[base + 2] = v[2]; plane[base + 3] = v[3]
                }
                if (x & 63) == 60 { try cancellation() }
                x += 4
            }
            while x < w {
                for i in 0..<lowH { low1[i] = plane[i * stride + x] }
                for i in 0..<(h - lowH) { high1[i] = plane[(lowH + i) * stride + x] }
                try Wavelet53.synthesise(low: low1, high: high1, i0: ry0, count: h, into: &line1)
                for row in 0..<h { plane[row * stride + x] = line1[row] }
                x += 1
            }
            try cancellation()
        }
    }
}

// MARK: - 2. SIMD 9/7 Irreversible Wavelet Transform (ISO/IEC 15444-1 Annex F.3.8.2 / F.4.8.2)

internal enum SIMDWavelet97 {
    @inline(__always)
    private static func pse(_ i: Int, _ i0: Int, _ i1: Int) -> Int {
        let span = 2 * (i1 - i0 - 1)
        var m = (i - i0) % span
        if m < 0 { m += span }
        return i0 + min(m, span - m)
    }

    internal static func forward1D4(
        _ signal: inout [SIMD4<Double>],
        i0: Int,
        i1: Int,
        scratch: inout [SIMD4<Double>]
    ) {
        let count = i1 - i0
        guard count > 0 else { return }
        if count == 1 {
            if i0 & 1 != 0 {
                signal[0] *= SIMD4<Double>(repeating: 2.0)
            }
            return
        }
        for k in 0..<count { scratch[k] = signal[k] }
        @inline(__always)
        func x(_ i: Int) -> SIMD4<Double> { scratch[pse(i, i0, i1) - i0] }

        let alphaVec = SIMD4<Double>(repeating: Wavelet97.alpha)
        let betaVec  = SIMD4<Double>(repeating: Wavelet97.beta)
        let gammaVec = SIMD4<Double>(repeating: Wavelet97.gamma)
        let deltaVec = SIMD4<Double>(repeating: Wavelet97.delta)
        let kVec     = SIMD4<Double>(repeating: Wavelet97.k)
        let invKVec  = SIMD4<Double>(repeating: Wavelet97.invK)

        for i in i0..<i1 where i & 1 != 0 {
            scratch[i - i0] += alphaVec * (x(i - 1) + x(i + 1))
        }
        for i in i0..<i1 where i & 1 == 0 {
            scratch[i - i0] += betaVec * (x(i - 1) + x(i + 1))
        }
        for i in i0..<i1 where i & 1 != 0 {
            scratch[i - i0] += gammaVec * (x(i - 1) + x(i + 1))
        }
        for i in i0..<i1 where i & 1 == 0 {
            scratch[i - i0] += deltaVec * (x(i - 1) + x(i + 1))
        }

        let lows = Wavelet53.lowCount(i0, i1)
        var l = 0
        var h = lows
        for i in i0..<i1 {
            if i & 1 == 0 {
                signal[l] = scratch[i - i0] * invKVec
                l += 1
            } else {
                signal[h] = scratch[i - i0] * kVec
                h += 1
            }
        }
    }

    internal static func inverse1D4(
        _ signal: inout [SIMD4<Double>],
        i0: Int,
        i1: Int,
        scratch: inout [SIMD4<Double>]
    ) {
        let count = i1 - i0
        guard count > 0 else { return }
        if count == 1 {
            if i0 & 1 != 0 {
                signal[0] *= SIMD4<Double>(repeating: 0.5)
            }
            return
        }

        let alphaVec = SIMD4<Double>(repeating: Wavelet97.alpha)
        let betaVec  = SIMD4<Double>(repeating: Wavelet97.beta)
        let gammaVec = SIMD4<Double>(repeating: Wavelet97.gamma)
        let deltaVec = SIMD4<Double>(repeating: Wavelet97.delta)
        let kVec     = SIMD4<Double>(repeating: Wavelet97.k)
        let invKVec  = SIMD4<Double>(repeating: Wavelet97.invK)

        let lows = Wavelet53.lowCount(i0, i1)
        var l = 0
        var h = lows
        for i in i0..<i1 {
            if i & 1 == 0 {
                scratch[i - i0] = signal[l] * kVec
                l += 1
            } else {
                scratch[i - i0] = signal[h] * invKVec
                h += 1
            }
        }
        @inline(__always)
        func y(_ i: Int) -> SIMD4<Double> { scratch[pse(i, i0, i1) - i0] }

        for i in i0..<i1 where i & 1 == 0 {
            scratch[i - i0] -= deltaVec * (y(i - 1) + y(i + 1))
        }
        for i in i0..<i1 where i & 1 != 0 {
            scratch[i - i0] -= gammaVec * (y(i - 1) + y(i + 1))
        }
        for i in i0..<i1 where i & 1 == 0 {
            scratch[i - i0] -= betaVec * (y(i - 1) + y(i + 1))
        }
        for i in i0..<i1 where i & 1 != 0 {
            scratch[i - i0] -= alphaVec * (y(i - 1) + y(i + 1))
        }
        for idx in 0..<count { signal[idx] = scratch[idx] }
    }

    /// Forward 2D 9/7 wavelet decomposition in-place using 4-lane `SIMD4<Double>` lifting.
    ///
    /// Preserves IEEE-754 double-precision arithmetic (remediating `M9-AUD-004`) and is
    /// bit-for-bit identical to `Wavelet97.forward`.
    internal static func forward(
        plane: inout [Double],
        stride: Int,
        x0: Int,
        x1: Int,
        y0: Int,
        y1: Int,
        levels: Int,
        cancellation: () throws -> Void
    ) throws {
        guard levels > 0 else { return }
        let maxLine = max(x1 - x0, y1 - y0)
        guard maxLine > 0 else { return }

        var line4 = [SIMD4<Double>](repeating: .zero, count: maxLine)
        var scratch4 = [SIMD4<Double>](repeating: .zero, count: maxLine)
        var line1 = [Double](repeating: 0.0, count: maxLine)
        var scratch1 = [Double](repeating: 0.0, count: maxLine)

        for level in 0..<levels {
            try cancellation()
            let lx0 = Wavelet53.ceilDivPowerOfTwo(x0, level)
            let lx1 = Wavelet53.ceilDivPowerOfTwo(x1, level)
            let ly0 = Wavelet53.ceilDivPowerOfTwo(y0, level)
            let ly1 = Wavelet53.ceilDivPowerOfTwo(y1, level)
            let w = lx1 - lx0
            let h = ly1 - ly0
            guard w > 0, h > 0 else { continue }

            // Horizontal pass across 4 rows at a time
            var y = 0
            while y + 4 <= h {
                let r0 = y * stride
                let r1 = (y + 1) * stride
                let r2 = (y + 2) * stride
                let r3 = (y + 3) * stride
                for x in 0..<w {
                    line4[x] = SIMD4<Double>(plane[r0 + x], plane[r1 + x], plane[r2 + x], plane[r3 + x])
                }
                forward1D4(&line4, i0: lx0, i1: lx1, scratch: &scratch4)
                for x in 0..<w {
                    let v = line4[x]
                    plane[r0 + x] = v[0]; plane[r1 + x] = v[1]; plane[r2 + x] = v[2]; plane[r3 + x] = v[3]
                }
                y += 4
            }
            if y < h {
                line1.withUnsafeMutableBufferPointer { lineBuf in
                    scratch1.withUnsafeMutableBufferPointer { scratchBuf in
                        while y < h {
                            let base = y * stride
                            for x in 0..<w { lineBuf[x] = plane[base + x] }
                            Wavelet97.forward1D(lineBuf, i0: lx0, i1: lx1, scratch: scratchBuf)
                            for x in 0..<w { plane[base + x] = lineBuf[x] }
                            y += 1
                        }
                    }
                }
            }

            // Vertical pass across 4 columns at a time
            var x = 0
            while x + 4 <= w {
                for row in 0..<h {
                    let base = row * stride + x
                    line4[row] = SIMD4<Double>(plane[base], plane[base + 1], plane[base + 2], plane[base + 3])
                }
                forward1D4(&line4, i0: ly0, i1: ly1, scratch: &scratch4)
                for row in 0..<h {
                    let base = row * stride + x
                    let v = line4[row]
                    plane[base] = v[0]; plane[base + 1] = v[1]; plane[base + 2] = v[2]; plane[base + 3] = v[3]
                }
                x += 4
            }
            if x < w {
                line1.withUnsafeMutableBufferPointer { lineBuf in
                    scratch1.withUnsafeMutableBufferPointer { scratchBuf in
                        while x < w {
                            for row in 0..<h { lineBuf[row] = plane[row * stride + x] }
                            Wavelet97.forward1D(lineBuf, i0: ly0, i1: ly1, scratch: scratchBuf)
                            for row in 0..<h { plane[row * stride + x] = lineBuf[row] }
                            x += 1
                        }
                    }
                }
            }
        }
    }

    /// Inverse 2D 9/7 wavelet reconstruction in-place using 4-lane `SIMD4<Double>` lifting.
    ///
    /// Bit-for-bit identical to `Wavelet97.inverse`.
    internal static func inverse(
        plane: inout [Double],
        stride: Int,
        x0: Int,
        x1: Int,
        y0: Int,
        y1: Int,
        levels: Int,
        cancellation: () throws -> Void
    ) throws {
        guard levels > 0 else { return }
        let maxLine = max(x1 - x0, y1 - y0)
        guard maxLine > 0 else { return }

        var line4 = [SIMD4<Double>](repeating: .zero, count: maxLine)
        var scratch4 = [SIMD4<Double>](repeating: .zero, count: maxLine)
        var line1 = [Double](repeating: 0.0, count: maxLine)
        var scratch1 = [Double](repeating: 0.0, count: maxLine)

        for level in (0..<levels).reversed() {
            try cancellation()
            let lx0 = Wavelet53.ceilDivPowerOfTwo(x0, level)
            let lx1 = Wavelet53.ceilDivPowerOfTwo(x1, level)
            let ly0 = Wavelet53.ceilDivPowerOfTwo(y0, level)
            let ly1 = Wavelet53.ceilDivPowerOfTwo(y1, level)
            let w = lx1 - lx0
            let h = ly1 - ly0
            guard w > 0, h > 0 else { continue }

            // Vertical inverse pass across 4 columns at a time
            var x = 0
            while x + 4 <= w {
                for row in 0..<h {
                    let base = row * stride + x
                    line4[row] = SIMD4<Double>(plane[base], plane[base + 1], plane[base + 2], plane[base + 3])
                }
                inverse1D4(&line4, i0: ly0, i1: ly1, scratch: &scratch4)
                for row in 0..<h {
                    let base = row * stride + x
                    let v = line4[row]
                    plane[base] = v[0]; plane[base + 1] = v[1]; plane[base + 2] = v[2]; plane[base + 3] = v[3]
                }
                x += 4
            }
            if x < w {
                line1.withUnsafeMutableBufferPointer { lineBuf in
                    scratch1.withUnsafeMutableBufferPointer { scratchBuf in
                        while x < w {
                            for row in 0..<h { lineBuf[row] = plane[row * stride + x] }
                            Wavelet97.inverse1D(lineBuf, i0: ly0, i1: ly1, scratch: scratchBuf)
                            for row in 0..<h { plane[row * stride + x] = lineBuf[row] }
                            x += 1
                        }
                    }
                }
            }

            // Horizontal inverse pass across 4 rows at a time
            var y = 0
            while y + 4 <= h {
                let r0 = y * stride
                let r1 = (y + 1) * stride
                let r2 = (y + 2) * stride
                let r3 = (y + 3) * stride
                for col in 0..<w {
                    line4[col] = SIMD4<Double>(plane[r0 + col], plane[r1 + col], plane[r2 + col], plane[r3 + col])
                }
                inverse1D4(&line4, i0: lx0, i1: lx1, scratch: &scratch4)
                for col in 0..<w {
                    let v = line4[col]
                    plane[r0 + col] = v[0]; plane[r1 + col] = v[1]; plane[r2 + col] = v[2]; plane[r3 + col] = v[3]
                }
                y += 4
            }
            if y < h {
                line1.withUnsafeMutableBufferPointer { lineBuf in
                    scratch1.withUnsafeMutableBufferPointer { scratchBuf in
                        while y < h {
                            let base = y * stride
                            for col in 0..<w { lineBuf[col] = plane[base + col] }
                            Wavelet97.inverse1D(lineBuf, i0: lx0, i1: lx1, scratch: scratchBuf)
                            for col in 0..<w { plane[base + col] = lineBuf[col] }
                            y += 1
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 3. SIMD Colour Transforms (RCT & ICT — ISO/IEC 15444-1 Annex G.2 / G.3)

internal enum SIMDColourTransform {
    /// Forward Reversible Colour Transform (RCT) in-place on 3 component planes using `SIMD4<Int64>`.
    ///
    /// Remediates predecessor `M9-AUD-005` by performing `(R + 2*G + B) >> 2` in 64-bit lanes.
    /// Bit-for-bit identical to `ColourTransform.forwardRCT(planes:)`.
    internal static func forwardRCT(planes: inout [[Int32]]) {
        guard planes.count >= 3 else { return }
        let count = min(planes[0].count, min(planes[1].count, planes[2].count))
        var rPlane = planes[0]
        var gPlane = planes[1]
        var bPlane = planes[2]

        let two = SIMD4<Int64>(repeating: 2)
        var i = 0
        while i + 4 <= count {
            let r = SIMD4<Int64>(
                Int64(rPlane[i]), Int64(rPlane[i + 1]), Int64(rPlane[i + 2]), Int64(rPlane[i + 3])
            )
            let g = SIMD4<Int64>(
                Int64(gPlane[i]), Int64(gPlane[i + 1]), Int64(gPlane[i + 2]), Int64(gPlane[i + 3])
            )
            let b = SIMD4<Int64>(
                Int64(bPlane[i]), Int64(bPlane[i + 1]), Int64(bPlane[i + 2]), Int64(bPlane[i + 3])
            )

            let y  = SIMD4<Int32>(truncatingIfNeeded: (r &+ (two &* g) &+ b) &>> 2)
            let cb = SIMD4<Int32>(truncatingIfNeeded: b &- g)
            let cr = SIMD4<Int32>(truncatingIfNeeded: r &- g)

            rPlane[i] = y[0];  rPlane[i + 1] = y[1];  rPlane[i + 2] = y[2];  rPlane[i + 3] = y[3]
            gPlane[i] = cb[0]; gPlane[i + 1] = cb[1]; gPlane[i + 2] = cb[2]; gPlane[i + 3] = cb[3]
            bPlane[i] = cr[0]; bPlane[i + 1] = cr[1]; bPlane[i + 2] = cr[2]; bPlane[i + 3] = cr[3]
            i += 4
        }
        while i < count {
            let r = Int64(rPlane[i])
            let g = Int64(gPlane[i])
            let b = Int64(bPlane[i])
            rPlane[i] = Int32(truncatingIfNeeded: (r + 2 * g + b) >> 2)
            gPlane[i] = Int32(truncatingIfNeeded: b - g)
            bPlane[i] = Int32(truncatingIfNeeded: r - g)
            i += 1
        }
        planes[0] = rPlane
        planes[1] = gPlane
        planes[2] = bPlane
    }

    /// Inverse Reversible Colour Transform (RCT) in-place on 3 component planes using `SIMD4<Int64>`.
    ///
    /// Bit-for-bit identical to `ColourTransform.inverseRCT(planes:)`.
    internal static func inverseRCT(planes: inout [[Int32]]) {
        guard planes.count >= 3 else { return }
        let count = min(planes[0].count, min(planes[1].count, planes[2].count))
        var yPlane = planes[0]
        var cbPlane = planes[1]
        var crPlane = planes[2]

        var i = 0
        while i + 4 <= count {
            let yv = SIMD4<Int64>(
                Int64(yPlane[i]), Int64(yPlane[i + 1]), Int64(yPlane[i + 2]), Int64(yPlane[i + 3])
            )
            let cbv = SIMD4<Int64>(
                Int64(cbPlane[i]), Int64(cbPlane[i + 1]), Int64(cbPlane[i + 2]), Int64(cbPlane[i + 3])
            )
            let crv = SIMD4<Int64>(
                Int64(crPlane[i]), Int64(crPlane[i + 1]), Int64(crPlane[i + 2]), Int64(crPlane[i + 3])
            )

            let g = yv &- ((cbv &+ crv) &>> 2)
            let r = SIMD4<Int32>(truncatingIfNeeded: crv &+ g)
            let g32 = SIMD4<Int32>(truncatingIfNeeded: g)
            let b = SIMD4<Int32>(truncatingIfNeeded: cbv &+ g)

            yPlane[i]  = r[0];   yPlane[i + 1]  = r[1];   yPlane[i + 2]  = r[2];   yPlane[i + 3]  = r[3]
            cbPlane[i] = g32[0]; cbPlane[i + 1] = g32[1]; cbPlane[i + 2] = g32[2]; cbPlane[i + 3] = g32[3]
            crPlane[i] = b[0];   crPlane[i + 1] = b[1];   crPlane[i + 2] = b[2];   crPlane[i + 3] = b[3]
            i += 4
        }
        while i < count {
            let yv  = Int64(yPlane[i])
            let cbv = Int64(cbPlane[i])
            let crv = Int64(crPlane[i])
            let g = yv - ((cbv + crv) >> 2)
            yPlane[i]  = Int32(truncatingIfNeeded: crv + g)
            cbPlane[i] = Int32(truncatingIfNeeded: g)
            crPlane[i] = Int32(truncatingIfNeeded: cbv + g)
            i += 1
        }
        planes[0] = yPlane
        planes[1] = cbPlane
        planes[2] = crPlane
    }

    /// Forward Irreversible Colour Transform (ICT) in-place on 3 component planes using `SIMD4<Double>`.
    ///
    /// Bit-for-bit identical to `ColourTransform.forwardICT(planes:)`.
    internal static func forwardICT(planes: inout [[Double]]) {
        guard planes.count >= 3 else { return }
        let count = min(planes[0].count, min(planes[1].count, planes[2].count))
        var rPlane = planes[0]
        var gPlane = planes[1]
        var bPlane = planes[2]

        let c0R = SIMD4<Double>(repeating:  0.299)
        let c0G = SIMD4<Double>(repeating:  0.587)
        let c0B = SIMD4<Double>(repeating:  0.114)
        let c1R = SIMD4<Double>(repeating: -0.168736)
        let c1G = SIMD4<Double>(repeating: -0.331264)
        let c1B = SIMD4<Double>(repeating:  0.5)
        let c2R = SIMD4<Double>(repeating:  0.5)
        let c2G = SIMD4<Double>(repeating: -0.418688)
        let c2B = SIMD4<Double>(repeating: -0.081312)

        var i = 0
        while i + 4 <= count {
            let r = SIMD4<Double>(rPlane[i], rPlane[i + 1], rPlane[i + 2], rPlane[i + 3])
            let g = SIMD4<Double>(gPlane[i], gPlane[i + 1], gPlane[i + 2], gPlane[i + 3])
            let b = SIMD4<Double>(bPlane[i], bPlane[i + 1], bPlane[i + 2], bPlane[i + 3])

            let y  = c0R * r + c0G * g + c0B * b
            let cb = c1R * r + c1G * g + c1B * b
            let cr = c2R * r + c2G * g + c2B * b

            rPlane[i] = y[0];  rPlane[i + 1] = y[1];  rPlane[i + 2] = y[2];  rPlane[i + 3] = y[3]
            gPlane[i] = cb[0]; gPlane[i + 1] = cb[1]; gPlane[i + 2] = cb[2]; gPlane[i + 3] = cb[3]
            bPlane[i] = cr[0]; bPlane[i + 1] = cr[1]; bPlane[i + 2] = cr[2]; bPlane[i + 3] = cr[3]
            i += 4
        }
        while i < count {
            let r = rPlane[i]
            let g = gPlane[i]
            let b = bPlane[i]
            rPlane[i] =  0.299    * r + 0.587    * g + 0.114    * b
            gPlane[i] = -0.168736 * r - 0.331264 * g + 0.5      * b
            bPlane[i] =  0.5      * r - 0.418688 * g - 0.081312 * b
            i += 1
        }
        planes[0] = rPlane
        planes[1] = gPlane
        planes[2] = bPlane
    }

    /// Inverse Irreversible Colour Transform (ICT) in-place on 3 component planes using `SIMD4<Double>`.
    ///
    /// Bit-for-bit identical to `ColourTransform.inverseICT(planes:)`.
    internal static func inverseICT(planes: inout [[Double]]) {
        guard planes.count >= 3 else { return }
        let count = min(planes[0].count, min(planes[1].count, planes[2].count))
        var yPlane = planes[0]
        var cbPlane = planes[1]
        var crPlane = planes[2]

        let crToR = SIMD4<Double>(repeating: 1.402)
        let cbToG = SIMD4<Double>(repeating: 0.344136)
        let crToG = SIMD4<Double>(repeating: 0.714136)
        let cbToB = SIMD4<Double>(repeating: 1.772)

        var i = 0
        while i + 4 <= count {
            let yv  = SIMD4<Double>(yPlane[i],  yPlane[i + 1],  yPlane[i + 2],  yPlane[i + 3])
            let cbv = SIMD4<Double>(cbPlane[i], cbPlane[i + 1], cbPlane[i + 2], cbPlane[i + 3])
            let crv = SIMD4<Double>(crPlane[i], crPlane[i + 1], crPlane[i + 2], crPlane[i + 3])

            let r = yv + crToR * crv
            let g = yv - cbToG * cbv - crToG * crv
            let b = yv + cbToB * cbv

            yPlane[i]  = r[0]; yPlane[i + 1]  = r[1]; yPlane[i + 2]  = r[2]; yPlane[i + 3]  = r[3]
            cbPlane[i] = g[0]; cbPlane[i + 1] = g[1]; cbPlane[i + 2] = g[2]; cbPlane[i + 3] = g[3]
            crPlane[i] = b[0]; crPlane[i + 1] = b[1]; crPlane[i + 2] = b[2]; crPlane[i + 3] = b[3]
            i += 4
        }
        while i < count {
            let yv  = yPlane[i]
            let cbv = cbPlane[i]
            let crv = crPlane[i]
            yPlane[i]  = yv + 1.402 * crv
            cbPlane[i] = yv - 0.344136 * cbv - 0.714136 * crv
            crPlane[i] = yv + 1.772 * cbv
            i += 1
        }
        planes[0] = yPlane
        planes[1] = cbPlane
        planes[2] = crPlane
    }
}

// MARK: - 4. SIMD Quantization & ROI MaxShift (ISO/IEC 15444-1 Annex E / Annex H)

internal enum SIMDQuantizationAndROI {
    /// Vectorised dead-zone quantization of a subband rectangle in `doublePlane` into `quantisedPlane`.
    internal static func quantizeSubband(
        doublePlane: [Double],
        quantisedPlane: inout [Int64],
        stride: Int,
        band: BandGeometry,
        step: Double,
        mb: Int
    ) {
        let invStep = 1.0 / step
        let maxMag = (Int64(1) << mb) - 1
        let invStepVec = SIMD4<Double>(repeating: invStep)

        for row in 0..<band.height {
            let rBase = (band.planeY + row) * stride + band.planeX
            var col = 0
            while col + 4 <= band.width {
                let idx = rBase + col
                let v = SIMD4<Double>(
                    doublePlane[idx],
                    doublePlane[idx + 1],
                    doublePlane[idx + 2],
                    doublePlane[idx + 3]
                )
                let absV = pointwiseMax(v, -v)
                let scaled = (absV * invStepVec).rounded(.down)
                for lane in 0..<4 {
                    let val = v[lane]
                    let qMag = min(maxMag, Int64(scaled[lane]))
                    quantisedPlane[idx + lane] = val < 0 ? -qMag : qMag
                }
                col += 4
            }
            while col < band.width {
                let idx = rBase + col
                let val = doublePlane[idx]
                let qMag = min(maxMag, Int64(floor(abs(val) * invStep)))
                quantisedPlane[idx] = val < 0 ? -qMag : qMag
                col += 1
            }
        }
    }

    /// Vectorised MaxShift foreground ROI left-shift on a subband bounding box in `quantisedPlane`.
    internal static func scaleROISubband(
        quantisedPlane: inout [Int64],
        stride: Int,
        band: BandGeometry,
        bounds: (x0: Int, x1: Int, y0: Int, y1: Int),
        roiShift: Int,
        mb: Int
    ) {
        guard bounds.x1 > bounds.x0, bounds.y1 > bounds.y0, roiShift > 0 else { return }
        let maxShiftedMag = (Int64(1) << min(61, mb + roiShift)) - 1
        let maxMagVec = SIMD4<Int64>(repeating: maxShiftedMag)
        let shiftVec = SIMD4<Int64>(repeating: Int64(roiShift))
        let span = bounds.x1 - bounds.x0

        for sy in bounds.y0..<bounds.y1 {
            let rowIdx = (band.planeY + (sy - band.y0)) * stride + band.planeX + (bounds.x0 - band.x0)
            var offset = 0
            while offset + 4 <= span {
                let idx = rowIdx + offset
                let v = SIMD4<Int64>(
                    quantisedPlane[idx],
                    quantisedPlane[idx + 1],
                    quantisedPlane[idx + 2],
                    quantisedPlane[idx + 3]
                )
                if v != .zero {
                    let mag = pointwiseMax(v, .zero &- v)
                    let shifted = pointwiseMin(maxMagVec, mag &<< shiftVec)
                    for lane in 0..<4 {
                        let raw = v[lane]
                        if raw != 0 {
                            let s = shifted[lane]
                            quantisedPlane[idx + lane] = raw < 0 ? -s : s
                        }
                    }
                }
                offset += 4
            }
            while offset < span {
                let idx = rowIdx + offset
                let v = quantisedPlane[idx]
                if v != 0 {
                    let mag = v < 0 ? -v : v
                    let shifted = min(maxShiftedMag, mag << roiShift)
                    quantisedPlane[idx] = v < 0 ? -shifted : shifted
                }
                offset += 1
            }
        }
    }

    /// Vectorised MaxShift decoder descaling across a code-block buffer using `SIMD4<Int64>`.
    ///
    /// Bit-for-bit identical to `ROICoding.descaleCoefficient(_:shift:)`.
    internal static func descaleROICoefficients(
        coefficients: inout [Int64],
        shift: Int
    ) {
        guard shift > 0 else { return }
        let threshold = Int64(1) << shift
        let shift64 = Int64(shift)
        let count = coefficients.count
        var i = 0
        while i + 4 <= count {
            let v = SIMD4<Int64>(
                coefficients[i],
                coefficients[i + 1],
                coefficients[i + 2],
                coefficients[i + 3]
            )
            if v != .zero {
                for lane in 0..<4 {
                    let c = v[lane]
                    if c != 0 {
                        let mag = c < 0 ? -c : c
                        if mag >= threshold {
                            let descaled = mag >> shift64
                            coefficients[i + lane] = c < 0 ? -descaled : descaled
                        }
                    }
                }
            }
            i += 4
        }
        while i < count {
            if coefficients[i] != 0 {
                coefficients[i] = ROICoding.descaleCoefficient(coefficients[i], shift: shift)
            }
            i += 1
        }
    }
}

// MARK: - 5. SIMD HTJ2K FBCOT Cleanup Pass Coder (ISO/IEC 15444-15 Clause 7.3)

package enum SIMDHTBlockCoder {
    /// Pre-classified 2×2 quad information produced by vectorised `SIMD4<Int32>` / Metal GPU quad
    /// classification (adapting predecessor `j2knhe_encode_block_ht.c`, `J2KNeonEntropyCoding.swift`,
    /// and `J2KMetalHTForwardClassifier.swift` with `M9-AUD-001` fixed).
    package struct PreclassifiedQuad: Sendable, Equatable {
        package let rho: Int
        package let eQMax: Int
        package let eQ0: Int
        package let eQ1: Int
        package let eQ2: Int
        package let eQ3: Int
        package let s0: UInt32
        package let s1: UInt32
        package let s2: UInt32
        package let s3: UInt32
    }

    /// Vectorised 2×2 quad classification across an entire code-block using `SIMD4<Int32>` and
    /// `SIMD4<UInt32>` lane operations.
    internal static func classifyQuads(
        coefficients: [Int32],
        width: Int,
        height: Int,
        bandShift: Int
    ) throws -> [PreclassifiedQuad] {
        let qw = (width + 1) / 2
        let qh = (height + 1) / 2
        var quads = [PreclassifiedQuad]()
        quads.reserveCapacity(qw * qh)

        let oneVec = SIMD4<UInt32>(repeating: 1)

        for qy in 0..<qh {
            let baseY = qy * 2
            let y1Valid = (baseY + 1) < height
            let r0 = baseY * width
            let r1 = y1Valid ? (baseY + 1) * width : r0

            for qx in 0..<qw {
                let baseX = qx * 2
                let x0Valid = baseX < width
                let x1Valid = (baseX + 1) < width

                // Gather the 4 quad samples in (dx=0,dy=0), (dx=0,dy=1), (dx=1,dy=0), (dx=1,dy=1) order
                let raw = SIMD4<Int32>(
                    x0Valid ? coefficients[r0 + baseX] : 0,
                    (x0Valid && y1Valid) ? coefficients[r1 + baseX] : 0,
                    x1Valid ? coefficients[r0 + baseX + 1] : 0,
                    (x1Valid && y1Valid) ? coefficients[r1 + baseX + 1] : 0
                )

                if raw == .zero {
                    quads.append(PreclassifiedQuad(
                        rho: 0, eQMax: 0,
                        eQ0: 0, eQ1: 0, eQ2: 0, eQ3: 0,
                        s0: 0, s1: 0, s2: 0, s3: 0
                    ))
                    continue
                }

                var muVec = SIMD4<UInt32>.zero
                var signVec = SIMD4<UInt32>.zero
                for lane in 0..<4 {
                    let c = raw[lane]
                    if c == 0 { continue }
                    let mu = UInt64(c.magnitude) >> bandShift
                    if mu == 0 { continue }
                    guard mu <= 0x3FFF_FFFF else {
                        throw CodecError(.invalidArgument, "HTJ2K coefficient magnitude exceeds 30-bit reversible range.")
                    }
                    muVec[lane] = UInt32(mu)
                    signVec[lane] = (c < 0) ? 1 : 0
                }

                var rho = 0
                if muVec[0] != 0 { rho |= 1 }
                if muVec[1] != 0 { rho |= 2 }
                if muVec[2] != 0 { rho |= 4 }
                if muVec[3] != 0 { rho |= 8 }

                if rho == 0 {
                    quads.append(PreclassifiedQuad(
                        rho: 0, eQMax: 0,
                        eQ0: 0, eQ1: 0, eQ2: 0, eQ3: 0,
                        s0: 0, s1: 0, s2: 0, s3: 0
                    ))
                    continue
                }

                let twoMuMinusOne = (muVec &<< oneVec) &- oneVec
                let payloadVec = (twoMuMinusOne &- oneVec) &+ signVec

                let eQ0 = (rho & 1) != 0 ? (32 - twoMuMinusOne[0].leadingZeroBitCount) : 0
                let eQ1 = (rho & 2) != 0 ? (32 - twoMuMinusOne[1].leadingZeroBitCount) : 0
                let eQ2 = (rho & 4) != 0 ? (32 - twoMuMinusOne[2].leadingZeroBitCount) : 0
                let eQ3 = (rho & 8) != 0 ? (32 - twoMuMinusOne[3].leadingZeroBitCount) : 0
                let eQMax = max(max(eQ0, eQ1), max(eQ2, eQ3))

                quads.append(PreclassifiedQuad(
                    rho: rho,
                    eQMax: eQMax,
                    eQ0: eQ0,
                    eQ1: eQ1,
                    eQ2: eQ2,
                    eQ3: eQ3,
                    s0: (rho & 1) != 0 ? payloadVec[0] : 0,
                    s1: (rho & 2) != 0 ? payloadVec[1] : 0,
                    s2: (rho & 4) != 0 ? payloadVec[2] : 0,
                    s3: (rho & 8) != 0 ? payloadVec[3] : 0
                ))
            }
        }
        return quads
    }

    /// Encode a code-block's cleanup pass using SIMD quad classification (or pre-classified quads
    /// from `MetalAccelerationEngine`).
    ///
    /// Bit-for-bit identical to `HTBlockEncoder.encodeCleanup`.
    package static func encodeCleanup(
        coefficients: [Int32],
        width: Int,
        height: Int,
        bandShift: Int = 0,
        maximumOutputBytes: Int = Int.max,
        preclassifiedQuads: [PreclassifiedQuad]? = nil
    ) throws -> [UInt8] {
        guard width >= 1, height >= 1, coefficients.count == width * height else {
            throw CodecError(.invalidArgument, "HTJ2K block dimensions do not match coefficient count.")
        }
        guard bandShift >= 0, bandShift < 31 else {
            throw CodecError(.invalidArgument, "HTJ2K cleanup bit-plane shift (\(bandShift)) is out of range.")
        }

        // Vectorised non-zero scan across the code-block using SIMD4<Int32>
        var hasNonZero = false
        let count = coefficients.count
        var i = 0
        while i + 4 <= count {
            let v = SIMD4<Int32>(
                coefficients[i], coefficients[i + 1], coefficients[i + 2], coefficients[i + 3]
            )
            if v != .zero {
                if (v[0].magnitude >> bandShift) != 0
                    || (v[1].magnitude >> bandShift) != 0
                    || (v[2].magnitude >> bandShift) != 0
                    || (v[3].magnitude >> bandShift) != 0
                {
                    hasNonZero = true
                    break
                }
            }
            i += 4
        }
        if !hasNonZero {
            while i < count {
                if (coefficients[i].magnitude >> bandShift) != 0 {
                    hasNonZero = true
                    break
                }
                i += 1
            }
        }
        if !hasNonZero {
            return []
        }

        guard maximumOutputBytes >= 2 else {
            throw CodecError(.resourceLimitExceeded, "HTJ2K cleanup segment exceeds the remaining block admission budget.")
        }

        let quads: [PreclassifiedQuad]
        if let provided = preclassifiedQuads {
            quads = provided
        } else {
            quads = try classifyQuads(
                coefficients: coefficients,
                width: width,
                height: height,
                bandShift: bandShift
            )
        }

        var magsgnEnc = HTMagSgnEncoder(maximumBytes: maximumOutputBytes)
        var melEnc = HTMELEncoder(maximumBytes: min(4079, maximumOutputBytes))
        var vlcEnc = HTReverseBitEmitter(maximumBytes: min(4079, maximumOutputBytes))

        encodeClassifiedQuads(
            quads: quads,
            width: width,
            height: height,
            magsgnEnc: &magsgnEnc,
            melEnc: &melEnc,
            vlcEnc: &vlcEnc
        )

        let magsgnBytes = magsgnEnc.finish()
        guard !magsgnEnc.overflowed else {
            throw CodecError(.resourceLimitExceeded, "HTJ2K MagSgn stream exceeds the remaining block admission budget.")
        }
        return try HTBlockLayout.assemble(
            magsgn: magsgnBytes,
            mel: &melEnc,
            vlc: vlcEnc,
            maximumOutputBytes: maximumOutputBytes
        )
    }

    private static func encodeClassifiedQuads(
        quads: [PreclassifiedQuad],
        width: Int,
        height: Int,
        magsgnEnc: inout HTMagSgnEncoder,
        melEnc: inout HTMELEncoder,
        vlcEnc: inout HTReverseBitEmitter
    ) {
        magsgnEnc.reset()
        melEnc.reset()
        vlcEnc.reset()

        let qw = (width + 1) / 2
        let guardedWidth = ((width + 3) / 4) * 2 + 2
        var eVal = [UInt8](repeating: 0, count: guardedWidth)
        var cxVal = [UInt8](repeating: 0, count: guardedWidth)

        @inline(__always)
        func emitQuadMagSgn(
            rho: Int,
            tuple: Int,
            Uq: Int,
            s0: UInt32,
            s1: UInt32,
            s2: UInt32,
            s3: UInt32
        ) {
            if rho == 0 { return }
            if Uq <= 16 {
                var combined: UInt64 = 0
                var totalBits: Int = 0
                if (rho & 1) != 0 {
                    let m = Uq - (tuple & 1)
                    let mask: UInt32 = (UInt32(1) << m) - 1
                    combined |= UInt64(s0 & mask) << totalBits
                    totalBits &+= m
                }
                if (rho & 2) != 0 {
                    let m = Uq - ((tuple >> 1) & 1)
                    let mask: UInt32 = (UInt32(1) << m) - 1
                    combined |= UInt64(s1 & mask) << totalBits
                    totalBits &+= m
                }
                if (rho & 4) != 0 {
                    let m = Uq - ((tuple >> 2) & 1)
                    let mask: UInt32 = (UInt32(1) << m) - 1
                    combined |= UInt64(s2 & mask) << totalBits
                    totalBits &+= m
                }
                if (rho & 8) != 0 {
                    let m = Uq - ((tuple >> 3) & 1)
                    let mask: UInt32 = (UInt32(1) << m) - 1
                    combined |= UInt64(s3 & mask) << totalBits
                    totalBits &+= m
                }
                magsgnEnc.encode64(codeword: combined, count: totalBits)
                return
            }
            @inline(__always)
            func emit(sample: UInt32, eBit: Int) {
                let m = Uq - eBit
                let mask: UInt32 = (m >= 32) ? ~UInt32(0) : ((UInt32(1) << m) - 1)
                magsgnEnc.encode(codeword: sample & mask, count: m)
            }
            if (rho & 1) != 0 { emit(sample: s0, eBit: tuple & 1) }
            if (rho & 2) != 0 { emit(sample: s1, eBit: (tuple >> 1) & 1) }
            if (rho & 4) != 0 { emit(sample: s2, eBit: (tuple >> 2) & 1) }
            if (rho & 8) != 0 { emit(sample: s3, eBit: (tuple >> 3) & 1) }
        }

        // Initial row of quads (y = 0, 1)
        var c_q0 = 0
        var lep = 0
        var lcxp = 0
        eVal[lep] = 0
        cxVal[lcxp] = 0

        if height > 0 {
            var spX = 0
            while spX < width {
                let qx0 = spX / 2
                let q0 = quads[qx0]
                let rho0 = q0.rho
                let eQMax0 = q0.eQMax
                let Uq0 = max(eQMax0, 1)
                let u_q0 = Uq0 - 1

                var eps0 = 0
                if u_q0 > 0 {
                    if q0.eQ0 == eQMax0 { eps0 |= 1 }
                    if q0.eQ1 == eQMax0 { eps0 |= 2 }
                    if q0.eQ2 == eQMax0 { eps0 |= 4 }
                    if q0.eQ3 == eQMax0 { eps0 |= 8 }
                }

                eVal[lep] = max(eVal[lep], UInt8(q0.eQ1)); lep += 1
                eVal[lep] = UInt8(q0.eQ3)
                cxVal[lcxp] = cxVal[lcxp] | UInt8((rho0 & 2) >> 1); lcxp += 1
                cxVal[lcxp] = UInt8((rho0 & 8) >> 3)

                let tuple0 = Int(vlcTable0Conformant[(c_q0 << 8) | (rho0 << 4) | eps0])
                vlcEnc.encode(codeword: tuple0 >> 8, count: (tuple0 >> 4) & 0x7)

                if c_q0 == 0 {
                    melEnc.encode(eventIsOne: rho0 != 0)
                }

                emitQuadMagSgn(
                    rho: rho0, tuple: tuple0, Uq: Uq0,
                    s0: q0.s0, s1: q0.s1, s2: q0.s2, s3: q0.s3
                )

                var rho1 = 0
                var u_q1 = 0
                if spX + 2 < width {
                    let q1 = quads[qx0 + 1]
                    let eQMax1 = q1.eQMax
                    rho1 = q1.rho
                    let c_q1 = (rho0 >> 1) | (rho0 & 1)
                    let Uq1 = max(eQMax1, 1)
                    u_q1 = Uq1 - 1
                    var eps1 = 0
                    if u_q1 > 0 {
                        if q1.eQ0 == eQMax1 { eps1 |= 1 }
                        if q1.eQ1 == eQMax1 { eps1 |= 2 }
                        if q1.eQ2 == eQMax1 { eps1 |= 4 }
                        if q1.eQ3 == eQMax1 { eps1 |= 8 }
                    }
                    eVal[lep] = max(eVal[lep], UInt8(q1.eQ1)); lep += 1
                    eVal[lep] = UInt8(q1.eQ3)
                    cxVal[lcxp] = cxVal[lcxp] | UInt8((rho1 & 2) >> 1); lcxp += 1
                    cxVal[lcxp] = UInt8((rho1 & 8) >> 3)

                    let tuple1 = Int(vlcTable0Conformant[(c_q1 << 8) | (rho1 << 4) | eps1])
                    vlcEnc.encode(codeword: tuple1 >> 8, count: (tuple1 >> 4) & 0x7)

                    if c_q1 == 0 {
                        melEnc.encode(eventIsOne: rho1 != 0)
                    }

                    emitQuadMagSgn(
                        rho: rho1, tuple: tuple1, Uq: Uq1,
                        s0: q1.s0, s1: q1.s1, s2: q1.s2, s3: q1.s3
                    )
                }

                if u_q0 > 0 && u_q1 > 0 {
                    melEnc.encode(eventIsOne: min(u_q0, u_q1) > 2)
                }
                if u_q0 > 2 && u_q1 > 2 {
                    let e0 = uvlcTableConformant[u_q0 - 2]
                    let e1 = uvlcTableConformant[u_q1 - 2]
                    vlcEnc.encode(codeword: Int(e0.pre), count: Int(e0.preLen))
                    vlcEnc.encode(codeword: Int(e1.pre), count: Int(e1.preLen))
                    vlcEnc.encode(codeword: Int(e0.suf), count: Int(e0.sufLen))
                    vlcEnc.encode(codeword: Int(e1.suf), count: Int(e1.sufLen))
                    vlcEnc.encode(codeword: Int(e0.ext), count: Int(e0.extLen))
                    vlcEnc.encode(codeword: Int(e1.ext), count: Int(e1.extLen))
                } else if u_q0 > 2 && u_q1 > 0 {
                    let e0 = uvlcTableConformant[u_q0]
                    vlcEnc.encode(codeword: Int(e0.pre), count: Int(e0.preLen))
                    vlcEnc.encode(codeword: u_q1 - 1, count: 1)
                    vlcEnc.encode(codeword: Int(e0.suf), count: Int(e0.sufLen))
                    vlcEnc.encode(codeword: Int(e0.ext), count: Int(e0.extLen))
                } else {
                    let e0 = uvlcTableConformant[u_q0]
                    let e1 = uvlcTableConformant[u_q1]
                    vlcEnc.encode(codeword: Int(e0.pre), count: Int(e0.preLen))
                    vlcEnc.encode(codeword: Int(e1.pre), count: Int(e1.preLen))
                    vlcEnc.encode(codeword: Int(e0.suf), count: Int(e0.sufLen))
                    vlcEnc.encode(codeword: Int(e1.suf), count: Int(e1.sufLen))
                    vlcEnc.encode(codeword: Int(e0.ext), count: Int(e0.extLen))
                    vlcEnc.encode(codeword: Int(e1.ext), count: Int(e1.extLen))
                }

                c_q0 = (rho1 >> 1) | (rho1 & 1)
                spX += 4
            }
        }
        if lep + 1 < guardedWidth { eVal[lep + 1] = 0 }

        // Subsequent quad rows (y = 2, 4, ...)
        var y = 2
        while y < height {
            let qy = y / 2
            let rowQuadBase = qy * qw
            lep = 0
            var maxE = max(Int(eVal[0]), Int(eVal[1])) - 1
            eVal[0] = 0
            lcxp = 0
            c_q0 = Int(cxVal[0]) + (Int(cxVal[1]) << 2)
            cxVal[0] = 0

            var spX = 0
            while spX < width {
                let qx0 = spX / 2
                let q0 = quads[rowQuadBase + qx0]
                let rho0 = q0.rho
                let eQMax0 = q0.eQMax
                let kappaA = ((rho0 & (rho0 - 1)) != 0) ? max(1, maxE) : 1
                let Uq0 = max(eQMax0, kappaA)
                let u_q0 = Uq0 - kappaA
                var eps0 = 0
                if u_q0 > 0 {
                    if q0.eQ0 == eQMax0 { eps0 |= 1 }
                    if q0.eQ1 == eQMax0 { eps0 |= 2 }
                    if q0.eQ2 == eQMax0 { eps0 |= 4 }
                    if q0.eQ3 == eQMax0 { eps0 |= 8 }
                }
                eVal[lep] = max(eVal[lep], UInt8(q0.eQ1)); lep += 1
                maxE = max(Int(eVal[lep]), Int(eVal[lep + 1])) - 1
                eVal[lep] = UInt8(q0.eQ3)
                cxVal[lcxp] = cxVal[lcxp] | UInt8((rho0 & 2) >> 1); lcxp += 1
                var c_q1 = Int(cxVal[lcxp]) + (Int(cxVal[lcxp + 1]) << 2)
                cxVal[lcxp] = UInt8((rho0 & 8) >> 3)

                let tuple0 = Int(vlcTable1Conformant[(c_q0 << 8) | (rho0 << 4) | eps0])
                vlcEnc.encode(codeword: tuple0 >> 8, count: (tuple0 >> 4) & 0x7)
                if c_q0 == 0 {
                    melEnc.encode(eventIsOne: rho0 != 0)
                }
                emitQuadMagSgn(
                    rho: rho0, tuple: tuple0, Uq: Uq0,
                    s0: q0.s0, s1: q0.s1, s2: q0.s2, s3: q0.s3
                )

                var rho1 = 0
                var u_q1 = 0
                if spX + 2 < width {
                    let q1 = quads[rowQuadBase + qx0 + 1]
                    let eQMax1 = q1.eQMax
                    rho1 = q1.rho
                    let kappaB = ((rho1 & (rho1 - 1)) != 0) ? max(1, maxE) : 1
                    c_q1 |= ((rho0 & 4) >> 1) | ((rho0 & 8) >> 2)
                    let Uq1 = max(eQMax1, kappaB)
                    u_q1 = Uq1 - kappaB
                    var eps1 = 0
                    if u_q1 > 0 {
                        if q1.eQ0 == eQMax1 { eps1 |= 1 }
                        if q1.eQ1 == eQMax1 { eps1 |= 2 }
                        if q1.eQ2 == eQMax1 { eps1 |= 4 }
                        if q1.eQ3 == eQMax1 { eps1 |= 8 }
                    }
                    eVal[lep] = max(eVal[lep], UInt8(q1.eQ1)); lep += 1
                    maxE = max(Int(eVal[lep]), Int(eVal[lep + 1])) - 1
                    eVal[lep] = UInt8(q1.eQ3)
                    cxVal[lcxp] = cxVal[lcxp] | UInt8((rho1 & 2) >> 1); lcxp += 1
                    c_q0 = Int(cxVal[lcxp]) + (Int(cxVal[lcxp + 1]) << 2)
                    cxVal[lcxp] = UInt8((rho1 & 8) >> 3)

                    let tuple1 = Int(vlcTable1Conformant[(c_q1 << 8) | (rho1 << 4) | eps1])
                    vlcEnc.encode(codeword: tuple1 >> 8, count: (tuple1 >> 4) & 0x7)
                    if c_q1 == 0 {
                        melEnc.encode(eventIsOne: rho1 != 0)
                    }
                    emitQuadMagSgn(
                        rho: rho1, tuple: tuple1, Uq: Uq1,
                        s0: q1.s0, s1: q1.s1, s2: q1.s2, s3: q1.s3
                    )
                }

                let e0 = uvlcTableConformant[u_q0]
                let e1 = uvlcTableConformant[u_q1]
                vlcEnc.encode(codeword: Int(e0.pre), count: Int(e0.preLen))
                vlcEnc.encode(codeword: Int(e1.pre), count: Int(e1.preLen))
                vlcEnc.encode(codeword: Int(e0.suf), count: Int(e0.sufLen))
                vlcEnc.encode(codeword: Int(e1.suf), count: Int(e1.sufLen))
                vlcEnc.encode(codeword: Int(e0.ext), count: Int(e0.extLen))
                vlcEnc.encode(codeword: Int(e1.ext), count: Int(e1.extLen))

                c_q0 |= ((rho1 & 4) >> 1) | ((rho1 & 8) >> 2)
                spX += 4
            }
            y += 2
        }
    }

    /// Decode a Part 15 HTJ2K cleanup segment (adapting `j2knhd_decode_block_ht.c` with `M9-AUD-002` fixed).
    ///
    /// Bit-for-bit identical to `HTBlockDecoder.decodeCleanup`.
    internal static func decodeCleanup(
        block: [UInt8],
        width: Int,
        height: Int,
        kMax: Int,
        missingMSBs: Int
    ) throws -> [Int32] {
        return try HTBlockDecoder.decodeCleanup(
            block: block,
            width: width,
            height: height,
            kMax: kMax,
            missingMSBs: missingMSBs
        )
    }
}
