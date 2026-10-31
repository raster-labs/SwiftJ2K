// SPDX-License-Identifier: Apache-2.0
//
// CodexR3IndependentTests.swift
// SwiftJ2KJPIPTests
//
// Preserved Codex R3 independent JPIP cache reproducers plus regression coverage
// for Phase R3 rework items F04-01 through F04-10.

import Foundation
import Dispatch
import Synchronization
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2K3D
@testable import SwiftJ2KJPIP

@Suite("Codex R3 independent JPIP cache semantics and F04 rework verification")
struct CodexR3IndependentTests {
    // MARK: - Preserved Codex R3 Independent Reproducers (F04-01, F04-02)

    @Test func codestreamsDoNotReplaceEachOther() {
        var cache = JPIPCacheModel()
        cache.addDataBin(JPIPDataBin(binClass: .mainHeader, binID: 0, data: Data([10,11]), isComplete: true, codestreamID: 0))
        cache.addDataBin(JPIPDataBin(binClass: .mainHeader, binID: 0, data: Data([20,21]), isComplete: true, codestreamID: 1))
        let bins = cache.allDataBins()
        #expect(bins.count == 2)
        #expect(bins.contains { $0.codestreamID == 0 && $0.data == Data([10,11]) })
        #expect(bins.contains { $0.codestreamID == 1 && $0.data == Data([20,21]) })
    }

    @Test func normalAndExtendedMessagesMergeIntoOnePrecinct() {
        var cache = JPIPCacheModel()
        cache.addDataBin(JPIPDataBin(binClass: .precinct, binID: 7, data: Data([1,2]), isComplete: false, codestreamID: 3))
        cache.addDataBin(JPIPDataBin(binClass: .extendedPrecinct, binID: 7, data: Data([3,4]), isComplete: true, codestreamID: 3, msgOffset: 2, aux: 1))
        let bins = cache.allDataBins()
        #expect(bins.count == 1)
        #expect(bins.contains { $0.codestreamID == 3 && $0.isComplete && $0.data == Data([1,2,3,4]) })
    }

    @Test func subtractiveLengthIsRemainingPrefix() async {
        let session = JPIPServerSession(sessionID: "audit", channelID: "audit", target: "fixture")
        let bin = JPIPDataBin(binClass: .precinct, binID: 7, data: Data(repeating: 1, count: 100), isComplete: true)
        await session.recordSentDataBin(bin)
        await session.applyCacheModel(items: ["-P7:20"], availableBins: [bin])
        let offset = await session.sentByteOffset(binClass: .precinct, binID: 7)
        #expect(offset == 20)
    }

    // MARK: - F04-01, F04-02 & RA2-01 Extended Cache & Normative Codestream Context Tests

    @Test("F04-01/02 & RA2-01: Extended tile merges with tile, sticky [<csn>] model qualifiers round-trip, -c1 subtracts component 1 precincts only, and [1],-P* clears codestream 1 precincts")
    func extendedTileMergeCodestreamQualifiersAndSubtractiveCap() async throws {
        var cache = JPIPCacheModel()
        cache.addDataBin(JPIPDataBin(binClass: .tile, binID: 2, data: Data([0xAA, 0xBB]), isComplete: false, codestreamID: 4))
        cache.addDataBin(JPIPDataBin(binClass: .extendedTile, binID: 2, data: Data([0xCC, 0xDD]), isComplete: true, codestreamID: 4, msgOffset: 2, aux: 9))
        #expect(cache.hasDataBin(binClass: .tile, binID: 2, codestreamID: 4))
        #expect(cache.hasDataBin(binClass: .extendedTile, binID: 2, codestreamID: 4))
        #expect(!cache.hasDataBin(binClass: .tile, binID: 2, codestreamID: 0))
        let fetchedTile = cache.getDataBin(binClass: .tile, binID: 2, codestreamID: 4)
        let mergedTile = try #require(fetchedTile)
        #expect(mergedTile.binClass == .tile)
        #expect(mergedTile.data == Data([0xAA, 0xBB, 0xCC, 0xDD]))
        #expect(mergedTile.isComplete)

        // Sticky Clause C.8.1.1 `[<csn>]` emission & parsing
        cache.addDataBin(JPIPDataBin(binClass: .mainHeader, binID: 0, data: Data([1, 2, 3]), isComplete: true, codestreamID: 0))
        let formatted = cache.formatCacheModelField()
        #expect(formatted.contains("Hm"))
        #expect(formatted.contains("[4]"))
        #expect(!formatted.contains("c4"))
        #expect(formatted.contains("T2"))

        let parsed = try JPIPCacheModel.parseValidatedModelItems(formatted)
        #expect(parsed.contains { $0.codestreamID == 0 && $0.binClass == .mainHeader })
        #expect(parsed.contains { $0.codestreamID == 4 && $0.binClass == .tile && $0.binID == 2 })

        // Server session: multi-codestream isolation + `-P7:80` when only 20 bytes held keeps 20 bytes
        let session = JPIPServerSession(sessionID: "s1", channelID: "c1", target: "multi")
        let p0Comp0 = JPIPDataBin(
            binClass: .precinct, binID: 0,
            data: Data(repeating: 0x33, count: 40),
            isComplete: true, tileIndex: 0, codestreamID: 0,
            componentIndex: 0, resolutionLevel: 0, precinctInResolution: 0, sequenceInTileComponent: 0
        )
        let p0Comp1 = JPIPDataBin(
            binClass: .precinct, binID: 1,
            data: Data(repeating: 0x44, count: 50),
            isComplete: true, tileIndex: 0, codestreamID: 0,
            componentIndex: 1, resolutionLevel: 0, precinctInResolution: 0, sequenceInTileComponent: 0
        )
        let p0 = JPIPDataBin(binClass: .precinct, binID: 7, data: Data(repeating: 0x11, count: 20), isComplete: false, codestreamID: 0)
        let p1 = JPIPDataBin(binClass: .precinct, binID: 7, data: Data(repeating: 0x22, count: 60), isComplete: true, codestreamID: 1)
        await session.recordSentDataBin(p0Comp0)
        await session.recordSentDataBin(p0Comp1)
        await session.recordSentDataBin(p0)
        await session.recordSentDataBin(p1)
        #expect(await session.sentByteOffset(binClass: .precinct, binID: 7, codestreamID: 0) == 20)
        #expect(await session.sentByteOffset(binClass: .precinct, binID: 7, codestreamID: 1) == 60)

        let fullP0 = JPIPDataBin(binClass: .precinct, binID: 7, data: Data(repeating: 0x11, count: 100), isComplete: true, codestreamID: 0)
        await session.applyCacheModel(items: ["-P7:80"], availableBins: [p0Comp0, p0Comp1, fullP0, p1])
        #expect(await session.sentByteOffset(binClass: .precinct, binID: 7, codestreamID: 0) == 20)
        #expect(!(await session.hasCompleteDataBin(binClass: .precinct, binID: 7, totalLength: 100, codestreamID: 0)))
        // Codestream 1 untouched by codestream 0 directive
        #expect(await session.sentByteOffset(binClass: .precinct, binID: 7, codestreamID: 1) == 60)

        // Clause C.8.1.3: `-c1` is an implicit COMPONENT-1 precinct subtraction on active codestream 0 (must NOT flush codestream 1 or component 0!)
        await session.applyCacheModel(items: ["-c1"], availableBins: [p0Comp0, p0Comp1, fullP0, p1])
        #expect(await session.sentByteOffset(binClass: .precinct, binID: 1, codestreamID: 0) == 0)
        #expect(await session.sentByteOffset(binClass: .precinct, binID: 0, codestreamID: 0) == 40)
        #expect(await session.sentByteOffset(binClass: .precinct, binID: 7, codestreamID: 1) == 60)

        // Clause C.8.1.1 + C.8.1.2: `["[1]", "-P*"]` clears codestream 1 precincts without clearing codestream 0
        await session.applyCacheModel(items: ["[1]", "-P*"], availableBins: [p0Comp0, p0Comp1, fullP0, p1])
        #expect(await session.sentByteOffset(binClass: .precinct, binID: 7, codestreamID: 1) == 0)
        #expect(await session.sentByteOffset(binClass: .precinct, binID: 7, codestreamID: 0) == 20)
    }

    // MARK: - F04-03 Checked Arithmetic & Malformed Token Rejection

    @Test("F04-03: Malformed model tokens and overflowing JPIP query dimensions/offsets fail cleanly without trapping")
    func malformedTokensAndOverflowingQueryRangesRejected() async throws {
        // Valid Clause C.8.1.1 `[0]` followed by a bin descriptor parses cleanly;
        // trailing `[0]` without a bin descriptor or malformed brackets must reject cleanly without trapping.
        let validZeroContext = try JPIPCacheModel.parseValidatedModelItems(["[0]", "Hm"])
        #expect(validZeroContext.count == 1)
        #expect(validZeroContext.first?.codestreamID == 0)
        for badBracket in ["[0]", "[]", "[abc]", "[2-1]", "[1,]"] {
            #expect(throws: J2KError.self) {
                _ = try JPIPCacheModel.parseValidatedModelItems([badBracket])
            }
            #expect(JPIPCacheModel.parseModelItems([badBracket]).isEmpty)
        }

        // Malformed HTTP query values record validation error and throw on validateParameters()
        let badFSiz = JPIPRequest.parseHTTPTarget("/jpip?target=a.j2k&fsiz=0,-5")
        #expect(throws: J2KError.self) {
            try badFSiz.validateParameters()
        }

        let badFVSiz = JPIPRequest.parseHTTPTarget("/jpip?target=a.jp3d&fvsiz=16,16,0")
        #expect(throws: J2KError.self) {
            try badFVSiz.validateParameters()
        }

        // Programmatic `roff + rsiz` and `rsiz.width * rsiz.height` overflow rejected without trapping
        let server = JPIPServer(port: 0)
        let img = makeGreyImage(width: 8, height: 8)
        let encoded = try await Encoder(
            configuration: try EncoderConfiguration(
                mode: .lossless,
                codecOptions: try CodecOptions(containerFormat: .codestream)
            )
        ).encode(try img.toContractImage()).data
        await server.registerImageData(name: "tiny.j2k", data: encoded)
        try await server.start()
        defer { Task { try? await server.stop() } }

        var overflowAreaReq = JPIPRequest(target: "tiny.j2k")
        overflowAreaReq.rsiz = (Int.max, 2)
        overflowAreaReq.roff = (1, 0)
        await #expect(throws: J2KError.self) {
            _ = try await server.handleRequest(overflowAreaReq)
        }

        var overflow3DReq = JPIPRequest(target: "tiny.j2k")
        overflow3DReq.rvoff = [Int.max - 2, 0, 0]
        overflow3DReq.rvsiz = [10, 4, 4]
        await #expect(throws: J2KError.self) {
            _ = try await server.handleRequest(overflow3DReq)
        }

        try await server.stop()
    }

    // MARK: - F04-04 Pre-Allocation Sparse Msg-Offset & Multi-Round Cumulative Limits

    @Test("F04-04: Sparse Msg-Offset amplification and multi-round cumulative responses fail pre-allocation against ResourceLimits")
    func sparseMsgOffsetAndCumulativeLimitsEnforcedPreAllocation() async throws {
        // 1. 1-byte wire bin with 64 MiB Msg-Offset rejected before allocating 64 MiB
        let sparseBin = JPIPDataBin(
            binClass: .precinct,
            binID: 0,
            data: Data([0xFF]),
            isComplete: true,
            msgOffset: 64 * 1024 * 1024
        )
        let cache = JPIPCacheModel()
        let projected = try cache.projectedAllocation(adding: [sparseBin])
        #expect(projected.totalPayloadBytes == 64 * 1024 * 1024 + 1)
        #expect(cache.statistics.totalSize == 0)

        let tightLimits = try ResourceLimits(
            maximumCompressedBytes: 4096,
            maximumWorkspaceBytes: 16 * 1024,
            maximumMemoryBytes: 32 * 1024
        )
        #expect(throws: CodecError.self) {
            _ = try JPIPDataBinGenerator().reassembleCodestreamThrowing(
                from: [sparseBin],
                reconstructContainer: false,
                limits: tightLimits
            )
        }

        // 2. Multi-round `len=48` delivery rejected once cumulative bytes exceed `maximumCompressedBytes`
        let img = makeGreyImage(width: 32, height: 32)
        let j2k = try await Encoder(
            configuration: try EncoderConfiguration(
                mode: .lossless,
                codecOptions: try CodecOptions(containerFormat: .codestream)
            )
        ).encode(try img.toContractImage()).data
        #expect(j2k.count > 160)

        let server = JPIPServer(port: 0)
        await server.registerImageData(name: "multiround.j2k", data: j2k)
        try await server.start()
        defer { Task { try? await server.stop() } }
        let port = await server.listeningPort

        let session = JPIPStreamingSession(server: server, port: port)
        let cumulativeCap = try ResourceLimits(maximumCompressedBytes: 120)
        do {
            _ = try await session.deliverImage(
                imageID: "multiround.j2k",
                viewWindow: nil,
                options: JPIPStreamingOptions(resourceLimits: cumulativeCap)
            )
            Issue.record("Expected multi-round cumulative compressed limit to throw CodecError(.resourceLimitExceeded)")
        } catch let err as CodecError {
            #expect(err.category == .resourceLimitExceeded)
        }
        try await session.close()
        try await server.stop()
    }

    // MARK: - F04-05 Normative `len=` Budget Excludes 3-Byte EOR

    @Test("F04-05: len=0..3 and len=64 always emit a complete decodable 3-byte EOR excluded from len")
    func lenAlwaysEmitsCompleteThreeByteEOR() async throws {
        let img = makeGreyImage(width: 16, height: 16)
        let j2k = try await Encoder(
            configuration: try EncoderConfiguration(
                mode: .lossless,
                codecOptions: try CodecOptions(containerFormat: .codestream)
            )
        ).encode(try img.toContractImage()).data

        let server = JPIPServer(port: 0)
        await server.registerImageData(name: "eor.j2k", data: j2k)
        try await server.start()
        defer { Task { try? await server.stop() } }

        for testLen in [0, 1, 2, 3, 24, 64] {
            var req = JPIPRequest(target: "eor.j2k")
            req.streamType = .jppStream
            req.len = testLen
            let resp = try await server.handleRequest(req)
            #expect(resp.data.count >= 3)
            #expect(resp.data.count - 3 <= testLen)
            let decoded = try JPIPWireCodec.decodeStream(resp.data)
            #expect(decoded.eorReason == .byteLimit)
        }

        try await server.stop()
    }

    // MARK: - F04-06 RFC 6455 Fragmented Message With Interleaved Control Frame

    @Test("F04-06: RFC 6455 fragmented binary message survives interleaved FIN=1 ping control frame")
    func rfc6455FragmentedMessageSurvivesInterleavedControlFrame() throws {
        let listener = try JPIPTCPListener(host: "127.0.0.1", port: 0)
        defer { listener.close() }

        final class AcceptedBox: @unchecked Sendable {
            private let lock = NSLock()
            private var conn: JPIPTCPConnection?
            func store(_ c: JPIPTCPConnection?) { lock.lock(); conn = c; lock.unlock() }
            func load() -> JPIPTCPConnection? { lock.lock(); defer { lock.unlock() }; return conn }
        }
        let acceptedBox = AcceptedBox()
        let acceptSema = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            acceptedBox.store(try? listener.acceptConnection(timeoutSeconds: 5))
            acceptSema.signal()
        }

        let clientConn = try JPIPTCPConnection.connect(host: "127.0.0.1", port: listener.boundPort, timeoutSeconds: 5)
        defer { clientConn.close() }
        acceptSema.wait()
        let serverConn = try #require(acceptedBox.load())
        defer { serverConn.close() }

        // Server writes:
        //   1. Fragment 1: FIN=0, opcode=.binary (0x02), payload=[1, 2, 3]
        //   2. Interleaved control frame: FIN=1, opcode=.ping (0x09), payload=[0x99]
        //   3. Fragment 2: FIN=1, opcode=.continuation (0x00), payload=[4, 5, 6]
        var rawWire = Data()
        rawWire.append(contentsOf: [0x02, 0x03, 1, 2, 3])
        rawWire.append(contentsOf: [0x89, 0x01, 0x99])
        rawWire.append(contentsOf: [0x80, 0x03, 4, 5, 6])
        try serverConn.writeAll(rawWire)

        // First read returns the interleaved ping immediately
        let firstFrame = try clientConn.readWebSocketFrame(requireMasked: false)
        #expect(firstFrame.opcode == .ping)
        #expect(firstFrame.payload == Data([0x99]))

        // Second read completes the fragmented binary message [1, 2, 3, 4, 5, 6]
        let secondFrame = try clientConn.readWebSocketFrame(requireMasked: false)
        #expect(secondFrame.opcode == .binary)
        #expect(secondFrame.fin)
        #expect(secondFrame.payload == Data([1, 2, 3, 4, 5, 6]))
    }

    // MARK: - F04-07 & F04-08 Normative 3D View-Window Grammar & Substantiated 3D Fidelity

    @Test("F04-07/08: Normative fvsiz/rvoff/rvsiz 3D JPIP query grammar and substantiated 3D fidelity/workspace reporting")
    func normative3DQueryGrammarAndSubstantiatedFidelity() async throws {
        // 1. Query round-trip for fvsiz, rvoff, rvsiz
        var qReq = JPIPRequest(target: "vol.jp3d")
        qReq.fvsiz = [8, 6, 4]
        qReq.fvsizRoundDirection = "closest"
        qReq.rvoff = [2, 1, 1]
        qReq.rvsiz = [4, 4, 2]
        qReq.streamType = .jppStream

        let transport = JPIPTransport(baseURL: URL(string: "http://127.0.0.1:9999")!)
        let formattedQuery = await transport.buildPathAndQuery(from: qReq)
        #expect(formattedQuery.contains("fvsiz=8,6,4,closest"))
        #expect(formattedQuery.contains("rvoff=2,1,1"))
        #expect(formattedQuery.contains("rvsiz=4,4,2"))
        #expect(!formattedQuery.contains("zoff="))
        #expect(!formattedQuery.contains("zsiz="))
        #expect(!formattedQuery.contains("reslevels="))
        await transport.close()

        let reparsed = JPIPRequest.parseHTTPTarget(formattedQuery)
        try reparsed.validateParameters()
        #expect(reparsed.fvsiz == [8, 6, 4])
        #expect(reparsed.fvsizRoundDirection == "closest")
        #expect(reparsed.rvoff == [2, 1, 1])
        #expect(reparsed.rvsiz == [4, 4, 2])

        // 2. Substantiated 3D fidelity: reversible full -> .exactSamples; lossy -> .lossy; reduced layer -> .lossy; non-JP3D -> malformedInput
        let vol = makeGreyVolume(width: 16, height: 16, depth: 4)
        let losslessTwoLayer = try await JP3DEncoder(
            configuration: JP3DEncoderConfiguration(
                compressionMode: .lossless,
                qualityLayers: 2,
                levelsX: 1,
                levelsY: 1,
                levelsZ: 1
            )
        ).encode(vol)
        let lossyVol = try await JP3DEncoder(
            configuration: JP3DEncoderConfiguration(
                compressionMode: .lossy(psnr: 36.0),
                qualityLayers: 1,
                levelsX: 1,
                levelsY: 1,
                levelsZ: 1
            )
        ).encode(vol)

        let server = JPIPServer(port: 0)
        await server.registerImageData(name: "rev2.jp3d", data: losslessTwoLayer.data)
        await server.registerImageData(name: "lossy.jp3d", data: lossyVol.data)
        await server.registerImageData(name: "rawblob", data: Data("not-a-jp3d-codestream".utf8))
        try await server.start()
        defer { Task { try? await server.stop() } }
        let port = await server.listeningPort

        let session = JPIPStreamingSession(server: server, port: port)
        let fullRegion = JP3DStreamingRegion(xRange: 0..<16, yRange: 0..<16, zRange: 0..<4, qualityLayer: 0, resolutionLevel: 0)
        let exactDelivered = try await session.deliverVolumeRegion(volumeID: "rev2.jp3d", region: fullRegion)
        #expect(exactDelivered.report.fidelity == .exactSamples)
        #expect((exactDelivered.report.peakWorkspaceBytes ?? 0) > losslessTwoLayer.data.count)

        let layer1Region = JP3DStreamingRegion(xRange: 0..<16, yRange: 0..<16, zRange: 0..<4, qualityLayer: 1, resolutionLevel: 0)
        let partialLayerDelivered = try await session.deliverVolumeRegion(volumeID: "rev2.jp3d", region: layer1Region)
        #expect(partialLayerDelivered.report.fidelity == .lossy)

        let lossyDelivered = try await session.deliverVolumeRegion(volumeID: "lossy.jp3d", region: fullRegion)
        #expect(lossyDelivered.report.fidelity == .lossy)

        do {
            _ = try await session.deliverVolumeRegion(volumeID: "rawblob", region: fullRegion)
            Issue.record("Expected non-JP3D target in deliverVolumeRegion to throw CodecError")
        } catch let err as CodecError {
            #expect(err.category == .unsupportedFormat || err.category == .malformedInput)
        }

        let tinyWorkspace = try ResourceLimits(maximumWorkspaceBytes: 256)
        do {
            _ = try await session.deliverVolumeRegion(
                volumeID: "rev2.jp3d",
                region: fullRegion,
                options: JPIPStreamingOptions(resourceLimits: tinyWorkspace)
            )
            Issue.record("Expected tight maximumWorkspaceBytes to reject deliverVolumeRegion")
        } catch let err as CodecError {
            #expect(err.category == .resourceLimitExceeded)
        }

        try await session.close()
        try await server.stop()
    }

    // MARK: - F04-09 Prompt Structured Task Cancellation & Bounded WebSocket Timeout

    @Test("F04-09: Stalled TCP HTTP and WebSocket requests respond promptly to task cancellation and request timeout")
    func stalledTCPTransportsCancelAndTimeoutPromptly() async throws {
        // Read the complete request, then deliberately send no response. Readiness
        // establishes stalled I/O before measuring cancellation responsiveness.
        let peer = try R3OwnedScriptedPeer(connections: 2) { connection, index, peer in
            guard try connection.readHTTPRequest() != nil else {
                throw R3ScriptedPeerFailure("Request \(index) closed before headers arrived")
            }
            peer.mark("request.\(index)")
        }
        defer { peer.close() }
        try await peer.waitForStartup()
        let clock = ContinuousClock()
        let httpTransport = JPIPTransport(baseURL: URL(string: "http://127.0.0.1:\(peer.port)")!)
        let httpTask = Task {
            do {
                var request = JPIPRequest(target: "stalled.j2k")
                request.streamType = .jppStream
                return try await httpTransport.send(request)
            } catch {
                peer.recordClientFailure(error, before: "request.1")
                throw error
            }
        }
        do {
            try await peer.waitFor("request.1")
            peer.mark("http.cancel")
            let cancelledAt = clock.now
            httpTask.cancel()
            await #expect(throws: CancellationError.self) { _ = try await httpTask.value }
            let httpElapsed = clock.now - cancelledAt
            peer.mark("http.caller.resumed")
            #expect(httpElapsed < .seconds(2), "\(peer.diagnostics)")
            await httpTransport.close()
        } catch {
            httpTask.cancel()
            _ = try? await httpTask.value
            await httpTransport.close()
            let stopped = await peer.stopAndObserve()
            throw R3ScriptedPeerFailure("HTTP cancellation setup failed: \(error); stopped=\(stopped); \(peer.diagnostics)")
        }

        let wsTransport = JPIPWebSocketTransport(
            url: URL(string: "ws://127.0.0.1:\(peer.port)/jpip")!,
            requestTimeout: 15.0
        )
        let wsConnectTask = Task {
            do { try await wsTransport.connect() }
            catch {
                peer.recordClientFailure(error, before: "request.2")
                throw error
            }
        }
        do {
            try await peer.waitFor("request.2")
            peer.mark("websocket.cancel")
            let cancelledAt = clock.now
            wsConnectTask.cancel()
            await #expect(throws: CancellationError.self) { try await wsConnectTask.value }
            let wsElapsed = clock.now - cancelledAt
            peer.mark("websocket.caller.resumed")
            #expect(wsElapsed < .seconds(2), "\(peer.diagnostics)")
            await wsTransport.disconnect()
        } catch {
            wsConnectTask.cancel()
            _ = try? await wsConnectTask.value
            await wsTransport.disconnect()
            let stopped = await peer.stopAndObserve()
            throw R3ScriptedPeerFailure("WebSocket cancellation setup failed: \(error); stopped=\(stopped); \(peer.diagnostics)")
        }
        let stopped = await peer.stopAndObserve()
        #expect(stopped, "\(peer.diagnostics)")
        #expect(peer.failures.isEmpty, "\(peer.diagnostics)")
    }

    // MARK: - F04-10 Corrupt Codestream Propagates Error Instead of Raw Octet-Stream Fallback

    @Test("F04-10: Corrupt or truncated JPEG 2000 target propagates error / HTTP 422 instead of raw octet-stream")
    func corruptCodestreamPropagatesErrorInsteadOfRawFallback() async throws {
        // Starts with JPEG 2000 SOC (0xFF 0x4F) followed by truncated SIZ marker
        let corruptCodestream = Data([0xFF, 0x4F, 0xFF, 0x51, 0x00, 0x29, 0x00, 0x00])
        let server = JPIPServer(port: 0)
        await server.registerImageData(name: "corrupt.j2k", data: corruptCodestream)
        try await server.start()
        defer { Task { try? await server.stop() } }
        let port = await server.listeningPort

        // Direct actor request throws rather than returning 200 application/octet-stream
        let untypedReq = JPIPRequest(target: "corrupt.j2k")
        await #expect(throws: (any Error).self) {
            _ = try await server.handleRequest(untypedReq)
        }

        // Live HTTP wire request returns 422 Unprocessable Content (not 200 OK raw bytes)
        let conn = try JPIPTCPConnection.connect(host: "127.0.0.1", port: port, timeoutSeconds: 5)
        defer { conn.close() }
        try conn.writeHTTPRequest(
            method: "GET",
            pathAndQuery: "/jpip?target=corrupt.j2k&type=jpp-stream",
            hostHeader: "127.0.0.1:\(port)"
        )
        let wireResp = try conn.readHTTPResponse(maxBodyBytes: 65_536)
        #expect(wireResp.statusCode == 422)

        try await server.stop()
    }

    // MARK: - RA2-06 JPIP 3D Verification Allocation Telemetry & Combined Retained Budget

    @Test("RA2-06: deliverVolumeRegion propagates verification pixel/copy telemetry and enforces combined retained cache + codestream + decode workspace")
    func deliverVolumeRegionVerificationTelemetryAndCombinedBudget() async throws {
        let vol = makeGreyVolume(width: 16, height: 16, depth: 4)
        let encoded = try await JP3DEncoder(
            configuration: JP3DEncoderConfiguration(
                compressionMode: .lossless,
                qualityLayers: 1,
                levelsX: 1,
                levelsY: 1,
                levelsZ: 1
            )
        ).encode(vol)

        let standaloneDecoded = try await VolumeDecoder().decode(encoded.data)
        let standaloneWS = try #require(standaloneDecoded.report.peakWorkspaceBytes)

        let server = JPIPServer(port: 0)
        await server.registerImageData(name: "vol.jp3d", data: encoded.data)
        try await server.start()
        defer { Task { try? await server.stop() } }
        let port = await server.listeningPort
        let url = URL(string: "http://127.0.0.1:\(port)")!

        let session1 = JPIPStreamingSession(serverURL: url)
        let fullRegion = JP3DStreamingRegion(
            xRange: 0..<16,
            yRange: 0..<16,
            zRange: 0..<4,
            qualityLayer: 0,
            resolutionLevel: 0
        )
        let delivered = try await session1.deliverVolumeRegion(
            volumeID: "vol.jp3d",
            region: fullRegion
        )
        try await session1.close()

        #expect(!delivered.bins.isEmpty)
        #expect(delivered.report.fidelity == .exactSamples)
        #expect((delivered.report.pixelAllocationCount ?? 0) > 0)
        #expect((delivered.report.peakPixelBytes ?? 0) >= 16 * 16 * 4)
        #expect(!delivered.report.copyEvents.isEmpty)

        let totalBinBytes = delivered.bins.reduce(0) { $0 + $1.data.count }
        let deliveredWS = try #require(delivered.report.peakWorkspaceBytes)
        #expect(deliveredWS > standaloneWS)
        #expect(deliveredWS > totalBinBytes)
        // Returned fragments and their descriptors remain live alongside the
        // assembled cache; a maximum of the payload counts would miss this overlap.
        let returnedStorage = totalBinBytes + delivered.bins.count * MemoryLayout<JP3DDataBin>.stride
        #expect(deliveredWS >= standaloneWS + returnedStorage)

        let snapshotClient = JP3DJPIPClient(serverURL: url)
        try await snapshotClient.connect()
        try await snapshotClient.createSession(volumeID: "vol.jp3d")
        let snapshotBins = try await snapshotClient.requestRegion(fullRegion)
        let snapshotReturned = snapshotBins.reduce(0) { $0 + $1.data.count }
            + snapshotBins.count * MemoryLayout<JP3DDataBin>.stride
        let wideSnapshot = try await snapshotClient.verificationCacheSnapshot(
            limits: .default, retainingAdditionalBytes: snapshotReturned
        )
        #expect(!wideSnapshot.bins.isEmpty)
        #expect(wideSnapshot.retainedWorkspaceBytes > snapshotReturned)
        // This boundary fails at the pre-snapshot admission point, before any
        // reconstructed stream or verification decoder can allocate storage.
        do {
            _ = try await snapshotClient.verificationCacheSnapshot(
                limits: try ResourceLimits(maximumWorkspaceBytes: wideSnapshot.retainedWorkspaceBytes - 1),
                retainingAdditionalBytes: snapshotReturned
            )
            Issue.record("Expected retained-cache snapshot admission failure")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
            #expect(error.message.contains("before snapshot allocation"))
        }
        await snapshotClient.disconnect()

        // Pick a workspace limit strictly above standalone decode and bin payload individually,
        // but strictly below the simultaneous retained cache + reconstructed codestream + decode workspace.
        let tightCombinedWS = max(standaloneWS, totalBinBytes) + 16
        #expect(tightCombinedWS < deliveredWS)

        let completedPhases = Mutex<Int>(0)
        let session2 = JPIPStreamingSession(serverURL: url)
        do {
            _ = try await session2.deliverVolumeRegion(
                volumeID: "vol.jp3d",
                region: fullRegion,
                options: JPIPStreamingOptions(
                    resourceLimits: try ResourceLimits(maximumWorkspaceBytes: tightCombinedWS),
                    progress: { update in
                        if update.phase == .completed {
                            completedPhases.withLock { $0 += 1 }
                        }
                    }
                )
            )
            Issue.record("Expected combined retained JPIP + verification workspace limit to throw CodecError(.resourceLimitExceeded)")
        } catch let err as CodecError {
            #expect(err.category == .resourceLimitExceeded)
        }
        #expect(completedPhases.withLock { $0 } == 0)

        try await session2.close()
        try await server.stop()
    }

    // MARK: - RA2-07 HTTP & WebSocket Operation Deadlines Without External Task Cancellation

    @Test("RA2-07: ResourceLimits.deadlineSeconds aborts silent HTTP and WebSocket peers promptly without external Task.cancel and cleans up pending WS requests")
    func httpAndWebSocketDeadlinesAbortSilentPeersPromptlyWithoutExternalCancel() async throws {
        // Dedicated foreground workers own blocking accept/read operations. A
        // completed read leaves the accepted socket held until explicit stop.
        let httpPeer = try R3OwnedScriptedPeer(connections: 1) { connection, index, peer in
            if try connection.readHTTPRequest() != nil { peer.mark("request.\(index)") }
        }
        defer { httpPeer.close() }
        try await httpPeer.waitForStartup()
        let clock = ContinuousClock()
        let httpSession = JPIPStreamingSession(
            serverURL: URL(string: "http://127.0.0.1:\(httpPeer.port)/jpip")!
        )
        let t0 = clock.now
        httpPeer.mark("http.deadline.begin")
        do {
            do {
                _ = try await httpSession.deliverImage(
                    imageID: "silent.j2k",
                    options: JPIPStreamingOptions(
                        resourceLimits: try ResourceLimits(deadlineSeconds: 0.12)
                    )
                )
                Issue.record("Expected silent HTTP peer to time out with CodecError(.resourceLimitExceeded)")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }
            let httpElapsed = clock.now - t0
            httpPeer.mark("http.deadline.caller.resumed")
            #expect(httpElapsed < .seconds(2), "\(httpPeer.diagnostics)")
            try? await httpSession.close()
        } catch {
            try? await httpSession.close()
            let stopped = await httpPeer.stopAndObserve()
            throw R3ScriptedPeerFailure("HTTP deadline failed: \(error); stopped=\(stopped); \(httpPeer.diagnostics)")
        }
        let httpStopped = await httpPeer.stopAndObserve()
        #expect(httpStopped, "\(httpPeer.diagnostics)")

        // Two clients complete RFC 6455 handshakes, then receive no response to
        // their request frames. Both original deadline cases stay unchanged.
        let wsPeer = try R3OwnedScriptedPeer(connections: 2) { connection, index, peer in
            guard let request = try connection.readHTTPRequest(),
                  let key = request.header("Sec-WebSocket-Key") else {
                throw R3ScriptedPeerFailure("WebSocket \(index) has no handshake key")
            }
            peer.mark("handshake.read.\(index)")
            try connection.writeWebSocketServerHandshake(clientKey: key)
            peer.mark("handshake.written.\(index)")
            _ = try connection.readWebSocketFrame(requireMasked: true)
            peer.mark("request.\(index)")
        }
        defer { wsPeer.close() }
        try await wsPeer.waitForStartup()
        let wsSession = JPIPStreamingSession(
            serverURL: URL(string: "ws://127.0.0.1:\(wsPeer.port)/jpip")!
        )
        let t1 = clock.now
        wsPeer.mark("session.deadline.begin")
        do {
            do {
                _ = try await wsSession.deliverImage(
                    imageID: "silent-ws.j2k",
                    options: JPIPStreamingOptions(
                        resourceLimits: try ResourceLimits(deadlineSeconds: 0.12)
                    )
                )
                Issue.record("Expected silent WebSocket peer to time out with CodecError(.resourceLimitExceeded)")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }
            let sessionElapsed = clock.now - t1
            wsPeer.mark("session.deadline.caller.resumed")
            #expect(sessionElapsed < .seconds(2), "\(wsPeer.diagnostics)")
            try? await wsSession.close()
        } catch {
            try? await wsSession.close()
            let stopped = await wsPeer.stopAndObserve()
            throw R3ScriptedPeerFailure("WebSocket session deadline failed: \(error); stopped=\(stopped); \(wsPeer.diagnostics)")
        }

        let wsTransport = JPIPWebSocketTransport(
            url: URL(string: "ws://127.0.0.1:\(wsPeer.port)/jpip")!,
            requestTimeout: 30.0
        )
        do {
            wsPeer.mark("direct.connect.begin")
            try await wsTransport.connect(deadline: clock.now + .seconds(2))
            wsPeer.mark("direct.connect.returned")
            let t2 = clock.now
            do {
                _ = try await wsTransport.sendRequest(
                    JPIPRequest(target: "silent-ws.j2k"),
                    timeout: 0.12
                )
                Issue.record("Expected JPIPWebSocketTransport.sendRequest(timeout: 0.12) to throw CodecError(.resourceLimitExceeded)")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }
            let requestElapsed = clock.now - t2
            wsPeer.mark("direct.request.caller.resumed")
            #expect(requestElapsed < .seconds(2), "\(wsPeer.diagnostics)")
            #expect(await wsTransport.pendingRequestCount == 0)
            await wsTransport.disconnect()
        } catch {
            await wsTransport.disconnect()
            let stopped = await wsPeer.stopAndObserve()
            throw R3ScriptedPeerFailure("Direct WebSocket deadline failed: \(error); stopped=\(stopped); \(wsPeer.diagnostics)")
        }
        let wsStopped = await wsPeer.stopAndObserve()
        #expect(wsStopped, "\(wsPeer.diagnostics)")
    }

    // MARK: - Helpers

    private func makeGreyImage(width: Int, height: Int) -> J2KImage {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                bytes[y * width + x] = UInt8((x * 13 + y * 29) & 0xFF)
            }
        }
        return J2KImage(
            width: width,
            height: height,
            components: [
                J2KComponent(
                    index: 0,
                    bitDepth: 8,
                    signed: false,
                    width: width,
                    height: height,
                    data: Data(bytes)
                )
            ]
        )
    }

    private func makeGreyVolume(width: Int, height: Int, depth: Int) -> J2KVolume {
        var bytes = [UInt8](repeating: 0, count: width * height * depth)
        for z in 0..<depth {
            for y in 0..<height {
                for x in 0..<width {
                    bytes[(z * height + y) * width + x] = UInt8((x * 7 + y * 11 + z * 23) & 0xFF)
                }
            }
        }
        return J2KVolume(
            width: width,
            height: height,
            depth: depth,
            components: [
                J2KVolumeComponent(
                    index: 0,
                    bitDepth: 8,
                    signed: false,
                    width: width,
                    height: height,
                    depth: depth,
                    data: Data(bytes)
                )
            ]
        )
    }
}
