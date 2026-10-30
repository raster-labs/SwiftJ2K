// SPDX-License-Identifier: Apache-2.0
//
// R2VolumeRemediationTests.swift
// SwiftJ2K3DTests
//
// Phase R2 3D volumetric semantics remediation regressions covering:
// - F09: Enforcement of `CopyPolicy` (`.requireSharedStorage` vs `.allowCopy`),
//        `ExecutionPolicy` (`.required(.accelerated)`, `.preferred(.accelerated)`, `.scalarCPU`
//        including simulated backend unavailability and `JP3DMetalDWT.isMetalAvailable`),
//        and truthful `OperationReport` telemetry (`copyEvents`, `peakPixelBytes`,
//        measured `peakWorkspaceBytes`, `elapsedSeconds`, and `discardedMetadata*`).
// - F11: Preservation and explicit representation of 3D volume geometry
//        (`spacingX/Y/Z`, `originX/Y/Z`) across `VolumeEncoder`, `VolumeDecoder.inspect`,
//        `VolumeDecoder.decode`, sub-volume ROI decode, reduced-resolution decode, and
//        `VolumeTranscoder` under `.preserve`, plus deliberate omission/stripping under
//        `.discardAncillary` and validation of malformed/non-finite geometry.

import Foundation
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2K3D

private func makeSyntheticVolume(
    width: Int = 8,
    height: Int = 8,
    depth: Int = 4,
    spacing: (Double, Double, Double) = (0, 0, 0),
    origin: (Double, Double, Double) = (0, 0, 0)
) -> J2KVolume {
    let voxelCount: Int = width * height * depth
    var bytes = Data(count: voxelCount * 2)
    bytes.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Void in
        guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
        for z in 0..<depth {
            let sliceBase: Int = z * height * width
            let zTerm: Int = z * 191
            for y in 0..<height {
                let rowBase: Int = sliceBase + y * width
                let yzTerm: Int = y * 53 + zTerm
                for x in 0..<width {
                    let idx: Int = rowBase + x
                    let sample: Int = (x * 37 + yzTerm) & 0x0FFF
                    let val: UInt16 = UInt16(sample)
                    let lowByte: UInt8 = UInt8(val & 0x00FF)
                    let highByte: UInt8 = UInt8((val >> 8) & 0x00FF)
                    base[idx * 2] = lowByte
                    base[idx * 2 + 1] = highByte
                }
            }
        }
    }
    let comp = J2KVolumeComponent(
        index: 0,
        bitDepth: 12,
        signed: false,
        width: width,
        height: height,
        depth: depth,
        data: bytes
    )
    return J2KVolume(
        width: width,
        height: height,
        depth: depth,
        components: [comp],
        spacingX: spacing.0,
        spacingY: spacing.1,
        spacingZ: spacing.2,
        originX: origin.0,
        originY: origin.1,
        originZ: origin.2
    )
}

@Suite("Phase R2 — SwiftJ2K3D Semantics Remediation Regressions")
struct R2VolumeRemediationTests {

    // MARK: F09 — CopyPolicy, ExecutionPolicy, and Truthful OperationReport Telemetry

    @Test("F09: VolumeEncoder, VolumeDecoder, and VolumeTranscoder enforce CopyPolicy and emit truthful OperationReport telemetry")
    func volumeCopyPolicyAndOperationReportTelemetry() async throws {
        let volume = makeSyntheticVolume(
            width: 8,
            height: 8,
            depth: 4,
            spacing: (0.5, 0.5, 1.25),
            origin: (-10.0, 20.0, 5.0)
        )
        let encConfig = try VolumeEncoderConfiguration(
            compressionMode: .lossless,
            tiling: JP3DTilingConfiguration(tileSizeX: 8, tileSizeY: 8, tileSizeZ: 4),
            levelsX: 1,
            levelsY: 1,
            levelsZ: 1
        )
        let encoder = try VolumeEncoder(configuration: encConfig)

        // 1. VolumeEncoder rejects `.requireSharedStorage` truthfully
        do {
            _ = try await encoder.encode(
                volume,
                options: VolumeEncodeOptions(copyPolicy: .requireSharedStorage)
            )
            Issue.record("Expected VolumeEncoder.encode to reject .requireSharedStorage")
        } catch let err as CodecError {
            #expect(err.category == .incompatibleImageLayout)
        }

        // 2. VolumeEncoder with `.allowCopy` records CopyEvent, measured workspace, and elapsed timing
        let encoded = try await encoder.encode(
            volume,
            options: VolumeEncodeOptions(copyPolicy: .allowCopy, metadataPolicy: .preserve)
        )
        let expectedVoxelBytes = 8 * 8 * 4 * 2
        #expect(encoded.report.copyEvents.count == 1)
        #expect(encoded.report.copyEvents[0].bytesMoved == expectedVoxelBytes)
        #expect(encoded.report.pixelAllocationCount == 0) // native Part 10 3D path uses no 2D slice bridge
        #expect(encoded.report.peakPixelBytes == expectedVoxelBytes)
        #expect((encoded.report.peakWorkspaceBytes ?? 0) > 0)
        #expect(encoded.report.peakWorkspaceBytes != encoded.data.count)
        #expect((encoded.report.elapsedSeconds ?? -1) >= 0)
        #expect(encoded.report.discardedMetadataCount == 0)

        // 3. VolumeDecoder rejects `.requireSharedStorage` truthfully
        let decoder = try VolumeDecoder()
        do {
            _ = try await decoder.decode(
                encoded.data,
                options: VolumeDecodeOptions(copyPolicy: .requireSharedStorage)
            )
            Issue.record("Expected VolumeDecoder.decode to reject .requireSharedStorage")
        } catch let err as CodecError {
            #expect(err.category == .incompatibleImageLayout)
        }

        // 4. VolumeDecoder with `.allowCopy` records CopyEvent, pixel allocations, and real workspace
        let decoded = try await decoder.decode(
            encoded.data,
            options: VolumeDecodeOptions(copyPolicy: .allowCopy, metadataPolicy: .preserve)
        )
        #expect(decoded.report.copyEvents.count == 1)
        #expect(decoded.report.copyEvents[0].bytesMoved == expectedVoxelBytes)
        #expect(decoded.report.pixelAllocationCount == 1) // 1 output J2KVolume component buffer
        #expect(decoded.report.peakPixelBytes == expectedVoxelBytes)
        #expect((decoded.report.peakWorkspaceBytes ?? 0) > 0)
        #expect(decoded.report.peakWorkspaceBytes != encoded.data.count)

        // 5. Lossless VolumeTranscoder operates directly on tile codestreams without J2KVolume allocation,
        //    so `.requireSharedStorage` succeeds with zero CopyEvents and zero pixel allocations!
        let transcoder = try VolumeTranscoder()
        let transcodedHT = try await transcoder.transcode(
            encoded.data,
            to: .htj2k,
            options: TranscodeOptions(copyPolicy: .requireSharedStorage, metadataPolicy: .preserve)
        )
        #expect(transcodedHT.report.copyEvents.isEmpty)
        #expect(transcodedHT.report.pixelAllocationCount == 0)
        #expect(transcodedHT.report.peakPixelBytes == 0)
        #expect((transcodedHT.report.peakWorkspaceBytes ?? 0) > 0)

        // 6. Lossy VolumeTranscoder fallback materialises transient J2KVolume buffers:
        //    must reject `.requireSharedStorage` and report CopyEvent under `.allowCopy`!
        let lossyEnc = try VolumeEncoder(
            configuration: VolumeEncoderConfiguration(
                compressionMode: .lossy(psnr: 38.0),
                tiling: JP3DTilingConfiguration(tileSizeX: 8, tileSizeY: 8, tileSizeZ: 4),
                levelsX: 1,
                levelsY: 1,
                levelsZ: 1
            )
        )
        let lossyEncoded = try await lossyEnc.encode(volume)
        do {
            _ = try await transcoder.transcode(
                lossyEncoded.data,
                to: .htj2k,
                options: TranscodeOptions(copyPolicy: .requireSharedStorage)
            )
            Issue.record("Expected lossy VolumeTranscoder fallback to reject .requireSharedStorage")
        } catch let err as CodecError {
            #expect(err.category == .incompatibleImageLayout)
        }
        let lossyTranscoded = try await transcoder.transcode(
            lossyEncoded.data,
            to: .htj2k,
            options: TranscodeOptions(copyPolicy: .allowCopy)
        )
        #expect(lossyTranscoded.report.copyEvents.count == 1)
        #expect(lossyTranscoded.report.copyEvents[0].bytesMoved == expectedVoxelBytes * 2)
        #expect(lossyTranscoded.report.pixelAllocationCount == 1) // 1 intermediate J2KVolume component buffer
        #expect(lossyTranscoded.report.peakPixelBytes == expectedVoxelBytes)
    }

    @Test("F09: VolumeEncoder, VolumeDecoder, VolumeTranscoder, and JP3DMetalDWT honour ExecutionPolicy and simulated unavailability")
    func volumeExecutionPolicyEnforcementAndFallback() async throws {
        let volume = makeSyntheticVolume(width: 8, height: 8, depth: 2)
        let encConfig = try VolumeEncoderConfiguration(
            compressionMode: .lossless,
            tiling: JP3DTilingConfiguration(tileSizeX: 8, tileSizeY: 8, tileSizeZ: 2),
            levelsX: 1,
            levelsY: 1,
            levelsZ: 1
        )
        let encoder = try VolumeEncoder(configuration: encConfig)
        let decoder = try VolumeDecoder()
        let transcoder = try VolumeTranscoder()

        // Explicit `.scalarCPU` always reports `.scalarCPU` with `fallbackReason == nil`
        let scalarEnc = try await encoder.encode(
            volume,
            options: VolumeEncodeOptions(executionPolicy: .scalarCPU)
        )
        #expect(scalarEnc.report.backend == .scalarCPU)
        #expect(scalarEnc.report.fallbackReason == nil)

        try await AccelerationRuntime.$forceUnavailable.withValue(true) {
            // Metal DWT availability respects AccelerationRuntime task-local unavailability
            #expect(JP3DMetalDWT.isMetalAvailable == false)

            // `.required(.accelerated)` must throw `CodecError(.backendUnavailable)` on all 3 surfaces
            do {
                _ = try await encoder.encode(
                    volume,
                    options: VolumeEncodeOptions(executionPolicy: .required(.accelerated))
                )
                Issue.record("Expected VolumeEncoder to throw .backendUnavailable")
            } catch let err as CodecError {
                #expect(err.category == .backendUnavailable)
            }

            do {
                _ = try await decoder.decode(
                    scalarEnc.data,
                    options: VolumeDecodeOptions(executionPolicy: .required(.accelerated))
                )
                Issue.record("Expected VolumeDecoder to throw .backendUnavailable")
            } catch let err as CodecError {
                #expect(err.category == .backendUnavailable)
            }

            do {
                _ = try await transcoder.transcode(
                    scalarEnc.data,
                    to: .htj2k,
                    options: TranscodeOptions(executionPolicy: .required(.accelerated))
                )
                Issue.record("Expected VolumeTranscoder to throw .backendUnavailable instead of swallowing into fallback")
            } catch let err as CodecError {
                #expect(err.category == .backendUnavailable)
            }

            // `.preferred(.accelerated)` must fall back cleanly to `.scalarCPU` with a non-empty fallbackReason
            let prefEnc = try await encoder.encode(
                volume,
                options: VolumeEncodeOptions(executionPolicy: .preferred(.accelerated))
            )
            #expect(prefEnc.report.backend == .scalarCPU)
            #expect(prefEnc.report.fallbackReason != nil)

            let prefDec = try await decoder.decode(
                prefEnc.data,
                options: VolumeDecodeOptions(executionPolicy: .preferred(.accelerated))
            )
            #expect(prefDec.report.backend == .scalarCPU)
            #expect(prefDec.report.fallbackReason != nil)

            let prefTrans = try await transcoder.transcode(
                prefEnc.data,
                to: .htj2k,
                options: TranscodeOptions(executionPolicy: .preferred(.accelerated))
            )
            #expect(prefTrans.report.backend == .scalarCPU)
            #expect(prefTrans.report.fallbackReason != nil)
        }
    }

    // MARK: F11 — Volume Geometry Preservation, ROI/Resolution Scaling, & Discard Policy

    @Test("F11: Volume spacing and physical origin round-trip across encode, inspect, decode, ROI, reduced resolution, transcode, and discardAncillary")
    func volumeGeometryPreservationAndMetadataPolicy() async throws {
        // Choose an origin whose IEEE-754 big-endian representation contains 0xFF 0x90
        // (`Double(bitPattern: 0xC05E_FF90_1234_5678)` = finite negative coordinate ~ -123.993168...)
        // to prove binary `COM` segments never confuse `JP3DTranscoder` SOT marker scanning!
        let trickyOriginX = Double(bitPattern: 0xC05E_FF90_1234_5678)
        #expect(trickyOriginX.isFinite)
        let spacing = (0.625, 0.75, 1.5)
        let origin = (trickyOriginX, 14.25, -30.5)

        let volume = makeSyntheticVolume(
            width: 8,
            height: 8,
            depth: 4,
            spacing: spacing,
            origin: origin
        )
        let encConfig = try VolumeEncoderConfiguration(
            compressionMode: .lossless,
            tiling: JP3DTilingConfiguration(tileSizeX: 4, tileSizeY: 4, tileSizeZ: 2),
            levelsX: 1,
            levelsY: 1,
            levelsZ: 1
        )
        let encoder = try VolumeEncoder(configuration: encConfig)
        let encoded = try await encoder.encode(
            volume,
            options: VolumeEncodeOptions(metadataPolicy: .preserve)
        )

        // 1. Inspect under `.preserve` exposes exact spacing & origin
        let decoder = try VolumeDecoder()
        let info = try decoder.inspect(encoded.data, options: VolumeDecodeOptions(metadataPolicy: .preserve))
        #expect(info.spacingX == spacing.0)
        #expect(info.spacingY == spacing.1)
        #expect(info.spacingZ == spacing.2)
        #expect(info.originX == origin.0)
        #expect(info.originY == origin.1)
        #expect(info.originZ == origin.2)

        // Inspect under `.discardAncillary` reports unset `(0, 0, 0)` geometry
        let discardedInfo = try decoder.inspect(encoded.data, options: VolumeDecodeOptions(metadataPolicy: .discardAncillary))
        #expect(discardedInfo.spacingX == 0 && discardedInfo.spacingY == 0 && discardedInfo.spacingZ == 0)
        #expect(discardedInfo.originX == 0 && discardedInfo.originY == 0 && discardedInfo.originZ == 0)

        // 2. Full decode under `.preserve` restores bit-identical geometry and voxel samples
        let decoded = try await decoder.decode(
            encoded.data,
            options: VolumeDecodeOptions(metadataPolicy: .preserve)
        )
        #expect(decoded.volume.spacingX == spacing.0)
        #expect(decoded.volume.spacingY == spacing.1)
        #expect(decoded.volume.spacingZ == spacing.2)
        #expect(decoded.volume.originX == origin.0)
        #expect(decoded.volume.originY == origin.1)
        #expect(decoded.volume.originZ == origin.2)
        #expect(decoded.volume.components[0].data == volume.components[0].data)

        // 3. Sub-volume ROI decode shifts physical origin by `roiLower * spacing`
        let roi = JP3DRegion(x: 2..<6, y: 4..<8, z: 1..<3)
        let roiDecoded = try await decoder.decode(
            encoded.data,
            options: VolumeDecodeOptions(metadataPolicy: .preserve, regionOfInterest: roi)
        )
        #expect(roiDecoded.volume.width == 4 && roiDecoded.volume.height == 4 && roiDecoded.volume.depth == 2)
        #expect(roiDecoded.volume.spacingX == spacing.0)
        #expect(roiDecoded.volume.spacingY == spacing.1)
        #expect(roiDecoded.volume.spacingZ == spacing.2)
        #expect(roiDecoded.volume.originX == origin.0 + 2.0 * spacing.0)
        #expect(roiDecoded.volume.originY == origin.1 + 4.0 * spacing.1)
        #expect(roiDecoded.volume.originZ == origin.2 + 1.0 * spacing.2)

        // 4. Reduced-resolution decode (`resolutionLevel: 1`) doubles XY voxel spacing while preserving Z spacing and origin
        let res1Decoder = try VolumeDecoder(configuration: VolumeDecoderConfiguration(resolutionLevel: 1))
        let res1Decoded = try await res1Decoder.decode(
            encoded.data,
            options: VolumeDecodeOptions(metadataPolicy: .preserve)
        )
        #expect(res1Decoded.volume.spacingX == spacing.0 * 2.0)
        #expect(res1Decoded.volume.spacingY == spacing.1 * 2.0)
        #expect(res1Decoded.volume.spacingZ == spacing.2)
        #expect(res1Decoded.volume.originX == origin.0)
        #expect(res1Decoded.volume.originY == origin.1)
        #expect(res1Decoded.volume.originZ == origin.2)

        // 5. Transcode Part 1 -> HTJ2K -> Part 1 under `.preserve` retains exact geometry (even with 0xFF 0x90 inside COM!)
        let transcoder = try VolumeTranscoder()
        let htVolume = try await transcoder.transcode(
            encoded.data,
            to: .htj2k,
            options: TranscodeOptions(metadataPolicy: .preserve)
        )
        let backToPart1 = try await transcoder.transcode(
            htVolume.data,
            to: .jpeg2000,
            options: TranscodeOptions(metadataPolicy: .preserve)
        )
        let roundTripDecoded = try await decoder.decode(backToPart1.data)
        #expect(roundTripDecoded.volume.spacingX == spacing.0)
        #expect(roundTripDecoded.volume.spacingY == spacing.1)
        #expect(roundTripDecoded.volume.spacingZ == spacing.2)
        #expect(roundTripDecoded.volume.originX == origin.0)
        #expect(roundTripDecoded.volume.originY == origin.1)
        #expect(roundTripDecoded.volume.originZ == origin.2)
        #expect(roundTripDecoded.volume.components[0].data == volume.components[0].data)

        // 6. `.discardAncillary` across encode, decode, and transcode strips geometry and reports discarded metadata telemetry
        let encDiscarded = try await encoder.encode(
            volume,
            options: VolumeEncodeOptions(metadataPolicy: .discardAncillary)
        )
        #expect(encDiscarded.report.discardedMetadataCount == 1)
        #expect(encDiscarded.report.discardedMetadataBytes == 62)
        #expect(encDiscarded.report.discardedMetadataKinds == ["volumeGeometry"])
        let decFromEncDiscarded = try await decoder.decode(encDiscarded.data)
        #expect(!decFromEncDiscarded.volume.hasExplicitGeometry)

        let decDiscarded = try await decoder.decode(
            encoded.data,
            options: VolumeDecodeOptions(metadataPolicy: .discardAncillary)
        )
        #expect(!decDiscarded.volume.hasExplicitGeometry)
        #expect(decDiscarded.report.discardedMetadataCount == 1)
        #expect(decDiscarded.report.discardedMetadataBytes == 62)
        #expect(decDiscarded.report.discardedMetadataKinds == ["volumeGeometry"])

        let transDiscarded = try await transcoder.transcode(
            encoded.data,
            to: .htj2k,
            options: TranscodeOptions(metadataPolicy: .discardAncillary)
        )
        #expect(transDiscarded.report.discardedMetadataCount == 1)
        #expect(transDiscarded.report.discardedMetadataBytes == 62)
        #expect(transDiscarded.report.discardedMetadataKinds == ["volumeGeometry"])
        let decAfterTransDiscarded = try await decoder.decode(transDiscarded.data)
        #expect(!decAfterTransDiscarded.volume.hasExplicitGeometry)

        // 7. Validation of non-finite / negative spacing and corrupted `"SJ2K3D_GEOM_V1"` COM payload
        let nanVol = makeSyntheticVolume(spacing: (.nan, 1.0, 1.0))
        #expect(throws: J2KError.self) { try nanVol.validate() }
        let infOriginVol = makeSyntheticVolume(origin: (0, .infinity, 0))
        #expect(throws: J2KError.self) { try infOriginVol.validate() }
        let negSpacingVol = makeSyntheticVolume(spacing: (1.0, -0.5, 1.0))
        #expect(throws: J2KError.self) { try negSpacingVol.validate() }

        // Corrupt the `"SJ2K3D_GEOM_V1"` COM payload inside `encoded.data` with NaN (`0x7FF8_0000_0000_0000`)
        var corrupted = encoded.data
        let magic = Data("SJ2K3D_GEOM_V1".utf8)
        if let magicRange = corrupted.range(of: magic) {
            let firstDoublePos = magicRange.upperBound
            let nanBits: [UInt8] = [0x7F, 0xF8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
            corrupted.replaceSubrange(firstDoublePos..<(firstDoublePos + 8), with: nanBits)
            do {
                _ = try decoder.inspect(corrupted)
                Issue.record("Expected Decoder.inspect to reject corrupted NaN SJ2K3D_GEOM_V1 COM segment")
            } catch let err as CodecError {
                #expect(err.category == .malformedInput)
            }
        } else {
            Issue.record("Expected encoded codestream to contain SJ2K3D_GEOM_V1 COM marker")
        }
    }
}
