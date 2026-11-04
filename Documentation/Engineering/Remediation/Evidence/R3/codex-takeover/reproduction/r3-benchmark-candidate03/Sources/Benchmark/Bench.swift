import Foundation
import Darwin
import CryptoKit
import SwiftJ2K
import SwiftJ2K3D

struct Case: Sendable {
    let name: String, width: Int, height: Int, depth: Int, bits: Int, tile: Int, tileZ: Int
    var count: Int { width * height * depth }
    func raw() -> Data {
        var bytes = [UInt8](); bytes.reserveCapacity(count * (bits / 8))
        var state: UInt64 = 0xD4A8_19F2_650C_B371
        for z in 0..<depth {
            for y in 0..<height {
                for x in 0..<width {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    let mask = (1 << bits) - 1
                    let value: Int
                    switch x * 3 / width {
                    case 0: value = (mask / 3 + z) & mask
                    case 1: value = (x * 997 + y * 131 + z * 71) & mask
                    default: value = Int((state >> 32) & UInt64(mask))
                    }
                    bytes.append(UInt8(truncatingIfNeeded: value))
                    if bits > 8 { bytes.append(UInt8(truncatingIfNeeded: value >> 8)) }
                }
            }
        }
        return Data(bytes)
    }
    func volume(_ raw: Data) -> J2KVolume {
        J2KVolume(width: width, height: height, depth: depth,
            components: [J2KVolumeComponent(index: 0, bitDepth: bits, signed: false,
                width: width, height: height, depth: depth, data: raw)])
    }
    func encoder(ht: Bool) throws -> VolumeEncoder {
        try VolumeEncoder(configuration: VolumeEncoderConfiguration(
            compressionMode: ht ? .losslessHTJ2K : .lossless,
            tiling: JP3DTilingConfiguration(tileSizeX: tile, tileSizeY: tile, tileSizeZ: tileZ),
            qualityLayers: 1, levelsX: 1, levelsY: 1, levelsZ: 1))
    }
}

@main struct Benchmark {
    static let cases = [
        Case(name: "odd8", width: 37, height: 23, depth: 3, bits: 8, tile: 16, tileZ: 2),
        Case(name: "medium16", width: 96, height: 64, depth: 8, bits: 16, tile: 32, tileZ: 4)
    ]
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { throw NSError(domain: "Usage: benchmark prepare ROOT | sample ROOT CASE OPERATION", code: 1) }
        let root = URL(fileURLWithPath: args[2], isDirectory: true)
        let serialLimits = try ResourceLimits(maximumWorkers: 1)
        if args[1] == "prepare" {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for item in cases {
                let raw = item.raw(); try raw.write(to: root.appendingPathComponent(item.name + ".raw"))
                for ht in [false, true] {
                    let encoded = try await item.encoder(ht: ht).encode(item.volume(raw), options: .init(resourceLimits: serialLimits, executionPolicy: .scalarCPU))
                    let decoded = try await VolumeDecoder().decode(encoded.data, options: .init(resourceLimits: serialLimits, executionPolicy: .scalarCPU))
                    guard decoded.volume.components[0].data == raw else { throw NSError(domain: "Preparation lossless mismatch", code: 2) }
                    try encoded.data.write(to: root.appendingPathComponent(item.name + (ht ? ".ht.j2k" : ".ebcot.j2k")))
                }
            }
            print("Prepared two common exact-sample corpora")
            return
        }
        guard args.count == 5, let item = cases.first(where: { $0.name == args[3] }) else {
            throw NSError(domain: "Invalid benchmark case", code: 3)
        }
        let operation = args[4]
        let expected = try Data(contentsOf: root.appendingPathComponent(item.name + ".raw"))
        guard expected == item.raw() else { throw NSError(domain: "Input identity mismatch", code: 4) }
        let volume = item.volume(expected)
        let sourceHT = operation == "decode-ht" || operation == "transcode-to-ebcot"
        let input = try Data(contentsOf: root.appendingPathComponent(item.name + (sourceHT ? ".ht.j2k" : ".ebcot.j2k")))
        let encoder = try item.encoder(ht: operation == "encode-ht")
        let decoder = try VolumeDecoder()
        let transcoder = try VolumeTranscoder()
        func perform() async throws -> (Data, OperationReport) {
            if operation.hasPrefix("encode-") {
                let value = try await encoder.encode(volume, options: .init(resourceLimits: serialLimits, executionPolicy: .scalarCPU))
                return (value.data, value.report)
            }
            if operation.hasPrefix("decode-") {
                let value = try await decoder.decode(input, options: .init(resourceLimits: serialLimits, executionPolicy: .scalarCPU))
                return (value.volume.components[0].data, value.report)
            }
            guard operation == "transcode-to-ht" || operation == "transcode-to-ebcot" else {
                throw NSError(domain: "Invalid benchmark operation", code: 5)
            }
            let value = try await transcoder.transcode(input, to: operation == "transcode-to-ht" ? .htj2k : .jpeg2000,
                                                       options: .init(resourceLimits: serialLimits, executionPolicy: .scalarCPU))
            return (value.data, value.report)
        }
        for _ in 0..<5 { _ = try await perform() }
        let started = ContinuousClock.now
        let (output, report) = try await perform()
        let elapsed = ContinuousClock.now - started
        var usage = rusage(); _ = getrusage(RUSAGE_SELF, &usage)
        let exact: Bool
        if operation.hasPrefix("decode-") { exact = output == expected }
        else { exact = try await decoder.decode(output, options: .init(resourceLimits: serialLimits, executionPolicy: .scalarCPU)).volume.components[0].data == expected }
        guard exact else { throw NSError(domain: "Timed operation sample mismatch", code: 6) }
        func optional(_ value: Int?) -> Any { value.map { $0 as Any } ?? NSNull() }
        let result: [String: Any] = [
            "case": item.name, "operation": operation, "warmups": 5, "timed_iterations": 1,
            "elapsed_seconds": Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18,
            "voxels": item.count, "encoded_bytes": operation.hasPrefix("decode-") ? input.count : output.count,
            "output_sha256": SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined(),
            "peak_rss_bytes": usage.ru_maxrss, "peak_rss_scope": "process through timed sample, before verification",
            "reported_peak_pixel_bytes": optional(report.peakPixelBytes),
            "reported_peak_workspace_bytes": optional(report.peakWorkspaceBytes),
            "reported_pixel_allocation_count": optional(report.pixelAllocationCount),
            "copy_count": report.copyEvents.count, "copy_bytes": report.copyEvents.reduce(0) { $0 + $1.bytesMoved },
            "sample_exact": exact, "backend": String(describing: report.backend),
            "maximum_workers": 1, "thermal_state": ProcessInfo.processInfo.thermalState.rawValue,
            "low_power_mode": ProcessInfo.processInfo.isLowPowerModeEnabled
        ]
        print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
