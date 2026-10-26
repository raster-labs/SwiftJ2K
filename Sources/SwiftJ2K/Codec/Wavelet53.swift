// SPDX-License-Identifier: Apache-2.0
//
// Reversible 5/3 discrete wavelet transform (ISO/IEC 15444-1 Annex F, F.3.8.2
// and F.4.8.2, lifting form with periodic symmetric extension) over signals
// that start at an arbitrary coordinate `i0`, as tiles and image origins
// require (Milestone 4). Parity of the absolute coordinate decides which
// samples are low-pass.
//
// Provenance: the one-dimensional lifting kernels were adapted in Milestone 2
// from Raster-Lab/J2KSwift at commit 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca,
// Sources/J2KCodec/J2KDWT1D.swift (MIT, relicensed Apache-2.0 under POL-07),
// for the origin-0 case; the general-origin form below follows the standard's
// equations F-5, F-6, F-7 and F-8 directly. The two-dimensional driver works
// in place on the nested subband layout, applying VER_SD then HOR_SD on
// analysis and HOR_SR then VER_SR on synthesis.

enum Wavelet53 {
    /// ceil(a / b) for b > 0 and any sign of a.
    @inline(__always)
    static func ceilDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? (a + b - 1) / b : -((-a) / b) }

    /// floor(a / b) for b > 0 and any sign of a.
    @inline(__always)
    static func floorDiv(_ a: Int, _ b: Int) -> Int { a >= 0 ? a / b : -((-a + b - 1) / b) }

    /// ceil(value / 2^power).
    static func ceilDivPowerOfTwo(_ value: Int, _ power: Int) -> Int {
        power > 0 ? ceilDiv(value, 1 << power) : value
    }

    /// Number of low-pass samples of the interval [i0, i1).
    static func lowCount(_ i0: Int, _ i1: Int) -> Int { ceilDiv(i1, 2) - ceilDiv(i0, 2) }
    /// Number of high-pass samples of the interval [i0, i1).
    static func highCount(_ i0: Int, _ i1: Int) -> Int { floorDiv(i1, 2) - floorDiv(i0, 2) }

    /// Periodic symmetric extension of an interleaved signal stored in
    /// `y[0..<n]` for coordinates [i0, i0+n): value at absolute coordinate `i`.
    @inline(__always)
    private static func extended(_ y: [Int32], i0: Int, n: Int, at i: Int) -> Int32 {
        var k = i - i0
        if n == 1 { return y[0] }
        let period = 2 * (n - 1)
        k = ((k % period) + period) % period
        if k >= n { k = period - k }
        return y[k]
    }

    /// 1D_SD: analyses `x` (coordinates [i0, i0+n)) into `low`/`high`.
    static func analyse(_ x: [Int32], i0: Int, count n: Int, into low: inout [Int32], _ high: inout [Int32]) {
        let i1 = i0 + n
        if n == 1 {
            if i0 & 1 == 0 { low[0] = x[0] } else { high[0] = x[0] * 2 }
            return
        }
        // Y(2n+1) = X(2n+1) - floor((X(2n) + X(2n+2)) / 2) for odd coordinates in [i0-1, i1+1)
        // Y(2n)   = X(2n) + floor((Y(2n-1) + Y(2n+1) + 2) / 4) for even coordinates in [i0, i1)
        var oddValues: [Int32] = []            // Y at odd coordinates from firstOdd upward
        let firstOdd = (i0 - 1) | 1            // largest odd <= i0 - 1... (i0-1)|1 is odd and >= i0-1
        let lastOdd = ((i1 + 1) & ~1) - 1      // largest odd < i1 + 1
        oddValues.reserveCapacity((lastOdd - firstOdd) / 2 + 1)
        var i = firstOdd
        while i <= lastOdd {
            let left = extended(x, i0: i0, n: n, at: i - 1), right = extended(x, i0: i0, n: n, at: i + 1)
            oddValues.append(extended(x, i0: i0, n: n, at: i) - ((left + right) >> 1))
            i += 2
        }
        @inline(__always) func oddY(_ coordinate: Int) -> Int32 { oddValues[(coordinate - firstOdd) / 2] }
        var lowIndex = 0, highIndex = 0
        for coordinate in i0..<i1 {
            if coordinate & 1 == 0 {
                low[lowIndex] = x[coordinate - i0] + ((oddY(coordinate - 1) + oddY(coordinate + 1) + 2) >> 2)
                lowIndex += 1
            } else {
                high[highIndex] = oddY(coordinate)
                highIndex += 1
            }
        }
    }

    /// 1D_SR: reconstructs `x` over [i0, i0+n) from `low`/`high`.
    static func synthesise(low: [Int32], high: [Int32], i0: Int, count n: Int, into x: inout [Int32]) throws {
        let i1 = i0 + n
        if n == 1 {
            x[0] = i0 & 1 == 0 ? low[0] : high[0] / 2
            return
        }
        // Interleave into Y over [i0, i1).
        var y = [Int32](repeating: 0, count: n)
        var lowIndex = 0, highIndex = 0
        for coordinate in i0..<i1 {
            if coordinate & 1 == 0 { y[coordinate - i0] = low[lowIndex]; lowIndex += 1 }
            else { y[coordinate - i0] = high[highIndex]; highIndex += 1 }
        }
        // X(2n) = Y(2n) - floor((Y(2n-1) + Y(2n+1) + 2) / 4) for even coordinates in [i0-1, i1+1)
        var evenValues: [Int32] = []
        let firstEven = (i0 - 1) & ~1          // largest even <= i0 - 1
        let lastEven = i1 & ~1                 // largest even <= i1 (covers X(2n+2) at the right edge)
        evenValues.reserveCapacity((lastEven - firstEven) / 2 + 1)
        var i = firstEven
        while i <= lastEven {
            let left = Int64(extended(y, i0: i0, n: n, at: i - 1))
            let right = Int64(extended(y, i0: i0, n: n, at: i + 1))
            let center = Int64(extended(y, i0: i0, n: n, at: i))
            let even = center - ((left + right + 2) >> 2)
            guard even >= Int64(Int32.min), even <= Int64(Int32.max) else {
                throw CodecError(.malformedInput, "Wavelet synthesis overflowed the 32-bit coefficient range.")
            }
            evenValues.append(Int32(even))
            i += 2
        }
        @inline(__always) func evenX(_ coordinate: Int) -> Int32 { evenValues[(coordinate - firstEven) / 2] }
        // X(2n+1) = Y(2n+1) + floor((X(2n) + X(2n+2)) / 2) for odd coordinates in [i0, i1)
        for coordinate in i0..<i1 {
            if coordinate & 1 == 0 {
                x[coordinate - i0] = evenX(coordinate)
            } else {
                let odd = Int64(y[coordinate - i0]) + ((Int64(evenX(coordinate - 1)) + Int64(evenX(coordinate + 1))) >> 1)
                guard odd >= Int64(Int32.min), odd <= Int64(Int32.max) else {
                    throw CodecError(.malformedInput, "Wavelet synthesis overflowed the 32-bit coefficient range.")
                }
                x[coordinate - i0] = Int32(odd)
            }
        }
    }

    /// Forward transform of a tile-component whose samples occupy the region
    /// [x0, x1) × [y0, y1) of the reference grid, stored in `plane` with row
    /// stride `stride` and origin at `plane[0]`, for `levels` levels, leaving
    /// the nested subband layout in place.
    static func forward(plane: inout [Int32], stride: Int, x0: Int, x1: Int, y0: Int, y1: Int,
                        levels: Int, cancellation: () throws -> Void) throws {
        var line = [Int32](repeating: 0, count: max(x1 - x0, y1 - y0))
        var low = [Int32](repeating: 0, count: line.count / 2 + 1)
        var high = [Int32](repeating: 0, count: line.count / 2 + 1)
        for level in 1...max(levels, 1) where levels > 0 {
            let rx0 = ceilDivPowerOfTwo(x0, level - 1), rx1 = ceilDivPowerOfTwo(x1, level - 1)
            let ry0 = ceilDivPowerOfTwo(y0, level - 1), ry1 = ceilDivPowerOfTwo(y1, level - 1)
            let w = rx1 - rx0, h = ry1 - ry0
            guard w > 0, h > 0 else { continue }
            // VER_SD on every column, then HOR_SD on every row (F.4.8.2).
            let lowH = lowCount(ry0, ry1), lowW = lowCount(rx0, rx1)
            for x in 0..<w {
                for y in 0..<h { line[y] = plane[y * stride + x] }
                analyse(line, i0: ry0, count: h, into: &low, &high)
                for i in 0..<lowH { plane[i * stride + x] = low[i] }
                for i in 0..<(h - lowH) { plane[(lowH + i) * stride + x] = high[i] }
                if x & 63 == 63 { try cancellation() }
            }
            for y in 0..<h {
                for x in 0..<w { line[x] = plane[y * stride + x] }
                analyse(line, i0: rx0, count: w, into: &low, &high)
                for i in 0..<lowW { plane[y * stride + i] = low[i] }
                for i in 0..<(w - lowW) { plane[y * stride + lowW + i] = high[i] }
                if y & 63 == 63 { try cancellation() }
            }
            try cancellation()
        }
    }

    /// Inverse transform: reverses `forward` for the same geometry.
    static func inverse(plane: inout [Int32], stride: Int, x0: Int, x1: Int, y0: Int, y1: Int,
                        levels: Int, cancellation: () throws -> Void) throws {
        var line = [Int32](repeating: 0, count: max(x1 - x0, y1 - y0))
        var low = [Int32](repeating: 0, count: line.count / 2 + 1)
        var high = [Int32](repeating: 0, count: line.count / 2 + 1)
        for level in Swift.stride(from: levels, through: 1, by: -1) {
            let rx0 = ceilDivPowerOfTwo(x0, level - 1), rx1 = ceilDivPowerOfTwo(x1, level - 1)
            let ry0 = ceilDivPowerOfTwo(y0, level - 1), ry1 = ceilDivPowerOfTwo(y1, level - 1)
            let w = rx1 - rx0, h = ry1 - ry0
            guard w > 0, h > 0 else { continue }
            // HOR_SR on every row, then VER_SR on every column (F.3.8).
            let lowW = lowCount(rx0, rx1), lowH = lowCount(ry0, ry1)
            for y in 0..<h {
                for i in 0..<lowW { low[i] = plane[y * stride + i] }
                for i in 0..<(w - lowW) { high[i] = plane[y * stride + lowW + i] }
                try synthesise(low: low, high: high, i0: rx0, count: w, into: &line)
                for x in 0..<w { plane[y * stride + x] = line[x] }
                if y & 63 == 63 { try cancellation() }
            }
            for x in 0..<w {
                for i in 0..<lowH { low[i] = plane[i * stride + x] }
                for i in 0..<(h - lowH) { high[i] = plane[(lowH + i) * stride + x] }
                try synthesise(low: low, high: high, i0: ry0, count: h, into: &line)
                for y in 0..<h { plane[y * stride + x] = line[y] }
                if x & 63 == 63 { try cancellation() }
            }
            try cancellation()
        }
    }
}
