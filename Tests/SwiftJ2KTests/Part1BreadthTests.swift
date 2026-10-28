// SPDX-License-Identifier: Apache-2.0
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Testing
@testable import SwiftJ2K

// MARK: - Milestone 7 Part 1 Breadth Fixture Access

enum Part1BreadthFixtures {
    struct Entry: Decodable, Sendable {
        let name: String
        let file: String
        let referenceRaw: String
        let width: Int
        let height: Int
        let components: Int
        let meaningfulBits: Int
        let storageBits: Int
        let signed: Bool
        let lossless: Bool
        let tool: String
        let note: String
        let sha256: String
        let bytes: Int
        let oracleMaxError: Int
        let oraclePSNR: Double?
    }
    struct Manifest: Decodable, Sendable {
        let fixtures: [Entry]
    }

    static let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/Part1Breadth")
    static let manifest: Manifest = {
        let data = try! Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        return try! JSONDecoder().decode(Manifest.self, from: data)
    }()

    static func codestreamBytes(_ entry: Entry) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent(entry.file))
    }

    static func referencePlanes(_ entry: Entry) throws -> [[Int]] {
        let raw = [UInt8](try Data(contentsOf: directory.appendingPathComponent(entry.referenceRaw)))
        let pixelCount = entry.width * entry.height
        var planes: [[Int]] = []
        planes.reserveCapacity(entry.components)
        let bytesPerSample = entry.storageBits / 8
        for c in 0..<entry.components {
            var plane = [Int](repeating: 0, count: pixelCount)
            let baseOffset = c * pixelCount * bytesPerSample
            for i in 0..<pixelCount {
                let off = baseOffset + i * bytesPerSample
                if bytesPerSample == 1 {
                    let u = raw[off]
                    plane[i] = entry.signed ? Int(Int8(bitPattern: u)) : Int(u)
                } else {
                    let u = UInt16(raw[off]) | (UInt16(raw[off + 1]) << 8)
                    plane[i] = entry.signed ? Int(Int16(bitPattern: u)) : Int(u)
                }
            }
            planes.append(plane)
        }
        return planes
    }
}

func extractPlanes(_ image: Image) throws -> [[Int]] {
    let w = image.descriptor.width
    let h = image.descriptor.height
    let cCount = image.descriptor.components.count
    var planes: [[Int]] = []
    planes.reserveCapacity(cCount)
    for c in 0..<cCount {
        var plane = [Int](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                plane[y * w + x] = try image.sampleInt(component: c, x: x, y: y)
            }
        }
        planes.append(plane)
    }
    return planes
}

func computeErrorMetrics(_ expected: [[Int]], _ actual: [[Int]], meaningfulBits: Int) -> (maxError: Int, psnr: Double) {
    var maxErr = 0
    var sumSq = 0.0
    var count = 0
    for (ep, ap) in zip(expected, actual) {
        for (e, a) in zip(ep, ap) {
            let d = abs(e - a)
            if d > maxErr { maxErr = d }
            sumSq += Double(d * d)
            count += 1
        }
    }
    if sumSq == 0 { return (0, .infinity) }
    let mse = sumSq / Double(max(1, count))
    let peak = Double((1 << meaningfulBits) - 1)
    let psnr = 10.0 * log10((peak * peak) / mse)
    return (maxErr, psnr)
}

func makeMultiPlaneImage(
    planes: [[Int]],
    width: Int,
    height: Int,
    meaningfulBits: Int,
    storageBits: Int,
    signed: Bool,
    interleaved: Bool = false
) throws -> Image {
    let descriptor: ImageDescriptor
    if interleaved && planes.count == 3 {
        descriptor = try ImageDescriptor.rgbInterleaved(
            width: width, height: height, storageBits: storageBits,
            meaningfulBits: meaningfulBits, signed: signed
        )
    } else if planes.count == 3 {
        descriptor = try ImageDescriptor.rgbPlanar(
            width: width, height: height, storageBits: storageBits,
            meaningfulBits: meaningfulBits, signed: signed
        )
    } else {
        descriptor = try ImageDescriptor.multiComponentPlanar(
            width: width, height: height, componentCount: planes.count,
            storageBits: storageBits, meaningfulBits: meaningfulBits,
            sampleType: signed ? .signedInteger : .unsignedInteger
        )
    }
    return try ImageDestination.allocate(descriptor: descriptor).writeSamples { c, x, y in
        planes[c][y * width + x]
    }
}

// MARK: - 1. Independent OpenJPEG 2.5.4 and Kakadu 8.4.1 Part 1 Breadth Fixtures

@Test(arguments: Part1BreadthFixtures.manifest.fixtures.map(\.name))
func independentPart1BreadthFixturesDecodeCorrectly(name: String) async throws {
    let entry = Part1BreadthFixtures.manifest.fixtures.first { $0.name == name }!
    let data = try Part1BreadthFixtures.codestreamBytes(entry)
    #expect(data.count == entry.bytes)

    let decoder = try Decoder()
    let info = try decoder.inspect(data)
    #expect(info.descriptor.width == entry.width)
    #expect(info.descriptor.height == entry.height)
    #expect(info.descriptor.components.count == entry.components)
    #expect(info.descriptor.meaningfulBits == entry.meaningfulBits)
    #expect(info.descriptor.sampleType == (entry.signed ? .signedInteger : .unsignedInteger))

    let decoded = try await decoder.decode(data)
    #expect(decoded.report.backend == .accelerated)
    #expect(decoded.report.copyEvents.isEmpty && decoded.report.pixelAllocationCount == 1)

    let expectedPlanes = try Part1BreadthFixtures.referencePlanes(entry)
    let actualPlanes = try extractPlanes(decoded.image)
    let (maxErr, psnr) = computeErrorMetrics(expectedPlanes, actualPlanes, meaningfulBits: entry.meaningfulBits)

    if entry.lossless {
        #expect(decoded.report.fidelity == .exactSamples)
        #expect(maxErr == 0, "Lossless fixture \(entry.file) had maxErr=\(maxErr)")
    } else {
        #expect(decoded.report.fidelity == .lossy)
        let refPSNR = entry.oraclePSNR ?? 40.0
        #expect(psnr >= refPSNR - 1.0, "Lossy fixture \(entry.file) PSNR \(psnr) dB below oracle \(refPSNR) dB")
        #expect(maxErr <= entry.oracleMaxError + 2, "Lossy fixture \(entry.file) maxErr \(maxErr) above oracle \(entry.oracleMaxError)")
    }
}

// MARK: - 2. Colour and Multi-Component (RCT, ICT, Planar & Interleaved, RGBA)

@Test func rgbPlanarAndInterleavedRoundTripWithRCTAndICTAndNoMCT() async throws {
    let w = 48, h = 36
    var r = [Int](repeating: 0, count: w * h)
    var g = [Int](repeating: 0, count: w * h)
    var b = [Int](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            let idx = y * w + x
            r[idx] = (x * 5 + y * 2) & 0xFF
            g[idx] = (x * 2 + y * 6 + 40) & 0xFF
            b[idx] = ((x ^ y) * 4 + 90) & 0xFF
        }
    }
    let planes = [r, g, b]
    let planarImage = try makeMultiPlaneImage(planes: planes, width: w, height: h, meaningfulBits: 8, storageBits: 8, signed: false, interleaved: false)
    let interleavedImage = try makeMultiPlaneImage(planes: planes, width: w, height: h, meaningfulBits: 8, storageBits: 8, signed: false, interleaved: true)

    // 1. Lossless 5/3 + RCT on both planar and interleaved produce identical codestreams and exact samples
    let rctConfig = try EncoderConfiguration(
        mode: .lossless,
        codecOptions: CodecOptions(decompositionLevels: 3, wavelet: .reversible53, colourTransform: .rct)
    )
    let encPlanar = try await Encoder(configuration: rctConfig).encode(planarImage)
    let encInterleaved = try await Encoder(configuration: rctConfig).encode(interleavedImage)
    #expect(encPlanar.data == encInterleaved.data)
    #expect(encPlanar.report.fidelity == .exactSamples)

    let decPlanar = try await Decoder().decode(encPlanar.data)
    #expect(try extractPlanes(decPlanar.image) == planes)

    // Decode directly into caller-allocated interleaved RGB destination
    let interleavedDest = try ImageDestination.allocate(
        descriptor: .rgbInterleaved(width: w, height: h, storageBits: 8, meaningfulBits: 8)
    )
    let decInterleaved = try await Decoder().decode(encPlanar.data, into: interleavedDest)
    #expect(decInterleaved.report.pixelAllocationCount == 0 && decInterleaved.report.copyEvents.isEmpty)
    #expect(try extractPlanes(decInterleaved.image) == planes)

    // 2. Lossless 5/3 without MCT (.none)
    let noMctConfig = try EncoderConfiguration(
        mode: .lossless,
        codecOptions: CodecOptions(decompositionLevels: 3, wavelet: .reversible53, colourTransform: .none)
    )
    let encNoMct = try await Encoder(configuration: noMctConfig).encode(planarImage)
    let decNoMct = try await Decoder().decode(encNoMct.data)
    #expect(try extractPlanes(decNoMct.image) == planes)

    // 3. Lossy 9/7 + ICT
    let ictConfig = try EncoderConfiguration(
        mode: .lossy,
        codecOptions: CodecOptions(decompositionLevels: 3, wavelet: .irreversible97, colourTransform: .ict, quality: 0.9)
    )
    let encIct = try await Encoder(configuration: ictConfig).encode(planarImage)
    #expect(encIct.report.fidelity == .lossy)
    let decIct = try await Decoder().decode(encIct.data)
    #expect(decIct.report.fidelity == .lossy)
    let (maxErrIct, psnrIct) = computeErrorMetrics(planes, try extractPlanes(decIct.image), meaningfulBits: 8)
    #expect(psnrIct > 38.0 && maxErrIct <= 12)
}

@Test func fourComponentRGBARoundTripsLosslessAndLossy() async throws {
    let w = 32, h = 24
    var planes: [[Int]] = Array(repeating: [Int](repeating: 0, count: w * h), count: 4)
    for y in 0..<h {
        for x in 0..<w {
            let i = y * w + x
            planes[0][i] = (x * 7 + y) & 0xFF
            planes[1][i] = (x + y * 9) & 0xFF
            planes[2][i] = (128 + x - y) & 0xFF
            planes[3][i] = (255 - (x * 3)) & 0xFF
        }
    }
    let image = try makeMultiPlaneImage(planes: planes, width: w, height: h, meaningfulBits: 8, storageBits: 8, signed: false)
    let losslessEnc = try await Encoder(configuration: EncoderConfiguration(
        mode: .lossless,
        codecOptions: CodecOptions(decompositionLevels: 2, colourTransform: .rct)
    )).encode(image)
    let losslessDec = try await Decoder().decode(losslessEnc.data)
    #expect(losslessDec.image.descriptor.components.count == 4)
    #expect(try extractPlanes(losslessDec.image) == planes)

    let lossyEnc = try await Encoder(configuration: EncoderConfiguration(
        mode: .lossy,
        codecOptions: CodecOptions(decompositionLevels: 2, wavelet: .irreversible97, colourTransform: .ict, quality: 0.92)
    )).encode(image)
    let lossyDec = try await Decoder().decode(lossyEnc.data)
    let (_, psnr) = computeErrorMetrics(planes, try extractPlanes(lossyDec.image), meaningfulBits: 8)
    #expect(psnr > 38.0)
}

// MARK: - 3. Signed Integer Samples (8-bit, 12-bit, 16-bit)

@Test func signedSamplesRoundTripAcrossBitDepthsAndExtremes() async throws {
    for (bits, storageBits) in [(8, 8), (12, 16), (16, 16)] {
        let w = 41, h = 29
        let minVal = -(1 << (bits - 1))
        let maxVal = (1 << (bits - 1)) - 1
        var plane = [Int](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let idx = y * w + x
                switch idx {
                case 0: plane[idx] = minVal
                case 1: plane[idx] = maxVal
                case 2: plane[idx] = 0
                case 3: plane[idx] = -1
                case 4: plane[idx] = 1
                default:
                    let v = Int(Double(maxVal) * 0.8 * sin(Double(x) / 5.0) * cos(Double(y) / 4.0))
                    plane[idx] = max(minVal, min(maxVal, v))
                }
            }
        }
        let image = try makeMultiPlaneImage(planes: [plane], width: w, height: h, meaningfulBits: bits, storageBits: storageBits, signed: true)
        let enc = try await Encoder(configuration: EncoderConfiguration(
            mode: .lossless,
            codecOptions: CodecOptions(decompositionLevels: 3)
        )).encode(image)
        let dec = try await Decoder().decode(enc.data)
        #expect(dec.image.descriptor.sampleType == .signedInteger)
        #expect(dec.image.descriptor.meaningfulBits == bits)
        #expect(try extractPlanes(dec.image) == [plane])
    }
}

// MARK: - 4. 9/7 Irreversible Wavelet, Quantisation, Guard Bits, and Rate-Distortion Curve

@Test func lossy97RateDistortionCurveIsMonotonicAndGuardBitsWork() async throws {
    let w = 64, h = 64
    var plane = [Int](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            let v = 32768.0 + 26000.0 * sin(Double(x) / 7.0) * cos(Double(y) / 5.0) + Double((x * 13 + y * 7) % 19 - 9)
            plane[y * w + x] = max(0, min(65535, Int(v)))
        }
    }
    let image = try makeMultiPlaneImage(planes: [plane], width: w, height: h, meaningfulBits: 16, storageBits: 16, signed: false)

    let targetBpps: [Double] = [0.25, 0.5, 1.0, 2.0, 4.0]
    var prevPSNR = 0.0
    var prevBytes = 0
    for bpp in targetBpps {
        let cfg = try EncoderConfiguration(
            mode: .lossy,
            codecOptions: CodecOptions(
                decompositionLevels: 4,
                wavelet: .irreversible97,
                targetBitsPerPixel: bpp,
                quantizationStyle: .scalarExpounded,
                guardBits: 2
            )
        )
        let enc = try await Encoder(configuration: cfg).encode(image)
        let dec = try await Decoder().decode(enc.data)
        let (_, psnr) = computeErrorMetrics([plane], try extractPlanes(dec.image), meaningfulBits: 16)
        #expect(psnr > prevPSNR, "PSNR did not increase at \(bpp) bpp: \(psnr) <= \(prevPSNR)")
        #expect(enc.data.count >= prevBytes, "Bytes did not increase at \(bpp) bpp: \(enc.data.count) < \(prevBytes)")
        prevPSNR = psnr
        prevBytes = enc.data.count
    }

    // Verify scalar-derived (Sqcd=1) and extended guard bits (1...7)
    for gb in [1, 2, 4, 7] {
        let cfg = try EncoderConfiguration(
            mode: .lossy,
            codecOptions: CodecOptions(
                decompositionLevels: 3,
                wavelet: .irreversible97,
                quality: 0.9,
                quantizationStyle: .scalarDerived,
                guardBits: gb
            )
        )
        let enc = try await Encoder(configuration: cfg).encode(image)
        let dec = try await Decoder().decode(enc.data)
        let (_, psnr) = computeErrorMetrics([plane], try extractPlanes(dec.image), meaningfulBits: 16)
        #expect(psnr > 45.0, "Scalar-derived with guardBits=\(gb) produced low PSNR \(psnr)")
    }
}

// MARK: - 5. Near-Lossless Mode (.nearLossless(maximumAbsoluteError:))

@Test func nearLosslessEnforcesMaximumAbsoluteErrorBound() async throws {
    let w = 48, h = 48
    var plane = [Int](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            plane[y * w + x] = (x * 5 + y * 3 + Int(40.0 * sin(Double(x) / 4.0))) & 0xFF
        }
    }
    let image = try makeMultiPlaneImage(planes: [plane], width: w, height: h, meaningfulBits: 8, storageBits: 8, signed: false)

    for maxError in [1, 2, 5] {
        let cfg = try EncoderConfiguration(
            mode: .nearLossless(maximumAbsoluteError: maxError),
            codecOptions: CodecOptions(decompositionLevels: 3)
        )
        let enc = try await Encoder(configuration: cfg).encode(image)
        #expect(enc.report.fidelity == .boundedError(maxError))
        let dec = try await Decoder().decode(enc.data)
        let (actualMaxErr, _) = computeErrorMetrics([plane], try extractPlanes(dec.image), meaningfulBits: 8)
        #expect(actualMaxErr <= maxError, "Near-lossless bound \(maxError) violated: actualMaxErr=\(actualMaxErr)")
    }
}

// MARK: - 6. Region of Interest (RGN 0xFF5E MaxShift)

@Test func roiMaxShiftPreservesLosslessAndPrioritisesForegroundAtLowBitrate() async throws {
    let w = 64, h = 64
    var plane = [Int](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            let base = 128.0 + 80.0 * sin(Double(x) / 4.0) * cos(Double(y) / 4.0)
            let detail = Double(((x * 13 + y * 29) % 31) - 15)
            plane[y * w + x] = max(0, min(255, Int(base + detail)))
        }
    }
    let image = try makeMultiPlaneImage(planes: [plane], width: w, height: h, meaningfulBits: 8, storageBits: 8, signed: false)
    let roi = try CodecOptions.RegionOfInterest(x: 20, y: 20, width: 24, height: 24)

    // 1. Lossless with ROI recovers exact samples everywhere
    let losslessCfg = try EncoderConfiguration(
        mode: .lossless,
        codecOptions: CodecOptions(decompositionLevels: 3, regionOfInterest: roi)
    )
    let losslessEnc = try await Encoder(configuration: losslessCfg).encode(image)
    let losslessDec = try await Decoder().decode(losslessEnc.data)
    #expect(try extractPlanes(losslessDec.image) == [plane])

    // 2. Constrained-bitrate lossy with ROI gives higher PSNR inside the ROI than outside
    let lossyRoiCfg = try EncoderConfiguration(
        mode: .lossy,
        codecOptions: CodecOptions(
            decompositionLevels: 2,
            codeBlockWidth: 16,
            codeBlockHeight: 16,
            wavelet: .irreversible97,
            targetBitsPerPixel: 1.5,
            regionOfInterest: roi
        )
    )
    let lossyEnc = try await Encoder(configuration: lossyRoiCfg).encode(image)
    let lossyDec = try await Decoder().decode(lossyEnc.data)
    let decodedPlane = try extractPlanes(lossyDec.image)[0]

    var fgSq = 0.0, fgCount = 0
    var bgSq = 0.0, bgCount = 0
    for y in 0..<h {
        for x in 0..<w {
            let d = Double(plane[y * w + x] - decodedPlane[y * w + x])
            if x >= 20 && x < 44 && y >= 20 && y < 44 {
                fgSq += d * d; fgCount += 1
            } else {
                bgSq += d * d; bgCount += 1
            }
        }
    }
    let fgMSE = fgSq / Double(fgCount)
    let bgMSE = bgSq / Double(bgCount)
    #expect(fgMSE < bgMSE * 0.25, "Foreground ROI MSE (\(fgMSE)) should be much lower than background MSE (\(bgMSE))")
}

// MARK: - 7. Multi-Tile, Multi-Layer, Precincts, Progressions, POC, SOP/EPH, Styles

@Test func multiTileMultiLayerPrecinctsProgressionsAndPOCRoundTrip() async throws {
    let w = 64, h = 48
    var r = [Int](repeating: 0, count: w * h)
    var g = [Int](repeating: 0, count: w * h)
    var b = [Int](repeating: 0, count: w * h)
    for y in 0..<h {
        for x in 0..<w {
            let i = y * w + x
            r[i] = (x * 4 + y) & 0xFF
            g[i] = (x + y * 5) & 0xFF
            b[i] = ((x + y) * 3) & 0xFF
        }
    }
    let planes = [r, g, b]
    let image = try makeMultiPlaneImage(planes: planes, width: w, height: h, meaningfulBits: 8, storageBits: 8, signed: false)

    for order in CodecOptions.ProgressionOrder.allCases {
        let cfg = try EncoderConfiguration(
            mode: .lossless,
            codecOptions: CodecOptions(
                decompositionLevels: 2,
                codeBlockWidth: 32,
                codeBlockHeight: 32,
                progressionOrder: order,
                progressionChanges: [
                    try CodecOptions.ProgressionOrderChange(
                        startResolution: 0, startComponent: 0, endLayer: 3,
                        endResolution: 2, endComponent: 3, progressionOrder: order
                    ),
                    try CodecOptions.ProgressionOrderChange(
                        startResolution: 2, startComponent: 0, endLayer: 3,
                        endResolution: 3, endComponent: 3, progressionOrder: .lrcp
                    )
                ],
                qualityLayers: 3,
                tileWidth: 32,
                tileHeight: 24,
                precinctSizes: [try CodecOptions.PrecinctSize(width: 32, height: 32)],
                codeBlockStyleBits: 0x01 | 0x04 | 0x20,
                usesSOP: true,
                usesEPH: true
            )
        )
        let enc = try await Encoder(configuration: cfg).encode(image)
        let dec = try await Decoder().decode(enc.data)
        #expect(try extractPlanes(dec.image) == planes, "Failed round-trip for progression \(order)")
    }
}

// MARK: - 8. Independent Oracle Cross-Decode of Successor Part 1 Breadth Encodings

@Test(.enabled(if: Oracle.available, "No independent JPEG 2000 decoder installed"))
func independentOraclesCrossDecodePart1BreadthEncodings() async throws {
    #if os(macOS) || os(Linux)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("swiftj2k-m7-oracle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // 1. 8-bit RGB Lossless (5/3 + RCT) and Lossy (9/7 + ICT) -> Kakadu & OpenJPEG decode to PPM
    let w = 48, h = 32
    var r = [Int](repeating: 0, count: w * h)
    var g = [Int](repeating: 0, count: w * h)
    var b = [Int](repeating: 0, count: w * h)
    for i in 0..<(w * h) {
        r[i] = (i * 5) & 0xFF
        g[i] = (i * 3 + 50) & 0xFF
        b[i] = (i * 7 + 100) & 0xFF
    }
    let rgbImage = try makeMultiPlaneImage(planes: [r, g, b], width: w, height: h, meaningfulBits: 8, storageBits: 8, signed: false)

    let rgbLossless = try await Encoder(configuration: EncoderConfiguration(
        mode: .lossless,
        codecOptions: CodecOptions(decompositionLevels: 3, wavelet: .reversible53, colourTransform: .rct, qualityLayers: 2, tileWidth: 24, tileHeight: 16)
    )).encode(rgbImage).data
    let rgbLosslessURL = directory.appendingPathComponent("rgb_lossless.j2k")
    try rgbLossless.write(to: rgbLosslessURL)

    let rgbLossy = try await Encoder(configuration: EncoderConfiguration(
        mode: .lossy,
        codecOptions: CodecOptions(decompositionLevels: 3, wavelet: .irreversible97, colourTransform: .ict, quality: 0.9)
    )).encode(rgbImage).data
    let rgbLossyURL = directory.appendingPathComponent("rgb_lossy.j2k")
    try rgbLossy.write(to: rgbLossyURL)

    for tool in [Oracle.openJPEG, Oracle.kakadu].compactMap({ $0 }) {
        let ppmLossless = directory.appendingPathComponent("lossless_\(tool.contains("kdu") ? "kdu" : "opj").ppm")
        #expect(try Oracle.decode(tool, rgbLosslessURL, ppmLossless), "\(tool) failed on RGB lossless")
        let ppmLossy = directory.appendingPathComponent("lossy_\(tool.contains("kdu") ? "kdu" : "opj").ppm")
        #expect(try Oracle.decode(tool, rgbLossyURL, ppmLossy), "\(tool) failed on RGB lossy")
    }

    // 2. Signed 16-bit lossless & Signed 12-bit + ROI -> Kakadu & OpenJPEG decode to PGX
    var s16Plane = [Int](repeating: 0, count: w * h)
    var s12Plane = [Int](repeating: 0, count: w * h)
    for i in 0..<(w * h) {
        s16Plane[i] = Int(Int16(truncatingIfNeeded: (i * 521) - 16000))
        s12Plane[i] = max(-2048, min(2047, (i * 37) % 4096 - 2048))
    }
    let signed16Image = try makeMultiPlaneImage(planes: [s16Plane], width: w, height: h, meaningfulBits: 16, storageBits: 16, signed: true)
    let signed16Enc = try await Encoder(configuration: EncoderConfiguration(
        mode: .lossless,
        codecOptions: CodecOptions(decompositionLevels: 3)
    )).encode(signed16Image).data
    let signed16URL = directory.appendingPathComponent("signed16.j2k")
    try signed16Enc.write(to: signed16URL)

    let signed12Image = try makeMultiPlaneImage(planes: [s12Plane], width: w, height: h, meaningfulBits: 12, storageBits: 16, signed: true)
    let signed12RoiEnc = try await Encoder(configuration: EncoderConfiguration(
        mode: .lossless,
        codecOptions: CodecOptions(decompositionLevels: 3, regionOfInterest: try CodecOptions.RegionOfInterest(x: 8, y: 8, width: 16, height: 16))
    )).encode(signed12Image).data
    let signed12RoiURL = directory.appendingPathComponent("signed12_roi.j2k")
    try signed12RoiEnc.write(to: signed12RoiURL)

    let signed16RoiEnc = try await Encoder(configuration: EncoderConfiguration(
        mode: .lossless,
        codecOptions: CodecOptions(decompositionLevels: 3, regionOfInterest: try CodecOptions.RegionOfInterest(x: 8, y: 8, width: 16, height: 16))
    )).encode(signed16Image).data
    let signed16RoiURL = directory.appendingPathComponent("signed16_roi.j2k")
    try signed16RoiEnc.write(to: signed16RoiURL)

    if let kdu = Oracle.kakadu {
        #expect(try Oracle.decode(kdu, signed16URL, directory.appendingPathComponent("s16_kdu.pgx")), "Kakadu failed on signed 16-bit")
        #expect(try Oracle.decode(kdu, signed12RoiURL, directory.appendingPathComponent("s12_roi_kdu.pgx")), "Kakadu failed on signed 12-bit + ROI")
        #expect(try Oracle.decode(kdu, signed16RoiURL, directory.appendingPathComponent("s16_roi_kdu.pgx")), "Kakadu failed on signed 16-bit + ROI (34 bit-planes)")
    }
    if let opj = Oracle.openJPEG {
        #expect(try Oracle.decode(opj, signed16URL, directory.appendingPathComponent("s16_opj.pgx")), "OpenJPEG failed on signed 16-bit")
        #expect(try Oracle.decode(opj, signed12RoiURL, directory.appendingPathComponent("s12_roi_opj.pgx")), "OpenJPEG failed on signed 12-bit + ROI")
    }
    #endif
}

// MARK: - 9. Validation of Invalid Part 1 Breadth Option Combinations

@Test func invalidPart1BreadthOptionsAreRejectedExplicitly() async throws {
    // ICT with reversible 5/3 wavelet is forbidden by ISO/IEC 15444-1
    #expect(throws: CodecError.self) {
        _ = try EncoderConfiguration(
            mode: .lossless,
            codecOptions: CodecOptions(wavelet: .reversible53, colourTransform: .ict)
        )
    }
    // RCT with irreversible 9/7 wavelet is forbidden by ISO/IEC 15444-1
    #expect(throws: CodecError.self) {
        _ = try EncoderConfiguration(
            mode: .lossy,
            codecOptions: CodecOptions(wavelet: .irreversible97, colourTransform: .rct)
        )
    }
    // Reversible 5/3 without rate target in .lossy mode is rejected
    #expect(throws: CodecError.self) {
        _ = try EncoderConfiguration(
            mode: .lossy,
            codecOptions: CodecOptions(wavelet: .reversible53)
        )
    }
    // Guard bits outside 1...7 are rejected
    #expect(throws: CodecError.self) {
        _ = try EncoderConfiguration(
            mode: .lossless,
            codecOptions: CodecOptions(guardBits: 0)
        )
    }
    #expect(throws: CodecError.self) {
        _ = try EncoderConfiguration(
            mode: .lossless,
            codecOptions: CodecOptions(guardBits: 8)
        )
    }
    // Quality outside 0.0...1.0 is rejected
    #expect(throws: CodecError.self) {
        _ = try EncoderConfiguration(
            mode: .lossy,
            codecOptions: CodecOptions(quality: 1.5)
        )
    }
}
