// SPDX-License-Identifier: MIT
//
// EBCOT tier-1 block coder (ISO/IEC 15444-1 Annex D): three coding passes per
// bit-plane. The encoder emits the default code-block style; the decoder
// (Milestone 4) additionally handles every Table A.19 style bit: selective
// arithmetic bypass with raw passes (D.6), context reset (D.4.1),
// termination on each pass and the resulting codeword segments (D.4.2),
// vertically causal contexts (D.7), predictable termination (transparent to
// a decoder) and segmentation symbols (D.5).
//
// Provenance: adapted from Raster-Lab/J2KSwift at commit
// 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca,
// Sources/J2KCodec/J2KBitPlaneCoder.swift (MIT under
// POL-07). Retained: the stripe-oriented scan, the significance-propagation,
// magnitude-refinement and cleanup pass rules including run-length coding
// with the two uniform-context position bits, the sign XOR prediction and
// the visited/refined flag handling. The raw (bypass) bit reader follows the
// predecessor's RawBypassDecoder with bounds-checked indexing. Not migrated:
// rate-control distortion accounting, MQ checkpoints, SIMD magnitude
// splitting, scratch-buffer pools, debug tracing and half-LSB reconstruction
// of truncated code-blocks.

/// Result of coding one code-block: the codeword segment(s), the number of
/// coding passes it contains, the number of missing most-significant
/// bit-planes relative to the band's `Mb`, and optional per-pass/per-layer metadata.
package struct CodeBlockEncoding: Sendable {
    package var data: [UInt8]
    package var passCount: Int
    package let zeroBitPlanes: Int
    package var passByteOffsets: [Int]
    package var passTerminatedBytes: [Int]
    package var passDistortionReductions: [Double]
    package var layerPassCounts: [Int]
    package var passTails: [MQTerminationTail]

    package init(
        data: [UInt8],
        passCount: Int,
        zeroBitPlanes: Int,
        passByteOffsets: [Int] = [],
        passTerminatedBytes: [Int] = [],
        passDistortionReductions: [Double] = [],
        layerPassCounts: [Int]? = nil,
        passTails: [MQTerminationTail] = []
    ) {
        self.data = data
        self.passCount = passCount
        self.zeroBitPlanes = zeroBitPlanes
        self.passByteOffsets = passByteOffsets.isEmpty && passCount > 0
            ? Array(repeating: data.count, count: passCount)
            : passByteOffsets
        self.passTerminatedBytes = passTerminatedBytes.isEmpty ? self.passByteOffsets : passTerminatedBytes
        self.passDistortionReductions = passDistortionReductions
        self.layerPassCounts = layerPassCounts ?? [passCount]
        self.passTails = passTails
    }

    /// Zero-auxiliary-allocation initializer for single-layer lossless Tier-2 packet assembly.
    @inline(__always)
    package init(losslessSingleLayer data: [UInt8], passCount: Int, zeroBitPlanes: Int) {
        self.data = data
        self.passCount = passCount
        self.zeroBitPlanes = zeroBitPlanes
        self.passByteOffsets = []
        self.passTerminatedBytes = []
        self.passDistortionReductions = []
        self.layerPassCounts = []
        self.passTails = []
    }

    /// Truncates an encoded code-block to `count` coding passes in O(bytes) using recorded
    /// `MQTerminationTail` snapshots without re-running bit-plane coding.
    package func truncated(toPasses count: Int, style: CodeBlockStyle) -> CodeBlockEncoding? {
        if count <= 0 {
            return CodeBlockEncoding(data: [], passCount: 0, zeroBitPlanes: zeroBitPlanes)
        }
        if count >= passCount {
            return self
        }
        guard count <= passTails.count else {
            return nil
        }
        let snap = passTails[count - 1]
        var newData: [UInt8] = []
        newData.reserveCapacity(max(0, snap.totalCount))
        let prefixCount = min(snap.baseCount, data.count)
        if prefixCount > 0 {
            newData.append(contentsOf: data[0..<prefixCount])
        }
        if snap.baseCount > data.count {
            newData.append(contentsOf: repeatElement(UInt8(0xFF), count: snap.baseCount - data.count))
        }
        if snap.tailCount >= 1 { newData.append(snap.tail0) }
        if snap.tailCount >= 2 { newData.append(snap.tail1) }
        if snap.tailCount >= 3 { newData.append(snap.tail2) }
        if snap.tailCount >= 4 { newData.append(snap.tail3) }

        var newOffsets = Array(passByteOffsets.prefix(count))
        for i in 0..<newOffsets.count {
            if newOffsets[i] > newData.count { newOffsets[i] = newData.count }
            if i > 0 && newOffsets[i] < newOffsets[i - 1] { newOffsets[i] = newOffsets[i - 1] }
        }
        if !newOffsets.isEmpty {
            newOffsets[newOffsets.count - 1] = newData.count
        }
        let newTerm = Array(passTerminatedBytes.prefix(count))
        let newDist = passDistortionReductions.isEmpty
            ? []
            : Array(passDistortionReductions.prefix(min(count, passDistortionReductions.count)))
        let newTails = Array(passTails.prefix(count))
        return CodeBlockEncoding(
            data: newData,
            passCount: count,
            zeroBitPlanes: zeroBitPlanes,
            passByteOffsets: newOffsets,
            passTerminatedBytes: newTerm,
            passDistortionReductions: newDist,
            passTails: newTails
        )
    }
}

/// Raw (bypass) bit writer: MSB first, seven bits after a 0xFF byte (D.6).
package struct RawEncoder: Sendable {
    private var bytes: [UInt8] = []
    private var current: UInt8 = 0
    private var maxBits: Int = 8
    private var usedBits: Int = 0
    private let maximumOutputBytes: Int
    private let budget: EntropyOutputBudget?
    package private(set) var reservedBudgetBytes: Int = 0
    package private(set) var overflowed = false

    package init(maximumOutputBytes: Int = Int.max, budget: EntropyOutputBudget? = nil) {
        self.maximumOutputBytes = maximumOutputBytes
        self.budget = budget
    }

    @inline(__always)
    private mutating func appendAdmittedByte(_ byte: UInt8) {
        guard !overflowed, bytes.count < maximumOutputBytes else {
            overflowed = true
            return
        }
        if let budget, bytes.count >= reservedBudgetBytes {
            let chunk = min(64, max(1, maximumOutputBytes - reservedBudgetBytes))
            do {
                try budget.reserve(reservedBudgetBytes, countsTowardCompressedOutput: false, site: "raw-encoder-growth-overlap")
                defer { budget.release(reservedBudgetBytes, countsTowardCompressedOutput: false, site: "raw-encoder-growth-overlap") }
                try budget.reserve(chunk, countsTowardCompressedOutput: true, site: "raw-encoder-chunk")
                budget.recordActualAllocation(chunk, site: "raw-encoder-chunk")
                bytes.reserveCapacity(reservedBudgetBytes + chunk)
            } catch {
                overflowed = true
                return
            }
            reservedBudgetBytes += chunk
        }
        bytes.append(byte)
    }

    package mutating func releaseAllReservedBudget() {
        if let budget, reservedBudgetBytes > 0 {
            budget.release(reservedBudgetBytes, countsTowardCompressedOutput: true, site: "raw-encoder-rollback")
            reservedBudgetBytes = 0
        }
    }

    package mutating func discardFinishedStorage() {
        bytes = []
        reservedBudgetBytes = 0
    }

    @inline(__always)
    package mutating func encode(_ bit: Bool) {
        current = (current << 1) | (bit ? 1 : 0)
        usedBits += 1
        if usedBits == maxBits {
            appendAdmittedByte(current)
            maxBits = current == 0xFF ? 7 : 8
            current = 0
            usedBits = 0
        }
    }

    package mutating func finish() -> [UInt8] {
        if usedBits > 0 {
            let remaining = maxBits - usedBits
            // Pad remaining low bits with alternating 0101... (0x55 mask) per Annex D.6
            let padMask = UInt8((1 << remaining) - 1) & 0x55
            let finalByte = (current << UInt8(remaining)) | padMask
            appendAdmittedByte(finalByte)
            current = 0
            usedBits = 0
            maxBits = 8
        }
        while let last = bytes.last, last == 0xFF {
            bytes.removeLast()
        }
        if !overflowed, let budget, reservedBudgetBytes > bytes.count {
            do {
                try budget.compactOutput(&bytes, reservedBytes: &reservedBudgetBytes, site: "raw-encoder-finish-compact")
            } catch {
                overflowed = true
            }
        }
        return bytes
    }

    package var emittedByteCount: Int { bytes.count + (usedBits > 0 ? 1 : 0) }

    @inline(__always)
    package func terminatedSnapshot(prefixOffset: Int = 0) -> MQTerminationTail {
        if usedBits > 0 {
            let remaining = maxBits - usedBits
            let padMask = UInt8((1 << remaining) - 1) & 0x55
            let finalByte = (current << UInt8(remaining)) | padMask
            if finalByte != 0xFF {
                let base = prefixOffset + bytes.count
                return MQTerminationTail(totalCount: base + 1, baseCount: base, tail0: finalByte, tailCount: 1)
            }
        }
        var count = bytes.count
        while count > 0 && bytes[count - 1] == 0xFF { count -= 1 }
        let total = prefixOffset + count
        return MQTerminationTail(totalCount: total, baseCount: total)
    }
}

/// Raw (bypass) bit reader: MSB first, seven bits after a 0xFF byte, 0xFF fed
/// past the end of the segment (D.6).
package struct RawDecoder: Sendable {
    private let bytes: [UInt8]
    private var position: Int
    private let end: Int
    private var current: UInt32 = 0
    private var bitsLeft = 0

    package init(bytes: [UInt8]) { self.bytes = bytes; position = 0; end = bytes.count }

    @inline(__always)
    package mutating func decode() -> Bool {
        if bitsLeft == 0 {
            let previous = current
            if position < end {
                let next = UInt32(bytes[position])
                if previous == 0xFF && next > 0x8F {
                    current = 0xFF; bitsLeft = 8       // a marker: do not consume it
                } else {
                    current = next; position += 1
                    bitsLeft = previous == 0xFF ? 7 : 8
                }
            } else {
                current = 0xFF; bitsLeft = 8
            }
        }
        bitsLeft -= 1
        return (current >> UInt32(bitsLeft)) & 1 == 1
    }
}

package typealias EBCOTWorkspace = BitPlaneCoder.EBCOTWorkspace

package enum BitPlaneCoder {
    package static let maximumCoefficients = 4096
    package static let maximumMagnitudeBitPlanes = 30
    package static let maximumExtendedBitPlanes = 62

    /// Reusable per-worker scratch buffers for zero-allocation EBCOT Tier-1 block coding.
    package final class EBCOTWorkspace {
        package var flags: [UInt8]
        package var contexts: [MQContext]
        package var magnitudes32: [UInt32]
        package var magnitudes64: [UInt64]
        package var negFlags: [UInt8]
        package var reconstructed: [UInt64]
        package var lastPlane: [Int]

        package init() {
            self.flags = [UInt8](repeating: 0, count: 66 * 66)
            self.contexts = [MQContext](repeating: MQContext(), count: ContextLabel.count)
            self.magnitudes32 = [UInt32](repeating: 0, count: maximumCoefficients)
            self.magnitudes64 = [UInt64](repeating: 0, count: maximumCoefficients)
            self.negFlags = [UInt8](repeating: 0, count: maximumCoefficients)
            self.reconstructed = [UInt64](repeating: 0, count: maximumCoefficients)
            self.lastPlane = [Int](repeating: -1, count: maximumCoefficients)
        }

        @inline(__always)
        func prepareFlags(width: Int, height: Int) {
            let needed = (width + 2) * (height + 2)
            if flags.count < needed {
                flags = [UInt8](repeating: 0, count: needed)
            } else {
                flags.withUnsafeMutableBufferPointer { buf in
                    guard let base = buf.baseAddress else { return }
                    base.update(repeating: 0, count: needed)
                }
            }
        }

        @inline(__always)
        func ensureCount32(_ count: Int) {
            if magnitudes32.count < count {
                magnitudes32 = [UInt32](repeating: 0, count: count)
            }
        }

        @inline(__always)
        func ensureCount64(_ count: Int, withDistortion: Bool) {
            if magnitudes64.count < count {
                magnitudes64 = [UInt64](repeating: 0, count: count)
                negFlags = [UInt8](repeating: 0, count: count)
            }
            if withDistortion && reconstructed.count < count {
                reconstructed = [UInt64](repeating: 0, count: count)
                lastPlane = [Int](repeating: -1, count: count)
            }
        }
    }

    // MARK: - Pointer-backed Context Helpers

    @inline(__always)
    private static func resetContextsPtr(_ ctxPtr: UnsafeMutablePointer<MQContext>) {
        for i in 0..<ContextLabel.count {
            ctxPtr[i] = MQContext()
        }
        ctxPtr[0] = MQContext(stateIndex: 4)
        ctxPtr[Int(ContextLabel.runLength)] = MQContext(stateIndex: 3)
        ctxPtr[Int(ContextLabel.uniform)] = MQContext(stateIndex: 46)
    }

    @inline(__always)
    private static func sigKeyPtr(
        at i: Int,
        stride: Int,
        flagsPtr: UnsafePointer<UInt8>,
        ignoreBelow: Bool
    ) -> Int {
        let s = CoefficientFlag.significant
        let h = Int(flagsPtr[i - 1] & s) + Int(flagsPtr[i + 1] & s)
        var v = Int(flagsPtr[i - stride] & s)
        var d = Int(flagsPtr[i - stride - 1] & s) + Int(flagsPtr[i - stride + 1] & s)
        if !ignoreBelow {
            v += Int(flagsPtr[i + stride] & s)
            d += Int(flagsPtr[i + stride - 1] & s) + Int(flagsPtr[i + stride + 1] & s)
        }
        return h * 15 + v * 5 + d
    }

    @inline(__always)
    private static func signEntryPtr(
        at i: Int,
        stride: Int,
        flagsPtr: UnsafePointer<UInt8>,
        signTbl: UnsafePointer<UInt8>,
        ignoreBelow: Bool
    ) -> UInt8 {
        @inline(__always)
        func contribution(_ f: UInt8) -> Int {
            guard (f & CoefficientFlag.significant) != 0 else { return 0 }
            return (f & CoefficientFlag.negative) != 0 ? -1 : 1
        }
        var h = contribution(flagsPtr[i - 1]) + contribution(flagsPtr[i + 1])
        var v = contribution(flagsPtr[i - stride]) + (ignoreBelow ? 0 : contribution(flagsPtr[i + stride]))
        if h < -1 { h = -1 } else if h > 1 { h = 1 }
        if v < -1 { v = -1 } else if v > 1 { v = 1 }
        return signTbl[(h + 1) * 3 + (v + 1)]
    }

    @inline(__always)
    private static func hasSigNbrPtr(
        at i: Int,
        stride: Int,
        flagsPtr: UnsafePointer<UInt8>,
        ignoreBelow: Bool
    ) -> Bool {
        let s = CoefficientFlag.significant
        var u = flagsPtr[i - 1] | flagsPtr[i + 1] | flagsPtr[i - stride] | flagsPtr[i - stride - 1] | flagsPtr[i - stride + 1]
        if !ignoreBelow {
            u |= flagsPtr[i + stride] | flagsPtr[i + stride - 1] | flagsPtr[i + stride + 1]
        }
        return (u & s) != 0
    }

    @inline(__always)
    private static func refLabelPtr(
        flags: UInt8,
        at i: Int,
        stride: Int,
        flagsPtr: UnsafePointer<UInt8>,
        ignoreBelow: Bool
    ) -> Int {
        if (flags & CoefficientFlag.refined) != 0 {
            return Int(ContextLabel.refinementSubsequent)
        }
        return Int(
            hasSigNbrPtr(at: i, stride: stride, flagsPtr: flagsPtr, ignoreBelow: ignoreBelow)
                ? ContextLabel.refinementFirstWithNeighbours
                : ContextLabel.refinementFirstNoNeighbours
        )
    }

    @inline(__always)
    private static func runLengthEligiblePtr(
        x: Int,
        stripe: Int,
        stride: Int,
        flagsPtr: UnsafePointer<UInt8>,
        causal: Bool
    ) -> Bool {
        let baseIdx = (stripe + 1) * stride + x + 1
        let busyMask = CoefficientFlag.significant | CoefficientFlag.visited
        for k in 0..<4 {
            let i = baseIdx + k * stride
            if (flagsPtr[i] & busyMask) != 0 { return false }
            if hasSigNbrPtr(at: i, stride: stride, flagsPtr: flagsPtr, ignoreBelow: causal && k == 3) {
                return false
            }
        }
        return true
    }

    @inline(__always)
    private static func clearVisitedPtr(_ flagsPtr: UnsafeMutablePointer<UInt8>, count: Int) {
        let mask8 = ~CoefficientFlag.visited
        let mask64 = UInt64(mask8) &* 0x0101_0101_0101_0101
        let raw = UnsafeMutableRawPointer(flagsPtr)
        let vecEnd = count & ~7
        var i = 0
        while i < vecEnd {
            let v = raw.loadUnaligned(fromByteOffset: i, as: UInt64.self)
            raw.storeBytes(of: v & mask64, toByteOffset: i, as: UInt64.self)
            i += 8
        }
        while i < count {
            flagsPtr[i] &= mask8
            i += 1
        }
    }

    // MARK: - Encoder (default style, strided & array entry points)

    package static func encode(
        coefficients: [Int32],
        width: Int,
        height: Int,
        orientation: BandOrientation,
        magnitudeBitPlanes mb: Int,
        maximumOutputBytes: Int = Int.max
    ) throws -> CodeBlockEncoding {
        let count = width * height
        guard width > 0, height > 0, count <= maximumCoefficients, coefficients.count == count,
              mb >= 1, mb <= maximumMagnitudeBitPlanes else {
            throw CodecError(.internalFailure, "Code-block geometry or bit-plane count is outside the coder's range.")
        }
        let ws = EBCOTWorkspace()
        return try coefficients.withUnsafeBufferPointer { buf in
            try encodeStrided(
                planeBase: buf.baseAddress!,
                planeStride: width,
                planeX: 0,
                planeY: 0,
                width: width,
                height: height,
                orientation: orientation,
                magnitudeBitPlanes: mb,
                maximumOutputBytes: maximumOutputBytes,
                workspace: ws
            )
        }
    }

    @inline(__always)
    package static func encodeStrided(
        source: UnsafePointer<Int32>,
        sourceStride: Int,
        width: Int,
        height: Int,
        orientation: BandOrientation,
        magnitudeBitPlanes mb: Int,
        maximumOutputBytes: Int = Int.max,
        workspace ws: inout EBCOTWorkspace,
        allocateLayerMetadata: Bool = true
    ) throws -> CodeBlockEncoding {
        try encodeStrided(
            planeBase: source,
            planeStride: sourceStride,
            planeX: 0,
            planeY: 0,
            width: width,
            height: height,
            orientation: orientation,
            magnitudeBitPlanes: mb,
            maximumOutputBytes: maximumOutputBytes,
            workspace: ws,
            allocateLayerMetadata: allocateLayerMetadata
        )
    }

    package static func encodeStrided(
        planeBase: UnsafePointer<Int32>,
        planeStride: Int,
        planeX: Int,
        planeY: Int,
        width: Int,
        height: Int,
        orientation: BandOrientation,
        magnitudeBitPlanes mb: Int,
        maximumOutputBytes: Int = Int.max,
        workspace ws: EBCOTWorkspace,
        allocateLayerMetadata: Bool = true
    ) throws -> CodeBlockEncoding {
        let count = width * height
        guard width > 0, height > 0, count <= maximumCoefficients,
              mb >= 1, mb <= maximumMagnitudeBitPlanes else {
            throw CodecError(.internalFailure, "Code-block geometry or bit-plane count is outside the coder's range.")
        }
        ws.ensureCount32(count)
        var maximum: UInt32 = 0
        ws.magnitudes32.withUnsafeMutableBufferPointer { magBuf in
            let magPtr = magBuf.baseAddress!
            for y in 0..<height {
                let srcRow = planeBase.advanced(by: (planeY + y) * planeStride + planeX)
                let dstRow = magPtr.advanced(by: y * width)
                for x in 0..<width {
                    let value = srcRow[x]
                    let mag = value < 0 ? UInt32(bitPattern: 0 &- value) : UInt32(value)
                    if mag > maximum { maximum = mag }
                    dstRow[x] = mag | (value < 0 ? 0x8000_0000 : 0)
                }
            }
        }
        let bitPlanes = maximum == 0 ? 0 : UInt32.bitWidth - maximum.leadingZeroBitCount
        guard bitPlanes <= mb else {
            throw CodecError(.invalidArgument, "A coefficient exceeds the precision the band can represent.")
        }
        if bitPlanes == 0 {
            return allocateLayerMetadata
                ? CodeBlockEncoding(data: [], passCount: 0, zeroBitPlanes: mb)
                : CodeBlockEncoding(losslessSingleLayer: [], passCount: 0, zeroBitPlanes: mb)
        }
        guard maximumOutputBytes > 0 else {
            throw CodecError(.resourceLimitExceeded, "Encoded code-block exceeds the output byte budget.")
        }

        let tables = ContextTables(orientation: orientation)
        let fStride = width + 2
        let fCount = fStride * (height + 2)
        ws.prepareFlags(width: width, height: height)

        var encoder = MQEncoder(capacityHint: max(16, count / 2), maximumOutputBytes: maximumOutputBytes)
        var passCount = 0

        try ws.flags.withUnsafeMutableBufferPointer { flagsBuf in
            try ws.contexts.withUnsafeMutableBufferPointer { ctxBuf in
                try ws.magnitudes32.withUnsafeBufferPointer { magBuf in
                    try tables.significance.withUnsafeBufferPointer { sigTblBuf in
                        try ContextTables.sign.withUnsafeBufferPointer { signTblBuf in
                            try mqStateTable.withUnsafeBufferPointer { stateTblBuf in
                                let flagsPtr = flagsBuf.baseAddress!
                                let ctxPtr = ctxBuf.baseAddress!
                                let magPtr = magBuf.baseAddress!
                                let sigTbl = sigTblBuf.baseAddress!
                                let signTbl = signTblBuf.baseAddress!
                                let stateTbl = stateTblBuf.baseAddress!
                                resetContextsPtr(ctxPtr)

                                for plane in stride(from: bitPlanes - 1, through: 0, by: -1) {
                                    let mask = UInt32(1) << UInt32(plane)
                                    if plane != bitPlanes - 1 {
                                        encodeSigPass32Ptr(
                                            mask: mask, width: width, height: height, fStride: fStride,
                                            magPtr: magPtr, flagsPtr: flagsPtr, sigTbl: sigTbl, signTbl: signTbl,
                                            ctxPtr: ctxPtr, stateTbl: stateTbl, encoder: &encoder
                                        )
                                        encodeRefPass32Ptr(
                                            mask: mask, width: width, height: height, fStride: fStride,
                                            magPtr: magPtr, flagsPtr: flagsPtr,
                                            ctxPtr: ctxPtr, stateTbl: stateTbl, encoder: &encoder
                                        )
                                        passCount += 2
                                    }
                                    encodeCleanupPass32Ptr(
                                        mask: mask, width: width, height: height, fStride: fStride,
                                        magPtr: magPtr, flagsPtr: flagsPtr, sigTbl: sigTbl, signTbl: signTbl,
                                        ctxPtr: ctxPtr, stateTbl: stateTbl, encoder: &encoder
                                    )
                                    passCount += 1
                                    if encoder.overflowed {
                                        throw CodecError(.resourceLimitExceeded, "Encoded code-block exceeds the output byte budget.")
                                    }
                                    clearVisitedPtr(flagsPtr, count: fCount)
                                }
                            }
                        }
                    }
                }
            }
        }

        let encodedBytes = encoder.finish()
        if encoder.overflowed {
            throw CodecError(.resourceLimitExceeded, "Encoded code-block exceeds the output byte budget.")
        }
        return allocateLayerMetadata
            ? CodeBlockEncoding(data: encodedBytes, passCount: passCount, zeroBitPlanes: mb - bitPlanes)
            : CodeBlockEncoding(losslessSingleLayer: encodedBytes, passCount: passCount, zeroBitPlanes: mb - bitPlanes)
    }

    @inline(__always)
    private static func encodeSign32Ptr(
        negative: Bool,
        at i: Int,
        fStride: Int,
        flagsPtr: UnsafeMutablePointer<UInt8>,
        signTbl: UnsafePointer<UInt8>,
        ctxPtr: UnsafeMutablePointer<MQContext>,
        stateTbl: UnsafePointer<MQState>,
        encoder: inout MQEncoder
    ) {
        let entry = signEntryPtr(at: i, stride: fStride, flagsPtr: flagsPtr, signTbl: signTbl, ignoreBelow: false)
        encoder.encode(negative != ((entry & 1) == 1), context: ctxPtr.advanced(by: Int(entry >> 1)), stateTbl: stateTbl)
        flagsPtr[i] = (flagsPtr[i] & CoefficientFlag.hasSigNeighbor)
            | CoefficientFlag.significant
            | CoefficientFlag.visited
            | (negative ? CoefficientFlag.negative : 0)
        flagsPtr[i - fStride - 1] |= CoefficientFlag.hasSigNeighbor
        flagsPtr[i - fStride] |= CoefficientFlag.hasSigNeighbor
        flagsPtr[i - fStride + 1] |= CoefficientFlag.hasSigNeighbor
        flagsPtr[i - 1] |= CoefficientFlag.hasSigNeighbor
        flagsPtr[i + 1] |= CoefficientFlag.hasSigNeighbor
        flagsPtr[i + fStride - 1] |= CoefficientFlag.hasSigNeighbor
        flagsPtr[i + fStride] |= CoefficientFlag.hasSigNeighbor
        flagsPtr[i + fStride + 1] |= CoefficientFlag.hasSigNeighbor
    }

    @inline(__always)
    private static func encodeSigPass32Ptr(
        mask: UInt32,
        width w: Int,
        height h: Int,
        fStride: Int,
        magPtr: UnsafePointer<UInt32>,
        flagsPtr: UnsafeMutablePointer<UInt8>,
        sigTbl: UnsafePointer<UInt8>,
        signTbl: UnsafePointer<UInt8>,
        ctxPtr: UnsafeMutablePointer<MQContext>,
        stateTbl: UnsafePointer<MQState>,
        encoder: inout MQEncoder
    ) {
        let sigPassGate = CoefficientFlag.hasSigNeighbor | CoefficientFlag.significant | CoefficientFlag.visited
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                for y in stripe..<stripeEnd {
                    let i = (y + 1) * fStride + x + 1
                    let flags = flagsPtr[i]
                    if (flags & sigPassGate) != CoefficientFlag.hasSigNeighbor { continue }
                    let key = sigKeyPtr(at: i, stride: fStride, flagsPtr: flagsPtr, ignoreBelow: false)
                    let m = magPtr[y * w + x]
                    let becomesSignificant = (m & mask) != 0
                    encoder.encode(becomesSignificant, context: ctxPtr.advanced(by: Int(sigTbl[key])), stateTbl: stateTbl)
                    if becomesSignificant {
                        encodeSign32Ptr(
                            negative: m >= 0x8000_0000, at: i, fStride: fStride,
                            flagsPtr: flagsPtr, signTbl: signTbl, ctxPtr: ctxPtr, stateTbl: stateTbl, encoder: &encoder
                        )
                    } else {
                        flagsPtr[i] = flags | CoefficientFlag.visited
                    }
                }
            }
        }
    }

    @inline(__always)
    private static func encodeRefPass32Ptr(
        mask: UInt32,
        width w: Int,
        height h: Int,
        fStride: Int,
        magPtr: UnsafePointer<UInt32>,
        flagsPtr: UnsafeMutablePointer<UInt8>,
        ctxPtr: UnsafeMutablePointer<MQContext>,
        stateTbl: UnsafePointer<MQState>,
        encoder: inout MQEncoder
    ) {
        let busy = CoefficientFlag.significant | CoefficientFlag.visited
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                for y in stripe..<stripeEnd {
                    let i = (y + 1) * fStride + x + 1
                    let flags = flagsPtr[i]
                    guard (flags & busy) == CoefficientFlag.significant else { continue }
                    let label: Int
                    if (flags & CoefficientFlag.refined) != 0 {
                        label = Int(ContextLabel.refinementSubsequent)
                    } else {
                        label = Int((flags & CoefficientFlag.hasSigNeighbor) != 0
                            ? ContextLabel.refinementFirstWithNeighbours
                            : ContextLabel.refinementFirstNoNeighbours)
                    }
                    encoder.encode((magPtr[y * w + x] & mask) != 0, context: ctxPtr.advanced(by: label), stateTbl: stateTbl)
                    flagsPtr[i] = flags | CoefficientFlag.visited | CoefficientFlag.refined
                }
            }
        }
    }

    @inline(__always)
    private static func encodeCleanupPass32Ptr(
        mask: UInt32,
        width w: Int,
        height h: Int,
        fStride: Int,
        magPtr: UnsafePointer<UInt32>,
        flagsPtr: UnsafeMutablePointer<UInt8>,
        sigTbl: UnsafePointer<UInt8>,
        signTbl: UnsafePointer<UInt8>,
        ctxPtr: UnsafeMutablePointer<MQContext>,
        stateTbl: UnsafePointer<MQState>,
        encoder: inout MQEncoder
    ) {
        let busy = CoefficientFlag.significant | CoefficientFlag.visited
        let rlGate = CoefficientFlag.hasSigNeighbor | busy
        let rlCtx = ctxPtr.advanced(by: Int(ContextLabel.runLength))
        let uniCtx = ctxPtr.advanced(by: Int(ContextLabel.uniform))
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                var y = stripe
                if stripeEnd - stripe == 4 {
                    let i0 = (stripe + 1) * fStride + x + 1
                    let colFlags = flagsPtr[i0] | flagsPtr[i0 + fStride] | flagsPtr[i0 + 2 * fStride] | flagsPtr[i0 + 3 * fStride]
                    if (colFlags & rlGate) == 0 {
                        var first = -1
                        for k in 0..<4 where (magPtr[(stripe + k) * w + x] & mask) != 0 {
                            first = k
                            break
                        }
                        encoder.encode(first >= 0, context: rlCtx, stateTbl: stateTbl)
                        if first < 0 { continue }
                        encoder.encode((first & 2) != 0, context: uniCtx, stateTbl: stateTbl)
                        encoder.encode((first & 1) != 0, context: uniCtx, stateTbl: stateTbl)
                        let m = magPtr[(stripe + first) * w + x]
                        encodeSign32Ptr(
                            negative: m >= 0x8000_0000,
                            at: i0 + first * fStride,
                            fStride: fStride,
                            flagsPtr: flagsPtr, signTbl: signTbl, ctxPtr: ctxPtr, stateTbl: stateTbl, encoder: &encoder
                        )
                        y = stripe + first + 1
                    }
                }
                while y < stripeEnd {
                    let i = (y + 1) * fStride + x + 1
                    let flags = flagsPtr[i]
                    if (flags & busy) == 0 {
                        let ctxIdx = (flags & CoefficientFlag.hasSigNeighbor) == 0
                            ? 0
                            : Int(sigTbl[sigKeyPtr(at: i, stride: fStride, flagsPtr: flagsPtr, ignoreBelow: false)])
                        let m = magPtr[y * w + x]
                        let becomesSignificant = (m & mask) != 0
                        encoder.encode(becomesSignificant, context: ctxPtr.advanced(by: ctxIdx), stateTbl: stateTbl)
                        if becomesSignificant {
                            encodeSign32Ptr(
                                negative: m >= 0x8000_0000, at: i, fStride: fStride,
                                flagsPtr: flagsPtr, signTbl: signTbl, ctxPtr: ctxPtr, stateTbl: stateTbl, encoder: &encoder
                            )
                        }
                    }
                    y += 1
                }
            }
        }
    }

    // MARK: - Decoder (all styles, strided & array entry points)

    @inline(__always)
    package static func decodeStrided(
        segments: [CodewordSegment],
        destination: UnsafeMutablePointer<Int32>,
        destinationStride: Int,
        width: Int,
        height: Int,
        orientation: BandOrientation,
        zeroBitPlanes: Int,
        passCount: Int,
        magnitudeBitPlanes mb: Int,
        style: CodeBlockStyle,
        workspace ws: inout EBCOTWorkspace
    ) throws {
        try decodeStrided(
            segments: segments,
            width: width,
            height: height,
            orientation: orientation,
            zeroBitPlanes: zeroBitPlanes,
            passCount: passCount,
            magnitudeBitPlanes: mb,
            style: style,
            planeOut: destination,
            planeStride: destinationStride,
            planeX: 0,
            planeY: 0,
            workspace: ws
        )
    }

    /// Fast strided 32-bit EBCOT decoder writing directly into `planeOut`.
    package static func decodeStrided(
        segments: [CodewordSegment],
        width: Int,
        height: Int,
        orientation: BandOrientation,
        zeroBitPlanes: Int,
        passCount: Int,
        magnitudeBitPlanes mb: Int,
        style: CodeBlockStyle,
        planeOut: UnsafeMutablePointer<Int32>,
        planeStride: Int,
        planeX: Int,
        planeY: Int,
        workspace ws: EBCOTWorkspace
    ) throws {
        let count = width * height
        guard width > 0, height > 0, count <= maximumCoefficients, mb >= 1, mb <= maximumMagnitudeBitPlanes else {
            throw CodecError(.internalFailure, "Code-block geometry or bit-plane count is outside the coder's range.")
        }
        if passCount == 0 {
            for y in 0..<height {
                planeOut.advanced(by: (planeY + y) * planeStride + planeX).update(repeating: 0, count: width)
            }
            return
        }
        let bitPlanes = mb - zeroBitPlanes
        guard zeroBitPlanes >= 0, bitPlanes >= 1, passCount <= 3 * bitPlanes - 2 else {
            throw CodecError(.malformedInput, "Code-block signals more coding passes or missing bit-planes than its band allows.")
        }

        // Fast single-segment MQ pointer path (covers standard lossless & lossy Part-1 blocks).
        if segments.count == 1 && !style.bypass && !style.terminateAll {
            guard segments[0].passes == passCount else {
                throw CodecError(.malformedInput, "Codeword segments do not account for every coding pass.")
            }
            ws.ensureCount32(count)
            ws.magnitudes32.withUnsafeMutableBufferPointer { buf in
                buf.baseAddress?.update(repeating: 0, count: count)
            }
            let fStride = width + 2
            let fCount = fStride * (height + 2)
            ws.prepareFlags(width: width, height: height)
            let tables = ContextTables(orientation: orientation)

            try segments[0].data.withUnsafeBufferPointer { segBuf in
                try ws.flags.withUnsafeMutableBufferPointer { flagsBuf in
                    try ws.contexts.withUnsafeMutableBufferPointer { ctxBuf in
                        try ws.magnitudes32.withUnsafeMutableBufferPointer { magBuf in
                            try tables.significance.withUnsafeBufferPointer { sigTblBuf in
                                try ContextTables.sign.withUnsafeBufferPointer { signTblBuf in
                                    try mqStateTable.withUnsafeBufferPointer { stateTblBuf in
                                        let flagsPtr = flagsBuf.baseAddress!
                                        let ctxPtr = ctxBuf.baseAddress!
                                        let magPtr = magBuf.baseAddress!
                                        let sigTbl = sigTblBuf.baseAddress!
                                        let signTbl = signTblBuf.baseAddress!
                                        let stateTbl = stateTblBuf.baseAddress!
                                        resetContextsPtr(ctxPtr)
                                        var mq = MQPtrDecoder(base: segBuf.baseAddress, count: segBuf.count, stateTbl: stateTbl)
                                        var passIndex = 0
                                        let causal = style.causal
                                        let reset = style.reset
                                        let segSym = style.segmentationSymbols

                                        planes: for plane in stride(from: bitPlanes - 1, through: 0, by: -1) {
                                            let mask = UInt32(1) << UInt32(plane)
                                            if plane != bitPlanes - 1 {
                                                if passIndex == passCount { break planes }
                                                decodeSigPass32Ptr(
                                                    mask: mask, width: width, height: height, fStride: fStride,
                                                    magPtr: magPtr, flagsPtr: flagsPtr, sigTbl: sigTbl, signTbl: signTbl,
                                                    ctxPtr: ctxPtr, decoder: &mq, causal: causal
                                                )
                                                passIndex += 1
                                                if reset { resetContextsPtr(ctxPtr) }

                                                if passIndex == passCount { break planes }
                                                decodeRefPass32Ptr(
                                                    mask: mask, width: width, height: height, fStride: fStride,
                                                    magPtr: magPtr, flagsPtr: flagsPtr,
                                                    ctxPtr: ctxPtr, decoder: &mq, causal: causal
                                                )
                                                passIndex += 1
                                                if reset { resetContextsPtr(ctxPtr) }
                                            }
                                            if passIndex == passCount { break planes }
                                            decodeCleanupPass32Ptr(
                                                mask: mask, width: width, height: height, fStride: fStride,
                                                magPtr: magPtr, flagsPtr: flagsPtr, sigTbl: sigTbl, signTbl: signTbl,
                                                ctxPtr: ctxPtr, decoder: &mq, causal: causal
                                            )
                                            if segSym {
                                                let uniCtx = ctxPtr.advanced(by: Int(ContextLabel.uniform))
                                                var symbol = 0
                                                for _ in 0..<4 {
                                                    symbol = (symbol << 1) | (mq.decode(context: uniCtx) ? 1 : 0)
                                                }
                                                guard symbol == 0b1010 else {
                                                    throw CodecError(.malformedInput, "Segmentation symbol mismatch after a cleanup pass.")
                                                }
                                            }
                                            passIndex += 1
                                            if reset { resetContextsPtr(ctxPtr) }
                                            clearVisitedPtr(flagsPtr, count: fCount)
                                        }

                                        for y in 0..<height {
                                            let dstRow = planeOut.advanced(by: (planeY + y) * planeStride + planeX)
                                            let srcRow = magPtr.advanced(by: y * width)
                                            let flagRow = flagsPtr.advanced(by: (y + 1) * fStride + 1)
                                            for x in 0..<width {
                                                let mag = Int32(srcRow[x])
                                                dstRow[x] = (flagRow[x] & CoefficientFlag.negative) != 0 ? -mag : mag
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return
        }

        let coeffs = try decode(
            segments: segments,
            width: width,
            height: height,
            orientation: orientation,
            zeroBitPlanes: zeroBitPlanes,
            passCount: passCount,
            magnitudeBitPlanes: mb,
            style: style
        )
        coeffs.withUnsafeBufferPointer { srcBuf in
            let srcBase = srcBuf.baseAddress!
            for y in 0..<height {
                planeOut.advanced(by: (planeY + y) * planeStride + planeX)
                    .update(from: srcBase.advanced(by: y * width), count: width)
            }
        }
    }

    @inline(__always)
    private static func decodeSign32Ptr(
        at i: Int,
        fStride: Int,
        ignoreBelow: Bool,
        causal: Bool,
        flagsPtr: UnsafeMutablePointer<UInt8>,
        signTbl: UnsafePointer<UInt8>,
        ctxPtr: UnsafeMutablePointer<MQContext>,
        decoder: inout MQPtrDecoder
    ) {
        let entry = signEntryPtr(at: i, stride: fStride, flagsPtr: flagsPtr, signTbl: signTbl, ignoreBelow: ignoreBelow)
        let negative = decoder.decode(context: ctxPtr.advanced(by: Int(entry >> 1))) != ((entry & 1) == 1)
        flagsPtr[i] = (flagsPtr[i] & CoefficientFlag.hasSigNeighbor)
            | CoefficientFlag.significant
            | CoefficientFlag.visited
            | (negative ? CoefficientFlag.negative : 0)
        if !causal {
            flagsPtr[i - fStride - 1] |= CoefficientFlag.hasSigNeighbor
            flagsPtr[i - fStride] |= CoefficientFlag.hasSigNeighbor
            flagsPtr[i - fStride + 1] |= CoefficientFlag.hasSigNeighbor
            flagsPtr[i - 1] |= CoefficientFlag.hasSigNeighbor
            flagsPtr[i + 1] |= CoefficientFlag.hasSigNeighbor
            flagsPtr[i + fStride - 1] |= CoefficientFlag.hasSigNeighbor
            flagsPtr[i + fStride] |= CoefficientFlag.hasSigNeighbor
            flagsPtr[i + fStride + 1] |= CoefficientFlag.hasSigNeighbor
        }
    }

    @inline(__always)
    private static func decodeSigPass32Ptr(
        mask: UInt32,
        width w: Int,
        height h: Int,
        fStride: Int,
        magPtr: UnsafeMutablePointer<UInt32>,
        flagsPtr: UnsafeMutablePointer<UInt8>,
        sigTbl: UnsafePointer<UInt8>,
        signTbl: UnsafePointer<UInt8>,
        ctxPtr: UnsafeMutablePointer<MQContext>,
        decoder: inout MQPtrDecoder,
        causal: Bool
    ) {
        if !causal {
            let sigPassGate = CoefficientFlag.hasSigNeighbor | CoefficientFlag.significant | CoefficientFlag.visited
            for stripe in stride(from: 0, to: h, by: 4) {
                let stripeEnd = min(stripe + 4, h)
                for x in 0..<w {
                    for y in stripe..<stripeEnd {
                        let i = (y + 1) * fStride + x + 1
                        let flags = flagsPtr[i]
                        if (flags & sigPassGate) != CoefficientFlag.hasSigNeighbor { continue }
                        let key = sigKeyPtr(at: i, stride: fStride, flagsPtr: flagsPtr, ignoreBelow: false)
                        if decoder.decode(context: ctxPtr.advanced(by: Int(sigTbl[key]))) {
                            magPtr[y * w + x] |= mask
                            decodeSign32Ptr(
                                at: i, fStride: fStride, ignoreBelow: false, causal: false,
                                flagsPtr: flagsPtr, signTbl: signTbl, ctxPtr: ctxPtr, decoder: &decoder
                            )
                        } else {
                            flagsPtr[i] = flags | CoefficientFlag.visited
                        }
                    }
                }
            }
            return
        }
        let busy = CoefficientFlag.significant | CoefficientFlag.visited
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                for y in stripe..<stripeEnd {
                    let i = (y + 1) * fStride + x + 1
                    let flags = flagsPtr[i]
                    if (flags & busy) != 0 { continue }
                    let ignoreBelow = y == stripeEnd - 1
                    let key = sigKeyPtr(at: i, stride: fStride, flagsPtr: flagsPtr, ignoreBelow: ignoreBelow)
                    if key == 0 { continue }
                    if decoder.decode(context: ctxPtr.advanced(by: Int(sigTbl[key]))) {
                        magPtr[y * w + x] |= mask
                        decodeSign32Ptr(
                            at: i, fStride: fStride, ignoreBelow: ignoreBelow, causal: true,
                            flagsPtr: flagsPtr, signTbl: signTbl, ctxPtr: ctxPtr, decoder: &decoder
                        )
                    } else {
                        flagsPtr[i] = flags | CoefficientFlag.visited
                    }
                }
            }
        }
    }

    @inline(__always)
    private static func decodeRefPass32Ptr(
        mask: UInt32,
        width w: Int,
        height h: Int,
        fStride: Int,
        magPtr: UnsafeMutablePointer<UInt32>,
        flagsPtr: UnsafeMutablePointer<UInt8>,
        ctxPtr: UnsafeMutablePointer<MQContext>,
        decoder: inout MQPtrDecoder,
        causal: Bool
    ) {
        let busy = CoefficientFlag.significant | CoefficientFlag.visited
        if !causal {
            for stripe in stride(from: 0, to: h, by: 4) {
                let stripeEnd = min(stripe + 4, h)
                for x in 0..<w {
                    for y in stripe..<stripeEnd {
                        let i = (y + 1) * fStride + x + 1
                        let flags = flagsPtr[i]
                        guard (flags & busy) == CoefficientFlag.significant else { continue }
                        let label: Int
                        if (flags & CoefficientFlag.refined) != 0 {
                            label = Int(ContextLabel.refinementSubsequent)
                        } else {
                            label = Int((flags & CoefficientFlag.hasSigNeighbor) != 0
                                ? ContextLabel.refinementFirstWithNeighbours
                                : ContextLabel.refinementFirstNoNeighbours)
                        }
                        if decoder.decode(context: ctxPtr.advanced(by: label)) {
                            magPtr[y * w + x] |= mask
                        }
                        flagsPtr[i] = flags | CoefficientFlag.visited | CoefficientFlag.refined
                    }
                }
            }
            return
        }
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                for y in stripe..<stripeEnd {
                    let i = (y + 1) * fStride + x + 1
                    let flags = flagsPtr[i]
                    guard (flags & busy) == CoefficientFlag.significant else { continue }
                    let label = refLabelPtr(
                        flags: flags, at: i, stride: fStride, flagsPtr: flagsPtr,
                        ignoreBelow: y == stripeEnd - 1
                    )
                    if decoder.decode(context: ctxPtr.advanced(by: label)) {
                        magPtr[y * w + x] |= mask
                    }
                    flagsPtr[i] = flags | CoefficientFlag.visited | CoefficientFlag.refined
                }
            }
        }
    }

    @inline(__always)
    private static func decodeCleanupPass32Ptr(
        mask: UInt32,
        width w: Int,
        height h: Int,
        fStride: Int,
        magPtr: UnsafeMutablePointer<UInt32>,
        flagsPtr: UnsafeMutablePointer<UInt8>,
        sigTbl: UnsafePointer<UInt8>,
        signTbl: UnsafePointer<UInt8>,
        ctxPtr: UnsafeMutablePointer<MQContext>,
        decoder: inout MQPtrDecoder,
        causal: Bool
    ) {
        let busy = CoefficientFlag.significant | CoefficientFlag.visited
        let rlCtx = ctxPtr.advanced(by: Int(ContextLabel.runLength))
        let uniCtx = ctxPtr.advanced(by: Int(ContextLabel.uniform))
        if !causal {
            let rlGate = CoefficientFlag.hasSigNeighbor | busy
            for stripe in stride(from: 0, to: h, by: 4) {
                let stripeEnd = min(stripe + 4, h)
                for x in 0..<w {
                    var y = stripe
                    if stripeEnd - stripe == 4 {
                        let i0 = (stripe + 1) * fStride + x + 1
                        let colFlags = flagsPtr[i0] | flagsPtr[i0 + fStride] | flagsPtr[i0 + 2 * fStride] | flagsPtr[i0 + 3 * fStride]
                        if (colFlags & rlGate) == 0 {
                            guard decoder.decode(context: rlCtx) else { continue }
                            let high = decoder.decode(context: uniCtx) ? 2 : 0
                            let low = decoder.decode(context: uniCtx) ? 1 : 0
                            let first = high + low
                            magPtr[(stripe + first) * w + x] |= mask
                            decodeSign32Ptr(
                                at: i0 + first * fStride,
                                fStride: fStride,
                                ignoreBelow: false,
                                causal: false,
                                flagsPtr: flagsPtr, signTbl: signTbl, ctxPtr: ctxPtr, decoder: &decoder
                            )
                            y = stripe + first + 1
                        }
                    }
                    while y < stripeEnd {
                        let i = (y + 1) * fStride + x + 1
                        let flags = flagsPtr[i]
                        if (flags & busy) == 0 {
                            let ctxIdx = (flags & CoefficientFlag.hasSigNeighbor) == 0
                                ? 0
                                : Int(sigTbl[sigKeyPtr(at: i, stride: fStride, flagsPtr: flagsPtr, ignoreBelow: false)])
                            if decoder.decode(context: ctxPtr.advanced(by: ctxIdx)) {
                                magPtr[y * w + x] |= mask
                                decodeSign32Ptr(
                                    at: i, fStride: fStride, ignoreBelow: false, causal: false,
                                    flagsPtr: flagsPtr, signTbl: signTbl, ctxPtr: ctxPtr, decoder: &decoder
                                )
                            }
                        }
                        y += 1
                    }
                }
            }
            return
        }
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                var y = stripe
                if stripeEnd - stripe == 4,
                   runLengthEligiblePtr(x: x, stripe: stripe, stride: fStride, flagsPtr: flagsPtr, causal: true) {
                    guard decoder.decode(context: rlCtx) else { continue }
                    let high = decoder.decode(context: uniCtx) ? 2 : 0
                    let low = decoder.decode(context: uniCtx) ? 1 : 0
                    let first = high + low
                    magPtr[(stripe + first) * w + x] |= mask
                    decodeSign32Ptr(
                        at: (stripe + first + 1) * fStride + x + 1,
                        fStride: fStride,
                        ignoreBelow: first == 3,
                        causal: true,
                        flagsPtr: flagsPtr, signTbl: signTbl, ctxPtr: ctxPtr, decoder: &decoder
                    )
                    y = stripe + first + 1
                }
                while y < stripeEnd {
                    let i = (y + 1) * fStride + x + 1
                    if (flagsPtr[i] & busy) == 0 {
                        let ignoreBelow = y == stripeEnd - 1
                        let key = sigKeyPtr(at: i, stride: fStride, flagsPtr: flagsPtr, ignoreBelow: ignoreBelow)
                        if decoder.decode(context: ctxPtr.advanced(by: Int(sigTbl[key]))) {
                            magPtr[y * w + x] |= mask
                            decodeSign32Ptr(
                                at: i, fStride: fStride, ignoreBelow: ignoreBelow, causal: true,
                                flagsPtr: flagsPtr, signTbl: signTbl, ctxPtr: ctxPtr, decoder: &decoder
                            )
                        }
                    }
                    y += 1
                }
            }
        }
    }

    /// Decodes one code-block from its codeword segments into sign-magnitude
    /// integer coefficients. `passCount` passes are consumed in total.
    package static func decode(
        segments: [CodewordSegment],
        width: Int,
        height: Int,
        orientation: BandOrientation,
        zeroBitPlanes: Int,
        passCount: Int,
        magnitudeBitPlanes mb: Int,
        style: CodeBlockStyle
    ) throws -> [Int32] {
        let count = width * height
        guard width > 0, height > 0, count <= maximumCoefficients, mb >= 1, mb <= maximumMagnitudeBitPlanes else {
            throw CodecError(.internalFailure, "Code-block geometry or bit-plane count is outside the coder's range.")
        }
        if passCount == 0 { return [Int32](repeating: 0, count: count) }
        let bitPlanes = mb - zeroBitPlanes
        guard zeroBitPlanes >= 0, bitPlanes >= 1, passCount <= 3 * bitPlanes - 2 else {
            throw CodecError(.malformedInput, "Code-block signals more coding passes or missing bit-planes than its band allows.")
        }
        guard segments.reduce(0, { $0 + $1.passes }) == passCount else {
            throw CodecError(.malformedInput, "Codeword segments do not account for every coding pass.")
        }

        if segments.count == 1 && !style.bypass && !style.terminateAll {
            var out = [Int32](repeating: 0, count: count)
            let ws = EBCOTWorkspace()
            try out.withUnsafeMutableBufferPointer { outBuf in
                try decodeStrided(
                    segments: segments,
                    width: width,
                    height: height,
                    orientation: orientation,
                    zeroBitPlanes: zeroBitPlanes,
                    passCount: passCount,
                    magnitudeBitPlanes: mb,
                    style: style,
                    planeOut: outBuf.baseAddress!,
                    planeStride: width,
                    planeX: 0,
                    planeY: 0,
                    workspace: ws
                )
            }
            return out
        }

        let tables = ContextTables(orientation: orientation)
        var states = StatePlane(width: width, height: height)
        var contexts = ContextSet()
        var magnitudes = [UInt32](repeating: 0, count: count)
        var mqDecoder = try MQDecoder(bytes: [], start: 0, end: 0)
        var rawDecoder = RawDecoder(bytes: [])
        var activeIsRaw = false
        var segmentIndex = 0
        var passIndex = 0

        func beginPassIfNeeded() throws {
            guard passIndex == 0 || style.passTerminates(passIndex - 1) else { return }
            guard segmentIndex < segments.count else {
                throw CodecError(.malformedInput, "A coding pass has no codeword segment.")
            }
            let segment = segments[segmentIndex]
            segmentIndex += 1
            if style.passIsRaw(passIndex) {
                rawDecoder = RawDecoder(bytes: segment.data)
                activeIsRaw = true
            } else {
                mqDecoder = try MQDecoder(bytes: segment.data, start: 0, end: segment.data.count)
                activeIsRaw = false
            }
        }
        func endPass() {
            passIndex += 1
            if style.reset { contexts = ContextSet() }
        }

        planes: for plane in stride(from: bitPlanes - 1, through: 0, by: -1) {
            let mask = UInt32(1) << UInt32(plane)
            if plane != bitPlanes - 1 {
                if passIndex == passCount { break planes }
                try beginPassIfNeeded()
                if activeIsRaw {
                    decodeSignificancePassRaw(mask: mask, magnitudes: &magnitudes, states: &states,
                                              decoder: &rawDecoder, causal: style.causal)
                } else {
                    decodeSignificancePassMQ(mask: mask, magnitudes: &magnitudes, states: &states, tables: tables,
                                             contexts: &contexts, decoder: &mqDecoder, causal: style.causal)
                }
                endPass()
                if passIndex == passCount { break planes }
                try beginPassIfNeeded()
                if activeIsRaw {
                    decodeRefinementPassRaw(mask: mask, magnitudes: &magnitudes, states: &states, decoder: &rawDecoder)
                } else {
                    decodeRefinementPassMQ(mask: mask, magnitudes: &magnitudes, states: &states,
                                           contexts: &contexts, decoder: &mqDecoder, causal: style.causal)
                }
                endPass()
            }
            if passIndex == passCount { break planes }
            try beginPassIfNeeded()
            guard !activeIsRaw else {
                throw CodecError(.malformedInput, "A cleanup pass fell inside a raw codeword segment.")
            }
            decodeCleanupPass(mask: mask, magnitudes: &magnitudes, states: &states, tables: tables,
                              contexts: &contexts, decoder: &mqDecoder, causal: style.causal)
            if style.segmentationSymbols {
                var symbol = 0
                for _ in 0..<4 { symbol = symbol << 1 | (mqDecoder.decode(context: &contexts.contexts[Int(ContextLabel.uniform)]) ? 1 : 0) }
                guard symbol == 0b1010 else {
                    throw CodecError(.malformedInput, "Segmentation symbol mismatch after a cleanup pass.")
                }
            }
            endPass()
            states.clearVisited()
        }

        var coefficients = [Int32](repeating: 0, count: count)
        for y in 0..<height {
            for x in 0..<width {
                let j = y * width + x
                let magnitude = Int32(magnitudes[j])
                coefficients[j] = states.flags[states.index(x: x, y: y)] & CoefficientFlag.negative != 0 ? -magnitude : magnitude
            }
        }
        return coefficients
    }

    private static func decodeSignificancePassMQ(
        mask: UInt32, magnitudes: inout [UInt32], states: inout StatePlane,
        tables: ContextTables, contexts: inout ContextSet,
        decoder: inout MQDecoder, causal: Bool
    ) {
        let w = states.width, h = states.height
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                for y in stripe..<stripeEnd {
                    let i = states.index(x: x, y: y)
                    let flags = states.flags[i]
                    if flags & (CoefficientFlag.significant | CoefficientFlag.visited) != 0 { continue }
                    let ignoreBelow = causal && y == stripeEnd - 1
                    let key = states.significanceKey(at: i, ignoreBelow: ignoreBelow)
                    if key == 0 { continue }
                    if decoder.decode(context: &contexts.contexts[Int(tables.significance[key])]) {
                        magnitudes[y * w + x] |= mask
                        decodeSign(at: i, ignoreBelow: ignoreBelow, states: &states, contexts: &contexts, decoder: &decoder)
                    } else {
                        states.flags[i] = flags | CoefficientFlag.visited
                    }
                }
            }
        }
    }

    private static func decodeSignificancePassRaw(
        mask: UInt32, magnitudes: inout [UInt32], states: inout StatePlane,
        decoder: inout RawDecoder, causal: Bool
    ) {
        let w = states.width, h = states.height
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                for y in stripe..<stripeEnd {
                    let i = states.index(x: x, y: y)
                    let flags = states.flags[i]
                    if flags & (CoefficientFlag.significant | CoefficientFlag.visited) != 0 { continue }
                    let ignoreBelow = causal && y == stripeEnd - 1
                    let key = states.significanceKey(at: i, ignoreBelow: ignoreBelow)
                    if key == 0 { continue }
                    if decoder.decode() {
                        magnitudes[y * w + x] |= mask
                        let negative = decoder.decode()
                        states.flags[i] = CoefficientFlag.significant | CoefficientFlag.visited | (negative ? CoefficientFlag.negative : 0)
                    } else {
                        states.flags[i] = flags | CoefficientFlag.visited
                    }
                }
            }
        }
    }

    private static func decodeRefinementPassMQ(
        mask: UInt32, magnitudes: inout [UInt32], states: inout StatePlane,
        contexts: inout ContextSet, decoder: inout MQDecoder, causal: Bool
    ) {
        let w = states.width, h = states.height
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                for y in stripe..<stripeEnd {
                    let i = states.index(x: x, y: y)
                    let flags = states.flags[i]
                    guard flags & (CoefficientFlag.significant | CoefficientFlag.visited) == CoefficientFlag.significant else { continue }
                    let label = refinementLabel(flags: flags, at: i, states: states, ignoreBelow: causal && y == stripeEnd - 1)
                    if decoder.decode(context: &contexts.contexts[Int(label)]) {
                        magnitudes[y * w + x] |= mask
                    }
                    states.flags[i] = flags | CoefficientFlag.visited | CoefficientFlag.refined
                }
            }
        }
    }

    private static func decodeRefinementPassRaw(
        mask: UInt32, magnitudes: inout [UInt32], states: inout StatePlane,
        decoder: inout RawDecoder
    ) {
        let w = states.width, h = states.height
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                for y in stripe..<stripeEnd {
                    let i = states.index(x: x, y: y)
                    let flags = states.flags[i]
                    guard flags & (CoefficientFlag.significant | CoefficientFlag.visited) == CoefficientFlag.significant else { continue }
                    if decoder.decode() {
                        magnitudes[y * w + x] |= mask
                    }
                    states.flags[i] = flags | CoefficientFlag.visited | CoefficientFlag.refined
                }
            }
        }
    }

    private static func decodeCleanupPass(mask: UInt32, magnitudes: inout [UInt32], states: inout StatePlane,
                                          tables: ContextTables, contexts: inout ContextSet,
                                          decoder: inout MQDecoder, causal: Bool) {
        let w = states.width, h = states.height
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                var y = stripe
                if stripeEnd - stripe == 4, runLengthEligible(x: x, stripe: stripe, states: states, causal: causal) {
                    guard decoder.decode(context: &contexts.contexts[Int(ContextLabel.runLength)]) else { continue }
                    let high = decoder.decode(context: &contexts.contexts[Int(ContextLabel.uniform)]) ? 2 : 0
                    let low = decoder.decode(context: &contexts.contexts[Int(ContextLabel.uniform)]) ? 1 : 0
                    let first = high + low
                    magnitudes[(stripe + first) * w + x] |= mask
                    decodeSign(at: states.index(x: x, y: stripe + first), ignoreBelow: causal && first == 3,
                               states: &states, contexts: &contexts, decoder: &decoder)
                    y = stripe + first + 1
                }
                while y < stripeEnd {
                    let i = states.index(x: x, y: y)
                    if states.flags[i] & (CoefficientFlag.significant | CoefficientFlag.visited) == 0 {
                        let ignoreBelow = causal && y == stripeEnd - 1
                        let key = states.significanceKey(at: i, ignoreBelow: ignoreBelow)
                        if decoder.decode(context: &contexts.contexts[Int(tables.significance[key])]) {
                            magnitudes[y * w + x] |= mask
                            decodeSign(at: i, ignoreBelow: ignoreBelow, states: &states, contexts: &contexts, decoder: &decoder)
                        }
                    }
                    y += 1
                }
            }
        }
    }

    @inline(__always)
    private static func decodeSign(at i: Int, ignoreBelow: Bool, states: inout StatePlane,
                                   contexts: inout ContextSet, decoder: inout MQDecoder) {
        let entry = states.signEntry(at: i, ignoreBelow: ignoreBelow)
        let negative = decoder.decode(context: &contexts.contexts[Int(entry >> 1)]) != (entry & 1 == 1)
        states.flags[i] = CoefficientFlag.significant | CoefficientFlag.visited | (negative ? CoefficientFlag.negative : 0)
    }

    // MARK: - Shared rules

    @inline(__always)
    private static func refinementLabel(flags: UInt8, at i: Int, states: borrowing StatePlane, ignoreBelow: Bool) -> UInt8 {
        if flags & CoefficientFlag.refined != 0 { return ContextLabel.refinementSubsequent }
        return states.hasSignificantNeighbour(at: i, ignoreBelow: ignoreBelow)
            ? ContextLabel.refinementFirstWithNeighbours : ContextLabel.refinementFirstNoNeighbours
    }

    /// D.3.4: a full four-row column enters run-length mode when every
    /// coefficient is insignificant, unvisited and has an all-zero context.
    @inline(__always)
    private static func runLengthEligible(x: Int, stripe: Int, states: borrowing StatePlane, causal: Bool) -> Bool {
        for k in 0..<4 {
            let i = states.index(x: x, y: stripe + k)
            if states.flags[i] & (CoefficientFlag.significant | CoefficientFlag.visited) != 0 { return false }
            if states.hasSignificantNeighbour(at: i, ignoreBelow: causal && k == 3) { return false }
        }
        return true
    }

    // MARK: - Extended 64-bit / Multi-Style / Rate-Distortion Encoder & Decoder (Milestone 7)

    /// Encodes one code-block of 64-bit signed integer coefficients with support for:
    /// - extended magnitude bit-planes (`1...62`, e.g. high guard bits or MaxShift ROI);
    /// - all Part 1 `CodeBlockStyle` bits (`bypass`, `reset`, `terminateAll`, `causal`, `segmentationSymbols`);
    /// - optional pass-count truncation (`maxPasses`);
    /// - per-pass termination snapshots (`passTails`) for O(bytes) post-compression truncation;
    /// - incremental L2-weighted squared-error distortion reduction tracking for PCRD-opt.
    package static func encodeRich(
        coefficients: [Int64],
        width: Int,
        height: Int,
        orientation: BandOrientation,
        magnitudeBitPlanes mb: Int,
        style: CodeBlockStyle = .default,
        maxPasses: Int? = nil,
        computeDistortion: Bool = false,
        irreversibleMidpoint: Bool = false,
        synthesisWeight: Double = 1.0,
        stepSize: Double = 1.0,
        maximumOutputBytes: Int = Int.max,
        workspace: EBCOTWorkspace? = nil
    ) throws -> CodeBlockEncoding {
        let count = width * height
        guard width > 0, height > 0, count <= maximumCoefficients, coefficients.count == count,
              mb >= 1, mb <= maximumExtendedBitPlanes else {
            throw CodecError(.internalFailure, "Code-block geometry or bit-plane count is outside the extended coder's range.")
        }
        return try coefficients.withUnsafeBufferPointer { coeffBuf in
            try encodeRichStrided(
                source: coeffBuf.baseAddress!,
                sourceStride: width,
                width: width,
                height: height,
                orientation: orientation,
                magnitudeBitPlanes: mb,
                style: style,
                maxPasses: maxPasses,
                computeDistortion: computeDistortion,
                irreversibleMidpoint: irreversibleMidpoint,
                synthesisWeight: synthesisWeight,
                stepSize: stepSize,
                maximumOutputBytes: maximumOutputBytes,
                workspace: workspace
            )
        }
    }

    package static func encodeRichStrided(
        source: UnsafePointer<Int64>,
        sourceStride: Int,
        width: Int,
        height: Int,
        orientation: BandOrientation,
        magnitudeBitPlanes mb: Int,
        style: CodeBlockStyle = .default,
        maxPasses: Int? = nil,
        computeDistortion: Bool = false,
        irreversibleMidpoint: Bool = false,
        synthesisWeight: Double = 1.0,
        stepSize: Double = 1.0,
        maximumOutputBytes: Int = Int.max,
        workspace: EBCOTWorkspace? = nil
    ) throws -> CodeBlockEncoding {
        let count = width * height
        guard width > 0, height > 0, count <= maximumCoefficients,
              mb >= 1, mb <= maximumExtendedBitPlanes else {
            throw CodecError(.internalFailure, "Code-block geometry or bit-plane count is outside the extended coder's range.")
        }
        let ws = workspace ?? EBCOTWorkspace()
        ws.ensureCount64(count, withDistortion: computeDistortion)

        var maximum: UInt64 = 0
        ws.magnitudes64.withUnsafeMutableBufferPointer { magBuf in
            ws.negFlags.withUnsafeMutableBufferPointer { negBuf in
                let mags = magBuf.baseAddress!
                let negs = negBuf.baseAddress!
                for row in 0..<height {
                    let srcRow = source.advanced(by: row * sourceStride)
                    let dstOff = row * width
                    for col in 0..<width {
                        let value = srcRow[col]
                        let neg: UInt8 = value < 0 ? 1 : 0
                        let mag = value < 0 ? UInt64(bitPattern: 0 &- value) : UInt64(value)
                        if mag > maximum { maximum = mag }
                        mags[dstOff + col] = mag
                        negs[dstOff + col] = neg
                    }
                }
            }
        }
        let bitPlanes = maximum == 0 ? 0 : UInt64.bitWidth - maximum.leadingZeroBitCount
        guard bitPlanes <= mb else {
            throw CodecError(.invalidArgument, "A coefficient exceeds the precision the band can represent.")
        }
        if bitPlanes == 0 || (maxPasses != nil && maxPasses! <= 0) {
            return CodeBlockEncoding(data: [], passCount: 0, zeroBitPlanes: mb)
        }
        guard maximumOutputBytes > 0 else {
            throw CodecError(.resourceLimitExceeded, "Encoded code-block exceeds the output byte budget.")
        }

        let totalAvailablePasses = 3 * bitPlanes - 2
        let targetPasses = min(totalAvailablePasses, maxPasses ?? totalAvailablePasses)

        let tables = ContextTables(orientation: orientation)
        let fStride = width + 2
        let fCount = fStride * (height + 2)
        ws.prepareFlags(width: width, height: height)
        if computeDistortion {
            ws.reconstructed.withUnsafeMutableBufferPointer { $0.baseAddress?.update(repeating: 0, count: count) }
            ws.lastPlane.withUnsafeMutableBufferPointer { $0.baseAddress?.update(repeating: -1, count: count) }
        }

        let wStep = synthesisWeight * stepSize
        let weightSq = wStep * wStep
        var unweightedDistReduction = 0.0

        var committedData: [UInt8] = []
        var mqCoder = MQEncoder(capacityHint: max(16, count / 2), maximumOutputBytes: maximumOutputBytes)
        var rawCoder = RawEncoder(maximumOutputBytes: maximumOutputBytes)
        var activeIsRaw = false
        var hasActiveCoder = false

        var passByteOffsets: [Int] = []
        var passTerminatedBytes: [Int] = []
        var passDistortionReductions: [Double] = []
        var passTails: [MQTerminationTail] = []
        passByteOffsets.reserveCapacity(targetPasses)
        passTerminatedBytes.reserveCapacity(targetPasses)
        passTails.reserveCapacity(targetPasses)
        if computeDistortion { passDistortionReductions.reserveCapacity(targetPasses) }

        var passIndex = 0

        try ws.flags.withUnsafeMutableBufferPointer { flagsBuf in
            try ws.contexts.withUnsafeMutableBufferPointer { ctxBuf in
                try ws.magnitudes64.withUnsafeBufferPointer { magBuf in
                    try ws.negFlags.withUnsafeBufferPointer { negBuf in
                        try ws.reconstructed.withUnsafeMutableBufferPointer { reconBuf in
                            try ws.lastPlane.withUnsafeMutableBufferPointer { lpBuf in
                                try tables.significance.withUnsafeBufferPointer { sigTblBuf in
                                    try ContextTables.sign.withUnsafeBufferPointer { signTblBuf in
                                        try mqStateTable.withUnsafeBufferPointer { stateTblBuf in
                                            let flagsPtr = flagsBuf.baseAddress!
                                            let ctxPtr = ctxBuf.baseAddress!
                                            let magPtr = magBuf.baseAddress!
                                            let negPtr = negBuf.baseAddress!
                                            let reconPtr = reconBuf.baseAddress
                                            let lpPtr = lpBuf.baseAddress
                                            let sigTbl = sigTblBuf.baseAddress!
                                            let signTbl = signTblBuf.baseAddress!
                                            let stateTbl = stateTblBuf.baseAddress!
                                            resetContextsPtr(ctxPtr)

                                            func beginPass() {
                                                if !hasActiveCoder {
                                                    let remBudget = max(1, maximumOutputBytes - committedData.count)
                                                    if style.passIsRaw(passIndex) {
                                                        rawCoder = RawEncoder(maximumOutputBytes: remBudget)
                                                        activeIsRaw = true
                                                    } else {
                                                        mqCoder = MQEncoder(capacityHint: max(16, count / 2), maximumOutputBytes: remBudget)
                                                        activeIsRaw = false
                                                    }
                                                    hasActiveCoder = true
                                                }
                                            }

                                            func finishPass() throws {
                                                let isLastPass = (passIndex + 1 == targetPasses)
                                                let terminates = style.passTerminates(passIndex) || isLastPass
                                                if !activeIsRaw {
                                                    if mqCoder.overflowed {
                                                        throw CodecError(.resourceLimitExceeded, "Encoded code-block exceeds the output byte budget.")
                                                    }
                                                    if terminates {
                                                        let seg = mqCoder.finish()
                                                        if mqCoder.overflowed || committedData.count + seg.count > maximumOutputBytes {
                                                            throw CodecError(.resourceLimitExceeded, "Encoded code-block exceeds the output byte budget.")
                                                        }
                                                        committedData.append(contentsOf: seg)
                                                        let total = committedData.count
                                                        passByteOffsets.append(total)
                                                        passTerminatedBytes.append(total)
                                                        passTails.append(MQTerminationTail(totalCount: total, baseCount: total))
                                                        hasActiveCoder = false
                                                    } else {
                                                        let snap = mqCoder.terminatedSnapshot(prefixOffset: committedData.count)
                                                        passByteOffsets.append(committedData.count + mqCoder.emittedByteCount)
                                                        passTerminatedBytes.append(snap.totalCount)
                                                        passTails.append(snap)
                                                    }
                                                } else {
                                                    if rawCoder.overflowed {
                                                        throw CodecError(.resourceLimitExceeded, "Encoded code-block exceeds the output byte budget.")
                                                    }
                                                    if terminates {
                                                        let seg = rawCoder.finish()
                                                        if rawCoder.overflowed || committedData.count + seg.count > maximumOutputBytes {
                                                            throw CodecError(.resourceLimitExceeded, "Encoded code-block exceeds the output byte budget.")
                                                        }
                                                        committedData.append(contentsOf: seg)
                                                        let total = committedData.count
                                                        passByteOffsets.append(total)
                                                        passTerminatedBytes.append(total)
                                                        passTails.append(MQTerminationTail(totalCount: total, baseCount: total))
                                                        hasActiveCoder = false
                                                    } else {
                                                        let snap = rawCoder.terminatedSnapshot(prefixOffset: committedData.count)
                                                        let cur = committedData.count + rawCoder.emittedByteCount
                                                        passByteOffsets.append(cur)
                                                        passTerminatedBytes.append(snap.totalCount)
                                                        passTails.append(snap)
                                                    }
                                                }
                                                if style.reset {
                                                    resetContextsPtr(ctxPtr)
                                                }
                                                if computeDistortion {
                                                    passDistortionReductions.append(max(0.0, unweightedDistReduction * weightSq))
                                                }
                                                passIndex += 1
                                            }

                                            planes: for plane in stride(from: bitPlanes - 1, through: 0, by: -1) {
                                                let mask = UInt64(1) << UInt64(plane)
                                                let newMid: Double = plane > 0
                                                    ? Double(UInt64(1) << UInt64(plane - 1))
                                                    : (irreversibleMidpoint ? 0.5 : 0.0)

                                                if plane != bitPlanes - 1 {
                                                    if passIndex == targetPasses { break planes }
                                                    beginPass()
                                                    if activeIsRaw {
                                                        encodeSigPass64RawPtr(
                                                            mask: mask, plane: plane, newMid: newMid,
                                                            width: width, height: height, fStride: fStride,
                                                            magPtr: magPtr, negPtr: negPtr, flagsPtr: flagsPtr,
                                                            encoder: &rawCoder, causal: style.causal,
                                                            computeDistortion: computeDistortion,
                                                            reconPtr: reconPtr, lpPtr: lpPtr,
                                                            unweightedDistReduction: &unweightedDistReduction
                                                        )
                                                    } else {
                                                        encodeSigPass64MQPtr(
                                                            mask: mask, plane: plane, newMid: newMid,
                                                            width: width, height: height, fStride: fStride,
                                                            magPtr: magPtr, negPtr: negPtr, flagsPtr: flagsPtr,
                                                            sigTbl: sigTbl, signTbl: signTbl, ctxPtr: ctxPtr, stateTbl: stateTbl,
                                                            encoder: &mqCoder, causal: style.causal,
                                                            computeDistortion: computeDistortion,
                                                            reconPtr: reconPtr, lpPtr: lpPtr,
                                                            unweightedDistReduction: &unweightedDistReduction
                                                        )
                                                    }
                                                    try finishPass()

                                                    if passIndex == targetPasses { break planes }
                                                    beginPass()
                                                    if activeIsRaw {
                                                        encodeRefPass64RawPtr(
                                                            mask: mask, plane: plane, newMid: newMid, irreversibleMidpoint: irreversibleMidpoint,
                                                            width: width, height: height, fStride: fStride,
                                                            magPtr: magPtr, flagsPtr: flagsPtr,
                                                            encoder: &rawCoder,
                                                            computeDistortion: computeDistortion,
                                                            reconPtr: reconPtr, lpPtr: lpPtr,
                                                            unweightedDistReduction: &unweightedDistReduction
                                                        )
                                                    } else {
                                                        encodeRefPass64MQPtr(
                                                            mask: mask, plane: plane, newMid: newMid, irreversibleMidpoint: irreversibleMidpoint,
                                                            width: width, height: height, fStride: fStride,
                                                            magPtr: magPtr, flagsPtr: flagsPtr,
                                                            ctxPtr: ctxPtr, stateTbl: stateTbl,
                                                            encoder: &mqCoder, causal: style.causal,
                                                            computeDistortion: computeDistortion,
                                                            reconPtr: reconPtr, lpPtr: lpPtr,
                                                            unweightedDistReduction: &unweightedDistReduction
                                                        )
                                                    }
                                                    try finishPass()
                                                }
                                                if passIndex == targetPasses { break planes }
                                                beginPass()
                                                guard !activeIsRaw else {
                                                    throw CodecError(.internalFailure, "Cleanup pass requires MQ coder.")
                                                }
                                                encodeCleanupPass64MQPtr(
                                                    mask: mask, plane: plane, newMid: newMid,
                                                    width: width, height: height, fStride: fStride,
                                                    magPtr: magPtr, negPtr: negPtr, flagsPtr: flagsPtr,
                                                    sigTbl: sigTbl, signTbl: signTbl, ctxPtr: ctxPtr, stateTbl: stateTbl,
                                                    encoder: &mqCoder, causal: style.causal,
                                                    segmentationSymbols: style.segmentationSymbols,
                                                    computeDistortion: computeDistortion,
                                                    reconPtr: reconPtr, lpPtr: lpPtr,
                                                    unweightedDistReduction: &unweightedDistReduction
                                                )
                                                try finishPass()
                                                clearVisitedPtr(flagsPtr, count: fCount)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        for i in 0..<passByteOffsets.count {
            if passByteOffsets[i] > committedData.count {
                passByteOffsets[i] = committedData.count
            }
            if i > 0 && passByteOffsets[i] < passByteOffsets[i - 1] {
                passByteOffsets[i] = passByteOffsets[i - 1]
            }
        }
        if !passByteOffsets.isEmpty {
            passByteOffsets[passByteOffsets.count - 1] = committedData.count
        }

        return CodeBlockEncoding(
            data: committedData,
            passCount: passIndex,
            zeroBitPlanes: mb - bitPlanes,
            passByteOffsets: passByteOffsets,
            passTerminatedBytes: passTerminatedBytes,
            passDistortionReductions: passDistortionReductions,
            passTails: passTails
        )
    }

    @inline(__always)
    private static func activateDistortion64(
        flatIdx: Int,
        mask: UInt64,
        plane: Int,
        newMid: Double,
        magPtr: UnsafePointer<UInt64>,
        reconPtr: UnsafeMutablePointer<UInt64>?,
        lpPtr: UnsafeMutablePointer<Int>?,
        unweightedDistReduction: inout Double
    ) {
        guard let reconPtr, let lpPtr else { return }
        let trueMag = Double(magPtr[flatIdx])
        let newReconVal = mask
        reconPtr[flatIdx] = newReconVal
        lpPtr[flatIdx] = plane
        let newRecon = Double(newReconVal) + newMid
        let newDiff = trueMag - newRecon
        unweightedDistReduction += (trueMag * trueMag) - (newDiff * newDiff)
    }

    @inline(__always)
    private static func refineDistortion64(
        flatIdx: Int,
        bit: Bool,
        mask: UInt64,
        plane: Int,
        newMid: Double,
        irreversibleMidpoint: Bool,
        magPtr: UnsafePointer<UInt64>,
        reconPtr: UnsafeMutablePointer<UInt64>?,
        lpPtr: UnsafeMutablePointer<Int>?,
        unweightedDistReduction: inout Double
    ) {
        guard let reconPtr, let lpPtr else { return }
        let trueMag = Double(magPtr[flatIdx])
        let oldReconVal = reconPtr[flatIdx]
        let pPrev = lpPtr[flatIdx]
        let oldMid: Double = pPrev > 0
            ? Double(UInt64(1) << UInt64(pPrev - 1))
            : (irreversibleMidpoint ? 0.5 : 0.0)
        let oldDiff = trueMag - (Double(oldReconVal) + oldMid)
        let newReconVal = bit ? (oldReconVal | mask) : oldReconVal
        reconPtr[flatIdx] = newReconVal
        lpPtr[flatIdx] = plane
        let newDiff = trueMag - (Double(newReconVal) + newMid)
        unweightedDistReduction += (oldDiff * oldDiff) - (newDiff * newDiff)
    }

    @inline(__always)
    private static func markSignificant64Ptr(
        at i: Int,
        fStride: Int,
        neg: Bool,
        causal: Bool,
        flagsPtr: UnsafeMutablePointer<UInt8>
    ) {
        flagsPtr[i] = (flagsPtr[i] & CoefficientFlag.hasSigNeighbor)
            | CoefficientFlag.significant
            | CoefficientFlag.visited
            | (neg ? CoefficientFlag.negative : 0)
        if !causal {
            flagsPtr[i - fStride - 1] |= CoefficientFlag.hasSigNeighbor
            flagsPtr[i - fStride] |= CoefficientFlag.hasSigNeighbor
            flagsPtr[i - fStride + 1] |= CoefficientFlag.hasSigNeighbor
            flagsPtr[i - 1] |= CoefficientFlag.hasSigNeighbor
            flagsPtr[i + 1] |= CoefficientFlag.hasSigNeighbor
            flagsPtr[i + fStride - 1] |= CoefficientFlag.hasSigNeighbor
            flagsPtr[i + fStride] |= CoefficientFlag.hasSigNeighbor
            flagsPtr[i + fStride + 1] |= CoefficientFlag.hasSigNeighbor
        }
    }

    private static func encodeSigPass64MQPtr(
        mask: UInt64, plane: Int, newMid: Double,
        width w: Int, height h: Int, fStride: Int,
        magPtr: UnsafePointer<UInt64>, negPtr: UnsafePointer<UInt8>,
        flagsPtr: UnsafeMutablePointer<UInt8>,
        sigTbl: UnsafePointer<UInt8>, signTbl: UnsafePointer<UInt8>,
        ctxPtr: UnsafeMutablePointer<MQContext>, stateTbl: UnsafePointer<MQState>,
        encoder: inout MQEncoder, causal: Bool, computeDistortion: Bool,
        reconPtr: UnsafeMutablePointer<UInt64>?, lpPtr: UnsafeMutablePointer<Int>?,
        unweightedDistReduction: inout Double
    ) {
        let busy = CoefficientFlag.significant | CoefficientFlag.visited
        let sigPassGate = CoefficientFlag.hasSigNeighbor | busy
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                for y in stripe..<stripeEnd {
                    let i = (y + 1) * fStride + x + 1
                    let flags = flagsPtr[i]
                    let ignoreBelow: Bool
                    let key: Int
                    if !causal {
                        if (flags & sigPassGate) != CoefficientFlag.hasSigNeighbor { continue }
                        ignoreBelow = false
                        key = sigKeyPtr(at: i, stride: fStride, flagsPtr: flagsPtr, ignoreBelow: false)
                    } else {
                        if (flags & busy) != 0 { continue }
                        ignoreBelow = y == stripeEnd - 1
                        key = sigKeyPtr(at: i, stride: fStride, flagsPtr: flagsPtr, ignoreBelow: ignoreBelow)
                        if key == 0 { continue }
                    }
                    let flatIdx = y * w + x
                    let becomesSignificant = (magPtr[flatIdx] & mask) != 0
                    encoder.encode(becomesSignificant, context: ctxPtr.advanced(by: Int(sigTbl[key])), stateTbl: stateTbl)
                    if becomesSignificant {
                        let neg = negPtr[flatIdx] != 0
                        let entry = signEntryPtr(at: i, stride: fStride, flagsPtr: flagsPtr, signTbl: signTbl, ignoreBelow: ignoreBelow)
                        encoder.encode(neg != ((entry & 1) == 1), context: ctxPtr.advanced(by: Int(entry >> 1)), stateTbl: stateTbl)
                        markSignificant64Ptr(at: i, fStride: fStride, neg: neg, causal: causal, flagsPtr: flagsPtr)
                        if computeDistortion {
                            activateDistortion64(
                                flatIdx: flatIdx, mask: mask, plane: plane, newMid: newMid,
                                magPtr: magPtr, reconPtr: reconPtr, lpPtr: lpPtr,
                                unweightedDistReduction: &unweightedDistReduction
                            )
                        }
                    } else {
                        flagsPtr[i] = flags | CoefficientFlag.visited
                    }
                }
            }
        }
    }

    private static func encodeSigPass64RawPtr(
        mask: UInt64, plane: Int, newMid: Double,
        width w: Int, height h: Int, fStride: Int,
        magPtr: UnsafePointer<UInt64>, negPtr: UnsafePointer<UInt8>,
        flagsPtr: UnsafeMutablePointer<UInt8>,
        encoder: inout RawEncoder, causal: Bool, computeDistortion: Bool,
        reconPtr: UnsafeMutablePointer<UInt64>?, lpPtr: UnsafeMutablePointer<Int>?,
        unweightedDistReduction: inout Double
    ) {
        let busy = CoefficientFlag.significant | CoefficientFlag.visited
        let sigPassGate = CoefficientFlag.hasSigNeighbor | busy
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                for y in stripe..<stripeEnd {
                    let i = (y + 1) * fStride + x + 1
                    let flags = flagsPtr[i]
                    if !causal {
                        if (flags & sigPassGate) != CoefficientFlag.hasSigNeighbor { continue }
                    } else {
                        if (flags & busy) != 0 { continue }
                        let ignoreBelow = y == stripeEnd - 1
                        let key = sigKeyPtr(at: i, stride: fStride, flagsPtr: flagsPtr, ignoreBelow: ignoreBelow)
                        if key == 0 { continue }
                    }
                    let flatIdx = y * w + x
                    let becomesSignificant = (magPtr[flatIdx] & mask) != 0
                    encoder.encode(becomesSignificant)
                    if becomesSignificant {
                        let neg = negPtr[flatIdx] != 0
                        encoder.encode(neg)
                        markSignificant64Ptr(at: i, fStride: fStride, neg: neg, causal: causal, flagsPtr: flagsPtr)
                        if computeDistortion {
                            activateDistortion64(
                                flatIdx: flatIdx, mask: mask, plane: plane, newMid: newMid,
                                magPtr: magPtr, reconPtr: reconPtr, lpPtr: lpPtr,
                                unweightedDistReduction: &unweightedDistReduction
                            )
                        }
                    } else {
                        flagsPtr[i] = flags | CoefficientFlag.visited
                    }
                }
            }
        }
    }

    private static func encodeRefPass64MQPtr(
        mask: UInt64, plane: Int, newMid: Double, irreversibleMidpoint: Bool,
        width w: Int, height h: Int, fStride: Int,
        magPtr: UnsafePointer<UInt64>, flagsPtr: UnsafeMutablePointer<UInt8>,
        ctxPtr: UnsafeMutablePointer<MQContext>, stateTbl: UnsafePointer<MQState>,
        encoder: inout MQEncoder, causal: Bool, computeDistortion: Bool,
        reconPtr: UnsafeMutablePointer<UInt64>?, lpPtr: UnsafeMutablePointer<Int>?,
        unweightedDistReduction: inout Double
    ) {
        let busy = CoefficientFlag.significant | CoefficientFlag.visited
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                for y in stripe..<stripeEnd {
                    let i = (y + 1) * fStride + x + 1
                    let flags = flagsPtr[i]
                    guard (flags & busy) == CoefficientFlag.significant else { continue }
                    let flatIdx = y * w + x
                    let bit = (magPtr[flatIdx] & mask) != 0
                    let label: Int
                    if !causal {
                        if (flags & CoefficientFlag.refined) != 0 {
                            label = Int(ContextLabel.refinementSubsequent)
                        } else {
                            label = Int((flags & CoefficientFlag.hasSigNeighbor) != 0
                                ? ContextLabel.refinementFirstWithNeighbours
                                : ContextLabel.refinementFirstNoNeighbours)
                        }
                    } else {
                        label = refLabelPtr(flags: flags, at: i, stride: fStride, flagsPtr: flagsPtr, ignoreBelow: y == stripeEnd - 1)
                    }
                    encoder.encode(bit, context: ctxPtr.advanced(by: label), stateTbl: stateTbl)
                    flagsPtr[i] = flags | CoefficientFlag.visited | CoefficientFlag.refined
                    if computeDistortion {
                        refineDistortion64(
                            flatIdx: flatIdx, bit: bit, mask: mask, plane: plane,
                            newMid: newMid, irreversibleMidpoint: irreversibleMidpoint,
                            magPtr: magPtr, reconPtr: reconPtr, lpPtr: lpPtr,
                            unweightedDistReduction: &unweightedDistReduction
                        )
                    }
                }
            }
        }
    }

    private static func encodeRefPass64RawPtr(
        mask: UInt64, plane: Int, newMid: Double, irreversibleMidpoint: Bool,
        width w: Int, height h: Int, fStride: Int,
        magPtr: UnsafePointer<UInt64>, flagsPtr: UnsafeMutablePointer<UInt8>,
        encoder: inout RawEncoder, computeDistortion: Bool,
        reconPtr: UnsafeMutablePointer<UInt64>?, lpPtr: UnsafeMutablePointer<Int>?,
        unweightedDistReduction: inout Double
    ) {
        let busy = CoefficientFlag.significant | CoefficientFlag.visited
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                for y in stripe..<stripeEnd {
                    let i = (y + 1) * fStride + x + 1
                    let flags = flagsPtr[i]
                    guard (flags & busy) == CoefficientFlag.significant else { continue }
                    let flatIdx = y * w + x
                    let bit = (magPtr[flatIdx] & mask) != 0
                    encoder.encode(bit)
                    flagsPtr[i] = flags | CoefficientFlag.visited | CoefficientFlag.refined
                    if computeDistortion {
                        refineDistortion64(
                            flatIdx: flatIdx, bit: bit, mask: mask, plane: plane,
                            newMid: newMid, irreversibleMidpoint: irreversibleMidpoint,
                            magPtr: magPtr, reconPtr: reconPtr, lpPtr: lpPtr,
                            unweightedDistReduction: &unweightedDistReduction
                        )
                    }
                }
            }
        }
    }

    private static func encodeCleanupPass64MQPtr(
        mask: UInt64, plane: Int, newMid: Double,
        width w: Int, height h: Int, fStride: Int,
        magPtr: UnsafePointer<UInt64>, negPtr: UnsafePointer<UInt8>,
        flagsPtr: UnsafeMutablePointer<UInt8>,
        sigTbl: UnsafePointer<UInt8>, signTbl: UnsafePointer<UInt8>,
        ctxPtr: UnsafeMutablePointer<MQContext>, stateTbl: UnsafePointer<MQState>,
        encoder: inout MQEncoder, causal: Bool, segmentationSymbols: Bool,
        computeDistortion: Bool,
        reconPtr: UnsafeMutablePointer<UInt64>?, lpPtr: UnsafeMutablePointer<Int>?,
        unweightedDistReduction: inout Double
    ) {
        let busy = CoefficientFlag.significant | CoefficientFlag.visited
        let rlGate = CoefficientFlag.hasSigNeighbor | busy
        let rlCtx = ctxPtr.advanced(by: Int(ContextLabel.runLength))
        let uniCtx = ctxPtr.advanced(by: Int(ContextLabel.uniform))
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                var y = stripe
                if stripeEnd - stripe == 4 {
                    let i0 = (stripe + 1) * fStride + x + 1
                    let rlOk: Bool
                    if !causal {
                        let colFlags = flagsPtr[i0] | flagsPtr[i0 + fStride] | flagsPtr[i0 + 2 * fStride] | flagsPtr[i0 + 3 * fStride]
                        rlOk = (colFlags & rlGate) == 0
                    } else {
                        rlOk = runLengthEligiblePtr(x: x, stripe: stripe, stride: fStride, flagsPtr: flagsPtr, causal: true)
                    }
                    if rlOk {
                        var first = -1
                        for k in 0..<4 where (magPtr[(stripe + k) * w + x] & mask) != 0 {
                            first = k
                            break
                        }
                        encoder.encode(first >= 0, context: rlCtx, stateTbl: stateTbl)
                        if first < 0 { continue }
                        encoder.encode((first & 2) != 0, context: uniCtx, stateTbl: stateTbl)
                        encoder.encode((first & 1) != 0, context: uniCtx, stateTbl: stateTbl)
                        let firstY = stripe + first
                        let flatIdx = firstY * w + x
                        let i = i0 + first * fStride
                        let neg = negPtr[flatIdx] != 0
                        let entry = signEntryPtr(at: i, stride: fStride, flagsPtr: flagsPtr, signTbl: signTbl, ignoreBelow: causal && first == 3)
                        encoder.encode(neg != ((entry & 1) == 1), context: ctxPtr.advanced(by: Int(entry >> 1)), stateTbl: stateTbl)
                        markSignificant64Ptr(at: i, fStride: fStride, neg: neg, causal: causal, flagsPtr: flagsPtr)
                        if computeDistortion {
                            activateDistortion64(
                                flatIdx: flatIdx, mask: mask, plane: plane, newMid: newMid,
                                magPtr: magPtr, reconPtr: reconPtr, lpPtr: lpPtr,
                                unweightedDistReduction: &unweightedDistReduction
                            )
                        }
                        y = firstY + 1
                    }
                }
                while y < stripeEnd {
                    let i = (y + 1) * fStride + x + 1
                    let flags = flagsPtr[i]
                    if (flags & busy) == 0 {
                        let ignoreBelow: Bool
                        let ctxIdx: Int
                        if !causal {
                            ignoreBelow = false
                            ctxIdx = (flags & CoefficientFlag.hasSigNeighbor) == 0
                                ? 0
                                : Int(sigTbl[sigKeyPtr(at: i, stride: fStride, flagsPtr: flagsPtr, ignoreBelow: false)])
                        } else {
                            ignoreBelow = y == stripeEnd - 1
                            ctxIdx = Int(sigTbl[sigKeyPtr(at: i, stride: fStride, flagsPtr: flagsPtr, ignoreBelow: ignoreBelow)])
                        }
                        let flatIdx = y * w + x
                        let becomesSignificant = (magPtr[flatIdx] & mask) != 0
                        encoder.encode(becomesSignificant, context: ctxPtr.advanced(by: ctxIdx), stateTbl: stateTbl)
                        if becomesSignificant {
                            let neg = negPtr[flatIdx] != 0
                            let entry = signEntryPtr(at: i, stride: fStride, flagsPtr: flagsPtr, signTbl: signTbl, ignoreBelow: ignoreBelow)
                            encoder.encode(neg != ((entry & 1) == 1), context: ctxPtr.advanced(by: Int(entry >> 1)), stateTbl: stateTbl)
                            markSignificant64Ptr(at: i, fStride: fStride, neg: neg, causal: causal, flagsPtr: flagsPtr)
                            if computeDistortion {
                                activateDistortion64(
                                    flatIdx: flatIdx, mask: mask, plane: plane, newMid: newMid,
                                    magPtr: magPtr, reconPtr: reconPtr, lpPtr: lpPtr,
                                    unweightedDistReduction: &unweightedDistReduction
                                )
                            }
                        }
                    }
                    y += 1
                }
            }
        }
        if segmentationSymbols {
            encoder.encode(true,  context: uniCtx, stateTbl: stateTbl)
            encoder.encode(false, context: uniCtx, stateTbl: stateTbl)
            encoder.encode(true,  context: uniCtx, stateTbl: stateTbl)
            encoder.encode(false, context: uniCtx, stateTbl: stateTbl)
        }
    }

    /// Decodes one code-block into 64-bit signed integer coefficients and per-sample
    /// lowest updated bit-plane indices (`lastUpdatedPlanes[j] == -1` for zero samples,
    /// `0...(bitPlanes-1)` for significant samples). Supports `mb` up to 62 bit-planes.
    package static func decodeRich(
        segments: [CodewordSegment],
        width: Int,
        height: Int,
        orientation: BandOrientation,
        zeroBitPlanes: Int,
        passCount: Int,
        magnitudeBitPlanes mb: Int,
        style: CodeBlockStyle,
        workspace: EBCOTWorkspace? = nil
    ) throws -> (coefficients: [Int64], lastUpdatedPlanes: [Int8]) {
        let count = width * height
        guard width > 0, height > 0, count <= maximumCoefficients, mb >= 1, mb <= maximumExtendedBitPlanes else {
            throw CodecError(.internalFailure, "Code-block geometry or bit-plane count is outside the extended coder's range.")
        }
        if passCount == 0 {
            return ([Int64](repeating: 0, count: count), [Int8](repeating: -1, count: count))
        }
        let bitPlanes = mb - zeroBitPlanes
        guard zeroBitPlanes >= 0, bitPlanes >= 1, passCount <= 3 * bitPlanes - 2 else {
            throw CodecError(.malformedInput, "Code-block signals more coding passes or missing bit-planes than its band allows.")
        }
        guard segments.reduce(0, { $0 + $1.passes }) == passCount else {
            throw CodecError(.malformedInput, "Codeword segments do not account for every coding pass.")
        }

        // Fast pointer-backed single-segment MQ path (covers standard lossy & lossless Part-1 blocks).
        if segments.count == 1 && !style.bypass && !style.terminateAll {
            let ws = workspace ?? EBCOTWorkspace()
            ws.ensureCount64(count, withDistortion: false)
            ws.magnitudes64.withUnsafeMutableBufferPointer { $0.baseAddress?.update(repeating: 0, count: count) }
            var lastUpdatedPlanes = [Int8](repeating: -1, count: count)
            var coefficients = [Int64](repeating: 0, count: count)
            let fStride = width + 2
            let fCount = fStride * (height + 2)
            ws.prepareFlags(width: width, height: height)
            let tables = ContextTables(orientation: orientation)

            try segments[0].data.withUnsafeBufferPointer { segBuf in
                try ws.flags.withUnsafeMutableBufferPointer { flagsBuf in
                    try ws.contexts.withUnsafeMutableBufferPointer { ctxBuf in
                        try ws.magnitudes64.withUnsafeMutableBufferPointer { magBuf in
                            try lastUpdatedPlanes.withUnsafeMutableBufferPointer { lpBuf in
                                try coefficients.withUnsafeMutableBufferPointer { outBuf in
                                    try tables.significance.withUnsafeBufferPointer { sigTblBuf in
                                        try ContextTables.sign.withUnsafeBufferPointer { signTblBuf in
                                            try mqStateTable.withUnsafeBufferPointer { stateTblBuf in
                                                let flagsPtr = flagsBuf.baseAddress!
                                                let ctxPtr = ctxBuf.baseAddress!
                                                let magPtr = magBuf.baseAddress!
                                                let lpPtr = lpBuf.baseAddress!
                                                let outPtr = outBuf.baseAddress!
                                                let sigTbl = sigTblBuf.baseAddress!
                                                let signTbl = signTblBuf.baseAddress!
                                                let stateTbl = stateTblBuf.baseAddress!
                                                resetContextsPtr(ctxPtr)
                                                var mq = MQPtrDecoder(base: segBuf.baseAddress, count: segBuf.count, stateTbl: stateTbl)
                                                var passIndex = 0
                                                let causal = style.causal
                                                let reset = style.reset
                                                let segSym = style.segmentationSymbols
                                                let busy = CoefficientFlag.significant | CoefficientFlag.visited
                                                let sigPassGate = CoefficientFlag.hasSigNeighbor | busy
                                                let rlGate = CoefficientFlag.hasSigNeighbor | busy

                                                planes: for plane in stride(from: bitPlanes - 1, through: 0, by: -1) {
                                                    let mask = UInt64(1) << UInt64(plane)
                                                    let planeInt8 = Int8(plane)
                                                    if plane != bitPlanes - 1 {
                                                        if passIndex == passCount { break planes }
                                                        for stripe in stride(from: 0, to: height, by: 4) {
                                                            let stripeEnd = min(stripe + 4, height)
                                                            for x in 0..<width {
                                                                for y in stripe..<stripeEnd {
                                                                    let i = (y + 1) * fStride + x + 1
                                                                    let flags = flagsPtr[i]
                                                                    let ignoreBelow: Bool
                                                                    let key: Int
                                                                    if !causal {
                                                                        if (flags & sigPassGate) != CoefficientFlag.hasSigNeighbor { continue }
                                                                        ignoreBelow = false
                                                                        key = sigKeyPtr(at: i, stride: fStride, flagsPtr: flagsPtr, ignoreBelow: false)
                                                                    } else {
                                                                        if (flags & busy) != 0 { continue }
                                                                        ignoreBelow = y == stripeEnd - 1
                                                                        key = sigKeyPtr(at: i, stride: fStride, flagsPtr: flagsPtr, ignoreBelow: ignoreBelow)
                                                                        if key == 0 { continue }
                                                                    }
                                                                    let flatIdx = y * width + x
                                                                    if mq.decode(context: ctxPtr.advanced(by: Int(sigTbl[key]))) {
                                                                        magPtr[flatIdx] |= mask
                                                                        lpPtr[flatIdx] = planeInt8
                                                                        decodeSign32Ptr(
                                                                            at: i, fStride: fStride, ignoreBelow: ignoreBelow, causal: causal,
                                                                            flagsPtr: flagsPtr, signTbl: signTbl, ctxPtr: ctxPtr, decoder: &mq
                                                                        )
                                                                    } else {
                                                                        flagsPtr[i] = flags | CoefficientFlag.visited
                                                                    }
                                                                }
                                                            }
                                                        }
                                                        passIndex += 1
                                                        if reset { resetContextsPtr(ctxPtr) }

                                                        if passIndex == passCount { break planes }
                                                        for stripe in stride(from: 0, to: height, by: 4) {
                                                            let stripeEnd = min(stripe + 4, height)
                                                            for x in 0..<width {
                                                                for y in stripe..<stripeEnd {
                                                                    let i = (y + 1) * fStride + x + 1
                                                                    let flags = flagsPtr[i]
                                                                    guard (flags & busy) == CoefficientFlag.significant else { continue }
                                                                    let flatIdx = y * width + x
                                                                    let label: Int
                                                                    if !causal {
                                                                        if (flags & CoefficientFlag.refined) != 0 {
                                                                            label = Int(ContextLabel.refinementSubsequent)
                                                                        } else {
                                                                            label = Int((flags & CoefficientFlag.hasSigNeighbor) != 0
                                                                                ? ContextLabel.refinementFirstWithNeighbours
                                                                                : ContextLabel.refinementFirstNoNeighbours)
                                                                        }
                                                                    } else {
                                                                        label = refLabelPtr(flags: flags, at: i, stride: fStride, flagsPtr: flagsPtr, ignoreBelow: y == stripeEnd - 1)
                                                                    }
                                                                    if mq.decode(context: ctxPtr.advanced(by: label)) {
                                                                        magPtr[flatIdx] |= mask
                                                                    }
                                                                    lpPtr[flatIdx] = planeInt8
                                                                    flagsPtr[i] = flags | CoefficientFlag.visited | CoefficientFlag.refined
                                                                }
                                                            }
                                                        }
                                                        passIndex += 1
                                                        if reset { resetContextsPtr(ctxPtr) }
                                                    }
                                                    if passIndex == passCount { break planes }
                                                    let rlCtx = ctxPtr.advanced(by: Int(ContextLabel.runLength))
                                                    let uniCtx = ctxPtr.advanced(by: Int(ContextLabel.uniform))
                                                    for stripe in stride(from: 0, to: height, by: 4) {
                                                        let stripeEnd = min(stripe + 4, height)
                                                        for x in 0..<width {
                                                            var y = stripe
                                                            if stripeEnd - stripe == 4 {
                                                                let i0 = (stripe + 1) * fStride + x + 1
                                                                let rlOk: Bool
                                                                if !causal {
                                                                    let colFlags = flagsPtr[i0] | flagsPtr[i0 + fStride] | flagsPtr[i0 + 2 * fStride] | flagsPtr[i0 + 3 * fStride]
                                                                    rlOk = (colFlags & rlGate) == 0
                                                                } else {
                                                                    rlOk = runLengthEligiblePtr(x: x, stripe: stripe, stride: fStride, flagsPtr: flagsPtr, causal: true)
                                                                }
                                                                if rlOk {
                                                                    if !mq.decode(context: rlCtx) { continue }
                                                                    let high = mq.decode(context: uniCtx) ? 2 : 0
                                                                    let low = mq.decode(context: uniCtx) ? 1 : 0
                                                                    let first = high + low
                                                                    let flatIdx = (stripe + first) * width + x
                                                                    magPtr[flatIdx] |= mask
                                                                    lpPtr[flatIdx] = planeInt8
                                                                    decodeSign32Ptr(
                                                                        at: i0 + first * fStride,
                                                                        fStride: fStride,
                                                                        ignoreBelow: causal && first == 3,
                                                                        causal: causal,
                                                                        flagsPtr: flagsPtr, signTbl: signTbl, ctxPtr: ctxPtr, decoder: &mq
                                                                    )
                                                                    y = stripe + first + 1
                                                                }
                                                            }
                                                            while y < stripeEnd {
                                                                let i = (y + 1) * fStride + x + 1
                                                                let flags = flagsPtr[i]
                                                                if (flags & busy) == 0 {
                                                                    let ignoreBelow: Bool
                                                                    let ctxIdx: Int
                                                                    if !causal {
                                                                        ignoreBelow = false
                                                                        ctxIdx = (flags & CoefficientFlag.hasSigNeighbor) == 0
                                                                            ? 0
                                                                            : Int(sigTbl[sigKeyPtr(at: i, stride: fStride, flagsPtr: flagsPtr, ignoreBelow: false)])
                                                                    } else {
                                                                        ignoreBelow = y == stripeEnd - 1
                                                                        let key = sigKeyPtr(at: i, stride: fStride, flagsPtr: flagsPtr, ignoreBelow: ignoreBelow)
                                                                        ctxIdx = Int(sigTbl[key])
                                                                    }
                                                                    if mq.decode(context: ctxPtr.advanced(by: ctxIdx)) {
                                                                        let flatIdx = y * width + x
                                                                        magPtr[flatIdx] |= mask
                                                                        lpPtr[flatIdx] = planeInt8
                                                                        decodeSign32Ptr(
                                                                            at: i, fStride: fStride, ignoreBelow: ignoreBelow, causal: causal,
                                                                            flagsPtr: flagsPtr, signTbl: signTbl, ctxPtr: ctxPtr, decoder: &mq
                                                                        )
                                                                    }
                                                                }
                                                                y += 1
                                                            }
                                                        }
                                                    }
                                                    if segSym {
                                                        var symbol = 0
                                                        for _ in 0..<4 {
                                                            symbol = (symbol << 1) | (mq.decode(context: uniCtx) ? 1 : 0)
                                                        }
                                                        guard symbol == 0b1010 else {
                                                            throw CodecError(.malformedInput, "Segmentation symbol mismatch after a cleanup pass.")
                                                        }
                                                    }
                                                    passIndex += 1
                                                    if reset { resetContextsPtr(ctxPtr) }
                                                    clearVisitedPtr(flagsPtr, count: fCount)
                                                }

                                                for y in 0..<height {
                                                    let flagRow = flagsPtr.advanced(by: (y + 1) * fStride + 1)
                                                    let rowOff = y * width
                                                    for x in 0..<width {
                                                        let j = rowOff + x
                                                        let mag = Int64(bitPattern: magPtr[j])
                                                        outPtr[j] = (flagRow[x] & CoefficientFlag.negative) != 0 ? -mag : mag
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return (coefficients, lastUpdatedPlanes)
        }

        let tables = ContextTables(orientation: orientation)
        var states = StatePlane(width: width, height: height)
        var contexts = ContextSet()
        var magnitudes = [UInt64](repeating: 0, count: count)
        var lastUpdatedPlanes = [Int8](repeating: -1, count: count)
        var mqDecoder = try MQDecoder(bytes: [], start: 0, end: 0)
        var rawDecoder = RawDecoder(bytes: [])
        var activeIsRaw = false
        var segmentIndex = 0
        var passIndex = 0

        func beginPassIfNeeded() throws {
            guard passIndex == 0 || style.passTerminates(passIndex - 1) else { return }
            guard segmentIndex < segments.count else {
                throw CodecError(.malformedInput, "A coding pass has no codeword segment.")
            }
            let segment = segments[segmentIndex]
            segmentIndex += 1
            if style.passIsRaw(passIndex) {
                rawDecoder = RawDecoder(bytes: segment.data)
                activeIsRaw = true
            } else {
                mqDecoder = try MQDecoder(bytes: segment.data, start: 0, end: segment.data.count)
                activeIsRaw = false
            }
        }
        func endPass() {
            passIndex += 1
            if style.reset { contexts = ContextSet() }
        }

        planes: for plane in stride(from: bitPlanes - 1, through: 0, by: -1) {
            let mask = UInt64(1) << UInt64(plane)
            let planeInt8 = Int8(plane)
            if plane != bitPlanes - 1 {
                if passIndex == passCount { break planes }
                try beginPassIfNeeded()
                if activeIsRaw {
                    decodeSigPass64Raw(mask: mask, plane: planeInt8, magnitudes: &magnitudes, lastPlanes: &lastUpdatedPlanes,
                                       states: &states, decoder: &rawDecoder, causal: style.causal)
                } else {
                    decodeSigPass64MQ(mask: mask, plane: planeInt8, magnitudes: &magnitudes, lastPlanes: &lastUpdatedPlanes,
                                      states: &states, tables: tables, contexts: &contexts, decoder: &mqDecoder, causal: style.causal)
                }
                endPass()
                if passIndex == passCount { break planes }
                try beginPassIfNeeded()
                if activeIsRaw {
                    decodeRefPass64Raw(mask: mask, plane: planeInt8, magnitudes: &magnitudes, lastPlanes: &lastUpdatedPlanes,
                                       states: &states, decoder: &rawDecoder)
                } else {
                    decodeRefPass64MQ(mask: mask, plane: planeInt8, magnitudes: &magnitudes, lastPlanes: &lastUpdatedPlanes,
                                      states: &states, contexts: &contexts, decoder: &mqDecoder, causal: style.causal)
                }
                endPass()
            }
            if passIndex == passCount { break planes }
            try beginPassIfNeeded()
            guard !activeIsRaw else {
                throw CodecError(.malformedInput, "A cleanup pass fell inside a raw codeword segment.")
            }
            decodeCleanupPass64(mask: mask, plane: planeInt8, magnitudes: &magnitudes, lastPlanes: &lastUpdatedPlanes,
                                states: &states, tables: tables, contexts: &contexts, decoder: &mqDecoder, causal: style.causal)
            if style.segmentationSymbols {
                var symbol = 0
                for _ in 0..<4 { symbol = symbol << 1 | (mqDecoder.decode(context: &contexts.contexts[Int(ContextLabel.uniform)]) ? 1 : 0) }
                guard symbol == 0b1010 else {
                    throw CodecError(.malformedInput, "Segmentation symbol mismatch after a cleanup pass.")
                }
            }
            endPass()
            states.clearVisited()
        }

        var coefficients = [Int64](repeating: 0, count: count)
        for y in 0..<height {
            for x in 0..<width {
                let j = y * width + x
                let mag = Int64(bitPattern: magnitudes[j])
                coefficients[j] = states.flags[states.index(x: x, y: y)] & CoefficientFlag.negative != 0 ? -mag : mag
            }
        }
        return (coefficients, lastUpdatedPlanes)
    }

    private static func decodeSigPass64MQ(
        mask: UInt64, plane: Int8, magnitudes: inout [UInt64], lastPlanes: inout [Int8],
        states: inout StatePlane, tables: ContextTables, contexts: inout ContextSet,
        decoder: inout MQDecoder, causal: Bool
    ) {
        let w = states.width, h = states.height
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                for y in stripe..<stripeEnd {
                    let i = states.index(x: x, y: y)
                    let flags = states.flags[i]
                    if flags & (CoefficientFlag.significant | CoefficientFlag.visited) != 0 { continue }
                    let ignoreBelow = causal && y == stripeEnd - 1
                    let key = states.significanceKey(at: i, ignoreBelow: ignoreBelow)
                    if key == 0 { continue }
                    let flatIdx = y * w + x
                    if decoder.decode(context: &contexts.contexts[Int(tables.significance[key])]) {
                        magnitudes[flatIdx] |= mask
                        lastPlanes[flatIdx] = plane
                        decodeSign(at: i, ignoreBelow: ignoreBelow, states: &states, contexts: &contexts, decoder: &decoder)
                    } else {
                        states.flags[i] = flags | CoefficientFlag.visited
                    }
                }
            }
        }
    }

    private static func decodeSigPass64Raw(
        mask: UInt64, plane: Int8, magnitudes: inout [UInt64], lastPlanes: inout [Int8],
        states: inout StatePlane, decoder: inout RawDecoder, causal: Bool
    ) {
        let w = states.width, h = states.height
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                for y in stripe..<stripeEnd {
                    let i = states.index(x: x, y: y)
                    let flags = states.flags[i]
                    if flags & (CoefficientFlag.significant | CoefficientFlag.visited) != 0 { continue }
                    let ignoreBelow = causal && y == stripeEnd - 1
                    let key = states.significanceKey(at: i, ignoreBelow: ignoreBelow)
                    if key == 0 { continue }
                    let flatIdx = y * w + x
                    if decoder.decode() {
                        magnitudes[flatIdx] |= mask
                        lastPlanes[flatIdx] = plane
                        let negative = decoder.decode()
                        states.flags[i] = CoefficientFlag.significant | CoefficientFlag.visited | (negative ? CoefficientFlag.negative : 0)
                    } else {
                        states.flags[i] = flags | CoefficientFlag.visited
                    }
                }
            }
        }
    }

    private static func decodeRefPass64MQ(
        mask: UInt64, plane: Int8, magnitudes: inout [UInt64], lastPlanes: inout [Int8],
        states: inout StatePlane, contexts: inout ContextSet, decoder: inout MQDecoder, causal: Bool
    ) {
        let w = states.width, h = states.height
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                for y in stripe..<stripeEnd {
                    let i = states.index(x: x, y: y)
                    let flags = states.flags[i]
                    guard flags & (CoefficientFlag.significant | CoefficientFlag.visited) == CoefficientFlag.significant else { continue }
                    let flatIdx = y * w + x
                    let label = refinementLabel(flags: flags, at: i, states: states, ignoreBelow: causal && y == stripeEnd - 1)
                    if decoder.decode(context: &contexts.contexts[Int(label)]) {
                        magnitudes[flatIdx] |= mask
                    }
                    lastPlanes[flatIdx] = plane
                    states.flags[i] = flags | CoefficientFlag.visited | CoefficientFlag.refined
                }
            }
        }
    }

    private static func decodeRefPass64Raw(
        mask: UInt64, plane: Int8, magnitudes: inout [UInt64], lastPlanes: inout [Int8],
        states: inout StatePlane, decoder: inout RawDecoder
    ) {
        let w = states.width, h = states.height
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                for y in stripe..<stripeEnd {
                    let i = states.index(x: x, y: y)
                    let flags = states.flags[i]
                    guard flags & (CoefficientFlag.significant | CoefficientFlag.visited) == CoefficientFlag.significant else { continue }
                    let flatIdx = y * w + x
                    if decoder.decode() {
                        magnitudes[flatIdx] |= mask
                    }
                    lastPlanes[flatIdx] = plane
                    states.flags[i] = flags | CoefficientFlag.visited | CoefficientFlag.refined
                }
            }
        }
    }

    private static func decodeCleanupPass64(
        mask: UInt64, plane: Int8, magnitudes: inout [UInt64], lastPlanes: inout [Int8],
        states: inout StatePlane, tables: ContextTables, contexts: inout ContextSet,
        decoder: inout MQDecoder, causal: Bool
    ) {
        let w = states.width, h = states.height
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                var y = stripe
                if stripeEnd - stripe == 4, runLengthEligible(x: x, stripe: stripe, states: states, causal: causal) {
                    guard decoder.decode(context: &contexts.contexts[Int(ContextLabel.runLength)]) else { continue }
                    let high = decoder.decode(context: &contexts.contexts[Int(ContextLabel.uniform)]) ? 2 : 0
                    let low = decoder.decode(context: &contexts.contexts[Int(ContextLabel.uniform)]) ? 1 : 0
                    let first = high + low
                    let flatIdx = (stripe + first) * w + x
                    magnitudes[flatIdx] |= mask
                    lastPlanes[flatIdx] = plane
                    decodeSign(at: states.index(x: x, y: stripe + first), ignoreBelow: causal && first == 3,
                               states: &states, contexts: &contexts, decoder: &decoder)
                    y = stripe + first + 1
                }
                while y < stripeEnd {
                    let i = states.index(x: x, y: y)
                    if states.flags[i] & (CoefficientFlag.significant | CoefficientFlag.visited) == 0 {
                        let ignoreBelow = causal && y == stripeEnd - 1
                        let key = states.significanceKey(at: i, ignoreBelow: ignoreBelow)
                        if decoder.decode(context: &contexts.contexts[Int(tables.significance[key])]) {
                            let flatIdx = y * w + x
                            magnitudes[flatIdx] |= mask
                            lastPlanes[flatIdx] = plane
                            decodeSign(at: i, ignoreBelow: ignoreBelow, states: &states, contexts: &contexts, decoder: &decoder)
                        }
                    }
                    y += 1
                }
            }
        }
    }
}
