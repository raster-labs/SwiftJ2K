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
        let scenario = HTTPSHarnessScenario(mode: .complete,
            headers: ["JPIP-cnew": "cid=abc,path=/negotiated", "Content-Length": "8", "X-Probe": "kept"],
            chunks: [Data([1, 2, 3]), Data([4, 5, 6, 7, 8])])
        let fixture = HTTPSHarnessProtocol.register(scenario)
        defer { HTTPSHarnessProtocol.remove(fixture.url) }
        let transport = JPIPTransport(baseURL: fixture.url, configuration: fixture.configuration)
        let result = try await transport.send(JPIPRequest(target: "a b.j2k"), maxBodyBytes: 8,
            deadline: .now.advanced(by: .seconds(2)), maximumStorageBytes: 65_536)
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
        await transport.close()
    }

    @Test(arguments: [true, false])
    func delegateRejectsOversizedAnnouncedOrUnknownBody(declared: Bool) async throws {
        let scenario = HTTPSHarnessScenario(mode: .complete,
            headers: declared ? ["Content-Length": "9"] : [:],
            chunks: declared ? [] : [Data(repeating: 1, count: 5), Data(repeating: 2, count: 4)])
        let fixture = HTTPSHarnessProtocol.register(scenario)
        defer { HTTPSHarnessProtocol.remove(fixture.url) }
        let operation = JPIPHTTPSRequest(maximumBodyBytes: 8, maximumStorageBytes: 65_536)
        do {
            _ = try await operation.read(URLRequest(url: fixture.url), configuration: fixture.configuration,
                deadline: .now.advanced(by: .seconds(2)))
            Issue.record("Expected delegated response admission denial")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
            let expected = declared
                ? "JPIP HTTPS Content-Length (9 bytes) exceeds limit (8 bytes)."
                : "JPIP HTTPS response payload exceeds limit (8 bytes)."
            #expect(error.message == expected)
        }
        #expect(!operation.hasActiveOwners)
        #expect(scenario.request != nil)
        if declared { #expect(scenario.deliveredChunks == 0) }
        else { #expect(scenario.deliveredChunks == 2) }
    }

    @Test func absoluteDeadlineCancelsSilentResponse() async throws {
        let scenario = HTTPSHarnessScenario(mode: .silent)
        let fixture = HTTPSHarnessProtocol.register(scenario)
        defer { HTTPSHarnessProtocol.remove(fixture.url) }
        let operation = JPIPHTTPSRequest(maximumBodyBytes: 65_536, maximumStorageBytes: 262_144)
        let start = ContinuousClock.now
        do {
            _ = try await operation.read(URLRequest(url: fixture.url), configuration: fixture.configuration,
                deadline: start.advanced(by: .milliseconds(120)))
            Issue.record("Expected absolute HTTPS deadline")
        } catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(!operation.hasActiveOwners)
    }

    @Test func sharedWatchdogInterruptsAnAlreadyActiveTrickle() async throws {
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
                        "protocol started: \(scenario.request != nil)")
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            // Test the shared watchdog and cancellation lifecycle after actual
            // delegate receipt. The separate silent test covers read(deadline:)
            // timer setup; this test does not claim to cover that setup itself.
            let start = ContinuousClock.now
            let watchdog = JPIPDeadlineWatchdog(after: 0.12) {
                operation.cancel(CodecError(.resourceLimitExceeded, "JPIP HTTPS operation deadline elapsed."))
            }
            defer { watchdog.cancel() }
            do {
                _ = try await request.value
                Issue.record("Expected active-trickle deadline cancellation")
            } catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
            #expect(ContinuousClock.now - start < .seconds(2))
            #expect(!operation.hasActiveOwners)
        } catch {
            request.cancel()
            _ = try? await request.value
            throw error
        }
    }

    @Test func taskCancellationJoinsAndAllowsFollowingRequest() async throws {
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
        #expect(!operation.hasActiveOwners)
        let good = HTTPSHarnessScenario(mode: .complete, chunks: [Data([42])])
        let next = HTTPSHarnessProtocol.register(good)
        defer { HTTPSHarnessProtocol.remove(next.url) }
        let recovered = JPIPHTTPSRequest(maximumBodyBytes: 8, maximumStorageBytes: 65_536)
        let recoveredResult = try await recovered.read(URLRequest(url: next.url), configuration: next.configuration,
            deadline: .now.advanced(by: .seconds(2)))
        #expect(recoveredResult.response.data == Data([42]))
        #expect(!recovered.hasActiveOwners)
    }

    @Test(arguments: [false, true])
    func cancellationBeforeTaskPublicationNeverStartsProtocol(inPublicationGap: Bool) async throws {
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
        #expect(scenario.request == nil)
        #expect(!operation.hasActiveOwners)
    }

    @Test func expiredDeadlineReleasesUnstartedOwners() async throws {
        let scenario = HTTPSHarnessScenario(mode: .silent)
        let fixture = HTTPSHarnessProtocol.register(scenario)
        defer { HTTPSHarnessProtocol.remove(fixture.url) }
        let operation = JPIPHTTPSRequest(maximumBodyBytes: 8, maximumStorageBytes: 65_536)
        do {
            _ = try await operation.read(URLRequest(url: fixture.url), configuration: fixture.configuration,
                deadline: .now.advanced(by: .milliseconds(-1)))
            Issue.record("Expected expired-deadline preflight denial")
        } catch let error as CodecError { #expect(error.category == .resourceLimitExceeded) }
        #expect(scenario.request == nil)
        #expect(!operation.hasActiveOwners)
        await operation.waitForCompletion()
        #expect(operation.isFinished)
    }

    @Test func invalidationAloneCannotReleaseTaskAndLateCallbacksCannotResumeAgain() async throws {
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
        #expect(remainedOwned.withLock { $0 })
        #expect(!operation.hasActiveOwners)
    }

    @Test(arguments: [false, true])
    func completionAndCancellationHaveOneWinner(cancelFirst: Bool) async throws {
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
            #expect(!cancelFirst)
            #expect(result.response.data == Data([42]))
        } catch is CancellationError { #expect(cancelFirst) }
        #expect(!operation.hasActiveOwners)
    }

    @Test func completedRequestEventuallyReleasesItsDelegateOwnership() async throws {
        let scenario = HTTPSHarnessScenario(mode: .complete, chunks: [Data([42])])
        let fixture = HTTPSHarnessProtocol.register(scenario)
        defer { HTTPSHarnessProtocol.remove(fixture.url) }
        let released = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        func completeRequest() async throws {
            let operation = JPIPHTTPSRequest(maximumBodyBytes: 8, maximumStorageBytes: 65_536,
                deinitObserver: {
                    released.continuation.yield(true)
                    released.continuation.finish()
                })
            _ = try await operation.read(URLRequest(url: fixture.url), configuration: fixture.configuration,
                deadline: .now.advanced(by: .seconds(2)))
            #expect(!operation.hasActiveOwners)
        }
        try await completeRequest()
        // Foundation/autorelease and async-frame ARC may release the delegate
        // after read returns. Observe actual deinit without retaining it or
        // promising synchronous destruction at the return boundary.
        let watchdog = JPIPDeadlineWatchdog(after: 2) {
            released.continuation.yield(false)
            released.continuation.finish()
        }
        defer { watchdog.cancel() }
        for await didDeinitialise in released.stream { #expect(didDeinitialise); break }
    }

    @Test func repeatedTransportCloseJoinsTheSameSilentHTTPSOwner() async throws {
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
    let started = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private struct State { var request: URLRequest?; var delivered = 0 }
    private let state = Mutex(State())
    init(mode: Mode, headers: [String: String] = [:], chunks: [Data] = []) {
        self.mode = mode; self.headers = headers; self.chunks = chunks
    }
    var request: URLRequest? { state.withLock { $0.request } }
    var deliveredChunks: Int { state.withLock { $0.delivered } }
    func begin(_ request: URLRequest) {
        state.withLock { $0.request = request }
        started.continuation.yield(())
    }
    func delivered() { state.withLock { $0.delivered += 1 } }
}

private final class HTTPSHarnessProtocol: URLProtocol, @unchecked Sendable {
    private static let scenarios = Mutex<[String: HTTPSHarnessScenario]>([:])
    // SAFETY: per-instance mutable fields and protocol callbacks use this serial
    // queue. The registry and observations use Mutex; no blocking executor waits.
    private let queue = DispatchQueue(label: "jpip.https.protocol-harness")
    private var timer: (any DispatchSourceTimer)?
    private var stopped = false

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
        scenarios.withLock { $0[request.url?.host ?? ""] != nil }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        queue.async { [self] in
            guard !stopped, let scenario = Self.scenarios.withLock({ $0[request.url?.host ?? ""] }),
                  let url = request.url else { return }
            scenario.begin(request)
            guard scenario.mode != .silent else { return }
            guard let response = HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: scenario.headers) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if scenario.mode == .complete {
                for data in scenario.chunks {
                    scenario.delivered()
                    client?.urlProtocol(self, didLoad: data)
                }
                client?.urlProtocolDidFinishLoading(self)
            } else {
                let tick = DispatchSource.makeTimerSource(queue: queue)
                tick.schedule(deadline: .now(), repeating: .milliseconds(10))
                tick.setEventHandler { [weak self] in
                    guard let self, !self.stopped else { return }
                    scenario.delivered()
                    self.client?.urlProtocol(self, didLoad: Data([42]))
                }
                timer = tick
                tick.resume()
            }
        }
    }
    override func stopLoading() {
        queue.async { [self] in
            stopped = true
            timer?.cancel()
            timer = nil
        }
    }
}
