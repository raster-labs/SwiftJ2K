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
    internal final class ExecutionTracker: Sendable {
        let engineMode: AccelerationRuntime.EngineMode
        let isMetalForcedAtEntry: Bool
        private let metalCount = Atomic<Int>(0)
        private let simdCount = Atomic<Int>(0)

        init(engineMode: AccelerationRuntime.EngineMode, isMetalForcedAtEntry: Bool = false) {
            self.engineMode = engineMode
            self.isMetalForcedAtEntry = isMetalForcedAtEntry
        }

        func recordMetal() {
            if metalCount.load(ordering: .relaxed) == 0 {
                metalCount.store(1, ordering: .relaxed)
            }
        }

        func recordSIMD() {
            if simdCount.load(ordering: .relaxed) == 0 {
                simdCount.store(1, ordering: .relaxed)
            }
        }

        func resolvedEngine(for backend: Backend) -> AcceleratedEngine {
            guard backend == .accelerated else { return .none }
            if metalCount.load(ordering: .relaxed) > 0 {
                return .metalGPU
            }
            if simdCount.load(ordering: .relaxed) > 0 {
                return .cpuSIMD
            }
            return .none
        }
    }

    @TaskLocal internal static var forceMetalDispatchTaskLocal: Bool = false
    @TaskLocal internal static var activeTracker: ExecutionTracker? = nil
    @TaskLocal internal static var activeWorkerLimit: Int = 1

    internal static func recordMetalDispatch() {
        activeTracker?.recordMetal()
    }

    internal static func recordSIMDDispatch() {
        activeTracker?.recordSIMD()
    }

    internal static func withExecutionScope<R>(
        resolved: AccelerationRuntime.ResolvedExecution,
        workers: Int = 1,
        _ body: () throws -> R
    ) rethrows -> (result: R, engine: AcceleratedEngine) {
        let forced = resolved.engineMode == .metalGPU || forceMetalDispatchTaskLocal
        let tracker = ExecutionTracker(engineMode: resolved.engineMode, isMetalForcedAtEntry: forced)
        let boundedWorkers = max(1, workers)
        let result = try $activeTracker.withValue(tracker) {
            try $activeWorkerLimit.withValue(boundedWorkers, operation: body)
        }
        return (result, tracker.resolvedEngine(for: resolved.backend))
    }

    internal static func withExecutionScope<R>(
        resolved: AccelerationRuntime.ResolvedExecution,
        workers: Int = 1,
        _ body: () async throws -> R
    ) async rethrows -> (result: R, engine: AcceleratedEngine) {
        let forced = resolved.engineMode == .metalGPU || forceMetalDispatchTaskLocal
        let tracker = ExecutionTracker(engineMode: resolved.engineMode, isMetalForcedAtEntry: forced)
        let boundedWorkers = max(1, workers)
        let result = try await $activeTracker.withValue(tracker) {
            try await $activeWorkerLimit.withValue(boundedWorkers) {
                try await body()
            }
        }
        return (result, tracker.resolvedEngine(for: resolved.backend))
    }

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
        if let tracker = activeTracker {
            return tracker.isMetalForcedAtEntry || forceMetalDispatchTaskLocal
        }
        return forceMetalDispatchTaskLocal
    }

    /// Evaluates once per tile whether HTJ2K quad classification should run on Metal GPU,
    /// avoiding repeated `@TaskLocal` and `MetalAccelerationEngine.stateMutex` checks per block.
    @inline(__always)
    internal static func shouldClassifyHTQuadsOnMetal(backend: Backend) -> Bool {
        guard backend == .accelerated else { return false }
        if let tracker = activeTracker {
            if tracker.engineMode == .cpuSIMD { return false }
            let forced = tracker.isMetalForcedAtEntry || forceMetalDispatchTaskLocal
            return forced && MetalAccelerationEngine.shared.isAvailable
        }
        return forceMetalDispatchTaskLocal && MetalAccelerationEngine.shared.isAvailable
    }

    @inline(__always)
    internal static func shouldUseMetal(sampleCount: Int) -> Bool {
        guard sampleCount > 0 else { return false }
        if sampleCount < MetalAccelerationEngine.defaultGPUDispatchSampleThreshold {
            if let tracker = activeTracker {
                if tracker.engineMode == .cpuSIMD { return false }
                guard tracker.isMetalForcedAtEntry || forceMetalDispatchTaskLocal else { return false }
            } else {
                guard forceMetalDispatchTaskLocal else { return false }
            }
            return MetalAccelerationEngine.shared.isAvailable
        }
        if activeTracker?.engineMode == .cpuSIMD { return false }
        return MetalAccelerationEngine.shared.isAvailable
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
        recordSIMDDispatch()
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
        recordSIMDDispatch()
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
        recordSIMDDispatch()
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
        recordSIMDDispatch()
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

    // MARK: - Colour Transforms (RCT, ICT & Part 2 MCT)

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
        recordSIMDDispatch()
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
        recordSIMDDispatch()
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
        recordSIMDDispatch()
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
        recordSIMDDispatch()
        SIMDColourTransform.inverseICT(planes: &planes)
    }

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
        recordSIMDDispatch()
        SIMDColourTransform.applyLinear3x3(
            in0: in0, in1: in1, in2: in2,
            matrix: matrix, offsets: offsets,
            out0: &out0, out1: &out1, out2: &out2
        )
    }

    internal static func forwardPart2ReversibleDep3(
        r: [Int32],
        g: [Int32],
        b: [Int32],
        anchorOffset: Int32
    ) -> [[Int32]]? {
        if shouldUseMetal(sampleCount: r.count),
           let gpuOut = try? MetalAccelerationEngine.shared.forwardPart2ReversibleDep3(
               r: r, g: g, b: b, anchorOffset: anchorOffset
           ) {
            return gpuOut
        }
        recordSIMDDispatch()
        return SIMDColourTransform.forwardPart2ReversibleDep3(
            r: r, g: g, b: b, anchorOffset: anchorOffset
        )
    }

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
    ) -> [[Int64]]? {
        guard abs(a10) <= 65_536, abs(a20) <= 65_536, abs(a21) <= 65_536,
              offsets.allSatisfy({ abs($0) <= (Int64(1) << 30) }) else {
            return nil
        }
        if shouldUseMetal(sampleCount: c0.count),
           let gpuOut = try? MetalAccelerationEngine.shared.inversePart2ReversibleDep3(
               c0: c0, c1: c1, c2: c2,
               a10: a10, shift1: shift1,
               a20: a20, a21: a21, shift2: shift2,
               offsets: offsets
           ) {
            return gpuOut
        }
        recordSIMDDispatch()
        return SIMDColourTransform.inversePart2ReversibleDep3(
            c0: c0, c1: c1, c2: c2,
            a10: a10, shift1: shift1,
            a20: a20, a21: a21, shift2: shift2,
            offsets: offsets
        )
    }

    internal static func levelShiftSamples32IfMetal(
        samples: inout [Int32],
        dcShift: Int32,
        backend: Backend
    ) throws {
        if backend == .accelerated && shouldUseMetal(sampleCount: samples.count) {
            try MetalAccelerationEngine.shared.levelShiftSamples32(samples: &samples, dcShift: dcShift)
        } else if dcShift != 0 {
            for i in 0..<samples.count {
                samples[i] -= dcShift
            }
        }
    }

    internal static func clampSamples64To32IfMetal(
        samples: [Int64],
        minVal: Int64,
        maxVal: Int64,
        backend: Backend
    ) throws -> [Int32] {
        if backend == .accelerated && shouldUseMetal(sampleCount: samples.count) {
            return try MetalAccelerationEngine.shared.clampSamples64To32(
                samples: samples, minVal: minVal, maxVal: maxVal
            )
        }
        var out = Array(repeating: Int32(0), count: samples.count)
        for i in 0..<samples.count {
            out[i] = Int32(min(maxVal, max(minVal, samples[i])))
        }
        return out
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
        recordSIMDDispatch()
        SIMDQuantizationAndROI.quantizeSubband(
            doublePlane: doublePlane,
            quantisedPlane: &quantisedPlane,
            stride: stride,
            band: band,
            step: step,
            mb: mb
        )
    }

    internal static func quantizeSubband32(
        doublePlane: [Double],
        quantisedPlane: inout [Int32],
        stride: Int,
        band: BandGeometry,
        step: Double,
        mb: Int,
        backend: Backend = .scalarCPU
    ) {
        guard backend == .accelerated else {
            let invStep = 1.0 / step
            let maxMag = Double((Int64(1) << min(30, mb)) - 1)
            for row in 0..<band.height {
                let rBase = (band.planeY + row) * stride + band.planeX
                for col in 0..<band.width {
                    let val = doublePlane[rBase + col]
                    let qMag = Int32(min(maxMag, floor(abs(val) * invStep)))
                    quantisedPlane[rBase + col] = val < 0 ? -qMag : qMag
                }
            }
            return
        }
        recordSIMDDispatch()
        SIMDQuantizationAndROI.quantizeSubband32(
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
        recordSIMDDispatch()
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
        recordSIMDDispatch()
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
        if activeTracker?.engineMode != .cpuSIMD && isMetalDispatchForced
            && MetalAccelerationEngine.shared.isAvailable && !coefficients.isEmpty {
            let quads = try MetalAccelerationEngine.shared.classifyHTQuads(
                coefficients: coefficients,
                width: width,
                height: height,
                bandShift: bandShift
            )
            recordSIMDDispatch()
            return try SIMDHTBlockCoder.encodeCleanup(
                coefficients: coefficients,
                width: width,
                height: height,
                bandShift: bandShift,
                maximumOutputBytes: maximumOutputBytes,
                preclassifiedQuads: quads
            )
        }
        recordSIMDDispatch()
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
        recordSIMDDispatch()
        return try SIMDHTBlockCoder.decodeCleanup(
            block: block,
            width: width,
            height: height,
            kMax: kMax,
            missingMSBs: missingMSBs
        )
    }

    @inline(__always)
    internal static func encodeHTCleanupStrided(
        source: UnsafePointer<Int32>,
        stride: Int,
        width: Int,
        height: Int,
        bandShift: Int = 0,
        maximumOutputBytes: Int = Int.max,
        backend: Backend = .scalarCPU,
        workspace: inout HTBlockEncoder.Workspace,
        useMetalHTOverride: Bool? = nil,
        recordTelemetry: Bool = true
    ) throws -> [UInt8] {
        try encodeHTCleanupStrided(
            planeBase: source,
            planeOrigin: 0,
            stride: stride,
            width: width,
            height: height,
            bandShift: bandShift,
            maximumOutputBytes: maximumOutputBytes,
            backend: backend,
            workspace: workspace,
            useMetalHTOverride: useMetalHTOverride,
            recordTelemetry: recordTelemetry
        )
    }

    internal static func encodeHTCleanupStrided(
        planeBase: UnsafePointer<Int32>,
        planeOrigin: Int,
        stride: Int,
        width: Int,
        height: Int,
        bandShift: Int = 0,
        maximumOutputBytes: Int = Int.max,
        backend: Backend = .scalarCPU,
        workspace: HTBlockEncoder.Workspace,
        useMetalHTOverride: Bool? = nil,
        recordTelemetry: Bool = true
    ) throws -> [UInt8] {
        guard backend == .accelerated else {
            return try HTBlockEncoder.encodeCleanupStrided(
                planeBase: planeBase,
                planeOrigin: planeOrigin,
                stride: stride,
                width: width,
                height: height,
                bandShift: bandShift,
                maximumOutputBytes: maximumOutputBytes,
                workspace: workspace
            )
        }
        let useMetal = useMetalHTOverride ?? shouldClassifyHTQuadsOnMetal(backend: backend)
        if useMetal && width > 0 && height > 0 {
            var coeffs = [Int32](repeating: 0, count: width * height)
            for row in 0..<height {
                let srcRow = planeOrigin + row * stride
                let dstRow = row * width
                for col in 0..<width {
                    coeffs[dstRow + col] = planeBase[srcRow + col]
                }
            }
            let quads = try MetalAccelerationEngine.shared.classifyHTQuads(
                coefficients: coeffs,
                width: width,
                height: height,
                bandShift: bandShift
            )
            if recordTelemetry { recordSIMDDispatch() }
            return try SIMDHTBlockCoder.encodeCleanup(
                coefficients: coeffs,
                width: width,
                height: height,
                bandShift: bandShift,
                maximumOutputBytes: maximumOutputBytes,
                preclassifiedQuads: quads
            )
        }
        if recordTelemetry { recordSIMDDispatch() }
        return try SIMDHTBlockCoder.encodeCleanupStrided(
            planeBase: planeBase,
            planeOrigin: planeOrigin,
            stride: stride,
            width: width,
            height: height,
            bandShift: bandShift,
            maximumOutputBytes: maximumOutputBytes,
            workspace: workspace
        )
    }

    @inline(__always)
    internal static func decodeHTCleanupStrided(
        block: ArraySlice<UInt8>,
        width: Int,
        height: Int,
        kMax: Int,
        missingMSBs: Int,
        destination: UnsafeMutablePointer<Int32>,
        stride: Int,
        backend: Backend = .scalarCPU,
        recordTelemetry: Bool = true
    ) throws {
        if block.isEmpty {
            var dummy: UInt8 = 0
            try withUnsafePointer(to: &dummy) { ptr in
                try decodeHTCleanupStrided(
                    blockBase: ptr,
                    blockCount: 0,
                    planeBase: destination,
                    planeOrigin: 0,
                    stride: stride,
                    width: width,
                    height: height,
                    kMax: kMax,
                    missingMSBs: missingMSBs,
                    backend: backend,
                    recordTelemetry: recordTelemetry
                )
            }
            return
        }
        try block.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            try decodeHTCleanupStrided(
                blockBase: base,
                blockCount: buf.count,
                planeBase: destination,
                planeOrigin: 0,
                stride: stride,
                width: width,
                height: height,
                kMax: kMax,
                missingMSBs: missingMSBs,
                backend: backend,
                recordTelemetry: recordTelemetry
            )
        }
    }

    internal static func decodeHTCleanupStrided(
        blockBase: UnsafePointer<UInt8>,
        blockCount: Int,
        planeBase: UnsafeMutablePointer<Int32>,
        planeOrigin: Int,
        stride: Int,
        width: Int,
        height: Int,
        kMax: Int,
        missingMSBs: Int,
        backend: Backend = .scalarCPU,
        recordTelemetry: Bool = true
    ) throws {
        if recordTelemetry && backend == .accelerated {
            recordSIMDDispatch()
        }
        try HTBlockDecoder.decodeCleanupStrided(
            blockBase: blockBase,
            blockCount: blockCount,
            planeBase: planeBase,
            planeOrigin: planeOrigin,
            stride: stride,
            width: width,
            height: height,
            kMax: kMax,
            missingMSBs: missingMSBs
        )
    }
}
