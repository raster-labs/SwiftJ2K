// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2K3D

@Suite("Codex R2 volume grid and coefficient workspace regressions")
struct CodexR2VolumeGridTests {
    private func ramp(width: Int, height: Int, depth: Int, bits: Int = 8) -> J2KVolume {
        var bytes = Data()
        for z in 0..<depth {
            for y in 0..<height {
                for x in 0..<width {
                    let value = UInt32(x + 9 * y + 64 * z) + (bits > 16 ? 0x8000_0000 : 0)
                    for byte in 0..<((bits + 7) / 8) {
                        bytes.append(UInt8(truncatingIfNeeded: value >> (8 * byte)))
                    }
                }
            }
        }
        return J2KVolume(
            width: width, height: height, depth: depth,
            components: [J2KVolumeComponent(index: 0, bitDepth: bits, signed: false,
                width: width, height: height, depth: depth, data: bytes)],
            spacingX: 0.5, spacingY: 0.75, spacingZ: 2,
            originX: -2, originY: 3, originZ: 7
        )
    }

    private func values(_ volume: J2KVolume) -> [UInt32] {
        let component = volume.components[0]
        let bytes = [UInt8](component.data)
        let bytesPerSample = (component.bitDepth + 7) / 8
        return stride(from: 0, to: bytes.count, by: bytesPerSample).map { offset in
            var value: UInt32 = 0
            for byte in 0..<bytesPerSample { value |= UInt32(bytes[offset + byte]) << (8 * byte) }
            return value
        }
    }

    private func encode(_ volume: J2KVolume, tile: Int) async throws -> Data {
        let configuration = try VolumeEncoderConfiguration(
            compressionMode: .lossless,
            tiling: JP3DTilingConfiguration(tileSizeX: tile, tileSizeY: tile, tileSizeZ: 1),
            levelsX: 1, levelsY: 1, levelsZ: 0
        )
        return try await VolumeEncoder(configuration: configuration).encode(
            volume, options: VolumeEncodeOptions(executionPolicy: .scalarCPU)
        ).data
    }

    @Test("Odd dimensions and odd tile origins select one volume-wide grid", arguments: [8, 32])
    func oddTilesUseGlobalGrid(bits: Int) async throws {
        let source = ramp(width: 9, height: 7, depth: 2, bits: bits)
        let data = try await encode(source, tile: 3)
        for level in [1, 2, 4] {
            let step = 1 << level
            let decoder = try VolumeDecoder(configuration: VolumeDecoderConfiguration(resolutionLevel: level))
            let decoded = try await decoder.decode(data, options: VolumeDecodeOptions(executionPolicy: .scalarCPU))
            let xs = Array(stride(from: 0, to: source.width, by: step))
            let ys = Array(stride(from: 0, to: source.height, by: step))
            var expected: [UInt32] = []
            for z in 0..<source.depth {
                for y in ys { for x in xs {
                    expected.append(UInt32(x + 9 * y + 64 * z) + (bits > 16 ? 0x8000_0000 : 0))
                } }
            }
            #expect(decoded.volume.width == xs.count && decoded.volume.height == ys.count)
            #expect(values(decoded.volume) == expected)
            #expect(decoded.volume.originX == source.originX && decoded.volume.originY == source.originY)
            #expect(decoded.volume.spacingX == source.spacingX * Double(step))
            #expect(decoded.volume.spacingY == source.spacingY * Double(step))
            #expect(!decoded.isPartial)
        }
    }

    @Test("Reduced ROI samples, dimensions and origin agree across tile boundaries", arguments: [8, 32])
    func reducedROIUsesSelectedGridOrigin(bits: Int) async throws {
        let source = ramp(width: 9, height: 7, depth: 2, bits: bits)
        let data = try await encode(source, tile: 3)
        let decoder = try VolumeDecoder(configuration: VolumeDecoderConfiguration(resolutionLevel: 1))
        let decoded = try await decoder.decode(data, options: VolumeDecodeOptions(
            executionPolicy: .scalarCPU,
            regionOfInterest: JP3DRegion(x: 1..<8, y: 1..<6, z: 1..<2)
        ))
        // Ceil bounds select x=[2,4,6], y=[2,4], z=[1]. No point before the ROI is returned.
        let expected = [2, 4].flatMap { y in [2, 4, 6].map { x in
            UInt32(x + 9 * y + 64) + (bits > 16 ? 0x8000_0000 : 0)
        } }
        #expect(values(decoded.volume) == expected)
        #expect(decoded.volume.width == 3 && decoded.volume.height == 2 && decoded.volume.depth == 1)
        #expect(decoded.volume.originX == source.originX + 2 * source.spacingX)
        #expect(decoded.volume.originY == source.originY + 2 * source.spacingY)
        #expect(decoded.volume.originZ == source.originZ + source.spacingZ)
        #expect(decoded.volume.spacingX == 2 * source.spacingX)
        #expect(decoded.volume.spacingY == 2 * source.spacingY)
    }

    @Test("A narrow ROI without any point on the reduced grid fails predictably")
    func emptyReducedROIIsDefined() async throws {
        let data = try await encode(ramp(width: 5, height: 5, depth: 1), tile: 3)
        let decoder = try VolumeDecoder(configuration: VolumeDecoderConfiguration(resolutionLevel: 1))
        do {
            _ = try await decoder.decode(data, options: VolumeDecodeOptions(
                executionPolicy: .scalarCPU,
                regionOfInterest: JP3DRegion(x: 1..<2, y: 0..<2, z: 0..<1)
            ))
            Issue.record("Expected a defined error for an ROI containing no reduced-grid sample")
        } catch let error as CodecError {
            #expect(error.category == .invalidArgument)
        }
    }

    @Test("Lossy reduced tiles select the same spatial samples as full reconstruction", arguments: [false, true])
    func lossyGridMatchesFullReconstruction(ht: Bool) async throws {
        let source = ramp(width: 9, height: 7, depth: 2)
        let configuration = try VolumeEncoderConfiguration(
            compressionMode: ht ? .lossyHTJ2K(psnr: 38) : .lossy(psnr: 38),
            tiling: JP3DTilingConfiguration(tileSizeX: 3, tileSizeY: 3, tileSizeZ: 1),
            levelsX: 1, levelsY: 1, levelsZ: 0
        )
        let encoded = try await VolumeEncoder(configuration: configuration).encode(
            source, options: VolumeEncodeOptions(executionPolicy: .scalarCPU)
        )
        let full = try await VolumeDecoder().decode(encoded.data,
            options: VolumeDecodeOptions(executionPolicy: .scalarCPU))
        let decoder = try VolumeDecoder(configuration: VolumeDecoderConfiguration(resolutionLevel: 1))
        let roi = try await decoder.decode(encoded.data, options: VolumeDecodeOptions(
            executionPolicy: .scalarCPU,
            regionOfInterest: JP3DRegion(x: 1..<8, y: 1..<6, z: 1..<2)
        ))
        let samples = values(full.volume)
        let expected = [2, 4].flatMap { y in [2, 4, 6].map { x in samples[63 + y * 9 + x] } }
        #expect(values(roi.volume) == expected)
        #expect(roi.volume.originX == source.originX + 2 * source.spacingX)
        #expect(roi.volume.originY == source.originY + 2 * source.spacingY)
    }

    @Test("The legacy disjoint-ROI partial canvas retains its geometry")
    func disjointROIStillPreservesCanvasGeometry() async throws {
        let source = ramp(width: 5, height: 5, depth: 1)
        let data = try await encode(source, tile: 3)
        let options = VolumeDecodeOptions(executionPolicy: .scalarCPU,
            regionOfInterest: JP3DRegion(x: 6..<7, y: 6..<7, z: 0..<1))
        let decoded = try await VolumeDecoder().decode(data, options: options)
        #expect(decoded.isPartial)
        #expect(decoded.volume.width == source.width && decoded.volume.height == source.height)
        #expect(decoded.volume.originX == source.originX && decoded.volume.originY == source.originY)
        #expect(decoded.volume.spacingX == source.spacingX && decoded.volume.spacingY == source.spacingY)
    }

    @Test("Direct slice reduction uses the requested stride for an odd-sized image")
    func sliceReductionHasExplicitStride() async throws {
        let source = ramp(width: 5, height: 5, depth: 1)
        let data = try await encode(source, tile: 5)
        let parsed = try JP3DCodestreamParser().parse(data)
        let tile = try #require(parsed.tiles.first)
        let decoded = try JP3DSliceStackCodec().decodeTileInteger(
            tile.data, expectedComponents: 1, expectedWidth: 5, expectedHeight: 5,
            expectedDepth: 1, resolutionLevel: 1, executionPolicy: .scalarCPU
        )
        #expect(decoded[0] == [0, 2, 4, 18, 20, 22, 36, 38, 40])
    }

    @Test("Volume transcode reports coefficient workspace even for tiny compressed inputs")
    func coefficientWorkspaceReachesVolumeReport() async throws {
        let width = 128
        let height = 128
        let component = J2KVolumeComponent(index: 0, bitDepth: 8, signed: false,
            width: width, height: height, depth: 2, data: Data(repeating: 0, count: width * height * 2))
        let source = J2KVolume(width: width, height: height, depth: 2, components: [component])
        let data = try await encode(source, tile: 128)
        let transcoder = try VolumeTranscoder()
        let result = try await transcoder.transcode(data, to: .htj2k, options: TranscodeOptions(
            executionPolicy: .scalarCPU, copyPolicy: .requireSharedStorage
        ))
        let peak = try #require(result.report.peakWorkspaceBytes)
        // At least one full Int32 coefficient plane is live, irrespective of compressed size.
        #expect(peak >= width * height * MemoryLayout<Int32>.stride)
        #expect(result.report.pixelAllocationCount == 0 && result.report.copyEvents.isEmpty)
        let decoded = try await VolumeDecoder().decode(result.data,
            options: VolumeDecodeOptions(executionPolicy: .scalarCPU))
        #expect(decoded.volume.components[0].data == component.data)
        let limited = try ResourceLimits(maximumWorkspaceBytes: peak - 1)
        do {
            _ = try await transcoder.transcode(data, to: .htj2k, options: TranscodeOptions(
                resourceLimits: limited, executionPolicy: .scalarCPU, copyPolicy: .requireSharedStorage
            ))
            Issue.record("Reported operation workspace must remain charged during nested slice transcoding")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
    }

    @Test("Reduced lossy decoding charges nested slice buffers", arguments: [false, true])
    func reducedLossyWorkspaceIncludesNestedSlices(useROI: Bool) async throws {
        let source = ramp(width: 64, height: 64, depth: 2)
        let configuration = try VolumeEncoderConfiguration(
            compressionMode: .lossy(psnr: 38),
            tiling: JP3DTilingConfiguration(tileSizeX: 64, tileSizeY: 64, tileSizeZ: 2),
            levelsX: 1, levelsY: 1, levelsZ: 0
        )
        let data = try await VolumeEncoder(configuration: configuration).encode(
            source, options: VolumeEncodeOptions(executionPolicy: .scalarCPU)
        ).data
        let decoder = try VolumeDecoder(configuration: VolumeDecoderConfiguration(resolutionLevel: 1))
        let roi: JP3DRegion? = useROI ? JP3DRegion(x: 1..<63, y: 1..<63, z: 0..<2) : nil
        let result = try await decoder.decode(data, options: VolumeDecodeOptions(
            resourceLimits: try ResourceLimits(maximumWorkers: 1), executionPolicy: .scalarCPU,
            regionOfInterest: roi
        ))
        let peak = try #require(result.report.peakWorkspaceBytes)
        #expect(peak >= 64 * 64 * 2 * (MemoryLayout<Int64>.stride + MemoryLayout<Float>.stride))
        for limits in [
            try ResourceLimits(maximumWorkspaceBytes: peak - 1, maximumWorkers: 1),
            try ResourceLimits(maximumWorkers: 1,
                maximumMemoryBytes: data.count + result.volume.sizeInBytes + peak - 1)
        ] {
            do {
                _ = try await decoder.decode(data, options: VolumeDecodeOptions(
                    resourceLimits: limits, executionPolicy: .scalarCPU, regionOfInterest: roi
                ))
                Issue.record("Nested slice buffers must remain charged during reduced decoding")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }
        }
    }

    @Test("Transcode publication is admitted before allocation and preserves builder bytes", arguments: [false, true])
    func publicationPreflight(hasHTMarkers: Bool) async throws {
        let sourceData = try await encode(ramp(width: 5, height: 3, depth: 2), tile: 3)
        let source = try JP3DCodestreamParser().parse(sourceData)
        let tiles = source.tiles.map(\.data)
        let ht: JP3DHTJ2KConfiguration? = hasHTMarkers ? .default : nil
        let builder = JP3DCodestreamBuilder()
        let expected = builder.build(
            tileData: tiles, width: source.siz.width, height: source.siz.height, depth: source.siz.depth,
            components: source.siz.componentCount, bitDepth: source.siz.bitDepth, signed: source.siz.signed,
            levelsX: source.cod.levelsX, levelsY: source.cod.levelsY, levelsZ: source.cod.levelsZ,
            tileSizeX: source.siz.tileSizeX, tileSizeY: source.siz.tileSizeY, tileSizeZ: source.siz.tileSizeZ,
            isLossless: source.cod.isLossless, htj2kConfiguration: ht, comments: source.comments
        )
        let expectedPeak = source.retainedTileBytes + source.commentPayloadBytes
            + tiles.reduce(0) { $0 + $1.count } + expected.count + MemoryLayout<UInt32>.size
        let deniedLimits = [
            try ResourceLimits(maximumCompressedBytes: expected.count - 1),
            try ResourceLimits(maximumWorkspaceBytes: expectedPeak - 1),
            try ResourceLimits(maximumMemoryBytes: sourceData.count + expectedPeak - 1)
        ]
        for limits in deniedLimits {
            let recorder = StorageTelemetry.Recorder()
            do {
                _ = try StorageTelemetry.$recorder.withValue(recorder) {
                    try builder.buildTranscodePublication(
                        sourceDataBytes: sourceData.count, source: source, tileData: tiles,
                        htj2kConfiguration: ht, comments: source.comments, limits: limits
                    )
                }
                Issue.record("Publication must fail before allocating the output")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }
            #expect(!recorder.events.contains { $0.stage == "volume-transcode-publication" })
        }
        let recorder = StorageTelemetry.Recorder()
        let result = try StorageTelemetry.$recorder.withValue(recorder) {
            try builder.buildTranscodePublication(
                sourceDataBytes: sourceData.count, source: source, tileData: tiles,
                htj2kConfiguration: ht, comments: source.comments,
                limits: try ResourceLimits(maximumCompressedBytes: expected.count,
                    maximumWorkspaceBytes: expectedPeak, maximumMemoryBytes: sourceData.count + expectedPeak)
            )
        }
        #expect(result.data == expected)
        #expect(result.peakWorkspaceBytes == expectedPeak)
        #expect(recorder.events.filter { $0.stage == "volume-transcode-publication" }.map(\.bytes) == [expected.count])
    }
}
