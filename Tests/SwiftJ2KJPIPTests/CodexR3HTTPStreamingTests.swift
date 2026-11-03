// SPDX-License-Identifier: Apache-2.0
import Foundation
import Dispatch
import Synchronization
import Testing
@testable import SwiftJ2KJPIP
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transport harness coverage only: URLProtocol/scripted delegate callbacks do
/// not exercise TLS or establish independent JPIP peer interoperability.
@Suite("R3 portable HTTPS streaming transport harness")
struct CodexR3HTTPStreamingTests {
    private func response(_ headers: [String: String] = [:], status: Int = 200) throws -> HTTPURLResponse {
        try #require(HTTPURLResponse(url: URL(string: "https://harness.invalid/jpip")!,
            statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers))
    }

    private func expectLimit(_ operation: () throws -> Void) {
        do { try operation(); Issue.record("Expected HTTPS admission denial") }
        catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
        catch { Issue.record("Unexpected error: \(error)") }
    }

    @Test func observableBodyOverlapIsAdmittedBeforeGrowthAtExactBoundary() throws {
        let head = try response(["JPIP-cnew": "cid=abc,path=/channel"])
        let a = Data([1, 2, 3]), b = Data([4, 5, 6, 7, 8])
        var probe = JPIPHTTPSResponseBuffer(maximumBodyBytes: 8, maximumStorageBytes: Int.max)
        try probe.receive(head)
        let headerPeak = probe.peak
        try probe.receive(a)
        try probe.receive(b)
        let expected = try probe.finish()
        // During growth: 3 old + 5 callback + 8 new. At finish: 8 + 8.
        #expect(expected.peak == headerPeak + 16)
        #expect(expected.response.channelID == "abc")
        #expect(expected.response.data == a + b)
        var exact = JPIPHTTPSResponseBuffer(maximumBodyBytes: 8, maximumStorageBytes: expected.peak)
        try exact.receive(head); try exact.receive(a); try exact.receive(b)
        let exactResult = try exact.finish()
        #expect(exactResult.response.data == a + b)
        var short = JPIPHTTPSResponseBuffer(maximumBodyBytes: 8, maximumStorageBytes: expected.peak - 1)
        try short.receive(head); try short.receive(a)
        expectLimit { try short.receive(b) }
        #expect(short.receivedBodyBytes == 3)
        #expect(short.retainedBodyCapacity == 3)
    }

    @Test func declaredUnknownAndSingleCallbackOversizeLeavePreviousStorageIntact() throws {
        var declared = JPIPHTTPSResponseBuffer(maximumBodyBytes: 8, maximumStorageBytes: 65_536)
        expectLimit { try declared.receive(response(["Content-Length": "9"])) }
        #expect(declared.retainedBodyCapacity == 0)
        #expect(declared.receivedBodyBytes == 0)
        let knownHead = try response(["Content-Length": "8"])
        var probe = JPIPHTTPSResponseBuffer(maximumBodyBytes: 8, maximumStorageBytes: Int.max)
        try probe.receive(knownHead)
        var short = JPIPHTTPSResponseBuffer(maximumBodyBytes: 8, maximumStorageBytes: probe.peak + 15)
        expectLimit { try short.receive(knownHead) }
        #expect(short.retainedBodyCapacity == 0)
        var unknown = JPIPHTTPSResponseBuffer(maximumBodyBytes: 8, maximumStorageBytes: 65_536)
        try unknown.receive(response())
        expectLimit { try unknown.receive(Data(repeating: 0, count: 9)) }
        #expect(unknown.retainedBodyCapacity == 0)
        try unknown.receive(Data(repeating: 1, count: 5))
        expectLimit { try unknown.receive(Data(repeating: 2, count: 4)) }
        #expect(unknown.receivedBodyBytes == 5)
        #expect(unknown.retainedBodyCapacity == 5)
    }

    @Test func budgetClampedGrowthHasBoundedCopyWorkForOneByteCallbacks() throws {
        let head = try response()
        var probe = JPIPHTTPSResponseBuffer(maximumBodyBytes: 12_000, maximumStorageBytes: Int.max)
        try probe.receive(head)
        for bodyBytes in [600, 6_000] {
            // Body policy permits twice as much; storage alone forces the
            // terminal capacity, exposing repeated exact-growth regressions.
            var buffer = JPIPHTTPSResponseBuffer(maximumBodyBytes: 2 * bodyBytes,
                maximumStorageBytes: probe.peak + 2 * bodyBytes)
            try buffer.receive(head)
            for _ in 0..<bodyBytes { try buffer.receive(Data([42])) }
            let result = try buffer.finish()
            #expect(result.response.data == Data(repeating: 42, count: bodyBytes))
            #expect(buffer.copiedBodyBytes <= 4 * bodyBytes)
            // Powers of two followed by one budget-clamped terminal allocation.
            #expect(buffer.bodyAllocations <= 15)
            #expect(buffer.retainedBodyCapacity == bodyBytes)
            let previousCopies = buffer.copiedBodyBytes
            expectLimit { try buffer.receive(Data([42])) }
            #expect(buffer.copiedBodyBytes == previousCopies)
            #expect(buffer.receivedBodyBytes == bodyBytes)
        }
    }

    @Test func headersEmptyBodyStatusAndResponseTypeRemainChecked() throws {
        let fields = Dictionary(uniqueKeysWithValues: (0..<64).map { ("X-\($0)", "v") })
        var tiny = JPIPHTTPSResponseBuffer(maximumBodyBytes: 0, maximumStorageBytes: 32)
        expectLimit { try tiny.receive(response(fields)) }
        #expect(tiny.peak == 0)
        #expect(tiny.retainedBodyCapacity == 0)
        var empty = JPIPHTTPSResponseBuffer(maximumBodyBytes: 0, maximumStorageBytes: 65_536)
        try empty.receive(response(["Content-Length": "0"], status: 204))
        let completed = try empty.finish()
        #expect(completed.response.statusCode == 204)
        #expect(completed.response.data.isEmpty)
        #expect(completed.peak > 0)
        for invalid in [try response(status: 503) as URLResponse,
                        URLResponse(url: URL(string: "https://harness.invalid")!, mimeType: nil,
                                    expectedContentLength: 0, textEncodingName: nil)] {
            var buffer = JPIPHTTPSResponseBuffer(maximumBodyBytes: 8, maximumStorageBytes: 65_536)
            #expect(throws: J2KError.self) { try buffer.receive(invalid) }
            #expect(buffer.retainedBodyCapacity == 0)
        }
    }

    @Test func sharedHTTPSPathPreservesRequestHeadersBodyAndNegotiatedChannel() async throws {
        await JPIPTestCooperativeQuiescence.settle()
        let scenario = HTTPSHarnessScenario(mode: .complete,
            headers: ["JPIP-cnew": "cid=abc,path=/negotiated", "Content-Length": "8", "X-Probe": "kept"],
            chunks: [Data([1, 2, 3]), Data([4, 5, 6, 7, 8])])
        let fixture = HTTPSHarnessProtocol.register(scenario)
        defer { HTTPSHarnessProtocol.remove(fixture.url) }
        let transport = JPIPTransport(baseURL: fixture.url, configuration: fixture.configuration)
        let result: JPIPResponse
        do {
            result = try await transport.send(JPIPRequest(target: "a b.j2k"), maxBodyBytes: 8,
                deadline: .now.advanced(by: .seconds(2)), maximumStorageBytes: 65_536)
        } catch {
            let phases = await transport.lastHTTPSPhaseDiagnostics
            await transport.close()
            Issue.record("sharedHTTPSPath failed: \(error); \(phases)")
            throw error
        }
        #expect(result.statusCode == 200)
        #expect(result.channelID == "abc")
        #expect(result.data == Data([1, 2, 3, 4, 5, 6, 7, 8]))
        let probeValue = result.headers.first { $0.key.lowercased() == "x-probe" }?.value
        let channelPath = await transport.getChannelPath()
        let admission = await transport.receiveAdmissionSnapshot()
        #expect(probeValue == "kept")
        #expect(channelPath == "/negotiated")
        #expect(admission.peakBytes >= 16)
        let sent = try #require(scenario.request)
        #expect(sent.httpMethod == "GET")
        #expect(sent.value(forHTTPHeaderField: "Accept") == "image/jpp-stream, image/jpt-stream, application/octet-stream, */*")
        let queryItems = URLComponents(url: sent.url!, resolvingAgainstBaseURL: false)?.queryItems
        let target = queryItems?.first { $0.name == "target" }?.value
        #expect(target == "a b.j2k")
        let phases = await transport.lastHTTPSPhaseDiagnostics
        #expect(phases.contains("invalidation("), "\(phases)")
        #expect(phases.contains("queue.tail"), "\(phases)")
        #expect(phases.contains("resume"), "\(phases)")
        await transport.close()
    }

    @Test(arguments: [true, false])
    func delegateRejectsOversizedAnnouncedOrUnknownBody(declared: Bool) async throws {
        await JPIPTestCooperativeQuiescence.settle()
        let scenario = HTTPSHarnessScenario(mode: .complete,
            headers: declared ? ["Content-Length": "9"] : [:],
            chunks: declared ? [] : [Data(repeating: 1, count: 5), Data(repeating: 2, count: 4)])
        let fixture = HTTPSHarnessProtocol.register(scenario)
        defer { HTTPSHarnessProtocol.remove(fixture.url) }
        let operation = JPIPHTTPSRequest(maximumBodyBytes: 8, maximumStorageBytes: 65_536)
        do {
            _ = try await operation.read(URLRequest(url: fixture.url), configuration: fixture.configuration,
                deadline: .now.advanced(by: .seconds(2)))
            Issue.record("Expected delegated response admission denial; \(operation.phaseDiagnostics)")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded, "\(operation.phaseDiagnostics)")
            let expected = declared
                ? "JPIP HTTPS Content-Length (9 bytes) exceeds limit (8 bytes)."
                : "JPIP HTTPS response payload exceeds limit (8 bytes)."
            #expect(error.message == expected, "\(operation.phaseDiagnostics)")
        }
        #expect(!operation.hasActiveOwners, "\(operation.phaseDiagnostics)")
        #expect(scenario.request != nil, "\(operation.phaseDiagnostics)")
        if declared { #expect(scenario.deliveredChunks == 0, "\(operation.phaseDiagnostics)") }
        else { #expect(scenario.deliveredChunks == 2, "\(operation.phaseDiagnostics)") }
    }

    @Test func absoluteDeadlineCancelsSilentResponse() async throws {
        await JPIPTestCooperativeQuiescence.settle()
        let scenario = HTTPSHarnessScenario(mode: .silent)
        let fixture = HTTPSHarnessProtocol.register(scenario)
        defer { HTTPSHarnessProtocol.remove(fixture.url) }
        let operation = JPIPHTTPSRequest(maximumBodyBytes: 65_536, maximumStorageBytes: 262_144)
        let start = ContinuousClock.now
        do {
            _ = try await operation.read(URLRequest(url: fixture.url), configuration: fixture.configuration,
                deadline: start.advanced(by: .milliseconds(120)))
            Issue.record("Expected absolute HTTPS deadline; \(operation.phaseDiagnostics)")
        } catch let error as CodecError { #expect(error.category == .resourceLimitExceeded, "\(operation.phaseDiagnostics)") }
        #expect(ContinuousClock.now - start < .seconds(2), "\(operation.phaseDiagnostics)")
        #expect(!operation.hasActiveOwners, "\(operation.phaseDiagnostics)")
        #expect(scenario.waitForStopCompleted(), "\(operation.phaseDiagnostics)")
        let phases = "\(operation.phaseDiagnostics); \(scenario.stopDiagnostics)"
        #expect(phases.contains(": watchdog"), "\(phases)")
        #expect(phases.contains("cancel(latched=true"), "\(phases)")
        #expect(phases.contains("cancel.returned(hasTask=true)"), "\(phases)")
        #expect(phases.contains("protocol.start.called"), "\(phases)")
        #expect(phases.contains("protocol.stop.called"), "\(phases)")
        #expect(phases.contains("invalidate.requested"), "\(phases)")
        #expect(phases.contains("invalidation("), "\(phases)")
        #expect(phases.contains("queue.tail"), "\(phases)")
        #expect(phases.contains(": resume"), "\(phases)")
    }

    @Test func sharedWatchdogInterruptsAnAlreadyActiveTrickle() async throws {
        await JPIPTestCooperativeQuiescence.settle()
        let scenario = HTTPSHarnessScenario(mode: .trickle,
            headers: ["Content-Type": "image/jpp-stream"])
        let fixture = HTTPSHarnessProtocol.register(scenario)
        defer { HTTPSHarnessProtocol.remove(fixture.url) }
        let operation = JPIPHTTPSRequest(maximumBodyBytes: 65_536, maximumStorageBytes: 262_144)
        let request = Task {
            try await operation.read(URLRequest(url: fixture.url), configuration: fixture.configuration, deadline: nil)
        }
        do {
            let setupDeadline = ContinuousClock.now.advanced(by: .seconds(2))
            while operation.receivedBodyBytes < 2 {
                guard ContinuousClock.now < setupDeadline else {
                    throw J2KError.invalidState("HTTPS trickle harness did not become active: " +
                        "protocol submitted \(scenario.deliveredChunks) one-byte chunks; " +
                        "accumulator received \(operation.receivedBodyBytes) bytes; " +
                        "protocol started: \(scenario.request != nil); \(operation.phaseDiagnostics)")
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            // Test the shared watchdog and cancellation lifecycle after actual
            // delegate receipt. The separate silent test covers read(deadline:)
            // timer setup; this test does not claim to cover that setup itself.
            scenario.markWatchdogArmed()
            let start = ContinuousClock.now
            let watchdog = JPIPDeadlineWatchdog(after: 0.12) {
                operation.cancel(CodecError(.resourceLimitExceeded, "JPIP HTTPS operation deadline elapsed."))
            }
            defer { watchdog.cancel() }
            do {
                _ = try await request.value
                Issue.record("Expected active-trickle deadline cancellation; \(operation.phaseDiagnostics)")
            } catch let error as CodecError { #expect(error.category == .resourceLimitExceeded, "\(operation.phaseDiagnostics)") }
            #expect(ContinuousClock.now - start < .seconds(2), "\(operation.phaseDiagnostics)")
            #expect(!operation.hasActiveOwners, "\(operation.phaseDiagnostics)")
            #expect(scenario.chunksDeliveredDuringWatchdog >= 1, "\(operation.phaseDiagnostics)")
            #expect(scenario.waitForStopCompleted(), "\(operation.phaseDiagnostics)")
            let phases = "\(operation.phaseDiagnostics); \(scenario.stopDiagnostics)"
            #expect(phases.contains("protocol.start.called"), "\(phases)")
            #expect(phases.contains("didReceiveData(chunk=1"), "\(phases)")
            #expect(phases.contains("didReceiveData(chunk=2"), "\(phases)")
            #expect(phases.contains("protocol.trickle.overlapChunk("), "\(phases)")
            #expect(phases.contains("cancel(latched=true"), "\(phases)")
            #expect(phases.contains("cancel.returned(hasTask=true)"), "\(phases)")
            #expect(phases.contains("protocol.stop.called"), "\(phases)")
            #expect(phases.contains("protocol.stop.done(timerActive=true)"), "\(phases)")
            #expect(phases.contains("invalidate.requested"), "\(phases)")
            #expect(phases.contains("invalidation("), "\(phases)")
        } catch {
            request.cancel()
            _ = try? await request.value
            throw error
        }
        try await verifyTrickleStopWinningTimerPublicationActivatesBeforeCancel()
    }

    private func verifyTrickleStopWinningTimerPublicationActivatesBeforeCancel() async throws {
        let scenario = HTTPSHarnessScenario(
            mode: .trickle,
            headers: ["Content-Type": "image/jpp-stream"],
            pauseBeforeTrickleTimerPublication: true
        )
        let fixture = HTTPSHarnessProtocol.register(scenario)
        defer { HTTPSHarnessProtocol.remove(fixture.url) }
        let operation = JPIPHTTPSRequest(maximumBodyBytes: 65_536, maximumStorageBytes: 262_144)
        try await runTrickleStopWinningTimerPublicationAttempt(
            scenario: scenario,
            operation: operation,
            url: fixture.url,
            configuration: fixture.configuration,
            deadline: .now.advanced(by: .seconds(2))
        )
        #expect(!operation.hasActiveOwners, "\(operation.phaseDiagnostics)")
        #expect(scenario.deliveredChunks == 0, "\(operation.phaseDiagnostics)")
        #expect(scenario.cancelledAtPublication, "\(operation.phaseDiagnostics)")
        #expect(scenario.waitForStopCompleted(), "\(operation.phaseDiagnostics)")
        let phases = "\(operation.phaseDiagnostics); \(scenario.stopDiagnostics)"
        #expect(phases.contains("protocol.trickle.pausedBeforePublication"), "\(phases)")
        #expect(phases.contains("protocol.stop.called"), "\(phases)")
        #expect(phases.contains("protocol.stop.done(timerActive=false)"), "\(phases)")

        try await verifyTrickleEarlyFailureBeforeTimerPublicationDoesNotHang(
            failureMode: .expiredDeadlineBeforeStartLoading
        )
        try await verifyTrickleEarlyFailureBeforeTimerPublicationDoesNotHang(
            failureMode: .protocolFailureBeforePause
        )
        try await verifyTrickleEarlyFailureBeforeTimerPublicationDoesNotHang(
            failureMode: .protocolExitBeforePublicationFinished
        )
    }

    private enum TricklePublicationFailureMode: Sendable {
        case expiredDeadlineBeforeStartLoading
        case protocolFailureBeforePause
        case protocolExitBeforePublicationFinished
    }

    private func runTrickleStopWinningTimerPublicationAttempt(
        scenario: HTTPSHarnessScenario,
        operation: JPIPHTTPSRequest,
        url: URL,
        configuration: URLSessionConfiguration,
        deadline: ContinuousClock.Instant
    ) async throws {
        let request = Task {
            defer {
                scenario.finishTricklePublicationOnRequestExit()
            }
            return try await operation.read(
                URLRequest(url: url),
                configuration: configuration,
                deadline: deadline
            )
        }
        do {
            let pausedDelivered = await scenario.waitForTricklePublicationPaused(after: 2.0)
            guard pausedDelivered else {
                let finishedAfterEarlyExit = await scenario.waitForTricklePublicationFinished(after: 1.0)
                #expect(!finishedAfterEarlyExit, "\(operation.phaseDiagnostics)")
                throw J2KError.invalidState(
                    "Trickle harness exited before timer-publication pause: \(operation.phaseDiagnostics)"
                )
            }
            operation.cancel()
            let finishedDelivered = await scenario.waitForTricklePublicationFinished(after: 2.0)
            guard finishedDelivered else {
                throw J2KError.invalidState(
                    "Trickle harness did not finish timer publication after cancel: \(operation.phaseDiagnostics)"
                )
            }
            await #expect(throws: CancellationError.self) { _ = try await request.value }
        } catch {
            scenario.markStopCompleted()
            scenario.finishTricklePublicationStreams()
            operation.cancel()
            request.cancel()
            _ = try? await request.value
            throw error
        }
    }

    private func verifyTrickleEarlyFailureBeforeTimerPublicationDoesNotHang(
        failureMode: TricklePublicationFailureMode
    ) async throws {
        let scenario = HTTPSHarnessScenario(
            mode: .trickle,
            headers: ["Content-Type": "image/jpp-stream"],
            pauseBeforeTrickleTimerPublication: true,
            failBeforeTrickleTimerPublication: failureMode == .protocolFailureBeforePause,
            abortBeforeTricklePublicationFinished: failureMode == .protocolExitBeforePublicationFinished
        )
        let fixture = HTTPSHarnessProtocol.register(scenario)
        defer { HTTPSHarnessProtocol.remove(fixture.url) }
        let operation = JPIPHTTPSRequest(maximumBodyBytes: 65_536, maximumStorageBytes: 262_144)
        let start = ContinuousClock.now
        let deadline: ContinuousClock.Instant =
            failureMode == .expiredDeadlineBeforeStartLoading
            ? .now.advanced(by: .milliseconds(-1))
            : .now.advanced(by: .seconds(2))
        await #expect(throws: J2KError.self) {
            try await runTrickleStopWinningTimerPublicationAttempt(
                scenario: scenario,
                operation: operation,
                url: fixture.url,
                configuration: fixture.configuration,
                deadline: deadline
            )
        }
        #expect(ContinuousClock.now - start < .seconds(1), "\(operation.phaseDiagnostics)")
        #expect(!operation.hasActiveOwners, "\(operation.phaseDiagnostics)")
        #expect(scenario.deliveredChunks == 0, "\(operation.phaseDiagnostics)")
        switch failureMode {
        case .expiredDeadlineBeforeStartLoading:
            #expect(scenario.request == nil, "\(operation.phaseDiagnostics)")
            #expect(!scenario.cancelledAtPublication, "\(operation.phaseDiagnostics)")
        case .protocolFailureBeforePause:
            #expect(!scenario.cancelledAtPublication, "\(operation.phaseDiagnostics)")
            #expect(
                operation.phaseDiagnostics.contains("protocol.start.failedBeforePublication"),
                "\(operation.phaseDiagnostics)"
            )
        case .protocolExitBeforePublicationFinished:
            #expect(scenario.cancelledAtPublication, "\(operation.phaseDiagnostics)")
            #expect(scenario.abortedBeforePublicationFinished, "\(operation.phaseDiagnostics)")
        }
    }

    @Test func taskCancellationJoinsAndAllowsFollowingRequest() async throws {
        await JPIPTestCooperativeQuiescence.settle()
        let scenario = HTTPSHarnessScenario(mode: .silent)
        let fixture = HTTPSHarnessProtocol.register(scenario)
        defer { HTTPSHarnessProtocol.remove(fixture.url) }
        let operation = JPIPHTTPSRequest(maximumBodyBytes: 8, maximumStorageBytes: 65_536)
        let request = Task {
            defer { scenario.started.continuation.finish() }
            return try await operation.read(URLRequest(url: fixture.url), configuration: fixture.configuration,
                deadline: .now.advanced(by: .seconds(2)))
        }
        for await _ in scenario.started.stream { break }
        request.cancel()
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        #expect(!operation.hasActiveOwners, "\(operation.phaseDiagnostics)")
        let good = HTTPSHarnessScenario(mode: .complete, chunks: [Data([42])])
        let next = HTTPSHarnessProtocol.register(good)
        defer { HTTPSHarnessProtocol.remove(next.url) }
        let recovered = JPIPHTTPSRequest(maximumBodyBytes: 8, maximumStorageBytes: 65_536)
        let recoveredResult = try await recovered.read(URLRequest(url: next.url), configuration: next.configuration,
            deadline: .now.advanced(by: .seconds(2)))
        #expect(recoveredResult.response.data == Data([42]), "\(recovered.phaseDiagnostics)")
        #expect(!recovered.hasActiveOwners, "\(recovered.phaseDiagnostics)")
    }

    @Test(arguments: [false, true])
    func cancellationBeforeTaskPublicationNeverStartsProtocol(inPublicationGap: Bool) async throws {
        await JPIPTestCooperativeQuiescence.settle()
        let scenario = HTTPSHarnessScenario(mode: .silent)
        let fixture = HTTPSHarnessProtocol.register(scenario)
        defer { HTTPSHarnessProtocol.remove(fixture.url) }
        let operation = JPIPHTTPSRequest(maximumBodyBytes: 8, maximumStorageBytes: 65_536)
        if !inPublicationGap { operation.cancel() }
        await #expect(throws: CancellationError.self) {
            _ = try await operation.read(URLRequest(url: fixture.url), configuration: fixture.configuration,
                deadline: .now.advanced(by: .seconds(2)), beforeTaskPublication: {
                    if inPublicationGap { operation.cancel() }
                })
        }
        #expect(scenario.request == nil, "\(operation.phaseDiagnostics)")
        #expect(!operation.hasActiveOwners, "\(operation.phaseDiagnostics)")
    }

    @Test func expiredDeadlineReleasesUnstartedOwners() async throws {
        await JPIPTestCooperativeQuiescence.settle()
        let scenario = HTTPSHarnessScenario(mode: .silent)
        let fixture = HTTPSHarnessProtocol.register(scenario)
        defer { HTTPSHarnessProtocol.remove(fixture.url) }
        let operation = JPIPHTTPSRequest(maximumBodyBytes: 8, maximumStorageBytes: 65_536)
        do {
            _ = try await operation.read(URLRequest(url: fixture.url), configuration: fixture.configuration,
                deadline: .now.advanced(by: .milliseconds(-1)))
            Issue.record("Expected expired-deadline preflight denial; \(operation.phaseDiagnostics)")
        } catch let error as CodecError { #expect(error.category == .resourceLimitExceeded, "\(operation.phaseDiagnostics)") }
        #expect(scenario.request == nil, "\(operation.phaseDiagnostics)")
        #expect(!operation.hasActiveOwners, "\(operation.phaseDiagnostics)")
        await operation.waitForCompletion()
        #expect(operation.isFinished, "\(operation.phaseDiagnostics)")
    }

    @Test func invalidationAloneCannotReleaseTaskAndLateCallbacksCannotResumeAgain() async throws {
        await JPIPTestCooperativeQuiescence.settle()
        let scenario = HTTPSHarnessScenario(mode: .silent)
        let fixture = HTTPSHarnessProtocol.register(scenario)
        defer { HTTPSHarnessProtocol.remove(fixture.url) }
        let operation = JPIPHTTPSRequest(maximumBodyBytes: 8, maximumStorageBytes: 65_536)
        let remainedOwned = Mutex(false)
        await #expect(throws: CancellationError.self) {
            _ = try await operation.read(URLRequest(url: fixture.url), configuration: fixture.configuration,
                deadline: .now.advanced(by: .seconds(2)), afterTaskPublication: { owner, task in
                    // Script the otherwise unusual invalidation-before-completion
                    // order against the actual bound task, before any network work.
                    owner.delegateQueue.isSuspended = true
                    defer { owner.delegateQueue.isSuspended = false }
                    operation.cancel()
                    operation.urlSession(owner, didBecomeInvalidWithError: nil)
                    remainedOwned.withLock { $0 = operation.hasActiveOwners }
                    operation.urlSession(owner, task: task, didCompleteWithError: URLError(.cancelled))
                    operation.cancel()
                    operation.urlSession(owner, dataTask: task, didReceive: Data(repeating: 0, count: 9))
                    operation.urlSession(owner, task: task, didCompleteWithError: nil)
                    operation.urlSession(owner, didBecomeInvalidWithError: nil)
                })
        }
        #expect(remainedOwned.withLock { $0 }, "\(operation.phaseDiagnostics)")
        #expect(!operation.hasActiveOwners, "\(operation.phaseDiagnostics)")
    }

    @Test(arguments: [false, true])
    func completionAndCancellationHaveOneWinner(cancelFirst: Bool) async throws {
        await JPIPTestCooperativeQuiescence.settle()
        let scenario = HTTPSHarnessScenario(mode: .silent)
        let fixture = HTTPSHarnessProtocol.register(scenario)
        defer { HTTPSHarnessProtocol.remove(fixture.url) }
        let head = try response()
        let operation = JPIPHTTPSRequest(maximumBodyBytes: 8, maximumStorageBytes: 65_536)
        do {
            let result = try await operation.read(URLRequest(url: fixture.url), configuration: fixture.configuration,
                deadline: .now.advanced(by: .seconds(2)), afterTaskPublication: { owner, task in
                    // Hold only this request's delegate delivery while scripting
                    // both lock orders; no suite concurrency cap or blocking wait.
                    owner.delegateQueue.isSuspended = true
                    defer { owner.delegateQueue.isSuspended = false }
                    if cancelFirst { operation.cancel() }
                    operation.urlSession(owner, dataTask: task, didReceive: head) { _ in }
                    operation.urlSession(owner, dataTask: task, didReceive: Data([42]))
                    operation.urlSession(owner, task: task, didCompleteWithError: nil)
                    operation.cancel()
                    task.cancel()
                    operation.urlSession(owner, task: task, didCompleteWithError: URLError(.cancelled))
                })
            #expect(!cancelFirst, "\(operation.phaseDiagnostics)")
            #expect(result.response.data == Data([42]), "\(operation.phaseDiagnostics)")
        } catch is CancellationError {
            #expect(cancelFirst, "\(operation.phaseDiagnostics)")
        } catch {
            Issue.record("Unexpected error in completionAndCancellationHaveOneWinner(cancelFirst: \(cancelFirst)): \(error); \(operation.phaseDiagnostics)")
            throw error
        }
        #expect(!operation.hasActiveOwners, "\(operation.phaseDiagnostics)")
        let phases = operation.phaseDiagnostics
        #expect(phases.contains("invalidation("), "\(phases)")
        #expect(phases.contains("queue.tail"), "\(phases)")
        #expect(phases.contains(": resume"), "\(phases)")
        if cancelFirst {
            #expect(phases.contains("cancel(latched=true"), "\(phases)")
            #expect(phases.contains("takeResult.failed"), "\(phases)")
        } else {
            #expect(phases.contains("cancel(ignored:taskCompleted"), "\(phases)")
            #expect(phases.contains("postJoinDeadlineRecheck.ok"), "\(phases)")
        }
    }

    @Test func completedRequestEventuallyReleasesItsDelegateOwnership() async throws {
        await JPIPTestCooperativeQuiescence.settle()
        let scenario = HTTPSHarnessScenario(mode: .complete, chunks: [Data([42])])
        let fixture = HTTPSHarnessProtocol.register(scenario)
        defer { HTTPSHarnessProtocol.remove(fixture.url) }
        let released = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let phaseLog = JPIPHTTPSPhaseLog()
        func completeRequest() async throws {
            let operation = JPIPHTTPSRequest(maximumBodyBytes: 8, maximumStorageBytes: 65_536,
                phaseLog: phaseLog,
                deinitObserver: {
                    phaseLog.record("deinit")
                    released.continuation.yield(true)
                    released.continuation.finish()
                })
            do {
                _ = try await operation.read(URLRequest(url: fixture.url), configuration: fixture.configuration,
                    deadline: .now.advanced(by: .seconds(2)))
            } catch {
                Issue.record("completedRequestEventuallyReleasesItsDelegateOwnership read failed: \(error); \(phaseLog.summary)")
                throw error
            }
            #expect(!operation.hasActiveOwners, "\(phaseLog.summary)")
        }
        try await completeRequest()
        // Foundation/autorelease and async-frame ARC may release the delegate
        // after read returns. Observe actual deinit without retaining it or
        // promising synchronous destruction at the return boundary.
        let watchdog = JPIPDeadlineWatchdog(after: 2) {
            phaseLog.record("deinit.watchdog.expired")
            released.continuation.yield(false)
            released.continuation.finish()
        }
        defer { watchdog.cancel() }
        for await didDeinitialise in released.stream { #expect(didDeinitialise, "\(phaseLog.summary)"); break }
        let phases = phaseLog.summary
        #expect(phases.contains("invalidation("), "\(phases)")
        #expect(phases.contains("queue.tail"), "\(phases)")
        #expect(phases.contains(": resume"), "\(phases)")
        #expect(phases.contains("postJoinDeadlineRecheck.ok"), "\(phases)")
    }

    @Test func repeatedTransportCloseJoinsTheSameSilentHTTPSOwner() async throws {
        await JPIPTestCooperativeQuiescence.settle()
        let scenario = HTTPSHarnessScenario(mode: .silent)
        let fixture = HTTPSHarnessProtocol.register(scenario)
        defer { HTTPSHarnessProtocol.remove(fixture.url) }
        let probe = TransportLifecycleProbe()
        let queue = Mutex<OperationQueue?>(nil)
        let transport = JPIPTransport(baseURL: fixture.url, configuration: fixture.configuration)
        await transport.setRequestLifecycleObserver({ event, id in await probe.observe(event, id) },
            httpsTaskPublished: { owner, _ in queue.withLock { $0 = owner.delegateQueue } })
        let request = Task {
            defer { scenario.started.continuation.finish() }
            return try await transport.send(JPIPRequest(target: "silent"), maxBodyBytes: 8,
                deadline: .now.advanced(by: .seconds(2)), maximumStorageBytes: 65_536)
        }
        for await _ in scenario.started.stream { break }
        let delegateQueue = try #require(queue.withLock { $0 })
        delegateQueue.isSuspended = true
        let first = Task { await transport.close() }
        let second = Task { await transport.close() }
        do { try await probe.wait(.closeJoining, count: 2) }
        catch {
            delegateQueue.isSuspended = false
            request.cancel()
            await first.value; await second.value
            _ = try? await request.value
            await transport.close()
            throw error
        }
        let before = await transport.requestOwnershipSnapshot
        let joined = await probe.count(.closeJoined)
        #expect(before.registered == 1)
        #expect(before.unfinished == 1)
        #expect(joined == 0)
        delegateQueue.isSuspended = false
        await first.value; await second.value
        await #expect(throws: CancellationError.self) { _ = try await request.value }
        let after = await transport.requestOwnershipSnapshot
        let path = await transport.getChannelPath()
        #expect(after.registered == 0)
        #expect(path == nil)
    }

    @Test func closeBeforeHTTPSReadStartupJoinsWithoutResurrectingARequest() async throws {
        await JPIPTestCooperativeQuiescence.settle()
        let scenario = HTTPSHarnessScenario(mode: .silent)
        let fixture = HTTPSHarnessProtocol.register(scenario)
        defer { HTTPSHarnessProtocol.remove(fixture.url) }
        let transport = JPIPTransport(baseURL: fixture.url, configuration: fixture.configuration)
        let probe = TransportLifecycleProbe(gatingFirst: [.registered])
        await transport.setRequestLifecycleObserver({ event, id in await probe.observe(event, id) })
        let request = Task {
            try await probe.track {
                try await transport.send(JPIPRequest(target: "unstarted"), maxBodyBytes: 8,
                    deadline: .now.advanced(by: .seconds(2)), maximumStorageBytes: 65_536)
            }
        }
        do {
            try await probe.wait(.registered)
            await transport.close()
            await transport.close()
            let joined = await transport.requestOwnershipSnapshot
            #expect(joined.registered == 1) // Sender is still held; duplicate close can find it.
            #expect(joined.unfinished == 0)
            #expect(scenario.request == nil)
            await probe.release(.registered)
            await #expect(throws: CancellationError.self) { _ = try await request.value }
            #expect(scenario.request == nil)
            let finished = await transport.requestOwnershipSnapshot
            #expect(finished.registered == 0)
        } catch {
            await probe.release(.registered)
            request.cancel()
            _ = try? await request.value
            await transport.close()
            throw error
        }
    }

    @Test func oldHTTPSSuccessAndOldCloseCannotOverwriteReplacementPath() async throws {
        await JPIPTestCooperativeQuiescence.settle()
        let old = HTTPSHarnessScenario(mode: .complete,
            headers: ["JPIP-cnew": "cid=old,path=/old"], chunks: [Data([1])])
        let fixture = HTTPSHarnessProtocol.register(old)
        defer { HTTPSHarnessProtocol.remove(fixture.url) }
        let transport = JPIPTransport(baseURL: fixture.url, configuration: fixture.configuration)
        let probe = TransportLifecycleProbe(gatingFirst: [.beforePublication, .closeJoining])
        await transport.setRequestLifecycleObserver({ event, id in await probe.observe(event, id) })
        let original = Task {
            try await probe.track {
                try await transport.send(JPIPRequest(target: "old"), maxBodyBytes: 8,
                    deadline: .now.advanced(by: .seconds(2)), maximumStorageBytes: 65_536)
            }
        }
        var closing: Task<Void, Never>?
        do {
            try await probe.wait(.beforePublication)
            closing = Task { await transport.close() }
            try await probe.wait(.closeJoining)
            let fresh = HTTPSHarnessScenario(mode: .complete,
                headers: ["JPIP-cnew": "cid=fresh,path=/fresh"], chunks: [Data([2])])
            HTTPSHarnessProtocol.replace(fixture.url, with: fresh)
            let replacement = try await transport.send(JPIPRequest(target: "fresh"), maxBodyBytes: 8,
                deadline: .now.advanced(by: .seconds(2)), maximumStorageBytes: 65_536)
            #expect(replacement.channelID == "fresh")
            await probe.release(.beforePublication)
            await #expect(throws: CancellationError.self) { _ = try await original.value }
            await probe.release(.closeJoining)
            await closing?.value
            let path = await transport.getChannelPath()
            let ownership = await transport.requestOwnershipSnapshot
            #expect(path == "/fresh")
            #expect(ownership.registered == 0)
        } catch {
            await probe.release(.beforePublication); await probe.release(.closeJoining)
            original.cancel()
            _ = try? await original.value
            await closing?.value
            await transport.close()
            throw error
        }
        await transport.close()
    }
}

private final class HTTPSHarnessScenario: Sendable {
    enum Mode: Sendable { case complete, silent, trickle }
    let mode: Mode
    let headers: [String: String]
    let chunks: [Data]
    let pauseBeforeTrickleTimerPublication: Bool
    let failBeforeTrickleTimerPublication: Bool
    let abortBeforeTricklePublicationFinished: Bool
    let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let trickleTimerPublicationPaused = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let trickleTimerPublicationFinished = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private struct State {
        var request: URLRequest?
        var delivered = 0
        var watchdogArmed = false
        var deliveredDuringWatchdog = 0
        var pausedBeforePublication = false
        var publicationFinished = false
        var abortedBeforePublicationFinished = false
        var stopCompleted = false
        var stopCalled = false
        var stopTimerActive: Bool?
        var cancelledAtPublication = false
    }
    private let state = Mutex(State())
    private let stopSemaphore = DispatchSemaphore(value: 0)
    init(
        mode: Mode,
        headers: [String: String] = [:],
        chunks: [Data] = [],
        pauseBeforeTrickleTimerPublication: Bool = false,
        failBeforeTrickleTimerPublication: Bool = false,
        abortBeforeTricklePublicationFinished: Bool = false
    ) {
        self.mode = mode
        self.headers = headers
        self.chunks = chunks
        self.pauseBeforeTrickleTimerPublication = pauseBeforeTrickleTimerPublication
        self.failBeforeTrickleTimerPublication = failBeforeTrickleTimerPublication
        self.abortBeforeTricklePublicationFinished = abortBeforeTricklePublicationFinished
    }
    var request: URLRequest? { state.withLock { $0.request } }
    var deliveredChunks: Int { state.withLock { $0.delivered } }
    var chunksDeliveredDuringWatchdog: Int { state.withLock { $0.deliveredDuringWatchdog } }
    var cancelledAtPublication: Bool { state.withLock { $0.cancelledAtPublication } }
    var abortedBeforePublicationFinished: Bool { state.withLock { $0.abortedBeforePublicationFinished } }
    var stopDiagnostics: String {
        state.withLock { state in
            guard state.stopCalled else { return "protocol.stop.notCalled" }
            if let timerActive = state.stopTimerActive {
                return "protocol.stop.called; protocol.stop.done(timerActive=\(timerActive))"
            }
            return "protocol.stop.called"
        }
    }
    func begin(_ request: URLRequest) {
        state.withLock { $0.request = request }
        started.continuation.yield(())
    }
    func delivered() { state.withLock { $0.delivered += 1 } }
    func markWatchdogArmed() {
        state.withLock { $0.watchdogArmed = true }
    }
    func recordTrickleChunk() -> (total: Int, duringWatchdog: Int) {
        state.withLock { state in
            state.delivered += 1
            if state.watchdogArmed {
                state.deliveredDuringWatchdog += 1
            }
            return (state.delivered, state.deliveredDuringWatchdog)
        }
    }
    func markPausedBeforePublication() -> Bool {
        let shouldPause = state.withLock { state -> Bool in
            guard !state.stopCompleted else { return false }
            state.pausedBeforePublication = true
            return true
        }
        if shouldPause {
            trickleTimerPublicationPaused.continuation.yield(true)
        }
        trickleTimerPublicationPaused.continuation.finish()
        return shouldPause
    }
    func markPublicationFinished() {
        state.withLock { $0.publicationFinished = true }
        trickleTimerPublicationFinished.continuation.yield(true)
        trickleTimerPublicationFinished.continuation.finish()
    }
    func markAbortedBeforePublicationFinished() {
        state.withLock { $0.abortedBeforePublicationFinished = true }
    }
    func finishTricklePublicationOnRequestExit() {
        let (paused, shouldSignalStop) = state.withLock { state -> (Bool, Bool) in
            if !state.pausedBeforePublication && !state.stopCompleted {
                state.stopCompleted = true
                return (false, true)
            }
            return (state.pausedBeforePublication, false)
        }
        if shouldSignalStop {
            stopSemaphore.signal()
        }
        trickleTimerPublicationPaused.continuation.finish()
        if !paused {
            trickleTimerPublicationFinished.continuation.finish()
        }
    }
    func finishTricklePublicationStreams() {
        trickleTimerPublicationPaused.continuation.finish()
        trickleTimerPublicationFinished.continuation.finish()
    }
    func waitForTricklePublicationPaused(after seconds: TimeInterval = 2.0) async -> Bool {
        let watchdog = JPIPDeadlineWatchdog(after: seconds) { [trickleTimerPublicationPaused] in
            trickleTimerPublicationPaused.continuation.finish()
        }
        defer { watchdog.cancel() }
        for await delivered in trickleTimerPublicationPaused.stream {
            return delivered && state.withLock { $0.pausedBeforePublication }
        }
        return false
    }
    func waitForTricklePublicationFinished(after seconds: TimeInterval = 2.0) async -> Bool {
        let watchdog = JPIPDeadlineWatchdog(after: seconds) { [trickleTimerPublicationFinished] in
            trickleTimerPublicationFinished.continuation.finish()
        }
        defer { watchdog.cancel() }
        for await delivered in trickleTimerPublicationFinished.stream {
            return delivered && state.withLock { $0.publicationFinished }
        }
        return false
    }
    func markStopCompleted(timerActive: Bool? = nil) {
        let shouldSignal = state.withLock { state -> Bool in
            if let timerActive {
                state.stopCalled = true
                state.stopTimerActive = timerActive
            }
            guard !state.stopCompleted else { return false }
            state.stopCompleted = true
            return true
        }
        if shouldSignal {
            stopSemaphore.signal()
        }
    }
    func markCancelledAtPublication() {
        state.withLock { $0.cancelledAtPublication = true }
    }
    func waitForStopCompleted(timeoutSeconds: TimeInterval = 1.0) -> Bool {
        if state.withLock({ $0.stopCompleted }) {
            return true
        }
        if stopSemaphore.wait(timeout: .now() + timeoutSeconds) == .success {
            stopSemaphore.signal()
            return true
        }
        return state.withLock { $0.stopCompleted }
    }
}

private final class HTTPSHarnessProtocol: URLProtocol {
    private static let scenarios = Mutex<[String: HTTPSHarnessScenario]>([:])
    // Service protocol callbacks at the same QoS as JPIP's deadline/delegate queues,
    // and guard stopped/timer state with a Mutex so stopLoading() halts emission
    // synchronously before returning to CFNetwork.
    private let queue = DispatchQueue(label: "jpip.https.protocol-harness", qos: .userInitiated)
    private struct RuntimeState {
        var stopped = false
        var timer: (any DispatchSourceTimer)?
    }
    private let runtime = Mutex(RuntimeState())

    static func register(_ scenario: HTTPSHarnessScenario) -> (url: URL, configuration: URLSessionConfiguration) {
        let host = UUID().uuidString.lowercased() + ".invalid"
        scenarios.withLock { $0[host] = scenario }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HTTPSHarnessProtocol.self]
        config.timeoutIntervalForRequest = 5
        return (URL(string: "https://\(host)/jpip")!, config)
    }
    static func remove(_ url: URL) { scenarios.withLock { _ = $0.removeValue(forKey: url.host ?? "") } }
    static func replace(_ url: URL, with scenario: HTTPSHarnessScenario) {
        scenarios.withLock { $0[url.host ?? ""] = scenario }
    }
    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        if host.hasSuffix(".invalid") { return true }
        return scenarios.withLock { $0[host] != nil }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = self.request
        let client = self.client
        let host = request.url?.host
        JPIPHTTPSPhaseLog.record(forHost: host, "protocol.start.called")
        queue.async(execute: DispatchWorkItem { [self] in
            let scenario = Self.scenarios.withLock { $0[host ?? ""] }
            defer {
                scenario?.finishTricklePublicationStreams()
            }
            guard !runtime.withLock({ $0.stopped }),
                  let url = request.url else {
                JPIPHTTPSPhaseLog.record(forHost: host, "protocol.start.skipped")
                return
            }
            guard let scenario else {
                JPIPHTTPSPhaseLog.record(forHost: host, "protocol.start.missingScenario")
                client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
                return
            }
            JPIPHTTPSPhaseLog.record(forHost: host, "protocol.start.run(mode=\(scenario.mode))")
            scenario.begin(request)
            if scenario.failBeforeTrickleTimerPublication {
                JPIPHTTPSPhaseLog.record(forHost: host, "protocol.start.failedBeforePublication")
                client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
                return
            }
            guard scenario.mode != .silent else { return }
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: scenario.headers) else { return }
            guard !runtime.withLock({ $0.stopped }) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if scenario.mode == .complete {
                for data in scenario.chunks {
                    guard !runtime.withLock({ $0.stopped }) else { return }
                    scenario.delivered()
                    client?.urlProtocol(self, didLoad: data)
                }
                guard !runtime.withLock({ $0.stopped }) else { return }
                JPIPHTTPSPhaseLog.record(forHost: host, "protocol.finishLoading")
                client?.urlProtocolDidFinishLoading(self)
            } else {
                let tick = DispatchSource.makeTimerSource(queue: queue)
                tick.schedule(deadline: .now(), repeating: .milliseconds(15))
                tick.setEventHandler(handler: DispatchWorkItem { [weak self, weak weakClient = client] in
                    guard let self, !self.runtime.withLock({ $0.stopped }) else { return }
                    let (count, duringWatchdog) = scenario.recordTrickleChunk()
                    if count <= 2 {
                        JPIPHTTPSPhaseLog.record(forHost: host, "protocol.trickle.chunk(\(count))")
                    } else if duringWatchdog == 1 {
                        JPIPHTTPSPhaseLog.record(forHost: host, "protocol.trickle.overlapChunk(\(count))")
                    }
                    weakClient?.urlProtocol(self, didLoad: Data([42]))
                })
                if scenario.pauseBeforeTrickleTimerPublication {
                    JPIPHTTPSPhaseLog.record(forHost: host, "protocol.trickle.pausedBeforePublication")
                    if scenario.markPausedBeforePublication() {
                        _ = scenario.waitForStopCompleted()
                    }
                }
                // Always activate the DispatchSourceTimer on every path before
                // publishing or cancelling it; disposing an unactivated
                // DispatchSource traps in libdispatch.
                tick.activate()
                let shouldCancelImmediately = runtime.withLock { state -> Bool in
                    if state.stopped {
                        return true
                    }
                    state.timer = tick
                    return false
                }
                if shouldCancelImmediately {
                    scenario.markCancelledAtPublication()
                    JPIPHTTPSPhaseLog.record(forHost: host, "protocol.trickle.cancelledAtPublication")
                    tick.cancel()
                }
                if scenario.abortBeforeTricklePublicationFinished {
                    scenario.markAbortedBeforePublicationFinished()
                    JPIPHTTPSPhaseLog.record(forHost: host, "protocol.trickle.abortedBeforePublicationFinished")
                    return
                }
                scenario.markPublicationFinished()
            }
        })
    }
    override func stopLoading() {
        let host = request.url?.host
        let scenario = Self.scenarios.withLock { $0[host ?? ""] }
        JPIPHTTPSPhaseLog.record(forHost: host, "protocol.stop.called")
        let activeTimer = runtime.withLock { state -> (any DispatchSourceTimer)? in
            state.stopped = true
            let t = state.timer
            state.timer = nil
            return t
        }
        activeTimer?.cancel()
        JPIPHTTPSPhaseLog.record(forHost: host, "protocol.stop.done(timerActive=\(activeTimer != nil))")
        scenario?.markStopCompleted(timerActive: activeTimer != nil)
    }
}
