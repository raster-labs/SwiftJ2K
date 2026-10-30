// SPDX-License-Identifier: Apache-2.0
//
// JPIPNetworkFramework.swift
// SwiftJ2KJPIP
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/JPIP/JPIPNetworkFramework.swift
//
// Reconciled in Phase R3 (F04) with declared ITU-T Rec. T.808 (12/2022) V2 profile:
// - Binary-safe HTTP/1.1 framing over TCP/TLS (preserving arbitrary VBAS bytes and
//   enforcing Content-Length / chunked boundaries without UTF-8 corruption).
// - Deterministic `CodecError(.unsupportedFeature)` rejection when ITU-T T.808 V3
//   HTTP/3 / QUIC transport (`enableHTTP3 == true`) is requested at connection time.

import Foundation
@_exported import SwiftJ2K
@_exported import SwiftJ2K3D
import Synchronization

#if canImport(Network)
import Network
#endif

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if os(iOS)
import BackgroundTasks
#endif

// MARK: - Network.framework Transport

/// Modern JPIP transport with binary-safe HTTP/1.1 framing and explicit profile validation.
@available(macOS 10.15, iOS 13.0, tvOS 13.0, *)
public actor JPIPNetworkTransport {
    /// Transport configuration.
    public struct Configuration: Sendable {
        /// Whether to enable HTTP/3 (QUIC).
        public let enableHTTP3: Bool

        /// Whether to enable TLS.
        public let enableTLS: Bool

        /// Connection timeout in seconds.
        public let connectionTimeout: TimeInterval

        /// Request timeout in seconds.
        public let requestTimeout: TimeInterval

        /// Quality of Service for network operations.
        public let qos: J2KQualityOfService

        /// Creates a new configuration.
        public init(
            enableHTTP3: Bool = true,
            enableTLS: Bool = true,
            connectionTimeout: TimeInterval = 30,
            requestTimeout: TimeInterval = 60,
            qos: J2KQualityOfService = .userInitiated
        ) {
            self.enableHTTP3 = enableHTTP3
            self.enableTLS = enableTLS
            self.connectionTimeout = connectionTimeout
            self.requestTimeout = requestTimeout
            self.qos = qos
        }
    }

    private let baseURL: URL
    private let configuration: Configuration
    private var tcpConnection: JPIPTCPConnection?
    private var httpsSession: URLSession?
    private var channelPathOverride: String?
    private var isConnected: Bool = false

    /// Creates a new Network.framework transport.
    public init(baseURL: URL, configuration: Configuration = Configuration()) {
        self.baseURL = baseURL
        self.configuration = configuration
    }

    /// Establishes a connection to the server.
    ///
    /// - Throws: ``CodecError`` (`.unsupportedFeature`) if `enableHTTP3` is enabled
    ///   (ITU-T Rec. T.808 V3 HTTP/3 / QUIC is outside the declared T.808 V2 profile),
    ///   or ``J2KError`` if TCP/TLS connection fails.
    public func connect() async throws {
        if configuration.enableHTTP3 {
            throw CodecError(
                .unsupportedFeature,
                "JPIP over HTTP/3 / QUIC (ITU-T Rec. T.808 V3) is not supported; SwiftJ2KJPIP implements ITU-T Rec. T.808 (12/2022) V2 over HTTP/1.1 and RFC 6455 WebSocket."
            )
        }
        guard !isConnected else { return }

        guard let host = baseURL.host, !host.isEmpty else {
            throw J2KError.invalidParameter("Invalid URL: no host")
        }

        if configuration.enableTLS || baseURL.scheme?.lowercased() == "https" {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = max(1, configuration.requestTimeout)
            cfg.timeoutIntervalForResource = max(1, configuration.requestTimeout * 2)
            self.httpsSession = URLSession(configuration: cfg)
            self.isConnected = true
            return
        }

        let port = baseURL.port ?? 80
        let timeoutSec = max(1, Int(configuration.connectionTimeout.rounded(.up)))
        self.tcpConnection = try JPIPTCPConnection.connect(
            host: host,
            port: port,
            timeoutSeconds: timeoutSec
        )
        self.isConnected = true
    }

    /// Sends a JPIP request over the established connection.
    public func send(
        _ request: JPIPRequest,
        maxBodyBytes: Int = 128 * 1024 * 1024
    ) async throws -> JPIPResponse {
        if configuration.enableHTTP3 {
            throw CodecError(
                .unsupportedFeature,
                "JPIP over HTTP/3 / QUIC (ITU-T Rec. T.808 V3) is not supported; SwiftJ2KJPIP implements ITU-T Rec. T.808 (12/2022) V2 over HTTP/1.1 and RFC 6455 WebSocket."
            )
        }
        guard isConnected else {
            throw J2KError.networkError("Not connected")
        }

        let pathAndQuery = buildPathAndQuery(from: request)

        if configuration.enableTLS || baseURL.scheme?.lowercased() == "https" {
            guard let session = httpsSession else {
                throw J2KError.networkError("TLS session not initialised")
            }
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
                throw J2KError.invalidParameter("Invalid base URL")
            }
            if components.scheme?.lowercased() != "https" {
                components.scheme = "https"
            }
            let split = pathAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            components.percentEncodedPath = String(split[0])
            components.percentEncodedQuery = split.count > 1 ? String(split[1]) : nil
            guard let url = components.url else {
                throw J2KError.invalidParameter("Failed to construct HTTPS JPIP URL")
            }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue(
                "image/jpp-stream, image/jpt-stream, application/octet-stream, */*",
                forHTTPHeaderField: "Accept"
            )
            let (data, resp) = try await session.data(for: req)
            guard let httpResp = resp as? HTTPURLResponse else {
                throw J2KError.networkError("Invalid HTTPS response")
            }
            guard data.count <= maxBodyBytes else {
                throw CodecError(.resourceLimitExceeded, "JPIP response exceeds \(maxBodyBytes) bytes.")
            }
            let headers = JPIPResponseParser.parseHeaders(from: httpResp)
            if let chPath = JPIPResponseParser.extractChannelPath(from: headers) {
                channelPathOverride = chPath.hasPrefix("/") ? chPath : "/\(chPath)"
            }
            return JPIPResponse(
                channelID: JPIPResponseParser.extractChannelID(from: headers),
                data: data,
                statusCode: httpResp.statusCode,
                headers: headers
            )
        }

        guard let host = baseURL.host else {
            throw J2KError.invalidParameter("Invalid URL: no host")
        }
        let port = baseURL.port ?? 80
        let hostHeader = (baseURL.port != nil) ? "\(host):\(port)" : host

        let conn: JPIPTCPConnection
        if let existing = tcpConnection, existing.isOpen {
            conn = existing
        } else {
            let timeoutSec = max(1, Int(configuration.connectionTimeout.rounded(.up)))
            let fresh = try JPIPTCPConnection.connect(host: host, port: port, timeoutSeconds: timeoutSec)
            self.tcpConnection = fresh
            conn = fresh
        }

        try conn.writeHTTPRequest(
            method: "GET",
            pathAndQuery: pathAndQuery,
            hostHeader: hostHeader,
            headers: [
                "Accept": "image/jpp-stream, image/jpt-stream, application/octet-stream, */*",
                "Connection": "keep-alive"
            ]
        )
        let wireResp = try conn.readHTTPResponse(maxBodyBytes: maxBodyBytes)
        if (wireResp.header("Connection")?.lowercased() ?? "").contains("close") {
            conn.close()
            self.tcpConnection = nil
        }
        if let chPath = JPIPResponseParser.extractChannelPath(from: wireResp.headers) {
            channelPathOverride = chPath.hasPrefix("/") ? chPath : "/\(chPath)"
        }
        return JPIPResponse(
            channelID: JPIPResponseParser.extractChannelID(from: wireResp.headers),
            data: wireResp.body,
            statusCode: wireResp.statusCode,
            headers: wireResp.headers
        )
    }

    private func buildPathAndQuery(from request: JPIPRequest) -> String {
        let basePath = (baseURL.path.isEmpty || baseURL.path == "/") ? "/jpip" : baseURL.path
        let effectivePath: String
        if request.cid != nil, request.cnew == nil, let chPath = channelPathOverride, !chPath.isEmpty {
            effectivePath = chPath.hasPrefix("/") ? chPath : "/\(chPath)"
        } else {
            effectivePath = basePath
        }
        var effectiveReq = request
        if effectiveReq.cid != nil && effectiveReq.cnew == nil {
            effectiveReq.target = ""
        }
        let items = effectiveReq.buildQueryItems()
        guard !items.isEmpty else { return effectivePath }
        let query = items.keys.sorted().compactMap { k -> String? in
            guard let v = items[k] else { return nil }
            return "\(JPIPTransport.encodeJPIPQueryToken(k))=\(JPIPTransport.encodeJPIPQueryToken(v))"
        }.joined(separator: "&")
        return "\(effectivePath)?\(query)"
    }

    /// Disconnects from the server.
    public func disconnect() {
        tcpConnection?.close()
        tcpConnection = nil
        httpsSession?.finishTasksAndInvalidate()
        httpsSession = nil
        channelPathOverride = nil
        isConnected = false
    }
}

// MARK: - QUIC Support

/// QUIC protocol configuration for JPIP (configuration surface retained for compatibility;
/// ITU-T Rec. T.808 V3 HTTP/3 / QUIC execution is rejected under the declared T.808 V2 profile).
@available(macOS 11.0, iOS 14.0, tvOS 14.0, *)
public struct JPIPQUICConfiguration: Sendable {
    /// Whether to enable 0-RTT connection resumption.
    public let enableZeroRTT: Bool

    /// Maximum idle timeout in seconds.
    public let maxIdleTimeout: TimeInterval

    /// Initial maximum data (flow control).
    public let initialMaxData: UInt64

    /// Creates a new QUIC configuration.
    public init(
        enableZeroRTT: Bool = true,
        maxIdleTimeout: TimeInterval = 30,
        initialMaxData: UInt64 = 10 * 1024 * 1024
    ) {
        self.enableZeroRTT = enableZeroRTT
        self.maxIdleTimeout = maxIdleTimeout
        self.initialMaxData = initialMaxData
    }
}

// MARK: - Background Transfer Service (iOS)

#if os(iOS)
/// Background transfer service for iOS.
@available(iOS 13.0, *)
public actor JPIPBackgroundTransferService {
    /// Transfer task information.
    public struct TransferTask: Sendable {
        /// Unique task identifier.
        public let id: String

        /// JPIP request being transferred.
        public let request: JPIPRequest

        /// Transfer status.
        public let status: TransferStatus
    }

    /// Transfer status.
    public enum TransferStatus: Sendable {
        case pending
        case inProgress(progress: Double)
        case completed
        case failed(Error)
    }

    private var session: URLSession?
    private var activeTasks: [String: TransferTask] = [:]

    /// Creates a new background transfer service.
    public init() {}

    /// Registers the background task handler.
    public func register() throws {
        guard #available(iOS 13.0, *) else {
            throw J2KError.internalError("Background tasks require iOS 13+")
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: "com.j2kswift.jpip.download",
            using: nil
        ) { task in
            Task {
                if let processingTask = task as? BGProcessingTask {
                    await self.handleBackgroundTask(processingTask)
                }
            }
        }

        let config = URLSessionConfiguration.background(
            withIdentifier: "com.j2kswift.jpip.background"
        )
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true

        session = URLSession(configuration: config)
    }

    /// Schedules a download for background execution.
    public func scheduleDownload(request: JPIPRequest) async throws -> String {
        guard let session = session else {
            throw J2KError.internalError("Background transfer not initialized")
        }

        let taskID = UUID().uuidString
        let url = URL(string: "https://example.com")!
        _ = session.downloadTask(with: url)

        let task = TransferTask(
            id: taskID,
            request: request,
            status: .pending
        )

        activeTasks[taskID] = task

        let bgTaskRequest = BGProcessingTaskRequest(identifier: "com.j2kswift.jpip.download")
        bgTaskRequest.requiresNetworkConnectivity = true
        bgTaskRequest.requiresExternalPower = false

        try BGTaskScheduler.shared.submit(bgTaskRequest)

        return taskID
    }

    /// Returns the status of a transfer task.
    public func taskStatus(taskID: String) -> TransferTask? {
        activeTasks[taskID]
    }

    /// Cancels a transfer task.
    public func cancelTask(taskID: String) {
        activeTasks.removeValue(forKey: taskID)
    }

    private func handleBackgroundTask(_ task: BGProcessingTask) {
        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }
        task.setTaskCompleted(success: true)
    }
}
#endif

// MARK: - HTTP/3 Support

/// HTTP/3 configuration for JPIP.
@available(macOS 11.0, iOS 14.0, tvOS 14.0, *)
public struct JPIPHTTP3Configuration: Sendable {
    /// Whether to enable HTTP/3 server push.
    public let enableServerPush: Bool

    /// Maximum concurrent streams.
    public let maxConcurrentStreams: Int

    /// Whether to enable early data (0-RTT).
    public let enableEarlyData: Bool

    /// Creates a new HTTP/3 configuration.
    public init(
        enableServerPush: Bool = false,
        maxConcurrentStreams: Int = 100,
        enableEarlyData: Bool = true
    ) {
        self.enableServerPush = enableServerPush
        self.maxConcurrentStreams = maxConcurrentStreams
        self.enableEarlyData = enableEarlyData
    }
}

// MARK: - Efficient TLS

/// Efficient TLS configuration for JPIP.
@available(macOS 10.15, iOS 13.0, tvOS 13.0, *)
public struct JPIPTLSConfiguration: Sendable {
    /// TLS version.
    public enum TLSVersion: Sendable {
        case v12
        case v13
    }

    /// Minimum TLS version to accept.
    public let minimumVersion: TLSVersion

    /// Whether to enable session resumption.
    public let enableSessionResumption: Bool

    /// Whether to verify server certificates.
    public let verifyServerCertificate: Bool

    /// Creates a new TLS configuration.
    public init(
        minimumVersion: TLSVersion = .v12,
        enableSessionResumption: Bool = true,
        verifyServerCertificate: Bool = true
    ) {
        self.minimumVersion = minimumVersion
        self.enableSessionResumption = enableSessionResumption
        self.verifyServerCertificate = verifyServerCertificate
    }
}
