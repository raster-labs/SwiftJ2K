// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftJ2K
import SwiftJ2K3D
import SwiftJ2KJPIP
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@main struct Consumer {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 2, args[0] == "--benchmark-in-memory" {
            try await runInMemoryBenchmark(repoRoot: URL(fileURLWithPath: args[1]))
            return
        }
        if args.count == 2, args[0] == "--benchmark-acceleration" {
            try await runAccelerationBenchmark(repoRoot: URL(fileURLWithPath: args[1]))
            return
        }
        let descriptor = try SwiftJ2K.ImageDescriptor.greyscale16(width: 3, height: 2,
            meaningfulBits: 12, rowBytes: 8)
        let destination = try SwiftJ2K.ImageDestination.allocate(descriptor: descriptor)
        let image = try destination.writeUInt16 { x, y in UInt16(x == 0 ? 4095 : y * 3 + x) }
        guard try image.sampleUInt16(x: 0, y: 1) == 4095 else {
            throw SwiftJ2K.CodecError(.internalFailure, "Synthetic sample changed.")
        }
        let encoder = try SwiftJ2K.Encoder()
        let decoder = try SwiftJ2K.Decoder()
        guard encoder.capabilities.canEncode, decoder.capabilities.canDecode else {
            throw SwiftJ2K.CodecError(.internalFailure, "Scalar lossless coverage is not advertised.")
        }
        let encoded = try await encoder.encode(image)
        let info = try decoder.inspect(encoded.data)
        guard info.descriptor.width == 3, info.descriptor.meaningfulBits == 12 else {
            throw SwiftJ2K.CodecError(.internalFailure, "Inspection disagrees with the source descriptor.")
        }
        let decoded = try await decoder.decode(encoded.data)
        for y in 0..<2 {
            for x in 0..<3 where try decoded.image.sampleUInt16(x: x, y: y) != image.sampleUInt16(x: x, y: y) {
                throw SwiftJ2K.CodecError(.internalFailure, "Lossless round trip changed a sample.")
            }
        }
        let htEncoder = try SwiftJ2K.Encoder(configuration: .init(codecOptions: try .init(blockCoding: .htj2k)))
        let htEncoded = try await htEncoder.encode(image)
        let transcoder = try SwiftJ2K.Transcoder()
        let transcodedToPart1 = try await transcoder.transcode(htEncoded.data, to: .jpeg2000)
        let transcodedToHT = try await transcoder.transcode(transcodedToPart1.data, to: .htj2k)
        let htDecoded = try await decoder.decode(transcodedToHT.data)
        for y in 0..<2 {
            for x in 0..<3 where try htDecoded.image.sampleUInt16(x: x, y: y) != image.sampleUInt16(x: x, y: y) {
                throw SwiftJ2K.CodecError(.internalFailure, "HTJ2K/transcode round trip changed a sample.")
            }
        }

        // Verify SwiftJ2K3D (Part 10 volumetric codec)
        let volComp = J2KVolumeComponent(
            index: 0, bitDepth: 8, signed: false,
            width: 4, height: 4, depth: 2,
            data: Data((0..<32).map { UInt8($0 * 7) })
        )
        let vol = J2KVolume(width: 4, height: 4, depth: 2, components: [volComp])
        let jp3dEnc = try await JP3DEncoder(configuration: .lossless).encode(vol)
        let jp3dDec = try await JP3DDecoder().decode(jp3dEnc.data)
        guard jp3dDec.volume.width == 4, jp3dDec.volume.height == 4, jp3dDec.volume.depth == 2,
              jp3dDec.volume.components[0].data == volComp.data else {
            throw SwiftJ2K.CodecError(.internalFailure, "SwiftJ2K3D volumetric round trip failed.")
        }

        // Verify SwiftJ2KJPIP (Part 9 interactive streaming)
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("consumer-jpip-\(UUID().uuidString).j2k")
        try encoded.data.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        let server = JPIPServer(port: 18599)
        try await server.registerImage(name: "sample.j2k", at: tmpURL)
        try await server.start()
        let client = JPIPClient(server: server)
        let jpipImg = try await client.requestImage(imageID: "sample.j2k")
        try await client.close()
        try await server.stop()
        guard jpipImg.width == 3, jpipImg.height == 2 else {
            throw SwiftJ2K.CodecError(.internalFailure, "SwiftJ2KJPIP streaming round trip failed.")
        }

        print("Independent SwiftJ2K/SwiftJ2K3D/SwiftJ2KJPIP consumer passed; \(encoded.data.count)-byte Part 1, \(htEncoded.data.count)-byte HTJ2K, \(jp3dEnc.data.count)-byte JP3D codestreams and JPIP session round-tripped.")
    }

    private static func maxRSSBytes() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        #if os(macOS)
        return Int(usage.ru_maxrss)
        #else
        return Int(usage.ru_maxrss) * 1024
        #endif
    }

    private static func ms(_ duration: Duration) -> Double {
        (Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) * 1000.0
    }

    private static func stats(_ samples: [Double]) -> [String: Any] {
        let sorted = samples.sorted()
        let n = sorted.count
        let median = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
        let p95 = sorted[Int(0.95 * Double(n - 1))]
        return [
            "median_ms": median,
            "p95_ms": p95,
            "min_ms": sorted.first ?? 0,
            "max_ms": sorted.last ?? 0,
            "samples_ms": samples
        ]
    }

    private static func runInMemoryBenchmark(repoRoot: URL) async throws {
        let cases: [(name: String, j2kFile: String, htFile: String)] = [
            ("g16_64x64_random", "g16_64x64_random.opj.j2k", "g16_64x64_random.ojph.j2c"),
            ("g12_129x67_gradient", "g12_129x67_gradient.opj.j2k", "g12_129x67_gradient.ojph.j2c"),
            ("g16_256x256_smooth", "g16_256x256_smooth.opj.j2k", "g16_256x256_smooth.ojph.j2c"),
            ("g10_300x200_gradient", "g10_300x200_gradient.opj.j2k", "g10_300x200_gradient.ojph.j2c")
        ]
        let losslessDir = repoRoot.appendingPathComponent("Tests/SwiftJ2KTests/Fixtures/Lossless")
        let htDir = repoRoot.appendingPathComponent("Tests/SwiftJ2KTests/Fixtures/HTJ2K")
        let decoder = try SwiftJ2K.Decoder()
        let transcoder = try SwiftJ2K.Transcoder()
        let part1Encoder = try SwiftJ2K.Encoder(configuration: .init(codecOptions: try .init(blockCoding: .part1)))
        let htEncoder = try SwiftJ2K.Encoder(configuration: .init(codecOptions: try .init(blockCoding: .htj2k)))
        let clock = ContinuousClock()
        let warmups = 5
        let iterations = 20
        var rows: [[String: Any]] = []

        for c in cases {
            let j2kData = try Data(contentsOf: losslessDir.appendingPathComponent(c.j2kFile))
            let htData = try Data(contentsOf: htDir.appendingPathComponent(c.htFile))
            let info = try decoder.inspect(j2kData)
            let descriptor = info.descriptor

            for (dirName, srcData, target, encoder) in [
                ("j2k-to-htj2k", j2kData, SwiftJ2K.TranscodeTarget.htj2k, htEncoder),
                ("htj2k-to-j2k", htData, SwiftJ2K.TranscodeTarget.jpeg2000, part1Encoder)
            ] {
                func runCoeff() async throws -> (Double, SwiftJ2K.EncodedImage) {
                    let t0 = clock.now
                    let out = try await transcoder.transcode(srcData, to: target)
                    return (ms(clock.now - t0), out)
                }
                func runSharedSample() async throws -> (Double, SwiftJ2K.DecodedImage, SwiftJ2K.EncodedImage) {
                    let t0 = clock.now
                    let dest = try SwiftJ2K.ImageDestination.allocate(descriptor: descriptor)
                    let dec = try await decoder.decode(srcData, into: dest)
                    let enc = try await encoder.encode(dec.image)
                    return (ms(clock.now - t0), dec, enc)
                }

                for _ in 0..<warmups {
                    _ = try await runCoeff()
                    _ = try await runSharedSample()
                }

                var coeffTimes: [Double] = []
                var sharedTimes: [Double] = []
                var lastCoeff: SwiftJ2K.EncodedImage?
                var lastDec: SwiftJ2K.DecodedImage?
                var lastEnc: SwiftJ2K.EncodedImage?

                for i in 0..<iterations {
                    if i % 2 == 0 {
                        let (ct, co) = try await runCoeff()
                        let (st, sd, se) = try await runSharedSample()
                        coeffTimes.append(ct); sharedTimes.append(st)
                        lastCoeff = co; lastDec = sd; lastEnc = se
                    } else {
                        let (st, sd, se) = try await runSharedSample()
                        let (ct, co) = try await runCoeff()
                        coeffTimes.append(ct); sharedTimes.append(st)
                        lastCoeff = co; lastDec = sd; lastEnc = se
                    }
                }

                guard let co = lastCoeff, let sd = lastDec, let se = lastEnc else { continue }
                var coeffStats = stats(coeffTimes)
                coeffStats["peak_workspace_bytes"] = co.report.peakWorkspaceBytes ?? -1
                coeffStats["peak_pixel_bytes"] = co.report.peakPixelBytes ?? 0
                coeffStats["pixel_allocations"] = co.report.pixelAllocationCount ?? 0
                coeffStats["copy_events"] = co.report.copyEvents.count
                coeffStats["output_bytes"] = co.data.count

                var sharedStats = stats(sharedTimes)
                let decWS = sd.report.peakWorkspaceBytes ?? 0
                let encWS = se.report.peakWorkspaceBytes ?? 0
                sharedStats["decode_peak_workspace_bytes"] = decWS
                sharedStats["encode_peak_workspace_bytes"] = encWS
                sharedStats["peak_workspace_bytes"] = max(decWS, encWS)
                sharedStats["peak_pixel_bytes"] = sd.report.peakPixelBytes ?? (descriptor.width * descriptor.height * 2)
                sharedStats["pixel_allocations"] = 1 // 1 caller-allocated shared ImageDestination
                sharedStats["decode_into_pixel_allocations"] = sd.report.pixelAllocationCount ?? 0
                sharedStats["encode_pixel_allocations"] = se.report.pixelAllocationCount ?? 0
                sharedStats["copy_events"] = sd.report.copyEvents.count + se.report.copyEvents.count
                sharedStats["output_bytes"] = se.data.count

                rows.append([
                    "case": c.name,
                    "direction": dirName,
                    "width": descriptor.width,
                    "height": descriptor.height,
                    "meaningfulBits": descriptor.meaningfulBits,
                    "inputBytes": srcData.count,
                    "inMemoryCoefficientPath": coeffStats,
                    "inMemorySharedSampleBaseline": sharedStats
                ])
            }
        }
        let payload: [String: Any] = [
            "warmups": warmups,
            "iterations": iterations,
            "max_rss_bytes": maxRSSBytes(),
            "cases": rows
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data + Data([10]))
    }

    private static func runAccelerationBenchmark(repoRoot: URL) async throws {
        let clock = ContinuousClock()
        let warmups = 3
        let iterations = 15

        // 1. Measure Cold Start (first-ever accelerated encode & decode on a 256x256x3 RGB 16-bit image,
        //    which exceeds the 65,536-sample Metal threshold and triggers MSL compilation + PSO creation):
        let coldDesc = try SwiftJ2K.ImageDescriptor.rgbPlanar(
            width: 256, height: 256, storageBits: 16, meaningfulBits: 12, signed: false
        )
        let coldImg = try SwiftJ2K.ImageDestination.allocate(descriptor: coldDesc).writeSamples { c, x, y in
            (x * 17 + y * 31 + c * 53) & 4095
        }
        let rgbPart1Enc = try SwiftJ2K.Encoder(configuration: .init(
            mode: .lossless,
            codecOptions: try .init(blockCoding: .part1, wavelet: .reversible53, colourTransform: .rct)
        ))
        let rgbHTEnc = try SwiftJ2K.Encoder(configuration: .init(
            mode: .lossless,
            codecOptions: try .init(blockCoding: .htj2k, wavelet: .reversible53, colourTransform: .rct)
        ))
        let rgb97Enc = try SwiftJ2K.Encoder(configuration: .init(
            mode: .lossy,
            codecOptions: try .init(blockCoding: .part1, wavelet: .irreversible97, colourTransform: .ict, quality: 0.85)
        ))
        let decoder = try SwiftJ2K.Decoder()
        let transcoder = try SwiftJ2K.Transcoder()

        let tCold0 = clock.now
        let coldOut = try await rgbPart1Enc.encode(coldImg, options: .init(executionPolicy: .required(.accelerated)))
        let coldEncodeMs = ms(clock.now - tCold0)

        let tColdDec0 = clock.now
        let coldDec = try await decoder.decode(coldOut.data, options: .init(executionPolicy: .required(.accelerated)))
        let coldDecodeMs = ms(clock.now - tColdDec0)
        _ = coldDec

        // 2. Warm steady-state comparisons (.scalarCPU vs .required(.accelerated)):
        struct Workload {
            let name: String
            let description: String
            let runScalar: () async throws -> Data
            let runAccelerated: () async throws -> Data
        }

        let losslessDir = repoRoot.appendingPathComponent("Tests/SwiftJ2KTests/Fixtures/Lossless")
        let g256Data = try Data(contentsOf: losslessDir.appendingPathComponent("g16_256x256_smooth.opj.j2k"))
        let g300Data = try Data(contentsOf: losslessDir.appendingPathComponent("g10_300x200_gradient.opj.j2k"))

        let workloads: [Workload] = [
            Workload(
                name: "encode_rgb16_256x256_part1_53_rct",
                description: "256x256x3 12-bit RGB lossless Part 1 encode (5/3 DWT + RCT, Metal GPU + SIMD)",
                runScalar: {
                    try await rgbPart1Enc.encode(coldImg, options: .init(executionPolicy: .scalarCPU)).data
                },
                runAccelerated: {
                    try await rgbPart1Enc.encode(coldImg, options: .init(executionPolicy: .required(.accelerated))).data
                }
            ),
            Workload(
                name: "decode_rgb16_256x256_part1_53_rct",
                description: "256x256x3 12-bit RGB lossless Part 1 decode (5/3 IDWT + Inverse RCT, Metal GPU + SIMD)",
                runScalar: {
                    let d = try await decoder.decode(coldOut.data, options: .init(executionPolicy: .scalarCPU))
                    return try d.image.storage.withUnsafeBytes { Data($0) }
                },
                runAccelerated: {
                    let d = try await decoder.decode(coldOut.data, options: .init(executionPolicy: .required(.accelerated)))
                    return try d.image.storage.withUnsafeBytes { Data($0) }
                }
            ),
            Workload(
                name: "encode_rgb16_256x256_htj2k_53_rct",
                description: "256x256x3 12-bit RGB lossless HTJ2K encode (5/3 DWT + RCT + FBCOT, Metal GPU + SIMD)",
                runScalar: {
                    try await rgbHTEnc.encode(coldImg, options: .init(executionPolicy: .scalarCPU)).data
                },
                runAccelerated: {
                    try await rgbHTEnc.encode(coldImg, options: .init(executionPolicy: .required(.accelerated))).data
                }
            ),
            Workload(
                name: "encode_rgb16_256x256_lossy_97_ict",
                description: "256x256x3 12-bit RGB lossy Part 1 encode (9/7 DWT + ICT + Quantisation, SIMD4<Double>)",
                runScalar: {
                    try await rgb97Enc.encode(coldImg, options: .init(executionPolicy: .scalarCPU)).data
                },
                runAccelerated: {
                    try await rgb97Enc.encode(coldImg, options: .init(executionPolicy: .required(.accelerated))).data
                }
            ),
            Workload(
                name: "decode_g16_256x256_smooth",
                description: "256x256 16-bit greyscale lossless Part 1 fixture decode (Metal GPU 5/3 IDWT)",
                runScalar: {
                    let d = try await decoder.decode(g256Data, options: .init(executionPolicy: .scalarCPU))
                    return try d.image.storage.withUnsafeBytes { Data($0) }
                },
                runAccelerated: {
                    let d = try await decoder.decode(g256Data, options: .init(executionPolicy: .required(.accelerated)))
                    return try d.image.storage.withUnsafeBytes { Data($0) }
                }
            ),
            Workload(
                name: "transcode_g10_300x200_j2k_to_htj2k",
                description: "300x200 10-bit greyscale J2K -> HTJ2K compressed-domain transcode (SIMD FBCOT)",
                runScalar: {
                    try await transcoder.transcode(g300Data, to: .htj2k, options: .init(executionPolicy: .scalarCPU)).data
                },
                runAccelerated: {
                    try await transcoder.transcode(g300Data, to: .htj2k, options: .init(executionPolicy: .required(.accelerated))).data
                }
            )
        ]

        var results: [[String: Any]] = []
        for w in workloads {
            for _ in 0..<warmups {
                _ = try await w.runScalar()
                _ = try await w.runAccelerated()
            }
            var scalarSamples: [Double] = []
            var accelSamples: [Double] = []
            var byteIdentical = true
            for i in 0..<iterations {
                let sOut: Data
                let aOut: Data
                if i % 2 == 0 {
                    let t0 = clock.now
                    sOut = try await w.runScalar()
                    scalarSamples.append(ms(clock.now - t0))
                    let t1 = clock.now
                    aOut = try await w.runAccelerated()
                    accelSamples.append(ms(clock.now - t1))
                } else {
                    let t1 = clock.now
                    aOut = try await w.runAccelerated()
                    accelSamples.append(ms(clock.now - t1))
                    let t0 = clock.now
                    sOut = try await w.runScalar()
                    scalarSamples.append(ms(clock.now - t0))
                }
                if sOut != aOut { byteIdentical = false }
            }
            let sStats = stats(scalarSamples)
            let aStats = stats(accelSamples)
            results.append([
                "workload": w.name,
                "description": w.description,
                "byte_identical": byteIdentical,
                "scalar_cpu": sStats,
                "accelerated": aStats
            ])
        }

        let payload: [String: Any] = [
            "available_backends": SwiftJ2K.Encoder.capabilities.availableBackends.map { "\($0)" },
            "cold_start_rgb16_256x256_encode_ms": coldEncodeMs,
            "cold_start_rgb16_256x256_decode_ms": coldDecodeMs,
            "warmups": warmups,
            "iterations": iterations,
            "max_rss_bytes": maxRSSBytes(),
            "workloads": results
        ]
        let outData = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(outData + Data([10]))
    }
}
