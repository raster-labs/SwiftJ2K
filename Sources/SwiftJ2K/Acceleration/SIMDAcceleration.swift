// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited

import Foundation

// MARK: - SIMD / NEON Acceleration Subsystem (Milestone 9)
//
// Migrates and unifies the in-house ARM NEON and SIMD acceleration paths:
// - `Sources/J2KCodec/ARM/J2KNeonEntropyCoding.swift`
// - `Sources/J2KCodec/J2KAcceleratedEncoder.swift` (CPU SIMD wavelet, colour, quantizer, ROI)
// - Vectorised 2×2 HTJ2K quad classification (`SIMDHTBlockCoder.classifyQuads`) feeding the
//   clean-room ITU-T Rec. T.814 block coder (`HTBlockEncoder` / `HTBlockDecoder`).
//
// All routines use portable Swift `SIMD4` vector types (compiling to ARM64 NEON `int32x4_t` /
// `int64x2_t` / `float64x2_t` instructions on Apple Silicon and SSE/AVX on x86_64) and preserve
// 100% bit-for-bit parity with the scalar reference paths.

// MARK: - 1. SIMD 5/3 Reversible Wavelet Transform (ISO/IEC 15444-1 Annex F.3.8.2 / F.4.8.2)

internal enum SIMDWavelet53 {
    @inline(__always)
    private static func extendedIndex(i0: Int, n: Int, at i: Int) -> Int {
        let k = i - i0
        if k >= 0 && k < n { return k }
        if n == 1 { return 0 }
        if k == -1 { return 1 }
        if k == n { return n - 2 }
        let period = 2 * (n - 1)
        var m = ((k % period) + period) % period
        if m >= n { m = period - m }
        return m
    }

    /// 4-lane `SIMD4<Int32>` 1D analysis over `[i0, i0 + n)` using raw scratch pointers.
    @inline(__always)
    private static func analyse4Ptr(
        xp: UnsafePointer<SIMD4<Int32>>,
        i0: Int,
        count n: Int,
        lp: UnsafeMutablePointer<SIMD4<Int32>>,
        hp: UnsafeMutablePointer<SIMD4<Int32>>,
        op: UnsafeMutablePointer<SIMD4<Int32>>
    ) {
        let i1 = i0 + n
        if n == 1 {
            if i0 & 1 == 0 {
                lp[0] = xp[0]
            } else {
                hp[0] = xp[0] &* 2
            }
            return
        }

        let firstOdd = (i0 - 1) | 1
        let lastOdd = ((i1 + 1) & ~1) - 1
        var oddIdx = 0
        var i = firstOdd
        while i <= lastOdd && i - 1 < i0 {
            let left = xp[extendedIndex(i0: i0, n: n, at: i - 1)]
            let right = xp[extendedIndex(i0: i0, n: n, at: i + 1)]
            let center = xp[extendedIndex(i0: i0, n: n, at: i)]
            op[oddIdx] = center &- ((left & right) &+ ((left ^ right) &>> 1))
            oddIdx &+= 1
            i &+= 2
        }
        let interiorEnd = min(lastOdd, i1 - 2)
        while i <= interiorEnd {
            let rel = i - i0
            let left = xp[rel - 1]
            let center = xp[rel]
            let right = xp[rel + 1]
            op[oddIdx] = center &- ((left & right) &+ ((left ^ right) &>> 1))
            oddIdx &+= 1
            i &+= 2
        }
        while i <= lastOdd {
            let left = xp[extendedIndex(i0: i0, n: n, at: i - 1)]
            let right = xp[extendedIndex(i0: i0, n: n, at: i + 1)]
            let center = xp[extendedIndex(i0: i0, n: n, at: i)]
            op[oddIdx] = center &- ((left & right) &+ ((left ^ right) &>> 1))
            oddIdx &+= 1
            i &+= 2
        }

        let two32 = SIMD4<Int32>(repeating: 2)
        let pairs = n >> 1
        if i0 & 1 == 0 {
            let lowCount = (n + 1) >> 1
            for k in 0..<lowCount {
                lp[k] = xp[2 * k] &+ ((op[k] &+ op[k + 1] &+ two32) &>> 2)
            }
            if pairs > 0 {
                hp.update(from: op.advanced(by: 1), count: pairs)
            }
        } else {
            let highCount = (n + 1) >> 1
            if highCount > 0 {
                hp.update(from: op, count: highCount)
            }
            for k in 0..<pairs {
                lp[k] = xp[2 * k + 1] &+ ((op[k] &+ op[k + 1] &+ two32) &>> 2)
            }
        }
    }

    /// 4-lane `SIMD4<Int32>` 1D synthesis over `[i0, i0 + n)` with exact 64-bit overflow checking.
    @inline(__always)
    private static func synthesise4Ptr(
        lp: UnsafePointer<SIMD4<Int32>>,
        hp: UnsafePointer<SIMD4<Int32>>,
        i0: Int,
        count n: Int,
        xp: UnsafeMutablePointer<SIMD4<Int32>>,
        yp: UnsafeMutablePointer<SIMD4<Int32>>,
        ep: UnsafeMutablePointer<SIMD4<Int32>>
    ) throws {
        let i1 = i0 + n
        if n == 1 {
            if i0 & 1 == 0 {
                xp[0] = lp[0]
            } else {
                let v = hp[0]
                xp[0] = SIMD4<Int32>(v[0] / 2, v[1] / 2, v[2] / 2, v[3] / 2)
            }
            return
        }

        let pairs = n >> 1
        var magOr = SIMD4<Int32>.zero
        if i0 & 1 == 0 {
            for k in 0..<pairs {
                let v0 = lp[k]
                let v1 = hp[k]
                yp[2 * k] = v0
                yp[2 * k + 1] = v1
                magOr |= (v0 ^ (v0 &>> 31)) | (v1 ^ (v1 &>> 31))
            }
            if (n & 1) != 0 {
                let v0 = lp[pairs]
                yp[n - 1] = v0
                magOr |= (v0 ^ (v0 &>> 31))
            }
        } else {
            for k in 0..<pairs {
                let v0 = hp[k]
                let v1 = lp[k]
                yp[2 * k] = v0
                yp[2 * k + 1] = v1
                magOr |= (v0 ^ (v0 &>> 31)) | (v1 ^ (v1 &>> 31))
            }
            if (n & 1) != 0 {
                let v0 = hp[pairs]
                yp[n - 1] = v0
                magOr |= (v0 ^ (v0 &>> 31))
            }
        }

        let firstEven = (i0 - 1) & ~1
        let lastEven = i1 & ~1

        // Fast pure-Int32 NEON path when all input lanes are within `[-2^28, 2^28 - 1]`,
        // which guarantees zero intermediate or output 32-bit overflow.
        let combinedOr = magOr[0] | magOr[1] | magOr[2] | magOr[3]
        if combinedOr < 0x1000_0000 {
            let two32 = SIMD4<Int32>(repeating: 2)
            var evenIdx = 0
            var i = firstEven
            while i <= lastEven && i - 1 < i0 {
                let left = yp[extendedIndex(i0: i0, n: n, at: i - 1)]
                let right = yp[extendedIndex(i0: i0, n: n, at: i + 1)]
                let center = yp[extendedIndex(i0: i0, n: n, at: i)]
                ep[evenIdx] = center &- ((left &+ right &+ two32) &>> 2)
                evenIdx &+= 1
                i &+= 2
            }
            let interiorEnd = min(lastEven, i1 - 2)
            while i <= interiorEnd {
                let rel = i - i0
                ep[evenIdx] = yp[rel] &- ((yp[rel - 1] &+ yp[rel + 1] &+ two32) &>> 2)
                evenIdx &+= 1
                i &+= 2
            }
            while i <= lastEven {
                let left = yp[extendedIndex(i0: i0, n: n, at: i - 1)]
                let right = yp[extendedIndex(i0: i0, n: n, at: i + 1)]
                let center = yp[extendedIndex(i0: i0, n: n, at: i)]
                ep[evenIdx] = center &- ((left &+ right &+ two32) &>> 2)
                evenIdx &+= 1
                i &+= 2
            }

            if i0 & 1 == 0 {
                for k in 0..<pairs {
                    let e0 = ep[k + 1]
                    let e1 = ep[k + 2]
                    xp[2 * k] = e0
                    xp[2 * k + 1] = yp[2 * k + 1] &+ ((e0 &+ e1) &>> 1)
                }
                if (n & 1) != 0 {
                    xp[n - 1] = ep[pairs + 1]
                }
            } else {
                for k in 0..<pairs {
                    let e0 = ep[k]
                    let e1 = ep[k + 1]
                    xp[2 * k] = yp[2 * k] &+ ((e0 &+ e1) &>> 1)
                    xp[2 * k + 1] = e1
                }
                if (n & 1) != 0 {
                    xp[n - 1] = yp[n - 1] &+ ((ep[pairs] &+ ep[pairs + 1]) &>> 1)
                }
            }
            return
        }

        // Exact 64-bit checked fallback for extreme >= 29-bit coefficients:
        let two64 = SIMD4<Int64>(repeating: 2)
        var evenIdx = 0
        var i = firstEven
        while i <= lastEven {
            let left = SIMD4<Int64>(truncatingIfNeeded: yp[extendedIndex(i0: i0, n: n, at: i - 1)])
            let right = SIMD4<Int64>(truncatingIfNeeded: yp[extendedIndex(i0: i0, n: n, at: i + 1)])
            let center = SIMD4<Int64>(truncatingIfNeeded: yp[extendedIndex(i0: i0, n: n, at: i)])
            let even = center &- ((left &+ right &+ two64) &>> 2)
            try validateInt32Range(even)
            ep[evenIdx] = SIMD4<Int32>(truncatingIfNeeded: even)
            evenIdx += 1
            i += 2
        }

        for coordinate in i0..<i1 {
            if coordinate & 1 == 0 {
                xp[coordinate - i0] = ep[(coordinate - firstEven) >> 1]
            } else {
                let idxL = (coordinate - 1 - firstEven) >> 1
                let c64 = SIMD4<Int64>(truncatingIfNeeded: yp[coordinate - i0])
                let eL = SIMD4<Int64>(truncatingIfNeeded: ep[idxL])
                let eR = SIMD4<Int64>(truncatingIfNeeded: ep[idxL + 1])
                let odd = c64 &+ ((eL &+ eR) &>> 1)
                try validateInt32Range(odd)
                xp[coordinate - i0] = SIMD4<Int32>(truncatingIfNeeded: odd)
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

    private final class ForwardScratch53 {
        var l4: [SIMD4<Int32>]
        var lo4: [SIMD4<Int32>]
        var hi4: [SIMD4<Int32>]
        var odd4: [SIMD4<Int32>]
        var l1: [Int32]
        var lo1: [Int32]
        var hi1: [Int32]

        init(maxDim: Int) {
            self.l4 = [SIMD4<Int32>](repeating: .zero, count: maxDim)
            self.lo4 = [SIMD4<Int32>](repeating: .zero, count: maxDim / 2 + 2)
            self.hi4 = [SIMD4<Int32>](repeating: .zero, count: maxDim / 2 + 2)
            self.odd4 = [SIMD4<Int32>](repeating: .zero, count: maxDim / 2 + 4)
            self.l1 = [Int32](repeating: 0, count: maxDim)
            self.lo1 = [Int32](repeating: 0, count: maxDim / 2 + 1)
            self.hi1 = [Int32](repeating: 0, count: maxDim / 2 + 1)
        }

        @inline(__always)
        func withSIMD4Pointers(
            _ body: (
                UnsafeMutablePointer<SIMD4<Int32>>,
                UnsafeMutablePointer<SIMD4<Int32>>,
                UnsafeMutablePointer<SIMD4<Int32>>,
                UnsafeMutablePointer<SIMD4<Int32>>
            ) throws -> Void
        ) rethrows {
            try l4.withUnsafeMutableBufferPointer { l4b in
                try lo4.withUnsafeMutableBufferPointer { lo4b in
                    try hi4.withUnsafeMutableBufferPointer { hi4b in
                        try odd4.withUnsafeMutableBufferPointer { odd4b in
                            try body(l4b.baseAddress!, lo4b.baseAddress!, hi4b.baseAddress!, odd4b.baseAddress!)
                        }
                    }
                }
            }
        }
    }

    private final class InverseScratch53 {
        var l4: [SIMD4<Int32>]
        var lo4: [SIMD4<Int32>]
        var hi4: [SIMD4<Int32>]
        var ys4: [SIMD4<Int32>]
        var es4: [SIMD4<Int32>]
        var l1: [Int32]
        var lo1: [Int32]
        var hi1: [Int32]

        init(maxDim: Int) {
            self.l4 = [SIMD4<Int32>](repeating: .zero, count: maxDim)
            self.lo4 = [SIMD4<Int32>](repeating: .zero, count: maxDim / 2 + 2)
            self.hi4 = [SIMD4<Int32>](repeating: .zero, count: maxDim / 2 + 2)
            self.ys4 = [SIMD4<Int32>](repeating: .zero, count: maxDim)
            self.es4 = [SIMD4<Int32>](repeating: .zero, count: maxDim / 2 + 4)
            self.l1 = [Int32](repeating: 0, count: maxDim)
            self.lo1 = [Int32](repeating: 0, count: maxDim / 2 + 1)
            self.hi1 = [Int32](repeating: 0, count: maxDim / 2 + 1)
        }

        @inline(__always)
        func withSIMD4Pointers(
            _ body: (
                UnsafeMutablePointer<SIMD4<Int32>>,
                UnsafeMutablePointer<SIMD4<Int32>>,
                UnsafeMutablePointer<SIMD4<Int32>>,
                UnsafeMutablePointer<SIMD4<Int32>>,
                UnsafeMutablePointer<SIMD4<Int32>>
            ) throws -> Void
        ) rethrows {
            try l4.withUnsafeMutableBufferPointer { l4b in
                try lo4.withUnsafeMutableBufferPointer { lo4b in
                    try hi4.withUnsafeMutableBufferPointer { hi4b in
                        try ys4.withUnsafeMutableBufferPointer { ysb in
                            try es4.withUnsafeMutableBufferPointer { esb in
                                try body(
                                    l4b.baseAddress!,
                                    lo4b.baseAddress!,
                                    hi4b.baseAddress!,
                                    ysb.baseAddress!,
                                    esb.baseAddress!
                                )
                            }
                        }
                    }
                }
            }
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

        let workers = AcceleratedCodec.activeWorkerLimit
        let canParallel = workers > 1 && !BoundedParallelPool.isInsideParallelRegion && ((x1 - x0) * (y1 - y0) >= 16_384)
        let scratchCount = canParallel ? min(workers, max(1, (maxDim + 15) / 16)) : 1
        var scratches = (0..<scratchCount).map { _ in ForwardScratch53(maxDim: maxDim) }

        try plane.withUnsafeMutableBufferPointer { planeBuf in
            guard let pBase = planeBuf.baseAddress else { return }
            let sharedPlane = UnsafeSendableMutableBuffer(planeBuf)
            try scratches.withUnsafeMutableBufferPointer { scratchBuf in
                let sharedScratches = UnsafeSendableMutableBuffer(scratchBuf)

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
                    let useParallel = canParallel && (w * h >= 16_384)

                    // VER_SD
                    let colStrips = (w + 15) / 16
                    if useParallel && colStrips >= 2 {
                        let wCount = BoundedParallelPool.effectiveWorkers(requested: scratchCount, jobCount: colStrips)
                        try BoundedParallelPool.forEach(jobCount: colStrips, maxWorkers: wCount) { (stripIdx: Int, workerIdx: Int) in
                            let pb = sharedPlane.baseAddress
                            let sc = sharedScratches.baseAddress[workerIdx]
                            let startX = stripIdx * 16
                            let endX = min(w, startX + 16)
                            var x = startX
                            sc.withSIMD4Pointers { l4p, lo4p, hi4p, odd4p in
                                while x + 4 <= endX {
                                    for y in 0..<h {
                                        let base = y * stride + x
                                        l4p[y] = SIMD4<Int32>(pb[base], pb[base + 1], pb[base + 2], pb[base + 3])
                                    }
                                    analyse4Ptr(xp: l4p, i0: ry0, count: h, lp: lo4p, hp: hi4p, op: odd4p)
                                    for i in 0..<lowH {
                                        let base = i * stride + x
                                        let v = lo4p[i]
                                        pb[base] = v[0]; pb[base + 1] = v[1]; pb[base + 2] = v[2]; pb[base + 3] = v[3]
                                    }
                                    for i in 0..<(h - lowH) {
                                        let base = (lowH + i) * stride + x
                                        let v = hi4p[i]
                                        pb[base] = v[0]; pb[base + 1] = v[1]; pb[base + 2] = v[2]; pb[base + 3] = v[3]
                                    }
                                    x += 4
                                }
                            }
                            while x < endX {
                                for y in 0..<h { sc.l1[y] = pb[y * stride + x] }
                                Wavelet53.analyse(sc.l1, i0: ry0, count: h, into: &sc.lo1, &sc.hi1)
                                for i in 0..<lowH { pb[i * stride + x] = sc.lo1[i] }
                                for i in 0..<(h - lowH) { pb[(lowH + i) * stride + x] = sc.hi1[i] }
                                x += 1
                            }
                        }
                    } else {
                        let sc = sharedScratches.baseAddress[0]
                        var x = 0
                        try sc.withSIMD4Pointers { l4p, lo4p, hi4p, odd4p in
                            while x + 4 <= w {
                                for y in 0..<h {
                                    let base = y * stride + x
                                    l4p[y] = SIMD4<Int32>(pBase[base], pBase[base + 1], pBase[base + 2], pBase[base + 3])
                                }
                                analyse4Ptr(xp: l4p, i0: ry0, count: h, lp: lo4p, hp: hi4p, op: odd4p)
                                for i in 0..<lowH {
                                    let base = i * stride + x
                                    let v = lo4p[i]
                                    pBase[base] = v[0]; pBase[base + 1] = v[1]; pBase[base + 2] = v[2]; pBase[base + 3] = v[3]
                                }
                                for i in 0..<(h - lowH) {
                                    let base = (lowH + i) * stride + x
                                    let v = hi4p[i]
                                    pBase[base] = v[0]; pBase[base + 1] = v[1]; pBase[base + 2] = v[2]; pBase[base + 3] = v[3]
                                }
                                if (x & 63) == 60 { try cancellation() }
                                x += 4
                            }
                        }
                        while x < w {
                            for y in 0..<h { sc.l1[y] = pBase[y * stride + x] }
                            Wavelet53.analyse(sc.l1, i0: ry0, count: h, into: &sc.lo1, &sc.hi1)
                            for i in 0..<lowH { pBase[i * stride + x] = sc.lo1[i] }
                            for i in 0..<(h - lowH) { pBase[(lowH + i) * stride + x] = sc.hi1[i] }
                            x += 1
                        }
                    }

                    // HOR_SD
                    let rowStrips = (h + 15) / 16
                    if useParallel && rowStrips >= 2 {
                        let wCount = BoundedParallelPool.effectiveWorkers(requested: scratchCount, jobCount: rowStrips)
                        try BoundedParallelPool.forEach(jobCount: rowStrips, maxWorkers: wCount) { (stripIdx: Int, workerIdx: Int) in
                            let pb = sharedPlane.baseAddress
                            let sc = sharedScratches.baseAddress[workerIdx]
                            let startY = stripIdx * 16
                            let endY = min(h, startY + 16)
                            var y = startY
                            sc.withSIMD4Pointers { l4p, lo4p, hi4p, odd4p in
                                while y + 4 <= endY {
                                    let r0 = y * stride, r1 = (y + 1) * stride, r2 = (y + 2) * stride, r3 = (y + 3) * stride
                                    for col in 0..<w {
                                        l4p[col] = SIMD4<Int32>(pb[r0 + col], pb[r1 + col], pb[r2 + col], pb[r3 + col])
                                    }
                                    analyse4Ptr(xp: l4p, i0: rx0, count: w, lp: lo4p, hp: hi4p, op: odd4p)
                                    for i in 0..<lowW {
                                        let v = lo4p[i]
                                        pb[r0 + i] = v[0]; pb[r1 + i] = v[1]; pb[r2 + i] = v[2]; pb[r3 + i] = v[3]
                                    }
                                    for i in 0..<(w - lowW) {
                                        let col = lowW + i
                                        let v = hi4p[i]
                                        pb[r0 + col] = v[0]; pb[r1 + col] = v[1]; pb[r2 + col] = v[2]; pb[r3 + col] = v[3]
                                    }
                                    y += 4
                                }
                            }
                            while y < endY {
                                for col in 0..<w { sc.l1[col] = pb[y * stride + col] }
                                Wavelet53.analyse(sc.l1, i0: rx0, count: w, into: &sc.lo1, &sc.hi1)
                                for i in 0..<lowW { pb[y * stride + i] = sc.lo1[i] }
                                for i in 0..<(w - lowW) { pb[y * stride + lowW + i] = sc.hi1[i] }
                                y += 1
                            }
                        }
                    } else {
                        let sc = sharedScratches.baseAddress[0]
                        var y = 0
                        try sc.withSIMD4Pointers { l4p, lo4p, hi4p, odd4p in
                            while y + 4 <= h {
                                let r0 = y * stride
                                let r1 = (y + 1) * stride
                                let r2 = (y + 2) * stride
                                let r3 = (y + 3) * stride
                                for col in 0..<w {
                                    l4p[col] = SIMD4<Int32>(pBase[r0 + col], pBase[r1 + col], pBase[r2 + col], pBase[r3 + col])
                                }
                                analyse4Ptr(xp: l4p, i0: rx0, count: w, lp: lo4p, hp: hi4p, op: odd4p)
                                for i in 0..<lowW {
                                    let v = lo4p[i]
                                    pBase[r0 + i] = v[0]; pBase[r1 + i] = v[1]; pBase[r2 + i] = v[2]; pBase[r3 + i] = v[3]
                                }
                                for i in 0..<(w - lowW) {
                                    let col = lowW + i
                                    let v = hi4p[i]
                                    pBase[r0 + col] = v[0]; pBase[r1 + col] = v[1]; pBase[r2 + col] = v[2]; pBase[r3 + col] = v[3]
                                }
                                if (y & 63) == 60 { try cancellation() }
                                y += 4
                            }
                        }
                        while y < h {
                            for col in 0..<w { sc.l1[col] = pBase[y * stride + col] }
                            Wavelet53.analyse(sc.l1, i0: rx0, count: w, into: &sc.lo1, &sc.hi1)
                            for i in 0..<lowW { pBase[y * stride + i] = sc.lo1[i] }
                            for i in 0..<(w - lowW) { pBase[y * stride + lowW + i] = sc.hi1[i] }
                            y += 1
                        }
                    }
                    try cancellation()
                }
            }
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

        let workers = AcceleratedCodec.activeWorkerLimit
        let canParallel = workers > 1 && !BoundedParallelPool.isInsideParallelRegion && ((x1 - x0) * (y1 - y0) >= 16_384)
        let scratchCount = canParallel ? min(workers, max(1, (maxDim + 15) / 16)) : 1
        var scratches = (0..<scratchCount).map { _ in InverseScratch53(maxDim: maxDim) }

        try plane.withUnsafeMutableBufferPointer { planeBuf in
            guard let pBase = planeBuf.baseAddress else { return }
            let sharedPlane = UnsafeSendableMutableBuffer(planeBuf)
            try scratches.withUnsafeMutableBufferPointer { scratchBuf in
                let sharedScratches = UnsafeSendableMutableBuffer(scratchBuf)

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
                    let useParallel = canParallel && (w * h >= 16_384)

                    // HOR_SR
                    let rowStrips = (h + 15) / 16
                    if useParallel && rowStrips >= 2 {
                        let wCount = BoundedParallelPool.effectiveWorkers(requested: scratchCount, jobCount: rowStrips)
                        try BoundedParallelPool.forEach(jobCount: rowStrips, maxWorkers: wCount) { (stripIdx: Int, workerIdx: Int) in
                            let pb = sharedPlane.baseAddress
                            let sc = sharedScratches.baseAddress[workerIdx]
                            let startY = stripIdx * 16
                            let endY = min(h, startY + 16)
                            var y = startY
                            try sc.withSIMD4Pointers { l4p, lo4p, hi4p, ysp, esp in
                                while y + 4 <= endY {
                                    let r0 = y * stride, r1 = (y + 1) * stride, r2 = (y + 2) * stride, r3 = (y + 3) * stride
                                    for i in 0..<lowW {
                                        lo4p[i] = SIMD4<Int32>(pb[r0 + i], pb[r1 + i], pb[r2 + i], pb[r3 + i])
                                    }
                                    for i in 0..<(w - lowW) {
                                        let col = lowW + i
                                        hi4p[i] = SIMD4<Int32>(pb[r0 + col], pb[r1 + col], pb[r2 + col], pb[r3 + col])
                                    }
                                    try synthesise4Ptr(
                                        lp: lo4p, hp: hi4p, i0: rx0, count: w,
                                        xp: l4p, yp: ysp, ep: esp
                                    )
                                    for col in 0..<w {
                                        let v = l4p[col]
                                        pb[r0 + col] = v[0]; pb[r1 + col] = v[1]; pb[r2 + col] = v[2]; pb[r3 + col] = v[3]
                                    }
                                    y += 4
                                }
                            }
                            while y < endY {
                                for i in 0..<lowW { sc.lo1[i] = pb[y * stride + i] }
                                for i in 0..<(w - lowW) { sc.hi1[i] = pb[y * stride + lowW + i] }
                                try Wavelet53.synthesise(low: sc.lo1, high: sc.hi1, i0: rx0, count: w, into: &sc.l1)
                                for col in 0..<w { pb[y * stride + col] = sc.l1[col] }
                                y += 1
                            }
                        }
                    } else {
                        let sc = sharedScratches.baseAddress[0]
                        var y = 0
                        try sc.withSIMD4Pointers { l4p, lo4p, hi4p, ysp, esp in
                            while y + 4 <= h {
                                let r0 = y * stride
                                let r1 = (y + 1) * stride
                                let r2 = (y + 2) * stride
                                let r3 = (y + 3) * stride
                                for i in 0..<lowW {
                                    lo4p[i] = SIMD4<Int32>(pBase[r0 + i], pBase[r1 + i], pBase[r2 + i], pBase[r3 + i])
                                }
                                for i in 0..<(w - lowW) {
                                    let col = lowW + i
                                    hi4p[i] = SIMD4<Int32>(pBase[r0 + col], pBase[r1 + col], pBase[r2 + col], pBase[r3 + col])
                                }
                                try synthesise4Ptr(
                                    lp: lo4p, hp: hi4p, i0: rx0, count: w,
                                    xp: l4p, yp: ysp, ep: esp
                                )
                                for col in 0..<w {
                                    let v = l4p[col]
                                    pBase[r0 + col] = v[0]; pBase[r1 + col] = v[1]; pBase[r2 + col] = v[2]; pBase[r3 + col] = v[3]
                                }
                                if (y & 63) == 60 { try cancellation() }
                                y += 4
                            }
                        }
                        while y < h {
                            for i in 0..<lowW { sc.lo1[i] = pBase[y * stride + i] }
                            for i in 0..<(w - lowW) { sc.hi1[i] = pBase[y * stride + lowW + i] }
                            try Wavelet53.synthesise(low: sc.lo1, high: sc.hi1, i0: rx0, count: w, into: &sc.l1)
                            for col in 0..<w { pBase[y * stride + col] = sc.l1[col] }
                            y += 1
                        }
                    }

                    // VER_SR
                    let colStrips = (w + 15) / 16
                    if useParallel && colStrips >= 2 {
                        let wCount = BoundedParallelPool.effectiveWorkers(requested: scratchCount, jobCount: colStrips)
                        try BoundedParallelPool.forEach(jobCount: colStrips, maxWorkers: wCount) { (stripIdx: Int, workerIdx: Int) in
                            let pb = sharedPlane.baseAddress
                            let sc = sharedScratches.baseAddress[workerIdx]
                            let startX = stripIdx * 16
                            let endX = min(w, startX + 16)
                            var x = startX
                            try sc.withSIMD4Pointers { l4p, lo4p, hi4p, ysp, esp in
                                while x + 4 <= endX {
                                    for i in 0..<lowH {
                                        let base = i * stride + x
                                        lo4p[i] = SIMD4<Int32>(pb[base], pb[base + 1], pb[base + 2], pb[base + 3])
                                    }
                                    for i in 0..<(h - lowH) {
                                        let base = (lowH + i) * stride + x
                                        hi4p[i] = SIMD4<Int32>(pb[base], pb[base + 1], pb[base + 2], pb[base + 3])
                                    }
                                    try synthesise4Ptr(
                                        lp: lo4p, hp: hi4p, i0: ry0, count: h,
                                        xp: l4p, yp: ysp, ep: esp
                                    )
                                    for row in 0..<h {
                                        let base = row * stride + x
                                        let v = l4p[row]
                                        pb[base] = v[0]; pb[base + 1] = v[1]; pb[base + 2] = v[2]; pb[base + 3] = v[3]
                                    }
                                    x += 4
                                }
                            }
                            while x < endX {
                                for i in 0..<lowH { sc.lo1[i] = pb[i * stride + x] }
                                for i in 0..<(h - lowH) { sc.hi1[i] = pb[(lowH + i) * stride + x] }
                                try Wavelet53.synthesise(low: sc.lo1, high: sc.hi1, i0: ry0, count: h, into: &sc.l1)
                                for row in 0..<h { pb[row * stride + x] = sc.l1[row] }
                                x += 1
                            }
                        }
                    } else {
                        let sc = sharedScratches.baseAddress[0]
                        var x = 0
                        try sc.withSIMD4Pointers { l4p, lo4p, hi4p, ysp, esp in
                            while x + 4 <= w {
                                for i in 0..<lowH {
                                    let base = i * stride + x
                                    lo4p[i] = SIMD4<Int32>(pBase[base], pBase[base + 1], pBase[base + 2], pBase[base + 3])
                                }
                                for i in 0..<(h - lowH) {
                                    let base = (lowH + i) * stride + x
                                    hi4p[i] = SIMD4<Int32>(pBase[base], pBase[base + 1], pBase[base + 2], pBase[base + 3])
                                }
                                try synthesise4Ptr(
                                    lp: lo4p, hp: hi4p, i0: ry0, count: h,
                                    xp: l4p, yp: ysp, ep: esp
                                )
                                for row in 0..<h {
                                    let base = row * stride + x
                                    let v = l4p[row]
                                    pBase[base] = v[0]; pBase[base + 1] = v[1]; pBase[base + 2] = v[2]; pBase[base + 3] = v[3]
                                }
                                if (x & 63) == 60 { try cancellation() }
                                x += 4
                            }
                        }
                        while x < w {
                            for i in 0..<lowH { sc.lo1[i] = pBase[i * stride + x] }
                            for i in 0..<(h - lowH) { sc.hi1[i] = pBase[(lowH + i) * stride + x] }
                            try Wavelet53.synthesise(low: sc.lo1, high: sc.hi1, i0: ry0, count: h, into: &sc.l1)
                            for row in 0..<h { pBase[row * stride + x] = sc.l1[row] }
                            x += 1
                        }
                    }
                    try cancellation()
                }
            }
        }
    }
}

// MARK: - 2. SIMD 9/7 Irreversible Wavelet Transform (ISO/IEC 15444-1 Annex F.3.8.2 / F.4.8.2)

internal enum SIMDWavelet97 {
    @inline(__always)
    private static func pse(_ i: Int, _ i0: Int, _ i1: Int) -> Int {
        if i >= i0 && i < i1 { return i }
        if i == i0 - 1 { return i0 + 1 }
        if i == i1 { return i1 - 2 }
        let span = 2 * (i1 - i0 - 1)
        var m = (i - i0) % span
        if m < 0 { m += span }
        return i0 + min(m, span - m)
    }

    private final class Scratch97 {
        var l4: [SIMD4<Double>]
        var s4: [SIMD4<Double>]
        var l1: [Double]
        var s1: [Double]

        init(maxLine: Int) {
            self.l4 = [SIMD4<Double>](repeating: .zero, count: maxLine)
            self.s4 = [SIMD4<Double>](repeating: .zero, count: maxLine)
            self.l1 = [Double](repeating: 0.0, count: maxLine)
            self.s1 = [Double](repeating: 0.0, count: maxLine)
        }

        @inline(__always)
        func withPointers<R>(
            _ body: (
                UnsafeMutablePointer<SIMD4<Double>>,
                UnsafeMutablePointer<SIMD4<Double>>,
                UnsafeMutableBufferPointer<Double>,
                UnsafeMutableBufferPointer<Double>
            ) throws -> R
        ) rethrows -> R {
            try l4.withUnsafeMutableBufferPointer { l4b in
                try s4.withUnsafeMutableBufferPointer { s4b in
                    try l1.withUnsafeMutableBufferPointer { l1b in
                        try s1.withUnsafeMutableBufferPointer { s1b in
                            try body(l4b.baseAddress!, s4b.baseAddress!, l1b, s1b)
                        }
                    }
                }
            }
        }
    }

    @inline(__always)
    private static func liftAddStep4(
        _ xp: UnsafeMutablePointer<SIMD4<Double>>,
        count: Int,
        i0: Int,
        i1: Int,
        parity: Int,
        coeff: SIMD4<Double>
    ) {
        @inline(__always)
        func x(_ i: Int) -> SIMD4<Double> { xp[pse(i, i0, i1) - i0] }

        if (i0 & 1) == parity {
            xp[0] += coeff * (x(i0 - 1) + x(i0 + 1))
        }
        var k = ((i0 & 1) == parity) ? 2 : 1
        let interiorLimit = count - 1
        while k < interiorLimit {
            xp[k] += coeff * (xp[k - 1] + xp[k + 1])
            k += 2
        }
        if count > 1 && ((i1 - 1) & 1) == parity {
            xp[count - 1] += coeff * (x(i1 - 2) + x(i1))
        }
    }

    @inline(__always)
    private static func liftSubStep4(
        _ xp: UnsafeMutablePointer<SIMD4<Double>>,
        count: Int,
        i0: Int,
        i1: Int,
        parity: Int,
        coeff: SIMD4<Double>
    ) {
        @inline(__always)
        func y(_ i: Int) -> SIMD4<Double> { xp[pse(i, i0, i1) - i0] }

        if (i0 & 1) == parity {
            xp[0] -= coeff * (y(i0 - 1) + y(i0 + 1))
        }
        var k = ((i0 & 1) == parity) ? 2 : 1
        let interiorLimit = count - 1
        while k < interiorLimit {
            xp[k] -= coeff * (xp[k - 1] + xp[k + 1])
            k += 2
        }
        if count > 1 && ((i1 - 1) & 1) == parity {
            xp[count - 1] -= coeff * (y(i1 - 2) + y(i1))
        }
    }

    @inline(__always)
    private static func forward1D4Ptr(
        _ sp: UnsafeMutablePointer<SIMD4<Double>>,
        i0: Int,
        i1: Int,
        scratch xp: UnsafeMutablePointer<SIMD4<Double>>
    ) {
        let count = i1 - i0
        guard count > 0 else { return }
        if count == 1 {
            if i0 & 1 != 0 {
                sp[0] *= SIMD4<Double>(repeating: 2.0)
            }
            return
        }
        xp.update(from: sp, count: count)

        let alphaVec = SIMD4<Double>(repeating: Wavelet97.alpha)
        let betaVec  = SIMD4<Double>(repeating: Wavelet97.beta)
        let gammaVec = SIMD4<Double>(repeating: Wavelet97.gamma)
        let deltaVec = SIMD4<Double>(repeating: Wavelet97.delta)
        let kVec     = SIMD4<Double>(repeating: Wavelet97.k)
        let invKVec  = SIMD4<Double>(repeating: Wavelet97.invK)

        liftAddStep4(xp, count: count, i0: i0, i1: i1, parity: 1, coeff: alphaVec)
        liftAddStep4(xp, count: count, i0: i0, i1: i1, parity: 0, coeff: betaVec)
        liftAddStep4(xp, count: count, i0: i0, i1: i1, parity: 1, coeff: gammaVec)
        liftAddStep4(xp, count: count, i0: i0, i1: i1, parity: 0, coeff: deltaVec)

        let lows = Wavelet53.lowCount(i0, i1)
        var l = 0
        var h = lows
        for i in i0..<i1 {
            if i & 1 == 0 {
                sp[l] = xp[i - i0] * invKVec
                l += 1
            } else {
                sp[h] = xp[i - i0] * kVec
                h += 1
            }
        }
    }

    internal static func forward1D4(
        _ signal: inout [SIMD4<Double>],
        i0: Int,
        i1: Int,
        scratch: inout [SIMD4<Double>]
    ) {
        guard i1 > i0 else { return }
        signal.withUnsafeMutableBufferPointer { sigBuf in
            scratch.withUnsafeMutableBufferPointer { scrBuf in
                forward1D4Ptr(sigBuf.baseAddress!, i0: i0, i1: i1, scratch: scrBuf.baseAddress!)
            }
        }
    }

    @inline(__always)
    private static func inverse1D4Ptr(
        _ sp: UnsafeMutablePointer<SIMD4<Double>>,
        i0: Int,
        i1: Int,
        scratch xp: UnsafeMutablePointer<SIMD4<Double>>
    ) {
        let count = i1 - i0
        guard count > 0 else { return }
        if count == 1 {
            if i0 & 1 != 0 {
                sp[0] *= SIMD4<Double>(repeating: 0.5)
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
                xp[i - i0] = sp[l] * kVec
                l += 1
            } else {
                xp[i - i0] = sp[h] * invKVec
                h += 1
            }
        }

        liftSubStep4(xp, count: count, i0: i0, i1: i1, parity: 0, coeff: deltaVec)
        liftSubStep4(xp, count: count, i0: i0, i1: i1, parity: 1, coeff: gammaVec)
        liftSubStep4(xp, count: count, i0: i0, i1: i1, parity: 0, coeff: betaVec)
        liftSubStep4(xp, count: count, i0: i0, i1: i1, parity: 1, coeff: alphaVec)

        sp.update(from: xp, count: count)
    }

    internal static func inverse1D4(
        _ signal: inout [SIMD4<Double>],
        i0: Int,
        i1: Int,
        scratch: inout [SIMD4<Double>]
    ) {
        guard i1 > i0 else { return }
        signal.withUnsafeMutableBufferPointer { sigBuf in
            scratch.withUnsafeMutableBufferPointer { scrBuf in
                inverse1D4Ptr(sigBuf.baseAddress!, i0: i0, i1: i1, scratch: scrBuf.baseAddress!)
            }
        }
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

        let workers = AcceleratedCodec.activeWorkerLimit
        let canParallel = workers > 1 && !BoundedParallelPool.isInsideParallelRegion && ((x1 - x0) * (y1 - y0) >= 16_384)
        let scratchCount = canParallel ? min(workers, max(1, (maxLine + 7) / 8)) : 1
        var scratches = (0..<scratchCount).map { _ in Scratch97(maxLine: maxLine) }

        try plane.withUnsafeMutableBufferPointer { planeBuf in
            guard let pBase = planeBuf.baseAddress else { return }
            let sharedPlane = UnsafeSendableMutableBuffer(planeBuf)
            try scratches.withUnsafeMutableBufferPointer { scratchBuf in
                let sharedScratches = UnsafeSendableMutableBuffer(scratchBuf)

                for level in 0..<levels {
                    try cancellation()
                    let lx0 = Wavelet53.ceilDivPowerOfTwo(x0, level)
                    let lx1 = Wavelet53.ceilDivPowerOfTwo(x1, level)
                    let ly0 = Wavelet53.ceilDivPowerOfTwo(y0, level)
                    let ly1 = Wavelet53.ceilDivPowerOfTwo(y1, level)
                    let w = lx1 - lx0
                    let h = ly1 - ly0
                    guard w > 0, h > 0 else { continue }
                    let useParallel = canParallel && (w * h >= 16_384)

                    // Horizontal pass
                    let rowStrips = (h + 15) / 16
                    if useParallel && rowStrips >= 2 {
                        let wCount = BoundedParallelPool.effectiveWorkers(requested: scratchCount, jobCount: rowStrips)
                        try BoundedParallelPool.forEach(jobCount: rowStrips, maxWorkers: wCount) { (stripIdx: Int, workerIdx: Int) in
                            let pb = sharedPlane.baseAddress
                            sharedScratches.baseAddress[workerIdx].withPointers { l4p, s4p, lineBuf, sBuf in
                                let startY = stripIdx * 16
                                let endY = min(h, startY + 16)
                                var y = startY
                                while y + 4 <= endY {
                                    let r0 = y * stride, r1 = (y + 1) * stride, r2 = (y + 2) * stride, r3 = (y + 3) * stride
                                    for x in 0..<w {
                                        l4p[x] = SIMD4<Double>(pb[r0 + x], pb[r1 + x], pb[r2 + x], pb[r3 + x])
                                    }
                                    forward1D4Ptr(l4p, i0: lx0, i1: lx1, scratch: s4p)
                                    for x in 0..<w {
                                        let v = l4p[x]
                                        pb[r0 + x] = v[0]; pb[r1 + x] = v[1]; pb[r2 + x] = v[2]; pb[r3 + x] = v[3]
                                    }
                                    y += 4
                                }
                                let l1p = lineBuf.baseAddress!
                                while y < endY {
                                    let base = y * stride
                                    for x in 0..<w { l1p[x] = pb[base + x] }
                                    Wavelet97.forward1D(lineBuf, i0: lx0, i1: lx1, scratch: sBuf)
                                    for x in 0..<w { pb[base + x] = l1p[x] }
                                    y += 1
                                }
                            }
                        }
                    } else {
                        sharedScratches.baseAddress[0].withPointers { l4p, s4p, lineBuf, sBuf in
                            var y = 0
                            while y + 4 <= h {
                                let r0 = y * stride
                                let r1 = (y + 1) * stride
                                let r2 = (y + 2) * stride
                                let r3 = (y + 3) * stride
                                for x in 0..<w {
                                    l4p[x] = SIMD4<Double>(pBase[r0 + x], pBase[r1 + x], pBase[r2 + x], pBase[r3 + x])
                                }
                                forward1D4Ptr(l4p, i0: lx0, i1: lx1, scratch: s4p)
                                for x in 0..<w {
                                    let v = l4p[x]
                                    pBase[r0 + x] = v[0]; pBase[r1 + x] = v[1]; pBase[r2 + x] = v[2]; pBase[r3 + x] = v[3]
                                }
                                y += 4
                            }
                            let l1p = lineBuf.baseAddress!
                            while y < h {
                                let base = y * stride
                                for x in 0..<w { l1p[x] = pBase[base + x] }
                                Wavelet97.forward1D(lineBuf, i0: lx0, i1: lx1, scratch: sBuf)
                                for x in 0..<w { pBase[base + x] = l1p[x] }
                                y += 1
                            }
                        }
                    }

                    // Vertical pass (16-column strips = 128-byte cache-line alignment)
                    let colStrips = (w + 15) / 16
                    if useParallel && colStrips >= 2 {
                        let wCount = BoundedParallelPool.effectiveWorkers(requested: scratchCount, jobCount: colStrips)
                        try BoundedParallelPool.forEach(jobCount: colStrips, maxWorkers: wCount) { (stripIdx: Int, workerIdx: Int) in
                            let pb = sharedPlane.baseAddress
                            sharedScratches.baseAddress[workerIdx].withPointers { l4p, s4p, lineBuf, sBuf in
                                let startX = stripIdx * 16
                                let endX = min(w, startX + 16)
                                var x = startX
                                while x + 4 <= endX {
                                    for row in 0..<h {
                                        let base = row * stride + x
                                        l4p[row] = SIMD4<Double>(pb[base], pb[base + 1], pb[base + 2], pb[base + 3])
                                    }
                                    forward1D4Ptr(l4p, i0: ly0, i1: ly1, scratch: s4p)
                                    for row in 0..<h {
                                        let base = row * stride + x
                                        let v = l4p[row]
                                        pb[base] = v[0]; pb[base + 1] = v[1]; pb[base + 2] = v[2]; pb[base + 3] = v[3]
                                    }
                                    x += 4
                                }
                                let l1p = lineBuf.baseAddress!
                                while x < endX {
                                    for row in 0..<h { l1p[row] = pb[row * stride + x] }
                                    Wavelet97.forward1D(lineBuf, i0: ly0, i1: ly1, scratch: sBuf)
                                    for row in 0..<h { pb[row * stride + x] = l1p[row] }
                                    x += 1
                                }
                            }
                        }
                    } else {
                        sharedScratches.baseAddress[0].withPointers { l4p, s4p, lineBuf, sBuf in
                            var x = 0
                            while x + 4 <= w {
                                for row in 0..<h {
                                    let base = row * stride + x
                                    l4p[row] = SIMD4<Double>(pBase[base], pBase[base + 1], pBase[base + 2], pBase[base + 3])
                                }
                                forward1D4Ptr(l4p, i0: ly0, i1: ly1, scratch: s4p)
                                for row in 0..<h {
                                    let base = row * stride + x
                                    let v = l4p[row]
                                    pBase[base] = v[0]; pBase[base + 1] = v[1]; pBase[base + 2] = v[2]; pBase[base + 3] = v[3]
                                }
                                x += 4
                            }
                            let l1p = lineBuf.baseAddress!
                            while x < w {
                                for row in 0..<h { l1p[row] = pBase[row * stride + x] }
                                Wavelet97.forward1D(lineBuf, i0: ly0, i1: ly1, scratch: sBuf)
                                for row in 0..<h { pBase[row * stride + x] = l1p[row] }
                                x += 1
                            }
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

        let workers = AcceleratedCodec.activeWorkerLimit
        let canParallel = workers > 1 && !BoundedParallelPool.isInsideParallelRegion && ((x1 - x0) * (y1 - y0) >= 16_384)
        let scratchCount = canParallel ? min(workers, max(1, (maxLine + 7) / 8)) : 1
        var scratches = (0..<scratchCount).map { _ in Scratch97(maxLine: maxLine) }

        try plane.withUnsafeMutableBufferPointer { planeBuf in
            guard let pBase = planeBuf.baseAddress else { return }
            let sharedPlane = UnsafeSendableMutableBuffer(planeBuf)
            try scratches.withUnsafeMutableBufferPointer { scratchBuf in
                let sharedScratches = UnsafeSendableMutableBuffer(scratchBuf)

                for level in (0..<levels).reversed() {
                    try cancellation()
                    let lx0 = Wavelet53.ceilDivPowerOfTwo(x0, level)
                    let lx1 = Wavelet53.ceilDivPowerOfTwo(x1, level)
                    let ly0 = Wavelet53.ceilDivPowerOfTwo(y0, level)
                    let ly1 = Wavelet53.ceilDivPowerOfTwo(y1, level)
                    let w = lx1 - lx0
                    let h = ly1 - ly0
                    guard w > 0, h > 0 else { continue }
                    let useParallel = canParallel && (w * h >= 16_384)

                    // Vertical inverse pass (16-column strips = 128-byte cache-line alignment)
                    let colStrips = (w + 15) / 16
                    if useParallel && colStrips >= 2 {
                        let wCount = BoundedParallelPool.effectiveWorkers(requested: scratchCount, jobCount: colStrips)
                        try BoundedParallelPool.forEach(jobCount: colStrips, maxWorkers: wCount) { (stripIdx: Int, workerIdx: Int) in
                            let pb = sharedPlane.baseAddress
                            sharedScratches.baseAddress[workerIdx].withPointers { l4p, s4p, lineBuf, sBuf in
                                let startX = stripIdx * 16
                                let endX = min(w, startX + 16)
                                var x = startX
                                while x + 4 <= endX {
                                    for row in 0..<h {
                                        let base = row * stride + x
                                        l4p[row] = SIMD4<Double>(pb[base], pb[base + 1], pb[base + 2], pb[base + 3])
                                    }
                                    inverse1D4Ptr(l4p, i0: ly0, i1: ly1, scratch: s4p)
                                    for row in 0..<h {
                                        let base = row * stride + x
                                        let v = l4p[row]
                                        pb[base] = v[0]; pb[base + 1] = v[1]; pb[base + 2] = v[2]; pb[base + 3] = v[3]
                                    }
                                    x += 4
                                }
                                let l1p = lineBuf.baseAddress!
                                while x < endX {
                                    for row in 0..<h { l1p[row] = pb[row * stride + x] }
                                    Wavelet97.inverse1D(lineBuf, i0: ly0, i1: ly1, scratch: sBuf)
                                    for row in 0..<h { pb[row * stride + x] = l1p[row] }
                                    x += 1
                                }
                            }
                        }
                    } else {
                        sharedScratches.baseAddress[0].withPointers { l4p, s4p, lineBuf, sBuf in
                            var x = 0
                            while x + 4 <= w {
                                for row in 0..<h {
                                    let base = row * stride + x
                                    l4p[row] = SIMD4<Double>(pBase[base], pBase[base + 1], pBase[base + 2], pBase[base + 3])
                                }
                                inverse1D4Ptr(l4p, i0: ly0, i1: ly1, scratch: s4p)
                                for row in 0..<h {
                                    let base = row * stride + x
                                    let v = l4p[row]
                                    pBase[base] = v[0]; pBase[base + 1] = v[1]; pBase[base + 2] = v[2]; pBase[base + 3] = v[3]
                                }
                                x += 4
                            }
                            let l1p = lineBuf.baseAddress!
                            while x < w {
                                for row in 0..<h { l1p[row] = pBase[row * stride + x] }
                                Wavelet97.inverse1D(lineBuf, i0: ly0, i1: ly1, scratch: sBuf)
                                for row in 0..<h { pBase[row * stride + x] = l1p[row] }
                                x += 1
                            }
                        }
                    }

                    // Horizontal inverse pass
                    let rowStrips = (h + 15) / 16
                    if useParallel && rowStrips >= 2 {
                        let wCount = BoundedParallelPool.effectiveWorkers(requested: scratchCount, jobCount: rowStrips)
                        try BoundedParallelPool.forEach(jobCount: rowStrips, maxWorkers: wCount) { (stripIdx: Int, workerIdx: Int) in
                            let pb = sharedPlane.baseAddress
                            sharedScratches.baseAddress[workerIdx].withPointers { l4p, s4p, lineBuf, sBuf in
                                let startY = stripIdx * 16
                                let endY = min(h, startY + 16)
                                var y = startY
                                while y + 4 <= endY {
                                    let r0 = y * stride, r1 = (y + 1) * stride, r2 = (y + 2) * stride, r3 = (y + 3) * stride
                                    for col in 0..<w {
                                        l4p[col] = SIMD4<Double>(pb[r0 + col], pb[r1 + col], pb[r2 + col], pb[r3 + col])
                                    }
                                    inverse1D4Ptr(l4p, i0: lx0, i1: lx1, scratch: s4p)
                                    for col in 0..<w {
                                        let v = l4p[col]
                                        pb[r0 + col] = v[0]; pb[r1 + col] = v[1]; pb[r2 + col] = v[2]; pb[r3 + col] = v[3]
                                    }
                                    y += 4
                                }
                                let l1p = lineBuf.baseAddress!
                                while y < endY {
                                    let base = y * stride
                                    for col in 0..<w { l1p[col] = pb[base + col] }
                                    Wavelet97.inverse1D(lineBuf, i0: lx0, i1: lx1, scratch: sBuf)
                                    for col in 0..<w { pb[base + col] = l1p[col] }
                                    y += 1
                                }
                            }
                        }
                    } else {
                        sharedScratches.baseAddress[0].withPointers { l4p, s4p, lineBuf, sBuf in
                            var y = 0
                            while y + 4 <= h {
                                let r0 = y * stride
                                let r1 = (y + 1) * stride
                                let r2 = (y + 2) * stride
                                let r3 = (y + 3) * stride
                                for col in 0..<w {
                                    l4p[col] = SIMD4<Double>(pBase[r0 + col], pBase[r1 + col], pBase[r2 + col], pBase[r3 + col])
                                }
                                inverse1D4Ptr(l4p, i0: lx0, i1: lx1, scratch: s4p)
                                for col in 0..<w {
                                    let v = l4p[col]
                                    pBase[r0 + col] = v[0]; pBase[r1 + col] = v[1]; pBase[r2 + col] = v[2]; pBase[r3 + col] = v[3]
                                }
                                y += 4
                            }
                            let l1p = lineBuf.baseAddress!
                            while y < h {
                                let base = y * stride
                                for col in 0..<w { l1p[col] = pBase[base + col] }
                                Wavelet97.inverse1D(lineBuf, i0: lx0, i1: lx1, scratch: sBuf)
                                for col in 0..<w { pBase[base + col] = l1p[col] }
                                y += 1
                            }
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
        guard count > 0 else { return }

        var rPlane = planes[0]; planes[0] = []
        var gPlane = planes[1]; planes[1] = []
        var bPlane = planes[2]; planes[2] = []
        defer {
            planes[0] = rPlane
            planes[1] = gPlane
            planes[2] = bPlane
        }

        rPlane.withUnsafeMutableBufferPointer { rBuf in
            gPlane.withUnsafeMutableBufferPointer { gBuf in
                bPlane.withUnsafeMutableBufferPointer { bBuf in
                    let rp = rBuf.baseAddress!
                    let gp = gBuf.baseAddress!
                    let bp = bBuf.baseAddress!
                    let two = SIMD4<Int64>(repeating: 2)

                    @inline(__always)
                    func runRange(_ start: Int, _ end: Int) {
                        var i = start
                        while i + 4 <= end {
                            let r = SIMD4<Int64>(Int64(rp[i]), Int64(rp[i + 1]), Int64(rp[i + 2]), Int64(rp[i + 3]))
                            let g = SIMD4<Int64>(Int64(gp[i]), Int64(gp[i + 1]), Int64(gp[i + 2]), Int64(gp[i + 3]))
                            let b = SIMD4<Int64>(Int64(bp[i]), Int64(bp[i + 1]), Int64(bp[i + 2]), Int64(bp[i + 3]))
                            let y  = SIMD4<Int32>(truncatingIfNeeded: (r &+ (two &* g) &+ b) &>> 2)
                            let cb = SIMD4<Int32>(truncatingIfNeeded: b &- g)
                            let cr = SIMD4<Int32>(truncatingIfNeeded: r &- g)
                            rp[i] = y[0];  rp[i + 1] = y[1];  rp[i + 2] = y[2];  rp[i + 3] = y[3]
                            gp[i] = cb[0]; gp[i + 1] = cb[1]; gp[i + 2] = cb[2]; gp[i + 3] = cb[3]
                            bp[i] = cr[0]; bp[i + 1] = cr[1]; bp[i + 2] = cr[2]; bp[i + 3] = cr[3]
                            i += 4
                        }
                        while i < end {
                            let r = Int64(rp[i]), g = Int64(gp[i]), b = Int64(bp[i])
                            rp[i] = Int32(truncatingIfNeeded: (r + 2 * g + b) >> 2)
                            gp[i] = Int32(truncatingIfNeeded: b - g)
                            bp[i] = Int32(truncatingIfNeeded: r - g)
                            i += 1
                        }
                    }

                    let workers = AcceleratedCodec.activeWorkerLimit
                    let chunkSize = 8192
                    let chunks = (count + chunkSize - 1) / chunkSize
                    if workers > 1 && !BoundedParallelPool.isInsideParallelRegion && chunks >= 2 && count >= 32_768 {
                        let sr = UnsafeSendableMutableBuffer(rBuf)
                        let sg = UnsafeSendableMutableBuffer(gBuf)
                        let sb = UnsafeSendableMutableBuffer(bBuf)
                        BoundedParallelPool.forEachNonThrowing(jobCount: chunks, maxWorkers: workers) { cIdx in
                            let s = cIdx * chunkSize
                            let e = min(count, s + chunkSize)
                            let p0 = sr.baseAddress, p1 = sg.baseAddress, p2 = sb.baseAddress
                            var i = s
                            while i + 4 <= e {
                                let r = SIMD4<Int64>(Int64(p0[i]), Int64(p0[i + 1]), Int64(p0[i + 2]), Int64(p0[i + 3]))
                                let g = SIMD4<Int64>(Int64(p1[i]), Int64(p1[i + 1]), Int64(p1[i + 2]), Int64(p1[i + 3]))
                                let b = SIMD4<Int64>(Int64(p2[i]), Int64(p2[i + 1]), Int64(p2[i + 2]), Int64(p2[i + 3]))
                                let y  = SIMD4<Int32>(truncatingIfNeeded: (r &+ (two &* g) &+ b) &>> 2)
                                let cb = SIMD4<Int32>(truncatingIfNeeded: b &- g)
                                let cr = SIMD4<Int32>(truncatingIfNeeded: r &- g)
                                p0[i] = y[0];  p0[i + 1] = y[1];  p0[i + 2] = y[2];  p0[i + 3] = y[3]
                                p1[i] = cb[0]; p1[i + 1] = cb[1]; p1[i + 2] = cb[2]; p1[i + 3] = cb[3]
                                p2[i] = cr[0]; p2[i + 1] = cr[1]; p2[i + 2] = cr[2]; p2[i + 3] = cr[3]
                                i += 4
                            }
                            while i < e {
                                let r = Int64(p0[i]), g = Int64(p1[i]), b = Int64(p2[i])
                                p0[i] = Int32(truncatingIfNeeded: (r + 2 * g + b) >> 2)
                                p1[i] = Int32(truncatingIfNeeded: b - g)
                                p2[i] = Int32(truncatingIfNeeded: r - g)
                                i += 1
                            }
                        }
                    } else {
                        runRange(0, count)
                    }
                }
            }
        }
    }

    /// Inverse Reversible Colour Transform (RCT) in-place on 3 component planes using `SIMD4<Int64>`.
    ///
    /// Bit-for-bit identical to `ColourTransform.inverseRCT(planes:)`.
    internal static func inverseRCT(planes: inout [[Int32]]) {
        guard planes.count >= 3 else { return }
        let count = min(planes[0].count, min(planes[1].count, planes[2].count))
        guard count > 0 else { return }

        var yPlane = planes[0]; planes[0] = []
        var cbPlane = planes[1]; planes[1] = []
        var crPlane = planes[2]; planes[2] = []
        defer {
            planes[0] = yPlane
            planes[1] = cbPlane
            planes[2] = crPlane
        }

        yPlane.withUnsafeMutableBufferPointer { yBuf in
            cbPlane.withUnsafeMutableBufferPointer { cbBuf in
                crPlane.withUnsafeMutableBufferPointer { crBuf in
                    let yp = yBuf.baseAddress!
                    let cbp = cbBuf.baseAddress!
                    let crp = crBuf.baseAddress!

                    let workers = AcceleratedCodec.activeWorkerLimit
                    let chunkSize = 8192
                    let chunks = (count + chunkSize - 1) / chunkSize
                    if workers > 1 && !BoundedParallelPool.isInsideParallelRegion && chunks >= 2 && count >= 32_768 {
                        let sy = UnsafeSendableMutableBuffer(yBuf)
                        let scb = UnsafeSendableMutableBuffer(cbBuf)
                        let scr = UnsafeSendableMutableBuffer(crBuf)
                        BoundedParallelPool.forEachNonThrowing(jobCount: chunks, maxWorkers: workers) { cIdx in
                            let s = cIdx * chunkSize
                            let e = min(count, s + chunkSize)
                            let p0 = sy.baseAddress, p1 = scb.baseAddress, p2 = scr.baseAddress
                            var i = s
                            while i + 4 <= e {
                                let yv  = SIMD4<Int64>(Int64(p0[i]), Int64(p0[i + 1]), Int64(p0[i + 2]), Int64(p0[i + 3]))
                                let cbv = SIMD4<Int64>(Int64(p1[i]), Int64(p1[i + 1]), Int64(p1[i + 2]), Int64(p1[i + 3]))
                                let crv = SIMD4<Int64>(Int64(p2[i]), Int64(p2[i + 1]), Int64(p2[i + 2]), Int64(p2[i + 3]))
                                let g = yv &- ((cbv &+ crv) &>> 2)
                                let r = SIMD4<Int32>(truncatingIfNeeded: crv &+ g)
                                let g32 = SIMD4<Int32>(truncatingIfNeeded: g)
                                let b = SIMD4<Int32>(truncatingIfNeeded: cbv &+ g)
                                p0[i] = r[0];   p0[i + 1] = r[1];   p0[i + 2] = r[2];   p0[i + 3] = r[3]
                                p1[i] = g32[0]; p1[i + 1] = g32[1]; p1[i + 2] = g32[2]; p1[i + 3] = g32[3]
                                p2[i] = b[0];   p2[i + 1] = b[1];   p2[i + 2] = b[2];   p2[i + 3] = b[3]
                                i += 4
                            }
                            while i < e {
                                let yv = Int64(p0[i]), cbv = Int64(p1[i]), crv = Int64(p2[i])
                                let g = yv - ((cbv + crv) >> 2)
                                p0[i] = Int32(truncatingIfNeeded: crv + g)
                                p1[i] = Int32(truncatingIfNeeded: g)
                                p2[i] = Int32(truncatingIfNeeded: cbv + g)
                                i += 1
                            }
                        }
                    } else {
                        var i = 0
                        while i + 4 <= count {
                            let yv  = SIMD4<Int64>(Int64(yp[i]), Int64(yp[i + 1]), Int64(yp[i + 2]), Int64(yp[i + 3]))
                            let cbv = SIMD4<Int64>(Int64(cbp[i]), Int64(cbp[i + 1]), Int64(cbp[i + 2]), Int64(cbp[i + 3]))
                            let crv = SIMD4<Int64>(Int64(crp[i]), Int64(crp[i + 1]), Int64(crp[i + 2]), Int64(crp[i + 3]))
                            let g = yv &- ((cbv &+ crv) &>> 2)
                            let r = SIMD4<Int32>(truncatingIfNeeded: crv &+ g)
                            let g32 = SIMD4<Int32>(truncatingIfNeeded: g)
                            let b = SIMD4<Int32>(truncatingIfNeeded: cbv &+ g)
                            yp[i]  = r[0];   yp[i + 1]  = r[1];   yp[i + 2]  = r[2];   yp[i + 3]  = r[3]
                            cbp[i] = g32[0]; cbp[i + 1] = g32[1]; cbp[i + 2] = g32[2]; cbp[i + 3] = g32[3]
                            crp[i] = b[0];   crp[i + 1] = b[1];   crp[i + 2] = b[2];   crp[i + 3] = b[3]
                            i += 4
                        }
                        while i < count {
                            let yv = Int64(yp[i]), cbv = Int64(cbp[i]), crv = Int64(crp[i])
                            let g = yv - ((cbv + crv) >> 2)
                            yp[i]  = Int32(truncatingIfNeeded: crv + g)
                            cbp[i] = Int32(truncatingIfNeeded: g)
                            crp[i] = Int32(truncatingIfNeeded: cbv + g)
                            i += 1
                        }
                    }
                }
            }
        }
    }

    /// Forward Irreversible Colour Transform (ICT) in-place on 3 component planes using `SIMD4<Double>`.
    ///
    /// Bit-for-bit identical to `ColourTransform.forwardICT(planes:)`.
    internal static func forwardICT(planes: inout [[Double]]) {
        guard planes.count >= 3 else { return }
        let count = min(planes[0].count, min(planes[1].count, planes[2].count))
        guard count > 0 else { return }

        var rPlane = planes[0]; planes[0] = []
        var gPlane = planes[1]; planes[1] = []
        var bPlane = planes[2]; planes[2] = []
        defer {
            planes[0] = rPlane
            planes[1] = gPlane
            planes[2] = bPlane
        }

        let c0R = SIMD4<Double>(repeating:  0.299)
        let c0G = SIMD4<Double>(repeating:  0.587)
        let c0B = SIMD4<Double>(repeating:  0.114)
        let c1R = SIMD4<Double>(repeating: -0.168736)
        let c1G = SIMD4<Double>(repeating: -0.331264)
        let c1B = SIMD4<Double>(repeating:  0.5)
        let c2R = SIMD4<Double>(repeating:  0.5)
        let c2G = SIMD4<Double>(repeating: -0.418688)
        let c2B = SIMD4<Double>(repeating: -0.081312)

        rPlane.withUnsafeMutableBufferPointer { rBuf in
            gPlane.withUnsafeMutableBufferPointer { gBuf in
                bPlane.withUnsafeMutableBufferPointer { bBuf in
                    let rp = rBuf.baseAddress!
                    let gp = gBuf.baseAddress!
                    let bp = bBuf.baseAddress!

                    let workers = AcceleratedCodec.activeWorkerLimit
                    let chunkSize = 8192
                    let chunks = (count + chunkSize - 1) / chunkSize
                    if workers > 1 && !BoundedParallelPool.isInsideParallelRegion && chunks >= 2 && count >= 32_768 {
                        let sr = UnsafeSendableMutableBuffer(rBuf)
                        let sg = UnsafeSendableMutableBuffer(gBuf)
                        let sb = UnsafeSendableMutableBuffer(bBuf)
                        BoundedParallelPool.forEachNonThrowing(jobCount: chunks, maxWorkers: workers) { cIdx in
                            let s = cIdx * chunkSize
                            let e = min(count, s + chunkSize)
                            let p0 = sr.baseAddress, p1 = sg.baseAddress, p2 = sb.baseAddress
                            var i = s
                            while i + 4 <= e {
                                let r = SIMD4<Double>(p0[i], p0[i + 1], p0[i + 2], p0[i + 3])
                                let g = SIMD4<Double>(p1[i], p1[i + 1], p1[i + 2], p1[i + 3])
                                let b = SIMD4<Double>(p2[i], p2[i + 1], p2[i + 2], p2[i + 3])
                                let y  = c0R * r + c0G * g + c0B * b
                                let cb = c1R * r + c1G * g + c1B * b
                                let cr = c2R * r + c2G * g + c2B * b
                                p0[i] = y[0];  p0[i + 1] = y[1];  p0[i + 2] = y[2];  p0[i + 3] = y[3]
                                p1[i] = cb[0]; p1[i + 1] = cb[1]; p1[i + 2] = cb[2]; p1[i + 3] = cb[3]
                                p2[i] = cr[0]; p2[i + 1] = cr[1]; p2[i + 2] = cr[2]; p2[i + 3] = cr[3]
                                i += 4
                            }
                            while i < e {
                                let r = p0[i], g = p1[i], b = p2[i]
                                p0[i] =  0.299    * r + 0.587    * g + 0.114    * b
                                p1[i] = -0.168736 * r - 0.331264 * g + 0.5      * b
                                p2[i] =  0.5      * r - 0.418688 * g - 0.081312 * b
                                i += 1
                            }
                        }
                    } else {
                        var i = 0
                        while i + 4 <= count {
                            let r = SIMD4<Double>(rp[i], rp[i + 1], rp[i + 2], rp[i + 3])
                            let g = SIMD4<Double>(gp[i], gp[i + 1], gp[i + 2], gp[i + 3])
                            let b = SIMD4<Double>(bp[i], bp[i + 1], bp[i + 2], bp[i + 3])
                            let y  = c0R * r + c0G * g + c0B * b
                            let cb = c1R * r + c1G * g + c1B * b
                            let cr = c2R * r + c2G * g + c2B * b
                            rp[i] = y[0];  rp[i + 1] = y[1];  rp[i + 2] = y[2];  rp[i + 3] = y[3]
                            gp[i] = cb[0]; gp[i + 1] = cb[1]; gp[i + 2] = cb[2]; gp[i + 3] = cb[3]
                            bp[i] = cr[0]; bp[i + 1] = cr[1]; bp[i + 2] = cr[2]; bp[i + 3] = cr[3]
                            i += 4
                        }
                        while i < count {
                            let r = rp[i], g = gp[i], b = bp[i]
                            rp[i] =  0.299    * r + 0.587    * g + 0.114    * b
                            gp[i] = -0.168736 * r - 0.331264 * g + 0.5      * b
                            bp[i] =  0.5      * r - 0.418688 * g - 0.081312 * b
                            i += 1
                        }
                    }
                }
            }
        }
    }

    /// Inverse Irreversible Colour Transform (ICT) in-place on 3 component planes using `SIMD4<Double>`.
    ///
    /// Bit-for-bit identical to `ColourTransform.inverseICT(planes:)`.
    internal static func inverseICT(planes: inout [[Double]]) {
        guard planes.count >= 3 else { return }
        let count = min(planes[0].count, min(planes[1].count, planes[2].count))
        guard count > 0 else { return }

        var yPlane = planes[0]; planes[0] = []
        var cbPlane = planes[1]; planes[1] = []
        var crPlane = planes[2]; planes[2] = []
        defer {
            planes[0] = yPlane
            planes[1] = cbPlane
            planes[2] = crPlane
        }

        let crToR = SIMD4<Double>(repeating: 1.402)
        let cbToG = SIMD4<Double>(repeating: 0.344136)
        let crToG = SIMD4<Double>(repeating: 0.714136)
        let cbToB = SIMD4<Double>(repeating: 1.772)

        yPlane.withUnsafeMutableBufferPointer { yBuf in
            cbPlane.withUnsafeMutableBufferPointer { cbBuf in
                crPlane.withUnsafeMutableBufferPointer { crBuf in
                    let yp = yBuf.baseAddress!
                    let cbp = cbBuf.baseAddress!
                    let crp = crBuf.baseAddress!

                    let workers = AcceleratedCodec.activeWorkerLimit
                    let chunkSize = 8192
                    let chunks = (count + chunkSize - 1) / chunkSize
                    if workers > 1 && !BoundedParallelPool.isInsideParallelRegion && chunks >= 2 && count >= 32_768 {
                        let sy = UnsafeSendableMutableBuffer(yBuf)
                        let scb = UnsafeSendableMutableBuffer(cbBuf)
                        let scr = UnsafeSendableMutableBuffer(crBuf)
                        BoundedParallelPool.forEachNonThrowing(jobCount: chunks, maxWorkers: workers) { cIdx in
                            let s = cIdx * chunkSize
                            let e = min(count, s + chunkSize)
                            let p0 = sy.baseAddress, p1 = scb.baseAddress, p2 = scr.baseAddress
                            var i = s
                            while i + 4 <= e {
                                let yv  = SIMD4<Double>(p0[i], p0[i + 1], p0[i + 2], p0[i + 3])
                                let cbv = SIMD4<Double>(p1[i], p1[i + 1], p1[i + 2], p1[i + 3])
                                let crv = SIMD4<Double>(p2[i], p2[i + 1], p2[i + 2], p2[i + 3])
                                let r = yv + crToR * crv
                                let g = yv - cbToG * cbv - crToG * crv
                                let b = yv + cbToB * cbv
                                p0[i] = r[0]; p0[i + 1] = r[1]; p0[i + 2] = r[2]; p0[i + 3] = r[3]
                                p1[i] = g[0]; p1[i + 1] = g[1]; p1[i + 2] = g[2]; p1[i + 3] = g[3]
                                p2[i] = b[0]; p2[i + 1] = b[1]; p2[i + 2] = b[2]; p2[i + 3] = b[3]
                                i += 4
                            }
                            while i < e {
                                let yv = p0[i], cbv = p1[i], crv = p2[i]
                                p0[i] = yv + 1.402 * crv
                                p1[i] = yv - 0.344136 * cbv - 0.714136 * crv
                                p2[i] = yv + 1.772 * cbv
                                i += 1
                            }
                        }
                    } else {
                        var i = 0
                        while i + 4 <= count {
                            let yv  = SIMD4<Double>(yp[i],  yp[i + 1],  yp[i + 2],  yp[i + 3])
                            let cbv = SIMD4<Double>(cbp[i], cbp[i + 1], cbp[i + 2], cbp[i + 3])
                            let crv = SIMD4<Double>(crp[i], crp[i + 1], crp[i + 2], crp[i + 3])
                            let r = yv + crToR * crv
                            let g = yv - cbToG * cbv - crToG * crv
                            let b = yv + cbToB * cbv
                            yp[i]  = r[0]; yp[i + 1]  = r[1]; yp[i + 2]  = r[2]; yp[i + 3]  = r[3]
                            cbp[i] = g[0]; cbp[i + 1] = g[1]; cbp[i + 2] = g[2]; cbp[i + 3] = g[3]
                            crp[i] = b[0]; crp[i + 1] = b[1]; crp[i + 2] = b[2]; crp[i + 3] = b[3]
                            i += 4
                        }
                        while i < count {
                            let yv = yp[i], cbv = cbp[i], crv = crp[i]
                            yp[i]  = yv + 1.402 * crv
                            cbp[i] = yv - 0.344136 * cbv - 0.714136 * crv
                            crp[i] = yv + 1.772 * cbv
                            i += 1
                        }
                    }
                }
            }
        }
    }

    /// Vectorised general 3×3 linear transform (`out = M * in + offsets`) using `SIMD4<Double>`.
    internal static func applyLinear3x3(
        in0: [Double],
        in1: [Double],
        in2: [Double],
        matrix: [Double],
        offsets: [Double],
        out0: inout [Double],
        out1: inout [Double],
        out2: inout [Double]
    ) {
        let count = min(in0.count, min(in1.count, in2.count))
        let m00 = SIMD4<Double>(repeating: matrix[0]), m01 = SIMD4<Double>(repeating: matrix[1]), m02 = SIMD4<Double>(repeating: matrix[2])
        let m10 = SIMD4<Double>(repeating: matrix[3]), m11 = SIMD4<Double>(repeating: matrix[4]), m12 = SIMD4<Double>(repeating: matrix[5])
        let m20 = SIMD4<Double>(repeating: matrix[6]), m21 = SIMD4<Double>(repeating: matrix[7]), m22 = SIMD4<Double>(repeating: matrix[8])
        let o0 = SIMD4<Double>(repeating: offsets[0])
        let o1 = SIMD4<Double>(repeating: offsets[1])
        let o2 = SIMD4<Double>(repeating: offsets[2])

        var i = 0
        while i + 4 <= count {
            let x0 = SIMD4<Double>(in0[i], in0[i + 1], in0[i + 2], in0[i + 3])
            let x1 = SIMD4<Double>(in1[i], in1[i + 1], in1[i + 2], in1[i + 3])
            let x2 = SIMD4<Double>(in2[i], in2[i + 1], in2[i + 2], in2[i + 3])
            let y0 = m00 * x0 + m01 * x1 + m02 * x2 + o0
            let y1 = m10 * x0 + m11 * x1 + m12 * x2 + o1
            let y2 = m20 * x0 + m21 * x1 + m22 * x2 + o2
            out0[i] = y0[0]; out0[i + 1] = y0[1]; out0[i + 2] = y0[2]; out0[i + 3] = y0[3]
            out1[i] = y1[0]; out1[i + 1] = y1[1]; out1[i + 2] = y1[2]; out1[i + 3] = y1[3]
            out2[i] = y2[0]; out2[i + 1] = y2[1]; out2[i + 2] = y2[2]; out2[i + 3] = y2[3]
            i += 4
        }
        while i < count {
            let x0 = in0[i], x1 = in1[i], x2 = in2[i]
            out0[i] = matrix[0] * x0 + matrix[1] * x1 + matrix[2] * x2 + offsets[0]
            out1[i] = matrix[3] * x0 + matrix[4] * x1 + matrix[5] * x2 + offsets[1]
            out2[i] = matrix[6] * x0 + matrix[7] * x1 + matrix[8] * x2 + offsets[2]
            i += 1
        }
    }

    /// Vectorised 3-component Part 2 reversible dependency forward transform (`SIMD4<Int32>`).
    internal static func forwardPart2ReversibleDep3(
        r: [Int32],
        g: [Int32],
        b: [Int32],
        anchorOffset: Int32
    ) -> [[Int32]] {
        let count = min(r.count, min(g.count, b.count))
        var w0 = Array(repeating: Int32(0), count: count)
        var w1 = Array(repeating: Int32(0), count: count)
        var w2 = Array(repeating: Int32(0), count: count)
        let off = SIMD4<Int32>(repeating: anchorOffset)
        var i = 0
        while i + 4 <= count {
            let rv = SIMD4<Int32>(r[i], r[i + 1], r[i + 2], r[i + 3])
            let gv = SIMD4<Int32>(g[i], g[i + 1], g[i + 2], g[i + 3])
            let bv = SIMD4<Int32>(b[i], b[i + 1], b[i + 2], b[i + 3])
            let y0 = gv &- off
            let d1 = rv &- gv
            let d2 = bv &- gv
            w0[i] = y0[0]; w0[i + 1] = y0[1]; w0[i + 2] = y0[2]; w0[i + 3] = y0[3]
            w1[i] = d1[0]; w1[i + 1] = d1[1]; w1[i + 2] = d1[2]; w1[i + 3] = d1[3]
            w2[i] = d2[0]; w2[i + 1] = d2[1]; w2[i + 2] = d2[2]; w2[i + 3] = d2[3]
            i += 4
        }
        while i < count {
            w0[i] = g[i] - anchorOffset
            w1[i] = r[i] - g[i]
            w2[i] = b[i] - g[i]
            i += 1
        }
        return [w0, w1, w2]
    }

    /// Vectorised 3-component Part 2 reversible dependency inverse transform (`SIMD4<Int64>`).
    internal static func inversePart2ReversibleDep3(
        c0: [Int64],
        c1: [Int64],
        c2: [Int64],
        a10: Int64,
        shift1: Int,
        a20: Int64,
        a21: Int64,
        shift2: Int,
        offsets: [Int64]
    ) -> [[Int64]] {
        let count = min(c0.count, min(c1.count, c2.count))
        var out0 = Array(repeating: Int64(0), count: count)
        var out1 = Array(repeating: Int64(0), count: count)
        var out2 = Array(repeating: Int64(0), count: count)

        let o0 = SIMD4<Int64>(repeating: offsets[0])
        let o1 = SIMD4<Int64>(repeating: offsets[1])
        let o2 = SIMD4<Int64>(repeating: offsets[2])
        let vA10 = SIMD4<Int64>(repeating: a10)
        let vA20 = SIMD4<Int64>(repeating: a20)
        let vA21 = SIMD4<Int64>(repeating: a21)
        let half1 = SIMD4<Int64>(repeating: (shift1 > 0) ? (Int64(1) << (shift1 - 1)) : 0)
        let half2 = SIMD4<Int64>(repeating: (shift2 > 0) ? (Int64(1) << (shift2 - 1)) : 0)
        let s1 = SIMD4<Int64>(repeating: Int64(shift1))
        let s2 = SIMD4<Int64>(repeating: Int64(shift2))

        var i = 0
        while i + 4 <= count {
            let x0 = SIMD4<Int64>(c0[i], c0[i + 1], c0[i + 2], c0[i + 3])
            let x1 = SIMD4<Int64>(c1[i], c1[i + 1], c1[i + 2], c1[i + 3])
            let x2 = SIMD4<Int64>(c2[i], c2[i + 1], c2[i + 2], c2[i + 3])
            let y0 = x0 &+ o0
            let p1 = (vA10 &* y0 &+ half1) &>> s1
            let y1 = x1 &+ p1 &+ o1
            let p2 = (vA20 &* y0 &+ vA21 &* y1 &+ half2) &>> s2
            let y2 = x2 &+ p2 &+ o2
            out0[i] = y0[0]; out0[i + 1] = y0[1]; out0[i + 2] = y0[2]; out0[i + 3] = y0[3]
            out1[i] = y1[0]; out1[i + 1] = y1[1]; out1[i + 2] = y1[2]; out1[i + 3] = y1[3]
            out2[i] = y2[0]; out2[i + 1] = y2[1]; out2[i + 2] = y2[2]; out2[i + 3] = y2[3]
            i += 4
        }
        let scHalf1: Int64 = (shift1 > 0) ? (Int64(1) << (shift1 - 1)) : 0
        let scHalf2: Int64 = (shift2 > 0) ? (Int64(1) << (shift2 - 1)) : 0
        while i < count {
            let y0 = c0[i] &+ offsets[0]
            let y1 = c1[i] &+ ((a10 &* y0 &+ scHalf1) >> shift1) &+ offsets[1]
            let y2 = c2[i] &+ ((a20 &* y0 &+ a21 &* y1 &+ scHalf2) >> shift2) &+ offsets[2]
            out0[i] = y0
            out1[i] = y1
            out2[i] = y2
            i += 1
        }
        return [out0, out1, out2]
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
        guard band.width > 0, band.height > 0 else { return }
        let invStep = 1.0 / step
        let maxMag = (Int64(1) << mb) - 1
        let invStepVec = SIMD4<Double>(repeating: invStep)

        doublePlane.withUnsafeBufferPointer { srcBuf in
            quantisedPlane.withUnsafeMutableBufferPointer { dstBuf in
                let sp = srcBuf.baseAddress!
                let dp = dstBuf.baseAddress!
                let workers = AcceleratedCodec.activeWorkerLimit
                let rowStrips = (band.height + 15) / 16
                if workers > 1 && !BoundedParallelPool.isInsideParallelRegion && rowStrips >= 2 && (band.width * band.height >= 16_384) {
                    let sSrc = UnsafeSendableBuffer(srcBuf)
                    let sDst = UnsafeSendableMutableBuffer(dstBuf)
                    BoundedParallelPool.forEachNonThrowing(jobCount: rowStrips, maxWorkers: workers) { stripIdx in
                        let rStart = stripIdx * 16
                        let rEnd = min(band.height, rStart + 16)
                        let srcP = sSrc.baseAddress
                        let dstP = sDst.baseAddress
                        for row in rStart..<rEnd {
                            let rBase = (band.planeY + row) * stride + band.planeX
                            var col = 0
                            while col + 4 <= band.width {
                                let idx = rBase + col
                                let v = SIMD4<Double>(srcP[idx], srcP[idx + 1], srcP[idx + 2], srcP[idx + 3])
                                let absV = pointwiseMax(v, -v)
                                let scaled = (absV * invStepVec).rounded(.down)
                                for lane in 0..<4 {
                                    let val = v[lane]
                                    let qMag = min(maxMag, Int64(scaled[lane]))
                                    dstP[idx + lane] = val < 0 ? -qMag : qMag
                                }
                                col += 4
                            }
                            while col < band.width {
                                let idx = rBase + col
                                let val = srcP[idx]
                                let qMag = min(maxMag, Int64(floor(abs(val) * invStep)))
                                dstP[idx] = val < 0 ? -qMag : qMag
                                col += 1
                            }
                        }
                    }
                } else {
                    for row in 0..<band.height {
                        let rBase = (band.planeY + row) * stride + band.planeX
                        var col = 0
                        while col + 4 <= band.width {
                            let idx = rBase + col
                            let v = SIMD4<Double>(sp[idx], sp[idx + 1], sp[idx + 2], sp[idx + 3])
                            let absV = pointwiseMax(v, -v)
                            let scaled = (absV * invStepVec).rounded(.down)
                            for lane in 0..<4 {
                                let val = v[lane]
                                let qMag = min(maxMag, Int64(scaled[lane]))
                                dp[idx + lane] = val < 0 ? -qMag : qMag
                            }
                            col += 4
                        }
                        while col < band.width {
                            let idx = rBase + col
                            let val = sp[idx]
                            let qMag = min(maxMag, Int64(floor(abs(val) * invStep)))
                            dp[idx] = val < 0 ? -qMag : qMag
                            col += 1
                        }
                    }
                }
            }
        }
    }

    /// Vectorised dead-zone quantization of a subband rectangle in `doublePlane` directly into a 32-bit `quantisedPlane`.
    internal static func quantizeSubband32(
        doublePlane: [Double],
        quantisedPlane: inout [Int32],
        stride: Int,
        band: BandGeometry,
        step: Double,
        mb: Int
    ) {
        guard band.width > 0, band.height > 0 else { return }
        let invStep = 1.0 / step
        let maxMag = (Int64(1) << min(30, mb)) - 1
        let maxMagD = Double(maxMag)
        let invStepVec = SIMD4<Double>(repeating: invStep)
        let maxMagVec = SIMD4<Double>(repeating: maxMagD)

        doublePlane.withUnsafeBufferPointer { srcBuf in
            quantisedPlane.withUnsafeMutableBufferPointer { dstBuf in
                let sp = srcBuf.baseAddress!
                let dp = dstBuf.baseAddress!
                let workers = AcceleratedCodec.activeWorkerLimit
                let rowStrips = (band.height + 15) / 16
                if workers > 1 && !BoundedParallelPool.isInsideParallelRegion && rowStrips >= 2 && (band.width * band.height >= 16_384) {
                    let sSrc = UnsafeSendableBuffer(srcBuf)
                    let sDst = UnsafeSendableMutableBuffer(dstBuf)
                    BoundedParallelPool.forEachNonThrowing(jobCount: rowStrips, maxWorkers: workers) { stripIdx in
                        let rStart = stripIdx * 16
                        let rEnd = min(band.height, rStart + 16)
                        let srcP = sSrc.baseAddress
                        let dstP = sDst.baseAddress
                        for row in rStart..<rEnd {
                            let rBase = (band.planeY + row) * stride + band.planeX
                            var col = 0
                            while col + 4 <= band.width {
                                let idx = rBase + col
                                let v = SIMD4<Double>(srcP[idx], srcP[idx + 1], srcP[idx + 2], srcP[idx + 3])
                                let absV = pointwiseMax(v, -v)
                                let scaled = pointwiseMin(maxMagVec, (absV * invStepVec).rounded(.down))
                                for lane in 0..<4 {
                                    let val = v[lane]
                                    let qMag = Int32(scaled[lane])
                                    dstP[idx + lane] = val < 0 ? -qMag : qMag
                                }
                                col += 4
                            }
                            while col < band.width {
                                let idx = rBase + col
                                let val = srcP[idx]
                                let qMag = Int32(min(maxMagD, floor(abs(val) * invStep)))
                                dstP[idx] = val < 0 ? -qMag : qMag
                                col += 1
                            }
                        }
                    }
                } else {
                    for row in 0..<band.height {
                        let rBase = (band.planeY + row) * stride + band.planeX
                        var col = 0
                        while col + 4 <= band.width {
                            let idx = rBase + col
                            let v = SIMD4<Double>(sp[idx], sp[idx + 1], sp[idx + 2], sp[idx + 3])
                            let absV = pointwiseMax(v, -v)
                            let scaled = pointwiseMin(maxMagVec, (absV * invStepVec).rounded(.down))
                            for lane in 0..<4 {
                                let val = v[lane]
                                let qMag = Int32(scaled[lane])
                                dp[idx + lane] = val < 0 ? -qMag : qMag
                            }
                            col += 4
                        }
                        while col < band.width {
                            let idx = rBase + col
                            let val = sp[idx]
                            let qMag = Int32(min(maxMagD, floor(abs(val) * invStep)))
                            dp[idx] = val < 0 ? -qMag : qMag
                            col += 1
                        }
                    }
                }
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
    /// Pre-classified 2×2 quad information produced by vectorised `SIMD4<Int32>` or Metal GPU quad
    /// classification per ITU-T Rec. T.814 Clauses 7.2 and 7.3.2.
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

    /// Vectorised 2×2 quad classification directly from a strided `Int32` plane into `workspace.quads`.
    /// Returns `true` iff at least one quad in the block has `rho != 0`.
    internal static func classifyQuadsStrided(
        planeBase: UnsafePointer<Int32>,
        planeOrigin: Int,
        stride: Int,
        width: Int,
        height: Int,
        bandShift: Int,
        into quads: inout [PreclassifiedQuad]
    ) throws -> Bool {
        let qw = (width + 1) / 2
        let qh = (height + 1) / 2
        let quadCount = qw * qh
        guard quadCount > 0 else {
            quads.removeAll(keepingCapacity: true)
            return false
        }

        let oneVec = SIMD4<UInt32>(repeating: 1)
        let zeroQuad = PreclassifiedQuad(
            rho: 0, eQMax: 0,
            eQ0: 0, eQ1: 0, eQ2: 0, eQ3: 0,
            s0: 0, s1: 0, s2: 0, s3: 0
        )
        if quads.count != quadCount {
            quads = [PreclassifiedQuad](repeating: zeroQuad, count: quadCount)
        }

        return try quads.withUnsafeMutableBufferPointer { quadBuf -> Bool in
            guard let qPtr = quadBuf.baseAddress else { return false }
            var anyActive = false
            var qIdx = 0

            for qy in 0..<qh {
                let baseY = qy * 2
                let y1Valid = (baseY + 1) < height
                let r0 = planeOrigin + baseY * stride
                let r1 = y1Valid ? (r0 + stride) : r0

                for qx in 0..<qw {
                    let baseX = qx * 2
                    let x1Valid = (baseX + 1) < width

                    let raw = SIMD4<Int32>(
                        planeBase[r0 + baseX],
                        y1Valid ? planeBase[r1 + baseX] : 0,
                        x1Valid ? planeBase[r0 + baseX + 1] : 0,
                        (x1Valid && y1Valid) ? planeBase[r1 + baseX + 1] : 0
                    )

                    if raw == .zero {
                        qPtr[qIdx] = zeroQuad
                        qIdx += 1
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
                        qPtr[qIdx] = zeroQuad
                        qIdx += 1
                        continue
                    }

                    anyActive = true
                    let twoMuMinusOne = (muVec &<< oneVec) &- oneVec
                    let payloadVec = (twoMuMinusOne &- oneVec) &+ signVec

                    let eQ0 = (rho & 1) != 0 ? (32 - twoMuMinusOne[0].leadingZeroBitCount) : 0
                    let eQ1 = (rho & 2) != 0 ? (32 - twoMuMinusOne[1].leadingZeroBitCount) : 0
                    let eQ2 = (rho & 4) != 0 ? (32 - twoMuMinusOne[2].leadingZeroBitCount) : 0
                    let eQ3 = (rho & 8) != 0 ? (32 - twoMuMinusOne[3].leadingZeroBitCount) : 0
                    let eQMax = max(max(eQ0, eQ1), max(eQ2, eQ3))

                    qPtr[qIdx] = PreclassifiedQuad(
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
                    )
                    qIdx += 1
                }
            }
            return anyActive
        }
    }

    /// Vectorised 2×2 quad classification across an entire code-block using `SIMD4<Int32>` and
    /// `SIMD4<UInt32>` lane operations.
    internal static func classifyQuads(
        coefficients: [Int32],
        width: Int,
        height: Int,
        bandShift: Int
    ) throws -> [PreclassifiedQuad] {
        var quads: [PreclassifiedQuad] = []
        try coefficients.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            _ = try classifyQuadsStrided(
                planeBase: base,
                planeOrigin: 0,
                stride: width,
                width: width,
                height: height,
                bandShift: bandShift,
                into: &quads
            )
        }
        return quads
    }

    /// Zero-intermediate-allocation strided SIMD HTJ2K cleanup encoder.
    internal static func encodeCleanupStrided(
        planeBase: UnsafePointer<Int32>,
        planeOrigin: Int,
        stride: Int,
        width: Int,
        height: Int,
        bandShift: Int = 0,
        maximumOutputBytes: Int = Int.max,
        workspace: HTBlockEncoder.Workspace
    ) throws -> [UInt8] {
        guard width >= 1, height >= 1 else {
            throw CodecError(.invalidArgument, "HTJ2K block dimensions must be positive.")
        }
        guard bandShift >= 0, bandShift < 31 else {
            throw CodecError(.invalidArgument, "HTJ2K cleanup bit-plane shift (\(bandShift)) is out of range.")
        }
        let anyActive = try classifyQuadsStrided(
            planeBase: planeBase,
            planeOrigin: planeOrigin,
            stride: stride,
            width: width,
            height: height,
            bandShift: bandShift,
            into: &workspace.quads
        )
        if !anyActive {
            return []
        }
        return try HTBlockEncoder.encodePreclassifiedCleanupWithWorkspace(
            quads: workspace.quads,
            width: width,
            height: height,
            maximumOutputBytes: maximumOutputBytes,
            workspace: workspace
        )
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
        preclassifiedQuads: [PreclassifiedQuad]? = nil,
        budget: EntropyOutputBudget? = nil
    ) throws -> [UInt8] {
        guard width >= 1, height >= 1, coefficients.count == width * height else {
            throw CodecError(.invalidArgument, "HTJ2K block dimensions do not match coefficient count.")
        }
        guard bandShift >= 0, bandShift < 31 else {
            throw CodecError(.invalidArgument, "HTJ2K cleanup bit-plane shift (\(bandShift)) is out of range.")
        }

        if budget == nil && preclassifiedQuads == nil {
            let ws = HTBlockEncoder.Workspace(maxQuads: ((width + 1) / 2) * ((height + 1) / 2), maxWidth: max(width, height))
            return try coefficients.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return [] }
                return try encodeCleanupStrided(
                    planeBase: base,
                    planeOrigin: 0,
                    stride: width,
                    width: width,
                    height: height,
                    bandShift: bandShift,
                    maximumOutputBytes: maximumOutputBytes,
                    workspace: ws
                )
            }
        }

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

        return try HTBlockEncoder.encodePreclassifiedCleanup(
            quads: quads,
            width: width,
            height: height,
            maximumOutputBytes: maximumOutputBytes,
            budget: budget
        )
    }

    /// Decode an ITU-T Rec. T.814 HTJ2K cleanup segment.
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
