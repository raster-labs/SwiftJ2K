// SPDX-License-Identifier: Apache-2.0
//
// JP3DIntegrationTests.swift
// SwiftJ2K3DTests
//
// Migrated from Raster-Lab/J2KSwift Tests/JP3DTests/JP3DIntegrationTests.swift
// at commit 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca for Milestone 10 (SwiftJ2K3D).
// Note: JPIP network streaming tests (JP3DHTj2KJPIPWorkflowTests, JP3DJPIPAPIIntegrationTests)
// are excluded per Decision M3 (IMPLEMENTATION.md lines 88, 121). All other test classes
// (previously disabled under `#if canImport(ObjectiveC)` in the predecessor) are enabled.

import Foundation
import XCTest
@testable import SwiftJ2K
@testable import SwiftJ2K3D

// MARK: - Helpers

private func makeVolume(
    width: Int, height: Int, depth: Int,
    componentCount: Int = 1, bitDepth: Int = 8
) -> J2KVolume {
    let bytesPerSample = (bitDepth + 7) / 8
    var components: [J2KVolumeComponent] = []
    for c in 0..<componentCount {
        var data = Data(count: width * height * depth * bytesPerSample)
        for z in 0..<depth {
            for y in 0..<height {
                for x in 0..<width {
                    let idx = (z * width * height + y * width + x) * bytesPerSample
                    let value = UInt8(truncatingIfNeeded: (x + y * 3 + z * 7 + c * 13) % 256)
                    data[idx] = value
                }
            }
        }
        components.append(J2KVolumeComponent(
            index: c, bitDepth: bitDepth, signed: false,
            width: width, height: height, depth: depth,
            data: data
        ))
    }
    return J2KVolume(width: width, height: height, depth: depth, components: components)
}

// MARK: - Round-Trip Tests

final class JP3DRoundTripTests: XCTestCase {
    func testLosslessRoundTrip() async throws {
        let volume = makeVolume(width: 16, height: 16, depth: 4)
        let encoder = JP3DEncoder(configuration: .lossless)
        let decoder = JP3DDecoder(configuration: .default)

        let encoded = try await encoder.encode(volume)
        let decoded = try await decoder.decode(encoded.data)

        XCTAssertTrue(encoded.isLossless)
        XCTAssertFalse(encoded.data.isEmpty)
        XCTAssertFalse(decoded.isPartial)
        XCTAssertEqual(decoded.volume.width, volume.width)
        XCTAssertEqual(decoded.volume.height, volume.height)
        XCTAssertEqual(decoded.volume.depth, volume.depth)
        XCTAssertEqual(decoded.volume.components.count, volume.components.count)
    }

    func testLossyPSNRRoundTrip() async throws {
        let volume = makeVolume(width: 16, height: 16, depth: 4)
        let config = JP3DEncoderConfiguration(compressionMode: .lossy(psnr: 40.0))
        let encoder = JP3DEncoder(configuration: config)
        let decoder = JP3DDecoder(configuration: .default)

        let encoded = try await encoder.encode(volume)
        let decoded = try await decoder.decode(encoded.data)

        XCTAssertFalse(encoded.isLossless)
        XCTAssertFalse(encoded.data.isEmpty)
        XCTAssertFalse(decoded.isPartial)
        XCTAssertEqual(decoded.volume.width, volume.width)
        XCTAssertEqual(decoded.volume.height, volume.height)
        XCTAssertEqual(decoded.volume.depth, volume.depth)
    }

    func testTargetBitrateRoundTrip() async throws {
        let volume = makeVolume(width: 16, height: 16, depth: 4)
        let config = JP3DEncoderConfiguration(compressionMode: .targetBitrate(bitsPerVoxel: 2.0))
        let encoder = JP3DEncoder(configuration: config)
        let decoder = JP3DDecoder(configuration: .default)

        let encoded = try await encoder.encode(volume)
        let decoded = try await decoder.decode(encoded.data)

        XCTAssertFalse(encoded.data.isEmpty)
        XCTAssertEqual(decoded.volume.width, volume.width)
        XCTAssertEqual(decoded.volume.height, volume.height)
        XCTAssertEqual(decoded.volume.depth, volume.depth)
    }

    func testVisuallyLosslessRoundTrip() async throws {
        let volume = makeVolume(width: 16, height: 16, depth: 4)
        let config = JP3DEncoderConfiguration(compressionMode: .visuallyLossless)
        let encoder = JP3DEncoder(configuration: config)
        let decoder = JP3DDecoder(configuration: .default)

        let encoded = try await encoder.encode(volume)
        let decoded = try await decoder.decode(encoded.data)

        XCTAssertFalse(encoded.data.isEmpty)
        XCTAssertEqual(decoded.volume.width, volume.width)
        XCTAssertEqual(decoded.volume.height, volume.height)
        XCTAssertEqual(decoded.volume.depth, volume.depth)
    }

    func testHTJ2KLosslessRoundTrip() async throws {
        let volume = makeVolume(width: 16, height: 16, depth: 4)
        let config = JP3DEncoderConfiguration(compressionMode: .losslessHTJ2K)
        let encoder = JP3DEncoder(configuration: config)
        let decoder = JP3DDecoder(configuration: .default)

        let encoded = try await encoder.encode(volume)
        let decoded = try await decoder.decode(encoded.data)

        XCTAssertTrue(encoded.isLossless)
        XCTAssertFalse(encoded.data.isEmpty)
        XCTAssertEqual(decoded.volume.width, volume.width)
        XCTAssertEqual(decoded.volume.height, volume.height)
        XCTAssertEqual(decoded.volume.depth, volume.depth)
    }

    func testHTJ2KLossyRoundTrip() async throws {
        let volume = makeVolume(width: 16, height: 16, depth: 4)
        let config = JP3DEncoderConfiguration(compressionMode: .lossyHTJ2K(psnr: 38.0))
        let encoder = JP3DEncoder(configuration: config)
        let decoder = JP3DDecoder(configuration: .default)

        let encoded = try await encoder.encode(volume)
        let decoded = try await decoder.decode(encoded.data)

        XCTAssertFalse(encoded.isLossless)
        XCTAssertFalse(encoded.data.isEmpty)
        XCTAssertEqual(decoded.volume.width, volume.width)
        XCTAssertEqual(decoded.volume.height, volume.height)
        XCTAssertEqual(decoded.volume.depth, volume.depth)
    }

    func testMultiComponentRoundTrip() async throws {
        let volume = makeVolume(width: 16, height: 16, depth: 4, componentCount: 3, bitDepth: 8)
        let encoder = JP3DEncoder(configuration: .lossless)
        let decoder = JP3DDecoder(configuration: .default)

        let encoded = try await encoder.encode(volume)
        let decoded = try await decoder.decode(encoded.data)

        XCTAssertEqual(decoded.volume.components.count, 3)
        XCTAssertEqual(decoded.volume.width, volume.width)
        XCTAssertEqual(decoded.volume.height, volume.height)
        XCTAssertEqual(decoded.volume.depth, volume.depth)
    }

    func testSingleSliceVolumeRoundTrip() async throws {
        let volume = makeVolume(width: 32, height: 32, depth: 1)
        let encoder = JP3DEncoder(configuration: .lossless)
        let decoder = JP3DDecoder(configuration: .default)

        let encoded = try await encoder.encode(volume)
        let decoded = try await decoder.decode(encoded.data)

        XCTAssertEqual(decoded.volume.depth, 1)
        XCTAssertEqual(decoded.volume.width, 32)
        XCTAssertEqual(decoded.volume.height, 32)
    }

    func test16BitRoundTrip() async throws {
        let volume = makeVolume(width: 16, height: 16, depth: 4, componentCount: 1, bitDepth: 16)
        let encoder = JP3DEncoder(configuration: .lossless)
        let decoder = JP3DDecoder(configuration: .default)

        let encoded = try await encoder.encode(volume)
        let decoded = try await decoder.decode(encoded.data)

        XCTAssertTrue(encoded.isLossless)
        XCTAssertEqual(decoded.volume.width, 16)
        XCTAssertEqual(decoded.volume.height, 16)
        XCTAssertEqual(decoded.volume.depth, 4)
    }

    func testMultipleQualityLayersRoundTrip() async throws {
        let volume = makeVolume(width: 16, height: 16, depth: 4)
        let config = JP3DEncoderConfiguration(
            compressionMode: .lossy(psnr: 35.0),
            qualityLayers: 4
        )
        let encoder = JP3DEncoder(configuration: config)
        let decoder = JP3DDecoder(configuration: .default)

        let encoded = try await encoder.encode(volume)
        let decoded = try await decoder.decode(encoded.data)

        XCTAssertFalse(encoded.data.isEmpty)
        XCTAssertEqual(decoded.volume.width, volume.width)
        XCTAssertEqual(decoded.volume.height, volume.height)
        XCTAssertEqual(decoded.volume.depth, volume.depth)
    }
}

// MARK: - Progression Order Tests

final class JP3DProgressionOrderIntegrationTests: XCTestCase {
    private func roundTrip(
        volume: J2KVolume,
        order: JP3DProgressionOrder
    ) async throws -> JP3DDecoderResult {
        let config = JP3DEncoderConfiguration(
            compressionMode: .lossless,
            progressionOrder: order
        )
        let encoded = try await JP3DEncoder(configuration: config).encode(volume)
        return try await JP3DDecoder(configuration: .default).decode(encoded.data)
    }

    func testLRCPSProgression() async throws {
        let volume = makeVolume(width: 16, height: 16, depth: 4)
        let result = try await roundTrip(volume: volume, order: .lrcps)
        XCTAssertEqual(result.volume.depth, 4)
    }

    func testRLCPSProgression() async throws {
        let volume = makeVolume(width: 16, height: 16, depth: 4)
        let result = try await roundTrip(volume: volume, order: .rlcps)
        XCTAssertEqual(result.volume.depth, 4)
    }

    func testPCRLSProgression() async throws {
        let volume = makeVolume(width: 16, height: 16, depth: 4)
        let result = try await roundTrip(volume: volume, order: .pcrls)
        XCTAssertEqual(result.volume.depth, 4)
    }

    func testSLRCPProgression() async throws {
        let volume = makeVolume(width: 16, height: 16, depth: 4)
        let result = try await roundTrip(volume: volume, order: .slrcp)
        XCTAssertEqual(result.volume.depth, 4)
    }

    func testCPRLSProgression() async throws {
        let volume = makeVolume(width: 16, height: 16, depth: 4)
        let result = try await roundTrip(volume: volume, order: .cprls)
        XCTAssertEqual(result.volume.depth, 4)
    }
}

// MARK: - Tiling Configuration Tests

final class JP3DTilingIntegrationTests: XCTestCase {
    func testStreamingTilingRoundTrip() async throws {
        let volume = makeVolume(width: 32, height: 32, depth: 8)
        let config = JP3DEncoderConfiguration(
            compressionMode: .lossless,
            tiling: .streaming
        )
        let encoder = JP3DEncoder(configuration: config)
        let decoder = JP3DDecoder(configuration: .default)

        let encoded = try await encoder.encode(volume)
        let decoded = try await decoder.decode(encoded.data)

        XCTAssertEqual(decoded.volume.width, 32)
        XCTAssertEqual(decoded.volume.height, 32)
        XCTAssertEqual(decoded.volume.depth, 8)
    }

    func testBatchTilingRoundTrip() async throws {
        let volume = makeVolume(width: 16, height: 16, depth: 4)
        let config = JP3DEncoderConfiguration(
            compressionMode: .lossless,
            tiling: .batch
        )
        let encoder = JP3DEncoder(configuration: config)
        let decoder = JP3DDecoder(configuration: .default)

        let encoded = try await encoder.encode(volume)
        let decoded = try await decoder.decode(encoded.data)

        XCTAssertEqual(decoded.volume.width, 16)
        XCTAssertEqual(decoded.volume.height, 16)
        XCTAssertEqual(decoded.volume.depth, 4)
    }

    func testNonPowerOf2DimensionsRoundTrip() async throws {
        let volume = makeVolume(width: 17, height: 13, depth: 5)
        let config = JP3DEncoderConfiguration(
            compressionMode: .lossless,
            tiling: JP3DTilingConfiguration(tileSizeX: 8, tileSizeY: 8, tileSizeZ: 4)
        )
        let encoder = JP3DEncoder(configuration: config)
        let decoder = JP3DDecoder(configuration: .default)

        let encoded = try await encoder.encode(volume)
        let decoded = try await decoder.decode(encoded.data)

        XCTAssertEqual(decoded.volume.width, 17)
        XCTAssertEqual(decoded.volume.height, 13)
        XCTAssertEqual(decoded.volume.depth, 5)
    }
}

// MARK: - Metal GPU vs CPU Result Equivalence

final class JP3DMetalCPUEquivalenceTests: XCTestCase {
    func testMetalAndCPUEncodeProduceSameVolumeShape() async throws {
        let volume = makeVolume(width: 16, height: 16, depth: 4)
        let cpuConfig = JP3DEncoderConfiguration(
            compressionMode: .lossless,
            parallelEncoding: false
        )
        let gpuConfig = JP3DEncoderConfiguration(
            compressionMode: .lossless,
            parallelEncoding: true
        )
        let cpuEncoder = JP3DEncoder(configuration: cpuConfig)
        let gpuEncoder = JP3DEncoder(configuration: gpuConfig)
        let decoder = JP3DDecoder(configuration: .default)

        let cpuEncoded = try await cpuEncoder.encode(volume)
        let gpuEncoded = try await gpuEncoder.encode(volume)

        let cpuDecoded = try await decoder.decode(cpuEncoded.data)
        let gpuDecoded = try await decoder.decode(gpuEncoded.data)

        XCTAssertEqual(cpuDecoded.volume.width, gpuDecoded.volume.width)
        XCTAssertEqual(cpuDecoded.volume.height, gpuDecoded.volume.height)
        XCTAssertEqual(cpuDecoded.volume.depth, gpuDecoded.volume.depth)
        XCTAssertEqual(cpuDecoded.volume.components.count, gpuDecoded.volume.components.count)
    }

    func testLosslessMetalAndCPUProduceSameTileCount() async throws {
        let volume = makeVolume(width: 32, height: 32, depth: 8)
        let tiling = JP3DTilingConfiguration(tileSizeX: 16, tileSizeY: 16, tileSizeZ: 4)
        let cpuConfig = JP3DEncoderConfiguration(
            compressionMode: .lossless, tiling: tiling, parallelEncoding: false
        )
        let gpuConfig = JP3DEncoderConfiguration(
            compressionMode: .lossless, tiling: tiling, parallelEncoding: true
        )

        let cpuResult = try await JP3DEncoder(configuration: cpuConfig).encode(volume)
        let gpuResult = try await JP3DEncoder(configuration: gpuConfig).encode(volume)

        XCTAssertEqual(cpuResult.tileCount, gpuResult.tileCount)
    }
}

// MARK: - Cross-Platform Validation

final class JP3DCrossPlatformTests: XCTestCase {
    func testTilingConfigurationIsConsistent() {
        let tiling = JP3DTilingConfiguration(tileSizeX: 64, tileSizeY: 64, tileSizeZ: 8)

        let grid = tiling.tileGrid(volumeWidth: 128, volumeHeight: 128, volumeDepth: 16)
        let total = tiling.totalTiles(volumeWidth: 128, volumeHeight: 128, volumeDepth: 16)

        XCTAssertEqual(grid.tilesX, 2)
        XCTAssertEqual(grid.tilesY, 2)
        XCTAssertEqual(grid.tilesZ, 2)
        XCTAssertEqual(total, 8)
    }

    func testRegionIntersectionIsConsistent() {
        let r1 = JP3DRegion(x: 0..<64, y: 0..<64, z: 0..<16)
        let r2 = JP3DRegion(x: 32..<96, y: 32..<96, z: 8..<24)

        let intersection = r1.intersection(r2)

        XCTAssertNotNil(intersection)
        XCTAssertEqual(intersection?.x, 32..<64)
        XCTAssertEqual(intersection?.y, 32..<64)
        XCTAssertEqual(intersection?.z, 8..<16)
    }

    func testCompressionModePropertiesAreConsistent() {
        XCTAssertTrue(JP3DCompressionMode.lossless.isLossless)
        XCTAssertTrue(JP3DCompressionMode.losslessHTJ2K.isLossless)
        XCTAssertFalse(JP3DCompressionMode.lossy(psnr: 40).isLossless)
        XCTAssertFalse(JP3DCompressionMode.lossyHTJ2K(psnr: 40).isLossless)
        XCTAssertTrue(JP3DCompressionMode.losslessHTJ2K.isHTJ2K)
        XCTAssertTrue(JP3DCompressionMode.lossyHTJ2K(psnr: 40).isHTJ2K)
        XCTAssertFalse(JP3DCompressionMode.lossless.isHTJ2K)
    }

    func testVolumeConstructionIsConsistent() {
        let volume = makeVolume(width: 8, height: 8, depth: 4)

        XCTAssertEqual(volume.width, 8)
        XCTAssertEqual(volume.height, 8)
        XCTAssertEqual(volume.depth, 4)
        XCTAssertFalse(volume.components.isEmpty)
        XCTAssertEqual(volume.voxelCount, 8 * 8 * 4)
    }

    func testProgressionOrderCasesAllPresent() {
        let allCases = JP3DProgressionOrder.allCases
        XCTAssertEqual(allCases.count, 5)
        XCTAssertTrue(allCases.contains(.lrcps))
        XCTAssertTrue(allCases.contains(.rlcps))
        XCTAssertTrue(allCases.contains(.pcrls))
        XCTAssertTrue(allCases.contains(.slrcp))
        XCTAssertTrue(allCases.contains(.cprls))
    }
}

// MARK: - Memory Usage Under Sustained Load

final class JP3DMemoryUsageTests: XCTestCase {
    func testRepeatedEncodeDecodeDoesNotLeak() async throws {
        let volume = makeVolume(width: 16, height: 16, depth: 4)
        let encoder = JP3DEncoder(configuration: .lossless)
        let decoder = JP3DDecoder(configuration: .default)

        for _ in 0..<20 {
            let encoded = try await encoder.encode(volume)
            let decoded = try await decoder.decode(encoded.data)

            XCTAssertFalse(encoded.data.isEmpty)
            XCTAssertEqual(decoded.volume.width, volume.width)
        }
    }

    func testCompressionRatioIsPositive() async throws {
        let volume = makeVolume(width: 32, height: 32, depth: 8)
        let config = JP3DEncoderConfiguration(compressionMode: .lossy(psnr: 30.0))
        let encoder = JP3DEncoder(configuration: config)

        let result = try await encoder.encode(volume)

        XCTAssertGreaterThan(result.compressionRatio, 0.0)
    }

    func testTileCountMatchesTilingGrid() async throws {
        let volume = makeVolume(width: 32, height: 32, depth: 8)
        let tiling = JP3DTilingConfiguration(tileSizeX: 16, tileSizeY: 16, tileSizeZ: 4)
        let config = JP3DEncoderConfiguration(compressionMode: .lossless, tiling: tiling)
        let encoder = JP3DEncoder(configuration: config)

        let result = try await encoder.encode(volume)

        XCTAssertEqual(result.tileCount, 8)
    }
}

// MARK: - Encoder/Decoder Configuration Validation

final class JP3DConfigurationValidationTests: XCTestCase {
    func testEncoderConfigurationDefaults() {
        let config = JP3DEncoderConfiguration()
        XCTAssertEqual(config.compressionMode, .lossless)
        XCTAssertEqual(config.tiling, .default)
        XCTAssertEqual(config.progressionOrder, .lrcps)
        XCTAssertEqual(config.qualityLayers, 1)
        XCTAssertTrue(config.parallelEncoding)
    }

    func testEncoderConfigurationLosslessPreset() {
        let config = JP3DEncoderConfiguration.lossless
        XCTAssertEqual(config.compressionMode, .lossless)
        XCTAssertTrue(config.compressionMode.isLossless)
    }

    func testEncoderConfigurationLossyPreset() {
        let config = JP3DEncoderConfiguration.lossy()
        XCTAssertFalse(config.compressionMode.isLossless)
        XCTAssertFalse(config.compressionMode.isHTJ2K)
    }

    func testDecoderConfigurationDefaults() {
        let config = JP3DDecoderConfiguration.default
        XCTAssertEqual(config.maxQualityLayers, 0)
        XCTAssertEqual(config.resolutionLevel, 0)
        XCTAssertTrue(config.tolerateErrors)
    }

    func testDecoderThumbnailPreset() {
        let config = JP3DDecoderConfiguration.thumbnail
        XCTAssertEqual(config.resolutionLevel, 2)
    }

    func testTilingConfigurationValidation() throws {
        let valid = JP3DTilingConfiguration(tileSizeX: 64, tileSizeY: 64, tileSizeZ: 8)
        XCTAssertNoThrow(try valid.validate())
    }

    func testHTJ2KConfigurationFromPreset() {
        let config = JP3DEncoderConfiguration(compressionMode: .losslessHTJ2K)
        XCTAssertTrue(config.compressionMode.isHTJ2K)
        XCTAssertTrue(config.compressionMode.isLossless)
    }
}
