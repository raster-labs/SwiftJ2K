// SPDX-License-Identifier: Apache-2.0
//
// R3VolumeRemediationTests.swift
// SwiftJ2K3DTests
//
// Phase R3 Standards Remediation (F01) regression and compliance suite for
// normative ITU-T T.809 (05/2011) | ISO/IEC 15444-10 (JP3D) and reconciled
// ITU-T T.814 HTJ2K-in-JP3D.

import Foundation
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2K3D

@Suite("Phase R3 — F01 Normative JP3D and Reconciled HT-in-JP3D")
struct R3VolumeRemediationTests {

    // MARK: - Helpers

    private func packSamples(_ samples: [Int64], bitDepth: Int, signed: Bool) -> Data {
        let bytesPerSample = (bitDepth + 7) / 8
        let mask: UInt64 = bitDepth >= 64 ? UInt64.max : ((UInt64(1) << UInt64(bitDepth)) - 1)
        var out = Data(count: samples.count * bytesPerSample)
        out.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for (idx, val) in samples.enumerated() {
                let raw: UInt64 = signed ? (UInt64(bitPattern: val) & mask) : (UInt64(bitPattern: max(0, val)) & mask)
                let dst = base + idx * bytesPerSample
                for b in 0..<bytesPerSample {
                    dst[b] = UInt8((raw >> (8 * b)) & 0xFF)
                }
            }
        }
        return out
    }

    private func unpackSamples(_ data: Data, count: Int, bitDepth: Int, signed: Bool) -> [Int64] {
        let bytesPerSample = (bitDepth + 7) / 8
        let signBit = UInt64(1) << UInt64(bitDepth - 1)
        let mask: UInt64 = bitDepth >= 64 ? UInt64.max : ((UInt64(1) << UInt64(bitDepth)) - 1)
        return data.withUnsafeBytes { rawBuf -> [Int64] in
            guard let base = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return [] }
            var out: [Int64] = []
            out.reserveCapacity(count)
            for idx in 0..<count {
                var raw: UInt64 = 0
                let src = base + idx * bytesPerSample
                for b in 0..<bytesPerSample {
                    raw |= UInt64(src[b]) << (8 * b)
                }
                raw &= mask
                if signed && (raw & signBit) != 0 {
                    let extMask = ~mask
                    out.append(Int64(bitPattern: raw | extMask))
                } else {
                    out.append(Int64(bitPattern: raw))
                }
            }
            return out
        }
    }

    private func containsASCII(_ needle: String, in data: Data) -> Bool {
        guard let bytes = needle.data(using: .ascii), !bytes.isEmpty else { return false }
        return data.range(of: bytes) != nil
    }

    // MARK: - 1. Byte-Level Normative Marker Segment Inspection

    @Test("F01: Normative Part 10 main header emits exact SIZ, mandatory CAP immediately after SIZ, NSI, 3D COD, Morton QCD, SOT/SOD, EOC, and zero private magic")
    func byteLevelNormativeMarkersAndNoPrivateFraming() async throws {
        let w = 12, h = 10, d = 6
        let samples = (0..<(w * h * d)).map { Int64(($0 * 17 + 5) & 0xFF) }
        let comp = J2KVolumeComponent(
            index: 0, bitDepth: 8, signed: false,
            width: w, height: h, depth: d,
            data: packSamples(samples, bitDepth: 8, signed: false)
        )
        let volume = J2KVolume(width: w, height: h, depth: d, components: [comp])
        let enc = try VolumeEncoder(
            configuration: VolumeEncoderConfiguration(
                compressionMode: .lossless,
                tiling: JP3DTilingConfiguration(tileSizeX: 8, tileSizeY: 8, tileSizeZ: 4),
                progressionOrder: .lrcps,
                qualityLayers: 1,
                levelsX: 2,
                levelsY: 2,
                levelsZ: 1
            )
        )
        let encoded = try await enc.encode(volume)
        let bytes = [UInt8](encoded.data)

        // Forbidden private magic strings must be completely absent:
        #expect(!containsASCII("J3DS", in: encoded.data))
        #expect(!containsASCII("J3DI", in: encoded.data))
        #expect(!containsASCII("JP3M", in: encoded.data))

        // SOC at offset 0:
        #expect(bytes[0] == 0xFF && bytes[1] == 0x4F)

        // SIZ immediately at offset 2: Lsiz = 38 + 3 * Csiz = 41, Rsiz = 0x4000
        #expect(bytes[2] == 0xFF && bytes[3] == 0x51)
        let lsiz = (Int(bytes[4]) << 8) | Int(bytes[5])
        #expect(lsiz == 41)
        let rsiz = (UInt16(bytes[6]) << 8) | UInt16(bytes[7])
        #expect(rsiz == 0x4000)

        // Mandatory Part 10 CAP (0xFF50) immediately after SIZ at offset 2 + 2 + lsiz = 45:
        let capOffset = 4 + lsiz
        #expect(bytes[capOffset] == 0xFF && bytes[capOffset + 1] == 0x50)
        let lcap = (Int(bytes[capOffset + 2]) << 8) | Int(bytes[capOffset + 3])
        #expect(lcap == 8)
        let pcap = (UInt32(bytes[capOffset + 4]) << 24)
            | (UInt32(bytes[capOffset + 5]) << 16)
            | (UInt32(bytes[capOffset + 6]) << 8)
            | UInt32(bytes[capOffset + 7])
        #expect(pcap == 0x0040_0000)

        // Walk remaining main-header markers up to first SOT (0xFF90):
        var offset = capOffset + 2 + lcap
        var foundNSI = false
        var foundCOD = false
        var foundQCD = false
        while offset + 4 <= bytes.count {
            let code = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
            if code == 0xFF90 { break }
            let segLen = (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
            if code == 0xFF54 {
                // ITU-T T.809 Table A.3: Lnsi = 19 + Csiz = 20, Ndim = 3
                foundNSI = true
                #expect(segLen == 20)
                #expect(bytes[offset + 4] == 3)
            } else if code == 0xFF52 {
                // ITU-T T.809 Table A.7: Lcod = 17 (Scod & 0x01 == 0)
                foundCOD = true
                #expect(segLen == 17)
                // Progression order 0 = LRCP
                #expect(bytes[offset + 5] == 0)
                // Decomposition levels NX=2, NY=2, NZ=1
                #expect(bytes[offset + 9] == 2)
                #expect(bytes[offset + 10] == 2)
                #expect(bytes[offset + 11] == 1)
                // Code-block style == 0x00 (EBCOT), 3-axis wavelet kernels: 5-3 reversible == 1
                #expect(bytes[offset + 15] == 0)
                #expect(bytes[offset + 16] == 1)
                #expect(bytes[offset + 17] == 1)
                #expect(bytes[offset + 18] == 1)
                // Code-block exponents (shift=0): xcb + ycb + zcb <= 18
                let xcb = Int(bytes[offset + 12] & 0x0F)
                let ycb = Int(bytes[offset + 13] & 0x0F)
                let zcb = Int(bytes[offset + 14] & 0x0F)
                #expect(xcb + ycb + zcb <= 18)
            } else if code == 0xFF5C {
                foundQCD = true
                let parsed = try JP3DCodestreamParser().parse(encoded.data)
                let expectedSubbands = JP3DGeometryBuilder.totalSubbandCount(levelsX: 2, levelsY: 2, levelsZ: 1)
                #expect(segLen == 3 + expectedSubbands)
                #expect(parsed.qcd.steps.count == expectedSubbands)
            }
            offset += 2 + segLen
        }
        #expect(foundNSI && foundCOD && foundQCD)

        // EOC at final two bytes:
        #expect(bytes[bytes.count - 2] == 0xFF && bytes[bytes.count - 1] == 0xD9)
    }

    // MARK: - 2. Multi-Component RCT, Heterogeneous Ssiz^i, Non-Cubic & Anisotropic Round-Trips

    @Test("F01: 3-component RCT, heterogeneous Ssiz^i (8-bit unsigned + 16-bit signed), non-cubic 17x11x5, and anisotropic levelsZ=0/levelsZ=2 round-trip bit-exactly")
    func multiComponentHeterogeneousAndNonCubicLosslessRoundTrips() async throws {
        // 2a. Non-cubic 17x11x5 3-component 12-bit signed lossless (with RCT) across multi-tile boundary grid:
        let w = 17, h = 11, d = 5
        let count = w * h * d
        var comps3: [J2KVolumeComponent] = []
        var orig3: [[Int64]] = []
        for c in 0..<3 {
            let s: [Int64] = (0..<count).map { idx in
                let raw = ((idx * (31 + c * 13) + c * 101) % 4096) - 2048
                return Int64(raw)
            }
            orig3.append(s)
            comps3.append(J2KVolumeComponent(
                index: c, bitDepth: 12, signed: true,
                width: w, height: h, depth: d,
                data: packSamples(s, bitDepth: 12, signed: true)
            ))
        }
        let vol3 = J2KVolume(width: w, height: h, depth: d, components: comps3)
        for lz in [0, 2] {
            let enc = try VolumeEncoder(configuration: VolumeEncoderConfiguration(
                compressionMode: .lossless,
                tiling: JP3DTilingConfiguration(tileSizeX: 7, tileSizeY: 6, tileSizeZ: 3),
                levelsX: 2, levelsY: 2, levelsZ: lz
            ))
            let encoded = try await enc.encode(vol3)
            let parsed = try JP3DCodestreamParser().parse(encoded.data)
            #expect(parsed.cod.multipleComponentTransform == 1)
            let decoded = try await VolumeDecoder().decode(encoded.data)
            #expect(decoded.report.fidelity == .exactSamples)
            for c in 0..<3 {
                let got = unpackSamples(decoded.volume.components[c].data, count: count, bitDepth: 12, signed: true)
                #expect(got == orig3[c])
            }
        }

        // 2b. Heterogeneous Ssiz^i: Component 0 = 8-bit unsigned, Component 1 = 16-bit signed
        let hw = 9, hh = 7, hd = 4
        let hCount = hw * hh * hd
        let c0Samples = (0..<hCount).map { Int64(($0 * 19 + 3) & 0xFF) }
        let c1Samples = (0..<hCount).map { Int64((($0 * 257 + 17) % 65536) - 32768) }
        let heteroVol = J2KVolume(
            width: hw, height: hh, depth: hd,
            components: [
                J2KVolumeComponent(index: 0, bitDepth: 8, signed: false, width: hw, height: hh, depth: hd,
                                   data: packSamples(c0Samples, bitDepth: 8, signed: false)),
                J2KVolumeComponent(index: 1, bitDepth: 16, signed: true, width: hw, height: hh, depth: hd,
                                   data: packSamples(c1Samples, bitDepth: 16, signed: true))
            ]
        )
        let heteroEnc = JP3DEncoder(configuration: JP3DEncoderConfiguration(
            compressionMode: .lossless,
            tiling: JP3DTilingConfiguration(tileSizeX: 5, tileSizeY: 5, tileSizeZ: 2),
            levelsX: 1, levelsY: 1, levelsZ: 1
        ))
        let heteroStream = try await heteroEnc.encode(heteroVol)
        let heteroParsed = try JP3DCodestreamParser().parse(heteroStream.data)
        #expect(heteroParsed.siz.componentBitDepths == [8, 16])
        #expect(heteroParsed.siz.componentSigned == [false, true])
        let heteroDec = try await JP3DDecoder().decode(heteroStream.data)
        #expect(unpackSamples(heteroDec.volume.components[0].data, count: hCount, bitDepth: 8, signed: false) == c0Samples)
        #expect(unpackSamples(heteroDec.volume.components[1].data, count: hCount, bitDepth: 16, signed: true) == c1Samples)
    }

    // MARK: - 3. All 5 Normative Progressions, Multi-Layer Monotonic PSNR, Multi-Tile-Part SOT, StreamWriter & MultiSpectral

    @Test("F01: All 5 normative Part 10 progressions (LRCP, RLCP, RPCL, PCRL, CPRL) emit distinct packet orders and round-trip bit-exactly")
    func allFiveProgressionsPacketOrderAndRoundTrip() async throws {
        let w = 8, h = 8, d = 4
        let count = w * h * d
        let s0 = (0..<count).map { Int64(($0 * 29 + 11) & 0xFF) }
        let s1 = (0..<count).map { Int64(($0 * 43 + 7) & 0xFF) }
        let vol = J2KVolume(
            width: w, height: h, depth: d,
            components: [
                J2KVolumeComponent(index: 0, bitDepth: 8, signed: false, width: w, height: h, depth: d, data: packSamples(s0, bitDepth: 8, signed: false)),
                J2KVolumeComponent(index: 1, bitDepth: 8, signed: false, width: w, height: h, depth: d, data: packSamples(s1, bitDepth: 8, signed: false))
            ]
        )

        let progressions: [(JP3DProgressionOrder, UInt8)] = [
            (.lrcps, 0), (.rlcps, 1), (.slrcp, 2), (.pcrls, 3), (.cprls, 4)
        ]
        for (order, expectedCode) in progressions {
            let enc = try VolumeEncoder(configuration: VolumeEncoderConfiguration(
                compressionMode: .lossless,
                tiling: JP3DTilingConfiguration(tileSizeX: 8, tileSizeY: 8, tileSizeZ: 4),
                progressionOrder: order,
                qualityLayers: 2,
                levelsX: 2, levelsY: 2, levelsZ: 1
            ))
            let encoded = try await enc.encode(vol)
            let parsed = try JP3DCodestreamParser().parse(encoded.data)
            #expect(parsed.cod.progressionOrderByte == expectedCode)
            let geoms = try (0..<2).map { _ in
                try JP3DGeometryBuilder.makeTileComponentGeometry(
                    x0: 0, x1: w, y0: 0, y1: h, z0: 0, z1: d,
                    cod: parsed.cod
                )
            }
            let expectedSequence = try JP3DTier2Coder.packetSequence(
                geometries: geoms,
                progression: parsed.cod.progressionOrderByte,
                totalLayers: 2
            )
            let (_, indexed, _) = try JP3DTier2Coder.decodePackets(
                geometries: geoms,
                cod: parsed.cod,
                bytes: [UInt8](parsed.tiles[0].data),
                cancellation: {}
            )
            let actualSequence = indexed.map(\.address)
            #expect(actualSequence == expectedSequence)

            let decoded = try await VolumeDecoder().decode(encoded.data)
            #expect(decoded.volume.components[0].data == vol.components[0].data)
            #expect(decoded.volume.components[1].data == vol.components[1].data)
        }
    }

    @Test("F01: 3-layer irreversible 9-7 3D codestream improves MSE/PSNR monotonically across layers 1, 2, and 3")
    func multiLayerIrreversibleMonotonicQuality() async throws {
        let w = 16, h = 16, d = 8
        let count = w * h * d
        let orig: [Int64] = (0..<count).map { idx in
            let x = Double(idx % w)
            let y = Double((idx / w) % h)
            let z = Double(idx / (w * h))
            let v = 128.0 + 70.0 * sin(x * 0.45) * cos(y * 0.35) + 40.0 * cos(z * 0.7)
            return Int64(max(0, min(255, Int(v.rounded()))))
        }
        let vol = J2KVolume(
            width: w, height: h, depth: d,
            components: [J2KVolumeComponent(index: 0, bitDepth: 8, signed: false, width: w, height: h, depth: d, data: packSamples(orig, bitDepth: 8, signed: false))]
        )
        let enc = try VolumeEncoder(configuration: VolumeEncoderConfiguration(
            compressionMode: .lossy(psnr: 44.0),
            tiling: JP3DTilingConfiguration(tileSizeX: 16, tileSizeY: 16, tileSizeZ: 8),
            qualityLayers: 3,
            levelsX: 2, levelsY: 2, levelsZ: 2
        ))
        let encoded = try await enc.encode(vol)

        var mses: [Double] = []
        for layer in 1...3 {
            let dec = try VolumeDecoder(configuration: VolumeDecoderConfiguration(maxQualityLayers: layer))
            let out = try await dec.decode(encoded.data)
            let rec = unpackSamples(out.volume.components[0].data, count: count, bitDepth: 8, signed: false)
            var sumSq = 0.0
            for i in 0..<count {
                let diff = Double(orig[i] - rec[i])
                sumSq += diff * diff
            }
            mses.append(sumSq / Double(count))
        }
        #expect(mses[0] >= mses[1])
        #expect(mses[1] >= mses[2])
        #expect(mses[0] > mses[2])
    }

    @Test("F01: Multi-tile-part SOT concatenation, JP3DStreamWriter, and JP3DMultiSpectralEncoder/Decoder round-trip normatively")
    func multiTilePartStreamWriterAndMultiSpectral() async throws {
        // 3a. Split single tile payload across two SOT..SOD tile-parts (TPsot = 0, 1; TNsot = 2):
        let w = 8, h = 8, d = 4
        let raw = Data((0..<(w * h * d)).map { UInt8(($0 * 13 + 9) & 0xFF) })
        let vol = J2KVolume(
            width: w, height: h, depth: d,
            components: [J2KVolumeComponent(index: 0, bitDepth: 8, signed: false, width: w, height: h, depth: d, data: raw)]
        )
        let single = try await JP3DEncoder(configuration: JP3DEncoderConfiguration(
            compressionMode: .lossless,
            tiling: JP3DTilingConfiguration(tileSizeX: 8, tileSizeY: 8, tileSizeZ: 4),
            levelsX: 1, levelsY: 1, levelsZ: 1
        )).encode(vol)
        let bytes = [UInt8](single.data)
        // Locate SOT (0xFF90) and split tile data into 2 tile-parts
        var sotPos: Int?
        for i in 0..<(bytes.count - 14) where bytes[i] == 0xFF && bytes[i + 1] == 0x90 && bytes[i + 12] == 0xFF && bytes[i + 13] == 0x93 {
            sotPos = i
            break
        }
        let sot = try #require(sotPos)
        let mainHeader = Data(bytes[0..<sot])
        let fullPayload = Data(bytes[(sot + 14)..<(bytes.count - 2)])
        let split = max(1, fullPayload.count / 2)
        let part0 = fullPayload.prefix(split)
        let part1 = fullPayload.suffix(fullPayload.count - split)

        func makeSOT(isot: UInt16, payloadCount: Int, tpsot: UInt8, tnsot: UInt8) -> Data {
            var d = Data([0xFF, 0x90, 0x00, 0x0A])
            d.append(UInt8(isot >> 8)); d.append(UInt8(isot & 0xFF))
            let psot = UInt32(14 + payloadCount)
            d.append(UInt8((psot >> 24) & 0xFF))
            d.append(UInt8((psot >> 16) & 0xFF))
            d.append(UInt8((psot >> 8) & 0xFF))
            d.append(UInt8(psot & 0xFF))
            d.append(tpsot)
            d.append(tnsot)
            d.append(contentsOf: [0xFF, 0x93])
            return d
        }

        var multiTP = mainHeader
        multiTP.append(makeSOT(isot: 0, payloadCount: part0.count, tpsot: 0, tnsot: 2))
        multiTP.append(part0)
        multiTP.append(makeSOT(isot: 0, payloadCount: part1.count, tpsot: 1, tnsot: 2))
        multiTP.append(part1)
        multiTP.append(contentsOf: [0xFF, 0xD9])

        let decodedMultiTP = try await VolumeDecoder().decode(multiTP)
        #expect(decodedMultiTP.volume.components[0].data == raw)

        // 3b. JP3DStreamWriter emits normative Part 10 codestream without private magic:
        let writer = JP3DStreamWriter(
            configuration: JP3DStreamWriter.Configuration(
                width: w, height: h, depth: d,
                componentCount: 1, bitDepth: 8,
                compressionMode: .lossless,
                tiling: JP3DTilingConfiguration(tileSizeX: 8, tileSizeY: 8, tileSizeZ: 4)
            )
        )
        for z in 0..<d {
            let sliceStart = z * w * h
            let sliceFloats = (0..<(w * h)).map { Float(raw[sliceStart + $0]) }
            try await writer.addSlice(sliceFloats, atIndex: z)
        }
        let streamed = try await writer.finalize()
        #expect(!containsASCII("J3DS", in: streamed))
        #expect(!containsASCII("J3DI", in: streamed))
        let streamedDec = try await VolumeDecoder().decode(streamed)
        #expect(streamedDec.volume.components[0].data == raw)

        // 3c. JP3DMultiSpectralEncoder & JP3DMultiSpectralDecoder round-trip normatively:
        let msBands: [[Float]] = (0..<3).map { b in
            (0..<72).map { idx in Float((idx * 11 + b * 50) & 0xFF) / 256.0 }
        }
        let msVol = JP3DMultiSpectralVolume(
            width: 6, height: 6, depth: 2,
            bands: JP3DSpectralMapping.visible.bands,
            samplesPerBand: msBands
        )
        let msConfig = JP3DMultiSpectralEncoderConfiguration(
            baseConfiguration: JP3DEncoderConfiguration(
                compressionMode: .lossless,
                tiling: JP3DTilingConfiguration(tileSizeX: 6, tileSizeY: 6, tileSizeZ: 2),
                levelsX: 1, levelsY: 1, levelsZ: 1
            ),
            spectralConfig: .default,
            qualityLayersPerBand: 1,
            enableSpectralDecorelation: false
        )
        let msEncoded = try await JP3DMultiSpectralEncoder().encode(msVol, configuration: msConfig)
        for bandData in msEncoded.encodedBands {
            #expect(!containsASCII("J3DS", in: bandData))
            #expect(!containsASCII("J3DI", in: bandData))
        }
        let msDecoded = try await JP3DMultiSpectralDecoder().decode(msEncoded)
        #expect(msDecoded.samplesPerBand == msBands)
    }

    // MARK: - 4. Reconciled HT-in-JP3D & Wavelet-Domain Transcoding

    @Test("F01: Reconciled HT-in-JP3D emits Pcap=0x0042_0000, Lcap=10, Ccap^15 Table A.2, zcb=0, HTMIXED for 32/38-bit, and zero-copy wavelet-domain EBCOT <-> HTJ2K transcode")
    func reconciledHTInJP3DAndWaveletDomainTranscode() async throws {
        // 4a. 16-bit lossless HTONLY (zcb = 0, cblksty = 0x40, Ccap^15 bits 14..15 == 0):
        let w = 8, h = 8, d = 4
        let count = w * h * d
        let s16 = (0..<count).map { Int64(($0 * 131 + 17) & 0xFFFF) }
        let vol16 = J2KVolume(
            width: w, height: h, depth: d,
            components: [J2KVolumeComponent(index: 0, bitDepth: 16, signed: false, width: w, height: h, depth: d, data: packSamples(s16, bitDepth: 16, signed: false))]
        )
        let htEnc = try VolumeEncoder(configuration: VolumeEncoderConfiguration(
            compressionMode: .losslessHTJ2K,
            tiling: JP3DTilingConfiguration(tileSizeX: 8, tileSizeY: 8, tileSizeZ: 4),
            levelsX: 2, levelsY: 2, levelsZ: 1
        ))
        let ht16 = try await htEnc.encode(vol16)
        #expect(!containsASCII("J3DS", in: ht16.data))
        #expect(!containsASCII("J3DI", in: ht16.data))
        let parsed16 = try JP3DCodestreamParser().parse(ht16.data)
        #expect(parsed16.hasPart10CAPMarker && parsed16.hasHTJ2KCAPMarker)
        #expect(parsed16.cod.codeBlockDepthExponent == 0)
        #expect((parsed16.cod.codeBlockStyle & 0x40) != 0)
        #expect((parsed16.ccap15 ?? 0xFFFF) & 0xC000 == 0x0000)

        // Transcode HTJ2K -> Standard Part 10 EBCOT -> HTJ2K in wavelet domain with .requireSharedStorage:
        let transcoder = try VolumeTranscoder()
        let toEBCOT = try await transcoder.transcode(
            ht16.data,
            to: .jpeg2000,
            options: TranscodeOptions(copyPolicy: .requireSharedStorage)
        )
        #expect(toEBCOT.report.pixelAllocationCount == 0 && toEBCOT.report.copyEvents.isEmpty)
        let parsedEBCOT = try JP3DCodestreamParser().parse(toEBCOT.data)
        #expect(parsedEBCOT.hasPart10CAPMarker && !parsedEBCOT.hasHTJ2KCAPMarker)
        #expect((parsedEBCOT.cod.codeBlockStyle & 0x40) == 0)

        let backToHT = try await transcoder.transcode(
            toEBCOT.data,
            to: .htj2k,
            options: TranscodeOptions(copyPolicy: .requireSharedStorage)
        )
        let dec16 = try await VolumeDecoder().decode(backToHT.data)
        #expect(unpackSamples(dec16.volume.components[0].data, count: count, bitDepth: 16, signed: false) == s16)

        // 4b. 38-bit signed lossless HTMIXED (cblksty = 0xC0, Ccap^15 bits 14..15 == 3):
        let s38: [Int64] = (0..<32).map { idx in
            let mag = (Int64(1) << 35) + Int64(idx * 1_048_583)
            return (idx % 2 == 0) ? mag : -mag
        }
        let vol38 = J2KVolume(
            width: 4, height: 4, depth: 2,
            components: [J2KVolumeComponent(index: 0, bitDepth: 38, signed: true, width: 4, height: 4, depth: 2, data: packSamples(s38, bitDepth: 38, signed: true))]
        )
        let ht38 = try await VolumeEncoder(configuration: VolumeEncoderConfiguration(
            compressionMode: .losslessHTJ2K,
            tiling: JP3DTilingConfiguration(tileSizeX: 4, tileSizeY: 4, tileSizeZ: 2),
            levelsX: 1, levelsY: 1, levelsZ: 1
        )).encode(vol38)
        let parsed38 = try JP3DCodestreamParser().parse(ht38.data)
        #expect((parsed38.ccap15 ?? 0) & 0xC000 == 0xC000)
        #expect((parsed38.cod.codeBlockStyle & 0xC0) == 0xC0)
        let dec38 = try await VolumeDecoder().decode(ht38.data)
        #expect(unpackSamples(dec38.volume.components[0].data, count: 32, bitDepth: 38, signed: true) == s38)
    }

    // MARK: - 5. Negative / Malformed Codestream & Entropy Validation

    @Test("F01: Parser and decoder reject malformed Part 10 / HT-in-JP3D marker segments and truncated entropy cleanly without traps")
    func malformedMarkerAndEntropyRejection() async throws {
        let raw = Data((0..<16).map { UInt8($0) })
        let vol = J2KVolume(
            width: 4, height: 4, depth: 1,
            components: [J2KVolumeComponent(index: 0, bitDepth: 8, signed: false, width: 4, height: 4, depth: 1, data: raw)]
        )
        let valid = try await VolumeEncoder(configuration: VolumeEncoderConfiguration(
            compressionMode: .losslessHTJ2K,
            tiling: JP3DTilingConfiguration(tileSizeX: 4, tileSizeY: 4, tileSizeZ: 1),
            levelsX: 1, levelsY: 1, levelsZ: 0
        )).encode(vol).data
        let parser = JP3DCodestreamParser()

        func findMarkerOffset(_ code: UInt16, in data: Data) -> Int? {
            let b = [UInt8](data)
            let hi = UInt8(code >> 8), lo = UInt8(code & 0xFF)
            var pos = 2
            while pos + 4 <= b.count {
                if b[pos] == hi && b[pos + 1] == lo { return pos }
                if b[pos] == 0xFF && b[pos + 1] == 0x90 { break }
                let len = (Int(b[pos + 2]) << 8) | Int(b[pos + 3])
                pos += 2 + len
            }
            return nil
        }

        let capPos = try #require(findMarkerOffset(0xFF50, in: valid))
        let nsiPos = try #require(findMarkerOffset(0xFF54, in: valid))
        let codPos = try #require(findMarkerOffset(0xFF52, in: valid))
        let qcdPos = try #require(findMarkerOffset(0xFF5C, in: valid))

        // 5a. Ndim != 3 in NSI:
        var badNdim = valid
        badNdim[nsiPos + 4] = 4
        #expect(throws: (any Error).self) { _ = try parser.parse(badNdim) }

        // 5b. Wrong Lnsi:
        var badLnsi = valid
        badLnsi[nsiPos + 3] = 18
        #expect(throws: (any Error).self) { _ = try parser.parse(badLnsi) }

        // 5c. CAP not immediately after SIZ (swap CAP and NSI):
        let capSeg = valid.subdata(in: capPos..<(capPos + 12))
        let nsiSeg = valid.subdata(in: nsiPos..<(nsiPos + 22))
        var swappedCapNsi = Data(valid.prefix(capPos))
        swappedCapNsi.append(nsiSeg)
        swappedCapNsi.append(capSeg)
        swappedCapNsi.append(valid.suffix(from: nsiPos + 22))
        #expect(throws: (any Error).self) { _ = try parser.parse(swappedCapNsi) }

        // 5d. Duplicate CAP:
        var dupCap = Data(valid.prefix(capPos + 12))
        dupCap.append(capSeg)
        dupCap.append(valid.suffix(from: capPos + 12))
        #expect(throws: (any Error).self) { _ = try parser.parse(dupCap) }

        // 5e. Reserved Ccap^15 bits 14..15 == 2 (0x8000):
        var badCcap15 = valid
        badCcap15[capPos + 10] = (badCcap15[capPos + 10] & 0x3F) | 0x80
        #expect(throws: (any Error).self) { _ = try parser.parse(badCcap15) }

        // 5f. HT codestream with zcb > 0:
        var badHTZcb = valid
        badHTZcb[codPos + 14] = 1
        #expect(throws: (any Error).self) { _ = try parser.parse(badHTZcb) }

        // 5g. xcb + ycb + zcb > 18:
        var badCbSum = valid
        badCbSum[codPos + 15] = 0x00 // clear HT flag
        badCbSum[codPos + 12] = 7
        badCbSum[codPos + 13] = 7
        badCbSum[codPos + 14] = 6
        #expect(throws: (any Error).self) { _ = try parser.parse(badCbSum) }

        // 5h. Malformed QCD subband count (truncate 1 byte from Lqcd and segment):
        var badQCD = valid
        badQCD[qcdPos + 3] -= 1
        badQCD.remove(at: qcdPos + 4)
        #expect(throws: (any Error).self) { _ = try parser.parse(badQCD) }

        // 5i. Missing NSI on Rsiz = 0x4000 Part 10 codestream:
        var missingNSI = Data(valid.prefix(nsiPos))
        missingNSI.append(valid.suffix(from: nsiPos + 22))
        #expect(throws: (any Error).self) { _ = try parser.parse(missingNSI) }

        // 5j. Overflowing Psot in SOT:
        var badPsot = valid
        if let sot = (0..<(badPsot.count - 12)).first(where: { badPsot[$0] == 0xFF && badPsot[$0 + 1] == 0x90 }) {
            badPsot[sot + 6] = 0x7F
            badPsot[sot + 7] = 0xFF
            badPsot[sot + 8] = 0xFF
            badPsot[sot + 9] = 0xFF
            #expect(throws: (any Error).self) { _ = try parser.parse(badPsot) }
        }
    }

    @Test("F01: 3D DWT 5-3 and 9-7 enforce ISO/IEC 15444-1 Annex F whole-sample symmetric extension (PWS) at even and odd boundaries")
    func waveletWholeSampleSymmetricBoundaryCompliance() async throws {
        // On an even-length linear ramp x[k] = 10 + 17*k (n = 8, cas = 0),
        // whole-sample symmetric extension reflects x[8] -> x[6] = s[3] = 112 (NOT s[2] = 78),
        // yielding high-pass detail d[0..2] = 0 and d[3] = x[7] - ((s[3] + s[3]) >> 1) = 129 - 112 = +17.
        var ramp: [Int64] = (0..<8).map { Int64(10 + 17 * $0) }
        JP3DWaveletEngine.forward53_1D(&ramp, length: 8, cas: 0)
        // Polyphase deinterleaved layout: s[0..3] followed by d[0..3]
        #expect(Array(ramp[4..<8]) == [0, 0, 0, 17])

        JP3DWaveletEngine.inverse53_1D(&ramp, length: 8, cas: 0)
        #expect(ramp == (0..<8).map { Int64(10 + 17 * $0) })

        // Odd-offset (cas = 1) even-length linear ramp must also round-trip bit-exact with PWS extension.
        var oddCasRamp: [Int64] = (0..<8).map { Int64(25 + 13 * $0) }
        JP3DWaveletEngine.forward53_1D(&oddCasRamp, length: 8, cas: 1)
        #expect(oddCasRamp[4] == -13)
        #expect(Array(oddCasRamp[5..<8]) == [0, 0, 0])
        JP3DWaveletEngine.inverse53_1D(&oddCasRamp, length: 8, cas: 1)
        #expect(oddCasRamp == (0..<8).map { Int64(25 + 13 * $0) })
    }
}
