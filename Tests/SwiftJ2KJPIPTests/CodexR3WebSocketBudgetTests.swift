// SPDX-License-Identifier: MIT
import Foundation
import Dispatch
import Testing
import Synchronization
@testable import SwiftJ2KJPIP

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("R3 transport pre-allocation budgets")
struct CodexR3WebSocketBudgetTests {
    @Test func descriptorHeavyHTTPHeaderIsRejectedBeforeTextParsingOrBodyRead() throws {
        let (reader, peer) = try socketPair()
        defer { reader.close(); peer.close() }
        var header = "HTTP/1.1 200 OK\r\n"
        for index in 0..<80 { header += "X\(index):0\r\n" }
        header += "Content-Length:8192\r\n\r\n"
        #expect(header.utf8.count < 4096 / 3)
        // Raw header bytes fit. No body is sent, so a body read would time out.
        // The specific pre-text error proves rejection before allocating String,
        // split-line or dictionary representations dominated by tiny headers.
        try peer.writeAll(Data(header.utf8))
        do {
            _ = try reader.readHTTPResponse(maxBodyBytes: 16_384, maximumStorageBytes: 4096)
            Issue.record("Expected HTTP header descriptor admission failure")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
            #expect(error.message.contains("before text parsing"))
        }
    }

    @Test func oversizedFrameIsDeniedFromLengthWithoutReadingItsPayload() throws {
        let (reader, peer) = try socketPair()
        defer { reader.close(); peer.close() }
        let budget = JPIPWebSocketReadBudget()
        try budget.configure(maxBodyBytes: 1_048_576, maximumStorageBytes: 4096)
        // Deliberately send only a header announcing 8192 bytes. An attempt to
        // buffer/read that payload would time out, rather than produce this error.
        try peer.writeAll(Data([0x82, 0x7E, 0x20, 0x00]))
        do {
            _ = try reader.readWebSocketFrame(requireMasked: false, budget: budget)
            Issue.record("Expected frame rejection from its announced length")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(budget.snapshot.payloadAllocationCount == 0)
    }

    @Test func declaredBodyLimitIsCheckedBeforeOwningMessageAllocation() throws {
        let (reader, peer) = try socketPair()
        defer { reader.close(); peer.close() }
        let budget = JPIPWebSocketReadBudget()
        try budget.configure(maxBodyBytes: 4096, maximumStorageBytes: 65_536)
        // This wire message fits storage, but its declared response body exceeds
        // the compressed/body ceiling. Only the bounded 27-byte prefix is sent.
        var wire = frameHeader(opcode: 0x82, payloadCount: 8192 + 13)
        wire.append(responsePrefix(bodyBytes: 8192))
        wire.append(Data(repeating: 0, count: 14))
        try peer.writeAll(wire)
        do {
            _ = try reader.readWebSocketFrame(requireMasked: false, budget: budget)
            Issue.record("Expected body rejection before the message allocation")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(budget.snapshot.payloadAllocationCount == 0)
    }

    @Test func fragmentedMessageIncludesOldAndNewBuffersBeforeNextPayload() throws {
        let (reader, peer) = try socketPair()
        defer { reader.close(); peer.close() }
        let budget = JPIPWebSocketReadBudget()
        try budget.configure(maxBodyBytes: 4096, maximumStorageBytes: 1000)
        var first = responsePrefix(bodyBytes: 800 - 13)
        first.append(Data(repeating: 0, count: 400 - first.count))
        var wire = frameHeader(opcode: 0x02, payloadCount: first.count)
        wire.append(first)
        // Each 400-byte fragment and the final 800-byte message fit separately.
        // The second fragment's payload is absent: rejection must precede its read.
        wire.append(frameHeader(opcode: 0x80, payloadCount: 400))
        try peer.writeAll(wire)
        do {
            _ = try reader.readWebSocketFrame(requireMasked: false, budget: budget)
            Issue.record("Expected fragment copy overlap rejection")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(budget.snapshot.payloadAllocationCount == 1)
    }

    @Test func queuedPushesReduceTheNextResponseBodyAllowance() throws {
        let (reader, peer) = try socketPair()
        defer { reader.close(); peer.close() }
        let budget = JPIPWebSocketReadBudget()
        try budget.beginRequest(1, maxBodyBytes: 128, maximumStorageBytes: 4096)
        try budget.reservePush(payloadBytes: 96, requestID: nil)
        var wire = frameHeader(opcode: 0x82, payloadCount: 64 + 13)
        wire.append(responsePrefix(bodyBytes: 64))
        wire.append(Data(repeating: 0, count: 14))
        try peer.writeAll(wire)
        do {
            _ = try reader.readWebSocketFrame(requireMasked: false, budget: budget)
            Issue.record("Expected cumulative push/response body rejection")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(budget.snapshot.payloadAllocationCount == 0)
        #expect(budget.snapshot.queuedBins == 1)
    }

    @Test func zeroPayloadPushesAreBoundedByDescriptorsBeforeAppend() async throws {
        let transport = JPIPWebSocketTransport(url: URL(string: "ws://127.0.0.1/jpip")!)
        let twoBins = 6 * MemoryLayout<JPIPDataBin>.stride
        try await transport.configureReceiveLimits(maxBodyBytes: 1024, maximumStorageBytes: twoBins)
        // Independently specified compact bin: class 0, ID 1, complete, zero bytes.
        let frame = JPIPWebSocketFrame(type: .dataBin, payload: Data([0, 0, 0, 0, 1, 1]))
        try await transport.handleReceivedFrameBounded(frame)
        try await transport.handleReceivedFrameBounded(frame)
        do {
            try await transport.handleReceivedFrameBounded(frame)
            Issue.record("Expected descriptor admission before third pushed-bin append")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
        #expect(await transport.receiveStorageSnapshot.queuedBins == 2)
        #expect(await transport.statistics.dataBinsPushed == 2)
        #expect(await transport.drainReceivedDataBins().count == 2)
        #expect(await transport.receiveStorageSnapshot.queuedBins == 0)
    }

    @Test func readerWaitsAfterResponseAndWakesForNextRequestOrClose() async throws {
        let budget = JPIPWebSocketReadBudget()
        defer { budget.close() }
        try budget.beginRequest(1, maxBodyBytes: 1024, maximumStorageBytes: 4096)
        budget.pauseAfterResponse(1)
        budget.endRequest(1)
        let state = Mutex((entered: false, resumed: false, closed: false))
        Thread.detachNewThread {
            state.withLock { $0.entered = true }
            if budget.waitUntilReadAllowed() { state.withLock { $0.resumed = true } }
        }
        let entered = try await observe { state.withLock { $0.entered } }
        #expect(entered)
        try await Task.sleep(for: .milliseconds(50))
        #expect(!state.withLock { $0.resumed })
        try budget.beginRequest(2, maxBodyBytes: 512, maximumStorageBytes: 2048)
        let resumed = try await observe { state.withLock { $0.resumed } }
        #expect(resumed)
        budget.pauseAfterResponse(2)
        budget.endRequest(2)
        Thread.detachNewThread {
            if !budget.waitUntilReadAllowed() { state.withLock { $0.closed = true } }
        }
        budget.close()
        let closed = try await observe { state.withLock { $0.closed } }
        #expect(closed)
    }

    @Test func priorQueuedPushesRetainStorageWithoutChargingNextBodyAgain() throws {
        let budget = JPIPWebSocketReadBudget()
        try budget.beginRequest(1, maxBodyBytes: 100, maximumStorageBytes: 4096)
        try budget.reservePush(payloadBytes: 96, requestID: 1)
        budget.pauseAfterResponse(1)
        budget.endRequest(1)
        // The shared transfer ledger now has four bytes remaining. Existing
        // queued owners remain live, but three response bytes plus a new push byte are legal.
        try budget.beginRequest(2, maxBodyBytes: 4, maximumStorageBytes: 4096)
        try budget.reserveResponse(bodyBytes: 3, decodedStorageBytes: 3, requestID: 2)
        try budget.reservePush(payloadBytes: 1, requestID: nil)
        #expect(budget.snapshot.queuedBins == 2)
        #expect(budget.snapshot.queuedStorageBytes >= 97)
        do {
            try budget.reservePush(payloadBytes: 1, requestID: 2)
            Issue.record("Expected same-request push to exceed exhausted body allowance")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
    }

    @Test func acceptedPushCounterSurvivesQueueDrainAndChargesEachFrameOnce() async throws {
        let transport = JPIPWebSocketTransport(url: URL(string: "ws://127.0.0.1/jpip")!)
        try await transport.configureReceiveLimits(maxBodyBytes: 1024, maximumStorageBytes: 4096)
        let bin = Data([0, 0, 0, 0, 1, 1, 41, 42])
        try await transport.handleReceivedFrameBounded(JPIPWebSocketFrame(type: .dataBin, payload: bin))
        #expect(await transport.drainReceivedDataBins().count == 1)
        #expect(await transport.takeUnaccountedPushPayloadBytes() == 2)
        #expect(await transport.takeUnaccountedPushPayloadBytes() == 0)
        try await transport.handleReceivedFrameBounded(JPIPWebSocketFrame(type: .push, payload: bin))
        #expect(await transport.takeUnaccountedPushPayloadBytes() == 2)
        #expect(await transport.receiveStorageSnapshot.queuedBins == 1)
        #expect(await transport.takeUnaccountedPushPayloadBytes() == 0)
    }

    @Test func deadlineWatchdogWakesDedicatedReaderAndCancellationDisarmsIt() async throws {
        let budget = JPIPWebSocketReadBudget()
        let exited = Mutex(false)
        Thread.detachNewThread {
            if !budget.waitUntilReadAllowed() { exited.withLock { $0 = true } }
        }
        let watchdog = JPIPDeadlineWatchdog(after: 0.05) { budget.close() }
        defer { watchdog.cancel(); budget.close() }
        let joined = try await observe { exited.withLock { $0 } }
        #expect(joined)
        #expect(watchdog.isExpired)

        let calls = Mutex(0)
        let cancelled = JPIPDeadlineWatchdog(after: 0.05) { calls.withLock { $0 += 1 } }
        cancelled.cancel()
        try await Task.sleep(for: .milliseconds(100))
        #expect(!cancelled.isExpired)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func descriptorHeavyHandshakePeakBelongsOnlyToConnectingRequest() async throws {
        // Scripted extension peer, not an independent interoperability oracle.
        // Explicit fixture close owns socket lifetime, including the interval
        // between requests; it has no incidental two-second idle I/O expiry.
        let peer = try R3OwnedScriptedPeer(connections: 1) { connection, _, peer in
            guard let request = try connection.readHTTPRequest(),
                  let key = request.header("Sec-WebSocket-Key") else {
                throw J2KError.invalidData("Test handshake has no key")
            }
            peer.mark("handshake.read")
            var header = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            header += "Sec-WebSocket-Accept: \(JPIPRFC6455Crypto.computeAcceptKey(for: key))\r\nSec-WebSocket-Protocol: jpip\r\n"
            for index in 0..<80 { header += "X\(index):0\r\n" }
            try connection.writeAll(Data((header + "\r\n").utf8))
            peer.mark("handshake.written")
            for index in 1...2 {
                let incoming = try connection.readWebSocketFrame(requireMasked: true)
                peer.mark("request.read.\(index)")
                guard incoming.payload.count >= 9 else { throw J2KError.invalidData("Short test request") }
                var reply = Data([0x02])
                reply.append(incoming.payload[1..<5])
                reply.append(contentsOf: [0, 0, 0, 4, 0, 200, 0, 0])
                try connection.writeWebSocketFrame(opcode: .binary, payload: reply, masked: false)
                peer.mark("response.written.\(index)")
            }
        }
        defer { peer.close() }
        try await peer.waitForStartup()
        let transport = JPIPTransport(baseURL: URL(string: "ws://127.0.0.1:\(peer.port)/jpip")!)
        await transport.setWebSocketHandshakePhaseObserver { peer.mark($0) }
        do {
            peer.mark("first.send.begin")
            let first = try await transport.send(JPIPRequest(target: "tiny.j2k"), maxBodyBytes: 1,
                deadline: ContinuousClock.now.advanced(by: .seconds(2)), maximumStorageBytes: 65_536)
            peer.mark("first.send.returned")
            #expect(first.data.isEmpty)
            let connecting = await transport.receiveAdmissionSnapshot()
            #expect(connecting.peakBytes > 10_000)
            peer.mark("second.send.begin")
            let second = try await transport.send(JPIPRequest(target: "tiny.j2k"), maxBodyBytes: 1,
                deadline: ContinuousClock.now.advanced(by: .seconds(2)), maximumStorageBytes: 65_536)
            peer.mark("second.send.returned")
            #expect(second.data.isEmpty)
            let reused = await transport.receiveAdmissionSnapshot()
            #expect(reused.peakBytes < connecting.peakBytes)
            #expect(reused.peakBytes < 1024)
            await transport.close()
        } catch {
            await transport.close()
            let stopped = await peer.stopAndObserve()
            throw R3ScriptedPeerFailure("Handshake budget fixture failed: \(error); stopped=\(stopped); \(peer.diagnostics)")
        }
        let stopped = await peer.stopAndObserve()
        let diagnostics = peer.diagnostics
        #expect(stopped, "\(diagnostics)")
        #expect(peer.failures.isEmpty, "\(diagnostics)")
        #expect(diagnostics.contains("ws.header.read"), "\(diagnostics)")
        #expect(diagnostics.contains("ws.publication"), "\(diagnostics)")
        #expect(diagnostics.contains("ws.actor.resume"), "\(diagnostics)")
    }

    @Test func overlappingFirstSendsAndCloseWithTracingShareSingleTransportAndJoinAllReaders() async throws {
        // 1. Overlapping first sends with tracing enabled must share a single JPIPWebSocketTransport,
        //    coalesce onto one handshake/reader/socket, and join completely on close().
        do {
            let peer = try R3OwnedScriptedPeer(connections: 1) { connection, _, peer in
                guard let request = try connection.readHTTPRequest(),
                      let key = request.header("Sec-WebSocket-Key") else {
                    throw J2KError.invalidData("Missing Sec-WebSocket-Key")
                }
                peer.mark("part1.upgrade.read")
                _ = peer.waitForGate("part1.releaseHandshake")
                try connection.writeWebSocketServerHandshake(clientKey: key)
                peer.mark("part1.upgrade.written")
                for index in 1...2 {
                    let incoming = try connection.readWebSocketFrame(requireMasked: true)
                    peer.mark("part1.frame.read.\(index)")
                    guard incoming.payload.count >= 9 else {
                        throw J2KError.invalidData("Short WebSocket request frame")
                    }
                    var reply = Data([0x02])
                    reply.append(incoming.payload[1..<5])
                    reply.append(contentsOf: [0, 0, 0, 5, 0, 200, 0, 0, UInt8(40 + index)])
                    try connection.writeWebSocketFrame(opcode: .binary, payload: reply, masked: false)
                    peer.mark("part1.frame.written.\(index)")
                }
            }
            defer {
                peer.openGate("part1.releaseHandshake")
                peer.close()
            }
            try await peer.waitForStartup()

            let transport = JPIPTransport(baseURL: URL(string: "ws://127.0.0.1:\(peer.port)/jpip")!)
            let observedPhases = Mutex<[String]>([])
            await transport.setWebSocketHandshakePhaseObserver { phase in
                observedPhases.withLock { $0.append(phase) }
                peer.mark(phase)
            }

            let sendA = Task {
                try await transport.send(
                    JPIPRequest(target: "a.j2k"),
                    maxBodyBytes: 16,
                    deadline: ContinuousClock.now.advanced(by: .seconds(5)),
                    maximumStorageBytes: 65_536
                )
            }
            let sendB = Task {
                try await transport.send(
                    JPIPRequest(target: "b.j2k"),
                    maxBodyBytes: 16,
                    deadline: ContinuousClock.now.advanced(by: .seconds(5)),
                    maximumStorageBytes: 65_536
                )
            }

            do {
                try await peer.waitFor("part1.upgrade.read")
                let bothRegistered = try await observeAsync {
                    let ownership = await transport.requestOwnershipSnapshot
                    return ownership.registered == 2 && ownership.unfinished == 2
                }
                #expect(bothRegistered, "\(peer.diagnostics)")
                let midActivity = await transport.webSocketActivitySnapshot
                #expect(midActivity.createdTransports == 1)
                #expect(midActivity.activeHandshakes == 1)

                peer.openGate("part1.releaseHandshake")
                let respA = try await sendA.value
                let respB = try await sendB.value
                #expect(respA.statusCode == 200)
                #expect(respB.statusCode == 200)
                #expect(Set([respA.data, respB.data]) == Set([Data([41]), Data([42])]))

                let connectedActivity = await transport.webSocketActivitySnapshot
                #expect(connectedActivity.createdTransports == 1)
                #expect(connectedActivity.activeHandshakes == 0)
                #expect(connectedActivity.activeReaders == 1)
                #expect(connectedActivity.activeSockets == 1)

                let phases = observedPhases.withLock { $0 }
                #expect(phases.filter { $0 == "ws.connect.start" }.count == 1, "\(phases)")
                #expect(phases.filter { $0 == "ws.header.read" }.count == 1, "\(phases)")
                #expect(phases.filter { $0 == "ws.publication" }.count == 1, "\(phases)")
                #expect(phases.filter { $0 == "ws.actor.resume" }.count == 1, "\(phases)")

                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await transport.close() }
                    group.addTask { await transport.close() }
                }

                let closedActivity = await transport.webSocketActivitySnapshot
                let closedOwnership = await transport.requestOwnershipSnapshot
                #expect(closedActivity.createdTransports == 1)
                #expect(closedActivity.activeHandshakes == 0)
                #expect(closedActivity.activeReaders == 0)
                #expect(closedActivity.activeSockets == 0)
                #expect(closedOwnership.registered == 0)
                #expect(closedOwnership.unfinished == 0)
            } catch {
                peer.openGate("part1.releaseHandshake")
                sendA.cancel()
                sendB.cancel()
                _ = try? await sendA.value
                _ = try? await sendB.value
                await transport.close()
                _ = await peer.stopAndObserve()
                throw error
            }
            let stopped = await peer.stopAndObserve()
            #expect(stopped, "\(peer.diagnostics)")
            #expect(peer.failures.isEmpty, "\(peer.diagnostics)")
        }

        // 2. Overlapping first sends + close() during handshake AND during active reader frame wait
        //    with tracing enabled must cancel and join without leaving any hidden reader or socket.
        do {
            let peer = try R3OwnedScriptedPeer(connections: 2) { connection, index, peer in
                guard let request = try connection.readHTTPRequest(),
                      let key = request.header("Sec-WebSocket-Key") else {
                    throw J2KError.invalidData("Missing Sec-WebSocket-Key on connection \(index)")
                }
                peer.mark("conn.\(index).upgrade.read")
                if index == 1 {
                    // Connection 1 withholds 101 response until client close() cancels the socket.
                    _ = try? connection.readHTTPRequest()
                    return
                }
                // Connection 2 completes 101 upgrade, reads the first frame, then withholds reply until close().
                try connection.writeWebSocketServerHandshake(clientKey: key)
                peer.mark("conn.2.upgrade.written")
                _ = try connection.readWebSocketFrame(requireMasked: true)
                peer.mark("conn.2.frame.read")
                _ = try? connection.readWebSocketFrame(requireMasked: true)
            }
            defer { peer.close() }
            try await peer.waitForStartup()

            let transport = JPIPTransport(baseURL: URL(string: "ws://127.0.0.1:\(peer.port)/jpip")!)
            await transport.setWebSocketHandshakePhaseObserver { peer.mark("trace.\($0)") }

            // 2A: Close while two overlapping first sends are in the middle of the handshake.
            let hsSend1 = Task {
                try await transport.send(
                    JPIPRequest(target: "hs1.j2k"),
                    maxBodyBytes: 16,
                    deadline: ContinuousClock.now.advanced(by: .seconds(10)),
                    maximumStorageBytes: 65_536
                )
            }
            let hsSend2 = Task {
                try await transport.send(
                    JPIPRequest(target: "hs2.j2k"),
                    maxBodyBytes: 16,
                    deadline: ContinuousClock.now.advanced(by: .seconds(10)),
                    maximumStorageBytes: 65_536
                )
            }

            try await peer.waitFor("conn.1.upgrade.read")
            let bothInHandshake = try await observeAsync {
                let own = await transport.requestOwnershipSnapshot
                let act = await transport.webSocketActivitySnapshot
                return own.registered == 2 && act.createdTransports == 1 && act.activeHandshakes == 1
            }
            #expect(bothInHandshake, "\(peer.diagnostics)")

            await withTaskGroup(of: Void.self) { group in
                group.addTask { await transport.close() }
                group.addTask { await transport.close() }
            }

            await #expect(throws: CancellationError.self) { _ = try await hsSend1.value }
            await #expect(throws: CancellationError.self) { _ = try await hsSend2.value }

            let afterHandshakeClose = await transport.webSocketActivitySnapshot
            let ownAfterHandshakeClose = await transport.requestOwnershipSnapshot
            #expect(afterHandshakeClose.createdTransports == 1)
            #expect(afterHandshakeClose.activeHandshakes == 0)
            #expect(afterHandshakeClose.activeReaders == 0)
            #expect(afterHandshakeClose.activeSockets == 0)
            #expect(ownAfterHandshakeClose.registered == 0)
            #expect(ownAfterHandshakeClose.unfinished == 0)

            // 2B: Close while two overlapping sends in the next generation share the live reader thread.
            let liveSend1 = Task {
                try await transport.send(
                    JPIPRequest(target: "live1.j2k"),
                    maxBodyBytes: 16,
                    deadline: ContinuousClock.now.advanced(by: .seconds(10)),
                    maximumStorageBytes: 65_536
                )
            }
            let liveSend2 = Task {
                try await transport.send(
                    JPIPRequest(target: "live2.j2k"),
                    maxBodyBytes: 16,
                    deadline: ContinuousClock.now.advanced(by: .seconds(10)),
                    maximumStorageBytes: 65_536
                )
            }

            try await peer.waitFor("conn.2.frame.read")
            let bothInLiveRequest = try await observeAsync {
                let own = await transport.requestOwnershipSnapshot
                let act = await transport.webSocketActivitySnapshot
                return own.registered == 2 && act.createdTransports == 2 && act.activeReaders == 1 && act.activeSockets == 1
            }
            #expect(bothInLiveRequest, "\(peer.diagnostics)")

            await withTaskGroup(of: Void.self) { group in
                group.addTask { await transport.close() }
                group.addTask { await transport.close() }
            }

            await #expect(throws: CancellationError.self) { _ = try await liveSend1.value }
            await #expect(throws: CancellationError.self) { _ = try await liveSend2.value }

            let afterLiveClose = await transport.webSocketActivitySnapshot
            let ownAfterLiveClose = await transport.requestOwnershipSnapshot
            #expect(afterLiveClose.createdTransports == 2)
            #expect(afterLiveClose.activeHandshakes == 0)
            #expect(afterLiveClose.activeReaders == 0)
            #expect(afterLiveClose.activeSockets == 0)
            #expect(ownAfterLiveClose.registered == 0)
            #expect(ownAfterLiveClose.unfinished == 0)

            let stopped = await peer.stopAndObserve()
            #expect(stopped, "\(peer.diagnostics)")
            #expect(peer.failures.isEmpty, "\(peer.diagnostics)")
        }
    }

    @Test func followerWaitersExpireOrCancelIndependentlyWithoutCancellingSlowLeaderHandshake() async throws {
        // Part A: A 10s leader is joined by a 100ms follower, a cancelled 10s follower,
        // and an uncancelled 10s follower. The 100ms follower and cancelled follower
        // must fail and remove themselves from handshakeWaiters without cancelling the leader;
        // when the peer completes the 101 upgrade, both the leader and the remaining 10s follower succeed.
        do {
            let peer = try R3OwnedScriptedPeer(connections: 1) { connection, _, peer in
                guard let request = try connection.readHTTPRequest(),
                      let key = request.header("Sec-WebSocket-Key") else {
                    throw J2KError.invalidData("Missing Sec-WebSocket-Key")
                }
                peer.mark("leader.upgrade.read")
                _ = peer.waitForGate("leader.releaseHandshake")
                try connection.writeWebSocketServerHandshake(clientKey: key)
                peer.mark("leader.upgrade.written")
                for index in 1...2 {
                    let incoming = try connection.readWebSocketFrame(requireMasked: true)
                    peer.mark("leader.frame.read.\(index)")
                    guard incoming.payload.count >= 9 else {
                        throw J2KError.invalidData("Short WebSocket request frame")
                    }
                    var reply = Data([0x02])
                    reply.append(incoming.payload[1..<5])
                    reply.append(contentsOf: [0, 0, 0, 5, 0, 200, 0, 0, UInt8(60 + index)])
                    try connection.writeWebSocketFrame(opcode: .binary, payload: reply, masked: false)
                    peer.mark("leader.frame.written.\(index)")
                }
            }
            defer {
                peer.openGate("leader.releaseHandshake")
                peer.close()
            }
            try await peer.waitForStartup()

            let transport = JPIPTransport(baseURL: URL(string: "ws://127.0.0.1:\(peer.port)/jpip")!)
            let leaderTask = Task {
                try await transport.send(
                    JPIPRequest(target: "leader.j2k"),
                    maxBodyBytes: 16,
                    deadline: ContinuousClock.now.advanced(by: .seconds(10)),
                    maximumStorageBytes: 65_536
                )
            }

            try await peer.waitFor("leader.upgrade.read")
            let ws = try #require(await transport.currentWebSocketTransportForTesting)

            // Park a long-lived follower (10s deadline) and a follower that will be cancelled.
            let survivingFollowerTask = Task {
                try await transport.send(
                    JPIPRequest(target: "survivor.j2k"),
                    maxBodyBytes: 16,
                    deadline: ContinuousClock.now.advanced(by: .seconds(10)),
                    maximumStorageBytes: 65_536
                )
            }
            let cancelledFollowerTask = Task {
                try await transport.send(
                    JPIPRequest(target: "cancelled.j2k"),
                    maxBodyBytes: 16,
                    deadline: ContinuousClock.now.advanced(by: .seconds(10)),
                    maximumStorageBytes: 65_536
                )
            }
            let twoFollowersParked = try await observeAsync {
                await ws.parkedHandshakeWaiterCountForTesting == 2
            }
            #expect(twoFollowersParked, "\(peer.diagnostics)")

            // Start a 100ms-deadline follower while the 10s leader is still waiting for 101.
            let shortStart = ContinuousClock.now
            let shortFollowerTask = Task {
                try await transport.send(
                    JPIPRequest(target: "short.j2k"),
                    maxBodyBytes: 16,
                    deadline: shortStart.advanced(by: .milliseconds(100)),
                    maximumStorageBytes: 65_536
                )
            }
            do {
                _ = try await shortFollowerTask.value
                Issue.record("Expected 100ms follower to expire before 10s leader")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
                #expect(error.message.contains("deadline elapsed"))
            }
            let shortElapsed = ContinuousClock.now - shortStart
            #expect(shortElapsed < .seconds(1), "100ms follower took \(shortElapsed)")

            // Cancel the second follower and verify it exits promptly with CancellationError.
            let cancelStart = ContinuousClock.now
            cancelledFollowerTask.cancel()
            await #expect(throws: CancellationError.self) {
                _ = try await cancelledFollowerTask.value
            }
            #expect(ContinuousClock.now - cancelStart < .seconds(1))

            // Both expired and cancelled followers must be removed from handshakeWaiters,
            // leaving only survivingFollowerTask parked while the leader handshake remains active.
            let onlySurvivorParked = try await observeAsync {
                await ws.parkedHandshakeWaiterCountForTesting == 1
            }
            #expect(onlySurvivorParked)
            let midActivity = await transport.webSocketActivitySnapshot
            #expect(midActivity.createdTransports == 1)
            #expect(midActivity.activeHandshakes == 1)

            // Release the 101 handshake; both the 10s leader and the surviving 10s follower must succeed.
            peer.openGate("leader.releaseHandshake")
            let leaderResp = try await leaderTask.value
            let survivorResp = try await survivingFollowerTask.value
            #expect(leaderResp.statusCode == 200)
            #expect(survivorResp.statusCode == 200)
            #expect(Set([leaderResp.data, survivorResp.data]) == Set([Data([61]), Data([62])]))
            #expect(await ws.parkedHandshakeWaiterCountForTesting == 0)

            await transport.close()
            let stopped = await peer.stopAndObserve()
            #expect(stopped, "\(peer.diagnostics)")
            #expect(peer.failures.isEmpty, "\(peer.diagnostics)")
        }

        // Part B: Conversely, if a 100ms leader expires while a 10s follower is parked,
        // the 10s follower wakes, re-evaluates its still-valid deadline, becomes the new leader, and succeeds.
        do {
            let peer = try R3OwnedScriptedPeer(connections: 2) { connection, index, peer in
                guard let request = try connection.readHTTPRequest(),
                      let key = request.header("Sec-WebSocket-Key") else {
                    throw J2KError.invalidData("Missing Sec-WebSocket-Key on connection \(index)")
                }
                peer.mark("partB.conn.\(index).upgrade.read")
                if index == 1 {
                    // Stall connection 1 so the 100ms leader times out.
                    _ = try? connection.readHTTPRequest()
                    return
                }
                try connection.writeWebSocketServerHandshake(clientKey: key)
                peer.mark("partB.conn.2.upgrade.written")
                let incoming = try connection.readWebSocketFrame(requireMasked: true)
                var reply = Data([0x02])
                reply.append(incoming.payload[1..<5])
                reply.append(contentsOf: [0, 0, 0, 5, 0, 200, 0, 0, 77])
                try connection.writeWebSocketFrame(opcode: .binary, payload: reply, masked: false)
                peer.mark("partB.conn.2.frame.written")
            }
            defer { peer.close() }
            try await peer.waitForStartup()

            let transport = JPIPTransport(baseURL: URL(string: "ws://127.0.0.1:\(peer.port)/jpip")!)
            let shortLeader = Task {
                try await transport.send(
                    JPIPRequest(target: "short-leader.j2k"),
                    maxBodyBytes: 16,
                    deadline: ContinuousClock.now.advanced(by: .milliseconds(120)),
                    maximumStorageBytes: 65_536
                )
            }
            try await peer.waitFor("partB.conn.1.upgrade.read")
            let longFollower = Task {
                try await transport.send(
                    JPIPRequest(target: "long-follower.j2k"),
                    maxBodyBytes: 16,
                    deadline: ContinuousClock.now.advanced(by: .seconds(10)),
                    maximumStorageBytes: 65_536
                )
            }

            do {
                _ = try await shortLeader.value
                Issue.record("Expected 120ms leader to time out on stalled connection 1")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }

            let followerResp = try await longFollower.value
            #expect(followerResp.statusCode == 200)
            #expect(followerResp.data == Data([77]))

            await transport.close()
            let stopped = await peer.stopAndObserve()
            #expect(stopped, "\(peer.diagnostics)")
            #expect(peer.failures.isEmpty, "\(peer.diagnostics)")
        }
    }

    @Test func repeatedCloseAndReopenReleasesRetiredWebSocketOwnersAndQueuedData() async throws {
        let rounds = 3
        let peer = try R3OwnedScriptedPeer(connections: rounds) { connection, index, peer in
            guard let request = try connection.readHTTPRequest(),
                  let key = request.header("Sec-WebSocket-Key") else {
                throw J2KError.invalidData("Missing Sec-WebSocket-Key on connection \(index)")
            }
            try connection.writeWebSocketServerHandshake(clientKey: key)
            peer.mark("reopen.\(index).handshake")
            let incoming = try connection.readWebSocketFrame(requireMasked: true)
            guard incoming.payload.count >= 9 else {
                throw J2KError.invalidData("Short WebSocket request frame on connection \(index)")
            }
            // Push two binary data bins before the response so the transport queues pushed data.
            let encoder = JPIPWebSocketMessageEncoder()
            for binIndex in 1...2 {
                let bin = JPIPDataBin(
                    binClass: .precinct,
                    binID: index * 10 + binIndex,
                    data: Data(repeating: UInt8(index * 10 + binIndex), count: 256),
                    isComplete: true
                )
                let pushPayload = encoder.encodeDataBin(bin, requestID: nil).serialize()
                try connection.writeWebSocketFrame(opcode: .binary, payload: pushPayload, masked: false)
            }
            var reply = Data([0x02])
            reply.append(incoming.payload[1..<5])
            reply.append(contentsOf: [0, 0, 0, 5, 0, 200, 0, 0, UInt8(80 + index)])
            try connection.writeWebSocketFrame(opcode: .binary, payload: reply, masked: false)
            peer.mark("reopen.\(index).responded")
            _ = try? connection.readWebSocketFrame(requireMasked: true)
        }
        defer { peer.close() }
        try await peer.waitForStartup()

        let transport = JPIPTransport(baseURL: URL(string: "ws://127.0.0.1:\(peer.port)/jpip")!)
        for round in 1...rounds {
            weak var weakWS: JPIPWebSocketTransport?
            weak var weakBudget: JPIPWebSocketReadBudget?
            weak var weakController: JPIPWebSocketCloseController?

            do {
                let response = try await transport.send(
                    JPIPRequest(target: "round-\(round).j2k"),
                    maxBodyBytes: 4096,
                    deadline: ContinuousClock.now.advanced(by: .seconds(5)),
                    maximumStorageBytes: 65_536
                )
                #expect(response.statusCode == 200)
                #expect(response.data == Data([UInt8(80 + round)]))

                let admissionBeforeClose = await transport.receiveAdmissionSnapshot()
                let slotsBeforeClose = await transport.trackedWebSocketSlotCountForTesting
                #expect(admissionBeforeClose.queuedBytes >= 512)
                #expect(slotsBeforeClose == 1)

                if let activeWS = await transport.currentWebSocketTransportForTesting {
                    weakWS = activeWS
                    weakBudget = await activeWS.currentReadBudgetForTesting
                    weakController = activeWS.closeController
                    let queuedBins = await activeWS.receiveStorageSnapshot.queuedBins
                    #expect(queuedBins == 2)
                } else {
                    Issue.record("Expected active WebSocket transport in round \(round)")
                }
            }

            await transport.close()

            let admissionAfterClose = await transport.receiveAdmissionSnapshot()
            let currentAfterClose = await transport.currentWebSocketTransportForTesting
            #expect(admissionAfterClose.queuedBytes == 0)
            #expect(currentAfterClose == nil)

            let releaseDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while ContinuousClock.now < releaseDeadline {
                let slots = await transport.trackedWebSocketSlotCountForTesting
                if weakWS == nil && weakBudget == nil && weakController == nil && slots == 0 {
                    break
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            let slotsAfterRelease = await transport.trackedWebSocketSlotCountForTesting
            let ownersReleased = weakWS == nil && weakBudget == nil && weakController == nil && slotsAfterRelease == 0
            #expect(ownersReleased, "Round \(round): weakWS=\(String(describing: weakWS)), weakBudget=\(String(describing: weakBudget)), weakController=\(String(describing: weakController)), slots=\(slotsAfterRelease)")

            let snap = await transport.webSocketActivitySnapshot
            #expect(snap.createdTransports == round)
            #expect(snap.activeHandshakes == 0)
            #expect(snap.activeReaders == 0)
            #expect(snap.activeSockets == 0)
        }

        let stopped = await peer.stopAndObserve()
        #expect(stopped, "\(peer.diagnostics)")
        #expect(peer.failures.isEmpty, "\(peer.diagnostics)")
    }

    @Test func rejectedConcurrentRequestAndConfigurePreserveActivePolicyAndSharedConnection() async throws {
        // Part 1: Direct unit verification of transactional admission in JPIPWebSocketReadBudget.
        do {
            let budget = JPIPWebSocketReadBudget()
            defer { budget.close() }

            try budget.beginRequest(1, maxBodyBytes: 100, maximumStorageBytes: 4096, pauseAfterResponse: false)
            try budget.reservePush(payloadBytes: 10, requestID: 1)
            budget.willAllocatePayload()

            let beforeLimits = budget.configuredLimits
            let beforeSnap = budget.snapshot
            #expect(beforeLimits.body == 100)
            #expect(beforeLimits.storage == 4096)
            #expect(beforeLimits.backgroundPush == true)
            #expect(beforeSnap.payloadAllocationCount == 1)

            // Rejected overlapping beginRequest B must not overwrite bodyLimit, storageLimit, or allowsIdleReads.
            do {
                try budget.beginRequest(2, maxBodyBytes: 1, maximumStorageBytes: 1, pauseAfterResponse: true)
                Issue.record("Expected overlapping beginRequest B to fail storage preflight")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }
            #expect(budget.configuredLimits == beforeLimits)
            #expect(budget.snapshot == beforeSnap)

            // Rejected configure must also leave all configured limits and snapshot counters intact.
            do {
                try budget.configure(maxBodyBytes: 1, maximumStorageBytes: 1, allowBackgroundPush: false)
                Issue.record("Expected configure with insufficient storage to fail preflight")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }
            #expect(budget.configuredLimits == beforeLimits)
            #expect(budget.snapshot == beforeSnap)

            // Active request A must still be able to reserve its response under its 100 / 4096 limits.
            try budget.reserveResponse(bodyBytes: 1, decodedStorageBytes: 1, requestID: 1)
            budget.pauseAfterResponse(1)
            budget.endRequest(1)
            #expect(budget.configuredLimits == beforeLimits)

            // While idle (requests.isEmpty), a rejected beginRequest must not zero deliveredStorageBytes,
            // peakBytes, or payloadAllocations, nor overwrite configuredLimits.
            let idleSnapBeforeReject = budget.snapshot
            #expect(idleSnapBeforeReject.retainedStorageBytes > 1)
            #expect(idleSnapBeforeReject.peakStorageBytes > 1)
            #expect(idleSnapBeforeReject.payloadAllocationCount == 1)
            do {
                try budget.beginRequest(3, maxBodyBytes: 1, maximumStorageBytes: 1, pauseAfterResponse: true)
                Issue.record("Expected idle beginRequest with insufficient storage to fail preflight")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }
            #expect(budget.configuredLimits == beforeLimits)
            #expect(budget.snapshot == idleSnapBeforeReject)

            // Overlapping admitted request B that finishes before A must restore A's larger limits and idle policy.
            let budget2 = JPIPWebSocketReadBudget()
            defer { budget2.close() }
            try budget2.beginRequest(10, maxBodyBytes: 100, maximumStorageBytes: 4096, pauseAfterResponse: false)
            try budget2.beginRequest(11, maxBodyBytes: 50, maximumStorageBytes: 2048, pauseAfterResponse: true)
            #expect(budget2.configuredLimits.body == 50)
            #expect(budget2.configuredLimits.storage == 2048)
            #expect(budget2.configuredLimits.backgroundPush == false)
            budget2.pauseAfterResponse(11)
            budget2.endRequest(11)
            #expect(budget2.configuredLimits.body == 100)
            #expect(budget2.configuredLimits.storage == 4096)
            #expect(budget2.configuredLimits.backgroundPush == true)
            try budget2.reserveResponse(bodyBytes: 80, decodedStorageBytes: 3000, requestID: 10)
            budget2.pauseAfterResponse(10)
            budget2.endRequest(10)
        }

        // Part 2: End-to-end shared WebSocket connection regression proving A completes,
        // rejected overlapping B does not mutate limits or close the socket, and C reuses the same connection.
        do {
            let peer = try R3OwnedScriptedPeer(connections: 1) { connection, _, peer in
                guard let request = try connection.readHTTPRequest(),
                      let key = request.header("Sec-WebSocket-Key") else {
                    throw J2KError.invalidData("Missing Sec-WebSocket-Key")
                }
                try connection.writeWebSocketServerHandshake(clientKey: key)
                peer.mark("shared.handshake")

                // Read Request A and push a 64-byte data bin before A's response.
                let incomingA = try connection.readWebSocketFrame(requireMasked: true)
                guard incomingA.payload.count >= 9 else {
                    throw J2KError.invalidData("Short WebSocket frame for request A")
                }
                peer.mark("shared.a.read")
                let encoder = JPIPWebSocketMessageEncoder()
                let pushedBin = JPIPDataBin(
                    binClass: .precinct,
                    binID: 1,
                    data: Data(repeating: 0x5A, count: 64),
                    isComplete: true
                )
                let pushPayload = encoder.encodeDataBin(pushedBin, requestID: nil).serialize()
                try connection.writeWebSocketFrame(opcode: .binary, payload: pushPayload, masked: false)
                peer.mark("shared.a.push.written")

                _ = peer.waitForGate("shared.releaseAResponse")
                var replyA = Data([0x02])
                replyA.append(incomingA.payload[1..<5])
                replyA.append(contentsOf: [0, 0, 0, 36, 0, 200, 0, 0])
                replyA.append(Data(repeating: 0x41, count: 32))
                try connection.writeWebSocketFrame(opcode: .binary, payload: replyA, masked: false)
                peer.mark("shared.a.response.written")

                // Read subsequent Request C on the same WebSocket connection.
                let incomingC = try connection.readWebSocketFrame(requireMasked: true)
                guard incomingC.payload.count >= 9 else {
                    throw J2KError.invalidData("Short WebSocket frame for request C")
                }
                peer.mark("shared.c.read")
                var replyC = Data([0x02])
                replyC.append(incomingC.payload[1..<5])
                replyC.append(contentsOf: [0, 0, 0, 5, 0, 200, 0, 0, 0x43])
                try connection.writeWebSocketFrame(opcode: .binary, payload: replyC, masked: false)
                peer.mark("shared.c.response.written")
            }
            defer {
                peer.openGate("shared.releaseAResponse")
                peer.close()
            }
            try await peer.waitForStartup()

            let transport = JPIPTransport(baseURL: URL(string: "ws://127.0.0.1:\(peer.port)/jpip")!)
            let taskA = Task {
                try await transport.send(
                    JPIPRequest(target: "a.j2k"),
                    maxBodyBytes: 256,
                    deadline: ContinuousClock.now.advanced(by: .seconds(5)),
                    maximumStorageBytes: 65_536
                )
            }

            do {
                try await peer.waitFor("shared.a.push.written")
                let pushQueued = try await observeAsync {
                    await transport.receiveAdmissionSnapshot().queuedBytes >= 64
                }
                #expect(pushQueued, "\(peer.diagnostics)")

                let ws = try #require(await transport.currentWebSocketTransportForTesting)
                let budget = await ws.currentReadBudgetForTesting
                let activeLimitsBeforeB = budget.configuredLimits
                #expect(activeLimitsBeforeB.body == 256)
                #expect(activeLimitsBeforeB.storage == 65_536)
                #expect(activeLimitsBeforeB.backgroundPush == false)

                // Overlapping request B cannot admit the already-queued 64-byte push into maximumStorageBytes = 1.
                do {
                    _ = try await transport.send(
                        JPIPRequest(target: "b.j2k"),
                        maxBodyBytes: 1,
                        deadline: ContinuousClock.now.advanced(by: .seconds(5)),
                        maximumStorageBytes: 1
                    )
                    Issue.record("Expected overlapping request B to fail receive-budget admission")
                } catch let error as CodecError {
                    #expect(error.category == .resourceLimitExceeded)
                }

                // Active policy on the shared budget must remain A's (256, 65_536, false).
                #expect(budget.configuredLimits == activeLimitsBeforeB)

                // Release A's 32-byte response; A must succeed without hitting B's rejected 1-byte limit.
                peer.openGate("shared.releaseAResponse")
                let respA = try await taskA.value
                #expect(respA.statusCode == 200)
                #expect(respA.data == Data(repeating: 0x41, count: 32))

                // Send request C over the same WebSocket connection without reconnecting.
                let respC = try await transport.send(
                    JPIPRequest(target: "c.j2k"),
                    maxBodyBytes: 256,
                    deadline: ContinuousClock.now.advanced(by: .seconds(5)),
                    maximumStorageBytes: 65_536
                )
                #expect(respC.statusCode == 200)
                #expect(respC.data == Data([0x43]))

                let activity = await transport.webSocketActivitySnapshot
                #expect(activity.createdTransports == 1)
                #expect(activity.activeReaders == 1)
                #expect(activity.activeSockets == 1)

                await transport.close()
            } catch {
                peer.openGate("shared.releaseAResponse")
                taskA.cancel()
                _ = try? await taskA.value
                await transport.close()
                _ = await peer.stopAndObserve()
                throw error
            }

            let stopped = await peer.stopAndObserve()
            #expect(stopped, "\(peer.diagnostics)")
            #expect(peer.failures.isEmpty, "\(peer.diagnostics)")
        }
    }

    private func observeAsync(_ predicate: @Sendable () async -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await predicate()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return await predicate()
    }

    private func observe(_ predicate: @Sendable () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }

    private func socketPair() throws -> (JPIPTCPConnection, JPIPTCPConnection) {
        var descriptors = [Int32](repeating: -1, count: 2)
        #if canImport(Glibc)
        let stream = Int32(SOCK_STREAM.rawValue)
        #else
        let stream = SOCK_STREAM
        #endif
        let result = descriptors.withUnsafeMutableBufferPointer {
            socketpair(AF_UNIX, stream, 0, $0.baseAddress!)
        }
        guard result == 0 else { throw J2KError.networkError("Could not create local test socket pair") }
        return (JPIPTCPConnection(connectedFD: descriptors[0], timeoutSeconds: 1),
                JPIPTCPConnection(connectedFD: descriptors[1], timeoutSeconds: 1))
    }

    private func frameHeader(opcode: UInt8, payloadCount: Int) -> Data {
        if payloadCount < 126 { return Data([opcode, UInt8(payloadCount)]) }
        return Data([opcode, 0x7E, UInt8((payloadCount >> 8) & 0xFF), UInt8(payloadCount & 0xFF)])
    }

    private func responsePrefix(bodyBytes: Int) -> Data {
        let declared = bodyBytes + 4
        return Data([0x02, 0, 0, 0, 1,
                     UInt8((declared >> 24) & 0xFF), UInt8((declared >> 16) & 0xFF),
                     UInt8((declared >> 8) & 0xFF), UInt8(declared & 0xFF),
                     0, 200, 0, 0])
    }
}
