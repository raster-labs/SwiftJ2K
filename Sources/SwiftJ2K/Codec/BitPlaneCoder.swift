// SPDX-License-Identifier: Apache-2.0
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
// Sources/J2KCodec/J2KBitPlaneCoder.swift (MIT; relicensed Apache-2.0 under
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
struct CodeBlockEncoding: Sendable {
    var data: [UInt8]
    var passCount: Int
    let zeroBitPlanes: Int
    var passByteOffsets: [Int]
    var passTerminatedBytes: [Int]
    var passDistortionReductions: [Double]
    var layerPassCounts: [Int]

    init(
        data: [UInt8],
        passCount: Int,
        zeroBitPlanes: Int,
        passByteOffsets: [Int] = [],
        passTerminatedBytes: [Int] = [],
        passDistortionReductions: [Double] = [],
        layerPassCounts: [Int]? = nil
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
    }
}

/// Raw (bypass) bit writer: MSB first, seven bits after a 0xFF byte (D.6).
struct RawEncoder: Sendable {
    private var bytes: [UInt8] = []
    private var current: UInt8 = 0
    private var maxBits: Int = 8
    private var usedBits: Int = 0
    private let maximumOutputBytes: Int
    private(set) var overflowed = false

    init(maximumOutputBytes: Int = Int.max) {
        self.maximumOutputBytes = maximumOutputBytes
    }

    @inline(__always)
    mutating func encode(_ bit: Bool) {
        current = (current << 1) | (bit ? 1 : 0)
        usedBits += 1
        if usedBits == maxBits {
            if bytes.count < maximumOutputBytes {
                bytes.append(current)
            } else {
                overflowed = true
            }
            maxBits = current == 0xFF ? 7 : 8
            current = 0
            usedBits = 0
        }
    }

    mutating func finish() -> [UInt8] {
        if usedBits > 0 {
            let remaining = maxBits - usedBits
            // Pad remaining low bits with alternating 0101... (0x55 mask) per Annex D.6
            let padMask = UInt8((1 << remaining) - 1) & 0x55
            let finalByte = (current << UInt8(remaining)) | padMask
            if bytes.count < maximumOutputBytes {
                bytes.append(finalByte)
            } else {
                overflowed = true
            }
            current = 0
            usedBits = 0
            maxBits = 8
        }
        while let last = bytes.last, last == 0xFF {
            bytes.removeLast()
        }
        return bytes
    }

    var emittedByteCount: Int { bytes.count + (usedBits > 0 ? 1 : 0) }
}

/// Raw (bypass) bit reader: MSB first, seven bits after a 0xFF byte, 0xFF fed
/// past the end of the segment (D.6).
struct RawDecoder: Sendable {
    private let bytes: [UInt8]
    private var position: Int
    private let end: Int
    private var current: UInt32 = 0
    private var bitsLeft = 0

    init(bytes: [UInt8]) { self.bytes = bytes; position = 0; end = bytes.count }

    @inline(__always)
    mutating func decode() -> Bool {
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

enum BitPlaneCoder {
    static let maximumCoefficients = 4096
    static let maximumMagnitudeBitPlanes = 30

    // MARK: - Encoder (default style)

    static func encode(coefficients: [Int32], width: Int, height: Int,
                       orientation: BandOrientation, magnitudeBitPlanes mb: Int,
                       maximumOutputBytes: Int = Int.max) throws -> CodeBlockEncoding {
        let count = width * height
        guard width > 0, height > 0, count <= maximumCoefficients, coefficients.count == count,
              mb >= 1, mb <= maximumMagnitudeBitPlanes else {
            throw CodecError(.internalFailure, "Code-block geometry or bit-plane count is outside the coder's range.")
        }
        var magnitudes = [UInt32](repeating: 0, count: count)
        var maximum: UInt32 = 0
        for i in 0..<count {
            let value = coefficients[i]
            let magnitude = value < 0 ? UInt32(bitPattern: 0 &- value) : UInt32(value)
            if magnitude > maximum { maximum = magnitude }
            magnitudes[i] = magnitude | (value < 0 ? 0x8000_0000 : 0)
        }
        let bitPlanes = maximum == 0 ? 0 : UInt32.bitWidth - maximum.leadingZeroBitCount
        guard bitPlanes <= mb else {
            throw CodecError(.invalidArgument, "A coefficient exceeds the precision the band can represent.")
        }
        if bitPlanes == 0 { return CodeBlockEncoding(data: [], passCount: 0, zeroBitPlanes: mb) }
        guard maximumOutputBytes > 0 else {
            throw CodecError(.resourceLimitExceeded, "Encoded code-block exceeds the output byte budget.")
        }

        let tables = ContextTables(orientation: orientation)
        var states = StatePlane(width: width, height: height)
        var contexts = ContextSet()
        var encoder = MQEncoder(capacityHint: count / 2, maximumOutputBytes: maximumOutputBytes)
        var passCount = 0
        for plane in stride(from: bitPlanes - 1, through: 0, by: -1) {
            let mask = UInt32(1) << UInt32(plane)
            if plane != bitPlanes - 1 {
                encodeSignificancePass(mask: mask, magnitudes: magnitudes,
                                       states: &states, tables: tables, contexts: &contexts, encoder: &encoder)
                encodeRefinementPass(mask: mask, magnitudes: magnitudes, states: &states, contexts: &contexts, encoder: &encoder)
                passCount += 2
            }
            encodeCleanupPass(mask: mask, magnitudes: magnitudes,
                              states: &states, tables: tables, contexts: &contexts, encoder: &encoder)
            passCount += 1
            if encoder.overflowed {
                throw CodecError(.resourceLimitExceeded, "Encoded code-block exceeds the output byte budget.")
            }
            states.clearVisited()
        }
        let encodedBytes = encoder.finish()
        if encoder.overflowed {
            throw CodecError(.resourceLimitExceeded, "Encoded code-block exceeds the output byte budget.")
        }
        return CodeBlockEncoding(data: encodedBytes, passCount: passCount, zeroBitPlanes: mb - bitPlanes)
    }

    private static func encodeSignificancePass(mask: UInt32, magnitudes: borrowing [UInt32],
                                               states: inout StatePlane, tables: ContextTables,
                                               contexts: inout ContextSet, encoder: inout MQEncoder) {
        let w = states.width, h = states.height
        for stripe in stride(from: 0, to: h, by: 4) {
            for x in 0..<w {
                for y in stripe..<min(stripe + 4, h) {
                    let i = states.index(x: x, y: y)
                    let flags = states.flags[i]
                    if flags & (CoefficientFlag.significant | CoefficientFlag.visited) != 0 { continue }
                    let key = states.significanceKey(at: i, ignoreBelow: false)
                    if key == 0 { continue }
                    let m = magnitudes[y * w + x]
                    let becomesSignificant = m & mask != 0
                    encoder.encode(becomesSignificant, context: &contexts.contexts[Int(tables.significance[key])])
                    if becomesSignificant {
                        encodeSign(negative: m >= 0x8000_0000, at: i, states: &states, contexts: &contexts, encoder: &encoder)
                    } else {
                        states.flags[i] = flags | CoefficientFlag.visited
                    }
                }
            }
        }
    }

    private static func encodeRefinementPass(mask: UInt32, magnitudes: borrowing [UInt32], states: inout StatePlane,
                                             contexts: inout ContextSet, encoder: inout MQEncoder) {
        let w = states.width, h = states.height
        for stripe in stride(from: 0, to: h, by: 4) {
            for x in 0..<w {
                for y in stripe..<min(stripe + 4, h) {
                    let i = states.index(x: x, y: y)
                    let flags = states.flags[i]
                    guard flags & (CoefficientFlag.significant | CoefficientFlag.visited) == CoefficientFlag.significant else { continue }
                    let label = refinementLabel(flags: flags, at: i, states: states, ignoreBelow: false)
                    encoder.encode(magnitudes[y * w + x] & mask != 0, context: &contexts.contexts[Int(label)])
                    states.flags[i] = flags | CoefficientFlag.visited | CoefficientFlag.refined
                }
            }
        }
    }

    private static func encodeCleanupPass(mask: UInt32, magnitudes: borrowing [UInt32],
                                          states: inout StatePlane, tables: ContextTables,
                                          contexts: inout ContextSet, encoder: inout MQEncoder) {
        let w = states.width, h = states.height
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                var y = stripe
                if stripeEnd - stripe == 4, runLengthEligible(x: x, stripe: stripe, states: states, causal: false) {
                    var first = -1
                    for k in 0..<4 where magnitudes[(stripe + k) * w + x] & mask != 0 { first = k; break }
                    encoder.encode(first >= 0, context: &contexts.contexts[Int(ContextLabel.runLength)])
                    if first < 0 { continue }
                    encoder.encode(first & 2 != 0, context: &contexts.contexts[Int(ContextLabel.uniform)])
                    encoder.encode(first & 1 != 0, context: &contexts.contexts[Int(ContextLabel.uniform)])
                    encodeSign(negative: magnitudes[(stripe + first) * w + x] >= 0x8000_0000, at: states.index(x: x, y: stripe + first),
                               states: &states, contexts: &contexts, encoder: &encoder)
                    y = stripe + first + 1
                }
                while y < stripeEnd {
                    let i = states.index(x: x, y: y)
                    if states.flags[i] & (CoefficientFlag.significant | CoefficientFlag.visited) == 0 {
                        let key = states.significanceKey(at: i, ignoreBelow: false)
                        let m = magnitudes[y * w + x]
                        let becomesSignificant = m & mask != 0
                        encoder.encode(becomesSignificant, context: &contexts.contexts[Int(tables.significance[key])])
                        if becomesSignificant {
                            encodeSign(negative: m >= 0x8000_0000, at: i, states: &states, contexts: &contexts, encoder: &encoder)
                        }
                    }
                    y += 1
                }
            }
        }
    }

    @inline(__always)
    private static func encodeSign(negative: Bool, at i: Int, states: inout StatePlane,
                                   contexts: inout ContextSet, encoder: inout MQEncoder) {
        let entry = states.signEntry(at: i, ignoreBelow: false)
        encoder.encode(negative != (entry & 1 == 1), context: &contexts.contexts[Int(entry >> 1)])
        states.flags[i] = CoefficientFlag.significant | CoefficientFlag.visited | (negative ? CoefficientFlag.negative : 0)
    }

    // MARK: - Decoder (all styles)

    private enum Coder {
        case mq(MQDecoder)
        case raw(RawDecoder)
    }

    /// Decodes one code-block from its codeword segments into sign-magnitude
    /// integer coefficients. `passCount` passes are consumed in total.
    static func decode(segments: [CodewordSegment], width: Int, height: Int, orientation: BandOrientation,
                       zeroBitPlanes: Int, passCount: Int, magnitudeBitPlanes mb: Int,
                       style: CodeBlockStyle) throws -> [Int32] {
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

        let tables = ContextTables(orientation: orientation)
        var states = StatePlane(width: width, height: height)
        var contexts = ContextSet()
        var magnitudes = [UInt32](repeating: 0, count: count)
        var coder: Coder? = nil
        var segmentIndex = 0
        var passIndex = 0

        func beginPassIfNeeded() throws {
            guard passIndex == 0 || style.passTerminates(passIndex - 1) else { return }
            guard segmentIndex < segments.count else {
                throw CodecError(.malformedInput, "A coding pass has no codeword segment.")
            }
            let segment = segments[segmentIndex]
            segmentIndex += 1
            coder = style.passIsRaw(passIndex)
                ? .raw(RawDecoder(bytes: segment.data))
                : .mq(try MQDecoder(bytes: segment.data, start: 0, end: segment.data.count))
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
                decodeSignificancePass(mask: mask, magnitudes: &magnitudes, states: &states, tables: tables,
                                       contexts: &contexts, coder: &coder!, causal: style.causal)
                endPass()
                if passIndex == passCount { break planes }
                try beginPassIfNeeded()
                decodeRefinementPass(mask: mask, magnitudes: &magnitudes, states: &states,
                                     contexts: &contexts, coder: &coder!, causal: style.causal)
                endPass()
            }
            if passIndex == passCount { break planes }
            try beginPassIfNeeded()
            guard case .mq(var mq) = coder! else {
                throw CodecError(.malformedInput, "A cleanup pass fell inside a raw codeword segment.")
            }
            decodeCleanupPass(mask: mask, magnitudes: &magnitudes, states: &states, tables: tables,
                              contexts: &contexts, decoder: &mq, causal: style.causal)
            if style.segmentationSymbols {
                var symbol = 0
                for _ in 0..<4 { symbol = symbol << 1 | (mq.decode(context: &contexts.contexts[Int(ContextLabel.uniform)]) ? 1 : 0) }
                guard symbol == 0b1010 else {
                    throw CodecError(.malformedInput, "Segmentation symbol mismatch after a cleanup pass.")
                }
            }
            coder = .mq(mq)
            endPass()
            states.clearVisited()
        }

        var coefficients = [Int32](repeating: 0, count: count)
        for y in 0..<height {
            for x in 0..<width {
                let j = y * width + x
                let magnitude = Int32(magnitudes[j])   // mb <= 30 keeps this in range
                coefficients[j] = states.flags[states.index(x: x, y: y)] & CoefficientFlag.negative != 0 ? -magnitude : magnitude
            }
        }
        return coefficients
    }

    private static func decodeSignificancePass(mask: UInt32, magnitudes: inout [UInt32], states: inout StatePlane,
                                               tables: ContextTables, contexts: inout ContextSet,
                                               coder: inout Coder, causal: Bool) {
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
                    switch coder {
                    case .mq(var mq):
                        if mq.decode(context: &contexts.contexts[Int(tables.significance[key])]) {
                            magnitudes[y * w + x] |= mask
                            decodeSign(at: i, ignoreBelow: ignoreBelow, states: &states, contexts: &contexts, decoder: &mq)
                        } else {
                            states.flags[i] = flags | CoefficientFlag.visited
                        }
                        coder = .mq(mq)
                    case .raw(var raw):
                        if raw.decode() {
                            magnitudes[y * w + x] |= mask
                            let negative = raw.decode()
                            states.flags[i] = CoefficientFlag.significant | CoefficientFlag.visited | (negative ? CoefficientFlag.negative : 0)
                        } else {
                            states.flags[i] = flags | CoefficientFlag.visited
                        }
                        coder = .raw(raw)
                    }
                }
            }
        }
    }

    private static func decodeRefinementPass(mask: UInt32, magnitudes: inout [UInt32], states: inout StatePlane,
                                             contexts: inout ContextSet, coder: inout Coder, causal: Bool) {
        let w = states.width, h = states.height
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                for y in stripe..<stripeEnd {
                    let i = states.index(x: x, y: y)
                    let flags = states.flags[i]
                    guard flags & (CoefficientFlag.significant | CoefficientFlag.visited) == CoefficientFlag.significant else { continue }
                    let bit: Bool
                    switch coder {
                    case .mq(var mq):
                        let label = refinementLabel(flags: flags, at: i, states: states, ignoreBelow: causal && y == stripeEnd - 1)
                        bit = mq.decode(context: &contexts.contexts[Int(label)])
                        coder = .mq(mq)
                    case .raw(var raw):
                        bit = raw.decode()
                        coder = .raw(raw)
                    }
                    if bit { magnitudes[y * w + x] |= mask }
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

    static let maximumExtendedBitPlanes = 62

    private enum EncodeCoder {
        case mq(MQEncoder)
        case raw(RawEncoder)
    }

    /// Encodes one code-block of 64-bit signed integer coefficients with support for:
    /// - extended magnitude bit-planes (`1...62`, e.g. high guard bits or MaxShift ROI);
    /// - all Part 1 `CodeBlockStyle` bits (`bypass`, `reset`, `terminateAll`, `causal`, `segmentationSymbols`);
    /// - optional pass-count truncation (`maxPasses`);
    /// - optional per-pass byte offsets and squared-error distortion reduction tracking for PCRD-opt.
    static func encodeRich(
        coefficients: [Int64],
        width: Int,
        height: Int,
        orientation: BandOrientation,
        magnitudeBitPlanes mb: Int,
        style: CodeBlockStyle = .default,
        maxPasses: Int? = nil,
        computeDistortion: Bool = false,
        synthesisWeight: Double = 1.0,
        stepSize: Double = 1.0,
        maximumOutputBytes: Int = Int.max
    ) throws -> CodeBlockEncoding {
        let count = width * height
        guard width > 0, height > 0, count <= maximumCoefficients, coefficients.count == count,
              mb >= 1, mb <= maximumExtendedBitPlanes else {
            throw CodecError(.internalFailure, "Code-block geometry or bit-plane count is outside the extended coder's range.")
        }
        var magnitudes = [UInt64](repeating: 0, count: count)
        var negFlags = [Bool](repeating: false, count: count)
        var maximum: UInt64 = 0
        for i in 0..<count {
            let value = coefficients[i]
            let neg = value < 0
            let mag = neg ? UInt64(bitPattern: 0 &- value) : UInt64(value)
            if mag > maximum { maximum = mag }
            magnitudes[i] = mag
            negFlags[i] = neg
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
        var states = StatePlane(width: width, height: height)
        var contexts = ContextSet()
        var reconstructed = computeDistortion ? [UInt64](repeating: 0, count: count) : []
        var lastPlane = computeDistortion ? [Int](repeating: -1, count: count) : []
        let weightSq = synthesisWeight * stepSize * stepSize
        var initialDistortion = 0.0
        if computeDistortion {
            for i in 0..<count {
                let d = Double(magnitudes[i])
                initialDistortion += d * d * weightSq
            }
        }

        var committedData: [UInt8] = []
        var activeCoder: EncodeCoder? = nil
        var passByteOffsets: [Int] = []
        var passTerminatedBytes: [Int] = []
        var passDistortionReductions: [Double] = []
        passByteOffsets.reserveCapacity(targetPasses)
        passTerminatedBytes.reserveCapacity(targetPasses)
        if computeDistortion { passDistortionReductions.reserveCapacity(targetPasses) }

        var passIndex = 0

        func beginPass() {
            if activeCoder == nil {
                if style.passIsRaw(passIndex) {
                    activeCoder = .raw(RawEncoder(maximumOutputBytes: max(1, maximumOutputBytes - committedData.count)))
                } else {
                    activeCoder = .mq(MQEncoder(capacityHint: max(16, count / 2),
                                                maximumOutputBytes: max(1, maximumOutputBytes - committedData.count)))
                }
            }
        }

        func finishPass() throws {
            let isLastPass = (passIndex + 1 == targetPasses)
            let terminates = style.passTerminates(passIndex) || isLastPass
            switch activeCoder! {
            case .mq(var mq):
                if mq.overflowed {
                    throw CodecError(.resourceLimitExceeded, "Encoded code-block exceeds the output byte budget.")
                }
                let termLen = committedData.count + mq.terminatedByteCount()
                if terminates {
                    let seg = mq.finish()
                    if mq.overflowed || committedData.count + seg.count > maximumOutputBytes {
                        throw CodecError(.resourceLimitExceeded, "Encoded code-block exceeds the output byte budget.")
                    }
                    committedData.append(contentsOf: seg)
                    passByteOffsets.append(committedData.count)
                    passTerminatedBytes.append(committedData.count)
                    activeCoder = nil
                } else {
                    passByteOffsets.append(committedData.count + mq.emittedByteCount)
                    passTerminatedBytes.append(termLen)
                    activeCoder = .mq(mq)
                }
            case .raw(var raw):
                if raw.overflowed {
                    throw CodecError(.resourceLimitExceeded, "Encoded code-block exceeds the output byte budget.")
                }
                if terminates {
                    let seg = raw.finish()
                    if raw.overflowed || committedData.count + seg.count > maximumOutputBytes {
                        throw CodecError(.resourceLimitExceeded, "Encoded code-block exceeds the output byte budget.")
                    }
                    committedData.append(contentsOf: seg)
                    passByteOffsets.append(committedData.count)
                    passTerminatedBytes.append(committedData.count)
                    activeCoder = nil
                } else {
                    let cur = committedData.count + raw.emittedByteCount
                    passByteOffsets.append(cur)
                    passTerminatedBytes.append(cur)
                    activeCoder = .raw(raw)
                }
            }
            if style.reset {
                contexts = ContextSet()
            }
            if computeDistortion {
                var currentDistortion = 0.0
                for idx in 0..<count {
                    let trueMag = Double(magnitudes[idx])
                    let reconMag: Double
                    if lastPlane[idx] >= 0 {
                        let p = lastPlane[idx]
                        let mid = p > 0 ? Double(UInt64(1) << UInt64(p - 1)) : 0.0
                        reconMag = Double(reconstructed[idx]) + mid
                    } else {
                        reconMag = 0.0
                    }
                    let diff = trueMag - reconMag
                    currentDistortion += diff * diff * weightSq
                }
                passDistortionReductions.append(max(0.0, initialDistortion - currentDistortion))
            }
            passIndex += 1
        }

        planes: for plane in stride(from: bitPlanes - 1, through: 0, by: -1) {
            let mask = UInt64(1) << UInt64(plane)
            if plane != bitPlanes - 1 {
                if passIndex == targetPasses { break planes }
                beginPass()
                encodeSigPass64(mask: mask, plane: plane, magnitudes: magnitudes, negFlags: negFlags,
                                states: &states, tables: tables, contexts: &contexts, coder: &activeCoder!,
                                causal: style.causal, computeDistortion: computeDistortion,
                                reconstructed: &reconstructed, lastPlane: &lastPlane)
                try finishPass()

                if passIndex == targetPasses { break planes }
                beginPass()
                encodeRefPass64(mask: mask, plane: plane, magnitudes: magnitudes,
                                states: &states, contexts: &contexts, coder: &activeCoder!,
                                causal: style.causal, computeDistortion: computeDistortion,
                                reconstructed: &reconstructed, lastPlane: &lastPlane)
                try finishPass()
            }
            if passIndex == targetPasses { break planes }
            beginPass()
            guard case .mq(var mq) = activeCoder! else {
                throw CodecError(.internalFailure, "Cleanup pass requires MQ coder.")
            }
            encodeCleanupPass64(mask: mask, plane: plane, magnitudes: magnitudes, negFlags: negFlags,
                                states: &states, tables: tables, contexts: &contexts, encoder: &mq,
                                causal: style.causal, segmentationSymbols: style.segmentationSymbols,
                                computeDistortion: computeDistortion,
                                reconstructed: &reconstructed, lastPlane: &lastPlane)
            activeCoder = .mq(mq)
            try finishPass()
            states.clearVisited()
        }

        // Clamp any passByteOffsets to committedData.count so slices are valid.
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
            passDistortionReductions: passDistortionReductions
        )
    }

    private static func encodeSigPass64(
        mask: UInt64, plane: Int, magnitudes: borrowing [UInt64], negFlags: borrowing [Bool],
        states: inout StatePlane, tables: ContextTables, contexts: inout ContextSet,
        coder: inout EncodeCoder, causal: Bool, computeDistortion: Bool,
        reconstructed: inout [UInt64], lastPlane: inout [Int]
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
                    let becomesSignificant = (magnitudes[flatIdx] & mask) != 0
                    let neg = negFlags[flatIdx]
                    switch coder {
                    case .mq(var mq):
                        mq.encode(becomesSignificant, context: &contexts.contexts[Int(tables.significance[key])])
                        if becomesSignificant {
                            let entry = states.signEntry(at: i, ignoreBelow: ignoreBelow)
                            mq.encode(neg != (entry & 1 == 1), context: &contexts.contexts[Int(entry >> 1)])
                            states.flags[i] = CoefficientFlag.significant | CoefficientFlag.visited | (neg ? CoefficientFlag.negative : 0)
                            if computeDistortion {
                                reconstructed[flatIdx] |= mask
                                lastPlane[flatIdx] = plane
                            }
                        } else {
                            states.flags[i] = flags | CoefficientFlag.visited
                        }
                        coder = .mq(mq)
                    case .raw(var raw):
                        raw.encode(becomesSignificant)
                        if becomesSignificant {
                            raw.encode(neg)
                            states.flags[i] = CoefficientFlag.significant | CoefficientFlag.visited | (neg ? CoefficientFlag.negative : 0)
                            if computeDistortion {
                                reconstructed[flatIdx] |= mask
                                lastPlane[flatIdx] = plane
                            }
                        } else {
                            states.flags[i] = flags | CoefficientFlag.visited
                        }
                        coder = .raw(raw)
                    }
                }
            }
        }
    }

    private static func encodeRefPass64(
        mask: UInt64, plane: Int, magnitudes: borrowing [UInt64],
        states: inout StatePlane, contexts: inout ContextSet,
        coder: inout EncodeCoder, causal: Bool, computeDistortion: Bool,
        reconstructed: inout [UInt64], lastPlane: inout [Int]
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
                    let bit = (magnitudes[flatIdx] & mask) != 0
                    switch coder {
                    case .mq(var mq):
                        let label = refinementLabel(flags: flags, at: i, states: states, ignoreBelow: causal && y == stripeEnd - 1)
                        mq.encode(bit, context: &contexts.contexts[Int(label)])
                        coder = .mq(mq)
                    case .raw(var raw):
                        raw.encode(bit)
                        coder = .raw(raw)
                    }
                    states.flags[i] = flags | CoefficientFlag.visited | CoefficientFlag.refined
                    if computeDistortion {
                        if bit { reconstructed[flatIdx] |= mask }
                        lastPlane[flatIdx] = plane
                    }
                }
            }
        }
    }

    private static func encodeCleanupPass64(
        mask: UInt64, plane: Int, magnitudes: borrowing [UInt64], negFlags: borrowing [Bool],
        states: inout StatePlane, tables: ContextTables, contexts: inout ContextSet,
        encoder: inout MQEncoder, causal: Bool, segmentationSymbols: Bool,
        computeDistortion: Bool, reconstructed: inout [UInt64], lastPlane: inout [Int]
    ) {
        let w = states.width, h = states.height
        for stripe in stride(from: 0, to: h, by: 4) {
            let stripeEnd = min(stripe + 4, h)
            for x in 0..<w {
                var y = stripe
                if stripeEnd - stripe == 4, runLengthEligible(x: x, stripe: stripe, states: states, causal: causal) {
                    var first = -1
                    for k in 0..<4 where (magnitudes[(stripe + k) * w + x] & mask) != 0 { first = k; break }
                    encoder.encode(first >= 0, context: &contexts.contexts[Int(ContextLabel.runLength)])
                    if first < 0 { continue }
                    encoder.encode(first & 2 != 0, context: &contexts.contexts[Int(ContextLabel.uniform)])
                    encoder.encode(first & 1 != 0, context: &contexts.contexts[Int(ContextLabel.uniform)])
                    let firstY = stripe + first
                    let flatIdx = firstY * w + x
                    let i = states.index(x: x, y: firstY)
                    let neg = negFlags[flatIdx]
                    let entry = states.signEntry(at: i, ignoreBelow: causal && first == 3)
                    encoder.encode(neg != (entry & 1 == 1), context: &contexts.contexts[Int(entry >> 1)])
                    states.flags[i] = CoefficientFlag.significant | CoefficientFlag.visited | (neg ? CoefficientFlag.negative : 0)
                    if computeDistortion {
                        reconstructed[flatIdx] |= mask
                        lastPlane[flatIdx] = plane
                    }
                    y = firstY + 1
                }
                while y < stripeEnd {
                    let i = states.index(x: x, y: y)
                    if states.flags[i] & (CoefficientFlag.significant | CoefficientFlag.visited) == 0 {
                        let ignoreBelow = causal && y == stripeEnd - 1
                        let key = states.significanceKey(at: i, ignoreBelow: ignoreBelow)
                        let flatIdx = y * w + x
                        let becomesSignificant = (magnitudes[flatIdx] & mask) != 0
                        encoder.encode(becomesSignificant, context: &contexts.contexts[Int(tables.significance[key])])
                        if becomesSignificant {
                            let neg = negFlags[flatIdx]
                            let entry = states.signEntry(at: i, ignoreBelow: ignoreBelow)
                            encoder.encode(neg != (entry & 1 == 1), context: &contexts.contexts[Int(entry >> 1)])
                            states.flags[i] = CoefficientFlag.significant | CoefficientFlag.visited | (neg ? CoefficientFlag.negative : 0)
                            if computeDistortion {
                                reconstructed[flatIdx] |= mask
                                lastPlane[flatIdx] = plane
                            }
                        }
                    }
                    y += 1
                }
            }
        }
        if segmentationSymbols {
            encoder.encode(true,  context: &contexts.contexts[Int(ContextLabel.uniform)])
            encoder.encode(false, context: &contexts.contexts[Int(ContextLabel.uniform)])
            encoder.encode(true,  context: &contexts.contexts[Int(ContextLabel.uniform)])
            encoder.encode(false, context: &contexts.contexts[Int(ContextLabel.uniform)])
        }
    }

    /// Decodes one code-block into 64-bit signed integer coefficients and per-sample
    /// lowest updated bit-plane indices (`lastUpdatedPlanes[j] == -1` for zero samples,
    /// `0...(bitPlanes-1)` for significant samples). Supports `mb` up to 62 bit-planes.
    static func decodeRich(
        segments: [CodewordSegment],
        width: Int,
        height: Int,
        orientation: BandOrientation,
        zeroBitPlanes: Int,
        passCount: Int,
        magnitudeBitPlanes mb: Int,
        style: CodeBlockStyle
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

        let tables = ContextTables(orientation: orientation)
        var states = StatePlane(width: width, height: height)
        var contexts = ContextSet()
        var magnitudes = [UInt64](repeating: 0, count: count)
        var lastUpdatedPlanes = [Int8](repeating: -1, count: count)
        var coder: Coder? = nil
        var segmentIndex = 0
        var passIndex = 0

        func beginPassIfNeeded() throws {
            guard passIndex == 0 || style.passTerminates(passIndex - 1) else { return }
            guard segmentIndex < segments.count else {
                throw CodecError(.malformedInput, "A coding pass has no codeword segment.")
            }
            let segment = segments[segmentIndex]
            segmentIndex += 1
            coder = style.passIsRaw(passIndex)
                ? .raw(RawDecoder(bytes: segment.data))
                : .mq(try MQDecoder(bytes: segment.data, start: 0, end: segment.data.count))
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
                decodeSigPass64(mask: mask, plane: planeInt8, magnitudes: &magnitudes, lastPlanes: &lastUpdatedPlanes,
                                states: &states, tables: tables, contexts: &contexts, coder: &coder!, causal: style.causal)
                endPass()
                if passIndex == passCount { break planes }
                try beginPassIfNeeded()
                decodeRefPass64(mask: mask, plane: planeInt8, magnitudes: &magnitudes, lastPlanes: &lastUpdatedPlanes,
                                states: &states, contexts: &contexts, coder: &coder!, causal: style.causal)
                endPass()
            }
            if passIndex == passCount { break planes }
            try beginPassIfNeeded()
            guard case .mq(var mq) = coder! else {
                throw CodecError(.malformedInput, "A cleanup pass fell inside a raw codeword segment.")
            }
            decodeCleanupPass64(mask: mask, plane: planeInt8, magnitudes: &magnitudes, lastPlanes: &lastUpdatedPlanes,
                                states: &states, tables: tables, contexts: &contexts, decoder: &mq, causal: style.causal)
            if style.segmentationSymbols {
                var symbol = 0
                for _ in 0..<4 { symbol = symbol << 1 | (mq.decode(context: &contexts.contexts[Int(ContextLabel.uniform)]) ? 1 : 0) }
                guard symbol == 0b1010 else {
                    throw CodecError(.malformedInput, "Segmentation symbol mismatch after a cleanup pass.")
                }
            }
            coder = .mq(mq)
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

    private static func decodeSigPass64(
        mask: UInt64, plane: Int8, magnitudes: inout [UInt64], lastPlanes: inout [Int8],
        states: inout StatePlane, tables: ContextTables, contexts: inout ContextSet,
        coder: inout Coder, causal: Bool
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
                    switch coder {
                    case .mq(var mq):
                        if mq.decode(context: &contexts.contexts[Int(tables.significance[key])]) {
                            magnitudes[flatIdx] |= mask
                            lastPlanes[flatIdx] = plane
                            decodeSign(at: i, ignoreBelow: ignoreBelow, states: &states, contexts: &contexts, decoder: &mq)
                        } else {
                            states.flags[i] = flags | CoefficientFlag.visited
                        }
                        coder = .mq(mq)
                    case .raw(var raw):
                        if raw.decode() {
                            magnitudes[flatIdx] |= mask
                            lastPlanes[flatIdx] = plane
                            let negative = raw.decode()
                            states.flags[i] = CoefficientFlag.significant | CoefficientFlag.visited | (negative ? CoefficientFlag.negative : 0)
                        } else {
                            states.flags[i] = flags | CoefficientFlag.visited
                        }
                        coder = .raw(raw)
                    }
                }
            }
        }
    }

    private static func decodeRefPass64(
        mask: UInt64, plane: Int8, magnitudes: inout [UInt64], lastPlanes: inout [Int8],
        states: inout StatePlane, contexts: inout ContextSet, coder: inout Coder, causal: Bool
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
                    let bit: Bool
                    switch coder {
                    case .mq(var mq):
                        let label = refinementLabel(flags: flags, at: i, states: states, ignoreBelow: causal && y == stripeEnd - 1)
                        bit = mq.decode(context: &contexts.contexts[Int(label)])
                        coder = .mq(mq)
                    case .raw(var raw):
                        bit = raw.decode()
                        coder = .raw(raw)
                    }
                    if bit { magnitudes[flatIdx] |= mask }
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
