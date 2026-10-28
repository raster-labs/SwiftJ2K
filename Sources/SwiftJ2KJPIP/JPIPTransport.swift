// SPDX-License-Identifier: Apache-2.0
//
// JPIPTransport.swift
// SwiftJ2KJPIP
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/JPIP/JPIPTransport.swift
//
//
// JPIPTransport.swift
// J2KSwift
//
/// # JPIPTransport
///
/// HTTP transport layer for JPIP protocol.

import Foundation
@_exported import SwiftJ2K
@_exported import SwiftJ2K3D

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP transport for JPIP requests.
public actor JPIPTransport {
    /// The base server URL.
    private let baseURL: URL

    /// The URL session for network requests.
    private let session: URLSession

    /// Optional directly bound in-process server.
    private let boundServer: JPIPServer?

    /// Creates a new JPIP transport.
    ///
    /// - Parameters:
    ///   - baseURL: The base URL of the JPIP server.
    ///   - configuration: Optional URL session configuration.
    public init(baseURL: URL, configuration: URLSessionConfiguration? = nil) {
        self.baseURL = baseURL
        let config = configuration ?? URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config)
        self.boundServer = nil
    }

    /// Creates a new JPIP transport bound directly to an in-process ``JPIPServer``.
    ///
    /// - Parameter server: The in-process JPIP server.
    public init(server: JPIPServer) {
        self.baseURL = URL(string: "http://localhost:\(server.port)")!
        self.session = URLSession(configuration: .ephemeral)
        self.boundServer = server
    }

    /// Sends a JPIP request to the server.
    ///
    /// - Parameter request: The JPIP request to send.
    /// - Returns: The JPIP response.
    /// - Throws: ``J2KError`` if the request fails.
    public func send(_ request: JPIPRequest) async throws -> JPIPResponse {
        // 1. Check direct server binding
        if let server = boundServer {
            let response = try await server.handleRequest(request)
            guard (200..<300).contains(response.statusCode) else {
                throw J2KError.networkError("HTTP error: \(response.statusCode)")
            }
            return response
        }

        // 2. Check in-process loopback server registry when targeting localhost / 127.0.0.1 / ::1
        if let host = baseURL.host?.lowercased(),
           (host == "localhost" || host == "127.0.0.1" || host == "::1") {
            let port = baseURL.port ?? (baseURL.scheme?.lowercased() == "https" ? 443 : 80)
            if let loopbackServer = await JPIPLoopbackRegistry.shared.server(forPort: port) {
                let response = try await loopbackServer.handleRequest(request)
                guard (200..<300).contains(response.statusCode) else {
                    throw J2KError.networkError("HTTP error: \(response.statusCode)")
                }
                return response
            }
        }

        // 3. Fall back to HTTP network request via URLSession
        let urlRequest = try buildURLRequest(from: request)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw J2KError.networkError("Invalid response type")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw J2KError.networkError("HTTP error: \(httpResponse.statusCode)")
        }

        let headers = JPIPResponseParser.parseHeaders(from: httpResponse)
        let channelID = JPIPResponseParser.extractChannelID(from: headers)

        return JPIPResponse(
            channelID: channelID,
            data: data,
            statusCode: httpResponse.statusCode,
            headers: headers
        )
    }

    /// Builds a URLRequest from a JPIP request.
    ///
    /// - Parameter request: The JPIP request.
    /// - Returns: A configured URL request.
    /// - Throws: ``J2KError`` if the URL cannot be built.
    private func buildURLRequest(from request: JPIPRequest) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: true) else {
            throw J2KError.invalidParameter("Invalid base URL")
        }

        let queryItems = request.buildQueryItems()
        components.queryItems = queryItems.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components.url else {
            throw J2KError.invalidParameter("Failed to build request URL")
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

        return urlRequest
    }

    /// Closes the transport and cleans up resources.
    public func close() {
        session.finishTasksAndInvalidate()
    }
}

extension J2KError {
    /// Creates a network error.
    ///
    /// - Parameter message: The error message.
    /// - Returns: A network error.
    static func networkError(_ message: String) -> J2KError {
        .internalError("Network error: \(message)")
    }
}
