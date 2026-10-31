// SPDX-License-Identifier: Apache-2.0
// Regression cases derived from ITU-T T.808 (12/2022), clauses 5.1 and C.8.1.
// These are implementation regressions; they do not replace independent peer qualification.
import Foundation
import Testing
@testable import SwiftJ2KJPIP

@Suite("R3 takeover JPIP cache and deadline regressions")
struct CodexR3TakeoverJPIPTests {
    @Test func normativeQualifierSeparatorAndBoundedRanges() throws {
        let items = try JPIPCacheModel.parseValidatedModelItems(["[1;3-9223372036854775807]", "Hm"])
        #expect(items.count == 2)
        #expect(items[0].matchesCodestream(1))
        #expect(!items[0].matchesCodestream(3))
        #expect(items[1].matchesCodestream(3))
        #expect(items[1].matchesCodestream(Int.max))
        #expect(!items[1].matchesCodestream(2))
        let request = JPIPRequest.parseHTTPTarget("/jpip?target=multi.jpx&model=%5B1%3B3%5D,Hm,-c1:L2")
        try request.validateParameters()
        let directives = try JPIPCacheModel.parseValidatedModelItems(try #require(request.model))
        #expect(directives.count == 4)
        #expect(directives[2].isImplicitPrecinct)
        #expect(directives[2].layerCount == 2)
        #expect(directives[2].componentFilter?.contains(1) == true)
    }

    @Test func inventedFormsAreRejectedWithoutPartialMutation() {
        for token in ["[1,3],Hm", "*", "-*", "Hm*", "Hm1", "P", "H", "T", "M", "P1-3",
                      "c1:20", "s1", "c1-", "P1:L", "T1:L1", "[1;]", "c1c2", "[1],Hm,"] {
            #expect(throws: J2KError.self) {
                _ = try JPIPCacheModel.parseValidatedModelItems([token])
            }
            #expect(JPIPCacheModel.parseModelItems([token]).isEmpty)
        }
    }

    @Test func sessionRestrictionsApplyToSubtractiveAndImplicitSelectors() throws {
        for token in ["-P*", "[0-2],Hm", "[0-],Hm", "[1;3],Hm", "c*", "-t0-2"] {
            var request = JPIPRequest(target: "")
            request.cid = "session"
            request.model = [token]
            #expect(throws: J2KError.self) { try request.validateParameters() }
        }
        var request = JPIPRequest(target: "")
        request.cid = "session"
        request.model = ["[1]", "-c1r0p2t0:L3", "Hm"]
        try request.validateParameters()
    }

    @Test func layerHintsCannotSuppressUndeliveredPackets() async throws {
        let session = JPIPServerSession(sessionID: "layers", channelID: "layers", target: "sample")
        let bin = JPIPDataBin(binClass: .precinct, binID: 2,
                              data: Data(repeating: 7, count: 100), isComplete: true,
                              qualityLayer: 3, componentIndex: 0)
        // A layer hint is not a claim to the entire bin. Ignoring additive hints
        // is permitted by C.8.1.1 and is safe without a retained packet index.
        await session.applyCacheModel(items: ["P2:L1"], availableBins: [bin])
        #expect(await session.sentByteOffset(binClass: .precinct, binID: 2) == 0)
        await session.applyCacheModel(items: ["P*:L1"], availableBins: [bin])
        #expect(await session.sentByteOffset(binClass: .precinct, binID: 2) == 0)
        await session.recordSentDataBin(bin)
        await session.applyCacheModel(items: ["-c0:L1"], availableBins: [bin])
        #expect(await session.sentByteOffset(binClass: .precinct, binID: 2) == 0)
        #expect(await session.hasCompleteDataBin(binClass: .precinct, binID: 2, totalLength: 100) == false)
    }

    @Test func additiveRectangleDoesNotMarkOutsidePrecinctsCached() async throws {
        let session = JPIPServerSession(sessionID: "rectangle", channelID: "rectangle", target: "sample")
        let bins = (0..<9).map { id in
            JPIPDataBin(binClass: .precinct, binID: id,
                        data: Data([UInt8(id)]), isComplete: true,
                        tileIndex: id, componentIndex: 0)
        }
        // On a three-column tile grid t0-4 is {0,1,3,4}, not the linear {0...4}.
        // With no grid metadata, ignore the additive rectangle instead of claiming tile 2.
        await session.applyCacheModel(items: ["t0-4"], availableBins: bins)
        #expect(await session.sentByteOffset(binClass: .precinct, binID: 2) == 0)
    }

    @Test func reassemblyRejectsBudgetThatFitsEachBufferButNotTheirOverlap() throws {
        let header = Data([0xFF, 0x4F])
        let tileHeader = Data([0xFF, 0x90, 0, 10, 0, 0, 0, 0, 0, 14, 0, 1, 0xFF, 0x93])
        let payload = Data(repeating: 7, count: 4096)
        let bins = [
            JPIPDataBin(binClass: .mainHeader, binID: 0, data: header, isComplete: true),
            JPIPDataBin(binClass: .tileHeader, binID: 0, data: tileHeader, isComplete: true),
            JPIPDataBin(binClass: .tile, binID: 0, data: payload, isComplete: true)
        ]
        let generator = JPIPDataBinGenerator()
        let output = try generator.reassembleCodestreamThrowing(from: bins, reconstructContainer: false)
        #expect(output == header + tileHeader + payload + Data([0xFF, 0xD9]))
        let mergeAlone = bins.reduce(0) { $0 + $1.data.count }
            + bins.count * MemoryLayout<JPIPCacheModel.CacheEntry>.stride
        let isolatedBudget = max(mergeAlone, output.count) + 1
        // The old implementation admitted merge and output independently under
        // this limit. Both workspace and total-memory ceilings must reject it.
        for limits in [
            try ResourceLimits(maximumWorkspaceBytes: isolatedBudget),
            try ResourceLimits(maximumMemoryBytes: isolatedBudget)
        ] {
            do {
                _ = try generator.reassembleCodestreamThrowing(from: bins, reconstructContainer: false, limits: limits)
                Issue.record("Expected simultaneous merge/output admission failure")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }
        }
    }

    @Test func reassemblyAccountsForLargeBinBeforeSmallerReplacement() throws {
        let large = JPIPDataBin(binClass: .mainHeader, binID: 0,
                               data: Data(repeating: 1, count: 16_384), isComplete: true)
        let replacement = JPIPDataBin(binClass: .mainHeader, binID: 0,
                                     data: Data([0xFF, 0x4F]), isComplete: true)
        let projected = try JPIPCacheModel().projectedAllocation(adding: [large, replacement])
        #expect(projected.totalPayloadBytes == 2)
        #expect(projected.peakPayloadBytes == large.data.count)
        do {
            _ = try JPIPDataBinGenerator().reassembleCodestreamThrowing(
                from: [large, replacement], reconstructContainer: false,
                limits: ResourceLimits(maximumWorkspaceBytes: 8192)
            )
            Issue.record("Expected transient merge allocation admission failure")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
    }
}
