// SPDX-License-Identifier: Apache-2.0
//
// R1JPIPRemediationTests.swift
// SwiftJ2KJPIPTests
//
// Phase R1 JPIP audit remediation regressions covering:
// - F05 (pre-allocation ResourceLimits + deadlineSeconds enforcement in JPIPStreamingSession)
// - F06 (truthful OperationReport.fidelity for lossy codestreams, reduced resolution/quality, and component subsets)
// - F13 (post-.completed cancellation in deliverImage and deliverVolumeRegion)
// - F03 / M12-CX-02 (JPIPViewWindow checked region arithmetic & resolutionLevel <= 32 bounds)

import Foundation
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2K3D
@testable import SwiftJ2KJPIP

private func makeRGBJ2KImage(width: Int = 16, height: Int = 16) -> J2KImage {
    var comps: [J2KComponent] = []
    for c in 0..<3 {
        var bytes = Data(count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                bytes[y * width + x] = UInt8((x * 11 + y * 17 + c * 53) & 0xFF)
            }
        }
        comps.append(
            J2KComponent(
                index: c,
                bitDepth: 8,
                signed: false,
                width: width,
                height: height,
                data: bytes
            )
        )
    }
    return J2KImage(width: width, height: height, components: comps, colorSpace: .sRGB)
}

@Suite("Phase R1 — SwiftJ2KJPIP Audit Remediation Regressions")
struct R1JPIPRemediationTests {

    @Test("F03 & M12-CX-02: JPIPViewWindow rejects Int.max region overflow and resolutionLevel > 32 cleanly")
    func viewWindowValidatesRegionOverflowAndResolutionBounds() throws {
        #expect(throws: CodecError.self) {
            _ = try JPIPViewWindow(region: (x: Int.max, y: 0, width: 1, height: 1))
        }
        #expect(throws: CodecError.self) {
            _ = try JPIPViewWindow(region: (x: 0, y: Int.max, width: 1, height: 1))
        }
        #expect(throws: CodecError.self) {
            _ = try JPIPViewWindow(resolutionLevel: 64)
        }
        #expect(throws: CodecError.self) {
            _ = try JPIPViewWindow(resolutionLevel: -1)
        }
        let validBoundary = try JPIPViewWindow(resolutionLevel: 32)
        #expect(validBoundary.resolutionLevel == 32)
    }

    @Test("F05: JPIPStreamingSession enforces ResourceLimits and deadlineSeconds before/during delivery")
    func streamingSessionEnforcesResourceLimitsAndDeadline() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftj2k-r1-jpip-f05-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let img = makeRGBJ2KImage(width: 16, height: 16)
        let encoded = try await J2KEncoder(
            encodingConfiguration: J2KEncodingConfiguration(
                quality: 1.0,
                lossless: true,
                decompositionLevels: 1,
                qualityLayers: 2
            )
        ).encode(img)
        let imgURL = tempDir.appendingPathComponent("sample.jp2")
        try encoded.write(to: imgURL)

        let port = Int.random(in: 41_000..<49_000)
        let server = JPIPServer(port: port)
        try await server.registerImage(name: "sample.jp2", at: imgURL)
        try await server.start()
        let session = JPIPStreamingSession(server: server, port: port)

        do {
            // 1. maximumCompressedBytes denial before decode
            let tightCompressed = try ResourceLimits(maximumCompressedBytes: 16)
            do {
                _ = try await session.deliverImage(
                    imageID: "sample.jp2",
                    options: JPIPStreamingOptions(resourceLimits: tightCompressed)
                )
                Issue.record("Expected tight maximumCompressedBytes to deny JPIP deliverImage")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }

            // 2. maximumDecodedBytes denial
            let tightDecoded = try ResourceLimits(maximumDecodedBytes: 64)
            do {
                _ = try await session.deliverImage(
                    imageID: "sample.jp2",
                    options: JPIPStreamingOptions(resourceLimits: tightDecoded)
                )
                Issue.record("Expected tight maximumDecodedBytes to deny JPIP deliverImage")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }

            // 3. maximumMemoryBytes denial
            let tightMemory = try ResourceLimits(maximumMemoryBytes: 64)
            do {
                _ = try await session.deliverImage(
                    imageID: "sample.jp2",
                    options: JPIPStreamingOptions(resourceLimits: tightMemory)
                )
                Issue.record("Expected tight maximumMemoryBytes to deny JPIP deliverImage")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }

            // 4. deadlineSeconds denial on deliverImage
            let tinyDeadline = try ResourceLimits(deadlineSeconds: 1e-9)
            do {
                _ = try await session.deliverImage(
                    imageID: "sample.jp2",
                    options: JPIPStreamingOptions(resourceLimits: tinyDeadline)
                )
                Issue.record("Expected 1 ns deadlineSeconds to deny JPIP deliverImage")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }

            // 5. deliverVolumeRegion ResourceLimits denial
            let region3D = JP3DStreamingRegion(xRange: 0..<32, yRange: 0..<32, zRange: 0..<8)
            let tightPixels3D = try ResourceLimits(maximumPixels: 16)
            do {
                _ = try await session.deliverVolumeRegion(
                    volumeID: "vol3d",
                    region: region3D,
                    options: JPIPStreamingOptions(resourceLimits: tightPixels3D)
                )
                Issue.record("Expected tight maximumPixels to deny deliverVolumeRegion")
            } catch let error as CodecError {
                #expect(error.category == .resourceLimitExceeded)
            }

            try await session.close()
            try await server.stop()
        } catch {
            try? await session.close()
            try? await server.stop()
            throw error
        }
    }

    @Test("F06: JPIPStreamingSession reports .lossy for lossy codestreams, reduced resolution/layers, and component subsets")
    func streamingSessionTruthfulFidelity() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftj2k-r1-jpip-f06-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let img = makeRGBJ2KImage(width: 16, height: 16)

        let losslessBytes = try await J2KEncoder(
            encodingConfiguration: J2KEncodingConfiguration(
                quality: 1.0,
                lossless: true,
                decompositionLevels: 2,
                qualityLayers: 2
            )
        ).encode(img)
        let losslessURL = tempDir.appendingPathComponent("lossless.jp2")
        try losslessBytes.write(to: losslessURL)

        let lossyBytes = try await J2KEncoder(
            encodingConfiguration: J2KEncodingConfiguration(
                quality: 0.65,
                lossless: false,
                decompositionLevels: 2,
                qualityLayers: 2
            )
        ).encode(img)
        let lossyURL = tempDir.appendingPathComponent("lossy.jp2")
        try lossyBytes.write(to: lossyURL)

        let port = Int.random(in: 41_000..<49_000)
        let server = JPIPServer(port: port)
        try await server.registerImage(name: "lossless.jp2", at: losslessURL)
        try await server.registerImage(name: "lossy.jp2", at: lossyURL)
        try await server.start()
        let session = JPIPStreamingSession(server: server, port: port)

        do {
            // 1. Lossy codestream with full viewWindow: nil MUST report .lossy (never .exactSamples):
            let lossyDelivered = try await session.deliverImage(imageID: "lossy.jp2", viewWindow: nil)
            #expect(lossyDelivered.report.fidelity == .lossy)

            // 2. Lossless codestream with full viewWindow: nil reports .exactSamples:
            let fullLossless = try await session.deliverImage(imageID: "lossless.jp2", viewWindow: nil)
            #expect(fullLossless.report.fidelity == .exactSamples)

            // 3. Lossless codestream with reduced resolutionLevel: 1 reports .lossy:
            let reducedRes = try await session.deliverImage(
                imageID: "lossless.jp2",
                viewWindow: try JPIPViewWindow(resolutionLevel: 1)
            )
            #expect(reducedRes.report.fidelity == .lossy)

            // 4. Lossless 2-layer codestream with maxQualityLayers: 1 reports .lossy:
            let reducedLayers = try await session.deliverImage(
                imageID: "lossless.jp2",
                viewWindow: try JPIPViewWindow(maxQualityLayers: 1)
            )
            #expect(reducedLayers.report.fidelity == .lossy)

            // 5. Lossless 3-component codestream with components: [0] subset reports .lossy:
            let subsetComp = try await session.deliverImage(
                imageID: "lossless.jp2",
                viewWindow: try JPIPViewWindow(components: [0])
            )
            #expect(subsetComp.report.fidelity == .lossy)

            try await session.close()
            try await server.stop()
        } catch {
            try? await session.close()
            try? await server.stop()
            throw error
        }
    }

    @Test("F13: cancellation inside .completed progress callback aborts JPIPStreamingSession deliveries")
    func postCompletedCancellationAbortsJPIPDeliveries() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftj2k-r1-jpip-f13-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let img = makeRGBJ2KImage(width: 16, height: 16)
        let encoded = try await J2KEncoder(
            encodingConfiguration: J2KEncodingConfiguration(
                quality: 1.0,
                lossless: true,
                decompositionLevels: 1,
                qualityLayers: 1
            )
        ).encode(img)
        let imgURL = tempDir.appendingPathComponent("f13.jp2")
        try encoded.write(to: imgURL)

        let port = Int.random(in: 41_000..<49_000)
        let server = JPIPServer(port: port)
        try await server.registerImage(name: "f13.jp2", at: imgURL)
        try await server.start()
        let session = JPIPStreamingSession(server: server, port: port)

        do {
            let imgTask = Task {
                try await session.deliverImage(
                    imageID: "f13.jp2",
                    options: JPIPStreamingOptions(progress: { update in
                        if update.phase == .completed {
                            withUnsafeCurrentTask { $0?.cancel() }
                        }
                    })
                )
            }
            await #expect(throws: CancellationError.self) {
                _ = try await imgTask.value
            }

            let volTask = Task {
                try await session.deliverVolumeRegion(
                    volumeID: "vol-f13",
                    region: JP3DStreamingRegion(xRange: 0..<4, yRange: 0..<4, zRange: 0..<2),
                    options: JPIPStreamingOptions(progress: { update in
                        if update.phase == .completed {
                            withUnsafeCurrentTask { $0?.cancel() }
                        }
                    })
                )
            }
            await #expect(throws: CancellationError.self) {
                _ = try await volTask.value
            }

            try await session.close()
            try await server.stop()
        } catch {
            try? await session.close()
            try? await server.stop()
            throw error
        }
    }
}
