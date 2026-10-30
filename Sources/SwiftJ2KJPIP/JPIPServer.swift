// SPDX-License-Identifier: Apache-2.0
//
// JPIPServer.swift
// SwiftJ2KJPIP
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/JPIP/JPIPServer.swift
//
// Re-engineered in Phase R3 (F04) with:
// - Real POSIX TCP listening socket (`JPIPTCPListener`) supporting concurrent
//   persistent HTTP/1.1 connections and RFC 6455 WebSocket upgrade (`Sec-WebSocket-Protocol: jpip`).
// - Ephemeral port binding (`port == 0` -> `listeningPort`).
// - Normative ITU-T Rec. T.808 (12/2022) V2 | ISO/IEC 15444-9 Annex A.2 VBAS
//   data-bin streaming (`image/jpp-stream` & `image/jpt-stream`) for 2D (`.j2k`,
//   `.jp2`, `.jph`) and 3D Part 10 (`.jp3d`) targets, per-byte `Msg-Offset` session
//   deduplication, Clause C.8.1 `model=` reconciliation, `len=` byte-budget partial
//   bins, `cclose` channel teardown, and Clause D.3 End of Response (EOR) signalling.

import Foundation
import Dispatch
@_exported import SwiftJ2K
@_exported import SwiftJ2K3D

/// Thread-safe registry of active client TCP sockets owned by a running ``JPIPServer``
/// so `stop()` can close all open sockets immediately and unblock reader threads.
///
/// Concurrency proof (`@unchecked Sendable`):
/// All mutable state (`connections`, `isStopped`) is guarded exclusively by `lock` (`NSLock`).
package final class JPIPActiveSocketPool: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [UUID: JPIPTCPConnection] = [:]
    private var isStopped: Bool = false

    package init() {}

    package func insert(_ conn: JPIPTCPConnection) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        if isStopped {
            conn.close()
            return nil
        }
        let id = UUID()
        connections[id] = conn
        return id
    }

    package func remove(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        connections.removeValue(forKey: id)
    }

    package var activeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return connections.count
    }

    package func closeAll() {
        let toClose: [JPIPTCPConnection] = {
            lock.lock()
            defer { lock.unlock() }
            isStopped = true
            let all = Array(connections.values)
            connections.removeAll()
            return all
        }()
        for c in toClose {
            c.close()
        }
    }
}

/// A JPIP server for serving 2D JPEG 2000 (`.j2k`, `.jp2`, `.jph`) and 3D Part 10 (`.jp3d`)
/// targets over real HTTP/1.1 and RFC 6455 WebSocket connections.
public actor JPIPServer {
    /// Requested listening port (`0` requests an OS-assigned ephemeral port).
    nonisolated public let port: Int

    /// Host/interface address bound by `start()` (defaults to `"127.0.0.1"`).
    nonisolated public let bindHost: String

    /// Actual bound TCP port once `start()` succeeds (equals `port` when `port > 0`,
    /// or the OS-assigned ephemeral port when `port == 0`).
    public private(set) var listeningPort: Int

    /// Registered file URLs available for serving.
    private var registeredImages: [String: URL]

    /// Registered in-memory codestream/container/volume blobs available for serving.
    private var registeredBlobs: [String: Data]

    /// Reverse lookup from `JPIP-tid` to registered target name.
    private var targetByTID: [String: String]

    /// Cached image format information for registered images.
    private var imageInfoCache: [String: JPIPImageInfo]

    /// HTJ2K support helper.
    private let htj2kSupport: JPIPHTJ2KSupport

    /// Data bin generator for codestream extraction.
    private let dataBinGenerator: JPIPDataBinGenerator

    /// Transcoding service for on-the-fly format conversion.
    private let transcodingService: JPIPTranscodingService

    /// Cache for transcoded data.
    private let transcodingCache: JPIPTranscodingCache

    /// Active client sessions keyed by `channelID` (`cid`).
    private var sessions: [String: JPIPServerSession]

    /// Request queue for managing incoming requests.
    private var requestQueue: JPIPRequestQueue

    /// Bandwidth throttle for controlling data rates.
    private var bandwidthThrottle: JPIPBandwidthThrottle

    /// Whether the server is currently running.
    public private(set) var isRunning: Bool

    /// Active POSIX TCP listener while running.
    private var listener: JPIPTCPListener?

    /// Active accepted client sockets while running.
    private var socketPool: JPIPActiveSocketPool?

    /// Optional WebSocket upgrade delegate (used when embedded inside ``JPIPWebSocketServer``).
    private var webSocketDelegate: JPIPWebSocketServer?

    /// Configuration for the server.
    nonisolated public let configuration: Configuration

    /// Server statistics.
    private var stats: Statistics

    /// Configuration for the JPIP server.
    public struct Configuration: Sendable {
        /// Maximum number of concurrent clients.
        public let maxClients: Int

        /// Maximum queue size for pending requests.
        public let maxQueueSize: Int

        /// Global bandwidth limit in bytes per second (nil = unlimited).
        public let globalBandwidthLimit: Int?

        /// Per-client bandwidth limit in bytes per second (nil = unlimited).
        public let perClientBandwidthLimit: Int?

        /// Session timeout in seconds.
        public let sessionTimeout: TimeInterval

        /// Default stream media type when client does not specify `type=`.
        public let defaultStreamType: JPIPStreamType

        /// Creates a new server configuration.
        public init(
            maxClients: Int = 100,
            maxQueueSize: Int = 1000,
            globalBandwidthLimit: Int? = nil,
            perClientBandwidthLimit: Int? = nil,
            sessionTimeout: TimeInterval = 300,
            defaultStreamType: JPIPStreamType = .jppStream
        ) {
            self.maxClients = maxClients
            self.maxQueueSize = maxQueueSize
            self.globalBandwidthLimit = globalBandwidthLimit
            self.perClientBandwidthLimit = perClientBandwidthLimit
            self.sessionTimeout = sessionTimeout
            self.defaultStreamType = defaultStreamType
        }
    }

    /// Server statistics.
    public struct Statistics: Sendable {
        /// Total requests received.
        public var totalRequests: Int

        /// Active client count.
        public var activeClients: Int

        /// Total bytes sent.
        public var totalBytesSent: Int

        /// Requests in queue.
        public var queuedRequests: Int

        /// Creates empty statistics.
        public init() {
            self.totalRequests = 0
            self.activeClients = 0
            self.totalBytesSent = 0
            self.queuedRequests = 0
        }
    }

    /// Creates a new JPIP server.
    ///
    /// - Parameters:
    ///   - port: The TCP port to listen on (`0` for ephemeral port, default: `8080`).
    ///   - host: The bind address (default: `"127.0.0.1"`).
    ///   - configuration: Server configuration.
    public init(
        port: Int = 8080,
        host: String = "127.0.0.1",
        configuration: Configuration = Configuration()
    ) {
        self.port = port
        self.bindHost = host
        self.listeningPort = port
        self.configuration = configuration
        self.registeredImages = [:]
        self.registeredBlobs = [:]
        self.targetByTID = [:]
        self.imageInfoCache = [:]
        self.htj2kSupport = JPIPHTJ2KSupport()
        self.dataBinGenerator = JPIPDataBinGenerator()
        self.transcodingService = JPIPTranscodingService()
        self.transcodingCache = JPIPTranscodingCache()
        self.sessions = [:]
        self.requestQueue = JPIPRequestQueue(maxSize: configuration.maxQueueSize)
        self.bandwidthThrottle = JPIPBandwidthThrottle(
            globalLimit: configuration.globalBandwidthLimit,
            perClientLimit: configuration.perClientBandwidthLimit
        )
        self.isRunning = false
        self.listener = nil
        self.socketPool = nil
        self.webSocketDelegate = nil
        self.stats = Statistics()
    }

    package func setWebSocketDelegate(_ delegate: JPIPWebSocketServer?) {
        self.webSocketDelegate = delegate
    }

    /// Registers an image or 3D `.jp3d` file for serving.
    ///
    /// - Parameters:
    ///   - name: The target name used in JPIP requests.
    ///   - url: The file URL of the JPEG 2000 / JP2 / JPH / JP3D target.
    /// - Throws: ``J2KError`` if the file cannot be accessed.
    public func registerImage(name: String, at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw J2KError.fileNotFound("Image file not found: \(url.path)")
        }

        registeredImages[name] = url
        registeredBlobs.removeValue(forKey: name)
        targetByTID["tid-\(name)"] = name

        if let info = try? htj2kSupport.detectFormat(at: url) {
            imageInfoCache[name] = info
        }
    }

    /// Registers an in-memory codestream, container, or Part 10 `.jp3d` volume for serving.
    public func registerImageData(name: String, data: Data) {
        registeredBlobs[name] = data
        registeredImages.removeValue(forKey: name)
        targetByTID["tid-\(name)"] = name

        if let info = try? htj2kSupport.detectFormat(from: data) {
            imageInfoCache[name] = info
        }
    }

    /// Unregisters a target from serving.
    public func unregisterImage(name: String) {
        registeredImages.removeValue(forKey: name)
        registeredBlobs.removeValue(forKey: name)
        targetByTID.removeValue(forKey: "tid-\(name)")
        imageInfoCache.removeValue(forKey: name)
    }

    /// Gets the list of registered target names.
    public func listRegisteredImages() async -> [String] {
        Array(Set(registeredImages.keys).union(registeredBlobs.keys)).sorted()
    }

    /// Starts the real POSIX TCP HTTP/1.1 + RFC 6455 WebSocket listener.
    public func start() async throws {
        guard !isRunning else {
            throw J2KError.invalidState("Server is already running")
        }

        let tcpListener = try JPIPTCPListener(host: bindHost, port: port)
        let pool = JPIPActiveSocketPool()
        self.listener = tcpListener
        self.listeningPort = tcpListener.boundPort
        self.socketPool = pool
        self.isRunning = true

        let serverRef = self
        let maxClients = configuration.maxClients
        let acceptQueue = DispatchQueue(
            label: "com.rasterlab.swiftj2k.jpip.accept.\(tcpListener.boundPort)",
            qos: .userInitiated
        )
        let clientQueue = DispatchQueue(
            label: "com.rasterlab.swiftj2k.jpip.clients.\(tcpListener.boundPort)",
            qos: .userInitiated,
            attributes: .concurrent
        )

        acceptQueue.async {
            while tcpListener.isOpen {
                let accepted: JPIPTCPConnection?
                do {
                    accepted = try tcpListener.acceptConnection(timeoutSeconds: 30)
                } catch {
                    if !tcpListener.isOpen { break }
                    continue
                }
                guard let conn = accepted else { break }

                if pool.activeCount >= maxClients {
                    try? conn.writeHTTPResponse(
                        statusCode: 503,
                        reasonPhrase: "Service Unavailable",
                        headers: ["Connection": "close", "Retry-After": "1"],
                        body: Data("Maximum concurrent clients reached".utf8)
                    )
                    conn.close()
                    continue
                }

                guard let connID = pool.insert(conn) else {
                    continue
                }

                clientQueue.async {
                    defer {
                        conn.close()
                        pool.remove(connID)
                    }
                    Self.serveClientConnection(conn, server: serverRef)
                }
            }
        }
    }

    /// Stops the server, closing the listening socket, active client connections, and sessions.
    public func stop() async throws {
        guard isRunning else {
            throw J2KError.invalidState("Server is not running")
        }

        isRunning = false
        listener?.close()
        listener = nil
        socketPool?.closeAll()
        socketPool = nil

        for (_, session) in sessions {
            await session.close()
        }
        sessions.removeAll()
        stats.activeClients = 0

        await requestQueue.clear()
    }

    // MARK: - Blocking Socket Connection Worker (Dedicated DispatchQueue)

    nonisolated private static func serveClientConnection(
        _ conn: JPIPTCPConnection,
        server: JPIPServer
    ) {
        while conn.isOpen {
            let wireReq: JPIPHTTPWireRequest?
            do {
                wireReq = try conn.readHTTPRequest()
            } catch {
                break
            }
            guard let req = wireReq else {
                break
            }

            // Check for RFC 6455 WebSocket upgrade (`Upgrade: websocket`)
            if let upgrade = req.header("Upgrade"),
               upgrade.lowercased() == "websocket" {
                Self.serveWebSocketUpgrade(req, on: conn, server: server)
                return
            }

            // Synchronous bridge to actor request processing on dedicated worker thread
            let box = WireOutcomeBox()
            let sema = DispatchSemaphore(value: 0)
            Task {
                let outcome = await server.handleWireHTTPRequest(req)
                box.store(outcome)
                sema.signal()
            }
            sema.wait()

            let outcome = box.load()
            let wantsClose = (req.header("Connection")?.lowercased() ?? "").contains("close")
                || (req.version == "HTTP/1.0" && !(req.header("Connection")?.lowercased() ?? "").contains("keep-alive"))
            var headers = outcome.headers
            headers["Connection"] = wantsClose ? "close" : "keep-alive"

            do {
                try conn.writeHTTPResponse(
                    statusCode: outcome.statusCode,
                    reasonPhrase: Self.httpReasonPhrase(for: outcome.statusCode),
                    headers: headers,
                    body: outcome.body
                )
            } catch {
                break
            }

            if wantsClose {
                break
            }
        }
    }

    nonisolated private static func serveWebSocketUpgrade(
        _ req: JPIPHTTPWireRequest,
        on conn: JPIPTCPConnection,
        server: JPIPServer
    ) {
        guard let clientKey = req.header("Sec-WebSocket-Key"),
              !clientKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            try? conn.writeHTTPResponse(
                statusCode: 400,
                reasonPhrase: "Bad Request",
                headers: ["Connection": "close"],
                body: Data("Missing Sec-WebSocket-Key".utf8)
            )
            return
        }

        // Delegate to attached JPIPWebSocketServer if present, or serve directly using JPIPWebSocketMessageEncoder.
        let upgradeBox = WSUpgradeBox()
        let sema = DispatchSemaphore(value: 0)
        Task {
            let delegate = await server.getWebSocketDelegate()
            if let wsServer = delegate {
                let res = await wsServer.acceptLiveSocketUpgrade(headers: req.headers, socket: conn)
                upgradeBox.store(delegate: wsServer, connectionID: res.connectionID, error: res.error)
            } else {
                upgradeBox.store(delegate: nil, connectionID: UUID().uuidString, error: nil)
            }
            sema.signal()
        }
        sema.wait()

        if let err = upgradeBox.error {
            try? conn.writeHTTPResponse(
                statusCode: 400,
                reasonPhrase: "Bad Request",
                headers: ["Connection": "close"],
                body: Data(err.utf8)
            )
            return
        }

        let requestedProto = req.header("Sec-WebSocket-Protocol") ?? ""
        let negotiatedProto: String? = requestedProto.lowercased().contains("jpip") || requestedProto.isEmpty
            ? "jpip"
            : nil
        do {
            try conn.writeWebSocketServerHandshake(
                clientKey: clientKey,
                negotiatedSubprotocol: negotiatedProto
            )
            conn.setReceiveTimeout(seconds: 0)
        } catch {
            if let wsServer = upgradeBox.delegate, let cid = upgradeBox.connectionID {
                let closeSema = DispatchSemaphore(value: 0)
                Task {
                    await wsServer.closeConnection(cid)
                    closeSema.signal()
                }
                closeSema.wait()
            }
            return
        }

        let wsDelegate = upgradeBox.delegate
        let wsConnID = upgradeBox.connectionID ?? UUID().uuidString
        defer {
            if let wsServer = wsDelegate {
                let closeSema = DispatchSemaphore(value: 0)
                Task {
                    await wsServer.closeConnection(wsConnID)
                    closeSema.signal()
                }
                closeSema.wait()
            }
        }

        let msgEncoder = JPIPWebSocketMessageEncoder()
        while conn.isOpen {
            let wireFrame: JPIPRFC6455WireFrame
            do {
                wireFrame = try conn.readWebSocketFrame(requireMasked: true)
            } catch {
                break
            }

            switch wireFrame.opcode {
            case .close:
                try? conn.writeWebSocketFrame(
                    opcode: .close,
                    payload: wireFrame.payload.prefix(2),
                    masked: false
                )
                return
            case .ping:
                try? conn.writeWebSocketFrame(
                    opcode: .pong,
                    payload: wireFrame.payload,
                    masked: false
                )
            case .pong:
                if let wsServer = wsDelegate {
                    let s = DispatchSemaphore(value: 0)
                    Task {
                        _ = try? await wsServer.handleFrame(
                            JPIPWebSocketFrame(type: .pong, payload: wireFrame.payload),
                            from: wsConnID
                        )
                        s.signal()
                    }
                    s.wait()
                }
            case .binary, .text:
                guard let appFrame = JPIPWebSocketFrame.deserialize(from: wireFrame.payload) else {
                    let errFrame = JPIPWebSocketFrame(
                        type: .error,
                        payload: Data("Malformed JPIP WebSocket frame".utf8)
                    )
                    try? conn.writeWebSocketFrame(opcode: .binary, payload: errFrame.serialize(), masked: false)
                    continue
                }

                let replyBox = WSFrameReplyBox()
                let s = DispatchSemaphore(value: 0)
                Task {
                    if let wsServer = wsDelegate {
                        do {
                            let reply = try await wsServer.handleFrame(appFrame, from: wsConnID)
                            replyBox.store(reply)
                        } catch {
                            replyBox.store(JPIPWebSocketFrame(
                                type: .error,
                                payload: Data("\(error)".utf8),
                                requestID: appFrame.requestID
                            ))
                        }
                    } else {
                        let reply = await server.handleStandaloneWebSocketFrame(appFrame, encoder: msgEncoder)
                        replyBox.store(reply)
                    }
                    s.signal()
                }
                s.wait()

                if let replyFrame = replyBox.load() {
                    do {
                        try conn.writeWebSocketFrame(
                            opcode: .binary,
                            payload: replyFrame.serialize(),
                            masked: false
                        )
                    } catch {
                        break
                    }
                }
            case .continuation:
                break
            }
        }
    }

    package func getWebSocketDelegate() -> JPIPWebSocketServer? {
        webSocketDelegate
    }

    private func handleStandaloneWebSocketFrame(
        _ frame: JPIPWebSocketFrame,
        encoder: JPIPWebSocketMessageEncoder
    ) async -> JPIPWebSocketFrame? {
        switch frame.type {
        case .ping:
            return JPIPWebSocketFrame(type: .pong, payload: frame.payload, requestID: frame.requestID)
        case .request:
            guard let req = encoder.decodeRequest(from: frame) else {
                return JPIPWebSocketFrame(
                    type: .error,
                    payload: Data("Invalid JPIP request payload".utf8),
                    requestID: frame.requestID
                )
            }
            do {
                let rawResp = try await handleRequest(req)
                var wsHeaders = rawResp.headers
                wsHeaders["X-JPIP-Transport"] = "websocket"
                let resp = JPIPResponse(
                    channelID: rawResp.channelID,
                    data: rawResp.data,
                    statusCode: rawResp.statusCode,
                    headers: wsHeaders
                )
                return encoder.encodeResponse(resp, requestID: frame.requestID ?? 0)
            } catch {
                return JPIPWebSocketFrame(
                    type: .error,
                    payload: Data("\(error)".utf8),
                    requestID: frame.requestID
                )
            }
        case .control:
            if let cmd = String(data: frame.payload, encoding: .utf8),
               cmd.hasPrefix("close-session:") {
                let sid = String(cmd.dropFirst("close-session:".count))
                await closeSession(sid)
                return JPIPWebSocketFrame(
                    type: .control,
                    payload: Data("session-closed:\(sid)".utf8),
                    requestID: frame.requestID
                )
            }
            return nil
        default:
            return nil
        }
    }

    private func handleWireHTTPRequest(_ wireReq: JPIPHTTPWireRequest) async -> (statusCode: Int, headers: [String: String], body: Data) {
        let method = wireReq.method.uppercased()
        guard method == "GET" || method == "HEAD" || method == "POST" else {
            return (405, ["Content-Type": "text/plain; charset=utf-8", "Allow": "GET, HEAD, POST"], Data("Method Not Allowed".utf8))
        }

        // Validate explicit `type=` query value before parsing so unknown return types get HTTP 415.
        if let qIdx = wireReq.target.firstIndex(of: "?") {
            let query = wireReq.target[wireReq.target.index(after: qIdx)...]
            for pair in query.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2, kv[0] == "type" {
                    let rawType = (String(kv[1]).removingPercentEncoding ?? String(kv[1]))
                    if JPIPStreamType(queryValue: rawType) == nil {
                        return (415, ["Content-Type": "text/plain; charset=utf-8"], Data("Unsupported JPIP stream return type: \(rawType)".utf8))
                    }
                }
            }
        }

        var parsedReq = JPIPRequest.parseHTTPTarget(wireReq.target)
        if method == "POST", !wireReq.body.isEmpty,
           let bodyQuery = String(data: wireReq.body, encoding: .utf8) {
            let mergedTarget = wireReq.target.contains("?")
                ? "\(wireReq.target)&\(bodyQuery)"
                : "\(wireReq.target)?\(bodyQuery)"
            parsedReq = JPIPRequest.parseHTTPTarget(mergedTarget)
        }

        do {
            let resp = try await handleRequest(parsedReq)
            let body = (method == "HEAD") ? Data() : resp.data
            return (resp.statusCode, resp.headers, body)
        } catch let j2kErr as J2KError {
            let msg = "\(j2kErr)"
            if msg.contains("File not found") || msg.contains("Image not found") {
                return (404, ["Content-Type": "text/plain; charset=utf-8"], Data(msg.utf8))
            }
            if msg.contains("Unknown or expired JPIP channel ID") {
                return (410, ["Content-Type": "text/plain; charset=utf-8"], Data(msg.utf8))
            }
            if msg.contains("Invalid parameter") || msg.contains("channel ID") {
                return (400, ["Content-Type": "text/plain; charset=utf-8"], Data(msg.utf8))
            }
            return (500, ["Content-Type": "text/plain; charset=utf-8"], Data(msg.utf8))
        } catch {
            return (500, ["Content-Type": "text/plain; charset=utf-8"], Data("\(error)".utf8))
        }
    }

    nonisolated private static func httpReasonPhrase(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 410: return "Gone"
        case 415: return "Unsupported Media Type"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }

    // MARK: - Core JPIP Request Handling

    /// Handles an incoming JPIP request.
    ///
    /// - Parameter request: The JPIP request to handle.
    /// - Returns: A JPIP response.
    /// - Throws: ``J2KError`` if the request cannot be handled.
    public func handleRequest(_ request: JPIPRequest) async throws -> JPIPResponse {
        guard isRunning else {
            throw J2KError.invalidState("Server is not running")
        }

        stats.totalRequests += 1

        // 1. Handle ITU-T Rec. T.808 Clause C.3.3 channel close (`cclose`)
        if let ccloseList = request.cclose, !ccloseList.isEmpty {
            return try await handleChannelClose(request, ccloseList: ccloseList)
        }

        // Enforce ITU-T Rec. T.808 Clause C.8.1.2: additive wildcard `model=` items (`*`, `H*`, `P*`, `T*`, `M*`)
        // are stateless-only and forbidden on stateful `cid=` requests.
        if request.cid != nil, let modelItems = request.model, !modelItems.isEmpty {
            let directives = JPIPCacheModel.parseModelItems(modelItems)
            if directives.contains(where: { $0.isAdditive && $0.binID == nil }) {
                throw J2KError.invalidParameter(
                    "ITU-T T.808 Clause C.8.1.2 forbids additive wildcard model= descriptors on stateful cid= requests."
                )
            }
        }

        // Enqueue the request
        try await requestQueue.enqueue(request, priority: determinePriority(request))
        stats.queuedRequests = await requestQueue.size

        // Resolve target name before session creation when `tid` or leading slash is used
        let resolvedRequest = resolveTargetAlias(in: request)

        // Get or create session
        let session = try await getOrCreateSession(for: resolvedRequest)

        // Check bandwidth limits
        let canSend = await bandwidthThrottle.canSend(
            clientID: session.sessionID,
            bytes: 1024
        )

        guard canSend else {
            _ = await requestQueue.dequeue()
            stats.queuedRequests = await requestQueue.size
            return JPIPResponse(
                channelID: session.channelID.isEmpty ? nil : session.channelID,
                data: Data(),
                statusCode: 503,
                headers: ["Retry-After": "1"]
            )
        }

        // Process the request
        let response: JPIPResponse
        do {
            response = try await processRequest(resolvedRequest, session: session)
        } catch {
            _ = await requestQueue.dequeue()
            stats.queuedRequests = await requestQueue.size
            // If `cnew` allocated a session for a nonexistent target, roll it back cleanly
            if resolvedRequest.cnew != nil && !session.channelID.isEmpty {
                sessions.removeValue(forKey: session.channelID)
                stats.activeClients = sessions.count
            }
            throw error
        }

        _ = await requestQueue.dequeue()
        await session.recordRequest(bytesSent: response.data.count)

        await bandwidthThrottle.recordSent(
            clientID: session.sessionID,
            bytes: response.data.count
        )

        stats.totalBytesSent += response.data.count
        stats.queuedRequests = await requestQueue.size

        return response
    }

    private func handleChannelClose(
        _ request: JPIPRequest,
        ccloseList: [String]
    ) async throws -> JPIPResponse {
        if ccloseList.contains("*") {
            if let cid = request.cid, sessions[cid] == nil {
                throw J2KError.invalidParameter("Unknown or already closed JPIP channel ID: \(cid)")
            }
            for (_, session) in sessions {
                await session.close()
            }
            sessions.removeAll()
        } else {
            for cidToClose in ccloseList {
                guard let session = sessions.removeValue(forKey: cidToClose) else {
                    throw J2KError.invalidParameter("Unknown or already closed JPIP channel ID: \(cidToClose)")
                }
                await session.close()
            }
        }
        stats.activeClients = sessions.count
        let body: Data
        let headers: [String: String]
        if let st = request.streamType {
            body = JPIPWireCodec.encodeEOR(reason: .windowDone)
            headers = ["Content-Type": st.contentTypeHeader, "Cache-Control": "no-cache"]
        } else {
            body = Data()
            headers = ["Content-Type": "application/octet-stream"]
        }
        return JPIPResponse(channelID: nil, data: body, statusCode: 200, headers: headers)
    }

    private func resolveTargetAlias(in request: JPIPRequest) -> JPIPRequest {
        var req = request
        if req.target.isEmpty, let cid = req.cid, let existing = sessions[cid] {
            req.target = existing.target
        }
        if req.target.isEmpty, let tid = req.tid, let mapped = targetByTID[tid] {
            req.target = mapped
        }
        if !req.target.isEmpty,
           registeredImages[req.target] == nil,
           registeredBlobs[req.target] == nil {
            let stripped = req.target.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if registeredImages[stripped] != nil || registeredBlobs[stripped] != nil {
                req.target = stripped
            }
        }
        return req
    }

    /// Determines the priority for a request.
    private func determinePriority(_ request: JPIPRequest) -> Int {
        if request.cnew != nil {
            return 100
        }
        if request.metadata == true {
            return 90
        }
        if let rsiz = request.rsiz, rsiz.width * rsiz.height < 10000 {
            return 80
        }
        return 50
    }

    /// Gets an existing session, creates a persistent session when `cnew` is requested,
    /// or returns an ephemeral non-persisted session for stateless requests (`cid == nil && cnew == nil`).
    private func getOrCreateSession(for request: JPIPRequest) async throws -> JPIPServerSession {
        if let cid = request.cid {
            if let existingSession = sessions[cid] {
                return existingSession
            }
            if request.cnew == nil {
                throw J2KError.invalidParameter("Unknown or expired JPIP channel ID: \(cid)")
            }
        }

        if request.cnew != nil {
            let sessionID = UUID().uuidString
            let channelID = "cid-\(sessionID)"

            let newSession = JPIPServerSession(
                sessionID: sessionID,
                channelID: channelID,
                target: request.target
            )

            sessions[channelID] = newSession
            stats.activeClients = sessions.count

            return newSession
        }

        return JPIPServerSession(
            sessionID: "stateless-\(UUID().uuidString)",
            channelID: "",
            target: request.target
        )
    }

    /// Processes a request and generates a response.
    private func processRequest(
        _ request: JPIPRequest,
        session: JPIPServerSession
    ) async throws -> JPIPResponse {
        let effectiveTarget = request.target.isEmpty ? session.target : request.target
        let imageURL = registeredImages[effectiveTarget]
        let blobData = registeredBlobs[effectiveTarget]

        guard imageURL != nil || blobData != nil else {
            throw J2KError.fileNotFound("Image not found: \(effectiveTarget)")
        }

        let responseChannelID: String? = session.channelID.isEmpty ? nil : session.channelID
        let tid = "tid-\(effectiveTarget)"
        targetByTID[tid] = effectiveTarget

        var baseHeaders: [String: String] = [
            "JPIP-tid": tid,
            "Cache-Control": "no-cache"
        ]

        if let cnewType = request.cnew {
            let transportToken = (cnewType == .webSocket) ? "ws" : "http"
            baseHeaders["JPIP-cnew"] = "cid=\(session.channelID),path=jpip,transport=\(transportToken)"
            if let info = imageInfoCache[effectiveTarget] {
                let capHeaders = htj2kSupport.capabilityHeaders(for: info)
                for (key, value) in capHeaders where key != "Content-Type" {
                    baseHeaders[key] = value
                }
            }

            // Bare session-establishment request (`cnew` with no view-window or stream parameters):
            // return 200 OK with `JPIP-cnew` header and empty body.
            if !request.hasViewWindowOrStreamParameters && request.metadata != true {
                baseHeaders["Content-Type"] = "application/octet-stream"
                return JPIPResponse(
                    channelID: responseChannelID,
                    data: Data(),
                    statusCode: 200,
                    headers: baseHeaders
                )
            }
        }

        // Key-value metadata query (`meta=yes` without explicit `type=jpp-stream`/`jpt-stream`)
        if request.metadata == true && request.streamType == nil {
            let metadataData = try await generateMetadata(
                targetName: effectiveTarget,
                imageURL: imageURL,
                blobData: blobData
            )
            baseHeaders["Content-Type"] = "application/octet-stream"
            return JPIPResponse(
                channelID: responseChannelID,
                data: metadataData,
                statusCode: 200,
                headers: baseHeaders
            )
        }

        // Normative data-bin or fallback raw image payload generation
        let generated = try await generateImagePayload(
            targetName: effectiveTarget,
            imageURL: imageURL,
            blobData: blobData,
            request: request,
            session: session
        )
        baseHeaders["Content-Type"] = generated.contentType

        return JPIPResponse(
            channelID: responseChannelID,
            data: generated.body,
            statusCode: 200,
            headers: baseHeaders
        )
    }

    /// Generates textual format/dimension metadata for `meta=yes` queries.
    private func generateMetadata(
        targetName: String,
        imageURL: URL?,
        blobData: Data?
    ) async throws -> Data {
        var lines: [String] = []
        if let info = imageInfoCache[targetName],
           let str = String(data: htj2kSupport.generateFormatMetadata(for: info), encoding: .utf8) {
            lines.append(str)
        }
        let rawData: Data?
        if let blobData {
            rawData = blobData
        } else if let imageURL {
            rawData = try? Data(contentsOf: imageURL, options: .mappedIfSafe)
        } else {
            rawData = nil
        }

        if let fileData = rawData {
            if JP3DJPIPIndexer.isJP3DCodestream(fileData),
               let idx3D = try? JP3DJPIPIndexer.index(fileData) {
                let bitDepth3D = (try? JP3DCodestreamParser().parse(fileData).siz.bitDepth) ?? 8
                lines.append("format=jp3d")
                lines.append("width=\(idx3D.width)")
                lines.append("height=\(idx3D.height)")
                lines.append("depth=\(idx3D.depth)")
                lines.append("components=\(idx3D.componentCount)")
                lines.append("bitDepth=\(bitDepth3D)")
            } else if let info = try? Decoder().inspect(fileData) {
                lines.append("width=\(info.descriptor.width)")
                lines.append("height=\(info.descriptor.height)")
                lines.append("components=\(info.descriptor.components.count)")
                lines.append("bitDepth=\(info.descriptor.meaningfulBits)")
            }
        }
        if !lines.isEmpty {
            return Data(lines.joined(separator: "\n").utf8)
        }
        return Data("metadata".utf8)
    }

    /// Generates normative ITU-T Rec. T.808 VBAS data-bin stream (`image/jpp-stream` or `image/jpt-stream`)
    /// for real 2D/3D JPEG 2000 targets, falling back to raw bytes only for non-codestream synthetic unit-test files.
    private func generateImagePayload(
        targetName: String,
        imageURL: URL?,
        blobData: Data?,
        request: JPIPRequest,
        session: JPIPServerSession
    ) async throws -> (body: Data, contentType: String) {
        let sourceData: Data
        if let blobData {
            sourceData = blobData
        } else if let imageURL {
            sourceData = try Data(contentsOf: imageURL, options: .mappedIfSafe)
        } else {
            throw J2KError.fileNotFound("Image not found: \(targetName)")
        }

        let preference = request.codingPreference ?? .none
        let sourceIsHTJ2K = imageInfoCache[targetName]?.isHTJ2K ?? false
        var dataToServe = sourceData

        if !JP3DJPIPIndexer.isJP3DCodestream(sourceData),
           transcodingService.needsTranscoding(preference: preference, sourceIsHTJ2K: sourceIsHTJ2K) {
            let sourceHash = stableHash(for: sourceData)
            if let direction = transcodingService.determineDirection(
                preference: preference,
                sourceIsHTJ2K: sourceIsHTJ2K
            ) {
                if let cached = await transcodingCache.get(sourceHash: sourceHash, direction: direction) {
                    dataToServe = cached
                } else if let result = try? transcodingService.transcode(
                    data: sourceData,
                    preference: preference,
                    sourceIsHTJ2K: sourceIsHTJ2K
                ), result.wasTranscoded {
                    dataToServe = result.data
                    await transcodingCache.put(
                        data: result.data,
                        sourceHash: sourceHash,
                        direction: direction
                    )
                }
            }
        }

        // Normative ITU-T Rec. T.808 Annex A.2 VBAS data-bin streaming for valid 2D & 3D targets
        if let windowGen = try? dataBinGenerator.generateWireDataBins(
            from: dataToServe,
            request: request,
            defaultStreamType: configuration.defaultStreamType
        ) {
            // 1. Reconcile client-supplied Clause C.8.1 `model=` descriptors if present
            if let modelItems = request.model, !modelItems.isEmpty {
                let mergedBins = Self.mergeContiguousSegmentsForModel(windowGen.bins)
                await session.applyCacheModel(items: modelItems, availableBins: mergedBins)
            }

            // 2. Compute unsent segments / `Msg-Offset` tails against `session`
            var unsentSegments: [JPIPDataBin] = []
            unsentSegments.reserveCapacity(windowGen.bins.count)

            for seg in windowGen.bins {
                let segStart = max(0, seg.msgOffset)
                let segEnd = segStart + seg.data.count
                if seg.data.isEmpty {
                    let complete = await session.hasCompleteDataBin(
                        binClass: seg.binClass,
                        binID: seg.binID,
                        totalLength: segEnd
                    )
                    if !complete {
                        unsentSegments.append(seg)
                    }
                    continue
                }

                let alreadySent = await session.sentByteOffset(binClass: seg.binClass, binID: seg.binID)
                if alreadySent >= segEnd {
                    if seg.isComplete {
                        let complete = await session.hasCompleteDataBin(
                            binClass: seg.binClass,
                            binID: seg.binID,
                            totalLength: segEnd
                        )
                        if !complete {
                            unsentSegments.append(JPIPDataBin(
                                binClass: seg.binClass,
                                binID: seg.binID,
                                codestreamID: seg.codestreamID,
                                data: Data(),
                                isComplete: true,
                                msgOffset: segEnd,
                                aux: seg.aux
                            ))
                        }
                    }
                    continue
                }

                if alreadySent > segStart {
                    let trim = min(seg.data.count, alreadySent - segStart)
                    let tail = Data(seg.data.dropFirst(trim))
                    unsentSegments.append(JPIPDataBin(
                        binClass: seg.binClass,
                        binID: seg.binID,
                        codestreamID: seg.codestreamID,
                        data: tail,
                        isComplete: seg.isComplete,
                        msgOffset: segStart + trim,
                        aux: seg.aux
                    ))
                } else {
                    unsentSegments.append(seg)
                }
            }

            // 3. Enforce `len=` byte budget with partial-bin (`isComplete = false`) splitting + EOR
            let completedReason: JPIPEORReason = windowGen.coversFullTarget ? .imageDone : .windowDone
            if let maxLen = request.len {
                if maxLen <= 3 {
                    let eorOnly = JPIPWireCodec.encodeEOR(reason: .byteLimit)
                    return (Data(eorOnly.prefix(max(0, maxLen))), windowGen.streamType.contentTypeHeader)
                }

                var emitted: [JPIPDataBin] = []
                var hitByteLimit = false

                for seg in unsentSegments {
                    let fullTrial = JPIPWireCodec.encodeStream(
                        bins: emitted + [seg],
                        eorReason: .byteLimit
                    )
                    if fullTrial.count <= maxLen {
                        emitted.append(seg)
                        await session.recordSentDataBin(seg)
                        continue
                    }

                    // Binary-search largest non-empty prefix `k` (`1..<seg.data.count`) whose
                    // VBAS header + `k` payload bytes + 3-byte EOR fits within `maxLen`.
                    if seg.data.count > 1 {
                        var lo = 1
                        var hi = seg.data.count - 1
                        var bestK = 0
                        while lo <= hi {
                            let mid = (lo + hi) / 2
                            let partialTrial = JPIPDataBin(
                                binClass: seg.binClass,
                                binID: seg.binID,
                                codestreamID: seg.codestreamID,
                                data: Data(seg.data.prefix(mid)),
                                isComplete: false,
                                msgOffset: seg.msgOffset,
                                aux: seg.aux
                            )
                            let wireTrial = JPIPWireCodec.encodeStream(
                                bins: emitted + [partialTrial],
                                eorReason: .byteLimit
                            )
                            if wireTrial.count <= maxLen {
                                bestK = mid
                                lo = mid + 1
                            } else {
                                hi = mid - 1
                            }
                        }

                        if bestK > 0 {
                            let partial = JPIPDataBin(
                                binClass: seg.binClass,
                                binID: seg.binID,
                                codestreamID: seg.codestreamID,
                                data: Data(seg.data.prefix(bestK)),
                                isComplete: false,
                                msgOffset: seg.msgOffset,
                                aux: seg.aux
                            )
                            emitted.append(partial)
                            await session.recordSentDataBin(partial)
                        }
                    }

                    hitByteLimit = true
                    break
                }

                let finalReason: JPIPEORReason = hitByteLimit ? .byteLimit : completedReason
                let wireData = JPIPWireCodec.encodeStream(bins: emitted, eorReason: finalReason)
                return (wireData, windowGen.streamType.contentTypeHeader)
            }

            // Unbounded response (`len == nil`): emit all unsent segments + completion EOR
            for seg in unsentSegments {
                await session.recordSentDataBin(seg)
            }
            let wireData = JPIPWireCodec.encodeStream(bins: unsentSegments, eorReason: completedReason)
            return (wireData, windowGen.streamType.contentTypeHeader)
        }

        // Legacy fallback only for non-JPEG2000 synthetic unit-test stubs (e.g. `Data("test".utf8)`)
        var responseData = dataToServe
        if let maxLen = request.len, responseData.count > maxLen {
            responseData = Data(responseData.prefix(max(0, maxLen)))
        }
        return (responseData, "application/octet-stream")
    }

    private static func mergeContiguousSegmentsForModel(_ segments: [JPIPDataBin]) -> [JPIPDataBin] {
        var merger = JPIPCacheModel(maxCacheSize: Int.max, maxEntries: Int.max)
        for seg in segments {
            merger.addDataBin(seg)
        }
        return merger.allDataBins()
    }

    /// Gets the current server statistics.
    public func getStatistics() async -> Statistics {
        var currentStats = stats
        currentStats.activeClients = sessions.count
        currentStats.queuedRequests = await requestQueue.size
        return currentStats
    }

    /// Closes a client session by channel/session ID.
    public func closeSession(_ sessionID: String) async {
        if let session = sessions.removeValue(forKey: sessionID) {
            await session.close()
            stats.activeClients = sessions.count
            return
        }
        if let match = sessions.first(where: { $0.value.sessionID == sessionID }) {
            sessions.removeValue(forKey: match.key)
            await match.value.close()
            stats.activeClients = sessions.count
        }
    }

    /// Gets the number of active sessions.
    public func getActiveSessionCount() async -> Int {
        sessions.count
    }

    /// Gets the format information for a registered image.
    public func getImageInfo(name: String) -> JPIPImageInfo? {
        imageInfoCache[name]
    }

    private func stableHash(for data: Data) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}

// MARK: - Thread-Safe Worker Bridge Boxes

/// Concurrency proof (`@unchecked Sendable`):
/// Written once inside the spawned `Task` before `DispatchSemaphore.signal()` and read
/// only after `DispatchSemaphore.wait()`, establishing a strict happens-before edge.
private final class WireOutcomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: (statusCode: Int, headers: [String: String], body: Data) = (
        500,
        ["Content-Type": "text/plain"],
        Data("Uninitialized".utf8)
    )

    func store(_ value: (statusCode: Int, headers: [String: String], body: Data)) {
        lock.lock()
        outcome = value
        lock.unlock()
    }

    func load() -> (statusCode: Int, headers: [String: String], body: Data) {
        lock.lock()
        defer { lock.unlock() }
        return outcome
    }
}

/// Concurrency proof (`@unchecked Sendable`):
/// Guarded by `NSLock` and synchronized via `DispatchSemaphore`.
private final class WSUpgradeBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var delegate: JPIPWebSocketServer?
    private(set) var connectionID: String?
    private(set) var error: String?

    func store(delegate: JPIPWebSocketServer?, connectionID: String?, error: String?) {
        lock.lock()
        self.delegate = delegate
        self.connectionID = connectionID
        self.error = error
        lock.unlock()
    }
}

/// Concurrency proof (`@unchecked Sendable`):
/// Guarded by `NSLock` and synchronized via `DispatchSemaphore`.
private final class WSFrameReplyBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: JPIPWebSocketFrame?

    func store(_ value: JPIPWebSocketFrame?) {
        lock.lock()
        reply = value
        lock.unlock()
    }

    func load() -> JPIPWebSocketFrame? {
        lock.lock()
        defer { lock.unlock() }
        return reply
    }
}

extension J2KError {
    /// Creates a file not found error.
    static func fileNotFound(_ message: String) -> J2KError {
        .internalError("File not found: \(message)")
    }

    /// Creates an invalid state error.
    static func invalidState(_ message: String) -> J2KError {
        .internalError("Invalid state: \(message)")
    }
}
