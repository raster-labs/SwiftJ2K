// SPDX-License-Identifier: Apache-2.0
//
// R3JPIPRemediationTests.swift
// SwiftJ2KJPIPTests
//
// Phase R3 (F04) normative JPIP verification suite covering ITU-T Rec. T.808 (12/2022) V2 |
// ISO/IEC 15444-9 wire framing, Table A.2 data-bin classes, multi-byte VBAS + malformed input
// rejection, Clause D.3 EOR messages, Clause C.8.1 `model=` cache grammar, out-of-order/partial
// `Msg-Offset` interval merging, real POSIX TCP HTTP/1.1 (`jpp-stream` & `jpt-stream` over
// `.j2k`, `.jph`, and `.jp2` `phld`), stateful `cid=` delta deduplication + `cclose`, stateless
// `model=`, `len=` partial-bin splitting & resumption, real TCP RFC 6455 WebSocket (`101`
// upgrade, multiplexing, server push, ping/pong), real TCP 3D JP3D JPIP (`http://` & `ws://`),
// and deterministic T.808 V3 HTTP/3 rejection.

import Foundation
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2K3D
@testable import SwiftJ2KJPIP

@Suite("Phase R3 — F04 Normative JPIP HTTP/1.1, Data-Bin, 3D, and RFC 6455 WebSocket")
struct R3JPIPRemediationTests {

    // MARK: - Helpers

    private func makeTestImage(width: Int = 32, height: Int = 24, components: Int = 3) -> J2KImage {
        var comps: [J2KComponent] = []
        for c in 0..<components {
            var bytes = Data(count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    bytes[y * width + x] = UInt8((x * 13 + y * 19 + c * 47 + (x ^ y)) & 0xFF)
                }
            }
            comps.append(
                J2KComponent(
                    index: c,
                    bitDepth: 8,
                    signed: false,
                    width: width,
                    height: height,
                    data: bytes
                )
            )
        }
        return J2KImage(
            width: width,
            height: height,
            components: comps,
            colorSpace: components == 3 ? .sRGB : .grayscale
        )
    }

    private func makeTestVolume(width: Int = 16, height: Int = 12, depth: Int = 6) -> J2KVolume {
        var bytes = Data(count: width * height * depth)
        for z in 0..<depth {
            for y in 0..<height {
                for x in 0..<width {
                    bytes[z * width * height + y * width + x] = UInt8((x * 7 + y * 11 + z * 29 + 5) & 0xFF)
                }
            }
        }
        let comp = J2KVolumeComponent(
            index: 0,
            bitDepth: 8,
            signed: false,
            width: width,
            height: height,
            depth: depth,
            data: bytes
        )
        return J2KVolume(width: width, height: height, depth: depth, components: [comp])
    }

    // MARK: - 1. Normative Table A.2 Wire Classes, Multi-Byte VBAS, and Clause D.3 EOR

    @Test("ITU-T T.808 Table A.2 wire class IDs, multi-byte VBAS, and Clause D.3 EOR round-trip cleanly")
    func normativeTableA2WireClassesAndVBAS() throws {
        #expect(JPIPDataBinClass.precinct.wireClassID == 0)
        #expect(JPIPDataBinClass.extendedPrecinct.wireClassID == 1)
        #expect(JPIPDataBinClass.tileHeader.wireClassID == 2)
        #expect(JPIPDataBinClass.tile.wireClassID == 4)
        #expect(JPIPDataBinClass.extendedTile.wireClassID == 5)
        #expect(JPIPDataBinClass.mainHeader.wireClassID == 6)
        #expect(JPIPDataBinClass.metadata.wireClassID == 8)
        #expect(JPIPDataBinClass(wireClassID: 3) == nil)
        #expect(JPIPDataBinClass(wireClassID: 7) == nil)

        for value: UInt64 in [0, 1, 15, 16, 127, 128, 16_383, 16_384, 2_097_151, 268_435_455] {
            let encoded = JPIPWireCodec.encodeVBAS(value)
            var cursor = 0
            let decoded = try JPIPWireCodec.decodeVBAS(from: encoded, offset: &cursor)
            #expect(decoded == value)
            #expect(cursor == encoded.count)
        }

        let bins: [JPIPDataBin] = [
            JPIPDataBin(binClass: .mainHeader, binID: 0, data: Data([0xFF, 0x4F, 0xFF, 0x51]), isComplete: true),
            JPIPDataBin(binClass: .tileHeader, binID: 3, data: Data([0xFF, 0x52]), isComplete: true),
            JPIPDataBin(binClass: .precinct, binID: 4097, data: Data(repeating: 0x5A, count: 300), isComplete: false, msgOffset: 128),
            JPIPDataBin(binClass: .extendedPrecinct, binID: 19, data: Data([0x11, 0x22, 0x33]), isComplete: true, codestreamID: 2, msgOffset: 0, aux: 3),
            JPIPDataBin(binClass: .metadata, binID: 0, data: Data("jp2h".utf8), isComplete: true)
        ]

        let wire = JPIPWireCodec.encodeStream(
            bins: bins,
            eor: JPIPEORMessage(reason: .byteLimitReached, body: Data([0xAA]))
        )
        let parsed = try JPIPWireCodec.decodeStream(wire)
        #expect(parsed.bins.count == bins.count)
        for (lhs, rhs) in zip(parsed.bins, bins) {
            #expect(lhs.binClass == rhs.binClass)
            #expect(lhs.binID == rhs.binID)
            #expect(lhs.data == rhs.data)
            #expect(lhs.isComplete == rhs.isComplete)
            #expect(lhs.msgOffset == rhs.msgOffset)
            #expect(lhs.aux == rhs.aux)
        }
        #expect(parsed.eor?.reason == .byteLimitReached)
        #expect(parsed.eor?.reason.rawValue == 0x04)
        #expect(parsed.eor?.body == Data([0xAA]))
    }

    @Test("Malformed VBAS, bb == 0, <3-byte EOR, trailing bytes after EOR, and truncated payloads fail deterministically")
    func malformedVBASAndEORRejection() {
        // 1. Unterminated VBAS continuation bit at EOF
        #expect(throws: (any Error).self) {
            _ = try JPIPWireCodec.decodeStream(Data([0x81, 0x82]))
        }
        // 2. Overlong >9-byte VBAS overflow
        #expect(throws: (any Error).self) {
            _ = try JPIPWireCodec.decodeStream(Data(repeating: 0x81, count: 10) + Data([0x01]))
        }
        // 3. Invalid `bb == 0` when first byte != 0x00 (reserved per T.808 Annex A.2)
        #expect(throws: (any Error).self) {
            // Bin-ID first byte with bits 6..5 (`bb`) == 00 and non-zero value `0x05`
            _ = try JPIPWireCodec.decodeStream(Data([0x05, 0x00, 0x00]))
        }
        // 4. Truncated <3-byte EOR (`0x00` followed by only 1 byte)
        #expect(throws: (any Error).self) {
            _ = try JPIPWireCodec.decodeStream(Data([0x00, 0x02]))
        }
        // 5. Trailing garbage after valid 3-byte EOR `[0x00, 0x02, 0x00]`
        #expect(throws: (any Error).self) {
            _ = try JPIPWireCodec.decodeStream(Data([0x00, 0x02, 0x00, 0x01]))
        }
        // 6. Truncated Msg-Length body (claims 50 bytes, only 4 bytes present)
        #expect(throws: (any Error).self) {
            var bad = Data([0x50, 0x06, 0x00, 50]) // bb=2 (Class follows) + Last=1 + id=0, class=6, off=0, len=50
            bad.append(contentsOf: [1, 2, 3, 4])
            _ = try JPIPWireCodec.decodeStream(bad)
        }
    }

    // MARK: - 2. Clause C.8.1 Cache-Model Grammar & Msg-Offset Interval Merging

    @Test("Clause C.8.1 model= grammar and out-of-order / overlapping / partial Msg-Offset merging")
    func cacheModelGrammarAndIntervalMerging() {
        var cache = JPIPCacheModel(maxCacheSize: 1_048_576, maxEntries: 1024)

        // Deliver precinct 7 in three out-of-order / overlapping fragments:
        // [4..<8], [0..<5], [6..<10] (isComplete = true on final tail)
        let full = Data([10, 11, 12, 13, 14, 15, 16, 17, 18, 19])
        cache.addDataBin(JPIPDataBin(binClass: .precinct, binID: 7, data: Data(full[4..<8]), isComplete: false, msgOffset: 4))
        #expect(!cache.hasCompleteDataBin(binClass: .precinct, binID: 7))
        #expect(cache.deliveredPrefixLength(binClass: .precinct, binID: 7) == 0)

        cache.addDataBin(JPIPDataBin(binClass: .precinct, binID: 7, data: Data(full[0..<5]), isComplete: false, msgOffset: 0))
        #expect(!cache.hasCompleteDataBin(binClass: .precinct, binID: 7))
        #expect(cache.deliveredPrefixLength(binClass: .precinct, binID: 7) == 8)

        cache.addDataBin(JPIPDataBin(binClass: .precinct, binID: 7, data: Data(full[6..<10]), isComplete: true, msgOffset: 6))
        #expect(cache.hasCompleteDataBin(binClass: .precinct, binID: 7))
        #expect(cache.getDataBin(binClass: .precinct, binID: 7)?.data == full)

        // Add complete Hm, Ht0, M0, and partial P9:12
        cache.addDataBin(JPIPDataBin(binClass: .mainHeader, binID: 0, data: Data([0xFF, 0x4F]), isComplete: true))
        cache.addDataBin(JPIPDataBin(binClass: .tileHeader, binID: 0, data: Data([0xFF, 0x90]), isComplete: true))
        cache.addDataBin(JPIPDataBin(binClass: .metadata, binID: 0, data: Data(count: 28), isComplete: true))
        cache.addDataBin(JPIPDataBin(binClass: .precinct, binID: 9, data: Data(repeating: 0x33, count: 12), isComplete: false, msgOffset: 0))

        let tokens = cache.formatCacheModelField()
        #expect(tokens.contains("Hm"))
        #expect(tokens.contains("H0"))
        #expect(!tokens.contains("Ht0"))
        #expect(tokens.contains("M0"))
        #expect(tokens.contains("P7"))
        #expect(tokens.contains("P9:12"))

        // Parse back into server session including subtractive `-H0`
        let parsedStatements = JPIPCacheModel.parseCacheModelField(tokens + ["-H0"])
        #expect(parsedStatements.contains(where: { !$0.isAdditive && $0.binClass == .tileHeader && $0.binID == 0 }))
    }

    // MARK: - 3. Real TCP HTTP/1.1 JPP & JPT, JP2 Placeholder Box, Stateful Delta, Stateless model=, len= Resumption

    @Test("Real TCP HTTP/1.1 jpp-stream and jpt-stream over .j2k, .jph (HTJ2K), and .jp2 (phld) reconstruct bit-exact pixels")
    func realTCPHTTP11JPPAndJPTBitExact() async throws {
        let sourceImage = makeTestImage(width: 32, height: 24, components: 3)

        let j2kData = try await J2KEncoder(
            encodingConfiguration: J2KEncodingConfiguration(
                quality: 1.0,
                lossless: true,
                decompositionLevels: 2,
                qualityLayers: 2
            )
        ).encode(sourceImage)

        let contractImg = try sourceImage.toContractImage()
        let expectedBytes = try contractImg.storage.withUnsafeBytes { Data($0) }
        let jphData = try await Encoder(
            configuration: try EncoderConfiguration(
                mode: .lossless,
                codecOptions: try CodecOptions(
                    decompositionLevels: 2,
                    blockCoding: .htj2k,
                    containerFormat: .jph
                )
            )
        ).encode(contractImg).data
        let jp2Data = try await Encoder(
            configuration: try EncoderConfiguration(
                mode: .lossless,
                codecOptions: try CodecOptions(
                    decompositionLevels: 2,
                    blockCoding: .part1,
                    containerFormat: .jp2
                )
            )
        ).encode(contractImg).data

        let server = JPIPServer(port: 0, host: "127.0.0.1")
        await server.registerImageData(name: "lossless.j2k", data: j2kData)
        await server.registerImageData(name: "lossless.jph", data: jphData)
        await server.registerImageData(name: "lossless.jp2", data: jp2Data)
        try await server.start()
        defer { Task { try? await server.stop() } }

        let port = await server.listeningPort
        #expect(port > 0)
        let baseURL = URL(string: "http://127.0.0.1:\(port)")!

        for target in ["lossless.j2k", "lossless.jph", "lossless.jp2"] {
            for streamType in [JPIPStreamType.jppStream, JPIPStreamType.jptStream] {
                let client = JPIPClient(serverURL: baseURL)
                let sess = try await client.createSession(target: target)
                var req = JPIPRequest(target: "")
                req.streamType = streamType
                let (resp, parsed) = try await client.sendStreamRequest(req)
                #expect(resp.statusCode == 200)
                #expect(resp.headers["Content-Type"] == streamType.contentTypeHeader)
                #expect(parsed.eorReason == JPIPEORReason.imageDone || parsed.eorReason == JPIPEORReason.windowDone)
                if target.hasSuffix(".jp2") || target.hasSuffix(".jph") {
                    // Verify ISO/IEC 15444-9 `Class 8` metadata bin #0 contains the 28-byte `phld` box
                    let allBins = await sess.cachedDataBins()
                    let meta0 = allBins.first(where: { $0.binClass == JPIPDataBinClass.metadata && $0.binID == 0 })
                    #expect(meta0 != nil)
                    let phldMagic = Data("phld".utf8)
                    #expect(meta0?.data.range(of: phldMagic) != nil)
                }

                let reassembled = try await client.reconstructCachedCodestream(reconstructContainer: true)
                let decoded = try await Decoder().decode(reassembled).image
                #expect(decoded.descriptor.width == 32)
                #expect(decoded.descriptor.height == 24)
                let actualBytes = try decoded.storage.withUnsafeBytes { Data($0) }
                #expect(actualBytes == expectedBytes)
                try await client.close()
            }
        }

        try await server.stop()
    }

    @Test("Stateful cid= delta deduplication, cclose teardown, stateless model=, and len= byte-limited partial-bin resumption")
    func statefulDeltaStatelessModelAndByteLimitedResumption() async throws {
        let sourceImage = makeTestImage(width: 48, height: 32, components: 3)
        let contractImg = try sourceImage.toContractImage()
        let expectedBytes = try contractImg.storage.withUnsafeBytes { Data($0) }
        let j2kData = try await Encoder(
            configuration: try EncoderConfiguration(
                mode: .lossless,
                codecOptions: try CodecOptions(
                    decompositionLevels: 2,
                    blockCoding: .part1,
                    containerFormat: .codestream
                )
            )
        ).encode(contractImg).data

        let server = JPIPServer(port: 0, host: "127.0.0.1")
        await server.registerImageData(name: "delta.j2k", data: j2kData)
        try await server.start()
        defer { Task { try? await server.stop() } }
        let baseURL = URL(string: "http://127.0.0.1:\(await server.listeningPort)")!

        // 1. Stateful `cid=` zero-duplicate delta + Clause C.8.1.2 wildcard rejection + `cclose`
        let statefulClient = JPIPClient(serverURL: baseURL)
        let session = try await statefulClient.createSession(target: "delta.j2k")
        let cid = try #require(await session.channelID)

        var fullReq = JPIPRequest(target: "")
        fullReq.cid = cid
        fullReq.streamType = .jppStream
        let (_, firstStream) = try await statefulClient.sendStreamRequest(fullReq)
        #expect(!firstStream.bins.isEmpty)

        // Second identical request on the same channel MUST deliver 0 duplicate bins!
        let (_, secondStream) = try await statefulClient.sendStreamRequest(fullReq)
        #expect(secondStream.bins.isEmpty)
        #expect(secondStream.eorReason == JPIPEORReason.imageDone || secondStream.eorReason == JPIPEORReason.windowDone)

        // Clause C.8.1.2: additive wildcard `P*` on stateful `cid=` must be rejected (HTTP 400)
        let wildcardTransport = JPIPTransport(baseURL: baseURL)
        var badWildcardReq = JPIPRequest(target: "")
        badWildcardReq.cid = cid
        badWildcardReq.model = ["P*"]
        do {
            let badWildcardResp = try await wildcardTransport.send(badWildcardReq)
            #expect(badWildcardResp.statusCode == 400)
        } catch {
            #expect("\(error)".contains("400"))
        }
        await wildcardTransport.close()

        // Close channel via `cclose` and verify subsequent use of closed `cid` returns HTTP 410
        try await statefulClient.closeChannel()
        let rawTransport = JPIPTransport(baseURL: baseURL)
        var staleReq = JPIPRequest(target: "")
        staleReq.cid = cid
        do {
            let staleResp = try await rawTransport.send(staleReq)
            #expect(staleResp.statusCode == 410)
        } catch {
            #expect("\(error)".contains("410"))
        }
        await rawTransport.close()
        try await statefulClient.close()

        // 2. Stateless `model=` deduplication without `cnew`/`cid`
        let statelessTransport = JPIPTransport(baseURL: baseURL)
        var statelessCache = JPIPCacheModel(maxCacheSize: 16 * 1024 * 1024, maxEntries: 4096)
        var sReq1 = JPIPRequest(target: "delta.j2k")
        sReq1.streamType = .jppStream
        let sResp1 = try await statelessTransport.send(sReq1)
        let sParsed1 = try JPIPWireCodec.decodeStream(sResp1.data)
        #expect(!sParsed1.bins.isEmpty)
        for b in sParsed1.bins { statelessCache.addDataBin(b) }

        var sReq2 = JPIPRequest(target: "delta.j2k")
        sReq2.streamType = .jppStream
        sReq2.model = statelessCache.formatCacheModelField()
        let sResp2 = try await statelessTransport.send(sReq2)
        let sParsed2 = try JPIPWireCodec.decodeStream(sResp2.data)
        #expect(sParsed2.bins.isEmpty)
        #expect(sParsed2.eorReason == JPIPEORReason.imageDone || sParsed2.eorReason == JPIPEORReason.windowDone)
        await statelessTransport.close()

        // 3. Byte-limited `len=96` partial-bin VBAS splitting (`EOR=0x04`) and multi-round resumption
        let chunkedClient = JPIPClient(serverURL: baseURL)
        let chunkSession = try await chunkedClient.createSession(target: "delta.j2k")
        let chunkCID = try #require(await chunkSession.channelID)
        var rounds = 0
        var sawPartialBin = false
        var sawByteLimitEOR = false

        while rounds < 256 {
            rounds += 1
            var rReq = JPIPRequest(target: "")
            rReq.cid = chunkCID
            rReq.len = 96
            rReq.streamType = .jppStream
            let (rResp, rStream) = try await chunkedClient.sendStreamRequest(rReq)
            // Per ITU-T Rec. T.808 Clause C.6.1, `len=` bounds ordinary JPIP data-bin message bytes
            // and excludes the mandatory 3-byte End of Response (EOR) message.
            #expect(rResp.data.count >= 3)
            #expect(rStream.eor != nil)
            #expect(rResp.data.count - 3 <= 96)
            if rStream.bins.contains(where: { !$0.isComplete || $0.msgOffset > 0 }) {
                sawPartialBin = true
            }
            if rStream.eorReason == JPIPEORReason.byteLimit {
                sawByteLimitEOR = true
            } else {
                break
            }
        }

        #expect(rounds > 2)
        #expect(sawPartialBin)
        #expect(sawByteLimitEOR)

        let reassembled = try await chunkedClient.reconstructCachedCodestream(reconstructContainer: false)
        let decoded = try await Decoder().decode(reassembled).image
        let actualChunkedBytes = try decoded.storage.withUnsafeBytes { Data($0) }
        #expect(actualChunkedBytes == expectedBytes)

        try await chunkedClient.close()
        try await server.stop()
    }

    // MARK: - 4. Real TCP RFC 6455 WebSocket Upgrade, Multiplexing, Server Push, and Ping/Pong

    @Test("Real TCP RFC 6455 WebSocket 101 upgrade, multiplexed requests, live server push, and ping/pong latency")
    func realTCPRFC6455WebSocketStreamingMultiplexingAndPush() async throws {
        let imgA = makeTestImage(width: 24, height: 24, components: 1)
        let imgB = makeTestImage(width: 20, height: 16, components: 3)
        let dataA = try await Encoder(
            configuration: try EncoderConfiguration(
                mode: .lossless,
                codecOptions: try CodecOptions(containerFormat: .codestream)
            )
        ).encode(try imgA.toContractImage()).data
        let dataB = try await Encoder(
            configuration: try EncoderConfiguration(
                mode: .lossless,
                codecOptions: try CodecOptions(containerFormat: .jp2)
            )
        ).encode(try imgB.toContractImage()).data

        let wsServer = JPIPWebSocketServer(port: 0)
        await wsServer.registerImageData(name: "a.j2k", data: dataA)
        await wsServer.registerImageData(name: "b.jp2", data: dataB)
        try await wsServer.start()
        defer { Task { try? await wsServer.stop() } }

        let port = await wsServer.listeningPort
        let wsURL = URL(string: "ws://127.0.0.1:\(port)/jpip")!

        let wsClient = JPIPWebSocketClient(
            serverURL: wsURL,
            configuration: JPIPWebSocketClientConfiguration(enableHTTPFallback: false)
        )
        try await wsClient.connect()
        #expect(await wsClient.isUsingHTTPFallback == false)

        // 1. Live TCP ping/pong round-trip latency measurement
        try await wsClient.sendPing()
        for _ in 0..<50 {
            if await wsClient.getLatency() != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let latency = await wsClient.getLatency()
        #expect(latency != nil)
        #expect((latency ?? -1) >= 0)

        // 2. Concurrent multiplexed requests over the single WebSocket TCP connection
        let (respA, respB) = try await withThrowingTaskGroup(of: (String, JPIPResponse).self) { group -> (JPIPResponse, JPIPResponse) in
            group.addTask {
                var r = JPIPRequest(target: "a.j2k")
                r.streamType = .jppStream
                return ("a", try await wsClient.sendRequest(r))
            }
            group.addTask {
                var r = JPIPRequest(target: "b.jp2")
                r.streamType = .jptStream
                return ("b", try await wsClient.sendRequest(r))
            }
            var outA: JPIPResponse?
            var outB: JPIPResponse?
            for try await (tag, resp) in group {
                if tag == "a" { outA = resp } else { outB = resp }
            }
            return (try #require(outA), try #require(outB))
        }
        #expect(respA.statusCode == 200)
        #expect(respB.statusCode == 200)
        #expect(respA.headers["Content-Type"] == "image/jpp-stream")
        #expect(respB.headers["Content-Type"] == "image/jpt-stream")

        // 3. Full image session & bit-exact decode over WebSocket
        let decodedA = try await wsClient.requestImage(imageID: "a.j2k")
        #expect(decodedA.width == 24)
        #expect(decodedA.height == 24)
        #expect(decodedA.components[0].data == imgA.components[0].data)

        // 4. Live server-initiated data-bin push over the upgraded TCP socket
        let infos = await wsServer.getConnectionInfos()
        let liveConnID = try #require(infos.first?.connectionID)
        let pushedBin = JPIPDataBin(
            binClass: .precinct,
            binID: 777,
            data: Data([0xDE, 0xAD, 0xBE, 0xEF]),
            isComplete: true,
            msgOffset: 16
        )
        let pushedWire = await wsServer.pushDataBin(pushedBin, to: liveConnID)
        #expect(pushedWire != nil)

        var receivedPushed: [JPIPDataBin] = []
        for _ in 0..<50 {
            let drained = await wsClient.drainPushedDataBins()
            if !drained.isEmpty {
                receivedPushed.append(contentsOf: drained)
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(receivedPushed.count == 1)
        #expect(receivedPushed.first?.binID == 777)
        #expect(receivedPushed.first?.msgOffset == 16)
        #expect(receivedPushed.first?.data == Data([0xDE, 0xAD, 0xBE, 0xEF]))

        try await wsClient.close()
        try await wsServer.stop()
    }

    // MARK: - 5. Real TCP 3D Volumetric JPIP (HTTP/1.1 & WebSocket, EBCOT & HT-in-JP3D)

    @Test("Real TCP 3D JP3D JPIP over http:// and ws:// delivers normative VBAS bins and bit-exact 3D voxels")
    func realTCP3DJP3DOverHTTPAndWebSocket() async throws {
        let volume = makeTestVolume(width: 16, height: 12, depth: 6)
        let ebcot3D = try await JP3DEncoder(configuration: .lossless).encode(volume)
        let ht3D = try await JP3DEncoder(
            configuration: JP3DEncoderConfiguration(
                compressionMode: .losslessHTJ2K,
                levelsX: 1,
                levelsY: 1,
                levelsZ: 1
            )
        ).encode(volume)

        let server = JP3DJPIPServer(configuration: JP3DServerConfiguration(port: 0))
        try await server.registerVolume(name: "ebcot.jp3d", data: ebcot3D.data, volume: volume)
        try await server.registerVolume(name: "ht.jp3d", data: ht3D.data, volume: volume)
        try await server.start()
        defer { Task { try? await server.stop() } }

        let port = await server.listeningPort
        let schemes = ["http", "ws"]
        let targets = ["ebcot.jp3d", "ht.jp3d"]

        for scheme in schemes {
            for target in targets {
                let url = URL(string: "\(scheme)://127.0.0.1:\(port)/jpip")!
                let client = JP3DJPIPClient(serverURL: url)
                try await client.connect()
                try await client.createSession(volumeID: target)

                // Full volume delivery & bit-exact voxel verification
                let fullRegion = JP3DStreamingRegion(xRange: 0..<16, yRange: 0..<12, zRange: 0..<6)
                let bins = try await client.requestRegion(fullRegion)
                #expect(!bins.isEmpty)
                // Positively verify NO synthetic 64-byte `0xAB` placeholder bin exists
                let syntheticPlaceholder = Data(repeating: 0xAB, count: 64)
                #expect(!bins.contains(where: { $0.data == syntheticPlaceholder }))

                let decodedFull = try await client.decodeVolume()
                #expect(decodedFull.width == 16)
                #expect(decodedFull.height == 12)
                #expect(decodedFull.depth == 6)
                #expect(decodedFull.components[0].data == volume.components[0].data)

                // Sub-volume 3D ROI decode verification
                let subRegion = JP3DStreamingRegion(xRange: 4..<12, yRange: 2..<10, zRange: 1..<4)
                let decodedSub = try await client.decodeVolume(region: subRegion)
                #expect(decodedSub.width == 8)
                #expect(decodedSub.height == 8)
                #expect(decodedSub.depth == 3)
                for z in 0..<3 {
                    for y in 0..<8 {
                        for x in 0..<8 {
                            let subVal = decodedSub.components[0].data[z * 64 + y * 8 + x]
                            let refVal = volume.components[0].data[(z + 1) * (16 * 12) + (y + 2) * 16 + (x + 4)]
                            #expect(subVal == refVal)
                        }
                    }
                }

                await client.disconnect()
            }
        }

        try await server.stop()
    }

    // MARK: - 6. Negative & Security Boundary Checks (HTTP/3 Rejection & Offline Port)

    @Test("T.808 V3 HTTP/3 transport throws CodecError(.unsupportedFeature) and offline TCP ports fail without synthetic fallback")
    func http3UnsupportedAndOfflinePortFails() async throws {
        // 1. T.808 V3 HTTP/3 rejection
        let h3Transport = JPIPNetworkTransport(
            baseURL: URL(string: "https://127.0.0.1:8443/jpip")!,
            configuration: JPIPNetworkTransport.Configuration(enableHTTP3: true)
        )
        do {
            try await h3Transport.connect()
            Issue.record("Expected enableHTTP3 == true to throw CodecError(.unsupportedFeature)")
        } catch let error as CodecError {
            #expect(error.category == .unsupportedFeature)
        }

        // 2. Bind and immediately close an ephemeral TCP listener to obtain an unused closed port
        let closedPort: Int = try {
            let tmp = try JPIPTCPListener(host: "127.0.0.1", port: 0)
            let p = tmp.boundPort
            tmp.close()
            return p
        }()

        let offlineWS = JPIPWebSocketTransport(url: URL(string: "ws://127.0.0.1:\(closedPort)/jpip")!)
        await #expect(throws: (any Error).self) {
            try await offlineWS.connect()
        }

        let offlineHTTP = JPIPClient(serverURL: URL(string: "http://127.0.0.1:\(closedPort)")!)
        await #expect(throws: (any Error).self) {
            _ = try await offlineHTTP.createSession(target: "missing.j2k")
        }

        let offline3D = JP3DJPIPClient(serverURL: URL(string: "http://127.0.0.1:\(closedPort)")!)
        await #expect(throws: (any Error).self) {
            try await offline3D.connect()
        }
    }
}
