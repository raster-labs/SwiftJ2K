// SPDX-License-Identifier: Apache-2.0
// Independent OpenJPEG 2.5.4 fixture and expected samples come from
// Fixtures/Containers/manifest.json: unsigned 12-bit grey, 16×12, sample
// (17 + 131*x + 197*y) modulo 4096. Source fixture SHA-256:
// a8a9a107587265cd8d7bd0eeaea8a99afba1cc4db3ce4d3c78fc50b27501d54e
import Foundation
import Testing
@testable import SwiftJ2K

private func legacyBudgetInputs() throws -> [Data] {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/SwiftJ2KTests/Fixtures/Containers/jp2_g16_lossless.opj.jp2")
    let container = try Data(contentsOf: url)
    let bytes = [UInt8](container)
    var offset = 0
    while bytes.count - offset >= 8 {
        let length = Int(UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3]))
        try #require(length >= 8 && length <= bytes.count - offset)
        if Array(bytes[(offset + 4)..<(offset + 8)]) == Array("jp2c".utf8) {
            // Nonzero prefix makes the public legacy SOC search exercise a separate
            // codestream slice instead of an array covering the entire raw input.
            var raw = Data(repeating: 0x31, count: 37)
            raw.append(contentsOf: bytes[(offset + 8)..<(offset + length)])
            return [raw, container]
        }
        offset += length
    }
    throw CodecError(.internalFailure, "Pinned test fixture has no jp2c box.")
}

private func expectLegacyBudgetDenial(_ input: Data, limits: ResourceLimits, retained: Int) {
    let recorder = StorageTelemetry.Recorder()
    #expect(throws: CodecError.self) {
        do {
            _ = try StorageTelemetry.$recorder.withValue(recorder) {
                try J2KDecoder.decodeWithInfo(input, limits: limits, executionPolicy: .scalarCPU,
                    metadataPolicy: .discardAncillary, retainedExternalBytes: retained)
            }
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
            throw error
        }
    }
    #expect(recorder.counts.pixelAllocations == 0)
    #expect(recorder.counts.workspaceAllocations == 0)
}

@Suite("R2 legacy decode combined-budget probes")
struct R2LegacyBudgetProbes {
    @Test("Reported workspace, input and destination form a usable exact-fit budget with retained cache")
    func rawAndContainerExactFitWithExternalStorage() throws {
        for input in try legacyBudgetInputs() {
            let baseline = try J2KDecoder.decodeWithInfo(input, executionPolicy: .scalarCPU,
                                                       metadataPolicy: .discardAncillary)
            let descriptor = try #require(baseline.contractImage?.descriptor)
            #expect(descriptor.requiredByteCount == 16 * 12 * 2)
            let retained = 4096
            // This uses the observable report, not private parser/coefficient formulas.
            // A caller must be able to provide room for that workspace, its input and
            // final pixels without the same compressed owner being charged twice.
            let workspace = baseline.peakWorkspaceBytes + retained
            let memory = input.count + descriptor.requiredByteCount + workspace
            let limits = try ResourceLimits(maximumWorkspaceBytes: workspace, maximumMemoryBytes: memory)
            let decoded = try J2KDecoder.decodeWithInfo(input, limits: limits, executionPolicy: .scalarCPU,
                metadataPolicy: .discardAncillary, retainedExternalBytes: retained)
            #expect(decoded.peakWorkspaceBytes == workspace)
            let image = try #require(decoded.contractImage)
            #expect(try image.sampleInt(component: 0, x: 0, y: 0) == 17)
            #expect(try image.sampleInt(component: 0, x: 2, y: 1) == 476)
            #expect(try image.sampleInt(component: 0, x: 15, y: 11) == 53)
            expectLegacyBudgetDenial(input,
                limits: try ResourceLimits(maximumWorkspaceBytes: workspace, maximumMemoryBytes: memory - 1),
                retained: retained)
            expectLegacyBudgetDenial(input,
                limits: try ResourceLimits(maximumWorkspaceBytes: workspace - 1, maximumMemoryBytes: memory),
                retained: retained)
        }
    }

    @Test("Retained cache and compressed-copy admission occurs before parser or pixel allocation")
    func outerStorageDenialPrecedesParserAllocation() throws {
        for input in try legacyBudgetInputs() {
            let retained = 4096
            let recorder = StorageTelemetry.Recorder()
            #expect(throws: CodecError.self) {
                do {
                    _ = try StorageTelemetry.$recorder.withValue(recorder) {
                        try J2KDecoder.decodeWithInfo(input,
                            limits: ResourceLimits(maximumMemoryBytes: input.count + retained),
                            executionPolicy: .scalarCPU, retainedExternalBytes: retained)
                    }
                } catch let error as CodecError {
                    #expect(error.category == .resourceLimitExceeded)
                    throw error
                }
            }
            #expect(recorder.parserEvents.isEmpty)
            #expect(recorder.counts.pixelAllocations == 0)
            #expect(recorder.counts.workspaceAllocations == 0)
        }
    }

    @Test("Combined crop and reduction count full, intermediate and returned logical pixels")
    func projectionCountsActualMaterialisations() throws {
        let input = try #require(legacyBudgetInputs().last)
        let decoded = try J2KDecoder.decodeWithInfo(input, resolutionLevel: 1,
            region: (x: 1, y: 1, width: 5, height: 3), executionPolicy: .scalarCPU,
            metadataPolicy: .discardAncillary)
        #expect(decoded.contractImage == nil)
        #expect(decoded.image.width == 3 && decoded.image.height == 2)
        // One final decoded contract buffer, one full legacy plane, one crop and one reduction.
        #expect(decoded.pixelAccounting.allocationCount == 4)
        #expect(decoded.pixelAccounting.copyEvents.map(\.bytesMoved) == [384, 30, 12])
        #expect(decoded.pixelAccounting.peakBytes == 384 + 384 + 30 + 12)
        let image = try decoded.image.toContractImage()
        for y in 0..<2 {
            for x in 0..<3 {
                #expect(try image.sampleInt(component: 0, x: x, y: y)
                    == (17 + 131 * (1 + 2 * x) + 197 * (1 + 2 * y)) % 4096)
            }
        }
    }
}
