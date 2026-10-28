// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJ2K

// MARK: - Helper to Extract Raw Storage Bytes

private func rawStorageBytes(_ image: Image) throws -> [UInt8] {
    try image.storage.withUnsafeBytes { Array($0) }
}

// MARK: - 1. ExecutionPolicy & Platform Availability Matrix (PLAT-05, API-03, API-07, Decision M1)

@Test func executionPolicyAndAvailabilityMatrixHonoursContract() async throws {
    let encoder = try Encoder()
    let decoder = try Decoder()
    let transcoder = try Transcoder(configuration: .init(mode: .lossless))

    #expect(AccelerationRuntime.isAvailable)
    #expect(AccelerationRuntime.isSIMDAvailable)
    #expect(encoder.capabilities.availableBackends == [.scalarCPU, .accelerated])
    #expect(decoder.capabilities.availableBackends == [.scalarCPU, .accelerated])

    let entry = Fixtures.manifest.fixtures.first { $0.name == "g16_17x9_alternating" }!
    let samples = try Fixtures.samples(entry)
    let image = try makeImage(samples, width: entry.width, height: entry.height, bits: entry.meaningfulBits)

    // 1. Normal hardware availability:
    let autoEnc = try await encoder.encode(image, options: .init(executionPolicy: .automatic))
    #expect(autoEnc.report.backend == .accelerated && autoEnc.report.fallbackReason == nil)

    let scalarEnc = try await encoder.encode(image, options: .init(executionPolicy: .scalarCPU))
    #expect(scalarEnc.report.backend == .scalarCPU && scalarEnc.report.fallbackReason == nil)
    #expect(autoEnc.data == scalarEnc.data)

    let prefScalarEnc = try await encoder.encode(image, options: .init(executionPolicy: .preferred(.scalarCPU)))
    #expect(prefScalarEnc.report.backend == .scalarCPU && prefScalarEnc.report.fallbackReason == nil)

    let reqScalarEnc = try await encoder.encode(image, options: .init(executionPolicy: .required(.scalarCPU)))
    #expect(reqScalarEnc.report.backend == .scalarCPU && reqScalarEnc.report.fallbackReason == nil)

    let prefAccEnc = try await encoder.encode(image, options: .init(executionPolicy: .preferred(.accelerated)))
    #expect(prefAccEnc.report.backend == .accelerated && prefAccEnc.report.fallbackReason == nil)
    #expect(prefAccEnc.data == scalarEnc.data)

    let reqAccEnc = try await encoder.encode(image, options: .init(executionPolicy: .required(.accelerated)))
    #expect(reqAccEnc.report.backend == .accelerated && reqAccEnc.report.fallbackReason == nil)
    #expect(reqAccEnc.data == scalarEnc.data)

    // 2. Simulated hardware unavailability (deterministic fallback & error verification):
    try await AccelerationRuntime.withSimulatedUnavailable {
        #expect(!AccelerationRuntime.isAvailable)
        #expect(!AccelerationRuntime.isSIMDAvailable)
        #expect(!AccelerationRuntime.isMetalAvailable)
        #expect(Encoder.capabilities.availableBackends == [.scalarCPU])
        #expect(Decoder.capabilities.availableBackends == [.scalarCPU])

        // .automatic selects .scalarCPU without fallbackReason
        let unavailAutoEnc = try await encoder.encode(image, options: .init(executionPolicy: .automatic))
        #expect(unavailAutoEnc.report.backend == .scalarCPU && unavailAutoEnc.report.fallbackReason == nil)
        #expect(unavailAutoEnc.data == scalarEnc.data)

        // .preferred(.accelerated) falls back to .scalarCPU with non-nil fallbackReason
        let unavailPrefEnc = try await encoder.encode(image, options: .init(executionPolicy: .preferred(.accelerated)))
        #expect(unavailPrefEnc.report.backend == .scalarCPU)
        #expect(unavailPrefEnc.report.fallbackReason != nil && !(unavailPrefEnc.report.fallbackReason?.isEmpty ?? true))
        #expect(unavailPrefEnc.data == scalarEnc.data)

        let unavailPrefDec = try await decoder.decode(scalarEnc.data, options: .init(executionPolicy: .preferred(.accelerated)))
        #expect(unavailPrefDec.report.backend == .scalarCPU)
        #expect(unavailPrefDec.report.fallbackReason != nil)

        let unavailPrefTrans = try await transcoder.transcode(scalarEnc.data, to: .htj2k, options: .init(executionPolicy: .preferred(.accelerated)))
        #expect(unavailPrefTrans.report.backend == .scalarCPU)
        #expect(unavailPrefTrans.report.fallbackReason != nil)

        // .required(.accelerated) fails in preflight with .backendUnavailable and leaves destination reusable
        do {
            _ = try decoder.inspect(scalarEnc.data, options: .init(executionPolicy: .required(.accelerated)))
            Issue.record("Expected .backendUnavailable on inspect")
        } catch let error as CodecError {
            #expect(error.category == .backendUnavailable)
        }

        do {
            _ = try await decoder.decode(scalarEnc.data, options: .init(executionPolicy: .required(.accelerated)))
            Issue.record("Expected .backendUnavailable on allocating decode")
        } catch let error as CodecError {
            #expect(error.category == .backendUnavailable)
        }

        let destination = try ImageDestination.allocate(
            descriptor: .greyscale16(width: entry.width, height: entry.height, meaningfulBits: entry.meaningfulBits)
        )
        do {
            _ = try await decoder.decode(scalarEnc.data, into: destination, options: .init(executionPolicy: .required(.accelerated)))
            Issue.record("Expected .backendUnavailable on destination decode")
        } catch let error as CodecError {
            #expect(error.category == .backendUnavailable)
        }
        // Destination remains reusable after preflight rejection:
        let reused = try await decoder.decode(scalarEnc.data, into: destination, options: .init(executionPolicy: .scalarCPU))
        #expect(reused.report.backend == .scalarCPU && reused.report.pixelAllocationCount == 0)

        do {
            _ = try await encoder.encode(image, options: .init(executionPolicy: .required(.accelerated)))
            Issue.record("Expected .backendUnavailable on encode")
        } catch let error as CodecError {
            #expect(error.category == .backendUnavailable)
        }

        do {
            _ = try await transcoder.transcode(scalarEnc.data, to: .htj2k, options: .init(executionPolicy: .required(.accelerated)))
            Issue.record("Expected .backendUnavailable on transcode")
        } catch let error as CodecError {
            #expect(error.category == .backendUnavailable)
        }
    }
}

// MARK: - 2. Byte-Identity Across All Lossless Part 1 Fixtures

@Test func acceleratedDecodeAndEncodeAreByteIdenticalAcrossAllLosslessFixtures() async throws {
    let decoder = try Decoder()
    let encoder = try Encoder()

    // 1. Decode byte-identity across all 51 independent lossless codestreams:
    for (_, codestream) in Fixtures.allCodestreams {
        let data = try Fixtures.bytes(codestream.file)
        let scalarDec = try await decoder.decode(data, options: .init(executionPolicy: .scalarCPU))
        let accelDec = try await decoder.decode(data, options: .init(executionPolicy: .required(.accelerated)))
        #expect(scalarDec.report.backend == .scalarCPU)
        #expect(accelDec.report.backend == .accelerated)
        #expect(try rawStorageBytes(scalarDec.image) == rawStorageBytes(accelDec.image),
                "Accelerated decode differed from scalar on \(codestream.file)")

        if AccelerationRuntime.isMetalAvailable {
            let metalDec = try await AcceleratedCodec.withForcedMetalDispatch(true) {
                try await decoder.decode(data, options: .init(executionPolicy: .required(.accelerated)))
            }
            #expect(metalDec.report.backend == .accelerated)
            #expect(try rawStorageBytes(scalarDec.image) == rawStorageBytes(metalDec.image),
                    "Forced-Metal decode differed from scalar on \(codestream.file)")
        }
    }

    // 2. Encode byte-identity across all 10 fixture images:
    for entry in Fixtures.manifest.fixtures {
        let samples = try Fixtures.samples(entry)
        let image = try makeImage(samples, width: entry.width, height: entry.height, bits: entry.meaningfulBits)
        let scalarEnc = try await encoder.encode(image, options: .init(executionPolicy: .scalarCPU))
        let accelEnc = try await encoder.encode(image, options: .init(executionPolicy: .required(.accelerated)))
        #expect(scalarEnc.report.backend == .scalarCPU)
        #expect(accelEnc.report.backend == .accelerated)
        #expect(scalarEnc.data == accelEnc.data, "Accelerated Part 1 encode differed from scalar on \(entry.name)")

        if AccelerationRuntime.isMetalAvailable {
            let metalEnc = try await AcceleratedCodec.withForcedMetalDispatch(true) {
                try await encoder.encode(image, options: .init(executionPolicy: .required(.accelerated)))
            }
            #expect(metalEnc.report.backend == .accelerated)
            #expect(scalarEnc.data == metalEnc.data, "Forced-Metal Part 1 encode differed from scalar on \(entry.name)")
        }
    }
}

// MARK: - 3. Byte-Identity Across All HTJ2K Fixtures and Compressed-Domain Transcoding

@Test func acceleratedHTJ2KAndTranscodeAreByteIdenticalAcrossAllFixtures() async throws {
    let decoder = try Decoder()
    let htEncoder = try Encoder(configuration: EncoderConfiguration(
        mode: .lossless,
        codecOptions: try CodecOptions(blockCoding: .htj2k)
    ))
    let transcoder = try Transcoder(configuration: .init(mode: .lossless))

    // 1. Decode byte-identity across all 120 HTJ2K codestreams:
    for (_, codestream) in HTJ2KFixtures.allCodestreams {
        let data = try HTJ2KFixtures.bytes(codestream.file)
        let scalarDec = try await decoder.decode(data, options: .init(executionPolicy: .scalarCPU))
        let accelDec = try await decoder.decode(data, options: .init(executionPolicy: .required(.accelerated)))
        #expect(scalarDec.report.backend == .scalarCPU)
        #expect(accelDec.report.backend == .accelerated)
        #expect(try rawStorageBytes(scalarDec.image) == rawStorageBytes(accelDec.image),
                "Accelerated HTJ2K decode differed from scalar on \(codestream.file)")
    }

    // 2. HTJ2K encode and J2K <-> HTJ2K transcode byte-identity across all 10 fixture images:
    for entry in Fixtures.manifest.fixtures {
        let samples = try Fixtures.samples(entry)
        let image = try makeImage(samples, width: entry.width, height: entry.height, bits: entry.meaningfulBits)

        let scalarHT = try await htEncoder.encode(image, options: .init(executionPolicy: .scalarCPU))
        let accelHT = try await htEncoder.encode(image, options: .init(executionPolicy: .required(.accelerated)))
        #expect(scalarHT.report.backend == .scalarCPU && accelHT.report.backend == .accelerated)
        #expect(scalarHT.data == accelHT.data, "Accelerated HTJ2K encode differed from scalar on \(entry.name)")

        let part1Source = try Fixtures.bytes(entry.codestreams[0].file)
        let scalarToHT = try await transcoder.transcode(part1Source, to: .htj2k, options: .init(executionPolicy: .scalarCPU))
        let accelToHT = try await transcoder.transcode(part1Source, to: .htj2k, options: .init(executionPolicy: .required(.accelerated)))
        #expect(scalarToHT.report.backend == .scalarCPU && accelToHT.report.backend == .accelerated)
        #expect(scalarToHT.report.pixelAllocationCount == 0 && accelToHT.report.pixelAllocationCount == 0)
        #expect(scalarToHT.data == accelToHT.data, "Accelerated J2K->HTJ2K transcode differed from scalar on \(entry.name)")

        let scalarToJ2K = try await transcoder.transcode(scalarToHT.data, to: .jpeg2000, options: .init(executionPolicy: .scalarCPU))
        let accelToJ2K = try await transcoder.transcode(scalarToHT.data, to: .jpeg2000, options: .init(executionPolicy: .required(.accelerated)))
        #expect(scalarToJ2K.report.backend == .scalarCPU && accelToJ2K.report.backend == .accelerated)
        #expect(scalarToJ2K.data == accelToJ2K.data, "Accelerated HTJ2K->J2K transcode differed from scalar on \(entry.name)")

        if AccelerationRuntime.isMetalAvailable {
            let metalHT = try await AcceleratedCodec.withForcedMetalDispatch(true) {
                try await htEncoder.encode(image, options: .init(executionPolicy: .required(.accelerated)))
            }
            #expect(scalarHT.data == metalHT.data, "Forced-Metal HTJ2K encode differed from scalar on \(entry.name)")

            let metalToHT = try await AcceleratedCodec.withForcedMetalDispatch(true) {
                try await transcoder.transcode(part1Source, to: .htj2k, options: .init(executionPolicy: .required(.accelerated)))
            }
            #expect(scalarToHT.data == metalToHT.data, "Forced-Metal J2K->HTJ2K transcode differed from scalar on \(entry.name)")
        }
    }
}

// MARK: - 4. Byte-Identity Across All Part 1 Breadth and Container Fixtures

@Test func acceleratedPart1BreadthAndContainersAreByteIdenticalAcrossAllFixtures() async throws {
    let decoder = try Decoder()

    // 1. Decode byte-identity across all 22 Part 1 breadth fixtures (RCT, ICT, 9/7 lossy, signed, ROI, tiles, layers, POC):
    for entry in Part1BreadthFixtures.manifest.fixtures {
        let data = try Part1BreadthFixtures.codestreamBytes(entry)
        let scalarDec = try await decoder.decode(data, options: .init(executionPolicy: .scalarCPU))
        let accelDec = try await decoder.decode(data, options: .init(executionPolicy: .required(.accelerated)))
        #expect(scalarDec.report.backend == .scalarCPU && accelDec.report.backend == .accelerated)
        #expect(try rawStorageBytes(scalarDec.image) == rawStorageBytes(accelDec.image),
                "Accelerated Part 1 breadth decode differed from scalar on \(entry.file)")

        if AccelerationRuntime.isMetalAvailable {
            let metalDec = try await AcceleratedCodec.withForcedMetalDispatch(true) {
                try await decoder.decode(data, options: .init(executionPolicy: .required(.accelerated)))
            }
            #expect(try rawStorageBytes(scalarDec.image) == rawStorageBytes(metalDec.image),
                    "Forced-Metal Part 1 breadth decode differed from scalar on \(entry.file)")
        }
    }

    // 2. Decode byte-identity across all 16 JP2/JPH/JPX container fixtures:
    for entry in ContainerFixtures.manifest.fixtures {
        let data = try ContainerFixtures.bytes(entry)
        let scalarDec = try await decoder.decode(data, options: .init(executionPolicy: .scalarCPU))
        let accelDec = try await decoder.decode(data, options: .init(executionPolicy: .required(.accelerated)))
        #expect(scalarDec.report.backend == .scalarCPU && accelDec.report.backend == .accelerated)
        #expect(try rawStorageBytes(scalarDec.image) == rawStorageBytes(accelDec.image),
                "Accelerated container decode differed from scalar on \(entry.file)")
        #expect(scalarDec.image.metadata == accelDec.image.metadata)

        if AccelerationRuntime.isMetalAvailable {
            let metalDec = try await AcceleratedCodec.withForcedMetalDispatch(true) {
                try await decoder.decode(data, options: .init(executionPolicy: .required(.accelerated)))
            }
            #expect(try rawStorageBytes(scalarDec.image) == rawStorageBytes(metalDec.image),
                    "Forced-Metal container decode differed from scalar on \(entry.file)")
        }
    }

    // 3. Encode byte-identity across Part 1 breadth modes & containers (RCT, ICT 9/7, ROI near-lossless, multi-tile, JP2/JPH/JPX):
    let w = 36, h = 28
    var rPlane = [Int](repeating: 0, count: w * h)
    var gPlane = [Int](repeating: 0, count: w * h)
    var bPlane = [Int](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            let idx = y * w + x
            rPlane[idx] = (x * 7 + y * 3) & 255
            gPlane[idx] = (x * 5 + y * 11 + 40) & 255
            bPlane[idx] = (x * 13 + y * 2 + 90) & 255
        }
    }
    let rgbImage = try makeMultiPlaneImage(
        planes: [rPlane, gPlane, bPlane],
        width: w, height: h, meaningfulBits: 8, storageBits: 8, signed: false
    )

    let configs: [EncoderConfiguration] = [
        try EncoderConfiguration(
            mode: .lossless,
            codecOptions: try CodecOptions(wavelet: .reversible53, colourTransform: .rct, tileWidth: 16, tileHeight: 16, containerFormat: .jp2)
        ),
        try EncoderConfiguration(
            mode: .lossy,
            codecOptions: try CodecOptions(wavelet: .irreversible97, colourTransform: .ict, quality: 0.85, qualityLayers: 2, containerFormat: .jpx)
        ),
        try EncoderConfiguration(
            mode: .nearLossless(maximumAbsoluteError: 2),
            codecOptions: try CodecOptions(
                wavelet: .reversible53,
                colourTransform: .rct,
                regionOfInterest: try .init(x: 4, y: 4, width: 12, height: 12)
            )
        ),
        try EncoderConfiguration(
            mode: .lossless,
            codecOptions: try CodecOptions(blockCoding: .htj2k, colourTransform: .rct, containerFormat: .jph)
        )
    ]

    for config in configs {
        let enc = try Encoder(configuration: config)
        let scalarOut = try await enc.encode(rgbImage, options: .init(executionPolicy: .scalarCPU))
        let accelOut = try await enc.encode(rgbImage, options: .init(executionPolicy: .required(.accelerated)))
        #expect(scalarOut.report.backend == .scalarCPU && accelOut.report.backend == .accelerated)
        #expect(scalarOut.data == accelOut.data)

        if AccelerationRuntime.isMetalAvailable {
            let metalOut = try await AcceleratedCodec.withForcedMetalDispatch(true) {
                try await enc.encode(rgbImage, options: .init(executionPolicy: .required(.accelerated)))
            }
            #expect(scalarOut.data == metalOut.data)
        }
    }
}

// MARK: - 5. Direct Kernel Parity & Predecessor Audit Regressions (M9-AUD-001..005)

@Test func directKernelParityAndPredecessorAuditRegressions() async throws {
    // 1. M9-AUD-001 & M9-AUD-002: HTJ2K UVLC large exponent residual (u_q > 32 -> ext bits) & bandShift parity
    let bw = 16, bh = 16
    var htCoeffs = [Int32](repeating: 0, count: bw * bh)
    // Populate 29-bit reversible dynamic range values so u_q reaches the maximum UVLC range:
    for i in 0..<htCoeffs.count {
        let sign: Int32 = (i & 1 == 0) ? 1 : -1
        let mag = Int32((1 << (i % 29)) - 1)
        htCoeffs[i] = sign * mag
    }
    for shift in [0, 1, 3] {
        let scalarBlock = try HTBlockEncoder.encodeCleanup(
            coefficients: htCoeffs, width: bw, height: bh, bandShift: shift
        )
        let simdBlock = try SIMDHTBlockCoder.encodeCleanup(
            coefficients: htCoeffs, width: bw, height: bh, bandShift: shift
        )
        #expect(scalarBlock == simdBlock, "SIMDHTBlockCoder cleanup bytes differed at bandShift=\(shift)")

        if AccelerationRuntime.isMetalAvailable {
            let gpuQuads = try MetalAccelerationEngine.shared.classifyHTQuads(
                coefficients: htCoeffs, width: bw, height: bh, bandShift: shift
            )
            let simdQuads = try SIMDHTBlockCoder.classifyQuads(
                coefficients: htCoeffs, width: bw, height: bh, bandShift: shift
            )
            #expect(gpuQuads == simdQuads, "Metal GPU quad classification differed at bandShift=\(shift)")
            let metalBlock = try SIMDHTBlockCoder.encodeCleanup(
                coefficients: htCoeffs, width: bw, height: bh, bandShift: shift, preclassifiedQuads: gpuQuads
            )
            #expect(scalarBlock == metalBlock)
        }

        let kMax = 30
        let missingMSBs = (kMax - 1) - shift
        let scalarDec = try HTBlockDecoder.decodeCleanup(
            block: scalarBlock, width: bw, height: bh, kMax: kMax, missingMSBs: missingMSBs
        )
        let simdDec = try SIMDHTBlockCoder.decodeCleanup(
            block: simdBlock, width: bw, height: bh, kMax: kMax, missingMSBs: missingMSBs
        )
        #expect(scalarDec == simdDec)
    }

    // 2. M9-AUD-003: 5/3 DWT odd origins (x0/y0 odd), n == 1 (* 2 / / 2), non-multiple-of-4 geometries, and 32-bit overflow
    let geometries: [(x0: Int, x1: Int, y0: Int, y1: Int, levels: Int)] = [
        (0, 1, 0, 1, 3),
        (1, 2, 1, 2, 3),     // n == 1 with odd origin (requires * 2 on forward and / 2 on inverse)
        (3, 4, 2, 9, 4),     // 1x7 with odd x0
        (5, 10, 7, 10, 4),   // 5x3 with odd x0 and odd y0
        (1, 18, 3, 12, 5),   // 17x9 with odd x0 and odd y0
        (0, 33, 0, 19, 5)    // 33x19 non-multiple of 4
    ]
    for g in geometries {
        let w = g.x1 - g.x0
        let h = g.y1 - g.y0
        var basePlane = [Int32](repeating: 0, count: w * h)
        for i in 0..<basePlane.count {
            basePlane[i] = Int32((i * 173 - 91) % 32768)
        }
        var scalarPlane = basePlane
        var simdPlane = basePlane
        try Wavelet53.forward(plane: &scalarPlane, stride: w, x0: g.x0, x1: g.x1, y0: g.y0, y1: g.y1, levels: g.levels) {}
        try SIMDWavelet53.forward(plane: &simdPlane, stride: w, x0: g.x0, x1: g.x1, y0: g.y0, y1: g.y1, levels: g.levels) {}
        #expect(scalarPlane == simdPlane, "SIMDWavelet53.forward differed for geometry \(g)")

        if AccelerationRuntime.isMetalAvailable {
            var metalPlane = basePlane
            try MetalAccelerationEngine.shared.forwardWavelet53(
                plane: &metalPlane, stride: w, x0: g.x0, x1: g.x1, y0: g.y0, y1: g.y1, levels: g.levels
            )
            #expect(scalarPlane == metalPlane, "Metal forwardWavelet53 differed for geometry \(g)")

            try MetalAccelerationEngine.shared.inverseWavelet53(
                plane: &metalPlane, stride: w, x0: g.x0, x1: g.x1, y0: g.y0, y1: g.y1, levels: g.levels
            )
            #expect(metalPlane == basePlane, "Metal inverseWavelet53 failed round-trip for geometry \(g)")
        }

        try Wavelet53.inverse(plane: &scalarPlane, stride: w, x0: g.x0, x1: g.x1, y0: g.y0, y1: g.y1, levels: g.levels) {}
        try SIMDWavelet53.inverse(plane: &simdPlane, stride: w, x0: g.x0, x1: g.x1, y0: g.y0, y1: g.y1, levels: g.levels) {}
        #expect(scalarPlane == basePlane && simdPlane == basePlane)
    }

    // Verify 32-bit synthesis overflow throws .malformedInput in both SIMDWavelet53 and MetalAccelerationEngine:
    var overflowPlane: [Int32] = [Int32.max, Int32.min, Int32.max, Int32.min]
    do {
        try SIMDWavelet53.inverse(plane: &overflowPlane, stride: 2, x0: 0, x1: 2, y0: 0, y1: 2, levels: 1) {}
        Issue.record("Expected SIMDWavelet53 synthesis overflow to throw")
    } catch let error as CodecError {
        #expect(error.category == .malformedInput)
    }
    if AccelerationRuntime.isMetalAvailable {
        var metalOverflowPlane: [Int32] = [Int32.max, Int32.min, Int32.max, Int32.min]
        do {
            try MetalAccelerationEngine.shared.inverseWavelet53(
                plane: &metalOverflowPlane, stride: 2, x0: 0, x1: 2, y0: 0, y1: 2, levels: 1
            )
            Issue.record("Expected Metal inverseWavelet53 synthesis overflow to throw")
        } catch let error as CodecError {
            #expect(error.category == .malformedInput)
        }
    }

    // 3. M9-AUD-004: 9/7 DWT IEEE-754 Double parity across odd origins and multiple levels
    for g in geometries {
        let w = g.x1 - g.x0
        let h = g.y1 - g.y0
        var base97 = [Double](repeating: 0.0, count: w * h)
        for i in 0..<base97.count {
            base97[i] = Double((i * 97 - 53) % 1024) * 0.25
        }
        var scalar97 = base97
        var simd97 = base97
        try Wavelet97.forward(plane: &scalar97, stride: w, x0: g.x0, x1: g.x1, y0: g.y0, y1: g.y1, levels: g.levels) {}
        try SIMDWavelet97.forward(plane: &simd97, stride: w, x0: g.x0, x1: g.x1, y0: g.y0, y1: g.y1, levels: g.levels) {}
        #expect(scalar97 == simd97, "SIMDWavelet97.forward differed from Wavelet97 for geometry \(g)")

        try Wavelet97.inverse(plane: &scalar97, stride: w, x0: g.x0, x1: g.x1, y0: g.y0, y1: g.y1, levels: g.levels) {}
        try SIMDWavelet97.inverse(plane: &simd97, stride: w, x0: g.x0, x1: g.x1, y0: g.y0, y1: g.y1, levels: g.levels) {}
        #expect(scalar97 == simd97, "SIMDWavelet97.inverse differed from Wavelet97 for geometry \(g)")
    }

    // 4. M9-AUD-005: RCT 64-bit intermediate arithmetic (preventing 32-bit overflow when R + 2*G + B > Int32.max)
    let extremeR: [Int32] = [1_073_741_820, -1_073_741_820, 900_000_000, -900_000_000, 123_456_789]
    let extremeG: [Int32] = [1_073_741_820, -1_073_741_820, 800_000_000, -800_000_000, -98_765_432]
    let extremeB: [Int32] = [1_073_741_820, -1_073_741_820, 700_000_000, -700_000_000, 55_555_555]
    let origPlanes = [extremeR, extremeG, extremeB]

    var scalarRCT = origPlanes
    var simdRCT = origPlanes
    ColourTransform.forwardRCT(planes: &scalarRCT)
    SIMDColourTransform.forwardRCT(planes: &simdRCT)
    #expect(scalarRCT == simdRCT, "SIMDColourTransform.forwardRCT differed on extreme 32-bit inputs")

    if AccelerationRuntime.isMetalAvailable {
        var metalRCT = origPlanes
        try MetalAccelerationEngine.shared.forwardRCT(planes: &metalRCT)
        #expect(scalarRCT == metalRCT, "Metal forwardRCT differed on extreme 32-bit inputs")
        try MetalAccelerationEngine.shared.inverseRCT(planes: &metalRCT)
        #expect(metalRCT == origPlanes, "Metal inverseRCT failed round-trip on extreme 32-bit inputs")
    }

    ColourTransform.inverseRCT(planes: &scalarRCT)
    SIMDColourTransform.inverseRCT(planes: &simdRCT)
    #expect(scalarRCT == origPlanes && simdRCT == origPlanes)

    // 5. Zero-copy caller-owned destination with prefix and row padding under .required(.accelerated) + Metal
    let entry = Fixtures.manifest.fixtures.first { $0.name == "g16_64x64_random" }!
    let expectedSamples = try Fixtures.samples(entry)
    let streamData = try Fixtures.bytes("g16_64x64_random.opj.j2k")
    let prefix = 8
    let rowBytes = 64 * 2 + 16
    let paddedDesc = try ImageDescriptor.greyscale16(
        width: 64, height: 64, meaningfulBits: 16, rowBytes: rowBytes, offset: prefix
    )
    let paddedDest = try ImageDestination.allocate(descriptor: paddedDesc)
    let decodedPadded = try await AcceleratedCodec.withForcedMetalDispatch(true) {
        try await Decoder().decode(streamData, into: paddedDest, options: .init(executionPolicy: .required(.accelerated)))
    }
    #expect(decodedPadded.report.backend == .accelerated)
    #expect(decodedPadded.report.pixelAllocationCount == 0)
    #expect(decodedPadded.report.copyEvents.isEmpty)
    try expectSamples(decodedPadded.image, equal: expectedSamples, width: 64, height: 64)

    // 6. Cold vs Warm Metal telemetry verification (PERF-01 / PERF-02):
    if AccelerationRuntime.isMetalAvailable {
        let coldEngine = MetalAccelerationEngine.makeFreshInstanceForBenchmarking()
        var testPlane = [Int32](repeating: 42, count: 64 * 64)
        try coldEngine.forwardWavelet53(plane: &testPlane, stride: 64, x0: 0, x1: 64, y0: 0, y1: 64, levels: 3)
        let afterCold = coldEngine.telemetrySnapshot()
        #expect(afterCold.isAvailable)
        #expect(afterCold.shaderCompilationDurationNs > 0)
        #expect(afterCold.dispatchCount == 1)
        #expect(afterCold.bufferPoolMisses >= 2)

        try coldEngine.inverseWavelet53(plane: &testPlane, stride: 64, x0: 0, x1: 64, y0: 0, y1: 64, levels: 3)
        let afterWarm = coldEngine.telemetrySnapshot()
        #expect(afterWarm.dispatchCount == 2)
        #expect(afterWarm.bufferPoolHits >= 2)
        #expect(testPlane == [Int32](repeating: 42, count: 64 * 64))
    }
}
