// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Raster-Lab
//
// Migrated from J2KSwift Sources/J2KMetal/JP3DMetalDWT.swift
// Predecessor commit: 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca

import Foundation
import SwiftJ2K

#if canImport(Metal)
@preconcurrency import Metal
#endif

// MARK: - JP3D Metal DWT Backend

/// Backend selection for JP3D DWT computation.
public enum JP3DMetalDWTBackend: Sendable, Equatable {
    /// Force GPU execution via Metal compute shaders.
    case metal
    /// Force CPU execution (pure Swift software fallback).
    case cpu
    /// Automatically use Metal if available on this device, otherwise CPU.
    case automatic
}

// MARK: - JP3D Metal DWT Statistics

/// Performance statistics for JP3D Metal DWT operations.
public struct JP3DMetalDWTStatistics: Sendable, Equatable {
    /// Total number of forward transforms performed.
    public let forwardTransforms: Int
    /// Total number of inverse transforms performed.
    public let inverseTransforms: Int
    /// Number of transforms executed on the Metal GPU.
    public let metalAccelerated: Int
    /// Number of transforms that fell back to CPU execution.
    public let cpuFallbacks: Int
    /// Cumulative processing time in seconds.
    public let totalProcessingTime: Double

    /// Creates a statistics snapshot.
    public init(
        forwardTransforms: Int,
        inverseTransforms: Int,
        metalAccelerated: Int,
        cpuFallbacks: Int,
        totalProcessingTime: Double
    ) {
        self.forwardTransforms = forwardTransforms
        self.inverseTransforms = inverseTransforms
        self.metalAccelerated = metalAccelerated
        self.cpuFallbacks = cpuFallbacks
        self.totalProcessingTime = totalProcessingTime
    }
}

// MARK: - JP3D Metal DWT Actor

/// Metal-accelerated 3D discrete wavelet transform for JP3D volumetric processing.
public actor JP3DMetalDWT {
    /// Whether Metal acceleration is available on this device.
    public static var isMetalAvailable: Bool {
        #if canImport(Metal)
        guard AccelerationRuntime.isAvailable, AccelerationRuntime.isMetalDevicePermitted else {
            return false
        }
        return MTLCreateSystemDefaultDevice() != nil
        #else
        return false
        #endif
    }

    private let backend: JP3DMetalDWTBackend
    private var isInitialized = false
    private var metalEnabled = false

    private var _forwardTransforms = 0
    private var _inverseTransforms = 0
    private var _metalAccelerated = 0
    private var _cpuFallbacks = 0
    private var _totalProcessingTime: Double = 0.0

    #if canImport(Metal)
    private var metalLibrary: (any MTLLibrary)?
    private var pipelines: [String: any MTLComputePipelineState] = [:]
    private var commandQueue: (any MTLCommandQueue)?
    #endif

    /// Creates a JP3D Metal DWT actor.
    public init(backend: JP3DMetalDWTBackend = .automatic) {
        self.backend = backend
    }

    /// Initialises Metal resources: compiles shaders and creates pipeline states.
    public func initialize() async throws {
        guard !isInitialized else { return }
        defer { isInitialized = true }

        let wantMetal: Bool
        switch backend {
        case .metal:     wantMetal = true
        case .cpu:       wantMetal = false
        case .automatic: wantMetal = JP3DMetalDWT.isMetalAvailable
        }

        guard wantMetal else { return }

        #if canImport(Metal)
        do {
            try initializeMetal()
        } catch {
            if case .metal = backend {
                throw J2KError.internalError("JP3DMetalDWT Metal init failed: \(error)")
            }
        }
        #else
        if case .metal = backend {
            throw J2KError.internalError("JP3DMetalDWT Metal backend unavailable on this platform")
        }
        #endif
    }

    /// Forward Le Gall 5/3 DWT along the X axis of a 3D volume.
    public func forward53X(
        data: [Float],
        width: Int,
        height: Int,
        depth: Int
    ) async throws -> (low: [Float], high: [Float]) {
        let start = currentTime()
        defer {
            _forwardTransforms += 1
            _totalProcessingTime += currentTime() - start
        }

        guard width > 0, height > 0, depth > 0 else {
            throw J2KError.invalidParameter("JP3DMetalDWT.forward53X: dimensions must be positive")
        }
        let (wh, ov1) = width.multipliedReportingOverflow(by: height)
        let (total, ov2) = wh.multipliedReportingOverflow(by: depth)
        guard !ov1, !ov2, data.count == total else {
            throw J2KError.invalidParameter("JP3DMetalDWT.forward53X: data.count mismatch")
        }

        #if canImport(Metal)
        if metalEnabled, let result = try? await metalForward53X(
            data: data, width: width, height: height, depth: depth
        ) {
            _metalAccelerated += 1
            return result
        }
        #endif
        _cpuFallbacks += 1
        return cpuForward53X(data: data, width: width, height: height, depth: depth)
    }

    /// Inverse Le Gall 5/3 DWT along the X axis.
    public func inverse53X(
        low: [Float],
        high: [Float],
        origWidth: Int,
        height: Int,
        depth: Int
    ) async throws -> [Float] {
        let start = currentTime()
        defer {
            _inverseTransforms += 1
            _totalProcessingTime += currentTime() - start
        }

        let lowLen  = (origWidth + 1) / 2
        let highLen = origWidth / 2
        guard origWidth > 0, height > 0, depth > 0 else {
            throw J2KError.invalidParameter("JP3DMetalDWT.inverse53X: dimensions must be positive")
        }
        let (hd, ov1) = height.multipliedReportingOverflow(by: depth)
        let (lowExpected, ov2) = lowLen.multipliedReportingOverflow(by: hd)
        let (highExpected, ov3) = highLen.multipliedReportingOverflow(by: hd)
        guard !ov1, !ov2, !ov3,
              low.count == lowExpected,
              high.count == highExpected else {
            throw J2KError.invalidParameter("JP3DMetalDWT.inverse53X: subband size mismatch")
        }

        #if canImport(Metal)
        if metalEnabled, let result = try? await metalInverse53X(
            low: low, high: high,
            origWidth: origWidth, height: height, depth: depth
        ) {
            _metalAccelerated += 1
            return result
        }
        #endif
        _cpuFallbacks += 1
        return cpuInverse53X(
            low: low, high: high,
            origWidth: origWidth, height: height, depth: depth
        )
    }

    /// Forward CDF 9/7 DWT along the X axis of a 3D volume.
    public func forward97X(
        data: [Float],
        width: Int,
        height: Int,
        depth: Int
    ) async throws -> (low: [Float], high: [Float]) {
        let start = currentTime()
        defer {
            _forwardTransforms += 1
            _totalProcessingTime += currentTime() - start
        }

        guard width > 0, height > 0, depth > 0 else {
            throw J2KError.invalidParameter("JP3DMetalDWT.forward97X: dimensions must be positive")
        }
        let (wh, ov1) = width.multipliedReportingOverflow(by: height)
        let (total, ov2) = wh.multipliedReportingOverflow(by: depth)
        guard !ov1, !ov2, data.count == total else {
            throw J2KError.invalidParameter("JP3DMetalDWT.forward97X: data.count mismatch")
        }

        #if canImport(Metal)
        if metalEnabled, let result = try? await metalForward97X(
            data: data, width: width, height: height, depth: depth
        ) {
            _metalAccelerated += 1
            return result
        }
        #endif
        _cpuFallbacks += 1
        return cpuForward97X(data: data, width: width, height: height, depth: depth)
    }

    /// Inverse CDF 9/7 DWT along the X axis.
    public func inverse97X(
        low: [Float],
        high: [Float],
        origWidth: Int,
        height: Int,
        depth: Int
    ) async throws -> [Float] {
        let start = currentTime()
        defer {
            _inverseTransforms += 1
            _totalProcessingTime += currentTime() - start
        }

        let lowLen  = (origWidth + 1) / 2
        let highLen = origWidth / 2
        guard origWidth > 0, height > 0, depth > 0 else {
            throw J2KError.invalidParameter("JP3DMetalDWT.inverse97X: dimensions must be positive")
        }
        let (hd, ov1) = height.multipliedReportingOverflow(by: depth)
        let (lowExpected, ov2) = lowLen.multipliedReportingOverflow(by: hd)
        let (highExpected, ov3) = highLen.multipliedReportingOverflow(by: hd)
        guard !ov1, !ov2, !ov3,
              low.count == lowExpected,
              high.count == highExpected else {
            throw J2KError.invalidParameter("JP3DMetalDWT.inverse97X: subband size mismatch")
        }

        #if canImport(Metal)
        if metalEnabled, let result = try? await metalInverse97X(
            low: low, high: high,
            origWidth: origWidth, height: height, depth: depth
        ) {
            _metalAccelerated += 1
            return result
        }
        #endif
        _cpuFallbacks += 1
        return cpuInverse97X(
            low: low, high: high,
            origWidth: origWidth, height: height, depth: depth
        )
    }

    /// Returns a snapshot of current processing statistics.
    public func statistics() -> JP3DMetalDWTStatistics {
        JP3DMetalDWTStatistics(
            forwardTransforms: _forwardTransforms,
            inverseTransforms: _inverseTransforms,
            metalAccelerated: _metalAccelerated,
            cpuFallbacks: _cpuFallbacks,
            totalProcessingTime: _totalProcessingTime
        )
    }

    /// Resets all statistics counters to zero.
    public func resetStatistics() {
        _forwardTransforms = 0
        _inverseTransforms = 0
        _metalAccelerated = 0
        _cpuFallbacks = 0
        _totalProcessingTime = 0.0
    }

    private func currentTime() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000.0
    }
}

// MARK: - Metal GPU Path

#if canImport(Metal)
extension JP3DMetalDWT {
    private static let mslSource: String = """
#include <metal_stdlib>
using namespace metal;

static inline float safeGet(device const float* buf, int idx, int len) {
    if (idx < 0)   idx = -idx;
    if (idx >= len) idx = 2 * (len - 1) - idx;
    idx = clamp(idx, 0, len - 1);
    return buf[idx];
}

kernel void jp3d_dwt_forward_53_x(
    device const float* input  [[buffer(0)]],
    device       float* outLow [[buffer(1)]],
    device       float* outHigh[[buffer(2)]],
    constant uint& width       [[buffer(3)]],
    constant uint& height      [[buffer(4)]],
    constant uint& depth       [[buffer(5)]],
    uint gid [[thread_position_in_grid]]
) {
    uint totalRows = height * depth;
    if (gid >= totalRows) return;

    int W = (int)width;
    int lowLen  = (W + 1) / 2;
    int highLen = W / 2;

    int rowOffset = (int)gid * W;
    device const float* row = input + rowOffset;

    for (int i = 0; i < highLen; ++i) {
        float left  = safeGet(row, 2 * i,     W);
        float right = safeGet(row, 2 * i + 2, W);
        outHigh[(int)gid * highLen + i] = row[2 * i + 1] - floor((left + right) / 2.0f);
    }

    for (int i = 0; i < lowLen; ++i) {
        float hPrev = (i == 0)
            ? outHigh[(int)gid * highLen]
            : outHigh[(int)gid * highLen + (i - 1)];
        float hCurr = (i < highLen)
            ? outHigh[(int)gid * highLen + i]
            : outHigh[(int)gid * highLen + max(highLen - 1, 0)];
        outLow[(int)gid * lowLen + i] = row[2 * i] + floor((hPrev + hCurr + 2.0f) / 4.0f);
    }
}

kernel void jp3d_dwt_inverse_53_x(
    device const float* inLow  [[buffer(0)]],
    device const float* inHigh [[buffer(1)]],
    device       float* output [[buffer(2)]],
    constant uint& origWidth   [[buffer(3)]],
    constant uint& height      [[buffer(4)]],
    constant uint& depth       [[buffer(5)]],
    uint gid [[thread_position_in_grid]]
) {
    uint totalRows = height * depth;
    if (gid >= totalRows) return;

    int W       = (int)origWidth;
    int lowLen  = (W + 1) / 2;
    int highLen = W / 2;
    int rowOut  = (int)gid * W;

    device const float* L = inLow  + (int)gid * lowLen;
    device const float* H = inHigh + (int)gid * highLen;
    device float*       O = output + rowOut;

    for (int i = 0; i < lowLen; ++i) {
        float hPrev = (i == 0) ? (highLen > 0 ? H[0] : 0.0f) : H[i - 1];
        float hCurr = (i < highLen) ? H[i] : (highLen > 0 ? H[highLen - 1] : 0.0f);
        O[2 * i] = L[i] - floor((hPrev + hCurr + 2.0f) / 4.0f);
    }

    for (int i = 0; i < highLen; ++i) {
        float left  = O[2 * i];
        float right = (2 * i + 2 < W) ? O[2 * i + 2] : O[2 * (lowLen - 1)];
        O[2 * i + 1] = H[i] + floor((left + right) / 2.0f);
    }
}

constant float kAlpha   = -1.586134342f;
constant float kBeta    = -0.052980118f;
constant float kGamma   =  0.882911075f;
constant float kDelta   =  0.443506852f;
constant float kK       =  1.230174105f;
constant float kKInv    =  1.0f / 1.230174105f;

kernel void jp3d_dwt_forward_97_x(
    device const float* input  [[buffer(0)]],
    device       float* outLow [[buffer(1)]],
    device       float* outHigh[[buffer(2)]],
    constant uint& width       [[buffer(3)]],
    constant uint& height      [[buffer(4)]],
    constant uint& depth       [[buffer(5)]],
    uint gid [[thread_position_in_grid]]
) {
    uint totalRows = height * depth;
    if (gid >= totalRows) return;

    int W      = (int)width;
    int rowOff = (int)gid * W;
    int lowLen = (W + 1) / 2;
    int hiLen  = W / 2;

    device const float* src = input + rowOff;

    for (int i = 0; i < lowLen; ++i) outLow [(int)gid * lowLen + i] = src[2 * i];
    for (int i = 0; i < hiLen;  ++i) outHigh[(int)gid * hiLen  + i] = src[2 * i + 1];

    device float* L = outLow  + (int)gid * lowLen;
    device float* H = outHigh + (int)gid * hiLen;

    for (int i = 0; i < hiLen; ++i) {
        float lLeft  = L[i];
        float lRight = (i + 1 < lowLen) ? L[i + 1] : L[lowLen - 1];
        H[i] += kAlpha * (lLeft + lRight);
    }
    for (int i = 0; i < lowLen; ++i) {
        float hPrev = (i == 0) ? (hiLen > 0 ? H[0] : 0.0f) : H[i - 1];
        float hCurr = (i < hiLen) ? H[i] : (hiLen > 0 ? H[hiLen - 1] : 0.0f);
        L[i] += kBeta * (hPrev + hCurr);
    }
    for (int i = 0; i < hiLen; ++i) {
        float lLeft  = L[i];
        float lRight = (i + 1 < lowLen) ? L[i + 1] : L[lowLen - 1];
        H[i] += kGamma * (lLeft + lRight);
    }
    for (int i = 0; i < lowLen; ++i) {
        float hPrev = (i == 0) ? (hiLen > 0 ? H[0] : 0.0f) : H[i - 1];
        float hCurr = (i < hiLen) ? H[i] : (hiLen > 0 ? H[hiLen - 1] : 0.0f);
        L[i] += kDelta * (hPrev + hCurr);
    }
    for (int i = 0; i < lowLen; ++i) L[i] *= kKInv;
    for (int i = 0; i < hiLen;  ++i) H[i] *= kK;
}
"""

    private func initializeMetal() throws {
        guard JP3DMetalDWT.isMetalAvailable, let device = MTLCreateSystemDefaultDevice() else {
            throw J2KError.unsupportedFeature("No Metal device available")
        }
        guard let queue = device.makeCommandQueue() else {
            throw J2KError.internalError("Failed to create Metal command queue")
        }

        let options = MTLCompileOptions()
        options.languageVersion = .version2_4

        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(source: JP3DMetalDWT.mslSource, options: options)
        } catch {
            throw J2KError.internalError("JP3DMetalDWT shader compilation failed: \(error)")
        }

        var builtPipelines: [String: any MTLComputePipelineState] = [:]
        let kernelNames = [
            "jp3d_dwt_forward_53_x",
            "jp3d_dwt_inverse_53_x",
            "jp3d_dwt_forward_97_x"
        ]
        for name in kernelNames {
            guard let fn = library.makeFunction(name: name) else {
                throw J2KError.internalError("Missing kernel: \(name)")
            }
            builtPipelines[name] = try device.makeComputePipelineState(function: fn)
        }

        metalLibrary = library
        commandQueue = queue
        pipelines    = builtPipelines
        metalEnabled = true
    }

    private func metalForward53X(
        data: [Float], width: Int, height: Int, depth: Int
    ) async throws -> (low: [Float], high: [Float]) {
        guard width >= 2,
              let device = commandQueue?.device,
              let queue  = commandQueue,
              let pipeline = pipelines["jp3d_dwt_forward_53_x"] else {
            throw J2KError.internalError("Metal not initialised or width < 2")
        }

        let lowLen  = (width + 1) / 2
        let highLen = width / 2
        let rows    = height * depth

        let inputBuf = try makeBuffer(device: device, data: data)
        guard let lowBuf = device.makeBuffer(
            length: max(4, rows * lowLen * MemoryLayout<Float>.stride),
            options: .storageModeShared
        ),
        let highBuf = device.makeBuffer(
            length: max(4, rows * highLen * MemoryLayout<Float>.stride),
            options: .storageModeShared
        ) else {
            throw J2KError.internalError("Failed to allocate Metal output buffers")
        }

        var w = UInt32(width), h = UInt32(height), d = UInt32(depth)

        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else {
            throw J2KError.internalError("Failed to create command encoder")
        }
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(inputBuf, offset: 0, index: 0)
        enc.setBuffer(lowBuf, offset: 0, index: 1)
        enc.setBuffer(highBuf, offset: 0, index: 2)
        enc.setBytes(&w, length: 4, index: 3)
        enc.setBytes(&h, length: 4, index: 4)
        enc.setBytes(&d, length: 4, index: 5)
        let tg = MTLSize(width: min(rows, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
        let g  = MTLSize(width: rows, height: 1, depth: 1)
        enc.dispatchThreads(g, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit()
        await cb.completed()

        return (
            low: readBuffer(lowBuf, count: rows * lowLen),
            high: readBuffer(highBuf, count: rows * highLen)
        )
    }

    private func metalInverse53X(
        low: [Float], high: [Float],
        origWidth: Int, height: Int, depth: Int
    ) async throws -> [Float] {
        guard origWidth >= 2,
              let device = commandQueue?.device,
              let queue  = commandQueue,
              let pipeline = pipelines["jp3d_dwt_inverse_53_x"] else {
            throw J2KError.internalError("Metal not initialised or origWidth < 2")
        }

        let rows = height * depth
        let lowBuf  = try makeBuffer(device: device, data: low)
        let highBuf = try makeBuffer(device: device, data: high)
        guard let outBuf = device.makeBuffer(
            length: max(4, rows * origWidth * MemoryLayout<Float>.stride),
            options: .storageModeShared
        ) else {
            throw J2KError.internalError("Failed to allocate Metal output buffer")
        }

        var ow = UInt32(origWidth), h = UInt32(height), d = UInt32(depth)

        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else {
            throw J2KError.internalError("Failed to create command encoder")
        }
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(lowBuf, offset: 0, index: 0)
        enc.setBuffer(highBuf, offset: 0, index: 1)
        enc.setBuffer(outBuf, offset: 0, index: 2)
        enc.setBytes(&ow, length: 4, index: 3)
        enc.setBytes(&h, length: 4, index: 4)
        enc.setBytes(&d, length: 4, index: 5)
        let tg = MTLSize(width: min(rows, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
        let g  = MTLSize(width: rows, height: 1, depth: 1)
        enc.dispatchThreads(g, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit()
        await cb.completed()

        return readBuffer(outBuf, count: rows * origWidth)
    }

    private func metalForward97X(
        data: [Float], width: Int, height: Int, depth: Int
    ) async throws -> (low: [Float], high: [Float]) {
        guard width >= 2,
              let device = commandQueue?.device,
              let queue  = commandQueue,
              let pipeline = pipelines["jp3d_dwt_forward_97_x"] else {
            throw J2KError.internalError("Metal not initialised or width < 2")
        }

        let lowLen  = (width + 1) / 2
        let highLen = width / 2
        let rows    = height * depth

        let inputBuf = try makeBuffer(device: device, data: data)
        guard let lowBuf = device.makeBuffer(
            length: max(4, rows * lowLen * MemoryLayout<Float>.stride),
            options: .storageModeShared
        ),
        let highBuf = device.makeBuffer(
            length: max(4, rows * highLen * MemoryLayout<Float>.stride),
            options: .storageModeShared
        ) else {
            throw J2KError.internalError("Failed to allocate Metal output buffers")
        }

        var w = UInt32(width), h = UInt32(height), d = UInt32(depth)

        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else {
            throw J2KError.internalError("Failed to create command encoder")
        }
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(inputBuf, offset: 0, index: 0)
        enc.setBuffer(lowBuf, offset: 0, index: 1)
        enc.setBuffer(highBuf, offset: 0, index: 2)
        enc.setBytes(&w, length: 4, index: 3)
        enc.setBytes(&h, length: 4, index: 4)
        enc.setBytes(&d, length: 4, index: 5)
        let tg = MTLSize(width: min(rows, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1)
        let g  = MTLSize(width: rows, height: 1, depth: 1)
        enc.dispatchThreads(g, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit()
        await cb.completed()

        return (
            low: readBuffer(lowBuf, count: rows * lowLen),
            high: readBuffer(highBuf, count: rows * highLen)
        )
    }

    private func metalInverse97X(
        low: [Float], high: [Float],
        origWidth: Int, height: Int, depth: Int
    ) async throws -> [Float] {
        cpuInverse97X(
            low: low, high: high,
            origWidth: origWidth, height: height, depth: depth
        )
    }

    private func makeBuffer(device: any MTLDevice, data: [Float]) throws -> any MTLBuffer {
        let byteCount = max(4, data.count * MemoryLayout<Float>.stride)
        if data.isEmpty {
            guard let buf = device.makeBuffer(length: byteCount, options: .storageModeShared) else {
                throw J2KError.internalError("Failed to allocate Metal buffer")
            }
            return buf
        }
        guard let buf = device.makeBuffer(
            bytes: data,
            length: data.count * MemoryLayout<Float>.stride,
            options: .storageModeShared
        ) else {
            throw J2KError.internalError("Failed to allocate Metal buffer")
        }
        return buf
    }

    private func readBuffer(_ buf: any MTLBuffer, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        let ptr = buf.contents().assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }
}
#endif

// MARK: - CPU Fallback

extension JP3DMetalDWT {
    private func cpuForward53X(
        data: [Float], width: Int, height: Int, depth: Int
    ) -> (low: [Float], high: [Float]) {
        let lowLen  = (width + 1) / 2
        let highLen = width / 2
        let rows    = height * depth

        var low  = [Float](repeating: 0, count: rows * lowLen)
        var high = [Float](repeating: 0, count: rows * highLen)

        for row in 0..<rows {
            let offset = row * width
            let slice  = Array(data[offset..<(offset + width)])
            let (l, h) = forward53Lifting(signal: slice)
            low.replaceSubrange((row * lowLen)..<(row * lowLen + lowLen), with: l)
            high.replaceSubrange((row * highLen)..<(row * highLen + highLen), with: h)
        }
        return (low: low, high: high)
    }

    private func cpuInverse53X(
        low: [Float], high: [Float],
        origWidth: Int, height: Int, depth: Int
    ) -> [Float] {
        let lowLen  = (origWidth + 1) / 2
        let highLen = origWidth / 2
        let rows    = height * depth

        var output = [Float](repeating: 0, count: rows * origWidth)
        for row in 0..<rows {
            let l = Array(low[row * lowLen..<row * lowLen + lowLen])
            let h = Array(high[row * highLen..<row * highLen + highLen])
            let rec = inverse53Lifting(low: l, high: h, origLen: origWidth)
            output.replaceSubrange(
                (row * origWidth)..<(row * origWidth + origWidth), with: rec
            )
        }
        return output
    }

    private func cpuForward97X(
        data: [Float], width: Int, height: Int, depth: Int
    ) -> (low: [Float], high: [Float]) {
        let lowLen  = (width + 1) / 2
        let highLen = width / 2
        let rows    = height * depth

        var low  = [Float](repeating: 0, count: rows * lowLen)
        var high = [Float](repeating: 0, count: rows * highLen)

        for row in 0..<rows {
            let offset = row * width
            let slice  = Array(data[offset..<(offset + width)])
            let (l, h) = forward97Lifting(signal: slice)
            low.replaceSubrange((row * lowLen)..<(row * lowLen + lowLen), with: l)
            high.replaceSubrange((row * highLen)..<(row * highLen + highLen), with: h)
        }
        return (low: low, high: high)
    }

    func cpuInverse97X(
        low: [Float], high: [Float],
        origWidth: Int, height: Int, depth: Int
    ) -> [Float] {
        let lowLen  = (origWidth + 1) / 2
        let highLen = origWidth / 2
        let rows    = height * depth

        var output = [Float](repeating: 0, count: rows * origWidth)
        for row in 0..<rows {
            let l = Array(low[row * lowLen..<row * lowLen + lowLen])
            let h = Array(high[row * highLen..<row * highLen + highLen])
            let rec = inverse97Lifting(low: l, high: h, origLen: origWidth)
            output.replaceSubrange(
                (row * origWidth)..<(row * origWidth + origWidth), with: rec
            )
        }
        return output
    }

    private func forward53Lifting(signal: [Float]) -> (low: [Float], high: [Float]) {
        let n = signal.count
        guard n > 0 else { return ([], []) }
        if n == 1 { return ([signal[0]], []) }
        let lowLen  = (n + 1) / 2
        let highLen = n / 2

        var low  = [Float](repeating: 0, count: lowLen)
        var high = [Float](repeating: 0, count: highLen)

        for i in 0..<highLen {
            let left = signal[2 * i]
            let right: Float = (2 * i + 2 < n) ? signal[2 * i + 2] : signal[max(n - 2, 0)]
            high[i] = signal[2 * i + 1] - floor((left + right) / 2)
        }
        for i in 0..<lowLen {
            let hPrev: Float = (i == 0) ? high[0] : high[i - 1]
            let hCurr: Float = (i < highLen) ? high[i] : high[max(highLen - 1, 0)]
            low[i] = signal[2 * i] + floor((hPrev + hCurr + 2) / 4)
        }
        return (low: low, high: high)
    }

    private func inverse53Lifting(low: [Float], high: [Float], origLen: Int) -> [Float] {
        if origLen == 1 { return low }
        let lowLen  = low.count
        let highLen = high.count
        var out = [Float](repeating: 0, count: origLen)

        for i in 0..<lowLen {
            let hPrev: Float = (i == 0) ? (highLen > 0 ? high[0] : 0) : high[i - 1]
            let hCurr: Float = (i < highLen) ? high[i] : (highLen > 0 ? high[highLen - 1] : 0)
            out[2 * i] = low[i] - floor((hPrev + hCurr + 2) / 4)
        }
        for i in 0..<highLen {
            let left = out[2 * i]
            let right: Float = (2 * i + 2 < origLen)
                ? out[2 * i + 2]
                : out[2 * max(lowLen - 1, 0)]
            out[2 * i + 1] = high[i] + floor((left + right) / 2)
        }
        return out
    }

    private func forward97Lifting(signal: [Float]) -> (low: [Float], high: [Float]) {
        let n = signal.count
        guard n > 0 else { return ([], []) }
        if n == 1 { return ([signal[0]], []) }
        let lowLen  = (n + 1) / 2
        let highLen = n / 2

        let alpha: Float = -1.586_134_342
        let beta: Float = -0.052_980_118
        let gamma: Float = 0.882_911_075
        let delta: Float = 0.443_506_852
        let k: Float = 1.230_174_105

        var l = [Float](repeating: 0, count: lowLen)
        var h = [Float](repeating: 0, count: highLen)

        for i in 0..<lowLen { l[i] = signal[2 * i] }
        for i in 0..<highLen { h[i] = signal[2 * i + 1] }

        for i in 0..<highLen {
            let lR: Float = (i + 1 < lowLen) ? l[i + 1] : l[max(lowLen - 1, 0)]
            h[i] += alpha * (l[i] + lR)
        }
        for i in 0..<lowLen {
            let hP: Float = (i == 0) ? h[0] : h[i - 1]
            let hC: Float = (i < highLen) ? h[i] : h[max(highLen - 1, 0)]
            l[i] += beta * (hP + hC)
        }
        for i in 0..<highLen {
            let lR: Float = (i + 1 < lowLen) ? l[i + 1] : l[max(lowLen - 1, 0)]
            h[i] += gamma * (l[i] + lR)
        }
        for i in 0..<lowLen {
            let hP: Float = (i == 0) ? h[0] : h[i - 1]
            let hC: Float = (i < highLen) ? h[i] : h[max(highLen - 1, 0)]
            l[i] += delta * (hP + hC)
        }
        for i in 0..<lowLen { l[i] /= k }
        for i in 0..<highLen { h[i] *= k }
        return (low: l, high: h)
    }

    private func inverse97Lifting(low: [Float], high: [Float], origLen: Int) -> [Float] {
        if origLen == 1 { return low }
        let lowLen  = low.count
        let highLen = high.count

        let alpha: Float = -1.586_134_342
        let beta: Float = -0.052_980_118
        let gamma: Float = 0.882_911_075
        let delta: Float = 0.443_506_852
        let k: Float = 1.230_174_105

        var l = low
        var h = high

        for i in 0..<lowLen { l[i] *= k }
        for i in 0..<highLen { h[i] /= k }

        for i in 0..<lowLen {
            let hP: Float = (i == 0) ? h[0] : h[i - 1]
            let hC: Float = (i < highLen) ? h[i] : h[max(highLen - 1, 0)]
            l[i] -= delta * (hP + hC)
        }
        for i in 0..<highLen {
            let lR: Float = (i + 1 < lowLen) ? l[i + 1] : l[max(lowLen - 1, 0)]
            h[i] -= gamma * (l[i] + lR)
        }
        for i in 0..<lowLen {
            let hP: Float = (i == 0) ? h[0] : h[i - 1]
            let hC: Float = (i < highLen) ? h[i] : h[max(highLen - 1, 0)]
            l[i] -= beta * (hP + hC)
        }
        for i in 0..<highLen {
            let lR: Float = (i + 1 < lowLen) ? l[i + 1] : l[max(lowLen - 1, 0)]
            h[i] -= alpha * (l[i] + lR)
        }

        var out = [Float](repeating: 0, count: origLen)
        for i in 0..<lowLen { out[2 * i] = l[i] }
        for i in 0..<highLen { out[2 * i + 1] = h[i] }
        return out
    }
}
