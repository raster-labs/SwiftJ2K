// SPDX-License-Identifier: Apache-2.0
//
// JPIPTCPSocket.swift
// SwiftJ2KJPIP
//
// Portable POSIX/BSD TCP listener, buffered binary TCP connection, HTTP/1.1
// request/response framing (Content-Length and Transfer-Encoding: chunked),
// and RFC 6455 WebSocket handshake + binary/control frame codec.

import Foundation
import SwiftJ2K

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Pure-Swift SHA-1 & RFC 6455 Accept Key

/// Pure-Swift RFC 3174 SHA-1 used exclusively for RFC 6455 Section 4.2.2
/// `Sec-WebSocket-Accept` handshake computation (zero external dependencies,
/// portable across Apple OS 26 and Linux).
package enum JPIPRFC6455Crypto {
    package static let websocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    package static func sha1(_ bytes: [UInt8]) -> [UInt8] {
        var msg = bytes
        let bitLen = UInt64(bytes.count) &* 8
        msg.append(0x80)
        while (msg.count % 64) != 56 {
            msg.append(0x00)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            msg.append(UInt8((bitLen >> UInt64(shift)) & 0xFF))
        }

        var h0: UInt32 = 0x6745_2301
        var h1: UInt32 = 0xEFCD_AB89
        var h2: UInt32 = 0x98BA_DCFE
        var h3: UInt32 = 0x1032_5476
        var h4: UInt32 = 0xC3D2_E1F0

        @inline(__always)
        func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 {
            (x << n) | (x >> (32 - n))
        }

        var w = [UInt32](repeating: 0, count: 80)
        for chunkStart in stride(from: 0, to: msg.count, by: 64) {
            for i in 0..<16 {
                let j = chunkStart + i * 4
                w[i] = (UInt32(msg[j]) << 24)
                    | (UInt32(msg[j + 1]) << 16)
                    | (UInt32(msg[j + 2]) << 8)
                    | UInt32(msg[j + 3])
            }
            for i in 16..<80 {
                w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
            }

            var a = h0, b = h1, c = h2, d = h3, e = h4
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0..<20:
                    f = (b & c) | ((~b) & d)
                    k = 0x5A82_7999
                case 20..<40:
                    f = b ^ c ^ d
                    k = 0x6ED9_EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1B_BCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62_C1D6
                }
                let temp = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = rotl(b, 30)
                b = a
                a = temp
            }

            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
        }

        var digest = [UInt8]()
        digest.reserveCapacity(20)
        for word in [h0, h1, h2, h3, h4] {
            digest.append(UInt8((word >> 24) & 0xFF))
            digest.append(UInt8((word >> 16) & 0xFF))
            digest.append(UInt8((word >> 8) & 0xFF))
            digest.append(UInt8(word & 0xFF))
        }
        return digest
    }

    package static func computeAcceptKey(for clientKey: String) -> String {
        let trimmed = clientKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = Array((trimmed + websocketGUID).utf8)
        return Data(sha1(combined)).base64EncodedString()
    }

    package static func randomClientKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            bytes[i] = UInt8.random(in: 0...255)
        }
        return Data(bytes).base64EncodedString()
    }
}

// MARK: - HTTP & WebSocket Wire Types

package struct JPIPHTTPWireRequest: Sendable {
    package let method: String
    package let target: String
    package let version: String
    package let headers: [String: String]
    package let body: Data

    package func header(_ name: String) -> String? {
        let lower = name.lowercased()
        for (k, v) in headers where k.lowercased() == lower {
            return v
        }
        return nil
    }
}

package struct JPIPHTTPWireResponse: Sendable {
    package let version: String
    package let statusCode: Int
    package let reasonPhrase: String
    package let headers: [String: String]
    package let body: Data
    package let retainedHeaderStorageBytes: Int
    package let peakWorkspaceBytes: Int

    package func header(_ name: String) -> String? {
        let lower = name.lowercased()
        for (k, v) in headers where k.lowercased() == lower {
            return v
        }
        return nil
    }
}

package enum JPIPRFC6455Opcode: UInt8, Sendable {
    case continuation = 0x0
    case text = 0x1
    case binary = 0x2
    case close = 0x8
    case ping = 0x9
    case pong = 0xA
}

package struct JPIPRFC6455WireFrame: Sendable {
    package let fin: Bool
    package let opcode: JPIPRFC6455Opcode
    package let payload: Data
}

// MARK: - POSIX Helpers

@inline(__always)
private var posixSocketStreamType: Int32 {
    #if canImport(Darwin)
    return SOCK_STREAM
    #else
    return Int32(SOCK_STREAM.rawValue)
    #endif
}

@inline(__always)
private var posixSendFlags: Int32 {
    #if canImport(Darwin)
    return 0
    #else
    return Int32(MSG_NOSIGNAL)
    #endif
}

@inline(__always)
package func currentPOSIXErrno() -> Int32 {
    #if canImport(Darwin)
    return Darwin.errno
    #else
    return Glibc.errno
    #endif
}

// MARK: - Scoped Descriptor Lifetime & Narrow Test Seam

package enum JPIPSocketOperationKind: Sendable, Equatable {
    case listenerAccept
    case setReceiveTimeout
    case setSendTimeout
    case writeAll
    case readExact
    case readToEOF
    case readHTTPRequest
    case readHTTPResponse
    case readWebSocketFrame
}

package enum JPIPSocketLifecycleEvent: Sendable, Equatable {
    case afterListenerBorrowAcquired(fd: Int32)
    case beforeListenerPoll(fd: Int32)
    case beforeListenerAccept(fd: Int32)
    case beforeAcceptedPublication(listenFD: Int32, clientFD: Int32)
    case abortedAcceptedClientClosed(clientFD: Int32, closeErrno: Int32?)
    case afterConnectionBorrowAcquired(op: JPIPSocketOperationKind, fd: Int32)
    case beforeControlShutdown(fd: Int32)
    case afterControlShutdown(fd: Int32)
    case beforePhysicalClose(fd: Int32, heldOperationLocks: Int)
    case afterPhysicalClose(fd: Int32, errno: Int32?, heldOperationLocks: Int)
    case beforeWaiterResume(heldOperationLocks: Int)
}

/// Narrow per-instance syscall seam for deterministic lifetime-model and
/// stale-readiness/error-injection tests (`T1`–`T6`). Always `nil` in production.
package struct JPIPSocketSyscallSeam: Sendable {
    package var getFlags: (@Sendable (Int32) -> (rc: Int32, errno: Int32))?
    package var setFlags: (@Sendable (Int32, Int32) -> (rc: Int32, errno: Int32))?
    package var pollListen: (@Sendable (Int32, Int32) -> (rc: Int32, revents: Int16, errno: Int32))?
    package var acceptClient: (@Sendable (Int32) -> (clientFD: Int32, errno: Int32))?
    package var configureAccepted: (@Sendable (Int32, TimeInterval) -> Void)?
    package var recvBytes: (@Sendable (Int32, UnsafeMutableRawPointer, Int) -> (rc: Int, errno: Int32))?
    package var sendBytes: (@Sendable (Int32, UnsafeRawPointer, Int) -> (rc: Int, errno: Int32))?
    package var setSockOpt: (@Sendable (Int32, Int32, Int32, TimeInterval) -> (rc: Int32, errno: Int32))?
    package var shutdownSocket: (@Sendable (Int32) -> (rc: Int32, errno: Int32))?
    package var closeDescriptor: (@Sendable (Int32) -> (rc: Int32, errno: Int32))?

    package init(
        getFlags: (@Sendable (Int32) -> (rc: Int32, errno: Int32))? = nil,
        setFlags: (@Sendable (Int32, Int32) -> (rc: Int32, errno: Int32))? = nil,
        pollListen: (@Sendable (Int32, Int32) -> (rc: Int32, revents: Int16, errno: Int32))? = nil,
        acceptClient: (@Sendable (Int32) -> (clientFD: Int32, errno: Int32))? = nil,
        configureAccepted: (@Sendable (Int32, TimeInterval) -> Void)? = nil,
        recvBytes: (@Sendable (Int32, UnsafeMutableRawPointer, Int) -> (rc: Int, errno: Int32))? = nil,
        sendBytes: (@Sendable (Int32, UnsafeRawPointer, Int) -> (rc: Int, errno: Int32))? = nil,
        setSockOpt: (@Sendable (Int32, Int32, Int32, TimeInterval) -> (rc: Int32, errno: Int32))? = nil,
        shutdownSocket: (@Sendable (Int32) -> (rc: Int32, errno: Int32))? = nil,
        closeDescriptor: (@Sendable (Int32) -> (rc: Int32, errno: Int32))? = nil
    ) {
        self.getFlags = getFlags
        self.setFlags = setFlags
        self.pollListen = pollListen
        self.acceptClient = acceptClient
        self.configureAccepted = configureAccepted
        self.recvBytes = recvBytes
        self.sendBytes = sendBytes
        self.setSockOpt = setSockOpt
        self.shutdownSocket = shutdownSocket
        self.closeDescriptor = closeDescriptor
    }
}

@inline(__always)
private func posixShutdownSocket(_ fd: Int32, seam: JPIPSocketSyscallSeam? = nil) -> Int32? {
    guard fd >= 0 else { return EBADF }
    if let hook = seam?.shutdownSocket {
        let res = hook(fd)
        return res.rc == 0 ? nil : max(1, res.errno)
    }
    #if canImport(Darwin)
    let rc = Darwin.shutdown(fd, SHUT_RDWR)
    #else
    let rc = Glibc.shutdown(fd, Int32(SHUT_RDWR))
    #endif
    return rc == 0 ? nil : max(1, currentPOSIXErrno())
}

/// Executes a single physical `close(fd)` without calling `shutdown` and without
/// retrying on `EINTR` or any other error (preventing closure of a recycled fd).
@inline(__always)
package func posixCloseDescriptorOnly(_ fd: Int32, seam: JPIPSocketSyscallSeam? = nil) -> Int32? {
    guard fd >= 0 else { return EBADF }
    if let hook = seam?.closeDescriptor {
        let res = hook(fd)
        return res.rc == 0 ? nil : max(1, res.errno)
    }
    #if canImport(Darwin)
    let rc = Darwin.close(fd)
    #else
    let rc = Glibc.close(fd)
    #endif
    return rc == 0 ? nil : max(1, currentPOSIXErrno())
}

@inline(__always)
private func posixSetNonBlocking(_ fd: Int32, enabled: Bool, seam: JPIPSocketSyscallSeam? = nil) -> Int32? {
    let flags: Int32
    if let getHook = seam?.getFlags {
        let res = getHook(fd)
        guard res.rc >= 0 else { return max(1, res.errno) }
        flags = res.rc
    } else {
        let rc = fcntl(fd, F_GETFL, 0)
        guard rc >= 0 else { return max(1, currentPOSIXErrno()) }
        flags = rc
    }
    let updatedFlags = enabled ? (flags | O_NONBLOCK) : (flags & ~O_NONBLOCK)
    if let setHook = seam?.setFlags {
        let res = setHook(fd, updatedFlags)
        guard res.rc == 0 else { return max(1, res.errno) }
    } else {
        let rc = fcntl(fd, F_SETFL, updatedFlags)
        guard rc == 0 else { return max(1, currentPOSIXErrno()) }
    }
    return nil
}

/// Reference-counted descriptor ownership state machine shared by ``JPIPTCPListener``
/// and ``JPIPTCPConnection``.
///
/// Concurrency proof (`@unchecked Sendable`):
/// `lock` is a pure leaf lock protecting `fd`, `admissionOpen`, `activeBorrows`,
/// `controlShutdownClaimed`, `physicalCloseClaimed`, `terminalResult`, and `waiters`.
/// No syscall, callback, or continuation resumption ever executes while `lock` is held.
package final class JPIPSocketDescriptor: @unchecked Sendable {
    package enum Kind: Sendable, Equatable {
        case listener
        case connection
    }

    package final class Borrow: @unchecked Sendable {
        private let releaseLock = NSLock()
        private var isReleased = false
        package let descriptor: JPIPSocketDescriptor
        package let fd: Int32

        fileprivate init(descriptor: JPIPSocketDescriptor, fd: Int32) {
            self.descriptor = descriptor
            self.fd = fd
        }

        package var isRetired: Bool {
            !descriptor.isOpen
        }

        package func release() {
            releaseLock.lock()
            if isReleased {
                releaseLock.unlock()
                return
            }
            isReleased = true
            releaseLock.unlock()
            descriptor.releaseBorrow()
        }

        deinit {
            release()
        }
    }

    private let lock = NSLock()
    package let kind: Kind
    private var fd: Int32
    private var admissionOpen: Bool = true
    private var activeBorrows: Int = 0
    private var controlShutdownClaimed: Bool = false
    private var physicalCloseClaimed: Bool = false
    private var terminalResult: Result<Void, J2KError>?
    private var recordedCloseErrno: Int32?
    private var physicalCloseCount: Int = 0
    private var shutdownCount: Int = 0
    private var waiters: [CheckedContinuation<Result<Void, J2KError>, Never>] = []
    package let syscallSeam: JPIPSocketSyscallSeam?
    private let observer: (@Sendable (JPIPSocketLifecycleEvent) -> Void)?
    private let operationLockCounter: (@Sendable () -> Int)?

    package init(
        kind: Kind,
        fd: Int32,
        syscallSeam: JPIPSocketSyscallSeam? = nil,
        observer: (@Sendable (JPIPSocketLifecycleEvent) -> Void)? = nil,
        operationLockCounter: (@Sendable () -> Int)? = nil
    ) {
        self.kind = kind
        self.fd = fd
        self.syscallSeam = syscallSeam
        self.observer = observer
        self.operationLockCounter = operationLockCounter
    }

    package var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return admissionOpen && fd >= 0
    }

    package var debugFD: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return fd
    }

    package var snapshot: (
        admissionOpen: Bool,
        activeBorrows: Int,
        physicalCloseClaimed: Bool,
        physicalCloseCompleted: Bool,
        physicalCloseCount: Int,
        shutdownCount: Int,
        closeErrno: Int32?
    ) {
        lock.lock()
        defer { lock.unlock() }
        return (
            admissionOpen,
            activeBorrows,
            physicalCloseClaimed,
            terminalResult != nil,
            physicalCloseCount,
            shutdownCount,
            recordedCloseErrno
        )
    }

    package func borrow(operation: JPIPSocketOperationKind) -> Borrow? {
        let borrowedFD: Int32
        let currentObserver: (@Sendable (JPIPSocketLifecycleEvent) -> Void)?
        lock.lock()
        guard admissionOpen, fd >= 0 else {
            lock.unlock()
            return nil
        }
        activeBorrows += 1
        borrowedFD = fd
        currentObserver = observer
        lock.unlock()

        if kind == .listener {
            currentObserver?(.afterListenerBorrowAcquired(fd: borrowedFD))
        } else {
            currentObserver?(.afterConnectionBorrowAcquired(op: operation, fd: borrowedFD))
        }
        return Borrow(descriptor: self, fd: borrowedFD)
    }

    package func borrowOrThrow(operation: JPIPSocketOperationKind) throws -> Borrow {
        guard let token = borrow(operation: operation) else {
            throw J2KError.networkError("TCP connection is closed.")
        }
        return token
    }

    package func acquireBorrow(operation: JPIPSocketOperationKind) throws -> Borrow {
        try borrowOrThrow(operation: operation)
    }

    /// Atomically checks whether listener admission remains open at the point
    /// an accepted connection is about to be published to the caller.
    package func admitAcceptedPublication() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return admissionOpen && fd >= 0
    }

    package func notify(_ event: JPIPSocketLifecycleEvent) {
        observer?(event)
    }

    /// Atomically retires listener admission on an unexpected `poll`/`accept`/setup
    /// error while an active borrower is held, so `isOpen` becomes `false` before
    /// `acceptConnection` throws and caller `while listener.isOpen` loops cannot spin.
    package func retireOnUnexpectedError() {
        initiateClose()
    }

    /// Handles `POLLNVAL` on an open listener as an invariant/descriptor error without
    /// issuing a physical `close` on an invalid descriptor.
    package func retireOnPollInvalidDescriptor() {
        let toResume: [CheckedContinuation<Result<Void, J2KError>, Never>]
        let outcome: Result<Void, J2KError> = .failure(
            J2KError.networkError("poll() reported POLLNVAL on listening socket (errno=\(EBADF))")
        )
        lock.lock()
        admissionOpen = false
        fd = -1
        physicalCloseClaimed = true
        if terminalResult == nil {
            recordedCloseErrno = EBADF
            terminalResult = outcome
        }
        let finalOutcome = terminalResult ?? outcome
        toResume = waiters
        waiters.removeAll()
        lock.unlock()

        if !toResume.isEmpty {
            let heldLocks = operationLockCounter?() ?? 0
            observer?(.beforeWaiterResume(heldOperationLocks: heldLocks))
        }
        for waiter in toResume {
            waiter.resume(returning: finalOutcome)
        }
    }

    package func initiateClose() {
        switch kind {
        case .listener:
            var fdToClose: Int32 = -1
            var currentSeam: JPIPSocketSyscallSeam?
            var currentObserver: (@Sendable (JPIPSocketLifecycleEvent) -> Void)?
            lock.lock()
            admissionOpen = false
            if activeBorrows == 0 && !physicalCloseClaimed && fd >= 0 {
                physicalCloseClaimed = true
                fdToClose = fd
                fd = -1
                currentSeam = syscallSeam
                currentObserver = observer
            }
            lock.unlock()

            if fdToClose >= 0 {
                performPhysicalCloseAndPublish(
                    fdToClose: fdToClose,
                    seam: currentSeam,
                    observer: currentObserver,
                    opLocksAtClaim: 0
                )
            }

        case .connection:
            var controlFD: Int32 = -1
            var claimPhysicalDirectly = false
            var directFD: Int32 = -1
            var currentSeam: JPIPSocketSyscallSeam?
            var currentObserver: (@Sendable (JPIPSocketLifecycleEvent) -> Void)?
            lock.lock()
            admissionOpen = false
            if !controlShutdownClaimed && fd >= 0 {
                controlShutdownClaimed = true
                activeBorrows += 1
                shutdownCount += 1
                controlFD = fd
                currentSeam = syscallSeam
                currentObserver = observer
            } else if activeBorrows == 0 && !physicalCloseClaimed && fd >= 0 {
                physicalCloseClaimed = true
                claimPhysicalDirectly = true
                directFD = fd
                fd = -1
                currentSeam = syscallSeam
                currentObserver = observer
            }
            lock.unlock()

            if controlFD >= 0 {
                currentObserver?(.beforeControlShutdown(fd: controlFD))
                _ = posixShutdownSocket(controlFD, seam: currentSeam)
                currentObserver?(.afterControlShutdown(fd: controlFD))
                releaseBorrow()
            } else if claimPhysicalDirectly && directFD >= 0 {
                let opLocks = operationLockCounter?() ?? 0
                performPhysicalCloseAndPublish(
                    fdToClose: directFD,
                    seam: currentSeam,
                    observer: currentObserver,
                    opLocksAtClaim: opLocks
                )
            }
        }
    }

    fileprivate func releaseBorrow() {
        var fdToClose: Int32 = -1
        var currentSeam: JPIPSocketSyscallSeam?
        var currentObserver: (@Sendable (JPIPSocketLifecycleEvent) -> Void)?
        var opLocks = 0
        lock.lock()
        precondition(activeBorrows > 0, "JPIPSocketDescriptor borrow count underflow")
        activeBorrows -= 1
        if !admissionOpen && activeBorrows == 0 && !physicalCloseClaimed && fd >= 0 {
            physicalCloseClaimed = true
            fdToClose = fd
            fd = -1
            currentSeam = syscallSeam
            currentObserver = observer
            opLocks = operationLockCounter?() ?? 0
        }
        lock.unlock()

        if fdToClose >= 0 {
            performPhysicalCloseAndPublish(
                fdToClose: fdToClose,
                seam: currentSeam,
                observer: currentObserver,
                opLocksAtClaim: opLocks
            )
        }
    }

    private func performPhysicalCloseAndPublish(
        fdToClose: Int32,
        seam: JPIPSocketSyscallSeam?,
        observer: (@Sendable (JPIPSocketLifecycleEvent) -> Void)?,
        opLocksAtClaim: Int
    ) {
        let preLocks = max(opLocksAtClaim, operationLockCounter?() ?? 0)
        observer?(.beforePhysicalClose(fd: fdToClose, heldOperationLocks: preLocks))
        let closeErr = posixCloseDescriptorOnly(fdToClose, seam: seam)
        let postLocks = max(preLocks, operationLockCounter?() ?? 0)
        observer?(.afterPhysicalClose(fd: fdToClose, errno: closeErr, heldOperationLocks: postLocks))

        let outcome: Result<Void, J2KError>
        if let closeErr {
            outcome = .failure(J2KError.networkError("Socket physical close failed (errno=\(closeErr))"))
        } else {
            outcome = .success(())
        }

        lock.lock()
        physicalCloseCount += 1
        recordedCloseErrno = closeErr
        terminalResult = outcome
        let toResume = waiters
        waiters.removeAll()
        lock.unlock()

        if !toResume.isEmpty {
            let resumeLocks = operationLockCounter?() ?? 0
            observer?(.beforeWaiterResume(heldOperationLocks: resumeLocks))
        }
        for waiter in toResume {
            waiter.resume(returning: outcome)
        }
    }

    package func waitForCloseCompletion() async throws {
        initiateClose()
        let outcome: Result<Void, J2KError> = await withCheckedContinuation { continuation in
            lock.lock()
            if let existing = terminalResult {
                lock.unlock()
                continuation.resume(returning: existing)
                return
            }
            waiters.append(continuation)
            lock.unlock()
        }
        try outcome.get()
    }
}

// MARK: - JPIPTCPListener

/// Thread-safe POSIX IPv4 TCP listening socket with scoped descriptor ownership
/// and nonblocking finite readiness polling.
///
/// Concurrency proof (`@unchecked Sendable`):
/// `descriptor` (`JPIPSocketDescriptor`) synchronizes admission retirement, active
/// borrowers, single physical `close(fd)`, and completion waiters under its leaf lock.
/// `boundHost` and `boundPort` are immutable after initialization.
package final class JPIPTCPListener: @unchecked Sendable {
    package static let pollQuantumMilliseconds: Int32 = 50
    package let descriptor: JPIPSocketDescriptor
    package let boundHost: String
    package let boundPort: Int

    package convenience init(host: String = "127.0.0.1", port: Int) throws {
        try self.init(host: host, port: port, syscallSeam: nil, observer: nil)
    }

    package init(
        host: String = "127.0.0.1",
        port: Int,
        syscallSeam: JPIPSocketSyscallSeam? = nil,
        observer: (@Sendable (JPIPSocketLifecycleEvent) -> Void)? = nil
    ) throws {
        guard port >= 0 && port <= 65535 else {
            throw J2KError.invalidParameter("Invalid TCP listening port: \(port)")
        }

        let sock = socket(AF_INET, posixSocketStreamType, 0)
        guard sock >= 0 else {
            throw J2KError.networkError("Failed to create TCP listening socket (errno=\(currentPOSIXErrno()))")
        }

        var reuse: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        _ = setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian

        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedHost.isEmpty || normalizedHost == "localhost" || normalizedHost == "127.0.0.1" {
            addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        } else if normalizedHost == "0.0.0.0" || normalizedHost == "*" {
            addr.sin_addr = in_addr(s_addr: 0)
        } else {
            let parsed = normalizedHost.withCString { cstr in
                inet_pton(AF_INET, cstr, &addr.sin_addr)
            }
            if parsed != 1 {
                _ = posixCloseDescriptorOnly(sock, seam: syscallSeam)
                throw J2KError.invalidParameter("Invalid IPv4 bind address: \(host)")
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(sock, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = currentPOSIXErrno()
            _ = posixCloseDescriptorOnly(sock, seam: syscallSeam)
            throw J2KError.networkError("Failed to bind \(host):\(port) (errno=\(err))")
        }

        guard listen(sock, 128) == 0 else {
            let err = currentPOSIXErrno()
            _ = posixCloseDescriptorOnly(sock, seam: syscallSeam)
            throw J2KError.networkError("Failed to listen on \(host):\(port) (errno=\(err))")
        }

        var actualAddr = sockaddr_in()
        var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &actualAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(sock, sa, &actualLen)
            }
        }
        guard nameResult == 0 else {
            let err = currentPOSIXErrno()
            _ = posixCloseDescriptorOnly(sock, seam: syscallSeam)
            throw J2KError.networkError("getsockname failed (errno=\(err))")
        }

        if let flagErr = posixSetNonBlocking(sock, enabled: true, seam: syscallSeam) {
            _ = posixCloseDescriptorOnly(sock, seam: syscallSeam)
            throw J2KError.networkError("Failed to set O_NONBLOCK on listening socket (errno=\(flagErr))")
        }

        self.descriptor = JPIPSocketDescriptor(
            kind: .listener,
            fd: sock,
            syscallSeam: syscallSeam,
            observer: observer
        )
        self.boundHost = normalizedHost.isEmpty ? "127.0.0.1" : normalizedHost
        self.boundPort = Int(UInt16(bigEndian: actualAddr.sin_port))
    }

    /// Package-only initializer for deterministic descriptor-number reuse model tests (`T5`).
    package init(
        syntheticFD: Int32,
        boundHost: String = "127.0.0.1",
        boundPort: Int = 0,
        syscallSeam: JPIPSocketSyscallSeam,
        observer: (@Sendable (JPIPSocketLifecycleEvent) -> Void)? = nil
    ) throws {
        if let flagErr = posixSetNonBlocking(syntheticFD, enabled: true, seam: syscallSeam) {
            _ = posixCloseDescriptorOnly(syntheticFD, seam: syscallSeam)
            throw J2KError.networkError("Failed to set O_NONBLOCK on synthetic listening socket (errno=\(flagErr))")
        }
        self.descriptor = JPIPSocketDescriptor(
            kind: .listener,
            fd: syntheticFD,
            syscallSeam: syscallSeam,
            observer: observer
        )
        self.boundHost = boundHost
        self.boundPort = boundPort
    }

    deinit {
        close()
    }

    package var isOpen: Bool {
        descriptor.isOpen
    }

    /// Blocks the calling dedicated OS thread/DispatchQueue (using finite 50ms `poll`
    /// readiness quanta on the nonblocking listener) until a client connects or the
    /// listener retires. `timeoutSeconds` configures the accepted socket only.
    package func acceptConnection(timeoutSeconds: Int = 30) throws -> JPIPTCPConnection? {
        guard let borrow = descriptor.borrow(operation: .listenerAccept) else {
            return nil
        }
        defer { borrow.release() }

        let seam = descriptor.syscallSeam
        while true {
            guard !borrow.isRetired else { return nil }
            descriptor.notify(.beforeListenerPoll(fd: borrow.fd))
            guard !borrow.isRetired else { return nil }

            let pollRC: Int32
            let revents: Int16
            let pollErr: Int32
            if let pollHook = seam?.pollListen {
                let res = pollHook(borrow.fd, Self.pollQuantumMilliseconds)
                pollRC = res.rc
                revents = res.revents
                pollErr = res.errno
            } else {
                var pfd = pollfd(fd: borrow.fd, events: Int16(POLLIN), revents: 0)
                pollRC = poll(&pfd, nfds_t(1), Self.pollQuantumMilliseconds)
                revents = pfd.revents
                pollErr = pollRC < 0 ? currentPOSIXErrno() : 0
            }

            if pollRC == 0 {
                continue
            }
            if pollRC < 0 {
                if pollErr == EINTR {
                    guard !borrow.isRetired else { return nil }
                    continue
                }
                if borrow.isRetired {
                    return nil
                }
                descriptor.retireOnUnexpectedError()
                throw J2KError.networkError("poll() failed on listening socket (errno=\(pollErr))")
            }

            guard !borrow.isRetired else { return nil }

            if (revents & Int16(POLLNVAL)) != 0 {
                descriptor.retireOnPollInvalidDescriptor()
                throw J2KError.networkError("poll() reported POLLNVAL on open listening socket.")
            }
            if (revents & Int16(POLLERR | POLLHUP)) != 0 && (revents & Int16(POLLIN)) == 0 {
                if borrow.isRetired { return nil }
                descriptor.retireOnUnexpectedError()
                throw J2KError.networkError("poll() reported error/hangup (revents=\(revents)) on listening socket.")
            }
            if (revents & Int16(POLLIN)) == 0 {
                continue
            }

            guard !borrow.isRetired else { return nil }
            descriptor.notify(.beforeListenerAccept(fd: borrow.fd))
            guard !borrow.isRetired else { return nil }

            let clientFD: Int32
            let acceptErr: Int32
            if let acceptHook = seam?.acceptClient {
                let res = acceptHook(borrow.fd)
                clientFD = res.clientFD
                acceptErr = res.errno
            } else {
                var clientAddr = sockaddr_storage()
                var clientLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        accept(borrow.fd, sa, &clientLen)
                    }
                }
                acceptErr = clientFD < 0 ? currentPOSIXErrno() : 0
            }

            if clientFD >= 0 {
                let timeoutInterval = TimeInterval(timeoutSeconds)
                if let flagErr = posixSetNonBlocking(clientFD, enabled: false, seam: seam) {
                    _ = posixCloseDescriptorOnly(clientFD, seam: seam)
                    if borrow.isRetired { return nil }
                    descriptor.retireOnUnexpectedError()
                    throw J2KError.networkError("Failed to clear O_NONBLOCK on accepted socket (errno=\(flagErr))")
                }
                if let configHook = seam?.configureAccepted {
                    configHook(clientFD, timeoutInterval)
                } else {
                    JPIPTCPConnection.configureExclusiveSocket(clientFD, timeoutInterval: timeoutInterval)
                }
                descriptor.notify(.beforeAcceptedPublication(listenFD: borrow.fd, clientFD: clientFD))
                guard descriptor.admitAcceptedPublication() else {
                    let closeErr = posixCloseDescriptorOnly(clientFD, seam: seam)
                    descriptor.notify(.abortedAcceptedClientClosed(clientFD: clientFD, closeErrno: closeErr))
                    return nil
                }
                return JPIPTCPConnection(
                    alreadyConfiguredFD: clientFD,
                    syscallSeam: seam,
                    observer: nil
                )
            }

            if borrow.isRetired {
                return nil
            }
            if acceptErr == EINTR || acceptErr == EAGAIN || acceptErr == EWOULDBLOCK || acceptErr == ECONNABORTED {
                continue
            }
            descriptor.retireOnUnexpectedError()
            throw J2KError.networkError("accept() failed (errno=\(acceptErr))")
        }
    }

    package func close() {
        descriptor.initiateClose()
    }

    package func waitForCloseCompletion() async throws {
        try await descriptor.waitForCloseCompletion()
    }
}

// MARK: - Socket Cancellation Token

/// Tracks active connection operation locks (`readLock`, `writeLock`, `wsReadLock`) so tests
/// and lifecycle observers can verify that no operation lock is ever held across physical
/// descriptor close or close-completion waiter resumption.
package final class JPIPOperationLockTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    package init() {}

    package func enter(_ opLock: NSLock) {
        lock.lock()
        count += 1
        lock.unlock()
        opLock.lock()
    }

    package func exit(_ opLock: NSLock) {
        opLock.unlock()
        lock.lock()
        count -= 1
        lock.unlock()
    }

    package var currentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Thread-safe cancellation token bridging structured Swift concurrency cancellation
/// (`withTaskCancellationHandler`) to blocking POSIX `connect` / `recv` / `send` operations.
///
/// Concurrency proof (`@unchecked Sendable`):
/// All mutable state (`isCancelled`, `connectingFD`, `activeConnection`) is guarded by `lock`.
/// `endFailedConnectAttempt()` clears `connectingFD` under `lock` *before* `posixCloseDescriptorOnly`
/// closes the exclusive pre-publication descriptor, and `cancel()` invokes non-blocking
/// `shutdown(fd, SHUT_RDWR)` while holding `lock`, guaranteeing `shutdown` can never target
/// a closed or recycled file descriptor.
package final class JPIPSocketCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var connectingFD: Int32 = -1
    private var activeConnection: JPIPTCPConnection?

    package init() {}

    package var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    package func beginConnect(fd: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled {
            return false
        }
        connectingFD = fd
        return true
    }

    package func endFailedConnectAttempt() {
        lock.lock()
        connectingFD = -1
        lock.unlock()
    }

    package func completeConnect(connection: JPIPTCPConnection) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        connectingFD = -1
        if isCancelled {
            return false
        }
        activeConnection = connection
        return true
    }

    package func bind(connection: JPIPTCPConnection?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled {
            return false
        }
        activeConnection = connection
        return true
    }

    package func cancel() {
        var connToClose: JPIPTCPConnection?
        lock.lock()
        isCancelled = true
        if connectingFD >= 0 {
            _ = posixShutdownSocket(connectingFD)
        }
        connToClose = activeConnection
        activeConnection = nil
        lock.unlock()
        connToClose?.close()
    }
}

// MARK: - JPIPTCPConnection

/// Thread-safe buffered binary TCP socket supporting HTTP/1.1 persistent framing
/// and RFC 6455 WebSocket binary/control frames.
///
/// Concurrency proof (`@unchecked Sendable`):
/// Socket descriptor lifecycle is managed by `descriptor` (`JPIPSocketDescriptor`), whose
/// leaf lock guards borrow counting, retirement, control-borrow `shutdown(SHUT_RDWR)`, and
/// single physical `close(fd)` after the last borrower releases. Every operation acquires
/// its `JPIPSocketDescriptor.Borrow` before acquiring `readLock`, `writeLock`, or `wsReadLock`,
/// and unlocks the operation lock before `borrow.release()`, guaranteeing that no operation
/// lock is ever held during physical close or waiter resumption.
package final class JPIPTCPConnection: @unchecked Sendable {
    package let descriptor: JPIPSocketDescriptor
    package let lockTracker: JPIPOperationLockTracker
    private let readLock = NSLock()
    private let wsReadLock = NSLock()
    private let writeLock = NSLock()
    private var readBuffer = [UInt8]()
    private var readOffset: Int = 0
    private var wsFragmentedOpcode: JPIPRFC6455Opcode?
    private var wsFragmentedPayload = Data()
    // Deterministic algorithm-work evidence, protected by readLock. Counters
    // saturate across arbitrarily many messages instead of overflowing.
    private var headerScanPositions = 0
    private var lineScanBytes = 0

    package var httpDelimiterScanWork: (headerPositions: Int, lineBytes: Int) {
        lockTracker.enter(readLock)
        defer { lockTracker.exit(readLock) }
        return (headerScanPositions, lineScanBytes)
    }

    package convenience init(connectedFD: Int32, timeoutSeconds: Int = 30) {
        self.init(connectedFD: connectedFD, timeoutInterval: TimeInterval(timeoutSeconds))
    }

    package convenience init(connectedFD: Int32, timeoutInterval: TimeInterval) {
        Self.configureExclusiveSocket(connectedFD, timeoutInterval: timeoutInterval)
        self.init(alreadyConfiguredFD: connectedFD)
    }

    package init(
        alreadyConfiguredFD: Int32,
        syscallSeam: JPIPSocketSyscallSeam? = nil,
        observer: (@Sendable (JPIPSocketLifecycleEvent) -> Void)? = nil
    ) {
        let tracker = JPIPOperationLockTracker()
        self.lockTracker = tracker
        self.descriptor = JPIPSocketDescriptor(
            kind: .connection,
            fd: alreadyConfiguredFD,
            syscallSeam: syscallSeam,
            observer: observer,
            operationLockCounter: { tracker.currentCount }
        )
    }

    package static func connect(host: String, port: Int, timeoutSeconds: Int = 30) throws -> JPIPTCPConnection {
        try connect(host: host, port: port, timeoutInterval: TimeInterval(timeoutSeconds))
    }

    package static func connect(
        host: String,
        port: Int,
        timeoutInterval: TimeInterval,
        cancellationToken: JPIPSocketCancellationToken? = nil,
        observer: (@Sendable (JPIPSocketLifecycleEvent) -> Void)? = nil
    ) throws -> JPIPTCPConnection {
        guard port > 0 && port <= 65535 else {
            throw J2KError.invalidParameter("Invalid remote TCP port: \(port)")
        }
        if cancellationToken?.cancelled == true {
            throw CancellationError()
        }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = posixSocketStreamType
        hints.ai_protocol = Int32(IPPROTO_TCP)

        var resPtr: UnsafeMutablePointer<addrinfo>?
        let portStr = String(port)
        let targetHost = (host == "localhost") ? "127.0.0.1" : host
        let gai = targetHost.withCString { hStr in
            portStr.withCString { pStr in
                getaddrinfo(hStr, pStr, &hints, &resPtr)
            }
        }
        guard gai == 0, let firstInfo = resPtr else {
            throw J2KError.networkError("DNS/address resolution failed for \(host):\(port) (gai=\(gai))")
        }
        defer { freeaddrinfo(firstInfo) }

        var lastErrno: Int32 = 0
        var infoPtr: UnsafeMutablePointer<addrinfo>? = firstInfo
        while let info = infoPtr {
            let sock = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            if sock >= 0 {
                if let cancellationToken, !cancellationToken.beginConnect(fd: sock) {
                    _ = posixCloseDescriptorOnly(sock)
                    throw CancellationError()
                }
                Self.configureExclusiveSocket(sock, timeoutInterval: timeoutInterval)
                let rc = DarwinOrGlibcConnect(sock, info.pointee.ai_addr, info.pointee.ai_addrlen)
                if rc == 0 {
                    let conn = JPIPTCPConnection(alreadyConfiguredFD: sock, observer: observer)
                    if let cancellationToken, !cancellationToken.completeConnect(connection: conn) {
                        conn.close()
                        throw CancellationError()
                    }
                    return conn
                }
                lastErrno = currentPOSIXErrno()
                cancellationToken?.endFailedConnectAttempt()
                _ = posixCloseDescriptorOnly(sock)
                if cancellationToken?.cancelled == true {
                    throw CancellationError()
                }
            } else {
                lastErrno = currentPOSIXErrno()
            }
            infoPtr = info.pointee.ai_next
        }
        if cancellationToken?.cancelled == true {
            throw CancellationError()
        }
        throw J2KError.networkError("TCP connect to \(host):\(port) failed (errno=\(lastErrno))")
    }

    private static func DarwinOrGlibcConnect(
        _ sock: Int32,
        _ addr: UnsafePointer<sockaddr>!,
        _ len: socklen_t
    ) -> Int32 {
        while true {
            #if canImport(Darwin)
            let rc = Darwin.connect(sock, addr, len)
            #else
            let rc = Glibc.connect(sock, addr, len)
            #endif
            if rc == 0 { return 0 }
            if currentPOSIXErrno() == EINTR { continue }
            return rc
        }
    }

    package static func makeTimeval(_ interval: TimeInterval) -> timeval {
        guard interval > 0, interval.isFinite else {
            return timeval(tv_sec: 0, tv_usec: 0)
        }
        let wholeSec = Int(floor(interval))
        let fracMicros = max(wholeSec == 0 ? 1 : 0, min(999_999, Int(((interval - Double(wholeSec)) * 1_000_000.0).rounded())))
        #if canImport(Darwin)
        return timeval(tv_sec: wholeSec, tv_usec: Int32(fracMicros))
        #else
        return timeval(tv_sec: wholeSec, tv_usec: Int(fracMicros))
        #endif
    }

    package static func configureExclusiveSocket(_ sock: Int32, timeoutInterval: TimeInterval) {
        var one: Int32 = 1
        _ = setsockopt(sock, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        _ = setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        if timeoutInterval > 0 {
            var tv = makeTimeval(timeoutInterval)
            _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    package func setReceiveTimeout(seconds: Int) {
        setReceiveTimeout(interval: TimeInterval(max(0, seconds)))
    }

    package func setReceiveTimeout(interval: TimeInterval) {
        guard let borrow = try? descriptor.acquireBorrow(operation: .setReceiveTimeout) else { return }
        defer { borrow.release() }
        guard !borrow.isRetired else { return }
        if let hook = descriptor.syscallSeam?.setSockOpt {
            _ = hook(borrow.fd, SOL_SOCKET, SO_RCVTIMEO, interval)
        } else {
            var tv = Self.makeTimeval(interval)
            let optLen = socklen_t(MemoryLayout<timeval>.size)
            _ = setsockopt(borrow.fd, SOL_SOCKET, SO_RCVTIMEO, &tv, optLen)
        }
    }

    package func setSendTimeout(interval: TimeInterval) {
        guard let borrow = try? descriptor.acquireBorrow(operation: .setSendTimeout) else { return }
        defer { borrow.release() }
        guard !borrow.isRetired else { return }
        if let hook = descriptor.syscallSeam?.setSockOpt {
            _ = hook(borrow.fd, SOL_SOCKET, SO_SNDTIMEO, interval)
        } else {
            var tv = Self.makeTimeval(interval)
            let optLen = socklen_t(MemoryLayout<timeval>.size)
            _ = setsockopt(borrow.fd, SOL_SOCKET, SO_SNDTIMEO, &tv, optLen)
        }
    }

    deinit {
        close()
    }

    package var isOpen: Bool {
        descriptor.isOpen
    }

    package func close() {
        descriptor.initiateClose()
    }

    package func waitForCloseCompletion() async throws {
        try await descriptor.waitForCloseCompletion()
    }

    // MARK: - Raw Binary Write & Buffered Read

    package func writeAll(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let borrow = try descriptor.acquireBorrow(operation: .writeAll)
        defer { borrow.release() }
        lockTracker.enter(writeLock)
        defer { lockTracker.exit(writeLock) }

        try data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var sent = 0
            while sent < rawBuf.count {
                guard !borrow.isRetired else {
                    throw J2KError.networkError("TCP send aborted because connection closed after \(sent)/\(rawBuf.count) bytes.")
                }
                let n: Int
                let err: Int32
                if let sendHook = descriptor.syscallSeam?.sendBytes {
                    let res = sendHook(borrow.fd, base.advanced(by: sent), rawBuf.count - sent)
                    n = res.rc
                    err = res.errno
                } else {
                    n = send(borrow.fd, base.advanced(by: sent), rawBuf.count - sent, posixSendFlags)
                    err = n < 0 ? currentPOSIXErrno() : 0
                }
                if n > 0 {
                    sent += n
                } else if n < 0 && err == EINTR {
                    guard !borrow.isRetired else {
                        throw J2KError.networkError("TCP send interrupted by connection close after \(sent)/\(rawBuf.count) bytes.")
                    }
                    continue
                } else {
                    throw J2KError.networkError("TCP send failed after \(sent)/\(rawBuf.count) bytes (errno=\(err))")
                }
            }
        }
    }

    private func compactReadBufferLocked() {
        if readOffset > 0 {
            if readOffset >= readBuffer.count {
                readBuffer.removeAll(keepingCapacity: false)
                readOffset = 0
            } else if readOffset >= 16384 {
                readBuffer.removeFirst(readOffset)
                readOffset = 0
            }
        }
    }

    private func performRecv(
        borrow: JPIPSocketDescriptor.Borrow,
        buffer: UnsafeMutableRawPointer,
        count: Int
    ) -> (result: Int, errno: Int32) {
        if let recvHook = descriptor.syscallSeam?.recvBytes {
            let res = recvHook(borrow.fd, buffer, count)
            return (res.rc, res.errno)
        }
        let n = recv(borrow.fd, buffer, count, 0)
        return (n, n < 0 ? currentPOSIXErrno() : 0)
    }

    private func fillOnceLocked(
        maxReadBytes: Int = 16384,
        borrow: JPIPSocketDescriptor.Borrow
    ) throws -> Int {
        guard maxReadBytes > 0 else {
            throw CodecError(.resourceLimitExceeded, "TCP read allowance exhausted before allocation.")
        }
        var scratch = [UInt8](repeating: 0, count: min(16384, maxReadBytes))
        while true {
            guard !borrow.isRetired else {
                throw J2KError.networkError("TCP connection is closed.")
            }
            let (n, err) = scratch.withUnsafeMutableBytes { buf in
                performRecv(borrow: borrow, buffer: buf.baseAddress!, count: buf.count)
            }
            if n > 0 {
                readBuffer.append(contentsOf: scratch[0..<n])
                return n
            } else if n == 0 {
                return 0
            } else {
                if err == EINTR {
                    guard !borrow.isRetired else {
                        throw J2KError.networkError("TCP connection is closed.")
                    }
                    continue
                }
                if err == EAGAIN || err == EWOULDBLOCK {
                    throw J2KError.networkError("TCP receive timed out.")
                }
                throw J2KError.networkError("TCP recv failed (errno=\(err))")
            }
        }
    }

    package func readExact(count: Int, maxAllowedBytes: Int = Int.max) throws -> Data {
        guard count >= 0 else {
            throw J2KError.invalidData("Negative byte count requested (\(count)).")
        }
        guard count <= maxAllowedBytes else {
            throw CodecError(.resourceLimitExceeded, "Requested TCP payload (\(count) bytes) exceeds limit (\(maxAllowedBytes) bytes).")
        }
        if count == 0 { return Data() }

        let borrow = try descriptor.acquireBorrow(operation: .readExact)
        defer { borrow.release() }
        lockTracker.enter(readLock)
        defer { lockTracker.exit(readLock) }

        return try readExactLocked(count: count, borrow: borrow)
    }

    /// The announced length is admitted by the caller before this one allocation.
    private func readExactLocked(
        count: Int,
        borrow: JPIPSocketDescriptor.Borrow
    ) throws -> Data {
        if count == 0 { return Data() }
        var output = Data(count: count)
        let buffered = min(count, readBuffer.count - readOffset)
        if buffered > 0 {
            output.replaceSubrange(0..<buffered, with: readBuffer[readOffset..<(readOffset + buffered)])
            readOffset += buffered
            compactReadBufferLocked()
        }
        try output.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var offset = buffered
            while offset < count {
                guard !borrow.isRetired else {
                    throw J2KError.networkError("TCP read failed before the complete admitted payload arrived.")
                }
                let (received, err) = performRecv(
                    borrow: borrow,
                    buffer: base.advanced(by: offset),
                    count: count - offset
                )
                if received > 0 {
                    offset += received
                } else if received < 0 && err == EINTR {
                    guard !borrow.isRetired else {
                        throw J2KError.networkError("TCP read failed before the complete admitted payload arrived.")
                    }
                    continue
                } else {
                    throw J2KError.networkError("TCP read failed before the complete admitted payload arrived.")
                }
            }
        }
        return output
    }

    package func readToEOFForTesting(maxAllowedBytes: Int) throws -> Data {
        let borrow = try descriptor.acquireBorrow(operation: .readToEOF)
        defer { borrow.release() }
        lockTracker.enter(readLock)
        defer { lockTracker.exit(readLock) }
        return try readToEOFLocked(maxAllowedBytes: maxAllowedBytes, borrow: borrow)
    }

    private func readToEOFLocked(
        maxAllowedBytes: Int,
        borrow: JPIPSocketDescriptor.Borrow
    ) throws -> Data {
        let buffered = readBuffer.count - readOffset
        guard buffered <= maxAllowedBytes else {
            throw CodecError(.resourceLimitExceeded, "EOF-delimited HTTP body exceeds limit before allocation.")
        }
        var output = Data(readBuffer[readOffset..<readBuffer.count])
        readOffset = readBuffer.count
        compactReadBufferLocked()
        while true {
            guard !borrow.isRetired else {
                throw J2KError.networkError("TCP read failed inside an EOF-delimited body.")
            }
            let remaining = maxAllowedBytes - output.count
            if remaining == 0 {
                var extra: UInt8 = 0
                let (count, err) = withUnsafeMutablePointer(to: &extra) { ptr in
                    performRecv(borrow: borrow, buffer: UnsafeMutableRawPointer(ptr), count: 1)
                }
                if count == 0 { return output }
                if count < 0 && err == EINTR {
                    guard !borrow.isRetired else {
                        throw J2KError.networkError("TCP read failed at the EOF-delimited body limit.")
                    }
                    continue
                }
                if count > 0 { throw CodecError(.resourceLimitExceeded, "EOF-delimited HTTP body exceeds limit before allocation.") }
                throw J2KError.networkError("TCP read failed at the EOF-delimited body limit.")
            }
            // Grow the read window with observed data, so a short response never
            // allocates a large speculative scratch buffer.
            var scratch = [UInt8](repeating: 0, count: min(16384, min(remaining, max(1, output.count))))
            let (count, err) = scratch.withUnsafeMutableBytes { buf in
                performRecv(borrow: borrow, buffer: buf.baseAddress!, count: buf.count)
            }
            if count == 0 { return output }
            if count < 0 {
                if err == EINTR {
                    guard !borrow.isRetired else {
                        throw J2KError.networkError("TCP read failed inside an EOF-delimited body.")
                    }
                    continue
                }
                throw J2KError.networkError("TCP read failed inside an EOF-delimited body.")
            }
            let nextCount = output.count + count // count is bounded by remaining.
            var replacement = Data(count: nextCount)
            replacement.replaceSubrange(0..<output.count, with: output)
            replacement.replaceSubrange(output.count..<nextCount, with: scratch.prefix(count))
            output = replacement
        }
    }

    private func readLineCRLFLocked(
        maxLineBytes: Int,
        borrow: JPIPSocketDescriptor.Borrow
    ) throws -> String {
        // readOffset and buffer indices stay fixed until a complete line returns.
        // A new fill therefore only requires examining newly appended bytes.
        var scanIndex = readOffset
        while true {
            let available = readBuffer.count - readOffset
            if available > 0 {
                while scanIndex < readBuffer.count {
                    let idx = scanIndex
                    scanIndex += 1
                    if lineScanBytes < Int.max { lineScanBytes += 1 }
                    guard readBuffer[idx] == 0x0A else { continue }
                    let lineLen = idx - readOffset
                    guard lineLen <= maxLineBytes else {
                        throw CodecError(.resourceLimitExceeded, "HTTP chunk line exceeds maximum length.")
                    }
                    var endIdx = idx
                    if endIdx > readOffset && readBuffer[endIdx - 1] == 0x0D {
                        endIdx -= 1
                    }
                    let lineBytes = readBuffer[readOffset..<endIdx]
                    readOffset = idx + 1
                    compactReadBufferLocked()
                    guard let str = String(bytes: lineBytes, encoding: .utf8) ?? String(bytes: lineBytes, encoding: .isoLatin1) else {
                        throw J2KError.invalidData("Malformed HTTP header/chunk line.")
                    }
                    return str
                }
                if available > maxLineBytes {
                    throw CodecError(.resourceLimitExceeded, "HTTP line exceeds \(maxLineBytes) bytes without CRLF.")
                }
            }
            let got = try fillOnceLocked(maxReadBytes: 1, borrow: borrow)
            if got == 0 {
                throw J2KError.networkError("Unexpected EOF while reading HTTP line.")
            }
        }
    }

    /// Reads until `\r\n\r\n` (or `\n\n`). Returns `nil` cleanly on immediate EOF before any byte.
    private func readHeaderBlockLocked(
        maxHeaderBytes: Int,
        borrow: JPIPSocketDescriptor.Borrow
    ) throws -> [UInt8]? {
        var scanIndex = readOffset
        while true {
            let available = readBuffer.count - readOffset
            if available >= 2 {
                var i = scanIndex
                while i < readBuffer.count {
                    if headerScanPositions < Int.max { headerScanPositions += 1 }
                    if i + 3 < readBuffer.count,
                       readBuffer[i] == 0x0D, readBuffer[i + 1] == 0x0A,
                       readBuffer[i + 2] == 0x0D, readBuffer[i + 3] == 0x0A {
                        let block = Array(readBuffer[readOffset..<i])
                        readOffset = i + 4
                        compactReadBufferLocked()
                        return block
                    }
                    if i + 1 < readBuffer.count,
                       readBuffer[i] == 0x0A, readBuffer[i + 1] == 0x0A {
                        let block = Array(readBuffer[readOffset..<i])
                        readOffset = i + 2
                        compactReadBufferLocked()
                        return block
                    }
                    i += 1
                }
                // Only a delimiter beginning in the final three bytes could
                // become complete after the next fill. Preserve that overlap
                // for CRLFCRLF (and LF-LF), without revisiting the entire prefix.
                // No compaction occurs until this method returns.
                scanIndex = max(readOffset, readBuffer.count - 3)
            }
            if available > maxHeaderBytes {
                throw CodecError(.resourceLimitExceeded, "HTTP header block exceeds \(maxHeaderBytes) bytes.")
            }
            let got = try fillOnceLocked(maxReadBytes: 1, borrow: borrow)
            if got == 0 {
                if (readBuffer.count - readOffset) == 0 {
                    return nil
                }
                throw J2KError.networkError("Unexpected EOF inside HTTP header block.")
            }
        }
    }

    private func readChunkedBodyLocked(
        maxBodyBytes: Int,
        borrow: JPIPSocketDescriptor.Borrow
    ) throws -> Data {
        var out = Data()
        while true {
            let sizeLine = try readLineCRLFLocked(maxLineBytes: 4096, borrow: borrow)
            let hexPart = sizeLine.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let trimmedHex = hexPart.trimmingCharacters(in: .whitespaces)
            guard let chunkSize = Int(trimmedHex, radix: 16), chunkSize >= 0 else {
                throw J2KError.invalidData("Malformed HTTP chunk size '\(trimmedHex)'.")
            }
            if chunkSize == 0 {
                // Consume trailing headers until empty line
                while true {
                    let trailer = try readLineCRLFLocked(maxLineBytes: 8192, borrow: borrow)
                    if trailer.isEmpty { break }
                }
                return out
            }
            let (nextTotal, ov) = out.count.addingReportingOverflow(chunkSize)
            guard !ov, nextTotal <= maxBodyBytes else {
                throw CodecError(.resourceLimitExceeded, "Chunked HTTP body exceeds limit (\(maxBodyBytes) bytes).")
            }
            let chunk = try readExactLocked(count: chunkSize, borrow: borrow)
            // Old output + chunk + replacement equal twice nextTotal, rather
            // than relying on an untracked Array/Data growth capacity.
            var replacement = Data(count: nextTotal)
            replacement.replaceSubrange(0..<out.count, with: out)
            replacement.replaceSubrange(out.count..<nextTotal, with: chunk)
            out = replacement
            // Consume trailing CRLF after chunk payload
            _ = try readLineCRLFLocked(maxLineBytes: 16, borrow: borrow)
        }
    }

    // MARK: - HTTP/1.1 Framing

    package func readHTTPRequest(
        maxHeaderBytes: Int = 65536,
        maxBodyBytes: Int = 64 * 1024 * 1024
    ) throws -> JPIPHTTPWireRequest? {
        let borrow = try descriptor.acquireBorrow(operation: .readHTTPRequest)
        defer { borrow.release() }
        lockTracker.enter(readLock)
        defer { lockTracker.exit(readLock) }

        guard let headerBytes = try readHeaderBlockLocked(maxHeaderBytes: maxHeaderBytes, borrow: borrow) else {
            return nil
        }
        guard let headerText = String(bytes: headerBytes, encoding: .utf8) ?? String(bytes: headerBytes, encoding: .isoLatin1) else {
            throw J2KError.invalidData("Malformed HTTP request header encoding.")
        }
        let rawLines = headerText.components(separatedBy: "\n").map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : $0
        }
        guard let requestLine = rawLines.first, !requestLine.isEmpty else {
            throw J2KError.invalidData("Empty HTTP request line.")
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            throw J2KError.invalidData("Malformed HTTP request line '\(requestLine)'.")
        }
        let method = String(parts[0])
        let target = String(parts[1])
        let version = parts.count >= 3 ? String(parts[2]) : "HTTP/1.1"

        var headers: [String: String] = [:]
        for line in rawLines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }

        let te = headers.first { $0.key.lowercased() == "transfer-encoding" }?.value.lowercased() ?? ""
        if te.contains("chunked") {
            let body = try readChunkedBodyLocked(maxBodyBytes: maxBodyBytes, borrow: borrow)
            return JPIPHTTPWireRequest(method: method, target: target, version: version, headers: headers, body: body)
        }

        var contentLen = 0
        if let clStr = headers.first(where: { $0.key.lowercased() == "content-length" })?.value {
            guard let parsed = Int(clStr.trimmingCharacters(in: .whitespaces)), parsed >= 0 else {
                throw J2KError.invalidData("Invalid Content-Length '\(clStr)'.")
            }
            contentLen = parsed
        }
        guard contentLen <= maxBodyBytes else {
            throw CodecError(.resourceLimitExceeded, "Requested TCP payload (\(contentLen) bytes) exceeds limit (\(maxBodyBytes) bytes).")
        }
        let body = contentLen > 0 ? try readExactLocked(count: contentLen, borrow: borrow) : Data()
        return JPIPHTTPWireRequest(method: method, target: target, version: version, headers: headers, body: body)
    }

    package func writeHTTPResponse(
        statusCode: Int,
        reasonPhrase: String,
        headers: [String: String],
        body: Data
    ) throws {
        var headerStr = "HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n"
        var hasContentLength = false
        for (k, v) in headers {
            if k.lowercased() == "content-length" { hasContentLength = true }
            headerStr += "\(k): \(v)\r\n"
        }
        if !hasContentLength && statusCode != 101 && statusCode != 204 {
            headerStr += "Content-Length: \(body.count)\r\n"
        }
        headerStr += "\r\n"

        var wire = Data(headerStr.utf8)
        wire.append(body)
        try writeAll(wire)
    }

    package func writeHTTPRequest(
        method: String = "GET",
        pathAndQuery: String,
        hostHeader: String,
        headers: [String: String] = [:],
        body: Data = Data()
    ) throws {
        var req = "\(method) \(pathAndQuery) HTTP/1.1\r\n"
        req += "Host: \(hostHeader)\r\n"
        var hasConnection = false
        var hasContentLength = false
        for (k, v) in headers {
            let lk = k.lowercased()
            if lk == "host" { continue }
            if lk == "connection" { hasConnection = true }
            if lk == "content-length" { hasContentLength = true }
            req += "\(k): \(v)\r\n"
        }
        if !hasConnection {
            req += "Connection: keep-alive\r\n"
        }
        if !body.isEmpty && !hasContentLength {
            req += "Content-Length: \(body.count)\r\n"
        }
        req += "\r\n"

        var wire = Data(req.utf8)
        wire.append(body)
        try writeAll(wire)
    }

    package func readHTTPResponse(
        maxHeaderBytes: Int = 65536,
        maxBodyBytes: Int = 128 * 1024 * 1024,
        maximumStorageBytes: Int = Int.max
    ) throws -> JPIPHTTPWireResponse {
        guard maxHeaderBytes >= 0, maxBodyBytes >= 0, maximumStorageBytes > 0 else {
            throw CodecError(.invalidArgument, "Invalid HTTP response admission limits.")
        }
        let borrow = try descriptor.acquireBorrow(operation: .readHTTPResponse)
        defer { borrow.release() }
        lockTracker.enter(readLock)
        defer { lockTracker.exit(readLock) }

        func add(_ a: Int, _ b: Int) throws -> Int {
            let (value, overflow) = a.addingReportingOverflow(b)
            guard a >= 0, b >= 0, !overflow else { throw CodecError(.resourceLimitExceeded, "HTTP response storage overflow.") }
            return value
        }
        func multiply(_ a: Int, _ b: Int) throws -> Int {
            let (value, overflow) = a.multipliedReportingOverflow(by: b)
            guard a >= 0, b >= 0, !overflow else { throw CodecError(.resourceLimitExceeded, "HTTP response storage overflow.") }
            return value
        }
        // Reading the raw block can retain the growable input plus its returned
        // byte copy. No text or descriptor arrays are created until the scan admits them.
        let rawCap = min(65_536, min(maxHeaderBytes, max(0, (maximumStorageBytes - 4) / 3)))
        func parseHeaders() throws -> (String, Int, String, [String: String], Int) {
            guard let bytes = try readHeaderBlockLocked(maxHeaderBytes: rawCap, borrow: borrow) else {
                throw J2KError.networkError("Server closed connection before sending HTTP response headers.")
            }
            var start = 0
            var headerCount = 0
            var longestLine = 0
            var firstLine = true
            for end in 0...bytes.count where end == bytes.count || bytes[end] == 0x0A {
                longestLine = max(longestLine, end - start)
                if !firstLine, bytes[start..<end].contains(0x3A) { headerCount += 1 }
                firstLine = false
                start = end + 1
            }
            // Raw bytes + retained Latin-1-expanded strings + duplicate-value
            // replacement; current line/trim copies; dictionary growth and status split.
            let descriptorBytes = try multiply(headerCount, 4 * MemoryLayout<(String, String)>.stride)
            let workspace = try add(multiply(bytes.count, 5), add(multiply(longestLine, 6),
                add(descriptorBytes, 4 * MemoryLayout<Substring>.stride + 2 * MemoryLayout<String>.stride)))
            guard workspace <= maximumStorageBytes else {
                throw CodecError(.resourceLimitExceeded, "HTTP header descriptors exceed remaining storage before text parsing.")
            }
            var headers: [String: String] = [:]
            var version = ""
            var reason = ""
            var status = 0
            start = 0
            firstLine = true
            for end in 0...bytes.count where end == bytes.count || bytes[end] == 0x0A {
                let trimmedEnd = end > start && bytes[end - 1] == 0x0D ? end - 1 : end
                guard let line = String(bytes: bytes[start..<trimmedEnd], encoding: .utf8)
                    ?? String(bytes: bytes[start..<trimmedEnd], encoding: .isoLatin1) else {
                    throw J2KError.invalidData("Malformed HTTP response header encoding.")
                }
                if firstLine {
                    let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                    guard parts.count >= 2, let code = Int(parts[1]) else { throw J2KError.invalidData("Malformed HTTP status line.") }
                    version = String(parts[0]); status = code
                    reason = parts.count >= 3 ? String(parts[2]) : ""
                    firstLine = false
                } else if let colon = line.firstIndex(of: ":") {
                    let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    if let existing = headers[key] { headers[key] = "\(existing), \(value)" }
                    else { headers[key] = value }
                }
                start = end + 1
            }
            return (version, status, reason, headers, workspace)
        }
        let (version, code, reason, headers, headerPeak) = try parseHeaders()
        let retainedHeaders = try add(JPIPResponse.headerStorageBytes(headers),
            add(version.utf8.count, add(reason.utf8.count, 2 * MemoryLayout<String>.stride)))
        guard retainedHeaders <= maximumStorageBytes else {
            throw CodecError(.resourceLimitExceeded, "Retained HTTP headers exceed response storage.")
        }
        let remainingStorage = maximumStorageBytes - retainedHeaders
        var peak = headerPeak
        func response(_ body: Data, bufferFactor: Int) throws -> JPIPHTTPWireResponse {
            peak = max(peak, try add(retainedHeaders, multiply(body.count, bufferFactor)))
            return JPIPHTTPWireResponse(version: version, statusCode: code, reasonPhrase: reason,
                headers: headers, body: body, retainedHeaderStorageBytes: retainedHeaders, peakWorkspaceBytes: peak)
        }

        if code == 101 || code == 204 || code == 304 {
            return try response(Data(), bufferFactor: 0)
        }

        let isChunked: Bool = {
            let encoding = headers.first { $0.key.lowercased() == "transfer-encoding" }?.value.lowercased() ?? ""
            return encoding.contains("chunked")
        }()
        if isChunked {
            let bodyCap = min(maxBodyBytes, max(0, remainingStorage - 4) / 2)
            var output = Data()
            func chunkLine(maximum: Int) throws -> String {
                let fixed = 4 * MemoryLayout<Substring>.stride
                let available = remainingStorage - output.count
                guard available > fixed else { throw CodecError(.resourceLimitExceeded, "HTTP chunk framing exceeds remaining storage.") }
                let line = try readLineCRLFLocked(maxLineBytes: min(maximum, (available - fixed) / 12), borrow: borrow)
                peak = max(peak, try add(retainedHeaders, add(output.count, add(multiply(line.utf8.count, 6), fixed))))
                return line
            }
            func nextChunkSize() throws -> Int {
                let line = try chunkLine(maximum: 4096)
                let raw = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                guard let size = Int(raw.trimmingCharacters(in: .whitespaces), radix: 16), size >= 0 else {
                    throw J2KError.invalidData("Malformed HTTP chunk size.")
                }
                return size
            }
            while true {
                let count = try nextChunkSize()
                if count == 0 {
                    while !(try chunkLine(maximum: 8192)).isEmpty {}
                    return try response(output, bufferFactor: 2)
                }
                let next = try add(output.count, count)
                guard next <= bodyCap else { throw CodecError(.resourceLimitExceeded, "Chunked HTTP body exceeds remaining header/body storage before allocation.") }
                peak = max(peak, try add(retainedHeaders, add(multiply(next, 2), 4)))
                let chunk = try readExactLocked(count: count, borrow: borrow)
                var replacement = Data(count: next)
                replacement.replaceSubrange(0..<output.count, with: output)
                replacement.replaceSubrange(output.count..<next, with: chunk)
                output = replacement
                guard try readExactLocked(count: 2, borrow: borrow) == Data([0x0D, 0x0A]) else { throw J2KError.invalidData("Missing HTTP chunk terminator.") }
            }
        }

        if let clStr = headers.first(where: { $0.key.lowercased() == "content-length" })?.value {
            guard let cl = Int(clStr.trimmingCharacters(in: .whitespaces)), cl >= 0 else {
                throw J2KError.invalidData("Invalid Content-Length '\(clStr)'.")
            }
            let maxAllowed = min(maxBodyBytes, remainingStorage / 2)
            guard cl <= maxAllowed else {
                throw CodecError(.resourceLimitExceeded, "Requested TCP payload (\(cl) bytes) exceeds limit (\(maxAllowed) bytes).")
            }
            let body = try readExactLocked(count: cl, borrow: borrow)
            return try response(body, bufferFactor: 2)
        }

        // Connection: close EOF-delimited body
        let body = try readToEOFLocked(maxAllowedBytes: min(maxBodyBytes, remainingStorage / 3), borrow: borrow)
        return try response(body, bufferFactor: 3)
    }

    // MARK: - RFC 6455 WebSocket Handshake & Framing

    package func performWebSocketClientHandshake(
        pathAndQuery: String,
        hostHeader: String,
        subprotocol: String = "jpip",
        maxHeaderBytes: Int = 65_536,
        maxBodyBytes: Int = 0,
        maximumStorageBytes: Int = Int.max
    ) throws -> (subprotocol: String?, peakWorkspaceBytes: Int) {
        let clientKey = JPIPRFC6455Crypto.randomClientKey()
        let expectedAccept = JPIPRFC6455Crypto.computeAcceptKey(for: clientKey)
        try writeHTTPRequest(
            method: "GET",
            pathAndQuery: pathAndQuery,
            hostHeader: hostHeader,
            headers: [
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Key": clientKey,
                "Sec-WebSocket-Version": "13",
                "Sec-WebSocket-Protocol": subprotocol
            ]
        )
        let resp = try readHTTPResponse(maxHeaderBytes: maxHeaderBytes, maxBodyBytes: maxBodyBytes,
                                        maximumStorageBytes: maximumStorageBytes)
        guard resp.statusCode == 101 else {
            throw J2KError.networkError("WebSocket upgrade rejected with HTTP \(resp.statusCode)")
        }
        guard resp.header("Upgrade")?.lowercased() == "websocket",
              let accept = resp.header("Sec-WebSocket-Accept"),
              accept.trimmingCharacters(in: .whitespaces) == expectedAccept else {
            throw J2KError.invalidData("RFC 6455 Sec-WebSocket-Accept verification failed.")
        }
        return (resp.header("Sec-WebSocket-Protocol"), resp.peakWorkspaceBytes)
    }

    package func writeWebSocketServerHandshake(
        clientKey: String,
        negotiatedSubprotocol: String? = "jpip",
        extraHeaders: [String: String] = [:]
    ) throws {
        var headers: [String: String] = [
            "Upgrade": "websocket",
            "Connection": "Upgrade",
            "Sec-WebSocket-Accept": JPIPRFC6455Crypto.computeAcceptKey(for: clientKey)
        ]
        if let proto = negotiatedSubprotocol, !proto.isEmpty {
            headers["Sec-WebSocket-Protocol"] = proto
        }
        for (k, v) in extraHeaders {
            headers[k] = v
        }
        try writeHTTPResponse(statusCode: 101, reasonPhrase: "Switching Protocols", headers: headers, body: Data())
    }

    package func writeWebSocketFrame(
        opcode: JPIPRFC6455Opcode,
        payload: Data,
        masked: Bool,
        fin: Bool = true
    ) throws {
        var header = [UInt8]()
        header.reserveCapacity(14)
        let b0: UInt8 = (fin ? 0x80 : 0x00) | (opcode.rawValue & 0x0F)
        header.append(b0)

        let maskBit: UInt8 = masked ? 0x80 : 0x00
        let len = payload.count
        if len < 126 {
            header.append(maskBit | UInt8(len))
        } else if len <= 65535 {
            header.append(maskBit | 126)
            header.append(UInt8((len >> 8) & 0xFF))
            header.append(UInt8(len & 0xFF))
        } else {
            header.append(maskBit | 127)
            let u64 = UInt64(len)
            for shift in stride(from: 56, through: 0, by: -8) {
                header.append(UInt8((u64 >> UInt64(shift)) & 0xFF))
            }
        }

        var wire = Data(header)
        if masked {
            let maskKey: [UInt8] = [
                UInt8.random(in: 0...255),
                UInt8.random(in: 0...255),
                UInt8.random(in: 0...255),
                UInt8.random(in: 0...255)
            ]
            wire.append(contentsOf: maskKey)
            var maskedBytes = [UInt8](payload)
            for i in 0..<maskedBytes.count {
                maskedBytes[i] ^= maskKey[i & 3]
            }
            wire.append(contentsOf: maskedBytes)
        } else {
            wire.append(payload)
        }
        try writeAll(wire)
    }

    /// Reads one complete RFC 6455 message (preserving fragmented `FIN=0` continuation state on the
    /// connection instance across interleaved `FIN=1` control frames `ping`/`pong`/`close` per RFC 6455 §5.4).
    package func readWebSocketFrame(
        maxFrameBytes: Int = 64 * 1024 * 1024,
        requireMasked: Bool? = nil,
        budget: JPIPWebSocketReadBudget? = nil
    ) throws -> JPIPRFC6455WireFrame {
        let borrow = try descriptor.acquireBorrow(operation: .readWebSocketFrame)
        defer { borrow.release() }
        lockTracker.enter(wsReadLock)
        defer { lockTracker.exit(wsReadLock) }
        var returnedMessage = false
        defer {
            if !returnedMessage {
                wsFragmentedOpcode = nil
                wsFragmentedPayload = Data()
                budget?.resetReading()
            }
        }

        while true {
            try budget?.admitFrame(fragmentedBytes: wsFragmentedPayload.count, payloadBytes: 0, control: true)
            let hdr2 = try readWebSocketExact(count: 2, borrow: borrow)
            let b0 = hdr2[hdr2.startIndex]
            let b1 = hdr2[hdr2.startIndex + 1]
            let fin = (b0 & 0x80) != 0
            let rsv = (b0 & 0x70)
            guard rsv == 0 else {
                wsFragmentedOpcode = nil
                wsFragmentedPayload.removeAll(keepingCapacity: false)
                throw J2KError.invalidData("RFC 6455 RSV bits must be 0 when no extension is negotiated.")
            }
            let rawOp = b0 & 0x0F
            guard let opcode = JPIPRFC6455Opcode(rawValue: rawOp) else {
                wsFragmentedOpcode = nil
                wsFragmentedPayload.removeAll(keepingCapacity: false)
                throw J2KError.invalidData("Unsupported RFC 6455 opcode 0x\(String(rawOp, radix: 16)).")
            }

            let isMasked = (b1 & 0x80) != 0
            if let reqMask = requireMasked, isMasked != reqMask {
                wsFragmentedOpcode = nil
                wsFragmentedPayload.removeAll(keepingCapacity: false)
                throw J2KError.invalidData("RFC 6455 masking requirement violated (masked=\(isMasked), expected=\(reqMask)).")
            }

            let len7 = Int(b1 & 0x7F)
            let payloadLen: Int
            if len7 < 126 {
                payloadLen = len7
            } else if len7 == 126 {
                let ext = try readWebSocketExact(count: 2, borrow: borrow)
                payloadLen = (Int(ext[ext.startIndex]) << 8) | Int(ext[ext.startIndex + 1])
            } else {
                let ext = try readWebSocketExact(count: 8, borrow: borrow)
                var u64: UInt64 = 0
                for idx in ext.indices {
                    u64 = (u64 << 8) | UInt64(ext[idx])
                }
                guard (u64 & (1 << 63)) == 0, u64 <= UInt64(maxFrameBytes) else {
                    wsFragmentedOpcode = nil
                    wsFragmentedPayload.removeAll(keepingCapacity: false)
                    throw CodecError(.resourceLimitExceeded, "RFC 6455 frame length \(u64) exceeds limit (\(maxFrameBytes)).")
                }
                payloadLen = Int(u64)
            }

            // Control frames (0x8..0xF) must not exceed 125 bytes and must not be fragmented.
            // Per RFC 6455 §5.4, control frames may be injected in the middle of a fragmented
            // data message and must be handled without resetting `wsFragmentedOpcode`/`wsFragmentedPayload`.
            if rawOp >= 0x8 {
                guard fin, payloadLen <= 125 else {
                    wsFragmentedOpcode = nil
                    wsFragmentedPayload.removeAll(keepingCapacity: false)
                    throw J2KError.invalidData("RFC 6455 control frame must have FIN=1 and length <= 125.")
                }
                guard payloadLen <= maxFrameBytes else {
                    throw CodecError(.resourceLimitExceeded, "RFC 6455 control frame exceeds limit (\(maxFrameBytes) bytes).")
                }
                try budget?.admitFrame(fragmentedBytes: wsFragmentedPayload.count, payloadBytes: payloadLen, control: true)
                let maskKey = isMasked ? try readWebSocketExact(count: 4, borrow: borrow) : Data()
                if payloadLen > 0 { budget?.willAllocatePayload() }
                var chunk = try readWebSocketExact(count: payloadLen, borrow: borrow)
                Self.unmaskWebSocketPayload(&chunk, maskKey: maskKey)
                budget?.didReadMessage(bytes: chunk.count, retainedFragments: wsFragmentedPayload.count)
                returnedMessage = true
                return JPIPRFC6455WireFrame(fin: true, opcode: opcode, payload: chunk)
            }

            let (nextTotal, ov) = wsFragmentedPayload.count.addingReportingOverflow(payloadLen)
            guard !ov, nextTotal <= maxFrameBytes else {
                wsFragmentedOpcode = nil
                wsFragmentedPayload.removeAll(keepingCapacity: false)
                throw CodecError(.resourceLimitExceeded, "RFC 6455 message exceeds limit (\(maxFrameBytes) bytes).")
            }

            if opcode == .continuation {
                guard wsFragmentedOpcode != nil else {
                    throw J2KError.invalidData("Unexpected RFC 6455 continuation frame without initial data frame.")
                }
            } else {
                guard wsFragmentedOpcode == nil else {
                    wsFragmentedOpcode = nil
                    wsFragmentedPayload.removeAll(keepingCapacity: false)
                    throw J2KError.invalidData("New RFC 6455 data frame started before fragmented message finished.")
                }
            }

            try budget?.admitFrame(fragmentedBytes: wsFragmentedPayload.count, payloadBytes: payloadLen, control: false)
            let maskKey = isMasked ? try readWebSocketExact(count: 4, borrow: borrow) : Data()
            let prefixCount = budget == nil ? 0 : min(payloadLen, max(0, 27 - wsFragmentedPayload.count))
            var prefix = try readWebSocketExact(count: prefixCount, borrow: borrow)
            Self.unmaskWebSocketPayload(&prefix, maskKey: maskKey)
            if let budget {
                var applicationPrefix = Data(wsFragmentedPayload.prefix(27))
                applicationPrefix.append(prefix)
                try budget.admitApplicationPrefix(applicationPrefix, announcedBytes: nextTotal, final: fin)
            }
            // The announced application body and every simultaneous receive/
            // fragment buffer have been admitted before this owning allocation.
            if payloadLen > 0 { budget?.willAllocatePayload() }
            var chunk = try readWebSocketExact(count: payloadLen, prefix: prefix, borrow: borrow)
            Self.unmaskWebSocketPayload(&chunk, maskKey: maskKey, startingAt: prefixCount)
            if opcode == .continuation { wsFragmentedPayload.append(chunk) }
            else {
                wsFragmentedOpcode = opcode
                wsFragmentedPayload = chunk
            }

            if fin, let finalOpcode = wsFragmentedOpcode {
                let completed = wsFragmentedPayload
                wsFragmentedOpcode = nil
                wsFragmentedPayload = Data()
                budget?.didReadMessage(bytes: completed.count, retainedFragments: 0)
                returnedMessage = true
                return JPIPRFC6455WireFrame(fin: true, opcode: finalOpcode, payload: completed)
            }
        }
    }

    /// Reads exactly the admitted bytes, without the HTTP reader's scratch buffer
    /// or read-ahead. Existing handshake bytes are consumed under the same lock.
    private func readWebSocketExact(
        count: Int,
        prefix: Data = Data(),
        borrow: JPIPSocketDescriptor.Borrow
    ) throws -> Data {
        guard count >= prefix.count else { throw J2KError.invalidData("Invalid WebSocket prefix length.") }
        if count == 0 { return Data() }
        lockTracker.enter(readLock)
        defer { lockTracker.exit(readLock) }
        var output = Data(count: count)
        try output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
            guard let base = destination.baseAddress else { return }
            if !prefix.isEmpty {
                prefix.withUnsafeBytes { source in
                    base.copyMemory(from: source.baseAddress!, byteCount: source.count)
                }
            }
            var filled = prefix.count
            let buffered = min(count - filled, readBuffer.count - readOffset)
            if buffered > 0 {
                readBuffer.withUnsafeBytes { source in
                    base.advanced(by: filled).copyMemory(from: source.baseAddress!.advanced(by: readOffset), byteCount: buffered)
                }
                filled += buffered
                readOffset += buffered
            }
            if readOffset == readBuffer.count {
                readBuffer.removeAll(keepingCapacity: false)
                readOffset = 0
            }
            while filled < count {
                guard !borrow.isRetired else {
                    throw J2KError.networkError("TCP recv failed while reading WebSocket payload (connection closed).")
                }
                let (n, err) = performRecv(
                    borrow: borrow,
                    buffer: base.advanced(by: filled),
                    count: count - filled
                )
                if n > 0 {
                    filled += n
                } else if n < 0 && err == EINTR {
                    guard !borrow.isRetired else {
                        throw J2KError.networkError("TCP recv failed while reading WebSocket payload (connection closed).")
                    }
                    continue
                } else if n == 0 {
                    throw J2KError.networkError("Unexpected EOF in WebSocket payload.")
                } else {
                    throw J2KError.networkError("TCP recv failed while reading WebSocket payload (errno=\(err)).")
                }
            }
        }
        return output
    }

    private static func unmaskWebSocketPayload(_ payload: inout Data, maskKey: Data, startingAt: Int = 0) {
        guard maskKey.count == 4, startingAt < payload.count else { return }
        payload.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for i in startingAt..<bytes.count { bytes[i] ^= maskKey[maskKey.startIndex + (i & 3)] }
        }
    }
}
