// SPDX-License-Identifier: Apache-2.0
import Foundation
import Dispatch
import Synchronization
import Testing
@testable import SwiftJ2KJPIP

@Suite("R3 independent-review allocation admission regressions")
struct CodexR3AdmissionTests {
    @Test func descriptorDenialPrecedesWireMaterialisation() throws {
        let bins = (0..<32).map { JPIPDataBin(binClass: .precinct, binID: $0, data: Data(), isComplete: true) }
        let wire = JPIPWireCodec.encodeStream(bins: bins)
        let observed = JPIPWorkspaceHighWater()
        do {
            _ = try JPIPWireCodec.decodeStream(wire, maxPayloadBytes: 4096,
                maximumStorageBytes: MemoryLayout<JPIPDataBin>.stride * 31,
                workspaceObserver: { observed.observe($0) })
            Issue.record("Expected descriptor admission failure")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
            #expect(error.message.contains("before allocation"))
        }
        // The observer is immediately before materialisation, after the complete
        // borrowed scan. A failing scan must never enter that phase.
        #expect(observed.peak == 0)
        let admitted = try JPIPWireCodec.decodeStream(wire, maxPayloadBytes: 4096,
            maximumStorageBytes: MemoryLayout<JPIPDataBin>.stride * 32)
        #expect(admitted.bins.count == 32)
    }

    @Test func cacheProjectionAndMergeDenyBeforeMutation() throws {
        var cache = JPIPCacheModel()
        let tiny = (0..<32).map { JPIPDataBin(binClass: .precinct, binID: $0, data: Data(), isComplete: true) }
        #expect(throws: CodecError.self) {
            _ = try cache.projectedAllocation(adding: tiny, maximumProjectionBytes: 1)
        }
        let payload = JPIPDataBin(binClass: .precinct, binID: 0, data: Data(repeating: 7, count: 512), isComplete: true)
        #expect(throws: CodecError.self) {
            try cache.addAdmitted([payload], limits: ResourceLimits(maximumWorkspaceBytes: 1536), retainingExternalBytes: 1024)
        }
        #expect(cache.statistics.entryCount == 0)
        #expect(cache.statistics.totalSize == 0)
    }

    @Test func remainingWireAllowanceIsAppliedBeforeTheNextRead() throws {
        let budget = JPIPTransferBudget(try ResourceLimits(maximumCompressedBytes: 64, maximumMemoryBytes: 4096))
        #expect(try budget.bodyLimit(retaining: 0) == 64)
        try budget.received(61, retaining: 0)
        #expect(try budget.bodyLimit(retaining: 1024) == 3)
        try budget.received(3, retaining: 1024)
        #expect(throws: CodecError.self) { _ = try budget.bodyLimit(retaining: 0) }
    }

    @Test func imageSessionCreationRejectsAnnouncedBodyWithoutReceivingIt() async throws {
        let peer = try HeaderOnlyAdmissionPeer(firstResponse: nil, announcedBodyBytes: 1_048_576)
        defer { peer.stop() }
        let session = JPIPStreamingSession(serverURL: peer.url)
        do {
            _ = try await session.deliverImage(imageID: "large-control.j2k",
                options: JPIPStreamingOptions(resourceLimits: ResourceLimits(
                    maximumCompressedBytes: 4096, maximumMemoryBytes: 4096)))
            Issue.record("Expected cnew body admission failure")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
            #expect(error.message.contains("TCP payload"))
        }
        // The peer writes headers only, then closes. A late body read would fail
        // as EOF/networkError, not the announced-length resource error above.
        #expect(peer.requests.withLock { $0 } > 0)
        try? await session.close()
    }

    @Test func volumeSessionCreationUsesMemoryAllowanceBeforeBodyRead() async throws {
        let peer = try HeaderOnlyAdmissionPeer(firstResponse: nil, announcedBodyBytes: 65_536)
        defer { peer.stop() }
        let client = JP3DJPIPClient(serverURL: peer.url)
        try await client.connect()
        do {
            try await client.createSession(volumeID: "large-control.jp3d",
                limits: ResourceLimits(maximumCompressedBytes: 1_048_576, maximumMemoryBytes: 4096))
            Issue.record("Expected 3D cnew memory admission failure")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
            #expect(error.message.contains("TCP payload"))
        }
        #expect(await client.lastWireNewlyDeliveredBins == 0)
        await client.disconnect()
    }

    @Test func volumeResumptionDeductsEarlierWireBytesBeforeRead() async throws {
        let initialEOR = Data([0, JPIPEORReason.imageDone.rawValue, 0])
        let peer = try HeaderOnlyAdmissionPeer(firstResponse: initialEOR, announcedBodyBytes: 64)
        defer { peer.stop() }
        let client = JP3DJPIPClient(serverURL: peer.url)
        try await client.connect()
        let limits = try ResourceLimits(maximumCompressedBytes: 64)
        try await client.createSession(volumeID: "cumulative.jp3d", limits: limits)
        do {
            _ = try await client.requestRegion(JP3DStreamingRegion(xRange: 0..<1, yRange: 0..<1, zRange: 0..<1), limits: limits)
            Issue.record("Expected remaining cumulative allowance failure")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
            #expect(error.message.contains("TCP payload"))
        }
        #expect(await client.cumulativeSessionWireBytes == initialEOR.count)
        await client.disconnect()
    }

    @Test func volumeRepeatedPushReplacementUsesCumulativeAllowanceBeforeSecondPayloadRead() async throws {
        let peer = try RepeatedPushAdmissionPeer()
        defer { peer.stop() }
        let client = JP3DJPIPClient(serverURL: peer.url)
        let limits = try ResourceLimits(maximumCompressedBytes: 100)
        try await client.connect(deadline: nil, limits: limits)
        try await client.createSession(volumeID: "repeated-push.jp3d", limits: limits)
        let region = JP3DStreamingRegion(xRange: 0..<1, yRange: 0..<1, zRange: 0..<1)
        let first = try await client.requestRegion(region, limits: limits)
        #expect(first.count == 1)
        #expect(first.first?.data == Data(repeating: 7, count: 64))
        // Three cnew EOR bytes, 64 accepted push bytes and three response EOR
        // bytes. Draining the queue must neither omit nor recharge that push.
        #expect(await client.cumulativeSessionWireBytes == 70)
        #expect(await client.lastWireResponseByteCount == 67)
        do {
            _ = try await client.requestRegion(region, limits: limits)
            Issue.record("Expected repeated push to exceed the remaining 30-byte transfer allowance")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
            #expect(error.message.contains("declared body"))
        }
        #expect(await client.cumulativeSessionWireBytes == 70)
        let cached = await client.cachedWireDataBins()
        #expect(cached.count == 1)
        #expect(cached.first?.data == Data(repeating: 7, count: 64))
        #expect(peer.requests.withLock { $0 } == 3)
        await client.disconnect()
    }

    @Test func reassemblyReportIncludesDescriptorDominatedPhase() throws {
        let header = Data([0xFF, 0x4F])
        let tileHeader = Data([0xFF, 0x90, 0, 10, 0, 0, 0, 0, 0, 14, 0, 1, 0xFF, 0x93])
        var bins = [JPIPDataBin(binClass: .mainHeader, binID: 0, data: header, isComplete: true),
                    JPIPDataBin(binClass: .tileHeader, binID: 0, data: tileHeader, isComplete: true)]
        bins += (0..<256).map { JPIPDataBin(binClass: .metadata, binID: $0, data: Data(), isComplete: true) }
        let reconstructed = try JPIPDataBinGenerator().reassembleCodestreamBounded(from: bins, reconstructContainer: false)
        #expect(reconstructed.data == header + tileHeader + Data([0xFF, 0xD9]))
        #expect(reconstructed.peakWorkspaceBytes >= bins.count * MemoryLayout<JPIPDataBin>.stride)
        #expect(reconstructed.peakWorkspaceBytes > reconstructed.data.count * 100)
    }

    @Test func volumeReportCarriesDescriptorDominatedReassemblyPeak() async throws {
        let volume = J2KVolume(width: 1, height: 1, depth: 1, components: [
            J2KVolumeComponent(index: 0, bitDepth: 8, signed: false,
                width: 1, height: 1, depth: 1, data: Data([37]))
        ])
        let encoded = try await JP3DEncoder(configuration: JP3DEncoderConfiguration(
            compressionMode: .lossless, qualityLayers: 1, levelsX: 0, levelsY: 0, levelsZ: 0)).encode(volume)
        var bins = try JPIPDataBinGenerator().generateWireDataBins(from: encoded.data).bins
        bins += (100..<612).map { JPIPDataBin(binClass: .metadata, binID: $0, data: Data(), isComplete: true) }
        let reassembled = try JPIPDataBinGenerator().reassembleCodestreamBounded(from: bins, reconstructContainer: false)
        let standalone = try await VolumeDecoder().decode(reassembled.data)
        #expect(reassembled.peakWorkspaceBytes > (standalone.report.peakWorkspaceBytes ?? 0))
        let wire = JPIPWireCodec.encodeStream(bins: bins, eorReason: .imageDone)
        let peer = try HeaderOnlyAdmissionPeer(firstResponse: Data([0, JPIPEORReason.imageDone.rawValue, 0]),
            announcedBodyBytes: 0, subsequentResponse: wire)
        defer { peer.stop() }
        let session = JPIPStreamingSession(serverURL: peer.url)
        let delivered = try await session.deliverVolumeRegion(volumeID: "descriptor-heavy.jp3d",
            region: JP3DStreamingRegion(xRange: 0..<1, yRange: 0..<1, zRange: 0..<1))
        #expect(delivered.bins.count >= 512)
        #expect((delivered.report.peakWorkspaceBytes ?? 0) >= reassembled.peakWorkspaceBytes)
        try await session.close()
    }

    @Test func volumeReportIncludesDescriptorHeavyWebSocketHandshake() async throws {
        let volume = J2KVolume(width: 1, height: 1, depth: 1, components: [
            J2KVolumeComponent(index: 0, bitDepth: 8, signed: false,
                width: 1, height: 1, depth: 1, data: Data([37]))
        ])
        let encoded = try await JP3DEncoder(configuration: JP3DEncoderConfiguration(
            compressionMode: .lossless, qualityLayers: 1, levelsX: 0, levelsY: 0, levelsZ: 0)).encode(volume)
        let bins = try JPIPDataBinGenerator().generateWireDataBins(from: encoded.data).bins
        let reassembly = try JPIPDataBinGenerator().reassembleCodestreamBounded(from: bins, reconstructContainer: false)
        let standalone = try await VolumeDecoder().decode(reassembly.data)
        let headerCount = 2000
        // This lower bound includes only the admitted dictionary descriptors,
        // excluding raw/text/line copies and mandatory upgrade header fields.
        let handshakeDescriptorFloor = headerCount * 4 * MemoryLayout<(String, String)>.stride
        #expect(reassembly.peakWorkspaceBytes < handshakeDescriptorFloor)
        #expect((standalone.report.peakWorkspaceBytes ?? 0) < handshakeDescriptorFloor)
        let peer = try HandshakeReportPeer(headerCount: headerCount,
            response: JPIPWireCodec.encodeStream(bins: bins, eorReason: .imageDone))
        defer { peer.stop() }
        let session = JPIPStreamingSession(serverURL: peer.url)
        let delivered = try await session.deliverVolumeRegion(volumeID: "handshake.jp3d",
            region: JP3DStreamingRegion(xRange: 0..<1, yRange: 0..<1, zRange: 0..<1))
        #expect(delivered.report.fidelity == .exactSamples)
        #expect((delivered.report.peakWorkspaceBytes ?? 0) >= handshakeDescriptorFloor)
        try await session.close()
    }
}

private final class HandshakeReportPeer: @unchecked Sendable {
    // One dedicated peer thread owns I/O; Mutex protects shutdown's connection.
    let listener: JPIPTCPListener
    let connection = Mutex<JPIPTCPConnection?>(nil)
    let group = DispatchGroup()
    var url: URL { URL(string: "ws://127.0.0.1:\(listener.boundPort)/jpip")! }

    init(headerCount: Int, response: Data) throws {
        listener = try JPIPTCPListener(host: "127.0.0.1", port: 0)
        let peer = self
        group.enter()
        Thread.detachNewThread {
            defer { peer.group.leave() }
            guard let connection = try? peer.listener.acceptConnection(timeoutSeconds: 30) else { return }
            peer.connection.withLock { $0 = connection }
            defer { connection.close() }
            guard let request = try? connection.readHTTPRequest(),
                  let key = request.header("Sec-WebSocket-Key") else { return }
            var headers: [String: String] = [:]
            for index in 0..<headerCount { headers["X-\(index)"] = "0" }
            guard (try? connection.writeWebSocketServerHandshake(clientKey: key, extraHeaders: headers)) != nil else { return }
            let encoder = JPIPWebSocketMessageEncoder()
            for index in 0..<3 {
                guard let wire = try? connection.readWebSocketFrame(requireMasked: true),
                      let frame = JPIPWebSocketFrame.deserialize(from: wire.payload),
                      let requestID = frame.requestID else { return }
                let body = index == 1 ? response : Data([0, JPIPEORReason.imageDone.rawValue, 0])
                let reply = JPIPResponse(channelID: "handshake", data: body, statusCode: 200,
                    headers: ["Content-Type": "image/jpp-stream", "JPIP-cnew": "cid=handshake"])
                guard (try? connection.writeWebSocketFrame(opcode: .binary,
                    payload: encoder.encodeResponse(reply, requestID: requestID).serialize(), masked: false)) != nil else { return }
            }
        }
    }

    func stop() {
        listener.close()
        connection.withLock { $0?.close() }
        group.wait()
    }
}

/// A scripted extension peer, not an interoperability oracle. It replaces the
/// same bin on two requests, so cache size cannot stand in for transferred bytes.
/// The second push has only its 27-byte prefix: an attempted payload read would
/// fail with EOF, proving that the asserted resource error precedes that read.
private final class RepeatedPushAdmissionPeer: @unchecked Sendable {
    // The listener is thread-safe; all shared mutable test state uses Mutex.
    let listener: JPIPTCPListener
    let requests = Mutex<Int>(0)
    let connection = Mutex<JPIPTCPConnection?>(nil)
    let group = DispatchGroup()
    var url: URL { URL(string: "ws://127.0.0.1:\(listener.boundPort)/jpip")! }

    init() throws {
        listener = try JPIPTCPListener(host: "127.0.0.1", port: 0)
        let peer = self
        group.enter()
        Thread.detachNewThread {
            defer { peer.group.leave() }
            guard let connection = try? peer.listener.acceptConnection(timeoutSeconds: 30) else { return }
            peer.connection.withLock { $0 = connection }
            defer { connection.close() }
            guard let request = try? connection.readHTTPRequest(),
                  let key = request.header("Sec-WebSocket-Key"),
                  (try? connection.writeWebSocketServerHandshake(clientKey: key)) != nil else { return }
            let encoder = JPIPWebSocketMessageEncoder()
            for index in 0..<3 {
                guard let wire = try? connection.readWebSocketFrame(requireMasked: true),
                      let frame = JPIPWebSocketFrame.deserialize(from: wire.payload),
                      let requestID = frame.requestID else { return }
                peer.requests.withLock { $0 += 1 }
                if index > 0 {
                    // Explicit extension push grammar: local metadata class 5,
                    // ID 17, complete flag, then a 64-byte payload.
                    let payload = Data([5, 0, 0, 0, 17, 1]) + Data(repeating: index == 1 ? 7 : 9, count: 64)
                    let push = JPIPWebSocketFrame(type: .push, payload: payload).serialize()
                    if index == 2 {
                        try? connection.writeAll(Data([0x82, UInt8(push.count)]) + push.prefix(27))
                        return
                    }
                    guard (try? connection.writeWebSocketFrame(opcode: .binary, payload: push, masked: false)) != nil else { return }
                }
                let response = JPIPResponse(channelID: "push-test",
                    data: Data([0, JPIPEORReason.imageDone.rawValue, 0]), statusCode: 200,
                    headers: ["Content-Type": "image/jpp-stream", "JPIP-cnew": "cid=push-test"])
                guard (try? connection.writeWebSocketFrame(opcode: .binary,
                    payload: encoder.encodeResponse(response, requestID: requestID).serialize(), masked: false)) != nil else { return }
            }
        }
    }

    func stop() {
        listener.close()
        connection.withLock { $0?.close() }
        group.wait()
    }
}

/// Sends no oversized body at all: admission is distinguished from EOF after a
/// late attempted read. The optional first response establishes a normal channel.
private final class HeaderOnlyAdmissionPeer: @unchecked Sendable {
    let listener: JPIPTCPListener
    let requests = Mutex<Int>(0)
    let connections = Mutex<[JPIPTCPConnection]>([])
    let group = DispatchGroup()
    var url: URL { URL(string: "http://127.0.0.1:\(listener.boundPort)/jpip")! }

    init(firstResponse: Data?, announcedBodyBytes: Int, subsequentResponse: Data? = nil) throws {
        listener = try JPIPTCPListener(host: "127.0.0.1", port: 0)
        let listener = self.listener, group = self.group
        let peer = self
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            while listener.isOpen {
                guard let connection = try? listener.acceptConnection(timeoutSeconds: 1) else { continue }
                peer.connections.withLock { $0.append(connection) }
                guard (try? connection.readHTTPRequest()) != nil else { connection.close(); continue }
                let index = peer.requests.withLock { count in count += 1; return count }
                let body = index == 1 ? firstResponse : subsequentResponse
                let length = body?.count ?? announcedBodyBytes
                let header = "HTTP/1.1 200 OK\r\nContent-Type: image/jpp-stream\r\nJPIP-cnew: cid=test\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n"
                try? connection.writeAll(Data(header.utf8))
                if let body { try? connection.writeAll(body) }
                connection.close()
            }
        }
    }
    func stop() {
        listener.close()
        connections.withLock { for connection in $0 { connection.close() } }
        group.wait()
    }
}
