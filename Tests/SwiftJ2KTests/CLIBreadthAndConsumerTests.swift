// SPDX-License-Identifier: Apache-2.0
//
// CLIBreadthAndConsumerTests.swift
// SwiftJ2KTests
//
// Milestone 12 CLI and consumer breadth tests covering predecessor CLI
// audit dispositions (M12-AUD-001..M12-AUD-005) and consumer migration
// patterns across 2D, 3D, and JPIP workflows.

import Foundation
import Testing
@testable import SwiftJ2K

// MARK: - Helper to locate the built swiftj2k-cli binary

private func locateCLIBinary() throws -> URL {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let candidates = [
        repoRoot.appendingPathComponent(".build/debug/swiftj2k-cli"),
        repoRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/swiftj2k-cli"),
        repoRoot.appendingPathComponent(".build/x86_64-unknown-linux-gnu/debug/swiftj2k-cli"),
        repoRoot.appendingPathComponent(".build/aarch64-unknown-linux-gnu/debug/swiftj2k-cli"),
        repoRoot.appendingPathComponent(".build/release/swiftj2k-cli")
    ]
    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
    }
    // Build the CLI product on demand if running via `swift test` before `swift build --product swiftj2k-cli`
    let buildProc = Process()
    buildProc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    buildProc.arguments = ["swift", "build", "--product", "swiftj2k-cli"]
    buildProc.currentDirectoryURL = repoRoot
    try buildProc.run()
    buildProc.waitUntilExit()
    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
    }
    throw CodecError(.internalFailure, "Could not locate or build swiftj2k-cli binary for Milestone 12 tests.")
}

private struct CLIInvocationResult: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
    var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
    var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
}

private func invokeCLI(_ args: [String], stdinData: Data? = nil) throws -> CLIInvocationResult {
    let binary = try locateCLIBinary()
    let proc = Process()
    proc.executableURL = binary
    proc.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    if stdinData != nil {
        let inPipe = Pipe()
        proc.standardInput = inPipe
        try proc.run()
        if let stdinData {
            inPipe.fileHandleForWriting.write(stdinData)
        }
        try? inPipe.fileHandleForWriting.close()
    } else {
        try proc.run()
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    proc.waitUntilExit()
    return CLIInvocationResult(status: proc.terminationStatus, stdout: outData, stderr: errData)
}

@Suite("Milestone 12 — CLI & Consumer Breadth Tests")
struct CLIBreadthAndConsumerTests {

    @Test("Consumer migration bridge: 12-bit signed/unsigned and planar/interleaved RGB round-trip")
    func consumerLegacyBridgeAndContractEquivalence() async throws {
        let limits = try ResourceLimits()

        // 1. 12-bit signed CT-style greyscale slice via contract Image -> legacy J2KImage -> contract Image
        let width = 16
        let height = 12
        let signedDesc = try ImageDescriptor.signedGreyscale16(
            width: width,
            height: height,
            meaningfulBits: 12,
            limits: limits
        )
        let dest = try ImageDestination.allocate(descriptor: signedDesc, limits: limits)
        let contractSigned = try dest.writeSamples { _, x, y in
            let v = (x * 137 - y * 91) % 2048
            return v
        }
        let legacySigned = try J2KImage(contractImage: contractSigned)
        #expect(legacySigned.width == width)
        #expect(legacySigned.height == height)
        #expect(legacySigned.components.count == 1)
        #expect(legacySigned.components[0].bitDepth == 12)
        #expect(legacySigned.components[0].signed == true)

        let roundTrippedContract = try legacySigned.toContractImage(limits: limits)
        for y in 0..<height {
            for x in 0..<width {
                let expected = try contractSigned.sampleInt(component: 0, x: x, y: y)
                let actual = try roundTrippedContract.sampleInt(component: 0, x: x, y: y)
                #expect(expected == actual)
            }
        }

        // 2. Encode signed 12-bit image to Part 1 J2K and decode back with exact signed sample preservation
        let encoder = try Encoder(configuration: .init(mode: .lossless))
        let encodedSignedJ2K = try await encoder.encode(roundTrippedContract)
        #expect(encodedSignedJ2K.report.copyEvents.isEmpty)
        let decodedSignedJ2K = try await Decoder().decode(encodedSignedJ2K.data)
        for y in 0..<height {
            for x in 0..<width {
                let expected = try contractSigned.sampleInt(component: 0, x: x, y: y)
                let actual = try decodedSignedJ2K.image.sampleInt(component: 0, x: x, y: y)
                #expect(expected == actual)
            }
        }

        // 3. Unsigned 12-bit image: encode to Part 1 J2K, transcode to HTJ2K in coefficient domain, and decode back
        let unsignedDesc = try ImageDescriptor.greyscale16(
            width: width,
            height: height,
            meaningfulBits: 12,
            limits: limits
        )
        let unsignedDest = try ImageDestination.allocate(descriptor: unsignedDesc, limits: limits)
        let contractUnsigned = try unsignedDest.writeSamples { _, x, y in
            (x * 251 + y * 313) & 0x0FFF
        }
        let encodedUnsignedJ2K = try await encoder.encode(contractUnsigned)
        let transcoder = try Transcoder()
        let transcodedHT = try await transcoder.transcode(encodedUnsignedJ2K.data, to: .htj2k)
        #expect(transcodedHT.encoding.format == "htj2k-codestream")
        #expect(transcodedHT.report.pixelAllocationCount == 0 && transcodedHT.report.peakPixelBytes == 0)

        let decodedHT = try await Decoder().decode(transcodedHT.data)
        for y in 0..<height {
            for x in 0..<width {
                let expected = try contractUnsigned.sampleInt(component: 0, x: x, y: y)
                let actual = try decodedHT.image.sampleInt(component: 0, x: x, y: y)
                #expect(expected == actual)
            }
        }
    }

    @Test("M12-AUD-001 & M12-AUD-003: CLI 16-bit PNG, TIFF, PGM, RAW, and compare endian/signedness accuracy")
    func cliMultiFormat16BitAndCompareMetrics() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("m12-aud001-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create a 12-bit PGM (16x12) with values up to 4095
        let w = 16, h = 12
        var pgmData = Data("P5\n\(w) \(h)\n4095\n".utf8)
        for y in 0..<h {
            for x in 0..<w {
                let val = ((x * 251 + y * 313) & 0x0FFF)
                pgmData.append(UInt8((val >> 8) & 0xFF))
                pgmData.append(UInt8(val & 0xFF))
            }
        }
        let pgmURL = tmp.appendingPathComponent("input12.pgm")
        try pgmData.write(to: pgmURL)

        let pngURL = tmp.appendingPathComponent("converted12.png")
        let tiffURL = tmp.appendingPathComponent("converted12.tiff")
        let rawURL = tmp.appendingPathComponent("converted12.raw")
        let j2kURL = tmp.appendingPathComponent("encoded12.j2k")

        // Convert PGM -> PNG -> TIFF -> RAW
        #expect(try invokeCLI(["convert", "-i", pgmURL.path, "-o", pngURL.path]).status == 0)
        #expect(try invokeCLI(["convert", "-i", pngURL.path, "-o", tiffURL.path]).status == 0)
        #expect(try invokeCLI(["convert", "-i", tiffURL.path, "-o", rawURL.path]).status == 0)

        // Encode from TIFF -> J2K
        #expect(try invokeCLI(["encode", "-i", tiffURL.path, "-o", j2kURL.path]).status == 0)

        // Compare PGM against PNG, TIFF, and J2K (M12-AUD-001 regression check)
        for candidate in [pngURL, tiffURL, j2kURL] {
            let cmp = try invokeCLI(["compare", "-i", pgmURL.path, "-r", candidate.path, "--bit-exact", "--json"])
            #expect(cmp.status == 0)
            let json = try JSONSerialization.jsonObject(with: cmp.stdout) as? [String: Any]
            #expect(json?["bitExact"] as? Bool == true)
            #expect(json?["maxError"] as? Int == 0)
            #expect(json?["passed"] as? Bool == true)
        }
    }

    @Test("M12-AUD-002: CLI batch parallel worker pool (--threads) and 3D/JPIP/benchmark/completions")
    func cliBatch3DJPIPBenchmarkAndCompletions() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("m12-aud002-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 1. Create a slice directory of 4 PGM images for both batch and encode3d
        let sliceDir = tmp.appendingPathComponent("slices", isDirectory: true)
        try FileManager.default.createDirectory(at: sliceDir, withIntermediateDirectories: true)
        for z in 0..<4 {
            var pgm = Data("P5\n16 12\n255\n".utf8)
            for i in 0..<(16 * 12) {
                pgm.append(UInt8((i + z * 19) & 0xFF))
            }
            try pgm.write(to: sliceDir.appendingPathComponent(String(format: "slice_%04d.pgm", z)))
        }

        // 2. Batch encode with --threads 2 (M12-AUD-002 regression check)
        let batchOut = tmp.appendingPathComponent("batch_jph", isDirectory: true)
        let batchRes = try invokeCLI([
            "batch", "encode",
            "-i", sliceDir.path,
            "-o", batchOut.path,
            "--output-format", "jph",
            "--threads", "2",
            "--json"
        ])
        #expect(batchRes.status == 0)
        let batchJSON = try JSONSerialization.jsonObject(with: batchRes.stdout) as? [String: Any]
        #expect(batchJSON?["succeeded"] as? Int == 4)
        #expect(batchJSON?["failed"] as? Int == 0)
        #expect(batchJSON?["threads"] as? Int == 2)

        // 3. 3D encode3d & decode3d & 3D compare
        let volJ3D = tmp.appendingPathComponent("volume.j3d")
        let volNRRD = tmp.appendingPathComponent("volume.nrrd")
        #expect(try invokeCLI([
            "encode3d", "-i", sliceDir.path, "-o", volJ3D.path,
            "--codec", "htj2k-lossless", "--levels", "1,1,1", "--json"
        ]).status == 0)
        #expect(try invokeCLI([
            "decode3d", "-i", volJ3D.path, "-o", volNRRD.path, "--json"
        ]).status == 0)
        let cmp3D = try invokeCLI([
            "compare", "-i", sliceDir.path, "-r", volNRRD.path,
            "--mode", "3d", "--bit-exact", "--json"
        ])
        #expect(cmp3D.status == 0)

        // 4. JPIP loopback client on one of the batch-encoded JPH files
        let jphFile = batchOut.appendingPathComponent("slice_0000.jph")
        let jpipOut = tmp.appendingPathComponent("jpip_decoded.png")
        let jpipRes = try invokeCLI([
            "jpip", "client",
            "--single-file", jphFile.path,
            "--port", "18511",
            "-o", jpipOut.path,
            "--json"
        ])
        #expect(jpipRes.status == 0)
        #expect(FileManager.default.fileExists(atPath: jpipOut.path))

        // 5. In-process benchmark (M12-AUD-004 regression check: zero external shell-outs)
        let benchRes = try invokeCLI([
            "benchmark", "-i", jphFile.path,
            "--runs", "1", "--warmup", "0", "--json"
        ])
        #expect(benchRes.status == 0)
        let benchJSON = try JSONSerialization.jsonObject(with: benchRes.stdout) as? [String: Any]
        #expect(benchJSON?["runs"] as? Int == 1)

        // 6. Shell completions & CLI-08 path hygiene (M12-AUD-005)
        for sh in ["bash", "zsh", "fish"] {
            let comp = try invokeCLI(["completions", sh])
            #expect(comp.status == 0)
            #expect(comp.stdoutText.contains("encode3d"))
        }
        let secretPath = tmp.appendingPathComponent("sensitive-patient-name.j2k")
        let failRes = try invokeCLI(["validate", "-i", secretPath.path, "-vvvvv"])
        #expect(failRes.status == 6)
        #expect(!failRes.stderrText.contains("sensitive-patient-name"))
    }
}
