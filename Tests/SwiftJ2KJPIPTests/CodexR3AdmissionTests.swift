// SPDX-License-Identifier: Apache-2.0
import Foundation
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
        do {
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
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test func admissionPeerStopRejectsLateAcceptedSocketAndObservesCompletion() async throws {
        struct Observation: Sendable {
            var accepted = false
            var openBeforeStop = false
            var admitted = true
            var openAfterAdmission = true
            var failure: String?
        }
        let lifetime = try AdmissionPeerLifetime()
        let observed = Mutex(Observation())
        let installed = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        async let completion: Void = lifetime.waitForCompletion(onWaiting: {
            installed.continuation.yield(())
            installed.continuation.finish()
        })
        for await _ in installed.stream { break }
        #expect(!lifetime.isFinished)
        lifetime.start {
            do {
                guard let connection = try lifetime.listener.acceptConnection(timeoutSeconds: 0) else {
                    observed.withLock { $0.failure = "Listener closed before the regression accepted a socket" }
                    return
                }
                defer { connection.close() }
                let openBeforeStop = connection.isOpen
                // Force the former race: accept succeeded, but no owner has yet
                // been published. Repeated close must make admission impossible.
                lifetime.close()
                lifetime.close()
                let admitted = lifetime.admit(connection)
                observed.withLock { state in
                    state.accepted = true
                    state.openBeforeStop = openBeforeStop
                    state.admitted = admitted
                    state.openAfterAdmission = connection.isOpen
                }
            } catch {
                observed.withLock { $0.failure = String(describing: error) }
            }
        }
        do {
            let client = try await JPIPBlockingWorker.run {
                try JPIPTCPConnection.connect(host: "127.0.0.1",
                    port: lifetime.listener.boundPort, timeoutSeconds: 2)
            }
            // This continuation was installed before the worker started, so
            // completion must wake an actual async waiter, not only a fast path.
            await completion
            let sawEOF = try await JPIPBlockingWorker.run {
                defer { client.close() }
                return try client.readHTTPRequest() == nil
            }
            let snapshot = observed.withLock { $0 }
            #expect(snapshot.failure == nil)
            #expect(snapshot.accepted)
            #expect(snapshot.openBeforeStop)
            #expect(!snapshot.admitted)
            #expect(!snapshot.openAfterAdmission)
            #expect(sawEOF)
            #expect(lifetime.isFinished)
        } catch {
            await lifetime.stop()
            await completion
            throw error
        }
        await lifetime.stop()
    }

    @Test func volumeSessionCreationUsesMemoryAllowanceBeforeBodyRead() async throws {
        let peer = try HeaderOnlyAdmissionPeer(firstResponse: nil, announcedBodyBytes: 65_536)
        do {
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
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test func volumeResumptionDeductsEarlierWireBytesBeforeRead() async throws {
        let initialEOR = Data([0, JPIPEORReason.imageDone.rawValue, 0])
        let peer = try HeaderOnlyAdmissionPeer(firstResponse: initialEOR, announcedBodyBytes: 64)
        do {
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
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test func volumeRepeatedPushReplacementUsesCumulativeAllowanceBeforeSecondPayloadRead() async throws {
        let peer = try RepeatedPushAdmissionPeer()
        do {
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
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
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
        do {
            let session = JPIPStreamingSession(serverURL: peer.url)
            let delivered = try await session.deliverVolumeRegion(volumeID: "descriptor-heavy.jp3d",
                region: JP3DStreamingRegion(xRange: 0..<1, yRange: 0..<1, zRange: 0..<1))
            #expect(delivered.bins.count >= 512)
            #expect((delivered.report.peakWorkspaceBytes ?? 0) >= reassembled.peakWorkspaceBytes)
            try await session.close()
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
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
        do {
            let session = JPIPStreamingSession(serverURL: peer.url)
            let delivered = try await session.deliverVolumeRegion(volumeID: "handshake.jp3d",
                region: JP3DStreamingRegion(xRange: 0..<1, yRange: 0..<1, zRange: 0..<1))
            #expect(delivered.report.fidelity == .exactSamples)
            #expect((delivered.report.peakWorkspaceBytes ?? 0) >= handshakeDescriptorFloor)
            try await session.close()
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }
}

private final class HandshakeReportPeer: @unchecked Sendable {
    // One dedicated peer thread owns I/O; Mutex protects shutdown's connection.
    private let lifetime: AdmissionPeerLifetime
    var listener: JPIPTCPListener { lifetime.listener }
    var url: URL { URL(string: "ws://127.0.0.1:\(listener.boundPort)/jpip")! }

    init(headerCount: Int, response: Data) throws {
        lifetime = try AdmissionPeerLifetime()
        let peer = self
        lifetime.start {
            guard let connection = try? peer.listener.acceptConnection(timeoutSeconds: 30) else { return }
            guard peer.lifetime.admit(connection) else { return }
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

    func stop() async { await lifetime.stop() }
}

/// A scripted extension peer, not an interoperability oracle. It replaces the
/// same bin on two requests, so cache size cannot stand in for transferred bytes.
/// The second push has only its 27-byte prefix: an attempted payload read would
/// fail with EOF, proving that the asserted resource error precedes that read.
private final class RepeatedPushAdmissionPeer: @unchecked Sendable {
    // The listener is thread-safe; all shared mutable test state uses Mutex.
    private let lifetime: AdmissionPeerLifetime
    var listener: JPIPTCPListener { lifetime.listener }
    let requests = Mutex<Int>(0)
    var url: URL { URL(string: "ws://127.0.0.1:\(listener.boundPort)/jpip")! }

    init() throws {
        lifetime = try AdmissionPeerLifetime()
        let peer = self
        lifetime.start {
            guard let connection = try? peer.listener.acceptConnection(timeoutSeconds: 30) else { return }
            guard peer.lifetime.admit(connection) else { return }
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

    func stop() async { await lifetime.stop() }
}

/// Sends no oversized body at all: admission is distinguished from EOF after a
/// late attempted read. The optional first response establishes a normal channel.
private final class HeaderOnlyAdmissionPeer: @unchecked Sendable {
    private let lifetime: AdmissionPeerLifetime
    var listener: JPIPTCPListener { lifetime.listener }
    let requests = Mutex<Int>(0)
    var url: URL { URL(string: "http://127.0.0.1:\(listener.boundPort)/jpip")! }

    init(firstResponse: Data?, announcedBodyBytes: Int, subsequentResponse: Data? = nil) throws {
        lifetime = try AdmissionPeerLifetime()
        let listener = self.listener
        let peer = self
        lifetime.start {
            while listener.isOpen {
                guard let connection = try? listener.acceptConnection(timeoutSeconds: 1) else { continue }
                guard peer.lifetime.admit(connection) else { break }
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
    func stop() async { await lifetime.stop() }
}

/// One dedicated worker owns the peer script. The same lock admits accepted
/// sockets and closes admission; shutdown closes owners and awaits the worker's
/// final publication without blocking the test executor. Completion observes
/// script exit and socket cleanup, not the physical OS thread's final exit.
private final class AdmissionPeerLifetime: Sendable {
    private struct State {
        var closed = false
        var started = false
        var finished = false
        var connections: [JPIPTCPConnection] = []
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    let listener: JPIPTCPListener
    private let state = Mutex(State())
    var isFinished: Bool { state.withLock { $0.finished } }

    init() throws {
        listener = try JPIPTCPListener(host: "127.0.0.1", port: 0)
    }

    func start(_ script: @escaping @Sendable () -> Void) {
        state.withLock { state in
            precondition(!state.started, "Admission peer has only one worker")
            state.started = true
        }
        Thread.detachNewThread {
            defer { self.workerFinished() }
            script()
        }
    }

    func admit(_ connection: JPIPTCPConnection) -> Bool {
        let admitted = state.withLock { state in
            guard !state.closed else { return false }
            state.connections.append(connection)
            return true
        }
        if !admitted { connection.close() }
        return admitted
    }

    func close() {
        let connections = state.withLock { state in
            state.closed = true
            let connections = state.connections
            state.connections.removeAll()
            return connections
        }
        listener.close()
        for connection in connections { connection.close() }
    }

    private func workerFinished() {
        let waiters = state.withLock { state in
            state.finished = true
            let waiters = state.waiters
            state.waiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func waitForCompletion(onWaiting: (@Sendable () -> Void)? = nil) async {
        await withCheckedContinuation { continuation in
            let finished = state.withLock { state in
                if state.finished { return true }
                state.waiters.append(continuation)
                return false
            }
            if finished { continuation.resume() }
            else { onWaiting?() }
        }
    }

    func stop() async {
        close()
        await waitForCompletion()
    }
}
