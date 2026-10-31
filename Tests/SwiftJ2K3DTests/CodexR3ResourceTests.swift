// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2K3D

@Suite("Codex R3 live entropy reservations")
struct CodexR3ResourceTests {
    private func twoLayerCOD() -> JP3DCODInfo {
        JP3DCODInfo(levelsX: 0, levelsY: 0, levelsZ: 0, isLossless: true,
            codeBlockStyle: 0, scod: 0, progressionOrderByte: 0, numLayers: 2,
            multipleComponentTransform: 0, codeBlockWidthExponent: 6,
            codeBlockHeightExponent: 6, codeBlockDepthExponent: 2,
            dwtX: 1, dwtY: 1, dwtZ: 1)
    }

    @Test("Continued segments admit growth before mutating a transferred payload owner")
    func continuedSegmentGrowthBoundary() throws {
        let cod = twoLayerCOD()
        let geom = try JP3DGeometryBuilder.makeTileComponentGeometry(
            x0: 0, x1: 1, y0: 0, y1: 1, z0: 0, z1: 1, cod: cod)
        let firstLength = 1 << 20
        var first = PacketBitWriter()
        first.writeBit(true) // packet present
        first.writeBit(true) // first inclusion at layer 0
        first.writeBit(true) // zero bit-planes
        first.writeBit(false) // one pass
        for _ in 3..<21 { first.writeBit(true) }
        first.writeBit(false) // Lblock is now 21
        first.writeBits(firstLength, count: 21)
        var packets = Data(first.finish())
        packets.append(Data(repeating: 0, count: firstLength))
        var second = PacketBitWriter()
        second.writeBit(true)
        second.writeBit(true) // already included
        second.writeBit(false) // one additional unterminated pass
        second.writeBit(false) // unchanged Lblock
        second.writeBits(1, count: 21)
        packets.append(contentsOf: second.finish())
        packets.append(0x7B)

        var admittedBytes = 0
        let baseline = StorageTelemetry.Recorder()
        let decoded = try StorageTelemetry.$recorder.withValue(baseline) {
            try JP3DTier2Coder.decodePackets(geometries: [geom], cod: cod, data: packets,
                admitWorkspaceBytes: { admittedBytes += $0 }, cancellation: {})
        }
        let segment = try #require(decoded.contributions[0][0][0][0][0].segments.first)
        #expect(segment.data.count == firstLength + 1)
        #expect(segment.data.last == 0x7B)
        #expect(segment.passes == 2)
        #expect(admittedBytes >= 2 * firstLength + 1)
        #expect(baseline.events.filter { $0.stage == "jp3d-segment-buffer-append" }.map(\.bytes)
            == [firstLength, firstLength + 1])

        let denied = StorageTelemetry.Recorder()
        var charged = 0
        do {
            _ = try StorageTelemetry.$recorder.withValue(denied) {
                try JP3DTier2Coder.decodePackets(geometries: [geom], cod: cod, data: packets,
                    admitWorkspaceBytes: { delta in
                        guard charged + delta < admittedBytes else {
                            throw CodecError(.resourceLimitExceeded, "Deny continuation growth")
                        }
                        charged += delta
                    }, cancellation: {})
            }
            Issue.record("Expected rejection before the continuation append")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(denied.events.filter { $0.stage == "jp3d-segment-buffer-append" }.map(\.bytes) == [firstLength])
    }

    @Test("Array-input packet parsing admits its Data copy before allocation")
    func arrayForwardingCopyIsAdmitted() throws {
        let cod = twoLayerCOD()
        let geom = try JP3DGeometryBuilder.makeTileComponentGeometry(
            x0: 0, x1: 1, y0: 0, y1: 1, z0: 0, z1: 1, cod: cod)
        let recorder = StorageTelemetry.Recorder()
        do {
            _ = try StorageTelemetry.$recorder.withValue(recorder) {
                try JP3DTier2Coder.decodePackets(geometries: [geom], cod: cod, bytes: [0, 0],
                    admitWorkspaceBytes: { _ in throw CodecError(.resourceLimitExceeded, "Deny input copy") },
                    cancellation: {})
            }
            Issue.record("Expected input-copy admission failure")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(!recorder.events.contains { $0.stage == "jp3d-packet-input-copy" })
    }

    @Test("Packet-header denial occurs before its staging buffer is allocated")
    func deniedPacketHeaderDoesNotAllocate() throws {
        let recorder = EntropyAllocationTelemetry.Recorder()
        let budget = EntropyOutputBudget(
            reserve: { _, _, _ in throw CodecError(.resourceLimitExceeded, "Injected header denial") },
            release: { _, _, _ in })
        EntropyAllocationTelemetry.$recorder.withValue(recorder) {
            var writer = PacketBitWriter(budget: budget)
            for _ in 0..<80 { writer.writeBit(true) }
            #expect(writer.finish().isEmpty)
            #expect(writer.allocationRejected)
            writer.releaseScratch()
        }
        #expect(recorder.events.contains { $0.kind == .reserveRejected && $0.site == "packet-header-grow" })
        #expect(!recorder.events.contains { $0.kind == .bufferAllocated })
    }

    @Test("Entropy capacity is compacted under an overlap reservation before unused bytes are released")
    func entropyFinishRetainsCapacityUntilCompaction() throws {
        let liveBytes = Mutex(0)
        let peakBytes = Mutex(0)
        let budget = EntropyOutputBudget(
            reserve: { bytes, _, _ in
                let live = liveBytes.withLock { value in value += bytes; return value }
                peakBytes.withLock { $0 = max($0, live) }
            },
            release: { bytes, _, _ in liveBytes.withLock { $0 -= bytes } })
        let recorder = EntropyAllocationTelemetry.Recorder()
        EntropyAllocationTelemetry.$recorder.withValue(recorder) {
            var encoder = RawEncoder(maximumOutputBytes: 128, budget: budget)
            for bit in [true, false, true, false, true, false, true, false] { encoder.encode(bit) }
            #expect(liveBytes.withLock { $0 } == 64)
            #expect(encoder.finish() == [0xAA])
            #expect(!encoder.overflowed)
            #expect(liveBytes.withLock { $0 } == 1)
            encoder.releaseAllReservedBudget()
        }
        #expect(peakBytes.withLock { $0 } >= 65)
        #expect(liveBytes.withLock { $0 } == 0)
        let allocation = try #require(recorder.events.first {
            $0.kind == .bufferAllocated && $0.site == "raw-encoder-finish-compact"
        })
        let trim = try #require(recorder.events.first {
            $0.kind == .unusedReleased && $0.bytes == 63
        })
        #expect(allocation.sequence < trim.sequence)
    }

    @Test("A many-layer encoder admits its retained per-block layer arrays before coding")
    func encoderLayerMetadataCannotBypassWorkspaceLimit() async throws {
        let volume = J2KVolume(width: 1, height: 1, depth: 1, components: [
            J2KVolumeComponent(index: 0, bitDepth: 8, signed: false,
                width: 1, height: 1, depth: 1, data: Data([128]))
        ])
        let encoder = try VolumeEncoder(configuration: VolumeEncoderConfiguration(
            compressionMode: .lossless,
            tiling: JP3DTilingConfiguration(tileSizeX: 1, tileSizeY: 1, tileSizeZ: 1),
            qualityLayers: 65_535, levelsX: 0, levelsY: 0, levelsZ: 0))
        let recorder = EntropyAllocationTelemetry.Recorder()
        do {
            _ = try await EntropyAllocationTelemetry.$recorder.withValue(recorder) {
                try await encoder.encode(volume, options: VolumeEncodeOptions(
                    resourceLimits: try ResourceLimits(maximumWorkspaceBytes: 131_072, maximumWorkers: 1)))
            }
            Issue.record("Per-block layer arrays exceed the complete workspace limit")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(!recorder.events.contains { $0.kind == .bufferAllocated })
    }

    @Test("Optional coefficient-transcode verification reports and bounds both decoded volumes")
    func verificationVolumesAreAdmittedAndReported() async throws {
        let pixels = Data((0..<128).map { UInt8(($0 * 73 + 11) & 255) })
        let volume = J2KVolume(width: 8, height: 8, depth: 2, components: [
            J2KVolumeComponent(index: 0, bitDepth: 8, signed: false,
                width: 8, height: 8, depth: 2, data: pixels)
        ])
        let source = try await VolumeEncoder(configuration: VolumeEncoderConfiguration(
            compressionMode: .lossless,
            tiling: JP3DTilingConfiguration(tileSizeX: 8, tileSizeY: 8, tileSizeZ: 2),
            levelsX: 0, levelsY: 0, levelsZ: 0)).encode(volume).data
        let configuration = JP3DTranscoderConfiguration(verifyRoundTrip: true)
        let result = try await JP3DTranscoder().transcode(source, configuration: configuration)
        #expect(!result.usedFullRoundTripCopy)
        #expect(result.roundTripPixelBytes == 256)
        #expect(result.roundTripComponentCount == 2)
        do {
            _ = try await JP3DTranscoder().transcodeAdmitted(source,
                configuration: configuration,
                limits: try ResourceLimits(maximumDecodedBytes: 255),
                executionPolicy: .required(.scalarCPU), work: VolumeWorkGuard(limits: nil))
            Issue.record("Both verification volumes must fit the decoded-byte budget")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
    }
}
