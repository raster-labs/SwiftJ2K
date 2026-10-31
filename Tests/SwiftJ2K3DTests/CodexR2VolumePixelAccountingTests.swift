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

    @Test("Full tile workspace and truthful pixel allocations are reported when the reduced result has only two voxels", arguments: [1, 2])
    func reducedVolumeCountsBridgeBuffers(workers: Int) async throws {
        let limits = try ResourceLimits(maximumWorkers: workers)
        let encoding = try encoder()
        let encodeRecorder = StorageTelemetry.Recorder()
        let encoded = try await StorageTelemetry.$recorder.withValue(encodeRecorder) {
            try await encoding.encode(volume(), options: VolumeEncodeOptions(
                resourceLimits: limits, executionPolicy: .scalarCPU, copyPolicy: .allowCopy))
        }
        let expectedVolumeBytes: Int = 64 * 64 * 2
        // Native Part 10 3D encoding extracts tile Int64 workspaces directly without 2D OwnedImage bridge allocations.
        #expect(encodeRecorder.counts.pixelAllocations == 0)
        #expect(encoded.report.pixelAllocationCount == 0)
        #expect(encoded.report.peakPixelBytes == expectedVolumeBytes)
        #expect(encoded.report.copyEvents.count == 1)
        #expect(encoded.report.copyEvents[0].sourceLayout == "j2kvolume-component-data")
        #expect(encoded.report.copyEvents[0].bytesMoved == expectedVolumeBytes)
        let encWorkspace = try #require(encoded.report.peakWorkspaceBytes)
        #expect(encWorkspace >= 64 * 64 * MemoryLayout<Int64>.stride)

        let decoding = try VolumeDecoder(configuration: VolumeDecoderConfiguration(resolutionLevel: 6))
        let decodeRecorder = StorageTelemetry.Recorder()
        let decoded = try await StorageTelemetry.$recorder.withValue(decodeRecorder) {
            try await decoding.decode(encoded.data, options: VolumeDecodeOptions(
                resourceLimits: limits, executionPolicy: .scalarCPU, copyPolicy: .allowCopy))
        }
        #expect(decoded.volume.width == 1 && decoded.volume.height == 1 && decoded.volume.depth == 2)
        // Native Part 10 3D decoding allocates only the 1 output component buffer (2 bytes) while charging
        // the full 64x64x1 Int64 3D tile reconstruction workspace in peakWorkspaceBytes.
        #expect(decodeRecorder.counts.pixelAllocations == 1)
        #expect(decoded.report.pixelAllocationCount == 1)
        #expect(decoded.report.peakPixelBytes == 2)
        let decWorkspace = try #require(decoded.report.peakWorkspaceBytes)
        #expect(decWorkspace >= 64 * 64 * MemoryLayout<Int64>.stride)
        #expect(decoded.report.copyEvents.count == 1)
        #expect(decoded.report.copyEvents[0].destinationLayout == "j2kvolume-component-data")
        #expect(decoded.report.copyEvents[0].bytesMoved == 2)
    }

    @Test("Lossy transcode reports intermediate volume allocation and reserves the retained source")
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
        let expectedVolumeBytes: Int = 64 * 64 * 2
        // Native Part 10 lossy fallback materialises one intermediate 1-component J2KVolume buffer.
        #expect(recorder.counts.pixelAllocations == 1)
        #expect(result.report.pixelAllocationCount == 1)
        #expect(result.report.peakPixelBytes == expectedVolumeBytes)
        #expect(result.report.copyEvents.count == 1)
        #expect(result.report.copyEvents[0].bytesMoved == expectedVolumeBytes * 2)
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
