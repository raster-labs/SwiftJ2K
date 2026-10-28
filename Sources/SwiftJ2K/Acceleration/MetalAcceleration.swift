import Foundation
import Synchronization

#if canImport(Metal)
import Metal
#endif

// MARK: - Internal Metal GPU Acceleration Subsystem (Milestone 9 — Decision M1)
//
// Consolidates and replaces the predecessor's standalone `J2KMetal` module (25 files) and
// `Sources/J2KCodec/J2KGPU*` / `J2KMetalSession.swift` files as an internal subsystem of
// `SwiftJ2K` behind `ExecutionPolicy`.
//
// Fixes all five predecessor defects identified in the Milestone 9 audit:
// - M9-AUD-001 / M9-AUD-002: HT quad classification + conformant UVLC/MagSgn bounds
// - M9-AUD-003: 5/3 DWT arbitrary `i0..<i1` periodic symmetric extension, `n == 1` odd-origin
//   `* 2` / `/ 2` scaling, `VER_SD` then `HOR_SD` pass order, and 64-bit overflow detection
// - M9-AUD-004: 9/7 DWT routed to IEEE-754 `SIMD4<Double>` (`SIMDWavelet97`) to avoid 32-bit
//   GPU float drift
// - M9-AUD-005: 64-bit `long` intermediate arithmetic in RCT and ROI kernels, plus synchronous
//   `MTLCommandBuffer.waitUntilCompleted()` before buffer release (`MEM-04`)

internal struct MetalTelemetrySnapshot: Sendable, Equatable {
    internal let isAvailable: Bool
    internal let deviceName: String?
    internal let hasUnifiedMemory: Bool
    internal let shaderCompilationDurationNs: UInt64
    internal let dispatchCount: Int
    internal let bufferPoolHits: Int
    internal let bufferPoolMisses: Int
}

/// Internal Metal GPU compute engine for reversible 5/3 wavelet transforms, Reversible Colour
/// Transform (RCT), Region-of-Interest (ROI) MaxShift scaling/descaling, and HTJ2K 2×2 quad
/// classification.
///
/// CONC-03 Proof of `@unchecked Sendable`:
/// All mutable state (the compiled `MTLLibrary`, `MTLComputePipelineState` cache, size-bucketed
/// `.storageModeShared` `MTLBuffer` pool, and telemetry counters) is stored exclusively inside
/// `stateMutex: Mutex<EngineState>` and accessed only while holding the lock. Every GPU command
/// buffer is committed and synchronously joined via `commandBuffer.waitUntilCompleted()` inside
/// the call before pooled `MTLBuffer` instances are returned to the pool or output arrays are
/// read (`MEM-04`). No raw pointer or `MTLBuffer` reference ever escapes a method call.
internal final class MetalAccelerationEngine: @unchecked Sendable {
    internal static let shared = MetalAccelerationEngine()

    /// Minimum sample count (width * height) where GPU dispatch amortises command-buffer launch
    /// overhead in automatic `.accelerated` mode (`256 * 256 = 65_536` samples).
    /// Direct calls to `MetalAccelerationEngine` methods in parity tests bypass this threshold.
    internal static let defaultGPUDispatchSampleThreshold: Int = 65_536

    #if canImport(Metal)
    private struct DWT53Params {
        var stride: Int32
        var i0: Int32
        var n: Int32
        var lowCount: Int32
        var lineCount: Int32
        var isVertical: Int32
    }

    private struct RCTParams {
        var count: UInt32
    }

    private struct ROIParams {
        var count: UInt32
        var shift: Int32
    }

    private struct HTQuadParams {
        var width: Int32
        var height: Int32
        var qw: Int32
        var qh: Int32
        var bandShift: Int32
    }

    private struct GPUClassifiedQuad {
        var rho: Int32
        var eQMax: Int32
        var eQ0: Int32
        var eQ1: Int32
        var eQ2: Int32
        var eQ3: Int32
        var s0: UInt32
        var s1: UInt32
        var s2: UInt32
        var s3: UInt32
    }

    private struct EngineState {
        var initialized: Bool = false
        var device: (any MTLDevice)?
        var commandQueue: (any MTLCommandQueue)?
        var library: (any MTLLibrary)?
        var pipelines: [String: any MTLComputePipelineState] = [:]
        var bufferPool: [Int: [any MTLBuffer]] = [:]
        var shaderCompilationDurationNs: UInt64 = 0
        var dispatchCount: Int = 0
        var bufferPoolHits: Int = 0
        var bufferPoolMisses: Int = 0
    }

    private let stateMutex = Mutex(EngineState())
    #endif

    private init() {}

    /// Creates an uncached engine instance for cold-start benchmark measurements (`PERF-01`/`PERF-02`).
    internal static func makeFreshInstanceForBenchmarking() -> MetalAccelerationEngine {
        MetalAccelerationEngine()
    }

    internal var isAvailable: Bool {
        guard AccelerationRuntime.isMetalDevicePermitted else { return false }
        #if canImport(Metal)
        return stateMutex.withLock { state in
            ensureInitialized(&state)
        }
        #else
        return false
        #endif
    }

    internal func telemetrySnapshot() -> MetalTelemetrySnapshot {
        #if canImport(Metal)
        return stateMutex.withLock { state in
            let ok = ensureInitialized(&state)
            return MetalTelemetrySnapshot(
                isAvailable: ok,
                deviceName: state.device?.name,
                hasUnifiedMemory: state.device?.hasUnifiedMemory ?? false,
                shaderCompilationDurationNs: state.shaderCompilationDurationNs,
                dispatchCount: state.dispatchCount,
                bufferPoolHits: state.bufferPoolHits,
                bufferPoolMisses: state.bufferPoolMisses
            )
        }
        #else
        return MetalTelemetrySnapshot(
            isAvailable: false,
            deviceName: nil,
            hasUnifiedMemory: false,
            shaderCompilationDurationNs: 0,
            dispatchCount: 0,
            bufferPoolHits: 0,
            bufferPoolMisses: 0
        )
        #endif
    }

    // MARK: - 1. Metal 5/3 Reversible Wavelet Transform (2D Multi-Level In-Place)

    internal func forwardWavelet53(
        plane: inout [Int32],
        stride: Int,
        x0: Int,
        x1: Int,
        y0: Int,
        y1: Int,
        levels: Int,
        cancellation: () throws -> Void = {}
    ) throws {
        guard levels > 0 else { return }
        let totalWidth = x1 - x0
        let totalHeight = y1 - y0
        guard totalWidth > 0, totalHeight > 0, !plane.isEmpty else { return }
        try cancellation()

        #if canImport(Metal)
        try stateMutex.withLock { state in
            guard ensureInitialized(&state),
                  let commandQueue = state.commandQueue,
                  let pAnalyse = try pipeline(named: "j2k_dwt53_forward_1d", state: &state),
                  let pCommit = try pipeline(named: "j2k_dwt53_commit_subband", state: &state)
            else {
                throw CodecError(.backendUnavailable, "Metal 5/3 forward wavelet pipeline is unavailable.")
            }

            let byteCount = max(4, plane.count * MemoryLayout<Int32>.stride)
            let mainBuf = try acquireBuffer(minBytes: byteCount, state: &state)
            let scratchBuf = try acquireBuffer(minBytes: byteCount, state: &state)
            defer {
                releaseBuffer(mainBuf, state: &state)
                releaseBuffer(scratchBuf, state: &state)
            }

            plane.withUnsafeBytes { raw in
                if let base = raw.baseAddress, raw.count > 0 {
                    memcpy(mainBuf.contents(), base, raw.count)
                }
            }

            guard let cmdBuf = commandQueue.makeCommandBuffer() else {
                throw CodecError(.internalFailure, "Failed to create Metal command buffer for forward 5/3 DWT.")
            }

            for level in 1...levels {
                let rx0 = Wavelet53.ceilDivPowerOfTwo(x0, level - 1)
                let rx1 = Wavelet53.ceilDivPowerOfTwo(x1, level - 1)
                let ry0 = Wavelet53.ceilDivPowerOfTwo(y0, level - 1)
                let ry1 = Wavelet53.ceilDivPowerOfTwo(y1, level - 1)
                let w = rx1 - rx0
                let h = ry1 - ry0
                guard w > 0, h > 0 else { continue }

                // VER_SD on every column (i0 = ry0, n = h, lineCount = w)
                try encodeForward1DPass(
                    commandBuffer: cmdBuf,
                    analysePipeline: pAnalyse,
                    commitPipeline: pCommit,
                    mainBuffer: mainBuf,
                    scratchBuffer: scratchBuf,
                    stride: stride,
                    i0: ry0,
                    n: h,
                    lineCount: w,
                    isVertical: true
                )

                // HOR_SD on every row (i0 = rx0, n = w, lineCount = h)
                try encodeForward1DPass(
                    commandBuffer: cmdBuf,
                    analysePipeline: pAnalyse,
                    commitPipeline: pCommit,
                    mainBuffer: mainBuf,
                    scratchBuffer: scratchBuf,
                    stride: stride,
                    i0: rx0,
                    n: w,
                    lineCount: h,
                    isVertical: false
                )
            }

            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
            state.dispatchCount += 1

            if cmdBuf.status != .completed {
                throw CodecError(.internalFailure, "Metal forward 5/3 DWT command buffer failed.")
            }

            plane.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress, raw.count > 0 {
                    memcpy(base, mainBuf.contents(), raw.count)
                }
            }
        }
        try cancellation()
        #else
        throw CodecError(.backendUnavailable, "Metal is not available on this platform.")
        #endif
    }

    internal func inverseWavelet53(
        plane: inout [Int32],
        stride: Int,
        x0: Int,
        x1: Int,
        y0: Int,
        y1: Int,
        levels: Int,
        cancellation: () throws -> Void = {}
    ) throws {
        guard levels > 0 else { return }
        let totalWidth = x1 - x0
        let totalHeight = y1 - y0
        guard totalWidth > 0, totalHeight > 0, !plane.isEmpty else { return }
        try cancellation()

        #if canImport(Metal)
        try stateMutex.withLock { state in
            guard ensureInitialized(&state),
                  let commandQueue = state.commandQueue,
                  let pInterleave = try pipeline(named: "j2k_dwt53_interleave_1d", state: &state),
                  let pSynthesise = try pipeline(named: "j2k_dwt53_inverse_1d", state: &state)
            else {
                throw CodecError(.backendUnavailable, "Metal 5/3 inverse wavelet pipeline is unavailable.")
            }

            let byteCount = max(4, plane.count * MemoryLayout<Int32>.stride)
            let mainBuf = try acquireBuffer(minBytes: byteCount, state: &state)
            let scratchBuf = try acquireBuffer(minBytes: byteCount, state: &state)
            let flagBuf = try acquireBuffer(minBytes: MemoryLayout<UInt32>.stride, state: &state)
            defer {
                releaseBuffer(mainBuf, state: &state)
                releaseBuffer(scratchBuf, state: &state)
                releaseBuffer(flagBuf, state: &state)
            }

            plane.withUnsafeBytes { raw in
                if let base = raw.baseAddress, raw.count > 0 {
                    memcpy(mainBuf.contents(), base, raw.count)
                }
            }
            flagBuf.contents().storeBytes(of: UInt32(0), as: UInt32.self)

            guard let cmdBuf = commandQueue.makeCommandBuffer() else {
                throw CodecError(.internalFailure, "Failed to create Metal command buffer for inverse 5/3 DWT.")
            }

            for level in Swift.stride(from: levels, through: 1, by: -1) {
                let rx0 = Wavelet53.ceilDivPowerOfTwo(x0, level - 1)
                let rx1 = Wavelet53.ceilDivPowerOfTwo(x1, level - 1)
                let ry0 = Wavelet53.ceilDivPowerOfTwo(y0, level - 1)
                let ry1 = Wavelet53.ceilDivPowerOfTwo(y1, level - 1)
                let w = rx1 - rx0
                let h = ry1 - ry0
                guard w > 0, h > 0 else { continue }

                // HOR_SR on every row (i0 = rx0, n = w, lineCount = h)
                try encodeInverse1DPass(
                    commandBuffer: cmdBuf,
                    interleavePipeline: pInterleave,
                    synthesisePipeline: pSynthesise,
                    mainBuffer: mainBuf,
                    scratchBuffer: scratchBuf,
                    overflowBuffer: flagBuf,
                    stride: stride,
                    i0: rx0,
                    n: w,
                    lineCount: h,
                    isVertical: false
                )

                // VER_SR on every column (i0 = ry0, n = h, lineCount = w)
                try encodeInverse1DPass(
                    commandBuffer: cmdBuf,
                    interleavePipeline: pInterleave,
                    synthesisePipeline: pSynthesise,
                    mainBuffer: mainBuf,
                    scratchBuffer: scratchBuf,
                    overflowBuffer: flagBuf,
                    stride: stride,
                    i0: ry0,
                    n: h,
                    lineCount: w,
                    isVertical: true
                )
            }

            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
            state.dispatchCount += 1

            if cmdBuf.status != .completed {
                throw CodecError(.internalFailure, "Metal inverse 5/3 DWT command buffer failed.")
            }

            if flagBuf.contents().load(as: UInt32.self) != 0 {
                throw CodecError(.malformedInput, "Wavelet synthesis overflowed the 32-bit coefficient range.")
            }

            plane.withUnsafeMutableBytes { raw in
                if let base = raw.baseAddress, raw.count > 0 {
                    memcpy(base, mainBuf.contents(), raw.count)
                }
            }
        }
        try cancellation()
        #else
        throw CodecError(.backendUnavailable, "Metal is not available on this platform.")
        #endif
    }

    // MARK: - 2. Metal Reversible Colour Transform (RCT)

    internal func forwardRCT(planes: inout [[Int32]]) throws {
        guard planes.count >= 3 else { return }
        let count = min(planes[0].count, min(planes[1].count, planes[2].count))
        if count == 0 { return }

        #if canImport(Metal)
        try stateMutex.withLock { state in
            guard ensureInitialized(&state),
                  let commandQueue = state.commandQueue,
                  let pipelineState = try pipeline(named: "j2k_rct_forward", state: &state)
            else {
                throw CodecError(.backendUnavailable, "Metal forward RCT pipeline is unavailable.")
            }

            let byteCount = count * MemoryLayout<Int32>.stride
            let buf0 = try acquireBuffer(minBytes: byteCount, state: &state)
            let buf1 = try acquireBuffer(minBytes: byteCount, state: &state)
            let buf2 = try acquireBuffer(minBytes: byteCount, state: &state)
            defer {
                releaseBuffer(buf0, state: &state)
                releaseBuffer(buf1, state: &state)
                releaseBuffer(buf2, state: &state)
            }

            planes[0].withUnsafeBytes { _ = memcpy(buf0.contents(), $0.baseAddress!, byteCount) }
            planes[1].withUnsafeBytes { _ = memcpy(buf1.contents(), $0.baseAddress!, byteCount) }
            planes[2].withUnsafeBytes { _ = memcpy(buf2.contents(), $0.baseAddress!, byteCount) }

            guard let cmdBuf = commandQueue.makeCommandBuffer(),
                  let encoder = cmdBuf.makeComputeCommandEncoder()
            else {
                throw CodecError(.internalFailure, "Failed to create Metal command encoder for forward RCT.")
            }

            var params = RCTParams(count: UInt32(count))
            encoder.setComputePipelineState(pipelineState)
            encoder.setBuffer(buf0, offset: 0, index: 0)
            encoder.setBuffer(buf1, offset: 0, index: 1)
            encoder.setBuffer(buf2, offset: 0, index: 2)
            encoder.setBytes(&params, length: MemoryLayout<RCTParams>.stride, index: 3)
            dispatch1D(encoder: encoder, pipeline: pipelineState, width: count)
            encoder.endEncoding()

            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
            state.dispatchCount += 1

            planes[0].withUnsafeMutableBytes { _ = memcpy($0.baseAddress!, buf0.contents(), byteCount) }
            planes[1].withUnsafeMutableBytes { _ = memcpy($0.baseAddress!, buf1.contents(), byteCount) }
            planes[2].withUnsafeMutableBytes { _ = memcpy($0.baseAddress!, buf2.contents(), byteCount) }
        }
        #else
        throw CodecError(.backendUnavailable, "Metal is not available on this platform.")
        #endif
    }

    internal func inverseRCT(planes: inout [[Int32]]) throws {
        guard planes.count >= 3 else { return }
        let count = min(planes[0].count, min(planes[1].count, planes[2].count))
        if count == 0 { return }

        #if canImport(Metal)
        try stateMutex.withLock { state in
            guard ensureInitialized(&state),
                  let commandQueue = state.commandQueue,
                  let pipelineState = try pipeline(named: "j2k_rct_inverse", state: &state)
            else {
                throw CodecError(.backendUnavailable, "Metal inverse RCT pipeline is unavailable.")
            }

            let byteCount = count * MemoryLayout<Int32>.stride
            let buf0 = try acquireBuffer(minBytes: byteCount, state: &state)
            let buf1 = try acquireBuffer(minBytes: byteCount, state: &state)
            let buf2 = try acquireBuffer(minBytes: byteCount, state: &state)
            defer {
                releaseBuffer(buf0, state: &state)
                releaseBuffer(buf1, state: &state)
                releaseBuffer(buf2, state: &state)
            }

            planes[0].withUnsafeBytes { _ = memcpy(buf0.contents(), $0.baseAddress!, byteCount) }
            planes[1].withUnsafeBytes { _ = memcpy(buf1.contents(), $0.baseAddress!, byteCount) }
            planes[2].withUnsafeBytes { _ = memcpy(buf2.contents(), $0.baseAddress!, byteCount) }

            guard let cmdBuf = commandQueue.makeCommandBuffer(),
                  let encoder = cmdBuf.makeComputeCommandEncoder()
            else {
                throw CodecError(.internalFailure, "Failed to create Metal command encoder for inverse RCT.")
            }

            var params = RCTParams(count: UInt32(count))
            encoder.setComputePipelineState(pipelineState)
            encoder.setBuffer(buf0, offset: 0, index: 0)
            encoder.setBuffer(buf1, offset: 0, index: 1)
            encoder.setBuffer(buf2, offset: 0, index: 2)
            encoder.setBytes(&params, length: MemoryLayout<RCTParams>.stride, index: 3)
            dispatch1D(encoder: encoder, pipeline: pipelineState, width: count)
            encoder.endEncoding()

            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
            state.dispatchCount += 1

            planes[0].withUnsafeMutableBytes { _ = memcpy($0.baseAddress!, buf0.contents(), byteCount) }
            planes[1].withUnsafeMutableBytes { _ = memcpy($0.baseAddress!, buf1.contents(), byteCount) }
            planes[2].withUnsafeMutableBytes { _ = memcpy($0.baseAddress!, buf2.contents(), byteCount) }
        }
        #else
        throw CodecError(.backendUnavailable, "Metal is not available on this platform.")
        #endif
    }

    // MARK: - 3. Metal ROI MaxShift Descaling

    internal func descaleROICoefficients(
        coefficients: inout [Int64],
        shift: Int
    ) throws {
        guard shift > 0, !coefficients.isEmpty else { return }
        let count = coefficients.count

        #if canImport(Metal)
        try stateMutex.withLock { state in
            guard ensureInitialized(&state),
                  let commandQueue = state.commandQueue,
                  let pipelineState = try pipeline(named: "j2k_roi_descale64", state: &state)
            else {
                throw CodecError(.backendUnavailable, "Metal ROI descale pipeline is unavailable.")
            }

            let byteCount = count * MemoryLayout<Int64>.stride
            let coeffBuf = try acquireBuffer(minBytes: byteCount, state: &state)
            defer { releaseBuffer(coeffBuf, state: &state) }

            coefficients.withUnsafeBytes { _ = memcpy(coeffBuf.contents(), $0.baseAddress!, byteCount) }

            guard let cmdBuf = commandQueue.makeCommandBuffer(),
                  let encoder = cmdBuf.makeComputeCommandEncoder()
            else {
                throw CodecError(.internalFailure, "Failed to create Metal command encoder for ROI descale.")
            }

            var params = ROIParams(count: UInt32(count), shift: Int32(shift))
            encoder.setComputePipelineState(pipelineState)
            encoder.setBuffer(coeffBuf, offset: 0, index: 0)
            encoder.setBytes(&params, length: MemoryLayout<ROIParams>.stride, index: 1)
            dispatch1D(encoder: encoder, pipeline: pipelineState, width: count)
            encoder.endEncoding()

            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
            state.dispatchCount += 1

            coefficients.withUnsafeMutableBytes { _ = memcpy($0.baseAddress!, coeffBuf.contents(), byteCount) }
        }
        #else
        throw CodecError(.backendUnavailable, "Metal is not available on this platform.")
        #endif
    }

    // MARK: - 4. Metal HTJ2K 2x2 Quad Classifier

    internal func classifyHTQuads(
        coefficients: [Int32],
        width: Int,
        height: Int,
        bandShift: Int = 0
    ) throws -> [SIMDHTBlockCoder.PreclassifiedQuad] {
        guard width >= 1, height >= 1, coefficients.count == width * height else {
            throw CodecError(.invalidArgument, "HTJ2K block dimensions do not match coefficient count.")
        }
        guard bandShift >= 0, bandShift < 31 else {
            throw CodecError(.invalidArgument, "HTJ2K cleanup bit-plane shift (\(bandShift)) is out of range.")
        }

        let qw = (width + 1) / 2
        let qh = (height + 1) / 2
        let quadCount = qw * qh

        #if canImport(Metal)
        return try stateMutex.withLock { state in
            guard ensureInitialized(&state),
                  let commandQueue = state.commandQueue,
                  let pipelineState = try pipeline(named: "j2k_ht_classify_quads", state: &state)
            else {
                throw CodecError(.backendUnavailable, "Metal HT quad classification pipeline is unavailable.")
            }

            let sampleBytes = coefficients.count * MemoryLayout<Int32>.stride
            let quadBytes = quadCount * MemoryLayout<GPUClassifiedQuad>.stride
            let sampleBuf = try acquireBuffer(minBytes: sampleBytes, state: &state)
            let quadBuf = try acquireBuffer(minBytes: quadBytes, state: &state)
            let flagBuf = try acquireBuffer(minBytes: MemoryLayout<UInt32>.stride, state: &state)
            defer {
                releaseBuffer(sampleBuf, state: &state)
                releaseBuffer(quadBuf, state: &state)
                releaseBuffer(flagBuf, state: &state)
            }

            coefficients.withUnsafeBytes { _ = memcpy(sampleBuf.contents(), $0.baseAddress!, sampleBytes) }
            flagBuf.contents().storeBytes(of: UInt32(0), as: UInt32.self)

            guard let cmdBuf = commandQueue.makeCommandBuffer(),
                  let encoder = cmdBuf.makeComputeCommandEncoder()
            else {
                throw CodecError(.internalFailure, "Failed to create Metal command encoder for HT quad classification.")
            }

            var params = HTQuadParams(
                width: Int32(width),
                height: Int32(height),
                qw: Int32(qw),
                qh: Int32(qh),
                bandShift: Int32(bandShift)
            )
            encoder.setComputePipelineState(pipelineState)
            encoder.setBuffer(sampleBuf, offset: 0, index: 0)
            encoder.setBuffer(quadBuf, offset: 0, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<HTQuadParams>.stride, index: 2)
            encoder.setBuffer(flagBuf, offset: 0, index: 3)
            dispatch1D(encoder: encoder, pipeline: pipelineState, width: quadCount)
            encoder.endEncoding()

            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()
            state.dispatchCount += 1

            if flagBuf.contents().load(as: UInt32.self) != 0 {
                throw CodecError(.invalidArgument, "HTJ2K coefficient magnitude exceeds 30-bit reversible range.")
            }

            let rawPtr = quadBuf.contents().bindMemory(to: GPUClassifiedQuad.self, capacity: quadCount)
            var result = [SIMDHTBlockCoder.PreclassifiedQuad]()
            result.reserveCapacity(quadCount)
            for i in 0..<quadCount {
                let g = rawPtr[i]
                result.append(SIMDHTBlockCoder.PreclassifiedQuad(
                    rho: Int(g.rho),
                    eQMax: Int(g.eQMax),
                    eQ0: Int(g.eQ0),
                    eQ1: Int(g.eQ1),
                    eQ2: Int(g.eQ2),
                    eQ3: Int(g.eQ3),
                    s0: g.s0,
                    s1: g.s1,
                    s2: g.s2,
                    s3: g.s3
                ))
            }
            return result
        }
        #else
        throw CodecError(.backendUnavailable, "Metal is not available on this platform.")
        #endif
    }

    // MARK: - Private Metal Initialization, Buffer Pool, and Dispatch Helpers

    #if canImport(Metal)
    private func ensureInitialized(_ state: inout EngineState) -> Bool {
        if state.initialized {
            return state.device != nil && state.commandQueue != nil && state.library != nil
        }
        state.initialized = true

        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue()
        else {
            return false
        }

        let startNs = DispatchTime.now().uptimeNanoseconds
        let options = MTLCompileOptions()
        guard let library = try? device.makeLibrary(source: Self.metalShaderSource, options: options) else {
            return false
        }
        let endNs = DispatchTime.now().uptimeNanoseconds

        state.device = device
        state.commandQueue = queue
        state.library = library
        state.shaderCompilationDurationNs = endNs &- startNs
        return true
    }

    private func pipeline(
        named name: String,
        state: inout EngineState
    ) throws -> (any MTLComputePipelineState)? {
        if let existing = state.pipelines[name] {
            return existing
        }
        guard let device = state.device,
              let library = state.library,
              let fn = library.makeFunction(name: name)
        else {
            return nil
        }
        let cps = try device.makeComputePipelineState(function: fn)
        state.pipelines[name] = cps
        return cps
    }

    private func acquireBuffer(minBytes: Int, state: inout EngineState) throws -> any MTLBuffer {
        let bucket = Self.bucketSize(for: max(16, minBytes))
        if var list = state.bufferPool[bucket], let buf = list.popLast() {
            state.bufferPool[bucket] = list
            state.bufferPoolHits += 1
            return buf
        }
        guard let device = state.device,
              let buf = device.makeBuffer(length: bucket, options: .storageModeShared)
        else {
            throw CodecError(.resourceLimitExceeded, "Failed to allocate shared Metal buffer (\(bucket) bytes).")
        }
        state.bufferPoolMisses += 1
        return buf
    }

    private func releaseBuffer(_ buffer: any MTLBuffer, state: inout EngineState) {
        let bucket = buffer.length
        var list = state.bufferPool[bucket] ?? []
        if list.count < 8 {
            list.append(buffer)
            state.bufferPool[bucket] = list
        }
    }

    private static func bucketSize(for bytes: Int) -> Int {
        var power = 4096
        while power < bytes {
            power <<= 1
        }
        return power
    }

    private func dispatch1D(
        encoder: any MTLComputeCommandEncoder,
        pipeline: any MTLComputePipelineState,
        width: Int
    ) {
        guard width > 0 else { return }
        let w = min(width, max(1, pipeline.maxTotalThreadsPerThreadgroup))
        let threadsPerGroup = MTLSize(width: w, height: 1, depth: 1)
        let groups = MTLSize(width: (width + w - 1) / w, height: 1, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
    }

    private func dispatch2D(
        encoder: any MTLComputeCommandEncoder,
        pipeline: any MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        guard width > 0, height > 0 else { return }
        let w = min(width, max(1, min(16, pipeline.threadExecutionWidth)))
        let maxH = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let h = min(height, min(16, maxH))
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let groups = MTLSize(
            width: (width + w - 1) / w,
            height: (height + h - 1) / h,
            depth: 1
        )
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
    }

    private func encodeForward1DPass(
        commandBuffer: any MTLCommandBuffer,
        analysePipeline: any MTLComputePipelineState,
        commitPipeline: any MTLComputePipelineState,
        mainBuffer: any MTLBuffer,
        scratchBuffer: any MTLBuffer,
        stride: Int,
        i0: Int,
        n: Int,
        lineCount: Int,
        isVertical: Bool
    ) throws {
        guard n > 0, lineCount > 0 else { return }
        let lowCount = Wavelet53.lowCount(i0, i0 + n)
        var params = DWT53Params(
            stride: Int32(stride),
            i0: Int32(i0),
            n: Int32(n),
            lowCount: Int32(lowCount),
            lineCount: Int32(lineCount),
            isVertical: isVertical ? 1 : 0
        )

        guard let enc = commandBuffer.makeComputeCommandEncoder() else {
            throw CodecError(.internalFailure, "Failed to create Metal compute encoder.")
        }

        // 1. Analyse `mainBuffer` -> `scratchBuffer`
        enc.setComputePipelineState(analysePipeline)
        enc.setBuffer(mainBuffer, offset: 0, index: 0)
        enc.setBuffer(scratchBuffer, offset: 0, index: 1)
        enc.setBytes(&params, length: MemoryLayout<DWT53Params>.stride, index: 2)
        dispatch2D(encoder: enc, pipeline: analysePipeline, width: n, height: lineCount)

        // 2. Commit subband region from `scratchBuffer` back to `mainBuffer`
        let subWidth = isVertical ? lineCount : n
        let subHeight = isVertical ? n : lineCount
        enc.setComputePipelineState(commitPipeline)
        enc.setBuffer(scratchBuffer, offset: 0, index: 0)
        enc.setBuffer(mainBuffer, offset: 0, index: 1)
        enc.setBytes(&params, length: MemoryLayout<DWT53Params>.stride, index: 2)
        dispatch2D(encoder: enc, pipeline: commitPipeline, width: subWidth, height: subHeight)
        enc.endEncoding()
    }

    private func encodeInverse1DPass(
        commandBuffer: any MTLCommandBuffer,
        interleavePipeline: any MTLComputePipelineState,
        synthesisePipeline: any MTLComputePipelineState,
        mainBuffer: any MTLBuffer,
        scratchBuffer: any MTLBuffer,
        overflowBuffer: any MTLBuffer,
        stride: Int,
        i0: Int,
        n: Int,
        lineCount: Int,
        isVertical: Bool
    ) throws {
        guard n > 0, lineCount > 0 else { return }
        let lowCount = Wavelet53.lowCount(i0, i0 + n)
        var params = DWT53Params(
            stride: Int32(stride),
            i0: Int32(i0),
            n: Int32(n),
            lowCount: Int32(lowCount),
            lineCount: Int32(lineCount),
            isVertical: isVertical ? 1 : 0
        )

        guard let enc = commandBuffer.makeComputeCommandEncoder() else {
            throw CodecError(.internalFailure, "Failed to create Metal compute encoder.")
        }

        // 1. Interleave `[low | high]` from `mainBuffer` into `scratchBuffer` (`Y[0..<n]`)
        enc.setComputePipelineState(interleavePipeline)
        enc.setBuffer(mainBuffer, offset: 0, index: 0)
        enc.setBuffer(scratchBuffer, offset: 0, index: 1)
        enc.setBytes(&params, length: MemoryLayout<DWT53Params>.stride, index: 2)
        dispatch2D(encoder: enc, pipeline: interleavePipeline, width: n, height: lineCount)

        // 2. Synthesise `scratchBuffer` (`Y[0..<n]`) back into `mainBuffer` (`X[0..<n]`)
        enc.setComputePipelineState(synthesisePipeline)
        enc.setBuffer(scratchBuffer, offset: 0, index: 0)
        enc.setBuffer(mainBuffer, offset: 0, index: 1)
        enc.setBytes(&params, length: MemoryLayout<DWT53Params>.stride, index: 2)
        enc.setBuffer(overflowBuffer, offset: 0, index: 3)
        dispatch2D(encoder: enc, pipeline: synthesisePipeline, width: n, height: lineCount)
        enc.endEncoding()
    }

    // MARK: - Embedded Metal Shading Language (MSL) Source

    private static let metalShaderSource: String = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct DWT53Params {
        int stride;
        int i0;
        int n;
        int lowCount;
        int lineCount;
        int isVertical;
    };

    struct RCTParams {
        uint count;
    };

    struct ROIParams {
        uint count;
        int shift;
    };

    struct HTQuadParams {
        int width;
        int height;
        int qw;
        int qh;
        int bandShift;
    };

    struct GPUClassifiedQuad {
        int rho;
        int eQMax;
        int eQ0;
        int eQ1;
        int eQ2;
        int eQ3;
        uint s0;
        uint s1;
        uint s2;
        uint s3;
    };

    // ISO/IEC 15444-1 Annex F Table F.2 periodic symmetric extension (matches Wavelet53.extended)
    inline int j2k_extended_index(int i, int i0, int n) {
        if (n <= 1) { return 0; }
        int period = 2 * (n - 1);
        int k = (i - i0) % period;
        if (k < 0) { k += period; }
        if (k >= n) { k = period - k; }
        return k;
    }

    inline int j2k_linear_index(int posAlongLine, int lineIdx, constant DWT53Params& p) {
        if (p.isVertical != 0) {
            return posAlongLine * p.stride + lineIdx;
        } else {
            return lineIdx * p.stride + posAlongLine;
        }
    }

    inline int j2k_odd_y(int oddCoord, int line, device const int* src, constant DWT53Params& p) {
        int kL = j2k_extended_index(oddCoord - 1, p.i0, p.n);
        int kC = j2k_extended_index(oddCoord,     p.i0, p.n);
        int kR = j2k_extended_index(oddCoord + 1, p.i0, p.n);
        long l = long(src[j2k_linear_index(kL, line, p)]);
        long c = long(src[j2k_linear_index(kC, line, p)]);
        long r = long(src[j2k_linear_index(kR, line, p)]);
        return int(c - ((l + r) >> 1));
    }

    // 1D_SD: analyses `src` over [i0, i0+n) into [low | high] in `dst` (matches Wavelet53.analyse)
    kernel void j2k_dwt53_forward_1d(
        device const int* src [[buffer(0)]],
        device int* dst [[buffer(1)]],
        constant DWT53Params& p [[buffer(2)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        int pos = int(gid.x);
        int line = int(gid.y);
        if (pos >= p.n || line >= p.lineCount) { return; }

        int coord = p.i0 + pos;
        if (p.n == 1) {
            int x0 = src[j2k_linear_index(0, line, p)];
            dst[j2k_linear_index(0, line, p)] = ((p.i0 & 1) == 0) ? x0 : (x0 * 2);
            return;
        }

        int firstEven = (p.i0 & 1) == 0 ? p.i0 : (p.i0 + 1);
        int firstOdd  = (p.i0 & 1) != 0 ? p.i0 : (p.i0 + 1);

        if ((coord & 1) == 0) {
            int lowIdx = (coord - firstEven) / 2;
            long xEven = long(src[j2k_linear_index(pos, line, p)]);
            long oL = long(j2k_odd_y(coord - 1, line, src, p));
            long oR = long(j2k_odd_y(coord + 1, line, src, p));
            int lowVal = int(xEven + ((oL + oR + 2L) >> 2));
            dst[j2k_linear_index(lowIdx, line, p)] = lowVal;
        } else {
            int highIdx = (coord - firstOdd) / 2;
            int highVal = j2k_odd_y(coord, line, src, p);
            dst[j2k_linear_index(p.lowCount + highIdx, line, p)] = highVal;
        }
    }

    // Interleaves [low | high] from `src` into `yBuf` over [i0, i0+n) (matches Wavelet53.synthesise step 1)
    kernel void j2k_dwt53_interleave_1d(
        device const int* src [[buffer(0)]],
        device int* yBuf [[buffer(1)]],
        constant DWT53Params& p [[buffer(2)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        int pos = int(gid.x);
        int line = int(gid.y);
        if (pos >= p.n || line >= p.lineCount) { return; }

        int coord = p.i0 + pos;
        int firstEven = (p.i0 & 1) == 0 ? p.i0 : (p.i0 + 1);
        int firstOdd  = (p.i0 & 1) != 0 ? p.i0 : (p.i0 + 1);

        int val;
        if ((coord & 1) == 0) {
            int lowIdx = (coord - firstEven) / 2;
            val = src[j2k_linear_index(lowIdx, line, p)];
        } else {
            int highIdx = (coord - firstOdd) / 2;
            val = src[j2k_linear_index(p.lowCount + highIdx, line, p)];
        }
        yBuf[j2k_linear_index(pos, line, p)] = val;
    }

    inline int j2k_even_x(
        int evenCoord,
        int line,
        device const int* yBuf,
        constant DWT53Params& p,
        device atomic_uint* overflowFlag
    ) {
        int kL = j2k_extended_index(evenCoord - 1, p.i0, p.n);
        int kC = j2k_extended_index(evenCoord,     p.i0, p.n);
        int kR = j2k_extended_index(evenCoord + 1, p.i0, p.n);
        long l = long(yBuf[j2k_linear_index(kL, line, p)]);
        long c = long(yBuf[j2k_linear_index(kC, line, p)]);
        long r = long(yBuf[j2k_linear_index(kR, line, p)]);
        long even = c - ((l + r + 2L) >> 2);
        if (even < -2147483648L || even > 2147483647L) {
            atomic_store_explicit(overflowFlag, 1u, memory_order_relaxed);
        }
        return int(even);
    }

    // 1D_SR: reconstructs `dst` over [i0, i0+n) from interleaved `yBuf` (matches Wavelet53.synthesise)
    kernel void j2k_dwt53_inverse_1d(
        device const int* yBuf [[buffer(0)]],
        device int* dst [[buffer(1)]],
        constant DWT53Params& p [[buffer(2)]],
        device atomic_uint* overflowFlag [[buffer(3)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        int pos = int(gid.x);
        int line = int(gid.y);
        if (pos >= p.n || line >= p.lineCount) { return; }

        int coord = p.i0 + pos;
        if (p.n == 1) {
            int v = yBuf[j2k_linear_index(0, line, p)];
            dst[j2k_linear_index(0, line, p)] = ((p.i0 & 1) == 0) ? v : (v / 2);
            return;
        }

        if ((coord & 1) == 0) {
            if (pos == 0) {
                // Also validate firstEven = i0 - 2 just as Wavelet53.synthesise does
                (void)j2k_even_x(p.i0 - 2, line, yBuf, p, overflowFlag);
            }
            int evenVal = j2k_even_x(coord, line, yBuf, p, overflowFlag);
            dst[j2k_linear_index(pos, line, p)] = evenVal;
        } else {
            long yOdd = long(yBuf[j2k_linear_index(pos, line, p)]);
            long eL = long(j2k_even_x(coord - 1, line, yBuf, p, overflowFlag));
            long eR = long(j2k_even_x(coord + 1, line, yBuf, p, overflowFlag));
            long oddVal = yOdd + ((eL + eR) >> 1);
            if (oddVal < -2147483648L || oddVal > 2147483647L) {
                atomic_store_explicit(overflowFlag, 1u, memory_order_relaxed);
            }
            dst[j2k_linear_index(pos, line, p)] = int(oddVal);
        }
    }

    kernel void j2k_dwt53_commit_subband(
        device const int* src [[buffer(0)]],
        device int* dst [[buffer(1)]],
        constant DWT53Params& p [[buffer(2)]],
        uint2 gid [[thread_position_in_grid]]
    ) {
        int subWidth = (p.isVertical != 0) ? p.lineCount : p.n;
        int subHeight = (p.isVertical != 0) ? p.n : p.lineCount;
        int x = int(gid.x);
        int y = int(gid.y);
        if (x >= subWidth || y >= subHeight) { return; }
        int idx = y * p.stride + x;
        dst[idx] = src[idx];
    }

    // Forward RCT in-place using 64-bit intermediate arithmetic (fixes M9-AUD-005)
    kernel void j2k_rct_forward(
        device int* p0 [[buffer(0)]],
        device int* p1 [[buffer(1)]],
        device int* p2 [[buffer(2)]],
        constant RCTParams& p [[buffer(3)]],
        uint gid [[thread_position_in_grid]]
    ) {
        if (gid >= p.count) { return; }
        long r = long(p0[gid]);
        long g = long(p1[gid]);
        long b = long(p2[gid]);

        p0[gid] = int((r + 2L * g + b) >> 2);
        p1[gid] = int(b - g);
        p2[gid] = int(r - g);
    }

    // Inverse RCT in-place using 64-bit intermediate arithmetic (fixes M9-AUD-005)
    kernel void j2k_rct_inverse(
        device int* p0 [[buffer(0)]],
        device int* p1 [[buffer(1)]],
        device int* p2 [[buffer(2)]],
        constant RCTParams& p [[buffer(3)]],
        uint gid [[thread_position_in_grid]]
    ) {
        if (gid >= p.count) { return; }
        long yv  = long(p0[gid]);
        long cbv = long(p1[gid]);
        long crv = long(p2[gid]);

        long g = yv - ((cbv + crv) >> 2);
        long r = crv + g;
        long b = cbv + g;

        p0[gid] = int(r);
        p1[gid] = int(g);
        p2[gid] = int(b);
    }

    // ROI MaxShift decoder descaling (matches ROICoding.descaleCoefficient)
    kernel void j2k_roi_descale64(
        device long* coeffs [[buffer(0)]],
        constant ROIParams& p [[buffer(1)]],
        uint gid [[thread_position_in_grid]]
    ) {
        if (gid >= p.count) { return; }
        long val = coeffs[gid];
        if (val == 0 || p.shift <= 0) { return; }
        long threshold = 1L << long(p.shift);
        long mag = (val < 0) ? -val : val;
        if (mag >= threshold) {
            long descaled = mag >> long(p.shift);
            coeffs[gid] = (val < 0) ? -descaled : descaled;
        }
    }

    // HTJ2K 2x2 quad forward significance/exponent/MagSgn classifier
    kernel void j2k_ht_classify_quads(
        device const int* samples [[buffer(0)]],
        device GPUClassifiedQuad* quads [[buffer(1)]],
        constant HTQuadParams& p [[buffer(2)]],
        device atomic_uint* overflowFlag [[buffer(3)]],
        uint gid [[thread_position_in_grid]]
    ) {
        uint totalQuads = uint(p.qw * p.qh);
        if (gid >= totalQuads) { return; }

        int qy = int(gid) / p.qw;
        int qx = int(gid) % p.qw;
        int baseX = qx * 2;
        int baseY = qy * 2;

        GPUClassifiedQuad outQuad = { 0, 0, 0, 0, 0, 0, 0u, 0u, 0u, 0u };
        int eQ[4] = { 0, 0, 0, 0 };
        uint sArr[4] = { 0u, 0u, 0u, 0u };
        int rho = 0;
        int eQMax = 0;

        for (int i = 0; i < 4; ++i) {
            int dx = i >> 1;
            int dy = i & 1;
            int xi = baseX + dx;
            int yi = baseY + dy;
            if (xi >= p.width || yi >= p.height) { continue; }
            int c = samples[yi * p.width + xi];
            if (c == 0) { continue; }
            uint sign = (c < 0) ? 1u : 0u;
            ulong absVal = (c < 0) ? ulong(-long(c)) : ulong(c);
            ulong mu64 = absVal >> uint(p.bandShift);
            if (mu64 == 0ul) { continue; }
            if (mu64 > 0x3FFFFFFFul) {
                atomic_store_explicit(overflowFlag, 1u, memory_order_relaxed);
                continue;
            }
            uint mu = uint(mu64);
            rho |= (1 << i);
            uint twoMuMinus1 = (mu << 1u) - 1u;
            int eq = 32 - int(clz(twoMuMinus1));
            eQ[i] = eq;
            if (eq > eQMax) { eQMax = eq; }
            sArr[i] = (twoMuMinus1 - 1u) + sign;
        }

        outQuad.rho = rho;
        outQuad.eQMax = eQMax;
        outQuad.eQ0 = eQ[0];
        outQuad.eQ1 = eQ[1];
        outQuad.eQ2 = eQ[2];
        outQuad.eQ3 = eQ[3];
        outQuad.s0 = sArr[0];
        outQuad.s1 = sArr[1];
        outQuad.s2 = sArr[2];
        outQuad.s3 = sArr[3];
        quads[gid] = outQuad;
    }
    """#
    #endif
}
