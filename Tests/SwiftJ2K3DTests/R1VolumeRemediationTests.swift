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
        let runtimeFailConcurrency = VolumeConcurrencyTelemetry.Recorder(artificialDelayMilliseconds: 15)
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
        let encConcurrency = VolumeConcurrencyTelemetry.Recorder(artificialDelayMilliseconds: 15)
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

        let decConcurrency = VolumeConcurrencyTelemetry.Recorder(artificialDelayMilliseconds: 15)
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
        // --- 1. 3-tile 32-bit J3DI (6x2x2 with 2x2x2 tiling -> 3 tiles of 89 B each, maximumWorkers = 3) ---
        // Workers 0 and 1 (0 ms delay) complete immediately and sit unconsumed inside ThrowingTaskGroup while the parent
        // delays before group.next() (45 ms). Worker 2 wakes at 18 ms while Workers 0 and 1 have ALREADY returned.
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

        // 1a. maximumCompressedBytes = 220 (> 171 B preflight floor; admits 2 * 89 = 178 B queued unconsumed outputs,
        // then rejects Worker 2's 89 B at 267 > 220 BEFORE parent consumes anything from group.next()):
        let denyQueuedCompressedRec = VolumeConcurrencyTelemetry.Recorder(
            workerDelayForTile: { $0 < 2 ? 0 : 18 },
            parentConsumeDelayMilliseconds: 45
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
        // Snapshot inside Worker 2 right after its 18 ms sleep proves Workers 0 & 1 had already returned
        // (currentInFlight == 1), parent had consumed 0 tiles (retainedBytes == 0), yet BOTH unconsumed child Data
        // outputs remained actively charged in liveOutputBytes (2 * 89 = 178 B):
        let snapTile2 = try #require(denyQueuedCompressedRec.snapshotAfterEnterDelay(forTile: 2))
        #expect(snapTile2.currentInFlight == 1)
        #expect(snapTile2.retainedBytes == 0)
        #expect(snapTile2.liveOutputBytes == 2 * 89)
        #expect(snapTile2.liveTransientBytes == 2 * 89)
        #expect(denyQueuedStorageRec.parserEvents.filter { $0.stage == "jp3d-j3di-tile-output" }.count == 2)
        // Workers 0 & 1 completed at 0 ms before Worker 2 failed at 18 ms; when parent later woke at 45 ms,
        // ThrowingTaskGroup yielded the 2 earlier completions before rethrowing Worker 2's pre-allocation denial:
        #expect(denyQueuedStorageRec.parserEvents.filter { $0.stage == "jp3d-retained-tile" }.count == 2)
        #expect(denyQueuedCompressedRec.currentInFlight == 0)
        #expect(denyQueuedCompressedRec.liveOutputBytes == 0)
        #expect(denyQueuedCompressedRec.liveTransientBytes == 0)

        // 1b. Unconsumed-result deinit path: all 3 workers complete within ~8 ms (queuing 3 * 89 = 267 B in
        // ThrowingTaskGroup), then parent wakes at 50 ms after the 25 ms deadline has elapsed, aborting inside
        // the first iteration before any tile is promoted to retained ("jp3d-retained-tile" count == 0) so the
        // remaining queued child results are cleaned up solely via OutputReservation.deinit:
        let unconsumedDeinitRec = VolumeConcurrencyTelemetry.Recorder(
            workerDelayForTile: { $0 < 2 ? 0 : 8 },
            parentConsumeDelayMilliseconds: 50
        )
        let unconsumedDeinitStorageRec = StorageTelemetry.Recorder()
        do {
            _ = try await StorageTelemetry.$recorder.withValue(unconsumedDeinitStorageRec) {
                try await VolumeConcurrencyTelemetry.$recorder.withValue(unconsumedDeinitRec) {
                    try await j3diEncoder.encode(
                        vol3TilesJ3DI,
                        options: VolumeEncodeOptions(
                            resourceLimits: try ResourceLimits(
                                maximumWorkers: 3,
                                deadlineSeconds: 0.025
                            )
                        )
                    )
                }
            }
            Issue.record("Expected elapsed 25 ms deadline to abort parent consumption with unconsumed child outputs queued")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(unconsumedDeinitStorageRec.parserEvents.filter { $0.stage == "jp3d-j3di-tile-output" }.count == 3)
        #expect(unconsumedDeinitStorageRec.parserEvents.filter { $0.stage == "jp3d-retained-tile" }.isEmpty)
        #expect(unconsumedDeinitRec.currentInFlight == 0)
        #expect(unconsumedDeinitRec.liveOutputBytes == 0)
        #expect(unconsumedDeinitRec.liveTransientBytes == 0)

        // --- 2. maximumWorkspaceBytes boundary on 10-tile 32-bit J3DI (20x2x2, 2x2x2 tiling -> 10 tiles, maximumWorkers = 2) ---
        // Preflight floor = 2 * 473 + 64 * 4 = 1202 B.
        // Wave-staggered delays (even tile 0 ms, odd tile 15 ms; parent consumes pairs every 30 ms) avoid dual-scratch
        // overlap during Waves 0..3. After 8 tiles are retained (8 * 89 = 712 B), Tile 8 completes (1185 <= 1230 B)
        // and sits unconsumed in ThrowingTaskGroup (89 B) while parent delays 45 ms at step 8. Tile 9 wakes at 15 ms:
        //   - Without unconsumed-output reservation transfer: 712 + 473 = 1185 <= 1230 B (would pass!).
        //   - With unconsumed-output reservation transfer: 712 + 89 + 473 = 1274 > 1230 B (denied before Tile 9 output!).
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
        let denyQueuedWSRec = VolumeConcurrencyTelemetry.Recorder(
            workerDelayForTile: { ($0 % 2 == 1) ? 15 : 0 },
            parentConsumeDelayForStep: { $0 == 8 ? 45 : (($0 % 2 == 0) ? 30 : 0) }
        )
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
        #expect(denyQueuedWSRec.currentInFlight == 0)
        #expect(denyQueuedWSRec.liveOutputBytes == 0)
        #expect(denyQueuedWSRec.liveTransientBytes == 0)

        // Larger-budget control (4096 B) with the exact same delayed-parent-consumption schedule succeeds cleanly:
        let passQueuedWSRec = VolumeConcurrencyTelemetry.Recorder(
            workerDelayForTile: { ($0 % 2 == 1) ? 15 : 0 },
            parentConsumeDelayForStep: { $0 == 8 ? 45 : (($0 % 2 == 0) ? 30 : 0) }
        )
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
        //     and lossy 3D wavelet (6x2x2 8-bit lossy, 2x2x2 tiling -> 3 tiles) reservation transfer ---
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
        let j3dsRec = VolumeConcurrencyTelemetry.Recorder(
            workerDelayForTile: { $0 < 2 ? 0 : 25 },
            parentConsumeDelayMilliseconds: 55
        )
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
        let lossyRec = VolumeConcurrencyTelemetry.Recorder(
            workerDelayForTile: { $0 < 2 ? 0 : 25 },
            parentConsumeDelayMilliseconds: 55
        )
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
}
