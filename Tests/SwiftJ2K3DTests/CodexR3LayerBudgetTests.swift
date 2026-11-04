// SPDX-License-Identifier: Apache-2.0
//
// CodexR3LayerBudgetTests.swift
// SwiftJ2K3DTests
//
// Regression coverage for Phase R3 second-rework finding RA2-02:
//   1. Streaming `JP3DTier2Coder.forEachPacketAddress` decodes 65,535-layer JP3D
//      codestreams across all five progression orders (`LRCP`, `RLCP`, `RPCL`,
//      `PCRL`, `CPRL`) under a 131,072-byte workspace cap with zero `O(numLayers)`
//      address-array or `Set<PacketAddress3D>` allocation.
//   2. Any retained packet-index (`JP3DJPIPIndexer.index`, `recordPacketRanges: true`)
//      or retained multi-layer `CodewordSegment` accumulation exceeding the
//      workspace cap throws `CodecError(.resourceLimitExceeded)` pre-allocation.

import Foundation
import Synchronization
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2K3D

@Suite("Codex R3 packet layer budget (RA2-02)")
struct CodexR3LayerBudgetTests {

    private func mainHeader(of stream: Data) throws -> Data {
        let bytes = [UInt8](stream)
        var cursor = 2
        while cursor + 4 <= bytes.count {
            let marker = UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1])
            if marker == 0xFF90 { return Data(bytes[..<cursor]) }
            if (0xFF30...0xFF3F).contains(marker) { cursor += 2; continue }
            let length = Int(UInt16(bytes[cursor + 2]) << 8 | UInt16(bytes[cursor + 3]))
            guard length >= 2, cursor + 2 + length <= bytes.count else { break }
            cursor += 2 + length
        }
        throw CodecError(.malformedInput, "Fixture lacks SOT")
    }

    @Test("3D reconstruction admits output growth while the complete tile buffer remains live")
    func reassemblyOutputCopyBoundary() async throws {
        let stream = try await makeManyEmptyLayersJP3D()
        let header = try mainHeader(of: stream)
        let peak = Mutex(0)
        let baseline = StorageTelemetry.Recorder()
        let control = try StorageTelemetry.$recorder.withValue(baseline) {
            try JP3DJPIPIndexer.reassembleJPP3D(mainHeader: header,
                tileHeaders: [0: Data()], precinctBins: [:],
                workspaceObserver: { bytes in peak.withLock { $0 = max($0, bytes) } })
        }
        #expect(control == stream)
        let requiredPeak = peak.withLock { $0 }
        #expect(requiredPeak > 2 * 65_535)
        for limits in [try ResourceLimits(maximumWorkspaceBytes: requiredPeak - 1),
                       try ResourceLimits(maximumMemoryBytes: requiredPeak - 1)] {
            let denied = StorageTelemetry.Recorder()
            do {
                _ = try StorageTelemetry.$recorder.withValue(denied) {
                    try JP3DJPIPIndexer.reassembleJPP3D(mainHeader: header,
                        tileHeaders: [0: Data()], precinctBins: [:], limits: limits)
                }
                Issue.record("Expected rejection before the simultaneous output copy")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }
            #expect(denied.events.contains { $0.stage == "jp3d-reassembly-tile-output" })
            #expect(!denied.events.contains { $0.stage == "jp3d-reassembly-output-growth" })
        }
        let exact = try JP3DJPIPIndexer.reassembleJPP3D(mainHeader: header,
            tileHeaders: [0: Data()], precinctBins: [:],
            limits: try ResourceLimits(maximumWorkspaceBytes: requiredPeak, maximumMemoryBytes: requiredPeak))
        #expect(exact == stream)

        let probeDenied = StorageTelemetry.Recorder()
        do {
            _ = try StorageTelemetry.$recorder.withValue(probeDenied) {
                try JP3DJPIPIndexer.reassembleJPP3D(mainHeader: header,
                    tileHeaders: [0: Data()], precinctBins: [:],
                    limits: try ResourceLimits(maximumWorkspaceBytes: header.count))
            }
            Issue.record("Expected probe admission failure")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(probeDenied.events.isEmpty)
    }

    @Test("3D indexing admits its source copy and avoids a second packet-input copy")
    func indexingSourceAndForwardingBoundary() async throws {
        let stream = try await makeManyEmptyLayersJP3D(numLayers: 256)
        let baseline = StorageTelemetry.Recorder()
        let index = try StorageTelemetry.$recorder.withValue(baseline) {
            try JP3DJPIPIndexer.index(stream)
        }
        #expect(index.precincts.first?.layerPackets.count == 256)
        #expect(!baseline.events.contains { $0.stage == "jp3d-packet-input-copy" })
        let denied = StorageTelemetry.Recorder()
        do {
            _ = try StorageTelemetry.$recorder.withValue(denied) {
                try JP3DJPIPIndexer.index(stream,
                    limits: try ResourceLimits(maximumWorkspaceBytes: stream.count + 4095))
            }
            Issue.record("Expected source-scanning-copy admission failure")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(!denied.events.contains { $0.stage == "jp3d-index-input-copy" })
    }

    /// Builds a valid 1x1x1 8-bit 1-component normative JP3D codestream whose `COD`
    /// advertises `numLayers` quality layers with `progressionOrderByte` (`0...4`) and
    /// `numLayers` empty 1-byte packet headers (`0x00`).
    private func makeManyEmptyLayersJP3D(
        numLayers: Int = 65_535,
        progressionOrderByte: UInt8 = 0
    ) async throws -> Data {
        let oneVoxel = J2KVolume(
            width: 1,
            height: 1,
            depth: 1,
            components: [
                J2KVolumeComponent(
                    index: 0,
                    bitDepth: 8,
                    signed: false,
                    width: 1,
                    height: 1,
                    depth: 1,
                    data: Data([0])
                )
            ]
        )
        let base = try await VolumeEncoder(
            configuration: VolumeEncoderConfiguration(
                compressionMode: .lossless,
                tiling: JP3DTilingConfiguration(tileSizeX: 1, tileSizeY: 1, tileSizeZ: 1),
                qualityLayers: 1,
                levelsX: 0,
                levelsY: 0,
                levelsZ: 0
            )
        ).encode(oneVoxel).data

        var bytes = [UInt8](base)
        // Locate main-header COD (`0xFF52`) and SOT (`0xFF90`) to patch `SGcod` and tile bitstream:
        var cursor = 2
        var codOffset: Int?
        var sotOffset: Int?
        while cursor + 2 <= bytes.count {
            let marker = UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1])
            if marker == 0xFF90 {
                sotOffset = cursor
                break
            }
            if (0xFF30...0xFF3F).contains(marker) {
                cursor += 2
                continue
            }
            let segLen = Int(UInt16(bytes[cursor + 2]) << 8 | UInt16(bytes[cursor + 3]))
            if marker == 0xFF52 {
                codOffset = cursor
            }
            cursor += 2 + segLen
        }
        let codPos = try #require(codOffset)
        let sotPos = try #require(sotOffset)

        // COD layout: `[FF 52] [Lcod:2] [Scod:1] [Prog:1] [Layers:2] [MCT:1] ...`
        bytes[codPos + 5] = progressionOrderByte
        bytes[codPos + 6] = UInt8((numLayers >> 8) & 0xFF)
        bytes[codPos + 7] = UInt8(numLayers & 0xFF)

        var patched = Data(bytes[0..<sotPos])
        // SOT (`12` B) + SOD (`2` B) + `numLayers` empty packet headers (`0x00`) = `14 + numLayers`
        let psot = UInt32(14 + numLayers)
        patched.append(contentsOf: [
            0xFF, 0x90,
            0x00, 0x0A,
            0x00, 0x00, // Isot = 0
            UInt8((psot >> 24) & 0xFF),
            UInt8((psot >> 16) & 0xFF),
            UInt8((psot >> 8) & 0xFF),
            UInt8(psot & 0xFF),
            0x00,       // TPsot = 0
            0x01,       // TNsot = 1
            0xFF, 0x93  // SOD
        ])
        patched.append(Data(repeating: 0x00, count: numLayers))
        patched.append(contentsOf: [0xFF, 0xD9]) // EOC
        return patched
    }

    /// Builds a valid 1x1x1 8-bit normative JP3D codestream with `numLayers` packets where
    /// EVERY packet includes code-block 0 with 1 coding pass and a 1-byte codeword segment
    /// (`terminateAll` bit `0x04` set in `SPcod` so each pass creates a distinct `CodewordSegment`).
    private func makeManyNonEmptySegmentLayersJP3D(numLayers: Int) async throws -> Data {
        let base = try await makeManyEmptyLayersJP3D(numLayers: numLayers, progressionOrderByte: 0)
        var bytes = [UInt8](base)
        var cursor = 2
        var codOffset: Int?
        var sotOffset: Int?
        while cursor + 2 <= bytes.count {
            let marker = UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1])
            if marker == 0xFF90 {
                sotOffset = cursor
                break
            }
            if (0xFF30...0xFF3F).contains(marker) {
                cursor += 2
                continue
            }
            let segLen = Int(UInt16(bytes[cursor + 2]) << 8 | UInt16(bytes[cursor + 3]))
            if marker == 0xFF52 {
                codOffset = cursor
            }
            cursor += 2 + segLen
        }
        let codPos = try #require(codOffset)
        let sotPos = try #require(sotOffset)

        // ITU-T T.809 COD SPcod: `[NLx:1][NLy:1][NLz:1][xcb:1][ycb:1][zcb:1][cbStyle:1]` at `codPos + 9 ..+ 15`
        bytes[codPos + 15] |= 0x04 // `terminateAll` -> every layer appends a fresh `CodewordSegment`

        // Build `numLayers` valid packets for 1 precinct with 1 1x1x1 code-block:
        //   Layer 0: non-empty(1), tag-tree first inclusion at layer 0(1), zero-bit-planes=0(1),
        //            newPasses=1(0), lblock-inc=0(0), length(3 bits)=001 -> 8 bits `0b1110_0001` (`0xE1`), body `0x00`.
        //   Layer >0: non-empty(1), already-included(1), newPasses=1(0), lblock-inc=0(0),
        //             length(3 bits)=001, pad(0) -> 8 bits `0b1100_0010` (`0xC2`), body `0x00`.
        var tileBody = Data()
        tileBody.reserveCapacity(numLayers * 2)
        if numLayers > 0 {
            tileBody.append(contentsOf: [0xE1, 0x00])
            for _ in 1..<numLayers {
                tileBody.append(contentsOf: [0xC2, 0x00])
            }
        }

        var patched = Data(bytes[0..<sotPos])
        let psot = UInt32(14 + tileBody.count)
        patched.append(contentsOf: [
            0xFF, 0x90,
            0x00, 0x0A,
            0x00, 0x00,
            UInt8((psot >> 24) & 0xFF),
            UInt8((psot >> 16) & 0xFF),
            UInt8((psot >> 8) & 0xFF),
            UInt8(psot & 0xFF),
            0x00,
            0x01,
            0xFF, 0x93
        ])
        patched.append(tileBody)
        patched.append(contentsOf: [0xFF, 0xD9])
        return patched
    }

    @Test("RA2-02a: Lazy streaming packet sequencer decodes 65,535-layer JP3D across all 5 progression orders under 128 KiB workspace with zero O(numLayers) allocation")
    func lazyStreamingSequencerFitsUnder128KiBAcrossAllProgressions() async throws {
        let cap = 131_072
        for prog: UInt8 in 0...4 {
            let stream = try await makeManyEmptyLayersJP3D(numLayers: 65_535, progressionOrderByte: prog)
            #expect(stream.count < 70_000)

            let parsed = try JP3DCodestreamParser().parse(stream)
            #expect(parsed.cod.numLayers == 65_535)
            #expect(parsed.cod.progressionOrderByte == prog)
            let geom = try JP3DGeometryBuilder.makeTileComponentGeometry(
                x0: 0, x1: 1, y0: 0, y1: 1, z0: 0, z1: 1, cod: parsed.cod
            )

            // The visited set contains one Boolean per precinct plus its component/resolution array headers; the bound is independent of layers.
            var admittedSequencerBytes = 0
            var visitedCount = 0
            try JP3DTier2Coder.forEachPacketAddress(
                geometries: [geom],
                progression: prog,
                totalLayers: 65_535,
                admitWorkspaceBytes: { admittedSequencerBytes += $0 }
            ) { _ in
                visitedCount += 1
                return true
            }
            #expect(visitedCount == 65_535)
            let precinctCount = geom.resolutions.reduce(0) { $0 + $1.precincts.count }
            let visitedBound = 32 + (32 + MemoryLayout<[[Bool]]>.stride)
                + geom.resolutions.count * (32 + MemoryLayout<[Bool]>.stride)
                + precinctCount * MemoryLayout<Bool>.stride
            #expect(admittedSequencerBytes <= visitedBound)
            var singleLayerBytes = 0
            try JP3DTier2Coder.forEachPacketAddress(
                geometries: [geom], progression: prog, totalLayers: 1,
                admitWorkspaceBytes: { singleLayerBytes += $0 }
            ) { _ in true }
            #expect(admittedSequencerBytes == singleLayerBytes)

            // Both `maxQualityLayers: 1` (early exit on LRCP) and full decode fit genuinely inside 131,072 B.
            // Unsigned 8-bit all-zero wavelet coefficients reconstruct to mid-grey `2^(8-1) = 128` after Part 1 DC level shift:
            let limits = try ResourceLimits(maximumWorkspaceBytes: cap, maximumWorkers: 1)
            let decLayer1 = try await VolumeDecoder(
                configuration: VolumeDecoderConfiguration(maxQualityLayers: 1)
            ).decode(stream, options: VolumeDecodeOptions(resourceLimits: limits))
            #expect(decLayer1.volume.components[0].data == Data([128]))

            let decFull = try await VolumeDecoder().decode(
                stream,
                options: VolumeDecodeOptions(resourceLimits: limits)
            )
            #expect(decFull.volume.components[0].data == Data([128]))
            if let reportedPeak = decFull.report.peakWorkspaceBytes {
                #expect(reportedPeak <= cap)
            }
        }
    }

    @Test("RA2-02b: Retained JPIP 3D packet indexing and retained multi-layer codeword segments reject 65,535-layer streams pre-allocation under 128 KiB cap")
    func retainedPacketIndexAndSegmentsRejectPreAllocationUnder128KiB() async throws {
        let cap = 131_072
        let limits = try ResourceLimits(maximumWorkspaceBytes: cap, maximumWorkers: 1)
        let emptyLayersStream = try await makeManyEmptyLayersJP3D(numLayers: 65_535, progressionOrderByte: 0)

        // 1. `JP3DJPIPIndexer.index` pre-admits `perPrc` (`tilePrecinctCount * 65535 * 16` B > 1 MiB) and `[JP3DIndexedPacket]` BEFORE allocating:
        #expect(throws: CodecError.self) {
            _ = try JP3DJPIPIndexer.index(emptyLayersStream, limits: limits)
        }
        do {
            _ = try JP3DJPIPIndexer.index(emptyLayersStream, limits: limits)
            Issue.record("Expected JP3DJPIPIndexer.index on 65,535 layers to fail 128 KiB workspace admission")
        } catch let err as CodecError {
            #expect(err.category == .resourceLimitExceeded, "Unexpected error: \(err)")
        }

        // 2. Direct `JP3DTier2Coder.decodePackets(..., recordPacketRanges: true)` rejects before `[JP3DIndexedPacket]` exceeds `cap`:
        let parsed = try JP3DCodestreamParser().parse(emptyLayersStream)
        let geom = try JP3DGeometryBuilder.makeTileComponentGeometry(
            x0: 0, x1: 1, y0: 0, y1: 1, z0: 0, z1: 1, cod: parsed.cod
        )
        var trackedIndexBytes = 0
        do {
            _ = try JP3DTier2Coder.decodePackets(
                geometries: [geom],
                cod: parsed.cod,
                data: parsed.tiles[0].data,
                recordPacketRanges: true,
                admitWorkspaceBytes: { delta in
                    trackedIndexBytes += delta
                    if trackedIndexBytes > cap {
                        throw CodecError(.resourceLimitExceeded, "Indexed packet range array exceeds 128 KiB budget")
                    }
                },
                cancellation: {}
            )
            Issue.record("Expected recordPacketRanges: true on 65,535 layers to exceed 128 KiB workspace")
        } catch let err as CodecError {
            #expect(err.category == .resourceLimitExceeded, "Unexpected error: \(err)")
        }

        // 3. Retained multi-layer `CodewordSegment` accumulation (`5,500` 1-byte terminated segments -> `~11 KiB` codestream, `> 148 KiB` retained `[CodewordSegment]`):
        let manySegmentsStream = try await makeManyNonEmptySegmentLayersJP3D(numLayers: 5_500)
        #expect(manySegmentsStream.count < 16_384)
        do {
            _ = try await VolumeDecoder(
                configuration: VolumeDecoderConfiguration(tolerateTruncation: false)
            ).decode(manySegmentsStream, options: VolumeDecodeOptions(resourceLimits: limits))
            Issue.record("Expected 5,500 retained CodewordSegments to fail 128 KiB workspace admission pre-allocation")
        } catch let err as CodecError {
            #expect(err.category == .resourceLimitExceeded, "Unexpected error: \(err)")
        }
    }
}
