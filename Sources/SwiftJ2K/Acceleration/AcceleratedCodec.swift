import Foundation
import Synchronization

// MARK: - Unified Backend-Aware Acceleration Router (Milestone 9)
//
// Routes wavelet transforms, colour transforms, quantization, ROI MaxShift, and HTJ2K cleanup
// coding according to the resolved `Backend` (`.scalarCPU` vs `.accelerated`).
//
// When `backend == .accelerated`:
// - Reversible 5/3 DWT, RCT, and ROI MaxShift dispatch to `MetalAccelerationEngine.shared` when
//   Metal is available and the buffer size meets `defaultGPUDispatchSampleThreshold` (or when
//   forced in tests via `withForcedMetalDispatch`), and to `SIMDWavelet53` / `SIMDColourTransform` /
//   `SIMDQuantizationAndROI` otherwise.
// - Irreversible 9/7 DWT, ICT, and dead-zone quantization dispatch to IEEE-754 double-precision
//   `SIMDWavelet97` / `SIMDColourTransform` / `SIMDQuantizationAndROI` to preserve exact bit-for-bit
//   parity with `Wavelet97`, `ColourTransform`, and `Quantization` (`M9-AUD-004`).
// - HTJ2K FBCOT cleanup pass coding dispatches to `SIMDHTBlockCoder` (with optional Metal GPU
//   quad classification when forced in tests).

internal enum AcceleratedCodec {
    @TaskLocal private static var forceMetalDispatchTaskLocal: Bool = false

    /// Test and benchmark helper that forces `.accelerated` operations on the current task to
    /// dispatch through `MetalAccelerationEngine.shared` regardless of sample count threshold.
    internal static func withForcedMetalDispatch<R>(
        _ force: Bool = true,
        _ body: () throws -> R
    ) rethrows -> R {
        try $forceMetalDispatchTaskLocal.withValue(force, operation: body)
    }

    /// Async test and benchmark helper that forces `.accelerated` operations on the current task to
    /// dispatch through `MetalAccelerationEngine.shared` regardless of sample count threshold.
    internal static func withForcedMetalDispatch<R>(
        _ force: Bool = true,
        _ body: () async throws -> R
    ) async rethrows -> R {
        try await $forceMetalDispatchTaskLocal.withValue(force) {
            try await body()
        }
    }

    internal static var isMetalDispatchForced: Bool {
        forceMetalDispatchTaskLocal
    }

    @inline(__always)
    private static func shouldUseMetal(sampleCount: Int) -> Bool {
        guard MetalAccelerationEngine.shared.isAvailable else { return false }
        if isMetalDispatchForced { return true }
        return sampleCount >= MetalAccelerationEngine.defaultGPUDispatchSampleThreshold
    }

    // MARK: - 5/3 Reversible Wavelet Transform

    internal static func forwardWavelet53(
        plane: inout [Int32],
        stride: Int,
        x0: Int,
        x1: Int,
        y0: Int,
        y1: Int,
        levels: Int,
        backend: Backend = .scalarCPU,
        cancellation: () throws -> Void
    ) throws {
        guard backend == .accelerated else {
            try Wavelet53.forward(
                plane: &plane,
                stride: stride,
                x0: x0,
                x1: x1,
                y0: y0,
                y1: y1,
                levels: levels,
                cancellation: cancellation
            )
            return
        }
        if shouldUseMetal(sampleCount: plane.count) {
            try MetalAccelerationEngine.shared.forwardWavelet53(
                plane: &plane,
                stride: stride,
                x0: x0,
                x1: x1,
                y0: y0,
                y1: y1,
                levels: levels,
                cancellation: cancellation
            )
            return
        }
        try SIMDWavelet53.forward(
            plane: &plane,
            stride: stride,
            x0: x0,
            x1: x1,
            y0: y0,
            y1: y1,
            levels: levels,
            cancellation: cancellation
        )
    }

    internal static func inverseWavelet53(
        plane: inout [Int32],
        stride: Int,
        x0: Int,
        x1: Int,
        y0: Int,
        y1: Int,
        levels: Int,
        backend: Backend = .scalarCPU,
        cancellation: () throws -> Void
    ) throws {
        guard backend == .accelerated else {
            try Wavelet53.inverse(
                plane: &plane,
                stride: stride,
                x0: x0,
                x1: x1,
                y0: y0,
                y1: y1,
                levels: levels,
                cancellation: cancellation
            )
            return
        }
        if shouldUseMetal(sampleCount: plane.count) {
            try MetalAccelerationEngine.shared.inverseWavelet53(
                plane: &plane,
                stride: stride,
                x0: x0,
                x1: x1,
                y0: y0,
                y1: y1,
                levels: levels,
                cancellation: cancellation
            )
            return
        }
        try SIMDWavelet53.inverse(
            plane: &plane,
            stride: stride,
            x0: x0,
            x1: x1,
            y0: y0,
            y1: y1,
            levels: levels,
            cancellation: cancellation
        )
    }

    // MARK: - 9/7 Irreversible Wavelet Transform

    internal static func forwardWavelet97(
        plane: inout [Double],
        stride: Int,
        x0: Int,
        x1: Int,
        y0: Int,
        y1: Int,
        levels: Int,
        backend: Backend = .scalarCPU,
        cancellation: () throws -> Void
    ) throws {
        guard backend == .accelerated else {
            try Wavelet97.forward(
                plane: &plane,
                stride: stride,
                x0: x0,
                x1: x1,
                y0: y0,
                y1: y1,
                levels: levels,
                cancellation: cancellation
            )
            return
        }
        try SIMDWavelet97.forward(
            plane: &plane,
            stride: stride,
            x0: x0,
            x1: x1,
            y0: y0,
            y1: y1,
            levels: levels,
            cancellation: cancellation
        )
    }

    internal static func inverseWavelet97(
        plane: inout [Double],
        stride: Int,
        x0: Int,
        x1: Int,
        y0: Int,
        y1: Int,
        levels: Int,
        backend: Backend = .scalarCPU,
        cancellation: () throws -> Void
    ) throws {
        guard backend == .accelerated else {
            try Wavelet97.inverse(
                plane: &plane,
                stride: stride,
                x0: x0,
                x1: x1,
                y0: y0,
                y1: y1,
                levels: levels,
                cancellation: cancellation
            )
            return
        }
        try SIMDWavelet97.inverse(
            plane: &plane,
            stride: stride,
            x0: x0,
            x1: x1,
            y0: y0,
            y1: y1,
            levels: levels,
            cancellation: cancellation
        )
    }

    // MARK: - Colour Transforms (RCT & ICT)

    internal static func forwardRCT(
        planes: inout [[Int32]],
        backend: Backend = .scalarCPU
    ) throws {
        guard backend == .accelerated else {
            ColourTransform.forwardRCT(planes: &planes)
            return
        }
        if planes.count >= 3 && shouldUseMetal(sampleCount: planes[0].count) {
            try MetalAccelerationEngine.shared.forwardRCT(planes: &planes)
            return
        }
        SIMDColourTransform.forwardRCT(planes: &planes)
    }

    internal static func inverseRCT(
        planes: inout [[Int32]],
        backend: Backend = .scalarCPU
    ) throws {
        guard backend == .accelerated else {
            ColourTransform.inverseRCT(planes: &planes)
            return
        }
        if planes.count >= 3 && shouldUseMetal(sampleCount: planes[0].count) {
            try MetalAccelerationEngine.shared.inverseRCT(planes: &planes)
            return
        }
        SIMDColourTransform.inverseRCT(planes: &planes)
    }

    internal static func forwardICT(
        planes: inout [[Double]],
        backend: Backend = .scalarCPU
    ) {
        guard backend == .accelerated else {
            ColourTransform.forwardICT(planes: &planes)
            return
        }
        SIMDColourTransform.forwardICT(planes: &planes)
    }

    internal static func inverseICT(
        planes: inout [[Double]],
        backend: Backend = .scalarCPU
    ) {
        guard backend == .accelerated else {
            ColourTransform.inverseICT(planes: &planes)
            return
        }
        SIMDColourTransform.inverseICT(planes: &planes)
    }

    // MARK: - Quantization & ROI MaxShift

    internal static func quantizeSubband(
        doublePlane: [Double],
        quantisedPlane: inout [Int64],
        stride: Int,
        band: BandGeometry,
        step: Double,
        mb: Int,
        backend: Backend = .scalarCPU
    ) {
        guard backend == .accelerated else {
            let invStep = 1.0 / step
            let maxMag = (Int64(1) << mb) - 1
            for row in 0..<band.height {
                let rBase = (band.planeY + row) * stride + band.planeX
                for col in 0..<band.width {
                    let val = doublePlane[rBase + col]
                    let qMag = min(maxMag, Int64(floor(abs(val) * invStep)))
                    quantisedPlane[rBase + col] = val < 0 ? -qMag : qMag
                }
            }
            return
        }
        SIMDQuantizationAndROI.quantizeSubband(
            doublePlane: doublePlane,
            quantisedPlane: &quantisedPlane,
            stride: stride,
            band: band,
            step: step,
            mb: mb
        )
    }

    internal static func scaleROISubband(
        quantisedPlane: inout [Int64],
        stride: Int,
        band: BandGeometry,
        bounds: (x0: Int, x1: Int, y0: Int, y1: Int),
        roiShift: Int,
        mb: Int,
        backend: Backend = .scalarCPU
    ) {
        guard backend == .accelerated else {
            let maxShiftedMag = (Int64(1) << min(61, mb + roiShift)) - 1
            for sy in bounds.y0..<bounds.y1 {
                let rowIdx = (band.planeY + (sy - band.y0)) * stride + band.planeX + (bounds.x0 - band.x0)
                for offset in 0..<(bounds.x1 - bounds.x0) {
                    let v = quantisedPlane[rowIdx + offset]
                    guard v != 0 else { continue }
                    let mag = v < 0 ? -v : v
                    let shifted = min(maxShiftedMag, mag << roiShift)
                    quantisedPlane[rowIdx + offset] = v < 0 ? -shifted : shifted
                }
            }
            return
        }
        SIMDQuantizationAndROI.scaleROISubband(
            quantisedPlane: &quantisedPlane,
            stride: stride,
            band: band,
            bounds: bounds,
            roiShift: roiShift,
            mb: mb
        )
    }

    internal static func descaleROICoefficients(
        coefficients: inout [Int64],
        shift: Int,
        backend: Backend = .scalarCPU
    ) throws {
        guard shift > 0 else { return }
        guard backend == .accelerated else {
            for i in 0..<coefficients.count where coefficients[i] != 0 {
                coefficients[i] = ROICoding.descaleCoefficient(coefficients[i], shift: shift)
            }
            return
        }
        if shouldUseMetal(sampleCount: coefficients.count) {
            try MetalAccelerationEngine.shared.descaleROICoefficients(
                coefficients: &coefficients,
                shift: shift
            )
            return
        }
        SIMDQuantizationAndROI.descaleROICoefficients(
            coefficients: &coefficients,
            shift: shift
        )
    }

    // MARK: - HTJ2K Cleanup Pass Coding

    internal static func encodeHTCleanup(
        coefficients: [Int32],
        width: Int,
        height: Int,
        bandShift: Int = 0,
        maximumOutputBytes: Int = Int.max,
        backend: Backend = .scalarCPU
    ) throws -> [UInt8] {
        guard backend == .accelerated else {
            return try HTBlockEncoder.encodeCleanup(
                coefficients: coefficients,
                width: width,
                height: height,
                bandShift: bandShift,
                maximumOutputBytes: maximumOutputBytes
            )
        }
        if isMetalDispatchForced && MetalAccelerationEngine.shared.isAvailable && !coefficients.isEmpty {
            let quads = try MetalAccelerationEngine.shared.classifyHTQuads(
                coefficients: coefficients,
                width: width,
                height: height,
                bandShift: bandShift
            )
            return try SIMDHTBlockCoder.encodeCleanup(
                coefficients: coefficients,
                width: width,
                height: height,
                bandShift: bandShift,
                maximumOutputBytes: maximumOutputBytes,
                preclassifiedQuads: quads
            )
        }
        return try SIMDHTBlockCoder.encodeCleanup(
            coefficients: coefficients,
            width: width,
            height: height,
            bandShift: bandShift,
            maximumOutputBytes: maximumOutputBytes
        )
    }

    internal static func decodeHTCleanup(
        block: [UInt8],
        width: Int,
        height: Int,
        kMax: Int,
        missingMSBs: Int,
        backend: Backend = .scalarCPU
    ) throws -> [Int32] {
        guard backend == .accelerated else {
            return try HTBlockDecoder.decodeCleanup(
                block: block,
                width: width,
                height: height,
                kMax: kMax,
                missingMSBs: missingMSBs
            )
        }
        return try SIMDHTBlockCoder.decodeCleanup(
            block: block,
            width: width,
            height: height,
            kMax: kMax,
            missingMSBs: missingMSBs
        )
    }
}
