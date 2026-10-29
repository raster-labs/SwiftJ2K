// SPDX-License-Identifier: Apache-2.0
//
// R2JPIPRemediationTests.swift
// SwiftJ2KJPIPTests
//
// Phase R2 JPIP semantics remediation regressions covering:
// - F07: Palette (`pclr`/`cmap`), channel-definition (`cdef`), and Restricted ICC (`colr`)
//        reconciliation across `JPIPDataBinGenerator`, `JPIPServer`, `JPIPClient`, and
//        `JPIPStreamingSession` (including on-the-fly HTJ2K `codingPreference` transcoding).
// - F09: Enforcement of `CopyPolicy`, `ExecutionPolicy` (including simulated unavailability),
//        and truthful `OperationReport` telemetry (`copyEvents`, `peakPixelBytes`,
//        `peakWorkspaceBytes`, and real `discardedMetadata*` counts/bytes/kinds).
// - F10: Simultaneous composition of `JPIPViewWindow` constraints (`region` + `resolutionLevel` +
//        `maxQualityLayers` + `components`), out-of-bounds region/component rejection, and
//        `JPIPSessionConfiguration` cache/delivery enforcement (`maxCachedDataBins`,
//        `maxCacheSizeBytes`, `deliveryMode`).

import Foundation
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2K3D
@testable import SwiftJ2KJPIP

private func jpipContainerFixtureURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Tests/SwiftJ2KTests/Fixtures/Containers")
        .appendingPathComponent(name)
}

@Suite("Phase R2 — SwiftJ2KJPIP Semantics Remediation Regressions")
struct R2JPIPRemediationTests {

    // MARK: F07 — Palette, Channel Definition, and ICC Preservation Through JPIP

    @Test("F07: JPIPDataBinGenerator, JPIPServer, and JPIPStreamingSession preserve pclr/cmap, cdef, and ICC under .none and .htj2k codingPreference")
    func jpipPreservesPaletteCdefAndICCSemantics() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftj2k-r2-jpip-f07-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let palURL = jpipContainerFixtureURL("jp2_pal8_pclr_cmap_resc.kdu.jp2")
        let rgbaURL = jpipContainerFixtureURL("jp2_rgba8_cdef.kdu.jp2")
        let iccURL = jpipContainerFixtureURL("jp2_rgb8_icc_res_meta.kdu.jp2")

        // Verify JPIPDataBinGenerator preserves JP2 container framing (ihdr/pclr/cmap/colr) across generate & reassemble
        let generator = JPIPDataBinGenerator()
        let palBins = try generator.generateDataBins(from: Data(contentsOf: palURL))
        #expect(palBins.contains { $0.binClass == .metadata })
        let reassembledPal = generator.reassembleCodestream(from: palBins)
        #expect(try await J2KDecoder().decode(reassembledPal).componentCount == 3)

        let server = JPIPServer(port: 19_411)
        try await server.registerImage(name: "pal.jp2", at: palURL)
        try await server.registerImage(name: "rgba.jp2", at: rgbaURL)
        try await server.registerImage(name: "icc.jp2", at: iccURL)
        try await server.start()
        defer { Task { try? await server.stop() } }

        for codingPref in [JPIPCodingPreference.none, JPIPCodingPreference.htj2k] {
            let session = JPIPStreamingSession(
                server: server,
                port: 19_411,
                configuration: try JPIPSessionConfiguration(codingPreference: codingPref)
            )

            // 1. Palettised JP2 (`pclr`/`cmap`) -> 3-component RGB matching direct `Decoder().decode`
            let directPal = try await Decoder().decode(Data(contentsOf: palURL)).image
            let jpipPal = try await session.deliverImage(imageID: "pal.jp2")
            #expect(jpipPal.image.descriptor.components == [.red, .green, .blue])
            #expect(jpipPal.image.descriptor.colour == .rgb)
            #expect(jpipPal.legacyImage.componentCount == 3)
            for y in 0..<directPal.descriptor.height {
                for x in 0..<directPal.descriptor.width {
                    for c in 0..<3 {
                        let expected = try directPal.sampleInt(component: c, x: x, y: y)
                        let actual = try jpipPal.image.sampleInt(component: c, x: x, y: y)
                        #expect(actual == expected)
                    }
                }
            }

            // 2. RGBA `cdef` JP2 -> 4-component RGBA with straight alpha matching direct `Decoder().decode`
            let directRGBA = try await Decoder().decode(Data(contentsOf: rgbaURL)).image
            let jpipRGBA = try await session.deliverImage(imageID: "rgba.jp2")
            #expect(jpipRGBA.image.descriptor.components == directRGBA.descriptor.components)
            #expect(jpipRGBA.image.descriptor.alpha == directRGBA.descriptor.alpha)
            for y in 0..<min(4, directRGBA.descriptor.height) {
                for x in 0..<min(4, directRGBA.descriptor.width) {
                    for c in 0..<4 {
                        #expect(
                            try jpipRGBA.image.sampleInt(component: c, x: x, y: y)
                            == directRGBA.sampleInt(component: c, x: x, y: y)
                        )
                    }
                }
            }

            // 3. Restricted ICC JP2 -> preserves ICC profile bytes in delivered contract & legacy images
            let directICC = try await Decoder().decode(Data(contentsOf: iccURL)).image
            let jpipICC = try await session.deliverImage(imageID: "icc.jp2")
            #expect(jpipICC.image.descriptor.iccProfile == directICC.descriptor.iccProfile)
            if case .iccProfile(let legacyProf) = jpipICC.legacyImage.colorSpace {
                #expect(legacyProf == directICC.descriptor.iccProfile)
            } else {
                Issue.record("Expected JPIP legacyImage.colorSpace to carry Restricted ICC profile")
            }

            try await session.close()
        }
    }

    // MARK: F09 — CopyPolicy, ExecutionPolicy, and Truthful OperationReport Telemetry

    @Test("F09: JPIPStreamingSession enforces CopyPolicy and ExecutionPolicy and reports truthful CopyEvent and discarded metadata telemetry")
    func jpipPoliciesAndOperationReportTelemetry() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftj2k-r2-jpip-f09-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Synthetic clean JP2 without any ancillary boxes or COM markers vs Kakadu JP2 with XML + UUID + COM metadata
        let cleanDesc = try ImageDescriptor.rgbPlanar(width: 8, height: 8, storageBits: 8, meaningfulBits: 8)
        let cleanDest = try ImageDestination.allocate(descriptor: cleanDesc)
        let cleanSrc = try cleanDest.writeSamples { c, x, y in (c * 50 + y * 8 + x) & 0xFF }
        let cleanData = try await Encoder(
            configuration: EncoderConfiguration(
                mode: .lossless,
                codecOptions: CodecOptions(containerFormat: .jp2)
            )
        ).encode(cleanSrc, options: EncodeOptions(metadataPolicy: .discardAncillary)).data
        let cleanURL = tmpDir.appendingPathComponent("synthetic_clean.jp2")
        try cleanData.write(to: cleanURL)

        let kduComURL = jpipContainerFixtureURL("jp2_rgb8_rct.kdu.jp2")
        let metaURL = jpipContainerFixtureURL("jp2_rgb8_icc_res_meta.kdu.jp2")

        let server = JPIPServer(port: 19_412)
        try await server.registerImage(name: "clean.jp2", at: cleanURL)
        try await server.registerImage(name: "kdu_com.jp2", at: kduComURL)
        try await server.registerImage(name: "meta.jp2", at: metaURL)
        try await server.start()
        defer { Task { try? await server.stop() } }

        let session = JPIPStreamingSession(server: server, port: 19_412)

        // 1. `copyPolicy: .requireSharedStorage` must fail truthfully with `.incompatibleImageLayout`
        do {
            _ = try await session.deliverImage(
                imageID: "clean.jp2",
                options: JPIPStreamingOptions(copyPolicy: .requireSharedStorage)
            )
            Issue.record("Expected JPIPStreamingSession.deliverImage to reject .requireSharedStorage")
        } catch let err as CodecError {
            #expect(err.category == .incompatibleImageLayout)
        }

        // 2. `copyPolicy: .allowCopy` + `executionPolicy: .scalarCPU` + `.discardAncillary` on zero-metadata JP2
        let cleanDelivered = try await session.deliverImage(
            imageID: "clean.jp2",
            options: JPIPStreamingOptions(
                executionPolicy: .scalarCPU,
                copyPolicy: .allowCopy,
                metadataPolicy: .discardAncillary
            )
        )
        #expect(cleanDelivered.report.backend == .scalarCPU)
        #expect(cleanDelivered.report.fallbackReason == nil)
        #expect(cleanDelivered.report.copyEvents.count == 1)
        #expect(cleanDelivered.report.copyEvents[0].bytesMoved > 0)
        #expect((cleanDelivered.report.pixelAllocationCount ?? 0) >= 4)
        #expect((cleanDelivered.report.peakWorkspaceBytes ?? 0) > 0)
        // Zero-metadata JP2 has zero ancillary boxes and zero COM markers -> must report 0, not fabricated data.count / 16
        #expect(cleanDelivered.report.discardedMetadataCount == 0)
        #expect(cleanDelivered.report.discardedMetadataBytes == 0)
        #expect(cleanDelivered.report.discardedMetadataKinds.isEmpty)

        // 3. `.discardAncillary` on Kakadu codestream with COM markers and on JP2 with XML/UUID boxes reports exact real counts
        let kduComDelivered = try await session.deliverImage(
            imageID: "kdu_com.jp2",
            options: JPIPStreamingOptions(copyPolicy: .allowCopy, metadataPolicy: .discardAncillary)
        )
        #expect(kduComDelivered.report.discardedMetadataCount == 2)
        #expect(kduComDelivered.report.discardedMetadataBytes == 105)
        #expect(kduComDelivered.report.discardedMetadataKinds == ["COM"])

        let metaDelivered = try await session.deliverImage(
            imageID: "meta.jp2",
            options: JPIPStreamingOptions(
                copyPolicy: .allowCopy,
                metadataPolicy: .discardAncillary
            )
        )
        #expect((metaDelivered.report.discardedMetadataCount ?? 0) > 2)
        #expect((metaDelivered.report.discardedMetadataBytes ?? 0) > 105)
        #expect(!metaDelivered.report.discardedMetadataKinds.isEmpty)
        #expect(metaDelivered.image.metadata.entries.isEmpty)

        // 4. Simulated backend unavailability enforces `.required(.accelerated)` and `.preferred(.accelerated)`
        try await AccelerationRuntime.$forceUnavailable.withValue(true) {
            do {
                _ = try await session.deliverImage(
                    imageID: "clean.jp2",
                    options: JPIPStreamingOptions(executionPolicy: .required(.accelerated))
                )
                Issue.record("Expected JPIPStreamingSession.deliverImage to throw .backendUnavailable")
            } catch let err as CodecError {
                #expect(err.category == .backendUnavailable)
            }

            let fallbackDelivered = try await session.deliverImage(
                imageID: "clean.jp2",
                options: JPIPStreamingOptions(executionPolicy: .preferred(.accelerated))
            )
            #expect(fallbackDelivered.report.backend == .scalarCPU)
            #expect(fallbackDelivered.report.fallbackReason != nil)
        }

        try await session.close()
    }

    // MARK: F10 — JPIPViewWindow Composition & JPIPSessionConfiguration Cache/Delivery Enforcement

    @Test("F10: JPIPViewWindow composes region, resolutionLevel, maxQualityLayers, and components simultaneously and validates bounds")
    func jpipViewWindowConstraintCompositionAndBoundsValidation() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftj2k-r2-jpip-f10-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Encode a 16x16 3-component RGB JP2 with 2 decomposition levels and 2 quality layers
        let width = 16, height = 16
        let desc = try ImageDescriptor.rgbPlanar(width: width, height: height, storageBits: 8, meaningfulBits: 8)
        let dest = try ImageDestination.allocate(descriptor: desc)
        let srcImg = try dest.writeSamples { c, x, y in
            // Constant within 2x2 blocks so level-1 averaging is exact:
            let bx = x / 2
            let by = y / 2
            return (c * 60 + by * 7 + bx * 3) & 0xFF
        }
        let encodedJP2 = try await Encoder(
            configuration: EncoderConfiguration(
                mode: .lossless,
                codecOptions: CodecOptions(
                    decompositionLevels: 2,
                    colourTransform: .none,
                    qualityLayers: 2,
                    containerFormat: .jp2
                )
            )
        ).encode(srcImg).data
        let jp2URL = tmpDir.appendingPathComponent("multi16.jp2")
        try encodedJP2.write(to: jp2URL)

        let server = JPIPServer(port: 19_413)
        try await server.registerImage(name: "multi16.jp2", at: jp2URL)
        try await server.start()
        defer { Task { try? await server.stop() } }

        let session = JPIPStreamingSession(server: server, port: 19_413)

        // 1. Combined view window:
        //    - region: (x: 4, y: 2, width: 8, height: 6) -> cropped 8x6
        //    - resolutionLevel: 1 -> downsampled by 2^1 to 4x3
        //    - maxQualityLayers: 1 -> partial layer decode (report.fidelity == .lossy)
        //    - components: [2, 0] -> 2 components in [Blue, Red] order!
        let combinedWindow = try JPIPViewWindow(
            region: (x: 4, y: 2, width: 8, height: 6),
            resolutionLevel: 1,
            maxQualityLayers: 1,
            components: [2, 0]
        )
        let delivered = try await session.deliverImage(
            imageID: "multi16.jp2",
            viewWindow: combinedWindow
        )
        #expect(delivered.image.descriptor.width == 4)
        #expect(delivered.image.descriptor.height == 3)
        #expect(delivered.image.descriptor.components.count == 2)
        #expect(delivered.legacyImage.componentCount == 2)
        #expect(delivered.report.fidelity == .lossy)

        // Check full-layer combined window (`maxQualityLayers: 2`) for exact spatial + component values!
        let exactCombined = try JPIPViewWindow(
            region: (x: 4, y: 2, width: 8, height: 6),
            resolutionLevel: 1,
            maxQualityLayers: 2,
            components: [2, 0]
        )
        let exactDelivered = try await session.deliverImage(
            imageID: "multi16.jp2",
            viewWindow: exactCombined
        )
        #expect(exactDelivered.image.descriptor.width == 4)
        #expect(exactDelivered.image.descriptor.height == 3)
        #expect(exactDelivered.image.descriptor.components.count == 2)
        for dy in 0..<3 {
            for dx in 0..<4 {
                let fullX = 4 + dx * 2
                let fullY = 2 + dy * 2
                let expectedBlue = try srcImg.sampleInt(component: 2, x: fullX, y: fullY)
                let expectedRed = try srcImg.sampleInt(component: 0, x: fullX, y: fullY)
                let actualComp0 = try exactDelivered.image.sampleInt(component: 0, x: dx, y: dy)
                let actualComp1 = try exactDelivered.image.sampleInt(component: 1, x: dx, y: dy)
                #expect(actualComp0 == expectedBlue)
                #expect(actualComp1 == expectedRed)
            }
        }

        // 2. Out-of-range component index (`[3]` on 3-component image) -> CodecError(.invalidArgument)
        let badCompWindow = try JPIPViewWindow(components: [0, 3])
        do {
            _ = try await session.deliverImage(imageID: "multi16.jp2", viewWindow: badCompWindow)
            Issue.record("Expected out-of-range JPIPViewWindow component index to throw .invalidArgument")
        } catch let err as CodecError {
            #expect(err.category == .invalidArgument)
        }

        // 3. Out-of-bounds spatial region (`x: 12, width: 8` on 16x16 image) -> CodecError(.invalidArgument)
        let badRegionWindow = try JPIPViewWindow(region: (x: 12, y: 0, width: 8, height: 8))
        do {
            _ = try await session.deliverImage(imageID: "multi16.jp2", viewWindow: badRegionWindow)
            Issue.record("Expected out-of-bounds JPIPViewWindow region to throw .invalidArgument")
        } catch let err as CodecError {
            #expect(err.category == .invalidArgument)
        }

        try await session.close()
    }

    @Test("F10: JPIPSessionConfiguration enforces maxCachedDataBins, maxCacheSizeBytes, and deliveryMode")
    func jpipSessionConfigurationCacheAndDeliveryEnforcement() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftj2k-r2-jpip-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Encode a 64x64 3-component multi-tile high-entropy JP2 (> 4 KiB across >= 6 data-bins)
        let desc = try ImageDescriptor.rgbPlanar(width: 64, height: 64, storageBits: 8, meaningfulBits: 8)
        let dest = try ImageDestination.allocate(descriptor: desc)
        let highEntropy = try dest.writeSamples { c, x, y in
            var v = UInt32(c &* 73 &+ y &* 131 &+ x &* 17 &+ 19)
            v ^= v << 13
            v ^= v >> 17
            v ^= v << 5
            return Int(v & 0xFF)
        }
        let encoded = try await Encoder(
            configuration: EncoderConfiguration(
                mode: .lossless,
                codecOptions: CodecOptions(
                    decompositionLevels: 1,
                    tileWidth: 32,
                    tileHeight: 32,
                    containerFormat: .jp2
                )
            )
        ).encode(highEntropy).data
        #expect(encoded.count > 2_048)
        let jp2URL = tmpDir.appendingPathComponent("large_tiled.jp2")
        try encoded.write(to: jp2URL)

        let server = JPIPServer(port: 19_414)
        try await server.registerImage(name: "large.jp2", at: jp2URL)
        try await server.start()
        defer { Task { try? await server.stop() } }

        // Baseline unconstrained `.incremental` retains all bins (> 2 bins and > 1024 bytes)
        let unconstrained = JPIPStreamingSession(
            server: server,
            port: 19_414,
            configuration: try JPIPSessionConfiguration(
                deliveryMode: .incremental,
                maxCachedDataBins: 1000,
                maxCacheSizeBytes: 1_048_576
            )
        )
        let baseDelivered = try await unconstrained.deliverImage(imageID: "large.jp2")
        #expect(baseDelivered.cachedDataBins > 2)
        #expect(baseDelivered.cachedBytes > 1_024)
        try await unconstrained.close()

        // 1. `maxCachedDataBins: 2` under `.incremental` caps retained cache bins to <= 2
        let binBoundedSession = JPIPStreamingSession(
            server: server,
            port: 19_414,
            configuration: try JPIPSessionConfiguration(
                deliveryMode: .incremental,
                maxCachedDataBins: 2,
                maxCacheSizeBytes: 1_048_576
            )
        )
        let binDelivered = try await binBoundedSession.deliverImage(imageID: "large.jp2")
        #expect(binDelivered.cachedDataBins > 0)
        #expect(binDelivered.cachedDataBins <= 2)
        try await binBoundedSession.close()

        // 2. `maxCacheSizeBytes: 1024` under `.incremental` caps retained cache bytes to <= 1024
        let byteBoundedSession = JPIPStreamingSession(
            server: server,
            port: 19_414,
            configuration: try JPIPSessionConfiguration(
                deliveryMode: .incremental,
                maxCachedDataBins: 1000,
                maxCacheSizeBytes: 1_024
            )
        )
        let byteDelivered = try await byteBoundedSession.deliverImage(imageID: "large.jp2")
        #expect(byteDelivered.cachedBytes <= 1_024)
        try await byteBoundedSession.close()

        // 3. `deliveryMode: .full` bypasses persistent incremental cache retention
        let fullModeSession = JPIPStreamingSession(
            server: server,
            port: 19_414,
            configuration: try JPIPSessionConfiguration(
                deliveryMode: .full,
                maxCachedDataBins: 1000,
                maxCacheSizeBytes: 1_048_576
            )
        )
        let fullDelivered = try await fullModeSession.deliverImage(imageID: "large.jp2")
        #expect(fullDelivered.cachedDataBins == 0)
        #expect(fullDelivered.cachedBytes == 0)
        try await fullModeSession.close()
    }
}
