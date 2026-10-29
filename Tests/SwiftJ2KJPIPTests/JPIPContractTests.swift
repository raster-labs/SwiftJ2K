// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Raster-Lab
//
// Contract API-13 and Defect Regression Tests for SwiftJ2KJPIP

import XCTest
import Foundation
@testable import SwiftJ2KJPIP
@testable import SwiftJ2K3D
@testable import SwiftJ2K

final class JPIPContractTests: XCTestCase {

    // MARK: - Helpers

    private func makeTestJ2KImage(
        width: Int = 32,
        height: Int = 32,
        components: Int = 3,
        bitDepth: Int = 8
    ) -> J2KImage {
        var compList: [J2KComponent] = []
        for c in 0..<components {
            var bytes = Data(count: width * height)
            for y in 0..<height {
                for x in 0..<width {
                    bytes[y * width + x] = UInt8((x * 5 + y * 7 + c * 43) & 0xFF)
                }
            }
            compList.append(
                J2KComponent(
                    index: c,
                    bitDepth: bitDepth,
                    signed: false,
                    width: width,
                    height: height,
                    data: bytes
                )
            )
        }
        return J2KImage(
            width: width,
            height: height,
            components: compList,
            colorSpace: components == 1 ? .grayscale : .sRGB
        )
    }

    private func writeEncodedTempFile(
        image: J2KImage,
        useHTJ2K: Bool = false,
        qualityLayers: Int = 2,
        decompositionLevels: Int = 2
    ) async throws -> URL {
        let config = J2KEncodingConfiguration(
            quality: 1.0,
            lossless: true,
            decompositionLevels: decompositionLevels,
            qualityLayers: qualityLayers,
            useHTJ2K: useHTJ2K
        )
        let encoded = try await J2KEncoder(encodingConfiguration: config).encode(image)
        let ext = useHTJ2K ? "jph" : "jp2"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("jpip-contract-\(UUID().uuidString).\(ext)")
        try encoded.write(to: url)
        return url
    }

    // MARK: - 1. End-to-End JPIPClient Image, Region, Resolution, Quality, and Component Retrieval (Finding F1 Fix)

    func testJPIPClientEndToEndImageRegionQualityResolutionAndComponents() async throws {
        let port = Int.random(in: 29_000..<39_000)
        let server = JPIPServer(port: port)
        let sourceImage = makeTestJ2KImage(width: 32, height: 32, components: 3, bitDepth: 8)
        let fileURL = try await writeEncodedTempFile(
            image: sourceImage,
            useHTJ2K: false,
            qualityLayers: 2,
            decompositionLevels: 2
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try await server.registerImage(name: "study.jp2", at: fileURL)
        try await server.start()

        let client = JPIPClient(serverURL: URL(string: "http://localhost:\(port)")!)

        // 1. Full image retrieval (lossless exact match)
        let fullImage = try await client.requestImage(imageID: "study.jp2")
        XCTAssertEqual(fullImage.width, 32)
        XCTAssertEqual(fullImage.height, 32)
        XCTAssertEqual(fullImage.components.count, 3)
        for c in 0..<3 {
            XCTAssertEqual(fullImage.components[c].data, sourceImage.components[c].data)
        }

        // 2. Spatial sub-region retrieval (exact crop match)
        let region = try await client.requestRegion(
            imageID: "study.jp2",
            region: (x: 4, y: 6, width: 12, height: 10),
            layers: 2
        )
        XCTAssertEqual(region.width, 12)
        XCTAssertEqual(region.height, 10)
        XCTAssertEqual(region.components.count, 3)
        for y in 0..<10 {
            for x in 0..<12 {
                let expected = sourceImage.components[0].data[(y + 6) * 32 + (x + 4)]
                let actual = region.components[0].data[y * 12 + x]
                XCTAssertEqual(actual, expected)
            }
        }

        // 3. Progressive quality retrieval
        let progressive = try await client.requestProgressiveQuality(
            imageID: "study.jp2",
            upToLayers: 1
        )
        XCTAssertEqual(progressive.width, 32)
        XCTAssertEqual(progressive.height, 32)
        XCTAssertEqual(progressive.components.count, 3)

        // 4. Resolution level retrieval (level 1 = half resolution = 16x16)
        let halfRes = try await client.requestResolutionLevel(
            imageID: "study.jp2",
            level: 1,
            layers: 2
        )
        XCTAssertEqual(halfRes.width, 16)
        XCTAssertEqual(halfRes.height, 16)
        XCTAssertEqual(halfRes.components.count, 3)

        // 5. Component subset retrieval (component [1] only)
        let singleComp = try await client.requestComponents(
            imageID: "study.jp2",
            components: [1],
            layers: 2
        )
        XCTAssertEqual(singleComp.width, 32)
        XCTAssertEqual(singleComp.height, 32)
        XCTAssertEqual(singleComp.components.count, 1)
        XCTAssertEqual(singleComp.components[0].data, sourceImage.components[1].data)

        // 6. Metadata retrieval (DICOMJPIPClient compatibility keys)
        let metadata = try await client.requestMetadata(imageID: "study.jp2")
        XCTAssertEqual(metadata["width"] as? Int, 32)
        XCTAssertEqual(metadata["height"] as? Int, 32)
        XCTAssertEqual(metadata["components"] as? Int, 3)
        XCTAssertEqual(metadata["bitDepth"] as? Int, 8)

        try await client.close()
        try await server.stop()
    }

    // MARK: - 2. On-the-Fly HTJ2K Transcoding Over JPIP Loopback

    func testJPIPHTJ2KTranscodingPreferenceEndToEnd() async throws {
        let port = Int.random(in: 39_000..<49_000)
        let server = JPIPServer(port: port)
        let sourceImage = makeTestJ2KImage(width: 24, height: 24, components: 1, bitDepth: 8)
        let fileURL = try await writeEncodedTempFile(
            image: sourceImage,
            useHTJ2K: false,
            qualityLayers: 1,
            decompositionLevels: 2
        )
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try await server.registerImage(name: "gray.jp2", at: fileURL)
        try await server.start()

        let client = JPIPClient(
            serverURL: URL(string: "http://localhost:\(port)")!,
            codingPreference: .htj2k
        )
        let decoded = try await client.requestImage(imageID: "gray.jp2")
        XCTAssertEqual(decoded.width, 24)
        XCTAssertEqual(decoded.height, 24)
        XCTAssertEqual(decoded.components[0].data, sourceImage.components[0].data)

        try await client.close()
        try await server.stop()
    }

    // MARK: - 3. Inactive Cache Entry Compression & Transparent Decompression

    func testCacheManagerCompressInactiveEntriesReclaimsMemoryAndDecompressesOnRead() async throws {
        let config = JPIPCacheManagerConfiguration(
            maxMemorySize: 10 * 1024 * 1024,
            maxDiskSize: 20 * 1024 * 1024,
            maxEntries: 500,
            enableCompression: true,
            compressionInactivityThreshold: 0
        )
        let manager = JPIPClientCacheManager(configuration: config)

        // Repetitive payload > 64 bytes compresses well with RLE
        let originalPayload = Data(repeating: 0xAB, count: 4096)
        let bin = JPIPDataBin(
            binClass: .precinct,
            binID: 42,
            data: originalPayload,
            isComplete: true
        )
        await manager.addDataBin(bin, imageID: "test-img", resolutionLevel: 0)

        let savedBytes = await manager.compressInactiveEntries()
        XCTAssertGreaterThan(savedBytes, 3000)

        // Retrieving the bin must transparently decompress back to the exact 4096-byte payload
        let retrieved = await manager.getDataBin(
            binClass: .precinct,
            binID: 42,
            imageID: "test-img"
        )
        XCTAssertNotNil(retrieved)
        XCTAssertEqual(retrieved?.data, originalPayload)
        XCTAssertEqual(retrieved?.isComplete, true)
    }

    // MARK: - 4. Checked Arithmetic & Reassembly in JPIPDataBinGenerator

    func testDataBinGeneratorCheckedArithmeticAndReassembly() async throws {
        let generator = JPIPDataBinGenerator()

        // Truncated SOT marker with oversized Psot must throw cleanly without trapping
        let malformed = Data([0xFF, 0x4F, 0xFF, 0x51, 0x00, 0x04, 0x00, 0x00, 0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00, 0x7F, 0xFF, 0xFF, 0xFF, 0x00, 0x01, 0xFF, 0x93])
        let bins = try generator.generateDataBins(from: malformed)
        XCTAssertFalse(bins.isEmpty)

        // Reassemble from valid image data bins and verify decode
        let sourceImage = makeTestJ2KImage(width: 16, height: 16, components: 1, bitDepth: 8)
        let encoded = try await J2KEncoder(encodingConfiguration: .init(lossless: true)).encode(sourceImage)
        let validBins = try generator.generateDataBins(from: encoded)
        let reassembled = generator.reassembleCodestream(from: validBins)
        XCTAssertFalse(reassembled.isEmpty)
        let decoded = try await J2KDecoder().decode(reassembled)
        XCTAssertEqual(decoded.width, 16)
        XCTAssertEqual(decoded.height, 16)
        XCTAssertEqual(decoded.components[0].data, sourceImage.components[0].data)
    }

    // MARK: - 5. Contract API-13 JPIPStreamingSession Surface

    func testContractAPI13JPIPStreamingSession2DAnd3D() async throws {
        let port = Int.random(in: 49_000..<59_000)
        let server = JPIPServer(port: port)
        let sourceImage = makeTestJ2KImage(width: 32, height: 32, components: 3, bitDepth: 8)
        let fileURL = try await writeEncodedTempFile(image: sourceImage)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try await server.registerImage(name: "contract.jp2", at: fileURL)
        try await server.start()

        let sessionConfig = try JPIPSessionConfiguration(
            codingPreference: .none,
            deliveryMode: .incremental,
            maxCachedDataBins: 1000,
            maxCacheSizeBytes: 10 * 1024 * 1024
        )
        let session = JPIPStreamingSession(
            server: server,
            port: port,
            configuration: sessionConfig
        )

        final class PhaseRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var phases: [ProgressUpdate.Phase] = []
            func record(_ phase: ProgressUpdate.Phase) {
                lock.lock()
                phases.append(phase)
                lock.unlock()
            }
        }
        let recorder = PhaseRecorder()
        let options = JPIPStreamingOptions(
            resourceLimits: .default,
            executionPolicy: .automatic,
            copyPolicy: .allowCopy,
            metadataPolicy: .discardAncillary,
            progress: { update in
                recorder.record(update.phase)
            }
        )

        // 1. Full image delivery returning contract `Image` + `OperationReport`
        let delivered = try await session.deliverImage(
            imageID: "contract.jp2",
            viewWindow: nil,
            options: options
        )
        XCTAssertEqual(delivered.image.descriptor.width, 32)
        XCTAssertEqual(delivered.image.descriptor.height, 32)
        XCTAssertTrue(delivered.image.descriptor.colour == .rgb)
        XCTAssertEqual(delivered.image.descriptor.components.count, 3)
        XCTAssertTrue(delivered.report.fidelity == .exactSamples)
        XCTAssertEqual(delivered.report.discardedMetadataCount, 0)
        XCTAssertEqual(delivered.report.copyEvents.count, 1)
        XCTAssertTrue(recorder.phases.contains(.completed))

        // 2. ViewWindow spatial sub-region delivery
        let regionWindow = try JPIPViewWindow(
            region: (x: 8, y: 8, width: 16, height: 16),
            maxQualityLayers: 2
        )
        let deliveredRegion = try await session.deliverImage(
            imageID: "contract.jp2",
            viewWindow: regionWindow,
            options: options
        )
        XCTAssertEqual(deliveredRegion.image.descriptor.width, 16)
        XCTAssertEqual(deliveredRegion.image.descriptor.height, 16)

        // 3. ResourceLimits enforcement on delivered image
        let tightLimits = try ResourceLimits(maximumDimension: 8)
        await XCTAssertThrowsErrorAsync(
            try await session.deliverImage(
                imageID: "contract.jp2",
                viewWindow: nil,
                options: JPIPStreamingOptions(resourceLimits: tightLimits)
            )
        )

        // 4. 3D Volumetric region delivery
        let volRegion = JP3DStreamingRegion(
            xRange: 0..<16,
            yRange: 0..<16,
            zRange: 0..<4,
            qualityLayer: 2,
            resolutionLevel: 0
        )
        let volDelivered = try await session.deliverVolumeRegion(
            volumeID: "vol-1",
            region: volRegion,
            options: options
        )
        XCTAssertFalse(volDelivered.bins.isEmpty)
        XCTAssertTrue(volDelivered.report.fidelity == .exactSamples)

        try await session.close()
        try await server.stop()
    }

    // MARK: - 6. DICOMKit JPIP Consumer Surface Compatibility (DICOMJPIPClient + dicom-jpip)

    func testDICOMKitJPIPConsumerSurfaceCompatibility() async throws {
        // Exercises the exact JPIPServer.Configuration, JPIPServer, JPIPClient, and J2KImage
        // signatures consumed by DICOMKit's `Sources/DICOMKit/DICOMJPIPClient.swift` and
        // `Sources/dicom-jpip/main.swift`.
        let port = Int.random(in: 59_001..<64_000)
        let config = JPIPServer.Configuration(
            maxClients: 16,
            maxQueueSize: 64,
            globalBandwidthLimit: nil,
            perClientBandwidthLimit: nil,
            sessionTimeout: 300
        )
        let server = JPIPServer(port: port, configuration: config)
        let sourceImage = makeTestJ2KImage(width: 16, height: 16, components: 1, bitDepth: 8)
        let fileURL = try await writeEncodedTempFile(image: sourceImage)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        try await server.registerImage(name: "CT0001", at: fileURL)
        try await server.start()

        let serverURL = URL(string: "http://localhost:\(port)")!
        let jpipURI = serverURL.appendingPathComponent("CT0001")
        let client = JPIPClient(serverURL: serverURL)

        // 1. DICOMJPIPClient.fetchImage pattern
        let full = try await client.requestImage(imageID: jpipURI.lastPathComponent)
        XCTAssertEqual(full.width, 16)
        XCTAssertEqual(full.height, 16)
        XCTAssertEqual(full.components.count, 1)
        XCTAssertEqual(full.components.first?.bitDepth, 8)
        XCTAssertEqual(full.components[0].data, sourceImage.components[0].data)

        // 2. DICOMJPIPClient.fetchRegion pattern (2-argument call without `layers:`)
        let region = try await client.requestRegion(
            imageID: jpipURI.lastPathComponent,
            region: (x: 2, y: 2, width: 8, height: 8)
        )
        XCTAssertEqual(region.width, 8)
        XCTAssertEqual(region.height, 8)

        // 3. DICOMJPIPClient.fetchProgressiveQuality pattern
        let preview = try await client.requestProgressiveQuality(
            imageID: jpipURI.lastPathComponent,
            upToLayers: 1
        )
        XCTAssertEqual(preview.width, 16)
        XCTAssertEqual(preview.height, 16)

        // 4. DICOMJPIPClient.fetchResolutionLevel pattern
        let thumbnail = try await client.requestResolutionLevel(
            imageID: jpipURI.lastPathComponent,
            level: 1,
            layers: 1
        )
        XCTAssertEqual(thumbnail.width, 8)
        XCTAssertEqual(thumbnail.height, 8)

        // 5. dicom-jpip ServeCommand statistics pattern
        let stats = await server.getStatistics()
        XCTAssertGreaterThanOrEqual(stats.totalRequests, 4)
        XCTAssertGreaterThan(stats.totalBytesSent, 0)

        try await client.close()
        try await server.stop()
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        // Expected
    }
}
