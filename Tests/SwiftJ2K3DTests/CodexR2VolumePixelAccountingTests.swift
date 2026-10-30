// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2K3D

@Suite("Codex R2 volume bridge pixel accounting")
struct CodexR2VolumePixelAccountingTests {
    private func volume() -> J2KVolume {
        let component = J2KVolumeComponent(index: 0, bitDepth: 8, signed: false,
            width: 64, height: 64, depth: 2, data: Data(repeating: 0, count: 64 * 64 * 2))
        return J2KVolume(width: 64, height: 64, depth: 2, components: [component])
    }

    private func encoder(lossy: Bool = false) throws -> VolumeEncoder {
        try VolumeEncoder(configuration: VolumeEncoderConfiguration(
            compressionMode: lossy ? .lossy(psnr: 38) : .lossless,
            tiling: JP3DTilingConfiguration(tileSizeX: 64, tileSizeY: 64, tileSizeZ: 1),
            levelsX: 1, levelsY: 1, levelsZ: 0
        ))
    }

    @Test("Full slice pixels remain counted when the result has only two voxels", arguments: [1, 2])
    func reducedVolumeCountsBridgeBuffers(workers: Int) async throws {
        let limits = try ResourceLimits(maximumWorkers: workers)
        let encoding = try encoder()
        let encodeRecorder = StorageTelemetry.Recorder()
        let encoded = try await StorageTelemetry.$recorder.withValue(encodeRecorder) {
            try await encoding.encode(volume(), options: VolumeEncodeOptions(
                resourceLimits: limits, executionPolicy: .scalarCPU, copyPolicy: .allowCopy))
        }
        // Two complete 8-bit slices each allocate packed pixels and an owned image.
        #expect(encodeRecorder.counts.pixelAllocations == 4)
        #expect(encoded.report.pixelAllocationCount == encodeRecorder.counts.pixelAllocations)
        #expect(encoded.report.peakPixelBytes == nil)
        #expect(encoded.report.copyEvents.filter { $0.sourceLayout == "int32-slice-samples" }
            .reduce(0) { $0 + $1.bytesMoved } == 64 * 64 * 2)
        #expect(encoded.report.copyEvents.filter { $0.sourceLayout == "packed-slice-pixels" }
            .reduce(0) { $0 + $1.bytesMoved } == 64 * 64 * 2)

        let decoding = try VolumeDecoder(configuration: VolumeDecoderConfiguration(resolutionLevel: 6))
        let decodeRecorder = StorageTelemetry.Recorder()
        let decoded = try await StorageTelemetry.$recorder.withValue(decodeRecorder) {
            try await decoding.decode(encoded.data, options: VolumeDecodeOptions(
                resourceLimits: limits, executionPolicy: .scalarCPU, copyPolicy: .allowCopy))
        }
        #expect(decoded.volume.width == 1 && decoded.volume.height == 1 && decoded.volume.depth == 2)
        // Each 2D decoder materialises a full 16-bit mono slice before reduction.
        #expect(decodeRecorder.events.filter { $0.stage == "pixel" && $0.bytes == 64 * 64 * 2 }.count == 2)
        #expect(decodeRecorder.counts.pixelAllocations == 3)
        #expect(decoded.report.pixelAllocationCount == decodeRecorder.counts.pixelAllocations)
        // The exact simultaneous peak is intentionally unknown, never claimed as two bytes.
        #expect(decoded.report.peakPixelBytes == nil)
        #expect(decoded.report.copyEvents.filter { $0.sourceLayout == "image-destination" }
            .reduce(0) { $0 + $1.bytesMoved } == 64 * 64 * 2 * MemoryLayout<Int32>.stride)
        #expect(decoded.report.copyEvents.filter { $0.destinationLayout == "j2kvolume-component-data" }
            .reduce(0) { $0 + $1.bytesMoved } == 2)
    }

    @Test("Lossy transcode reports both bridge directions and reserves the retained source")
    func lossyFallbackKeepsOuterBuffersCharged() async throws {
        let limits = try ResourceLimits(maximumWorkers: 1)
        let data = try await encoder(lossy: true).encode(volume(), options: VolumeEncodeOptions(
            resourceLimits: limits, executionPolicy: .scalarCPU)).data
        let transcoder = try VolumeTranscoder()
        let recorder = StorageTelemetry.Recorder()
        let result = try await StorageTelemetry.$recorder.withValue(recorder) {
            try await transcoder.transcode(data, to: .htj2k, options: TranscodeOptions(
                resourceLimits: limits, executionPolicy: .scalarCPU, copyPolicy: .allowCopy))
        }
        // Two decoder destinations, one intermediate volume, four encoder pixel buffers.
        #expect(recorder.counts.pixelAllocations == 7)
        #expect(result.report.pixelAllocationCount == recorder.counts.pixelAllocations)
        #expect(result.report.peakPixelBytes == nil)
        #expect(result.report.copyEvents.count == 4)
        #expect(result.report.copyEvents.filter { $0.sourceLayout == "image-destination" }
            .reduce(0) { $0 + $1.bytesMoved } == 64 * 64 * 2 * MemoryLayout<Int32>.stride)
        let peak = try #require(result.report.peakWorkspaceBytes)
        for limits in [
            try ResourceLimits(maximumWorkspaceBytes: peak - 1, maximumWorkers: 1),
            try ResourceLimits(maximumWorkers: 1, maximumMemoryBytes: data.count + 64 * 64 * 2 + peak - 1)
        ] {
            do {
                _ = try await transcoder.transcode(data, to: .htj2k, options: TranscodeOptions(
                    resourceLimits: limits, executionPolicy: .scalarCPU, copyPolicy: .allowCopy))
                Issue.record("The retained source must remain charged throughout nested decode and encode")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }
        }
    }
}
