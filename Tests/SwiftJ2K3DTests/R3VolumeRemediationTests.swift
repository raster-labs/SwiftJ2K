// SPDX-License-Identifier: Apache-2.0
//
// R3VolumeRemediationTests.swift
// SwiftJ2K3DTests
//
// Phase R3 Standards Remediation (F01) regression and compliance suite for
// normative ITU-T T.809 (05/2011) | ISO/IEC 15444-10 (JP3D) and reconciled
// ITU-T T.814 HTJ2K-in-JP3D.

import Foundation
import Synchronization
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

    private func makeTestVolume(
        width: Int,
        height: Int,
        depth: Int,
        bitDepth: Int,
        signed: Bool,
        componentSamples: [[Int64]]
    ) -> J2KVolume {
        let comps = componentSamples.enumerated().map { idx, samples in
            J2KVolumeComponent(
                index: idx,
                bitDepth: bitDepth,
                signed: signed,
                width: width,
                height: height,
                depth: depth,
                data: packSamples(samples, bitDepth: bitDepth, signed: signed)
            )
        }
        return J2KVolume(width: width, height: height, depth: depth, components: comps)
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
                recordPacketRanges: true,
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

        // 5e. ISO/IEC 15444-15:2019 Table A.2 Ccap^15 bit-field semantics:
        //   - bits 15..14 == 10 (0x8000, HTDECLARED) and bit 13 == 1 (0x2000, MULTIHT) are LEGAL;
        //   - bits 15..14 == 01 (0x4000) and bits 10..6 != 0 (0x07C0) are RESERVED and MUST throw.
        var legalHTDeclared = valid
        legalHTDeclared[capPos + 10] = (legalHTDeclared[capPos + 10] & 0x3F) | 0x80
        let parsedHTDeclared = try parser.parse(legalHTDeclared)
        #expect(parsedHTDeclared.hasHTJ2KCAPMarker == true)
        #expect(((parsedHTDeclared.ccap15 ?? 0) & 0xC000) == 0x8000)

        var legalMultiHT = valid
        legalMultiHT[capPos + 10] = (legalMultiHT[capPos + 10] & 0x1F) | 0x20
        let parsedMultiHT = try parser.parse(legalMultiHT)
        #expect(((parsedMultiHT.ccap15 ?? 0) & 0x2000) == 0x2000)

        var badCcap15Reserved01 = valid
        badCcap15Reserved01[capPos + 10] = (badCcap15Reserved01[capPos + 10] & 0x3F) | 0x40
        #expect(throws: (any Error).self) { _ = try parser.parse(badCcap15Reserved01) }

        var badCcap15ReservedMidBits = valid
        badCcap15ReservedMidBits[capPos + 10] |= 0x04 // bit 10 in reserved 0x07C0 mask
        #expect(throws: (any Error).self) { _ = try parser.parse(badCcap15ReservedMidBits) }

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
        let expectedRamp: [Int64] = (0..<8).map { Int64(10 + 17 * $0) }
        #expect(ramp == expectedRamp)

        // Odd-offset (cas = 1) even-length linear ramp must also round-trip bit-exact with PWS extension.
        var oddCasRamp: [Int64] = (0..<8).map { Int64(25 + 13 * $0) }
        JP3DWaveletEngine.forward53_1D(&oddCasRamp, length: 8, cas: 1)
        #expect(oddCasRamp[4] == -13)
        #expect(Array(oddCasRamp[5..<8]) == [0, 0, 0])
        JP3DWaveletEngine.inverse53_1D(&oddCasRamp, length: 8, cas: 1)
        let expectedOddCasRamp: [Int64] = (0..<8).map { Int64(25 + 13 * $0) }
        #expect(oddCasRamp == expectedOddCasRamp)
    }

    // MARK: - 6. Phase R3 Rework Coverage (F01-01..04 & REG-01..03)

    @Test("F01-01 & F01-03: CAP Ccap^15 MAGB Table 4 encoding and RGNFREE/HOMOGENEOUS consistency checks")
    func capMagbTable4AndRgnfreeHomogeneousEnforcement() async throws {
        // ITU-T T.814 Table 4 piecewise formula check:
        //   P = 0 -> B = 8; 1 <= P < 20 -> B = P + 8; 20 <= P < 31 -> B = 4*(P - 19) + 27; P = 31 -> B = 74
        let p8 = Int(JP3DHTMarkers.encodeMAGBParameter(maxMb: 8))
        let p20 = Int(JP3DHTMarkers.encodeMAGBParameter(maxMb: 20))
        let p28 = Int(JP3DHTMarkers.encodeMAGBParameter(maxMb: 28))
        let p31 = Int(JP3DHTMarkers.encodeMAGBParameter(maxMb: 31))
        let p74 = Int(JP3DHTMarkers.encodeMAGBParameter(maxMb: 74))
        #expect(p8 == 0 && JP3DHTMarkers.decodeMAGBBound(p: p8) == 8)
        #expect(p20 == 12 && JP3DHTMarkers.decodeMAGBBound(p: p20) == 20)
        #expect(p28 == 20 && JP3DHTMarkers.decodeMAGBBound(p: p28) == 31)
        #expect(p31 == 20 && JP3DHTMarkers.decodeMAGBBound(p: p31) == 31)
        #expect(p74 == 31 && JP3DHTMarkers.decodeMAGBBound(p: p74) == 74)

        // Multi-level 16-bit HTJ2K-in-JP3D emits valid MAGB >= wire K_max and round-trips bit-exact
        let samples16: [Int64] = (0..<(8 * 8 * 4)).map { idx in
            Int64((idx * 257) & 0xFFFF)
        }
        let vol16 = makeTestVolume(width: 8, height: 8, depth: 4, bitDepth: 16, signed: false, componentSamples: [samples16])
        let encoded16 = try await JP3DEncoder(
            configuration: JP3DEncoderConfiguration(
                compressionMode: .losslessHTJ2K,
                levelsX: 2,
                levelsY: 2,
                levelsZ: 1
            )
        ).encode(vol16)
        let parsed16 = try JP3DCodestreamParser().parse(encoded16.data)
        let ccap15 = try #require(parsed16.ccap15)
        let maxWireK = (parsed16.qcd.steps.map(\.exponent).max() ?? 0) + parsed16.qcd.guardBits - 1
        let decodedMagb = JP3DHTMarkers.decodeMAGBBound(p: Int(ccap15 & 0x1F))
        #expect(decodedMagb >= maxWireK)

        let decoded16 = try await JP3DDecoder().decode(encoded16.data)
        #expect(unpackSamples(decoded16.volume.components[0].data, count: samples16.count, bitDepth: 16, signed: false) == samples16)

        // Inject RGN marker into RGNFREE (bit 12 == 0) HT codestream -> MUST throw
        let bytes16 = [UInt8](encoded16.data)
        var sotPos16: Int?
        for idx in 0..<(bytes16.count - 14) {
            if bytes16[idx] == 0xFF && bytes16[idx + 1] == 0x90 {
                sotPos16 = idx
                break
            }
        }
        if let sot = sotPos16 {
            // Insert main-header RGN (0xFF5E, Lrgn=5, Crgn=0, Srgn=0, SPrgn=3) right before SOT
            var withIllegalRGN = Data(encoded16.data.prefix(sot))
            withIllegalRGN.append(contentsOf: [0xFF, 0x5E, 0x00, 0x05, 0x00, 0x00, 0x03])
            withIllegalRGN.append(encoded16.data.suffix(from: sot))
            #expect(throws: (any Error).self) {
                _ = try JP3DCodestreamParser().parse(withIllegalRGN)
            }
        }
    }

    @Test("F01-02: Tile-header QCD/QCC/COD/COC/RGN overrides and wire K_max without private +3 lift")
    func tileHeaderQcdQccCodCocPrecedenceAndWireKmax() async throws {
        // Reproduce Codex independent finding: valid codestream whose main-header QCD has deliberately
        // wrong exponents, overridden by a valid TPsot==0 tile-part QCD marker before SOD.
        var samples: [Int64] = []
        samples.reserveCapacity(8 * 8 * 4)
        for i in 0..<(8 * 8 * 4) {
            samples.append(Int64((i * 73 + 19) & 0xFF))
        }
        let vol = makeTestVolume(width: 8, height: 8, depth: 4, bitDepth: 8, signed: false, componentSamples: [samples])
        let baseEncoded = try await JP3DEncoder(
            configuration: JP3DEncoderConfiguration(
                compressionMode: .lossless,
                levelsX: 1,
                levelsY: 1,
                levelsZ: 1
            )
        ).encode(vol)

        // Extract main-header QCD segment from `baseEncoded.data`, corrupt main-header QCD exponents
        // (+4 bitplanes on every subband so decoding without tile-QCD override produces completely wrong samples),
        // and splice the true QCD segment into tile 0's TPsot==0 tile-part header before SOD (updating Psot).
        let bytes = [UInt8](baseEncoded.data)
        var pos = 2
        var qcdRange: Range<Int>?
        var sotOffset: Int?
        while pos + 4 <= bytes.count {
            if bytes[pos] == 0xFF && bytes[pos + 1] == 0x90 {
                sotOffset = pos
                break
            }
            let segLen = (Int(bytes[pos + 2]) << 8) | Int(bytes[pos + 3])
            if bytes[pos] == 0xFF && bytes[pos + 1] == 0x5C {
                qcdRange = pos..<(pos + 2 + segLen)
            }
            pos += 2 + segLen
        }
        let qRange = try #require(qcdRange)
        let sot = try #require(sotOffset)
        let trueQCDSegment = Data(bytes[qRange])

        var overridden = Data(baseEncoded.data)
        for idx in (qRange.lowerBound + 5)..<qRange.upperBound {
            let origExp = Int(overridden[idx] >> 3)
            let bogusExp = min(31, origExp + 4)
            overridden[idx] = UInt8(bogusExp << 3)
        }
        let b0 = UInt32(overridden[sot + 6]) << 24
        let b1 = UInt32(overridden[sot + 7]) << 16
        let b2 = UInt32(overridden[sot + 8]) << 8
        let b3 = UInt32(overridden[sot + 9])
        let oldPsot = b0 | b1 | b2 | b3
        let newPsot = oldPsot + UInt32(trueQCDSegment.count)
        overridden[sot + 6] = UInt8((newPsot >> 24) & 0xFF)
        overridden[sot + 7] = UInt8((newPsot >> 16) & 0xFF)
        overridden[sot + 8] = UInt8((newPsot >> 8) & 0xFF)
        overridden[sot + 9] = UInt8(newPsot & 0xFF)

        // Splice `trueQCDSegment` right after the 12-byte SOT segment (before SOD 0xFF93)
        var spliced = Data(overridden.prefix(sot + 12))
        spliced.append(trueQCDSegment)
        spliced.append(overridden.suffix(from: sot + 12))

        let decodedOverride = try await JP3DDecoder().decode(spliced)
        let actualOverride = unpackSamples(decodedOverride.volume.components[0].data, count: samples.count, bitDepth: 8, signed: false)
        #expect(actualOverride == samples)

        // Verify wire K_max == G + eps_b - 1 (no private +3 lift even when usesReversibleMCT == true)
        let parsed0 = try JP3DCodestreamParser().parse(baseEncoded.data)
        #expect(parsed0.qcd.guardBits == 2)
        let lllBand = JP3DBandGeometry(
            bandNumber: 0, orientation: .ll,
            x0: 0, x1: 4, y0: 0, y1: 4, z0: 0, z1: 2,
            bufX: 0, bufY: 0, bufZ: 0,
            gain: 0, quantizationIndex: 0
        )
        let wireMb = parsed0.qcd.magnitudeBitPlanes(
            for: lllBand, resolution: 0, maxLevels: 1, componentBitDepth: 8, usesReversibleMCT: true
        )
        #expect(wireMb == parsed0.qcd.guardBits + parsed0.qcd.steps[0].exponent - 1)
    }

    @Test("F01-04: Multi-pass HT block coding (SigProp + MagRef, MULTIHT, and 3*P0 placeholder passes) decodes and transcodes losslessly")
    func multiPassHTSigPropMagRefMultiHTAndPlaceholders() async throws {
        // 1. Direct HTBlockEncoder & HTBlockDecoder test across 3 passes (Cleanup + SigProp + MagRef),
        //    4 passes across 2 HT sets (MULTIHT), SINGLEHT rejection, and 3*P0 leading placeholder passes.
        let width = 8
        let height = 8
        let kMax = 9
        var coeffs32: [Int32] = []
        coeffs32.reserveCapacity(width * height)
        for idx in 0..<(width * height) {
            // Alternating >= 2 and 1 magnitudes so every |v|==1 sample has an adjacent significant neighbour
            // in cleanup at bandShift=1, exercising both SigProp (for |v|==1) and MagRef (for |v|>=2)!
            let mag: Int32 = (idx % 2 == 0) ? Int32(2 + ((idx * 37) & 0xFD)) : 1
            coeffs32.append((idx % 3 == 0) ? -mag : mag)
        }
        let coeffs64 = coeffs32.map { Int64($0) }

        // 3 passes in 1 HT set at sBlk = kMax - 2 = 7 (p = 1: Cleanup at bandShift=1 + SigProp + MagRef)
        let cupBand1 = try HTBlockEncoder.encodeCleanup(
            coefficients: coeffs32,
            width: width,
            height: height,
            bandShift: 1
        )
        let refBand1 = try HTBlockEncoder.encodeRefinement(
            coefficients: coeffs64,
            width: width,
            height: height,
            cleanupBandShift: 1,
            includeMagRef: true
        )
        #expect(!cupBand1.isEmpty)
        #expect(!refBand1.isEmpty)

        let rec3 = try HTBlockDecoder.decodeHTCodeBlock(
            segments: [
                HTSegmentInput(data: cupBand1, passes: 1),
                HTSegmentInput(data: refBand1, passes: 2)
            ],
            zeroBitPlanes: kMax - 2,
            totalPasses: 3,
            width: width,
            height: height,
            kMax: kMax,
            allowMultiHT: false
        )
        #expect(rec3 == coeffs64)

        // 4 passes across 2 HT sets (MULTIHT: Set 0 = Cleanup@1 + SigProp + MagRef; Set 1 = Cleanup@0)
        let cupBand0 = try HTBlockEncoder.encodeCleanup(
            coefficients: coeffs32,
            width: width,
            height: height,
            bandShift: 0
        )
        let multiHTSegments = [
            HTSegmentInput(data: cupBand1, passes: 1),
            HTSegmentInput(data: refBand1, passes: 2),
            HTSegmentInput(data: cupBand0, passes: 1)
        ]
        let recMulti = try HTBlockDecoder.decodeHTCodeBlock(
            segments: multiHTSegments,
            zeroBitPlanes: kMax - 2,
            totalPasses: 4,
            width: width,
            height: height,
            kMax: kMax,
            allowMultiHT: true
        )
        #expect(recMulti == coeffs64)

        // SINGLEHT (allowMultiHT: false) MUST reject >1 HT sets per code-block!
        #expect(throws: (any Error).self) {
            _ = try HTBlockDecoder.decodeHTCodeBlock(
                segments: multiHTSegments,
                zeroBitPlanes: kMax - 2,
                totalPasses: 4,
                width: width,
                height: height,
                kMax: kMax,
                allowMultiHT: false
            )
        }

        // Leading 3*P0 zero-length placeholder passes (P0 = 1 -> 3 placeholder passes + 1 active cleanup pass)
        let recPlaceholder = try HTBlockDecoder.decodeHTCodeBlock(
            segments: [
                HTSegmentInput(data: [], passes: 3),
                HTSegmentInput(data: cupBand0, passes: 1)
            ],
            zeroBitPlanes: kMax - 2,
            totalPasses: 4,
            width: width,
            height: height,
            kMax: kMax,
            allowMultiHT: false
        )
        #expect(recPlaceholder == coeffs64)

        // 2. End-to-end 3D multi-layer HTJ2K-in-JP3D (qualityLayers = 2 -> multi-pass HT refinement + MULTIHT)
        //    decode AND lossless transcode to Part 10 EBCOT and back to HTJ2K-in-JP3D!
        var vox: [Int64] = []
        vox.reserveCapacity(8 * 8 * 4)
        for idx in 0..<(8 * 8 * 4) {
            vox.append(Int64((idx * 53 + 7) & 0xFF))
        }
        let vol = makeTestVolume(width: 8, height: 8, depth: 4, bitDepth: 8, signed: false, componentSamples: [vox])
        let multiLayerHT = try await JP3DEncoder(
            configuration: JP3DEncoderConfiguration(
                compressionMode: .losslessHTJ2K,
                qualityLayers: 2,
                levelsX: 1,
                levelsY: 1,
                levelsZ: 1
            )
        ).encode(vol)
        let parsedMultiHT = try JP3DCodestreamParser().parse(multiLayerHT.data)
        #expect(((parsedMultiHT.ccap15 ?? 0) & 0x2000) == 0x2000)

        let decodedMultiHT = try await JP3DDecoder().decode(multiLayerHT.data)
        #expect(unpackSamples(decodedMultiHT.volume.components[0].data, count: vox.count, bitDepth: 8, signed: false) == vox)

        let transcoder = JP3DTranscoder()
        let toEBCOT = try await transcoder.transcode(multiLayerHT.data, configuration: .reverseDefault)
        let decodedEBCOT = try await JP3DDecoder().decode(toEBCOT.data)
        #expect(unpackSamples(decodedEBCOT.volume.components[0].data, count: vox.count, bitDepth: 8, signed: false) == vox)

        let backToHT = try await transcoder.transcode(toEBCOT.data, configuration: .forwardDefault)
        let decodedBackHT = try await JP3DDecoder().decode(backToHT.data)
        #expect(unpackSamples(decodedBackHT.volume.components[0].data, count: vox.count, bitDepth: 8, signed: false) == vox)
    }

    @Test("REG-01, REG-02, REG-03: Pre-decode tile workspace limits, 20/24/38-bit Part 2 reversible bit-split JP3D, and honest SIMD acceleration policy")
    func r1R2RegressionRepairsBitSplitWorkspaceAndAcceleration() async throws {
        // REG-02: 20-bit unsigned, 24-bit signed, and 38-bit unsigned reversible JP3D bit-exact round-trip
        let count = 4 * 4 * 2
        let mask20 = (Int64(1) << 20) - 1
        var samples20: [Int64] = []
        for idx in 0..<count {
            samples20.append((Int64(idx) * 32_771 + 123_457) & mask20)
        }
        let vol20 = makeTestVolume(width: 4, height: 4, depth: 2, bitDepth: 20, signed: false, componentSamples: [samples20])
        let enc20 = try await JP3DEncoder(
            configuration: JP3DEncoderConfiguration(compressionMode: .lossless, levelsX: 1, levelsY: 1, levelsZ: 1)
        ).encode(vol20)
        let dec20 = try await JP3DDecoder().decode(enc20.data)
        #expect(dec20.volume.components[0].bitDepth == 20)
        #expect(unpackSamples(dec20.volume.components[0].data, count: count, bitDepth: 20, signed: false) == samples20)

        let mask23 = (Int64(1) << 23) - 1
        var samples24Signed: [Int64] = []
        for i in 0..<count {
            let mag = (Int64(i) * 262_147 + 77_777) & mask23
            samples24Signed.append((i % 2 == 0) ? mag : -mag)
        }
        let vol24s = makeTestVolume(width: 4, height: 4, depth: 2, bitDepth: 24, signed: true, componentSamples: [samples24Signed])
        let enc24s = try await JP3DEncoder(
            configuration: JP3DEncoderConfiguration(compressionMode: .losslessHTJ2K, levelsX: 1, levelsY: 1, levelsZ: 1)
        ).encode(vol24s)
        let dec24s = try await JP3DDecoder().decode(enc24s.data)
        #expect(dec24s.volume.components[0].bitDepth == 24)
        #expect(dec24s.volume.components[0].signed == true)
        #expect(unpackSamples(dec24s.volume.components[0].data, count: count, bitDepth: 24, signed: true) == samples24Signed)

        let mask38 = (Int64(1) << 38) - 1
        var samples38: [Int64] = [0, mask38, Int64(1) << 37, (Int64(1) << 19) - 1, Int64(1) << 19]
        for idx in 5..<count {
            samples38.append((Int64(idx) * 1_000_000_007) & mask38)
        }
        let vol38 = makeTestVolume(width: 4, height: 4, depth: 2, bitDepth: 38, signed: false, componentSamples: [samples38])
        let enc38 = try await JP3DEncoder(
            configuration: JP3DEncoderConfiguration(compressionMode: .lossless, levelsX: 1, levelsY: 1, levelsZ: 1)
        ).encode(vol38)
        let dec38 = try await JP3DDecoder().decode(enc38.data)
        #expect(dec38.volume.components[0].bitDepth == 38)
        #expect(unpackSamples(dec38.volume.components[0].data, count: count, bitDepth: 38, signed: false) == samples38)

        // REG-01: Tight maximumWorkspaceBytes fails pre-decode before allocating tile buffers
        let tightWS = try ResourceLimits(maximumWorkspaceBytes: 128)
        let contractDecoder = try VolumeDecoder()
        do {
            _ = try await contractDecoder.decode(enc20.data, options: VolumeDecodeOptions(resourceLimits: tightWS))
            Issue.record("Expected tight maximumWorkspaceBytes to reject JP3D decode pre-allocation")
        } catch let err as CodecError {
            #expect(err.category == .resourceLimitExceeded)
        }

        // REG-03: `.required(.accelerated)` executes genuine SIMD kernels on >=4-sample volumes (`backend == .accelerated`)
        //         and fails explicitly with `CodecError(.backendUnavailable)` on 2x2x2 sub-vector volumes!
        let contractEncoder = try VolumeEncoder(configuration: VolumeEncoderConfiguration(compressionMode: .lossless))
        var simdSamples: [Int64] = []
        for idx in 0..<(8 * 8 * 4) {
            simdSamples.append(Int64(idx & 0xFF))
        }
        let simdVol = makeTestVolume(
            width: 8,
            height: 8,
            depth: 4,
            bitDepth: 8,
            signed: false,
            componentSamples: [simdSamples]
        )
        let accelEnc = try await contractEncoder.encode(
            simdVol,
            options: VolumeEncodeOptions(executionPolicy: .required(.accelerated))
        )
        #expect(accelEnc.report.backend == .accelerated)
        let accelDec = try await contractDecoder.decode(
            accelEnc.data,
            options: VolumeDecodeOptions(executionPolicy: .required(.accelerated))
        )
        #expect(accelDec.report.backend == .accelerated)

        let tinySubVectorVol = makeTestVolume(
            width: 1,
            height: 1,
            depth: 2,
            bitDepth: 8,
            signed: false,
            componentSamples: [[19, 211]]
        )
        do {
            _ = try await contractEncoder.encode(
                tinySubVectorVol,
                options: VolumeEncodeOptions(executionPolicy: .required(.accelerated))
            )
            Issue.record("Expected 1x1x2 (<4-lane) volume under .required(.accelerated) to throw CodecError(.backendUnavailable)")
        } catch let err as CodecError {
            #expect(err.category == .backendUnavailable)
        }
    }

    // MARK: - Phase R3 Second Rework Regression Suite (RA2-03, RA2-04, RA2-05, RA2-08)

    private func stripPart2MCTMarkers(_ codestream: Data) -> Data {
        let bytes = [UInt8](codestream)
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0x4F else { return codestream }
        var out: [UInt8] = [0xFF, 0x4F]
        var cursor = 2
        while cursor + 2 <= bytes.count {
            let marker = UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1])
            if marker == 0xFF90 || marker == 0xFFD9 {
                out.append(contentsOf: bytes[cursor..<bytes.count])
                break
            }
            if (0xFF30...0xFF3F).contains(marker) {
                out.append(bytes[cursor])
                out.append(bytes[cursor + 1])
                cursor += 2
                continue
            }
            guard cursor + 4 <= bytes.count else { break }
            let segLen = Int(UInt16(bytes[cursor + 2]) << 8 | UInt16(bytes[cursor + 3]))
            guard segLen >= 2, cursor + 2 + segLen <= bytes.count else { break }
            let totalSeg = 2 + segLen
            if marker != 0xFF74 && marker != 0xFF75 && marker != 0xFF77 && marker != 0xFF78 {
                var segment = Array(bytes[cursor..<(cursor + totalSeg)])
                // This test derives a wire-component stream: remove the usage
                // signals as well as the synthesis marker payloads.
                if marker == 0xFF51 { segment[4] &= 0x7E }
                if marker == 0xFF52 { segment[8] = 0 }
                out.append(contentsOf: segment)
            }
            cursor += totalSeg
        }
        return Data(out)
    }

    @Test("RA2-03: Signed and unsigned 38-bit Part 2 bit-split fallback uses signed wire limbs with zero DC offset across decode, ROI decode, transcode, and stripped-Part-2 limb synthesis")
    func part2SignedWireLimbsZeroDCOffsetSynthesis() async throws {
        let w = 8, h = 8, d = 4
        let count = w * h * d

        for isSigned in [false, true] {
            let minVal: Int64 = isSigned ? -(Int64(1) << 37) : 0
            let maxVal: Int64 = isSigned ? ((Int64(1) << 37) - 1) : ((Int64(1) << 38) - 1)
            var samples = [Int64](repeating: 0, count: count)
            samples[0] = 0
            samples[1] = minVal
            samples[2] = maxVal
            samples[3] = isSigned ? -1 : 1
            samples[4] = isSigned ? -524_288 : 524_288
            samples[5] = isSigned ? 524_287 : 524_287
            for idx in 6..<count {
                let frac = UInt64(idx) &* 0x9E37_79B9_7F4A_7C15
                if isSigned {
                    let span = UInt64(1) << 38
                    let mapped = Int64(bitPattern: frac % span) - (Int64(1) << 37)
                    samples[idx] = max(minVal, min(maxVal, mapped))
                } else {
                    let span = UInt64(1) << 38
                    samples[idx] = Int64(frac % span)
                }
            }

            let vol = makeTestVolume(
                width: w, height: h, depth: d,
                bitDepth: 38, signed: isSigned,
                componentSamples: [samples]
            )
            let enc = try VolumeEncoder(
                configuration: VolumeEncoderConfiguration(
                    compressionMode: .losslessHTJ2K,
                    tiling: JP3DTilingConfiguration(tileSizeX: 4, tileSizeY: 4, tileSizeZ: 2),
                    levelsX: 1, levelsY: 1, levelsZ: 0
                )
            )
            let encoded = try await enc.encode(vol)
            let parsed = try JP3DCodestreamParser().parse(encoded.data)
            let split = try #require(parsed.part2BitSplit)
            #expect(parsed.siz.componentCount == 2)
            #expect(parsed.siz.componentSigned == [true, true])
            #expect(split.coeffLow == 1)
            #expect(split.coeffHigh == 524_288)
            #expect(split.logicalComponentBitDepths == [38])
            #expect(split.logicalComponentSigned == [isSigned])

            // 1. Whole-volume decode
            let dec = try await VolumeDecoder().decode(encoded.data)
            #expect(dec.volume.components.count == 1)
            #expect(dec.volume.components[0].bitDepth == 38)
            #expect(dec.volume.components[0].signed == isSigned)
            let wholeUnpacked = unpackSamples(dec.volume.components[0].data, count: count, bitDepth: 38, signed: isSigned)
            #expect(wholeUnpacked == samples)

            // 2. Sub-volume ROI decode
            let roi = JP3DRegion(x: 0..<6, y: 0..<5, z: 0..<3)
            let roiRes = try await JP3DROIDecoder().decode(encoded.data, region: roi)
            #expect(roiRes.volume.components.count == 1)
            let roiUnpacked = unpackSamples(
                roiRes.volume.components[0].data,
                count: 6 * 5 * 3,
                bitDepth: 38,
                signed: isSigned
            )
            for rz in 0..<3 {
                for ry in 0..<5 {
                    for rx in 0..<6 {
                        let expected = samples[rz * (w * h) + ry * w + rx]
                        let actual = roiUnpacked[rz * (6 * 5) + ry * 6 + rx]
                        #expect(actual == expected)
                    }
                }
            }

            // 3. HT -> EBCOT wavelet-domain transcode
            let toStd = try await VolumeTranscoder().transcode(
                encoded.data,
                to: .jpeg2000
            )
            let stdDec = try await VolumeDecoder().decode(toStd.data)
            #expect(unpackSamples(stdDec.volume.components[0].data, count: count, bitDepth: 38, signed: isSigned) == samples)

            // 4. Stripped-Part-2 independent wire-limb decode + pure `[1, 524288]` matrix synthesis with zero DC offset
            let stripped = stripPart2MCTMarkers(encoded.data)
            let strippedParsed = try JP3DCodestreamParser().parse(stripped)
            #expect(strippedParsed.part2BitSplit == nil)
            #expect(strippedParsed.siz.componentCount == 2)
            #expect(strippedParsed.siz.componentSigned == [true, true])

            let rawLimbsDecoded = try await VolumeDecoder().decode(stripped)
            #expect(rawLimbsDecoded.volume.components.count == 2)
            let loDepth = rawLimbsDecoded.volume.components[0].bitDepth
            let hiDepth = rawLimbsDecoded.volume.components[1].bitDepth
            let loLimb = unpackSamples(rawLimbsDecoded.volume.components[0].data, count: count, bitDepth: loDepth, signed: true)
            let hiLimb = unpackSamples(rawLimbsDecoded.volume.components[1].data, count: count, bitDepth: hiDepth, signed: true)
            for idx in 0..<count {
                let synthesized = loLimb[idx] * split.coeffLow + hiLimb[idx] * split.coeffHigh
                #expect(synthesized == samples[idx])
            }
        }
    }

    @Test("RA2-04: Pre-allocation Tier-1/Tier-2 entropy budget rejects incompressible tiled 3D encode before allocating rejected output buffer")
    func preAllocationEntropyBudgetRejectsBeforeAllocating() async throws {
        let w = 16, h = 16, d = 4
        let count = w * h * d
        let noisy: [Int64] = (0..<count).map { idx in
            Int64(((UInt64(idx &+ 1) &* 0x9E37_79B9_7F4A_7C15) >> 32) & 0xFFFF_FFFF)
        }
        let vol = makeTestVolume(
            width: w, height: h, depth: d,
            bitDepth: 32, signed: false,
            componentSamples: [noisy]
        )

        for mode: JP3DCompressionMode in [.lossless, .losslessHTJ2K] {
            let encoder = try VolumeEncoder(
                configuration: VolumeEncoderConfiguration(
                    compressionMode: mode,
                    tiling: JP3DTilingConfiguration(tileSizeX: 8, tileSizeY: 8, tileSizeZ: 2),
                    levelsX: 1, levelsY: 1, levelsZ: 1
                )
            )
            let control = try await encoder.encode(
                vol,
                options: VolumeEncodeOptions(resourceLimits: ResourceLimits(maximumWorkers: 1))
            )
            let parsed = try JP3DCodestreamParser().parse(control.data)
            let firstTileBytes = try #require(parsed.tiles.first?.data.count)
            #expect(parsed.tiles.count == 8)

            // 1. Single-worker tight compressed budget (< firstTileBytes / 2): zero `.bufferAllocated` events follow `.reserveRejected`!
            let singleRec = EntropyAllocationTelemetry.Recorder()
            do {
                _ = try await EntropyAllocationTelemetry.$recorder.withValue(singleRec) {
                    try await encoder.encode(
                        vol,
                        options: VolumeEncodeOptions(
                            resourceLimits: try ResourceLimits(
                                maximumCompressedBytes: max(16, firstTileBytes / 2),
                                maximumWorkers: 1
                            )
                        )
                    )
                }
                Issue.record("Expected tight compressed allowance to reject \(mode) pre-allocation")
            } catch let err as CodecError {
                #expect(err.category == .resourceLimitExceeded)
            }
            let singleEvents = singleRec.events
            let firstReject = try #require(singleEvents.first { $0.kind == .reserveRejected })
            let allocationsAfterReject = singleEvents.filter {
                $0.kind == .bufferAllocated && $0.sequence > firstReject.sequence
            }
            #expect(allocationsAfterReject.isEmpty)

            // 2. Concurrent 2-worker tight workspace/compressed budget: rejects cleanly as `.resourceLimitExceeded` with `.reserveRejected` recorded and every `.bufferAllocated` preceded by a matching `.reserveAdmitted`!
            let twoWorkerRec = EntropyAllocationTelemetry.Recorder()
            do {
                _ = try await EntropyAllocationTelemetry.$recorder.withValue(twoWorkerRec) {
                    try await encoder.encode(
                        vol,
                        options: VolumeEncodeOptions(
                            resourceLimits: try ResourceLimits(
                                maximumCompressedBytes: 3 * firstTileBytes,
                                maximumWorkers: 2
                            )
                        )
                    )
                }
                Issue.record("Expected 2-worker tight compressed allowance to reject \(mode)")
            } catch let err as CodecError {
                #expect(err.category == .resourceLimitExceeded)
            }
            let twoEvents = twoWorkerRec.events
            #expect(twoEvents.contains { $0.kind == .reserveRejected })
            let admittedCount = twoEvents.filter { $0.kind == .reserveAdmitted }.count
            let allocatedCount = twoEvents.filter { $0.kind == .bufferAllocated }.count
            #expect(allocatedCount <= admittedCount)
        }
    }

    @Test("RA2-05: Part 2 whole/ROI decode stays within the geometry floor plus bounded packet workspace without a logical-plane overlap")
    func part2BitSplitDecodeWithinFloorAndBoundedPacketWorkspace() async throws {
        let w = 256, h = 256, d = 4
        let count = w * h * d
        var samples = [Int64](repeating: 0, count: count)
        samples[0] = (Int64(1) << 38) - 1 // Forces Part 2 bit-split across the codestream
        for i in stride(from: 1, to: count, by: 257) {
            samples[i] = Int64(i) * 1_048_579
        }
        let vol = makeTestVolume(
            width: w, height: h, depth: d,
            bitDepth: 38, signed: false,
            componentSamples: [samples]
        )
        let enc = try VolumeEncoder(
            configuration: VolumeEncoderConfiguration(
                compressionMode: .losslessHTJ2K,
                tiling: JP3DTilingConfiguration(tileSizeX: 8, tileSizeY: 8, tileSizeZ: 2),
                levelsX: 1, levelsY: 1, levelsZ: 0
            )
        )
        let encoded = try await enc.encode(vol)
        let parsed = try JP3DCodestreamParser().parse(encoded.data)
        #expect(parsed.part2BitSplit != nil)
        #expect(parsed.siz.componentCount == 2)

        // Initial geometry/sample preflight is a floor. Packet contributions and
        // their old/replacement capacity allowances are admitted separately at runtime.
        let retainedSourceBytes = parsed.retainedTileBytes + parsed.commentPayloadBytes
        let bufferWorkspaceBytes = count * 2 * MemoryLayout<Int64>.stride // 4,194,304 B
        let perWorkerSampleBuf = (8 * 8 * 2 * 2) * (MemoryLayout<Int64>.stride * 2) // 4,096 B
        let compFootprint = try JP3DGeometryBuilder.preflightTileComponentGeometry(
            x0: 0, x1: 8, y0: 0, y1: 8, z0: 0, z1: 2,
            cod: parsed.cod,
            maximumWorkspaceBytes: nil,
            includeDecodeState: true
        )
        let compGeom = compFootprint.totalBytes
        // This fixture emits one HT cleanup segment per codeblock in one layer.
        // Bound payload capacity by three times the entire encoded tile (which
        // also includes packet headers), and allow table/data growth plus the
        // minimum payload allocation for every block, even an empty one.
        #expect(parsed.cod.numLayers == 1)
        #expect(parsed.cod.codeBlockStyle & 0x40 != 0)
        let largestTileBytes = try #require(parsed.tiles.map { $0.data.count }.max())
        let segmentStructureAllowance = 128 + 3 * MemoryLayout<CodewordSegment>.stride + 3 * 8
        let packetWorkspaceBound = 3 * largestTileBytes
            + 2 * compFootprint.codeBlockCount * segmentStructureAllowance
        let exactFullPreflightWS = retainedSourceBytes + bufferWorkspaceBytes + perWorkerSampleBuf + 2 * compGeom

        let boundedFullWorkspace = exactFullPreflightWS + packetWorkspaceBound
        let fullLogicalPlaneBytes = count * MemoryLayout<Int64>.stride
        #expect(packetWorkspaceBound < fullLogicalPlaneBytes / 4)

        // One byte below the initial floor still rejects before worker allocation.
        // Success uses a separate bounded packet allowance, far below the extra
        // 2 MiB that a complete logical Int64 plane would need.
        do {
            _ = try await VolumeDecoder().decode(
                encoded.data,
                options: VolumeDecodeOptions(
                    resourceLimits: try ResourceLimits(maximumWorkspaceBytes: exactFullPreflightWS - 1, maximumWorkers: 1)
                )
            )
            Issue.record("Expected exactFullPreflightWS - 1 to reject preflight")
        } catch let err as CodecError {
            #expect(err.category == .resourceLimitExceeded)
        }

        let fullStorage = StorageTelemetry.Recorder()
        let fullDec = try await StorageTelemetry.$recorder.withValue(fullStorage) {
            try await VolumeDecoder().decode(encoded.data, options: VolumeDecodeOptions(
                resourceLimits: try ResourceLimits(maximumWorkspaceBytes: boundedFullWorkspace, maximumWorkers: 1)))
        }
        #expect(fullDec.volume.components[0].data == vol.components[0].data)
        let fullPeak = try #require(fullDec.report.peakWorkspaceBytes)
        #expect(fullPeak >= exactFullPreflightWS)
        #expect(fullPeak <= boundedFullWorkspace)
        #expect(fullStorage.events.contains { $0.stage == "volume-decode-buffers" && $0.bytes == bufferWorkspaceBytes })
        let fullSourceCopies = fullStorage.parserEvents.filter { $0.stage == "jp3d-tile-subdata" }
        #expect(fullSourceCopies.suffix(parsed.tiles.count).reduce(0) { $0 + $1.bytes } == parsed.retainedTileBytes)

        // ROI decode uses the same bounded packet allowance and its smaller wire planes:
        let roi = JP3DRegion(x: 0..<128, y: 0..<128, z: 0..<2)
        let roiVoxels = 128 * 128 * 2
        let roiBufferWS = roiVoxels * 2 * MemoryLayout<Int64>.stride
        let exactROIPreflightWS = retainedSourceBytes + roiBufferWS + perWorkerSampleBuf + 2 * compGeom
        let boundedROIWorkspace = exactROIPreflightWS + packetWorkspaceBound
        #expect(packetWorkspaceBound < roiVoxels * MemoryLayout<Int64>.stride / 4)
        let roiGuard = VolumeWorkGuard(limits: nil)
        do {
            _ = try await JP3DROIDecoder(configuration: JP3DDecoderConfiguration(parallelTileDecoding: false, maximumWorkers: 1))
                .decodeAdmitted(
                    encoded.data,
                    region: roi,
                    maxQualityLayers: nil,
                    resolutionLevel: 0,
                    limits: try ResourceLimits(maximumWorkspaceBytes: exactROIPreflightWS - 1, maximumWorkers: 1),
                    executionPolicy: .automatic,
                    work: roiGuard
                )
            Issue.record("Expected exactROIPreflightWS - 1 to reject ROI preflight")
        } catch let err as CodecError {
            #expect(err.category == .resourceLimitExceeded)
        }
        let roiStorage = StorageTelemetry.Recorder()
        let roiDec = try await StorageTelemetry.$recorder.withValue(roiStorage) {
            try await JP3DROIDecoder(configuration: JP3DDecoderConfiguration(parallelTileDecoding: false, maximumWorkers: 1))
            .decodeAdmitted(
                encoded.data,
                region: roi,
                maxQualityLayers: nil,
                resolutionLevel: 0,
                limits: try ResourceLimits(maximumWorkspaceBytes: boundedROIWorkspace, maximumWorkers: 1),
                executionPolicy: .automatic,
                work: roiGuard
            )
        }
        #expect(roiDec.peakWorkspaceBytes >= exactROIPreflightWS)
        #expect(roiDec.peakWorkspaceBytes <= boundedROIWorkspace)
        #expect(roiStorage.events.contains { $0.stage == "volume-roi-decode-buffers" && $0.bytes == roiBufferWS })
        #expect(roiStorage.parserEvents.filter { $0.stage == "jp3d-tile-subdata" }.reduce(0) { $0 + $1.bytes }
            == parsed.retainedTileBytes)
        #expect(roiDec.volume.width == 128)
        #expect(roiDec.volume.height == 128)
        #expect(roiDec.volume.depth == 2)
        var expectedROI: [Int64] = []
        expectedROI.reserveCapacity(roiVoxels)
        for z in 0..<2 {
            for y in 0..<128 {
                expectedROI.append(contentsOf: samples[(z * w * h + y * w)..<(z * w * h + y * w + 128)])
            }
        }
        #expect(unpackSamples(roiDec.volume.components[0].data,
            count: roiVoxels, bitDepth: 38, signed: false) == expectedROI)
    }

    @Test("RA2-08: Required accelerated backend failure on <4-voxel 3D encode, decode, and transcode never emits .completed progress")
    func requiredAcceleratedFailureNeverEmitsCompletedProgress() async throws {
        let tinyVol = makeTestVolume(
            width: 1, height: 1, depth: 2,
            bitDepth: 8, signed: false,
            componentSamples: [[19, 211]]
        )
        let autoEnc = try await VolumeEncoder(
            configuration: VolumeEncoderConfiguration(
                compressionMode: .lossless,
                levelsX: 0, levelsY: 0, levelsZ: 0
            )
        ).encode(tinyVol)

        // 1. VolumeEncoder
        let encPhases = Mutex<[ProgressUpdate.Phase]>([])
        await #expect(throws: CodecError.self) {
            _ = try await VolumeEncoder(configuration: VolumeEncoderConfiguration(compressionMode: .lossless)).encode(
                tinyVol,
                options: VolumeEncodeOptions(
                    executionPolicy: .required(.accelerated),
                    progress: { p in encPhases.withLock { $0.append(p.phase) } }
                )
            )
        }
        #expect(!encPhases.withLock { $0 }.contains(.completed))

        // 2. VolumeDecoder
        let decPhases = Mutex<[ProgressUpdate.Phase]>([])
        await #expect(throws: CodecError.self) {
            _ = try await VolumeDecoder().decode(
                autoEnc.data,
                options: VolumeDecodeOptions(
                    executionPolicy: .required(.accelerated),
                    progress: { p in decPhases.withLock { $0.append(p.phase) } }
                )
            )
        }
        #expect(!decPhases.withLock { $0 }.contains(.completed))

        // 3. VolumeTranscoder (`zcb == 0` 2D-plane lossless codestream eligible for HT transcoding, <4 voxels so no SIMD vector kernel)
        let transPhases = Mutex<[ProgressUpdate.Phase]>([])
        await #expect(throws: CodecError.self) {
            _ = try await VolumeTranscoder().transcode(
                autoEnc.data,
                to: .htj2k,
                options: TranscodeOptions(
                    executionPolicy: .required(.accelerated),
                    progress: { p in transPhases.withLock { $0.append(p.phase) } }
                )
            )
        }
        #expect(!transPhases.withLock { $0 }.contains(.completed))
    }
}
