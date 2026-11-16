// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Raster Images Private Limited
//
// High-Throughput JPEG 2000 (HTJ2K) block encoder and decoder implemented from
// first principles per ITU-T Rec. T.814 (06/2019) | ISO/IEC 15444-15:2019
// (Clauses 7.1–7.6, Annex B, Annex C, and Annex F).

/// Input codeword segment descriptor for multi-pass / multi-set HTJ2K code-block decoding (Annex B.2–B.3).
package struct HTSegmentInput: Sendable, Equatable {
    package let data: [UInt8]
    package let passes: Int

    package init(data: [UInt8], passes: Int) {
        self.data = data
        self.passes = passes
    }
}

// MARK: - Budget-Admitted Byte Stream Buffer

/// Growable byte stream that enforces both `maximumBytes` and pre-allocation `EntropyOutputBudget`
/// reservations before growing storage.
private struct AdmittedByteStream {
    var bytes: [UInt8] = []
    let maximumBytes: Int
    let budget: EntropyOutputBudget?
    let site: String
    var reservedBytes: Int = 0
    var overflowed: Bool = false

    init(maximumBytes: Int, budget: EntropyOutputBudget?, site: String, capacityHint: Int = 64) {
        self.maximumBytes = max(0, maximumBytes)
        self.budget = budget
        self.site = site
        if budget == nil {
            let initial = min(capacityHint, self.maximumBytes)
            if initial > 0 {
                bytes.reserveCapacity(initial)
            }
        }
    }

    @inline(__always)
    mutating func append(_ byte: UInt8) {
        guard !overflowed, bytes.count < maximumBytes else {
            overflowed = true
            return
        }
        if let budget, bytes.count >= reservedBytes {
            let chunk = min(64, max(1, maximumBytes - reservedBytes))
            let overlapSite = "\(site)-overlap"
            do {
                if reservedBytes > 0 {
                    try budget.reserve(reservedBytes, countsTowardCompressedOutput: false, site: overlapSite)
                }
                defer {
                    if reservedBytes > 0 {
                        budget.release(reservedBytes, countsTowardCompressedOutput: false, site: overlapSite)
                    }
                }
                try budget.reserve(chunk, countsTowardCompressedOutput: true, site: site)
                budget.recordActualAllocation(chunk, site: site)
                bytes.reserveCapacity(reservedBytes + chunk)
            } catch {
                overflowed = true
                return
            }
            reservedBytes += chunk
        }
        bytes.append(byte)
    }

    @inline(__always)
    mutating func popLast() {
        _ = bytes.popLast()
    }

    mutating func releaseAll() {
        if let budget, reservedBytes > 0 {
            budget.release(reservedBytes, countsTowardCompressedOutput: true, site: "\(site)-rollback")
            reservedBytes = 0
        }
        bytes = []
    }

    mutating func detachAfterTransfer() {
        reservedBytes = 0
        bytes = []
    }
}

// MARK: - Encoder Bit-Stream Packers (ITU-T Rec. T.814 Annex F.3–F.4)

/// Forward little-endian bit-stuffed MagSgn byte-stream packer (`initMSPacker` / `emitMagSgnBits` / `termMSPacker`, Annex F.4).
private struct MagSgnForwardPacker {
    var stream: AdmittedByteStream
    private var partialBits: UInt64 = 0
    private var bitCount: Int = 0
    private var maxBitsInByte: Int = 8

    init(maximumBytes: Int, budget: EntropyOutputBudget?) {
        self.stream = AdmittedByteStream(
            maximumBytes: maximumBytes,
            budget: budget,
            site: "ht-magsgn-chunk",
            capacityHint: 128
        )
    }

    @inline(__always)
    mutating func emitBits(value: UInt32, count: Int) {
        guard count > 0 else { return }
        let mask = (UInt64(1) << count) - 1
        partialBits |= (UInt64(value) & mask) << bitCount
        bitCount += count
        if bitCount >= 32 && maxBitsInByte == 8 {
            let word = UInt32(truncatingIfNeeded: partialBits)
            let inv = ~word
            if ((inv &- 0x0101_0101) & word & 0x8080_8080) == 0 {
                stream.append(UInt8(truncatingIfNeeded: word))
                stream.append(UInt8(truncatingIfNeeded: word >> 8))
                stream.append(UInt8(truncatingIfNeeded: word >> 16))
                stream.append(UInt8(truncatingIfNeeded: word >> 24))
                partialBits >>= 32
                bitCount -= 32
            }
        }
        while bitCount >= maxBitsInByte {
            let byteMask = (UInt64(1) << maxBitsInByte) - 1
            let outByte = UInt8(partialBits & byteMask)
            stream.append(outByte)
            partialBits >>= maxBitsInByte
            bitCount -= maxBitsInByte
            maxBitsInByte = (outByte == 0xFF) ? 7 : 8
        }
    }

    /// Terminates the MagSgn byte-stream per `termMSPacker` (Annex F.4, p. 66), ensuring no trailing `0xFF` remains.
    mutating func terminate() {
        if bitCount > 0 {
            let padCount = maxBitsInByte - bitCount
            let padOnes = ((UInt64(1) << padCount) - 1) << bitCount
            let finalByte = UInt8(partialBits | padOnes)
            if finalByte != 0xFF {
                stream.append(finalByte)
            }
            partialBits = 0
            bitCount = 0
            maxBitsInByte = 8
        } else if maxBitsInByte == 7 {
            // Discard trailing 0xFF; decoder's importMagSgnBit synthesizes 0xFF at Pcup (Clause 7.1.2 Note 3).
            stream.popLast()
            maxBitsInByte = 8
        }
    }
}

/// Adaptive MEL run-length encoder and forward big-endian bit-stuffed byte-stream packer
/// (`initMELEncoder` / `encodeMEL` / `termMEL` & `initMELPacker` / `emitMELBit`, Annex F.3–F.4).
private struct MELForwardPacker {
    var stream: AdmittedByteStream
    private var stateIndex: Int = 0
    private var runCount: Int = 0
    private var runThreshold: Int = 1 // 1 << melExponents[0]
    fileprivate var partialByte: UInt8 = 0
    fileprivate var remainingBits: Int = 8

    init(maximumBytes: Int, budget: EntropyOutputBudget?) {
        self.stream = AdmittedByteStream(
            maximumBytes: maximumBytes,
            budget: budget,
            site: "ht-mel-chunk",
            capacityHint: 32
        )
    }

    @inline(__always)
    private mutating func emitBit(_ bit: Int) {
        partialByte = (partialByte << 1) | UInt8(bit & 1)
        remainingBits -= 1
        if remainingBits == 0 {
            stream.append(partialByte)
            remainingBits = (partialByte == 0xFF) ? 7 : 8
            partialByte = 0
        }
    }

    @inline(__always)
    mutating func encodeSymbol(_ symbol: Int) {
        if symbol == 0 {
            runCount += 1
            if runCount >= runThreshold {
                emitBit(1)
                runCount = 0
                if stateIndex < 12 {
                    stateIndex += 1
                }
                runThreshold = 1 << HTTables.melExponents[stateIndex]
            }
        } else {
            emitBit(0)
            var exponent = HTTables.melExponents[stateIndex]
            while exponent > 0 {
                exponent -= 1
                emitBit((runCount >> exponent) & 1)
            }
            runCount = 0
            if stateIndex > 0 {
                stateIndex -= 1
            }
            runThreshold = 1 << HTTables.melExponents[stateIndex]
        }
    }

    mutating func terminateSymbols() {
        if runCount > 0 {
            emitBit(1)
            runCount = 0
        }
    }
}

/// Backward-growing little-endian bit-stuffed VLC byte-stream packer (`initVLCPacker` / `emitVLCBits`, Annex F.4).
/// Bytes are appended in emission order and reversed into the suffix of `Dcup` during segment assembly.
private struct VLCBackwardPacker {
    var stream: AdmittedByteStream
    fileprivate var usedBits: Int = 4
    fileprivate var partialByte: UInt8 = 0x0F
    private var lastByte: UInt8 = 0xFF

    init(maximumBytes: Int, budget: EntropyOutputBudget?) {
        self.stream = AdmittedByteStream(
            maximumBytes: maximumBytes,
            budget: budget,
            site: "ht-vlc-chunk",
            capacityHint: 64
        )
        // Reserved slot for Dcup[Lcup - 1] = Scup >> 4 (`initVLCPacker`: VLC_buf[0] = 255).
        self.stream.append(0xFF)
    }

    @inline(__always)
    mutating func emitBits(_ codeword: UInt8, count: Int) {
        if count <= 0 { return }
        if (lastByte <= 0x8F && usedBits + count < 8) || (usedBits + count < 7) {
            let mask: UInt8 = (UInt8(1) << count) - 1
            partialByte |= (codeword & mask) << usedBits
            usedBits += count
            return
        }
        var cwd = codeword
        var rem = count
        while rem > 0 {
            let bit = cwd & 1
            cwd >>= 1
            rem -= 1
            partialByte |= (bit << usedBits)
            usedBits += 1
            if lastByte > 0x8F && partialByte == 0x7F {
                usedBits += 1
            }
            if usedBits == 8 {
                stream.append(partialByte)
                lastByte = partialByte
                partialByte = 0
                usedBits = 0
            }
        }
    }
}

/// Forward little-endian bit-stuffed SigProp packer (`initSPPacker` / `emitSPBit` / `termSPPacker`, Annex F.4).
private struct SigPropForwardPacker {
    var stream: AdmittedByteStream
    fileprivate var partialByte: UInt8 = 0
    fileprivate var usedBits: Int = 0
    fileprivate var maxBitsInByte: Int = 8

    init(maximumBytes: Int, budget: EntropyOutputBudget?) {
        self.stream = AdmittedByteStream(
            maximumBytes: maximumBytes,
            budget: budget,
            site: "ht-sigprop-chunk",
            capacityHint: 32
        )
    }

    @inline(__always)
    mutating func emitBit(_ bit: Int) {
        partialByte |= UInt8(bit & 1) << usedBits
        usedBits += 1
        if usedBits == maxBitsInByte {
            stream.append(partialByte)
            maxBitsInByte = (partialByte == 0xFF) ? 7 : 8
            partialByte = 0
            usedBits = 0
        }
    }

    /// Terminates a SigProp-only refinement segment per `termSPPacker` (Annex F.4, p. 70).
    mutating func terminateStandalone() {
        if partialByte != 0 {
            stream.append(partialByte)
            maxBitsInByte = (partialByte == 0xFF) ? 7 : 8
            partialByte = 0
            usedBits = 0
        }
        if maxBitsInByte == 7 {
            // Prevent terminal 0xFF byte (Clause 7.1.1).
            stream.append(0x00)
            maxBitsInByte = 8
        }
    }
}

/// Backward-growing little-endian bit-stuffed MagRef packer (`initMRPacker` / `emitMRBit`, Annex F.4).
private struct MagRefBackwardPacker {
    var stream: AdmittedByteStream
    fileprivate var partialByte: UInt8 = 0
    fileprivate var usedBits: Int = 0
    private var lastByte: UInt8 = 0xFF

    init(maximumBytes: Int, budget: EntropyOutputBudget?) {
        self.stream = AdmittedByteStream(
            maximumBytes: maximumBytes,
            budget: budget,
            site: "ht-magref-chunk",
            capacityHint: 32
        )
    }

    @inline(__always)
    mutating func emitBit(_ bit: Int) {
        partialByte |= UInt8(bit & 1) << usedBits
        usedBits += 1
        if lastByte > 0x8F && partialByte == 0x7F {
            usedBits += 1
        }
        if usedBits == 8 {
            stream.append(partialByte)
            lastByte = partialByte
            partialByte = 0
            usedBits = 0
        }
    }
}

// MARK: - Geometry Validation Helper

@inline(__always)
private func validateBlockGeometry(width: Int, height: Int, caller: String) throws -> Int {
    guard width >= 1, height >= 1, width <= 4096, height <= 4096 else {
        throw CodecError(.invalidArgument, "\(caller): invalid HTJ2K block dimensions (\(width)x\(height)).")
    }
    let (sampleCount, overflow) = width.multipliedReportingOverflow(by: height)
    guard !overflow, sampleCount <= 4096 * 4096 else {
        throw CodecError(.invalidArgument, "\(caller): HTJ2K block sample count overflows bounds.")
    }
    return sampleCount
}

// MARK: - HTBlockEncoder

package enum HTBlockEncoder {

    /// Returns the ISO/IEC 15444-1 Annex E Table E.1 reversible subband log2 gain.
    package static func reversibleGain(subband: BandOrientation) -> Int {
        switch subband {
        case .ll: return 0
        case .hl, .lh: return 1
        case .hh: return 2
        }
    }

    /// Encodes a single HT Cleanup coding pass per ITU-T Rec. T.814 Clauses 7.1–7.3 and Annex F.
    package static func encodeCleanup(
        coefficients: [Int32],
        width: Int,
        height: Int,
        bandShift: Int = 0,
        maximumOutputBytes: Int = Int.max,
        budget: EntropyOutputBudget? = nil
    ) throws -> [UInt8] {
        let sampleCount = try validateBlockGeometry(width: width, height: height, caller: "HTBlockEncoder.encodeCleanup")
        guard coefficients.count == sampleCount else {
            throw CodecError(.invalidArgument, "HTJ2K block dimensions do not match coefficient count.")
        }
        guard bandShift >= 0, bandShift < 31 else {
            throw CodecError(.invalidArgument, "HTJ2K cleanup bit-plane shift (\(bandShift)) is out of range.")
        }

        var anySignificant = false
        for coeff in coefficients {
            if coeff != 0 {
                let mu = UInt64(coeff.magnitude) >> bandShift
                if mu != 0 {
                    guard mu <= 0x3FFF_FFFF else {
                        throw CodecError(.invalidArgument, "HTJ2K coefficient magnitude exceeds 30-bit reversible range.")
                    }
                    anySignificant = true
                }
            }
        }
        if !anySignificant {
            return []
        }

        guard maximumOutputBytes >= 2 else {
            throw CodecError(.resourceLimitExceeded, "HTJ2K cleanup segment exceeds the remaining block admission budget.")
        }

        let qw = (width + 1) / 2
        let qh = (height + 1) / 2
        var quads = [SIMDHTBlockCoder.PreclassifiedQuad]()
        quads.reserveCapacity(qw * qh)

        for qy in 0..<qh {
            let y0 = qy * 2
            let hasY1 = (y0 + 1) < height
            let row0 = y0 * width
            let row1 = hasY1 ? (y0 + 1) * width : row0

            for qx in 0..<qw {
                let x0 = qx * 2
                let hasX1 = (x0 + 1) < width

                let c0 = coefficients[row0 + x0]
                let c1: Int32 = hasY1 ? coefficients[row1 + x0] : 0
                let c2: Int32 = hasX1 ? coefficients[row0 + x0 + 1] : 0
                let c3: Int32 = (hasX1 && hasY1) ? coefficients[row1 + x0 + 1] : 0

                if (c0 | c1 | c2 | c3) == 0 {
                    quads.append(SIMDHTBlockCoder.PreclassifiedQuad(
                        rho: 0, eQMax: 0,
                        eQ0: 0, eQ1: 0, eQ2: 0, eQ3: 0,
                        s0: 0, s1: 0, s2: 0, s3: 0
                    ))
                    continue
                }

                @inline(__always)
                func classifySample(_ c: Int32) -> (active: Bool, exponent: Int, magSgn: UInt32) {
                    guard c != 0 else { return (false, 0, 0) }
                    let mu = UInt32(UInt64(c.magnitude) >> bandShift)
                    guard mu != 0 else { return (false, 0, 0) }
                    let twoMuMinusOne = (mu << 1) - 1
                    let exponent = 32 - twoMuMinusOne.leadingZeroBitCount
                    let sign: UInt32 = c < 0 ? 1 : 0
                    let magSgn = (twoMuMinusOne - 1) + sign
                    return (true, exponent, magSgn)
                }

                let q0 = classifySample(c0)
                let q1 = classifySample(c1)
                let q2 = classifySample(c2)
                let q3 = classifySample(c3)

                let rho = (q0.active ? 1 : 0)
                    | (q1.active ? 2 : 0)
                    | (q2.active ? 4 : 0)
                    | (q3.active ? 8 : 0)

                if rho == 0 {
                    quads.append(SIMDHTBlockCoder.PreclassifiedQuad(
                        rho: 0, eQMax: 0,
                        eQ0: 0, eQ1: 0, eQ2: 0, eQ3: 0,
                        s0: 0, s1: 0, s2: 0, s3: 0
                    ))
                } else {
                    let eMax = max(max(q0.exponent, q1.exponent), max(q2.exponent, q3.exponent))
                    quads.append(SIMDHTBlockCoder.PreclassifiedQuad(
                        rho: rho,
                        eQMax: eMax,
                        eQ0: q0.exponent,
                        eQ1: q1.exponent,
                        eQ2: q2.exponent,
                        eQ3: q3.exponent,
                        s0: q0.magSgn,
                        s1: q1.magSgn,
                        s2: q2.magSgn,
                        s3: q3.magSgn
                    ))
                }
            }
        }

        return try encodePreclassifiedCleanup(
            quads: quads,
            width: width,
            height: height,
            maximumOutputBytes: maximumOutputBytes,
            budget: budget
        )
    }

    /// Shared T.814 cleanup bitstream encoder invoked by both `HTBlockEncoder.encodeCleanup` and
    /// `SIMDHTBlockCoder.encodeCleanup` to guarantee exact bit-for-bit output parity.
    internal static func encodePreclassifiedCleanup(
        quads: [SIMDHTBlockCoder.PreclassifiedQuad],
        width: Int,
        height: Int,
        maximumOutputBytes: Int,
        budget: EntropyOutputBudget?
    ) throws -> [UInt8] {
        let qw = (width + 1) / 2
        let qh = (height + 1) / 2
        guard quads.count == qw * qh else {
            throw CodecError(.invalidArgument, "Preclassified HTJ2K quad count (\(quads.count)) does not match \(qw)x\(qh) quad grid.")
        }
        guard maximumOutputBytes >= 2 else {
            throw CodecError(.resourceLimitExceeded, "HTJ2K cleanup segment exceeds the remaining block admission budget.")
        }

        let suffixCap = min(4079, maximumOutputBytes)
        let segmentCap = min(65534, maximumOutputBytes)

        var magSgnPacker = MagSgnForwardPacker(maximumBytes: segmentCap, budget: budget)
        var melPacker = MELForwardPacker(maximumBytes: suffixCap, budget: budget)
        var vlcPacker = VLCBackwardPacker(maximumBytes: suffixCap, budget: budget)
        var extraAssemblyReserved = 0
        var transferredOwnership = false
        defer {
            if !transferredOwnership {
                magSgnPacker.stream.releaseAll()
                melPacker.stream.releaseAll()
                vlcPacker.stream.releaseAll()
                if let budget, extraAssemblyReserved > 0 {
                    budget.release(extraAssemblyReserved, countsTowardCompressedOutput: true, site: "ht-cleanup-assemble-rollback")
                }
            }
        }

        var prevRowRho = [Int](repeating: 0, count: qw)
        var prevRowE1 = [Int](repeating: 0, count: qw)
        var prevRowE3 = [Int](repeating: 0, count: qw)
        var currRowRho = [Int](repeating: 0, count: qw)
        var currRowE1 = [Int](repeating: 0, count: qw)
        var currRowE3 = [Int](repeating: 0, count: qw)

        @inline(__always)
        func emitUVLCPair(_ first: HTTables.UVLCComponents, _ second: HTTables.UVLCComponents) {
            if first.prefixLength > 0 {
                vlcPacker.emitBits(first.prefixBits, count: Int(first.prefixLength))
            }
            if second.prefixLength > 0 {
                vlcPacker.emitBits(second.prefixBits, count: Int(second.prefixLength))
            }
            if first.suffixLength > 0 {
                vlcPacker.emitBits(first.suffixBits, count: Int(first.suffixLength))
            }
            if second.suffixLength > 0 {
                vlcPacker.emitBits(second.suffixBits, count: Int(second.suffixLength))
            }
            if first.extensionLength > 0 {
                vlcPacker.emitBits(first.extensionBits, count: Int(first.extensionLength))
            }
            if second.extensionLength > 0 {
                vlcPacker.emitBits(second.extensionBits, count: Int(second.extensionLength))
            }
        }

        @inline(__always)
        func emitQuadMagSgn(_ quad: SIMDHTBlockCoder.PreclassifiedQuad, upperU: Int, embKnown: UInt8) {
            let rho = quad.rho
            guard rho != 0 else { return }
            let known = Int(embKnown)
            if (rho & 1) != 0 {
                magSgnPacker.emitBits(value: quad.s0, count: upperU - (known & 1))
            }
            if (rho & 2) != 0 {
                magSgnPacker.emitBits(value: quad.s1, count: upperU - ((known >> 1) & 1))
            }
            if (rho & 4) != 0 {
                magSgnPacker.emitBits(value: quad.s2, count: upperU - ((known >> 2) & 1))
            }
            if (rho & 8) != 0 {
                magSgnPacker.emitBits(value: quad.s3, count: upperU - ((known >> 3) & 1))
            }
        }

        @inline(__always)
        func prepareQuad(
            quad: SIMDHTBlockCoder.PreclassifiedQuad,
            qy: Int,
            qx: Int,
            leftRho: Int
        ) -> (u: Int, uOff: Int, upperU: Int, cxtEntry: HTTables.CxtVLCEncodeEntry) {
            let context: Int
            let kappa: Int
            if qy == 0 {
                if qx == 0 {
                    context = 0
                } else {
                    let fOrSf = (leftRho & 0x03) != 0 ? 1 : 0
                    let wAndSw = (leftRho >> 1) & 0x06
                    context = fOrSf | wAndSw
                }
                kappa = 1
            } else {
                let nw = qx > 0 ? ((prevRowRho[qx - 1] >> 3) & 1) : 0
                let n = (prevRowRho[qx] >> 1) & 1
                let ne = (prevRowRho[qx] >> 3) & 1
                let nf = (qx + 1 < qw) ? ((prevRowRho[qx + 1] >> 1) & 1) : 0
                let wOrSw = qx > 0 ? (((leftRho & 0x0C) != 0) ? 1 : 0) : 0
                context = (nw | n) | (wOrSw << 1) | ((ne | nf) << 2)

                let eNW = qx > 0 ? prevRowE3[qx - 1] : 0
                let eN = prevRowE1[qx]
                let eNE = prevRowE3[qx]
                let eNF = (qx + 1 < qw) ? prevRowE1[qx + 1] : 0
                let maxNeighborE = max(max(eNW, eN), max(eNE, eNF))
                let gamma = quad.rho.nonzeroBitCount > 1 ? 1 : 0
                kappa = max(1, gamma * (maxNeighborE - 1))
            }

            if quad.rho == 0 {
                if context == 0 {
                    melPacker.encodeSymbol(0)
                    return (0, 0, 0, HTTables.CxtVLCEncodeEntry(codeword: 0, bitLength: 0, embKnown: 0))
                }
                let entry = qy == 0
                    ? HTTables.cxtVLCEncodeTable0[context << 8]
                    : HTTables.cxtVLCEncodeTable1[context << 8]
                return (0, 0, 0, entry)
            }

            let upperU = max(quad.eQMax, kappa)
            let u = upperU - kappa
            let uOff = u > 0 ? 1 : 0
            var emb = 0
            if uOff == 1 {
                if quad.eQ0 == quad.eQMax { emb |= 1 }
                if quad.eQ1 == quad.eQMax { emb |= 2 }
                if quad.eQ2 == quad.eQMax { emb |= 4 }
                if quad.eQ3 == quad.eQMax { emb |= 8 }
            }
            if context == 0 {
                melPacker.encodeSymbol(1)
            }
            let tableIndex = (context << 8) | (quad.rho << 4) | emb
            let entry = qy == 0
                ? HTTables.cxtVLCEncodeTable0[tableIndex]
                : HTTables.cxtVLCEncodeTable1[tableIndex]
            return (u, uOff, upperU, entry)
        }

        for qy in 0..<qh {
            let rowBase = qy * qw
            var leftRho = 0
            var qx = 0
            while qx < qw {
                let quad1 = quads[rowBase + qx]
                let prep1 = prepareQuad(quad: quad1, qy: qy, qx: qx, leftRho: leftRho)
                emitQuadMagSgn(quad1, upperU: prep1.upperU, embKnown: prep1.cxtEntry.embKnown)
                if prep1.cxtEntry.bitLength > 0 {
                    vlcPacker.emitBits(prep1.cxtEntry.codeword, count: Int(prep1.cxtEntry.bitLength))
                }
                leftRho = quad1.rho
                currRowRho[qx] = quad1.rho
                currRowE1[qx] = quad1.eQ1
                currRowE3[qx] = quad1.eQ3

                if qx + 1 < qw {
                    let quad2 = quads[rowBase + qx + 1]
                    let prep2 = prepareQuad(quad: quad2, qy: qy, qx: qx + 1, leftRho: leftRho)
                    emitQuadMagSgn(quad2, upperU: prep2.upperU, embKnown: prep2.cxtEntry.embKnown)
                    if prep2.cxtEntry.bitLength > 0 {
                        vlcPacker.emitBits(prep2.cxtEntry.codeword, count: Int(prep2.cxtEntry.bitLength))
                    }
                    leftRho = quad2.rho
                    currRowRho[qx + 1] = quad2.rho
                    currRowE1[qx + 1] = quad2.eQ1
                    currRowE3[qx + 1] = quad2.eQ3

                    if qy == 0 && prep1.uOff == 1 && prep2.uOff == 1 {
                        let jointMel = (prep1.u > 2 && prep2.u > 2) ? 1 : 0
                        melPacker.encodeSymbol(jointMel)
                        if jointMel == 1 {
                            let c1 = HTTables.encodeUVLC(prep1.u - 2)
                            let c2 = HTTables.encodeUVLC(prep2.u - 2)
                            emitUVLCPair(c1, c2)
                        } else if prep1.u > 2 {
                            let c1 = HTTables.encodeUVLC(prep1.u)
                            let c2 = HTTables.UVLCComponents(
                                prefixBits: UInt8(prep2.u - 1),
                                prefixLength: 1,
                                suffixBits: 0,
                                suffixLength: 0,
                                extensionBits: 0,
                                extensionLength: 0
                            )
                            emitUVLCPair(c1, c2)
                        } else {
                            let c1 = HTTables.encodeUVLC(prep1.u)
                            let c2 = HTTables.encodeUVLC(prep2.u)
                            emitUVLCPair(c1, c2)
                        }
                    } else {
                        let c1 = prep1.uOff == 1 ? HTTables.encodeUVLC(prep1.u) : .empty
                        let c2 = prep2.uOff == 1 ? HTTables.encodeUVLC(prep2.u) : .empty
                        emitUVLCPair(c1, c2)
                    }
                    qx += 2
                } else {
                    if prep1.uOff == 1 {
                        let c1 = HTTables.encodeUVLC(prep1.u)
                        emitUVLCPair(c1, .empty)
                    }
                    qx += 1
                }

                if magSgnPacker.stream.overflowed || melPacker.stream.overflowed || vlcPacker.stream.overflowed {
                    throw CodecError(.resourceLimitExceeded, "HTJ2K cleanup stream exceeds the remaining block admission budget.")
                }
            }
            swap(&prevRowRho, &currRowRho)
            swap(&prevRowE1, &currRowE1)
            swap(&prevRowE3, &currRowE3)
        }

        magSgnPacker.terminate()
        melPacker.terminateSymbols()

        // Joint MEL + VLC termination per `termMELandVLCPackers` (Annex F.4, p. 68):
        let shiftedMEL: UInt8 = melPacker.remainingBits == 8
            ? 0
            : UInt8((Int(melPacker.partialByte) << melPacker.remainingBits) & 0xFF)
        let melMask: UInt8 = melPacker.remainingBits == 8
            ? 0
            : UInt8((0xFF << melPacker.remainingBits) & 0xFF)
        let vlcMask: UInt8 = vlcPacker.usedBits == 0
            ? 0
            : UInt8(0xFF >> (8 - vlcPacker.usedBits))
        if (melMask | vlcMask) != 0 {
            let fuse = shiftedMEL | vlcPacker.partialByte
            if (((fuse ^ shiftedMEL) & melMask) | ((fuse ^ vlcPacker.partialByte) & vlcMask)) == 0
                && fuse != 0xFF
            {
                melPacker.stream.append(fuse)
            } else {
                melPacker.stream.append(shiftedMEL)
                vlcPacker.stream.append(vlcPacker.partialByte)
            }
        }

        guard !magSgnPacker.stream.overflowed, !melPacker.stream.overflowed, !vlcPacker.stream.overflowed else {
            throw CodecError(.resourceLimitExceeded, "HTJ2K cleanup stream exceeds the remaining block admission budget.")
        }

        let magSgnCount = magSgnPacker.stream.bytes.count
        let melCount = melPacker.stream.bytes.count
        let vlcCount = vlcPacker.stream.bytes.count
        let scup = melCount + vlcCount
        let lcup = magSgnCount + scup

        guard scup >= 2, scup <= 4079, lcup >= 2, lcup < 65535 else {
            throw CodecError(.resourceLimitExceeded, "HTJ2K cleanup segment lengths (Lcup=\(lcup), Scup=\(scup)) exceed T.814 bounds.")
        }
        guard lcup <= maximumOutputBytes else {
            throw CodecError(.resourceLimitExceeded, "HTJ2K cleanup segment (\(lcup) bytes) exceeds block output limit (\(maximumOutputBytes) bytes).")
        }

        var heldCompressed = magSgnPacker.stream.reservedBytes
            + melPacker.stream.reservedBytes
            + vlcPacker.stream.reservedBytes

        if let budget {
            if lcup > heldCompressed {
                let extra = lcup - heldCompressed
                try budget.reserve(extra, countsTowardCompressedOutput: true, site: "ht-cleanup-assemble-grow")
                extraAssemblyReserved = extra
                heldCompressed += extra
            }
            try budget.reserve(lcup, countsTowardCompressedOutput: false, site: "ht-cleanup-assemble-overlap")
            budget.recordActualAllocation(lcup, site: "ht-cleanup-assemble")
        }
        defer {
            if let budget {
                budget.release(lcup, countsTowardCompressedOutput: false, site: "ht-cleanup-assemble-overlap")
            }
        }

        let segment = [UInt8](unsafeUninitializedCapacity: lcup) { dst, initializedCount in
            guard let dstBase = dst.baseAddress else {
                initializedCount = 0
                return
            }
            if magSgnCount > 0 {
                magSgnPacker.stream.bytes.withUnsafeBufferPointer { src in
                    if let srcBase = src.baseAddress {
                        dstBase.initialize(from: srcBase, count: magSgnCount)
                    }
                }
            }
            if melCount > 0 {
                melPacker.stream.bytes.withUnsafeBufferPointer { src in
                    if let srcBase = src.baseAddress {
                        (dstBase + magSgnCount).initialize(from: srcBase, count: melCount)
                    }
                }
            }
            vlcPacker.stream.bytes.withUnsafeBufferPointer { src in
                if let srcBase = src.baseAddress {
                    let vlcDst = dstBase + magSgnCount + melCount
                    for i in 0..<vlcCount {
                        (vlcDst + i).initialize(to: srcBase[vlcCount - 1 - i])
                    }
                }
            }
            dstBase[lcup - 1] = UInt8((scup >> 4) & 0xFF)
            dstBase[lcup - 2] = (dstBase[lcup - 2] & 0xF0) | UInt8(scup & 0x0F)
            initializedCount = lcup
        }

        magSgnPacker.stream.detachAfterTransfer()
        melPacker.stream.detachAfterTransfer()
        vlcPacker.stream.detachAfterTransfer()
        extraAssemblyReserved = 0
        if let budget, heldCompressed > lcup {
            budget.release(heldCompressed - lcup, countsTowardCompressedOutput: true, site: "ht-cleanup-assemble-trim")
        }
        transferredOwnership = true
        return segment
    }

    /// Encodes an HT Refinement segment (`HT SigProp` + optional `HT MagRef`) per ITU-T Rec. T.814
    /// Clauses 7.4–7.5 and Annex F.4.
    package static func encodeRefinement(
        coefficients: [Int64],
        width: Int,
        height: Int,
        cleanupBandShift: Int,
        includeMagRef: Bool,
        causal: Bool = false,
        maximumOutputBytes: Int = Int.max,
        budget: EntropyOutputBudget? = nil
    ) throws -> [UInt8] {
        let sampleCount = try validateBlockGeometry(width: width, height: height, caller: "HTBlockEncoder.encodeRefinement")
        guard coefficients.count == sampleCount else {
            throw CodecError(.invalidArgument, "HTJ2K refinement block dimensions do not match coefficient count.")
        }
        guard cleanupBandShift >= 1, cleanupBandShift < 63 else {
            throw CodecError(.invalidArgument, "HTJ2K refinement cleanupBandShift (\(cleanupBandShift)) is out of range.")
        }
        guard maximumOutputBytes >= 0 else {
            throw CodecError(.resourceLimitExceeded, "Negative maximumOutputBytes for HTJ2K refinement segment.")
        }

        let refinementCap = min(2046, maximumOutputBytes)
        var spPacker = SigPropForwardPacker(maximumBytes: refinementCap, budget: budget)
        var mrPacker = MagRefBackwardPacker(maximumBytes: refinementCap, budget: budget)
        var extraAssemblyReserved = 0
        var transferredOwnership = false
        defer {
            if !transferredOwnership {
                spPacker.stream.releaseAll()
                mrPacker.stream.releaseAll()
                if let budget, extraAssemblyReserved > 0 {
                    budget.release(extraAssemblyReserved, countsTowardCompressedOutput: true, site: "ht-refinement-assemble-rollback")
                }
            }
        }

        let refPlane = cleanupBandShift - 1
        var cleanupSig = [UInt8](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            if (coefficients[i].magnitude >> cleanupBandShift) != 0 {
                cleanupSig[i] = 1
            }
        }
        var sigPropMag = [UInt8](repeating: 0, count: sampleCount)

        // 1. HT SigProp pass (Clause 7.4): 4-line stripes, 4-column groups, magnitude pass then sign pass.
        var stripeY = 0
        while stripeY < height {
            let stripeEndY = min(stripeY + 4, height)
            var groupX = 0
            while groupX < width {
                let groupEndX = min(groupX + 4, width)

                // Magnitude step across the column-group:
                for col in groupX..<groupEndX {
                    for row in stripeY..<stripeEndY {
                        let idx = row * width + col
                        guard cleanupSig[idx] == 0 else { continue }

                        let minNY = max(0, row - 1)
                        let maxNY = causal ? min(stripeEndY - 1, row + 1) : min(height - 1, row + 1)
                        let minNX = max(0, col - 1)
                        let maxNX = min(width - 1, col + 1)

                        var hasActiveNeighbour = false
                        neighbourScan: for ny in minNY...maxNY {
                            let nRowBase = ny * width
                            for nx in minNX...maxNX {
                                if nx == col && ny == row { continue }
                                let nIdx = nRowBase + nx
                                if cleanupSig[nIdx] != 0 || sigPropMag[nIdx] != 0 {
                                    hasActiveNeighbour = true
                                    break neighbourScan
                                }
                            }
                        }

                        if hasActiveNeighbour {
                            let magBit = Int((coefficients[idx].magnitude >> refPlane) & 1)
                            sigPropMag[idx] = UInt8(magBit)
                            spPacker.emitBit(magBit)
                        }
                    }
                }

                // Sign step across the same column-group:
                for col in groupX..<groupEndX {
                    for row in stripeY..<stripeEndY {
                        let idx = row * width + col
                        if sigPropMag[idx] != 0 {
                            let signBit = coefficients[idx] < 0 ? 1 : 0
                            spPacker.emitBit(signBit)
                        }
                    }
                }

                if spPacker.stream.overflowed {
                    throw CodecError(.resourceLimitExceeded, "HTJ2K SigProp stream exceeds block output budget.")
                }
                groupX += 4
            }
            stripeY += 4
        }

        // 2. Optional HT MagRef pass (Clause 7.5): 4-line stripe scan over samples significant in Cleanup.
        if includeMagRef {
            var mrStripeY = 0
            while mrStripeY < height {
                let mrStripeEndY = min(mrStripeY + 4, height)
                for col in 0..<width {
                    for row in mrStripeY..<mrStripeEndY {
                        let idx = row * width + col
                        if cleanupSig[idx] != 0 {
                            let magBit = Int((coefficients[idx].magnitude >> refPlane) & 1)
                            mrPacker.emitBit(magBit)
                        }
                    }
                }
                if mrPacker.stream.overflowed {
                    throw CodecError(.resourceLimitExceeded, "HTJ2K MagRef stream exceeds block output budget.")
                }
                mrStripeY += 4
            }

            // Joint SigProp + MagRef termination per `termSPandMRPackers` (Annex F.4, p. 71):
            var spMask: UInt8 = spPacker.usedBits == 0 ? 0 : UInt8(0xFF >> (8 - spPacker.usedBits))
            if spPacker.maxBitsInByte == 7 {
                spMask |= 0x80 // Cover mandatory 0-stuff bit following 0xFF
            }
            let mrMask: UInt8 = mrPacker.usedBits == 0 ? 0 : UInt8(0xFF >> (8 - mrPacker.usedBits))
            if (spMask | mrMask) != 0 {
                let fuse = spPacker.partialByte | mrPacker.partialByte
                if (((fuse ^ spPacker.partialByte) & spMask) | ((fuse ^ mrPacker.partialByte) & mrMask)) == 0 {
                    spPacker.stream.append(fuse)
                } else {
                    spPacker.stream.append(spPacker.partialByte)
                    mrPacker.stream.append(mrPacker.partialByte)
                }
            }
        } else {
            spPacker.terminateStandalone()
        }

        guard !spPacker.stream.overflowed, !mrPacker.stream.overflowed else {
            throw CodecError(.resourceLimitExceeded, "HTJ2K refinement segment exceeds block output budget.")
        }

        let spCount = spPacker.stream.bytes.count
        let mrCount = mrPacker.stream.bytes.count
        let lref = spCount + mrCount

        if lref == 0 {
            return []
        }
        guard lref < 2047 else {
            throw CodecError(.resourceLimitExceeded, "HTJ2K refinement segment length (\(lref)) exceeds T.814 limit of 2046 bytes.")
        }
        guard lref <= maximumOutputBytes else {
            throw CodecError(.resourceLimitExceeded, "HTJ2K refinement segment (\(lref) bytes) exceeds block output limit (\(maximumOutputBytes) bytes).")
        }

        var heldCompressed = spPacker.stream.reservedBytes + mrPacker.stream.reservedBytes
        if let budget {
            if lref > heldCompressed {
                let extra = lref - heldCompressed
                try budget.reserve(extra, countsTowardCompressedOutput: true, site: "ht-refinement-assemble-grow")
                extraAssemblyReserved = extra
                heldCompressed += extra
            }
            try budget.reserve(lref, countsTowardCompressedOutput: false, site: "ht-refinement-assemble-overlap")
            budget.recordActualAllocation(lref, site: "ht-refinement-assemble")
        }
        defer {
            if let budget {
                budget.release(lref, countsTowardCompressedOutput: false, site: "ht-refinement-assemble-overlap")
            }
        }

        let segment = [UInt8](unsafeUninitializedCapacity: lref) { dst, initializedCount in
            guard let dstBase = dst.baseAddress else {
                initializedCount = 0
                return
            }
            if spCount > 0 {
                spPacker.stream.bytes.withUnsafeBufferPointer { src in
                    if let srcBase = src.baseAddress {
                        dstBase.initialize(from: srcBase, count: spCount)
                    }
                }
            }
            if mrCount > 0 {
                mrPacker.stream.bytes.withUnsafeBufferPointer { src in
                    if let srcBase = src.baseAddress {
                        let mrDst = dstBase + spCount
                        for i in 0..<mrCount {
                            (mrDst + i).initialize(to: srcBase[mrCount - 1 - i])
                        }
                    }
                }
            }
            initializedCount = lref
        }

        spPacker.stream.detachAfterTransfer()
        mrPacker.stream.detachAfterTransfer()
        extraAssemblyReserved = 0
        if let budget, heldCompressed > lref {
            budget.release(heldCompressed - lref, countsTowardCompressedOutput: true, site: "ht-refinement-assemble-trim")
        }
        transferredOwnership = true
        return segment
    }

    /// Reusable per-worker scratch buffers eliminating intermediate heap allocations across HTJ2K code-blocks.
    package final class Workspace {
        package var quads: [SIMDHTBlockCoder.PreclassifiedQuad] = []
        package var rowBuf0: [Int] = []
        package var rowBuf1: [Int] = []
        package var rowBuf2: [Int] = []
        package var rowBuf3: [Int] = []
        package var rowBuf4: [Int] = []
        package var rowBuf5: [Int] = []
        package var magSgnBytes: [UInt8] = []
        package var suffixScratch: [UInt8] = []
        package var rowScratch: [Int] = []
        package var refScratch: [UInt8] = []
        package var nzMags: [UInt32] = []
        package var paddedSig: [UInt8] = []

        package init(maxQuads: Int = 1024, maxWidth: Int = 64) {
            let maxQW = (maxWidth + 1) / 2
            quads.reserveCapacity(maxQuads)
            rowBuf0 = [Int](repeating: 0, count: maxQW)
            rowBuf1 = [Int](repeating: 0, count: maxQW)
            rowBuf2 = [Int](repeating: 0, count: maxQW)
            rowBuf3 = [Int](repeating: 0, count: maxQW)
            rowBuf4 = [Int](repeating: 0, count: maxQW)
            rowBuf5 = [Int](repeating: 0, count: maxQW)
            magSgnBytes = [UInt8](repeating: 0, count: 8192)
            suffixScratch = [UInt8](repeating: 0, count: 4083 * 2)
            rowScratch = [Int](repeating: 0, count: maxQW * 6)
            refScratch = [UInt8](repeating: 0, count: 4096)
            nzMags = [UInt32](repeating: 0, count: maxQuads * 4)
            paddedSig = [UInt8](repeating: 0, count: (maxWidth + 2) * (maxWidth + 2))
        }

        @inline(__always)
        package func ensureRowCapacity(_ qw: Int) {
            if rowBuf0.count < qw {
                rowBuf0 = [Int](repeating: 0, count: qw)
                rowBuf1 = [Int](repeating: 0, count: qw)
                rowBuf2 = [Int](repeating: 0, count: qw)
                rowBuf3 = [Int](repeating: 0, count: qw)
                rowBuf4 = [Int](repeating: 0, count: qw)
                rowBuf5 = [Int](repeating: 0, count: qw)
            } else {
                for i in 0..<qw {
                    rowBuf0[i] = 0
                    rowBuf1[i] = 0
                    rowBuf2[i] = 0
                }
            }
        }
    }

    /// Zero-intermediate-allocation strided HT Cleanup encoder reading directly from a component wavelet plane.
    package static func encodeCleanupStrided(
        planeBase: UnsafePointer<Int32>,
        planeOrigin: Int,
        stride: Int,
        width: Int,
        height: Int,
        bandShift: Int = 0,
        maximumOutputBytes: Int = Int.max,
        workspace: Workspace
    ) throws -> [UInt8] {
        _ = try validateBlockGeometry(width: width, height: height, caller: "HTBlockEncoder.encodeCleanupStrided")
        guard bandShift >= 0, bandShift < 31 else {
            throw CodecError(.invalidArgument, "HTJ2K cleanup bit-plane shift (\(bandShift)) is out of range.")
        }

        let qw = (width + 1) / 2
        let qh = (height + 1) / 2
        let quadCount = qw * qh
        guard quadCount > 0 else { return [] }

        let zeroQuad = SIMDHTBlockCoder.PreclassifiedQuad(
            rho: 0, eQMax: 0,
            eQ0: 0, eQ1: 0, eQ2: 0, eQ3: 0,
            s0: 0, s1: 0, s2: 0, s3: 0
        )
        if workspace.quads.count != quadCount {
            workspace.quads = [SIMDHTBlockCoder.PreclassifiedQuad](repeating: zeroQuad, count: quadCount)
        }

        let anySignificant = try workspace.quads.withUnsafeMutableBufferPointer { quadBuf -> Bool in
            guard let qPtr = quadBuf.baseAddress else { return false }
            var foundSignificant = false
            var qIdx = 0
            for qy in 0..<qh {
                let y0 = qy * 2
                let hasY1 = (y0 + 1) < height
                let r0 = planeOrigin + y0 * stride
                let r1 = hasY1 ? (r0 + stride) : r0

                for qx in 0..<qw {
                    let x0 = qx * 2
                    let hasX1 = (x0 + 1) < width

                    let c0 = planeBase[r0 + x0]
                    let c1: Int32 = hasY1 ? planeBase[r1 + x0] : 0
                    let c2: Int32 = hasX1 ? planeBase[r0 + x0 + 1] : 0
                    let c3: Int32 = (hasX1 && hasY1) ? planeBase[r1 + x0 + 1] : 0

                    if (c0 | c1 | c2 | c3) == 0 {
                        qPtr[qIdx] = zeroQuad
                        qIdx += 1
                        continue
                    }

                    @inline(__always)
                    func classify(_ c: Int32) throws -> (active: Bool, exponent: Int, magSgn: UInt32) {
                        guard c != 0 else { return (false, 0, 0) }
                        let mu64 = UInt64(c.magnitude) >> bandShift
                        guard mu64 != 0 else { return (false, 0, 0) }
                        guard mu64 <= 0x3FFF_FFFF else {
                            throw CodecError(.invalidArgument, "HTJ2K coefficient magnitude exceeds 30-bit reversible range.")
                        }
                        let mu = UInt32(truncatingIfNeeded: mu64)
                        let twoMuMinusOne = (mu &<< 1) &- 1
                        let exponent = 32 - twoMuMinusOne.leadingZeroBitCount
                        let sign: UInt32 = c < 0 ? 1 : 0
                        let magSgn = (twoMuMinusOne &- 1) &+ sign
                        return (true, exponent, magSgn)
                    }

                    let q0 = try classify(c0)
                    let q1 = try classify(c1)
                    let q2 = try classify(c2)
                    let q3 = try classify(c3)

                    let rho = (q0.active ? 1 : 0)
                        | (q1.active ? 2 : 0)
                        | (q2.active ? 4 : 0)
                        | (q3.active ? 8 : 0)

                    if rho == 0 {
                        qPtr[qIdx] = zeroQuad
                    } else {
                        foundSignificant = true
                        let eMax = max(max(q0.exponent, q1.exponent), max(q2.exponent, q3.exponent))
                        qPtr[qIdx] = SIMDHTBlockCoder.PreclassifiedQuad(
                            rho: rho,
                            eQMax: eMax,
                            eQ0: q0.exponent,
                            eQ1: q1.exponent,
                            eQ2: q2.exponent,
                            eQ3: q3.exponent,
                            s0: q0.magSgn,
                            s1: q1.magSgn,
                            s2: q2.magSgn,
                            s3: q3.magSgn
                        )
                    }
                    qIdx += 1
                }
            }
            return foundSignificant
        }

        if !anySignificant {
            return []
        }

        return try encodePreclassifiedCleanupWithWorkspace(
            quads: workspace.quads,
            width: width,
            height: height,
            maximumOutputBytes: maximumOutputBytes,
            workspace: workspace
        )
    }

    /// Encodes preclassified quads using reusable buffers in `workspace` (when `budget == nil`).
    package static func encodePreclassifiedCleanupWithWorkspace(
        quads: [SIMDHTBlockCoder.PreclassifiedQuad],
        width: Int,
        height: Int,
        maximumOutputBytes: Int,
        workspace: Workspace
    ) throws -> [UInt8] {
        let qw = (width + 1) / 2
        let qh = (height + 1) / 2
        guard quads.count == qw * qh else {
            throw CodecError(.invalidArgument, "Preclassified HTJ2K quad count (\(quads.count)) does not match \(qw)x\(qh) quad grid.")
        }
        guard maximumOutputBytes >= 2 else {
            throw CodecError(.resourceLimitExceeded, "HTJ2K cleanup segment exceeds the remaining block admission budget.")
        }

        let suffixCap = min(4079, maximumOutputBytes)
        let segmentCap = min(65534, maximumOutputBytes)
        let rowCap = max(1, qw)
        let suffixScratchCap = suffixCap + 4

        if workspace.magSgnBytes.count < segmentCap {
            workspace.magSgnBytes = [UInt8](repeating: 0, count: segmentCap)
        }
        if workspace.suffixScratch.count < suffixScratchCap * 2 {
            workspace.suffixScratch = [UInt8](repeating: 0, count: suffixScratchCap * 2)
        }
        if workspace.rowScratch.count < rowCap * 6 {
            workspace.rowScratch = [Int](repeating: 0, count: rowCap * 6)
        }

        return try workspace.magSgnBytes.withUnsafeMutableBufferPointer { msBuf in
            let msPtr = msBuf.baseAddress!
            return try workspace.suffixScratch.withUnsafeMutableBufferPointer { suffixScratch in
                let melPtr = suffixScratch.baseAddress!
                let vlcPtr = melPtr.advanced(by: suffixScratchCap)
                return try workspace.rowScratch.withUnsafeMutableBufferPointer { rowScratch in
                    let scratchBase = rowScratch.baseAddress!
                    scratchBase.update(repeating: 0, count: rowCap * 6)
                    var r0 = scratchBase
                    var r1 = scratchBase.advanced(by: rowCap)
                    var r2 = scratchBase.advanced(by: rowCap * 2)
                    var r3 = scratchBase.advanced(by: rowCap * 3)
                    var r4 = scratchBase.advanced(by: rowCap * 4)
                    var r5 = scratchBase.advanced(by: rowCap * 5)

                    var msCount = 0
                    var melCount = 0
                    vlcPtr[0] = 0xFF
                    var vlcCount = 1

                    var msPartial: UInt64 = 0
                    var msBits = 0
                    var msMaxBits = 8
                    var msOverflow = false

                    var melState = 0
                    var melRun = 0
                    var melThreshold = 1
                    var melPartial: UInt8 = 0
                    var melRemBits = 8
                    var melOverflow = false

                    var vlcUsedBits = 4
                    var vlcPartial: UInt8 = 0x0F
                    var vlcLast: UInt8 = 0xFF
                    var vlcOverflow = false

                    return try HTTables.cxtVLCEncodeTable0.withUnsafeBufferPointer { tbl0Buf in
                        try HTTables.cxtVLCEncodeTable1.withUnsafeBufferPointer { tbl1Buf in
                            try HTTables.melExponents.withUnsafeBufferPointer { melExpBuf in
                                try quads.withUnsafeBufferPointer { quadBuf in
                                    let tbl0 = tbl0Buf.baseAddress!
                                    let tbl1 = tbl1Buf.baseAddress!
                                    let melExps = melExpBuf.baseAddress!
                                    let qBase = quadBuf.baseAddress!

                                    @inline(__always)
                                    func msEmit(_ value: UInt32, _ count: Int) {
                                        guard count > 0 else { return }
                                        let mask = (UInt64(1) << count) - 1
                                        msPartial |= (UInt64(value) & mask) << msBits
                                        msBits += count
                                        if msBits >= 32 && msMaxBits == 8 {
                                            let word = UInt32(truncatingIfNeeded: msPartial)
                                            let inv = ~word
                                            if ((inv &- 0x0101_0101) & word & 0x8080_8080) == 0 {
                                                if msCount + 4 <= segmentCap {
                                                    msPtr[msCount] = UInt8(truncatingIfNeeded: word)
                                                    msPtr[msCount + 1] = UInt8(truncatingIfNeeded: word >> 8)
                                                    msPtr[msCount + 2] = UInt8(truncatingIfNeeded: word >> 16)
                                                    msPtr[msCount + 3] = UInt8(truncatingIfNeeded: word >> 24)
                                                    msCount += 4
                                                    msPartial >>= 32
                                                    msBits -= 32
                                                }
                                            }
                                        }
                                        while msBits >= msMaxBits {
                                            let byteMask = (UInt64(1) << msMaxBits) - 1
                                            let outByte = UInt8(msPartial & byteMask)
                                            if msCount < segmentCap {
                                                msPtr[msCount] = outByte
                                                msCount += 1
                                            } else {
                                                msOverflow = true
                                            }
                                            msPartial >>= msMaxBits
                                            msBits -= msMaxBits
                                            msMaxBits = (outByte == 0xFF) ? 7 : 8
                                        }
                                    }

                                    @inline(__always)
                                    func melEmitBit(_ bit: Int) {
                                        melPartial = (melPartial << 1) | UInt8(bit & 1)
                                        melRemBits -= 1
                                        if melRemBits == 0 {
                                            if melCount < suffixCap {
                                                melPtr[melCount] = melPartial
                                                melCount += 1
                                            } else {
                                                melOverflow = true
                                            }
                                            melRemBits = (melPartial == 0xFF) ? 7 : 8
                                            melPartial = 0
                                        }
                                    }

                                    @inline(__always)
                                    func melEncode(_ symbol: Int) {
                                        if symbol == 0 {
                                            melRun += 1
                                            if melRun >= melThreshold {
                                                melEmitBit(1)
                                                melRun = 0
                                                if melState < 12 { melState += 1 }
                                                melThreshold = 1 << melExps[melState]
                                            }
                                        } else {
                                            melEmitBit(0)
                                            var exp = melExps[melState]
                                            while exp > 0 {
                                                exp -= 1
                                                melEmitBit((melRun >> exp) & 1)
                                            }
                                            melRun = 0
                                            if melState > 0 { melState -= 1 }
                                            melThreshold = 1 << melExps[melState]
                                        }
                                    }

                                    @inline(__always)
                                    func vlcEmit(_ codeword: UInt8, _ count: Int) {
                                        if count <= 0 { return }
                                        if (vlcLast <= 0x8F && vlcUsedBits + count < 8) || (vlcUsedBits + count < 7) {
                                            let mask: UInt8 = (UInt8(1) << count) - 1
                                            vlcPartial |= (codeword & mask) << vlcUsedBits
                                            vlcUsedBits += count
                                            return
                                        }
                                        var cwd = codeword
                                        var rem = count
                                        while rem > 0 {
                                            let bit = cwd & 1
                                            cwd >>= 1
                                            rem -= 1
                                            vlcPartial |= (bit << vlcUsedBits)
                                            vlcUsedBits += 1
                                            if vlcLast > 0x8F && vlcPartial == 0x7F {
                                                vlcUsedBits += 1
                                            }
                                            if vlcUsedBits == 8 {
                                                if vlcCount < suffixCap {
                                                    vlcPtr[vlcCount] = vlcPartial
                                                    vlcCount += 1
                                                } else {
                                                    vlcOverflow = true
                                                }
                                                vlcLast = vlcPartial
                                                vlcPartial = 0
                                                vlcUsedBits = 0
                                            }
                                        }
                                    }

                                    @inline(__always)
                                    func emitUVLCPair(_ first: HTTables.UVLCComponents, _ second: HTTables.UVLCComponents) {
                                        if first.prefixLength > 0 { vlcEmit(first.prefixBits, Int(first.prefixLength)) }
                                        if second.prefixLength > 0 { vlcEmit(second.prefixBits, Int(second.prefixLength)) }
                                        if first.suffixLength > 0 { vlcEmit(first.suffixBits, Int(first.suffixLength)) }
                                        if second.suffixLength > 0 { vlcEmit(second.suffixBits, Int(second.suffixLength)) }
                                        if first.extensionLength > 0 { vlcEmit(first.extensionBits, Int(first.extensionLength)) }
                                        if second.extensionLength > 0 { vlcEmit(second.extensionBits, Int(second.extensionLength)) }
                                    }

                                    @inline(__always)
                                    func emitQuadMS(_ quad: SIMDHTBlockCoder.PreclassifiedQuad, _ upperU: Int, _ embKnown: UInt8) {
                                        let rho = quad.rho
                                        guard rho != 0 else { return }
                                        let known = Int(embKnown)
                                        if (rho & 1) != 0 { msEmit(quad.s0, upperU - (known & 1)) }
                                        if (rho & 2) != 0 { msEmit(quad.s1, upperU - ((known >> 1) & 1)) }
                                        if (rho & 4) != 0 { msEmit(quad.s2, upperU - ((known >> 2) & 1)) }
                                        if (rho & 8) != 0 { msEmit(quad.s3, upperU - ((known >> 3) & 1)) }
                                    }

                                    @inline(__always)
                                    func prepQuad(_ quad: SIMDHTBlockCoder.PreclassifiedQuad, _ qy: Int, _ qx: Int, _ leftRho: Int)
                                        -> (u: Int, uOff: Int, upperU: Int, cxtEntry: HTTables.CxtVLCEncodeEntry)
                                    {
                                        let context: Int
                                        let kappa: Int
                                        if qy == 0 {
                                            if qx == 0 {
                                                context = 0
                                            } else {
                                                let fOrSf = (leftRho & 0x03) != 0 ? 1 : 0
                                                let wAndSw = (leftRho >> 1) & 0x06
                                                context = fOrSf | wAndSw
                                            }
                                            kappa = 1
                                        } else {
                                            let nw = qx > 0 ? ((r0[qx - 1] >> 3) & 1) : 0
                                            let n = (r0[qx] >> 1) & 1
                                            let ne = (r0[qx] >> 3) & 1
                                            let nf = (qx + 1 < qw) ? ((r0[qx + 1] >> 1) & 1) : 0
                                            let wOrSw = qx > 0 ? (((leftRho & 0x0C) != 0) ? 1 : 0) : 0
                                            context = (nw | n) | (wOrSw << 1) | ((ne | nf) << 2)

                                            let eNW = qx > 0 ? r2[qx - 1] : 0
                                            let eN = r1[qx]
                                            let eNE = r2[qx]
                                            let eNF = (qx + 1 < qw) ? r1[qx + 1] : 0
                                            let maxNeighborE = max(max(eNW, eN), max(eNE, eNF))
                                            let gamma = quad.rho.nonzeroBitCount > 1 ? 1 : 0
                                            kappa = max(1, gamma * (maxNeighborE - 1))
                                        }

                                        if quad.rho == 0 {
                                            if context == 0 {
                                                melEncode(0)
                                                return (0, 0, 0, HTTables.CxtVLCEncodeEntry(codeword: 0, bitLength: 0, embKnown: 0))
                                            }
                                            let entry = qy == 0 ? tbl0[context << 8] : tbl1[context << 8]
                                            return (0, 0, 0, entry)
                                        }

                                        let upperU = max(quad.eQMax, kappa)
                                        let u = upperU - kappa
                                        let uOff = u > 0 ? 1 : 0
                                        var emb = 0
                                        if uOff == 1 {
                                            if quad.eQ0 == quad.eQMax { emb |= 1 }
                                            if quad.eQ1 == quad.eQMax { emb |= 2 }
                                            if quad.eQ2 == quad.eQMax { emb |= 4 }
                                            if quad.eQ3 == quad.eQMax { emb |= 8 }
                                        }
                                        if context == 0 { melEncode(1) }
                                        let tableIndex = (context << 8) | (quad.rho << 4) | emb
                                        let entry = qy == 0 ? tbl0[tableIndex] : tbl1[tableIndex]
                                        return (u, uOff, upperU, entry)
                                    }

                                    for qy in 0..<qh {
                                        let rowBase = qy * qw
                                        var leftRho = 0
                                        var qx = 0
                                        while qx < qw {
                                            let quad1 = qBase[rowBase + qx]
                                            let p1 = prepQuad(quad1, qy, qx, leftRho)
                                            emitQuadMS(quad1, p1.upperU, p1.cxtEntry.embKnown)
                                            if p1.cxtEntry.bitLength > 0 {
                                                vlcEmit(p1.cxtEntry.codeword, Int(p1.cxtEntry.bitLength))
                                            }
                                            leftRho = quad1.rho
                                            r3[qx] = quad1.rho
                                            r4[qx] = quad1.eQ1
                                            r5[qx] = quad1.eQ3

                                            if qx + 1 < qw {
                                                let quad2 = qBase[rowBase + qx + 1]
                                                let p2 = prepQuad(quad2, qy, qx + 1, leftRho)
                                                emitQuadMS(quad2, p2.upperU, p2.cxtEntry.embKnown)
                                                if p2.cxtEntry.bitLength > 0 {
                                                    vlcEmit(p2.cxtEntry.codeword, Int(p2.cxtEntry.bitLength))
                                                }
                                                leftRho = quad2.rho
                                                r3[qx + 1] = quad2.rho
                                                r4[qx + 1] = quad2.eQ1
                                                r5[qx + 1] = quad2.eQ3

                                                if qy == 0 && p1.uOff == 1 && p2.uOff == 1 {
                                                    let jointMel = (p1.u > 2 && p2.u > 2) ? 1 : 0
                                                    melEncode(jointMel)
                                                    if jointMel == 1 {
                                                        emitUVLCPair(HTTables.encodeUVLC(p1.u - 2), HTTables.encodeUVLC(p2.u - 2))
                                                    } else if p1.u > 2 {
                                                        let c2 = HTTables.UVLCComponents(
                                                            prefixBits: UInt8(p2.u - 1), prefixLength: 1,
                                                            suffixBits: 0, suffixLength: 0, extensionBits: 0, extensionLength: 0
                                                        )
                                                        emitUVLCPair(HTTables.encodeUVLC(p1.u), c2)
                                                    } else {
                                                        emitUVLCPair(HTTables.encodeUVLC(p1.u), HTTables.encodeUVLC(p2.u))
                                                    }
                                                } else {
                                                    let c1 = p1.uOff == 1 ? HTTables.encodeUVLC(p1.u) : .empty
                                                    let c2 = p2.uOff == 1 ? HTTables.encodeUVLC(p2.u) : .empty
                                                    emitUVLCPair(c1, c2)
                                                }
                                                qx += 2
                                            } else {
                                                if p1.uOff == 1 {
                                                    emitUVLCPair(HTTables.encodeUVLC(p1.u), .empty)
                                                }
                                                qx += 1
                                            }

                                            if msOverflow || melOverflow || vlcOverflow {
                                                throw CodecError(.resourceLimitExceeded, "HTJ2K cleanup stream exceeds the remaining block admission budget.")
                                            }
                                        }
                                        swap(&r0, &r3)
                                        swap(&r1, &r4)
                                        swap(&r2, &r5)
                                    }

                                    if msBits > 0 {
                                        let padCount = msMaxBits - msBits
                                        let padOnes = ((UInt64(1) << padCount) - 1) << msBits
                                        let finalByte = UInt8(msPartial | padOnes)
                                        if finalByte != 0xFF {
                                            if msCount < segmentCap {
                                                msPtr[msCount] = finalByte
                                                msCount += 1
                                            } else {
                                                msOverflow = true
                                            }
                                        }
                                    } else if msMaxBits == 7 && msCount > 0 {
                                        msCount -= 1
                                    }

                                    if melRun > 0 {
                                        melEmitBit(1)
                                    }

                                    let shiftedMEL: UInt8 = melRemBits == 8 ? 0 : UInt8((Int(melPartial) << melRemBits) & 0xFF)
                                    let melMask: UInt8 = melRemBits == 8 ? 0 : UInt8((0xFF << melRemBits) & 0xFF)
                                    let vlcMask: UInt8 = vlcUsedBits == 0 ? 0 : UInt8(0xFF >> (8 - vlcUsedBits))
                                    if (melMask | vlcMask) != 0 {
                                        let fuse = shiftedMEL | vlcPartial
                                        if (((fuse ^ shiftedMEL) & melMask) | ((fuse ^ vlcPartial) & vlcMask)) == 0 && fuse != 0xFF {
                                            if melCount < suffixCap {
                                                melPtr[melCount] = fuse
                                                melCount += 1
                                            } else {
                                                melOverflow = true
                                            }
                                        } else {
                                            if melCount < suffixCap {
                                                melPtr[melCount] = shiftedMEL
                                                melCount += 1
                                            } else {
                                                melOverflow = true
                                            }
                                            if vlcCount < suffixCap {
                                                vlcPtr[vlcCount] = vlcPartial
                                                vlcCount += 1
                                            } else {
                                                vlcOverflow = true
                                            }
                                        }
                                    }

                                    guard !msOverflow, !melOverflow, !vlcOverflow else {
                                        throw CodecError(.resourceLimitExceeded, "HTJ2K cleanup stream exceeds the remaining block admission budget.")
                                    }

                                    let scup = melCount + vlcCount
                                    let lcup = msCount + scup

                                    guard scup >= 2, scup <= 4079, lcup >= 2, lcup < 65535 else {
                                        throw CodecError(.resourceLimitExceeded, "HTJ2K cleanup segment lengths (Lcup=\(lcup), Scup=\(scup)) exceed T.814 bounds.")
                                    }
                                    guard lcup <= maximumOutputBytes else {
                                        throw CodecError(.resourceLimitExceeded, "HTJ2K cleanup segment (\(lcup) bytes) exceeds block output limit (\(maximumOutputBytes) bytes).")
                                    }

                                    return [UInt8](unsafeUninitializedCapacity: lcup) { dst, initializedCount in
                                        guard let dstBase = dst.baseAddress else {
                                            initializedCount = 0
                                            return
                                        }
                                        if msCount > 0 {
                                            dstBase.initialize(from: msPtr, count: msCount)
                                        }
                                        if melCount > 0 {
                                            (dstBase + msCount).initialize(from: melPtr, count: melCount)
                                        }
                                        let vlcDst = dstBase + msCount + melCount
                                        for i in 0..<vlcCount {
                                            (vlcDst + i).initialize(to: vlcPtr[vlcCount - 1 - i])
                                        }
                                        dstBase[lcup - 1] = UInt8((scup >> 4) & 0xFF)
                                        dstBase[lcup - 2] = (dstBase[lcup - 2] & 0xF0) | UInt8(scup & 0x0F)
                                        initializedCount = lcup
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Computes both `zBlk=2` (`SigProp` standalone) and `zBlk=3` (`SigProp + MagRef` fused) HT refinement
    /// segments plus exact squared-error distortion deltas in a single pass.
    @inline(__always)
    package static func encodeRefinementPair(
        coefficients: [Int32],
        width: Int,
        height: Int,
        cleanupBandShift: Int,
        causal: Bool,
        isUnquantized: Bool,
        wStep: Double,
        workspace: Workspace
    ) -> (sigPropBytes: [UInt8], sigPropDistDelta: Double, sigPropMagRefBytes: [UInt8], sigPropMagRefDistDelta: Double) {
        guard !coefficients.isEmpty else { return ([], 0.0, [], 0.0) }
        return coefficients.withUnsafeBufferPointer { buf in
            encodeRefinementPair(
                source: buf.baseAddress!,
                stride: width,
                width: width,
                height: height,
                cleanupBandShift: cleanupBandShift,
                causal: causal,
                isUnquantized: isUnquantized,
                wStep: wStep,
                workspace: workspace
            )
        }
    }

    /// Strided zero-copy overload of `encodeRefinementPair` reading directly from a tile wavelet plane.
    package static func encodeRefinementPair(
        source: UnsafePointer<Int32>,
        stride: Int,
        width: Int,
        height: Int,
        cleanupBandShift: Int,
        causal: Bool,
        isUnquantized: Bool,
        wStep: Double,
        workspace: Workspace
    ) -> (sigPropBytes: [UInt8], sigPropDistDelta: Double, sigPropMagRefBytes: [UInt8], sigPropMagRefDistDelta: Double) {
        guard cleanupBandShift >= 1, cleanupBandShift < 31, width > 0, height > 0 else {
            return ([], 0.0, [], 0.0)
        }
        let pStride = width + 2
        let paddedCount = pStride * (height + 2)
        if workspace.paddedSig.count < paddedCount {
            workspace.paddedSig = [UInt8](repeating: 0, count: paddedCount)
        }
        if workspace.refScratch.count < 4096 {
            workspace.refScratch = [UInt8](repeating: 0, count: 4096)
        }

        let refPlane = cleanupBandShift - 1
        let wStepSq = wStep * wStep
        let cleanupMid: Double = 0.5 * Double(Int64(1) << min(cleanupBandShift, 30))
        let refMid: Double = (isUnquantized && refPlane == 0) ? 0.0 : (0.5 * Double(Int64(1) << min(refPlane, 30)))
        let spRecon: Double = Double(Int64(1) << refPlane) + refMid

        return workspace.paddedSig.withUnsafeMutableBufferPointer { sigBuf in
            guard let sigPtr = sigBuf.baseAddress else {
                return ([], 0.0, [], 0.0)
            }
            sigPtr.update(repeating: 0, count: paddedCount)

            var hasAnyCleanupSig = false
            for row in 0..<height {
                let srcRow = row * stride
                let dstRow = (row + 1) * pStride + 1
                for col in 0..<width {
                    let c = source[srcRow + col]
                    if c != 0 && (UInt32(c.magnitude) >> cleanupBandShift) != 0 {
                        sigPtr[dstRow + col] = 1
                        hasAnyCleanupSig = true
                    }
                }
            }
            if !hasAnyCleanupSig {
                return ([], 0.0, [], 0.0)
            }

            return workspace.refScratch.withUnsafeMutableBufferPointer { scratchBuf in
                let spPtr = scratchBuf.baseAddress!
                let mrPtr = spPtr.advanced(by: 2048)
                var spLen = 0
                var mrLen = 0

                var spPartial: UInt8 = 0
                var spUsed = 0
                var spMax = 8
                var spOverflow = false

                @inline(__always)
                func spEmit(_ bit: Int) {
                    spPartial |= UInt8(bit & 1) << spUsed
                    spUsed &+= 1
                    if spUsed == spMax {
                        if spLen < 2046 {
                            spPtr[spLen] = spPartial
                            spLen &+= 1
                        } else {
                            spOverflow = true
                        }
                        spMax = (spPartial == 0xFF) ? 7 : 8
                        spPartial = 0
                        spUsed = 0
                    }
                }

                var deltaDistSP = 0.0
                var stripeY = 0
                while stripeY < height {
                    let stripeEndY = min(stripeY + 4, height)
                    var groupX = 0
                    while groupX < width {
                        let groupEndX = min(groupX + 4, width)
                        for col in groupX..<groupEndX {
                            for row in stripeY..<stripeEndY {
                                let pIdx = (row + 1) * pStride + (col + 1)
                                guard sigPtr[pIdx] == 0 else { continue }

                                var nbr: UInt8 = sigPtr[pIdx - pStride - 1]
                                    | sigPtr[pIdx - pStride]
                                    | sigPtr[pIdx - pStride + 1]
                                    | sigPtr[pIdx - 1]
                                    | sigPtr[pIdx + 1]
                                if !causal || (row + 1 < stripeEndY) {
                                    nbr |= sigPtr[pIdx + pStride - 1]
                                        | sigPtr[pIdx + pStride]
                                        | sigPtr[pIdx + pStride + 1]
                                }
                                if nbr != 0 {
                                    let c = source[row * stride + col]
                                    let mag = UInt32(c.magnitude)
                                    let magBit = Int((mag >> refPlane) & 1)
                                    spEmit(magBit)
                                    if magBit != 0 {
                                        sigPtr[pIdx] = 2
                                        let a = Double(mag)
                                        let newDiff = a - spRecon
                                        deltaDistSP += (a * a - newDiff * newDiff) * wStepSq
                                    }
                                }
                            }
                        }
                        for col in groupX..<groupEndX {
                            for row in stripeY..<stripeEndY {
                                let pIdx = (row + 1) * pStride + (col + 1)
                                if sigPtr[pIdx] == 2 {
                                    let signBit = source[row * stride + col] < 0 ? 1 : 0
                                    spEmit(signBit)
                                }
                            }
                        }
                        groupX += 4
                    }
                    stripeY += 4
                }

                // Build standalone SigProp segment (`zBlk = 2`):
                var spStandalone: [UInt8] = []
                if !spOverflow {
                    var termMax = spMax
                    let extraPartial = (spPartial != 0) ? 1 : 0
                    if spPartial != 0 {
                        termMax = (spPartial == 0xFF) ? 7 : 8
                    }
                    let extraZero = (termMax == 7) ? 1 : 0
                    let standaloneCount = spLen + extraPartial + extraZero
                    if standaloneCount > 0 && standaloneCount < 2047 {
                        spStandalone = [UInt8](unsafeUninitializedCapacity: standaloneCount) { dst, initCount in
                            let dstBase = dst.baseAddress!
                            if spLen > 0 {
                                dstBase.initialize(from: spPtr, count: spLen)
                            }
                            var pos = spLen
                            if extraPartial != 0 {
                                (dstBase + pos).initialize(to: spPartial)
                                pos += 1
                            }
                            if extraZero != 0 {
                                (dstBase + pos).initialize(to: 0x00)
                                pos += 1
                            }
                            initCount = pos
                        }
                    } else if standaloneCount >= 2047 {
                        deltaDistSP = 0.0
                    }
                } else {
                    deltaDistSP = 0.0
                }

                // MagRef pass + fused termination (`zBlk = 3`):
                var mrPartial: UInt8 = 0
                var mrUsed = 0
                var mrLast: UInt8 = 0xFF
                var mrOverflow = spOverflow
                var deltaDistMR = 0.0

                @inline(__always)
                func mrEmit(_ bit: Int) {
                    mrPartial |= UInt8(bit & 1) << mrUsed
                    mrUsed &+= 1
                    if mrLast > 0x8F && mrPartial == 0x7F {
                        mrUsed &+= 1
                    }
                    if mrUsed == 8 {
                        if mrLen < 2046 {
                            mrPtr[mrLen] = mrPartial
                            mrLen &+= 1
                        } else {
                            mrOverflow = true
                        }
                        mrLast = mrPartial
                        mrPartial = 0
                        mrUsed = 0
                    }
                }

                if !mrOverflow {
                    var mrStripeY = 0
                    while mrStripeY < height {
                        let mrStripeEndY = min(mrStripeY + 4, height)
                        for col in 0..<width {
                            for row in mrStripeY..<mrStripeEndY {
                                let pIdx = (row + 1) * pStride + (col + 1)
                                if sigPtr[pIdx] == 1 {
                                    let c = source[row * stride + col]
                                    let mag = Int64(c.magnitude)
                                    let magBit = Int((mag >> refPlane) & 1)
                                    mrEmit(magBit)
                                    let a = Double(mag)
                                    let oldRecon = Double((mag >> cleanupBandShift) << cleanupBandShift) + cleanupMid
                                    let newRecon = Double((mag >> refPlane) << refPlane) + refMid
                                    let oldDiff = a - oldRecon
                                    let newDiff = a - newRecon
                                    deltaDistMR += (oldDiff * oldDiff - newDiff * newDiff) * wStepSq
                                }
                            }
                        }
                        mrStripeY += 4
                    }
                }

                var spMagRef: [UInt8] = []
                if !mrOverflow {
                    var spMask: UInt8 = spUsed == 0 ? 0 : UInt8(0xFF >> (8 - spUsed))
                    if spMax == 7 { spMask |= 0x80 }
                    let mrMask: UInt8 = mrUsed == 0 ? 0 : UInt8(0xFF >> (8 - mrUsed))
                    if (spMask | mrMask) != 0 {
                        let fuse = spPartial | mrPartial
                        if (((fuse ^ spPartial) & spMask) | ((fuse ^ mrPartial) & mrMask)) == 0 {
                            spPtr[spLen] = fuse
                            spLen &+= 1
                        } else {
                            spPtr[spLen] = spPartial
                            spLen &+= 1
                            mrPtr[mrLen] = mrPartial
                            mrLen &+= 1
                        }
                    }
                    let lref = spLen + mrLen
                    if lref > 0 && lref < 2047 {
                        spMagRef = [UInt8](unsafeUninitializedCapacity: lref) { dst, initializedCount in
                            let dstBase = dst.baseAddress!
                            if spLen > 0 {
                                dstBase.initialize(from: spPtr, count: spLen)
                            }
                            if mrLen > 0 {
                                let mrDst = dstBase + spLen
                                for i in 0..<mrLen {
                                    (mrDst + i).initialize(to: mrPtr[mrLen - 1 - i])
                                }
                            }
                            initializedCount = lref
                        }
                    } else if lref >= 2047 {
                        deltaDistMR = -deltaDistSP
                    }
                }

                return (spStandalone, deltaDistSP, spMagRef, deltaDistSP + deltaDistMR)
            }
        }
    }
}

// MARK: - Decoder Bit-Stream Readers (ITU-T Rec. T.814 Clauses 7.1.1–7.1.6)

/// Validates `Dcup` framing and extracts `(lcup, scup, pcup)` per Clause 7.1.1.
@inline(__always)
private func parseCleanupSegmentBounds(_ base: UnsafePointer<UInt8>, count lcup: Int) throws -> (lcup: Int, scup: Int, pcup: Int) {
    guard lcup >= 2, lcup < 65535 else {
        throw CodecError(.malformedInput, "Invalid HT cleanup segment length Lcup=\(lcup).")
    }
    guard base[lcup - 1] != 0xFF else {
        throw CodecError(.malformedInput, "HT cleanup segment terminates with prohibited 0xFF byte.")
    }
    let scup = (Int(base[lcup - 1]) << 4) | Int(base[lcup - 2] & 0x0F)
    guard scup >= 2, scup <= lcup, scup <= 4079 else {
        throw CodecError(.malformedInput, "Invalid HT cleanup suffix length Scup=\(scup) for Lcup=\(lcup).")
    }
    let pcup = lcup - scup
    if pcup > 0, base[pcup - 1] == 0xFF {
        throw CodecError(.malformedInput, "HT cleanup prefix terminates with prohibited 0xFF byte at Pcup-1.")
    }
    var i = 0
    let limit = lcup - 1
    while i + 8 <= limit {
        let lo = UInt32(base[i]) | (UInt32(base[i + 1]) << 8) | (UInt32(base[i + 2]) << 16) | (UInt32(base[i + 3]) << 24)
        let hi = UInt32(base[i + 4]) | (UInt32(base[i + 5]) << 8) | (UInt32(base[i + 6]) << 16) | (UInt32(base[i + 7]) << 24)
        let invLo = ~lo
        let invHi = ~hi
        if (((invLo &- 0x0101_0101) & lo & 0x8080_8080) | ((invHi &- 0x0101_0101) & hi & 0x8080_8080)) != 0 {
            for k in i..<(i + 8) where base[k] == 0xFF {
                guard base[k + 1] <= 0x8F else {
                    throw CodecError(.malformedInput, "Prohibited marker code > 0xFF8F inside HT cleanup segment.")
                }
            }
        }
        i += 8
    }
    while i < limit {
        if base[i] == 0xFF {
            guard base[i + 1] <= 0x8F else {
                throw CodecError(.malformedInput, "Prohibited marker code > 0xFF8F inside HT cleanup segment.")
            }
        }
        i += 1
    }
    return (lcup, scup, pcup)
}

/// Forward little-endian MagSgn bit-stream reader (`initMS` / `importMagSgnBit`, Clause 7.1.2).
/// Loads bytes strictly on demand so unconsumed prefix padding (`0xFF80...0xFF8F`) is untouched.
private struct MagSgnBitReader {
    let base: UnsafePointer<UInt8>
    let pcup: Int
    private var pos: Int = 0
    private var lastByte: UInt8 = 0
    private var bitBuffer: UInt64 = 0
    private var bitCount: Int = 0

    init(base: UnsafePointer<UInt8>, pcup: Int) {
        self.base = base
        self.pcup = pcup
    }

    @inline(__always)
    private mutating func readUpTo32Bits(_ count: Int) throws -> UInt64 {
        if bitCount < count && lastByte != 0xFF && bitCount <= 24 && pos + 4 <= pcup {
            let word = UInt32(base[pos])
                | (UInt32(base[pos + 1]) << 8)
                | (UInt32(base[pos + 2]) << 16)
                | (UInt32(base[pos + 3]) << 24)
            let inv = ~word
            if ((inv &- 0x0101_0101) & word & 0x8080_8080) == 0 {
                lastByte = UInt8(truncatingIfNeeded: word >> 24)
                pos += 4
                bitBuffer |= UInt64(word) << bitCount
                bitCount += 32
            }
        }
        while bitCount < count {
            let loadBits = (lastByte == 0xFF) ? 7 : 8
            let byte: UInt8
            if pos < pcup {
                byte = base[pos]
                if loadBits == 7 && (byte & 0x80) != 0 {
                    throw CodecError(.malformedInput, "Non-zero stuff bit in HT MagSgn byte following 0xFF.")
                }
            } else if pos == pcup {
                byte = 0xFF
            } else {
                throw CodecError(.malformedInput, "HT MagSgn bit-stream overrun past Pcup.")
            }
            lastByte = byte
            pos += 1
            let masked: UInt8 = loadBits == 7 ? (byte & 0x7F) : byte
            bitBuffer |= UInt64(masked) << bitCount
            bitCount += loadBits
        }
        let mask = (UInt64(1) << count) - 1
        let value = bitBuffer & mask
        bitBuffer >>= count
        bitCount -= count
        return value
    }

    @inline(__always)
    mutating func readBits(_ count: Int) throws -> UInt64 {
        if count <= 32 {
            return try readUpTo32Bits(count)
        }
        let low = try readUpTo32Bits(32)
        let high = try readUpTo32Bits(count - 32)
        return low | (high << 32)
    }
}

/// Forward big-endian MEL bit-stream and adaptive run-length symbol decoder (`initMEL` / `importMELBit` &
/// `initMELDecoder` / `decodeMELSym`, Clauses 7.1.3 & 7.3.3).
private struct MELSymbolDecoder {
    let base: UnsafePointer<UInt8>
    let melExps: UnsafePointer<Int>
    let lcup: Int
    private var melPos: Int
    private var melBits: Int = 0
    private var melTmp: UInt8 = 0
    private var stateIndex: Int = 0
    private var runCount: Int = 0
    private var pendingOne: Bool = false

    init(base: UnsafePointer<UInt8>, melExps: UnsafePointer<Int>, lcup: Int, pcup: Int) {
        self.base = base
        self.melExps = melExps
        self.lcup = lcup
        self.melPos = pcup
    }

    @inline(__always)
    private func modDcup(_ index: Int) -> UInt8 {
        if index == lcup - 1 { return 0xFF }
        if index == lcup - 2 { return base[index] | 0x0F }
        return base[index]
    }

    @inline(__always)
    private mutating func importBit() -> Int {
        if melBits == 0 {
            melBits = (melTmp == 0xFF) ? 7 : 8
            if melPos < lcup {
                melTmp = modDcup(melPos)
                melPos += 1
            } else {
                melTmp = 0xFF
            }
        }
        melBits -= 1
        return Int((melTmp >> melBits) & 1)
    }

    @inline(__always)
    mutating func decodeSymbol() -> Int {
        if runCount == 0 && !pendingOne {
            var exponent = melExps[stateIndex]
            let bit = importBit()
            if bit == 1 {
                runCount = 1 << exponent
                if stateIndex < 12 {
                    stateIndex += 1
                }
            } else {
                runCount = 0
                while exponent > 0 {
                    runCount = (runCount << 1) | importBit()
                    exponent -= 1
                }
                if stateIndex > 0 {
                    stateIndex -= 1
                }
                pendingOne = true
            }
        }
        if runCount > 0 {
            runCount -= 1
            return 0
        }
        pendingOne = false
        return 1
    }
}

/// Backward little-endian VLC bit-stream reader (`initVLC` / `importVLCBit`, Clause 7.1.4).
private struct VLCBitReader {
    let base: UnsafePointer<UInt8>
    let tbl0: UnsafePointer<HTTables.CxtVLCDecodeEntry>
    let tbl1: UnsafePointer<HTTables.CxtVLCDecodeEntry>
    let pcup: Int
    private var vlcPos: Int
    private var vlcLast: UInt8
    private var bitBuffer: UInt64
    private var bitCount: Int

    init(
        base: UnsafePointer<UInt8>,
        tbl0: UnsafePointer<HTTables.CxtVLCDecodeEntry>,
        tbl1: UnsafePointer<HTTables.CxtVLCDecodeEntry>,
        lcup: Int,
        pcup: Int
    ) {
        self.base = base
        self.tbl0 = tbl0
        self.tbl1 = tbl1
        self.pcup = pcup
        self.vlcPos = lcup - 3
        let modSecondLast = base[lcup - 2] | 0x0F
        self.vlcLast = modSecondLast
        let initialTmp = modSecondLast >> 4
        let initialBits = ((initialTmp & 0x07) < 7) ? 4 : 3
        self.bitBuffer = UInt64(initialTmp & ((1 << initialBits) - 1))
        self.bitCount = initialBits
    }

    @inline(__always)
    private mutating func fill(minBits: Int) {
        if bitCount < minBits && vlcLast <= 0x8F && bitCount <= 32 && vlcPos - 3 >= pcup {
            let b0 = base[vlcPos]
            let b1 = base[vlcPos - 1]
            let b2 = base[vlcPos - 2]
            let b3 = base[vlcPos - 3]
            if b0 <= 0x8F && b1 <= 0x8F && b2 <= 0x8F {
                let word = UInt64(b0) | (UInt64(b1) << 8) | (UInt64(b2) << 16) | (UInt64(b3) << 24)
                vlcPos -= 4
                vlcLast = b3
                bitBuffer |= word << bitCount
                bitCount += 32
                return
            }
        }
        while bitCount < minBits && vlcPos >= pcup {
            let rawByte = base[vlcPos]
            vlcPos -= 1
            let usableBits = (vlcLast > 0x8F && (rawByte & 0x7F) == 0x7F) ? 7 : 8
            vlcLast = rawByte
            let masked: UInt8 = usableBits == 7 ? 0x7F : rawByte
            bitBuffer |= UInt64(masked) << bitCount
            bitCount += usableBits
        }
    }

    @inline(__always)
    mutating func decodeCxtVLC(context: Int, isInitialRow: Bool) throws -> HTTables.CxtVLCDecodeEntry {
        fill(minBits: 7)
        let peek7 = Int(bitBuffer & 0x7F)
        let tableIndex = (context << 7) | peek7
        let entry = isInitialRow ? tbl0[tableIndex] : tbl1[tableIndex]
        let len = Int(entry.bitLength)
        guard bitCount >= len else {
            throw CodecError(.malformedInput, "HT VLC bit-stream overrun past Pcup during CxtVLC decode.")
        }
        bitBuffer >>= len
        bitCount -= len
        return entry
    }

    @inline(__always)
    mutating func readBits(_ count: Int) throws -> Int {
        guard count > 0 else { return 0 }
        fill(minBits: count)
        guard bitCount >= count else {
            throw CodecError(.malformedInput, "HT VLC bit-stream overrun past Pcup during U-VLC decode.")
        }
        let value = Int(bitBuffer & ((UInt64(1) << count) - 1))
        bitBuffer >>= count
        bitCount -= count
        return value
    }

    @inline(__always)
    mutating func decodeUPrefix() throws -> Int {
        fill(minBits: 3)
        if bitCount >= 3 {
            let b3 = Int(bitBuffer & 0x07)
            if (b3 & 1) != 0 {
                bitBuffer >>= 1
                bitCount -= 1
                return 1
            }
            if (b3 & 2) != 0 {
                bitBuffer >>= 2
                bitCount -= 2
                return 2
            }
            bitBuffer >>= 3
            bitCount -= 3
            return (b3 & 4) != 0 ? 3 : 5
        }
        if try readBits(1) == 1 { return 1 }
        if try readBits(1) == 1 { return 2 }
        return (try readBits(1) == 1) ? 3 : 5
    }

    @inline(__always)
    mutating func decodeUSuffix(prefix: Int) throws -> Int {
        if prefix < 3 { return 0 }
        if prefix == 3 { return try readBits(1) }
        return try readBits(5)
    }

    @inline(__always)
    mutating func decodeUExtension(suffix: Int) throws -> Int {
        if suffix < 28 { return 0 }
        return try readBits(4)
    }
}

/// Forward little-endian SigProp bit-stream reader (`initSP` / `importSigPropBit`, Clause 7.1.5).
private struct SigPropBitReader {
    let bytes: [UInt8]
    private var spPos: Int = 0
    private var spBits: Int = 0
    private var spTmp: UInt8 = 0
    private var spLast: UInt8 = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    @inline(__always)
    mutating func readBit() throws -> Int {
        if spBits == 0 {
            let maxBits = (spLast == 0xFF) ? 7 : 8
            if spPos < bytes.count {
                spTmp = bytes[spPos]
                spPos += 1
                if maxBits == 7 && (spTmp & 0x80) != 0 {
                    throw CodecError(.malformedInput, "Non-zero stuff bit in HT SigProp byte following 0xFF.")
                }
            } else {
                spTmp = 0
            }
            spLast = spTmp
            spBits = maxBits
        }
        let bit = Int(spTmp & 1)
        spTmp >>= 1
        spBits -= 1
        return bit
    }
}

/// Backward little-endian MagRef bit-stream reader (`initMR` / `importMagRefBit`, Clause 7.1.6).
private struct MagRefBitReader {
    let bytes: [UInt8]
    private var mrPos: Int
    private var mrBits: Int = 0
    private var mrLast: UInt8 = 0xFF
    private var mrTmp: UInt8 = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
        self.mrPos = bytes.count - 1
    }

    @inline(__always)
    mutating func readBit() -> Int {
        if mrBits == 0 {
            if mrPos >= 0 {
                mrTmp = bytes[mrPos]
                mrPos -= 1
            } else {
                mrTmp = 0
            }
            mrBits = (mrLast > 0x8F && (mrTmp & 0x7F) == 0x7F) ? 7 : 8
            mrLast = mrTmp
        }
        let bit = Int(mrTmp & 1)
        mrTmp >>= 1
        mrBits -= 1
        return bit
    }
}

// MARK: - HTBlockDecoder

package enum HTBlockDecoder {

    /// Maximum extended subband bit-plane count supported in `Int64` HT decoding paths.
    package static let maximumExtendedKMax: Int = 62

    /// Zero-allocation strided HT Cleanup pass decoder writing directly into a pre-zeroed component wavelet plane.
    package static func decodeCleanupStrided(
        blockBase: UnsafePointer<UInt8>,
        blockCount: Int,
        planeBase: UnsafeMutablePointer<Int32>,
        planeOrigin: Int,
        stride: Int,
        width: Int,
        height: Int,
        kMax: Int,
        missingMSBs: Int
    ) throws {
        _ = try validateBlockGeometry(width: width, height: height, caller: "HTBlockDecoder.decodeCleanupStrided")
        guard kMax >= 1, kMax <= 31, missingMSBs >= 0 else {
            throw CodecError(.malformedInput, "Invalid HT cleanup kMax (\(kMax)) or missingMSBs (\(missingMSBs)).")
        }
        if blockCount == 0 { return }
        guard missingMSBs <= kMax - 1 else {
            throw CodecError(.malformedInput, "HT cleanup missingMSBs (\(missingMSBs)) exceeds kMax - 1 (\(kMax - 1)).")
        }

        let bandShift = (kMax - 1) - missingMSBs
        let allowedCleanupPlanes = missingMSBs + 1
        let maxMuExclusive = UInt64(1) << allowedCleanupPlanes

        let (lcup, _, pcup) = try parseCleanupSegmentBounds(blockBase, count: blockCount)
        let qw = (width + 1) / 2
        let qh = (height + 1) / 2
        let rowCap = max(1, qw)

        try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: rowCap * 6) { rowScratch in
            guard let scratchBase = rowScratch.baseAddress else { return }
            scratchBase.initialize(repeating: 0, count: rowCap * 6)
            var r0 = scratchBase
            var r1 = scratchBase.advanced(by: rowCap)
            var r2 = scratchBase.advanced(by: rowCap * 2)
            var r3 = scratchBase.advanced(by: rowCap * 3)
            var r4 = scratchBase.advanced(by: rowCap * 4)
            var r5 = scratchBase.advanced(by: rowCap * 5)

            try HTTables.cxtVLCDecodeTable0.withUnsafeBufferPointer { tbl0Buf in
                try HTTables.cxtVLCDecodeTable1.withUnsafeBufferPointer { tbl1Buf in
                    try HTTables.melExponents.withUnsafeBufferPointer { melExpBuf in
                        var magSgnReader = MagSgnBitReader(base: blockBase, pcup: pcup)
                        var melDecoder = MELSymbolDecoder(base: blockBase, melExps: melExpBuf.baseAddress!, lcup: lcup, pcup: pcup)
                        var vlcReader = VLCBitReader(
                            base: blockBase,
                            tbl0: tbl0Buf.baseAddress!,
                            tbl1: tbl1Buf.baseAddress!,
                            lcup: lcup,
                            pcup: pcup
                        )

                        @inline(__always)
                        func decodeSigEMB(qy: Int, qx: Int, leftRho: Int) throws -> (entry: HTTables.CxtVLCDecodeEntry, maxNeighborE: Int) {
                            if qy == 0 {
                                let context: Int
                                if qx == 0 {
                                    context = 0
                                } else {
                                    let fOrSf = (leftRho & 0x03) != 0 ? 1 : 0
                                    let wAndSw = (leftRho >> 1) & 0x06
                                    context = fOrSf | wAndSw
                                }
                                if context == 0 && melDecoder.decodeSymbol() == 0 {
                                    return (HTTables.CxtVLCDecodeEntry(rho: 0, uOff: 0, embKnown: 0, embOne: 0, bitLength: 0), 0)
                                }
                                return (try vlcReader.decodeCxtVLC(context: context, isInitialRow: true), 0)
                            } else {
                                let nw = qx > 0 ? Int((r0[qx - 1] >> 3) & 1) : 0
                                let n = Int((r0[qx] >> 1) & 1)
                                let ne = Int((r0[qx] >> 3) & 1)
                                let nf = (qx + 1 < qw) ? Int((r0[qx + 1] >> 1) & 1) : 0
                                let wOrSw = qx > 0 ? (((leftRho & 0x0C) != 0) ? 1 : 0) : 0
                                let context = (nw | n) | (wOrSw << 1) | ((ne | nf) << 2)

                                let eNW = qx > 0 ? Int(r2[qx - 1]) : 0
                                let eN = Int(r1[qx])
                                let eNE = Int(r2[qx])
                                let eNF = (qx + 1 < qw) ? Int(r1[qx + 1]) : 0
                                let maxNeighborE = max(max(eNW, eN), max(eNE, eNF))

                                if context == 0 && melDecoder.decodeSymbol() == 0 {
                                    return (HTTables.CxtVLCDecodeEntry(rho: 0, uOff: 0, embKnown: 0, embOne: 0, bitLength: 0), maxNeighborE)
                                }
                                return (try vlcReader.decodeCxtVLC(context: context, isInitialRow: false), maxNeighborE)
                            }
                        }

                        @inline(__always)
                        func unpackQuad(
                            entry: HTTables.CxtVLCDecodeEntry,
                            u: Int,
                            maxNeighborE: Int,
                            qy: Int,
                            qx: Int
                        ) throws -> (e1: UInt8, e3: UInt8) {
                            let rho = Int(entry.rho)
                            guard rho != 0 else { return (0, 0) }

                            let x0 = qx * 2
                            let y0 = qy * 2
                            var invalidMask = 0
                            if x0 + 1 >= width { invalidMask |= 0b1100 }
                            if y0 + 1 >= height { invalidMask |= 0b1010 }
                            guard (rho & invalidMask) == 0 else {
                                throw CodecError(.malformedInput, "Non-zero significance decoded in padded HT quad sample.")
                            }

                            let kappa: Int = (qy == 0) ? 1 : max(1, (entry.rho.nonzeroBitCount > 1 ? 1 : 0) * (maxNeighborE - 1))
                            let upperU = kappa + u
                            guard upperU <= 31 else {
                                throw CodecError(.malformedInput, "HT quad exponent bound U_q (\(upperU)) exceeds 32-bit cleanup range.")
                            }

                            let known = Int(entry.embKnown)
                            let knownOne = Int(entry.embOne)
                            var e1: UInt8 = 0
                            var e3: UInt8 = 0
                            let row0 = planeOrigin + y0 * stride

                            if (rho & 1) != 0 {
                                let m = upperU - (known & 1)
                                guard m >= 1, m <= 31 else {
                                    throw CodecError(.malformedInput, "Invalid HT MagSgn bit count m_n=\(m).")
                                }
                                let iFlag = UInt64(knownOne & 1)
                                let v = (try magSgnReader.readBits(m)) + (iFlag << m)
                                let mu = (v >> 1) + 1
                                guard mu < maxMuExclusive else {
                                    throw CodecError(.malformedInput, "Decoded HT cleanup magnitude exceeds subband bit-plane bound.")
                                }
                                let scaled = mu << bandShift
                                guard scaled <= UInt64(Int32.max) else {
                                    throw CodecError(.malformedInput, "Scaled HT cleanup coefficient overflows Int32 range.")
                                }
                                planeBase[row0 + x0] = (v & 1) == 1 ? -Int32(scaled) : Int32(scaled)
                            }
                            if (rho & 2) != 0 {
                                let m = upperU - ((known >> 1) & 1)
                                guard m >= 1, m <= 31 else {
                                    throw CodecError(.malformedInput, "Invalid HT MagSgn bit count m_n=\(m).")
                                }
                                let iFlag = UInt64((knownOne >> 1) & 1)
                                let v = (try magSgnReader.readBits(m)) + (iFlag << m)
                                let mu = (v >> 1) + 1
                                guard mu < maxMuExclusive else {
                                    throw CodecError(.malformedInput, "Decoded HT cleanup magnitude exceeds subband bit-plane bound.")
                                }
                                let scaled = mu << bandShift
                                guard scaled <= UInt64(Int32.max) else {
                                    throw CodecError(.malformedInput, "Scaled HT cleanup coefficient overflows Int32 range.")
                                }
                                planeBase[row0 + stride + x0] = (v & 1) == 1 ? -Int32(scaled) : Int32(scaled)
                                e1 = UInt8(truncatingIfNeeded: 64 - ((mu << 1) - 1).leadingZeroBitCount)
                            }
                            if (rho & 4) != 0 {
                                let m = upperU - ((known >> 2) & 1)
                                guard m >= 1, m <= 31 else {
                                    throw CodecError(.malformedInput, "Invalid HT MagSgn bit count m_n=\(m).")
                                }
                                let iFlag = UInt64((knownOne >> 2) & 1)
                                let v = (try magSgnReader.readBits(m)) + (iFlag << m)
                                let mu = (v >> 1) + 1
                                guard mu < maxMuExclusive else {
                                    throw CodecError(.malformedInput, "Decoded HT cleanup magnitude exceeds subband bit-plane bound.")
                                }
                                let scaled = mu << bandShift
                                guard scaled <= UInt64(Int32.max) else {
                                    throw CodecError(.malformedInput, "Scaled HT cleanup coefficient overflows Int32 range.")
                                }
                                planeBase[row0 + x0 + 1] = (v & 1) == 1 ? -Int32(scaled) : Int32(scaled)
                            }
                            if (rho & 8) != 0 {
                                let m = upperU - ((known >> 3) & 1)
                                guard m >= 1, m <= 31 else {
                                    throw CodecError(.malformedInput, "Invalid HT MagSgn bit count m_n=\(m).")
                                }
                                let iFlag = UInt64((knownOne >> 3) & 1)
                                let v = (try magSgnReader.readBits(m)) + (iFlag << m)
                                let mu = (v >> 1) + 1
                                guard mu < maxMuExclusive else {
                                    throw CodecError(.malformedInput, "Decoded HT cleanup magnitude exceeds subband bit-plane bound.")
                                }
                                let scaled = mu << bandShift
                                guard scaled <= UInt64(Int32.max) else {
                                    throw CodecError(.malformedInput, "Scaled HT cleanup coefficient overflows Int32 range.")
                                }
                                planeBase[row0 + stride + x0 + 1] = (v & 1) == 1 ? -Int32(scaled) : Int32(scaled)
                                e3 = UInt8(truncatingIfNeeded: 64 - ((mu << 1) - 1).leadingZeroBitCount)
                            }
                            return (e1, e3)
                        }

                        for qy in 0..<qh {
                            var leftRho = 0
                            var qx = 0
                            while qx < qw {
                                let (entry1, maxNE1) = try decodeSigEMB(qy: qy, qx: qx, leftRho: leftRho)
                                leftRho = Int(entry1.rho)
                                r3[qx] = entry1.rho

                                if qx + 1 < qw {
                                    let (entry2, maxNE2) = try decodeSigEMB(qy: qy, qx: qx + 1, leftRho: leftRho)
                                    leftRho = Int(entry2.rho)
                                    r3[qx + 1] = entry2.rho

                                    var u1 = 0
                                    var u2 = 0
                                    if qy == 0 && entry1.uOff == 1 && entry2.uOff == 1 {
                                        let jointMel = melDecoder.decodeSymbol()
                                        if jointMel == 1 {
                                            let pfx1 = try vlcReader.decodeUPrefix()
                                            let pfx2 = try vlcReader.decodeUPrefix()
                                            let sfx1 = try vlcReader.decodeUSuffix(prefix: pfx1)
                                            let sfx2 = try vlcReader.decodeUSuffix(prefix: pfx2)
                                            let ext1 = try vlcReader.decodeUExtension(suffix: sfx1)
                                            let ext2 = try vlcReader.decodeUExtension(suffix: sfx2)
                                            u1 = 2 + pfx1 + sfx1 + 4 * ext1
                                            u2 = 2 + pfx2 + sfx2 + 4 * ext2
                                        } else {
                                            let pfx1 = try vlcReader.decodeUPrefix()
                                            let pfx2: Int = pfx1 > 2 ? ((try vlcReader.readBits(1)) + 1) : (try vlcReader.decodeUPrefix())
                                            let sfx1 = try vlcReader.decodeUSuffix(prefix: pfx1)
                                            let sfx2 = try vlcReader.decodeUSuffix(prefix: pfx2)
                                            let ext1 = try vlcReader.decodeUExtension(suffix: sfx1)
                                            let ext2 = try vlcReader.decodeUExtension(suffix: sfx2)
                                            u1 = pfx1 + sfx1 + 4 * ext1
                                            u2 = pfx2 + sfx2 + 4 * ext2
                                        }
                                    } else {
                                        let pfx1 = entry1.uOff == 1 ? (try vlcReader.decodeUPrefix()) : 0
                                        let pfx2 = entry2.uOff == 1 ? (try vlcReader.decodeUPrefix()) : 0
                                        let sfx1 = entry1.uOff == 1 ? (try vlcReader.decodeUSuffix(prefix: pfx1)) : 0
                                        let sfx2 = entry2.uOff == 1 ? (try vlcReader.decodeUSuffix(prefix: pfx2)) : 0
                                        let ext1 = entry1.uOff == 1 ? (try vlcReader.decodeUExtension(suffix: sfx1)) : 0
                                        let ext2 = entry2.uOff == 1 ? (try vlcReader.decodeUExtension(suffix: sfx2)) : 0
                                        u1 = pfx1 + sfx1 + 4 * ext1
                                        u2 = pfx2 + sfx2 + 4 * ext2
                                    }

                                    let exps1 = try unpackQuad(entry: entry1, u: u1, maxNeighborE: maxNE1, qy: qy, qx: qx)
                                    let exps2 = try unpackQuad(entry: entry2, u: u2, maxNeighborE: maxNE2, qy: qy, qx: qx + 1)
                                    r4[qx] = exps1.e1
                                    r5[qx] = exps1.e3
                                    r4[qx + 1] = exps2.e1
                                    r5[qx + 1] = exps2.e3
                                    qx += 2
                                } else {
                                    var u1 = 0
                                    if entry1.uOff == 1 {
                                        let pfx1 = try vlcReader.decodeUPrefix()
                                        let sfx1 = try vlcReader.decodeUSuffix(prefix: pfx1)
                                        let ext1 = try vlcReader.decodeUExtension(suffix: sfx1)
                                        u1 = pfx1 + sfx1 + 4 * ext1
                                    }
                                    let exps1 = try unpackQuad(entry: entry1, u: u1, maxNeighborE: maxNE1, qy: qy, qx: qx)
                                    r4[qx] = exps1.e1
                                    r5[qx] = exps1.e3
                                    qx += 1
                                }
                            }
                            swap(&r0, &r3)
                            swap(&r1, &r4)
                            swap(&r2, &r5)
                        }
                    }
                }
            }
        }
    }

    /// Decodes a single HT Cleanup pass into signed 32-bit wavelet coefficients per ITU-T Rec. T.814
    /// Clauses 7.1–7.3 and 7.6.
    package static func decodeCleanup(
        block: [UInt8],
        width: Int,
        height: Int,
        kMax: Int,
        missingMSBs: Int
    ) throws -> [Int32] {
        let sampleCount = try validateBlockGeometry(width: width, height: height, caller: "HTBlockDecoder.decodeCleanup")
        guard kMax >= 1, kMax <= 31, missingMSBs >= 0 else {
            throw CodecError(.malformedInput, "Invalid HT cleanup kMax (\(kMax)) or missingMSBs (\(missingMSBs)).")
        }

        if block.isEmpty {
            return [Int32](repeating: 0, count: sampleCount)
        }

        var output = [Int32](repeating: 0, count: sampleCount)
        try block.withUnsafeBufferPointer { blkBuf in
            try output.withUnsafeMutableBufferPointer { outBuf in
                try decodeCleanupStrided(
                    blockBase: blkBuf.baseAddress!,
                    blockCount: blkBuf.count,
                    planeBase: outBuf.baseAddress!,
                    planeOrigin: 0,
                    stride: width,
                    width: width,
                    height: height,
                    kMax: kMax,
                    missingMSBs: missingMSBs
                )
            }
        }
        return output
    }

    /// Decodes an HT code-block across leading placeholder passes, single or multiple HT sets
    /// (`Cleanup` + optional `SigProp` + optional `MagRef`), causal mode, and optional midpoint reconstruction.
    package static func decodeHTCodeBlock(
        segments: [HTSegmentInput],
        zeroBitPlanes: Int,
        totalPasses: Int,
        width: Int,
        height: Int,
        kMax: Int,
        causal: Bool = false,
        allowMultiHT: Bool = false,
        midpointReconstruction: Bool = false
    ) throws -> [Int64] {
        return try decodeHTCodeBlockWithPlanes(
            segments: segments,
            zeroBitPlanes: zeroBitPlanes,
            totalPasses: totalPasses,
            width: width,
            height: height,
            kMax: kMax,
            causal: causal,
            allowMultiHT: allowMultiHT,
            midpointReconstruction: midpointReconstruction
        ).0
    }

    /// Decodes an HT code-block and also returns each sample's last decoded bit-plane index (`-1` for zero samples)
    /// for floating-point midpoint inverse quantisation.
    package static func decodeHTCodeBlockWithPlanes(
        segments: [HTSegmentInput],
        zeroBitPlanes: Int,
        totalPasses: Int,
        width: Int,
        height: Int,
        kMax: Int,
        causal: Bool = false,
        allowMultiHT: Bool = false,
        midpointReconstruction: Bool = false
    ) throws -> ([Int64], [Int8]) {
        let sampleCount = try validateBlockGeometry(width: width, height: height, caller: "HTBlockDecoder.decodeHTCodeBlock")
        if totalPasses == 0 {
            return (
                [Int64](repeating: 0, count: sampleCount),
                [Int8](repeating: -1, count: sampleCount)
            )
        }
        guard totalPasses > 0, !segments.isEmpty else {
            throw CodecError(.malformedInput, "HT code-block signals \(totalPasses) passes with no codeword segments.")
        }
        guard kMax >= 1, kMax <= maximumExtendedKMax, zeroBitPlanes >= 0 else {
            throw CodecError(.malformedInput, "Invalid HT code-block kMax (\(kMax)) or zeroBitPlanes (\(zeroBitPlanes)).")
        }

        var passSum = 0
        for seg in segments {
            guard seg.passes >= 1 else {
                throw CodecError(.malformedInput, "HT codeword segment has non-positive pass count (\(seg.passes)).")
            }
            let (nextSum, ov) = passSum.addingReportingOverflow(seg.passes)
            guard !ov else {
                throw CodecError(.malformedInput, "HT codeword segment pass count overflows.")
            }
            passSum = nextSum
        }
        guard passSum == totalPasses else {
            throw CodecError(.malformedInput, "HT codeword segment pass counts (\(passSum)) do not match totalPasses (\(totalPasses)).")
        }

        // Locate the first non-empty segment to determine placeholder sets `P0` (Annex B.1–B.3):
        guard let firstNonEmptyIdx = segments.firstIndex(where: { !$0.data.isEmpty }) else {
            // All segments have zero length (Z_blk == 0 across placeholder / empty passes):
            return (
                [Int64](repeating: 0, count: sampleCount),
                [Int8](repeating: -1, count: sampleCount)
            )
        }

        var passesUpToFirstCleanup = 0
        for idx in 0...firstNonEmptyIdx {
            passesUpToFirstCleanup += segments[idx].passes
        }
        guard passesUpToFirstCleanup >= 1, (passesUpToFirstCleanup - 1) % 3 == 0 else {
            throw CodecError(
                .malformedInput,
                "First non-empty HT cleanup segment ends at pass \(passesUpToFirstCleanup), violating 3*P0 + 1 alignment."
            )
        }
        let p0 = (passesUpToFirstCleanup - 1) / 3

        struct ParsedHTSet {
            let sSkip: Int
            var passCount: Int
            var cleanupBytes: [UInt8]
            var refinementBytes: [UInt8]
        }

        var htSets: [ParsedHTSet] = []
        var activeSet = ParsedHTSet(
            sSkip: 0,
            passCount: 1,
            cleanupBytes: segments[firstNonEmptyIdx].data,
            refinementBytes: []
        )

        for seg in segments[(firstNonEmptyIdx + 1)...] {
            if seg.data.isEmpty {
                var rem = seg.passes
                while rem > 0 {
                    if activeSet.passCount == 3 {
                        htSets.append(activeSet)
                        activeSet = ParsedHTSet(
                            sSkip: htSets.count,
                            passCount: 0,
                            cleanupBytes: [],
                            refinementBytes: []
                        )
                    }
                    let step = min(rem, 3 - activeSet.passCount)
                    activeSet.passCount += step
                    rem -= step
                }
            } else {
                if activeSet.passCount == 3 {
                    htSets.append(activeSet)
                    activeSet = ParsedHTSet(
                        sSkip: htSets.count,
                        passCount: 0,
                        cleanupBytes: [],
                        refinementBytes: []
                    )
                }
                if activeSet.passCount == 0 {
                    guard seg.passes == 1 else {
                        throw CodecError(.malformedInput, "Non-empty HT cleanup segment spans \(seg.passes) passes (expected 1).")
                    }
                    activeSet.cleanupBytes = seg.data
                    activeSet.passCount = 1
                } else if activeSet.passCount == 1 {
                    guard seg.passes == 1 || seg.passes == 2 else {
                        throw CodecError(.malformedInput, "Non-empty HT refinement segment spans \(seg.passes) passes (expected 1 or 2).")
                    }
                    activeSet.refinementBytes.append(contentsOf: seg.data)
                    activeSet.passCount += seg.passes
                } else {
                    // activeSet.passCount == 2 (MagRef continuation segment)
                    guard seg.passes == 1 else {
                        throw CodecError(.malformedInput, "Non-empty HT MagRef segment spans \(seg.passes) passes (expected 1).")
                    }
                    activeSet.refinementBytes.append(contentsOf: seg.data)
                    activeSet.passCount = 3
                }
            }
        }
        htSets.append(activeSet)

        if !allowMultiHT && htSets.count > 1 {
            throw CodecError(.malformedInput, "Multiple HT sets (\(htSets.count)) are prohibited when SINGLEHT is active.")
        }

        var latestCoefficients = [Int64](repeating: 0, count: sampleCount)
        var latestPlanes = [Int8](repeating: -1, count: sampleCount)

        for htSet in htSets {
            if htSet.cleanupBytes.isEmpty {
                // Annex B.3: if Lcup == 0, Lref shall also be 0 and Z_blk = 0.
                guard htSet.refinementBytes.isEmpty else {
                    throw CodecError(.malformedInput, "HT set has non-empty refinement segment with empty cleanup segment.")
                }
                continue
            }

            let zBlk: Int
            if htSet.refinementBytes.isEmpty {
                zBlk = 1
            } else {
                zBlk = htSet.passCount // 2 or 3 (Annex B.3)
            }

            let sBlk = zeroBitPlanes + p0 + htSet.sSkip
            guard sBlk <= kMax - 1 else {
                throw CodecError(.malformedInput, "HT set S_blk (\(sBlk)) exceeds kMax - 1 (\(kMax - 1)).")
            }
            let cleanupShift = (kMax - 1) - sBlk
            if zBlk >= 2 {
                guard cleanupShift >= 1 else {
                    throw CodecError(.malformedInput, "HT refinement pass present when cleanup already reached bit-plane 0.")
                }
            }

            let (cleanupMag, signs) = try decodeCleanup64(
                block: htSet.cleanupBytes,
                width: width,
                height: height,
                allowedPlanes: sBlk + 1
            )

            var refinedFlag = [UInt8](repeating: 0, count: sampleCount)
            var refinedBit = [UInt8](repeating: 0, count: sampleCount)
            var finalSigns = signs

            if zBlk >= 2 {
                let dref = htSet.refinementBytes
                let lref = dref.count
                guard lref < 2047 else {
                    throw CodecError(.malformedInput, "HT refinement segment length Lref=\(lref) exceeds 2046.")
                }
                if lref > 0 {
                    guard dref[lref - 1] != 0xFF else {
                        throw CodecError(.malformedInput, "HT refinement segment terminates with prohibited 0xFF byte.")
                    }
                    for i in 0..<(lref - 1) where dref[i] == 0xFF {
                        guard dref[i + 1] <= 0x8F else {
                            throw CodecError(.malformedInput, "Prohibited marker code > 0xFF8F inside HT refinement segment.")
                        }
                    }
                }

                // HT SigProp pass (Clause 7.4):
                var spReader = SigPropBitReader(bytes: dref)
                var stripeY = 0
                while stripeY < height {
                    let stripeEndY = min(stripeY + 4, height)
                    var groupX = 0
                    while groupX < width {
                        let groupEndX = min(groupX + 4, width)

                        for col in groupX..<groupEndX {
                            for row in stripeY..<stripeEndY {
                                let idx = row * width + col
                                guard cleanupMag[idx] == 0 else { continue }

                                let minNY = max(0, row - 1)
                                let maxNY = causal ? min(stripeEndY - 1, row + 1) : min(height - 1, row + 1)
                                let minNX = max(0, col - 1)
                                let maxNX = min(width - 1, col + 1)

                                var mbr = false
                                neighbourCheck: for ny in minNY...maxNY {
                                    let nRowBase = ny * width
                                    for nx in minNX...maxNX {
                                        if nx == col && ny == row { continue }
                                        let nIdx = nRowBase + nx
                                        if cleanupMag[nIdx] != 0 || refinedBit[nIdx] != 0 {
                                            mbr = true
                                            break neighbourCheck
                                        }
                                    }
                                }

                                if mbr {
                                    refinedFlag[idx] = 1
                                    refinedBit[idx] = UInt8(try spReader.readBit())
                                }
                            }
                        }

                        for col in groupX..<groupEndX {
                            for row in stripeY..<stripeEndY {
                                let idx = row * width + col
                                if cleanupMag[idx] == 0 && refinedBit[idx] != 0 {
                                    finalSigns[idx] = UInt8(try spReader.readBit())
                                }
                            }
                        }
                        groupX += 4
                    }
                    stripeY += 4
                }

                // HT MagRef pass (Clause 7.5):
                if zBlk == 3 {
                    var mrReader = MagRefBitReader(bytes: dref)
                    var mrStripeY = 0
                    while mrStripeY < height {
                        let mrStripeEndY = min(mrStripeY + 4, height)
                        for col in 0..<width {
                            for row in mrStripeY..<mrStripeEndY {
                                let idx = row * width + col
                                if cleanupMag[idx] != 0 {
                                    refinedFlag[idx] = 1
                                    refinedBit[idx] = UInt8(mrReader.readBit())
                                }
                            }
                        }
                        mrStripeY += 4
                    }
                }
            }

            // Reconstruct sample output values & last decoded bit-planes (Clause 7.6):
            var setCoeffs = [Int64](repeating: 0, count: sampleCount)
            var setPlanes = [Int8](repeating: -1, count: sampleCount)
            for i in 0..<sampleCount {
                var mag = cleanupMag[i] << cleanupShift
                let z = Int(refinedFlag[i])
                if z != 0 && cleanupShift >= 1 {
                    mag |= UInt64(refinedBit[i]) << (cleanupShift - 1)
                }
                guard mag != 0 else { continue }
                let lastPlane = cleanupShift - z
                setPlanes[i] = Int8(clamping: lastPlane)
                if midpointReconstruction && lastPlane > 0 {
                    mag |= UInt64(1) << (lastPlane - 1)
                }
                let signedMag = Int64(bitPattern: mag)
                setCoeffs[i] = finalSigns[i] != 0 ? -signedMag : signedMag
            }

            latestCoefficients = setCoeffs
            latestPlanes = setPlanes
        }

        return (latestCoefficients, latestPlanes)
    }

    // MARK: - 64-Bit Extended Cleanup Unpacker

    private static func decodeCleanup64(
        block: [UInt8],
        width: Int,
        height: Int,
        allowedPlanes: Int
    ) throws -> (magnitudes: [UInt64], signs: [UInt8]) {
        let sampleCount = width * height
        guard allowedPlanes >= 1, allowedPlanes <= maximumExtendedKMax else {
            throw CodecError(.malformedInput, "HT cleanup allowed bit-plane count (\(allowedPlanes)) is out of bounds.")
        }
        let maxMuExclusive = UInt64(1) << allowedPlanes

        guard !block.isEmpty else {
            throw CodecError(.malformedInput, "Invalid HT cleanup segment length Lcup=0.")
        }

        let qw = (width + 1) / 2
        let qh = (height + 1) / 2
        var magnitudes = [UInt64](repeating: 0, count: sampleCount)
        var signs = [UInt8](repeating: 0, count: sampleCount)

        try block.withUnsafeBufferPointer { blkBuf in
            try HTTables.cxtVLCDecodeTable0.withUnsafeBufferPointer { tbl0Buf in
                try HTTables.cxtVLCDecodeTable1.withUnsafeBufferPointer { tbl1Buf in
                    try HTTables.melExponents.withUnsafeBufferPointer { melExpBuf in
                        let blkBase = blkBuf.baseAddress!
                        let (lcup, _, pcup) = try parseCleanupSegmentBounds(blkBase, count: blkBuf.count)
                        var magSgnReader = MagSgnBitReader(base: blkBase, pcup: pcup)
                        var melDecoder = MELSymbolDecoder(base: blkBase, melExps: melExpBuf.baseAddress!, lcup: lcup, pcup: pcup)
                        var vlcReader = VLCBitReader(
                            base: blkBase,
                            tbl0: tbl0Buf.baseAddress!,
                            tbl1: tbl1Buf.baseAddress!,
                            lcup: lcup,
                            pcup: pcup
                        )

                        var prevRowRho = [Int](repeating: 0, count: qw)
                        var prevRowE1 = [Int](repeating: 0, count: qw)
                        var prevRowE3 = [Int](repeating: 0, count: qw)
                        var currRowRho = [Int](repeating: 0, count: qw)
                        var currRowE1 = [Int](repeating: 0, count: qw)
                        var currRowE3 = [Int](repeating: 0, count: qw)

                        @inline(__always)
                        func decodeSigEMB(qy: Int, qx: Int, leftRho: Int) throws -> (entry: HTTables.CxtVLCDecodeEntry, maxNeighborE: Int) {
                            if qy == 0 {
                                let context: Int
                                if qx == 0 {
                                    context = 0
                                } else {
                                    let fOrSf = (leftRho & 0x03) != 0 ? 1 : 0
                                    let wAndSw = (leftRho >> 1) & 0x06
                                    context = fOrSf | wAndSw
                                }
                                if context == 0 {
                                    if melDecoder.decodeSymbol() == 0 {
                                        return (HTTables.CxtVLCDecodeEntry(rho: 0, uOff: 0, embKnown: 0, embOne: 0, bitLength: 0), 0)
                                    }
                                }
                                let entry = try vlcReader.decodeCxtVLC(context: context, isInitialRow: true)
                                return (entry, 0)
                            } else {
                                let nw = qx > 0 ? ((prevRowRho[qx - 1] >> 3) & 1) : 0
                                let n = (prevRowRho[qx] >> 1) & 1
                                let ne = (prevRowRho[qx] >> 3) & 1
                                let nf = (qx + 1 < qw) ? ((prevRowRho[qx + 1] >> 1) & 1) : 0
                                let wOrSw = qx > 0 ? (((leftRho & 0x0C) != 0) ? 1 : 0) : 0
                                let context = (nw | n) | (wOrSw << 1) | ((ne | nf) << 2)

                                let eNW = qx > 0 ? prevRowE3[qx - 1] : 0
                                let eN = prevRowE1[qx]
                                let eNE = prevRowE3[qx]
                                let eNF = (qx + 1 < qw) ? prevRowE1[qx + 1] : 0
                                let maxNeighborE = max(max(eNW, eN), max(eNE, eNF))

                                if context == 0 {
                                    if melDecoder.decodeSymbol() == 0 {
                                        return (HTTables.CxtVLCDecodeEntry(rho: 0, uOff: 0, embKnown: 0, embOne: 0, bitLength: 0), maxNeighborE)
                                    }
                                }
                                let entry = try vlcReader.decodeCxtVLC(context: context, isInitialRow: false)
                                return (entry, maxNeighborE)
                            }
                        }

                        @inline(__always)
                        func unpackQuadSamples(
                            entry: HTTables.CxtVLCDecodeEntry,
                            u: Int,
                            maxNeighborE: Int,
                            qy: Int,
                            qx: Int
                        ) throws -> (e1: Int, e3: Int) {
                            let rho = Int(entry.rho)
                            guard rho != 0 else { return (0, 0) }

                            let x0 = qx * 2
                            let y0 = qy * 2
                            var invalidMask = 0
                            if x0 + 1 >= width { invalidMask |= 0b1100 }
                            if y0 + 1 >= height { invalidMask |= 0b1010 }
                            guard (rho & invalidMask) == 0 else {
                                throw CodecError(.malformedInput, "Non-zero significance decoded in padded HT quad sample.")
                            }

                            let kappa: Int
                            if qy == 0 {
                                kappa = 1
                            } else {
                                let gamma = entry.rho.nonzeroBitCount > 1 ? 1 : 0
                                kappa = max(1, gamma * (maxNeighborE - 1))
                            }
                            let upperU = kappa + u
                            guard upperU <= maximumExtendedKMax else {
                                throw CodecError(.malformedInput, "HT quad exponent bound U_q (\(upperU)) exceeds 62-bit extended range.")
                            }

                            let known = Int(entry.embKnown)
                            let knownOne = Int(entry.embOne)
                            var e1 = 0
                            var e3 = 0

                            for j in 0..<4 where (rho & (1 << j)) != 0 {
                                let m = upperU - ((known >> j) & 1)
                                guard m >= 1, m <= maximumExtendedKMax else {
                                    throw CodecError(.malformedInput, "Invalid HT MagSgn bit count m_n=\(m).")
                                }
                                let iFlag = UInt64((knownOne >> j) & 1)
                                let v = (try magSgnReader.readBits(m)) + (iFlag << m)
                                let mu = (v >> 1) + 1
                                guard mu < maxMuExclusive else {
                                    throw CodecError(.malformedInput, "Decoded HT cleanup magnitude exceeds subband bit-plane bound.")
                                }
                                let dstX = x0 + (j >> 1)
                                let dstY = y0 + (j & 1)
                                let dstIdx = dstY * width + dstX
                                magnitudes[dstIdx] = mu
                                signs[dstIdx] = UInt8(v & 1)

                                if j == 1 || j == 3 {
                                    let twoMuMinusOne = (mu << 1) - 1
                                    let exp = 64 - twoMuMinusOne.leadingZeroBitCount
                                    if j == 1 { e1 = exp } else { e3 = exp }
                                }
                            }
                            return (e1, e3)
                        }

                        for qy in 0..<qh {
                            var leftRho = 0
                            var qx = 0
                            while qx < qw {
                                let (entry1, maxNE1) = try decodeSigEMB(qy: qy, qx: qx, leftRho: leftRho)
                                leftRho = Int(entry1.rho)
                                currRowRho[qx] = leftRho

                                if qx + 1 < qw {
                                    let (entry2, maxNE2) = try decodeSigEMB(qy: qy, qx: qx + 1, leftRho: leftRho)
                                    leftRho = Int(entry2.rho)
                                    currRowRho[qx + 1] = leftRho

                                    var u1 = 0
                                    var u2 = 0
                                    if qy == 0 && entry1.uOff == 1 && entry2.uOff == 1 {
                                        let jointMel = melDecoder.decodeSymbol()
                                        if jointMel == 1 {
                                            let pfx1 = try vlcReader.decodeUPrefix()
                                            let pfx2 = try vlcReader.decodeUPrefix()
                                            let sfx1 = try vlcReader.decodeUSuffix(prefix: pfx1)
                                            let sfx2 = try vlcReader.decodeUSuffix(prefix: pfx2)
                                            let ext1 = try vlcReader.decodeUExtension(suffix: sfx1)
                                            let ext2 = try vlcReader.decodeUExtension(suffix: sfx2)
                                            u1 = 2 + pfx1 + sfx1 + 4 * ext1
                                            u2 = 2 + pfx2 + sfx2 + 4 * ext2
                                        } else {
                                            let pfx1 = try vlcReader.decodeUPrefix()
                                            let pfx2: Int = pfx1 > 2 ? ((try vlcReader.readBits(1)) + 1) : (try vlcReader.decodeUPrefix())
                                            let sfx1 = try vlcReader.decodeUSuffix(prefix: pfx1)
                                            let sfx2 = try vlcReader.decodeUSuffix(prefix: pfx2)
                                            let ext1 = try vlcReader.decodeUExtension(suffix: sfx1)
                                            let ext2 = try vlcReader.decodeUExtension(suffix: sfx2)
                                            u1 = pfx1 + sfx1 + 4 * ext1
                                            u2 = pfx2 + sfx2 + 4 * ext2
                                        }
                                    } else {
                                        let pfx1 = entry1.uOff == 1 ? (try vlcReader.decodeUPrefix()) : 0
                                        let pfx2 = entry2.uOff == 1 ? (try vlcReader.decodeUPrefix()) : 0
                                        let sfx1 = entry1.uOff == 1 ? (try vlcReader.decodeUSuffix(prefix: pfx1)) : 0
                                        let sfx2 = entry2.uOff == 1 ? (try vlcReader.decodeUSuffix(prefix: pfx2)) : 0
                                        let ext1 = entry1.uOff == 1 ? (try vlcReader.decodeUExtension(suffix: sfx1)) : 0
                                        let ext2 = entry2.uOff == 1 ? (try vlcReader.decodeUExtension(suffix: sfx2)) : 0
                                        u1 = pfx1 + sfx1 + 4 * ext1
                                        u2 = pfx2 + sfx2 + 4 * ext2
                                    }

                                    let exps1 = try unpackQuadSamples(entry: entry1, u: u1, maxNeighborE: maxNE1, qy: qy, qx: qx)
                                    let exps2 = try unpackQuadSamples(entry: entry2, u: u2, maxNeighborE: maxNE2, qy: qy, qx: qx + 1)
                                    currRowE1[qx] = exps1.e1
                                    currRowE3[qx] = exps1.e3
                                    currRowE1[qx + 1] = exps2.e1
                                    currRowE3[qx + 1] = exps2.e3
                                    qx += 2
                                } else {
                                    var u1 = 0
                                    if entry1.uOff == 1 {
                                        let pfx1 = try vlcReader.decodeUPrefix()
                                        let sfx1 = try vlcReader.decodeUSuffix(prefix: pfx1)
                                        let ext1 = try vlcReader.decodeUExtension(suffix: sfx1)
                                        u1 = pfx1 + sfx1 + 4 * ext1
                                    }
                                    let exps1 = try unpackQuadSamples(entry: entry1, u: u1, maxNeighborE: maxNE1, qy: qy, qx: qx)
                                    currRowE1[qx] = exps1.e1
                                    currRowE3[qx] = exps1.e3
                                    qx += 1
                                }
                            }
                            swap(&prevRowRho, &currRowRho)
                            swap(&prevRowE1, &currRowE1)
                            swap(&prevRowE3, &currRowE3)
                        }
                    }
                }
            }
        }

        return (magnitudes, signs)
    }
}
