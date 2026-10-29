// SPDX-License-Identifier: Apache-2.0
//
// R1VolumeRemediationTests.swift
// SwiftJ2K3DTests
//
// Phase R1 volumetric audit remediation regressions covering:
// - F02 (32-bit and 38-bit unsigned/signed lossless exact voxel preservation)
// - R1-CODE-01 (checked Int64 5/3 lifting arithmetic on adversarial Int64.max coefficients)
// - F03 (resolutionLevel > 32 rejected cleanly without shift trap)
// - F05 + follow-up residual (combined live multi-worker + retained-tile + J3DI workspace admission,
//   JP3DCodestreamParser tile-subdata pre-allocation admission, inspect payload-free parsing,
//   deadlineSeconds, and maximumWorkers concurrency cap)
// - F06 (truthful OperationReport.fidelity on partial/corrupted, reduced-resolution/layer, and lossy 3D decodes)
// - F13 (post-.completed cancellation across VolumeEncoder, VolumeDecoder, and VolumeTranscoder)

import Foundation
import Synchronization
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2K3D

// MARK: - Helpers

private func packLittleEndianSamples(
    _ samples: [Int64],
    bitDepth: Int,
    signed: Bool
) -> Data {
    let bytesPerSample = (bitDepth + 7) / 8
    var out = Data(count: samples.count * bytesPerSample)
    let mask: UInt64 = bitDepth == 64 ? UInt64.max : ((UInt64(1) << UInt64(bitDepth)) - 1)
    out.withUnsafeMutableBytes { rawBuf in
        guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        for (i, sample) in samples.enumerated() {
            let word: UInt64 = signed
                ? (UInt64(bitPattern: sample) & mask)
                : (UInt64(bitPattern: max(0, sample)) & mask)
            let offset = i * bytesPerSample
            for b in 0..<bytesPerSample {
                base[offset + b] = UInt8(truncatingIfNeeded: word >> (b * 8))
            }
        }
    }
    return out
}

private func unpackLittleEndianSamples(
    _ data: Data,
    voxelCount: Int,
    bitDepth: Int,
    signed: Bool
) -> [Int64] {
    let bytesPerSample = (bitDepth + 7) / 8
    var out = [Int64](repeating: 0, count: voxelCount)
    let signBit = UInt64(1) << UInt64(bitDepth - 1)
    let valueMask: UInt64 = (UInt64(1) << UInt64(bitDepth)) - 1
    let signExtendMask: UInt64 = ~valueMask
    data.withUnsafeBytes { rawBuf in
        guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        for i in 0..<voxelCount {
            var word: UInt64 = 0
            let offset = i * bytesPerSample
            for b in 0..<bytesPerSample {
                word |= UInt64(base[offset + b]) << UInt64(b * 8)
            }
            word &= valueMask
            if signed && (word & signBit) != 0 {
                out[i] = Int64(bitPattern: word | signExtendMask)
            } else {
                out[i] = Int64(bitPattern: word)
            }
        }
    }
    return out
}

@Suite("Phase R1 — SwiftJ2K3D Audit Remediation Regressions")
struct R1VolumeRemediationTests {

    @Test("F02: 32-bit and 38-bit unsigned/signed lossless volumes preserve exact integer voxels (including 2^24 + 1 = 16,777,217)")
    func highBitDepthLosslessExactVoxelPreservation() async throws {
        let width = 4, height = 4, depth = 4
        let voxelCount = width * height * depth

        // 1. 32-bit unsigned including 16_777_217 (which Float(16_777_217) truncates to 16_777_216) and UInt32.max
        let u32Palette: [Int64] = [
            0, 1, 16_777_215, 16_777_216, 16_777_217, 16_777_218, 16_777_219,
            2_147_483_647, 2_147_483_648, 3_000_000_005, Int64(UInt32.max - 1), Int64(UInt32.max)
        ]
        let u32Samples = (0..<voxelCount).map { u32Palette[$0 % u32Palette.count] }
        let u32Volume = J2KVolume(
            width: width,
            height: height,
            depth: depth,
            components: [
                J2KVolumeComponent(
                    index: 0,
                    bitDepth: 32,
                    signed: false,
                    width: width,
                    height: height,
                    depth: depth,
                    data: packLittleEndianSamples(u32Samples, bitDepth: 32, signed: false)
                )
            ]
        )

        let encoder = try VolumeEncoder(
            configuration: try VolumeEncoderConfiguration(
                compressionMode: .lossless,
                tiling: JP3DTilingConfiguration(tileSizeX: 2, tileSizeY: 2, tileSizeZ: 2),
                levelsX: 1,
                levelsY: 1,
                levelsZ: 1
            )
        )
        let decoder = try VolumeDecoder()
        let encodedU32 = try await encoder.encode(u32Volume)
        #expect(encodedU32.report.fidelity == .exactSamples)

        let decodedU32 = try await decoder.decode(encodedU32.data)
        #expect(decodedU32.report.fidelity == .exactSamples)
        let roundTripU32 = unpackLittleEndianSamples(
            decodedU32.volume.components[0].data,
            voxelCount: voxelCount,
            bitDepth: 32,
            signed: false
        )
        #expect(roundTripU32 == u32Samples)
        #expect(roundTripU32.contains(16_777_217))
        #expect(roundTripU32.contains(Int64(UInt32.max)))

        // Sub-volume ROI decode preserves 32-bit exact voxels:
        let roi = JP3DRegion(x: 1..<3, y: 1..<3, z: 1..<3)
        let roiDecodedU32 = try await decoder.decode(
            encodedU32.data,
            options: VolumeDecodeOptions(regionOfInterest: roi)
        )
        let roiSamples = unpackLittleEndianSamples(
            roiDecodedU32.volume.components[0].data,
            voxelCount: 8,
            bitDepth: 32,
            signed: false
        )
        var expectedROI: [Int64] = []
        for z in 1..<3 {
            for y in 1..<3 {
                for x in 1..<3 {
                    expectedROI.append(u32Samples[z * width * height + y * width + x])
                }
            }
        }
        #expect(roiSamples == expectedROI)

        // VolumeTranscoder (.jpeg2000 -> .htj2k) preserves 32-bit exact voxels:
        let transcodedHT = try await VolumeTranscoder().transcode(encodedU32.data, to: .htj2k)
        #expect(transcodedHT.report.fidelity == .exactSamples)
        let decodedHTU32 = try await decoder.decode(transcodedHT.data)
        let htSamplesU32 = unpackLittleEndianSamples(
            decodedHTU32.volume.components[0].data,
            voxelCount: voxelCount,
            bitDepth: 32,
            signed: false
        )
        #expect(htSamplesU32 == u32Samples)

        // 2. 32-bit signed exact preservation
        let s32Palette: [Int64] = [
            Int64(Int32.min), Int64(Int32.min + 1), -16_777_219, -16_777_217, -16_777_216,
            -1, 0, 1, 16_777_216, 16_777_217, Int64(Int32.max - 1), Int64(Int32.max)
        ]
        let s32Samples = (0..<voxelCount).map { s32Palette[$0 % s32Palette.count] }
        let s32Volume = J2KVolume(
            width: width,
            height: height,
            depth: depth,
            components: [
                J2KVolumeComponent(
                    index: 0,
                    bitDepth: 32,
                    signed: true,
                    width: width,
                    height: height,
                    depth: depth,
                    data: packLittleEndianSamples(s32Samples, bitDepth: 32, signed: true)
                )
            ]
        )
        let encodedS32 = try await encoder.encode(s32Volume)
        let decodedS32 = try await decoder.decode(encodedS32.data)
        let roundTripS32 = unpackLittleEndianSamples(
            decodedS32.volume.components[0].data,
            voxelCount: voxelCount,
            bitDepth: 32,
            signed: true
        )
        #expect(roundTripS32 == s32Samples)

        // 3. 38-bit unsigned and 38-bit signed exact preservation (5 bytes/sample)
        let maxU38: Int64 = (Int64(1) << 38) - 1
        let u38Palette: [Int64] = [
            0, 1, 16_777_217, (Int64(1) << 31) + 3, (Int64(1) << 37) + 1, maxU38 - 1, maxU38
        ]
        let u38Samples = (0..<voxelCount).map { u38Palette[$0 % u38Palette.count] }
        let u38Volume = J2KVolume(
            width: width,
            height: height,
            depth: depth,
            components: [
                J2KVolumeComponent(
                    index: 0,
                    bitDepth: 38,
                    signed: false,
                    width: width,
                    height: height,
                    depth: depth,
                    data: packLittleEndianSamples(u38Samples, bitDepth: 38, signed: false)
                )
            ]
        )
        let encodedU38 = try await encoder.encode(u38Volume)
        let decodedU38 = try await decoder.decode(encodedU38.data)
        let roundTripU38 = unpackLittleEndianSamples(
            decodedU38.volume.components[0].data,
            voxelCount: voxelCount,
            bitDepth: 38,
            signed: false
        )
        #expect(roundTripU38 == u38Samples)

        let minS38: Int64 = -(Int64(1) << 37)
        let maxS38: Int64 = (Int64(1) << 37) - 1
        let s38Palette: [Int64] = [
            minS38, minS38 + 1, -16_777_217, -1, 0, 1, 16_777_217, maxS38 - 1, maxS38
        ]
        let s38Samples = (0..<voxelCount).map { s38Palette[$0 % s38Palette.count] }
        let s38Volume = J2KVolume(
            width: width,
            height: height,
            depth: depth,
            components: [
                J2KVolumeComponent(
                    index: 0,
                    bitDepth: 38,
                    signed: true,
                    width: width,
                    height: height,
                    depth: depth,
                    data: packLittleEndianSamples(s38Samples, bitDepth: 38, signed: true)
                )
            ]
        )
        let encodedS38 = try await encoder.encode(s38Volume)
        let decodedS38 = try await decoder.decode(encodedS38.data)
        let roundTripS38 = unpackLittleEndianSamples(
            decodedS38.volume.components[0].data,
            voxelCount: voxelCount,
            bitDepth: 38,
            signed: true
        )
        #expect(roundTripS38 == s38Samples)
    }

    @Test("R1-CODE-01: adversarial Int64.max lifting coefficients throw malformedInput cleanly without arithmetic trap")
    func adversarialInt64MaxCoefficientsThrowWithoutTrapping() async throws {
        // 1. Direct inverseLosslessInt64 lifting overflow check
        #expect(throws: J2KError.self) {
            _ = try JP3DWaveletTransform.inverseLosslessInt64(
                coefficients: [0, Int64.max],
                width: 2,
                height: 1,
                depth: 1,
                levelsX: 1,
                levelsY: 0,
                levelsZ: 0
            )
        }

        // 2. Crafted J3DI 2x1x1 Int64 tile payload decoded through public VolumeDecoder.decode
        var j3diTile = Data([0x4A, 0x33, 0x44, 0x49]) // "J3DI"
        j3diTile.append(1)                            // version = 1
        j3diTile.append(0x01)                         // flags: usesInt64 = true
        j3diTile.append(contentsOf: [0x00, 0x01])     // compCount = 1
        j3diTile.append(contentsOf: [0, 0, 0, 2])     // tileW = 2
        j3diTile.append(contentsOf: [0, 0, 0, 1])     // tileH = 1
        j3diTile.append(contentsOf: [0, 0, 0, 1])     // tileD = 1
        j3diTile.append(contentsOf: [1, 0, 0])        // levelsX=1, levelsY=0, levelsZ=0
        j3diTile.append(32)                           // bitDepth = 32
        j3diTile.append(0)                            // signed = false
        for coeff: Int64 in [0, Int64.max] {
            let word = UInt64(bitPattern: coeff)
            for shift in stride(from: 56, through: 0, by: -8) {
                j3diTile.append(UInt8(truncatingIfNeeded: word >> shift))
            }
        }
        let adversarialCodestream = JP3DCodestreamBuilder().build(
            tileData: [j3diTile],
            width: 2,
            height: 1,
            depth: 1,
            components: 1,
            bitDepth: 32,
            signed: false,
            levelsX: 1,
            levelsY: 0,
            levelsZ: 0,
            tileSizeX: 2,
            tileSizeY: 1,
            tileSizeZ: 1,
            isLossless: true
        )

        do {
            _ = try await VolumeDecoder().decode(adversarialCodestream)
            Issue.record("Expected adversarial Int64.max J3DI codestream to throw CodecError(.malformedInput)")
        } catch let error as CodecError {
            #expect(error.category == .malformedInput)
        }
    }

    @Test("F03: resolutionLevel > 32 throws cleanly across VolumeDecoderConfiguration, JP3DDecoder, and JP3DROIDecoder")
    func oversizedResolutionLevelRejectedWithoutShiftTrap() async throws {
        #expect(throws: CodecError.self) {
            _ = try VolumeDecoderConfiguration(resolutionLevel: 64)
        }
        #expect(throws: CodecError.self) {
            _ = try VolumeDecoderConfiguration(resolutionLevel: -1)
        }

        let vol = J2KVolume(
            width: 8,
            height: 8,
            depth: 2,
            components: [
                J2KVolumeComponent(
                    index: 0,
                    bitDepth: 8,
                    signed: false,
                    width: 8,
                    height: 8,
                    depth: 2,
                    data: Data((0..<(8 * 8 * 2)).map { UInt8($0 & 0xFF) })
                )
            ]
        )
        let encoded = try await VolumeEncoder().encode(vol)

        let badDecoder = JP3DDecoder(configuration: JP3DDecoderConfiguration(resolutionLevel: 64))
        do {
            _ = try await badDecoder.decode(encoded.data)
            Issue.record("Expected JP3DDecoder with resolutionLevel 64 to throw")
        } catch is J2KError {
            // Expected
        }

        let roiDecoder = JP3DROIDecoder()
        do {
            _ = try await roiDecoder.decode(
                encoded.data,
                region: JP3DRegion(x: 0..<4, y: 0..<4, z: 0..<2),
                maxQualityLayers: nil,
                resolutionLevel: 64
            )
            Issue.record("Expected JP3DROIDecoder with resolutionLevel 64 to throw")
        } catch is J2KError {
            // Expected
        }

        // Boundary resolutionLevel == 32 succeeds cleanly (clamped to 1x1xD) without trapping on 1 << 32:
        let boundaryConfig = try VolumeDecoderConfiguration(resolutionLevel: 32)
        let boundaryDecoded = try await VolumeDecoder(configuration: boundaryConfig).decode(encoded.data)
        #expect(boundaryDecoded.volume.width == 1)
        #expect(boundaryDecoded.volume.height == 1)
        #expect(boundaryDecoded.volume.depth == 2)
    }

    @Test("F05 + follow-up residual: simultaneous runtime worker + retained-tile admission, cleanup on failure, bounded-copy inspect, deadlineSeconds, and deterministic maximumWorkers overlap")
    func volumetricResourceLimitsConcurrencyAndPreAllocationAdmission() async throws {
        // 8x4x4 32-bit unsigned volume with 2x2x2 tiling -> 16 tiles of 8 voxels each (>31-bit J3DI path).
        // Alternating [0, UInt32.max] samples force 64-bit J3DI wavelet coefficients (89 B per encoded tile),
        // so runtime retained tile payloads (89 B/tile) grow faster than the 4 B/voxel minimum preflight lower bound (1394 B),
        // letting us deterministically exercise BOTH global preflight denial AND the actual runtime simultaneous
        // 2-worker + retained-output reservation boundary.
        let w = 8, h = 4, d = 4
        let vox = w * h * d
        let highDynamicSamples: [Int64] = (0..<vox).map { ($0 % 2 == 0) ? 0 : Int64(UInt32.max) }
        let vol32 = J2KVolume(
            width: w,
            height: h,
            depth: d,
            components: [
                J2KVolumeComponent(
                    index: 0,
                    bitDepth: 32,
                    signed: false,
                    width: w,
                    height: h,
                    depth: d,
                    data: packLittleEndianSamples(highDynamicSamples, bitDepth: 32, signed: false)
                )
            ]
        )
        let multiTileEncConfig = try VolumeEncoderConfiguration(
            compressionMode: .lossless,
            tiling: JP3DTilingConfiguration(tileSizeX: 2, tileSizeY: 2, tileSizeZ: 2),
            levelsX: 1,
            levelsY: 1,
            levelsZ: 1
        )
        let multiTileEncoder = try VolumeEncoder(configuration: multiTileEncConfig)
        let decoder = try VolumeDecoder()

        // 1. Global preflight denial (512 B < 1394 B preflight floor) before any worker task starts:
        let denyPreflightLimits = try ResourceLimits(
            maximumWorkspaceBytes: 512,
            maximumWorkers: 2
        )
        let denyPreflightRecorder = StorageTelemetry.Recorder()
        let denyPreflightConcurrency = VolumeConcurrencyTelemetry.Recorder()
        do {
            _ = try await StorageTelemetry.$recorder.withValue(denyPreflightRecorder) {
                try await VolumeConcurrencyTelemetry.$recorder.withValue(denyPreflightConcurrency) {
                    try await multiTileEncoder.encode(
                        vol32,
                        options: VolumeEncodeOptions(resourceLimits: denyPreflightLimits)
                    )
                }
            }
            Issue.record("Expected 512 B workspace budget to fail preflight admission")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(denyPreflightConcurrency.totalTasksStarted == 0)
        #expect(!denyPreflightRecorder.parserEvents.map(\.stage).contains("jp3d-j3di-tile-output"))

        // 2. Runtime simultaneous 2-worker + retained-output boundary & full task/reservation cleanup on failure:
        // 1650 B exceeds the 1394 B global preflight floor so concurrent workers start, overlap (peakInFlight == 2),
        // retain earlier 89-byte tiles, and then cross 1650 B when simultaneous transient worker leases + retained tiles collide.
        let runtimeBoundaryLimits = try ResourceLimits(
            maximumWorkspaceBytes: 1650,
            maximumWorkers: 2
        )
        let runtimeFailStorage = StorageTelemetry.Recorder()
        let waveBarriers = (0..<8).map { _ in VolumeConcurrencyTelemetry.RendezvousBarrier(parties: 2) }
        let waveParentGates = (0..<8).map { _ in VolumeConcurrencyTelemetry.PhaseGate() }
        let waveExitCounts = Mutex(Array(repeating: 0, count: 8))
        let runtimeFailConcurrency = VolumeConcurrencyTelemetry.Recorder(
            onWorkerEnter: { tileIdx, _ in
                if let idx = tileIdx, idx / 2 < waveBarriers.count {
                    await waveBarriers[idx / 2].arriveAndWait()
                }
            },
            onWorkerExit: { tileIdx in
                if let idx = tileIdx, idx / 2 < waveParentGates.count {
                    let wave = idx / 2
                    let done = waveExitCounts.withLock { counts -> Int in
                        counts[wave] += 1
                        return counts[wave]
                    }
                    if done >= 2 {
                        waveParentGates[wave].open()
                    }
                }
            },
            onBeforeParentConsume: { step, _ in
                let wave = step / 2
                if step % 2 == 0, wave < waveParentGates.count {
                    await waveParentGates[wave].wait()
                }
            }
        )
        do {
            _ = try await StorageTelemetry.$recorder.withValue(runtimeFailStorage) {
                try await VolumeConcurrencyTelemetry.$recorder.withValue(runtimeFailConcurrency) {
                    try await multiTileEncoder.encode(
                        vol32,
                        options: VolumeEncodeOptions(resourceLimits: runtimeBoundaryLimits)
                    )
                }
            }
            Issue.record("Expected 1650 B workspace budget to fail at runtime simultaneous worker + retained-output boundary")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(runtimeFailConcurrency.totalTasksStarted >= 2)
        #expect(runtimeFailConcurrency.peakInFlight == 2)
        #expect(runtimeFailConcurrency.retainedBytes > 0)
        #expect(runtimeFailStorage.parserEvents.map(\.stage).contains("jp3d-retained-tile"))
        // Verify all concurrent tasks joined and every transient worker lease was released on failure unwind:
        #expect(runtimeFailConcurrency.currentInFlight == 0)
        #expect(runtimeFailConcurrency.liveTransientBytes == 0)

        // 3. Deterministic 2-worker overlap control with sufficient workspace budget (peakInFlight == 2, never serial 1):
        let twoWorkerControlLimits = try ResourceLimits(
            maximumWorkspaceBytes: 8192,
            maximumWorkers: 2
        )
        let encFirstTwo = VolumeConcurrencyTelemetry.RendezvousBarrier(parties: 2)
        let encStarted = Mutex(0)
        let encConcurrency = VolumeConcurrencyTelemetry.Recorder(
            onWorkerEnter: { _, _ in
                let order = encStarted.withLock { c -> Int in
                    let cur = c
                    c += 1
                    return cur
                }
                if order < 2 {
                    await encFirstTwo.arriveAndWait()
                }
            }
        )
        let encoded16 = try await VolumeConcurrencyTelemetry.$recorder.withValue(encConcurrency) {
            try await multiTileEncoder.encode(
                vol32,
                options: VolumeEncodeOptions(resourceLimits: twoWorkerControlLimits)
            )
        }
        #expect(encConcurrency.totalTasksStarted == 16)
        #expect(encConcurrency.peakInFlight == 2)
        #expect(encConcurrency.currentInFlight == 0)
        #expect(encConcurrency.liveTransientBytes == 0)
        #expect(encConcurrency.retainedBytes == 16 * 89)

        let decFirstTwo = VolumeConcurrencyTelemetry.RendezvousBarrier(parties: 2)
        let decStarted = Mutex(0)
        let decConcurrency = VolumeConcurrencyTelemetry.Recorder(
            onWorkerEnter: { _, _ in
                let order = decStarted.withLock { c -> Int in
                    let cur = c
                    c += 1
                    return cur
                }
                if order < 2 {
                    await decFirstTwo.arriveAndWait()
                }
            }
        )
        let decoded16 = try await VolumeConcurrencyTelemetry.$recorder.withValue(decConcurrency) {
            try await decoder.decode(
                encoded16.data,
                options: VolumeDecodeOptions(resourceLimits: ResourceLimits(maximumWorkers: 2))
            )
        }
        #expect(decConcurrency.totalTasksStarted == 16)
        #expect(decConcurrency.peakInFlight == 2)
        #expect(decConcurrency.currentInFlight == 0)
        #expect(decoded16.volume.components[0].data == vol32.components[0].data)

        // 4. Bounded-copy VolumeDecoder.inspect contract vs full-payload decode copy:
        // Build a 16x16x4 32-bit 4-tile codestream (each tile = 8x8x4 = 256 voxels -> >= 1049 B per tile payload,
        // > 4400 B for full tile copies, whereas inspect retains only min(dataLength, 32) + recordOverhead per tile).
        let bigTileSamples = (0..<(16 * 16 * 4)).map { Int64(($0 * 4099) & 0x7FFF_FFFF) }
        let vol4LargeTiles = J2KVolume(
            width: 16,
            height: 16,
            depth: 4,
            components: [
                J2KVolumeComponent(
                    index: 0,
                    bitDepth: 32,
                    signed: false,
                    width: 16,
                    height: 16,
                    depth: 4,
                    data: packLittleEndianSamples(bigTileSamples, bitDepth: 32, signed: false)
                )
            ]
        )
        let encoded4Large = try await VolumeEncoder(
            configuration: try VolumeEncoderConfiguration(
                compressionMode: .lossless,
                tiling: JP3DTilingConfiguration(tileSizeX: 8, tileSizeY: 8, tileSizeZ: 4),
                levelsX: 1,
                levelsY: 1,
                levelsZ: 1
            )
        ).encode(vol4LargeTiles)

        let inspectEntryBytes = 32 + 32 + MemoryLayout<JP3DParsedTile>.stride
        let totalInspectBytes = 4 * inspectEntryBytes

        // 4a. 1 byte below first bounded prefix -> rejected before 1st allocation (0 events):
        let denyFirstPrefixRec = StorageTelemetry.Recorder()
        do {
            _ = try StorageTelemetry.$recorder.withValue(denyFirstPrefixRec) {
                try decoder.inspect(
                    encoded4Large.data,
                    options: VolumeDecodeOptions(resourceLimits: try ResourceLimits(maximumWorkspaceBytes: inspectEntryBytes - 1))
                )
            }
            Issue.record("Expected inspect to reject before 1st bounded tile prefix under \(inspectEntryBytes - 1) B")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(denyFirstPrefixRec.parserEvents.filter { $0.stage == "jp3d-tile-subdata" }.isEmpty)

        // 4b. 1 byte below 4th bounded prefix -> admits 3 prefixes, rejects before the 4th crossing allocation:
        let denyFourthPrefixRec = StorageTelemetry.Recorder()
        do {
            _ = try StorageTelemetry.$recorder.withValue(denyFourthPrefixRec) {
                try decoder.inspect(
                    encoded4Large.data,
                    options: VolumeDecodeOptions(resourceLimits: try ResourceLimits(maximumWorkspaceBytes: totalInspectBytes - 1))
                )
            }
            Issue.record("Expected inspect to reject before 4th bounded tile prefix under \(totalInspectBytes - 1) B")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        let threePrefixEvents = denyFourthPrefixRec.parserEvents.filter { $0.stage == "jp3d-tile-subdata" }
        #expect(threePrefixEvents.count == 3)
        #expect(threePrefixEvents.allSatisfy { $0.bytes == inspectEntryBytes })

        // 4c. Exact bounded-prefix budget (totalInspectBytes = 352 B, >12x smaller than full 4-tile payload copies)
        // SUCCEEDS for inspect, while full-payload decode/parse REJECTS before the 1st >1 KiB full tile copy:
        let exactInspectLimits = try ResourceLimits(maximumWorkspaceBytes: totalInspectBytes)
        let exactInspectRec = StorageTelemetry.Recorder()
        let info = try StorageTelemetry.$recorder.withValue(exactInspectRec) {
            try decoder.inspect(encoded4Large.data, options: VolumeDecodeOptions(resourceLimits: exactInspectLimits))
        }
        #expect(info.width == 16 && info.height == 16 && info.depth == 4 && info.tileCount == 4)
        let fourPrefixEvents = exactInspectRec.parserEvents.filter { $0.stage == "jp3d-tile-subdata" }
        #expect(fourPrefixEvents.count == 4)
        #expect(fourPrefixEvents.reduce(0) { $0 + $1.bytes } == totalInspectBytes)

        let denyFullPayloadRec = StorageTelemetry.Recorder()
        do {
            _ = try StorageTelemetry.$recorder.withValue(denyFullPayloadRec) {
                try JP3DCodestreamParser().parse(
                    encoded4Large.data,
                    limits: exactInspectLimits,
                    copyTilePayloads: true
                )
            }
            Issue.record("Expected full-payload parse to reject >1 KiB tile subdata copy under \(totalInspectBytes) B budget")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(denyFullPayloadRec.parserEvents.filter { $0.stage == "jp3d-tile-subdata" }.isEmpty)

        // 5. deadlineSeconds enforcement on multi-tile encode:
        let bigRaw = Data((0..<(16 * 16 * 8)).map { UInt8($0 & 0xFF) })
        let bigVol = J2KVolume(
            width: 16,
            height: 16,
            depth: 8,
            components: [
                J2KVolumeComponent(index: 0, bitDepth: 8, signed: false, width: 16, height: 16, depth: 8, data: bigRaw)
            ]
        )
        let bigEncoder = try VolumeEncoder(
            configuration: try VolumeEncoderConfiguration(
                compressionMode: .lossless,
                tiling: JP3DTilingConfiguration(tileSizeX: 4, tileSizeY: 4, tileSizeZ: 2)
            )
        )
        let tinyDeadline = try ResourceLimits(deadlineSeconds: 1e-9)
        do {
            _ = try await bigEncoder.encode(
                bigVol,
                options: VolumeEncodeOptions(resourceLimits: tinyDeadline)
            )
            Issue.record("Expected 1 ns deadlineSeconds to abort multi-tile VolumeEncoder.encode")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
    }

    @Test("F06: OperationReport.fidelity is .lossy for partial/corrupt 3D decodes, reduced resolution/layers, and lossy codestreams")
    func volumetricFidelityTruthfulness() async throws {
        var raw = Data(count: 8 * 4 * 2)
        for i in 0..<raw.count { raw[i] = UInt8((i * 19 + 3) & 0xFF) }
        let vol = J2KVolume(
            width: 8,
            height: 4,
            depth: 2,
            components: [
                J2KVolumeComponent(index: 0, bitDepth: 8, signed: false, width: 8, height: 4, depth: 2, data: raw)
            ]
        )

        let losslessEnc = try await VolumeEncoder(
            configuration: try VolumeEncoderConfiguration(
                compressionMode: .lossless,
                tiling: JP3DTilingConfiguration(tileSizeX: 4, tileSizeY: 4, tileSizeZ: 2),
                qualityLayers: 2,
                levelsX: 1,
                levelsY: 1,
                levelsZ: 1
            )
        ).encode(vol)
        #expect(losslessEnc.report.fidelity == .exactSamples)

        // Full lossless decode -> .exactSamples
        let fullDec = try await VolumeDecoder().decode(losslessEnc.data)
        #expect(!fullDec.isPartial)
        #expect(fullDec.report.fidelity == .exactSamples)

        // Reduced resolution decode -> .lossy
        let res1Dec = try await VolumeDecoder(
            configuration: try VolumeDecoderConfiguration(resolutionLevel: 1)
        ).decode(losslessEnc.data)
        #expect(res1Dec.report.fidelity == .lossy)

        // Reduced quality layers -> .lossy
        let q1Dec = try await VolumeDecoder(
            configuration: try VolumeDecoderConfiguration(maxQualityLayers: 1)
        ).decode(losslessEnc.data)
        #expect(q1Dec.report.fidelity == .lossy)

        // Corrupt the second tile payload inside the codestream:
        let parsed = try JP3DCodestreamParser().parse(losslessEnc.data)
        #expect(parsed.tiles.count == 2)
        let brokenSecondTile = Data([0x00, 0xFF, 0x00, 0x13, 0x37])
        let corruptedStream = JP3DCodestreamBuilder().build(
            tileData: [parsed.tiles[0].data, brokenSecondTile],
            width: parsed.siz.width,
            height: parsed.siz.height,
            depth: parsed.siz.depth,
            components: parsed.siz.componentCount,
            bitDepth: parsed.siz.bitDepth,
            signed: parsed.siz.signed,
            levelsX: parsed.cod.levelsX,
            levelsY: parsed.cod.levelsY,
            levelsZ: parsed.cod.levelsZ,
            tileSizeX: parsed.siz.tileSizeX,
            tileSizeY: parsed.siz.tileSizeY,
            tileSizeZ: parsed.siz.tileSizeZ,
            isLossless: true
        )

        // Strict decode rejects corrupted tile:
        do {
            _ = try await VolumeDecoder(
                configuration: try VolumeDecoderConfiguration(tolerateTruncation: false)
            ).decode(corruptedStream)
            Issue.record("Expected strict VolumeDecoder to reject corrupted tile payload")
        } catch let error as CodecError {
            #expect(error.category == .malformedInput)
        }

        // Tolerant decode succeeds partially and MUST report .lossy (never .exactSamples):
        let partialDec = try await VolumeDecoder(
            configuration: try VolumeDecoderConfiguration(tolerateTruncation: true)
        ).decode(corruptedStream)
        #expect(partialDec.isPartial)
        #expect(partialDec.report.fidelity == .lossy)

        // Lossy compression mode reports .lossy on both encode and decode:
        let lossyEnc = try await VolumeEncoder(
            configuration: try VolumeEncoderConfiguration(compressionMode: .lossy(psnr: 35.0))
        ).encode(vol)
        #expect(lossyEnc.report.fidelity == .lossy)
        let lossyDec = try await VolumeDecoder().decode(lossyEnc.data)
        #expect(lossyDec.report.fidelity == .lossy)
    }

    @Test("F13: cancellation inside .completed progress callback aborts VolumeEncoder, VolumeDecoder, and VolumeTranscoder")
    func postCompletedProgressCancellationAbortsVolumeOperations() async throws {
        var raw = Data(count: 4 * 4 * 2)
        for i in 0..<raw.count { raw[i] = UInt8(i * 7) }
        let vol = J2KVolume(
            width: 4,
            height: 4,
            depth: 2,
            components: [
                J2KVolumeComponent(index: 0, bitDepth: 8, signed: false, width: 4, height: 4, depth: 2, data: raw)
            ]
        )
        let encoder = try VolumeEncoder()
        let decoder = try VolumeDecoder()
        let transcoder = try VolumeTranscoder()
        let baseline = try await encoder.encode(vol)

        let encTask = Task {
            try await encoder.encode(
                vol,
                options: VolumeEncodeOptions(progress: { update in
                    if update.phase == .completed {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
            )
        }
        await #expect(throws: CancellationError.self) {
            _ = try await encTask.value
        }

        let decTask = Task {
            try await decoder.decode(
                baseline.data,
                options: VolumeDecodeOptions(progress: { update in
                    if update.phase == .completed {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
            )
        }
        await #expect(throws: CancellationError.self) {
            _ = try await decTask.value
        }

        let transTask = Task {
            try await transcoder.transcode(
                baseline.data,
                to: .htj2k,
                options: TranscodeOptions(progress: { update in
                    if update.phase == .completed {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                })
            )
        }
        await #expect(throws: CancellationError.self) {
            _ = try await transTask.value
        }
    }

    @Test("F05 rework: completed unconsumed child tile outputs retain reservation until parent collection across J3DI, J3DS slice-stack, and lossy 3D paths")
    func childTileOutputReservationTransferAndDelayedParentConsumption() async throws {
        // --- 1. 3-tile 32-bit J3DI (6x2x2 with 2x2x2 tiling -> 3 tiles of 89 B each) ---
        // Workers 0 and 1 finish their `encodeTileStatic` bodies (releasing worker scratch while keeping their 89 B
        // `OutputReservation`s alive in the returned `JP3DEncodedTileOutput` values) and open `tiles0And1Exited` while
        // the parent waits on `tile2Exited` before calling `group.next()`. Note that `onWorkerExit` / `onChildTaskReturned`
        // fire inside the child task before Swift's runtime enqueues the result into `ThrowingTaskGroup`, so task-group
        // result queue order relative to a sibling error is never assumed without a parent-consumption synchronization point.
        let samples24: [Int64] = (0..<24).map { ($0 % 2 == 0) ? 0 : Int64(UInt32.max) }
        let vol3TilesJ3DI = J2KVolume(
            width: 6,
            height: 2,
            depth: 2,
            components: [
                J2KVolumeComponent(
                    index: 0,
                    bitDepth: 32,
                    signed: false,
                    width: 6,
                    height: 2,
                    depth: 2,
                    data: packLittleEndianSamples(samples24, bitDepth: 32, signed: false)
                )
            ]
        )
        let j3diEncoder = try VolumeEncoder(
            configuration: try VolumeEncoderConfiguration(
                compressionMode: .lossless,
                tiling: JP3DTilingConfiguration(tileSizeX: 2, tileSizeY: 2, tileSizeZ: 2),
                levelsX: 1,
                levelsY: 1,
                levelsZ: 1
            )
        )

        // 1a. maximumCompressedBytes = 220 (> 171 B preflight floor; admits 2 * 89 = 178 B unconsumed child outputs,
        // then rejects Worker 2's 89 B at 267 > 220 BEFORE parent consumes anything from group.next()).
        // Explicit phase barriers (zero timing sleeps):
        //   - Workers 0 & 1 finish `encodeTileStatic` and open `tiles0And1Exited` in `onWorkerExit`.
        //   - Worker 2 waits on `tiles0And1Exited` in `onWorkerEnter`, captures `snapTile2`, attempts its 89 B output
        //     reservation (denied pre-allocation at 267 > 220), and opens `tile2Exited` in `onWorkerExit`.
        //   - Parent waits on `tile2Exited` in `onBeforeParentConsume(step: 0)` and captures `preConsumeSnap` before
        //     making its first `group.next()` call.
        let tiles0And1Exited = VolumeConcurrencyTelemetry.PhaseGate()
        let tile2Exited = VolumeConcurrencyTelemetry.PhaseGate()
        let firstTwoExitCount = Mutex(0)
        let preConsumeSnap1a = Mutex<VolumeConcurrencyTelemetry.Snapshot?>(nil)
        let denyQueuedCompressedRec = VolumeConcurrencyTelemetry.Recorder(
            onWorkerEnter: { tileIdx, _ in
                if tileIdx == 2 {
                    await tiles0And1Exited.wait()
                }
            },
            onWorkerExit: { tileIdx in
                if tileIdx == 0 || tileIdx == 1 {
                    let done = firstTwoExitCount.withLock { c -> Int in
                        c += 1
                        return c
                    }
                    if done >= 2 {
                        tiles0And1Exited.open()
                    }
                } else if tileIdx == 2 {
                    tile2Exited.open()
                }
            },
            onBeforeParentConsume: { step, rec in
                if step == 0 {
                    await tile2Exited.wait()
                    preConsumeSnap1a.withLock { $0 = rec.currentSnapshot() }
                }
            }
        )
        let denyQueuedStorageRec = StorageTelemetry.Recorder()
        do {
            _ = try await StorageTelemetry.$recorder.withValue(denyQueuedStorageRec) {
                try await VolumeConcurrencyTelemetry.$recorder.withValue(denyQueuedCompressedRec) {
                    try await j3diEncoder.encode(
                        vol3TilesJ3DI,
                        options: VolumeEncodeOptions(
                            resourceLimits: try ResourceLimits(
                                maximumCompressedBytes: 220,
                                maximumWorkers: 3
                            )
                        )
                    )
                }
            }
            Issue.record("Expected 2 unconsumed 89 B child outputs + Worker 2's 89 B output (267 B) to fail 220 B compressed limit before parent consumption")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        // Snapshot inside Worker 2 right after `tiles0And1Exited.wait()` AND `preConsumeSnap` right before step-0
        // `group.next()` both prove parent had consumed 0 tiles (`retainedBytes == 0`) while BOTH completed child Data
        // outputs remained actively charged in `liveOutputBytes` (`2 * 89 = 178 B`):
        let snapTile2 = try #require(denyQueuedCompressedRec.snapshotAfterEnterDelay(forTile: 2))
        #expect(snapTile2.currentInFlight == 1)
        #expect(snapTile2.retainedBytes == 0)
        #expect(snapTile2.liveOutputBytes == 2 * 89)
        #expect(snapTile2.liveTransientBytes == 2 * 89)
        let preParentSnap = try #require(preConsumeSnap1a.withLock { $0 })
        #expect(preParentSnap.currentInFlight == 0)
        #expect(preParentSnap.retainedBytes == 0)
        #expect(preParentSnap.liveOutputBytes == 2 * 89)
        #expect(preParentSnap.liveScratchBytes == 0)
        let admittedTileOutputs = denyQueuedStorageRec.parserEvents.filter { $0.stage == "jp3d-j3di-tile-output" }
        #expect(admittedTileOutputs.count == 2)
        #expect(admittedTileOutputs.allSatisfy { $0.bytes == 89 })
        // Queue-order-independent conservation-of-bytes invariant:
        // Depending on Swift Concurrency's internal `ThrowingTaskGroup` completion-queue ordering relative to Worker 2's
        // error, `group.next()` pops `k` (`0...2`) completed 89 B tiles (promoting `k * 89 B` to `retainedBytes`) before
        // rethrowing `.resourceLimitExceeded`, while the remaining `(2 - k)` unpopped child outputs are released
        // (`(2 - k) * 89 B`) via `OutputReservation.deinit` during task-group unwind:
        let promotedTileEvents = denyQueuedStorageRec.parserEvents.filter { $0.stage == "jp3d-retained-tile" }
        #expect((0...2).contains(promotedTileEvents.count))
        #expect(promotedTileEvents.allSatisfy { $0.bytes == 89 })
        #expect(denyQueuedCompressedRec.retainedBytes == promotedTileEvents.count * 89)
        #expect(denyQueuedCompressedRec.releasedOutputBytes == (2 - promotedTileEvents.count) * 89)
        #expect(denyQueuedCompressedRec.retainedBytes + denyQueuedCompressedRec.releasedOutputBytes == 2 * 89)
        #expect(denyQueuedCompressedRec.currentInFlight == 0)
        #expect(denyQueuedCompressedRec.liveOutputBytes == 0)
        #expect(denyQueuedCompressedRec.liveScratchBytes == 0)
        #expect(denyQueuedCompressedRec.liveTransientBytes == 0)
        #expect(denyQueuedCompressedRec.authoritativeLiveOutputBytes == 0)
        #expect(denyQueuedCompressedRec.authoritativeLiveScratchBytes == 0)
        #expect(denyQueuedCompressedRec.authoritativeLiveTransientBytes == 0)
        #expect(denyQueuedCompressedRec.authoritativeRetainedBytes == promotedTileEvents.count * 89)
        #expect(denyQueuedCompressedRec.authoritativeReleasedOutputBytes == (2 - promotedTileEvents.count) * 89)

        // 1a-sync. Parent-consumption-synchronized promotion proof (`maximumWorkers: 2`, `maximumCompressedBytes: 220`):
        // With `maximumWorkers: 2`, Worker 2 is spawned only after `group.next()` consumes the 1st tile, and waits on
        // `bothTilesPromoted` opened inside `onBeforeParentConsume(step: 2)` AFTER the parent loop has actually consumed
        // and promoted BOTH initial tiles (`retainedBytes == 2 * 89`, `liveOutputBytes == 0`), establishing exact 2
        // promotions via an actual parent-side synchronization point before Worker 2 fails at `178 + 89 = 267 > 220`:
        let bothTilesPromoted = VolumeConcurrencyTelemetry.PhaseGate()
        let syncPromotedRec = VolumeConcurrencyTelemetry.Recorder(
            onWorkerEnter: { tileIdx, _ in
                if tileIdx == 2 {
                    await bothTilesPromoted.wait()
                }
            },
            onBeforeParentConsume: { step, _ in
                if step == 2 {
                    bothTilesPromoted.open()
                }
            }
        )
        let syncPromotedStorage = StorageTelemetry.Recorder()
        do {
            _ = try await StorageTelemetry.$recorder.withValue(syncPromotedStorage) {
                try await VolumeConcurrencyTelemetry.$recorder.withValue(syncPromotedRec) {
                    try await j3diEncoder.encode(
                        vol3TilesJ3DI,
                        options: VolumeEncodeOptions(
                            resourceLimits: try ResourceLimits(
                                maximumCompressedBytes: 220,
                                maximumWorkers: 2
                            )
                        )
                    )
                }
            }
            Issue.record("Expected Worker 2's 89 B output after 2 synchronized 89 B promotions (267 B) to fail 220 B limit")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        let syncSnapTile2 = try #require(syncPromotedRec.snapshotAfterEnterDelay(forTile: 2))
        #expect(syncSnapTile2.retainedBytes == 2 * 89)
        #expect(syncSnapTile2.liveOutputBytes == 0)
        #expect(syncPromotedStorage.parserEvents.filter { $0.stage == "jp3d-j3di-tile-output" }.count == 2)
        #expect(syncPromotedStorage.parserEvents.filter { $0.stage == "jp3d-retained-tile" }.count == 2)
        #expect(syncPromotedRec.retainedBytes == 2 * 89)
        #expect(syncPromotedRec.releasedOutputBytes == 0)
        #expect(syncPromotedRec.liveOutputBytes == 0)
        #expect(syncPromotedRec.liveScratchBytes == 0)
        #expect(syncPromotedRec.authoritativeLiveOutputBytes == 0)
        #expect(syncPromotedRec.authoritativeLiveScratchBytes == 0)
        #expect(syncPromotedRec.authoritativeRetainedBytes == 2 * 89)
        #expect(syncPromotedRec.authoritativeReleasedOutputBytes == 0)

        // 1b. Unconsumed-result deinit path (deterministic barrier + task cancellation, zero timing sleeps):
        // All 3 worker child closures finish executing (`allThreeReturned` barrier, holding 3 * 89 = 267 B in
        // `liveOutputBytes` with `retainedBytes == 0`), then parent cancels the child Task inside
        // `onBeforeParentConsume(step: 0)` so the first iteration throws `CancellationError` at `work.check()` before
        // any tile is promoted to retained (`"jp3d-retained-tile"` count == 0), releasing the 1st popped reservation in
        // `catch` and leaving the remaining 2 unconsumed child results to clean up via `OutputReservation.deinit`:
        let allThreeReturned = VolumeConcurrencyTelemetry.PhaseGate()
        let returnedCount = Mutex(0)
        let preCancelSnap = Mutex<VolumeConcurrencyTelemetry.Snapshot?>(nil)
        let unconsumedDeinitRec = VolumeConcurrencyTelemetry.Recorder(
            onChildTaskReturned: { _ in
                let done = returnedCount.withLock { c -> Int in
                    c += 1
                    return c
                }
                if done >= 3 {
                    allThreeReturned.open()
                }
            },
            onBeforeParentConsume: { step, rec in
                if step == 0 {
                    await allThreeReturned.wait()
                    preCancelSnap.withLock { $0 = rec.currentSnapshot() }
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        )
        let unconsumedDeinitStorageRec = StorageTelemetry.Recorder()
        let cancelChild = Task {
            try await StorageTelemetry.$recorder.withValue(unconsumedDeinitStorageRec) {
                try await VolumeConcurrencyTelemetry.$recorder.withValue(unconsumedDeinitRec) {
                    try await j3diEncoder.encode(
                        vol3TilesJ3DI,
                        options: VolumeEncodeOptions(
                            resourceLimits: try ResourceLimits(maximumWorkers: 3)
                        )
                    )
                }
            }
        }
        await #expect(throws: CancellationError.self) {
            _ = try await cancelChild.value
        }
        let queuedAll3Snap = try #require(preCancelSnap.withLock { $0 })
        #expect(queuedAll3Snap.currentInFlight == 0)
        #expect(queuedAll3Snap.retainedBytes == 0)
        #expect(queuedAll3Snap.liveOutputBytes == 3 * 89)
        #expect(unconsumedDeinitStorageRec.parserEvents.filter { $0.stage == "jp3d-j3di-tile-output" }.count == 3)
        #expect(unconsumedDeinitStorageRec.parserEvents.filter { $0.stage == "jp3d-retained-tile" }.isEmpty)
        #expect(unconsumedDeinitRec.retainedBytes == 0)
        #expect(unconsumedDeinitRec.releasedOutputBytes == 3 * 89)
        #expect(unconsumedDeinitRec.currentInFlight == 0)
        #expect(unconsumedDeinitRec.liveOutputBytes == 0)
        #expect(unconsumedDeinitRec.liveScratchBytes == 0)
        #expect(unconsumedDeinitRec.liveTransientBytes == 0)
        #expect(unconsumedDeinitRec.authoritativeLiveOutputBytes == 0)
        #expect(unconsumedDeinitRec.authoritativeLiveScratchBytes == 0)
        #expect(unconsumedDeinitRec.authoritativeRetainedBytes == 0)
        #expect(unconsumedDeinitRec.authoritativeReleasedOutputBytes == 3 * 89)

        // --- 2. maximumWorkspaceBytes boundary on 10-tile 32-bit J3DI (20x2x2, 2x2x2 tiling -> 10 tiles, maximumWorkers = 2) ---
        // Preflight floor = 2 * 473 + 64 * 4 = 1202 B.
        // Explicit per-tile exit barriers (zero timing sleeps):
        //   - Odd tile `2k + 1` waits on `tileExited[2k]` before entering, avoiding dual-scratch overlap in Waves 0..3.
        //   - At even consume step `2k`, parent waits on `tileExited[2k + 1]` and then consumes both `2k` and `2k + 1`.
        //   - In Wave 4 (`retainedBytes == 8 * 89 = 712 B`), Tile 8 completes (`1185 <= 1230 B`) and sits unconsumed
        //     (`89 B`) while parent waits on `tileExited[9]`; Tile 9 wakes after `tileExited[8]`:
        //       * Without unconsumed-output reservation transfer: 712 + 473 = 1185 <= 1230 B (would pass!).
        //       * With unconsumed-output reservation transfer: 712 + 89 + 473 = 1274 > 1230 B (denied before Tile 9 output!).
        let samples80: [Int64] = (0..<80).map { ($0 % 2 == 0) ? 0 : Int64(UInt32.max) }
        let vol10TilesJ3DI = J2KVolume(
            width: 20,
            height: 2,
            depth: 2,
            components: [
                J2KVolumeComponent(
                    index: 0,
                    bitDepth: 32,
                    signed: false,
                    width: 20,
                    height: 2,
                    depth: 2,
                    data: packLittleEndianSamples(samples80, bitDepth: 32, signed: false)
                )
            ]
        )
        func makeTenTileWaveRecorder() -> VolumeConcurrencyTelemetry.Recorder {
            let tileExited = (0..<10).map { _ in VolumeConcurrencyTelemetry.PhaseGate() }
            return VolumeConcurrencyTelemetry.Recorder(
                onWorkerEnter: { tileIdx, _ in
                    if let idx = tileIdx, idx % 2 == 1, idx - 1 < tileExited.count {
                        await tileExited[idx - 1].wait()
                    }
                },
                onWorkerExit: { tileIdx in
                    if let idx = tileIdx, idx < tileExited.count {
                        tileExited[idx].open()
                    }
                },
                onBeforeParentConsume: { step, _ in
                    if step % 2 == 0, step + 1 < tileExited.count {
                        await tileExited[step + 1].wait()
                    }
                }
            )
        }

        let denyQueuedWSRec = makeTenTileWaveRecorder()
        do {
            _ = try await VolumeConcurrencyTelemetry.$recorder.withValue(denyQueuedWSRec) {
                try await j3diEncoder.encode(
                    vol10TilesJ3DI,
                    options: VolumeEncodeOptions(
                        resourceLimits: try ResourceLimits(
                            maximumWorkspaceBytes: 1230,
                            maximumWorkers: 2
                        )
                    )
                )
            }
            Issue.record("Expected 712 B retained + 89 B unconsumed Tile 8 + 473 B active Tile 9 (1274 B) to fail 1230 B workspace")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        let snapTile9 = try #require(denyQueuedWSRec.snapshotAfterEnterDelay(forTile: 9))
        #expect(snapTile9.currentInFlight == 1)
        #expect(snapTile9.retainedBytes == 8 * 89)
        #expect(snapTile9.liveOutputBytes == 89)
        #expect(denyQueuedWSRec.retainedBytes + denyQueuedWSRec.releasedOutputBytes == 9 * 89)
        #expect(denyQueuedWSRec.currentInFlight == 0)
        #expect(denyQueuedWSRec.liveOutputBytes == 0)
        #expect(denyQueuedWSRec.liveScratchBytes == 0)
        #expect(denyQueuedWSRec.liveTransientBytes == 0)
        #expect(denyQueuedWSRec.authoritativeLiveOutputBytes == 0)
        #expect(denyQueuedWSRec.authoritativeLiveScratchBytes == 0)
        #expect((denyQueuedWSRec.authoritativeRetainedBytes ?? 0) + (denyQueuedWSRec.authoritativeReleasedOutputBytes ?? 0) == 9 * 89)

        // Larger-budget control (4096 B) with the exact same barrier schedule succeeds cleanly:
        let passQueuedWSRec = makeTenTileWaveRecorder()
        let encoded10 = try await VolumeConcurrencyTelemetry.$recorder.withValue(passQueuedWSRec) {
            try await j3diEncoder.encode(
                vol10TilesJ3DI,
                options: VolumeEncodeOptions(
                    resourceLimits: try ResourceLimits(
                        maximumWorkspaceBytes: 4096,
                        maximumWorkers: 2
                    )
                )
            )
        }
        #expect(passQueuedWSRec.retainedBytes == 10 * 89)
        #expect(passQueuedWSRec.liveOutputBytes == 0)
        #expect(passQueuedWSRec.liveTransientBytes == 0)
        let decoded10 = try await VolumeDecoder().decode(encoded10.data)
        #expect(decoded10.volume.components[0].data == vol10TilesJ3DI.components[0].data)

        // --- 3. Equivalent J3DS slice-stack (12x4x2 16-bit lossless, 4x4x2 tiling -> 3 tiles)
        //     and lossy 3D wavelet (6x2x2 8-bit lossy, 2x2x2 tiling -> 3 tiles) reservation transfer via explicit barriers ---
        func makeThreeTileQueuedRecorder() -> VolumeConcurrencyTelemetry.Recorder {
            let firstTwoDone = VolumeConcurrencyTelemetry.PhaseGate()
            let thirdDone = VolumeConcurrencyTelemetry.PhaseGate()
            let count = Mutex(0)
            return VolumeConcurrencyTelemetry.Recorder(
                onWorkerEnter: { tileIdx, _ in
                    if tileIdx == 2 {
                        await firstTwoDone.wait()
                    }
                },
                onWorkerExit: { tileIdx in
                    if tileIdx == 0 || tileIdx == 1 {
                        let done = count.withLock { c -> Int in
                            c += 1
                            return c
                        }
                        if done >= 2 {
                            firstTwoDone.open()
                        }
                    } else if tileIdx == 2 {
                        thirdDone.open()
                    }
                },
                onBeforeParentConsume: { step, _ in
                    if step == 0 {
                        await thirdDone.wait()
                    }
                }
            )
        }

        let j3dsVoxelCount = 96
        let j3dsSamples: [Int64] = (0..<j3dsVoxelCount).map { (idx: Int) -> Int64 in
            let v = (idx * 257 + 19) & 0xFFFF
            return Int64(v)
        }
        let vol3TilesJ3DS = J2KVolume(
            width: 12,
            height: 4,
            depth: 2,
            components: [
                J2KVolumeComponent(
                    index: 0,
                    bitDepth: 16,
                    signed: false,
                    width: 12,
                    height: 4,
                    depth: 2,
                    data: packLittleEndianSamples(j3dsSamples, bitDepth: 16, signed: false)
                )
            ]
        )
        let j3dsEncoder = try VolumeEncoder(
            configuration: try VolumeEncoderConfiguration(
                compressionMode: .lossless,
                tiling: JP3DTilingConfiguration(tileSizeX: 4, tileSizeY: 4, tileSizeZ: 2),
                levelsX: 1,
                levelsY: 1,
                levelsZ: 1
            )
        )
        let j3dsRec = makeThreeTileQueuedRecorder()
        let encodedJ3DS = try await VolumeConcurrencyTelemetry.$recorder.withValue(j3dsRec) {
            try await j3dsEncoder.encode(
                vol3TilesJ3DS,
                options: VolumeEncodeOptions(resourceLimits: ResourceLimits(maximumWorkers: 3))
            )
        }
        #expect(!encodedJ3DS.data.isEmpty)
        let j3dsSnap2 = try #require(j3dsRec.snapshotAfterEnterDelay(forTile: 2))
        #expect(j3dsSnap2.currentInFlight == 1)
        #expect(j3dsSnap2.retainedBytes == 0)
        #expect(j3dsSnap2.liveOutputBytes > 0)
        #expect(j3dsRec.retainedBytes > j3dsSnap2.liveOutputBytes)
        #expect(j3dsRec.liveOutputBytes == 0)
        #expect(j3dsRec.liveTransientBytes == 0)

        let lossyRawBytes: [UInt8] = (0..<24).map { (idx: Int) -> UInt8 in
            UInt8((idx * 29 + 7) & 0xFF)
        }
        let lossy3DVol = J2KVolume(
            width: 6,
            height: 2,
            depth: 2,
            components: [
                J2KVolumeComponent(
                    index: 0,
                    bitDepth: 8,
                    signed: false,
                    width: 6,
                    height: 2,
                    depth: 2,
                    data: Data(lossyRawBytes)
                )
            ]
        )
        let lossy3DEncoder = try VolumeEncoder(
            configuration: try VolumeEncoderConfiguration(
                compressionMode: .lossy(psnr: 35.0),
                tiling: JP3DTilingConfiguration(tileSizeX: 2, tileSizeY: 2, tileSizeZ: 2),
                levelsX: 1,
                levelsY: 1,
                levelsZ: 1
            )
        )
        let lossyRec = makeThreeTileQueuedRecorder()
        let encodedLossy3D = try await VolumeConcurrencyTelemetry.$recorder.withValue(lossyRec) {
            try await lossy3DEncoder.encode(
                lossy3DVol,
                options: VolumeEncodeOptions(resourceLimits: ResourceLimits(maximumWorkers: 3))
            )
        }
        #expect(encodedLossy3D.report.fidelity == .lossy)
        let lossySnap2 = try #require(lossyRec.snapshotAfterEnterDelay(forTile: 2))
        #expect(lossySnap2.currentInFlight == 1)
        #expect(lossySnap2.retainedBytes == 0)
        #expect(lossySnap2.liveOutputBytes > 0)
        #expect(lossyRec.retainedBytes > lossySnap2.liveOutputBytes)
        #expect(lossyRec.liveOutputBytes == 0)
        #expect(lossyRec.liveTransientBytes == 0)
    }

    @Test("F05 re-audit: scoped growth copy-overlap reservation with explicit barriers and exact 22-byte J3DS header admission across single and multi-tile retained outputs")
    func outputGrowthOverlapAndExactJ3DSHeaderBoundaries() async throws {
        // --- 1. Concurrent shared-budget output growth overlap with explicit phase barriers ---
        // Two workers each hold a 20-byte initial output reservation and live 20-byte buffer (`20 + 20 = 40 B`).
        // Each worker grows its output by 20 B while its old 20-byte buffer remains live (`40 + 40` output + `20 + 20`
        // simultaneous copy overlap = `120 B`). Must deny under `100 B` and succeed under `120 B`.
        func runConcurrentGrowthModel(workspaceLimit: Int) async throws -> (
            workerBDenied: Bool,
            midOverlapScratchBytes: Int,
            midOverlapOutputBytes: Int,
            peakWorkspaceBytes: Int
        ) {
            let rec = VolumeConcurrencyTelemetry.Recorder()
            return try await VolumeConcurrencyTelemetry.$recorder.withValue(rec) {
                let budget = JP3DLiveBudgetTracker(
                    baseBytes: 0,
                    limits: try ResourceLimits(maximumWorkspaceBytes: workspaceLimit)
                )
                let resA = try budget.makeOutputReservation(initialBytes: 20, stage: "grow-init-a", message: "init a")
                let resB = try budget.makeOutputReservation(initialBytes: 20, stage: "grow-init-b", message: "init b")
                defer {
                    resA.release()
                    resB.release()
                }
                #expect(budget.currentOutputBytes == 40)
                #expect(budget.currentScratchBytes == 0)

                let workerAEnteredGrowth = VolumeConcurrencyTelemetry.PhaseGate()
                let workerBFinishedAttempt = VolumeConcurrencyTelemetry.PhaseGate()
                let midScratchObserved = Mutex(0)
                let midOutputObserved = Mutex(0)
                let bDenied = Mutex(false)

                let taskA = Task {
                    var bufA = Data(repeating: 0xAA, count: 20)
                    try await resA.withGrowth(
                        by: 20,
                        extraTransientBytes: bufA.count,
                        stage: "grow-step-a",
                        message: "a growth"
                    ) {
                        var grownA = Data(capacity: 40)
                        grownA.append(bufA)
                        grownA.append(Data(repeating: 0xAB, count: 20))
                        // Signal Worker B while `bufA` (old 20 B) and `grownA` (new 40 B) coexist inside `withGrowth`:
                        workerAEnteredGrowth.open()
                        await workerBFinishedAttempt.wait()
                        bufA = grownA
                    }
                    #expect(bufA.count == 40)
                }

                let taskB = Task {
                    await workerAEnteredGrowth.wait()
                    // Worker A's 20 B copy-overlap MUST be actively held in shared `liveScratchBytes` right now:
                    #expect(budget.currentOutputBytes == 60)
                    #expect(budget.currentScratchBytes == 20)
                    var bufB = Data(repeating: 0xBB, count: 20)
                    do {
                        try resB.withGrowth(
                            by: 20,
                            extraTransientBytes: bufB.count,
                            stage: "grow-step-b",
                            message: "b growth"
                        ) {
                            var grownB = Data(capacity: 40)
                            grownB.append(bufB)
                            grownB.append(Data(repeating: 0xBC, count: 20))
                            midScratchObserved.withLock { $0 = budget.currentScratchBytes }
                            midOutputObserved.withLock { $0 = budget.currentOutputBytes }
                            bufB = grownB
                        }
                        #expect(bufB.count == 40)
                    } catch let error as CodecError {
                        #expect(error.category == .resourceLimitExceeded)
                        bDenied.withLock { $0 = true }
                        midScratchObserved.withLock { $0 = budget.currentScratchBytes }
                        midOutputObserved.withLock { $0 = budget.currentOutputBytes }
                    }
                    workerBFinishedAttempt.open()
                }

                try await taskA.value
                try await taskB.value
                // After both `withGrowth` scopes complete, temporary copy-overlap scratch is 0 while committed outputs remain reserved:
                #expect(budget.currentScratchBytes == 0)
                let wasDenied = bDenied.withLock { $0 }
                #expect(budget.currentOutputBytes == (wasDenied ? 60 : 80))
                #expect(resA.reservedBytes == 40)
                #expect(resB.reservedBytes == (wasDenied ? 20 : 40))

                resA.release()
                resB.release()
                #expect(budget.currentOutputBytes == 0)
                #expect(budget.currentScratchBytes == 0)
                #expect(budget.currentTransientBytes == 0)
                return (
                    workerBDenied: wasDenied,
                    midOverlapScratchBytes: midScratchObserved.withLock { $0 },
                    midOverlapOutputBytes: midOutputObserved.withLock { $0 },
                    peakWorkspaceBytes: rec.peakLiveWorkspaceBytes
                )
            }
        }

        let denied100 = try await runConcurrentGrowthModel(workspaceLimit: 100)
        #expect(denied100.workerBDenied)
        #expect(denied100.midOverlapScratchBytes == 20)
        #expect(denied100.midOverlapOutputBytes == 60)
        #expect(denied100.peakWorkspaceBytes == 80)

        let passed120 = try await runConcurrentGrowthModel(workspaceLimit: 120)
        #expect(!passed120.workerBDenied)
        #expect(passed120.midOverlapScratchBytes == 40)
        #expect(passed120.midOverlapOutputBytes == 80)
        #expect(passed120.peakWorkspaceBytes == 120)

        // Error/cancellation rollback mid-growth releases BOTH uncommitted output bytes and copy-overlap scratch bytes:
        let rollbackBudget = JP3DLiveBudgetTracker(
            baseBytes: 0,
            limits: try ResourceLimits(maximumWorkspaceBytes: 120)
        )
        let rollbackRes = try rollbackBudget.makeOutputReservation(
            initialBytes: 20,
            stage: "rollback-init",
            message: "rollback init"
        )
        do {
            try rollbackRes.withGrowth(
                by: 20,
                extraTransientBytes: 20,
                stage: "rollback-grow",
                message: "rollback grow"
            ) {
                #expect(rollbackBudget.currentOutputBytes == 40)
                #expect(rollbackBudget.currentScratchBytes == 20)
                throw CancellationError()
            }
            Issue.record("Expected thrown CancellationError inside withGrowth")
        } catch is CancellationError {
            // Expected.
        }
        #expect(rollbackRes.reservedBytes == 20)
        #expect(rollbackBudget.currentOutputBytes == 20)
        #expect(rollbackBudget.currentScratchBytes == 0)
        rollbackRes.release()
        #expect(rollbackBudget.currentOutputBytes == 0)

        // --- 2. Exact 22-byte J3DS header and output byte-identity across single, queued, and multiple retained outputs ---
        #expect(JP3DSliceStackCodec.v1HeaderSize == 21)
        #expect(JP3DSliceStackCodec.v2HeaderSize == 22)

        let constant32Samples = [[Int64](repeating: 7, count: 32)]
        func encodeSingleJ3DSTile(
            budget: JP3DLiveBudgetTracker,
            limits: ResourceLimits
        ) throws -> JP3DEncodedTileOutput {
            try JP3DSliceStackCodec().encodeTileInteger(
                componentSamples: constant32Samples,
                tileWidth: 4,
                tileHeight: 4,
                tileDepth: 2,
                bitDepth: 8,
                signed: false,
                levelsX: 1,
                levelsY: 1,
                levelsZ: 1,
                compressionMode: .lossless,
                qualityLayers: 1,
                zDeltaPolicy: .never,
                budget: budget,
                limits: limits
            )
        }

        // 2a. Control establishes exact `reservedBytes == data.count` (216 B, including all 22 v2 header bytes):
        let controlBudget = JP3DLiveBudgetTracker(baseBytes: 0, limits: .default)
        let controlTile = try encodeSingleJ3DSTile(budget: controlBudget, limits: .default)
        let exactTileBytes = controlTile.data.count
        #expect(exactTileBytes == 216)
        #expect(controlTile.reservation.reservedBytes == exactTileBytes)
        #expect(controlBudget.currentOutputBytes == exactTileBytes)
        #expect(controlBudget.currentScratchBytes == 0)
        controlTile.reservation.release()
        #expect(controlBudget.currentOutputBytes == 0)

        // 2b. Pre-header compressed limit (`v2HeaderSize - 1 = 21 B`) rejects BEFORE header allocation (`0` events):
        let preHeaderLimits = try ResourceLimits(maximumCompressedBytes: JP3DSliceStackCodec.v2HeaderSize - 1)
        let preHeaderBudget = JP3DLiveBudgetTracker(baseBytes: 0, limits: preHeaderLimits)
        let preHeaderStorage = StorageTelemetry.Recorder()
        do {
            _ = try StorageTelemetry.$recorder.withValue(preHeaderStorage) {
                try encodeSingleJ3DSTile(budget: preHeaderBudget, limits: preHeaderLimits)
            }
            Issue.record("Expected 22-byte J3DS v2 header to fail 21-byte compressed limit before allocation")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(preHeaderStorage.parserEvents.filter { $0.stage == "jp3d-j3ds-tile-output" }.isEmpty)
        #expect(preHeaderBudget.currentOutputBytes == 0)
        #expect(preHeaderBudget.currentScratchBytes == 0)

        // 2c. Exact single-tile boundary: `exactTileBytes - 1` (215 B) denies before final output construction and cleans up;
        // exact `exactTileBytes` (216 B) succeeds with `reservedBytes == data.count == 216`:
        let deny215Limits = try ResourceLimits(maximumCompressedBytes: exactTileBytes - 1)
        let deny215Budget = JP3DLiveBudgetTracker(baseBytes: 0, limits: deny215Limits)
        do {
            let over = try encodeSingleJ3DSTile(budget: deny215Budget, limits: deny215Limits)
            Issue.record("J3DS emitted \(over.data.count) B under \(exactTileBytes - 1) B limit (reserved \(over.reservation.reservedBytes) B)")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(deny215Budget.currentOutputBytes == 0)
        #expect(deny215Budget.currentScratchBytes == 0)

        let pass216Limits = try ResourceLimits(maximumCompressedBytes: exactTileBytes)
        let pass216Budget = JP3DLiveBudgetTracker(baseBytes: 0, limits: pass216Limits)
        let pass216Tile = try encodeSingleJ3DSTile(budget: pass216Budget, limits: pass216Limits)
        #expect(pass216Tile.data.count == exactTileBytes)
        #expect(pass216Tile.reservation.reservedBytes == exactTileBytes)
        pass216Tile.reservation.promoteToRetained(stage: "jp3d-retained-tile")
        #expect(pass216Budget.currentOutputBytes == 0)
        #expect(pass216Budget.currentRetainedBytes == exactTileBytes)

        // 2d. Multiple retained J3DS outputs (`3 * 216 = 648 B`):
        // With the prior 2-byte header undercharge (`3 * 214 = 642 B`), `maximumCompressedBytes = 647` wrongly admitted 3 tiles!
        // Now `647 B` (`3 * exactTileBytes - 1`) rejects Tile 2 before final output allocation, while exact `648 B` admits all 3:
        let threeTilesTotal = 3 * exactTileBytes
        let deny3Limits = try ResourceLimits(maximumCompressedBytes: threeTilesTotal - 1)
        let deny3Budget = JP3DLiveBudgetTracker(baseBytes: 0, limits: deny3Limits)
        let t0 = try encodeSingleJ3DSTile(budget: deny3Budget, limits: deny3Limits)
        t0.reservation.promoteToRetained(stage: "jp3d-retained-tile")
        let t1 = try encodeSingleJ3DSTile(budget: deny3Budget, limits: deny3Limits)
        t1.reservation.promoteToRetained(stage: "jp3d-retained-tile")
        #expect(deny3Budget.currentRetainedBytes == 2 * exactTileBytes)
        do {
            _ = try encodeSingleJ3DSTile(budget: deny3Budget, limits: deny3Limits)
            Issue.record("Expected 3rd 216 B J3DS tile (648 B cumulative) to fail \(threeTilesTotal - 1) B compressed limit")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(deny3Budget.currentRetainedBytes == 2 * exactTileBytes)
        #expect(deny3Budget.currentOutputBytes == 0)
        #expect(deny3Budget.currentScratchBytes == 0)

        let pass3Limits = try ResourceLimits(maximumCompressedBytes: threeTilesTotal)
        let pass3Budget = JP3DLiveBudgetTracker(baseBytes: 0, limits: pass3Limits)
        for _ in 0..<3 {
            let t = try encodeSingleJ3DSTile(budget: pass3Budget, limits: pass3Limits)
            #expect(t.data.count == exactTileBytes)
            #expect(t.reservation.reservedBytes == exactTileBytes)
            t.reservation.promoteToRetained(stage: "jp3d-retained-tile")
        }
        #expect(pass3Budget.currentRetainedBytes == threeTilesTotal)
        #expect(pass3Budget.currentOutputBytes == 0)
        #expect(pass3Budget.currentScratchBytes == 0)

        // 2e. End-to-end 3-tile J3DS `VolumeEncoder` (`12x4x2` constant `7` 8-bit lossless, `4x4x2` tiling -> 3 x 216 B tiles)
        // with explicit barriers verifies queued `2 * 216 = 432 B` and denial of Tile 2 under `647 B` before parent consumes:
        let vol3Const8 = J2KVolume(
            width: 12,
            height: 4,
            depth: 2,
            components: [
                J2KVolumeComponent(
                    index: 0,
                    bitDepth: 8,
                    signed: false,
                    width: 12,
                    height: 4,
                    depth: 2,
                    data: Data(repeating: 7, count: 12 * 4 * 2)
                )
            ]
        )
        let enc3J3DS = try VolumeEncoder(
            configuration: try VolumeEncoderConfiguration(
                compressionMode: .lossless,
                tiling: JP3DTilingConfiguration(tileSizeX: 4, tileSizeY: 4, tileSizeZ: 2),
                levelsX: 1,
                levelsY: 1,
                levelsZ: 1
            )
        )
        let qFirstTwo = VolumeConcurrencyTelemetry.PhaseGate()
        let qThirdDone = VolumeConcurrencyTelemetry.PhaseGate()
        let qCount = Mutex(0)
        let qRec = VolumeConcurrencyTelemetry.Recorder(
            onWorkerEnter: { tileIdx, _ in
                if tileIdx == 2 {
                    await qFirstTwo.wait()
                }
            },
            onWorkerExit: { tileIdx in
                if tileIdx == 0 || tileIdx == 1 {
                    let done = qCount.withLock { c -> Int in
                        c += 1
                        return c
                    }
                    if done >= 2 {
                        qFirstTwo.open()
                    }
                } else if tileIdx == 2 {
                    qThirdDone.open()
                }
            },
            onBeforeParentConsume: { step, _ in
                if step == 0 {
                    await qThirdDone.wait()
                }
            }
        )
        do {
            _ = try await VolumeConcurrencyTelemetry.$recorder.withValue(qRec) {
                try await enc3J3DS.encode(
                    vol3Const8,
                    options: VolumeEncodeOptions(
                        resourceLimits: try ResourceLimits(
                            maximumCompressedBytes: threeTilesTotal - 1,
                            maximumWorkers: 3
                        )
                    )
                )
            }
            Issue.record("Expected 3 x 216 B J3DS tiles (648 B) to fail 647 B compressed limit during Worker 2")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        let qSnap2 = try #require(qRec.snapshotAfterEnterDelay(forTile: 2))
        #expect(qSnap2.currentInFlight == 1)
        #expect(qSnap2.retainedBytes == 0)
        #expect(qSnap2.liveOutputBytes == 2 * exactTileBytes)
        #expect(qRec.currentInFlight == 0)
        #expect(qRec.liveOutputBytes == 0)
        #expect(qRec.liveScratchBytes == 0)
        #expect(qRec.liveTransientBytes == 0)
        #expect(qRec.authoritativeLiveOutputBytes == 0)
        #expect(qRec.authoritativeLiveScratchBytes == 0)

        // Truncated 21-byte J3DS v2 header rejects cleanly without out-of-bounds read:
        var truncatedV2Header = Data([0x4A, 0x33, 0x44, 0x53, 0x02])
        truncatedV2Header.append(Data(repeating: 0, count: 16))
        #expect(truncatedV2Header.count == 21)
        #expect(throws: J2KError.self) {
            _ = try JP3DSliceStackCodec().decodeTileInteger(
                truncatedV2Header,
                expectedComponents: 1,
                expectedWidth: 4,
                expectedHeight: 4,
                expectedDepth: 2
            )
        }
    }

    @Test("F05 qualification: monotonic budget revision gating prevents out-of-order stale telemetry snapshots from overwriting newer live counters or final zeros")
    func monotonicBudgetTelemetryOrderingAndStaleSnapshotRejection() async throws {
        // --- 1. Direct out-of-order revision delivery to VolumeConcurrencyTelemetry.Recorder ---
        let directRec = VolumeConcurrencyTelemetry.Recorder()
        let r1 = directRec.allocateBudgetRevision()
        let r2 = directRec.allocateBudgetRevision()
        let r3 = directRec.allocateBudgetRevision()
        let r4 = directRec.allocateBudgetRevision()
        #expect(r1 < r2 && r2 < r3 && r3 < r4)

        // Newer snapshot `r2` arrives before older snapshot `r1`:
        directRec.recordBudgetUpdate(
            revision: r2,
            liveScratch: 160,
            liveTransient: 240,
            liveOutput: 80,
            retained: 0,
            releasedOutput: 0
        )
        directRec.recordBudgetUpdate(
            revision: r1,
            liveScratch: 96,
            liveTransient: 136,
            liveOutput: 40,
            retained: 0,
            releasedOutput: 0
        )
        #expect(directRec.staleBudgetUpdatesIgnored == 1)
        #expect(directRec.lastBudgetRevision == r2)
        #expect(directRec.liveScratchBytes == 160)
        #expect(directRec.liveOutputBytes == 80)

        // Final-zero cleanup snapshot `r4` arrives BEFORE delayed high-water intermediate snapshot `r3`:
        // Current counters MUST remain at `r4`'s final zeros, while commutative `peak*` counters still capture `r3`:
        directRec.recordBudgetUpdate(
            revision: r4,
            liveScratch: 0,
            liveTransient: 0,
            liveOutput: 0,
            retained: 80,
            releasedOutput: 40
        )
        directRec.recordBudgetUpdate(
            revision: r3,
            liveScratch: 320,
            liveTransient: 440,
            liveOutput: 120,
            retained: 0,
            releasedOutput: 0
        )
        #expect(directRec.staleBudgetUpdatesIgnored == 2)
        #expect(directRec.lastBudgetRevision == r4)
        #expect(directRec.liveScratchBytes == 0)
        #expect(directRec.liveOutputBytes == 0)
        #expect(directRec.liveTransientBytes == 0)
        #expect(directRec.retainedBytes == 80)
        #expect(directRec.releasedOutputBytes == 40)
        #expect(directRec.peakScratchBytes == 320)
        #expect(directRec.peakOutputBytes == 120)
        #expect(directRec.peakTransientBytes == 440)
        #expect(directRec.peakLiveWorkspaceBytes == 440)

        // --- 2. End-to-end JP3DLiveBudgetTracker delayed-publication reordering ---
        // Acquire two scratch leases (64 + 128 = 192 B) and two output reservations (50 + 70 = 120 B), then hold the
        // publication of the 1st release (`scratch = 128, output = 120`) while the remaining releases/promotions drive
        // authoritative tracker state to final `scratch = 0, output = 0, retained = 50, releasedOutput = 70` and publish
        // first; flushing the held older publication afterwards must NOT overwrite the final zeros:
        let trackerRec = VolumeConcurrencyTelemetry.Recorder()
        try VolumeConcurrencyTelemetry.$recorder.withValue(trackerRec) {
            let budget = JP3DLiveBudgetTracker(baseBytes: 0, limits: .default)
            let leaseA = try budget.reserveTransient(64, stage: "rev-scratch-a", message: "a")
            let leaseB = try budget.reserveTransient(128, stage: "rev-scratch-b", message: "b")
            let outA = try budget.makeOutputReservation(initialBytes: 50, stage: "rev-out-a", message: "oa")
            let outB = try budget.makeOutputReservation(initialBytes: 70, stage: "rev-out-b", message: "ob")
            #expect(trackerRec.liveScratchBytes == 192)
            #expect(trackerRec.liveOutputBytes == 120)

            let deferredOlderPublish = Mutex<(@Sendable () -> Void)?>(nil)
            let interceptedFirst = Mutex(false)
            budget.setTestPublishInterceptor { _, publish in
                let holdThisOne = interceptedFirst.withLock { held -> Bool in
                    if !held {
                        held = true
                        return true
                    }
                    return false
                }
                if holdThisOne {
                    deferredOlderPublish.withLock { $0 = publish }
                } else {
                    publish()
                }
            }

            // Mutates `budget` to `scratch = 128, output = 120` at an older revision, holding its Recorder publication:
            leaseA.release()
            #expect(budget.currentScratchBytes == 128)
            // Subsequent mutations advance `budget` to final zero scratch/output and publish newer revisions immediately:
            leaseB.release()
            outA.promoteToRetained(stage: "jp3d-retained-tile")
            outB.release()
            #expect(budget.currentScratchBytes == 0)
            #expect(budget.currentOutputBytes == 0)
            #expect(budget.currentRetainedBytes == 50)
            #expect(budget.currentReleasedOutputBytes == 70)
            #expect(trackerRec.liveScratchBytes == 0)
            #expect(trackerRec.liveOutputBytes == 0)
            #expect(trackerRec.retainedBytes == 50)
            #expect(trackerRec.releasedOutputBytes == 70)

            // Flush the delayed older publication (`scratch = 128, output = 120, retained = 0, releasedOutput = 0`):
            let stalePublish = try #require(deferredOlderPublish.withLock { $0 })
            stalePublish()

            #expect(trackerRec.staleBudgetUpdatesIgnored == 1)
            #expect(trackerRec.lastBudgetRevision == budget.currentRevision)
            #expect(trackerRec.liveScratchBytes == 0)
            #expect(trackerRec.liveOutputBytes == 0)
            #expect(trackerRec.liveTransientBytes == 0)
            #expect(trackerRec.retainedBytes == 50)
            #expect(trackerRec.releasedOutputBytes == 70)
            #expect(trackerRec.authoritativeLiveScratchBytes == 0)
            #expect(trackerRec.authoritativeLiveOutputBytes == 0)
            #expect(trackerRec.authoritativeLiveTransientBytes == 0)
            #expect(trackerRec.authoritativeRetainedBytes == 50)
            #expect(trackerRec.authoritativeReleasedOutputBytes == 70)
            #expect(trackerRec.peakScratchBytes == 192)
            #expect(trackerRec.peakOutputBytes == 120)
            budget.setTestPublishInterceptor(nil)
        }

        // --- 3. Multi-task concurrent reordering & final-zero cleanup check ---
        let concurrentRec = VolumeConcurrencyTelemetry.Recorder()
        try await VolumeConcurrencyTelemetry.$recorder.withValue(concurrentRec) {
            let budget = JP3DLiveBudgetTracker(baseBytes: 0, limits: .default)
            let delayedQueue = Mutex<[@Sendable () -> Void]>([])
            let toggle = Mutex(0)
            budget.setTestPublishInterceptor { _, publish in
                let delay = toggle.withLock { c -> Bool in
                    c += 1
                    return (c % 2) == 1
                }
                if delay {
                    delayedQueue.withLock { $0.append(publish) }
                } else {
                    publish()
                }
            }

            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<12 {
                    group.addTask {
                        let lease = try budget.reserveTransient(32 + i, stage: "conc-sc", message: "sc")
                        let out = try budget.makeOutputReservation(initialBytes: 24, stage: "conc-out", message: "out")
                        if i % 2 == 0 {
                            out.promoteToRetained(stage: "jp3d-retained-tile")
                        } else {
                            out.release()
                        }
                        lease.release()
                    }
                }
                try await group.waitForAll()
            }

            // Ensure the final authoritative state publishes cleanly, then replay all delayed older publications in reverse:
            budget.setTestPublishInterceptor(nil)
            let finalAnchor = try budget.reserveTransient(16, stage: "conc-anchor", message: "anchor")
            finalAnchor.release()

            let ignoredDuringConcurrentPhase = concurrentRec.staleBudgetUpdatesIgnored
            let queuedStale = delayedQueue.withLock { q -> [@Sendable () -> Void] in
                let copy = Array(q.reversed())
                q.removeAll()
                return copy
            }
            #expect(queuedStale.count == 24)
            for publish in queuedStale {
                publish()
            }

            // Every replayed stale snapshot after `finalAnchor` is deterministically rejected on top of any
            // natural thread-reordered unlocked publications caught during the concurrent phase:
            #expect(concurrentRec.staleBudgetUpdatesIgnored == ignoredDuringConcurrentPhase + queuedStale.count)
            #expect(concurrentRec.lastBudgetRevision == budget.currentRevision)
            #expect(concurrentRec.liveScratchBytes == 0)
            #expect(concurrentRec.liveOutputBytes == 0)
            #expect(concurrentRec.liveTransientBytes == 0)
            #expect(concurrentRec.retainedBytes == 6 * 24)
            #expect(concurrentRec.releasedOutputBytes == 6 * 24)
            #expect(concurrentRec.authoritativeLiveScratchBytes == 0)
            #expect(concurrentRec.authoritativeLiveOutputBytes == 0)
            #expect(concurrentRec.authoritativeLiveTransientBytes == 0)
            #expect(concurrentRec.authoritativeRetainedBytes == 6 * 24)
            #expect(concurrentRec.authoritativeReleasedOutputBytes == 6 * 24)
            #expect(concurrentRec.peakScratchBytes >= 32)
            #expect(concurrentRec.peakOutputBytes >= 24)
            #expect(concurrentRec.peakLiveWorkspaceBytes >= 6 * 24)
        }

        // --- 4. Production ordered-publication path (`interceptor == nil`) across 12 concurrent tasks ---
        // Because `commitSnapshot` publishes under `Tracker.state -> leaf Recorder.state` when no test interceptor is set,
        // concurrent tasks observe zero out-of-order deliveries (`staleBudgetUpdatesIgnored == 0`) and exact final zeros:
        let orderedRec = VolumeConcurrencyTelemetry.Recorder()
        try await VolumeConcurrencyTelemetry.$recorder.withValue(orderedRec) {
            let budget = JP3DLiveBudgetTracker(baseBytes: 0, limits: .default)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for i in 0..<12 {
                    group.addTask {
                        let lease = try budget.reserveTransient(32 + i, stage: "ord-sc", message: "sc")
                        let out = try budget.makeOutputReservation(initialBytes: 24, stage: "ord-out", message: "out")
                        if i % 2 == 0 {
                            out.promoteToRetained(stage: "jp3d-retained-tile")
                        } else {
                            out.release()
                        }
                        lease.release()
                    }
                }
                try await group.waitForAll()
            }
            #expect(orderedRec.staleBudgetUpdatesIgnored == 0)
            #expect(orderedRec.lastBudgetRevision == budget.currentRevision)
            #expect(orderedRec.liveScratchBytes == 0)
            #expect(orderedRec.liveOutputBytes == 0)
            #expect(orderedRec.liveTransientBytes == 0)
            #expect(orderedRec.retainedBytes == 6 * 24)
            #expect(orderedRec.releasedOutputBytes == 6 * 24)
            #expect(orderedRec.authoritativeLiveScratchBytes == 0)
            #expect(orderedRec.authoritativeLiveOutputBytes == 0)
            #expect(orderedRec.peakScratchBytes >= 32)
            #expect(orderedRec.peakOutputBytes >= 24)
            #expect(orderedRec.peakLiveWorkspaceBytes >= 6 * 24)
        }

        // --- 5. Weak-sentinel ARC deallocation proof for Recorder <-> JP3DLiveBudgetTracker <-> StateStorage ---
        // Verifies there is no retain cycle between `VolumeConcurrencyTelemetry.Recorder` and `JP3DLiveBudgetTracker`:
        //   (a) `JP3DLiveBudgetTracker` deallocates as soon as its owner leaves scope even while `Recorder` remains alive,
        //       AND `Recorder.authoritative*` still preserves the final authoritative counters via `StateStorage`;
        //   (b) once `Recorder` and the `$recorder.withValue` task-local scope end, `Recorder`, `JP3DLiveBudgetTracker`,
        //       and `StateStorage` are all deallocated (`nil`), both in direct tracker usage and full `VolumeEncoder.encode`.
        struct WeakSentinel<Object: AnyObject> {
            weak var object: Object?
        }

        @inline(never)
        func runScopedTrackerUnderRecorder(
            _ rec: VolumeConcurrencyTelemetry.Recorder
        ) throws -> (
            tracker: WeakSentinel<JP3DLiveBudgetTracker>,
            storage: WeakSentinel<JP3DLiveBudgetTracker.StateStorage>
        ) {
            try VolumeConcurrencyTelemetry.$recorder.withValue(rec) {
                let budget = JP3DLiveBudgetTracker(baseBytes: 0, limits: .default)
                let scratch = try budget.reserveTransient(48, stage: "arc-sc", message: "sc")
                let outPromoted = try budget.makeOutputReservation(initialBytes: 40, stage: "arc-out1", message: "o1")
                try outPromoted.withGrowth(
                    by: 24,
                    extraTransientBytes: 40,
                    stage: "arc-grow1",
                    message: "g1"
                ) {
                    #expect(budget.currentScratchBytes == 88)
                    #expect(budget.currentOutputBytes == 64)
                }
                let outReleased = try budget.makeOutputReservation(initialBytes: 32, stage: "arc-out2", message: "o2")
                outPromoted.promoteToRetained(stage: "jp3d-retained-tile")
                outReleased.release()
                scratch.release()
                return (WeakSentinel(object: budget), WeakSentinel(object: budget.stateStorage))
            }
        }

        @inline(never)
        func runFullRecorderAndTrackerScope() throws -> (
            recorder: WeakSentinel<VolumeConcurrencyTelemetry.Recorder>,
            tracker: WeakSentinel<JP3DLiveBudgetTracker>,
            storage: WeakSentinel<JP3DLiveBudgetTracker.StateStorage>
        ) {
            let rec = VolumeConcurrencyTelemetry.Recorder()
            let sentinels = try runScopedTrackerUnderRecorder(rec)
            // While `rec` is still alive, `JP3DLiveBudgetTracker` has ALREADY deallocated (`Recorder` does not retain it),
            // yet `rec.authoritative*` still reads the exact final counters from `StateStorage`:
            #expect(sentinels.tracker.object == nil)
            #expect(rec.liveScratchBytes == 0)
            #expect(rec.liveOutputBytes == 0)
            #expect(rec.retainedBytes == 64)
            #expect(rec.releasedOutputBytes == 32)
            #expect(rec.peakScratchBytes == 88)
            #expect(rec.peakOutputBytes == 96)
            #expect(rec.authoritativeLiveScratchBytes == 0)
            #expect(rec.authoritativeLiveOutputBytes == 0)
            #expect(rec.authoritativeLiveTransientBytes == 0)
            #expect(rec.authoritativeRetainedBytes == 64)
            #expect(rec.authoritativeReleasedOutputBytes == 32)
            return (WeakSentinel(object: rec), sentinels.tracker, sentinels.storage)
        }

        let directSentinels = try runFullRecorderAndTrackerScope()
        #expect(directSentinels.recorder.object == nil)
        #expect(directSentinels.tracker.object == nil)
        #expect(directSentinels.storage.object == nil)

        @inline(never)
        func runInstrumentedVolumeEncodeScope() async throws -> WeakSentinel<VolumeConcurrencyTelemetry.Recorder> {
            let vol = J2KVolume(
                width: 4,
                height: 2,
                depth: 2,
                components: [
                    J2KVolumeComponent(
                        index: 0,
                        bitDepth: 16,
                        signed: false,
                        width: 4,
                        height: 2,
                        depth: 2,
                        data: Data(repeating: 11, count: 4 * 2 * 2 * 2)
                    )
                ]
            )
            let encoder = try VolumeEncoder(
                configuration: try VolumeEncoderConfiguration(
                    compressionMode: .lossless,
                    tiling: JP3DTilingConfiguration(tileSizeX: 2, tileSizeY: 2, tileSizeZ: 2),
                    levelsX: 1,
                    levelsY: 1,
                    levelsZ: 1
                )
            )
            let rec = VolumeConcurrencyTelemetry.Recorder()
            let encoded = try await VolumeConcurrencyTelemetry.$recorder.withValue(rec) {
                try await encoder.encode(
                    vol,
                    options: VolumeEncodeOptions(resourceLimits: try ResourceLimits(maximumWorkers: 2))
                )
            }
            #expect(!encoded.data.isEmpty)
            #expect(rec.retainedBytes > 0)
            #expect(rec.liveScratchBytes == 0)
            #expect(rec.liveOutputBytes == 0)
            #expect(rec.authoritativeLiveScratchBytes == 0)
            #expect(rec.authoritativeLiveOutputBytes == 0)
            #expect(rec.authoritativeRetainedBytes == rec.retainedBytes)
            return WeakSentinel(object: rec)
        }

        let encodeRecSentinel = try await runInstrumentedVolumeEncodeScope()
        #expect(encodeRecSentinel.object == nil)
    }
}
