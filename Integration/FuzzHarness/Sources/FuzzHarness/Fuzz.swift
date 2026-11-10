// SPDX-License-Identifier: MIT
// Mutation-based fuzz campaign for SwiftJ2K, SwiftJ2K3D, and SwiftJ2KJPIP entry
// points (TESTING.md TEST-05). Deterministic: the seed corpus is built from the
// repository's conformant fixtures and deterministic in-memory 3D/JPIP wire
// encodings, and every mutation derives from a SplitMix64 stream seeded from
// --seed, so any finding is reproducible from (seed, iteration).
//
//   FuzzHarness --entry <entry> --seconds N --seed N
//               [--corpus DIR] --output DIR [--slow-ms N]
//
// Supported --entry values:
//   2D (SwiftJ2K):       inspect | decode | decodeInto | transcodeToHT | transcodeToJ2K
//   3D (SwiftJ2K3D):     inspect3d | decode3d | roi3d | transcode3d | transcode3dToHT | transcode3dToJ2K
//   JPIP (SwiftJ2KJPIP): jpipStream | jpipRequest | jpipWebSocketFrame
//
// Before every execution the input is written to <output>/current.bin and its
// provenance to <output>/current.json, so a trap or hang leaves its reproducer
// on disk. Inputs that take longer than --slow-ms are kept as slow-*.bin.
// Outcomes are counted by CodecError category (plus J2KError category on
// low-level JPIP wire/grammar parsers); any other error is a finding and is
// kept as unexpected-*.bin. This is a bounded mutation experiment, not
// coverage-guided fuzzing.

import Foundation
import SwiftJ2K
import SwiftJ2K3D
import SwiftJ2KJPIP

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
}

enum Mutation: Int, CaseIterable {
    case truncate, bitFlip, byteSet, deleteChunk, insertChunk, duplicateChunk, markerLength, headerField, splice, zeroRun
}

struct Mutator {
    let seeds: [[UInt8]]

    func apply(_ op: Mutation, to bytes: inout [UInt8], rng: inout SplitMix64) {
        guard !bytes.isEmpty else { bytes = [rng.byte()]; return }
        let n = bytes.count
        switch op {
        case .truncate:
            bytes.removeSubrange(rng.below(n)..<n)
        case .bitFlip:
            for _ in 0..<(1 + rng.below(8)) {
                let i = rng.below(n); bytes[i] ^= UInt8(1 << rng.below(8))
            }
        case .byteSet:
            for _ in 0..<(1 + rng.below(4)) {
                let i = rng.below(n)
                bytes[i] = [0x00, 0xFF, rng.byte()][rng.below(3)]
            }
        case .deleteChunk:
            let start = rng.below(n); let length = min(1 + rng.below(64), n - start)
            bytes.removeSubrange(start..<(start + length))
        case .insertChunk:
            let position = rng.below(n + 1)
            let chunk = (0..<(1 + rng.below(64))).map { _ in rng.byte() }
            bytes.insert(contentsOf: chunk, at: position)
        case .duplicateChunk:
            let start = rng.below(n); let length = min(1 + rng.below(64), n - start)
            let chunk = Array(bytes[start..<(start + length)])
            bytes.insert(contentsOf: chunk, at: rng.below(n + 1))
        case .markerLength:
            // Every 0xFF 0x4F..0xFF pair that carries a length field.
            var positions: [Int] = []
            var i = 0
            while i + 3 < n {
                if bytes[i] == 0xFF, bytes[i + 1] >= 0x4F, bytes[i + 1] != 0xFF, bytes[i + 1] != 0x4F,
                   bytes[i + 1] != 0x93, bytes[i + 1] != 0xD9 {
                    positions.append(i + 2)
                }
                i += 1
            }
            guard let at = positions.isEmpty ? nil : positions[rng.below(positions.count)] else { return }
            let value: UInt16 = [0, 1, 2, 3, 0xFFFF, 0x8000, UInt16(truncatingIfNeeded: rng.next())][rng.below(7)]
            bytes[at] = UInt8(value >> 8); bytes[at + 1] = UInt8(value & 0xFF)
        case .headerField:
            // SIZ/NSI/COD/VBAS/WS header fields live in the first tens of bytes.
            guard n >= 6 else { return }
            let at = min(n - 2, rng.below(min(n, 80)))
            let value: UInt16 = [0, 1, 0xFFFF, 0x8000, 0x7FFF, UInt16(truncatingIfNeeded: rng.next())][rng.below(6)]
            bytes[at] = UInt8(value >> 8)
            if at + 1 < n { bytes[at + 1] = UInt8(value & 0xFF) }
        case .splice:
            let other = seeds[rng.below(seeds.count)]
            guard !other.isEmpty else { return }
            let cut = rng.below(n); let from = rng.below(other.count)
            bytes = Array(bytes[0..<cut]) + Array(other[from...])
        case .zeroRun:
            let start = rng.below(n); let length = min(1 + rng.below(256), n - start)
            for i in start..<(start + length) { bytes[i] = 0 }
        }
    }

    func mutate(_ input: [UInt8], rng: inout SplitMix64) -> ([UInt8], [String]) {
        var bytes = input
        var applied: [String] = []
        for _ in 0..<(1 + rng.below(4)) {
            let op = Mutation.allCases[rng.below(Mutation.allCases.count)]
            apply(op, to: &bytes, rng: &rng)
            applied.append("\(op)")
        }
        return (bytes, applied)
    }
}

func peakResidentBytes() -> Int {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    #if os(Linux)
    return Int(usage.ru_maxrss) * 1024
    #else
    return Int(usage.ru_maxrss)
    #endif
}

private let allEntries: Set<String> = [
    "inspect", "decode", "decodeInto", "transcodeToHT", "transcodeToJ2K",
    "inspect3d", "decode3d", "roi3d", "transcode3d", "transcode3dToHT", "transcode3dToJ2K",
    "jpipStream", "jpipRequest", "jpipWebSocketFrame",
]

private let jpipWireEntries: Set<String> = [
    "jpipStream", "jpipRequest", "jpipWebSocketFrame",
]

private func makeVolumeSeeds() async throws -> [(name: String, bytes: [UInt8])] {
    var out: [(String, [UInt8])] = []

    // 1. 8x8x4 12-bit unsigned Part 10 EBCOT lossless (5/3)
    var v12 = Data(count: 8 * 8 * 4 * 2)
    v12.withUnsafeMutableBytes { raw in
        let p = raw.bindMemory(to: UInt16.self)
        for i in 0..<(8 * 8 * 4) { p[i] = UInt16((i * 97 + 13) & 0x0FFF) }
    }
    let vol12 = J2KVolume(width: 8, height: 8, depth: 4, components: [
        J2KVolumeComponent(index: 0, bitDepth: 12, signed: false, width: 8, height: 8, depth: 4, data: v12)
    ])
    let cfgLossless = try VolumeEncoderConfiguration(
        compressionMode: .lossless,
        tiling: JP3DTilingConfiguration(tileSizeX: 4, tileSizeY: 4, tileSizeZ: 2),
        progressionOrder: .lrcps,
        qualityLayers: 1,
        levelsX: 1, levelsY: 1, levelsZ: 1
    )
    let encLossless = try await VolumeEncoder(configuration: cfgLossless).encode(vol12)
    out.append(("synthetic:jp3d_8x8x4_u12_ebcot_lossless", [UInt8](encLossless.data)))

    // 2. 8x8x4 12-bit signed HTJ2K-in-JP3D lossless
    let vol12Signed = J2KVolume(width: 8, height: 8, depth: 4, components: [
        J2KVolumeComponent(index: 0, bitDepth: 12, signed: true, width: 8, height: 8, depth: 4, data: v12)
    ])
    let cfgHTLossless = try VolumeEncoderConfiguration(
        compressionMode: .losslessHTJ2K,
        tiling: JP3DTilingConfiguration(tileSizeX: 8, tileSizeY: 8, tileSizeZ: 4),
        progressionOrder: .slrcp,
        qualityLayers: 1,
        levelsX: 1, levelsY: 1, levelsZ: 1
    )
    let encHTLossless = try await VolumeEncoder(configuration: cfgHTLossless).encode(vol12Signed)
    out.append(("synthetic:jp3d_8x8x4_s12_htj2k_lossless", [UInt8](encHTLossless.data)))

    // 3. 8x8x4 8-bit unsigned Part 10 EBCOT lossy (9/7 visuallyLossless, 2 layers)
    var v8 = Data(count: 8 * 8 * 4)
    for i in 0..<v8.count { v8[i] = UInt8((i * 37 + 19) & 0xFF) }
    let vol8 = J2KVolume(width: 8, height: 8, depth: 4, components: [
        J2KVolumeComponent(index: 0, bitDepth: 8, signed: false, width: 8, height: 8, depth: 4, data: v8)
    ])
    let cfgLossy = try VolumeEncoderConfiguration(
        compressionMode: .visuallyLossless,
        tiling: JP3DTilingConfiguration(tileSizeX: 8, tileSizeY: 8, tileSizeZ: 4),
        progressionOrder: .rlcps,
        qualityLayers: 2,
        levelsX: 1, levelsY: 1, levelsZ: 1
    )
    let encLossy = try await VolumeEncoder(configuration: cfgLossy).encode(vol8)
    out.append(("synthetic:jp3d_8x8x4_u8_ebcot_lossy97", [UInt8](encLossy.data)))

    // 4. 8x8x4 8-bit lossy HTJ2K-in-JP3D
    let cfgHTLossy = try VolumeEncoderConfiguration(
        compressionMode: .lossyHTJ2K(psnr: 38.0),
        tiling: JP3DTilingConfiguration(tileSizeX: 8, tileSizeY: 8, tileSizeZ: 4),
        progressionOrder: .lrcps,
        qualityLayers: 1,
        levelsX: 1, levelsY: 1, levelsZ: 1
    )
    let encHTLossy = try await VolumeEncoder(configuration: cfgHTLossy).encode(vol8)
    out.append(("synthetic:jp3d_8x8x4_u8_htj2k_lossy", [UInt8](encHTLossy.data)))

    // 5. 4x4x2 24-bit unsigned Part 2 extended-precision bit-split JP3D
    var v24 = Data(count: 4 * 4 * 2 * 3)
    for i in 0..<(4 * 4 * 2) {
        let sample = UInt32((i * 0x13_579B + 0x01_0203) & 0xFF_FFFF)
        v24[i * 3] = UInt8(sample & 0xFF)
        v24[i * 3 + 1] = UInt8((sample >> 8) & 0xFF)
        v24[i * 3 + 2] = UInt8((sample >> 16) & 0xFF)
    }
    let vol24 = J2KVolume(width: 4, height: 4, depth: 2, components: [
        J2KVolumeComponent(index: 0, bitDepth: 24, signed: false, width: 4, height: 4, depth: 2, data: v24)
    ])
    let cfgBitSplit = try VolumeEncoderConfiguration(
        compressionMode: .lossless,
        tiling: JP3DTilingConfiguration(tileSizeX: 4, tileSizeY: 4, tileSizeZ: 2),
        progressionOrder: .lrcps,
        qualityLayers: 1,
        levelsX: 1, levelsY: 1, levelsZ: 1
    )
    if let enc24 = try? await VolumeEncoder(configuration: cfgBitSplit).encode(vol24) {
        out.append(("synthetic:jp3d_4x4x2_u24_part2_bitsplit", [UInt8](enc24.data)))
    }

    return out
}

private func makeJPIPSeeds(entry: String) async throws -> [(name: String, bytes: [UInt8])] {
    if entry == "jpipRequest" {
        let targets: [(String, String)] = [
            ("req:2d_jpp_window", "/jpip?target=ct.j2k&fsiz=256,256,round-up&roff=16,16&rsiz=64,64&layers=2&type=jpp-stream&len=4096"),
            ("req:2d_jpt_cnew_ws", "/ct.jp2?cnew=ws,http&type=jpt-stream&reslevels=1&comps=0-2&meta=yes&pref=htj2k"),
            ("req:cache_model_csn_implicit", "/jpip?cid=ch-1&model=[0]Hm,Ht0:32,[1-2]Hp0:L2,-[0]t0-1c0r0-2p*:64,s0-3"),
            ("req:3d_jp3d_volume_window", "/jpip?target=vol.jp3d&fvsiz=32,32,16,closest&rvoff=4,4,2&rvsiz=16,16,8&layers=1&type=jpp-stream"),
            ("req:3d_zslice_cclose", "/jpip?cid=ch-2&zoff=2&zsiz=4&cclose=ch-2"),
            ("req:raw_cache_model", "[0]Hm,Ht0:32,[1]Hp0:L2,-[0]t0-1c0r0-2p*:64,s0-3"),
        ]
        return targets.map { ($0.0, [UInt8]($0.1.utf8)) }
    }

    // Synthesize compact 2D (.j2k + .jp2) and 3D (.jp3d) codestreams for wire-stream & WebSocket seeds
    let desc = try ImageDescriptor.greyscale16(width: 16, height: 16, meaningfulBits: 12)
    let img = try ImageDestination.allocate(descriptor: desc).writeUInt16 { x, y in
        UInt16((x * 97 + y * 131) & 0x0FFF)
    }
    let enc2DJ2K = try await Encoder(
        configuration: EncoderConfiguration(mode: .lossless, codecOptions: CodecOptions(containerFormat: .codestream))
    ).encode(img)
    let enc2DJP2 = try await Encoder(
        configuration: EncoderConfiguration(mode: .lossless, codecOptions: CodecOptions(containerFormat: .jp2))
    ).encode(img)
    let volSeeds = try await makeVolumeSeeds()
    let jp3dData = Data(volSeeds[0].bytes)

    let gen = JPIPDataBinGenerator()
    let jpp2D = try gen.generateWireDataBins(from: enc2DJ2K.data, defaultStreamType: .jppStream)
    let jpt2D = try gen.generateWireDataBins(from: enc2DJ2K.data, defaultStreamType: .jptStream)
    let jppJP2 = try gen.generateWireDataBins(from: enc2DJP2.data, defaultStreamType: .jppStream)
    var req3D = JPIPRequest(target: "vol.jp3d")
    req3D.fvsiz = [8, 8, 4]
    req3D.rvoff = [0, 0, 0]
    req3D.rvsiz = [4, 4, 2]
    let jpp3D = try gen.generateWireDataBins(from: jp3dData, request: req3D, defaultStreamType: .jppStream)
    let jpt3D = try gen.generateWireDataBins(from: jp3dData, defaultStreamType: .jptStream)

    let streamJPP2D = JPIPWireCodec.encodeStream(bins: jpp2D.bins, includeEOR: true, eorReason: .windowDone)
    let streamJPT2D = JPIPWireCodec.encodeStream(bins: jpt2D.bins, includeEOR: true, eorReason: .imageDone)
    let streamJP2 = JPIPWireCodec.encodeStream(bins: jppJP2.bins, includeEOR: true, eorReason: .windowDone)
    let streamJPP3D = JPIPWireCodec.encodeStream(bins: jpp3D.bins, includeEOR: true, eorReason: .windowDone)
    let streamJPT3D = JPIPWireCodec.encodeStream(bins: jpt3D.bins, includeEOR: true, eorReason: .imageDone)

    if entry == "jpipStream" {
        return [
            ("synthetic:jpip_2d_jpp_stream", [UInt8](streamJPP2D)),
            ("synthetic:jpip_2d_jpt_stream", [UInt8](streamJPT2D)),
            ("synthetic:jpip_2d_jp2_container_stream", [UInt8](streamJP2)),
            ("synthetic:jpip_3d_jp3d_jpp_stream", [UInt8](streamJPP3D)),
            ("synthetic:jpip_3d_jp3d_jpt_stream", [UInt8](streamJPT3D)),
        ]
    }

    // entry == "jpipWebSocketFrame"
    let wsEncoder = JPIPWebSocketMessageEncoder()
    var wsReq = JPIPRequest(target: "vol.jp3d")
    wsReq.fvsiz = [8, 8, 4]
    wsReq.rvoff = [2, 2, 0]
    wsReq.rvsiz = [4, 4, 2]
    wsReq.model = ["[0]Hm", "t0c0r0p0:32"]
    let frameReq = wsEncoder.encodeRequest(wsReq, requestID: 7).serialize()

    let resp = JPIPResponse(
        channelID: "ws-ch-1",
        data: streamJPP3D,
        statusCode: 200,
        headers: ["Content-Type": "image/jpp-stream", "JPIP-cnew": "cid=ws-ch-1,transport=ws"]
    )
    let frameResp = wsEncoder.encodeResponse(resp, requestID: 7).serialize()

    var sampleBin = jpp2D.bins.first ?? JPIPDataBin(binClass: .precinct, binID: 3, data: Data([0x01, 0x02, 0x03]), isComplete: false)
    sampleBin = JPIPDataBin(
        binClass: .extendedPrecinct,
        binID: sampleBin.binID,
        data: sampleBin.data,
        isComplete: true,
        codestreamID: 2,
        msgOffset: 16,
        aux: 1
    )
    let frameBin = wsEncoder.encodeDataBin(sampleBin, requestID: 9).serialize()
    let frameCtrl = JPIPWebSocketFrame(type: .control, payload: Data("cclose=ws-ch-1".utf8), requestID: 10).serialize()

    return [
        ("synthetic:ws_request_frame", [UInt8](frameReq)),
        ("synthetic:ws_response_jpp3d_frame", [UInt8](frameResp)),
        ("synthetic:ws_extended_databin_frame", [UInt8](frameBin)),
        ("synthetic:ws_control_frame", [UInt8](frameCtrl)),
    ]
}

@main
struct Fuzz {
    static func option(_ name: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static func main() async throws {
        let entry = option("--entry") ?? "decode"
        let seconds = Double(option("--seconds") ?? "60") ?? 60
        let seed = UInt64(option("--seed") ?? "1") ?? 1
        let slowMilliseconds = Double(option("--slow-ms") ?? "2000") ?? 2000
        let corpus = URL(fileURLWithPath: option("--corpus") ?? "Tests/SwiftJ2KTests/Fixtures/Lossless")
        let output = URL(fileURLWithPath: option("--output") ?? "fuzz-output")
        guard allEntries.contains(entry) else {
            FileHandle.standardError.write(Data("unknown --entry \(entry)\n".utf8)); exit(2)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let names: [String]
        let seeds: [[UInt8]]
        if entry.hasSuffix("3d") || entry.contains("3dTo") {
            var pairs = try await makeVolumeSeeds()
            if let extra = try? FileManager.default.contentsOfDirectory(atPath: corpus.path)
                .filter({ $0.hasSuffix(".jp3d") || $0.hasSuffix(".j3d") }).sorted() {
                for f in extra {
                    if let d = try? Data(contentsOf: corpus.appendingPathComponent(f)) {
                        pairs.append((f, [UInt8](d)))
                    }
                }
            }
            names = pairs.map(\.name)
            seeds = pairs.map(\.bytes)
        } else if jpipWireEntries.contains(entry) {
            let pairs = try await makeJPIPSeeds(entry: entry)
            names = pairs.map(\.name)
            seeds = pairs.map(\.bytes)
        } else {
            let fileNames = try FileManager.default.contentsOfDirectory(atPath: corpus.path)
                .filter { $0.hasSuffix(".j2k") || $0.hasSuffix(".j2c") }.sorted()
            names = fileNames
            seeds = try fileNames.map { [UInt8](try Data(contentsOf: corpus.appendingPathComponent($0))) }
        }
        guard !seeds.isEmpty else { FileHandle.standardError.write(Data("empty corpus\n".utf8)); exit(2) }

        let limits = try ResourceLimits(
            maximumCompressedBytes: 8 << 20,
            maximumDecodedBytes: 64 << 20,
            maximumWorkspaceBytes: 256 << 20,
            maximumPixels: 8_000_000,
            maximumDimension: 8192,
            maximumFrames: 512,
            deadlineSeconds: 5,
            maximumMemoryBytes: 512 << 20
        )
        let options = DecodeOptions(resourceLimits: limits)
        let transcodeOptions = TranscodeOptions(resourceLimits: limits)
        let volDecodeOptions = VolumeDecodeOptions(resourceLimits: limits)
        let volROIOptions = VolumeDecodeOptions(
            resourceLimits: limits,
            regionOfInterest: JP3DRegion(originX: 1, originY: 1, originZ: 0, width: 4, height: 4, depth: 2)
        )

        let decoder = try Decoder()
        let transcoder = try Transcoder()
        let volumeDecoder = try VolumeDecoder()
        let volumeTranscoder = try VolumeTranscoder()
        let jpipGenerator = JPIPDataBinGenerator()
        let wsEncoder = JPIPWebSocketMessageEncoder()

        let mutator = Mutator(seeds: seeds)
        var rng = SplitMix64(state: seed)
        let clock = ContinuousClock()
        let started = clock.now

        var iterations = 0
        var categories: [String: Int] = [:]
        var slowest = 0.0, slowCount = 0, unexpectedCount = 0
        var lastProgress = started
        var applied: [String: Int] = [:]

        func writeProgress(final: Bool) throws {
            let elapsed = clock.now - started
            let summary: [String: Any] = [
                "entry": entry, "seed": seed, "iterations": iterations, "final": final,
                "elapsedSeconds": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
                "outcomes": categories, "mutations": applied, "slowestMilliseconds": slowest,
                "slowInputsKept": slowCount, "unexpectedErrors": unexpectedCount,
                "peakResidentBytes": peakResidentBytes(), "corpus": names,
                "limits": [
                    "deadlineSeconds": limits.deadlineSeconds,
                    "maximumDecodedBytes": limits.maximumDecodedBytes,
                    "maximumWorkspaceBytes": limits.maximumWorkspaceBytes,
                    "maximumPixels": limits.maximumPixels,
                    "maximumFrames": limits.maximumFrames,
                ],
            ]
            let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: output.appendingPathComponent(final ? "summary.json" : "progress.json"))
        }

        while clock.now - started < .seconds(seconds) {
            let seedIndex = rng.below(seeds.count)
            let (bytes, ops) = mutator.mutate(seeds[seedIndex], rng: &rng)
            iterations += 1
            try Data(bytes).write(to: output.appendingPathComponent("current.bin"))
            let provenance = "{\"iteration\":\(iterations),\"seed\":\(seed),\"source\":\"\(names[seedIndex])\",\"mutations\":\(ops)}\n"
            try Data(provenance.utf8).write(to: output.appendingPathComponent("current.json"))
            for op in ops { applied[op, default: 0] += 1 }

            let data = Data(bytes)
            let before = clock.now
            var category: String
            do {
                switch entry {
                case "inspect":
                    _ = try decoder.inspect(data, options: options)
                case "decode":
                    _ = try await decoder.decode(data, options: options)
                case "transcodeToHT":
                    _ = try await transcoder.transcode(data, to: .htj2k, options: transcodeOptions)
                case "transcodeToJ2K":
                    _ = try await transcoder.transcode(data, to: .jpeg2000, options: transcodeOptions)
                case "decodeInto":
                    let info = try decoder.inspect(data, options: options)
                    let destination = try ImageDestination.allocate(descriptor: info.descriptor, limits: limits)
                    _ = try await decoder.decode(data, into: destination, options: options)

                case "inspect3d":
                    _ = try volumeDecoder.inspect(data, options: volDecodeOptions)
                case "decode3d":
                    let opts = (iterations & 3) == 0 ? volROIOptions : volDecodeOptions
                    _ = try await volumeDecoder.decode(data, options: opts)
                case "roi3d":
                    _ = try await volumeDecoder.decode(data, options: volROIOptions)
                case "transcode3d":
                    let target: TranscodeTarget = (iterations & 1) == 0 ? .htj2k : .jpeg2000
                    _ = try await volumeTranscoder.transcode(data, to: target, options: transcodeOptions)
                case "transcode3dToHT":
                    _ = try await volumeTranscoder.transcode(data, to: .htj2k, options: transcodeOptions)
                case "transcode3dToJ2K":
                    _ = try await volumeTranscoder.transcode(data, to: .jpeg2000, options: transcodeOptions)

                case "jpipStream":
                    let parsed = try JPIPWireCodec.decodeStream(data, maxPayloadBytes: 8 << 20)
                    if let mh = parsed.bins.first(where: { $0.binClass == .mainHeader })?.data {
                        _ = JPIPRequest.extractCodestreamDimensions(fromMainHeader: mh)
                        _ = JPIPRequest.extract3DCodestreamDimensions(fromMainHeader: mh)
                    }
                    _ = try jpipGenerator.reassembleCodestreamThrowing(
                        from: parsed.bins,
                        reconstructContainer: (iterations & 1) == 0,
                        limits: limits
                    )

                case "jpipRequest":
                    let raw = String(decoding: bytes, as: UTF8.self)
                    if raw.hasPrefix("/") {
                        let req = JPIPRequest.parseHTTPTarget(raw)
                        _ = req.buildQueryItems()
                        try req.validateParameters()
                        if let model = req.model {
                            _ = try JPIPCacheModel.parseValidatedModelItems(model, sessionBased: (iterations & 1) == 0)
                        }
                    } else {
                        let items = raw.split(separator: ",").map(String.init)
                        _ = try JPIPCacheModel.parseValidatedModelItems(
                            items.isEmpty ? [raw] : items,
                            sessionBased: (iterations & 1) == 0
                        )
                    }

                case "jpipWebSocketFrame":
                    if let frame = JPIPWebSocketFrame.deserialize(from: data) {
                        if let req = wsEncoder.decodeRequest(from: frame) {
                            try req.validateParameters()
                        }
                        if let resp = wsEncoder.decodeResponse(from: frame) {
                            _ = try JPIPWireCodec.decodeStream(resp.data, maxPayloadBytes: 4 << 20)
                        }
                        if let bin = wsEncoder.decodeDataBin(from: frame) {
                            _ = try jpipGenerator.reassembleCodestreamThrowing(from: [bin], limits: limits)
                        }
                    }

                default:
                    throw CodecError(.invalidArgument, "Unhandled entry \(entry)")
                }
                category = "success"
            } catch let error as CodecError {
                category = "\(error.category)"
            } catch let error as J2KError where jpipWireEntries.contains(entry) {
                category = "j2k:\(error.asCodecError.category)"
            } catch is CancellationError {
                category = "cancelled"
            } catch {
                category = "unexpected:\(type(of: error))"
                unexpectedCount += 1
                try data.write(to: output.appendingPathComponent("unexpected-\(iterations).bin"))
            }
            let elapsed = clock.now - before
            let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            slowest = max(slowest, milliseconds)
            if milliseconds > slowMilliseconds {
                slowCount += 1
                try data.write(to: output.appendingPathComponent("slow-\(iterations)-\(Int(milliseconds))ms.bin"))
            }
            categories[category, default: 0] += 1
            if clock.now - lastProgress > .seconds(30) { try writeProgress(final: false); lastProgress = clock.now }
        }
        try writeProgress(final: true)
        try? FileManager.default.removeItem(at: output.appendingPathComponent("current.bin"))
        try? FileManager.default.removeItem(at: output.appendingPathComponent("current.json"))
        print("\(entry): \(iterations) iterations, outcomes \(categories.sorted { $0.key < $1.key }), slowest \(Int(slowest)) ms, unexpected \(unexpectedCount), peak RSS \(peakResidentBytes() >> 20) MiB")
        exit(unexpectedCount == 0 ? 0 : 1)
    }
}
