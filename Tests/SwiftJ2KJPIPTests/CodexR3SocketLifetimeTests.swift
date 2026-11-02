import Foundation
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2KJPIP

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Deterministic socket descriptor lifetime, non-blocking listener poll/accept,
/// descriptor-reuse model, and generation-bound server lifecycle tests (`proposal25` T1–T8).
@Suite("Codex R3 Socket Lifetime & Server Generation Tests")
struct CodexR3SocketLifetimeTests {

    // MARK: - Synchronization Primitives for Deterministic Ordering

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isSignaled = false
        private var asyncWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
        private let sema = DispatchSemaphore(value: 0)

        func signal() {
            lock.lock()
            let firstSignal = !isSignaled
            isSignaled = true
            let waiters = Array(asyncWaiters.values)
            asyncWaiters.removeAll()
            lock.unlock()
            if firstSignal {
                sema.signal()
            }
            for waiter in waiters {
                waiter.resume(returning: true)
            }
        }

        /// Synchronous wait for dedicated non-cooperative GCD worker threads / syscallSeam callbacks only.
        func wait(timeoutSeconds: TimeInterval = 5.0) -> Bool {
            lock.lock()
            if isSignaled {
                lock.unlock()
                return true
            }
            lock.unlock()
            let ok = sema.wait(timeout: .now() + timeoutSeconds) == .success
            if ok {
                sema.signal()
            }
            return ok
        }

        /// Non-blocking wait for async @Test functions on the Swift Concurrency cooperative pool.
        func waitAsync(timeoutSeconds: TimeInterval = 5.0) async -> Bool {
            let waiterID = UUID()
            return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                lock.lock()
                if isSignaled {
                    lock.unlock()
                    continuation.resume(returning: true)
                    return
                }
                asyncWaiters[waiterID] = continuation
                lock.unlock()
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeoutSeconds) { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let expired = self.asyncWaiters.removeValue(forKey: waiterID)
                    self.lock.unlock()
                    expired?.resume(returning: false)
                }
            }
        }
    }

    private actor AsyncGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func open() {
            isOpen = true
            let current = waiters
            waiters.removeAll()
            for waiter in current {
                waiter.resume()
            }
        }

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if isOpen {
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
        }
    }

    private final class AtomicBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Value

        init(_ initial: Value) {
            self.storage = initial
        }

        func withLock<R>(_ body: (inout Value) -> R) -> R {
            lock.lock()
            defer { lock.unlock() }
            return body(&storage)
        }

        var value: Value {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private static func realOSClose(_ fd: Int32) -> (rc: Int32, errno: Int32) {
        if let err = posixCloseDescriptorOnly(fd, seam: nil) {
            return (-1, err)
        }
        return (0, 0)
    }

    // MARK: - T1: Closed Before Accept

    @Test("T1: Listener closed twice before accept returns nil with zero poll/accept syscalls")
    func closedBeforeAcceptReturnsNilWithZeroSyscalls() async throws {
        await JPIPTestCooperativeQuiescence.settle()
        let counts = AtomicBox((poll: 0, accept: 0, close: 0))
        let seam = JPIPSocketSyscallSeam(
            pollListen: { _, _ in
                counts.withLock { $0.poll += 1 }
                return (0, 0, 0)
            },
            acceptClient: { _ in
                counts.withLock { $0.accept += 1 }
                return (-1, EAGAIN)
            },
            closeDescriptor: { fd in
                counts.withLock { $0.close += 1 }
                return Self.realOSClose(fd)
            }
        )

        let listener = try JPIPTCPListener(port: 0, syscallSeam: seam)
        #expect(listener.isOpen)

        listener.close()
        listener.close()
        #expect(!listener.isOpen)

        try await listener.waitForCloseCompletion()
        #expect(counts.value.close == 1)

        let workerDone = Gate()
        let acceptResult = AtomicBox<Result<JPIPTCPConnection?, Error>>(.failure(J2KError.internalError("unrun")))
        let queue = DispatchQueue(label: "test.r3.socket.t1")
        queue.async {
            acceptResult.withLock {
                $0 = Result { try listener.acceptConnection(timeoutSeconds: 1) }
            }
            workerDone.signal()
        }

        #expect(await workerDone.waitAsync(timeoutSeconds: 5.0))
        let conn = try acceptResult.value.get()
        #expect(conn == nil)
        #expect(counts.value.poll == 0)
        #expect(counts.value.accept == 0)
        #expect(counts.value.close == 1)
    }

    // MARK: - T2: Close While Borrower Held Before Poll/Accept

    @Test("T2: Close while listener borrower held retires immediately and defers physical close until release")
    func closeWhileBorrowerHeldBeforePollRetiresAndDefersPhysicalClose() async throws {
        await JPIPTestCooperativeQuiescence.settle()
        let enteredBorrow = Gate()
        let releaseBorrow = Gate()
        let counts = AtomicBox((poll: 0, accept: 0, close: 0, closeEvents: 0))

        let seam = JPIPSocketSyscallSeam(
            pollListen: { _, _ in
                counts.withLock { $0.poll += 1 }
                return (0, 0, 0)
            },
            acceptClient: { _ in
                counts.withLock { $0.accept += 1 }
                return (-1, EAGAIN)
            },
            closeDescriptor: { fd in
                counts.withLock { $0.close += 1 }
                return Self.realOSClose(fd)
            }
        )

        let listener = try JPIPTCPListener(
            port: 0,
            syscallSeam: seam,
            observer: { event in
                switch event {
                case .afterListenerBorrowAcquired:
                    enteredBorrow.signal()
                    _ = releaseBorrow.wait(timeoutSeconds: 5.0)
                case .afterPhysicalClose(_, let err, let heldLocks):
                    if err == nil && heldLocks == 0 {
                        counts.withLock { $0.closeEvents += 1 }
                    }
                default:
                    break
                }
            }
        )

        let workerDone = Gate()
        let workerOutcome = AtomicBox<Result<JPIPTCPConnection?, Error>>(.failure(J2KError.internalError("unrun")))
        let queue = DispatchQueue(label: "test.r3.socket.t2")
        queue.async {
            workerOutcome.withLock {
                $0 = Result { try listener.acceptConnection(timeoutSeconds: 2) }
            }
            workerDone.signal()
        }

        #expect(await enteredBorrow.waitAsync(timeoutSeconds: 5.0))

        // Close twice while the worker holds the listener borrow before poll/accept.
        listener.close()
        listener.close()
        #expect(!listener.isOpen)
        #expect(counts.value.close == 0)

        let waiterEntered = AsyncGate()
        let waiterTask = Task {
            await waiterEntered.open()
            try await listener.waitForCloseCompletion()
        }
        await waiterEntered.wait()
        #expect(counts.value.close == 0)

        releaseBorrow.signal()
        #expect(await workerDone.waitAsync(timeoutSeconds: 5.0))
        try await waiterTask.value

        let accepted = try workerOutcome.value.get()
        #expect(accepted == nil)
        #expect(counts.value.poll == 0)
        #expect(counts.value.accept == 0)
        #expect(counts.value.close == 1)
        #expect(counts.value.closeEvents == 1)
    }

    // MARK: - T3: Late Successful Accept Before Publication

    @Test("T3: Real loopback accept paused before publication closes accepted fd once on listener close and client sees EOF")
    func lateSuccessfulAcceptBeforePublicationClosesClientFDOnceAndClientReadsEOF() async throws {
        await JPIPTestCooperativeQuiescence.settle()
        let pausedBeforePublication = Gate()
        let resumePublicationCheck = Gate()
        let events = AtomicBox((abortedClientClosed: 0, listenerClosed: 0, pausedClientFD: Int32(-1)))

        let listener = try JPIPTCPListener(
            port: 0,
            observer: { event in
                switch event {
                case .beforeAcceptedPublication(_, let clientFD):
                    events.withLock { $0.pausedClientFD = clientFD }
                    pausedBeforePublication.signal()
                    _ = resumePublicationCheck.wait(timeoutSeconds: 5.0)
                case .abortedAcceptedClientClosed(_, let closeErrno):
                    if closeErrno == nil {
                        events.withLock { $0.abortedClientClosed += 1 }
                    }
                case .afterPhysicalClose(_, let err, let heldLocks):
                    if err == nil && heldLocks == 0 {
                        events.withLock { $0.listenerClosed += 1 }
                    }
                default:
                    break
                }
            }
        )

        let workerDone = Gate()
        let acceptOutcome = AtomicBox<Result<JPIPTCPConnection?, Error>>(.failure(J2KError.internalError("unrun")))
        let queue = DispatchQueue(label: "test.r3.socket.t3")
        queue.async {
            acceptOutcome.withLock {
                $0 = Result { try listener.acceptConnection(timeoutSeconds: 5) }
            }
            workerDone.signal()
        }

        let boundPort = listener.boundPort
        let clientConn = try await JPIPBlockingWorker.run {
            try JPIPTCPConnection.connect(
                host: "127.0.0.1",
                port: boundPort,
                timeoutInterval: 5.0
            )
        }
        defer { clientConn.close() }

        #expect(await pausedBeforePublication.waitAsync(timeoutSeconds: 5.0))
        #expect(events.value.pausedClientFD >= 0)

        // Retire listener while the accepted socket is still unexposed before publication.
        listener.close()
        #expect(!listener.isOpen)

        resumePublicationCheck.signal()
        #expect(await workerDone.waitAsync(timeoutSeconds: 5.0))
        try await listener.waitForCloseCompletion()

        let published = try acceptOutcome.value.get()
        #expect(published == nil)
        #expect(events.value.abortedClientClosed == 1)
        #expect(events.value.listenerClosed == 1)

        // Client must observe immediate EOF on the closed accepted socket.
        let eofBytes = try await JPIPBlockingWorker.run {
            try clientConn.readToEOFForTesting(maxAllowedBytes: 64)
        }
        #expect(eofBytes.isEmpty)
    }

    // MARK: - T4: Stale Readiness, EINTR, Poll Errors & fcntl Setup Failures

    @Test("T4: Stale readiness EAGAIN, EINTR, POLLNVAL/POLLERR, and fcntl setup failures retire cleanly without spin or leak")
    func staleReadinessAndEINTRAndPollErrorsAndFcntlSetupFailures() async throws {
        await JPIPTestCooperativeQuiescence.settle()
        // 4A: Stale readiness (poll returns POLLIN, accept returns EAGAIN, close ordered before retry).
        do {
            let counts = AtomicBox((poll: 0, accept: 0, close: 0))
            let listenerBox = AtomicBox<JPIPTCPListener?>(nil)
            let seam = JPIPSocketSyscallSeam(
                pollListen: { _, _ in
                    counts.withLock { $0.poll += 1 }
                    return (1, Int16(POLLIN), 0)
                },
                acceptClient: { _ in
                    counts.withLock { $0.accept += 1 }
                    listenerBox.value?.close()
                    return (-1, EAGAIN)
                },
                closeDescriptor: { fd in
                    counts.withLock { $0.close += 1 }
                    return Self.realOSClose(fd)
                }
            )
            let listener = try JPIPTCPListener(port: 0, syscallSeam: seam)
            listenerBox.withLock { $0 = listener }
            let result = try listener.acceptConnection(timeoutSeconds: 1)
            #expect(result == nil)
            #expect(!listener.isOpen)
            #expect(counts.value.poll == 1)
            #expect(counts.value.accept == 1)
            #expect(counts.value.close == 1)
            try await listener.waitForCloseCompletion()
        }

        // 4B: EINTR at poll and accept checks retirement before retry.
        do {
            let counts = AtomicBox((poll: 0, accept: 0, close: 0))
            let listenerBox = AtomicBox<JPIPTCPListener?>(nil)
            let seam = JPIPSocketSyscallSeam(
                pollListen: { _, _ in
                    let call = counts.withLock {
                        $0.poll += 1
                        return $0.poll
                    }
                    if call == 1 {
                        return (-1, 0, EINTR)
                    }
                    return (1, Int16(POLLIN), 0)
                },
                acceptClient: { _ in
                    counts.withLock { $0.accept += 1 }
                    listenerBox.value?.close()
                    return (-1, EINTR)
                },
                closeDescriptor: { fd in
                    counts.withLock { $0.close += 1 }
                    return Self.realOSClose(fd)
                }
            )
            let listener = try JPIPTCPListener(port: 0, syscallSeam: seam)
            listenerBox.withLock { $0 = listener }
            let result = try listener.acceptConnection(timeoutSeconds: 1)
            #expect(result == nil)
            #expect(!listener.isOpen)
            #expect(counts.value.poll == 2)
            #expect(counts.value.accept == 1)
            #expect(counts.value.close == 1)
        }

        // 4C: POLLNVAL retires listener without calling physical close on invalid descriptor,
        // and POLLERR retires listener before throwing so `while listener.isOpen` cannot spin.
        do {
            let closeCalls = AtomicBox(0)
            var orphanFD: Int32 = -1
            let seamNVAL = JPIPSocketSyscallSeam(
                pollListen: { _, _ in
                    (1, Int16(POLLNVAL), 0)
                },
                closeDescriptor: { fd in
                    closeCalls.withLock { $0 += 1 }
                    return Self.realOSClose(fd)
                }
            )
            let listenerNVAL = try JPIPTCPListener(port: 0, syscallSeam: seamNVAL)
            orphanFD = listenerNVAL.descriptor.debugFD
            defer {
                if orphanFD >= 0 {
                    _ = posixCloseDescriptorOnly(orphanFD, seam: nil)
                }
            }
            var loopIterations = 0
            while listenerNVAL.isOpen {
                loopIterations += 1
                #expect(throws: J2KError.self) {
                    _ = try listenerNVAL.acceptConnection(timeoutSeconds: 1)
                }
            }
            #expect(loopIterations == 1)
            #expect(!listenerNVAL.isOpen)
            #expect(closeCalls.value == 0)
            await #expect(throws: J2KError.self) {
                try await listenerNVAL.waitForCloseCompletion()
            }
        }

        do {
            let closeCalls = AtomicBox(0)
            let seamERR = JPIPSocketSyscallSeam(
                pollListen: { _, _ in
                    (1, Int16(POLLERR), 0)
                },
                closeDescriptor: { fd in
                    closeCalls.withLock { $0 += 1 }
                    return Self.realOSClose(fd)
                }
            )
            let listenerERR = try JPIPTCPListener(port: 0, syscallSeam: seamERR)
            var loopIterations = 0
            while listenerERR.isOpen {
                loopIterations += 1
                #expect(throws: J2KError.self) {
                    _ = try listenerERR.acceptConnection(timeoutSeconds: 1)
                }
            }
            #expect(loopIterations == 1)
            #expect(!listenerERR.isOpen)
            #expect(closeCalls.value == 1)
            try await listenerERR.waitForCloseCompletion()
        }

        // 4D: Listener F_GETFL / F_SETFL failures clean up exclusive fds once.
        do {
            let closedGet = AtomicBox<[Int32]>([])
            let getFailSeam = JPIPSocketSyscallSeam(
                getFlags: { _ in (-1, EINVAL) },
                closeDescriptor: { fd in
                    closedGet.withLock { $0.append(fd) }
                    return Self.realOSClose(fd)
                }
            )
            #expect(throws: J2KError.self) {
                _ = try JPIPTCPListener(port: 0, syscallSeam: getFailSeam)
            }
            #expect(closedGet.value.count == 1)

            let closedSet = AtomicBox<[Int32]>([])
            let setFailSeam = JPIPSocketSyscallSeam(
                setFlags: { _, _ in (-1, EINVAL) },
                closeDescriptor: { fd in
                    closedSet.withLock { $0.append(fd) }
                    return Self.realOSClose(fd)
                }
            )
            #expect(throws: J2KError.self) {
                _ = try JPIPTCPListener(port: 0, syscallSeam: setFailSeam)
            }
            #expect(closedSet.value.count == 1)
        }

        // Accepted-socket F_SETFL failure closes clientFD and retires listener without leaking.
        do {
            var pair: [Int32] = [-1, -1]
            #if canImport(Darwin)
            let sp = Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
            #else
            let sp = Glibc.socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &pair)
            #endif
            #expect(sp == 0)
            let fakeAcceptedFD = pair[0]
            let peerFD = pair[1]
            defer { _ = posixCloseDescriptorOnly(peerFD, seam: nil) }

            let closedFDs = AtomicBox<[Int32]>([])
            let acceptedFailSeam = JPIPSocketSyscallSeam(
                setFlags: { fd, flags in
                    if fd == fakeAcceptedFD {
                        return (-1, EIO)
                    }
                    let rc = fcntl(fd, F_SETFL, flags)
                    return (rc, rc < 0 ? currentPOSIXErrno() : 0)
                },
                pollListen: { _, _ in
                    (1, Int16(POLLIN), 0)
                },
                acceptClient: { _ in
                    (fakeAcceptedFD, 0)
                },
                closeDescriptor: { fd in
                    closedFDs.withLock { $0.append(fd) }
                    return Self.realOSClose(fd)
                }
            )
            let listener = try JPIPTCPListener(port: 0, syscallSeam: acceptedFailSeam)
            #expect(throws: J2KError.self) {
                _ = try listener.acceptConnection(timeoutSeconds: 1)
            }
            #expect(!listener.isOpen)
            #expect(closedFDs.value.contains(fakeAcceptedFD))
            #expect(closedFDs.value.count == 2) // fakeAcceptedFD + listenerFD
        }
    }

    // MARK: - T5: Deterministic Descriptor-Number Reuse Model

    @Test("T5: Deterministic descriptor-number reuse model test proves retired owner never touches recycled slot")
    func deterministicDescriptorNumberReuseModelNeverTargetsRecycledSlot() async throws {
        await JPIPTestCooperativeQuiescence.settle()
        struct SlotState {
            var generation = 1
            var availableForReuse = false
            var shutdownGen1 = 0
            var closeGen1 = 0
            var sentinelTouches = 0
        }

        let syntheticFD: Int32 = 700
        let table = AtomicBox(SlotState())
        let enteredReadBorrow = Gate()
        let releaseReadBorrow = Gate()

        let seam = JPIPSocketSyscallSeam(
            recvBytes: { fd, _, _ in
                #expect(fd == syntheticFD)
                let touch = table.withLock { state -> Bool in
                    if state.generation != 1 || state.availableForReuse {
                        state.sentinelTouches += 1
                        return true
                    }
                    return false
                }
                if touch { return (-1, EBADF) }
                enteredReadBorrow.signal()
                _ = releaseReadBorrow.wait(timeoutSeconds: 5.0)
                return (0, 0)
            },
            sendBytes: { fd, _, _ in
                #expect(fd == syntheticFD)
                return table.withLock { state in
                    if state.generation != 1 || state.availableForReuse {
                        state.sentinelTouches += 1
                    }
                    return (-1, EPIPE)
                }
            },
            setSockOpt: { fd, _, _, _ in
                #expect(fd == syntheticFD)
                return table.withLock { state in
                    if state.generation != 1 || state.availableForReuse {
                        state.sentinelTouches += 1
                    }
                    return (0, 0)
                }
            },
            shutdownSocket: { fd in
                #expect(fd == syntheticFD)
                return table.withLock { state in
                    if state.generation == 1 && !state.availableForReuse {
                        state.shutdownGen1 += 1
                        return (0, 0)
                    }
                    state.sentinelTouches += 1
                    return (-1, EBADF)
                }
            },
            closeDescriptor: { fd in
                #expect(fd == syntheticFD)
                return table.withLock { state in
                    if state.generation == 1 && !state.availableForReuse {
                        state.closeGen1 += 1
                        state.availableForReuse = true
                        return (0, 0)
                    }
                    state.sentinelTouches += 1
                    return (-1, EBADF)
                }
            }
        )

        let conn = JPIPTCPConnection(alreadyConfiguredFD: syntheticFD, syscallSeam: seam)
        let workerDone = Gate()
        let queue = DispatchQueue(label: "test.r3.socket.t5.io")
        queue.async {
            _ = try? conn.readExact(count: 4)
            workerDone.signal()
        }

        #expect(await enteredReadBorrow.waitAsync(timeoutSeconds: 5.0))

        // Initiate close while the read borrower still holds slot 700.
        conn.close()
        #expect(!conn.isOpen)
        #expect(table.value.shutdownGen1 == 1)
        #expect(table.value.closeGen1 == 0)
        #expect(!table.value.availableForReuse)

        // Release the read borrower; physical close must now make slot 700 available for reuse.
        releaseReadBorrow.signal()
        #expect(await workerDone.waitAsync(timeoutSeconds: 5.0))
        try await conn.waitForCloseCompletion()
        #expect(table.value.closeGen1 == 1)
        #expect(table.value.availableForReuse)

        // Deterministically assign slot 700 to an unrelated sentinel owner (generation 2).
        table.withLock { state in
            state.generation = 2
            state.availableForReuse = false
        }

        // Duplicate close, timeout setters, and I/O calls on the retired connection must never touch generation 2.
        conn.close()
        conn.setReceiveTimeout(interval: 1.0)
        conn.setSendTimeout(interval: 1.0)
        #expect(throws: J2KError.self) { try conn.writeAll(Data([0x01])) }
        #expect(throws: J2KError.self) { _ = try conn.readExact(count: 1) }
        try await conn.waitForCloseCompletion()
        #expect(table.value.sentinelTouches == 0)

        // Second sub-case: control-borrow shutdown finishing AFTER the I/O borrower releases.
        let enteredShutdown = Gate()
        let releaseShutdown = Gate()
        let enteredIO = Gate()
        let releaseIO = Gate()
        let orderLog = AtomicBox<[String]>([])

        let inverseSeam = JPIPSocketSyscallSeam(
            recvBytes: { _, _, _ in
                enteredIO.signal()
                _ = releaseIO.wait(timeoutSeconds: 5.0)
                orderLog.withLock { $0.append("io.end") }
                return (0, 0)
            },
            shutdownSocket: { _ in
                orderLog.withLock { $0.append("shutdown.begin") }
                enteredShutdown.signal()
                _ = releaseShutdown.wait(timeoutSeconds: 5.0)
                orderLog.withLock { $0.append("shutdown.end") }
                return (0, 0)
            },
            closeDescriptor: { _ in
                orderLog.withLock { $0.append("physical.close") }
                return (0, 0)
            }
        )

        let conn2 = JPIPTCPConnection(alreadyConfiguredFD: 701, syscallSeam: inverseSeam)
        let ioDone = Gate()
        let closeDone = Gate()
        DispatchQueue(label: "test.r3.socket.t5.io2").async {
            _ = try? conn2.readExact(count: 1)
            ioDone.signal()
        }
        #expect(await enteredIO.waitAsync(timeoutSeconds: 5.0))

        DispatchQueue(label: "test.r3.socket.t5.close2").async {
            conn2.close()
            closeDone.signal()
        }
        #expect(await enteredShutdown.waitAsync(timeoutSeconds: 5.0))

        // Let I/O finish and release its borrow while control-borrow shutdown is still in progress.
        releaseIO.signal()
        #expect(await ioDone.waitAsync(timeoutSeconds: 5.0))
        #expect(!orderLog.value.contains("physical.close"))

        // Now let shutdown finish; the control borrower releases last and performs physical close.
        releaseShutdown.signal()
        #expect(await closeDone.waitAsync(timeoutSeconds: 5.0))
        try await conn2.waitForCloseCompletion()
        #expect(orderLog.value == ["shutdown.begin", "io.end", "shutdown.end", "physical.close"])
    }

    // MARK: - T6: Connection Operations, Lock Hierarchy, Concurrent Borrowers & Waiter Propagation

    @Test("T6: Connection operations release operation locks before physical close and support concurrent read/write borrowers")
    func connectionOperationsLockHierarchyConcurrentBorrowersAndWaiters() async throws {
        await JPIPTestCooperativeQuiescence.settle()
        let operations: [JPIPSocketOperationKind] = [
            .writeAll,
            .readExact,
            .readToEOF,
            .readHTTPRequest,
            .readHTTPResponse,
            .readWebSocketFrame,
            .setReceiveTimeout,
            .setSendTimeout
        ]

        for op in operations {
            let paused = Gate()
            let resume = Gate()
            let state = AtomicBox((closed: 0, postCloseSyscalls: 0, nonZeroLockEvents: 0))

            let seam = JPIPSocketSyscallSeam(
                recvBytes: { _, buf, count in
                    if state.value.closed > 0 {
                        state.withLock { $0.postCloseSyscalls += 1 }
                    }
                    if count > 0 {
                        buf.storeBytes(of: UInt8(0x41), as: UInt8.self)
                        return (1, 0)
                    }
                    return (0, 0)
                },
                sendBytes: { _, _, count in
                    if state.value.closed > 0 {
                        state.withLock { $0.postCloseSyscalls += 1 }
                    }
                    return (max(1, count), 0)
                },
                setSockOpt: { _, _, _, _ in
                    if state.value.closed > 0 {
                        state.withLock { $0.postCloseSyscalls += 1 }
                    }
                    return (0, 0)
                },
                shutdownSocket: { _ in (0, 0) },
                closeDescriptor: { _ in
                    state.withLock { $0.closed += 1 }
                    return (0, 0)
                }
            )

            let conn = JPIPTCPConnection(
                alreadyConfiguredFD: 800 + Int32(operations.firstIndex(of: op)!),
                syscallSeam: seam,
                observer: { event in
                    switch event {
                    case .afterConnectionBorrowAcquired(let kind, _) where kind == op:
                        paused.signal()
                        _ = resume.wait(timeoutSeconds: 5.0)
                    case .beforePhysicalClose(_, let heldLocks),
                         .afterPhysicalClose(_, _, let heldLocks),
                         .beforeWaiterResume(let heldLocks):
                        if heldLocks != 0 {
                            state.withLock { $0.nonZeroLockEvents += 1 }
                        }
                    default:
                        break
                    }
                }
            )

            let workerDone = Gate()
            DispatchQueue(label: "test.r3.socket.t6.\(op)").async {
                switch op {
                case .writeAll:
                    _ = try? conn.writeAll(Data([1, 2, 3, 4]))
                case .readExact:
                    _ = try? conn.readExact(count: 4)
                case .readToEOF:
                    _ = try? conn.readToEOFForTesting(maxAllowedBytes: 16)
                case .readHTTPRequest:
                    _ = try? conn.readHTTPRequest()
                case .readHTTPResponse:
                    _ = try? conn.readHTTPResponse()
                case .readWebSocketFrame:
                    _ = try? conn.readWebSocketFrame()
                case .setReceiveTimeout:
                    conn.setReceiveTimeout(interval: 1.5)
                case .setSendTimeout:
                    conn.setSendTimeout(interval: 1.5)
                case .listenerAccept:
                    break
                }
                workerDone.signal()
            }

            #expect(await paused.waitAsync(timeoutSeconds: 5.0))
            conn.close()
            #expect(state.value.closed == 0)

            resume.signal()
            #expect(await workerDone.waitAsync(timeoutSeconds: 5.0))
            try await conn.waitForCloseCompletion()

            #expect(state.value.closed == 1)
            #expect(state.value.postCloseSyscalls == 0)
            #expect(state.value.nonZeroLockEvents == 0)
            #expect(conn.lockTracker.currentCount == 0)
        }

        // Concurrent read + write borrowers on the same connection: last release triggers physical close.
        do {
            let readPaused = Gate()
            let writePaused = Gate()
            let releaseRead = Gate()
            let releaseWrite = Gate()
            let metrics = AtomicBox((closeCount: 0, nonZeroLocks: 0))

            let seam = JPIPSocketSyscallSeam(
                recvBytes: { _, buf, _ in
                    readPaused.signal()
                    _ = releaseRead.wait(timeoutSeconds: 5.0)
                    buf.storeBytes(of: UInt8(0xAA), as: UInt8.self)
                    return (1, 0)
                },
                sendBytes: { _, _, _ in
                    writePaused.signal()
                    _ = releaseWrite.wait(timeoutSeconds: 5.0)
                    return (1, 0)
                },
                shutdownSocket: { _ in (0, 0) },
                closeDescriptor: { _ in
                    metrics.withLock { $0.closeCount += 1 }
                    return (0, 0)
                }
            )

            let conn = JPIPTCPConnection(
                alreadyConfiguredFD: 850,
                syscallSeam: seam,
                observer: { event in
                    switch event {
                    case .beforePhysicalClose(_, let heldLocks),
                         .afterPhysicalClose(_, _, let heldLocks),
                         .beforeWaiterResume(let heldLocks):
                        if heldLocks != 0 {
                            metrics.withLock { $0.nonZeroLocks += 1 }
                        }
                    default:
                        break
                    }
                }
            )

            let rDone = Gate()
            let wDone = Gate()
            DispatchQueue(label: "test.r3.socket.t6.concurrent.r").async {
                _ = try? conn.readExact(count: 2)
                rDone.signal()
            }
            DispatchQueue(label: "test.r3.socket.t6.concurrent.w").async {
                _ = try? conn.writeAll(Data([1, 2]))
                wDone.signal()
            }

            #expect(await readPaused.waitAsync(timeoutSeconds: 5.0))
            #expect(await writePaused.waitAsync(timeoutSeconds: 5.0))
            #expect(conn.lockTracker.currentCount == 2)

            // Two simultaneous close callers + multiple async waiters before and after close completion.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { conn.close() }
                group.addTask { conn.close() }
            }
            #expect(metrics.value.closeCount == 0)

            let waiter1 = Task { try await conn.waitForCloseCompletion() }
            let waiter2 = Task { try await conn.waitForCloseCompletion() }

            // Release reader first; writer still holds its borrow.
            releaseRead.signal()
            #expect(await rDone.waitAsync(timeoutSeconds: 5.0))
            #expect(metrics.value.closeCount == 0)

            // Release writer last; physical close and waiter resumption now fire with 0 held operation locks.
            releaseWrite.signal()
            #expect(await wDone.waitAsync(timeoutSeconds: 5.0))
            try await waiter1.value
            try await waiter2.value
            try await conn.waitForCloseCompletion() // Waiter registered after completion

            #expect(metrics.value.closeCount == 1)
            #expect(metrics.value.nonZeroLocks == 0)
            #expect(conn.lockTracker.currentCount == 0)
        }

        // Non-zero close(fd) errno is preserved without retrying close(fd) and thrown to all waiters.
        do {
            let closeCalls = AtomicBox(0)
            let failCloseSeam = JPIPSocketSyscallSeam(
                shutdownSocket: { _ in (0, 0) },
                closeDescriptor: { _ in
                    closeCalls.withLock { $0 += 1 }
                    return (-1, EIO)
                }
            )
            let conn = JPIPTCPConnection(alreadyConfiguredFD: 860, syscallSeam: failCloseSeam)
            conn.close()
            #expect(closeCalls.value == 1)
            await #expect(throws: J2KError.self) {
                try await conn.waitForCloseCompletion()
            }
            await #expect(throws: J2KError.self) {
                try await conn.waitForCloseCompletion()
            }
            #expect(closeCalls.value == 1)
        }
    }

    // MARK: - T7: Native Connected Cancellation & Accepted Socket Flags/Timeouts

    @Test("T7: Real loopback sockets restore blocking mode on accepted fds, preserve timeouts, and unblock recv/send on cancellation")
    func nativeConnectedCancellationAndAcceptedSocketFlagsAndTimeouts() async throws {
        await JPIPTestCooperativeQuiescence.settle()
        let listenerCloseEvents = AtomicBox(0)
        let listener = try JPIPTCPListener(
            port: 0,
            observer: { event in
                if case .afterPhysicalClose(_, let err, _) = event, err == nil {
                    listenerCloseEvents.withLock { $0 += 1 }
                }
            }
        )
        defer { listener.close() }

        let acceptedBox = AtomicBox<JPIPTCPConnection?>(nil)
        let acceptDone = Gate()
        DispatchQueue(label: "test.r3.socket.t7.accept").async {
            acceptedBox.withLock {
                $0 = try? listener.acceptConnection(timeoutSeconds: 5)
            }
            acceptDone.signal()
        }

        let recvStarted = Gate()
        let boundPort = listener.boundPort
        let clientConn = try await JPIPBlockingWorker.run {
            try JPIPTCPConnection.connect(
                host: "127.0.0.1",
                port: boundPort,
                timeoutInterval: 5.0,
                observer: { event in
                    if case .afterConnectionBorrowAcquired(let op, _) = event, op == .readExact {
                        recvStarted.signal()
                    }
                }
            )
        }
        defer { clientConn.close() }

        #expect(await acceptDone.waitAsync(timeoutSeconds: 5.0))
        let serverConn = try #require(acceptedBox.value)
        defer { serverConn.close() }

        // 1. Verify accepted socket has O_NONBLOCK cleared (blocking mode restored) and listener has O_NONBLOCK set.
        let listenerFlags = fcntl(listener.descriptor.debugFD, F_GETFL, 0)
        #expect(listenerFlags >= 0)
        #expect((listenerFlags & O_NONBLOCK) != 0)

        let acceptedFD = serverConn.descriptor.debugFD
        let acceptedFlags = fcntl(acceptedFD, F_GETFL, 0)
        #expect(acceptedFlags >= 0)
        #expect((acceptedFlags & O_NONBLOCK) == 0)

        // 2. Verify positive SO_RCVTIMEO and SO_SNDTIMEO are retained, and 0 clears timeout for WebSocket idle mode.
        var rcvTV = timeval()
        var sndTV = timeval()
        var tvLen = socklen_t(MemoryLayout<timeval>.size)
        #expect(getsockopt(acceptedFD, SOL_SOCKET, SO_RCVTIMEO, &rcvTV, &tvLen) == 0)
        #expect(getsockopt(acceptedFD, SOL_SOCKET, SO_SNDTIMEO, &sndTV, &tvLen) == 0)
        #expect(rcvTV.tv_sec > 0 || rcvTV.tv_usec > 0)
        #expect(sndTV.tv_sec > 0 || sndTV.tv_usec > 0)

        serverConn.setReceiveTimeout(seconds: 0)
        tvLen = socklen_t(MemoryLayout<timeval>.size)
        #expect(getsockopt(acceptedFD, SOL_SOCKET, SO_RCVTIMEO, &rcvTV, &tvLen) == 0)
        #expect(rcvTV.tv_sec == 0 && rcvTV.tv_usec == 0)
        serverConn.setReceiveTimeout(seconds: 30)
        clientConn.setReceiveTimeout(seconds: 30)

        // 3A. Explicit borrow-before-I/O cancellation coverage (canceling after borrow acquisition, before entering native recv).
        await JPIPTestCooperativeQuiescence.settle()
        do {
            let acceptBorrowDone = Gate()
            let acceptedBorrowBox = AtomicBox<JPIPTCPConnection?>(nil)
            DispatchQueue(label: "test.r3.socket.t7.accept.borrow").async {
                acceptedBorrowBox.withLock {
                    $0 = try? listener.acceptConnection(timeoutSeconds: 5)
                }
                acceptBorrowDone.signal()
            }
            let borrowEntered = Gate()
            let borrowRelease = Gate()
            let borrowClient = try await JPIPBlockingWorker.run {
                try JPIPTCPConnection.connect(
                    host: "127.0.0.1",
                    port: boundPort,
                    timeoutInterval: 30.0,
                    observer: { event in
                        if case .afterConnectionBorrowAcquired(let op, _) = event, op == .readExact {
                            borrowEntered.signal()
                            _ = borrowRelease.wait(timeoutSeconds: 5.0)
                        }
                    }
                )
            }
            defer { borrowClient.close() }
            #expect(await acceptBorrowDone.waitAsync(timeoutSeconds: 5.0))
            let borrowServer = try #require(acceptedBorrowBox.value)
            defer { borrowServer.close() }

            let borrowToken = JPIPSocketCancellationToken()
            #expect(borrowToken.bind(connection: borrowClient))
            let borrowDone = Gate()
            let borrowErr = AtomicBox<Error?>(nil)
            DispatchQueue(label: "test.r3.socket.t7.recv.borrow").async {
                do {
                    _ = try borrowClient.readExact(count: 16)
                } catch {
                    borrowErr.withLock { $0 = error }
                }
                borrowDone.signal()
            }
            #expect(await borrowEntered.waitAsync(timeoutSeconds: 5.0))
            await JPIPTestCooperativeQuiescence.settle()
            let borrowCancelStart = ContinuousClock.now
            borrowToken.cancel()
            borrowRelease.signal()
            #expect(await borrowDone.waitAsync(timeoutSeconds: 5.0))
            #expect(ContinuousClock.now - borrowCancelStart < .seconds(1))
            #expect(borrowErr.value != nil)
            try await borrowClient.waitForCloseCompletion()
            borrowServer.close()
            try await borrowServer.waitForCloseCompletion()
        }

        // 3B. Pending native recv() progress + non-completion + prompt cancellation:
        // Write 32 bytes from serverConn so clientConn's readExact(count: 64) observes and drains
        // the first 32 bytes (POLLIN transitions 1 -> 0) and remains unfinished awaiting the remaining
        // 32 bytes against a 30s SO_RCVTIMEO (from which blocking in the subsequent recv() is inferred).
        await JPIPTestCooperativeQuiescence.settle()
        try await JPIPBlockingWorker.run {
            try serverConn.writeAll(Data(repeating: 0x42, count: 32))
        }
        var preRecvPfd = pollfd(fd: clientConn.descriptor.debugFD, events: Int16(POLLIN), revents: 0)
        #expect(poll(&preRecvPfd, 1, 1000) == 1)
        #expect((preRecvPfd.revents & Int16(POLLIN)) != 0)

        let recvToken = JPIPSocketCancellationToken()
        #expect(recvToken.bind(connection: clientConn))
        let recvDone = Gate()
        let recvError = AtomicBox<Error?>(nil)
        DispatchQueue(label: "test.r3.socket.t7.recv").async {
            do {
                _ = try clientConn.readExact(count: 64)
            } catch {
                recvError.withLock { $0 = error }
            }
            recvDone.signal()
        }
        #expect(await recvStarted.waitAsync(timeoutSeconds: 5.0))

        // Observe that the 32 kernel-buffered bytes are drained (POLLIN == 0), showing native
        // readExact progress past the first 32 bytes while the 64-byte read remains unfinished
        // (inferring the worker is now waiting in the subsequent recv() call).
        var recvDrainedFirstHalf = false
        let recvDrainDeadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < recvDrainDeadline {
            var pfd = pollfd(fd: clientConn.descriptor.debugFD, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 0)
            if pr == 0 && (pfd.revents & Int16(POLLIN)) == 0 {
                recvDrainedFirstHalf = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(recvDrainedFirstHalf)
        // Observe that readExact(count: 64) remains unfinished across a 50ms window (30s SO_RCVTIMEO).
        #expect(!(await recvDone.waitAsync(timeoutSeconds: 0.05)))
        await JPIPTestCooperativeQuiescence.settle()

        let recvCancelStart = ContinuousClock.now
        recvToken.cancel()
        #expect(await recvDone.waitAsync(timeoutSeconds: 5.0))
        #expect(ContinuousClock.now - recvCancelStart < .seconds(1))
        let capturedRecvError = try #require(recvError.value)
        #expect(!String(describing: capturedRecvError).contains("timed out"))
        try await clientConn.waitForCloseCompletion()
        serverConn.close()
        try await serverConn.waitForCloseCompletion()

        // 4. Pending native send() progress + backpressure + prompt cancellation:
        // Start a backpressured 16 MiB writeAll (30s SO_SNDTIMEO) on a dedicated worker and observe via
        // poll() that bytes have arrived in idlePeer's receive buffer (POLLIN == 1) and sendClient's
        // send buffer is saturated (POLLOUT == 0) while writeAll remains unfinished (from which blocking
        // in native send() under backpressure is inferred) before canceling via JPIPSocketCancellationToken.
        await JPIPTestCooperativeQuiescence.settle()
        let accept2Done = Gate()
        let accepted2Box = AtomicBox<JPIPTCPConnection?>(nil)
        DispatchQueue(label: "test.r3.socket.t7.accept2").async {
            accepted2Box.withLock {
                $0 = try? listener.acceptConnection(timeoutSeconds: 5)
            }
            accept2Done.signal()
        }
        let sendStarted = Gate()
        let sendClient = try await JPIPBlockingWorker.run {
            try JPIPTCPConnection.connect(
                host: "127.0.0.1",
                port: boundPort,
                timeoutInterval: 30.0,
                observer: { event in
                    if case .afterConnectionBorrowAcquired(let op, _) = event, op == .writeAll {
                        sendStarted.signal()
                    }
                }
            )
        }
        defer { sendClient.close() }
        #expect(await accept2Done.waitAsync(timeoutSeconds: 5.0))
        let idlePeer = try #require(accepted2Box.value)
        defer { idlePeer.close() }

        var smallBuf: Int32 = 4096
        _ = setsockopt(sendClient.descriptor.debugFD, SOL_SOCKET, SO_SNDBUF, &smallBuf, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(idlePeer.descriptor.debugFD, SOL_SOCKET, SO_RCVBUF, &smallBuf, socklen_t(MemoryLayout<Int32>.size))

        let sendToken = JPIPSocketCancellationToken()
        #expect(sendToken.bind(connection: sendClient))
        let sendDone = Gate()
        let sendError = AtomicBox<Error?>(nil)
        let largePayload = Data(repeating: 0x5A, count: 16 * 1024 * 1024)
        DispatchQueue(label: "test.r3.socket.t7.send").async {
            do {
                try sendClient.writeAll(largePayload)
            } catch {
                sendError.withLock { $0 = error }
            }
            sendDone.signal()
        }
        #expect(await sendStarted.waitAsync(timeoutSeconds: 5.0))

        // Observe via poll() that native send progress delivered bytes to idlePeer (POLLIN == 1)
        // and saturated sendClient's socket send buffer (POLLOUT == 0).
        var sendBufferSaturatedInKernel = false
        let sendSaturateDeadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < sendSaturateDeadline {
            var peerPfd = pollfd(fd: idlePeer.descriptor.debugFD, events: Int16(POLLIN), revents: 0)
            var clientPfd = pollfd(fd: sendClient.descriptor.debugFD, events: Int16(POLLOUT), revents: 0)
            let peerReady = poll(&peerPfd, 1, 0) == 1 && (peerPfd.revents & Int16(POLLIN)) != 0
            let clientBlocked = poll(&clientPfd, 1, 0) == 0 && (clientPfd.revents & Int16(POLLOUT)) == 0
            if peerReady && clientBlocked {
                sendBufferSaturatedInKernel = true
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(sendBufferSaturatedInKernel)
        // Observe that writeAll remains unfinished under backpressure across a 50ms window (30s SO_SNDTIMEO).
        #expect(!(await sendDone.waitAsync(timeoutSeconds: 0.05)))
        await JPIPTestCooperativeQuiescence.settle()

        let sendCancelStart = ContinuousClock.now
        sendToken.cancel()
        #expect(await sendDone.waitAsync(timeoutSeconds: 5.0))
        #expect(ContinuousClock.now - sendCancelStart < .seconds(1))
        let capturedSendError = try #require(sendError.value)
        #expect(!String(describing: capturedSendError).contains("timed out"))
        try await sendClient.waitForCloseCompletion()

        listener.close()
        try await listener.waitForCloseCompletion()
        #expect(listenerCloseEvents.value == 1)
    }

    // MARK: - T8: Server & WebSocket Lifecycle Interleavings, Rebind, and Transport Integration

    @Test("T8: JPIPServer and JPIPWebSocketServer prevent start/stop and start/start races, reject stale generation callbacks, and rebind cleanly")
    func serverAndWebSocketLifecycleInterleavingsRebindAndTransportIntegration() async throws {
        await JPIPTestCooperativeQuiescence.settle()
        let codestream = try await J2KEncoder(encodingConfiguration: J2KEncodingConfiguration(
            quality: 1.0,
            lossless: true,
            decompositionLevels: 1
        )).encode(J2KImage(width: 8, height: 8, components: 1, bitDepth: 8))

        // 8A: Stopped JPIPActiveSocketPool rejects late arrival and closes its connection.
        do {
            let pool = JPIPActiveSocketPool()
            pool.closeAll()
            let closedCount = AtomicBox(0)
            let lateConn = JPIPTCPConnection(
                alreadyConfiguredFD: 910,
                syscallSeam: JPIPSocketSyscallSeam(
                    shutdownSocket: { _ in (0, 0) },
                    closeDescriptor: { _ in
                        closedCount.withLock { $0 += 1 }
                        return (0, 0)
                    }
                )
            )
            #expect(pool.insert(lateConn) == nil)
            #expect(!lateConn.isOpen)
            #expect(closedCount.value == 1)
        }

        // 8B: JPIPServer stop/start and start/start interleavings + stale generation callback rejection + port rebind.
        do {
            let server = JPIPServer(port: 0)
            await server.registerImageData(name: "sample.j2k", data: codestream)

            let enteredStarting = AsyncGate()
            let releaseStarting = AsyncGate()
            await server.configureTestingHooks(
                startLifecycleHook: { _ in
                    await enteredStarting.open()
                    await releaseStarting.wait()
                }
            )

            let start1Task = Task { try await server.start() }
            await enteredStarting.wait()
            #expect(await server.lifecyclePhase == .starting(generation: 1))

            // Concurrent start/start and start/stop while in .starting(1) must fail without corrupting state.
            await #expect(throws: J2KError.self) {
                try await server.start()
            }
            await #expect(throws: J2KError.self) {
                try await server.stop()
            }

            await releaseStarting.open()
            try await start1Task.value
            #expect(await server.lifecyclePhase == .running(generation: 1))
            let firstPort = await server.listeningPort
            #expect(firstPort > 0)

            // Pause stop() in .stopping(generation: 1) and verify concurrent start() and stop() are rejected.
            let enteredStopping = AsyncGate()
            let releaseStopping = AsyncGate()
            await server.configureTestingHooks(
                stopLifecycleHook: { _ in
                    await enteredStopping.open()
                    await releaseStopping.wait()
                }
            )

            let stop1Task = Task { try await server.stop() }
            await enteredStopping.wait()
            #expect(await server.lifecyclePhase == .stopping(generation: 1))

            await #expect(throws: J2KError.self) {
                try await server.start()
            }
            await #expect(throws: J2KError.self) {
                try await server.stop()
            }

            // Stale generation-1 HTTP request during .stopping(1) must return 503.
            let staleDuringStop = await server.handleWireHTTPRequest(
                JPIPHTTPWireRequest(
                    method: "GET",
                    target: "/jpip?target=sample.j2k&fsiz=8,8&cnew=http",
                    version: "HTTP/1.1",
                    headers: ["Host": "localhost"],
                    body: Data()
                ),
                generation: 1
            )
            #expect(staleDuringStop.statusCode == 503)

            await releaseStopping.open()
            try await stop1Task.value
            #expect(await server.lifecyclePhase == .idle)

            // Rebind another server instance on the exact same port immediately after stop() completion.
            let reboundServer = JPIPServer(port: firstPort)
            try await reboundServer.start()
            #expect(await reboundServer.listeningPort == firstPort)
            try await reboundServer.stop()

            // Restart original server as generation 2 and verify delayed generation-1 callbacks are rejected.
            await server.configureTestingHooks()
            try await server.start()
            #expect(await server.lifecyclePhase == .running(generation: 2))

            let gen2Resp = try await server.handleRequest(
                JPIPRequest.parseHTTPTarget("/jpip?target=sample.j2k&fsiz=8,8&cnew=http"),
                expectedGeneration: 2
            )
            let gen2CID = try #require(gen2Resp.channelID)
            #expect(await server.getActiveSessionCount() == 1)

            // Stale generation-1 request and closeSession must not touch generation 2's sessions or queue.
            await #expect(throws: J2KError.self) {
                _ = try await server.handleRequest(
                    JPIPRequest.parseHTTPTarget("/jpip?target=sample.j2k&fsiz=8,8&cnew=http"),
                    expectedGeneration: 1
                )
            }
            await server.closeSession(gen2CID, expectedGeneration: 1)
            #expect(await server.getActiveSessionCount() == 1)
            #expect(await server.getWebSocketDelegate(forServerGeneration: 1).isActive == false)

            try await server.stop()
            #expect(await server.lifecyclePhase == .idle)
        }

        // 8C: JPIPWebSocketServer start/start, stop/start, close-error recovery, and live HTTP keep-alive + RFC 6455 upgrade.
        do {
            let wsServer = JPIPWebSocketServer(port: 0)
            await wsServer.registerImageData(name: "sample.j2k", data: codestream)

            let wsStartEntered = AsyncGate()
            let wsStartRelease = AsyncGate()
            await wsServer.configureTestingHooks(
                startLifecycleHook: { _ in
                    await wsStartEntered.open()
                    await wsStartRelease.wait()
                }
            )

            let wsStartTask = Task { try await wsServer.start() }
            await wsStartEntered.wait()
            #expect(await wsServer.lifecyclePhase == .starting(generation: 1))

            // Concurrent start/start while in .starting(1) must throw and must NOT clear the attached delegate.
            await #expect(throws: J2KError.self) {
                try await wsServer.start()
            }
            await wsStartRelease.open()
            try await wsStartTask.value
            #expect(await wsServer.lifecyclePhase == .running(generation: 1))

            let port = await wsServer.listeningPort
            #expect(port > 0)

            // Persistent HTTP/1.1 keep-alive requests followed by invalid-Connection upgrade (HTTP 400) and valid upgrade (HTTP 101).
            let (httpResp1, httpResp2, badUpgradeResp) = try await JPIPBlockingWorker.run {
                let httpConn = try JPIPTCPConnection.connect(host: "127.0.0.1", port: port, timeoutInterval: 5.0)
                defer { httpConn.close() }

                try httpConn.writeHTTPRequest(
                    method: "GET",
                    pathAndQuery: "/jpip?target=sample.j2k&fsiz=8,8&cnew=http&type=jpp-stream",
                    hostHeader: "127.0.0.1:\(port)"
                )
                let resp1 = try httpConn.readHTTPResponse()

                try httpConn.writeHTTPRequest(
                    method: "GET",
                    pathAndQuery: "/jpip?target=sample.j2k&fsiz=8,8&type=jpp-stream",
                    hostHeader: "127.0.0.1:\(port)"
                )
                let resp2 = try httpConn.readHTTPResponse()

                // Invalid Connection header on WebSocket upgrade must return HTTP 400 Bad Request.
                try httpConn.writeHTTPRequest(
                    method: "GET",
                    pathAndQuery: "/jpip",
                    hostHeader: "127.0.0.1:\(port)",
                    headers: [
                        "Upgrade": "websocket",
                        "Connection": "keep-alive",
                        "Sec-WebSocket-Key": JPIPRFC6455Crypto.randomClientKey(),
                        "Sec-WebSocket-Version": "13"
                    ]
                )
                let badResp = try httpConn.readHTTPResponse()
                return (resp1, resp2, badResp)
            }
            #expect(httpResp1.statusCode == 200)
            #expect(!httpResp1.body.isEmpty)
            #expect(httpResp2.statusCode == 200)
            #expect(badUpgradeResp.statusCode == 400)

            // Valid RFC 6455 WebSocket upgrade and binary JPIP request frame exchange.
            let encoder = JPIPWebSocketMessageEncoder()
            var wsReq = JPIPRequest(target: "sample.j2k")
            wsReq.fsiz = (width: 8, height: 8)
            wsReq.cnew = .http
            let reqFramePayload = encoder.encodeRequest(wsReq, requestID: 7).serialize()
            let (wsConn, handshakeSubprotocol, wireReply) = try await JPIPBlockingWorker.run {
                let conn = try JPIPTCPConnection.connect(host: "127.0.0.1", port: port, timeoutInterval: 5.0)
                let handshake = try conn.performWebSocketClientHandshake(
                    pathAndQuery: "/jpip",
                    hostHeader: "127.0.0.1:\(port)"
                )
                try conn.writeWebSocketFrame(opcode: .binary, payload: reqFramePayload, masked: true)
                let reply = try conn.readWebSocketFrame(requireMasked: false)
                return (conn, handshake.subprotocol, reply)
            }
            defer { wsConn.close() }
            #expect(handshakeSubprotocol == "jpip")
            #expect(wireReply.opcode == .binary)
            let appReply = try #require(JPIPWebSocketFrame.deserialize(from: wireReply.payload))
            let decodedResp = try #require(encoder.decodeResponse(from: appReply))
            #expect(decodedResp.statusCode == 200)
            #expect(!decodedResp.data.isEmpty)

            // Pause wsServer.stop() in .stopping(1) and verify concurrent start() and stop() fail.
            let wsStopEntered = AsyncGate()
            let wsStopRelease = AsyncGate()
            await wsServer.configureTestingHooks(
                stopLifecycleHook: { _ in
                    await wsStopEntered.open()
                    await wsStopRelease.wait()
                }
            )

            let wsStopTask = Task { try await wsServer.stop() }
            await wsStopEntered.wait()
            #expect(await wsServer.lifecyclePhase == .stopping(generation: 1))

            await #expect(throws: J2KError.self) {
                try await wsServer.start()
            }
            await #expect(throws: J2KError.self) {
                try await wsServer.stop()
            }

            await wsStopRelease.open()
            try await wsStopTask.value
            #expect(await wsServer.lifecyclePhase == .idle)
            #expect(await wsServer.getActiveConnectionCount() == 0)

            // Inject non-zero listener close(fd) errno in generation 2 and verify stop() propagates error AND returns to .idle.
            await wsServer.configureTestingHooks(
                underlyingListenerSyscallSeamFactory: {
                    JPIPSocketSyscallSeam(
                        closeDescriptor: { fd in
                            _ = Self.realOSClose(fd)
                            return (-1, EIO)
                        }
                    )
                }
            )
            try await wsServer.start()
            #expect(await wsServer.lifecyclePhase == .running(generation: 2))
            await #expect(throws: J2KError.self) {
                try await wsServer.stop()
            }
            #expect(await wsServer.lifecyclePhase == .idle)

            // Clear hooks and confirm generation 3 starts and stops cleanly after close-error recovery.
            await wsServer.configureTestingHooks()
            try await wsServer.start()
            #expect(await wsServer.lifecyclePhase == .running(generation: 3))
            try await wsServer.stop()
            #expect(await wsServer.lifecyclePhase == .idle)
        }

        // 8D: Cross-actor generation ownership across JPIPServer <-> JPIPWebSocketServer hops
        //     with separated numeric generation counters (wsServer.lifecycleGeneration != wsServer.activeBackendGeneration).
        do {
            let wsServer = JPIPWebSocketServer(port: 0)
            await wsServer.registerImageData(name: "sample.j2k", data: codestream)

            // 1) Separate numeric generation counters: fail wsServer.start() on generation 1 before jpipServer.start() runs.
            await wsServer.configureTestingHooks(
                startLifecycleHook: { gen in
                    if gen == 1 {
                        throw J2KError.networkError("Simulated pre-backend WebSocket start failure")
                    }
                }
            )
            await #expect(throws: J2KError.self) {
                try await wsServer.start()
            }
            #expect(await wsServer.lifecyclePhase == .idle)
            #expect(await wsServer.lifecycleGeneration == 1)
            #expect(await wsServer.backendLifecycleGeneration == 0)

            await wsServer.configureTestingHooks()
            try await wsServer.start()
            #expect(await wsServer.lifecyclePhase == .running(generation: 2))
            #expect(await wsServer.backendLifecycleGeneration == 1)
            #expect(await wsServer.activeBackendGeneration == 1)
            #expect(await wsServer.lifecycleGeneration != wsServer.backendLifecycleGeneration)

            // Verify normal upgrade, cnew request, and close-session control frame succeed when counters are separated (2 != 1).
            let separatedConn = await wsServer.handleUpgradeRequest(
                headers: [
                    "Upgrade": "websocket",
                    "Connection": "Upgrade",
                    "Sec-WebSocket-Key": JPIPRFC6455Crypto.randomClientKey(),
                    "Sec-WebSocket-Version": "13",
                    "Sec-WebSocket-Protocol": "jpip"
                ]
            )
            let separatedConnID = try #require(separatedConn.connectionID)
            let encoder = JPIPWebSocketMessageEncoder()
            var sepReq = JPIPRequest(target: "sample.j2k")
            sepReq.fsiz = (width: 8, height: 8)
            sepReq.cnew = .http
            let sepReplyRaw = try await wsServer.handleFrame(
                encoder.encodeRequest(sepReq, requestID: 101),
                from: separatedConnID
            )
            let sepReplyFrame = try #require(sepReplyRaw)
            let sepDecoded = try #require(encoder.decodeResponse(from: sepReplyFrame))
            #expect(sepDecoded.statusCode == 200)
            let sepChannelID = try #require(sepDecoded.channelID)
            #expect(await wsServer.getActiveBackendSessionCount() == 1)

            let sepCloseRaw = try await wsServer.handleFrame(
                JPIPWebSocketFrame(
                    type: .control,
                    payload: Data("close-session:\(sepChannelID)".utf8),
                    requestID: 102
                ),
                from: separatedConnID
            )
            let sepCloseReply = try #require(sepCloseRaw)
            #expect(String(data: sepCloseReply.payload, encoding: .utf8) == "session-closed:\(sepChannelID)")
            #expect(await wsServer.getActiveBackendSessionCount() == 0)
            await wsServer.closeConnection(separatedConnID)
            #expect(await wsServer.getActiveConnectionCount() == 0)
            try await wsServer.stop()

            // 2) Delayed JPIPServer.serveWebSocketUpgrade -> wsServer.acceptLiveSocketUpgrade across restart:
            // Attach a reference-counted beacon to the underlying listener's syscallSeam so its deinit
            // fires only after both the listener (retired on stop()) and the accepted server-side socket
            // `conn` held on the `serveWebSocketUpgrade` worker frame have exited after the resumed hop.
            final class UpgradeWorkerCompletionBeacon: @unchecked Sendable {
                let gate: Gate
                init(_ gate: Gate) { self.gate = gate }
                deinit { gate.signal() }
            }
            let serverUpgradeWorkerCompleted = Gate()
            let upgradeHopEntered = AsyncGate()
            let upgradeHopRelease = AsyncGate()
            let capturedHopGenerations = AtomicBox<(serverGen: UInt64, delegateGen: UInt64)?>(nil)
            do {
                let beacon = UpgradeWorkerCompletionBeacon(serverUpgradeWorkerCompleted)
                await wsServer.configureTestingHooks(
                    underlyingListenerSyscallSeamFactory: {
                        JPIPSocketSyscallSeam(
                            configureAccepted: { fd, timeout in
                                _ = beacon
                                JPIPTCPConnection.configureExclusiveSocket(fd, timeoutInterval: timeout)
                            }
                        )
                    },
                    underlyingBeforeWebSocketUpgradeHopHook: { serverGen, delegateGen in
                        // Confirm separated counters: JPIPServer is gen 2, wsServer delegate is gen 3.
                        if serverGen == 2 && delegateGen == 3 {
                            capturedHopGenerations.withLock { $0 = (serverGen, delegateGen) }
                            await upgradeHopEntered.open()
                            await upgradeHopRelease.wait()
                        }
                    }
                )
            }
            try await wsServer.start()
            #expect(await wsServer.lifecyclePhase == .running(generation: 3))
            #expect(await wsServer.backendLifecycleGeneration == 2)

            let portGen3 = await wsServer.listeningPort
            let staleUpgradeClientDone = Gate()
            DispatchQueue(label: "test.r3.socket.t8.stale.upgrade").async {
                if let sock = try? JPIPTCPConnection.connect(host: "127.0.0.1", port: portGen3, timeoutInterval: 5.0) {
                    defer { sock.close() }
                    _ = try? sock.performWebSocketClientHandshake(
                        pathAndQuery: "/jpip",
                        hostHeader: "127.0.0.1:\(portGen3)"
                    )
                }
                staleUpgradeClientDone.signal()
            }
            await upgradeHopEntered.wait()
            let hopGens = try #require(capturedHopGenerations.value)
            #expect(hopGens.serverGen == 2)
            #expect(hopGens.delegateGen == 3)

            // Also stage a direct server-side upgrade hop task carrying the same captured delegateGeneration (3)
            // so we directly join and inspect the receiver's UpgradeResult decision alongside the worker completion.
            let probeSocket = JPIPTCPConnection(
                alreadyConfiguredFD: 911,
                syscallSeam: JPIPSocketSyscallSeam(
                    shutdownSocket: { _ in (0, 0) },
                    closeDescriptor: { _ in (0, 0) }
                )
            )
            defer { probeSocket.close() }
            let directHopEntered = AsyncGate()
            let directServerUpgradeHopTask = Task { () -> JPIPWebSocketServer.UpgradeResult in
                await directHopEntered.open()
                await upgradeHopRelease.wait()
                return await wsServer.acceptLiveSocketUpgrade(
                    headers: [
                        "Upgrade": "websocket",
                        "Connection": "Upgrade",
                        "Sec-WebSocket-Key": JPIPRFC6455Crypto.randomClientKey(),
                        "Sec-WebSocket-Version": "13",
                        "Sec-WebSocket-Protocol": "jpip"
                    ],
                    socket: probeSocket,
                    expectedGeneration: hopGens.delegateGen
                )
            }
            await directHopEntered.wait()

            // Stop and restart wsServer while the old upgrade hop is in flight between JPIPServer and wsServer.
            try await wsServer.stop()
            #expect(await staleUpgradeClientDone.waitAsync(timeoutSeconds: 5.0))
            // Confirm the server-side `serveWebSocketUpgrade` worker is STILL paused at the hop barrier after stop().
            #expect(!(await serverUpgradeWorkerCompleted.waitAsync(timeoutSeconds: 0.05)))

            await wsServer.configureTestingHooks()
            try await wsServer.start()
            #expect(await wsServer.lifecyclePhase == .running(generation: 4))
            #expect(await wsServer.backendLifecycleGeneration == 3)
            #expect(await wsServer.getActiveConnectionCount() == 0)
            let statsBeforeStaleUpgrade = await wsServer.statistics

            // Release the delayed upgrade hops from (serverGen: 2, delegateGen: 3) against running (serverGen: 3, delegateGen: 4),
            // join both the resumed server-side worker and the direct hop task, and assert receiving decision + admission counters.
            await upgradeHopRelease.open()
            let staleUpgradeDecision = await directServerUpgradeHopTask.value
            #expect(await serverUpgradeWorkerCompleted.waitAsync(timeoutSeconds: 5.0))
            #expect(!staleUpgradeDecision.isSuccess)
            #expect(staleUpgradeDecision.connectionID == nil)
            #expect(staleUpgradeDecision.generation == nil)
            #expect(staleUpgradeDecision.error == "Server is not running")
            let statsAfterStaleUpgrade = await wsServer.statistics
            #expect(statsAfterStaleUpgrade.upgradeRequests == statsBeforeStaleUpgrade.upgradeRequests)
            #expect(statsAfterStaleUpgrade.failedUpgrades == statsBeforeStaleUpgrade.failedUpgrades)
            #expect(statsAfterStaleUpgrade.activeConnections == 0)
            #expect(await wsServer.getActiveConnectionCount() == 0)

            // 3a) Delayed wsServer.handleFrame -> jpipServer.handleRequest with stale `cnew` tested independently:
            let connOldCnew = await wsServer.handleUpgradeRequest(
                headers: [
                    "Upgrade": "websocket",
                    "Connection": "Upgrade",
                    "Sec-WebSocket-Key": JPIPRFC6455Crypto.randomClientKey(),
                    "Sec-WebSocket-Version": "13"
                ]
            )
            let connOldCnewID = try #require(connOldCnew.connectionID)

            let cnewHopEntered = AsyncGate()
            let releaseCnewHop = AsyncGate()
            await wsServer.configureTestingHooks(
                beforeBackendRequestHopHook: { wsGen, backendGen, req in
                    if wsGen == 4 && backendGen == 3 && req.cnew != nil {
                        await cnewHopEntered.open()
                        await releaseCnewHop.wait()
                    }
                }
            )

            var oldCnewReq = JPIPRequest(target: "sample.j2k")
            oldCnewReq.fsiz = (width: 8, height: 8)
            oldCnewReq.cnew = .http
            let oldCnewFrame = encoder.encodeRequest(oldCnewReq, requestID: 201)

            let oldCnewTask = Task {
                try? await wsServer.handleFrame(oldCnewFrame, from: connOldCnewID)
            }
            await cnewHopEntered.wait()

            // Restart wsServer into (wsGen: 5, backendGen: 4) with zero sessions and release the stale cnew hop alone.
            try await wsServer.stop()
            await wsServer.configureTestingHooks()
            try await wsServer.start()
            #expect(await wsServer.lifecyclePhase == .running(generation: 5))
            #expect(await wsServer.backendLifecycleGeneration == 4)
            #expect(await wsServer.getActiveBackendSessionCount() == 0)

            await releaseCnewHop.open()
            let oldCnewResult = await oldCnewTask.value
            #expect(oldCnewResult == nil)
            // Prove no phantom session was created in the successor generation (0 -> 0).
            #expect(await wsServer.getActiveBackendSessionCount() == 0)

            // 3b) Delayed wsServer.handleFrame -> jpipServer.handleRequest with stale `cclose=*` tested independently
            //     plus verification of the exact surviving successor session identity:
            let connOldWildcard = await wsServer.handleUpgradeRequest(
                headers: [
                    "Upgrade": "websocket",
                    "Connection": "Upgrade",
                    "Sec-WebSocket-Key": JPIPRFC6455Crypto.randomClientKey(),
                    "Sec-WebSocket-Version": "13"
                ]
            )
            let connOldWildcardID = try #require(connOldWildcard.connectionID)

            let wildcardHopEntered = AsyncGate()
            let releaseWildcardHop = AsyncGate()
            await wsServer.configureTestingHooks(
                beforeBackendRequestHopHook: { wsGen, backendGen, req in
                    if wsGen == 5 && backendGen == 4 && req.cclose == ["*"] {
                        await wildcardHopEntered.open()
                        await releaseWildcardHop.wait()
                    }
                }
            )

            var oldWildcardReq = JPIPRequest(target: "sample.j2k")
            oldWildcardReq.cclose = ["*"]
            let oldWildcardFrame = encoder.encodeRequest(oldWildcardReq, requestID: 202)

            let oldWildcardTask = Task {
                try? await wsServer.handleFrame(oldWildcardFrame, from: connOldWildcardID)
            }
            await wildcardHopEntered.wait()

            // Restart wsServer into (wsGen: 6, backendGen: 5) and register "succ-active-session".
            try await wsServer.stop()
            await wsServer.configureTestingHooks()
            try await wsServer.start()
            #expect(await wsServer.lifecyclePhase == .running(generation: 6))
            #expect(await wsServer.backendLifecycleGeneration == 5)
            let succSessionID = "succ-active-session"
            await wsServer.registerTestingBackendSession(id: succSessionID, target: "sample.j2k")
            #expect(await wsServer.getActiveBackendSessionCount() == 1)

            // Release the delayed stale cclose=* hop (backendGen: 4) against the restarted backend (backendGen: 5).
            await releaseWildcardHop.open()
            let oldWildcardResult = await oldWildcardTask.value
            #expect(oldWildcardResult == nil)
            #expect(await wsServer.getActiveBackendSessionCount() == 1)

            // Prove that the exact successor session `succSessionID` survived (and was not replaced by any phantom session)
            // by issuing a stateful request with `cid = succSessionID` and `cnew = nil`.
            let connVerifySucc = await wsServer.handleUpgradeRequest(
                headers: [
                    "Upgrade": "websocket",
                    "Connection": "Upgrade",
                    "Sec-WebSocket-Key": JPIPRFC6455Crypto.randomClientKey(),
                    "Sec-WebSocket-Version": "13"
                ]
            )
            let connVerifySuccID = try #require(connVerifySucc.connectionID)
            var verifySuccReq = JPIPRequest(target: "sample.j2k")
            verifySuccReq.cid = succSessionID
            verifySuccReq.fsiz = (width: 8, height: 8)
            let verifySuccRaw = try await wsServer.handleFrame(
                encoder.encodeRequest(verifySuccReq, requestID: 203),
                from: connVerifySuccID
            )
            let verifySuccFrame = try #require(verifySuccRaw)
            let verifySuccDecoded = try #require(encoder.decodeResponse(from: verifySuccFrame))
            #expect(verifySuccDecoded.statusCode == 200)
            #expect(!verifySuccDecoded.data.isEmpty)
            #expect(await wsServer.getActiveBackendSessionCount() == 1)

            var missingReq = JPIPRequest(target: "sample.j2k")
            missingReq.cid = "non-existent-phantom-session"
            missingReq.fsiz = (width: 8, height: 8)
            await #expect(throws: J2KError.self) {
                _ = try await wsServer.handleFrame(
                    encoder.encodeRequest(missingReq, requestID: 204),
                    from: connVerifySuccID
                )
            }

            // 4) Delayed wsServer -> jpipServer.closeSession across restart (for both close-session:<sid> control frame and closeConnection):
            let connOldCtrlClose = await wsServer.handleUpgradeRequest(
                headers: [
                    "Upgrade": "websocket",
                    "Connection": "Upgrade",
                    "Sec-WebSocket-Key": JPIPRFC6455Crypto.randomClientKey(),
                    "Sec-WebSocket-Version": "13"
                ]
            )
            let connOldCtrlCloseID = try #require(connOldCtrlClose.connectionID)
            let connOldDisconnClose = await wsServer.handleUpgradeRequest(
                headers: [
                    "Upgrade": "websocket",
                    "Connection": "Upgrade",
                    "Sec-WebSocket-Key": JPIPRFC6455Crypto.randomClientKey(),
                    "Sec-WebSocket-Version": "13"
                ]
            )
            let connOldDisconnCloseID = try #require(connOldDisconnClose.connectionID)
            let sharedCollisionSID = "shared-collision-session-id"
            await wsServer.bindTestingSession(
                connectionID: connOldDisconnCloseID,
                sessionID: sharedCollisionSID
            )

            let ctrlCloseHopEntered = AsyncGate()
            let disconnCloseHopEntered = AsyncGate()
            let releaseCloseHops = AsyncGate()
            let closeHopCounter = AtomicBox(0)
            await wsServer.configureTestingHooks(
                beforeBackendCloseSessionHopHook: { wsGen, backendGen, sid in
                    if wsGen == 6 && backendGen == 5 && sid == sharedCollisionSID {
                        let idx = closeHopCounter.withLock {
                            $0 += 1
                            return $0
                        }
                        if idx == 1 {
                            await ctrlCloseHopEntered.open()
                        } else {
                            await disconnCloseHopEntered.open()
                        }
                        await releaseCloseHops.wait()
                    }
                }
            )

            let oldCtrlCloseTask = Task {
                try? await wsServer.handleFrame(
                    JPIPWebSocketFrame(
                        type: .control,
                        payload: Data("close-session:\(sharedCollisionSID)".utf8),
                        requestID: 301
                    ),
                    from: connOldCtrlCloseID
                )
            }
            let oldDisconnCloseTask = Task {
                await wsServer.closeConnection(connOldDisconnCloseID)
            }

            await ctrlCloseHopEntered.wait()
            await disconnCloseHopEntered.wait()

            // Stop and restart wsServer into (wsGen: 7, backendGen: 6) and register a session with the exact same ID.
            try await wsServer.stop()
            await wsServer.configureTestingHooks()
            try await wsServer.start()
            #expect(await wsServer.lifecyclePhase == .running(generation: 7))
            #expect(await wsServer.backendLifecycleGeneration == 6)
            await wsServer.registerTestingBackendSession(id: sharedCollisionSID, target: "sample.j2k")
            #expect(await wsServer.getActiveBackendSessionCount() == 1)

            // Release both delayed closeSession hops (carrying expectedGeneration: 5) against backend generation 6.
            await releaseCloseHops.open()
            let oldCtrlCloseResult = await oldCtrlCloseTask.value
            await oldDisconnCloseTask.value
            #expect(oldCtrlCloseResult == nil)
            // Successor session with identical sessionID remains intact because expectedGeneration: 5 != 6.
            #expect(await wsServer.getActiveBackendSessionCount() == 1)

            let connVerifyCollision = await wsServer.handleUpgradeRequest(
                headers: [
                    "Upgrade": "websocket",
                    "Connection": "Upgrade",
                    "Sec-WebSocket-Key": JPIPRFC6455Crypto.randomClientKey(),
                    "Sec-WebSocket-Version": "13"
                ]
            )
            let connVerifyCollisionID = try #require(connVerifyCollision.connectionID)
            var verifyCollisionReq = JPIPRequest(target: "sample.j2k")
            verifyCollisionReq.cid = sharedCollisionSID
            verifyCollisionReq.fsiz = (width: 8, height: 8)
            let verifyCollisionRaw = try await wsServer.handleFrame(
                encoder.encodeRequest(verifyCollisionReq, requestID: 302),
                from: connVerifyCollisionID
            )
            let verifyCollisionFrame = try #require(verifyCollisionRaw)
            let verifyCollisionDecoded = try #require(encoder.decodeResponse(from: verifyCollisionFrame))
            #expect(verifyCollisionDecoded.statusCode == 200)
            #expect(!verifyCollisionDecoded.data.isEmpty)
            #expect(await wsServer.getActiveBackendSessionCount() == 1)

            var closeExactCollisionReq = JPIPRequest(target: "sample.j2k")
            closeExactCollisionReq.cclose = [sharedCollisionSID]
            let closeExactRaw = try await wsServer.handleFrame(
                encoder.encodeRequest(closeExactCollisionReq, requestID: 303),
                from: connVerifyCollisionID
            )
            let closeExactFrame = try #require(closeExactRaw)
            let closeExactDecoded = try #require(encoder.decodeResponse(from: closeExactFrame))
            #expect(closeExactDecoded.statusCode == 200)
            #expect(await wsServer.getActiveBackendSessionCount() == 0)

            try await wsServer.stop()
            #expect(await wsServer.lifecyclePhase == .idle)
        }
    }
}
