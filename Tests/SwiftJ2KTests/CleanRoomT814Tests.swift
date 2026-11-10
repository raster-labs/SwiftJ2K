// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Raster Images Private Limited
//
// Dedicated unit tests for the clean-room ITU-T Rec. T.814 (06/2019) | ISO/IEC 15444-15:2019
// HTJ2K tables, bit-stuffing state machines, segment framing, FBCOT passes, budget rollback,
// and SIMD/Metal cleanup bitstream parity.

import Foundation
import Synchronization
import Testing
@testable import SwiftJ2K

@Suite("Clean-Room ITU-T Rec. T.814 Block Coder")
struct CleanRoomT814Tests {

    @Test("Annex C Tables C.2 and C.3 satisfy Kraft completeness and bijective encode/decode lookup")
    func annexCTablesKraftCompletenessAndBijectiveLookup() {
        #expect(HTBlockEncoder.reversibleGain(subband: .ll) == 0)
        #expect(HTBlockEncoder.reversibleGain(subband: .hl) == 1)
        #expect(HTBlockEncoder.reversibleGain(subband: .lh) == 1)
        #expect(HTBlockEncoder.reversibleGain(subband: .hh) == 2)
        #expect(HTBlockDecoder.maximumExtendedKMax == 62)
        #expect(HTTables.melExponents == [0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 4, 5])
        #expect(HTTables.cxtVLCTable0Spec.count == 444)
        #expect(HTTables.cxtVLCTable1Spec.count == 358)
        #expect(HTTables.cxtVLCDecodeTable0.count == 1024)
        #expect(HTTables.cxtVLCDecodeTable1.count == 1024)
        #expect(HTTables.cxtVLCEncodeTable0.count == 2048)
        #expect(HTTables.cxtVLCEncodeTable1.count == 2048)

        let tablePairs: [(
            name: String,
            spec: [HTTables.CxtVLCSpecTuple],
            decode: [HTTables.CxtVLCDecodeEntry],
            encode: [HTTables.CxtVLCEncodeEntry]
        )] = [
            ("CxtVLC_table_0", HTTables.cxtVLCTable0Spec, HTTables.cxtVLCDecodeTable0, HTTables.cxtVLCEncodeTable0),
            ("CxtVLC_table_1", HTTables.cxtVLCTable1Spec, HTTables.cxtVLCDecodeTable1, HTTables.cxtVLCEncodeTable1)
        ]

        for pair in tablePairs {
            // 1. Verify exact Kraft partition across all 8 contexts (128 slots per context, zero overlaps).
            for context in 0..<8 {
                var covered = [Bool](repeating: false, count: 128)
                var kraftUnits = 0
                for tuple in pair.spec where Int(tuple.context) == context {
                    #expect(tuple.bitLength >= 1 && tuple.bitLength <= 7)
                    #expect(tuple.codeword < (1 << tuple.bitLength))
                    #expect((tuple.embOne & ~tuple.embKnown) == 0)
                    #expect((tuple.embKnown & ~tuple.rho) == 0)
                    if tuple.uOff == 0 {
                        #expect(tuple.embKnown == 0 && tuple.embOne == 0)
                    }
                    let step = 1 << Int(tuple.bitLength)
                    kraftUnits += 128 / step
                    var slot = Int(tuple.codeword)
                    while slot < 128 {
                        #expect(!covered[slot], "\(pair.name) prefix collision in context \(context) at slot \(slot)")
                        covered[slot] = true
                        slot += step
                    }
                }
                #expect(kraftUnits == 128, "\(pair.name) context \(context) Kraft sum != 1")
                #expect(covered.allSatisfy { $0 })
            }

            // 2. Verify every valid encoder input `(context, rho, emb)` round-trips through the 10-bit decode table
            //    for every high-bit suffix `hi` in `0 ..< 2^(7 - bitLength)`.
            for context in 0..<8 {
                for rho in 0..<16 {
                    if context == 0 && rho == 0 {
                        let azc = pair.encode[0]
                        #expect(azc.bitLength == 0 && azc.codeword == 0 && azc.embKnown == 0)
                        continue
                    }
                    for emb in 0..<16 where (emb & ~rho) == 0 {
                        let encIdx = (context << 8) | (rho << 4) | emb
                        let enc = pair.encode[encIdx]
                        #expect(enc.bitLength >= 1 && enc.bitLength <= 7)
                        let expectedUOff: UInt8 = emb == 0 ? 0 : 1
                        let expectedEmbOne = UInt8(emb) & enc.embKnown

                        let highCombinations = 1 << (7 - Int(enc.bitLength))
                        for hi in 0..<highCombinations {
                            let peek7 = Int(enc.codeword) | (hi << Int(enc.bitLength))
                            let dec = pair.decode[(context << 7) | peek7]
                            #expect(dec.rho == UInt8(rho))
                            #expect(dec.uOff == expectedUOff)
                            #expect(dec.embKnown == enc.embKnown)
                            #expect(dec.embOne == expectedEmbOne)
                            #expect(dec.bitLength == enc.bitLength)
                        }
                    }
                }
            }
        }
    }

    @Test("Clause 7.3.6 UVLC Table 3 decomposition, initial-row joint modes, and 62-bit extended u_ext coding")
    func uvlcTable3AndInitialRowJointPairModes() throws {
        // 1. Direct Table 3 verification across u = 0...74:
        #expect(HTTables.encodeUVLC(0) == .empty)
        for u in 1...74 {
            let comp = HTTables.encodeUVLC(u)
            if u == 1 {
                #expect(comp.prefixBits == 0b1 && comp.prefixLength == 1 && comp.suffixLength == 0 && comp.extensionLength == 0)
            } else if u == 2 {
                #expect(comp.prefixBits == 0b10 && comp.prefixLength == 2 && comp.suffixLength == 0 && comp.extensionLength == 0)
            } else if u <= 4 {
                #expect(comp.prefixBits == 0b100 && comp.prefixLength == 3 && comp.suffixLength == 1 && comp.extensionLength == 0)
                #expect(Int(comp.suffixBits) + 3 == u)
            } else if u <= 32 {
                #expect(comp.prefixBits == 0 && comp.prefixLength == 3 && comp.suffixLength == 5 && comp.extensionLength == 0)
                #expect(Int(comp.suffixBits) < 28)
                #expect(5 + Int(comp.suffixBits) == u)
            } else {
                #expect(comp.prefixBits == 0 && comp.prefixLength == 3 && comp.suffixLength == 5 && comp.extensionLength == 4)
                #expect(comp.suffixBits >= 28 && comp.suffixBits <= 31)
                let reconstructed = 5 + Int(comp.suffixBits) + 4 * Int(comp.extensionBits)
                #expect(reconstructed == u)
            }
        }

        // 2. Exercise all three q_y == 0 joint U-VLC pair sub-modes on 4x2 blocks (2 horizontally paired quads):
        //    kappa = 1 on q_y == 0, so u_q = E_q_max - 1:
        //    - Mode A: u0 > 2 && u1 > 2 (joint MEL = 1, encodes u0 - 2 and u1 - 2)
        //    - Mode B: u0 > 2 && u1 in 1...2 (joint MEL = 0, 1-bit u1 - 1 prefix)
        //    - Mode C: u0 in 1...2 && u1 > 2 (joint MEL = 0, standard Table 3 pair)
        let pairCases: [[Int32]] = [
            // Row 0 (4 cols), Row 1 (4 cols) -> q0 = [(0,0),(0,1),(1,0),(1,1)], q1 = [(2,0),(2,1),(3,0),(3,1)]
            [1 << 18, -3, 1 << 22, -7,    5, 0, -9, (1 << 25) - 1], // u0 = 19 > 2, u1 = 25 > 2 (Mode A)
            [1 << 20, -1, 2, 0,           3, -5, -2, 0],            // u0 = 21 > 2, u1 = 1 (Mode B, u1 == 1)
            [1 << 15, 0, 3, -4,           0, -9, 2, 0],             // u0 = 16 > 2, u1 = 2 (Mode B, u1 == 2)
            [2, 0, 1 << 19, -11,          0, 0, 5, -3],             // u0 = 1, u1 = 20 > 2 (Mode C, u0 == 1)
            [3, -4, 1 << 28, -1,          2, 0, -7, 9],             // u0 = 2, u1 = 29 > 2 (Mode C, u0 == 2)
        ]
        for coeffs in pairCases {
            let encoded = try HTBlockEncoder.encodeCleanup(coefficients: coeffs, width: 4, height: 2, bandShift: 0)
            let simdEncoded = try SIMDHTBlockCoder.encodeCleanup(coefficients: coeffs, width: 4, height: 2, bandShift: 0)
            #expect(encoded == simdEncoded)
            let decoded = try HTBlockDecoder.decodeCleanup(block: encoded, width: 4, height: 2, kMax: 30, missingMSBs: 29)
            #expect(decoded == coeffs)
        }

        // 3. Verify odd-QW single-quad tail and extended kMax = 54 (`Int64` magnitudes > 2^32) via decodeHTCodeBlock:
        let oddCoeffs: [Int32] = [
            (1 << 27) - 1, -5, 3, 1 << 24, -(1 << 26),
            7, -9, (1 << 22), 0, 13,
            -1, 2, -(1 << 20), 17, -(1 << 28) + 3
        ]
        let oddEncoded = try HTBlockEncoder.encodeCleanup(coefficients: oddCoeffs, width: 5, height: 3, bandShift: 0)
        let extDecoded = try HTBlockDecoder.decodeHTCodeBlock(
            segments: [HTSegmentInput(data: oddEncoded, passes: 1)],
            zeroBitPlanes: 29,
            totalPasses: 1,
            width: 5,
            height: 3,
            kMax: 54 // bandShift = 54 - 1 - 29 = 24 -> scales 28-bit magnitudes up to 52-bit Int64!
        )
        let expected54 = oddCoeffs.map { Int64($0) << 24 }
        #expect(extDecoded == expected54)
    }

    @Test("Forward/backward bit-stuffing, Scup boundaries, 0xFF80 prefix padding, and malformed segment rejection")
    func forwardAndBackwardBitStuffingAndScupBoundaries() throws {
        func assertNoProhibitedMarkers(_ bytes: [UInt8]) {
            guard !bytes.isEmpty else { return }
            #expect(bytes.last != 0xFF)
            for i in 0..<(bytes.count - 1) where bytes[i] == 0xFF {
                #expect(bytes[i + 1] <= 0x8F, "False marker 0xFF\(String(bytes[i + 1], radix: 16)) at offset \(i)")
            }
        }

        // 1. Minimum Scup == 2 boundary (1x2 single-quad block where MEL + VLC fuse into Dcup[Lcup - 2]):
        let tinyCoeffs: [Int32] = [0, 1]
        let tinyEncoded = try HTBlockEncoder.encodeCleanup(coefficients: tinyCoeffs, width: 1, height: 2)
        #expect(tinyEncoded.count >= 2)
        let tinyScup = (Int(tinyEncoded[tinyEncoded.count - 1]) << 4) | Int(tinyEncoded[tinyEncoded.count - 2] & 0x0F)
        #expect(tinyScup == 2)
        assertNoProhibitedMarkers(tinyEncoded)
        let tinyDecoded = try HTBlockDecoder.decodeCleanup(block: tinyEncoded, width: 1, height: 2, kMax: 4, missingMSBs: 3)
        #expect(tinyDecoded == tinyCoeffs)

        // 2. Force consecutive 0xFF bytes in MagSgn (`v_n = 2*(mu - 1) + sign` all-1s -> negative powers of two)
        //    and dense VLC/MEL activity to exercise 0xFF -> 7-bit forward stuffing, termMSPacker trailing 0xFF
        //    elision, and >0x8F + 0x7F backward VLC stuffing across varied block sizes:
        for count in 1...40 {
            var allOnesCoeffs = [Int32](repeating: 0, count: count * 2)
            for i in 0..<allOnesCoeffs.count {
                // c = -(1 << k) -> mu = 2^k -> v_n = 2*(2^k - 1) + 1 = 2^(k+1) - 1 (all 1-bits in MagSgn!)
                let k = (i % 16) + 1
                allOnesCoeffs[i] = -(Int32(1) << k)
            }
            let block = try HTBlockEncoder.encodeCleanup(coefficients: allOnesCoeffs, width: count, height: 2)
            assertNoProhibitedMarkers(block)
            let lcup = block.count
            let scup = (Int(block[lcup - 1]) << 4) | Int(block[lcup - 2] & 0x0F)
            let pcup = lcup - scup
            #expect(scup >= 2 && scup <= min(lcup, 4079))
            if pcup > 0 {
                #expect(block[pcup - 1] != 0xFF)
            }
            let roundTrip = try HTBlockDecoder.decodeCleanup(block: block, width: count, height: 2, kMax: 20, missingMSBs: 19)
            #expect(roundTrip == allOnesCoeffs)

            // 3. Clause 7.1.2 Note 4 / Annex F.4: unconsumed 0xFF80 padding pairs appended after a
            //    materialized [0xFF, 0x7F] guard (preserving any elided trailing 0xFF at old Pcup) must
            //    not trigger stuff-bit errors when MagSgn does not read into the padding tail:
            if pcup > 0 {
                var padded = Array(block[0..<pcup])
                padded.append(contentsOf: [0xFF, 0x7F, 0xFF, 0x80, 0x00])
                padded.append(contentsOf: block[pcup..<lcup])
                assertNoProhibitedMarkers(padded)
                let paddedDecoded = try HTBlockDecoder.decodeCleanup(
                    block: padded, width: count, height: 2, kMax: 20, missingMSBs: 19
                )
                #expect(paddedDecoded == allOnesCoeffs)
            }
        }

        // 4. Refinement forward (`SigProp`) and backward (`MagRef`) stuffing verification with all-1 refinement bits:
        let refW = 16, refH = 16
        var refCoeffs = [Int64](repeating: 0, count: refW * refH)
        for i in 0..<refCoeffs.count {
            // Alternating cleanup-significant (-7, bit 0 == 1, negative) and SigProp-significant (-1, bit 0 == 1, negative)
            refCoeffs[i] = (i % 2 == 0) ? -7 : -1
        }
        let cup = try HTBlockEncoder.encodeCleanup(
            coefficients: refCoeffs.map { Int32($0) }, width: refW, height: refH, bandShift: 1
        )
        let ref2 = try HTBlockEncoder.encodeRefinement(
            coefficients: refCoeffs, width: refW, height: refH, cleanupBandShift: 1, includeMagRef: false
        )
        let ref3 = try HTBlockEncoder.encodeRefinement(
            coefficients: refCoeffs, width: refW, height: refH, cleanupBandShift: 1, includeMagRef: true
        )
        assertNoProhibitedMarkers(cup)
        assertNoProhibitedMarkers(ref2)
        assertNoProhibitedMarkers(ref3)
        let dec3 = try HTBlockDecoder.decodeHTCodeBlock(
            segments: [HTSegmentInput(data: cup, passes: 1), HTSegmentInput(data: ref3, passes: 2)],
            zeroBitPlanes: 2, totalPasses: 3, width: refW, height: refH, kMax: 4
        )
        #expect(dec3 == refCoeffs)

        // 5. Negative / malformed framing rejections (must throw CodecError(.malformedInput)):
        let malformedCleanupBlocks: [[UInt8]] = [
            [0x02],                             // Lcup == 1 (< 2)
            [0x00, 0xFF],                       // Terminal 0xFF
            [0x01, 0x00],                       // Scup == 1 (< 2)
            [0x05, 0x01],                       // Scup == 21 > Lcup (2)
            [0x0F, 0xFF],                       // Scup == 4095 > 4079 & terminal 0xFF
            [0x00, 0xFF, 0x02, 0x00],           // Pcup == 2, Dcup[Pcup - 1] == 0xFF
            [0xFF, 0x90, 0x00, 0x02, 0x00],     // Prohibited internal marker 0xFF90 > 0xFF8F
            [0xFF, 0x80, 0x0F, 0x02, 0x00]      // Consumed MagSgn byte after 0xFF has MSB stuff bit == 1
        ]
        for bad in malformedCleanupBlocks {
            do {
                _ = try HTBlockDecoder.decodeCleanup(block: bad, width: 4, height: 4, kMax: 8, missingMSBs: 7)
                Issue.record("Expected malformed cleanup block \(bad) to throw CodecError")
            } catch let error as CodecError {
                #expect(error.category == .malformedInput)
            }
        }
    }

    @Test("SigProp/MagRef causal stripe boundaries, fragmented segments, midpoint planes, and budget rollback")
    func cleanupSigPropMagRefCausalMidpointAndMultiHTOrchestration() throws {
        // 1. Causal vs non-causal SigProp boundary across stripe 0 (rows 0...3) and stripe 1 (rows 4...7):
        //    Place a cleanup-significant sample ONLY at row 4, col 2 (top of stripe 1), and a |c|==1 sample
        //    at row 3, col 2 (bottom of stripe 0). Under causal == false, row 3 sees row 4 in SigProp;
        //    under causal == true, row 3 ignores row 4!
        let w = 4, h = 8
        var stripeCoeffs = [Int64](repeating: 0, count: w * h)
        stripeCoeffs[3 * w + 2] = -1 // row 3, col 2: cleanup insignificant at bandShift=1, bit 0 == 1
        stripeCoeffs[4 * w + 2] = 6  // row 4, col 2: cleanup significant at bandShift=1 (6 >> 1 == 3)

        let cup = try HTBlockEncoder.encodeCleanup(
            coefficients: stripeCoeffs.map { Int32($0) }, width: w, height: h, bandShift: 1
        )
        let refNonCausal = try HTBlockEncoder.encodeRefinement(
            coefficients: stripeCoeffs, width: w, height: h, cleanupBandShift: 1, includeMagRef: false, causal: false
        )
        let refCausal = try HTBlockEncoder.encodeRefinement(
            coefficients: stripeCoeffs, width: w, height: h, cleanupBandShift: 1, includeMagRef: false, causal: true
        )

        let decNonCausal = try HTBlockDecoder.decodeHTCodeBlock(
            segments: [HTSegmentInput(data: cup, passes: 1), HTSegmentInput(data: refNonCausal, passes: 1)],
            zeroBitPlanes: 2, totalPasses: 2, width: w, height: h, kMax: 4, causal: false
        )
        let decCausal = try HTBlockDecoder.decodeHTCodeBlock(
            segments: [HTSegmentInput(data: cup, passes: 1), HTSegmentInput(data: refCausal, passes: 1)],
            zeroBitPlanes: 2, totalPasses: 2, width: w, height: h, kMax: 4, causal: true
        )
        #expect(decNonCausal[3 * w + 2] == -1) // Refined in SigProp because row 4 neighbour was visible
        #expect(decCausal[3 * w + 2] == 0)     // Excluded by vertically causal stripe boundary!
        #expect(decNonCausal[4 * w + 2] == 6 && decCausal[4 * w + 2] == 6)

        // 2. Fragmented refinement segments (SigProp 1 pass + MagRef 1 pass split across two codeword segments),
        //    merged 3*P0 + 1 first segment, decodeHTCodeBlockWithPlanes `lastPlanes`, and midpointReconstruction:
        var lossyCoeffs = [Int64](repeating: 0, count: 16)
        lossyCoeffs[0] = 20   // cleanup sig at shift=2 (20 >> 2 = 5), bit 1 = 0 -> MagRef refines plane 1
        lossyCoeffs[1] = -2   // cleanup insig at shift=2, neighbour of [0], bit 1 = 1 -> SigProp refines plane 1
        lossyCoeffs[15] = 12  // cleanup sig at shift=2 (12 >> 2 = 3), bit 1 = 0 -> MagRef refines plane 1
        let cupShift2 = try HTBlockEncoder.encodeCleanup(
            coefficients: lossyCoeffs.map { Int32($0) }, width: 4, height: 4, bandShift: 2
        )
        let refShift2 = try HTBlockEncoder.encodeRefinement(
            coefficients: lossyCoeffs, width: 4, height: 4, cleanupBandShift: 2, includeMagRef: true
        )
        let splitIdx = max(1, refShift2.count / 2)
        let refPartA = Array(refShift2[0..<splitIdx])
        let refPartB = Array(refShift2[splitIdx..<refShift2.count])

        // P0 = 1 merged into first segment (passes = 4), kMax = 8, zeroBitPlanes = 4 -> S_blk = 4 + 1 = 5 -> shift = 8 - 1 - 5 = 2
        let (valsNoMid, planes) = try HTBlockDecoder.decodeHTCodeBlockWithPlanes(
            segments: [
                HTSegmentInput(data: cupShift2, passes: 4),
                HTSegmentInput(data: refPartA, passes: 1),
                HTSegmentInput(data: refPartB, passes: 1)
            ],
            zeroBitPlanes: 4, totalPasses: 6, width: 4, height: 4, kMax: 8
        )
        #expect(valsNoMid[0] == 20 && planes[0] == 1)
        #expect(valsNoMid[1] == -2 && planes[1] == 1)
        #expect(valsNoMid[2] == 0 && planes[2] == -1)
        #expect(valsNoMid[15] == 12 && planes[15] == 1)

        let valsMid = try HTBlockDecoder.decodeHTCodeBlock(
            segments: [
                HTSegmentInput(data: cupShift2, passes: 4),
                HTSegmentInput(data: refPartA, passes: 1),
                HTSegmentInput(data: refPartB, passes: 1)
            ],
            zeroBitPlanes: 4, totalPasses: 6, width: 4, height: 4, kMax: 8, midpointReconstruction: true
        )
        // Since lastPlane == 1 > 0, integer midpoint sets bit (1 - 1) = bit 0 (+1 magnitude on non-zero samples, 0 stays 0):
        #expect(valsMid[0] == 21)
        #expect(valsMid[1] == -3)
        #expect(valsMid[2] == 0)
        #expect(valsMid[15] == 13)

        // 3. Verify EntropyOutputBudget holds exact returned byte count on success and 0 bytes on budget denial:
        let heldCompressed = Mutex(0)
        let heldScratch = Mutex(0)
        let trackingBudget = EntropyOutputBudget(
            reserve: { bytes, countsCompressed, _ in
                if countsCompressed {
                    let next = heldCompressed.withLock { $0 + bytes }
                    if next > 256 {
                        throw CodecError(.resourceLimitExceeded, "Compressed budget cap reached")
                    }
                    heldCompressed.withLock { $0 = next }
                } else {
                    heldScratch.withLock { $0 += bytes }
                }
            },
            release: { bytes, countsCompressed, _ in
                if countsCompressed {
                    heldCompressed.withLock { $0 -= bytes }
                } else {
                    heldScratch.withLock { $0 -= bytes }
                }
            }
        )

        let smallOut = try HTBlockEncoder.encodeCleanup(
            coefficients: [3, -5, 2, 0], width: 2, height: 2, budget: trackingBudget
        )
        #expect(heldCompressed.withLock { $0 } == smallOut.count)
        #expect(heldScratch.withLock { $0 } == 0)
        trackingBudget.release(smallOut.count, countsTowardCompressedOutput: true)
        #expect(heldCompressed.withLock { $0 } == 0)

        var dense64 = [Int32](repeating: 0, count: 64 * 64)
        for i in 0..<dense64.count {
            dense64[i] = Int32(((i * 7919) & 0xFFFF) - 32768)
        }
        #expect(throws: CodecError.self) {
            _ = try HTBlockEncoder.encodeCleanup(
                coefficients: dense64, width: 64, height: 64, budget: trackingBudget
            )
        }
        #expect(heldCompressed.withLock { $0 } == 0)
        #expect(heldScratch.withLock { $0 } == 0)
    }

    @Test("SIMDHTBlockCoder and Metal quad classifier match HTBlockEncoder cleanup bytes across geometries and shifts")
    func simdAndMetalCleanupParityAcrossGeometriesAndBandShifts() throws {
        let geometries = [(1, 1), (3, 5), (7, 9), (16, 16), (33, 17), (64, 64)]
        let shifts = [0, 1, 2, 5, 11]

        var rng: UInt64 = 0xD1B5_4A32_D192_ED03
        func nextWord() -> UInt64 {
            rng ^= rng >> 12
            rng ^= rng << 25
            rng ^= rng >> 27
            return rng &* 0x2545_F491_4F6C_DD1D
        }

        for (w, h) in geometries {
            let count = w * h
            var coeffs = [Int32](repeating: 0, count: count)
            for i in 0..<count {
                let r = nextWord()
                if (r & 3) == 0 {
                    coeffs[i] = 0
                } else {
                    let bits = Int(r % 30)
                    let mag = Int32((UInt32(1) << bits) - 1)
                    coeffs[i] = ((r >> 8) & 1) == 0 ? mag : -mag
                }
            }

            for shift in shifts {
                let scalarBytes = try HTBlockEncoder.encodeCleanup(
                    coefficients: coeffs, width: w, height: h, bandShift: shift
                )
                let simdBytes = try SIMDHTBlockCoder.encodeCleanup(
                    coefficients: coeffs, width: w, height: h, bandShift: shift
                )
                #expect(scalarBytes == simdBytes, "SIMD parity mismatch for \(w)x\(h) shift=\(shift)")

                if AccelerationRuntime.isMetalAvailable {
                    let gpuQuads = try MetalAccelerationEngine.shared.classifyHTQuads(
                        coefficients: coeffs, width: w, height: h, bandShift: shift
                    )
                    let metalBytes = try SIMDHTBlockCoder.encodeCleanup(
                        coefficients: coeffs, width: w, height: h, bandShift: shift, preclassifiedQuads: gpuQuads
                    )
                    #expect(scalarBytes == metalBytes, "Metal parity mismatch for \(w)x\(h) shift=\(shift)")
                }

                let kMax = 31
                let missingMSBs = (kMax - 1) - shift
                let decoded = try HTBlockDecoder.decodeCleanup(
                    block: scalarBytes, width: w, height: h, kMax: kMax, missingMSBs: missingMSBs
                )
                let expected = coeffs.map { c -> Int32 in
                    let shifted = Int32(UInt64(c.magnitude) >> shift) << shift
                    return c < 0 ? -shifted : shifted
                }
                #expect(decoded == expected)
            }
        }
    }
}
