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
// 3D depth window (`zoff`, `zsiz`), and HTTP query-string parsing.

import Foundation

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

    /// Optional 3D depth offset and extent (`zoff`, `zsiz`) for volumetric Part 10 JP3D targets.
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

    /// Resolution levels to request (`0` = full resolution, higher values = lower resolution).
    public var reslevels: Int?

    /// Whether to request metadata only.
    public var metadata: Bool?

    /// Requested JPIP return stream type (`jpp-stream` or `jpt-stream`).
    public var streamType: JPIPStreamType?

    /// Normative ITU-T Rec. T.808 Clause C.8.1 cache-model items (`model=Hm,H0,P0:128,...`).
    public var model: [String]?

    /// Coding preference for HTJ2K or legacy JPEG 2000 responses.
    public var codingPreference: JPIPCodingPreference?

    /// Creates a new JPIP request.
    ///
    /// - Parameter target: The target image identifier.
    public init(target: String) {
        self.target = target
    }

    /// Whether this request explicitly asks for view-window or stream payload delivery
    /// alongside any `cnew` channel creation parameter.
    public var hasViewWindowOrStreamParameters: Bool {
        fsiz != nil || rsiz != nil || roff != nil || zRange != nil
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

        if let ccloseVal = params["cclose"], !ccloseVal.isEmpty {
            req.cclose = ccloseVal.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }

        if let fsizVal = params["fsiz"] {
            let tokens = fsizVal.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let nums = tokens.prefix(2).compactMap { Int($0) }
            if nums.count == 2 {
                req.fsiz = (nums[0], nums[1])
                if tokens.count >= 3 && !tokens[2].isEmpty && Int(tokens[2]) == nil {
                    req.fsizRoundDirection = tokens[2].lowercased()
                }
            }
        }

        if let rsizVal = params["rsiz"] {
            let nums = rsizVal.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if nums.count >= 2 {
                req.rsiz = (nums[0], nums[1])
            }
        }

        if let roffVal = params["roff"] {
            let nums = roffVal.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            if nums.count >= 2 {
                req.roff = (nums[0], nums[1])
            }
        }

        if let zoffStr = params["zoff"], let zoff = Int(zoffStr) {
            let zsiz = params["zsiz"].flatMap(Int.init) ?? 1
            req.zRange = (zoff, max(1, zsiz))
        } else if let sliceStr = params["slice"], let zoff = Int(sliceStr) {
            req.zRange = (zoff, 1)
        }

        if let layersVal = params["layers"], let l = Int(layersVal) {
            req.layers = l
        }

        if let lenVal = params["len"], let l = Int(lenVal) {
            req.len = l
        }

        if let compsVal = params["comps"] {
            var list: [Int] = []
            for token in compsVal.split(separator: ",") {
                let t = token.trimmingCharacters(in: .whitespaces)
                if t.contains("-") {
                    let bounds = t.split(separator: "-").compactMap { Int($0) }
                    if bounds.count == 2, bounds[0] <= bounds[1], bounds[1] - bounds[0] <= 4096 {
                        list.append(contentsOf: bounds[0]...bounds[1])
                    }
                } else if let idx = Int(t) {
                    list.append(idx)
                }
            }
            if !list.isEmpty { req.comps = list }
        }

        if let resVal = params["reslevels"], let r = Int(resVal) {
            req.reslevels = r
        }

        if let metaVal = params["meta"]?.lowercased() {
            if metaVal == "yes" || metaVal == "true" || metaVal == "1" {
                req.metadata = true
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

        if let modelVal = params["model"], !modelVal.isEmpty {
            req.model = modelVal.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        }

        if let prefVal = params["pref"], let pref = JPIPCodingPreference(rawValue: prefVal) {
            req.codingPreference = pref
        }

        return req
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
}
