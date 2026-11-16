// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import SwiftJ2K

@Suite("Parallel Pool, Synchronous Fast Path & Reduced-Resolution Decode")
struct ParallelSyncAndReducedDecodeTests {

    private static func makeLimits(workers: Int) throws -> ResourceLimits {
        try ResourceLimits(
            maximumCompressedBytes: 64 << 20,
            maximumDecodedBytes: 64 << 20,
            maximumWorkspaceBytes: 256 << 20,
            maximumPixels: 16 << 20,
            maximumDimension: 16_384,
            maximumFrames: 1,
            maximumMetadataBytes: 4 << 20,
            maximumICCBytes: 4 << 20,
            maximumNestingDepth: 16,
            maximumWorkers: workers,
            deadlineSeconds: 60.0,
            maximumMemoryBytes: 384 << 20
        )
    }

    private static func makeGreyscale16(width: Int, height: Int, limits: ResourceLimits) throws -> Image {
        let desc = try ImageDescriptor.greyscale16(width: width, height: height, meaningfulBits: 12, limits: limits)
        let dest = try ImageDestination.allocate(descriptor: desc, limits: limits)
        return try dest.writeUInt16 { x, y in
            let smooth = Int(2048.0 + 1200.0 * sin(Double(x) * 0.09) * cos(Double(y) * 0.07))
            let detail = ((x * 7 + y * 13) & 31) - 16
            return UInt16(clamping: max(0, min(4095, smooth + detail)))
        }
    }

    private static func makeRGB8(width: Int, height: Int, limits: ResourceLimits) throws -> Image {
        let desc = try ImageDescriptor.rgbInterleaved(
            width: width,
            height: height,
            storageBits: 8,
            meaningfulBits: 8,
            signed: false,
            byteOrder: .littleEndian,
            limits: limits
        )
        let dest = try ImageDestination.allocate(descriptor: desc, limits: limits)
        return try dest.writeSamples { c, x, y in
            (x * (17 + c * 11) + y * (29 - c * 5) + c * 61) & 0xFF
        }
    }

    @Test("Multi-worker BoundedParallelPool matches 1-worker bit-for-bit across encode, decode, and transcode")
    func multiWorkerDeterminismMatchesSingleWorker() async throws {
        let limits1 = try Self.makeLimits(workers: 1)
        let limits8 = try Self.makeLimits(workers: 8)
        let grey = try Self.makeGreyscale16(width: 257, height: 193, limits: limits8)
        let rgb = try Self.makeRGB8(width: 193, height: 129, limits: limits8)

        for (img, colour) in [(grey, CodecOptions.ColourTransform.none), (rgb, CodecOptions.ColourTransform.rct)] {
            for coding: CodecOptions.BlockCoding in [.part1, .htj2k] {
                let codecOpts = try CodecOptions(
                    decompositionLevels: 4,
                    blockCoding: coding,
                    wavelet: .reversible53,
                    colourTransform: colour,
                    containerFormat: .codestream
                )
                let encoder = try SwiftJ2K.Encoder(configuration: .init(mode: .lossless, codecOptions: codecOpts))
                let decoder = try SwiftJ2K.Decoder()

                let enc1 = try await encoder.encode(img, options: .init(resourceLimits: limits1))
                let enc8 = try await encoder.encode(img, options: .init(resourceLimits: limits8))
                #expect(enc1.data == enc8.data)

                let dst1 = try ImageDestination.allocate(descriptor: img.descriptor, limits: limits1)
                let dst8 = try ImageDestination.allocate(descriptor: img.descriptor, limits: limits8)
                let dec1 = try await decoder.decode(enc8.data, into: dst1, options: .init(resourceLimits: limits1))
                let dec8 = try await decoder.decode(enc8.data, into: dst8, options: .init(resourceLimits: limits8))
                let bytes1 = try dec1.image.storage.withUnsafeBytes { Data($0) }
                let bytes8 = try dec8.image.storage.withUnsafeBytes { Data($0) }
                let origBytes = try img.storage.withUnsafeBytes { Data($0) }
                #expect(bytes1 == origBytes)
                #expect(bytes8 == origBytes)

                let transcoder = try SwiftJ2K.Transcoder()
                let target: TranscodeTarget = coding == .part1 ? .htj2k : .jpeg2000
                let tr1 = try await transcoder.transcode(enc8.data, to: target, options: .init(resourceLimits: limits1))
                let tr8 = try await transcoder.transcode(enc8.data, to: target, options: .init(resourceLimits: limits8))
                #expect(tr1.data == tr8.data)
                #expect(tr8.report.pixelAllocationCount == 0)

                let dstTr = try ImageDestination.allocate(descriptor: img.descriptor, limits: limits8)
                let trDec = try await decoder.decode(tr8.data, into: dstTr, options: .init(resourceLimits: limits8))
                let trBytes = try trDec.image.storage.withUnsafeBytes { Data($0) }
                #expect(trBytes == origBytes)
            }
        }
    }

    @Test("Synchronous encodeSynchronously, decodeSynchronously, and transcodeSynchronously match async bit-for-bit")
    func synchronousFastPathMatchesAsync() async throws {
        let limits = try Self.makeLimits(workers: 4)
        let img = try Self.makeGreyscale16(width: 192, height: 144, limits: limits)

        for coding: CodecOptions.BlockCoding in [.part1, .htj2k] {
            let codecOpts = try CodecOptions(
                decompositionLevels: 4,
                blockCoding: coding,
                wavelet: .reversible53,
                containerFormat: .codestream
            )
            let encoder = try SwiftJ2K.Encoder(configuration: .init(mode: .lossless, codecOptions: codecOpts))
            let decoder = try SwiftJ2K.Decoder()
            let transcoder = try SwiftJ2K.Transcoder()

            let asyncEnc = try await encoder.encode(img, options: .init(resourceLimits: limits))
            let syncEnc = try encoder.encodeSynchronously(img, options: .init(resourceLimits: limits))
            #expect(syncEnc.data == asyncEnc.data)

            let asyncDec = try await decoder.decode(syncEnc.data, options: .init(resourceLimits: limits))
            let syncDec = try decoder.decodeSynchronously(syncEnc.data, options: .init(resourceLimits: limits))
            let dest = try ImageDestination.allocate(descriptor: img.descriptor, limits: limits)
            let syncInto = try decoder.decodeSynchronously(syncEnc.data, into: dest, options: .init(resourceLimits: limits))

            let bAsync = try asyncDec.image.storage.withUnsafeBytes { Data($0) }
            let bSync = try syncDec.image.storage.withUnsafeBytes { Data($0) }
            let bInto = try syncInto.image.storage.withUnsafeBytes { Data($0) }
            #expect(bSync == bAsync)
            #expect(bInto == bAsync)

            let target: TranscodeTarget = coding == .part1 ? .htj2k : .jpeg2000
            let asyncTr = try await transcoder.transcode(syncEnc.data, to: target, options: .init(resourceLimits: limits))
            let syncTr = try transcoder.transcodeSynchronously(syncEnc.data, to: target, options: .init(resourceLimits: limits))
            #expect(syncTr.data == asyncTr.data)
            #expect(syncTr.report.pixelAllocationCount == 0)
        }
    }

    @Test("Reduced-resolution decode (resolutionReductionLevels 1 and 2) produces exact subband dimensions on 5/3 and 9/7")
    func reducedResolutionDecodeReversibleAndIrreversible() throws {
        let limits = try Self.makeLimits(workers: 4)
        let width = 259
        let height = 195
        let grey = try Self.makeGreyscale16(width: width, height: height, limits: limits)
        let rgb = try Self.makeRGB8(width: 130, height: 98, limits: limits)

        for useContainer in [false, true] {
            for mode: CompressionMode in [.lossless, .lossy] {
                for coding: CodecOptions.BlockCoding in [.part1, .htj2k] {
                    let container: CodecOptions.ContainerFormat = useContainer
                        ? (coding == .htj2k ? .jph : .jp2)
                        : .codestream
                    let opts = try CodecOptions(
                        decompositionLevels: 4,
                        blockCoding: coding,
                        wavelet: mode == .lossless ? .reversible53 : .irreversible97,
                        quality: mode == .lossless ? nil : 0.85,
                        containerFormat: container
                    )
                    let enc = try SwiftJ2K.Encoder(configuration: .init(mode: mode, codecOptions: opts))
                        .encodeSynchronously(grey, options: .init(resourceLimits: limits))

                    for k in [1, 2, 6] {
                        let effectiveK = min(k, 4)
                        let expectedW = (width + (1 << effectiveK) - 1) >> effectiveK
                        let expectedH = (height + (1 << effectiveK) - 1) >> effectiveK
                        let reducedDecoder = try SwiftJ2K.Decoder(
                            configuration: .init(codecOptions: try CodecOptions(resolutionReductionLevels: k))
                        )
                        let decOpts = DecodeOptions(resourceLimits: limits)
                        let reduced = try reducedDecoder.decodeSynchronously(enc.data, options: decOpts)
                        #expect(reduced.image.descriptor.width == expectedW)
                        #expect(reduced.image.descriptor.height == expectedH)
                        #expect(reduced.report.fidelity == Fidelity.lossy)

                        let matchingDest = try ImageDestination.allocate(
                            descriptor: .greyscale16(width: expectedW, height: expectedH, meaningfulBits: 12, limits: limits),
                            limits: limits
                        )
                        let reducedInto = try reducedDecoder.decodeSynchronously(enc.data, into: matchingDest, options: decOpts)
                        #expect(reducedInto.image.descriptor.width == expectedW)
                        #expect(reducedInto.image.descriptor.height == expectedH)
                    }
                }
            }
        }

        // Also verify 3-component RGB reduced decode
        let rgbEnc = try SwiftJ2K.Encoder(
            configuration: .init(
                mode: .lossless,
                codecOptions: try CodecOptions(decompositionLevels: 3, blockCoding: .htj2k, wavelet: .reversible53, colourTransform: .rct)
            )
        ).encodeSynchronously(rgb, options: .init(resourceLimits: limits))
        let rgbRedDecoder = try SwiftJ2K.Decoder(
            configuration: .init(codecOptions: try CodecOptions(resolutionReductionLevels: 1))
        )
        let rgbRed = try rgbRedDecoder.decodeSynchronously(rgbEnc.data, options: DecodeOptions(resourceLimits: limits))
        #expect(rgbRed.image.descriptor.width == 65)
        #expect(rgbRed.image.descriptor.height == 49)
        #expect(rgbRed.image.descriptor.components.count == 3)
    }

    @Test("CodecOptions rejects negative resolutionReductionLevels")
    func negativeResolutionReductionLevelsRejected() {
        #expect(throws: CodecError.self) {
            _ = try CodecOptions(resolutionReductionLevels: -1)
        }
    }

    @Test("Lossy 9/7 Part-1 and multi-pass HTJ2K PCRD rate-distortion PSNR increases monotonically with bitrate")
    func lossyRateDistortionMonotonicity() throws {
        let limits = try Self.makeLimits(workers: 4)
        let width = 128
        let height = 128
        let img = try Self.makeGreyscale16(width: width, height: height, limits: limits)
        let decoder = try SwiftJ2K.Decoder()

        func computePSNR(_ decoded: Image) throws -> Double {
            var sse = 0.0
            for y in 0..<height {
                for x in 0..<width {
                    let a = Double(try img.sampleUInt16(x: x, y: y))
                    let b = Double(try decoded.sampleUInt16(x: x, y: y))
                    let d = a - b
                    sse += d * d
                }
            }
            let mse = sse / Double(width * height)
            if mse <= 1e-12 { return 99.0 }
            let peak = 4095.0
            return 10.0 * log10((peak * peak) / mse)
        }

        for coding: CodecOptions.BlockCoding in [.part1, .htj2k] {
            let lowOpts = try CodecOptions(
                decompositionLevels: 4,
                blockCoding: coding,
                wavelet: .irreversible97,
                targetBitsPerPixel: 0.5,
                containerFormat: .codestream
            )
            let highOpts = try CodecOptions(
                decompositionLevels: 4,
                blockCoding: coding,
                wavelet: .irreversible97,
                targetBitsPerPixel: 2.0,
                containerFormat: .codestream
            )
            let lowEnc = try SwiftJ2K.Encoder(configuration: .init(mode: .lossy, codecOptions: lowOpts))
                .encodeSynchronously(img, options: .init(resourceLimits: limits))
            let highEnc = try SwiftJ2K.Encoder(configuration: .init(mode: .lossy, codecOptions: highOpts))
                .encodeSynchronously(img, options: .init(resourceLimits: limits))

            let lowDec = try decoder.decodeSynchronously(lowEnc.data, options: .init(resourceLimits: limits))
            let highDec = try decoder.decodeSynchronously(highEnc.data, options: .init(resourceLimits: limits))

            let lowPSNR = try computePSNR(lowDec.image)
            let highPSNR = try computePSNR(highDec.image)
            #expect(highEnc.data.count > lowEnc.data.count)
            #expect(highPSNR > lowPSNR + 4.0)
            #expect(highPSNR > 45.0)
        }
    }

    /// Pure ISO/IEC 15444-1 Annex A minimal lossless 5/3 (`NL = 1`) single-component 8-bit codestream
    /// with non-zero canvas/tile origin:
    /// - `nonZero3x3 = true`: canvas `[1, 4) x [1, 4)` (`3x3`), `XTOsiz = 1, YTOsiz = 1, XTsiz = 3, YTsiz = 3`, all samples `128` (`0` after DC shift).
    /// - `nonZero3x3 = false`: canvas `[1, 2) x [1, 2)` (`1x1`), `XTOsiz = 1, YTOsiz = 1, XTsiz = 1, YTsiz = 1`, sample `128`.
    private static func makeNonZeroOriginCodestream(threeByThree: Bool) -> Data {
        let endCoord: UInt8 = threeByThree ? 0x04 : 0x02
        let tileDim: UInt8 = threeByThree ? 0x03 : 0x01
        let psot: UInt8 = threeByThree ? 0x10 : 0x0F
        let packetBytes: [UInt8] = threeByThree ? [0x80, 0x80] : [0x80]
        var bytes: [UInt8] = [
            0xFF, 0x4F,                                     // SOC
            0xFF, 0x51, 0x00, 0x29, 0x00, 0x00,             // SIZ (Lsiz=41, Rsiz=0)
            0x00, 0x00, 0x00, endCoord,                     // Xsiz
            0x00, 0x00, 0x00, endCoord,                     // Ysiz
            0x00, 0x00, 0x00, 0x01,                         // XOsiz = 1
            0x00, 0x00, 0x00, 0x01,                         // YOsiz = 1
            0x00, 0x00, 0x00, tileDim,                      // XTsiz
            0x00, 0x00, 0x00, tileDim,                      // YTsiz
            0x00, 0x00, 0x00, 0x01,                         // XTOsiz = 1
            0x00, 0x00, 0x00, 0x01,                         // YTOsiz = 1
            0x00, 0x01, 0x07, 0x01, 0x01,                   // Csiz=1, Ssiz=8-bit unsigned, XRsiz=1, YRsiz=1
            0xFF, 0x52, 0x00, 0x0C, 0x00,                   // COD (Lcod=12, Scod=0)
            0x00, 0x00, 0x01, 0x00,                         // LRCP, 1 layer, no MCT
            0x01, 0x04, 0x04, 0x00, 0x01,                   // NL=1, 64x64 cblk, 5/3 reversible
            0xFF, 0x5C, 0x00, 0x07, 0x20, 0x48, 0x48, 0x48, 0x50, // QCD reversible
            0xFF, 0x90, 0x00, 0x0A, 0x00, 0x00,             // SOT (Isot=0)
            0x00, 0x00, 0x00, psot, 0x00, 0x01,             // Psot, TPsot=0, TNsot=1
            0xFF, 0x93                                      // SOD
        ]
        bytes.append(contentsOf: packetBytes)
        bytes.append(contentsOf: [0xFF, 0xD9])              // EOC
        return Data(bytes)
    }

    @Test("Multi-tile (>1 tile) and non-zero-origin (XOsiz/YOsiz) reduced-resolution decode preserve exact canvas and sample values")
    func multiTileAndNonZeroOriginReducedResolutionDecode() async throws {
        let limits1 = try Self.makeLimits(workers: 1)
        let limits8 = try Self.makeLimits(workers: 8)
        let width = 195
        let height = 131
        let grey = try Self.makeGreyscale16(width: width, height: height, limits: limits8)

        for mode: CompressionMode in [.lossless, .lossy] {
            for coding: CodecOptions.BlockCoding in [.part1, .htj2k] {
                let encOpts = try CodecOptions(
                    decompositionLevels: 3,
                    blockCoding: coding,
                    wavelet: mode == .lossless ? .reversible53 : .irreversible97,
                    quality: mode == .lossless ? nil : 0.90,
                    tileWidth: 64,
                    tileHeight: 64,
                    containerFormat: .codestream
                )
                let enc = try SwiftJ2K.Encoder(configuration: .init(mode: mode, codecOptions: encOpts))
                    .encodeSynchronously(grey, options: .init(resourceLimits: limits8))

                for k in [1, 2] {
                    let expectedW = (width + (1 << k) - 1) >> k
                    let expectedH = (height + (1 << k) - 1) >> k
                    let redDec = try SwiftJ2K.Decoder(
                        configuration: .init(codecOptions: try CodecOptions(resolutionReductionLevels: k))
                    )
                    let async8 = try await redDec.decode(enc.data, options: .init(resourceLimits: limits8))
                    let sync1 = try redDec.decodeSynchronously(enc.data, options: .init(resourceLimits: limits1))
                    #expect(async8.image.descriptor.width == expectedW)
                    #expect(async8.image.descriptor.height == expectedH)
                    let bAsync8 = try async8.image.storage.withUnsafeBytes { Data($0) }
                    let bSync1 = try sync1.image.storage.withUnsafeBytes { Data($0) }
                    #expect(bAsync8 == bSync1)
                }
            }
        }

        // Non-zero canvas origin [1, 4) x [1, 4) (3x3) -> level 1 reduces to [1, 2) x [1, 2) (1x1) with DC-unshifted sample 128
        let shifted3 = Self.makeNonZeroOriginCodestream(threeByThree: true)

        let red1Dec = try SwiftJ2K.Decoder(
            configuration: .init(codecOptions: try CodecOptions(resolutionReductionLevels: 1))
        )
        let inspected3 = try red1Dec.inspect(shifted3, options: .init(resourceLimits: limits8))
        #expect(inspected3.descriptor.width == 1)
        #expect(inspected3.descriptor.height == 1)
        let decoded3 = try await red1Dec.decode(shifted3, options: .init(resourceLimits: limits8))
        #expect(try decoded3.image.sampleUInt16(x: 0, y: 0) == 128)

        // Narrow non-zero canvas [1, 2) x [1, 2) (1x1): ceil(2/2) - ceil(1/2) == 0, so effectiveReduction clamps to 0
        // and must decode pixel 128 rather than returning an uninitialized zero buffer.
        let narrowOdd = Self.makeNonZeroOriginCodestream(threeByThree: false)

        let inspectedNarrow = try red1Dec.inspect(narrowOdd, options: .init(resourceLimits: limits8))
        #expect(inspectedNarrow.descriptor.width == 1)
        #expect(inspectedNarrow.descriptor.height == 1)
        let decodedNarrow = try await red1Dec.decode(narrowOdd, options: .init(resourceLimits: limits8))
        #expect(try decodedNarrow.image.sampleUInt16(x: 0, y: 0) == 128)
    }

    @Test("Vertically causal, multi-segment bypass/terminateAll, and segmentation-symbol EBCOT styles round-trip across odd subband dimensions")
    func causalAndMultiSegmentEBCOTStylesAcrossOddDimensions() async throws {
        let limits = try Self.makeLimits(workers: 4)
        let width = 67
        let height = 53
        let img = try Self.makeGreyscale16(width: width, height: height, limits: limits)
        let origBytes = try img.storage.withUnsafeBytes { Data($0) }
        let decoder = try SwiftJ2K.Decoder()

        let styles: [UInt8] = [
            0x08, // causal
            0x28, // causal + segmentationSymbols
            0x0D, // bypass + terminateAll + causal
            0x2F, // bypass + reset + terminateAll + causal + segmentationSymbols
            0x25  // bypass + terminateAll + segmentationSymbols (!causal)
        ]
        let blockDims: [(Int, Int)] = [(64, 4), (4, 64), (16, 16)]

        for styleBits in styles {
            for (cbw, cbh) in blockDims {
                let losslessOpts = try CodecOptions(
                    decompositionLevels: 4,
                    codeBlockWidth: cbw,
                    codeBlockHeight: cbh,
                    blockCoding: .part1,
                    wavelet: .reversible53,
                    codeBlockStyleBits: styleBits,
                    containerFormat: .codestream
                )
                let enc = try SwiftJ2K.Encoder(configuration: .init(mode: .lossless, codecOptions: losslessOpts))
                    .encodeSynchronously(img, options: .init(resourceLimits: limits))
                let decSync = try decoder.decodeSynchronously(enc.data, options: .init(resourceLimits: limits))
                let decAsync = try await decoder.decode(enc.data, options: .init(resourceLimits: limits))
                let syncBytes = try decSync.image.storage.withUnsafeBytes { Data($0) }
                let asyncBytes = try decAsync.image.storage.withUnsafeBytes { Data($0) }
                #expect(syncBytes == origBytes)
                #expect(asyncBytes == origBytes)
            }

            let lossyOpts = try CodecOptions(
                decompositionLevels: 4,
                codeBlockWidth: 16,
                codeBlockHeight: 16,
                blockCoding: .part1,
                wavelet: .irreversible97,
                targetBitsPerPixel: 2.0,
                codeBlockStyleBits: styleBits,
                containerFormat: .codestream
            )
            let lossyEnc = try SwiftJ2K.Encoder(configuration: .init(mode: .lossy, codecOptions: lossyOpts))
                .encodeSynchronously(img, options: .init(resourceLimits: limits))
            let lossyDec = try decoder.decodeSynchronously(lossyEnc.data, options: .init(resourceLimits: limits))
            #expect(lossyDec.image.descriptor.width == width)
            #expect(lossyDec.image.descriptor.height == height)
        }
    }

    @Test("Extreme 16-bit white-noise and all-zero HTJ2K and Part-1 rate targeting preserves monotonic PSNR and high-slope PCRD bounds")
    func extreme16BitNoiseAndZeroHTJ2KAndPart1RateTargeting() throws {
        let limits = try Self.makeLimits(workers: 4)
        let width = 128
        let height = 128
        let desc16 = try ImageDescriptor.greyscale16(width: width, height: height, meaningfulBits: 16, limits: limits)

        let noisyDest = try ImageDestination.allocate(descriptor: desc16, limits: limits)
        let noisyImg = try noisyDest.writeUInt16 { x, y in
            var s = UInt64((x &* 73856093) ^ (y &* 19349663) ^ 0x9E37_79B9)
            s = (s ^ (s >> 30)) &* 0xBF58_476D_1CE4_E5B9
            s = (s ^ (s >> 27)) &* 0x94D0_49BB_1331_11EB
            s = s ^ (s >> 31)
            return UInt16(truncatingIfNeeded: s)
        }

        let zeroDest = try ImageDestination.allocate(descriptor: desc16, limits: limits)
        let zeroImg = try zeroDest.writeUInt16 { _, _ in 0 }

        let decoder = try SwiftJ2K.Decoder()

        func mse(against ref: Image, decoded: Image) throws -> Double {
            var sse = 0.0
            for y in 0..<height {
                for x in 0..<width {
                    let d = Double(try ref.sampleUInt16(x: x, y: y)) - Double(try decoded.sampleUInt16(x: x, y: y))
                    sse += d * d
                }
            }
            return sse / Double(width * height)
        }

        for coding: CodecOptions.BlockCoding in [.htj2k, .part1] {
            var prevMSE = Double.infinity
            var prevBytes = 0
            for bpp in [0.08, 1.0, 8.5] {
                let opts = try CodecOptions(
                    decompositionLevels: 5,
                    blockCoding: coding,
                    wavelet: .irreversible97,
                    targetBitsPerPixel: bpp,
                    containerFormat: .codestream
                )
                let encoder = try SwiftJ2K.Encoder(configuration: .init(mode: .lossy, codecOptions: opts))
                let enc = try encoder.encodeSynchronously(noisyImg, options: .init(resourceLimits: limits))
                let dec = try decoder.decodeSynchronously(enc.data, options: .init(resourceLimits: limits))
                let curMSE = try mse(against: noisyImg, decoded: dec.image)
                #expect(enc.data.count > prevBytes)
                #expect(curMSE < prevMSE)
                prevBytes = enc.data.count
                prevMSE = curMSE

                let zeroEnc = try encoder.encodeSynchronously(zeroImg, options: .init(resourceLimits: limits))
                let zeroDec = try decoder.decodeSynchronously(zeroEnc.data, options: .init(resourceLimits: limits))
                #expect(try mse(against: zeroImg, decoded: zeroDec.image) == 0.0)
            }
        }
    }

    @Test("Cancelled Task never silently skips non-throwing SIMD pool kernels or leaves convertInt32ToDouble uninitialized")
    func cancelledTaskSIMDAndLossyEncodeSafety() async throws {
        let limits4 = try Self.makeLimits(workers: 4)
        let grey256 = try Self.makeGreyscale16(width: 256, height: 256, limits: limits4)
        let rgb256 = try Self.makeRGB8(width: 256, height: 256, limits: limits4)

        // Prepare reference inputs above all multi-worker thresholds (`count = 40_960 >= 32_768`, `band = 256x128 = 32_768 >= 16_384`)
        let sampleCount = 40_960
        let baseRCT: [[Int32]] = [
            (0..<sampleCount).map { Int32(($0 * 17 + 3) & 0xFF) - 128 },
            (0..<sampleCount).map { Int32(($0 * 31 + 11) & 0xFF) - 128 },
            (0..<sampleCount).map { Int32(($0 * 47 + 29) & 0xFF) - 128 }
        ]
        var refFwdRCT = baseRCT
        var refInvRCT: [[Int32]] = []
        let baseICT: [[Double]] = [
            (0..<sampleCount).map { Double(($0 * 19 + 5) & 0xFF) - 128.0 },
            (0..<sampleCount).map { Double(($0 * 37 + 13) & 0xFF) - 128.0 },
            (0..<sampleCount).map { Double(($0 * 53 + 23) & 0xFF) - 128.0 }
        ]
        var refFwdICT = baseICT
        var refInvICT: [[Double]] = []

        let qWidth = 256
        let qHeight = 128
        let qCount = qWidth * qHeight
        let doubleSrc: [Double] = (0..<qCount).map { idx in
            let v = Double((idx * 73) % 2049) - 1024.0
            return v * 0.375
        }
        let band = BandGeometry(
            orientation: .ll,
            x0: 0, x1: qWidth,
            y0: 0, y1: qHeight,
            planeX: 0, planeY: 0,
            gain: 0,
            quantizationIndex: 0
        )
        var refQ64 = [Int64](repeating: -999, count: qCount)
        var refQ32 = [Int32](repeating: -999, count: qCount)

        AcceleratedCodec.$activeWorkerLimit.withValue(1) {
            SIMDColourTransform.forwardRCT(planes: &refFwdRCT)
            refInvRCT = refFwdRCT
            SIMDColourTransform.inverseRCT(planes: &refInvRCT)

            SIMDColourTransform.forwardICT(planes: &refFwdICT)
            refInvICT = refFwdICT
            SIMDColourTransform.inverseICT(planes: &refInvICT)

            SIMDQuantizationAndROI.quantizeSubband(
                doublePlane: doubleSrc, quantisedPlane: &refQ64,
                stride: qWidth, band: band, step: 0.5, mb: 12
            )
            SIMDQuantizationAndROI.quantizeSubband32(
                doublePlane: doubleSrc, quantisedPlane: &refQ32,
                stride: qWidth, band: band, step: 0.5, mb: 12
            )
        }
        #expect(refInvRCT == baseRCT)

        // Execute inside an actively cancelled Task (`Task.isCancelled == true`, `workers = 4`)
        let cancelledTask = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(Task.isCancelled)

            AcceleratedCodec.$activeWorkerLimit.withValue(4) {
                var candFwdRCT = baseRCT
                SIMDColourTransform.forwardRCT(planes: &candFwdRCT)
                #expect(candFwdRCT == refFwdRCT)

                var candInvRCT = refFwdRCT
                SIMDColourTransform.inverseRCT(planes: &candInvRCT)
                #expect(candInvRCT == refInvRCT)

                var candFwdICT = baseICT
                SIMDColourTransform.forwardICT(planes: &candFwdICT)
                #expect(candFwdICT == refFwdICT)

                var candInvICT = refFwdICT
                SIMDColourTransform.inverseICT(planes: &candInvICT)
                #expect(candInvICT == refInvICT)

                var candQ64 = [Int64](repeating: -999, count: qCount)
                SIMDQuantizationAndROI.quantizeSubband(
                    doublePlane: doubleSrc, quantisedPlane: &candQ64,
                    stride: qWidth, band: band, step: 0.5, mb: 12
                )
                #expect(candQ64 == refQ64)

                var candQ32 = [Int32](repeating: -999, count: qCount)
                SIMDQuantizationAndROI.quantizeSubband32(
                    doublePlane: doubleSrc, quantisedPlane: &candQ32,
                    stride: qWidth, band: band, step: 0.5, mb: 12
                )
                #expect(candQ32 == refQ32)
            }

            // Directly exercise `Array(unsafeUninitializedCapacity: 65_536)` + `BoundedParallelPool.forEachNonThrowing`
            // and `BoundedParallelPool.forEach` under `Task.isCancelled == true`:
            let uninitCount = 65_536
            let srcInt32: [Int32] = (0..<uninitCount).map { Int32(($0 * 29 + 7) - 32_768) }
            let convertedDoubles = [Double](unsafeUninitializedCapacity: uninitCount) { dstBuf, initializedCount in
                srcInt32.withUnsafeBufferPointer { srcBuf in
                    let sSrc = UnsafeSendableBuffer(srcBuf)
                    let sDst = UnsafeSendableMutableBuffer(dstBuf)
                    let chunk = 16_384
                    let chunks = (uninitCount + chunk - 1) / chunk
                    BoundedParallelPool.forEachNonThrowing(jobCount: chunks, maxWorkers: 4) { cIdx in
                        let s = cIdx * chunk
                        let e = min(uninitCount, s + chunk)
                        for i in s..<e { sDst.baseAddress[i] = Double(sSrc.baseAddress[i]) }
                    }
                }
                initializedCount = uninitCount
            }
            #expect(convertedDoubles.count == uninitCount)
            #expect(convertedDoubles.enumerated().allSatisfy { idx, val in !val.isNaN && val == Double(srcInt32[idx]) })
            #expect(throws: CancellationError.self) {
                try BoundedParallelPool.forEach(jobCount: 4, maxWorkers: 4) { _ in }
            }

            // Directly invoke `Part1Pipeline.encode` inside a cancelled Task (bypassing `CodecAPI` entry guards)
            // plus verify `Encoder.encodeSynchronously` / `Encoder.encode` propagate `CancellationError`:
            let nl0GreyOpts = try CodecOptions(
                decompositionLevels: 0,
                blockCoding: .part1,
                wavelet: .irreversible97,
                quality: 0.85,
                containerFormat: .codestream
            )
            let nl0GreyCfg = try EncoderConfiguration(mode: .lossy, codecOptions: nl0GreyOpts)
            #expect(throws: CancellationError.self) {
                _ = try Part1Pipeline.encode(
                    image: grey256,
                    configuration: nl0GreyCfg,
                    limits: limits4,
                    backend: .accelerated,
                    progress: nil
                )
            }
            let nl0GreyEnc = try SwiftJ2K.Encoder(configuration: nl0GreyCfg)
            #expect(throws: CancellationError.self) {
                _ = try nl0GreyEnc.encodeSynchronously(grey256, options: .init(resourceLimits: limits4))
            }

            let nl0RgbOpts = try CodecOptions(
                decompositionLevels: 0,
                blockCoding: .htj2k,
                wavelet: .irreversible97,
                colourTransform: .ict,
                targetBitsPerPixel: 1.0,
                containerFormat: .codestream
            )
            let nl0RgbCfg = try EncoderConfiguration(mode: .lossy, codecOptions: nl0RgbOpts)
            #expect(throws: CancellationError.self) {
                _ = try Part1Pipeline.encode(
                    image: rgb256,
                    configuration: nl0RgbCfg,
                    limits: limits4,
                    backend: .accelerated,
                    progress: nil
                )
            }
            let nl0RgbEnc = try SwiftJ2K.Encoder(configuration: nl0RgbCfg)
            #expect(throws: CancellationError.self) {
                _ = try nl0RgbEnc.encodeSynchronously(rgb256, options: .init(resourceLimits: limits4))
            }
            await #expect(throws: CancellationError.self) {
                _ = try await nl0RgbEnc.encode(rgb256, options: .init(resourceLimits: limits4))
            }
        }
        try await cancelledTask.value

        // Concurrent mid-flight cancellation from a separate task during multi-tile 9/7 HTJ2K RGB encodes
        // (`512x512` split into four `256x256` tiles = `65_536` samples/tile so `convertInt32ToDouble` uses the
        // parallel pool on every tile): must either throw `CancellationError` or finish with a valid codestream.
        let rgb512 = try Self.makeRGB8(width: 512, height: 512, limits: limits4)
        let decoder = try SwiftJ2K.Decoder()
        for nl in [0, 2] {
            let multiTileOpts = try CodecOptions(
                decompositionLevels: nl,
                blockCoding: .htj2k,
                wavelet: .irreversible97,
                colourTransform: .ict,
                targetBitsPerPixel: 1.25,
                tileWidth: 256,
                tileHeight: 256,
                containerFormat: .codestream
            )
            let multiTileEnc = try SwiftJ2K.Encoder(configuration: .init(mode: .lossy, codecOptions: multiTileOpts))
            for delayMicros: UInt64 in [0, 100, 400, 1_500] {
                let job = Task {
                    try await multiTileEnc.encode(rgb512, options: .init(resourceLimits: limits4))
                }
                if delayMicros > 0 {
                    try await Task.sleep(nanoseconds: delayMicros * 1_000)
                }
                job.cancel()
                do {
                    let encoded = try await job.value
                    let decoded = try decoder.decodeSynchronously(encoded.data, options: .init(resourceLimits: limits4))
                    #expect(decoded.image.descriptor.width == 512)
                    #expect(decoded.image.descriptor.height == 512)
                } catch is CancellationError {
                    // Expected deterministic mid-flight cancellation
                }
            }
        }
    }

    @Test("PCRD convex hull rejects zero-byte non-improving or distortion-worsening passes while merging improving zero-byte passes")
    func pcrdConvexHullRejectsNonImprovingZeroBytePasses() {
        // Block 0: Pass 1 = (10B, +100D), Pass 2 = (10B, +100D, deltaR=0 deltaD=0), Pass 3 = (10B, +92D, deltaR=0 deltaD=-8)
        // Must stop at Pass 1 even when budget allows 10B (less than maxBytes across blocks so budget < maxBytes path runs).
        let allocNonImproving = Quantization.allocatePassesPCRD(
            blockPassBytes: [[10, 10, 10], [50]],
            blockPassDistortionReductions: [[100.0, 100.0, 92.0], [10.0]],
            layerByteBudgets: [10, 25]
        )
        #expect(allocNonImproving[0] == [1, 1])
        #expect(allocNonImproving[1] == [0, 0])

        // Block 0: Pass 1 = (10B, +100D), Pass 2 = (10B, +125D, deltaR=0 deltaD=+25) -> merges to Pass 2 at 10B!
        let allocImproving = Quantization.allocatePassesPCRD(
            blockPassBytes: [[10, 10], [50]],
            blockPassDistortionReductions: [[100.0, 125.0], [10.0]],
            layerByteBudgets: [10]
        )
        #expect(allocImproving[0] == [2])
        #expect(allocImproving[1] == [0])
    }
}
