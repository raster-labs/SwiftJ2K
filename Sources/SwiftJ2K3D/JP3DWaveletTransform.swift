// SPDX-License-Identifier: Apache-2.0
//
// JP3DWaveletTransform.swift
// SwiftJ2K3D
//
// Migrated from Raster-Lab/J2KSwift Sources/J2K3D/JP3DWaveletTransform.swift
// at commit 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca.

import Foundation
import SwiftJ2K

// MARK: - Filter Type

/// Wavelet filter kernel for 3D DWT operations.
public enum JP3DWaveletFilter: Sendable, Equatable {
    /// Le Gall 5/3 reversible filter (integer arithmetic, lossless-capable).
    case reversible53
    /// CDF 9/7 irreversible filter (floating-point, higher compression efficiency).
    case irreversible97
}

// MARK: - Transform Mode

/// Axis ordering strategy for the 3D DWT.
public enum JP3DTransformMode: Sendable, Equatable {
    /// Apply X, Y, and Z filtering in a single conceptual 3D pass.
    case full3D
    /// Apply 2D XY transform first, then 1D Z transform.
    case separable
}

// MARK: - Boundary Extension Mode

/// Boundary extension strategy applied at signal edges during convolution.
public enum JP3DBoundaryMode: Sendable, Equatable {
    /// Whole-sample symmetric (mirror) extension.
    case symmetric
    /// Periodic (wrap-around) extension.
    case periodic
    /// Zero-padding extension.
    case zeroPadding
}

// MARK: - Configuration

/// Configuration for the JP3D 3D discrete wavelet transform.
public struct JP3DTransformConfiguration: Sendable, Equatable {
    /// Wavelet filter kernel to apply.
    public let filter: JP3DWaveletFilter
    /// Axis ordering strategy.
    public let mode: JP3DTransformMode
    /// Boundary extension mode.
    public let boundary: JP3DBoundaryMode
    /// Number of decomposition levels along the X axis.
    public let levelsX: Int
    /// Number of decomposition levels along the Y axis.
    public let levelsY: Int
    /// Number of decomposition levels along the Z axis.
    public let levelsZ: Int

    /// Creates a transform configuration.
    public init(
        filter: JP3DWaveletFilter = .reversible53,
        mode: JP3DTransformMode = .separable,
        boundary: JP3DBoundaryMode = .symmetric,
        levelsX: Int = 3,
        levelsY: Int = 3,
        levelsZ: Int = 1
    ) {
        self.filter = filter
        self.mode = mode
        self.boundary = boundary
        self.levelsX = max(0, levelsX)
        self.levelsY = max(0, levelsY)
        self.levelsZ = max(0, levelsZ)
    }

    /// Default lossless configuration: 5/3 filter, separable mode, 3/3/1 levels.
    public static let defaultLossless = JP3DTransformConfiguration(
        filter: .reversible53, mode: .separable, boundary: .symmetric,
        levelsX: 3, levelsY: 3, levelsZ: 1
    )

    /// Default lossy configuration: 9/7 filter, separable mode, 3/3/1 levels.
    public static let defaultLossy = JP3DTransformConfiguration(
        filter: .irreversible97, mode: .separable, boundary: .symmetric,
        levelsX: 3, levelsY: 3, levelsZ: 1
    )
}

// MARK: - Result Type

/// The result of a 3D wavelet forward transform.
public struct JP3DSubbandDecomposition: Sendable {
    /// Width of the coefficient array (equals original width).
    public let width: Int
    /// Height of the coefficient array (equals original height).
    public let height: Int
    /// Depth of the coefficient array (equals original depth).
    public let depth: Int
    /// Number of decomposition levels applied along X.
    public let levelsX: Int
    /// Number of decomposition levels applied along Y.
    public let levelsY: Int
    /// Number of decomposition levels applied along Z.
    public let levelsZ: Int
    /// All subband coefficients stored in a flat in-place layout.
    public var coefficients: J2K3DCoefficients
    /// Original signal width before transform.
    public let originalWidth: Int
    /// Original signal height before transform.
    public let originalHeight: Int
    /// Original signal depth before transform.
    public let originalDepth: Int

    public init(
        width: Int,
        height: Int,
        depth: Int,
        levelsX: Int,
        levelsY: Int,
        levelsZ: Int,
        coefficients: J2K3DCoefficients,
        originalWidth: Int,
        originalHeight: Int,
        originalDepth: Int
    ) {
        self.width = width
        self.height = height
        self.depth = depth
        self.levelsX = levelsX
        self.levelsY = levelsY
        self.levelsZ = levelsZ
        self.coefficients = coefficients
        self.originalWidth = originalWidth
        self.originalHeight = originalHeight
        self.originalDepth = originalDepth
    }
}

// MARK: - Actor

/// Three-dimensional discrete wavelet transform for JP3D volumetric data.
public actor JP3DWaveletTransform {
    // MARK: - State

    private let configuration: JP3DTransformConfiguration

    // MARK: - Init

    /// Creates a wavelet transform processor with the given configuration.
    public init(configuration: JP3DTransformConfiguration = .defaultLossless) {
        self.configuration = configuration
    }

    // MARK: - Public API

    /// Performs a forward 3D DWT on flat volume data.
    public func forward(
        data: [Float],
        width: Int,
        height: Int,
        depth: Int
    ) async throws -> JP3DSubbandDecomposition {
        guard width > 0, height > 0, depth > 0 else {
            throw J2KError.invalidParameter("Dimensions must be positive: \(width)×\(height)×\(depth)")
        }
        guard data.count == width * height * depth else {
            throw J2KError.invalidParameter(
                "Data count \(data.count) does not match \(width)×\(height)×\(depth) = \(width * height * depth)"
            )
        }

        let maxLX = maxLevels(for: width)
        let maxLY = maxLevels(for: height)
        let maxLZ = maxLevels(for: depth)
        let lx = min(configuration.levelsX, maxLX)
        let ly = min(configuration.levelsY, maxLY)
        let lz = min(configuration.levelsZ, maxLZ)

        var buf = data
        applyForward3D(&buf, width: width, height: height, depth: depth,
                       levelsX: lx, levelsY: ly, levelsZ: lz)

        let coeffs = J2K3DCoefficients(
            width: width, height: height, depth: depth,
            decompositionLevels: max(lx, ly, lz),
            data: buf
        )

        return JP3DSubbandDecomposition(
            width: width, height: height, depth: depth,
            levelsX: lx, levelsY: ly, levelsZ: lz,
            coefficients: coeffs,
            originalWidth: width, originalHeight: height, originalDepth: depth
        )
    }

    /// Performs an inverse 3D DWT, reconstructing the original signal.
    public func inverse(
        decomposition: JP3DSubbandDecomposition
    ) async throws -> [Float] {
        let width  = decomposition.width
        let height = decomposition.height
        let depth  = decomposition.depth
        guard width > 0, height > 0, depth > 0 else {
            throw J2KError.invalidParameter("Decomposition has invalid dimensions")
        }
        guard decomposition.coefficients.data.count == width * height * depth else {
            throw J2KError.invalidParameter("Coefficient buffer size mismatch")
        }

        var buf = decomposition.coefficients.data
        applyInverse3D(
            &buf, width: width, height: height, depth: depth,
            levelsX: decomposition.levelsX,
            levelsY: decomposition.levelsY,
            levelsZ: decomposition.levelsZ
        )
        return buf
    }

    // MARK: - Forward 3D (separable / full3D)

    private func applyForward3D(
        _ buf: inout [Float],
        width: Int, height: Int, depth: Int,
        levelsX: Int, levelsY: Int, levelsZ: Int
    ) {
        var curW = width, curH = height, curD = depth

        for lvl in 0..<max(levelsX, max(levelsY, levelsZ)) {
            let doX = lvl < levelsX
            let doY = lvl < levelsY
            let doZ = lvl < levelsZ

            if doX {
                forwardX(&buf, totalW: width, totalH: height, totalD: depth,
                         activeW: curW, activeH: curH, activeD: curD)
            }
            if doY {
                forwardY(&buf, totalW: width, totalH: height, totalD: depth,
                         activeW: curW, activeH: curH, activeD: curD)
            }
            if doZ {
                forwardZ(&buf, totalW: width, totalH: height, totalD: depth,
                         activeW: curW, activeH: curH, activeD: curD)
            }

            if doX { curW = (curW + 1) / 2 }
            if doY { curH = (curH + 1) / 2 }
            if doZ { curD = (curD + 1) / 2 }
        }
    }

    // MARK: - Inverse 3D

    private func applyInverse3D(
        _ buf: inout [Float],
        width: Int, height: Int, depth: Int,
        levelsX: Int, levelsY: Int, levelsZ: Int
    ) {
        var wStack = [Int](), hStack = [Int](), dStack = [Int]()
        var curW = width, curH = height, curD = depth
        for lvl in 0..<max(levelsX, max(levelsY, levelsZ)) {
            wStack.append(curW); hStack.append(curH); dStack.append(curD)
            if lvl < levelsX { curW = (curW + 1) / 2 }
            if lvl < levelsY { curH = (curH + 1) / 2 }
            if lvl < levelsZ { curD = (curD + 1) / 2 }
        }

        let maxLevel = max(levelsX, max(levelsY, levelsZ))
        for lvl in stride(from: maxLevel - 1, through: 0, by: -1) {
            let aw = wStack[lvl], ah = hStack[lvl], ad = dStack[lvl]
            let doZ = lvl < levelsZ
            let doY = lvl < levelsY
            let doX = lvl < levelsX

            if doZ {
                inverseZ(&buf, totalW: width, totalH: height, totalD: depth,
                         activeW: aw, activeH: ah, activeD: ad)
            }
            if doY {
                inverseY(&buf, totalW: width, totalH: height, totalD: depth,
                         activeW: aw, activeH: ah, activeD: ad)
            }
            if doX {
                inverseX(&buf, totalW: width, totalH: height, totalD: depth,
                         activeW: aw, activeH: ah, activeD: ad)
            }
        }
    }

    // MARK: - Axis Passes (Forward)

    private func forwardX(
        _ buf: inout [Float],
        totalW: Int, totalH: Int, totalD: Int,
        activeW: Int, activeH: Int, activeD: Int
    ) {
        guard activeW > 1 else { return }
        var row = [Float](repeating: 0, count: activeW)
        for z in 0..<activeD {
            for y in 0..<activeH {
                let base = z * totalW * totalH + y * totalW
                for x in 0..<activeW { row[x] = buf[base + x] }
                forwardDWT1D(&row)
                for x in 0..<activeW { buf[base + x] = row[x] }
            }
        }
    }

    private func forwardY(
        _ buf: inout [Float],
        totalW: Int, totalH: Int, totalD: Int,
        activeW: Int, activeH: Int, activeD: Int
    ) {
        guard activeH > 1 else { return }
        var col = [Float](repeating: 0, count: activeH)
        for z in 0..<activeD {
            for x in 0..<activeW {
                let zBase = z * totalW * totalH
                for y in 0..<activeH { col[y] = buf[zBase + y * totalW + x] }
                forwardDWT1D(&col)
                for y in 0..<activeH { buf[zBase + y * totalW + x] = col[y] }
            }
        }
    }

    private func forwardZ(
        _ buf: inout [Float],
        totalW: Int, totalH: Int, totalD: Int,
        activeW: Int, activeH: Int, activeD: Int
    ) {
        guard activeD > 1 else { return }
        let sliceSize = totalW * totalH
        var pillar = [Float](repeating: 0, count: activeD)
        for y in 0..<activeH {
            for x in 0..<activeW {
                let yx = y * totalW + x
                for z in 0..<activeD { pillar[z] = buf[z * sliceSize + yx] }
                forwardDWT1D(&pillar)
                for z in 0..<activeD { buf[z * sliceSize + yx] = pillar[z] }
            }
        }
    }

    // MARK: - Axis Passes (Inverse)

    private func inverseX(
        _ buf: inout [Float],
        totalW: Int, totalH: Int, totalD: Int,
        activeW: Int, activeH: Int, activeD: Int
    ) {
        guard activeW > 1 else { return }
        var row = [Float](repeating: 0, count: activeW)
        for z in 0..<activeD {
            for y in 0..<activeH {
                let base = z * totalW * totalH + y * totalW
                for x in 0..<activeW { row[x] = buf[base + x] }
                inverseDWT1D(&row)
                for x in 0..<activeW { buf[base + x] = row[x] }
            }
        }
    }

    private func inverseY(
        _ buf: inout [Float],
        totalW: Int, totalH: Int, totalD: Int,
        activeW: Int, activeH: Int, activeD: Int
    ) {
        guard activeH > 1 else { return }
        var col = [Float](repeating: 0, count: activeH)
        for z in 0..<activeD {
            for x in 0..<activeW {
                let zBase = z * totalW * totalH
                for y in 0..<activeH { col[y] = buf[zBase + y * totalW + x] }
                inverseDWT1D(&col)
                for y in 0..<activeH { buf[zBase + y * totalW + x] = col[y] }
            }
        }
    }

    private func inverseZ(
        _ buf: inout [Float],
        totalW: Int, totalH: Int, totalD: Int,
        activeW: Int, activeH: Int, activeD: Int
    ) {
        guard activeD > 1 else { return }
        let sliceSize = totalW * totalH
        var pillar = [Float](repeating: 0, count: activeD)
        for y in 0..<activeH {
            for x in 0..<activeW {
                let yx = y * totalW + x
                for z in 0..<activeD { pillar[z] = buf[z * sliceSize + yx] }
                inverseDWT1D(&pillar)
                for z in 0..<activeD { buf[z * sliceSize + yx] = pillar[z] }
            }
        }
    }

    // MARK: - 1D DWT Dispatch

    private func forwardDWT1D(_ signal: inout [Float]) {
        let n = signal.count
        guard n > 1 else { return }
        switch configuration.filter {
        case .reversible53:  forward53(&signal)
        case .irreversible97: forward97(&signal)
        }
    }

    private func inverseDWT1D(_ signal: inout [Float]) {
        let n = signal.count
        guard n > 1 else { return }
        switch configuration.filter {
        case .reversible53:  inverse53(&signal)
        case .irreversible97: inverse97(&signal)
        }
    }

    // MARK: - 5/3 Lifting (Le Gall)

    private func forward53(_ x: inout [Float]) {
        let n = x.count
        let nL = (n + 1) / 2
        let nH = n / 2

        let ext = extendSymmetric(x, leftPad: 1, rightPad: 2)
        let off = 1

        var h = [Float](repeating: 0, count: nH)
        for i in 0..<nH {
            let idx = off + 2 * i
            h[i] = ext[idx + 1] - floor((ext[idx] + ext[idx + 2]) * 0.5)
        }

        var l = [Float](repeating: 0, count: nL)
        for i in 0..<nL {
            let hPrev = (i == 0) ? h[0] : h[i - 1]
            let hCurr = (i < nH) ? h[i] : h[nH - 1]
            l[i] = ext[off + 2 * i] + floor((hPrev + hCurr + 2) * 0.25)
        }

        for i in 0..<nL { x[i]      = l[i] }
        for i in 0..<nH { x[nL + i] = h[i] }
    }

    private func inverse53(_ x: inout [Float]) {
        let n = x.count
        let nL = (n + 1) / 2
        let nH = n / 2

        let l = Array(x[0..<nL])
        let h = Array(x[nL..<nL + nH])

        var even = [Float](repeating: 0, count: nL)
        for i in 0..<nL {
            let hPrev = (i == 0) ? h[0] : h[i - 1]
            let hCurr = (i < nH) ? h[i] : h[nH - 1]
            even[i] = l[i] - floor((hPrev + hCurr + 2) * 0.25)
        }

        var odd = [Float](repeating: 0, count: nH)
        for i in 0..<nH {
            let eNext = (i + 1 < nL) ? even[i + 1] : even[nL - 1]
            odd[i] = h[i] + floor((even[i] + eNext) * 0.5)
        }

        for i in 0..<nL { x[2 * i]     = even[i] }
        for i in 0..<nH { x[2 * i + 1] = odd[i]  }
    }

    // MARK: - 9/7 CDF Lifting

    private let alpha97: Float = -1.586134342
    private let beta97: Float = -0.052980118
    private let gamma97: Float = 0.882911075
    private let delta97: Float = 0.443506852
    private let k97: Float = 1.230174105

    private func forward97(_ x: inout [Float]) {
        let n = x.count
        let nL = (n + 1) / 2
        let nH = n / 2

        var s = [Float](repeating: 0, count: nL)
        var d = [Float](repeating: 0, count: nH)
        for i in 0..<nL { s[i] = x[2 * i] }
        for i in 0..<nH { d[i] = x[2 * i + 1] }

        for i in 0..<nH {
            let sNext = (i + 1 < nL) ? s[i + 1] : s[nL - 1]
            d[i] += alpha97 * (s[i] + sNext)
        }
        for i in 0..<nL {
            let dPrev = (i == 0) ? d[0] : d[i - 1]
            let dCurr = (i < nH) ? d[i] : d[nH - 1]
            s[i] += beta97 * (dPrev + dCurr)
        }
        for i in 0..<nH {
            let sNext = (i + 1 < nL) ? s[i + 1] : s[nL - 1]
            d[i] += gamma97 * (s[i] + sNext)
        }
        for i in 0..<nL {
            let dPrev = (i == 0) ? d[0] : d[i - 1]
            let dCurr = (i < nH) ? d[i] : d[nH - 1]
            s[i] += delta97 * (dPrev + dCurr)
        }
        let invK = 1.0 / k97
        for i in 0..<nL { s[i] *= invK }
        for i in 0..<nH { d[i] *= k97  }

        for i in 0..<nL { x[i]      = s[i] }
        for i in 0..<nH { x[nL + i] = d[i] }
    }

    private func inverse97(_ x: inout [Float]) {
        let n = x.count
        let nL = (n + 1) / 2
        let nH = n / 2

        var s = Array(x[0..<nL])
        var d = Array(x[nL..<nL + nH])

        let invK = 1.0 / k97
        for i in 0..<nL { s[i] *= k97  }
        for i in 0..<nH { d[i] *= invK }

        for i in 0..<nL {
            let dPrev = (i == 0) ? d[0] : d[i - 1]
            let dCurr = (i < nH) ? d[i] : d[nH - 1]
            s[i] -= delta97 * (dPrev + dCurr)
        }
        for i in 0..<nH {
            let sNext = (i + 1 < nL) ? s[i + 1] : s[nL - 1]
            d[i] -= gamma97 * (s[i] + sNext)
        }
        for i in 0..<nL {
            let dPrev = (i == 0) ? d[0] : d[i - 1]
            let dCurr = (i < nH) ? d[i] : d[nH - 1]
            s[i] -= beta97 * (dPrev + dCurr)
        }
        for i in 0..<nH {
            let sNext = (i + 1 < nL) ? s[i + 1] : s[nL - 1]
            d[i] -= alpha97 * (s[i] + sNext)
        }

        for i in 0..<nL { x[2 * i]     = s[i] }
        for i in 0..<nH { x[2 * i + 1] = d[i] }
    }

    // MARK: - Boundary Extension Helpers

    private func extendSymmetric(_ s: [Float], leftPad: Int, rightPad: Int) -> [Float] {
        let n = s.count
        var out = [Float](repeating: 0, count: n + leftPad + rightPad)
        for i in 0..<leftPad {
            let srcIdx = min(leftPad - i, n - 1)
            out[i] = s[srcIdx]
        }
        for i in 0..<n { out[leftPad + i] = s[i] }
        for i in 0..<rightPad {
            let srcIdx = max(0, n - 2 - i)
            out[leftPad + n + i] = s[srcIdx]
        }
        return out
    }

    private func maxLevels(for dimension: Int) -> Int {
        guard dimension > 1 else { return 0 }
        var lvl = 0
        var d = dimension
        while d > 1 { d = (d + 1) / 2; lvl += 1 }
        return lvl
    }
}
