// SPDX-License-Identifier: Apache-2.0 AND BSD-2-Clause
// Provenance: Adapted from Raster-Lab/J2KSwift at commit
// 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca
// (Sources/J2KCodec/J2KHTConformantBitStream.swift,
// J2KHTConformantMELCoder.swift, J2KHTConformantVLCCoder.swift,
// J2KHTConformantMagSgnCoder.swift, J2KHTConformantBlockLayout.swift,
// J2KHTConformantBlockEncoder.swift, J2KHTConformantBlockDecoder.swift),
// which is a Swift translation of OpenJPH 0.26 (`ojph_block_encoder.cpp`,
// `ojph_block_decoder32.cpp`, `ojph_block_common.cpp`).
//
// Copyright (c) 2019-2024, Aous Naman
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//
// 1. Redistributions of source code must retain the above copyright notice, this
//    list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright notice,
//    this list of conditions and the following disclaimer in the documentation
//    and/or other materials provided with the distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
// FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
// DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
// OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Foundation

// MARK: - MEL Coder (ISO/IEC 15444-15 Clause 7.3.3)

internal struct HTMELEncoder: Sendable {
    private static let melExp: [Int] = [
        0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 4, 5
    ]

    private var buffer: [UInt8] = []
    private var tmp: UInt8 = 0
    private var rem: Int = 8
    private var run: Int = 0
    private var k: Int = 0
    private var threshold: Int = 1
    private let maximumBytes: Int
    internal private(set) var overflowed = false

    internal init(maximumBytes: Int = Int.max) {
        self.maximumBytes = maximumBytes
        let reserved = min(192, max(0, maximumBytes))
        if reserved > 0 {
            buffer.reserveCapacity(reserved)
        }
    }

    internal mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        tmp = 0
        rem = 8
        run = 0
        k = 0
        threshold = 1
        overflowed = false
    }

    private mutating func emitBit(_ bit: Bool) {
        tmp = (tmp << 1) | (bit ? 1 : 0)
        rem -= 1
        if rem == 0 {
            if buffer.count < maximumBytes {
                buffer.append(tmp)
            } else {
                overflowed = true
            }
            rem = (tmp == 0xFF) ? 7 : 8
            tmp = 0
        }
    }

    internal mutating func encode(eventIsOne: Bool) {
        if !eventIsOne {
            run += 1
            if run >= threshold {
                emitBit(true)
                run = 0
                k = min(12, k + 1)
                threshold = 1 << Self.melExp[k]
            }
        } else {
            emitBit(false)
            var t = Self.melExp[k]
            while t > 0 {
                t -= 1
                emitBit(((run >> t) & 1) != 0)
            }
            run = 0
            k = max(0, k - 1)
            threshold = 1 << Self.melExp[k]
        }
    }

    internal func snapshotForFuse() -> (bytes: [UInt8], tmp: UInt8, rem: Int) {
        var copy = self
        if copy.run > 0 {
            copy.emitBit(true)
        }
        return (copy.buffer, copy.tmp, copy.rem)
    }

    internal mutating func flushWithoutTrailingSeal() -> (tmp: UInt8, rem: Int) {
        if run > 0 {
            emitBit(true)
            run = 0
        }
        return (tmp, rem)
    }

    internal var bufferSlice: [UInt8] { buffer }
}

internal struct HTMELDecoder: Sendable {
    private static let melExp: [Int] = [
        0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 4, 5
    ]

    private let bytes: ArraySlice<UInt8>
    private let bytesCount: Int
    private var pos: Int
    private var tmp: UInt64 = 0
    private var bits: Int = 0
    private var unstuff: Bool = false
    private var k: Int = 0
    private var numRuns: Int = 0
    private var runs: UInt64 = 0

    internal init(bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.bytesCount = bytes.count
        self.pos = bytes.startIndex
    }

    internal init(bytes: [UInt8]) {
        self.init(bytes: bytes[...])
    }

    private mutating func read() {
        guard bits <= 32 else { return }
        let endIdx = bytes.startIndex + bytesCount
        let remaining = endIdx - pos

        var val: UInt32 = 0xFFFF_FFFF
        if remaining >= 4 {
            let b0 = UInt32(bytes[pos])
            let b1 = UInt32(bytes[pos + 1])
            let b2 = UInt32(bytes[pos + 2])
            let b3 = UInt32(bytes[pos + 3])
            val = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
            pos += 4
        } else if remaining > 0 {
            var i = 0
            while pos < endIdx {
                let b = UInt32(bytes[pos])
                let m = ~(UInt32(0xFF) << i)
                val = (val & m) | (b << i)
                pos += 1
                i += 8
            }
        }

        var bitsRead = 32 - (unstuff ? 1 : 0)
        var t: UInt32 = val & (unstuff ? 0x7F : 0xFF)
        var unstuffFlag = ((val & 0xFF) == 0xFF)

        t = (t << (8 - (unstuffFlag ? 1 : 0)))
            | ((val >> 8) & (0xFF >> (unstuffFlag ? 1 : 0)))
        bitsRead -= unstuffFlag ? 1 : 0
        unstuffFlag = (((val >> 8) & 0xFF) == 0xFF)

        t = (t << (8 - (unstuffFlag ? 1 : 0)))
            | ((val >> 16) & (0xFF >> (unstuffFlag ? 1 : 0)))
        bitsRead -= unstuffFlag ? 1 : 0
        unstuffFlag = (((val >> 16) & 0xFF) == 0xFF)

        t = (t << (8 - (unstuffFlag ? 1 : 0)))
            | ((val >> 24) & (0xFF >> (unstuffFlag ? 1 : 0)))
        bitsRead -= unstuffFlag ? 1 : 0
        unstuff = (((val >> 24) & 0xFF) == 0xFF)

        tmp |= UInt64(t) << (64 - bitsRead - bits)
        bits += bitsRead
    }

    private mutating func decodeMoreRuns() {
        if bits < 6 { read() }
        while bits >= 6 && numRuns < 8 {
            let eval = Self.melExp[k]
            var run = 0
            if (tmp & (UInt64(1) << 63)) != 0 {
                run = (1 << eval) - 1
                k = min(12, k + 1)
                tmp <<= 1
                bits -= 1
                run = run << 1
            } else {
                run = Int(tmp >> (63 - eval)) & ((1 << eval) - 1)
                k = max(0, k - 1)
                tmp <<= eval + 1
                bits -= eval + 1
                run = (run << 1) + 1
            }
            let shift = numRuns * 7
            runs &= ~(UInt64(0x3F) << shift)
            runs |= UInt64(run) << shift
            numRuns += 1
        }
    }

    internal mutating func nextRun() -> Int {
        if numRuns == 0 { decodeMoreRuns() }
        let t = Int(runs & 0x7F)
        runs >>= 7
        numRuns -= 1
        return t
    }
}

// MARK: - VLC Reverse Bit Emitter (ISO/IEC 15444-15 Clause 7.3.5)

internal struct HTReverseBitEmitter: Sendable {
    private var bytes: [UInt8] = [0xFF]
    private var tmp: UInt64 = 0xF
    private var usedBits: Int = 4
    private var lastGreaterThan8F: Bool = true
    private let maximumBytes: Int
    internal private(set) var overflowed: Bool = false

    internal init(maximumBytes: Int = Int.max) {
        self.maximumBytes = max(1, maximumBytes)
        bytes.reserveCapacity(min(512, max(1, maximumBytes)))
    }

    internal mutating func reset() {
        bytes.removeAll(keepingCapacity: true)
        bytes.append(0xFF)
        tmp = 0xF
        usedBits = 4
        lastGreaterThan8F = true
        overflowed = false
    }

    internal mutating func encode(codeword: Int, count: Int) {
        guard count > 0, !overflowed else { return }
        let mask = (UInt64(1) << count) - 1
        let cw = UInt64(codeword) & mask
        tmp |= cw << usedBits
        usedBits += count

        while usedBits >= 8 {
            var byte = UInt8(tmp & 0xFF)
            if lastGreaterThan8F && (byte & 0x7F) == 0x7F {
                byte &= 0x7F
                guard bytes.count < maximumBytes else { overflowed = true; return }
                bytes.append(byte)
                lastGreaterThan8F = false
                tmp >>= 7
                usedBits -= 7
            } else {
                guard bytes.count < maximumBytes else { overflowed = true; return }
                bytes.append(byte)
                lastGreaterThan8F = byte > 0x8F
                tmp >>= 8
                usedBits -= 8
            }
        }
    }

    internal func snapshotForFuse() -> (
        forwardTailBytes: [UInt8],
        tmp: UInt8,
        usedBits: Int,
        lastGreaterThan8F: Bool
    ) {
        return (
            forwardTailBytes: Array(bytes.reversed()),
            tmp: UInt8(tmp & 0xFF),
            usedBits: usedBits,
            lastGreaterThan8F: lastGreaterThan8F
        )
    }

    internal var rawBytesInEmitOrder: [UInt8] { bytes }
    internal var pendingTmp: UInt8 { UInt8(tmp & 0xFF) }
    internal var pendingUsedBits: Int { usedBits }
    internal var pendingLastGreaterThan8F: Bool { lastGreaterThan8F }
}

// MARK: - MagSgn Coder (ISO/IEC 15444-15 Clause 7.3.4)

internal struct HTMagSgnEncoder: Sendable {
    private var bytes: [UInt8] = []
    private var tmp: UInt64 = 0
    private var usedBits: Int = 0
    private var maxBits: Int = 8
    private let maximumBytes: Int
    internal private(set) var overflowed: Bool = false

    internal init(maximumBytes: Int = Int.max) {
        self.maximumBytes = max(0, maximumBytes)
        bytes.reserveCapacity(min(1024, max(0, maximumBytes)))
    }

    internal mutating func reset() {
        bytes.removeAll(keepingCapacity: true)
        tmp = 0
        usedBits = 0
        maxBits = 8
        overflowed = false
    }

    internal mutating func encode(codeword: UInt32, count: Int) {
        guard count > 0, !overflowed else { return }
        let mask: UInt64 = (count >= 32) ? 0xFFFF_FFFF : ((UInt64(1) << count) - 1)
        let cw = UInt64(codeword) & mask
        tmp |= cw << usedBits
        usedBits += count

        while usedBits >= maxBits {
            let pageMask: UInt64 = (maxBits == 8) ? 0xFF : 0x7F
            let byte = UInt8(tmp & pageMask)
            guard bytes.count < maximumBytes else { overflowed = true; return }
            bytes.append(byte)
            tmp >>= maxBits
            usedBits -= maxBits
            maxBits = (byte == 0xFF) ? 7 : 8
        }
    }

    internal mutating func encode64(codeword: UInt64, count: Int) {
        guard count > 0, !overflowed else { return }
        if usedBits &+ count <= 64 {
            let mask: UInt64 = (count >= 64) ? ~UInt64(0) : ((UInt64(1) << count) - 1)
            let cw = codeword & mask
            tmp |= cw << usedBits
            usedBits &+= count
            while usedBits >= maxBits {
                let pageMask: UInt64 = (maxBits == 8) ? 0xFF : 0x7F
                let byte = UInt8(tmp & pageMask)
                guard bytes.count < maximumBytes else { overflowed = true; return }
                bytes.append(byte)
                tmp >>= maxBits
                usedBits &-= maxBits
                maxBits = (byte == 0xFF) ? 7 : 8
            }
        } else {
            let lowCount = 32
            let highCount = count - 32
            encode(codeword: UInt32(truncatingIfNeeded: codeword), count: lowCount)
            encode(codeword: UInt32(truncatingIfNeeded: codeword >> 32), count: highCount)
        }
    }

    internal mutating func terminate() {
        guard !overflowed else { return }
        if usedBits > 0 {
            let unused = maxBits - usedBits
            let padMask: UInt64 = (UInt64(1) << unused) - 1
            tmp |= padMask << usedBits
            let pageMask: UInt64 = (maxBits == 8) ? 0xFF : 0x7F
            let byte = UInt8(tmp & pageMask)
            guard bytes.count < maximumBytes else { overflowed = true; return }
            bytes.append(byte)
            tmp = 0
            usedBits = 0
            maxBits = (byte == 0xFF) ? 7 : 8
        }
        if bytes.last == 0xFF {
            bytes.removeLast()
        }
    }

    internal mutating func finish() -> [UInt8] {
        terminate()
        return bytes
    }

    internal var currentBytes: [UInt8] { bytes }
}

internal struct HTMagSgnDecoder: Sendable {
    private let bytes: ArraySlice<UInt8>
    private let bytesCount: Int
    private var pos: Int
    private var tmp: UInt64 = 0
    private var bits: Int = 0
    private var unstuff: Bool = false

    internal init(bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.bytesCount = bytes.count
        self.pos = bytes.startIndex
    }

    internal init(bytes: [UInt8]) {
        self.init(bytes: bytes[...])
    }

    private mutating func refillScalar() {
        let endIdx = bytes.startIndex + bytesCount
        while bits <= 32 {
            let byte: UInt8
            if pos < endIdx {
                byte = bytes[pos]
                pos += 1
            } else {
                byte = 0xFF
            }
            let maxBits = unstuff ? 7 : 8
            let mask: UInt8 = unstuff ? 0x7F : 0xFF
            let value = UInt64(byte & mask)
            tmp |= value << bits
            bits += maxBits
            unstuff = (byte == 0xFF)
        }
    }

    internal mutating func read(count: Int) -> UInt32 {
        if count <= 0 { return 0 }
        let clampedCount = min(count, 32)
        if bits < clampedCount { refillScalar() }
        let mask: UInt64 = (clampedCount == 32) ? 0xFFFF_FFFF : ((UInt64(1) << clampedCount) - 1)
        let result = UInt32(tmp & mask)
        tmp >>= clampedCount
        bits -= clampedCount
        return result
    }
}

// MARK: - Block Layout Assembly & Parsing (ISO/IEC 15444-15 Clause 7.3.2)

internal enum HTBlockLayout {
    internal static func fuseMELAndVLC(
        mel: inout HTMELEncoder,
        vlc: HTReverseBitEmitter
    ) -> [UInt8] {
        var melSnap = mel.snapshotForFuse()
        let vlcSnap = vlc.snapshotForFuse()

        let melTmp = melSnap.tmp
        let melRem = melSnap.rem
        let melUsed = 8 - melRem
        let vlcTmp = vlcSnap.tmp
        let vlcUsed = vlcSnap.usedBits
        let vlcLastGT8F = vlcSnap.lastGreaterThan8F

        let melAligned = melTmp << melRem
        let vlcMask: UInt8 = (vlcUsed == 0) ? 0 : UInt8((1 << vlcUsed) - 1)
        let vlcLow = vlcTmp & vlcMask
        let fused = melAligned | vlcLow

        let fusePossible: Bool = {
            guard (melUsed + vlcUsed) <= 8 else { return false }
            if melUsed == 0 && vlcUsed == 0 { return false }
            if vlcLastGT8F && (fused & 0x7F) == 0x7F && (fused & 0x80) != 0 {
                return false
            }
            return true
        }()

        if fusePossible {
            melSnap.bytes.append(fused)
        } else {
            if melUsed > 0 {
                melSnap.bytes.append(melAligned)
            }
            if vlcUsed > 0 {
                melSnap.bytes.append(vlcLow)
            }
        }

        melSnap.bytes.append(contentsOf: vlcSnap.forwardTailBytes)
        return melSnap.bytes
    }

    internal static func assemble(
        magsgn: [UInt8],
        mel: inout HTMELEncoder,
        vlc: HTReverseBitEmitter,
        maximumOutputBytes: Int = Int.max
    ) throws -> [UInt8] {
        var melVlc = fuseMELAndVLC(mel: &mel, vlc: vlc)
        let scup = melVlc.count
        guard scup >= 2 else {
            throw CodecError(.internalFailure, "HTJ2K Scup (\(scup)) must be at least 2 bytes.")
        }
        guard scup <= 4079 else {
            throw CodecError(.resourceLimitExceeded, "HTJ2K Scup (\(scup)) exceeds 4079-byte Part 15 limit.")
        }
        let lcup = magsgn.count + scup
        guard lcup <= 65535 else {
            throw CodecError(.resourceLimitExceeded, "HTJ2K Lcup (\(lcup)) exceeds 65535-byte Part 15 limit.")
        }
        guard !mel.overflowed, !vlc.overflowed, lcup <= maximumOutputBytes else {
            throw CodecError(.resourceLimitExceeded, "HTJ2K cleanup segment (\(lcup) bytes) exceeds the remaining block admission budget.")
        }
        melVlc[scup - 1] = UInt8((scup >> 4) & 0xFF)
        melVlc[scup - 2] = (melVlc[scup - 2] & 0xF0) | UInt8(scup & 0x0F)

        var out: [UInt8] = []
        out.reserveCapacity(lcup)
        out.append(contentsOf: magsgn)
        out.append(contentsOf: melVlc)
        return out
    }

    internal static func parse(
        block: [UInt8]
    ) -> (magsgn: ArraySlice<UInt8>, melVlc: ArraySlice<UInt8>, scup: Int)? {
        let n = block.count
        guard n >= 2, n <= 65535 else { return nil }
        let last = Int(block[n - 1])
        let prev = Int(block[n - 2])
        let scup = (last << 4) | (prev & 0x0F)
        guard scup >= 2, scup <= 4079, scup <= n else { return nil }
        // ISO/IEC 15444-15 Clause 7.3.2: the high nibble of byte[Lcup - 2]
        // must not have all 4 bits set when combined with 0x0F (cannot be 0xFF).
        let magsgnLen = n - scup
        return (block[0..<magsgnLen], block[magsgnLen..<n], scup)
    }
}

// MARK: - HT Block Encoder (ISO/IEC 15444-15 Clause 7.3)

package enum HTBlockEncoder {
    /// Reversible 5-3 subband log2 gain `G_b` per ISO/IEC 15444-1 Annex E:
    /// LL = 0, HL = 1, LH = 1, HH = 2.
    package static func reversibleGain(subband: BandOrientation) -> Int {
        switch subband {
        case .ll: return 0
        case .hl, .lh: return 1
        case .hh: return 2
        }
    }

    /// Encode a code-block's cleanup pass from signed integer wavelet coefficients.
    ///
    /// - Parameters:
    ///   - coefficients: `width * height` signed integer coefficients in row-major order.
    ///   - width: Code-block width in samples (`1...64`).
    ///   - height: Code-block height in samples (`1...64`).
    ///   - bandShift: Bit-plane index of the cleanup pass (`0` for lossless full-precision coding).
    ///   - maximumOutputBytes: Upper bound on retained cleanup segment bytes (`Int.max` when unbounded).
    /// - Returns: Assembled Part 15 cleanup-pass segment bytes (`Lcup` bytes), or empty array if all coefficients are zero at `bandShift`.
    package static func encodeCleanup(
        coefficients: [Int32],
        width: Int,
        height: Int,
        bandShift: Int = 0,
        maximumOutputBytes: Int = Int.max
    ) throws -> [UInt8] {
        guard width >= 1, height >= 1, coefficients.count == width * height else {
            throw CodecError(.invalidArgument, "HTJ2K block dimensions do not match coefficient count.")
        }
        guard bandShift >= 0, bandShift < 31 else {
            throw CodecError(.invalidArgument, "HTJ2K cleanup bit-plane shift (\(bandShift)) is out of range.")
        }

        // Convert to OpenJPH sign-magnitude words placed at p = 1 (`missingMSBs = 29`)
        // or inspect magnitudes directly so no bit-plane is ever truncated or overflowed.
        var hasNonZero = false
        for c in coefficients {
            if (c.magnitude >> bandShift) != 0 {
                hasNonZero = true
                break
            }
        }
        if !hasNonZero {
            return []
        }

        guard maximumOutputBytes >= 2 else {
            throw CodecError(.resourceLimitExceeded, "HTJ2K cleanup segment exceeds the remaining block admission budget.")
        }

        var magsgnEnc = HTMagSgnEncoder(maximumBytes: maximumOutputBytes)
        var melEnc = HTMELEncoder(maximumBytes: min(4079, maximumOutputBytes))
        var vlcEnc = HTReverseBitEmitter(maximumBytes: min(4079, maximumOutputBytes))

        try encodeLoop(
            coefficients: coefficients,
            width: width,
            height: height,
            bandShift: bandShift,
            magsgnEnc: &magsgnEnc,
            melEnc: &melEnc,
            vlcEnc: &vlcEnc
        )

        let magsgnBytes = magsgnEnc.finish()
        guard !magsgnEnc.overflowed else {
            throw CodecError(.resourceLimitExceeded, "HTJ2K MagSgn stream exceeds the remaining block admission budget.")
        }
        return try HTBlockLayout.assemble(
            magsgn: magsgnBytes,
            mel: &melEnc,
            vlc: vlcEnc,
            maximumOutputBytes: maximumOutputBytes
        )
    }

    private static func encodeLoop(
        coefficients: [Int32],
        width: Int,
        height: Int,
        bandShift: Int,
        magsgnEnc: inout HTMagSgnEncoder,
        melEnc: inout HTMELEncoder,
        vlcEnc: inout HTReverseBitEmitter
    ) throws {
        magsgnEnc.reset()
        melEnc.reset()
        vlcEnc.reset()

        let guardedWidth = ((width + 3) / 4) * 2 + 2
        var eVal = [UInt8](repeating: 0, count: guardedWidth)
        var cxVal = [UInt8](repeating: 0, count: guardedWidth)

        @inline(__always)
        func sampleInfo(_ c: Int32) throws -> (Bool, Int, UInt32) {
            let mu = UInt64(c.magnitude) >> bandShift
            if mu == 0 { return (false, 0, 0) }
            guard mu <= 0x3FFF_FFFF else {
                throw CodecError(.invalidArgument, "HTJ2K coefficient magnitude exceeds 30-bit reversible range.")
            }
            let twoMuMinus1 = UInt32((mu << 1) - 1)
            let lz = twoMuMinus1.leadingZeroBitCount
            let eQ = 32 - lz
            let sign: UInt32 = c < 0 ? 1 : 0
            let payload = (twoMuMinus1 &- 1) &+ sign
            return (true, eQ, payload)
        }

        @inline(__always)
        func fetch(_ x: Int, _ y: Int) -> Int32 {
            guard x < width, y < height else { return 0 }
            return coefficients[y * width + x]
        }

        @inline(__always)
        func processQuad(baseX: Int, baseY: Int) throws -> (
            rho: Int, eQMax: Int,
            eQ0: Int, eQ1: Int, eQ2: Int, eQ3: Int,
            s0: UInt32, s1: UInt32, s2: UInt32, s3: UInt32
        ) {
            var rho = 0
            var eQMax = 0
            var eQ0 = 0, eQ1 = 0, eQ2 = 0, eQ3 = 0
            var s0: UInt32 = 0, s1: UInt32 = 0, s2: UInt32 = 0, s3: UInt32 = 0

            let (sig0, e0, p0) = try sampleInfo(fetch(baseX, baseY))
            if sig0 { rho |= 1; eQ0 = e0; s0 = p0; if e0 > eQMax { eQMax = e0 } }

            let (sig1, e1, p1) = try sampleInfo(fetch(baseX, baseY + 1))
            if sig1 { rho |= 2; eQ1 = e1; s1 = p1; if e1 > eQMax { eQMax = e1 } }

            let (sig2, e2, p2) = try sampleInfo(fetch(baseX + 1, baseY))
            if sig2 { rho |= 4; eQ2 = e2; s2 = p2; if e2 > eQMax { eQMax = e2 } }

            let (sig3, e3, p3) = try sampleInfo(fetch(baseX + 1, baseY + 1))
            if sig3 { rho |= 8; eQ3 = e3; s3 = p3; if e3 > eQMax { eQMax = e3 } }

            return (rho, eQMax, eQ0, eQ1, eQ2, eQ3, s0, s1, s2, s3)
        }

        @inline(__always)
        func emitQuadMagSgn(
            rho: Int, tuple: Int, Uq: Int,
            s0: UInt32, s1: UInt32, s2: UInt32, s3: UInt32
        ) {
            if rho == 0 { return }
            if Uq <= 16 {
                var combined: UInt64 = 0
                var totalBits: Int = 0
                if (rho & 1) != 0 {
                    let m = Uq - (tuple & 1)
                    let mask: UInt32 = (UInt32(1) << m) - 1
                    combined |= UInt64(s0 & mask) << totalBits
                    totalBits &+= m
                }
                if (rho & 2) != 0 {
                    let m = Uq - ((tuple >> 1) & 1)
                    let mask: UInt32 = (UInt32(1) << m) - 1
                    combined |= UInt64(s1 & mask) << totalBits
                    totalBits &+= m
                }
                if (rho & 4) != 0 {
                    let m = Uq - ((tuple >> 2) & 1)
                    let mask: UInt32 = (UInt32(1) << m) - 1
                    combined |= UInt64(s2 & mask) << totalBits
                    totalBits &+= m
                }
                if (rho & 8) != 0 {
                    let m = Uq - ((tuple >> 3) & 1)
                    let mask: UInt32 = (UInt32(1) << m) - 1
                    combined |= UInt64(s3 & mask) << totalBits
                    totalBits &+= m
                }
                magsgnEnc.encode64(codeword: combined, count: totalBits)
                return
            }
            @inline(__always)
            func emit(sample: UInt32, eBit: Int) {
                let m = Uq - eBit
                let mask: UInt32 = (m >= 32) ? ~UInt32(0) : ((UInt32(1) << m) - 1)
                magsgnEnc.encode(codeword: sample & mask, count: m)
            }
            if (rho & 1) != 0 { emit(sample: s0, eBit: tuple & 1) }
            if (rho & 2) != 0 { emit(sample: s1, eBit: (tuple >> 1) & 1) }
            if (rho & 4) != 0 { emit(sample: s2, eBit: (tuple >> 2) & 1) }
            if (rho & 8) != 0 { emit(sample: s3, eBit: (tuple >> 3) & 1) }
        }

        // Initial row of quads (y = 0, 1)
        var c_q0 = 0
        var lep = 0
        var lcxp = 0
        eVal[lep] = 0
        cxVal[lcxp] = 0

        if height > 0 {
            var spX = 0
            while spX < width {
                let q0 = try processQuad(baseX: spX, baseY: 0)
                let rho0 = q0.rho
                let eQMax0 = q0.eQMax
                let Uq0 = max(eQMax0, 1)
                let u_q0 = Uq0 - 1

                var eps0 = 0
                if u_q0 > 0 {
                    if q0.eQ0 == eQMax0 { eps0 |= 1 }
                    if q0.eQ1 == eQMax0 { eps0 |= 2 }
                    if q0.eQ2 == eQMax0 { eps0 |= 4 }
                    if q0.eQ3 == eQMax0 { eps0 |= 8 }
                }

                eVal[lep] = max(eVal[lep], UInt8(q0.eQ1)); lep += 1
                eVal[lep] = UInt8(q0.eQ3)
                cxVal[lcxp] = cxVal[lcxp] | UInt8((rho0 & 2) >> 1); lcxp += 1
                cxVal[lcxp] = UInt8((rho0 & 8) >> 3)

                let tuple0 = Int(vlcTable0Conformant[(c_q0 << 8) | (rho0 << 4) | eps0])
                vlcEnc.encode(codeword: tuple0 >> 8, count: (tuple0 >> 4) & 0x7)

                if c_q0 == 0 {
                    melEnc.encode(eventIsOne: rho0 != 0)
                }

                emitQuadMagSgn(
                    rho: rho0, tuple: tuple0, Uq: Uq0,
                    s0: q0.s0, s1: q0.s1, s2: q0.s2, s3: q0.s3
                )

                var rho1 = 0
                var u_q1 = 0
                if spX + 2 < width {
                    let q1 = try processQuad(baseX: spX + 2, baseY: 0)
                    let eQMax1 = q1.eQMax
                    rho1 = q1.rho
                    let c_q1 = (rho0 >> 1) | (rho0 & 1)
                    let Uq1 = max(eQMax1, 1)
                    u_q1 = Uq1 - 1
                    var eps1 = 0
                    if u_q1 > 0 {
                        if q1.eQ0 == eQMax1 { eps1 |= 1 }
                        if q1.eQ1 == eQMax1 { eps1 |= 2 }
                        if q1.eQ2 == eQMax1 { eps1 |= 4 }
                        if q1.eQ3 == eQMax1 { eps1 |= 8 }
                    }
                    eVal[lep] = max(eVal[lep], UInt8(q1.eQ1)); lep += 1
                    eVal[lep] = UInt8(q1.eQ3)
                    cxVal[lcxp] = cxVal[lcxp] | UInt8((rho1 & 2) >> 1); lcxp += 1
                    cxVal[lcxp] = UInt8((rho1 & 8) >> 3)

                    let tuple1 = Int(vlcTable0Conformant[(c_q1 << 8) | (rho1 << 4) | eps1])
                    vlcEnc.encode(codeword: tuple1 >> 8, count: (tuple1 >> 4) & 0x7)

                    if c_q1 == 0 {
                        melEnc.encode(eventIsOne: rho1 != 0)
                    }

                    emitQuadMagSgn(
                        rho: rho1, tuple: tuple1, Uq: Uq1,
                        s0: q1.s0, s1: q1.s1, s2: q1.s2, s3: q1.s3
                    )
                }

                if u_q0 > 0 && u_q1 > 0 {
                    melEnc.encode(eventIsOne: min(u_q0, u_q1) > 2)
                }
                if u_q0 > 2 && u_q1 > 2 {
                    let e0 = uvlcTableConformant[u_q0 - 2]
                    let e1 = uvlcTableConformant[u_q1 - 2]
                    vlcEnc.encode(codeword: Int(e0.pre), count: Int(e0.preLen))
                    vlcEnc.encode(codeword: Int(e1.pre), count: Int(e1.preLen))
                    vlcEnc.encode(codeword: Int(e0.suf), count: Int(e0.sufLen))
                    vlcEnc.encode(codeword: Int(e1.suf), count: Int(e1.sufLen))
                    vlcEnc.encode(codeword: Int(e0.ext), count: Int(e0.extLen))
                    vlcEnc.encode(codeword: Int(e1.ext), count: Int(e1.extLen))
                } else if u_q0 > 2 && u_q1 > 0 {
                    let e0 = uvlcTableConformant[u_q0]
                    vlcEnc.encode(codeword: Int(e0.pre), count: Int(e0.preLen))
                    vlcEnc.encode(codeword: u_q1 - 1, count: 1)
                    vlcEnc.encode(codeword: Int(e0.suf), count: Int(e0.sufLen))
                    vlcEnc.encode(codeword: Int(e0.ext), count: Int(e0.extLen))
                } else {
                    let e0 = uvlcTableConformant[u_q0]
                    let e1 = uvlcTableConformant[u_q1]
                    vlcEnc.encode(codeword: Int(e0.pre), count: Int(e0.preLen))
                    vlcEnc.encode(codeword: Int(e1.pre), count: Int(e1.preLen))
                    vlcEnc.encode(codeword: Int(e0.suf), count: Int(e0.sufLen))
                    vlcEnc.encode(codeword: Int(e1.suf), count: Int(e1.sufLen))
                    vlcEnc.encode(codeword: Int(e0.ext), count: Int(e0.extLen))
                    vlcEnc.encode(codeword: Int(e1.ext), count: Int(e1.extLen))
                }

                c_q0 = (rho1 >> 1) | (rho1 & 1)
                spX += 4
            }
        }
        if lep + 1 < guardedWidth { eVal[lep + 1] = 0 }

        // Subsequent quad rows (y = 2, 4, ...)
        var y = 2
        while y < height {
            lep = 0
            var maxE = max(Int(eVal[0]), Int(eVal[1])) - 1
            eVal[0] = 0
            lcxp = 0
            c_q0 = Int(cxVal[0]) + (Int(cxVal[1]) << 2)
            cxVal[0] = 0

            var spX = 0
            while spX < width {
                let q0 = try processQuad(baseX: spX, baseY: y)
                let rho0 = q0.rho
                let eQMax0 = q0.eQMax
                let kappaA = ((rho0 & (rho0 - 1)) != 0) ? max(1, maxE) : 1
                let Uq0 = max(eQMax0, kappaA)
                let u_q0 = Uq0 - kappaA
                var eps0 = 0
                if u_q0 > 0 {
                    if q0.eQ0 == eQMax0 { eps0 |= 1 }
                    if q0.eQ1 == eQMax0 { eps0 |= 2 }
                    if q0.eQ2 == eQMax0 { eps0 |= 4 }
                    if q0.eQ3 == eQMax0 { eps0 |= 8 }
                }
                eVal[lep] = max(eVal[lep], UInt8(q0.eQ1)); lep += 1
                maxE = max(Int(eVal[lep]), Int(eVal[lep + 1])) - 1
                eVal[lep] = UInt8(q0.eQ3)
                cxVal[lcxp] = cxVal[lcxp] | UInt8((rho0 & 2) >> 1); lcxp += 1
                var c_q1 = Int(cxVal[lcxp]) + (Int(cxVal[lcxp + 1]) << 2)
                cxVal[lcxp] = UInt8((rho0 & 8) >> 3)

                let tuple0 = Int(vlcTable1Conformant[(c_q0 << 8) | (rho0 << 4) | eps0])
                vlcEnc.encode(codeword: tuple0 >> 8, count: (tuple0 >> 4) & 0x7)
                if c_q0 == 0 {
                    melEnc.encode(eventIsOne: rho0 != 0)
                }
                emitQuadMagSgn(
                    rho: rho0, tuple: tuple0, Uq: Uq0,
                    s0: q0.s0, s1: q0.s1, s2: q0.s2, s3: q0.s3
                )

                var rho1 = 0
                var u_q1 = 0
                if spX + 2 < width {
                    let q1 = try processQuad(baseX: spX + 2, baseY: y)
                    let eQMax1 = q1.eQMax
                    rho1 = q1.rho
                    let kappaB = ((rho1 & (rho1 - 1)) != 0) ? max(1, maxE) : 1
                    c_q1 |= ((rho0 & 4) >> 1) | ((rho0 & 8) >> 2)
                    let Uq1 = max(eQMax1, kappaB)
                    u_q1 = Uq1 - kappaB
                    var eps1 = 0
                    if u_q1 > 0 {
                        if q1.eQ0 == eQMax1 { eps1 |= 1 }
                        if q1.eQ1 == eQMax1 { eps1 |= 2 }
                        if q1.eQ2 == eQMax1 { eps1 |= 4 }
                        if q1.eQ3 == eQMax1 { eps1 |= 8 }
                    }
                    eVal[lep] = max(eVal[lep], UInt8(q1.eQ1)); lep += 1
                    maxE = max(Int(eVal[lep]), Int(eVal[lep + 1])) - 1
                    eVal[lep] = UInt8(q1.eQ3)
                    cxVal[lcxp] = cxVal[lcxp] | UInt8((rho1 & 2) >> 1); lcxp += 1
                    c_q0 = Int(cxVal[lcxp]) + (Int(cxVal[lcxp + 1]) << 2)
                    cxVal[lcxp] = UInt8((rho1 & 8) >> 3)

                    let tuple1 = Int(vlcTable1Conformant[(c_q1 << 8) | (rho1 << 4) | eps1])
                    vlcEnc.encode(codeword: tuple1 >> 8, count: (tuple1 >> 4) & 0x7)
                    if c_q1 == 0 {
                        melEnc.encode(eventIsOne: rho1 != 0)
                    }
                    emitQuadMagSgn(
                        rho: rho1, tuple: tuple1, Uq: Uq1,
                        s0: q1.s0, s1: q1.s1, s2: q1.s2, s3: q1.s3
                    )
                }

                let e0 = uvlcTableConformant[u_q0]
                let e1 = uvlcTableConformant[u_q1]
                vlcEnc.encode(codeword: Int(e0.pre), count: Int(e0.preLen))
                vlcEnc.encode(codeword: Int(e1.pre), count: Int(e1.preLen))
                vlcEnc.encode(codeword: Int(e0.suf), count: Int(e0.sufLen))
                vlcEnc.encode(codeword: Int(e1.suf), count: Int(e1.sufLen))
                vlcEnc.encode(codeword: Int(e0.ext), count: Int(e0.extLen))
                vlcEnc.encode(codeword: Int(e1.ext), count: Int(e1.extLen))

                c_q0 |= ((rho1 & 4) >> 1) | ((rho1 & 8) >> 2)
                spX += 4
            }
            y += 2
        }
    }

    /// Encodes an ITU-T T.814 refinement segment (`HT SigProp` + optional `HT MagRef`, Clauses 7.1.5–7.1.6 & 7.4–7.5)
    /// for bit-plane `bandShift - 1` (`bandShift >= 1`), given the original signed `Int64` block coefficients.
    package static func encodeRefinement(
        coefficients: [Int64],
        width: Int,
        height: Int,
        cleanupBandShift: Int,
        includeMagRef: Bool,
        causal: Bool = false,
        maximumOutputBytes: Int = 2046
    ) throws -> [UInt8] {
        guard width >= 1, height >= 1, coefficients.count == width * height else {
            throw CodecError(.invalidArgument, "HTJ2K refinement block dimensions do not match coefficient count.")
        }
        guard cleanupBandShift >= 1, cleanupBandShift < 63 else {
            throw CodecError(.invalidArgument, "HTJ2K refinement cleanupBandShift (\(cleanupBandShift)) must be in 1..<63.")
        }
        let sampleCount = width * height
        let refBitMask = UInt64(1) << UInt64(cleanupBandShift - 1)

        var sigma = [Bool](repeating: false, count: sampleCount)
        var mags = [UInt64](repeating: 0, count: sampleCount)
        var signs = [Bool](repeating: false, count: sampleCount)
        for i in 0..<sampleCount {
            let v = coefficients[i]
            if v == 0 { continue }
            let mag = v.magnitude
            mags[i] = mag
            signs[i] = (v < 0)
            if (mag >> UInt64(cleanupBandShift)) != 0 {
                sigma[i] = true
            }
        }

        // Forward SigProp bit-stream writer (ITU-T T.814 Clause 7.1.5 & 7.4)
        var spBytes: [UInt8] = []
        var spCur: UInt8 = 0
        var spUsed = 0
        var spMaxBits = 8
        let hardLimit = min(2046, maximumOutputBytes)

        func emitSigPropBit(_ bit: Int) throws {
            spCur |= UInt8(bit & 1) << UInt8(spUsed)
            spUsed += 1
            if spUsed == spMaxBits {
                guard spBytes.count < hardLimit else {
                    throw CodecError(.resourceLimitExceeded, "HTJ2K SigProp stream exceeds segment budget.")
                }
                spBytes.append(spCur)
                spMaxBits = (spCur == 0xFF) ? 7 : 8
                spCur = 0
                spUsed = 0
            }
        }

        var sigPropSig = [Bool](repeating: false, count: sampleCount)
        for stripeY in stride(from: 0, to: height, by: 4) {
            let stripeEnd = min(stripeY + 4, height)
            for colGroup in stride(from: 0, to: width, by: 4) {
                let colEnd = min(colGroup + 4, width)
                for x in colGroup..<colEnd {
                    for y in stripeY..<stripeEnd {
                        let idx = y * width + x
                        if sigma[idx] { continue }
                        let nyMin = max(0, y - 1)
                        let nyMax = (causal && y == stripeEnd - 1) ? y : min(height - 1, y + 1)
                        let nxMin = max(0, x - 1)
                        let nxMax = min(width - 1, x + 1)
                        var mbr = false
                        outerNbr: for ny in nyMin...nyMax {
                            let rowOff = ny * width
                            for nx in nxMin...nxMax {
                                if nx == x && ny == y { continue }
                                let nIdx = rowOff + nx
                                if sigma[nIdx] || sigPropSig[nIdx] {
                                    mbr = true
                                    break outerNbr
                                }
                            }
                        }
                        if mbr {
                            let rBit = (mags[idx] & refBitMask) != 0 ? 1 : 0
                            try emitSigPropBit(rBit)
                            if rBit == 1 {
                                sigPropSig[idx] = true
                            }
                        }
                    }
                }
                for x in colGroup..<colEnd {
                    for y in stripeY..<stripeEnd {
                        let idx = y * width + x
                        if sigPropSig[idx] {
                            try emitSigPropBit(signs[idx] ? 1 : 0)
                        }
                    }
                }
            }
        }
        if spUsed > 0 {
            guard spBytes.count < hardLimit else {
                throw CodecError(.resourceLimitExceeded, "HTJ2K SigProp stream exceeds segment budget.")
            }
            spBytes.append(spCur)
        }
        if spBytes.last == 0xFF {
            guard spBytes.count < hardLimit else {
                throw CodecError(.resourceLimitExceeded, "HTJ2K SigProp trailing stuff byte exceeds segment budget.")
            }
            spBytes.append(0x00)
        }

        if !includeMagRef {
            // Trim trailing zero bytes if there are no MagRef bytes (importSigPropBit synthesizes 0 past Lref),
            // except preserve a stuff 0x00 byte immediately following 0xFF!
            while spBytes.count >= 2 && spBytes[spBytes.count - 1] == 0x00 && spBytes[spBytes.count - 2] != 0xFF {
                spBytes.removeLast()
            }
            if spBytes.count == 1 && spBytes[0] == 0x00 {
                spBytes.removeAll()
            }
            return spBytes
        }

        // Backward MagRef bit-stream writer (ITU-T T.814 Clause 7.1.6 & 7.5)
        var mrRev: [UInt8] = []
        var mrCur: UInt8 = 0
        var mrUsed = 0
        var mrPrev: UInt8 = 0xFF

        func emitMagRefBit(_ bit: Int) throws {
            mrCur |= UInt8(bit & 1) << UInt8(mrUsed)
            mrUsed += 1
            if mrUsed == 7 && mrPrev > 0x8F && mrCur == 0x7F {
                guard spBytes.count + mrRev.count < hardLimit else {
                    throw CodecError(.resourceLimitExceeded, "HTJ2K refinement segment exceeds budget.")
                }
                mrRev.append(mrCur)
                mrPrev = mrCur
                mrCur = 0
                mrUsed = 0
            } else if mrUsed == 8 {
                guard spBytes.count + mrRev.count < hardLimit else {
                    throw CodecError(.resourceLimitExceeded, "HTJ2K refinement segment exceeds budget.")
                }
                mrRev.append(mrCur)
                mrPrev = mrCur
                mrCur = 0
                mrUsed = 0
            }
        }

        for stripeY in stride(from: 0, to: height, by: 4) {
            let stripeEnd = min(stripeY + 4, height)
            for x in 0..<width {
                for y in stripeY..<stripeEnd {
                    let idx = y * width + x
                    if sigma[idx] {
                        let rBit = (mags[idx] & refBitMask) != 0 ? 1 : 0
                        try emitMagRefBit(rBit)
                    }
                }
            }
        }
        if mrUsed > 0 {
            guard spBytes.count + mrRev.count < hardLimit else {
                throw CodecError(.resourceLimitExceeded, "HTJ2K refinement segment exceeds budget.")
            }
            mrRev.append(mrCur)
        }

        var dref = spBytes
        dref.append(contentsOf: mrRev.reversed())
        return dref
    }
}

/// One terminated HT codeword segment (either a 1-pass cleanup segment, a 1..2-pass refinement segment,
/// or a leading zero-length placeholder segment) passed to `HTBlockDecoder.decodeHTCodeBlock`.
package struct HTSegmentInput: Sendable, Equatable {
    package let data: [UInt8]
    package let passes: Int

    package init(data: [UInt8], passes: Int) {
        self.data = data
        self.passes = passes
    }
}

// MARK: - HT Block Decoder (ISO/IEC 15444-15 Clauses 7.1–7.6 & Annex B)

package enum HTBlockDecoder {
    /// Maximum subband bit-plane count supported by 64-bit HT reconstruction (`ITU-T T.814` Clause 8.7.3).
    package static let maximumExtendedKMax = 62

    /// Decode a Part 15 code-block cleanup pass into signed `Int32` wavelet coefficients.
    ///
    /// - Parameters:
    ///   - block: Raw cleanup segment bytes (`Lcup` bytes). If empty, returns all zeros.
    ///   - width: Code-block width in samples (`1...64`).
    ///   - height: Code-block height in samples (`1...64`).
    ///   - kMax: Subband bit-plane count $K_{\max} = M_b = \text{guardBits} + \varepsilon_b - 1$.
    ///   - missingMSBs: Effective missing MSBs $K_{\text{msbs}} = \text{zeroBitPlanes} + \lfloor (\text{totalPasses} - 1) / 3 \rfloor$.
    package static func decodeCleanup(
        block: [UInt8],
        width: Int,
        height: Int,
        kMax: Int,
        missingMSBs: Int
    ) throws -> [Int32] {
        guard kMax >= 1, kMax <= BitPlaneCoder.maximumMagnitudeBitPlanes else {
            throw CodecError(.malformedInput, "HTJ2K subband K_max (\(kMax)) is out of range.")
        }
        let dec64 = try decodeHTCodeBlock(
            segments: [HTSegmentInput(data: block, passes: 1)],
            zeroBitPlanes: missingMSBs,
            totalPasses: 1,
            width: width,
            height: height,
            kMax: kMax,
            causal: false,
            allowMultiHT: false,
            midpointReconstruction: false
        )
        var out = [Int32](repeating: 0, count: dec64.count)
        for i in 0..<dec64.count {
            let v = dec64[i]
            guard v >= Int64(Int32.min), v <= Int64(Int32.max) else {
                throw CodecError(.malformedInput, "HTJ2K decoded coefficient magnitude exceeds subband K_max (\(kMax)) bound.")
            }
            out[i] = Int32(v)
        }
        return out
    }

    /// Decodes a complete Part 15 HT code-block contribution conforming to `ITU-T T.814` Clauses 7.1–7.6 and Annex B,
    /// including `3 * P0` leading placeholder passes, `SINGLEHT`/`MULTIHT` set selection, `HT Cleanup` (7.3),
    /// `HT SigProp` (7.4), `HT MagRef` (7.5), and `Sample output values` (7.6) into signed `Int64` coefficients.
    package static func decodeHTCodeBlock(
        segments: [HTSegmentInput],
        zeroBitPlanes: Int,
        totalPasses: Int,
        width: Int,
        height: Int,
        kMax: Int,
        causal: Bool = false,
        allowMultiHT: Bool = true,
        midpointReconstruction: Bool = false
    ) throws -> [Int64] {
        guard width >= 1, height >= 1 else {
            throw CodecError(.invalidArgument, "Invalid HTJ2K code-block dimensions \(width)x\(height).")
        }
        let sampleCount = try checkedMultiply(width, height)
        guard kMax >= 1, kMax <= maximumExtendedKMax else {
            throw CodecError(.malformedInput, "HTJ2K subband K_max (\(kMax)) is out of range.")
        }
        guard zeroBitPlanes >= 0 else {
            throw CodecError(.malformedInput, "Negative HTJ2K zeroBitPlanes (\(zeroBitPlanes)).")
        }
        if segments.isEmpty || totalPasses <= 0 {
            return [Int64](repeating: 0, count: sampleCount)
        }

        // Partition segments into leading placeholder passes (`3 * P0`) followed by HT sets `(cleanup, refinement?)`
        // per ITU-T T.814 Annex B.1–B.3.
        struct HTSetRecord {
            let cleanupData: [UInt8]
            let refinementData: [UInt8]
            let passCountInSet: Int // 1..3
            let sSkip: Int          // number of HT sets preceding this HT set (after P0)
        }

        var idx = 0
        var placeholderPasses = 0

        // Any strictly zero-length segments preceding the first non-zero cleanup segment contribute placeholder passes.
        while idx < segments.count && segments[idx].data.isEmpty {
            guard segments[idx].passes > 0 else {
                throw CodecError(.malformedInput, "HTJ2K segment carries non-positive pass count.")
            }
            placeholderPasses += segments[idx].passes
            idx += 1
        }

        // All segments empty => pure placeholder-pass contribution (`Z_blk = 0`, all zeros).
        if idx >= segments.count {
            return [Int64](repeating: 0, count: sampleCount)
        }

        // Note: per Annex B.2–B.3, if a single packet included both trailing placeholder passes of the `3 * P0`
        // prefix and the first HT cleanup coding pass, that first non-empty cleanup segment carries
        // `(trailingPlaceholderPasses + 1)` passes where `(placeholderPasses + trailingPlaceholderPasses) % 3 == 0`!
        let firstCleanupSeg = segments[idx]
        guard firstCleanupSeg.passes >= 1 else {
            throw CodecError(.malformedInput, "HTJ2K first cleanup segment carries non-positive pass count.")
        }
        let totalBeforeAfterFirstCleanup = placeholderPasses + (firstCleanupSeg.passes - 1)
        guard totalBeforeAfterFirstCleanup % 3 == 0 else {
            throw CodecError(.malformedInput, "HTJ2K leading placeholder pass count (\(totalBeforeAfterFirstCleanup)) is not a multiple of 3 (Annex B.1).")
        }
        let p0 = totalBeforeAfterFirstCleanup / 3
        guard firstCleanupSeg.data.count > 1 else {
            throw CodecError(.malformedInput, "HTJ2K first cleanup segment length (\(firstCleanupSeg.data.count)) must exceed 1 byte (Annex B.3).")
        }

        var htSets: [HTSetRecord] = []
        var sSkipCounter = 0

        while idx < segments.count {
            let cupSeg = segments[idx]
            idx += 1
            let cupPasses = (sSkipCounter == 0) ? 1 : cupSeg.passes
            guard cupPasses == 1 else {
                throw CodecError(.malformedInput, "HTJ2K cleanup segment carries \(cupPasses) passes instead of 1 (Annex B.2).")
            }
            if sSkipCounter > 0 && !cupSeg.data.isEmpty && cupSeg.data.count <= 1 {
                throw CodecError(.malformedInput, "HTJ2K cleanup segment length (\(cupSeg.data.count)) must be 0 or > 1 (Annex B.3).")
            }

            var refData: [UInt8] = []
            var refPasses = 0
            if idx < segments.count {
                // Next segment in the same HT set is the refinement segment (1 or 2 passes).
                // Note: if the previous HT set stopped after cleanup (1 pass), there are no further HT sets!
                let nextSeg = segments[idx]
                guard nextSeg.passes >= 1, nextSeg.passes <= 2 else {
                    throw CodecError(.malformedInput, "HTJ2K refinement segment carries \(nextSeg.passes) passes (expected 1 or 2).")
                }
                if cupSeg.data.isEmpty && !nextSeg.data.isEmpty {
                    throw CodecError(.malformedInput, "HTJ2K empty cleanup segment followed by non-empty refinement segment (Annex B.3).")
                }
                guard nextSeg.data.count <= 2046 else {
                    throw CodecError(.malformedInput, "HTJ2K refinement segment length (\(nextSeg.data.count)) exceeds 2046-byte limit.")
                }
                refData = nextSeg.data
                refPasses = nextSeg.passes
                idx += 1
                // An HT set with only 2 total passes (Cleanup + SigProp, no MagRef) must be the final HT set per B.1!
                if refPasses < 2 && idx < segments.count {
                    throw CodecError(.malformedInput, "Non-final HTJ2K set has fewer than 3 coding passes (Annex B.1).")
                }
            }

            htSets.append(HTSetRecord(
                cleanupData: cupSeg.data,
                refinementData: refData,
                passCountInSet: 1 + refPasses,
                sSkip: sSkipCounter
            ))
            sSkipCounter += 1
        }

        if htSets.count > 1 && !allowMultiHT {
            throw CodecError(.malformedInput, "Codestream contains \(htSets.count) HT sets for a code-block while CAP Ccap15 signals SINGLEHT.")
        }

        // Validate every non-empty HT set's S_blk and trailer, and select the last non-empty HT set (`Z_blk > 0`)
        // for highest-fidelity sample reconstruction (ITU-T T.814 Clause 8.3 & Annex B.3).
        var activeSet: HTSetRecord?
        for set in htSets where !set.cleanupData.isEmpty {
            let sBlk = zeroBitPlanes + p0 + set.sSkip
            guard sBlk >= 0, sBlk < kMax else {
                throw CodecError(.malformedInput, "HTJ2K S_blk (\(sBlk)) exceeds subband K_max - 1 (\(kMax - 1)).")
            }
            guard HTBlockLayout.parse(block: set.cleanupData) != nil else {
                throw CodecError(.malformedInput, "Malformed HTJ2K cleanup segment trailer (Scup/Lcup).")
            }
            activeSet = set
        }

        guard let chosen = activeSet, let parsed = HTBlockLayout.parse(block: chosen.cleanupData) else {
            return [Int64](repeating: 0, count: sampleCount)
        }

        let sBlk = zeroBitPlanes + p0 + chosen.sSkip
        let zBlk: Int
        if chosen.cleanupData.isEmpty {
            zBlk = 0
        } else if chosen.refinementData.isEmpty {
            zBlk = 1
        } else {
            zBlk = chosen.passCountInSet // 2 (Cleanup + SigProp) or 3 (Cleanup + SigProp + MagRef)
        }

        var state = DecodeState(
            melVlcBytes: parsed.melVlc,
            scup: parsed.scup,
            magsgnBytes: parsed.magsgn,
            width: width,
            height: height
        )
        try state.decodeInitialRow()
        var y = 2
        while y < height {
            try state.decodeSubsequentRow(y: y)
            y += 2
        }

        var sigma = [Bool](repeating: false, count: sampleCount)
        var sign = [Bool](repeating: false, count: sampleCount)
        var muArr = [UInt64](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let word = state.coefs[i]
            if word != 0 {
                sigma[i] = true
                sign[i] = (word & 0x8000_0000) != 0
                muArr[i] = UInt64(word & 0x7FFF_FFFF)
            }
        }

        var zN = [UInt8](repeating: 0, count: sampleCount)
        var rN = [UInt8](repeating: 0, count: sampleCount)

        // Clause 7.4: HT SigProp decoding procedure (`Z_blk > 1`)
        if zBlk >= 2 {
            var spReader = HTSigPropReader(bytes: chosen.refinementData)
            var sigPropSig = [Bool](repeating: false, count: sampleCount)

            for stripeY in stride(from: 0, to: height, by: 4) {
                let stripeEnd = min(stripeY + 4, height)
                for colGroup in stride(from: 0, to: width, by: 4) {
                    let colEnd = min(colGroup + 4, width)
                    // Step 1: decodeSigPropMag across 4-column group
                    for x in colGroup..<colEnd {
                        for sy in stripeY..<stripeEnd {
                            let sampleIdx = sy * width + x
                            if sigma[sampleIdx] { continue }
                            let nyMin = max(0, sy - 1)
                            let nyMax = (causal && sy == stripeEnd - 1) ? sy : min(height - 1, sy + 1)
                            let nxMin = max(0, x - 1)
                            let nxMax = min(width - 1, x + 1)
                            var mbr = false
                            outerNbr: for ny in nyMin...nyMax {
                                let rowOff = ny * width
                                for nx in nxMin...nxMax {
                                    if nx == x && ny == sy { continue }
                                    let nIdx = rowOff + nx
                                    if sigma[nIdx] || sigPropSig[nIdx] {
                                        mbr = true
                                        break outerNbr
                                    }
                                }
                            }
                            if mbr {
                                zN[sampleIdx] = 1
                                let rBit = try spReader.importSigPropBit()
                                rN[sampleIdx] = UInt8(rBit)
                                if rBit == 1 {
                                    sigPropSig[sampleIdx] = true
                                }
                            }
                        }
                    }
                    // Step 2: decodeSigPropSign across the same 4-column group
                    for x in colGroup..<colEnd {
                        for sy in stripeY..<stripeEnd {
                            let sampleIdx = sy * width + x
                            if sigPropSig[sampleIdx] {
                                let sBit = try spReader.importSigPropBit()
                                sign[sampleIdx] = (sBit != 0)
                            }
                        }
                    }
                }
            }
        }

        // Clause 7.5: HT MagRef decoding procedure (`Z_blk == 3`)
        if zBlk == 3 {
            var mrReader = HTMagRefReader(bytes: chosen.refinementData)
            for stripeY in stride(from: 0, to: height, by: 4) {
                let stripeEnd = min(stripeY + 4, height)
                for x in 0..<width {
                    for sy in stripeY..<stripeEnd {
                        let sampleIdx = sy * width + x
                        if sigma[sampleIdx] {
                            zN[sampleIdx] = 1
                            rN[sampleIdx] = UInt8(mrReader.importMagRefBit())
                        }
                    }
                }
            }
        }

        // Clause 7.6: Sample output values
        let p = kMax - 1 - sBlk
        let maxMagnitudeBound: UInt64 = (kMax >= 64) ? UInt64.max : (UInt64(1) << UInt64(kMax))
        var output = [Int64](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount {
            let mu = muArr[i]
            let z = Int(zN[i])
            let r = UInt64(rN[i])
            if mu == 0 && r == 0 { continue }

            // Guard against shift overflow on untrusted `mu` + `p`
            if mu != 0 && p > 0 {
                let leadZeros = mu.leadingZeroBitCount
                if p >= leadZeros {
                    throw CodecError(.malformedInput, "HTJ2K decoded coefficient magnitude exceeds subband K_max (\(kMax)) bound.")
                }
            }
            var mag: UInt64 = mu << UInt64(p)
            if z != 0 && r != 0 {
                if p >= 1 {
                    mag |= r << UInt64(p - 1)
                }
            }
            if midpointReconstruction && mag > 0 {
                let lastDecodedPlane = p - z
                if lastDecodedPlane > 0 {
                    mag |= UInt64(1) << UInt64(lastDecodedPlane - 1)
                }
            }
            guard mag < maxMagnitudeBound, mag <= UInt64(Int64.max) else {
                throw CodecError(.malformedInput, "HTJ2K decoded coefficient magnitude exceeds subband K_max (\(kMax)) bound.")
            }
            let signedVal = Int64(bitPattern: mag)
            output[i] = sign[i] ? -signedVal : signedVal
        }
        return output
    }
}

private struct HTSigPropReader {
    private let dref: [UInt8]
    private let lref: Int
    private var pos: Int = 0
    private var bits: Int = 0
    private var tmp: UInt8 = 0
    private var last: UInt8 = 0

    init(bytes: [UInt8]) {
        self.dref = bytes
        self.lref = bytes.count
    }

    @inline(__always)
    mutating func importSigPropBit() throws -> Int {
        if bits == 0 {
            bits = (last == 0xFF) ? 7 : 8
            if pos < lref {
                tmp = dref[pos]
                pos += 1
                if bits == 7 && (tmp & 0x80) != 0 {
                    throw CodecError(.malformedInput, "Malformed HTJ2K SigProp stuffed bit after 0xFF (Clause 7.1.5).")
                }
            } else {
                tmp = 0
            }
            last = tmp
        }
        let bit = Int(tmp & 1)
        tmp >>= 1
        bits -= 1
        return bit
    }
}

private struct HTMagRefReader {
    private let dref: [UInt8]
    private var pos: Int
    private var bits: Int = 0
    private var last: UInt8 = 0xFF
    private var tmp: UInt8 = 0

    init(bytes: [UInt8]) {
        self.dref = bytes
        self.pos = bytes.count - 1
    }

    @inline(__always)
    mutating func importMagRefBit() -> Int {
        if bits == 0 {
            if pos >= 0 {
                tmp = dref[pos]
                pos -= 1
            } else {
                tmp = 0
            }
            bits = 8
            if last > 0x8F && (tmp & 0x7F) == 0x7F {
                bits = 7
            }
            last = tmp
        }
        let bit = Int(tmp & 1)
        tmp >>= 1
        bits -= 1
        return bit
    }
}

private struct DecodeState {
    var melDec: HTMELDecoder
    var vlcReader: VLCReverseReader
    var magsgnDec: HTMagSgnDecoder
    let width: Int
    let height: Int
    var eVal: [UInt8]
    var cxVal: [UInt8]
    /// Stores `(mu_p & 0x7FFF_FFFF) | (sign << 31)` for each sample.
    var coefs: [UInt32]
    var melRun: Int

    init(
        melVlcBytes: ArraySlice<UInt8>,
        scup: Int,
        magsgnBytes: ArraySlice<UInt8>,
        width: Int,
        height: Int
    ) {
        self.melDec = HTMELDecoder(bytes: melVlcBytes)
        self.vlcReader = VLCReverseReader(melVlcBytes: melVlcBytes, scup: scup)
        self.magsgnDec = HTMagSgnDecoder(bytes: magsgnBytes)
        self.width = width
        self.height = height
        let guarded = ((width + 3) / 4) * 2 + 2
        self.eVal = [UInt8](repeating: 0, count: guarded)
        self.cxVal = [UInt8](repeating: 0, count: guarded)
        self.coefs = [UInt32](repeating: 0, count: width * height)
        self.melRun = self.melDec.nextRun()
    }

    mutating func nextMELEvent() -> Bool {
        melRun -= 2
        let isOne = (melRun == -1)
        if melRun < 0 {
            melRun = melDec.nextRun()
        }
        return isOne
    }

    @inline(__always)
    func lookupVLC(
        c_q: Int,
        bits: Int,
        initialLine: Bool
    ) -> (rho: Int, u_off: Int, cwd_len: Int, e_k: Int, e_1: Int) {
        let tbl = initialLine ? vlcDecoderTable0Conformant : vlcDecoderTable1Conformant
        let idx = (c_q << 7) | (bits & 0x7F)
        let entry = Int(tbl[idx])
        let cwd_len = entry & 0x7
        let u_off   = (entry >> 3) & 0x1
        let rho     = (entry >> 4) & 0xF
        let e_1     = (entry >> 8) & 0xF
        let e_k     = (entry >> 12) & 0xF
        return (rho: rho, u_off: u_off, cwd_len: cwd_len, e_k: e_k, e_1: e_1)
    }

    mutating func readPrefix() -> Int {
        let b0 = Int(vlcReader.read(count: 1))
        if b0 == 1 { return 1 }
        let b1 = Int(vlcReader.read(count: 1))
        if b1 == 1 { return 2 }
        let b2 = Int(vlcReader.read(count: 1))
        if b2 == 1 { return 3 }
        return 4
    }

    mutating func decodeFromPrefix(_ len: Int) -> Int {
        if len == 3 {
            let suf = Int(vlcReader.read(count: 1))
            return 3 + suf
        }
        if len == 4 {
            let suf = Int(vlcReader.read(count: 5))
            if suf < 28 { return 5 + suf }
            let ext = Int(vlcReader.read(count: 4))
            return 33 + (suf - 28) + 4 * ext
        }
        return len
    }

    mutating func decodeUVLCPairInitial(u_off0: Int, u_off1: Int) -> (Int, Int) {
        if u_off0 == 0 && u_off1 == 0 { return (0, 0) }
        if u_off0 == 1 && u_off1 == 1 {
            let melEvent = nextMELEvent()
            if melEvent {
                let p0 = readPrefix()
                let p1 = readPrefix()
                let s0 = decodeFromPrefix(p0)
                let s1 = decodeFromPrefix(p1)
                return (s0 + 2, s1 + 2)
            }
            let p0 = readPrefix()
            if p0 >= 3 {
                let bit = Int(vlcReader.read(count: 1))
                let u0 = decodeFromPrefix(p0)
                return (u0, bit + 1)
            }
            let p1 = readPrefix()
            let u0 = decodeFromPrefix(p0)
            let u1 = decodeFromPrefix(p1)
            return (u0, u1)
        }
        let u0 = (u_off0 != 0) ? decodeFromPrefix(readPrefix()) : 0
        let u1 = (u_off1 != 0) ? decodeFromPrefix(readPrefix()) : 0
        return (u0, u1)
    }

    mutating func decodeUVLCPairSubsequent(u_off0: Int, u_off1: Int) -> (Int, Int) {
        let len0 = (u_off0 != 0) ? readPrefix() : 0
        let len1 = (u_off1 != 0) ? readPrefix() : 0
        let u0 = (u_off0 != 0) ? decodeFromPrefix(len0) : 0
        let u1 = (u_off1 != 0) ? decodeFromPrefix(len1) : 0
        return (u0, u1)
    }

    mutating func decodeInitialRow() throws {
        var lep = 0
        var lcxp = 0
        var c_q0 = 0
        var x = 0
        while x < width {
            var rho0 = 0
            var look0: (rho: Int, u_off: Int, cwd_len: Int, e_k: Int, e_1: Int) = (0, 0, 0, 0, 0)
            if c_q0 == 0 {
                if nextMELEvent() {
                    let head = Int(vlcReader.peek(maxBits: 7))
                    look0 = lookupVLC(c_q: c_q0, bits: head, initialLine: true)
                    vlcReader.consume(count: look0.cwd_len)
                    rho0 = look0.rho
                }
            } else {
                let head = Int(vlcReader.peek(maxBits: 7))
                look0 = lookupVLC(c_q: c_q0, bits: head, initialLine: true)
                vlcReader.consume(count: look0.cwd_len)
                rho0 = look0.rho
            }

            var rho1 = 0
            var look1: (rho: Int, u_off: Int, cwd_len: Int, e_k: Int, e_1: Int) = (0, 0, 0, 0, 0)
            if x + 2 < width {
                let c_q1 = (rho0 >> 1) | (rho0 & 1)
                if c_q1 == 0 {
                    if nextMELEvent() {
                        let head1 = Int(vlcReader.peek(maxBits: 7))
                        look1 = lookupVLC(c_q: c_q1, bits: head1, initialLine: true)
                        vlcReader.consume(count: look1.cwd_len)
                        rho1 = look1.rho
                    }
                } else {
                    let head1 = Int(vlcReader.peek(maxBits: 7))
                    look1 = lookupVLC(c_q: c_q1, bits: head1, initialLine: true)
                    vlcReader.consume(count: look1.cwd_len)
                    rho1 = look1.rho
                }
            }

            let (u_q0, u_q1) = decodeUVLCPairInitial(
                u_off0: rho0 != 0 ? look0.u_off : 0,
                u_off1: rho1 != 0 ? look1.u_off : 0
            )
            let Uq0 = u_q0 + 1
            let Uq1 = u_q1 + 1

            try readQuadSamples(
                baseX: x, baseY: 0,
                rho: rho0, Uq: Uq0,
                e_k: look0.e_k, e_1: look0.e_1
            )
            if x + 2 < width {
                try readQuadSamples(
                    baseX: x + 2, baseY: 0,
                    rho: rho1, Uq: Uq1,
                    e_k: look1.e_k, e_1: look1.e_1
                )
            }

            let eQ0 = recoverEQBottomRow(rho: rho0, baseX: x, baseY: 0)
            eVal[lep] = max(eVal[lep], UInt8(eQ0.0)); lep += 1
            eVal[lep] = UInt8(eQ0.1)
            cxVal[lcxp] = cxVal[lcxp] | UInt8((rho0 & 2) >> 1); lcxp += 1
            cxVal[lcxp] = UInt8((rho0 & 8) >> 3)
            if x + 2 < width {
                let eQ1 = recoverEQBottomRow(rho: rho1, baseX: x + 2, baseY: 0)
                eVal[lep] = max(eVal[lep], UInt8(eQ1.0)); lep += 1
                eVal[lep] = UInt8(eQ1.1)
                cxVal[lcxp] = cxVal[lcxp] | UInt8((rho1 & 2) >> 1); lcxp += 1
                cxVal[lcxp] = UInt8((rho1 & 8) >> 3)
            }

            c_q0 = (rho1 >> 1) | (rho1 & 1)
            x += 4
        }
        if lep + 1 < eVal.count { eVal[lep + 1] = 0 }
    }

    mutating func decodeSubsequentRow(y: Int) throws {
        var lep = 0
        var lcxp = 0
        var maxE = max(Int(eVal[0]), Int(eVal[1])) - 1
        eVal[0] = 0
        var c_q0 = Int(cxVal[0]) + (Int(cxVal[1]) << 2)
        cxVal[0] = 0

        var x = 0
        while x < width {
            var rho0 = 0
            var look0: (rho: Int, u_off: Int, cwd_len: Int, e_k: Int, e_1: Int) = (0, 0, 0, 0, 0)
            if c_q0 == 0 {
                if nextMELEvent() {
                    let head = Int(vlcReader.peek(maxBits: 7))
                    look0 = lookupVLC(c_q: c_q0, bits: head, initialLine: false)
                    vlcReader.consume(count: look0.cwd_len)
                    rho0 = look0.rho
                }
            } else {
                let head = Int(vlcReader.peek(maxBits: 7))
                look0 = lookupVLC(c_q: c_q0, bits: head, initialLine: false)
                vlcReader.consume(count: look0.cwd_len)
                rho0 = look0.rho
            }
            let kappaA = ((rho0 & (rho0 - 1)) != 0) ? max(1, maxE) : 1

            cxVal[lcxp] = cxVal[lcxp] | UInt8((rho0 & 2) >> 1); lcxp += 1
            var c_q1 = Int(cxVal[lcxp]) + (Int(cxVal[lcxp + 1]) << 2)
            cxVal[lcxp] = UInt8((rho0 & 8) >> 3)

            var rho1 = 0
            var look1: (rho: Int, u_off: Int, cwd_len: Int, e_k: Int, e_1: Int) = (0, 0, 0, 0, 0)
            if x + 2 < width {
                c_q1 |= ((rho0 & 4) >> 1) | ((rho0 & 8) >> 2)
                if c_q1 == 0 {
                    if nextMELEvent() {
                        let head1 = Int(vlcReader.peek(maxBits: 7))
                        look1 = lookupVLC(c_q: c_q1, bits: head1, initialLine: false)
                        vlcReader.consume(count: look1.cwd_len)
                        rho1 = look1.rho
                    }
                } else {
                    let head1 = Int(vlcReader.peek(maxBits: 7))
                    look1 = lookupVLC(c_q: c_q1, bits: head1, initialLine: false)
                    vlcReader.consume(count: look1.cwd_len)
                    rho1 = look1.rho
                }
                cxVal[lcxp] = cxVal[lcxp] | UInt8((rho1 & 2) >> 1); lcxp += 1
                c_q0 = Int(cxVal[lcxp]) + (Int(cxVal[lcxp + 1]) << 2)
                cxVal[lcxp] = UInt8((rho1 & 8) >> 3)
            }

            let (u_q0, u_q1) = decodeUVLCPairSubsequent(
                u_off0: rho0 != 0 ? look0.u_off : 0,
                u_off1: rho1 != 0 ? look1.u_off : 0
            )

            let Uq0 = u_q0 + kappaA
            try readQuadSamples(
                baseX: x, baseY: y,
                rho: rho0, Uq: Uq0,
                e_k: look0.e_k, e_1: look0.e_1
            )

            let eQ0pair = recoverEQBottomRow(rho: rho0, baseX: x, baseY: y)
            eVal[lep] = max(eVal[lep], UInt8(eQ0pair.0)); lep += 1
            let maxEAfterQ0 = max(Int(eVal[lep]), Int(eVal[lep + 1])) - 1
            eVal[lep] = UInt8(eQ0pair.1)

            if x + 2 < width {
                let kappaB = ((rho1 & (rho1 - 1)) != 0) ? max(1, maxEAfterQ0) : 1
                let Uq1 = u_q1 + kappaB
                try readQuadSamples(
                    baseX: x + 2, baseY: y,
                    rho: rho1, Uq: Uq1,
                    e_k: look1.e_k, e_1: look1.e_1
                )

                let eQ1pair = recoverEQBottomRow(rho: rho1, baseX: x + 2, baseY: y)
                eVal[lep] = max(eVal[lep], UInt8(eQ1pair.0)); lep += 1
                maxE = max(Int(eVal[lep]), Int(eVal[lep + 1])) - 1
                eVal[lep] = UInt8(eQ1pair.1)
            } else {
                maxE = maxEAfterQ0
            }

            c_q0 |= ((rho1 & 4) >> 1) | ((rho1 & 8) >> 2)
            x += 4
        }
    }

    @inline(__always)
    mutating func readQuadSamples(
        baseX: Int,
        baseY: Int,
        rho: Int,
        Uq: Int,
        e_k: Int,
        e_1: Int
    ) throws {
        if rho == 0 { return }
        for i in 0..<4 {
            let bit = (rho >> i) & 1
            if bit == 0 { continue }
            let eBit = (e_k >> i) & 1
            let e1Bit = (e_1 >> i) & 1
            let m = Uq - eBit
            guard m >= 1, m <= 31 else {
                throw CodecError(.malformedInput, "HTJ2K magnitude bit count (\(m)) is out of range.")
            }
            let payload = magsgnDec.read(count: m)
            let sign = UInt32(payload & 1)
            let mask: UInt64 = (UInt64(1) << m) - 1
            var v_n: UInt64 = UInt64(payload) & mask
            v_n |= UInt64(e1Bit) << m
            v_n |= 1
            let mu = (v_n + 2) >> 1
            guard mu <= 0x7FFF_FFFF else {
                throw CodecError(.malformedInput, "HTJ2K cleanup magnitude overflows 31-bit representation.")
            }
            let dx = i >> 1
            let dy = i & 1
            let xi = baseX + dx
            let yi = baseY + dy
            if xi >= width || yi >= height { continue }
            var word = UInt32(mu)
            if sign != 0 { word |= 0x8000_0000 }
            coefs[yi * width + xi] = word
        }
    }

    @inline(__always)
    func recoverEQBottomRow(rho: Int, baseX: Int, baseY: Int) -> (Int, Int) {
        if rho == 0 { return (0, 0) }
        var eQ1 = 0
        if (rho >> 1) & 1 != 0 {
            let yi = baseY + 1
            if baseX < width && yi < height {
                let mu = coefs[yi * width + baseX] & 0x7FFF_FFFF
                let twoMuMinusOne = (mu &<< 1) &- 1
                eQ1 = 32 - twoMuMinusOne.leadingZeroBitCount
            }
        }
        var eQ3 = 0
        if (rho >> 3) & 1 != 0 {
            let xi = baseX + 1
            let yi = baseY + 1
            if xi < width && yi < height {
                let mu = coefs[yi * width + xi] & 0x7FFF_FFFF
                let twoMuMinusOne = (mu &<< 1) &- 1
                eQ3 = 32 - twoMuMinusOne.leadingZeroBitCount
            }
        }
        return (eQ1, eQ3)
    }
}

private struct VLCReverseReader {
    private let melVlcBytes: ArraySlice<UInt8>
    private let bytesStart: Int
    private var byteIdx: Int
    private var tmp: UInt64 = 0
    private var bits: Int = 0
    private var unstuff: Bool = false

    init(melVlcBytes: ArraySlice<UInt8>, scup: Int) {
        self.melVlcBytes = melVlcBytes
        self.bytesStart = melVlcBytes.startIndex
        self.byteIdx = scup - 2
        if byteIdx >= 0 {
            let b = melVlcBytes[bytesStart + byteIdx]
            let highNibble = UInt64(b >> 4)
            let t = ((highNibble & 0x7) == 0x7) ? UInt64(1) : UInt64(0)
            let val = highNibble & (0xF >> t)
            tmp = val
            bits = Int(4 - t)
            unstuff = val > 0x8
            byteIdx -= 1
        }
    }

    @inline(__always)
    mutating func refillScalar() {
        while bits <= 32 {
            let byte: UInt8
            if byteIdx >= 0 {
                byte = melVlcBytes[bytesStart + byteIdx]
                byteIdx -= 1
            } else {
                byte = 0
            }
            let t: Int = (unstuff && (Int(byte) & 0x7F) == 0x7F) ? 1 : 0
            let dBits = 8 - t
            let mask: UInt8 = (t == 1) ? 0x7F : 0xFF
            let value = UInt64(byte & mask)
            tmp |= value << bits
            bits += dBits
            unstuff = (byte > 0x8F)
        }
    }

    @inline(__always)
    mutating func peek(maxBits: Int) -> UInt64 {
        if bits < maxBits { refillScalar() }
        let m: UInt64 = (maxBits >= 64) ? ~UInt64(0) : ((UInt64(1) << maxBits) - 1)
        return tmp & m
    }

    @inline(__always)
    mutating func read(count: Int) -> UInt64 {
        if bits < count { refillScalar() }
        let m: UInt64 = (count >= 64) ? ~UInt64(0) : ((UInt64(1) << count) - 1)
        let v = tmp & m
        tmp >>= count
        bits -= count
        return v
    }

    @inline(__always)
    mutating func consume(count: Int) {
        tmp >>= count
        bits -= count
    }
}
