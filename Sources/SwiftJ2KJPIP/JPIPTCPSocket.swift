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

// MARK: - JPIPTCPConnection

/// Thread-safe buffered binary TCP socket supporting HTTP/1.1 persistent framing
/// and RFC 6455 WebSocket binary/control frames.
///
/// Concurrency proof (`@unchecked Sendable`):
/// `fd` is synchronized by `fdLock` (`close()` atomically swaps `fd` to `-1` and calls
/// `shutdown`/`close`). `readLock` serializes `readBuffer` and `recv` operations; `writeLock`
/// serializes `send` operations so full-duplex WebSocket/server-push writes never race with
/// concurrent frame reads.
package final class JPIPTCPConnection: @unchecked Sendable {
    private let fdLock = NSLock()
    private let readLock = NSLock()
    private let writeLock = NSLock()
    private var fd: Int32
    private var readBuffer = [UInt8]()
    private var readOffset: Int = 0

    package init(connectedFD: Int32, timeoutSeconds: Int = 30) {
        self.fd = connectedFD
        Self.configureSocket(connectedFD, timeoutSeconds: timeoutSeconds)
    }

    package static func connect(host: String, port: Int, timeoutSeconds: Int = 30) throws -> JPIPTCPConnection {
        guard port > 0 && port <= 65535 else {
            throw J2KError.invalidParameter("Invalid remote TCP port: \(port)")
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
                Self.configureSocket(sock, timeoutSeconds: timeoutSeconds)
                let rc = DarwinOrGlibcConnect(sock, info.pointee.ai_addr, info.pointee.ai_addrlen)
                if rc == 0 {
                    return JPIPTCPConnection(connectedFD: sock, timeoutSeconds: timeoutSeconds)
                }
                lastErrno = currentPOSIXErrno()
                posixCloseSocket(sock)
            } else {
                lastErrno = currentPOSIXErrno()
            }
            infoPtr = info.pointee.ai_next
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

    private static func configureSocket(_ sock: Int32, timeoutSeconds: Int) {
        var one: Int32 = 1
        _ = setsockopt(sock, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        _ = setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        if timeoutSeconds > 0 {
            var tv = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
            _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    package func setReceiveTimeout(seconds: Int) {
        fdLock.lock()
        let sock = fd
        fdLock.unlock()
        guard sock >= 0 else { return }
        var tv = timeval(tv_sec: max(0, seconds), tv_usec: 0)
        _ = setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
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
                readBuffer.removeAll(keepingCapacity: true)
                readOffset = 0
            } else if readOffset >= 16384 {
                readBuffer.removeFirst(readOffset)
                readOffset = 0
            }
        }
    }

    private func fillOnceLocked() throws -> Int {
        let sock = try currentFD()
        var scratch = [UInt8](repeating: 0, count: 16384)
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

        while (readBuffer.count - readOffset) < count {
            let got = try fillOnceLocked()
            if got == 0 {
                throw J2KError.networkError("Unexpected EOF while reading \(count) bytes (have \(readBuffer.count - readOffset)).")
            }
        }
        let slice = Data(readBuffer[readOffset..<(readOffset + count)])
        readOffset += count
        compactReadBufferLocked()
        return slice
    }

    private func readToEOF(maxAllowedBytes: Int) throws -> Data {
        readLock.lock()
        defer { readLock.unlock() }

        while true {
            let buffered = readBuffer.count - readOffset
            if buffered > maxAllowedBytes {
                throw CodecError(.resourceLimitExceeded, "EOF-delimited HTTP body exceeds limit (\(maxAllowedBytes) bytes).")
            }
            let got = try fillOnceLocked()
            if got == 0 { break }
        }
        let buffered = readBuffer.count - readOffset
        guard buffered <= maxAllowedBytes else {
            throw CodecError(.resourceLimitExceeded, "EOF-delimited HTTP body (\(buffered) bytes) exceeds limit (\(maxAllowedBytes) bytes).")
        }
        let out = Data(readBuffer[readOffset..<readBuffer.count])
        readOffset = readBuffer.count
        compactReadBufferLocked()
        return out
    }

    private func readLineCRLFLocked(maxLineBytes: Int) throws -> String {
        while true {
            let available = readBuffer.count - readOffset
            if available > 0 {
                for idx in readOffset..<readBuffer.count where readBuffer[idx] == 0x0A {
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
            let got = try fillOnceLocked()
            if got == 0 {
                throw J2KError.networkError("Unexpected EOF while reading HTTP line.")
            }
        }
    }

    /// Reads until `\r\n\r\n` (or `\n\n`). Returns `nil` cleanly on immediate EOF before any byte.
    private func readHeaderBlockLocked(maxHeaderBytes: Int) throws -> [UInt8]? {
        while true {
            let available = readBuffer.count - readOffset
            if available >= 2 {
                var i = readOffset
                while i < readBuffer.count {
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
            }
            if available > maxHeaderBytes {
                throw CodecError(.resourceLimitExceeded, "HTTP header block exceeds \(maxHeaderBytes) bytes.")
            }
            let got = try fillOnceLocked()
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
            while (readBuffer.count - readOffset) < chunkSize {
                let got = try fillOnceLocked()
                if got == 0 {
                    throw J2KError.networkError("Unexpected EOF inside HTTP chunk payload.")
                }
            }
            out.append(contentsOf: readBuffer[readOffset..<(readOffset + chunkSize)])
            readOffset += chunkSize
            compactReadBufferLocked()
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
        maxBodyBytes: Int = 128 * 1024 * 1024
    ) throws -> JPIPHTTPWireResponse {
        readLock.lock()
        var unlocked = false
        defer { if !unlocked { readLock.unlock() } }

        guard let headerBytes = try readHeaderBlockLocked(maxHeaderBytes: maxHeaderBytes) else {
            throw J2KError.networkError("Server closed connection before sending HTTP response headers.")
        }
        guard let headerText = String(bytes: headerBytes, encoding: .utf8) ?? String(bytes: headerBytes, encoding: .isoLatin1) else {
            throw J2KError.invalidData("Malformed HTTP response header encoding.")
        }
        let rawLines = headerText.components(separatedBy: "\n").map {
            $0.hasSuffix("\r") ? String($0.dropLast()) : $0
        }
        guard let statusLine = rawLines.first, !statusLine.isEmpty else {
            throw J2KError.invalidData("Empty HTTP status line.")
        }
        let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, let code = Int(parts[1]) else {
            throw J2KError.invalidData("Malformed HTTP status line '\(statusLine)'.")
        }
        let version = String(parts[0])
        let reason = parts.count >= 3 ? String(parts[2]) : ""

        var headers: [String: String] = [:]
        for line in rawLines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let val = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if let existing = headers[key] {
                headers[key] = "\(existing), \(val)"
            } else {
                headers[key] = val
            }
        }

        if code == 101 || code == 204 || code == 304 {
            return JPIPHTTPWireResponse(version: version, statusCode: code, reasonPhrase: reason, headers: headers, body: Data())
        }

        let te = headers.first { $0.key.lowercased() == "transfer-encoding" }?.value.lowercased() ?? ""
        if te.contains("chunked") {
            let body = try readChunkedBodyLocked(maxBodyBytes: maxBodyBytes)
            return JPIPHTTPWireResponse(version: version, statusCode: code, reasonPhrase: reason, headers: headers, body: body)
        }

        if let clStr = headers.first(where: { $0.key.lowercased() == "content-length" })?.value {
            guard let cl = Int(clStr.trimmingCharacters(in: .whitespaces)), cl >= 0 else {
                throw J2KError.invalidData("Invalid Content-Length '\(clStr)'.")
            }
            unlocked = true
            readLock.unlock()
            let body = try readExact(count: cl, maxAllowedBytes: maxBodyBytes)
            return JPIPHTTPWireResponse(version: version, statusCode: code, reasonPhrase: reason, headers: headers, body: body)
        }

        // Connection: close EOF-delimited body
        unlocked = true
        readLock.unlock()
        let body = try readToEOF(maxAllowedBytes: maxBodyBytes)
        return JPIPHTTPWireResponse(version: version, statusCode: code, reasonPhrase: reason, headers: headers, body: body)
    }

    // MARK: - RFC 6455 WebSocket Handshake & Framing

    package func performWebSocketClientHandshake(
        pathAndQuery: String,
        hostHeader: String,
        subprotocol: String = "jpip"
    ) throws -> String? {
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
        let resp = try readHTTPResponse()
        guard resp.statusCode == 101 else {
            throw J2KError.networkError("WebSocket upgrade rejected with HTTP \(resp.statusCode)")
        }
        guard resp.header("Upgrade")?.lowercased() == "websocket",
              let accept = resp.header("Sec-WebSocket-Accept"),
              accept.trimmingCharacters(in: .whitespaces) == expectedAccept else {
            throw J2KError.invalidData("RFC 6455 Sec-WebSocket-Accept verification failed.")
        }
        return resp.header("Sec-WebSocket-Protocol")
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

    /// Reads one complete RFC 6455 message (assembling fragmented `FIN=0` continuation frames,
    /// while returning control frames `ping`/`pong`/`close` immediately).
    package func readWebSocketFrame(
        maxFrameBytes: Int = 64 * 1024 * 1024,
        requireMasked: Bool? = nil
    ) throws -> JPIPRFC6455WireFrame {
        var assembledOpcode: JPIPRFC6455Opcode?
        var assembledPayload = Data()

        while true {
            let hdr2 = try readExact(count: 2)
            let b0 = hdr2[hdr2.startIndex]
            let b1 = hdr2[hdr2.startIndex + 1]
            let fin = (b0 & 0x80) != 0
            let rsv = (b0 & 0x70)
            guard rsv == 0 else {
                throw J2KError.invalidData("RFC 6455 RSV bits must be 0 when no extension is negotiated.")
            }
            let rawOp = b0 & 0x0F
            guard let opcode = JPIPRFC6455Opcode(rawValue: rawOp) else {
                throw J2KError.invalidData("Unsupported RFC 6455 opcode 0x\(String(rawOp, radix: 16)).")
            }

            let isMasked = (b1 & 0x80) != 0
            if let reqMask = requireMasked, isMasked != reqMask {
                throw J2KError.invalidData("RFC 6455 masking requirement violated (masked=\(isMasked), expected=\(reqMask)).")
            }

            let len7 = Int(b1 & 0x7F)
            let payloadLen: Int
            if len7 < 126 {
                payloadLen = len7
            } else if len7 == 126 {
                let ext = try readExact(count: 2)
                payloadLen = (Int(ext[ext.startIndex]) << 8) | Int(ext[ext.startIndex + 1])
            } else {
                let ext = try readExact(count: 8)
                var u64: UInt64 = 0
                for idx in ext.indices {
                    u64 = (u64 << 8) | UInt64(ext[idx])
                }
                guard (u64 & (1 << 63)) == 0, u64 <= UInt64(maxFrameBytes) else {
                    throw CodecError(.resourceLimitExceeded, "RFC 6455 frame length \(u64) exceeds limit (\(maxFrameBytes)).")
                }
                payloadLen = Int(u64)
            }

            // Control frames (0x8..0xF) must not exceed 125 bytes and must not be fragmented.
            if rawOp >= 0x8 {
                guard fin, payloadLen <= 125 else {
                    throw J2KError.invalidData("RFC 6455 control frame must have FIN=1 and length <= 125.")
                }
            }

            let (nextTotal, ov) = assembledPayload.count.addingReportingOverflow(payloadLen)
            guard !ov, nextTotal <= maxFrameBytes else {
                throw CodecError(.resourceLimitExceeded, "RFC 6455 message exceeds limit (\(maxFrameBytes) bytes).")
            }

            let maskKey = isMasked ? [UInt8](try readExact(count: 4)) : []
            var chunk = try readExact(count: payloadLen, maxAllowedBytes: maxFrameBytes)
            if isMasked && !chunk.isEmpty {
                var arr = [UInt8](chunk)
                for i in 0..<arr.count {
                    arr[i] ^= maskKey[i & 3]
                }
                chunk = Data(arr)
            }

            if rawOp >= 0x8 {
                return JPIPRFC6455WireFrame(fin: true, opcode: opcode, payload: chunk)
            }

            if opcode == .continuation {
                guard assembledOpcode != nil else {
                    throw J2KError.invalidData("Unexpected RFC 6455 continuation frame without initial data frame.")
                }
                assembledPayload.append(chunk)
            } else {
                guard assembledOpcode == nil else {
                    throw J2KError.invalidData("New RFC 6455 data frame started before fragmented message finished.")
                }
                assembledOpcode = opcode
                assembledPayload = chunk
            }

            if fin, let finalOpcode = assembledOpcode {
                return JPIPRFC6455WireFrame(fin: true, opcode: finalOpcode, payload: assembledPayload)
            }
        }
    }
}
