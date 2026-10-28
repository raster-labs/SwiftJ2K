// SPDX-License-Identifier: Apache-2.0
//
// JP3DParityAndSurfaceTests.swift
// SwiftJ2K3DTests
//
// Migrated from Raster-Lab/J2KSwift Tests/JP3DTests/V10_18_TrueSelectiveParityTests.swift,
// V10_28_JP3DDecoderPartialOverloadsParityTests.swift,
// V10_30_ProgressStreamParityTests.swift, and
// V10_32_PreWarmSymmetricCompletionTests.swift
// at commit 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca for Milestone 10 (SwiftJ2K3D).

import Foundation
import XCTest
@testable import SwiftJ2K
@testable import SwiftJ2K3D

// MARK: - V10_18_TrueSelectiveParityTests

final class V10_18_TrueSelectiveParityTests: XCTestCase {
    private func makeLCGVolume(
        width: Int = 64, height: Int = 64, depth: Int = 8,
        bitDepth: Int = 16, seed: UInt64 = 0xC0FFEE
    ) -> J2KVolume {
        let bytesPerSample = (bitDepth + 7) / 8
        let voxelCount = width * height * depth
        let maxVal = (1 << bitDepth) - 1
        var data = Data(count: voxelCount * bytesPerSample)
        var s: UInt64 = seed &* 6364136223846793005 &+ 1442695040888963407
        data.withUnsafeMutableBytes { raw in
            if bytesPerSample == 1 {
                let p = raw.bindMemory(to: UInt8.self)
                for i in 0..<voxelCount {
                    s = s &* 6364136223846793005 &+ 1442695040888963407
                    p[i] = UInt8(truncatingIfNeeded: Int((s >> 16) & 0xFFFFFFFF) % (maxVal + 1))
                }
            } else {
                let p = raw.bindMemory(to: UInt16.self)
                for i in 0..<voxelCount {
                    s = s &* 6364136223846793005 &+ 1442695040888963407
                    p[i] = UInt16(truncatingIfNeeded: Int((s >> 16) & 0xFFFFFFFF) % (maxVal + 1))
                }
            }
        }
        let comp = J2KVolumeComponent(
            index: 0, bitDepth: bitDepth, signed: false,
            width: width, height: height, depth: depth,
            data: data)
        return J2KVolume(
            width: width, height: height, depth: depth,
            components: [comp])
    }

    private func voxelValue(
        in volume: J2KVolume,
        x: Int, y: Int, z: Int,
        comp: Int = 0
    ) -> Int {
        guard comp < volume.components.count else { return 0 }
        let c = volume.components[comp]
        let bps = c.bytesPerSample
        let i = ((z * c.height * c.width) + y * c.width + x) * bps
        guard i + bps <= c.data.count else { return 0 }
        return c.data.withUnsafeBytes { raw -> Int in
            switch bps {
            case 1: return Int(raw[i])
            case 2: return Int(raw[i]) | (Int(raw[i + 1]) << 8)
            case 3: return Int(raw[i]) | (Int(raw[i + 1]) << 8) | (Int(raw[i + 2]) << 16)
            case 4: return Int(raw[i]) | (Int(raw[i + 1]) << 8)
                  | (Int(raw[i + 2]) << 16) | (Int(raw[i + 3]) << 24)
            default: return 0
            }
        }
    }

    private func encodeLossless(_ volume: J2KVolume) async throws -> Data {
        let cfg = JP3DEncoderConfiguration(compressionMode: .losslessHTJ2K)
        return try await JP3DEncoder(configuration: cfg).encode(volume).data
    }

    func testFullDecodeLosslessRoundTripBaseline() async throws {
        let volume = makeLCGVolume()
        let codestream = try await encodeLossless(volume)
        let decoded = try await JP3DDecoder().decode(codestream).volume

        XCTAssertEqual(decoded.width,  volume.width)
        XCTAssertEqual(decoded.height, volume.height)
        XCTAssertEqual(decoded.depth,  volume.depth)
        XCTAssertEqual(decoded.components.count, volume.components.count)

        for z in 0..<volume.depth {
            for y in 0..<volume.height {
                for x in 0..<volume.width {
                    let want = voxelValue(in: volume,  x: x, y: y, z: z)
                    let got  = voxelValue(in: decoded, x: x, y: y, z: z)
                    if want != got {
                        XCTFail("Voxel mismatch at (\(x),\(y),\(z)): want=\(want) got=\(got)")
                        return
                    }
                }
            }
        }
    }

    func testROIDecodeMatchesFullDecodeCropped() async throws {
        let volume = makeLCGVolume(width: 64, height: 64, depth: 8)
        let codestream = try await encodeLossless(volume)
        let full = try await JP3DDecoder().decode(codestream).volume

        let region = JP3DRegion(x: 16..<48, y: 16..<48, z: 2..<6)
        let roi = try await JP3DROIDecoder().decode(codestream, region: region).volume

        XCTAssertEqual(roi.width,  region.x.count)
        XCTAssertEqual(roi.height, region.y.count)
        XCTAssertEqual(roi.depth,  region.z.count)

        for (zi, z) in region.z.enumerated() {
            for (yi, y) in region.y.enumerated() {
                for (xi, x) in region.x.enumerated() {
                    let want = voxelValue(in: full, x: x, y: y, z: z)
                    let got  = voxelValue(in: roi, x: xi, y: yi, z: zi)
                    if want != got {
                        XCTFail("ROI voxel mismatch at full(\(x),\(y),\(z)) roi(\(xi),\(yi),\(zi)): want=\(want) got=\(got)")
                        return
                    }
                }
            }
        }
    }

    func testROIDecodeMatchesFullDecodeCroppedAtCorner() async throws {
        let volume = makeLCGVolume(width: 64, height: 64, depth: 8)
        let codestream = try await encodeLossless(volume)
        let full = try await JP3DDecoder().decode(codestream).volume

        let region = JP3DRegion(x: 0..<24, y: 0..<24, z: 0..<4)
        let roi = try await JP3DROIDecoder().decode(codestream, region: region).volume

        for (zi, z) in region.z.enumerated() {
            for (yi, y) in region.y.enumerated() {
                for (xi, x) in region.x.enumerated() {
                    let want = voxelValue(in: full, x: x, y: y, z: z)
                    let got  = voxelValue(in: roi, x: xi, y: yi, z: zi)
                    if want != got {
                        XCTFail("Corner-ROI voxel mismatch at full(\(x),\(y),\(z)) roi(\(xi),\(yi),\(zi)): want=\(want) got=\(got)")
                        return
                    }
                }
            }
        }
    }

    func testPartialResolutionShape() async throws {
        let volume = makeLCGVolume(width: 64, height: 64, depth: 8)
        let codestream = try await encodeLossless(volume)

        let cfg = JP3DDecoderConfiguration(resolutionLevel: 1)
        let half = try await JP3DDecoder(configuration: cfg).decode(codestream).volume

        XCTAssertEqual(half.width,  (volume.width + 1) / 2)
        XCTAssertEqual(half.height, (volume.height + 1) / 2)
        XCTAssertEqual(half.depth,  volume.depth)
    }

    func testPartialResolutionDeterministic() async throws {
        let volume = makeLCGVolume(width: 64, height: 64, depth: 8)
        let codestream = try await encodeLossless(volume)

        let cfg = JP3DDecoderConfiguration(resolutionLevel: 1)
        let a = try await JP3DDecoder(configuration: cfg).decode(codestream).volume
        let b = try await JP3DDecoder(configuration: cfg).decode(codestream).volume

        XCTAssertEqual(a.width,  b.width)
        XCTAssertEqual(a.height, b.height)
        XCTAssertEqual(a.depth,  b.depth)
        XCTAssertEqual(a.components.count, b.components.count)
        XCTAssertEqual(a.components.first?.data, b.components.first?.data)
    }

    func testResolutionLevel0IsBitExactFullDecode() async throws {
        let volume = makeLCGVolume(width: 48, height: 48, depth: 6)
        let codestream = try await encodeLossless(volume)

        let defaultDecoder = try await JP3DDecoder().decode(codestream).volume
        let level0Cfg = JP3DDecoderConfiguration(resolutionLevel: 0)
        let level0 = try await JP3DDecoder(configuration: level0Cfg).decode(codestream).volume

        XCTAssertEqual(defaultDecoder.width,  level0.width)
        XCTAssertEqual(defaultDecoder.height, level0.height)
        XCTAssertEqual(defaultDecoder.depth,  level0.depth)
        XCTAssertEqual(defaultDecoder.components.first?.data, level0.components.first?.data)
    }

    func testPartialResolutionLevel2Shape() async throws {
        let volume = makeLCGVolume(width: 64, height: 64, depth: 6)
        let codestream = try await encodeLossless(volume)

        let cfg = JP3DDecoderConfiguration(resolutionLevel: 2)
        let quarter = try await JP3DDecoder(configuration: cfg).decode(codestream).volume

        XCTAssertEqual(quarter.width,  (volume.width + 3) / 4)
        XCTAssertEqual(quarter.height, (volume.height + 3) / 4)
        XCTAssertEqual(quarter.depth,  volume.depth)
    }

    func testZNarrowROIBitExactWithFullCropped() async throws {
        let volume = makeLCGVolume(width: 64, height: 64, depth: 16)
        let codestream = try await encodeLossless(volume)

        let region = JP3DRegion(x: 0..<64, y: 0..<64, z: 8..<12)
        let roi = try await JP3DROIDecoder().decode(codestream, region: region).volume
        let full = try await JP3DDecoder().decode(codestream).volume

        XCTAssertEqual(roi.width, 64)
        XCTAssertEqual(roi.height, 64)
        XCTAssertEqual(roi.depth, 4)

        for (zi, z) in (8..<12).enumerated() {
            for y in 0..<64 {
                for x in 0..<64 {
                    let want = voxelValue(in: full, x: x, y: y, z: z)
                    let got  = voxelValue(in: roi, x: x, y: y, z: zi)
                    if want != got {
                        XCTFail("Z-narrow voxel mismatch at full(\(x),\(y),\(z)) roi(\(x),\(y),\(zi)): want=\(want) got=\(got)")
                        return
                    }
                }
            }
        }
    }

    func testCombinedResolutionLevelAndROI() async throws {
        let volume = makeLCGVolume(width: 64, height: 64, depth: 8)
        let codestream = try await encodeLossless(volume)

        let cfg = JP3DDecoderConfiguration(resolutionLevel: 1)
        let fullPartial = try await JP3DDecoder(configuration: cfg).decode(codestream).volume

        let region = JP3DRegion(x: 16..<48, y: 16..<48, z: 0..<4)
        let combined = try await JP3DROIDecoder(configuration: cfg)
            .decode(codestream, region: region).volume

        let dRegionX = (region.x.lowerBound >> 1)..<((region.x.upperBound + 1) >> 1)
        let dRegionY = (region.y.lowerBound >> 1)..<((region.y.upperBound + 1) >> 1)
        XCTAssertEqual(combined.width,  dRegionX.count)
        XCTAssertEqual(combined.height, dRegionY.count)
        XCTAssertEqual(combined.depth,  region.z.count)

        for (zi, z) in region.z.enumerated() {
            for (yi, y) in dRegionY.enumerated() {
                for (xi, x) in dRegionX.enumerated() {
                    let want = voxelValue(in: fullPartial, x: x, y: y, z: z)
                    let got  = voxelValue(in: combined, x: xi, y: yi, z: zi)
                    if want != got {
                        XCTFail("K+ROI voxel mismatch at fullPartial(\(x),\(y),\(z)) combined(\(xi),\(yi),\(zi)): want=\(want) got=\(got)")
                        return
                    }
                }
            }
        }
    }
}

// MARK: - V10_28_JP3DDecoderPartialOverloadsParityTests

final class V10_28_JP3DDecoderPartialOverloadsParityTests: XCTestCase {
    private func makeLCGVolume(
        width: Int, height: Int, depth: Int, seed: UInt64 = 0xCAFEBABE
    ) -> J2KVolume {
        let voxelCount = width * height * depth
        var data = Data(count: voxelCount * 2)
        var s: UInt64 = seed &* 6364136223846793005 &+ 1442695040888963407
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt16.self)
            for i in 0..<voxelCount {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                p[i] = UInt16(truncatingIfNeeded: Int((s >> 16) & 0xFFFF))
            }
        }
        let comp = J2KVolumeComponent(
            index: 0, bitDepth: 16, signed: false,
            width: width, height: height, depth: depth,
            data: data)
        return J2KVolume(
            width: width, height: height, depth: depth,
            components: [comp])
    }

    private func encodeLossless(_ volume: J2KVolume) async throws -> Data {
        let encoder = JP3DEncoder(configuration: JP3DEncoderConfiguration(
            compressionMode: .losslessHTJ2K))
        return try await encoder.encode(volume).data
    }

    func testDecodeResolutionLevelOverloadBitExact() async throws {
        let volume = makeLCGVolume(width: 64, height: 64, depth: 8)
        let codestream = try await encodeLossless(volume)

        let refCfg = JP3DDecoderConfiguration(resolutionLevel: 1)
        let referenceResult = try await JP3DDecoder(configuration: refCfg).decode(codestream)
        let convenienceResult = try await JP3DDecoder().decode(codestream, resolutionLevel: 1)

        XCTAssertEqual(referenceResult.volume.width, convenienceResult.volume.width)
        XCTAssertEqual(referenceResult.volume.height, convenienceResult.volume.height)
        XCTAssertEqual(referenceResult.volume.depth, convenienceResult.volume.depth)
        XCTAssertEqual(referenceResult.volume.components.count, convenienceResult.volume.components.count)
        for (rc, cc) in zip(referenceResult.volume.components, convenienceResult.volume.components) {
            XCTAssertEqual(rc.data, cc.data)
        }
    }

    func testDecodeRegionOverloadBitExact() async throws {
        let volume = makeLCGVolume(width: 64, height: 64, depth: 8)
        let codestream = try await encodeLossless(volume)

        let region = JP3DRegion(x: 16..<48, y: 16..<48, z: 2..<6)

        let referenceResult = try await JP3DROIDecoder().decode(codestream, region: region)
        let convenienceResult = try await JP3DDecoder().decode(codestream, region: region)

        XCTAssertEqual(referenceResult.volume.width, convenienceResult.volume.width)
        XCTAssertEqual(referenceResult.volume.height, convenienceResult.volume.height)
        XCTAssertEqual(referenceResult.volume.depth, convenienceResult.volume.depth)
        XCTAssertEqual(referenceResult.tilesDecoded, convenienceResult.tilesDecoded)
        XCTAssertEqual(referenceResult.tilesSkipped, convenienceResult.tilesSkipped)
        for (rc, cc) in zip(referenceResult.volume.components, convenienceResult.volume.components) {
            XCTAssertEqual(rc.data, cc.data)
        }
    }

    func testDecodeRegionAndResolutionLevelOverloadBitExact() async throws {
        let volume = makeLCGVolume(width: 64, height: 64, depth: 8)
        let codestream = try await encodeLossless(volume)

        let region = JP3DRegion(x: 16..<48, y: 16..<48, z: 2..<6)
        let level = 1

        let refCfg = JP3DDecoderConfiguration(resolutionLevel: level)
        let referenceResult = try await JP3DROIDecoder(configuration: refCfg).decode(codestream, region: region)
        let convenienceResult = try await JP3DDecoder().decode(codestream, region: region, resolutionLevel: level)

        XCTAssertEqual(referenceResult.volume.width, convenienceResult.volume.width)
        XCTAssertEqual(referenceResult.volume.height, convenienceResult.volume.height)
        XCTAssertEqual(referenceResult.volume.depth, convenienceResult.volume.depth)
        for (rc, cc) in zip(referenceResult.volume.components, convenienceResult.volume.components) {
            XCTAssertEqual(rc.data, cc.data)
        }
    }

    func testDecodeResolutionLevelZeroIsNoOp() async throws {
        let volume = makeLCGVolume(width: 64, height: 64, depth: 8)
        let codestream = try await encodeLossless(volume)

        let fullResult = try await JP3DDecoder().decode(codestream)
        let levelZeroResult = try await JP3DDecoder().decode(codestream, resolutionLevel: 0)

        XCTAssertEqual(fullResult.volume.width, levelZeroResult.volume.width)
        XCTAssertEqual(fullResult.volume.height, levelZeroResult.volume.height)
        XCTAssertEqual(fullResult.volume.depth, levelZeroResult.volume.depth)
        for (rc, cc) in zip(fullResult.volume.components, levelZeroResult.volume.components) {
            XCTAssertEqual(rc.data, cc.data)
        }
    }

    func testNegativeResolutionLevelIsClamped() async throws {
        let volume = makeLCGVolume(width: 64, height: 64, depth: 8)
        let codestream = try await encodeLossless(volume)

        let fullResult = try await JP3DDecoder().decode(codestream)
        let clampedResult = try await JP3DDecoder().decode(codestream, resolutionLevel: -3)

        XCTAssertEqual(fullResult.volume.width, clampedResult.volume.width)
        XCTAssertEqual(fullResult.volume.height, clampedResult.volume.height)
        XCTAssertEqual(fullResult.volume.depth, clampedResult.volume.depth)
    }

    func testConfigurationPropagatesThroughOverload() async throws {
        let volume = makeLCGVolume(width: 64, height: 64, depth: 8)
        let codestream = try await encodeLossless(volume)

        let outerCfg = JP3DDecoderConfiguration(
            maxQualityLayers: 0,
            resolutionLevel: 0,
            tolerateErrors: false)

        let result = try await JP3DDecoder(configuration: outerCfg).decode(codestream, resolutionLevel: 1)
        XCTAssertGreaterThan(result.volume.width, 0)
        XCTAssertGreaterThan(result.volume.height, 0)
        XCTAssertGreaterThan(result.volume.depth, 0)
    }
}

// MARK: - V10_30_ProgressStreamParityTests

final class V10_30_ProgressStreamParityTests: XCTestCase {
    private func makeLCGVolume(
        width: Int, height: Int, depth: Int, seed: UInt64 = 0xDEAD_BEEF
    ) -> J2KVolume {
        let voxelCount = width * height * depth
        var data = Data(count: voxelCount * 2)
        var s: UInt64 = seed &* 6364136223846793005 &+ 1442695040888963407
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt16.self)
            for i in 0..<voxelCount {
                s = s &* 6364136223846793005 &+ 1442695040888963407
                p[i] = UInt16(truncatingIfNeeded: Int((s >> 16) & 0xFFFF))
            }
        }
        let comp = J2KVolumeComponent(
            index: 0, bitDepth: 16, signed: false,
            width: width, height: height, depth: depth,
            data: data)
        return J2KVolume(
            width: width, height: height, depth: depth,
            components: [comp])
    }

    func testJP3DDecoderProgressStreamDeliversEvents() async throws {
        let volume = makeLCGVolume(width: 64, height: 64, depth: 8)
        let codestream = try await JP3DEncoder(configuration: .init(
            compressionMode: .losslessHTJ2K)).encode(volume).data

        let decoder = JP3DDecoder()
        let stream = await decoder.progressStream()

        let eventsTask = Task<[JP3DDecoderProgress], Never> {
            var collected: [JP3DDecoderProgress] = []
            for await progress in stream {
                collected.append(progress)
                if progress.stage == .volumeAssembly,
                   progress.overallProgress >= 0.99 {
                    break
                }
            }
            return collected
        }

        _ = try await decoder.decode(codestream)

        try await Task.sleep(nanoseconds: 50_000_000)
        eventsTask.cancel()
        let events = await eventsTask.value

        XCTAssertGreaterThan(events.count, 0)
        if let lastOverall = events.map({ $0.overallProgress }).max() {
            XCTAssertGreaterThan(lastOverall, 0.5)
        }
    }

    func testJP3DROIDecoderProgressStreamSurfaceIsAvailable() async throws {
        let volume = makeLCGVolume(width: 64, height: 64, depth: 8)
        let codestream = try await JP3DEncoder(configuration: .init(
            compressionMode: .losslessHTJ2K)).encode(volume).data

        let decoder = JP3DROIDecoder()
        let stream = await decoder.progressStream()

        let eventsTask = Task<[JP3DDecoderProgress], Never> {
            var collected: [JP3DDecoderProgress] = []
            for await progress in stream {
                collected.append(progress)
                if collected.count >= 1 { break }
            }
            return collected
        }

        let region = JP3DRegion(x: 16..<48, y: 16..<48, z: 2..<6)
        let result = try await decoder.decode(codestream, region: region)
        XCTAssertGreaterThan(result.volume.width, 0)

        try await Task.sleep(nanoseconds: 50_000_000)
        eventsTask.cancel()
        _ = await eventsTask.value
    }

    func testJP3DEncoderProgressStreamDeliversEvents() async throws {
        let volume = makeLCGVolume(width: 64, height: 64, depth: 8)

        let encoder = JP3DEncoder(configuration: .init(compressionMode: .losslessHTJ2K))
        let stream = await encoder.progressStream()

        let eventsTask = Task<[JP3DEncoderProgress], Never> {
            var collected: [JP3DEncoderProgress] = []
            for await progress in stream {
                collected.append(progress)
                if progress.overallProgress >= 0.99 { break }
            }
            return collected
        }

        _ = try await encoder.encode(volume)

        try await Task.sleep(nanoseconds: 50_000_000)
        eventsTask.cancel()
        let events = await eventsTask.value

        XCTAssertGreaterThan(events.count, 0)
        let observedStages = Set(events.map { $0.stage })
        XCTAssertFalse(observedStages.isEmpty)
    }

    func testSetProgressCallbackStillWorksAfterProgressStream() async throws {
        let volume = makeLCGVolume(width: 64, height: 64, depth: 8)
        let codestream = try await JP3DEncoder(configuration: .init(
            compressionMode: .losslessHTJ2K)).encode(volume).data

        let decoder = JP3DDecoder()
        _ = await decoder.progressStream()

        let counter = ProgressCounter()
        await decoder.setProgressCallback { _ in
            Task { await counter.increment() }
        }

        _ = try await decoder.decode(codestream)
        try await Task.sleep(nanoseconds: 50_000_000)

        let count = await counter.count
        XCTAssertGreaterThan(count, 0)
    }

    actor ProgressCounter {
        var count: Int = 0
        func increment() { count += 1 }
    }
}

// MARK: - V10_32_PreWarmSymmetricCompletionTests

final class V10_32_PreWarmSymmetricCompletionTests: XCTestCase {
    func testJP3DEncoderPreWarmCallable() async {
        await JP3DEncoder.preWarm()
        await JP3DEncoder.preWarm(includeWarmupDispatch: false)
    }

    func testJP3DDecoderPreWarmCallable() async {
        await JP3DDecoder.preWarm()
        await JP3DDecoder.preWarm(includeWarmupDispatch: false)
    }

    func testJP3DROIDecoderPreWarmCallable() async {
        await JP3DROIDecoder.preWarm()
        await JP3DROIDecoder.preWarm(includeWarmupDispatch: false)
    }

    func testJP3DMultiSpectralDecoderPreWarmCallable() async {
        await JP3DMultiSpectralDecoder.preWarm()
        await JP3DMultiSpectralDecoder.preWarm(includeWarmupDispatch: false)
    }

    func testJP3DMultiSpectralEncoderPreWarmCallable() async {
        await JP3DMultiSpectralEncoder.preWarm()
        await JP3DMultiSpectralEncoder.preWarm(includeWarmupDispatch: false)
    }

    func testJP3DProgressiveDecoderPreWarmCallable() async {
        await JP3DProgressiveDecoder.preWarm()
        await JP3DProgressiveDecoder.preWarm(includeWarmupDispatch: false)
    }

    func testJP3DStreamWriterPreWarmCallable() async {
        await JP3DStreamWriter.preWarm()
        await JP3DStreamWriter.preWarm(includeWarmupDispatch: false)
    }

    func testJP3DTranscoderPreWarmCallable() async {
        await JP3DTranscoder.preWarm()
        await JP3DTranscoder.preWarm(includeWarmupDispatch: false)
    }
}

// MARK: - JP3DMetalDWTTests

final class JP3DMetalDWTTests: XCTestCase {
    func testMetalDWTForwardInverseRoundTrip() async throws {
        let metalDWT = JP3DMetalDWT(backend: .automatic)
        try await metalDWT.initialize()
        var data = [Float](repeating: 0, count: 8 * 8 * 4)
        for i in 0..<data.count {
            data[i] = Float((i * 17) % 100)
        }
        let (low, high) = try await metalDWT.forward53X(data: data, width: 8, height: 8, depth: 4)
        let reconstructed = try await metalDWT.inverse53X(
            low: low,
            high: high,
            origWidth: 8,
            height: 8,
            depth: 4
        )
        XCTAssertEqual(reconstructed.count, data.count)
        for i in 0..<data.count {
            XCTAssertEqual(reconstructed[i], data[i], accuracy: 1e-4)
        }
        let stats = await metalDWT.statistics()
        XCTAssertEqual(stats.forwardTransforms, 1)
        XCTAssertEqual(stats.inverseTransforms, 1)
    }
}
