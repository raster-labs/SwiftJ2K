// SPDX-License-Identifier: Apache-2.0
// In-house structural JPEG 2000 fixture: SOC, short SIZ, one SOT/SOD, four data
// bytes and EOC. It tests framing/admission, not full image conformance.
// Raw bytes and malformed mutations are deterministic and independent of the writer.
// Canonical 28-byte fixture SHA-256:
// 92d376cdfb5799aebfea6daf93598abd58a530ea98a31ae7729079647fadac79
import Foundation
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2KJPIP

private func boundedBinFixture(psot: UInt32 = 18) -> Data {
    Data([
        0xFF, 0x4F, 0xFF, 0x51, 0, 4, 0, 0,
        0xFF, 0x90, 0, 10, 0, 0,
        UInt8(truncatingIfNeeded: psot >> 24), UInt8(truncatingIfNeeded: psot >> 16),
        UInt8(truncatingIfNeeded: psot >> 8), UInt8(truncatingIfNeeded: psot),
        0, 1, 0xFF, 0x93, 1, 2, 3, 4, 0xFF, 0xD9
    ])
}

private func expectBinLimit(_ body: () throws -> Void) {
    #expect(throws: CodecError.self) {
        do { try body() }
        catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
            throw error
        }
    }
}

@Suite("R2 JPIP data-bin generation admission")
struct R2BinGenerationBudgetTests {
    @Test("Input, existing cache, final bin bytes and descriptor reservations share one budget")
    func exactGenerationStorageBoundary() throws {
        let input = boundedBinFixture()
        let retained = 11 + 2 * MemoryLayout<JPIPCacheModel.CacheEntry>.stride
        // Independent framing: eight main-header bytes, twelve SOT-header bytes,
        // four tile bytes. SOD/EOC are regenerated during assembly.
        let expectedWorkspace = retained + 24 + 3 * MemoryLayout<JPIPDataBin>.stride
            + MemoryLayout<JPIPCacheModel.CacheEntry>.stride
        let memory = input.count + expectedWorkspace
        let limits = try ResourceLimits(maximumWorkspaceBytes: expectedWorkspace, maximumMemoryBytes: memory)
        let generated = try JPIPDataBinGenerator().generateDataBins(
            from: input, limits: limits, retainedBytes: retained, maximumAdditionalCacheEntries: 1)
        #expect(generated.bins.count == 3)
        #expect(generated.bins.map(\.data.count) == [8, 12, 4])
        #expect(generated.peakWorkspaceBytes == expectedWorkspace)
        #expect(JPIPDataBinGenerator().reassembleCodestream(from: generated.bins) == input)
        expectBinLimit {
            _ = try JPIPDataBinGenerator().generateDataBins(
                from: input,
                limits: ResourceLimits(maximumWorkspaceBytes: expectedWorkspace - 1, maximumMemoryBytes: memory),
                retainedBytes: retained, maximumAdditionalCacheEntries: 1)
        }
        expectBinLimit {
            _ = try JPIPDataBinGenerator().generateDataBins(
                from: input,
                limits: ResourceLimits(maximumWorkspaceBytes: expectedWorkspace, maximumMemoryBytes: memory - 1),
                retainedBytes: retained, maximumAdditionalCacheEntries: 1)
        }
    }

    @Test("Many empty tile payloads still require admitted bin descriptor storage")
    func binDescriptorCountHasARealBudget() throws {
        var input = Data([0xFF, 0x4F, 0xFF, 0x51, 0, 4, 0, 0])
        for index in 0..<20 {
            input.append(contentsOf: [0xFF, 0x90, 0, 10, 0, UInt8(index), 0, 0, 0, 14, 0, 1, 0xFF, 0x93])
        }
        input.append(contentsOf: [0xFF, 0xD9])
        let payloadBytes = 8 + 20 * 12
        let workspace = payloadBytes + 41 * MemoryLayout<JPIPDataBin>.stride
        let accepted = try JPIPDataBinGenerator().generateDataBins(
            from: input, limits: ResourceLimits(maximumWorkspaceBytes: workspace), retainedBytes: 0)
        #expect(accepted.bins.count == 41)
        #expect(accepted.peakWorkspaceBytes == workspace)
        expectBinLimit {
            _ = try JPIPDataBinGenerator().generateDataBins(
                from: input, limits: ResourceLimits(maximumWorkspaceBytes: payloadBytes), retainedBytes: 0)
        }
    }

    @Test("Malformed Psot cannot move backwards, overlap headers or extend past input")
    func malformedTileLengthsAreRejected() {
        for psot in [UInt32(1), 2, 12, 13, 17, 19, UInt32.max] {
            #expect(throws: CodecError.self) {
                do { _ = try JPIPDataBinGenerator().generateDataBins(from: boundedBinFixture(psot: psot)) }
                catch let error as CodecError {
                    #expect(error.category == .malformedInput)
                    throw error
                }
            }
        }
        var overlapping = boundedBinFixture(psot: 0)
        overlapping.removeLast(2)
        overlapping.append(boundedBinFixture().dropFirst(8))
        #expect(throws: CodecError.self) {
            _ = try JPIPDataBinGenerator().generateDataBins(from: overlapping)
        }
        #expect(throws: CodecError.self) {
            _ = try JPIPDataBinGenerator().generateDataBins(from: boundedBinFixture().dropLast(2))
        }
        var missingEOC = boundedBinFixture(psot: 0)
        missingEOC.removeLast(2)
        #expect(throws: CodecError.self) {
            _ = try JPIPDataBinGenerator().generateDataBins(from: missingEOC)
        }
    }

    @Test("A zero Psot final tile and bounded JP2 framing retain every emitted byte")
    func zeroLengthFinalTileAndContainerRanges() throws {
        let raw = boundedBinFixture(psot: 0)
        let generator = JPIPDataBinGenerator()
        let rawBins = try generator.generateDataBins(from: raw)
        #expect(rawBins.map(\.data.count) == [8, 12, 4])
        #expect(generator.reassembleCodestream(from: rawBins) == raw)
        var container = Data([0, 0, 0, 12, 0x6A, 0x50, 0x20, 0x20, 13, 10, 0x87, 10])
        container.append(contentsOf: [0, 0, 0, 36, 0x6A, 0x70, 0x32, 0x63])
        container.append(raw)
        container.append(contentsOf: [0, 0, 0, 12, 0x66, 0x72, 0x65, 0x65, 5, 6, 7, 8])
        let workspace = 48 + 5 * MemoryLayout<JPIPDataBin>.stride
        let generated = try generator.generateDataBins(
            from: container, limits: ResourceLimits(maximumWorkspaceBytes: workspace,
                maximumMemoryBytes: container.count + workspace), retainedBytes: 0)
        #expect(generated.bins.map(\.data.count) == [12, 8, 12, 4, 12])
        #expect(generated.peakWorkspaceBytes == workspace)
        #expect(generator.reassembleCodestream(from: generated.bins) == container)
    }

    @Test("A cache-aware request denies response admission before mutating its existing cache")
    func requestBudgetFailureLeavesCacheUnchanged() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/SwiftJ2KTests/Fixtures/Containers/jp2_rgb8_rct.kdu.jp2")
        let data = try Data(contentsOf: fixture)
        let generator = JPIPDataBinGenerator()
        let uncached = try generator.generateDataBins(from: data, limits: .default, retainedBytes: 0)
        let retained = 64 + MemoryLayout<JPIPCacheModel.CacheEntry>.stride
        let workspace = uncached.peakWorkspaceBytes + retained
            + uncached.bins.count * MemoryLayout<JPIPCacheModel.CacheEntry>.stride
        let server = JPIPServer(port: 19_419)
        try await server.registerImage(name: "bounded.jp2", at: fixture)
        try await server.start()
        defer { Task { try? await server.stop() } }
        let client = JPIPClient(server: server)
        let session = try await client.createSession(target: "bounded.jp2")
        await session.recordDataBin(JPIPDataBin(
            binClass: .metadata, binID: 99, data: Data(repeating: 42, count: 64), isComplete: true))
        let before = await session.getCacheStatistics()
        do {
            _ = try await client.requestDeliveredImage(
                imageID: "bounded.jp2", viewWindow: nil,
                limits: ResourceLimits(maximumWorkspaceBytes: workspace - 1),
                executionPolicy: .scalarCPU, metadataPolicy: .preserve,
                deadline: ContinuousClock.now.advanced(by: .seconds(30)))
            Issue.record("Expected response admission budget rejection")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
            // The shared receive/cache budget now rejects the response before
            // data-bin generation. Keep the specific early-stage proof as well
            // as the unchanged-cache assertions below.
            #expect(error.message.contains("JPIP response payload"))
        }
        let after = await session.getCacheStatistics()
        #expect(after.entryCount == before.entryCount)
        #expect(after.totalSize == before.totalSize)
        #expect(await session.hasDataBin(binClass: .metadata, binID: 99))
        try await client.close()
    }
}
