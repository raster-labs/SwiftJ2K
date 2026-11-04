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
private func currentPOSIXErrno() -> Int32 {
    #if canImport(Darwin)
    return Darwin.errno
    #else
    return Glibc.errno
    #endif
}

@inline(__always)
private func posixCloseSocket(_ fd: Int32) {
    guard fd >= 0 else { return }
    #if canImport(Darwin)
    _ = Darwin.shutdown(fd, SHUT_RDWR)
    _ = Darwin.close(fd)
    #else
    _ = Glibc.shutdown(fd, Int32(SHUT_RDWR))
    _ = Glibc.close(fd)
    #endif
}

// MARK: - JPIPTCPListener

/// Thread-safe POSIX IPv4 TCP listening socket.
///
/// Concurrency proof (`@unchecked Sendable`):
/// `fd` is mutated exclusively under `lock` (`acceptConnection` snapshots `fd` under `lock`
/// before calling `accept`, and `close()` atomically swaps `fd` to `-1` under `lock` before
/// calling `shutdown`/`close` to unblock any concurrent `accept`). `boundPort` is immutable.
package final class JPIPTCPListener: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    package let boundHost: String
    package let boundPort: Int

    package init(host: String = "127.0.0.1", port: Int) throws {
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
                posixCloseSocket(sock)
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
            posixCloseSocket(sock)
            throw J2KError.networkError("Failed to bind \(host):\(port) (errno=\(err))")
        }

        guard listen(sock, 128) == 0 else {
            let err = currentPOSIXErrno()
            posixCloseSocket(sock)
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
            posixCloseSocket(sock)
            throw J2KError.networkError("getsockname failed (errno=\(err))")
        }

        self.fd = sock
        self.boundHost = normalizedHost.isEmpty ? "127.0.0.1" : normalizedHost
        self.boundPort = Int(UInt16(bigEndian: actualAddr.sin_port))
    }

    deinit {
        close()
    }

    package var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fd >= 0
    }

    /// Blocks the calling OS thread until a client connects or the listener closes.
    /// Must be invoked from a non-cooperative OS thread/DispatchQueue.
    package func acceptConnection(timeoutSeconds: Int = 30) throws -> JPIPTCPConnection? {
        let listenFD: Int32 = {
            lock.lock()
            defer { lock.unlock() }
            return fd
        }()
        guard listenFD >= 0 else { return nil }

        while true {
            var clientAddr = sockaddr_storage()
            var clientLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    accept(listenFD, sa, &clientLen)
                }
            }
            if clientFD >= 0 {
                return JPIPTCPConnection(connectedFD: clientFD, timeoutSeconds: timeoutSeconds)
            }
            let err = currentPOSIXErrno()
            if err == EINTR {
                continue
            }
            if !isOpen || err == EBADF || err == EINVAL || err == ECONNABORTED {
                return nil
            }
            throw J2KError.networkError("accept() failed (errno=\(err))")
        }
    }

    package func close() {
        let oldFD: Int32 = {
            lock.lock()
            defer { lock.unlock() }
            let current = fd
            fd = -1
            return current
        }()
        if oldFD >= 0 {
            posixCloseSocket(oldFD)
        }
    }
}

// MARK: - Socket Cancellation Token

/// Thread-safe cancellation token bridging structured Swift concurrency cancellation
/// (`withTaskCancellationHandler`) to blocking POSIX `connect` / `recv` / `send` operations.
///
/// Concurrency proof (`@unchecked Sendable`):
/// All mutable state (`isCancelled`, `connectingFD`, `activeConnection`) is guarded by `lock`.
/// `endFailedConnectAttempt()` clears `connectingFD` under `lock` *before* `posixCloseSocket`
/// closes the descriptor, and `cancel()` invokes non-blocking `shutdown(fd, SHUT_RDWR)` while
/// holding `lock`, guaranteeing `shutdown` can never target a closed or recycled file descriptor.
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
            #if canImport(Darwin)
            _ = Darwin.shutdown(connectingFD, SHUT_RDWR)
            #else
            _ = Glibc.shutdown(connectingFD, Int32(SHUT_RDWR))
            #endif
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
/// `fd` is synchronized by `fdLock` (`close()` atomically swaps `fd` to `-1` and calls
/// `shutdown`/`close`). `readLock` serializes `readBuffer` and `recv` operations; `wsReadLock`
/// serializes RFC 6455 fragmented-message reassembly state across interleaved control frames;
/// `writeLock` serializes `send` operations so full-duplex WebSocket/server-push writes never
/// race with concurrent frame reads.
package final class JPIPTCPConnection: @unchecked Sendable {
    private let fdLock = NSLock()
    private let readLock = NSLock()
    private let wsReadLock = NSLock()
    private let writeLock = NSLock()
    private var fd: Int32
    private var readBuffer = [UInt8]()
    private var readOffset: Int = 0
    private var wsFragmentedOpcode: JPIPRFC6455Opcode?
    private var wsFragmentedPayload = Data()
    // Deterministic algorithm-work evidence, protected by readLock. Counters
    // saturate across arbitrarily many messages instead of overflowing.
    private var headerScanPositions = 0
    private var lineScanBytes = 0

    package var httpDelimiterScanWork: (headerPositions: Int, lineBytes: Int) {
        readLock.lock()
        defer { readLock.unlock() }
        return (headerScanPositions, lineScanBytes)
    }

    package init(connectedFD: Int32, timeoutSeconds: Int = 30) {
        self.fd = connectedFD
        Self.configureSocket(connectedFD, timeoutInterval: TimeInterval(timeoutSeconds))
    }

    package init(connectedFD: Int32, timeoutInterval: TimeInterval) {
        self.fd = connectedFD
        Self.configureSocket(connectedFD, timeoutInterval: timeoutInterval)
    }

    package static func connect(host: String, port: Int, timeoutSeconds: Int = 30) throws -> JPIPTCPConnection {
        try connect(host: host, port: port, timeoutInterval: TimeInterval(timeoutSeconds))
    }

    package static func connect(
        host: String,
        port: Int,
        timeoutInterval: TimeInterval,
        cancellationToken: JPIPSocketCancellationToken? = nil
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
                    posixCloseSocket(sock)
                    throw CancellationError()
                }
                Self.configureSocket(sock, timeoutInterval: timeoutInterval)
                let rc = DarwinOrGlibcConnect(sock, info.pointee.ai_addr, info.pointee.ai_addrlen)
                if rc == 0 {
                    let conn = JPIPTCPConnection(connectedFD: sock, timeoutInterval: timeoutInterval)
                    if let cancellationToken, !cancellationToken.completeConnect(connection: conn) {
                        conn.close()
                        throw CancellationError()
                    }
                    return conn
                }
                lastErrno = currentPOSIXErrno()
                cancellationToken?.endFailedConnectAttempt()
                posixCloseSocket(sock)
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

    private static func makeTimeval(_ interval: TimeInterval) -> timeval {
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

    private static func configureSocket(_ sock: Int32, timeoutInterval: TimeInterval) {
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
        fdLock.lock()
        let sock = fd
        fdLock.unlock()
        guard sock >= 0 else { return }
        var tv = Self.makeTimeval(interval)
        _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    package func setSendTimeout(interval: TimeInterval) {
        fdLock.lock()
        let sock = fd
        fdLock.unlock()
        guard sock >= 0 else { return }
        var tv = Self.makeTimeval(interval)
        _ = setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    deinit {
        close()
    }

    package var isOpen: Bool {
        fdLock.lock()
        defer { fdLock.unlock() }
        return fd >= 0
    }

    private func currentFD() throws -> Int32 {
        fdLock.lock()
        defer { fdLock.unlock() }
        guard fd >= 0 else {
            throw J2KError.networkError("TCP connection is closed.")
        }
        return fd
    }

    package func close() {
        let oldFD: Int32 = {
            fdLock.lock()
            defer { fdLock.unlock() }
            let cur = fd
            fd = -1
            return cur
        }()
        if oldFD >= 0 {
            posixCloseSocket(oldFD)
        }
    }

    // MARK: - Raw Binary Write & Buffered Read

    package func writeAll(_ data: Data) throws {
        guard !data.isEmpty else { return }
        writeLock.lock()
        defer { writeLock.unlock() }

        let sock = try currentFD()
        try data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var sent = 0
            while sent < rawBuf.count {
                let n = send(sock, base.advanced(by: sent), rawBuf.count - sent, posixSendFlags)
                if n > 0 {
                    sent += n
                } else if n < 0 && currentPOSIXErrno() == EINTR {
                    continue
                } else {
                    let err = currentPOSIXErrno()
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

    private func fillOnceLocked(maxReadBytes: Int = 16384) throws -> Int {
        guard maxReadBytes > 0 else {
            throw CodecError(.resourceLimitExceeded, "TCP read allowance exhausted before allocation.")
        }
        let sock = try currentFD()
        var scratch = [UInt8](repeating: 0, count: min(16384, maxReadBytes))
        while true {
            let n = scratch.withUnsafeMutableBytes { buf in
                recv(sock, buf.baseAddress!, buf.count, 0)
            }
            if n > 0 {
                readBuffer.append(contentsOf: scratch[0..<n])
                return n
            } else if n == 0 {
                return 0
            } else {
                let err = currentPOSIXErrno()
                if err == EINTR { continue }
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

        readLock.lock()
        defer { readLock.unlock() }

        return try readExactLocked(count: count)
    }

    /// The announced length is admitted by the caller before this one allocation.
    private func readExactLocked(count: Int) throws -> Data {
        var output = Data(count: count)
        let buffered = min(count, readBuffer.count - readOffset)
        if buffered > 0 {
            output.replaceSubrange(0..<buffered, with: readBuffer[readOffset..<(readOffset + buffered)])
            readOffset += buffered
            compactReadBufferLocked()
        }
        let socket = try currentFD()
        try output.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var offset = buffered
            while offset < count {
                let received = recv(socket, base.advanced(by: offset), count - offset, 0)
                if received > 0 { offset += received }
                else if received < 0 && currentPOSIXErrno() == EINTR { continue }
                else { throw J2KError.networkError("TCP read failed before the complete admitted payload arrived.") }
            }
        }
        return output
    }

    private func readToEOF(maxAllowedBytes: Int) throws -> Data {
        readLock.lock()
        defer { readLock.unlock() }
        let buffered = readBuffer.count - readOffset
        guard buffered <= maxAllowedBytes else {
            throw CodecError(.resourceLimitExceeded, "EOF-delimited HTTP body exceeds limit before allocation.")
        }
        var output = Data(readBuffer[readOffset..<readBuffer.count])
        readOffset = readBuffer.count
        compactReadBufferLocked()
        let socket = try currentFD()
        while true {
            let remaining = maxAllowedBytes - output.count
            if remaining == 0 {
                var extra: UInt8 = 0
                let count = withUnsafeMutablePointer(to: &extra) { recv(socket, $0, 1, 0) }
                if count == 0 { return output }
                if count < 0 && currentPOSIXErrno() == EINTR { continue }
                if count > 0 { throw CodecError(.resourceLimitExceeded, "EOF-delimited HTTP body exceeds limit before allocation.") }
                throw J2KError.networkError("TCP read failed at the EOF-delimited body limit.")
            }
            // Grow the read window with observed data, so a short response never
            // allocates a large speculative scratch buffer.
            var scratch = [UInt8](repeating: 0, count: min(16384, min(remaining, max(1, output.count))))
            let count = scratch.withUnsafeMutableBytes { recv(socket, $0.baseAddress, $0.count, 0) }
            if count == 0 { return output }
            if count < 0 {
                if currentPOSIXErrno() == EINTR { continue }
                throw J2KError.networkError("TCP read failed inside an EOF-delimited body.")
            }
            let nextCount = output.count + count // count is bounded by remaining.
            var replacement = Data(count: nextCount)
            replacement.replaceSubrange(0..<output.count, with: output)
            replacement.replaceSubrange(output.count..<nextCount, with: scratch.prefix(count))
            output = replacement
        }
    }

    private func readLineCRLFLocked(maxLineBytes: Int) throws -> String {
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
            let got = try fillOnceLocked(maxReadBytes: 1)
            if got == 0 {
                throw J2KError.networkError("Unexpected EOF while reading HTTP line.")
            }
        }
    }

    /// Reads until `\r\n\r\n` (or `\n\n`). Returns `nil` cleanly on immediate EOF before any byte.
    private func readHeaderBlockLocked(maxHeaderBytes: Int) throws -> [UInt8]? {
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
            let got = try fillOnceLocked(maxReadBytes: 1)
            if got == 0 {
                if (readBuffer.count - readOffset) == 0 {
                    return nil
                }
                throw J2KError.networkError("Unexpected EOF inside HTTP header block.")
            }
        }
    }

    private func readChunkedBodyLocked(maxBodyBytes: Int) throws -> Data {
        var out = Data()
        while true {
            let sizeLine = try readLineCRLFLocked(maxLineBytes: 4096)
            let hexPart = sizeLine.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let trimmedHex = hexPart.trimmingCharacters(in: .whitespaces)
            guard let chunkSize = Int(trimmedHex, radix: 16), chunkSize >= 0 else {
                throw J2KError.invalidData("Malformed HTTP chunk size '\(trimmedHex)'.")
            }
            if chunkSize == 0 {
                // Consume trailing headers until empty line
                while true {
                    let trailer = try readLineCRLFLocked(maxLineBytes: 8192)
                    if trailer.isEmpty { break }
                }
                return out
            }
            let (nextTotal, ov) = out.count.addingReportingOverflow(chunkSize)
            guard !ov, nextTotal <= maxBodyBytes else {
                throw CodecError(.resourceLimitExceeded, "Chunked HTTP body exceeds limit (\(maxBodyBytes) bytes).")
            }
            let chunk = try readExactLocked(count: chunkSize)
            // Old output + chunk + replacement equal twice nextTotal, rather
            // than relying on an untracked Array/Data growth capacity.
            var replacement = Data(count: nextTotal)
            replacement.replaceSubrange(0..<out.count, with: out)
            replacement.replaceSubrange(out.count..<nextTotal, with: chunk)
            out = replacement
            // Consume trailing CRLF after chunk payload
            _ = try readLineCRLFLocked(maxLineBytes: 16)
        }
    }

    // MARK: - HTTP/1.1 Framing

    package func readHTTPRequest(
        maxHeaderBytes: Int = 65536,
        maxBodyBytes: Int = 64 * 1024 * 1024
    ) throws -> JPIPHTTPWireRequest? {
        readLock.lock()
        var unlocked = false
        defer { if !unlocked { readLock.unlock() } }

        guard let headerBytes = try readHeaderBlockLocked(maxHeaderBytes: maxHeaderBytes) else {
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
            let body = try readChunkedBodyLocked(maxBodyBytes: maxBodyBytes)
            return JPIPHTTPWireRequest(method: method, target: target, version: version, headers: headers, body: body)
        }

        var contentLen = 0
        if let clStr = headers.first(where: { $0.key.lowercased() == "content-length" })?.value {
            guard let parsed = Int(clStr.trimmingCharacters(in: .whitespaces)), parsed >= 0 else {
                throw J2KError.invalidData("Invalid Content-Length '\(clStr)'.")
            }
            contentLen = parsed
        }
        unlocked = true
        readLock.unlock()

        let body = contentLen > 0 ? try readExact(count: contentLen, maxAllowedBytes: maxBodyBytes) : Data()
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
        readLock.lock()
        var unlocked = false
        defer { if !unlocked { readLock.unlock() } }

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
            guard let bytes = try readHeaderBlockLocked(maxHeaderBytes: rawCap) else {
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
                let line = try readLineCRLFLocked(maxLineBytes: min(maximum, (available - fixed) / 12))
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
                let chunk = try readExactLocked(count: count)
                var replacement = Data(count: next)
                replacement.replaceSubrange(0..<output.count, with: output)
                replacement.replaceSubrange(output.count..<next, with: chunk)
                output = replacement
                guard try readExactLocked(count: 2) == Data([0x0D, 0x0A]) else { throw J2KError.invalidData("Missing HTTP chunk terminator.") }
            }
        }

        if let clStr = headers.first(where: { $0.key.lowercased() == "content-length" })?.value {
            guard let cl = Int(clStr.trimmingCharacters(in: .whitespaces)), cl >= 0 else {
                throw J2KError.invalidData("Invalid Content-Length '\(clStr)'.")
            }
            unlocked = true
            readLock.unlock()
            let body = try readExact(count: cl, maxAllowedBytes: min(maxBodyBytes, remainingStorage / 2))
            return try response(body, bufferFactor: 2)
        }

        // Connection: close EOF-delimited body
        unlocked = true
        readLock.unlock()
        let body = try readToEOF(maxAllowedBytes: min(maxBodyBytes, remainingStorage / 3))
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
        wsReadLock.lock()
        defer { wsReadLock.unlock() }
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
            let hdr2 = try readWebSocketExact(count: 2)
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
                let ext = try readWebSocketExact(count: 2)
                payloadLen = (Int(ext[ext.startIndex]) << 8) | Int(ext[ext.startIndex + 1])
            } else {
                let ext = try readWebSocketExact(count: 8)
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
                let maskKey = isMasked ? try readWebSocketExact(count: 4) : Data()
                if payloadLen > 0 { budget?.willAllocatePayload() }
                var chunk = try readWebSocketExact(count: payloadLen)
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
            let maskKey = isMasked ? try readWebSocketExact(count: 4) : Data()
            let prefixCount = budget == nil ? 0 : min(payloadLen, max(0, 27 - wsFragmentedPayload.count))
            var prefix = try readWebSocketExact(count: prefixCount)
            Self.unmaskWebSocketPayload(&prefix, maskKey: maskKey)
            if let budget {
                var applicationPrefix = Data(wsFragmentedPayload.prefix(27))
                applicationPrefix.append(prefix)
                try budget.admitApplicationPrefix(applicationPrefix, announcedBytes: nextTotal, final: fin)
            }
            // The announced application body and every simultaneous receive/
            // fragment buffer have been admitted before this owning allocation.
            if payloadLen > 0 { budget?.willAllocatePayload() }
            var chunk = try readWebSocketExact(count: payloadLen, prefix: prefix)
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
    private func readWebSocketExact(count: Int, prefix: Data = Data()) throws -> Data {
        guard count >= prefix.count else { throw J2KError.invalidData("Invalid WebSocket prefix length.") }
        if count == 0 { return Data() }
        readLock.lock()
        defer { readLock.unlock() }
        let sock = try currentFD()
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
                let n = recv(sock, base.advanced(by: filled), count - filled, 0)
                if n > 0 { filled += n }
                else if n < 0 && currentPOSIXErrno() == EINTR { continue }
                else if n == 0 { throw J2KError.networkError("Unexpected EOF in WebSocket payload.") }
                else { throw J2KError.networkError("TCP recv failed while reading WebSocket payload (errno=\(currentPOSIXErrno())).") }
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
