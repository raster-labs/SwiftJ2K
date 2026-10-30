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

    /// Request timeout in seconds.
    private let timeoutSeconds: Int

    /// Optional channel path negotiated via `JPIP-cnew` (`path=...`).
    private var channelPathOverride: String?

    /// Creates a new JPIP transport targeting a remote or loopback HTTP(S) URL.
    ///
    /// - Parameters:
    ///   - baseURL: The base URL of the JPIP server.
    ///   - configuration: Optional URL session configuration (used for `https://`).
    public init(baseURL: URL, configuration: URLSessionConfiguration? = nil) {
        self.baseURL = baseURL
        let config = configuration ?? URLSessionConfiguration.ephemeral
        let reqTimeout = config.timeoutIntervalForRequest > 0 ? config.timeoutIntervalForRequest : 30
        config.timeoutIntervalForRequest = reqTimeout
        config.timeoutIntervalForResource = max(reqTimeout, 300)
        self.timeoutSeconds = max(1, Int(reqTimeout.rounded(.up)))
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
        self.timeoutSeconds = 30
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

    // MARK: - Real POSIX TCP HTTP/1.1 Transport

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

        // Attempt on existing persistent keep-alive socket first; if a stale socket
        // broke after server-side idle close, reconnect once cleanly.
        var hadExistingConnection = false
        let conn: JPIPTCPConnection
        if let existing = tcpConnection, existing.isOpen {
            conn = existing
            hadExistingConnection = true
        } else {
            let fresh = try JPIPTCPConnection.connect(host: host, port: port, timeoutSeconds: timeoutSeconds)
            self.tcpConnection = fresh
            conn = fresh
        }

        let wireResponse: JPIPHTTPWireResponse
        do {
            try conn.writeHTTPRequest(
                method: "GET",
                pathAndQuery: pathAndQuery,
                hostHeader: hostHeader,
                headers: reqHeaders
            )
            wireResponse = try conn.readHTTPResponse(maxBodyBytes: maxBodyBytes)
        } catch let limitErr as CodecError {
            conn.close()
            self.tcpConnection = nil
            throw limitErr
        } catch {
            conn.close()
            self.tcpConnection = nil
            guard hadExistingConnection else {
                throw error
            }
            let retryConn = try JPIPTCPConnection.connect(host: host, port: port, timeoutSeconds: timeoutSeconds)
            self.tcpConnection = retryConn
            do {
                try retryConn.writeHTTPRequest(
                    method: "GET",
                    pathAndQuery: pathAndQuery,
                    hostHeader: hostHeader,
                    headers: reqHeaders
                )
                wireResponse = try retryConn.readHTTPResponse(maxBodyBytes: maxBodyBytes)
            } catch {
                retryConn.close()
                self.tcpConnection = nil
                throw error
            }
        }

        // Respect `Connection: close` or HTTP/1.0 non-keep-alive peers (e.g., single-shot daemons)
        let connHdr = wireResponse.header("Connection")?.lowercased() ?? ""
        if connHdr.contains("close") || (wireResponse.version == "HTTP/1.0" && !connHdr.contains("keep-alive")) {
            tcpConnection?.close()
            tcpConnection = nil
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

    // MARK: - HTTPS Fallback via URLSession

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

        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw J2KError.networkError("Invalid response type")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw J2KError.networkError("HTTP error: \(httpResponse.statusCode)")
        }
        guard data.count <= maxBodyBytes else {
            throw CodecError(
                .resourceLimitExceeded,
                "JPIP HTTPS response payload (\(data.count) bytes) exceeds limit (\(maxBodyBytes) bytes)."
            )
        }

        let headers = JPIPResponseParser.parseHeaders(from: httpResponse)
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

        // Deterministic ordering (`target`, `tid`, `cid`, `cnew`, `cclose`, view-window, `type`, `len`, `model`)
        let preferredOrder = [
            "target", "tid", "cid", "cnew", "cclose",
            "fsiz", "roff", "rsiz", "zoff", "zsiz",
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
