// SPDX-License-Identifier: Apache-2.0
// Mutation-based fuzz campaign for the SwiftJ2K decode entry points
// (TESTING.md TEST-05). Deterministic: the seed corpus is the repository's
// conformant fixtures and every mutation derives from a SplitMix64 stream
// seeded from --seed, so a finding is reproducible from (seed, iteration).
//
//   FuzzHarness --entry inspect|decode|decodeInto --seconds N --seed N
//               --corpus DIR --output DIR [--slow-ms N]
//
// Before every execution the input is written to <output>/current.bin and its
// provenance to <output>/current.json, so a trap or hang leaves its reproducer
// on disk. Inputs that take longer than --slow-ms are kept as slow-*.bin.
// Outcomes are counted by CodecError category; any error that is not a
// CodecError or CancellationError is a finding and is kept as unexpected-*.bin.
// This is a bounded mutation experiment, not coverage-guided fuzzing.

import Foundation
import SwiftJ2K

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
            // SIZ and COD fields live in the first tens of bytes: dimensions,
            // origins, tile sizes, precision, levels, code-block exponents.
            guard n >= 6 else { return }
            let at = 4 + rng.below(min(n, 80) - 5)
            let value: UInt16 = [0, 1, 0xFFFF, 0x8000, 0x7FFF, UInt16(truncatingIfNeeded: rng.next())][rng.below(6)]
            bytes[at] = UInt8(value >> 8)
            if at + 1 < n { bytes[at + 1] = UInt8(value & 0xFF) }
        case .splice:
            let other = seeds[rng.below(seeds.count)]
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
        guard ["inspect", "decode", "decodeInto", "transcodeToHT", "transcodeToJ2K"].contains(entry) else {
            FileHandle.standardError.write(Data("unknown --entry \(entry)\n".utf8)); exit(2)
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let names = try FileManager.default.contentsOfDirectory(atPath: corpus.path)
            .filter { $0.hasSuffix(".j2k") || $0.hasSuffix(".j2c") }.sorted()
        let seeds = try names.map { [UInt8](try Data(contentsOf: corpus.appendingPathComponent($0))) }
        guard !seeds.isEmpty else { FileHandle.standardError.write(Data("empty corpus\n".utf8)); exit(2) }

        let limits = try ResourceLimits(maximumCompressedBytes: 8 << 20, maximumDecodedBytes: 64 << 20,
                                        maximumWorkspaceBytes: 256 << 20, maximumPixels: 8_000_000,
                                        maximumDimension: 8192, deadlineSeconds: 5, maximumMemoryBytes: 512 << 20)
        let options = DecodeOptions(resourceLimits: limits)
        let transcodeOptions = TranscodeOptions(resourceLimits: limits)
        let decoder = try Decoder()
        let transcoder = try Transcoder()
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
                "limits": ["deadlineSeconds": limits.deadlineSeconds, "maximumDecodedBytes": limits.maximumDecodedBytes,
                           "maximumWorkspaceBytes": limits.maximumWorkspaceBytes, "maximumPixels": limits.maximumPixels],
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
                default:
                    let info = try decoder.inspect(data, options: options)
                    let destination = try ImageDestination.allocate(descriptor: info.descriptor, limits: limits)
                    _ = try await decoder.decode(data, into: destination, options: options)
                }
                category = "success"
            } catch let error as CodecError {
                category = "\(error.category)"
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
