// SPDX-License-Identifier: Apache-2.0
//
// CodexR3WireGrammarTests.swift
// SwiftJ2KJPIPTests
//
// Preserved Codex R3 independent wire cache-model grammar reproducers (RA2-01)
// plus ITU-T Rec. T.808 Clauses C.8.1.1 / C.8.1.2 / C.8.1.3 regression tests.

import Foundation
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2K3D
@testable import SwiftJ2KJPIP

@Suite("Codex R3 normative wire model grammar")
struct CodexR3WireGrammarTests {
    @Test func standardCodestreamQualifierParses() throws {
        let items = try JPIPCacheModel.parseValidatedModelItems(["[1]", "Hm"])
        #expect(items.count == 1)
        #expect(items.first?.codestreamID == 1)
        #expect(items.first?.binClass == .mainHeader)
        #expect(items.first?.isAdditive == true)
    }

    @Test func emitsBracketedCodestreamQualifier() {
        var cache = JPIPCacheModel()
        cache.addDataBin(
            JPIPDataBin(
                binClass: .mainHeader,
                binID: 0,
                data: Data([0xFF, 0x4F]),
                isComplete: true,
                codestreamID: 1
            )
        )
        #expect(cache.formatCacheModelDescriptors() == ["[1]", "Hm"])
    }

    @Test("RA2-01: Multi-codestream ranges [0-1], HTTP query [1;3],Hm top-level splitting, and Clause C.8.1.3 implicit precinct selectors")
    func multiCodestreamRangesHTTPQueryAndImplicitPrecinctSelectors() async throws {
        // 1. `[0-1],Hm` expands across codestreams 0 and 1
        let rangeItems = try JPIPCacheModel.parseValidatedModelItems(["[0-1]", "Hm"])
        #expect(rangeItems.count == 1)
        #expect(rangeItems[0].matchesCodestream(0))
        #expect(rangeItems[0].matchesCodestream(1))
        #expect(!rangeItems[0].matchesCodestream(2))
        #expect(rangeItems.allSatisfy { $0.binClass == .mainHeader })

        // 2. HTTP query `model=[1;3],Hm,-c1:L1` preserves commas inside `[1;3]`
        let req = JPIPRequest.parseHTTPTarget("/jpip?target=multi.jpx&model=[1;3],Hm,-c1:L1")
        try req.validateParameters()
        let modelTokens = try #require(req.model)
        #expect(modelTokens == ["[1;3]", "Hm", "-c1:L1"])
        let parsedQuery = try JPIPCacheModel.parseValidatedModelItems(modelTokens)
        #expect(parsedQuery.count == 4)
        #expect(parsedQuery[0].codestreamID == 1 && parsedQuery[0].binClass == .mainHeader)
        #expect(parsedQuery[1].codestreamID == 3 && parsedQuery[1].binClass == .mainHeader)
        #expect(parsedQuery[2].codestreamID == 1 && parsedQuery[2].isImplicitPrecinct && !parsedQuery[2].isAdditive)
        #expect(parsedQuery[2].componentFilter == .init(lowerBound: 1, upperBound: 1))
        #expect(parsedQuery[2].layerCount == 1)
        #expect(parsedQuery[3].codestreamID == 3 && parsedQuery[3].isImplicitPrecinct && !parsedQuery[3].isAdditive)

        // 3. Clause C.8.1.3 implicit `t`/`c`/`r`/`p` selectors apply against precinct coordinates on JPIPServerSession
        let session = JPIPServerSession(sessionID: "wg", channelID: "wg-ch", target: "multi.j2k")
        let pComp0Res0 = JPIPDataBin(
            binClass: .precinct, binID: 0,
            data: Data(repeating: 0xAA, count: 64),
            isComplete: true, tileIndex: 0, codestreamID: 0,
            componentIndex: 0, resolutionLevel: 0, precinctInResolution: 0, sequenceInTileComponent: 0
        )
        let pComp1Res0 = JPIPDataBin(
            binClass: .precinct, binID: 1,
            data: Data(repeating: 0xBB, count: 64),
            isComplete: true, tileIndex: 0, codestreamID: 0,
            componentIndex: 1, resolutionLevel: 0, precinctInResolution: 0, sequenceInTileComponent: 0
        )
        let pComp1Res1 = JPIPDataBin(
            binClass: .precinct, binID: 3,
            data: Data(repeating: 0xCC, count: 64),
            isComplete: true, tileIndex: 0, codestreamID: 0,
            componentIndex: 1, resolutionLevel: 1, precinctInResolution: 0, sequenceInTileComponent: 1
        )
        let cs1MainHeader = JPIPDataBin(
            binClass: .mainHeader, binID: 0,
            data: Data([0xFF, 0x4F]),
            isComplete: true, codestreamID: 1
        )
        let allBins = [pComp0Res0, pComp1Res0, pComp1Res1, cs1MainHeader]

        // Additive `c1r0` marks component 1 resolution 0 (bin 1) ONLY
        await session.applyCacheModel(items: ["c1r0"], availableBins: allBins)
        #expect(await session.sentByteOffset(binClass: .precinct, binID: 0, codestreamID: 0) == 0)
        #expect(await session.sentByteOffset(binClass: .precinct, binID: 1, codestreamID: 0) == 64)
        #expect(await session.sentByteOffset(binClass: .precinct, binID: 3, codestreamID: 0) == 0)
        #expect(await session.sentByteOffset(binClass: .mainHeader, binID: 0, codestreamID: 1) == 0)

        // Additive `c1` marks all component-1 precincts on active codestream 0 complete, leaving codestream 1 untouched
        await session.applyCacheModel(items: ["c1"], availableBins: allBins)
        #expect(await session.sentByteOffset(binClass: .precinct, binID: 1, codestreamID: 0) == 64)
        #expect(await session.sentByteOffset(binClass: .precinct, binID: 3, codestreamID: 0) == 64)
        #expect(await session.sentByteOffset(binClass: .precinct, binID: 0, codestreamID: 0) == 0)
        #expect(await session.sentByteOffset(binClass: .mainHeader, binID: 0, codestreamID: 1) == 0)
    }
}
