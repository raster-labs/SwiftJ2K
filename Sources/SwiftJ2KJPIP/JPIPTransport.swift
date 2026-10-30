// SPDX-License-Identifier: Apache-2.0
//
// JPIPTransport.swift
// SwiftJ2KJPIP
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/JPIP/JPIPTransport.swift
//
// Re-engineered in Phase R3 (F04) to perform real persistent HTTP/1.1 TCP
// socket framing (`Content-Length` and `Transfer-Encoding: chunked`) without
// in-process loopback registry shortcuts.

import Foundation
import Dispatch
@_exported import SwiftJ2K
@_exported import SwiftJ2K3D

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP/1.1 transport for JPIP requests over real TCP sockets (and `URLSession` for HTTPS).
public actor JPIPTransport {
    /// The base server URL.
    private let baseURL: URL

    /// The URL session used only for `https://` TLS requests.
    private let session: URLSession

    /// Optional directly injected in-process server (explicit test/embedded binding only).
    private let boundServer: JPIPServer?

    /// Persistent HTTP/1.1 TCP socket connection for `http://` targets.
    private var tcpConnection: JPIPTCPConnection?

    /// Request timeout interval in seconds (supports sub-second deadlines).
    private let timeoutInterval: TimeInterval

    /// Optional channel path negotiated via `JPIP-cnew` (`path=...`).
    private var channelPathOverride: String?

    /// Creates a new JPIP transport targeting a remote or loopback HTTP(S) URL.
    ///
    /// - Parameters:
    ///   - baseURL: The base URL of the JPIP server.
    ///   - configuration: Optional URL session configuration (used for `https://` and socket timeout).
    public init(baseURL: URL, configuration: URLSessionConfiguration? = nil) {
        self.baseURL = baseURL
        let config = configuration ?? URLSessionConfiguration.ephemeral
        let reqTimeout = config.timeoutIntervalForRequest > 0 ? config.timeoutIntervalForRequest : 30.0
        config.timeoutIntervalForRequest = reqTimeout
        config.timeoutIntervalForResource = max(reqTimeout, 300.0)
        self.timeoutInterval = max(0.001, reqTimeout)
        self.session = URLSession(configuration: config)
        self.boundServer = nil
        self.tcpConnection = nil
        self.channelPathOverride = nil
    }

    /// Creates a new JPIP transport bound explicitly to an injected ``JPIPServer`` actor.
    ///
    /// - Parameter server: The injected JPIP server actor.
    public init(server: JPIPServer) {
        self.baseURL = URL(string: "http://127.0.0.1:\(max(1, server.port))")!
        self.timeoutInterval = 30.0
        self.session = URLSession(configuration: .ephemeral)
        self.boundServer = server
        self.tcpConnection = nil
        self.channelPathOverride = nil
    }

    /// Updates the HTTP request path negotiated by a `JPIP-cnew` response (`path=...`).
    public func setChannelPath(_ path: String?) {
        if let path, !path.isEmpty {
            self.channelPathOverride = path.hasPrefix("/") ? path : "/\(path)"
        } else {
            self.channelPathOverride = nil
        }
    }

    /// Returns the currently negotiated channel request path, if any.
    public func getChannelPath() -> String? {
        channelPathOverride
    }

    /// Sends a JPIP request to the server.
    ///
    /// - Parameters:
    ///   - request: The JPIP request to send.
    ///   - maxBodyBytes: Maximum permitted compressed response payload in bytes.
    /// - Returns: The JPIP response.
    /// - Throws: ``J2KError`` or ``CodecError`` if transport or framing fails.
    public func send(
        _ request: JPIPRequest,
        maxBodyBytes: Int = 128 * 1024 * 1024
    ) async throws -> JPIPResponse {
        try Task.checkCancellation()

        // 1. Explicit actor injection (only when constructed via `init(server:)`)
        if let server = boundServer {
            let response = try await server.handleRequest(request)
            guard (200..<300).contains(response.statusCode) else {
                throw J2KError.networkError("HTTP error: \(response.statusCode)")
            }
            if response.data.count > maxBodyBytes {
                throw CodecError(
                    .resourceLimitExceeded,
                    "JPIP response payload (\(response.data.count) bytes) exceeds limit (\(maxBodyBytes) bytes)."
                )
            }
            if let negotiatedPath = JPIPResponseParser.extractChannelPath(from: response.headers) {
                setChannelPath(negotiatedPath)
            }
            return response
        }

        let scheme = baseURL.scheme?.lowercased() ?? "http"
        if scheme == "https" {
            return try await sendViaHTTPS(request, maxBodyBytes: maxBodyBytes)
        }
        guard scheme == "http" else {
            throw J2KError.invalidParameter("Unsupported JPIP HTTP URL scheme '\(scheme)'.")
        }

        return try await sendViaHTTP11TCP(request, maxBodyBytes: maxBodyBytes)
    }

    // MARK: - Real POSIX TCP HTTP/1.1 Transport (Off Cooperative Pool + Cancellation Safe)

    private func sendViaHTTP11TCP(
        _ request: JPIPRequest,
        maxBodyBytes: Int
    ) async throws -> JPIPResponse {
        guard let host = baseURL.host, !host.isEmpty else {
            throw J2KError.invalidParameter("Invalid JPIP base URL (missing host): \(baseURL)")
        }
        let port = baseURL.port ?? 80
        let hostHeader = (baseURL.port != nil) ? "\(host):\(port)" : host
        let pathAndQuery = buildPathAndQuery(from: request)

        let reqHeaders: [String: String] = [
            "Accept": "image/jpp-stream, image/jpt-stream, application/octet-stream, */*",
            "User-Agent": "SwiftJ2KJPIP/0.5.0",
            "Connection": "keep-alive"
        ]

        let existingConn: JPIPTCPConnection?
        if let existing = tcpConnection, existing.isOpen {
            existingConn = existing
            // Detach while off-pool I/O executes so concurrent actor messages or cancellation never double-use it
            self.tcpConnection = nil
        } else {
            existingConn = nil
        }

        let timeout = self.timeoutInterval
        let cancelToken = JPIPSocketCancellationToken()
        if let existingConn, !cancelToken.bind(connection: existingConn) {
            existingConn.close()
            throw CancellationError()
        }

        let (wireResponse, survivingConnection): (JPIPHTTPWireResponse, JPIPTCPConnection)
        do {
            (wireResponse, survivingConnection) = try await withTaskCancellationHandler {
                try await Self.executeHTTP11OffPool(
                    host: host,
                    port: port,
                    timeoutInterval: timeout,
                    existingConnection: existingConn,
                    pathAndQuery: pathAndQuery,
                    hostHeader: hostHeader,
                    headers: reqHeaders,
                    maxBodyBytes: maxBodyBytes,
                    cancelToken: cancelToken
                )
            } onCancel: {
                cancelToken.cancel()
            }
        } catch {
            if Task.isCancelled || cancelToken.cancelled {
                throw CancellationError()
            }
            throw error
        }

        try Task.checkCancellation()

        // Respect `Connection: close` or HTTP/1.0 non-keep-alive peers (e.g., single-shot daemons)
        let connHdr = wireResponse.header("Connection")?.lowercased() ?? ""
        if connHdr.contains("close") || (wireResponse.version == "HTTP/1.0" && !connHdr.contains("keep-alive")) {
            survivingConnection.close()
            self.tcpConnection = nil
        } else {
            self.tcpConnection = survivingConnection
        }

        guard (200..<300).contains(wireResponse.statusCode) else {
            let detail = String(data: wireResponse.body.prefix(256), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if detail.isEmpty {
                throw J2KError.networkError("HTTP error: \(wireResponse.statusCode)")
            }
            throw J2KError.networkError("HTTP error: \(wireResponse.statusCode) (\(detail))")
        }

        let channelID = JPIPResponseParser.extractChannelID(from: wireResponse.headers)
        if let negotiatedPath = JPIPResponseParser.extractChannelPath(from: wireResponse.headers) {
            setChannelPath(negotiatedPath)
        }

        return JPIPResponse(
            channelID: channelID,
            data: wireResponse.body,
            statusCode: wireResponse.statusCode,
            headers: wireResponse.headers
        )
    }

    nonisolated private static func executeHTTP11OffPool(
        host: String,
        port: Int,
        timeoutInterval: TimeInterval,
        existingConnection: JPIPTCPConnection?,
        pathAndQuery: String,
        hostHeader: String,
        headers: [String: String],
        maxBodyBytes: Int,
        cancelToken: JPIPSocketCancellationToken
    ) async throws -> (JPIPHTTPWireResponse, JPIPTCPConnection) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                if cancelToken.cancelled {
                    existingConnection?.close()
                    continuation.resume(throwing: CancellationError())
                    return
                }

                let hadExisting = (existingConnection != nil)
                let conn: JPIPTCPConnection
                do {
                    if let existingConnection {
                        existingConnection.setReceiveTimeout(interval: timeoutInterval)
                        existingConnection.setSendTimeout(interval: timeoutInterval)
                        conn = existingConnection
                    } else {
                        conn = try JPIPTCPConnection.connect(
                            host: host,
                            port: port,
                            timeoutInterval: timeoutInterval,
                            cancellationToken: cancelToken
                        )
                    }
                } catch {
                    continuation.resume(throwing: cancelToken.cancelled ? CancellationError() : error)
                    return
                }

                do {
                    try conn.writeHTTPRequest(
                        method: "GET",
                        pathAndQuery: pathAndQuery,
                        hostHeader: hostHeader,
                        headers: headers
                    )
                    let resp = try conn.readHTTPResponse(maxBodyBytes: maxBodyBytes)
                    if cancelToken.cancelled {
                        conn.close()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    continuation.resume(returning: (resp, conn))
                } catch let limitErr as CodecError {
                    conn.close()
                    continuation.resume(throwing: cancelToken.cancelled ? CancellationError() : limitErr)
                } catch {
                    conn.close()
                    if cancelToken.cancelled || !hadExisting {
                        continuation.resume(throwing: cancelToken.cancelled ? CancellationError() : error)
                        return
                    }
                    // Stale idle keep-alive socket broke on server side: reconnect once cleanly
                    do {
                        let retryConn = try JPIPTCPConnection.connect(
                            host: host,
                            port: port,
                            timeoutInterval: timeoutInterval,
                            cancellationToken: cancelToken
                        )
                        do {
                            try retryConn.writeHTTPRequest(
                                method: "GET",
                                pathAndQuery: pathAndQuery,
                                hostHeader: hostHeader,
                                headers: headers
                            )
                            let resp = try retryConn.readHTTPResponse(maxBodyBytes: maxBodyBytes)
                            if cancelToken.cancelled {
                                retryConn.close()
                                continuation.resume(throwing: CancellationError())
                                return
                            }
                            continuation.resume(returning: (resp, retryConn))
                        } catch {
                            retryConn.close()
                            continuation.resume(throwing: cancelToken.cancelled ? CancellationError() : error)
                        }
                    } catch {
                        continuation.resume(throwing: cancelToken.cancelled ? CancellationError() : error)
                    }
                }
            }
        }
    }

    // MARK: - HTTPS Fallback via URLSession (Streaming Pre-Buffer Limit Enforcement)

    private func sendViaHTTPS(
        _ request: JPIPRequest,
        maxBodyBytes: Int
    ) async throws -> JPIPResponse {
        let pathAndQuery = buildPathAndQuery(from: request)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            throw J2KError.invalidParameter("Invalid base URL")
        }
        let split = pathAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        components.percentEncodedPath = String(split[0])
        components.percentEncodedQuery = split.count > 1 ? String(split[1]) : nil
        guard let url = components.url else {
            throw J2KError.invalidParameter("Failed to build HTTPS JPIP request URL")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue(
            "image/jpp-stream, image/jpt-stream, application/octet-stream, */*",
            forHTTPHeaderField: "Accept"
        )

        let (asyncBytes, response) = try await session.bytes(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw J2KError.networkError("Invalid response type")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw J2KError.networkError("HTTP error: \(httpResponse.statusCode)")
        }

        let headers = JPIPResponseParser.parseHeaders(from: httpResponse)
        if httpResponse.expectedContentLength > 0,
           httpResponse.expectedContentLength > Int64(maxBodyBytes) {
            throw CodecError(
                .resourceLimitExceeded,
                "JPIP HTTPS Content-Length (\(httpResponse.expectedContentLength) bytes) exceeds limit (\(maxBodyBytes) bytes)."
            )
        }
        if let clRaw = headers.first(where: { $0.key.lowercased() == "content-length" })?.value
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let declaredLen = Int(clRaw),
           declaredLen > maxBodyBytes {
            throw CodecError(
                .resourceLimitExceeded,
                "JPIP HTTPS Content-Length (\(declaredLen) bytes) exceeds limit (\(maxBodyBytes) bytes)."
            )
        }

        let initialCap: Int
        if httpResponse.expectedContentLength > 0 {
            initialCap = min(maxBodyBytes, Int(clamping: httpResponse.expectedContentLength))
        } else {
            initialCap = min(maxBodyBytes, 64 * 1024)
        }
        var data = Data()
        data.reserveCapacity(max(0, initialCap))

        for try await byte in asyncBytes {
            if (data.count & 0x3FFF) == 0 {
                try Task.checkCancellation()
            }
            if data.count >= maxBodyBytes {
                throw CodecError(
                    .resourceLimitExceeded,
                    "JPIP HTTPS response payload exceeds limit (\(maxBodyBytes) bytes)."
                )
            }
            data.append(byte)
        }

        let channelID = JPIPResponseParser.extractChannelID(from: headers)
        if let negotiatedPath = JPIPResponseParser.extractChannelPath(from: headers) {
            setChannelPath(negotiatedPath)
        }

        return JPIPResponse(
            channelID: channelID,
            data: data,
            statusCode: httpResponse.statusCode,
            headers: headers
        )
    }

    // MARK: - Normative JPIP Path & Query Formatting

    package func buildPathAndQuery(from request: JPIPRequest) -> String {
        let basePath = (baseURL.path.isEmpty || baseURL.path == "/") ? "/jpip" : baseURL.path
        let effectivePath: String
        if request.cid != nil, request.cnew == nil, let chPath = channelPathOverride, !chPath.isEmpty {
            effectivePath = chPath.hasPrefix("/") ? chPath : "/\(chPath)"
        } else {
            effectivePath = basePath
        }

        var effectiveRequest = request
        // Per ITU-T Rec. T.808 Clause C.2.1, once a stateful channel (`cid`) is active
        // and `cnew` is not requested, the target is implicitly bound to the channel
        // (`kdu_server` rejects redundant `target=` on `/jpip?cid=...`).
        if effectiveRequest.cid != nil && effectiveRequest.cnew == nil {
            effectiveRequest.target = ""
        }

        let items = effectiveRequest.buildQueryItems()
        guard !items.isEmpty else {
            return effectivePath
        }

        // Deterministic ordering (`target`, `tid`, `cid`, `cnew`, `cclose`, 2D/3D view-window, `type`, `len`, `model`)
        let preferredOrder = [
            "target", "tid", "cid", "cnew", "cclose",
            "fsiz", "roff", "rsiz", "fvsiz", "rvoff", "rvsiz", "zoff", "zsiz",
            "comps", "layers", "reslevels",
            "type", "len", "model", "meta", "pref"
        ]
        var orderedKeys: [String] = []
        for k in preferredOrder where items[k] != nil {
            orderedKeys.append(k)
        }
        for k in items.keys.sorted() where !orderedKeys.contains(k) {
            orderedKeys.append(k)
        }

        let query = orderedKeys.compactMap { key -> String? in
            guard let val = items[key] else { return nil }
            return "\(Self.encodeJPIPQueryToken(key))=\(Self.encodeJPIPQueryToken(val))"
        }.joined(separator: "&")

        return query.isEmpty ? effectivePath : "\(effectivePath)?\(query)"
    }

    /// Encodes a JPIP query token while preserving ITU-T T.808 sub-delimiters (`,`, `:`, `*`, `-`, `/`, `.`, `_`, `~`)
    /// required literally by `kdu_server` and `libopenjpip` query parsers.
    package static func encodeJPIPQueryToken(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~,:*/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Closes the transport and cleans up resources.
    public func close() {
        tcpConnection?.close()
        tcpConnection = nil
        channelPathOverride = nil
        session.finishTasksAndInvalidate()
    }
}

extension J2KError {
    /// Creates a network error.
    static func networkError(_ message: String) -> J2KError {
        .internalError("Network error: \(message)")
    }
}
