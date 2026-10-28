// SPDX-License-Identifier: Apache-2.0
//
// VolumeContractTests.swift
// SwiftJ2K3DTests
//
// Contract API-13 (VolumeEncoder, VolumeDecoder, VolumeTranscoder, VolumeInfo)
// and medical imaging signed voxel (16-bit CT Hounsfield, signed 8-bit) regression
// tests for Milestone 10 (SwiftJ2K3D).

import Foundation
import Synchronization
import XCTest
@testable import SwiftJ2K
@testable import SwiftJ2K3D

final class VolumeContractTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a synthetic signed 16-bit CT volume with Hounsfield units in `[-1024, +3071]`.
    private func makeSignedCTVolume(width: Int, height: Int, depth: Int) -> J2KVolume {
        let voxelCount = width * height * depth
        var data = Data(count: voxelCount * 2)
        for z in 0..<depth {
            for y in 0..<height {
                for x in 0..<width {
                    let idx = z * width * height + y * width + x
                    // Deterministic Hounsfield range [-1024, +3071]
                    let hu = Int16(-1024 + ((x * 37 + y * 73 + z * 199) % 4096))
                    let raw = UInt16(bitPattern: hu)
                    data[idx * 2] = UInt8(truncatingIfNeeded: raw)
                    data[idx * 2 + 1] = UInt8(truncatingIfNeeded: raw >> 8)
                }
            }
        }
        let comp = J2KVolumeComponent(
            index: 0,
            bitDepth: 16,
            signed: true,
            width: width,
            height: height,
            depth: depth,
            data: data
        )
        return J2KVolume(
            width: width,
            height: height,
            depth: depth,
            components: [comp],
            spacingX: 0.7,
            spacingY: 0.7,
            spacingZ: 1.5,
            originX: -120.0,
            originY: -120.0,
            originZ: -45.0
        )
    }

    private func readSigned16(in data: Data, at voxelIndex: Int) -> Int16 {
        let offset = voxelIndex * 2
        let lo = UInt16(data[offset])
        let hi = UInt16(data[offset + 1]) << 8
        return Int16(bitPattern: lo | hi)
    }

    // MARK: - 1. Signed Voxel Regression Tests (CT Hounsfield & Signed 8-Bit)

    func testSigned16BitCTHounsfieldLosslessRoundTrip() async throws {
        let volume = makeSignedCTVolume(width: 16, height: 16, depth: 6)
        let encoder = JP3DEncoder(configuration: .lossless)
        let encoded = try await encoder.encode(volume)

        let parser = JP3DCodestreamParser()
        let parsed = try parser.parse(encoded.data)
        XCTAssertTrue(parsed.siz.signed, "SIZ marker must preserve signed=true bit")
        XCTAssertEqual(parsed.siz.bitDepth, 16)

        let decoded = try await JP3DDecoder().decode(encoded.data)
        XCTAssertEqual(decoded.volume.width, 16)
        XCTAssertEqual(decoded.volume.height, 16)
        XCTAssertEqual(decoded.volume.depth, 6)
        XCTAssertTrue(decoded.volume.components[0].signed)

        let origData = volume.components[0].data
        let decData = decoded.volume.components[0].data
        XCTAssertEqual(origData.count, decData.count)
        for i in 0..<volume.voxelCount {
            let expected = readSigned16(in: origData, at: i)
            let actual = readSigned16(in: decData, at: i)
            XCTAssertEqual(actual, expected, "Signed 16-bit CT voxel mismatch at index \(i): expected \(expected), got \(actual)")
        }
    }

    func testSigned16BitCTHounsfieldHTJ2KAndZDeltaRoundTrip() async throws {
        let volume = makeSignedCTVolume(width: 16, height: 16, depth: 6)
        let config = JP3DEncoderConfiguration(
            compressionMode: .losslessHTJ2K,
            zDeltaMode: .always
        )
        let encoded = try await JP3DEncoder(configuration: config).encode(volume)
        let decoded = try await JP3DDecoder().decode(encoded.data)

        XCTAssertTrue(decoded.volume.components[0].signed)
        let origData = volume.components[0].data
        let decData = decoded.volume.components[0].data
        for i in 0..<volume.voxelCount {
            let expected = readSigned16(in: origData, at: i)
            let actual = readSigned16(in: decData, at: i)
            XCTAssertEqual(actual, expected, "HTJ2K+lag1 signed CT voxel mismatch at \(i)")
        }
    }

    func testSigned16BitCTHounsfieldROIDecoderRoundTrip() async throws {
        let volume = makeSignedCTVolume(width: 16, height: 16, depth: 6)
        let encoded = try await JP3DEncoder(configuration: .lossless).encode(volume)

        let roi = JP3DRegion(x: 4..<12, y: 4..<12, z: 1..<5)
        let roiDecoded = try await JP3DROIDecoder().decode(encoded.data, region: roi)
        XCTAssertTrue(roiDecoded.volume.components[0].signed)

        let origData = volume.components[0].data
        let roiData = roiDecoded.volume.components[0].data
        for (zi, z) in roi.z.enumerated() {
            for (yi, y) in roi.y.enumerated() {
                for (xi, x) in roi.x.enumerated() {
                    let fullIdx = z * 16 * 16 + y * 16 + x
                    let roiIdx = zi * 8 * 8 + yi * 8 + xi
                    XCTAssertEqual(
                        readSigned16(in: roiData, at: roiIdx),
                        readSigned16(in: origData, at: fullIdx),
                        "Signed ROI voxel mismatch at (\(x),\(y),\(z))"
                    )
                }
            }
        }
    }

    func testSigned8BitLosslessRoundTrip() async throws {
        let width = 8, height = 8, depth = 4
        let count = width * height * depth
        var data = Data(count: count)
        for i in 0..<count {
            let val = Int8(truncatingIfNeeded: (i * 19) % 256 - 128)
            data[i] = UInt8(bitPattern: val)
        }
        let comp = J2KVolumeComponent(
            index: 0, bitDepth: 8, signed: true,
            width: width, height: height, depth: depth,
            data: data
        )
        let volume = J2KVolume(width: width, height: height, depth: depth, components: [comp])
        let encoded = try await JP3DEncoder(configuration: .lossless).encode(volume)
        let decoded = try await JP3DDecoder().decode(encoded.data)

        XCTAssertTrue(decoded.volume.components[0].signed)
        XCTAssertEqual(decoded.volume.components[0].data, data)
    }

    func testUnsignedZDeltaNegativeResidualRoundTrip() async throws {
        // Slice 0 has value 200, slice 1 has value 50 -> residual is -150 (negative!)
        let width = 8, height = 8, depth = 3
        var data = Data(count: width * height * depth)
        for y in 0..<height {
            for x in 0..<width {
                data[0 * 64 + y * 8 + x] = 200
                data[1 * 64 + y * 8 + x] = 50
                data[2 * 64 + y * 8 + x] = 240
            }
        }
        let comp = J2KVolumeComponent(
            index: 0, bitDepth: 8, signed: false,
            width: width, height: height, depth: depth,
            data: data
        )
        let volume = J2KVolume(width: width, height: height, depth: depth, components: [comp])
        let config = JP3DEncoderConfiguration(compressionMode: .lossless, zDeltaMode: .always)
        let encoded = try await JP3DEncoder(configuration: config).encode(volume)
        let decoded = try await JP3DDecoder().decode(encoded.data)

        XCTAssertEqual(decoded.volume.components[0].data, data)
    }

    // MARK: - 2. Contract API-13 (VolumeEncoder, VolumeDecoder, VolumeTranscoder)

    func testVolumeEncoderDecoderLosslessContractRoundTrip() async throws {
        let volume = makeSignedCTVolume(width: 16, height: 16, depth: 4)
        let encoder = try VolumeEncoder()
        let progressEvents = Mutex<[ProgressUpdate]>([])

        let encoded = try await encoder.encode(
            volume,
            options: VolumeEncodeOptions(
                progress: { event in
                    progressEvents.withLock { $0.append(event) }
                }
            )
        )

        XCTAssertEqual(encoded.width, 16)
        XCTAssertEqual(encoded.height, 16)
        XCTAssertEqual(encoded.depth, 4)
        XCTAssertEqual(encoded.componentCount, 1)
        XCTAssertTrue(encoded.isLossless)
        XCTAssertEqual(encoded.report.fidelity, .exactSamples)
        XCTAssertGreaterThan(progressEvents.withLock { $0.count }, 0)

        let decoder = try VolumeDecoder()
        let inspected = try decoder.inspect(encoded.data)
        XCTAssertEqual(inspected.width, 16)
        XCTAssertEqual(inspected.height, 16)
        XCTAssertEqual(inspected.depth, 4)
        XCTAssertEqual(inspected.bitDepth, 16)
        XCTAssertTrue(inspected.signed)
        XCTAssertTrue(inspected.isLossless)

        let decoded = try await decoder.decode(encoded.data)
        XCTAssertFalse(decoded.isPartial)
        XCTAssertEqual(decoded.report.fidelity, .exactSamples)
        XCTAssertEqual(decoded.volume.components[0].data, volume.components[0].data)
    }

    func testVolumeDecoderROISubRegionViaContractOptions() async throws {
        let volume = makeSignedCTVolume(width: 16, height: 16, depth: 6)
        let encoded = try await VolumeEncoder().encode(volume)

        let region = JP3DRegion(x: 4..<12, y: 4..<12, z: 2..<5)
        let decoded = try await VolumeDecoder().decode(
            encoded.data,
            options: VolumeDecodeOptions(regionOfInterest: region)
        )

        XCTAssertEqual(decoded.volume.width, 8)
        XCTAssertEqual(decoded.volume.height, 8)
        XCTAssertEqual(decoded.volume.depth, 3)
        XCTAssertFalse(decoded.isPartial)
    }

    func testVolumeTranscoderForwardAndReverse() async throws {
        let volume = makeSignedCTVolume(width: 8, height: 8, depth: 4)
        let encoded = try await VolumeEncoder().encode(volume)
        let decoder = try VolumeDecoder()
        let initialInfo = try decoder.inspect(encoded.data)
        XCTAssertFalse(initialInfo.isHTJ2K)

        let transcoder = try VolumeTranscoder()
        let htEncoded = try await transcoder.transcode(
            encoded.data,
            to: .htj2k
        )
        let htInfo = try decoder.inspect(htEncoded.data)
        XCTAssertTrue(htInfo.isHTJ2K)
        XCTAssertTrue(htInfo.signed)

        let backToStandard = try await transcoder.transcode(
            htEncoded.data,
            to: .jpeg2000
        )
        let stdInfo = try decoder.inspect(backToStandard.data)
        XCTAssertFalse(stdInfo.isHTJ2K)

        let decoded = try await decoder.decode(backToStandard.data)
        XCTAssertEqual(decoded.volume.components[0].data, volume.components[0].data)
    }

    func testVolumeResourceLimitsRejectsOversizedVolume() async throws {
        let volume = makeSignedCTVolume(width: 16, height: 16, depth: 4)
        let strictLimits = try ResourceLimits(maximumDimension: 8)
        let encoder = try VolumeEncoder()

        do {
            _ = try await encoder.encode(
                volume,
                options: VolumeEncodeOptions(resourceLimits: strictLimits)
            )
            XCTFail("Expected resource limit error for width > maximumDimension")
        } catch let error as CodecError {
            guard case .resourceLimitExceeded = error.category else {
                XCTFail("Expected resourceLimitExceeded, got \(error)")
                return
            }
        }
    }

    // MARK: - 3. DICOMKit Consumer Surface Compatibility Gate

    func testDICOMKitJP3DConsumerSurfaceCompatibility() async throws {
        // Exercises the exact J2KVolume, J2KVolumeComponent, JP3DCompressionMode,
        // JP3DEncoderConfiguration, JP3DEncoder, and JP3DDecoder calls made by
        // DICOMCore/JP3DCodec.swift, DICOMKit/JP3DVolumeBridge.swift, and
        // DICOMKit/JP3DVolumeDocument.swift.
        let cols = 16, rows = 16, frames = 4
        let bitsStored = 12
        let isSigned = false
        var voxelData = Data(capacity: cols * rows * frames * 2)
        for f in 0..<frames {
            for r in 0..<rows {
                for c in 0..<cols {
                    var le = UInt16((f * 256 + r * 16 + c) & 0x0FFF).littleEndian
                    voxelData.append(Data(bytes: &le, count: 2))
                }
            }
        }

        let component = J2KVolumeComponent(
            index: 0,
            bitDepth: bitsStored,
            signed: isSigned,
            width: cols,
            height: rows,
            depth: frames,
            data: voxelData
        )
        let volume = J2KVolume(
            width: cols,
            height: rows,
            depth: frames,
            components: [component],
            spacingX: 0.75,
            spacingY: 0.5,
            spacingZ: 2.0,
            originX: 10.0,
            originY: -100.0,
            originZ: 50.0
        )

        XCTAssertEqual(volume.width, cols)
        XCTAssertEqual(volume.height, rows)
        XCTAssertEqual(volume.depth, frames)
        XCTAssertEqual(volume.spacingX, 0.75)
        XCTAssertEqual(volume.spacingY, 0.5)
        XCTAssertEqual(volume.spacingZ, 2.0)
        XCTAssertEqual(volume.originX, 10.0)
        XCTAssertEqual(volume.originY, -100.0)
        XCTAssertEqual(volume.originZ, 50.0)

        let modes: [JP3DCompressionMode] = [
            .lossless,
            .losslessHTJ2K,
            .lossy(psnr: 40.0),
            .lossyHTJ2K(psnr: 40.0)
        ]

        for mode in modes {
            let isLossless: Bool
            switch mode {
            case .lossless, .losslessHTJ2K: isLossless = true
            default: isLossless = false
            }
            let config = JP3DEncoderConfiguration(
                compressionMode: mode,
                tiling: .default,
                progressionOrder: .lrcps,
                qualityLayers: isLossless ? 1 : 3,
                levelsX: 3,
                levelsY: 3,
                levelsZ: 1
            )
            let encoder = JP3DEncoder(configuration: config)
            let result = try await encoder.encode(volume)
            XCTAssertFalse(result.data.isEmpty)

            let decoder = JP3DDecoder()
            let decoded = try await decoder.decode(result.data)
            XCTAssertEqual(decoded.volume.width, cols)
            XCTAssertEqual(decoded.volume.height, rows)
            XCTAssertEqual(decoded.volume.depth, frames)
            if isLossless {
                XCTAssertEqual(decoded.volume.components.first?.data, voxelData)
            }
        }
    }
}
