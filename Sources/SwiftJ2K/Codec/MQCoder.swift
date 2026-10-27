// SPDX-License-Identifier: Apache-2.0
//
// MQ arithmetic coder (ISO/IEC 15444-1 Annex C).
//
// Provenance: adapted from Raster-Lab/J2KSwift at commit
// 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca, Sources/J2KCodec/J2KMQCoder.swift
// (MIT, Raster-Lab / Raster Images Private Limited; relicensed Apache-2.0
// under SUITE_POLICY POL-07). Retained: the 47-entry probability table, the
// CODEMPS/CODELPS/BYTEOUT/FLUSH encoder procedures and the software-conventions
// decoder (INITDEC/DECODE/BYTEIN). Removed: the raw-pointer output buffer and the
// escaped array base pointer that made the decoder `@unchecked Sendable`,
// checkpoints and near-optimal/predictable termination used only by rate
// control, bypass coders, and debug tracing. The successor keeps every buffer
// access bounds checked and both coders plainly `Sendable`.

/// One row of the MQ probability estimation table (Table C.2).
struct MQState: Sendable {
    let qe: UInt32
    let nextMPS: UInt8
    let nextLPS: UInt8
    let switchMPS: Bool
}

let mqStateTable: [MQState] = [
    MQState(qe: 0x5601, nextMPS: 1, nextLPS: 1, switchMPS: true),
    MQState(qe: 0x3401, nextMPS: 2, nextLPS: 6, switchMPS: false),
    MQState(qe: 0x1801, nextMPS: 3, nextLPS: 9, switchMPS: false),
    MQState(qe: 0x0AC1, nextMPS: 4, nextLPS: 12, switchMPS: false),
    MQState(qe: 0x0521, nextMPS: 5, nextLPS: 29, switchMPS: false),
    MQState(qe: 0x0221, nextMPS: 38, nextLPS: 33, switchMPS: false),
    MQState(qe: 0x5601, nextMPS: 7, nextLPS: 6, switchMPS: true),
    MQState(qe: 0x5401, nextMPS: 8, nextLPS: 14, switchMPS: false),
    MQState(qe: 0x4801, nextMPS: 9, nextLPS: 14, switchMPS: false),
    MQState(qe: 0x3801, nextMPS: 10, nextLPS: 14, switchMPS: false),
    MQState(qe: 0x3001, nextMPS: 11, nextLPS: 17, switchMPS: false),
    MQState(qe: 0x2401, nextMPS: 12, nextLPS: 18, switchMPS: false),
    MQState(qe: 0x1C01, nextMPS: 13, nextLPS: 20, switchMPS: false),
    MQState(qe: 0x1601, nextMPS: 29, nextLPS: 21, switchMPS: false),
    MQState(qe: 0x5601, nextMPS: 15, nextLPS: 14, switchMPS: true),
    MQState(qe: 0x5401, nextMPS: 16, nextLPS: 14, switchMPS: false),
    MQState(qe: 0x5101, nextMPS: 17, nextLPS: 15, switchMPS: false),
    MQState(qe: 0x4801, nextMPS: 18, nextLPS: 16, switchMPS: false),
    MQState(qe: 0x3801, nextMPS: 19, nextLPS: 17, switchMPS: false),
    MQState(qe: 0x3401, nextMPS: 20, nextLPS: 18, switchMPS: false),
    MQState(qe: 0x3001, nextMPS: 21, nextLPS: 19, switchMPS: false),
    MQState(qe: 0x2801, nextMPS: 22, nextLPS: 19, switchMPS: false),
    MQState(qe: 0x2401, nextMPS: 23, nextLPS: 20, switchMPS: false),
    MQState(qe: 0x2201, nextMPS: 24, nextLPS: 21, switchMPS: false),
    MQState(qe: 0x1C01, nextMPS: 25, nextLPS: 22, switchMPS: false),
    MQState(qe: 0x1801, nextMPS: 26, nextLPS: 23, switchMPS: false),
    MQState(qe: 0x1601, nextMPS: 27, nextLPS: 24, switchMPS: false),
    MQState(qe: 0x1401, nextMPS: 28, nextLPS: 25, switchMPS: false),
    MQState(qe: 0x1201, nextMPS: 29, nextLPS: 26, switchMPS: false),
    MQState(qe: 0x1101, nextMPS: 30, nextLPS: 27, switchMPS: false),
    MQState(qe: 0x0AC1, nextMPS: 31, nextLPS: 28, switchMPS: false),
    MQState(qe: 0x09C1, nextMPS: 32, nextLPS: 29, switchMPS: false),
    MQState(qe: 0x08A1, nextMPS: 33, nextLPS: 30, switchMPS: false),
    MQState(qe: 0x0521, nextMPS: 34, nextLPS: 31, switchMPS: false),
    MQState(qe: 0x0441, nextMPS: 35, nextLPS: 32, switchMPS: false),
    MQState(qe: 0x02A1, nextMPS: 36, nextLPS: 33, switchMPS: false),
    MQState(qe: 0x0221, nextMPS: 37, nextLPS: 34, switchMPS: false),
    MQState(qe: 0x0141, nextMPS: 38, nextLPS: 35, switchMPS: false),
    MQState(qe: 0x0111, nextMPS: 39, nextLPS: 36, switchMPS: false),
    MQState(qe: 0x0085, nextMPS: 40, nextLPS: 37, switchMPS: false),
    MQState(qe: 0x0049, nextMPS: 41, nextLPS: 38, switchMPS: false),
    MQState(qe: 0x0025, nextMPS: 42, nextLPS: 39, switchMPS: false),
    MQState(qe: 0x0015, nextMPS: 43, nextLPS: 40, switchMPS: false),
    MQState(qe: 0x0009, nextMPS: 44, nextLPS: 41, switchMPS: false),
    MQState(qe: 0x0005, nextMPS: 45, nextLPS: 42, switchMPS: false),
    MQState(qe: 0x0001, nextMPS: 45, nextLPS: 43, switchMPS: false),
    MQState(qe: 0x5601, nextMPS: 46, nextLPS: 46, switchMPS: false)
]

/// Adaptive context: a state-table index and the current more probable symbol.
struct MQContext: Sendable {
    var stateIndex: UInt8
    var mps: Bool
    init(stateIndex: UInt8 = 0, mps: Bool = false) {
        self.stateIndex = stateIndex; self.mps = mps
    }
}

/// MQ encoder producing a default-terminated codeword segment.
struct MQEncoder: Sendable {
    private var c: UInt32 = 0
    private var a: UInt32 = 0x8000
    private var ct = 12
    private var buffer = -1
    private var output: [UInt8] = []
    private let maximumOutputBytes: Int
    private(set) var overflowed = false

    init(capacityHint: Int = 256, maximumOutputBytes: Int = Int.max) {
        self.maximumOutputBytes = maximumOutputBytes
        let reserved = min(max(capacityHint, 16), max(0, maximumOutputBytes))
        if reserved > 0 {
            output.reserveCapacity(reserved)
        }
    }

    @inline(__always)
    private mutating func emitByte(_ byte: UInt8) {
        guard output.count < maximumOutputBytes else {
            overflowed = true
            return
        }
        output.append(byte)
    }

    /// CODEMPS / CODELPS (C.2.4, C.2.6).
    @inline(__always)
    mutating func encode(_ symbol: Bool, context: inout MQContext) {
        let state = mqStateTable[Int(context.stateIndex)]
        let qe = state.qe
        a &-= qe
        if symbol == context.mps {
            if a & 0x8000 == 0 {
                if a < qe { a = qe } else { c &+= qe }
                context.stateIndex = state.nextMPS
                renormalise()
            } else {
                c &+= qe
            }
        } else {
            if a < qe { c &+= qe } else { a = qe }
            if state.switchMPS { context.mps.toggle() }
            context.stateIndex = state.nextLPS
            renormalise()
        }
    }

    @inline(__always)
    private mutating func renormalise() {
        repeat {
            a <<= 1; c <<= 1; ct -= 1
            if ct == 0 { byteOut() }
        } while a & 0x8000 == 0
    }

    /// BYTEOUT (C.2.8, Figure C.7).
    private mutating func byteOut() {
        if buffer >= 0 {
            if buffer == 0xFF {
                emitByte(0xFF)
                buffer = Int((c >> 20) & 0xFF)
                c &= 0x000F_FFFF
                ct = 7
            } else {
                buffer += Int(c >> 27)
                c &= 0x07FF_FFFF
                emitByte(UInt8(buffer & 0xFF))
                if buffer == 0xFF {
                    buffer = Int((c >> 20) & 0xFF)
                    c &= 0x000F_FFFF
                    ct = 7
                } else {
                    buffer = Int((c >> 19) & 0xFF)
                    c &= 0x0007_FFFF
                    ct = 8
                }
            }
        } else {
            // First byte: there is no previous byte for a carry to land in.
            c &= 0x07FF_FFFF
            buffer = Int((c >> 19) & 0xFF)
            c &= 0x0007_FFFF
            ct = 8
        }
    }

    /// FLUSH with SETBITS (C.2.9, Figure C.11). Trailing 0xFF bytes are dropped
    /// because a decoder feeds 0xFF past the end of the segment.
    mutating func finish() -> [UInt8] {
        let limit = c &+ a
        c |= 0x0000_FFFF
        if c >= limit { c &-= 0x8000 }
        c <<= UInt32(ct); byteOut()
        c <<= UInt32(ct); byteOut()
        if buffer >= 0 && buffer != 0xFF { emitByte(UInt8(buffer & 0xFF)) }
        while let last = output.last, last == 0xFF { output.removeLast() }
        return output
    }
}

/// MQ decoder over one codeword segment. Reading past the segment feeds 0xFF,
/// as Annex C requires, so a corrupt length never reads outside the segment.
struct MQDecoder: Sendable {
    private let bytes: [UInt8]
    private let start: Int
    private let end: Int
    private var position: Int
    private var c: UInt32 = 0
    private var a: UInt32 = 0x8000
    private var ct = 0
    private var buffer: UInt8 = 0

    /// `bytes[start..<end]` is the segment. The array is retained by value.
    init(bytes: [UInt8], start: Int, end: Int) throws {
        guard start >= 0, start <= end, end <= bytes.count else {
            throw CodecError(.malformedInput, "Code-block segment lies outside the tile data.")
        }
        self.bytes = bytes; self.start = start; self.end = end; self.position = start
        buffer = readByte()
        c = UInt32(buffer) << 16
        byteIn()
        c <<= 7
        ct -= 7
        a = 0x8000
    }

    @inline(__always)
    private mutating func readByte() -> UInt8 {
        guard position < end else { return 0xFF }
        let value = bytes[position]
        position += 1
        return value
    }

    /// BYTEIN (C.3.4). The marker guard never consumes a byte above 0x8F.
    @inline(__always)
    private mutating func byteIn() {
        if buffer == 0xFF {
            let next: UInt8 = position < end ? bytes[position] : 0xFF
            if next > 0x8F {
                c &+= 0xFF00
                ct = 8
            } else {
                position += 1
                buffer = next
                c &+= UInt32(next) << 9
                ct = 7
            }
        } else {
            buffer = readByte()
            c &+= UInt32(buffer) << 8
            ct = 8
        }
    }

    /// DECODE (C.3.2) using the "chigh" comparison convention.
    @inline(__always)
    mutating func decode(context: inout MQContext) -> Bool {
        let state = mqStateTable[Int(context.stateIndex)]
        let qe = state.qe
        a &-= qe
        let symbol: Bool
        if (c >> 16) < qe {
            if a < qe {
                a = qe
                symbol = context.mps
                context.stateIndex = state.nextMPS
            } else {
                a = qe
                symbol = !context.mps
                if state.switchMPS { context.mps.toggle() }
                context.stateIndex = state.nextLPS
            }
            renormalise()
        } else {
            c &-= qe << 16
            if a & 0x8000 == 0 {
                if a < qe {
                    symbol = !context.mps
                    if state.switchMPS { context.mps.toggle() }
                    context.stateIndex = state.nextLPS
                } else {
                    symbol = context.mps
                    context.stateIndex = state.nextMPS
                }
                renormalise()
            } else {
                symbol = context.mps
            }
        }
        return symbol
    }

    @inline(__always)
    private mutating func renormalise() {
        repeat {
            if ct == 0 { byteIn() }
            a <<= 1; c <<= 1; ct -= 1
        } while a & 0x8000 == 0
    }
}
