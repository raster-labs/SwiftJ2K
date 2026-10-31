// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJ2KJPIP

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@Suite("R3 incremental HTTP delimiter scans")
struct CodexR3HTTPDelimiterTests {
    @Test func headerDelimitersSurviveEveryTrailingFragmentBoundary() async throws {
        for newline in ["\r\n", "\n"] {
            let header = Data(("HTTP/1.1 200 OK" + newline + "Content-Length: 1" + newline
                + "X-Probe: a\rb" + newline + newline).utf8)
            // Split before and inside every final delimiter byte. The reader's
            // one-byte admitted fills also force every possible byte boundary.
            for tailBytes in 0...(newline.utf8.count * 2) {
                let (reader, writer) = try socketPair()
                defer { reader.close(); writer.close() }
                let (response, following) = try await exchange(
                    [Data(header.dropLast(tailBytes)), Data(header.suffix(tailBytes)), Data([0x5A, 0x51])],
                    reader: reader, writer: writer) {
                        let response = try reader.readHTTPResponse(maxHeaderBytes: header.count,
                            maxBodyBytes: 1, maximumStorageBytes: 65_536)
                        return (response, try reader.readExact(count: 1))
                    }
                #expect(response.statusCode == 200)
                #expect(response.header("X-Probe") == "a\rb")
                #expect(response.body == Data([0x5A]))
                // The delimiter neither consumes body bytes nor the next item.
                #expect(following == Data([0x51]))
                #expect(reader.httpDelimiterScanWork.headerPositions <= 4 * header.count)
            }
        }
    }

    @Test func headerScanWorkRemainsLinearAsInputQuadruples() async throws {
        for valueBytes in [1024, 4096, 16_384] {
            let (reader, writer) = try socketPair()
            defer { reader.close(); writer.close() }
            let header = Data(("HTTP/1.1 204 No Content\r\nX-Padding: "
                + String(repeating: "x", count: valueBytes) + "\r\n\r\n").utf8)
            let response = try await exchange([header], reader: reader, writer: writer) {
                try reader.readHTTPResponse(maxBodyBytes: 0, maximumStorageBytes: 1_048_576)
            }
            #expect(response.statusCode == 204)
            #expect(response.header("X-Padding")?.utf8.count == valueBytes)
            let work = reader.httpDelimiterScanWork
            // Count actual candidate positions examined by the socket helper.
            // The old full-prefix rescans require roughly n*n/2 positions.
            #expect(work.headerPositions >= header.count - 4)
            #expect(work.headerPositions <= 4 * header.count)
            #expect(work.lineBytes == 0)
        }
    }

    @Test func chunkLineScanVisitsEachByteOnceAndPreservesLineEndings() async throws {
        for newline in ["\r\n", "\n"] {
            for extensionBytes in [128, 512, 2048] {
                let (reader, writer) = try socketPair()
                defer { reader.close(); writer.close() }
                let header = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
                let sizeLine = "1;" + String(repeating: "e", count: extensionBytes) + newline
                let zeroLine = "0" + newline
                let trailer = "X-Trailer: " + String(repeating: "t", count: extensionBytes) + newline
                let lines = sizeLine + "Z\r\n" + zeroLine + trailer + newline
                let response = try await exchange([Data((header + lines).utf8)], reader: reader, writer: writer) {
                    try reader.readHTTPResponse(maxBodyBytes: 1, maximumStorageBytes: 1_048_576)
                }
                #expect(response.body == Data([0x5A]))
                let expectedLineBytes = sizeLine.utf8.count + zeroLine.utf8.count
                    + trailer.utf8.count + newline.utf8.count
                #expect(reader.httpDelimiterScanWork.lineBytes == expectedLineBytes)
            }
        }
    }

    @Test func twoThousandHeaderHandshakeHasLinearDelimiterWork() async throws {
        let (reader, writer) = try socketPair()
        defer { reader.close(); writer.close() }
        var text = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
        for index in 0..<2000 { text += "X-\(index): 0\r\n" }
        let header = Data((text + "\r\n").utf8)
        let response = try await exchange([header], reader: reader, writer: writer) {
            try reader.readHTTPResponse(maxBodyBytes: 0, maximumStorageBytes: 1_048_576)
        }
        #expect(response.statusCode == 101)
        #expect(response.headers.count == 2001)
        #expect(response.body.isEmpty)
        #expect(reader.httpDelimiterScanWork.headerPositions <= 4 * header.count)
    }

    @Test func headerAndChunkCapsStillRejectBeforeAnAbsentBodyRead() async throws {
        do {
            let (reader, writer) = try socketPair()
            defer { reader.close(); writer.close() }
            // No delimiter and no body: the extra byte must trigger admission,
            // rather than another recv which would wait for an absent payload.
            do {
                _ = try await exchange([Data(repeating: 0x41, count: 33)], reader: reader, writer: writer) {
                    try reader.readHTTPResponse(maxHeaderBytes: 32, maxBodyBytes: 1,
                        maximumStorageBytes: 65_536)
                }
                Issue.record("Expected header cap rejection")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
                #expect(error.message.contains("HTTP header block"))
            }
            #expect(reader.httpDelimiterScanWork.headerPositions <= 4 * 33)
        }
        for accepted in [true, false] {
            let (reader, writer) = try socketPair()
            defer { reader.close(); writer.close() }
            let header = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
            // Existing line cap counts bytes before LF, including a preceding CR.
            let extensionBytes = accepted ? 4093 : 4095
            let prefix = "1;" + String(repeating: "e", count: extensionBytes)
            let suffix = accepted ? "\r\nZ\r\n0\r\n\r\n" : ""
            let wire = Data((header + prefix + suffix).utf8)
            if accepted {
                let response = try await exchange([wire], reader: reader, writer: writer) {
                    try reader.readHTTPResponse(maxBodyBytes: 1, maximumStorageBytes: 1_048_576)
                }
                #expect(response.body == Data([0x5A]))
                #expect(reader.httpDelimiterScanWork.lineBytes == 4097 + 3 + 2)
            } else {
                do {
                    _ = try await exchange([wire], reader: reader, writer: writer) {
                        try reader.readHTTPResponse(maxBodyBytes: 1, maximumStorageBytes: 1_048_576)
                    }
                    Issue.record("Expected chunk line cap rejection")
                } catch let error as CodecError {
                    #expect(error.category == .resourceLimitExceeded)
                    #expect(error.message.contains("HTTP line exceeds"))
                }
                #expect(reader.httpDelimiterScanWork.lineBytes == 4097)
            }
        }
    }

    @Test func immediateAndTruncatedHeaderEOFRemainDistinct() async throws {
        do {
            let (reader, writer) = try socketPair()
            defer { reader.close() }
            let request = try await exchange([], reader: reader, writer: writer, closeAfterWrite: true) {
                try reader.readHTTPRequest()
            }
            #expect(request == nil)
        }
        do {
            let (reader, writer) = try socketPair()
            defer { reader.close() }
            await #expect(throws: J2KError.self) {
                _ = try await exchange([Data("GET / HTTP/1.1\r\nX: y\r\n\r".utf8)],
                    reader: reader, writer: writer, closeAfterWrite: true) {
                        try reader.readHTTPRequest()
                    }
            }
        }
    }

    /// Both blocking sides run on dedicated workers. A large fixture cannot
    /// fill the socket before the reader is started, or occupy a Swift executor
    /// while waiting for its peer. Every exit acknowledges writer completion.
    private func exchange<Value: Sendable>(
        _ fragments: [Data], reader: JPIPTCPConnection, writer: JPIPTCPConnection,
        closeAfterWrite: Bool = false, read: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let finished = AsyncStream<Result<Void, any Error>>(bufferingPolicy: .bufferingNewest(1)) { completion in
            Thread.detachNewThread {
                let result = Result<Void, any Error> {
                    for fragment in fragments { try writer.writeAll(fragment) }
                    if closeAfterWrite { writer.close() }
                }
                completion.yield(result)
                completion.finish()
            }
        }
        do {
            let value = try await JPIPBlockingWorker.run(read)
            for await result in finished { try result.get() }
            return value
        } catch {
            reader.close()
            writer.close()
            for await _ in finished { }
            throw error
        }
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
        guard result == 0 else { throw J2KError.networkError("Could not create delimiter-test socket pair") }
        return (JPIPTCPConnection(connectedFD: descriptors[0], timeoutSeconds: 1),
                JPIPTCPConnection(connectedFD: descriptors[1], timeoutSeconds: 1))
    }
}
