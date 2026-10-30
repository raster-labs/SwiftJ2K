// SPDX-License-Identifier: Apache-2.0
//
// JPIPRequest.swift
// SwiftJ2KJPIP
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/JPIP/JPIPRequest.swift
//
// Extended in Phase R3 (F04) with normative ITU-T Rec. T.808 (12/2022) V2 |
// ISO/IEC 15444-9 stream return types (`image/jpp-stream`, `image/jpt-stream`),
// target ID (`tid`), channel close (`cclose`), Clause C.8.1 cache model (`model`),
// Clauses C.4.5–C.4.7 variable-dimension 3D view-window (`fvsiz`, `rvoff`, `rvsiz`)
// plus compatibility `zoff`/`zsiz` extensions, and checked HTTP query-string parsing.

import Foundation
@_exported import SwiftJ2K
@_exported import SwiftJ2K3D

/// Return stream media types per ITU-T Rec. T.808 Clause C.7.2 (`type=`).
public enum JPIPStreamType: String, Sendable, Equatable {
    case jppStream = "jpp-stream"
    case jptStream = "jpt-stream"

    public var contentTypeHeader: String {
        switch self {
        case .jppStream: return "image/jpp-stream"
        case .jptStream: return "image/jpt-stream"
        }
    }

    public init?(queryValue: String) {
        let lower = queryValue.trimmingCharacters(in: .whitespaces).lowercased()
        if lower == "jpp-stream" || lower == "image/jpp-stream" || lower == "jpp" {
            self = .jppStream
        } else if lower == "jpt-stream" || lower == "image/jpt-stream" || lower == "jpt" {
            self = .jptStream
        } else {
            return nil
        }
    }
}

/// Represents a JPIP request with various parameters.
public struct JPIPRequest: Sendable {
    /// The target image identifier (filename or path).
    public var target: String

    /// Optional target ID (`tid`) per ITU-T T.808 Clause C.2.2.
    public var tid: String?

    /// Full size of the image window (width, height).
    public var fsiz: (width: Int, height: Int)?

    /// Optional ITU-T Rec. T.808 Clause C.4.1 rounding direction for `fsiz` (`"round-down"`, `"round-up"`, `"closest"`).
    public var fsizRoundDirection: String?

    /// Region size within the full image (width, height).
    public var rsiz: (width: Int, height: Int)?

    /// Region offset (x, y) from top-left corner.
    public var roff: (x: Int, y: Int)?

    /// Normative ITU-T Rec. T.808 Clause C.4.5 variable-dimension frame size (`fvsiz=fx,fy,fz[,round-direction]`).
    public var fvsiz: [Int]?

    /// Optional ITU-T Rec. T.808 Clause C.4.5 rounding direction for `fvsiz` (`"round-down"`, `"round-up"`, `"closest"`).
    public var fvsizRoundDirection: String?

    /// Normative ITU-T Rec. T.808 Clause C.4.6 variable-dimension region offset (`rvoff=ox,oy,oz`) in `fvsiz` frame coordinates.
    public var rvoff: [Int]?

    /// Normative ITU-T Rec. T.808 Clause C.4.7 variable-dimension region size (`rvsiz=sx,sy,sz`) in `fvsiz` frame coordinates.
    public var rvsiz: [Int]?

    /// Compatibility extension: 3D depth offset and extent (`zoff`, `zsiz`) when `fvsiz`/`rvoff`/`rvsiz` are omitted.
    public var zRange: (offset: Int, size: Int)?

    /// Number of quality layers to request.
    public var layers: Int?

    /// Channel ID for stateful sessions.
    public var cid: String?

    /// Whether to request a new channel.
    public var cnew: JPIPChannelType?

    /// Channel IDs to close (`cclose`, `["*"]` closes all channels in the session).
    public var cclose: [String]?

    /// Maximum length of response data in bytes (`len`).
    public var len: Int?

    /// Component indices to request (e.g., `[0, 1]` for red and green channels).
    public var comps: [Int]?

    /// Compatibility extension: resolution reduction levels (`0` = full resolution, higher values = lower resolution).
    public var reslevels: Int?

    /// Whether to request metadata only.
    public var metadata: Bool?

    /// Requested JPIP return stream type (`jpp-stream` or `jpt-stream`).
    public var streamType: JPIPStreamType?

    /// Normative ITU-T Rec. T.808 Clause C.8.1 cache-model items (`model=Hm,H0,P0:128,...`).
    public var model: [String]?

    /// Coding preference for HTJ2K or legacy JPEG 2000 responses.
    public var codingPreference: JPIPCodingPreference?

    /// Deferred query-parsing validation error recorded by ``parseHTTPTarget(_:)``.
    package var parseValidationError: String?

    /// Creates a new JPIP request.
    ///
    /// - Parameter target: The target image identifier.
    public init(target: String) {
        self.target = target
    }

    /// Whether this request explicitly asks for view-window or stream payload delivery
    /// alongside any `cnew` channel creation parameter.
    public var hasViewWindowOrStreamParameters: Bool {
        fsiz != nil || rsiz != nil || roff != nil
            || fvsiz != nil || rvoff != nil || rvsiz != nil || zRange != nil
            || layers != nil || comps != nil || reslevels != nil
            || streamType != nil || model != nil
    }

    /// Builds the URL query dictionary for this request.
    public func buildQueryItems() -> [String: String] {
        var items: [String: String] = [:]

        if !target.isEmpty {
            items["target"] = target
        }

        if let tid = tid, !tid.isEmpty {
            items["tid"] = tid
        }

        if let fsiz = fsiz {
            if let dir = fsizRoundDirection, !dir.isEmpty {
                items["fsiz"] = "\(fsiz.width),\(fsiz.height),\(dir)"
            } else {
                items["fsiz"] = "\(fsiz.width),\(fsiz.height)"
            }
        }

        if let rsiz = rsiz {
            items["rsiz"] = "\(rsiz.width),\(rsiz.height)"
        }

        if let roff = roff {
            items["roff"] = "\(roff.x),\(roff.y)"
        }

        if let fvsiz = fvsiz, !fvsiz.isEmpty {
            let joined = fvsiz.map { "\($0)" }.joined(separator: ",")
            if let dir = fvsizRoundDirection, !dir.isEmpty {
                items["fvsiz"] = "\(joined),\(dir)"
            } else {
                items["fvsiz"] = joined
            }
        }

        if let rvoff = rvoff, !rvoff.isEmpty {
            items["rvoff"] = rvoff.map { "\($0)" }.joined(separator: ",")
        }

        if let rvsiz = rvsiz, !rvsiz.isEmpty {
            items["rvsiz"] = rvsiz.map { "\($0)" }.joined(separator: ",")
        }

        if let zRange = zRange {
            items["zoff"] = "\(zRange.offset)"
            items["zsiz"] = "\(zRange.size)"
        }

        if let layers = layers {
            items["layers"] = "\(layers)"
        }

        if let cid = cid {
            items["cid"] = cid
        }

        if let cnew = cnew {
            items["cnew"] = cnew.rawValue
        }

        if let cclose = cclose, !cclose.isEmpty {
            items["cclose"] = cclose.joined(separator: ",")
        }

        if let len = len {
            items["len"] = "\(len)"
        }

        if let comps = comps, !comps.isEmpty {
            items["comps"] = comps.map { "\($0)" }.joined(separator: ",")
        }

        if let reslevels = reslevels {
            items["reslevels"] = "\(reslevels)"
        }

        if let metadata = metadata, metadata {
            items["meta"] = "yes"
        }

        if let streamType = streamType {
            items["type"] = streamType.rawValue
        }

        if let model = model, !model.isEmpty {
            items["model"] = model.joined(separator: ",")
        }

        if let codingPreference = codingPreference, codingPreference != .none {
            items["pref"] = codingPreference.rawValue
        }

        return items
    }

    /// Parses an incoming HTTP request target (`/<path>?<query>`) into a ``JPIPRequest``.
    public static func parseHTTPTarget(_ rawTarget: String) -> JPIPRequest {
        let split = rawTarget.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(split.first ?? "")
        let queryString = split.count > 1 ? String(split[1]) : ""

        var params: [String: String] = [:]
        if !queryString.isEmpty {
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard !kv.isEmpty else { continue }
                let k = (String(kv[0]).removingPercentEncoding ?? String(kv[0]))
                    .trimmingCharacters(in: .whitespaces)
                let vRaw = kv.count > 1 ? String(kv[1]) : ""
                let v = (vRaw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? vRaw)
                    .trimmingCharacters(in: .whitespaces)
                params[k] = v
            }
        }

        let trimmedPath = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathTarget: String
        if trimmedPath.isEmpty || trimmedPath.lowercased() == "jpip" {
            pathTarget = ""
        } else {
            pathTarget = trimmedPath.removingPercentEncoding ?? trimmedPath
        }

        let targetName = params["target"] ?? pathTarget
        var req = JPIPRequest(target: targetName)
        req.tid = params["tid"]
        req.cid = params["cid"]

        if let cnewVal = params["cnew"]?.lowercased() {
            if cnewVal.contains("ws") {
                req.cnew = .webSocket
            } else if cnewVal.contains("http-tcp") {
                req.cnew = .httpTcp
            } else if cnewVal.contains("http") {
                req.cnew = .http
            }
        }

        let validRoundDirections: Set<String> = ["round-up", "round-down", "closest"]
        func recordParseError(_ message: String) {
            if req.parseValidationError == nil {
                req.parseValidationError = message
            }
        }

        if let ccloseVal = params["cclose"] {
            let items = ccloseVal.split(separator: ",", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            if items.isEmpty || items.contains(where: \.isEmpty) {
                recordParseError("Malformed JPIP cclose= parameter.")
            } else {
                req.cclose = items
            }
        }

        if let fsizVal = params["fsiz"] {
            let tokens = fsizVal.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if (2...3).contains(tokens.count),
               let w = Int(tokens[0]), let h = Int(tokens[1]),
               w > 0, h > 0 {
                req.fsiz = (w, h)
                if tokens.count == 3 {
                    let dir = tokens[2].lowercased()
                    if validRoundDirections.contains(dir) {
                        req.fsizRoundDirection = dir
                    } else {
                        recordParseError("Invalid JPIP fsiz rounding direction '\(tokens[2])'.")
                    }
                }
            } else {
                recordParseError("Malformed JPIP fsiz= parameter '\(fsizVal)'.")
            }
        }

        if let rsizVal = params["rsiz"] {
            let tokens = rsizVal.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if tokens.count == 2,
               let w = Int(tokens[0]), let h = Int(tokens[1]),
               w > 0, h > 0,
               !w.multipliedReportingOverflow(by: h).overflow {
                req.rsiz = (w, h)
            } else {
                recordParseError("Malformed or overflowing JPIP rsiz= parameter '\(rsizVal)'.")
            }
        }

        if let roffVal = params["roff"] {
            let tokens = roffVal.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if tokens.count == 2,
               let ox = Int(tokens[0]), let oy = Int(tokens[1]),
               ox >= 0, oy >= 0 {
                req.roff = (ox, oy)
            } else {
                recordParseError("Malformed JPIP roff= parameter '\(roffVal)'.")
            }
        }

        if let fvsizVal = params["fvsiz"] {
            let tokens = fvsizVal.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if tokens.isEmpty || tokens.count > 17 {
                recordParseError("Malformed JPIP fvsiz= parameter '\(fvsizVal)'.")
            } else {
                var dimTokens = tokens
                if let last = tokens.last, Int(last) == nil {
                    let dir = last.lowercased()
                    if validRoundDirections.contains(dir) && tokens.count >= 2 {
                        req.fvsizRoundDirection = dir
                        dimTokens.removeLast()
                    } else {
                        recordParseError("Invalid JPIP fvsiz rounding direction '\(last)'.")
                    }
                }
                let parsedDims = dimTokens.compactMap { Int($0) }
                if parsedDims.count == dimTokens.count,
                   !parsedDims.isEmpty,
                   parsedDims.allSatisfy({ $0 > 0 }) {
                    req.fvsiz = parsedDims
                } else {
                    recordParseError("Malformed JPIP fvsiz= dimensions '\(fvsizVal)'.")
                }
            }
        }

        if let rvoffVal = params["rvoff"] {
            let tokens = rvoffVal.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let parsed = tokens.compactMap { Int($0) }
            if !tokens.isEmpty, tokens.count <= 16,
               parsed.count == tokens.count,
               parsed.allSatisfy({ $0 >= 0 }) {
                req.rvoff = parsed
            } else {
                recordParseError("Malformed JPIP rvoff= parameter '\(rvoffVal)'.")
            }
        }

        if let rvsizVal = params["rvsiz"] {
            let tokens = rvsizVal.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let parsed = tokens.compactMap { Int($0) }
            if !tokens.isEmpty, tokens.count <= 16,
               parsed.count == tokens.count,
               parsed.allSatisfy({ $0 > 0 }) {
                var product = 1
                var overflowed = false
                for d in parsed {
                    let (p, ov) = product.multipliedReportingOverflow(by: d)
                    if ov { overflowed = true; break }
                    product = p
                }
                if overflowed {
                    recordParseError("Overflowing JPIP rvsiz= parameter '\(rvsizVal)'.")
                } else {
                    req.rvsiz = parsed
                }
            } else {
                recordParseError("Malformed JPIP rvsiz= parameter '\(rvsizVal)'.")
            }
        }

        if let zoffStr = params["zoff"] {
            if let zoff = Int(zoffStr), zoff >= 0 {
                if let zsizStr = params["zsiz"] {
                    if let zsiz = Int(zsizStr), zsiz > 0, !zoff.addingReportingOverflow(zsiz).overflow {
                        req.zRange = (zoff, zsiz)
                    } else {
                        recordParseError("Malformed JPIP zsiz= parameter '\(zsizStr)'.")
                    }
                } else {
                    req.zRange = (zoff, 1)
                }
            } else {
                recordParseError("Malformed JPIP zoff= parameter '\(zoffStr)'.")
            }
        } else if let zsizStr = params["zsiz"] {
            if let zsiz = Int(zsizStr), zsiz > 0 {
                req.zRange = (0, zsiz)
            } else {
                recordParseError("Malformed JPIP zsiz= parameter '\(zsizStr)'.")
            }
        } else if let sliceStr = params["slice"] {
            if let zoff = Int(sliceStr), zoff >= 0 {
                req.zRange = (zoff, 1)
            } else {
                recordParseError("Malformed JPIP slice= parameter '\(sliceStr)'.")
            }
        }

        if let layersVal = params["layers"] {
            if let l = Int(layersVal), l >= 1 {
                req.layers = l
            } else {
                recordParseError("Malformed JPIP layers= parameter '\(layersVal)'.")
            }
        }

        if let lenVal = params["len"] {
            if let l = Int(lenVal), l >= 0 {
                req.len = l
            } else {
                recordParseError("Malformed JPIP len= parameter '\(lenVal)'.")
            }
        }

        if let compsVal = params["comps"] {
            var list: [Int] = []
            var compsValid = !compsVal.isEmpty
            for token in compsVal.split(separator: ",", omittingEmptySubsequences: false) {
                let t = token.trimmingCharacters(in: .whitespaces)
                if t.contains("-") {
                    let parts = t.split(separator: "-", omittingEmptySubsequences: false)
                    if parts.count == 2,
                       let lo = Int(parts[0]), let hi = Int(parts[1]),
                       lo >= 0, lo <= hi, (hi - lo) <= 4096 {
                        list.append(contentsOf: lo...hi)
                    } else {
                        compsValid = false
                    }
                } else if let idx = Int(t), idx >= 0 {
                    list.append(idx)
                } else {
                    compsValid = false
                }
            }
            if compsValid && !list.isEmpty {
                req.comps = list
            } else {
                recordParseError("Malformed JPIP comps= parameter '\(compsVal)'.")
            }
        }

        if let resVal = params["reslevels"] {
            if let r = Int(resVal), (0...64).contains(r) {
                req.reslevels = r
            } else {
                recordParseError("Malformed JPIP reslevels= parameter '\(resVal)'.")
            }
        }

        if let metaVal = params["meta"]?.lowercased() {
            if metaVal == "yes" || metaVal == "true" || metaVal == "1" {
                req.metadata = true
            } else if metaVal == "no" || metaVal == "false" || metaVal == "0" {
                req.metadata = false
            } else {
                recordParseError("Malformed JPIP meta= parameter '\(metaVal)'.")
            }
        }

        if let typeVal = params["type"] {
            // Multiple comma-separated types may be offered; pick first supported.
            for candidate in typeVal.split(separator: ",") {
                if let st = JPIPStreamType(queryValue: String(candidate)) {
                    req.streamType = st
                    break
                }
            }
        }

        if let modelVal = params["model"] {
            if modelVal.isEmpty {
                recordParseError("Empty JPIP model= parameter.")
            } else {
                req.model = modelVal.split(separator: ",", omittingEmptySubsequences: false)
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
            }
        }

        if let prefVal = params["pref"], let pref = JPIPCodingPreference(rawValue: prefVal) {
            req.codingPreference = pref
        }

        return req
    }

    /// Validates all query and view-window fields with checked arithmetic, throwing
    /// ``J2KError/invalidParameter(_:)`` on malformed, negative, or overflowing values.
    public func validateParameters() throws {
        if let err = parseValidationError {
            throw J2KError.invalidParameter(err)
        }
        let validRoundDirections: Set<String> = ["round-up", "round-down", "closest"]
        if let fsiz = fsiz {
            guard fsiz.width > 0, fsiz.height > 0 else {
                throw J2KError.invalidParameter("JPIP fsiz dimensions must be positive.")
            }
        }
        if let dir = fsizRoundDirection, !dir.isEmpty, !validRoundDirections.contains(dir.lowercased()) {
            throw J2KError.invalidParameter("Unsupported JPIP fsiz rounding direction '\(dir)'.")
        }
        if let roff = roff {
            guard roff.x >= 0, roff.y >= 0 else {
                throw J2KError.invalidParameter("JPIP roff coordinates must be non-negative.")
            }
        }
        if let rsiz = rsiz {
            guard rsiz.width > 0, rsiz.height > 0,
                  !rsiz.width.multipliedReportingOverflow(by: rsiz.height).overflow else {
                throw J2KError.invalidParameter("JPIP rsiz dimensions must be positive and non-overflowing.")
            }
            if let roff = roff {
                guard !roff.x.addingReportingOverflow(rsiz.width).overflow,
                      !roff.y.addingReportingOverflow(rsiz.height).overflow else {
                    throw J2KError.invalidParameter("JPIP roff + rsiz overflows integer bounds.")
                }
            }
        }
        if let fvsiz = fvsiz {
            guard !fvsiz.isEmpty, fvsiz.count <= 16, fvsiz.allSatisfy({ $0 > 0 }) else {
                throw J2KError.invalidParameter("JPIP fvsiz dimensions must be 1..16 positive integers.")
            }
        }
        if let dir = fvsizRoundDirection, !dir.isEmpty, !validRoundDirections.contains(dir.lowercased()) {
            throw J2KError.invalidParameter("Unsupported JPIP fvsiz rounding direction '\(dir)'.")
        }
        if let rvoff = rvoff {
            guard !rvoff.isEmpty, rvoff.count <= 16, rvoff.allSatisfy({ $0 >= 0 }) else {
                throw J2KError.invalidParameter("JPIP rvoff coordinates must be non-negative.")
            }
        }
        if let rvsiz = rvsiz {
            guard !rvsiz.isEmpty, rvsiz.count <= 16, rvsiz.allSatisfy({ $0 > 0 }) else {
                throw J2KError.invalidParameter("JPIP rvsiz dimensions must be positive.")
            }
            var prod = 1
            for d in rvsiz {
                let (next, ov) = prod.multipliedReportingOverflow(by: d)
                guard !ov else {
                    throw J2KError.invalidParameter("JPIP rvsiz volume product overflows integer bounds.")
                }
                prod = next
            }
            if let rvoff = rvoff {
                for i in 0..<min(rvoff.count, rvsiz.count) {
                    guard !rvoff[i].addingReportingOverflow(rvsiz[i]).overflow else {
                        throw J2KError.invalidParameter("JPIP rvoff + rvsiz overflows integer bounds.")
                    }
                }
            }
        }
        if let zr = zRange {
            guard zr.offset >= 0, zr.size > 0, !zr.offset.addingReportingOverflow(zr.size).overflow else {
                throw J2KError.invalidParameter("JPIP zoff/zsiz range must be non-negative, positive, and non-overflowing.")
            }
        }
        if let len = len {
            guard len >= 0 else {
                throw J2KError.invalidParameter("JPIP len= must be non-negative.")
            }
        }
        if let layers = layers {
            guard layers >= 1 else {
                throw J2KError.invalidParameter("JPIP layers= must be >= 1.")
            }
        }
        if let res = reslevels {
            guard (0...64).contains(res) else {
                throw J2KError.invalidParameter("JPIP reslevels= must be in 0..64.")
            }
        }
        if let comps = comps {
            guard !comps.isEmpty, comps.allSatisfy({ $0 >= 0 }) else {
                throw J2KError.invalidParameter("JPIP comps= indices must be non-negative.")
            }
        }
        if let modelItems = model {
            _ = try JPIPCacheModel.parseValidatedModelItems(modelItems)
        }
    }
}

/// Channel types for JPIP requests.
public enum JPIPChannelType: String, Sendable {
    /// HTTP channel.
    case http = "http"

    /// HTTP with TCP (persistent connection).
    case httpTcp = "http-tcp"

    /// WebSocket channel.
    case webSocket = "ws"
}

extension JPIPRequest {
    /// Creates a request for a specific region of interest.
    public static func regionRequest(
        target: String,
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        layers: Int? = nil
    ) -> JPIPRequest {
        var request = JPIPRequest(target: target)
        request.roff = (x, y)
        request.rsiz = (width, height)
        request.layers = layers
        return request
    }

    /// Creates a request for a specific resolution.
    public static func resolutionRequest(
        target: String,
        width: Int,
        height: Int,
        layers: Int? = nil
    ) -> JPIPRequest {
        var request = JPIPRequest(target: target)
        request.fsiz = (width, height)
        request.layers = layers
        return request
    }

    /// Creates a request for a specific resolution level.
    public static func resolutionLevelRequest(
        target: String,
        level: Int,
        layers: Int? = nil
    ) -> JPIPRequest {
        var request = JPIPRequest(target: target)
        request.reslevels = level
        request.layers = layers
        return request
    }

    /// Creates a request for specific image components.
    public static func componentRequest(
        target: String,
        components: [Int],
        layers: Int? = nil
    ) -> JPIPRequest {
        var request = JPIPRequest(target: target)
        request.comps = components
        request.layers = layers
        return request
    }

    /// Creates a request for progressive quality with increasing layers.
    public static func progressiveQualityRequest(
        target: String,
        upToLayers: Int
    ) -> JPIPRequest {
        var request = JPIPRequest(target: target)
        request.layers = upToLayers
        return request
    }

    /// Creates a request for metadata only (no image data).
    public static func metadataRequest(target: String) -> JPIPRequest {
        var request = JPIPRequest(target: target)
        request.metadata = true
        return request
    }

    /// Extracts full-resolution reference grid dimensions `(Xsiz - XOsiz, Ysiz - YOsiz)`
    /// from a JPEG 2000 `Class 6` main header (`SIZ` marker `0xFF51`).
    public static func extractCodestreamDimensions(fromMainHeader mainHeader: Data) -> (width: Int, height: Int)? {
        let bytes = [UInt8](mainHeader)
        guard bytes.count >= 42, bytes[0] == 0xFF, bytes[1] == 0x4F else { return nil }
        var cursor = 2
        while cursor + 4 <= bytes.count {
            let m = UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1])
            let segLen = Int(UInt16(bytes[cursor + 2]) << 8 | UInt16(bytes[cursor + 3]))
            guard segLen >= 2, cursor + 2 + segLen <= bytes.count else { break }
            if m == 0xFF51 && segLen >= 38 {
                let p = cursor + 2
                func u32(_ off: Int) -> Int {
                    Int(UInt32(bytes[p + off]) << 24 | UInt32(bytes[p + off + 1]) << 16
                        | UInt32(bytes[p + off + 2]) << 8 | UInt32(bytes[p + off + 3]))
                }
                let xsiz = u32(4), ysiz = u32(8), xosiz = u32(12), yosiz = u32(16)
                let w = xsiz - xosiz
                let h = ysiz - yosiz
                if w > 0 && h > 0 {
                    return (w, h)
                }
            }
            cursor += 2 + segLen
        }
        return nil
    }

    /// Extracts full-resolution 3D reference-grid extents and decomposition levels from a Part 10 JP3D
    /// `Class 6` main header (`SIZ` + `NSI` + `COD`).
    public static func extract3DCodestreamDimensions(
        fromMainHeader mainHeader: Data
    ) -> (width: Int, height: Int, depth: Int, levelsX: Int, levelsY: Int, levelsZ: Int)? {
        guard JP3DJPIPIndexer.isJP3DCodestream(mainHeader) else { return nil }
        var synthetic = mainHeader
        // Append one minimal empty 14-byte tile-part + EOC so `JP3DCodestreamParser` validates the full main header.
        synthetic.append(contentsOf: [
            0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x0E, 0x00, 0x01,
            0xFF, 0x93, 0xFF, 0xD9
        ])
        guard let parsed = try? JP3DCodestreamParser().parse(synthetic) else { return nil }
        let w = parsed.siz.width - parsed.siz.originX
        let h = parsed.siz.height - parsed.siz.originY
        let d = parsed.siz.depth - parsed.siz.originZ
        guard w > 0, h > 0, d > 0 else { return nil }
        return (w, h, d, parsed.cod.levelsX, parsed.cod.levelsY, parsed.cod.levelsZ)
    }

    /// Computes ITU-T Rec. T.808 Clause C.4.5 3D frame size `[fx, fy, fz]` at `resolutionLevel`
    /// (`0` = full resolution, `k > 0` = reduced by `k` DWT levels per axis up to `(levelsX, levelsY, levelsZ)`).
    public static func frameDimensions3D(
        fullWidth: Int,
        fullHeight: Int,
        fullDepth: Int,
        levelsX: Int,
        levelsY: Int,
        levelsZ: Int,
        resolutionLevel: Int
    ) -> [Int] {
        let r = max(0, resolutionLevel)
        let sx = min(r, max(0, levelsX))
        let sy = min(r, max(0, levelsY))
        let sz = min(r, max(0, levelsZ))
        let fx = max(1, (fullWidth + (1 << sx) - 1) >> sx)
        let fy = max(1, (fullHeight + (1 << sy) - 1) >> sy)
        let fz = max(1, (fullDepth + (1 << sz) - 1) >> sz)
        return [fx, fy, fz]
    }
}
