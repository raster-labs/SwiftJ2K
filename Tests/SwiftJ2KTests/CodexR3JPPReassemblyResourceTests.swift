// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJ2K

@Suite("Codex R3 JPP reconstruction admission")
struct CodexR3JPPReassemblyResourceTests {
    // In-house structural fixture: one 1x1 tile, one component, one precinct,
    // reversible Part 1 COD/QCD and empty packet headers. No encoder oracle.
    private func header(layers: Int = 1) throws -> Data {
        var writer = ByteWriter()
        writer.writeUInt16(Marker.soc)
        try CodestreamSyntax.writeSIZ(ImageSizeSegment(
            capabilities: 0, width: 1, height: 1, originX: 0, originY: 0,
            tileWidth: 1, tileHeight: 1, tileOriginX: 0, tileOriginY: 0,
            components: [ComponentSignalling(precision: 8, signed: false,
                horizontalSeparation: 1, verticalSeparation: 1)]), into: &writer)
        try CodestreamSyntax.writeCOD(CodingStyleSegment(
            usesPrecincts: false, usesSOP: false, usesEPH: false,
            progression: 0, layers: layers, componentTransform: 0,
            decompositionLevels: 0, codeBlockWidthExponent: 6,
            codeBlockHeightExponent: 6, codeBlockStyle: 0, reversible: true,
            precinctExponents: []), into: &writer)
        try CodestreamSyntax.writeQCD(QuantizationSegment(
            style: .none, guardBits: 2, exponents: [8], mantissas: []), into: &writer)
        return Data(writer.bytes)
    }

    @Test("Reconstruction workspace and memory boundaries reject before geometry or output allocation")
    func reconstructionBoundary() throws {
        let mainHeader = try header()
        let baseline = StorageTelemetry.Recorder()
        let expected = try StorageTelemetry.$recorder.withValue(baseline) {
            try JPIPCodestreamIndexer.reassembleJPP(
                mainHeader: mainHeader, tileHeaders: [:], precinctBins: [0: Data([0])])
        }
        let peak = try #require(baseline.events.first { $0.stage == "jpip-reassembly-peak" }?.bytes)
        #expect(expected.count == mainHeader.count + 17)
        #expect(try CodestreamSyntax.parse([UInt8](expected), limits: .default).sawEndOfCodestream)

        for limits in [try ResourceLimits(maximumWorkspaceBytes: peak - 1),
                       try ResourceLimits(maximumMemoryBytes: peak - 1)] {
            let denied = StorageTelemetry.Recorder()
            do {
                _ = try StorageTelemetry.$recorder.withValue(denied) {
                    try JPIPCodestreamIndexer.reassembleJPP(
                        mainHeader: mainHeader, tileHeaders: [:], precinctBins: [0: Data([0])], limits: limits)
                }
                Issue.record("Expected reconstruction pre-allocation rejection")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }
            #expect(!denied.parserEvents.isEmpty)
            #expect(!denied.events.contains { $0.stage == "jpip-reassembly-output" || $0.stage == "jpip-reassembly-geometry" })
        }
        let admitted = try JPIPCodestreamIndexer.reassembleJPP(
            mainHeader: mainHeader, tileHeaders: [:], precinctBins: [0: Data([0])],
            limits: try ResourceLimits(maximumWorkspaceBytes: peak, maximumMemoryBytes: peak))
        #expect(admitted == expected)
    }

    @Test("A tiny header cannot allocate an unadmitted 65,535-layer packet table")
    func layerProductRejectedBeforeAllocation() throws {
        let mainHeader = try header(layers: 65_535)
        let recorder = StorageTelemetry.Recorder()
        do {
            _ = try StorageTelemetry.$recorder.withValue(recorder) {
                try JPIPCodestreamIndexer.reassembleJPP(
                    mainHeader: mainHeader, tileHeaders: [:], precinctBins: [0: Data([0])],
                    limits: try ResourceLimits(maximumWorkspaceBytes: 131_072))
            }
            Issue.record("Expected layer-table admission failure")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(!recorder.parserEvents.isEmpty)
        #expect(!recorder.events.contains { $0.stage == "jpip-reassembly-output" || $0.stage == "jpip-reassembly-geometry" })
    }

    @Test("Reconstruction validates tile identifiers before synthesizing a probe")
    func invalidTileHeaderIdentifier() throws {
        let recorder = StorageTelemetry.Recorder()
        do {
            _ = try StorageTelemetry.$recorder.withValue(recorder) {
                try JPIPCodestreamIndexer.reassembleJPP(
                    mainHeader: header(), tileHeaders: [65_536: Data()], precinctBins: [:])
            }
            Issue.record("Expected unrepresentable tile identifier rejection")
        } catch let error as CodecError {
            #expect(error.category == .malformedInput)
        }
        #expect(recorder.events.isEmpty)
    }
}
