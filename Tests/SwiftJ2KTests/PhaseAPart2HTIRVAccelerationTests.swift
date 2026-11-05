// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJ2K

@Suite("Phase A Part 2 MCT, HTIRV, Acceleration, and Transcoding")
struct PhaseAPart2HTIRVAccelerationTests {

    // MARK: - Helpers

    private static func makePlanarImage(
        width: Int,
        height: Int,
        componentCount: Int,
        meaningfulBits: Int,
        signed: Bool
    ) throws -> (image: Image, planes: [[Int]]) {
        let storageBits = meaningfulBits <= 8 ? 8 : 16
        let sampleType: SampleType = signed ? .signedInteger : .unsignedInteger
        let descriptor: ImageDescriptor
        if componentCount == 1 {
            if meaningfulBits <= 8 && !signed {
                descriptor = try ImageDescriptor.greyscale8(width: width, height: height)
            } else if signed {
                descriptor = try ImageDescriptor.signedGreyscale16(
                    width: width, height: height, meaningfulBits: meaningfulBits
                )
            } else {
                descriptor = try ImageDescriptor.greyscale16(
                    width: width, height: height, meaningfulBits: meaningfulBits
                )
            }
        } else if componentCount == 3 {
            descriptor = try ImageDescriptor.rgbPlanar(
                width: width, height: height, storageBits: storageBits,
                meaningfulBits: meaningfulBits, signed: signed
            )
        } else {
            descriptor = try ImageDescriptor.multiComponentPlanar(
                width: width, height: height, componentCount: componentCount,
                storageBits: storageBits, meaningfulBits: meaningfulBits,
                sampleType: sampleType
            )
        }

        let minVal = signed ? -(1 << (meaningfulBits - 1)) : 0
        let maxVal = signed ? ((1 << (meaningfulBits - 1)) - 1) : ((1 << meaningfulBits) - 1)
        let span = max(1, maxVal - minVal)
        let count = width * height

        var planes: [[Int]] = []
        for c in 0..<componentCount {
            var plane = [Int](repeating: 0, count: count)
            for y in 0..<height {
                for x in 0..<width {
                    // Smooth gradient + structured wave so both lossless and lossy DWT behave realistically.
                    let grad = ((x * 5 + y * 7 + c * 19) * span) / max(1, (width + height + componentCount) * 7)
                    let wave = ((x ^ (y * 3 + c * 11)) & 7) - 3
                    let raw = minVal + grad + wave
                    plane[y * width + x] = min(max(raw, minVal), maxVal)
                }
            }
            planes.append(plane)
        }

        let localPlanes = planes
        let image = try ImageDestination.allocate(descriptor: descriptor).writeSamples { c, x, y in
            localPlanes[c][y * width + x]
        }
        return (image, planes)
    }

    private static func extractPlanes(_ image: Image) throws -> [[Int]] {
        let d = image.descriptor
        let w = d.width
        let h = d.height
        var out: [[Int]] = []
        out.reserveCapacity(d.components.count)
        for c in 0..<d.components.count {
            var plane = [Int](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    plane[y * w + x] = try image.sampleInt(component: c, x: x, y: y)
                }
            }
            out.append(plane)
        }
        return out
    }

    private static func computePSNR(_ ref: [[Int]], _ rec: [[Int]], bitDepth: Int) -> (mae: Double, maxErr: Int, psnr: Double) {
        var sumSq = 0.0
        var sumAbs = 0.0
        var maxErr = 0
        var total = 0
        for c in 0..<ref.count {
            for i in 0..<ref[c].count {
                let diff = abs(ref[c][i] - rec[c][i])
                if diff > maxErr { maxErr = diff }
                sumAbs += Double(diff)
                sumSq += Double(diff * diff)
                total += 1
            }
        }
        let mse = sumSq / Double(max(1, total))
        let mae = sumAbs / Double(max(1, total))
        let peak = Double((1 << bitDepth) - 1)
        let psnr = mse == 0 ? 999.0 : 10.0 * log10((peak * peak) / mse)
        return (mae, maxErr, psnr)
    }

    private static func containsMarker(_ bytes: [UInt8], _ marker: UInt16) -> Bool {
        let hi = UInt8((marker >> 8) & 0xFF)
        let lo = UInt8(marker & 0xFF)
        guard bytes.count >= 2 else { return false }
        for i in 0..<(bytes.count - 1) {
            if bytes[i] == hi && bytes[i + 1] == lo { return true }
        }
        return false
    }

    // MARK: - 1. Part 2 Reversible MCT Round-Trip, Containers, SERM, Multi-Segment, and Tile Overrides

    /// Part 2 reversible MCT round-trip across 1/3/4 components, signed/unsigned, containers, SERM, and tile overrides.
    @Test
    func part2ReversibleMCTRoundTripAndCustomStages() async throws {
        let decoder = try Decoder()

        for (comps, bits, signed, blockCoding) in [
            (1, 12, false, CodecOptions.BlockCoding.part1),
            (3, 8, false, CodecOptions.BlockCoding.part1),
            (3, 12, true, CodecOptions.BlockCoding.htj2k),
            (4, 16, false, CodecOptions.BlockCoding.part1),
            (4, 12, true, CodecOptions.BlockCoding.htj2k)
        ] {
            let (img, refPlanes) = try Self.makePlanarImage(
                width: 32, height: 24, componentCount: comps, meaningfulBits: bits, signed: signed
            )
            let opts = try CodecOptions(
                decompositionLevels: 2,
                blockCoding: blockCoding,
                multiComponentTransform: .part2
            )
            let cfg = try EncoderConfiguration(mode: .lossless, codecOptions: opts)
            let encoded = try await Encoder(configuration: cfg).encode(img)
            #expect(encoded.report.fidelity == .exactSamples)

            let csBytes = [UInt8](encoded.data)
            #expect(Self.containsMarker(csBytes, Marker.cbd))
            #expect(Self.containsMarker(csBytes, Marker.mct))
            #expect(Self.containsMarker(csBytes, Marker.mcc))
            #expect(Self.containsMarker(csBytes, Marker.mco))

            let info = try decoder.inspect(encoded.data)
            #expect(info.descriptor.components.count == comps)
            #expect(info.descriptor.meaningfulBits == bits)
            #expect((info.descriptor.sampleType == .signedInteger) == signed)

            let decoded = try await decoder.decode(encoded.data)
            #expect(decoded.report.fidelity == .exactSamples)
            let gotPlanes = try Self.extractPlanes(decoded.image)
            #expect(gotPlanes == refPlanes, "Reversible Part 2 MCT mismatch for comps=\(comps) bits=\(bits) signed=\(signed) coding=\(blockCoding)")
        }

        // Container round-trip (.jpx for Part 1 & HTJ2K, .jph for HTJ2K) and .jp2 rejection
        #expect(throws: CodecError.self) {
            _ = try CodecOptions(containerFormat: .jp2, multiComponentTransform: .part2)
        }
        let (rgbImg, rgbPlanes) = try Self.makePlanarImage(
            width: 24, height: 16, componentCount: 3, meaningfulBits: 8, signed: false
        )
        for (containerFmt, coding) in [
            (CodecOptions.ContainerFormat.jpx, CodecOptions.BlockCoding.part1),
            (CodecOptions.ContainerFormat.jpx, CodecOptions.BlockCoding.htj2k),
            (CodecOptions.ContainerFormat.jph, CodecOptions.BlockCoding.htj2k)
        ] {
            let cfg = try EncoderConfiguration(
                mode: .lossless,
                codecOptions: CodecOptions(
                    decompositionLevels: 2,
                    blockCoding: coding,
                    containerFormat: containerFmt,
                    multiComponentTransform: .part2
                )
            )
            let enc = try await Encoder(configuration: cfg).encode(rgbImg)
            let info = try decoder.inspect(enc.data)
            #expect(info.descriptor.components.count == 3)
            #expect(info.descriptor.meaningfulBits == 8)
            let dec = try await decoder.decode(enc.data)
            #expect(try Self.extractPlanes(dec.image) == rgbPlanes)
        }

        // Custom synthetic codestream with SERM (Xmcc=1, reversible=true), multi-segment MCT (Zmct=0,1,2),
        // wire SIZ components (2) != logical CBD components (3),
        // and tile-part 0 MCC+MCO override on tile 1!
        let (twoCompWireImg, wirePlanes) = try Self.makePlanarImage(
            width: 16, height: 8, componentCount: 2, meaningfulBits: 9, signed: true
        )
        let baseCodestream = [UInt8](try await Encoder(
            configuration: EncoderConfiguration(
                mode: .lossless,
                codecOptions: CodecOptions(decompositionLevels: 1, tileWidth: 8, tileHeight: 8)
            )
        ).encode(twoCompWireImg).data)
        let parsedBase = try CodestreamSyntax.parse(baseCodestream, limits: .default)
        #expect(parsedBase.tileParts.count == 2)

        // SERM for M=2 has M+1 = 3 rows (6 Int32 elements = 24 bytes, split into 3 MCT fragments at maxPayloadBytesPerSegment=8):
        // step 0 (target=1): [-1, 1] -> vec[1] -= (-vec[0]) = vec[1] + vec[0]
        // step 1 (target=0): [ 1, 0] -> vec[0] -= 0
        // step 2 (target=1): [ 0, 1] -> vec[1] -= 0
        let mctSERM = Part2MCTTable(
            tableIndex: 1,
            arrayType: .decorrelation,
            elementType: .int32,
            integerValues: [-1, 1, 1, 0, 0, 1],
            floatValues: []
        )
        let mctOff2 = Part2MCTTable(
            tableIndex: 2,
            arrayType: .offset,
            elementType: .int32,
            integerValues: [128, 128],
            floatValues: []
        )
        let mctOff3 = Part2MCTTable(
            tableIndex: 3,
            arrayType: .offset,
            elementType: .int32,
            integerValues: [128, 128, 0],
            floatValues: []
        )
        let mccStage1 = Part2MCCStage(
            stageIndex: 1,
            collections: [
                // Collection 0: SERM on wire [0, 1] -> logical [0, 1] + offset +128
                Part2MCCCollection(
                    decorrelationType: .matrix,
                    inputComponents: [0, 1],
                    outputComponents: [0, 1],
                    reversible: true,
                    offsetTableIndex: 2,
                    transformTableIndex: 1
                ),
                // Collection 1: null transform copying wire [0] -> logical [2] (clamped to 0...255 at CBD output)
                Part2MCCCollection(
                    decorrelationType: .dependency,
                    inputComponents: [0],
                    outputComponents: [2],
                    reversible: true,
                    offsetTableIndex: 0,
                    transformTableIndex: 0
                )
            ]
        )
        // For tile 1, override with single null-transform stage 2 expanding wire [0, 1] -> logical [0, 1, 2] (zero-filling [2]!)
        let mccStage2 = Part2MCCStage(
            stageIndex: 2,
            collections: [
                Part2MCCCollection(
                    decorrelationType: .dependency,
                    inputComponents: [0, 1],
                    outputComponents: [0, 1, 2],
                    reversible: true,
                    offsetTableIndex: 3,
                    transformTableIndex: 0
                )
            ]
        )
        let cbd = try ComponentBitDepthSegment(components: [
            .init(signed: false, precision: 8),
            .init(signed: false, precision: 8),
            .init(signed: false, precision: 8)
        ])

        // Rebuild codestream with Rsiz=0x8002, CBD, 3-fragment MCT, MCC stage 1, main MCO=[1], and tile 1 MCC stage 2 + MCO=[2]
        var customWriter = ByteWriter()
        customWriter.writeUInt16(Marker.soc)
        var modSize = parsedBase.size
        modSize = ImageSizeSegment(
            capabilities: 0x8002,
            width: modSize.width, height: modSize.height,
            originX: modSize.originX, originY: modSize.originY,
            tileWidth: modSize.tileWidth, tileHeight: modSize.tileHeight,
            tileOriginX: modSize.tileOriginX, tileOriginY: modSize.tileOriginY,
            components: modSize.components
        )
        try CodestreamSyntax.writeSIZ(modSize, into: &customWriter)
        try CodestreamSyntax.writeCBD(cbd, into: &customWriter)
        try CodestreamSyntax.writeMCT(mctSERM, maxPayloadBytesPerSegment: 8, into: &customWriter)
        try CodestreamSyntax.writeMCT(mctOff2, into: &customWriter)
        try CodestreamSyntax.writeMCT(mctOff3, into: &customWriter)
        try CodestreamSyntax.writeMCC(mccStage1, into: &customWriter)
        try CodestreamSyntax.writeMCO(Part2MCOSegment(stageIndices: [1]), into: &customWriter)
        try CodestreamSyntax.writeCOD(parsedBase.codingStyle, into: &customWriter)
        try CodestreamSyntax.writeQCD(parsedBase.quantization, into: &customWriter)

        for tilePart in parsedBase.tileParts {
            let tIdx = tilePart.tileIndex
            let bodyBytes = Array(baseCodestream[tilePart.dataRange])
            var tileHeaderExtra = ByteWriter()
            if tIdx == 1 {
                try CodestreamSyntax.writeMCC(mccStage2, into: &tileHeaderExtra)
                try CodestreamSyntax.writeMCO(Part2MCOSegment(stageIndices: [2]), into: &tileHeaderExtra)
            }
            let psot = 12 + tileHeaderExtra.bytes.count + 2 + bodyBytes.count
            customWriter.writeUInt16(Marker.sot)
            customWriter.writeUInt16(10)
            customWriter.writeUInt16(UInt16(tIdx))
            customWriter.writeUInt32(UInt32(psot))
            customWriter.writeUInt8(0)
            customWriter.writeUInt8(1)
            customWriter.writeBytes(tileHeaderExtra.bytes)
            customWriter.writeUInt16(Marker.sod)
            customWriter.writeBytes(bodyBytes)
        }
        customWriter.writeUInt16(Marker.eoc)

        let customDecoded = try await decoder.decode(Data(customWriter.bytes))
        #expect(customDecoded.image.descriptor.components.count == 3)
        #expect(customDecoded.image.descriptor.meaningfulBits == 8)
        #expect(customDecoded.image.descriptor.sampleType == .unsignedInteger)
        let customPlanes = try Self.extractPlanes(customDecoded.image)
        for y in 0..<8 {
            for x in 0..<16 {
                let w0 = wirePlanes[0][y * 16 + x]
                let w1 = wirePlanes[1][y * 16 + x]
                let exp0 = min(max(w0 + 128, 0), 255)
                // Tile 0 (x < 8) uses SERM -> y1 = w0 + w1 + 128, y2 = clamp(w0, 0...255);
                // Tile 1 (x >= 8) uses null-transform override -> y1 = w1 + 128, y2 = 0
                let exp1 = x < 8 ? min(max(w0 + w1 + 128, 0), 255) : min(max(w1 + 128, 0), 255)
                let exp2 = x < 8 ? min(max(w0, 0), 255) : 0
                #expect(customPlanes[0][y * 16 + x] == exp0)
                #expect(customPlanes[1][y * 16 + x] == exp1)
                #expect(customPlanes[2][y * 16 + x] == exp2)
            }
        }
    }

    // MARK: - 2. Part 2 Irreversible MCT & Fail-Closed Security Rejection

    /// Part 2 irreversible MCT round-trip and fail-closed rejection of unsupported or malformed Part 2 markers.
    @Test
    func part2IrreversibleMCTAndFailClosedSecurityRejection() async throws {
        let decoder = try Decoder()

        for (comps, bits, signed, blockCoding) in [
            (1, 12, false, CodecOptions.BlockCoding.part1),
            (3, 8, false, CodecOptions.BlockCoding.part1),
            (3, 8, false, CodecOptions.BlockCoding.htj2k),
            (4, 12, true, CodecOptions.BlockCoding.part1),
            (4, 16, false, CodecOptions.BlockCoding.htj2k)
        ] {
            let (img, refPlanes) = try Self.makePlanarImage(
                width: 48, height: 32, componentCount: comps, meaningfulBits: bits, signed: signed
            )
            let cfg = try EncoderConfiguration(
                mode: .lossy,
                codecOptions: CodecOptions(
                    decompositionLevels: 3,
                    blockCoding: blockCoding,
                    quality: 0.92,
                    multiComponentTransform: .part2
                )
            )
            let enc = try await Encoder(configuration: cfg).encode(img)
            #expect(enc.report.fidelity == .lossy)
            let dec = try await decoder.decode(enc.data)
            #expect(dec.report.fidelity == .lossy)
            let metrics = Self.computePSNR(refPlanes, try Self.extractPlanes(dec.image), bitDepth: bits)
            #expect(metrics.psnr >= 32.0, "Low PSNR (\(metrics.psnr) dB) for lossy Part 2 MCT comps=\(comps) bits=\(bits) coding=\(blockCoding)")
        }

        // Baseline valid Part 2 codestream for fail-closed mutation tests
        let (baseImg, _) = try Self.makePlanarImage(width: 16, height: 16, componentCount: 3, meaningfulBits: 8, signed: false)
        let validPart2 = [UInt8](try await Encoder(
            configuration: EncoderConfiguration(
                mode: .lossless,
                codecOptions: CodecOptions(decompositionLevels: 1, multiComponentTransform: .part2)
            )
        ).encode(baseImg).data)
        let parsedValid = try CodestreamSyntax.parse(validPart2, limits: .default)

        // Helper to inject a raw marker segment right after SIZ (SOC=2 bytes, SIZ=2+2+38+3*3=51 bytes -> offset 53)
        let afterSIZ = 2 + 2 + 38 + parsedValid.size.components.count * 3
        func injectAfterSIZ(marker: UInt16, payload: [UInt8]) -> Data {
            var out = Array(validPart2[0..<afterSIZ])
            let segLen = UInt16(payload.count + 2)
            out.append(UInt8((marker >> 8) & 0xFF))
            out.append(UInt8(marker & 0xFF))
            out.append(UInt8((segLen >> 8) & 0xFF))
            out.append(UInt8(segLen & 0xFF))
            out.append(contentsOf: payload)
            out.append(contentsOf: validPart2[afterSIZ...])
            return Data(out)
        }

        // 1. Unsupported Part 2 extensions: DCO, VMS, DFS, ADS, NLT, ATK -> .unsupportedFeature
        for unsupportedMarker: UInt16 in [0xFF70, 0xFF71, 0xFF72, 0xFF73, 0xFF76, 0xFF79] {
            let mutated = injectAfterSIZ(marker: unsupportedMarker, payload: [0x00, 0x00])
            do {
                _ = try decoder.inspect(mutated)
                Issue.record("Unsupported Part 2 marker 0x\(String(unsupportedMarker, radix: 16)) was accepted")
            } catch let error as CodecError {
                #expect(error.category == .unsupportedFeature)
            }
        }

        // 2. Wavelet-based MCC (Xmcc = 2 and Xmcc = 3) -> .unsupportedFeature
        for waveletXmcc: UInt8 in [2, 3] {
            let mccPayload: [UInt8] = [
                0x00, 0x00, // Zmcc = 0
                0x09,       // Imcc = 9
                0x00, 0x00, // Ymcc = 0
                0x00, 0x01, // Qmcc = 1
                waveletXmcc,
                0x00, 0x01, 0x00, // Nmcci = 1, input 0
                0x00, 0x01, 0x00, // Mmcci = 1, output 0
                0x00, 0x00, 0x00
            ]
            let mutated = injectAfterSIZ(marker: Marker.mcc, payload: mccPayload)
            do {
                _ = try decoder.inspect(mutated)
                Issue.record("Wavelet MCC Xmcc=\(waveletXmcc) was accepted")
            } catch let error as CodecError {
                #expect(error.category == .unsupportedFeature)
            }
        }

        // 3. Duplicate MCC stage definition in same header AND duplicate output component inside an MCC stage -> .malformedInput
        let uniformCBD = try ComponentBitDepthSegment(components: Array(repeating: .init(signed: false, precision: 8), count: 3))
        #expect(try ComponentBitDepthSegment.parse(uniformCBD.serialiseBody(preferUniform: true)) == uniformCBD)
        #expect(try ComponentBitDepthSegment.parse(uniformCBD.serialiseBody(preferUniform: false)) == uniformCBD)

        let dupMCCPayload: [UInt8] = [
            0x00, 0x00, // Zmcc = 0
            0x01,       // Imcc = 1 (duplicate stage 1 in same header)
            0x00, 0x00, // Ymcc = 0
            0x00, 0x02, // Qmcc = 2 collections writing same output component 0!
            0x00, 0x00, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00,
            0x00, 0x00, 0x01, 0x01, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00
        ]
        do {
            _ = try decoder.inspect(injectAfterSIZ(marker: Marker.mcc, payload: dupMCCPayload))
            Issue.record("Duplicate MCC stage in same header was accepted")
        } catch let error as CodecError {
            #expect(error.category == .malformedInput)
        }

        var dupOutPayload = dupMCCPayload
        dupOutPayload[2] = 0x02 // distinct stage Imcc = 2 with duplicate output component 0
        do {
            _ = try decoder.inspect(injectAfterSIZ(marker: Marker.mcc, payload: dupOutPayload))
            Issue.record("Duplicate output component in MCC stage 2 was accepted")
        } catch let error as CodecError {
            #expect(error.category == .malformedInput)
        }

        // 4. MCO referencing non-existent MCC stage 99 -> .malformedInput
        do {
            _ = try decoder.inspect(injectAfterSIZ(marker: Marker.mco, payload: [0x01, 99]))
            Issue.record("MCO referencing missing MCC stage 99 was accepted")
        } catch let error as CodecError {
            #expect(error.category == .malformedInput)
        }

        // 5. Truncated CBD, MCT, MCC, MCO segments -> .malformedInput
        for (marker, badPayload) in [
            (Marker.cbd, [UInt8]([0x00])),
            (Marker.mct, [UInt8]([0x00, 0x00, 0x00])),
            (Marker.mcc, [UInt8]([0x00, 0x00, 0x01])),
            (Marker.mco, [UInt8]([0x03, 0x01]))
        ] {
            do {
                _ = try decoder.inspect(injectAfterSIZ(marker: marker, payload: badPayload))
                Issue.record("Truncated marker 0x\(String(marker, radix: 16)) was accepted")
            } catch let error as CodecError {
                #expect(error.category == .malformedInput)
            }
        }

        // 6. Tight ResourceLimits rejects Part 2 MCT payload exceeding workspace budget -> .resourceLimitExceeded
        let tightLimits = try ResourceLimits(
            maximumCompressedBytes: 64 * 1024,
            maximumWorkspaceBytes: 16,
            maximumMemoryBytes: 64 * 1024
        )
        do {
            _ = try decoder.inspect(Data(validPart2), options: DecodeOptions(resourceLimits: tightLimits))
            Issue.record("Tight workspace budget did not reject Part 2 MCT table allocation")
        } catch let error as CodecError {
            #expect(error.category == .resourceLimitExceeded)
        }
    }

    // MARK: - 3. Lossy 9/7 HTJ2K (HTIRV) Round-Trip, Markers, Rate Control & Quality Layers

    /// Lossy 9/7 HTJ2K (HTIRV) round-trip across bit depths, signedness, PCRD rate control, layers, and containers.
    @Test
    func lossyHTIRVRoundTripQuantizationAndMarkers() async throws {
        let decoder = try Decoder()

        for (comps, bits, signed) in [
            (1, 8, false),
            (1, 12, false),
            (1, 16, true),
            (3, 8, false),
            (3, 12, false)
        ] {
            let (img, refPlanes) = try Self.makePlanarImage(
                width: 64, height: 48, componentCount: comps, meaningfulBits: bits, signed: signed
            )
            let cfg = try EncoderConfiguration(
                mode: .lossy,
                codecOptions: CodecOptions(
                    decompositionLevels: 3,
                    blockCoding: .htj2k,
                    quality: 0.90
                )
            )
            let enc = try await Encoder(configuration: cfg).encode(img)
            #expect(enc.encoding.format == "htj2k-codestream")
            #expect(enc.report.fidelity == .lossy)

            let parsed = try CodestreamSyntax.parse([UInt8](enc.data), limits: .default)
            let cap = try #require(parsed.extendedCapabilities)
            #expect(cap.mode == .htOnly)
            #expect(cap.irreversible)
            let cpf = try #require(parsed.correspondingProfile)
            #expect(cpf.values == [0x0002])

            let dec = try await decoder.decode(enc.data)
            #expect(dec.report.fidelity == .lossy)
            let metrics = Self.computePSNR(refPlanes, try Self.extractPlanes(dec.image), bitDepth: bits)
            #expect(metrics.psnr >= 33.0, "Unexpectedly low HTIRV PSNR \(metrics.psnr) dB for comps=\(comps) bits=\(bits) signed=\(signed)")
        }

        // Monotonicity across quality & targetBitsPerPixel + multi-layer progressive decode + JPH/JPX containers
        let (rgbImg, rgbPlanes) = try Self.makePlanarImage(
            width: 64, height: 64, componentCount: 3, meaningfulBits: 8, signed: false
        )
        var qualitySizes: [Int] = []
        var qualityPSNRs: [Double] = []
        for q in [0.30, 0.70, 0.95] {
            let enc = try await Encoder(
                configuration: EncoderConfiguration(
                    mode: .lossy,
                    codecOptions: CodecOptions(decompositionLevels: 3, blockCoding: .htj2k, quality: q)
                )
            ).encode(rgbImg)
            let dec = try await decoder.decode(enc.data)
            let m = Self.computePSNR(rgbPlanes, try Self.extractPlanes(dec.image), bitDepth: 8)
            qualitySizes.append(enc.data.count)
            qualityPSNRs.append(m.psnr)
        }
        #expect(qualitySizes[0] < qualitySizes[2])
        #expect(qualityPSNRs[0] < qualityPSNRs[2])

        var bppSizes: [Int] = []
        for bpp in [0.75, 3.0] {
            let enc = try await Encoder(
                configuration: EncoderConfiguration(
                    mode: .lossy,
                    codecOptions: CodecOptions(decompositionLevels: 3, blockCoding: .htj2k, targetBitsPerPixel: bpp)
                )
            ).encode(rgbImg)
            bppSizes.append(enc.data.count)
        }
        #expect(bppSizes[0] < bppSizes[1])

        // Multi-layer HTIRV + JPH and JPX containers + near-lossless HTJ2K
        let layeredHT = try await Encoder(
            configuration: EncoderConfiguration(
                mode: .lossy,
                codecOptions: CodecOptions(
                    decompositionLevels: 3,
                    blockCoding: .htj2k,
                    quality: 0.92,
                    qualityLayers: 3,
                    tileWidth: 32,
                    tileHeight: 32,
                    containerFormat: .jph
                )
            )
        ).encode(rgbImg)
        #expect(layeredHT.encoding.format == "jph")
        let decFull = try await decoder.decode(layeredHT.data)
        #expect(Self.computePSNR(rgbPlanes, try Self.extractPlanes(decFull.image), bitDepth: 8).psnr >= 32.0)

        let nearLosslessHT = try await Encoder(
            configuration: EncoderConfiguration(
                mode: .nearLossless(maximumAbsoluteError: 2),
                codecOptions: CodecOptions(decompositionLevels: 2, blockCoding: .htj2k, containerFormat: .jpx)
            )
        ).encode(rgbImg)
        #expect(nearLosslessHT.report.fidelity == .boundedError(2))
        let nearDec = try await decoder.decode(nearLosslessHT.data)
        let nearMetrics = Self.computePSNR(rgbPlanes, try Self.extractPlanes(nearDec.image), bitDepth: 8)
        #expect(nearMetrics.maxErr <= 4)
    }

    // MARK: - 4. Concrete Acceleration Engine Provenance (CPU SIMD vs Metal GPU) & Deterministic Fallbacks

    /// Concrete AcceleratedEngine provenance distinguishes scalar, CPU SIMD, and Metal GPU with deterministic fallbacks.
    @Test
    func concreteAccelerationEngineProvenanceAndFallbacks() async throws {
        #expect(CodecCapabilities.isSIMDAvailable == Encoder.capabilities.isSIMDAvailable)
        #expect(CodecCapabilities.isMetalAvailable == Encoder.capabilities.isMetalAvailable)

        let (rgbImg, rgbPlanes) = try Self.makePlanarImage(
            width: 32, height: 32, componentCount: 3, meaningfulBits: 8, signed: false
        )
        let part2Cfg = try EncoderConfiguration(
            mode: .lossless,
            codecOptions: CodecOptions(decompositionLevels: 2, blockCoding: .htj2k, multiComponentTransform: .part2)
        )
        let htirvCfg = try EncoderConfiguration(
            mode: .lossy,
            codecOptions: CodecOptions(decompositionLevels: 2, blockCoding: .htj2k, quality: 0.90)
        )
        let decoder = try Decoder()

        // 1. Scalar execution -> .scalarCPU + .none
        let scalarEnc = try await Encoder(configuration: part2Cfg).encode(
            rgbImg, options: EncodeOptions(executionPolicy: .scalarCPU)
        )
        #expect(scalarEnc.report.backend == .scalarCPU)
        #expect(scalarEnc.report.acceleratedEngine == .none)

        let scalarDec = try await decoder.decode(
            scalarEnc.data, options: DecodeOptions(executionPolicy: .scalarCPU)
        )
        #expect(scalarDec.report.backend == .scalarCPU)
        #expect(scalarDec.report.acceleratedEngine == .none)
        #expect(try Self.extractPlanes(scalarDec.image) == rgbPlanes)

        // 2. Explicit CPU SIMD preference -> .accelerated + .cpuSIMD
        if CodecCapabilities.isSIMDAvailable {
            let simdEnc = try await Encoder(configuration: part2Cfg).encode(
                rgbImg,
                options: EncodeOptions(
                    executionPolicy: .preferred(.accelerated),
                    acceleratedEnginePreference: .cpuSIMD
                )
            )
            #expect(simdEnc.report.backend == .accelerated)
            #expect(simdEnc.report.acceleratedEngine == .cpuSIMD)

            let simdDec = try await decoder.decode(
                simdEnc.data,
                options: DecodeOptions(
                    executionPolicy: .preferred(.accelerated),
                    acceleratedEnginePreference: .cpuSIMD
                )
            )
            #expect(simdDec.report.backend == .accelerated)
            #expect(simdDec.report.acceleratedEngine == .cpuSIMD)
            #expect(try Self.extractPlanes(simdDec.image) == rgbPlanes)
        }

        // 3. Explicit Metal GPU preference -> .accelerated + .metalGPU when Metal is available
        if CodecCapabilities.isMetalAvailable {
            let metalPart2Enc = try await Encoder(configuration: part2Cfg).encode(
                rgbImg,
                options: EncodeOptions(
                    executionPolicy: .required(.accelerated),
                    acceleratedEnginePreference: .metalGPU
                )
            )
            #expect(metalPart2Enc.report.backend == .accelerated)
            #expect(metalPart2Enc.report.acceleratedEngine == .metalGPU)

            let metalPart2Dec = try await decoder.decode(
                metalPart2Enc.data,
                options: DecodeOptions(
                    executionPolicy: .required(.accelerated),
                    acceleratedEnginePreference: .metalGPU
                )
            )
            #expect(metalPart2Dec.report.backend == .accelerated)
            #expect(metalPart2Dec.report.acceleratedEngine == .metalGPU)
            #expect(try Self.extractPlanes(metalPart2Dec.image) == rgbPlanes)

            let metalHTIRVEnc = try await Encoder(configuration: htirvCfg).encode(
                rgbImg,
                options: EncodeOptions(
                    executionPolicy: .required(.accelerated),
                    acceleratedEnginePreference: .metalGPU
                )
            )
            #expect(metalHTIRVEnc.report.backend == .accelerated)
            #expect(metalHTIRVEnc.report.acceleratedEngine == .metalGPU)

            let metalHTIRVDec = try await decoder.decode(
                metalHTIRVEnc.data,
                options: DecodeOptions(
                    executionPolicy: .required(.accelerated),
                    acceleratedEnginePreference: .metalGPU
                )
            )
            #expect(metalHTIRVDec.report.backend == .accelerated)
            #expect(metalHTIRVDec.report.acceleratedEngine == .metalGPU)

            // 0-level lossless greyscale16 exercises LosslessPipeline Metal dispatch as well
            let (grey16, greyPlanes) = try Self.makePlanarImage(
                width: 16, height: 16, componentCount: 1, meaningfulBits: 12, signed: false
            )
            let zeroLvlEnc = try await Encoder(
                configuration: EncoderConfiguration(
                    mode: .lossless,
                    codecOptions: CodecOptions(decompositionLevels: 0, blockCoding: .htj2k)
                )
            ).encode(
                grey16,
                options: EncodeOptions(
                    executionPolicy: .required(.accelerated),
                    acceleratedEnginePreference: .metalGPU
                )
            )
            #expect(zeroLvlEnc.report.acceleratedEngine == .metalGPU)
            let zeroLvlDec = try await decoder.decode(
                zeroLvlEnc.data,
                options: DecodeOptions(
                    executionPolicy: .required(.accelerated),
                    acceleratedEnginePreference: .metalGPU
                )
            )
            #expect(zeroLvlDec.report.acceleratedEngine == .metalGPU)
            #expect(try Self.extractPlanes(zeroLvlDec.image) == greyPlanes)
        }

        // 4. Simulated Metal-unavailable fallback (.preferred -> .cpuSIMD with fallbackReason, .required -> .backendUnavailable)
        try AccelerationRuntime.withSimulatedMetalUnavailable {
            #expect(!CodecCapabilities.isMetalAvailable)
            if CodecCapabilities.isSIMDAvailable {
                let resolved = try AccelerationRuntime.resolve(
                    .preferred(.accelerated),
                    enginePreference: .metalGPU
                )
                #expect(resolved.backend == .accelerated)
                #expect(resolved.engineMode == .cpuSIMD)
                #expect(resolved.fallbackReason != nil)
            }
            do {
                _ = try AccelerationRuntime.resolve(
                    .required(.accelerated),
                    enginePreference: .metalGPU
                )
                Issue.record("required(.accelerated) with .metalGPU succeeded when Metal was unavailable")
            } catch let error as CodecError {
                #expect(error.category == .backendUnavailable)
            }
        }
    }

    // MARK: - 5. Zero-Pixel-Allocation Wavelet-Domain Transcoding Across Signed, RGB, Part 2 MCT & RPCL

    /// Zero-pixel-allocation Transcoder preserves exact samples across signed, RGB, Part 2 reversible MCT, and RPCL.
    @Test
    func losslessTranscoderZeroPixelAllocationMultiComponentSignedAndPart2() async throws {
        let decoder = try Decoder()
        let defaultTranscoder = try Transcoder()

        // 1. Signed 12-bit & 16-bit single-component J2K <-> HTJ2K
        for bits in [12, 16] {
            let (signedImg, refPlanes) = try Self.makePlanarImage(
                width: 32, height: 24, componentCount: 1, meaningfulBits: bits, signed: true
            )
            let j2k = try await Encoder().encode(signedImg)
            let toHT = try await defaultTranscoder.transcode(j2k.data, to: .htj2k)
            #expect(toHT.report.pixelAllocationCount == 0)
            #expect(toHT.report.peakPixelBytes == 0)
            #expect(toHT.encoding.format == "htj2k-codestream")
            #expect(try Self.extractPlanes(try await decoder.decode(toHT.data).image) == refPlanes)

            let backToJ2K = try await defaultTranscoder.transcode(toHT.data, to: .jpeg2000)
            #expect(backToJ2K.report.pixelAllocationCount == 0)
            #expect(backToJ2K.report.peakPixelBytes == 0)
            #expect(backToJ2K.encoding.format == "jpeg2000-codestream")
            #expect(try Self.extractPlanes(try await decoder.decode(backToJ2K.data).image) == refPlanes)
        }

        // 2. 3-component RGB (8-bit and 16-bit RCT) + RPCL + precincts + re-blocking (64x64 -> 32x32)
        for bits in [8, 16] {
            let (rgbImg, refPlanes) = try Self.makePlanarImage(
                width: 48, height: 32, componentCount: 3, meaningfulBits: bits, signed: false
            )
            let j2k = try await Encoder(
                configuration: EncoderConfiguration(
                    mode: .lossless,
                    codecOptions: CodecOptions(decompositionLevels: 2, tileWidth: 24, tileHeight: 16)
                )
            ).encode(rgbImg)

            let rpclTranscoder = try Transcoder(
                configuration: TranscoderConfiguration(
                    mode: .lossless,
                    codecOptions: CodecOptions(
                        codeBlockWidth: 32,
                        codeBlockHeight: 32,
                        blockCoding: .htj2k,
                        progressionOrder: .rpcl,
                        precinctSizes: [CodecOptions.PrecinctSize(width: 64, height: 64)],
                        usesSOP: true,
                        usesEPH: true
                    )
                )
            )
            let toHT = try await rpclTranscoder.transcode(j2k.data, to: .htj2k)
            #expect(toHT.report.pixelAllocationCount == 0)
            #expect(toHT.report.peakPixelBytes == 0)
            let parsedHT = try CodestreamSyntax.parse([UInt8](toHT.data), limits: .default)
            #expect(parsedHT.codingStyle.progression == CodecOptions.ProgressionOrder.rpcl.rawValue)
            #expect(parsedHT.codingStyle.usesPrecincts)
            #expect(try Self.extractPlanes(try await decoder.decode(toHT.data).image) == refPlanes)

            let backJ2K = try await defaultTranscoder.transcode(toHT.data, to: .jpeg2000)
            #expect(backJ2K.report.pixelAllocationCount == 0)
            #expect(try Self.extractPlanes(try await decoder.decode(backJ2K.data).image) == refPlanes)
        }

        // 3. Part 2 reversible MCT (4-component codestream and 3-component .jpx <-> .jph containers)
        let (part2Img, part2Planes) = try Self.makePlanarImage(
            width: 24, height: 24, componentCount: 4, meaningfulBits: 12, signed: true
        )
        let part2J2K = try await Encoder(
            configuration: EncoderConfiguration(
                mode: .lossless,
                codecOptions: CodecOptions(decompositionLevels: 2, multiComponentTransform: .part2)
            )
        ).encode(part2Img)

        let part2HT = try await defaultTranscoder.transcode(part2J2K.data, to: .htj2k)
        #expect(part2HT.report.pixelAllocationCount == 0)
        #expect(Self.containsMarker([UInt8](part2HT.data), Marker.cbd))
        #expect(Self.containsMarker([UInt8](part2HT.data), Marker.mco))
        #expect(try Self.extractPlanes(try await decoder.decode(part2HT.data).image) == part2Planes)

        let part2Back = try await defaultTranscoder.transcode(part2HT.data, to: .jpeg2000)
        #expect(part2Back.report.pixelAllocationCount == 0)
        #expect(try Self.extractPlanes(try await decoder.decode(part2Back.data).image) == part2Planes)

        let (rgbPart2Img, rgbPart2Planes) = try Self.makePlanarImage(
            width: 24, height: 16, componentCount: 3, meaningfulBits: 8, signed: false
        )
        let jpxPart2 = try await Encoder(
            configuration: EncoderConfiguration(
                mode: .lossless,
                codecOptions: CodecOptions(
                    decompositionLevels: 2,
                    blockCoding: .part1,
                    containerFormat: .jpx,
                    multiComponentTransform: .part2
                )
            )
        ).encode(rgbPart2Img)
        let jphTranscoder = try Transcoder(
            configuration: TranscoderConfiguration(
                mode: .lossless,
                codecOptions: CodecOptions(blockCoding: .htj2k, containerFormat: .jph)
            )
        )
        let jphPart2 = try await jphTranscoder.transcode(jpxPart2.data, to: .htj2k)
        #expect(jphPart2.report.pixelAllocationCount == 0)
        #expect(jphPart2.encoding.format == "jph")
        #expect(try Self.extractPlanes(try await decoder.decode(jphPart2.data).image) == rgbPart2Planes)
    }

    // MARK: - 6. CLI Options & Bidirectional External Reference Verification (Kakadu, OpenJPEG, OpenJPH)

    #if os(macOS) || os(Linux)
    private static func findTool(_ candidates: [String]) -> String? {
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func runExternal(_ executable: String, _ args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let errPipe = Pipe()
        let outPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = outPipe
        try proc.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let msg = String(data: outData + errData, encoding: .utf8) ?? ""
            throw CodecError(.internalFailure, "External tool \(executable) exited \(proc.terminationStatus): \(msg)")
        }
    }

    private static func writePPM(path: URL, width: Int, height: Int, planes: [[Int]]) throws {
        var bytes = Array("P6\n\(width) \(height)\n255\n".utf8)
        bytes.reserveCapacity(bytes.count + width * height * 3)
        for i in 0..<(width * height) {
            bytes.append(UInt8(planes[0][i]))
            bytes.append(UInt8(planes[1][i]))
            bytes.append(UInt8(planes[2][i]))
        }
        try Data(bytes).write(to: path)
    }

    private static func readPNM8Or16(path: URL) throws -> (width: Int, height: Int, comps: Int, maxval: Int, planes: [[Int]]) {
        let data = try Data(contentsOf: path)
        let bytes = [UInt8](data)
        var pos = 0
        func nextToken() -> String {
            while pos < bytes.count {
                let b = bytes[pos]
                if b == 0x23 { // '#'
                    while pos < bytes.count && bytes[pos] != 0x0A { pos += 1 }
                } else if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                    pos += 1
                } else {
                    break
                }
            }
            let start = pos
            while pos < bytes.count {
                let b = bytes[pos]
                if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x23 { break }
                pos += 1
            }
            return String(decoding: bytes[start..<pos], as: UTF8.self)
        }
        let magic = nextToken()
        let comps = (magic == "P6") ? 3 : 1
        let w = Int(nextToken()) ?? 0
        let h = Int(nextToken()) ?? 0
        let maxval = Int(nextToken()) ?? 255
        pos += 1 // single whitespace byte after maxval
        var planes = (0..<comps).map { _ in [Int](repeating: 0, count: w * h) }
        if maxval <= 255 {
            for i in 0..<(w * h) {
                for c in 0..<comps {
                    planes[c][i] = Int(bytes[pos])
                    pos += 1
                }
            }
        } else {
            for i in 0..<(w * h) {
                for c in 0..<comps {
                    let v = (Int(bytes[pos]) << 8) | Int(bytes[pos + 1])
                    planes[c][i] = v
                    pos += 2
                }
            }
        }
        return (w, h, comps, maxval, planes)
    }

    /// CLI Part 2 / HTIRV / engine flags and bidirectional Kakadu, OpenJPEG, and OpenJPH verification.
    @Test
    func cliAndBidirectionalExternalOracleVerification() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swiftj2k-phase-a-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. CLI capabilities --json & --mct part2 & --engine simd/metal & --output-format htj2k --mode lossy
        let capRes = try await CLITestProcess.run(["capabilities", "--json"])
        #expect(capRes.status == 0, "\(capRes.stderrText)")
        let capJSON = try #require(JSONSerialization.jsonObject(with: capRes.stdout) as? [String: Any])
        #expect(capJSON["isSIMDAvailable"] as? Bool == CodecCapabilities.isSIMDAvailable)
        #expect(capJSON["isMetalAvailable"] as? Bool == CodecCapabilities.isMetalAvailable)

        let (rgbImg, rgbPlanes) = try Self.makePlanarImage(
            width: 48, height: 32, componentCount: 3, meaningfulBits: 8, signed: false
        )
        let inPPM = dir.appendingPathComponent("input.ppm")
        try Self.writePPM(path: inPPM, width: 48, height: 32, planes: rgbPlanes)

        let cliPart2Jpx = dir.appendingPathComponent("cli_part2_ht.jpx")
        let cliDecPPM = dir.appendingPathComponent("cli_dec.ppm")
        let engineArg = CodecCapabilities.isMetalAvailable ? "metal" : "simd"
        let encRes = try await CLITestProcess.run([
            "encode", "-i", inPPM.path, "-o", cliPart2Jpx.path,
            "--output-format", "jpx", "--htj2k", "--mct", "part2",
            "--backend", "accelerated", "--engine", engineArg, "--json"
        ])
        #expect(encRes.status == 0, "\(encRes.stderrText)")
        let encJSON = try #require(JSONSerialization.jsonObject(with: encRes.stderr) as? [String: Any])
        #expect(encJSON["backend"] as? String == "accelerated")
        if CodecCapabilities.isMetalAvailable {
            #expect(encJSON["acceleratedEngine"] as? String == "metalGPU")
        }

        let decRes = try await CLITestProcess.run([
            "decode", "-i", cliPart2Jpx.path, "-o", cliDecPPM.path,
            "--backend", "accelerated", "--engine", engineArg, "--json"
        ])
        #expect(decRes.status == 0, "\(decRes.stderrText)")
        #expect(try Self.readPNM8Or16(path: cliDecPPM).planes == rgbPlanes)

        let cliHTIRV = dir.appendingPathComponent("cli_lossy_ht.j2c")
        let cliHTIRVDec = dir.appendingPathComponent("cli_lossy_ht.ppm")
        let htirvEncRes = try await CLITestProcess.run([
            "encode", "-i", inPPM.path, "-o", cliHTIRV.path,
            "--output-format", "htj2k", "--mode", "lossy", "--quality", "0.9", "--json"
        ])
        #expect(htirvEncRes.status == 0, "\(htirvEncRes.stderrText)")
        let htirvDecRes = try await CLITestProcess.run([
            "decode", "-i", cliHTIRV.path, "-o", cliHTIRVDec.path, "--json"
        ])
        #expect(htirvDecRes.status == 0, "\(htirvDecRes.stderrText)")
        #expect(Self.computePSNR(rgbPlanes, try Self.readPNM8Or16(path: cliHTIRVDec).planes, bitDepth: 8).psnr >= 32.0)

        // 2. Bidirectional External Oracles (executed whenever installed on host)
        let kduCompress = Self.findTool(["/usr/local/bin/kdu_compress", "/opt/homebrew/bin/kdu_compress"])
        let kduExpand = Self.findTool(["/usr/local/bin/kdu_expand", "/opt/homebrew/bin/kdu_expand"])
        let opjCompress = Self.findTool(["/opt/homebrew/bin/opj_compress", "/usr/local/bin/opj_compress"])
        let opjDecompress = Self.findTool(["/opt/homebrew/bin/opj_decompress", "/usr/local/bin/opj_decompress"])
        let ojphCompress = Self.findTool(["/opt/homebrew/bin/ojph_compress", "/usr/local/bin/ojph_compress"])
        let ojphExpand = Self.findTool(["/opt/homebrew/bin/ojph_expand", "/usr/local/bin/ojph_expand"])

        let decoder = try Decoder()

        // 2a. SwiftJ2K Part 2 MCT (reversible & irreversible) -> Kakadu 8.4.1
        // (Note: OpenJPEG 2.5.4 opj_decompress rejects DEP Xmcc=0 and Part 2 MCT SGcod=0x02 upstream,
        // even on codestreams generated by OpenJPEG 2.5.4's own opj_set_MCT C API; OpenJPEG 2.5.4 is
        // verified below on HTIRV and Part 1 9/7 codestreams.)
        let swiftPart2Rev = try await Encoder(
            configuration: EncoderConfiguration(
                mode: .lossless,
                codecOptions: CodecOptions(decompositionLevels: 2, multiComponentTransform: .part2)
            )
        ).encode(rgbImg)
        let swiftPart2RevPath = dir.appendingPathComponent("swift_part2_rev.j2k")
        try swiftPart2Rev.data.write(to: swiftPart2RevPath)

        let swiftPart2Irr = try await Encoder(
            configuration: EncoderConfiguration(
                mode: .lossy,
                codecOptions: CodecOptions(decompositionLevels: 2, quality: 0.92, multiComponentTransform: .part2)
            )
        ).encode(rgbImg)
        let swiftPart2IrrPath = dir.appendingPathComponent("swift_part2_irr.j2k")
        try swiftPart2Irr.data.write(to: swiftPart2IrrPath)

        if let kduExpand {
            let kduRevOut = dir.appendingPathComponent("kdu_from_swift_part2_rev.ppm")
            try Self.runExternal(kduExpand, ["-i", swiftPart2RevPath.path, "-o", kduRevOut.path, "-quiet"])
            #expect(try Self.readPNM8Or16(path: kduRevOut).planes == rgbPlanes)

            let kduIrrOut = dir.appendingPathComponent("kdu_from_swift_part2_irr.ppm")
            try Self.runExternal(kduExpand, ["-i", swiftPart2IrrPath.path, "-o", kduIrrOut.path, "-quiet"])
            #expect(Self.computePSNR(rgbPlanes, try Self.readPNM8Or16(path: kduIrrOut).planes, bitDepth: 8).psnr >= 32.0)
        }

        if let opjCompress {
            let opjLossy = dir.appendingPathComponent("opj_part1_lossy.j2k")
            try Self.runExternal(opjCompress, ["-i", inPPM.path, "-o", opjLossy.path, "-I", "-n", "3", "-r", "3"])
            let decOpjLossy = try await decoder.decode(Data(contentsOf: opjLossy))
            #expect(Self.computePSNR(rgbPlanes, try Self.extractPlanes(decOpjLossy.image), bitDepth: 8).psnr >= 32.0)
        }

        // 2b. Kakadu Part 2 MCT (reversible DEP & irreversible MATRIX) -> SwiftJ2K
        if let kduCompress {
            let kduPart2Rev = dir.appendingPathComponent("kdu_part2_rev.j2c")
            try Self.runExternal(kduCompress, [
                "-i", inPPM.path, "-o", kduPart2Rev.path,
                "Cycc=no", "Creversible=yes",
                "Sprecision=9,9,9", "Ssigned=yes,yes,yes",
                "Mcomponents=3",
                "Mstage_inputs:I1={0,2}", "Mstage_outputs:I1={0,2}",
                "Mstage_collections:I1={3,3}",
                "Mstage_xforms:I1={DEP,1,2,1,0}",
                "Mtriang_size:I1=5",
                "Mtriang_coeffs:I1={-1},{1},{-1},{0},{1}",
                "Mvector_size:I2=3",
                "Mvector_coeffs:I2={128},{128},{128}",
                "Mnum_stages=1", "Mstages=1", "-quiet"
            ])
            let decKduRev = try await decoder.decode(Data(contentsOf: kduPart2Rev))
            #expect(try Self.extractPlanes(decKduRev.image) == rgbPlanes)

            let kduPart2Irr = dir.appendingPathComponent("kdu_part2_irr.j2c")
            try Self.runExternal(kduCompress, [
                "-i", inPPM.path, "-o", kduPart2Irr.path,
                "Cycc=no", "Creversible=no", "-rate", "4.0",
                "Sprecision=9,9,9", "Ssigned=yes,yes,yes",
                "Mcomponents=3",
                "Mstage_inputs:I1={0,2}", "Mstage_outputs:I1={0,2}",
                "Mstage_collections:I1={3,3}",
                "Mstage_xforms:I1={MATRIX,1,2,0,0}",
                "Mmatrix_size:I1=9",
                "Mmatrix_coeffs:I1={1},{0},{1.402},{1},{-0.344136},{-0.714136},{1},{1.772},{0}",
                "Mvector_size:I2=3",
                "Mvector_coeffs:I2={128},{128},{128}",
                "Mnum_stages=1", "Mstages=1", "-quiet"
            ])
            let decKduIrr = try await decoder.decode(Data(contentsOf: kduPart2Irr))
            #expect(Self.computePSNR(rgbPlanes, try Self.extractPlanes(decKduIrr.image), bitDepth: 8).psnr >= 32.0)
        }

        // 2c. SwiftJ2K HTIRV -> OpenJPH, Kakadu & OpenJPEG
        let swiftHTIRV = try await Encoder(
            configuration: EncoderConfiguration(
                mode: .lossy,
                codecOptions: CodecOptions(decompositionLevels: 3, blockCoding: .htj2k, quality: 0.90)
            )
        ).encode(rgbImg)
        let swiftHTIRVPath = dir.appendingPathComponent("swift_htirv.j2c")
        try swiftHTIRV.data.write(to: swiftHTIRVPath)
        let swiftHTIRVRecPlanes = try Self.extractPlanes(try await decoder.decode(swiftHTIRV.data).image)

        if let ojphExpand {
            let ojphOut = dir.appendingPathComponent("ojph_from_swift_htirv.ppm")
            try Self.runExternal(ojphExpand, ["-i", swiftHTIRVPath.path, "-o", ojphOut.path])
            let ojphPlanes = try Self.readPNM8Or16(path: ojphOut).planes
            #expect(Self.computePSNR(rgbPlanes, ojphPlanes, bitDepth: 8).psnr >= 33.0)
            #expect(Self.computePSNR(swiftHTIRVRecPlanes, ojphPlanes, bitDepth: 8).mae <= 1.5)
        }
        if let kduExpand {
            let kduOut = dir.appendingPathComponent("kdu_from_swift_htirv.ppm")
            try Self.runExternal(kduExpand, ["-i", swiftHTIRVPath.path, "-o", kduOut.path, "-quiet"])
            let kduPlanes = try Self.readPNM8Or16(path: kduOut).planes
            #expect(Self.computePSNR(rgbPlanes, kduPlanes, bitDepth: 8).psnr >= 33.0)
            #expect(Self.computePSNR(swiftHTIRVRecPlanes, kduPlanes, bitDepth: 8).mae <= 1.5)
        }
        if let opjDecompress {
            let opjOut = dir.appendingPathComponent("opj_from_swift_htirv.ppm")
            try Self.runExternal(opjDecompress, ["-i", swiftHTIRVPath.path, "-o", opjOut.path])
            let opjPlanes = try Self.readPNM8Or16(path: opjOut).planes
            #expect(Self.computePSNR(rgbPlanes, opjPlanes, bitDepth: 8).psnr >= 33.0)
        }

        // 2d. OpenJPH & Kakadu HTIRV -> SwiftJ2K
        if let ojphCompress, let ojphExpand {
            let ojphHTIRV = dir.appendingPathComponent("ojph_htirv.j2c")
            try Self.runExternal(ojphCompress, [
                "-i", inPPM.path, "-o", ojphHTIRV.path, "-reversible", "false", "-qstep", "0.01"
            ])
            let ojphRefPPM = dir.appendingPathComponent("ojph_ref.ppm")
            try Self.runExternal(ojphExpand, ["-i", ojphHTIRV.path, "-o", ojphRefPPM.path])
            let ojphRefPlanes = try Self.readPNM8Or16(path: ojphRefPPM).planes
            let swiftFromOjph = try Self.extractPlanes(try await decoder.decode(Data(contentsOf: ojphHTIRV)).image)
            #expect(Self.computePSNR(rgbPlanes, swiftFromOjph, bitDepth: 8).psnr >= 33.0)
            #expect(Self.computePSNR(ojphRefPlanes, swiftFromOjph, bitDepth: 8).mae <= 1.5)
        }

        if let kduCompress, let kduExpand {
            let kduHTIRV = dir.appendingPathComponent("kdu_htirv.j2c")
            try Self.runExternal(kduCompress, [
                "-i", inPPM.path, "-o", kduHTIRV.path,
                "Cmodes=HT", "Creversible=no", "-rate", "3.5", "-quiet"
            ])
            let kduRefPPM = dir.appendingPathComponent("kdu_ref.ppm")
            try Self.runExternal(kduExpand, ["-i", kduHTIRV.path, "-o", kduRefPPM.path, "-quiet"])
            let kduRefPlanes = try Self.readPNM8Or16(path: kduRefPPM).planes
            let swiftFromKdu = try Self.extractPlanes(try await decoder.decode(Data(contentsOf: kduHTIRV)).image)
            #expect(Self.computePSNR(rgbPlanes, swiftFromKdu, bitDepth: 8).psnr >= 33.0)
            #expect(Self.computePSNR(kduRefPlanes, swiftFromKdu, bitDepth: 8).mae <= 1.5)
        }
    }
    #endif
}
