// SPDX-License-Identifier: MIT
//
// Conformant ISO/IEC 15444-2 (ITU-T T.801) Annex A.3.7–A.3.10, Annex I, and Annex J
// 2D multi-component transform syntax and execution for SwiftJ2K.

import Foundation

/// Component bit depth definition segment (`CBD`, `0xFF78`, ISO/IEC 15444-2 Annex A.3.7 / I.2.1).
struct ComponentBitDepthSegment: Sendable, Equatable {
    struct Component: Sendable, Equatable {
        let signed: Bool
        let precision: Int
    }

    let components: [Component]

    init(components: [Component]) throws {
        guard !components.isEmpty && components.count <= 16_384 else {
            throw CodecError(.malformedInput, "CBD marker component count (\(components.count)) is outside 1...16384.")
        }
        for (index, component) in components.enumerated() {
            guard (1...38).contains(component.precision) else {
                throw CodecError(
                    .malformedInput,
                    "CBD component \(index) precision (\(component.precision)) is outside 1...38."
                )
            }
        }
        self.components = components
    }

    var isUniform: Bool {
        guard let first = components.first else { return true }
        return components.dropFirst().allSatisfy { $0 == first }
    }

    static func parse(_ payload: [UInt8]) throws -> ComponentBitDepthSegment {
        guard payload.count >= 3 else {
            throw CodecError(.malformedInput, "CBD marker segment is shorter than 3 bytes.")
        }
        var reader = ByteReader(payload)
        let ncbd = try reader.readUInt16()
        let uniform = (ncbd & 0x8000) != 0
        let count = Int(ncbd & 0x7FFF)
        guard count >= 1 && count <= 16_384 else {
            throw CodecError(.malformedInput, "CBD marker Ncbd count (\(count)) is outside 1...16384.")
        }
        if uniform {
            guard payload.count == 3 else {
                throw CodecError(.malformedInput, "Uniform CBD marker segment length (\(payload.count)) must be 3 bytes.")
            }
            let raw = try reader.readUInt8()
            let comp = Component(signed: (raw & 0x80) != 0, precision: Int(raw & 0x7F) + 1)
            return try ComponentBitDepthSegment(components: Array(repeating: comp, count: count))
        } else {
            let expectedLength = try checkedAdd(2, count)
            guard payload.count == expectedLength else {
                throw CodecError(
                    .malformedInput,
                    "Per-component CBD marker segment length (\(payload.count)) disagrees with Ncbd (\(count))."
                )
            }
            var parsed: [Component] = []
            parsed.reserveCapacity(count)
            for _ in 0..<count {
                let raw = try reader.readUInt8()
                parsed.append(Component(signed: (raw & 0x80) != 0, precision: Int(raw & 0x7F) + 1))
            }
            return try ComponentBitDepthSegment(components: parsed)
        }
    }

    func serialiseBody(preferUniform: Bool = false) -> [UInt8] {
        let count = UInt16(components.count)
        if preferUniform, isUniform, let first = components.first {
            let ncbd = UInt16(0x8000) | count
            let bd = (first.signed ? UInt8(0x80) : 0) | UInt8(first.precision - 1)
            return [UInt8(ncbd >> 8), UInt8(ncbd & 0xFF), bd]
        }
        var out: [UInt8] = []
        out.reserveCapacity(2 + components.count)
        out.append(UInt8(count >> 8))
        out.append(UInt8(count & 0xFF))
        for component in components {
            let bd = (component.signed ? UInt8(0x80) : 0) | UInt8(component.precision - 1)
            out.append(bd)
        }
        return out
    }
}

/// Array semantics in `MCT` (`Imct` bits 8...9, ISO/IEC 15444-2 Table A.33).
enum Part2MCTArrayType: UInt8, Sendable, Equatable {
    case dependency    = 0
    case decorrelation = 1
    case offset        = 2
}

/// Element representation in `MCT` (`Imct` bits 10...11, ISO/IEC 15444-2 Table A.33).
enum Part2MCTElementType: UInt8, Sendable, Equatable {
    case int16   = 0
    case int32   = 1
    case float32 = 2
    case float64 = 3

    var byteSize: Int {
        switch self {
        case .int16: return 2
        case .int32, .float32: return 4
        case .float64: return 8
        }
    }

    var isInteger: Bool {
        self == .int16 || self == .int32
    }
}

/// Raw `MCT` (`0xFF74`) marker segment fragment prior to `Zmct = 0...Ymct` assembly.
struct Part2MCTSegmentFragment: Sendable, Equatable {
    let segmentIndex: Int      // Zmct
    let tableIndex: Int        // Imct & 0xFF (1...255)
    let arrayType: Part2MCTArrayType
    let elementType: Part2MCTElementType
    let lastSegmentIndex: Int? // Ymct (present iff Zmct == 0)
    let rawBytes: [UInt8]      // SPmct fragment

    var imctWord: UInt16 {
        UInt16(tableIndex & 0xFF)
            | (UInt16(arrayType.rawValue) << 8)
            | (UInt16(elementType.rawValue) << 10)
    }

    static func parse(_ payload: [UInt8]) throws -> Part2MCTSegmentFragment {
        guard payload.count >= 5 else {
            throw CodecError(.malformedInput, "MCT marker segment is shorter than minimum header.")
        }
        var reader = ByteReader(payload)
        let zmct = Int(try reader.readUInt16())
        let imct = try reader.readUInt16()
        guard (imct & 0xF000) == 0 else {
            throw CodecError(.malformedInput, "MCT marker Imct reserved upper bits (0x\(String(imct, radix: 16))) are non-zero.")
        }
        let tableIndex = Int(imct & 0x00FF)
        guard (1...255).contains(tableIndex) else {
            throw CodecError(.malformedInput, "MCT marker table index (\(tableIndex)) must be in 1...255.")
        }
        let arrayRaw = UInt8((imct >> 8) & 0x03)
        guard let arrayType = Part2MCTArrayType(rawValue: arrayRaw) else {
            throw CodecError(.malformedInput, "MCT marker Imct specifies reserved array type 3.")
        }
        let elemRaw = UInt8((imct >> 10) & 0x03)
        guard let elementType = Part2MCTElementType(rawValue: elemRaw) else {
            throw CodecError(.malformedInput, "MCT marker Imct specifies invalid element type \(elemRaw).")
        }
        let ymct: Int?
        let headerBytes: Int
        if zmct == 0 {
            guard payload.count > 6 else {
                throw CodecError(.malformedInput, "Initial MCT marker segment (Zmct=0) contains no SPmct payload bytes.")
            }
            ymct = Int(try reader.readUInt16())
            headerBytes = 6
        } else {
            ymct = nil
            headerBytes = 4
        }
        let rawBytes = Array(payload[headerBytes..<payload.count])
        guard !rawBytes.isEmpty else {
            throw CodecError(.malformedInput, "MCT marker segment contains an empty SPmct payload.")
        }
        return Part2MCTSegmentFragment(
            segmentIndex: zmct,
            tableIndex: tableIndex,
            arrayType: arrayType,
            elementType: elementType,
            lastSegmentIndex: ymct,
            rawBytes: rawBytes
        )
    }

    func serialiseBody() throws -> [UInt8] {
        var out: [UInt8] = []
        let headerLen = (segmentIndex == 0) ? 6 : 4
        let total = try checkedAdd(headerLen, rawBytes.count)
        guard total <= 65_533 else {
            throw CodecError(.invalidArgument, "MCT segment body (\(total) bytes) exceeds single-segment limit.")
        }
        out.reserveCapacity(total)
        let zmct16 = UInt16(segmentIndex)
        let imct16 = imctWord
        out.append(UInt8(zmct16 >> 8))
        out.append(UInt8(zmct16 & 0xFF))
        out.append(UInt8(imct16 >> 8))
        out.append(UInt8(imct16 & 0xFF))
        if segmentIndex == 0 {
            let ymct16 = UInt16(lastSegmentIndex ?? 0)
            out.append(UInt8(ymct16 >> 8))
            out.append(UInt8(ymct16 & 0xFF))
        }
        out.append(contentsOf: rawBytes)
        return out
    }
}

/// Assembled `MCT` (`0xFF74`) coefficient or offset array for one `(arrayType, tableIndex)` key.
struct Part2MCTTable: Sendable, Equatable {
    struct Key: Hashable, Sendable {
        let arrayType: Part2MCTArrayType
        let tableIndex: Int
    }

    let tableIndex: Int
    let arrayType: Part2MCTArrayType
    let elementType: Part2MCTElementType
    let integerValues: [Int64]
    let floatValues: [Double]

    var key: Key { Key(arrayType: arrayType, tableIndex: tableIndex) }

    var elementCount: Int {
        elementType.isInteger ? integerValues.count : floatValues.count
    }

    func valueAsDouble(at index: Int) -> Double {
        elementType.isInteger ? Double(integerValues[index]) : floatValues[index]
    }

    func valueAsInt64(at index: Int) throws -> Int64 {
        if elementType.isInteger {
            return integerValues[index]
        }
        let v = floatValues[index]
        guard v.isFinite, v.rounded(.towardZero) == v,
              v >= Double(Int32.min), v <= Double(Int32.max) else {
            throw CodecError(
                .malformedInput,
                "Reversible Part 2 MCT stage references non-integer value (\(v)) in MCT table \(tableIndex)."
            )
        }
        return Int64(v)
    }

    static func assemble(
        fragments: [Part2MCTSegmentFragment],
        admitMetadataBytes: (Int) throws -> Void
    ) throws -> [Key: Part2MCTTable] {
        if fragments.isEmpty { return [:] }

        // Group fragments into contiguous or interleaved series keyed by (arrayType, tableIndex).
        // Within a single header scope, redefining the same (arrayType, tableIndex) with a second Zmct=0
        // segment is rejected as malformed; tile-part 0 overrides main-header tables via separate scopes.
        struct SeriesBuilder {
            var elementType: Part2MCTElementType
            var expectedLastIndex: Int?
            var parts: [Int: [UInt8]] = [:]
        }

        var builders: [Key: SeriesBuilder] = [:]
        for fragment in fragments {
            let key = Key(arrayType: fragment.arrayType, tableIndex: fragment.tableIndex)
            if fragment.segmentIndex == 0 {
                guard builders[key] == nil else {
                    throw CodecError(
                        .malformedInput,
                        "Duplicate MCT Zmct=0 table definition for (\(fragment.arrayType), \(fragment.tableIndex)) in the same header."
                    )
                }
                builders[key] = SeriesBuilder(
                    elementType: fragment.elementType,
                    expectedLastIndex: fragment.lastSegmentIndex,
                    parts: [0: fragment.rawBytes]
                )
            } else {
                guard var existing = builders[key] else {
                    throw CodecError(
                        .malformedInput,
                        "MCT marker segment Zmct=\(fragment.segmentIndex) encountered before Zmct=0 for table \(fragment.tableIndex)."
                    )
                }
                guard existing.elementType == fragment.elementType else {
                    throw CodecError(
                        .malformedInput,
                        "MCT marker segment series for table \(fragment.tableIndex) changes element type mid-series."
                    )
                }
                guard existing.parts[fragment.segmentIndex] == nil else {
                    throw CodecError(
                        .malformedInput,
                        "Duplicate MCT marker segment index Zmct=\(fragment.segmentIndex) for table \(fragment.tableIndex)."
                    )
                }
                existing.parts[fragment.segmentIndex] = fragment.rawBytes
                builders[key] = existing
            }
        }

        var result: [Key: Part2MCTTable] = [:]
        for (key, builder) in builders {
            guard let ymct = builder.expectedLastIndex else {
                throw CodecError(.malformedInput, "MCT table \(key.tableIndex) is missing initial Zmct=0 segment.")
            }
            let expectedCount = try checkedAdd(ymct, 1)
            guard builder.parts.count == expectedCount else {
                throw CodecError(
                    .malformedInput,
                    "MCT table \(key.tableIndex) expected \(expectedCount) segment(s) (Ymct=\(ymct)), found \(builder.parts.count)."
                )
            }
            var totalBytes = 0
            for z in 0...ymct {
                guard let part = builder.parts[z] else {
                    throw CodecError(.malformedInput, "MCT table \(key.tableIndex) is missing segment Zmct=\(z).")
                }
                totalBytes = try checkedAdd(totalBytes, part.count)
            }
            try admitMetadataBytes(totalBytes)
            let elemBytes = builder.elementType.byteSize
            guard totalBytes >= elemBytes && totalBytes % elemBytes == 0 else {
                throw CodecError(
                    .malformedInput,
                    "MCT table \(key.tableIndex) byte count (\(totalBytes)) is not a positive multiple of element size (\(elemBytes))."
                )
            }
            var assembled: [UInt8] = []
            assembled.reserveCapacity(totalBytes)
            for z in 0...ymct {
                assembled.append(contentsOf: builder.parts[z]!)
            }
            let count = totalBytes / elemBytes
            var reader = ByteReader(assembled)
            var ints: [Int64] = []
            var floats: [Double] = []
            if builder.elementType.isInteger {
                ints.reserveCapacity(count)
                for _ in 0..<count {
                    switch builder.elementType {
                    case .int16:
                        let raw = try reader.readUInt16()
                        ints.append(Int64(Int16(bitPattern: raw)))
                    case .int32:
                        let raw = try reader.readUInt32()
                        ints.append(Int64(Int32(bitPattern: raw)))
                    case .float32, .float64:
                        break
                    }
                }
            } else {
                floats.reserveCapacity(count)
                for _ in 0..<count {
                    let val: Double
                    switch builder.elementType {
                    case .float32:
                        let raw = try reader.readUInt32()
                        val = Double(Float(bitPattern: raw))
                    case .float64:
                        let hi = UInt64(try reader.readUInt32())
                        let lo = UInt64(try reader.readUInt32())
                        val = Double(bitPattern: (hi << 32) | lo)
                    case .int16, .int32:
                        val = 0
                    }
                    guard val.isFinite else {
                        throw CodecError(.malformedInput, "MCT table \(key.tableIndex) contains non-finite floating-point coefficient.")
                    }
                    floats.append(val)
                }
            }
            result[key] = Part2MCTTable(
                tableIndex: key.tableIndex,
                arrayType: key.arrayType,
                elementType: builder.elementType,
                integerValues: ints,
                floatValues: floats
            )
        }
        return result
    }

    func serialiseFragments(maxPayloadBytesPerSegment: Int = 65_520) throws -> [Part2MCTSegmentFragment] {
        let elemSize = elementType.byteSize
        let count = elementCount
        let totalBytes = try checkedMultiply(count, elemSize)
        var raw: [UInt8] = []
        raw.reserveCapacity(totalBytes)
        if elementType.isInteger {
            for v in integerValues {
                switch elementType {
                case .int16:
                    guard v >= Int64(Int16.min) && v <= Int64(Int16.max) else {
                        throw CodecError(.invalidArgument, "MCT int16 value \(v) overflows Int16.")
                    }
                    let u = UInt16(bitPattern: Int16(v))
                    raw.append(UInt8(u >> 8))
                    raw.append(UInt8(u & 0xFF))
                case .int32:
                    guard v >= Int64(Int32.min) && v <= Int64(Int32.max) else {
                        throw CodecError(.invalidArgument, "MCT int32 value \(v) overflows Int32.")
                    }
                    let u = UInt32(bitPattern: Int32(v))
                    raw.append(UInt8((u >> 24) & 0xFF))
                    raw.append(UInt8((u >> 16) & 0xFF))
                    raw.append(UInt8((u >> 8) & 0xFF))
                    raw.append(UInt8(u & 0xFF))
                case .float32, .float64:
                    break
                }
            }
        } else {
            for v in floatValues {
                switch elementType {
                case .float32:
                    let u = Float(v).bitPattern
                    raw.append(UInt8((u >> 24) & 0xFF))
                    raw.append(UInt8((u >> 16) & 0xFF))
                    raw.append(UInt8((u >> 8) & 0xFF))
                    raw.append(UInt8(u & 0xFF))
                case .float64:
                    let u = v.bitPattern
                    for shift in stride(from: 56, through: 0, by: -8) {
                        raw.append(UInt8((u >> shift) & 0xFF))
                    }
                case .int16, .int32:
                    break
                }
            }
        }

        let chunkCap = max(elemSize, (maxPayloadBytesPerSegment / elemSize) * elemSize)
        var chunks: [[UInt8]] = []
        var offset = 0
        while offset < raw.count {
            let end = min(raw.count, offset + chunkCap)
            chunks.append(Array(raw[offset..<end]))
            offset = end
        }
        let ymct = chunks.count - 1
        return chunks.enumerated().map { z, bytes in
            Part2MCTSegmentFragment(
                segmentIndex: z,
                tableIndex: tableIndex,
                arrayType: arrayType,
                elementType: elementType,
                lastSegmentIndex: (z == 0) ? ymct : nil,
                rawBytes: bytes
            )
        }
    }
}

/// Collection decorrelation mode (`Xmcc`, ISO/IEC 15444-2 Table A.36).
enum Part2MCCDecorrelationType: UInt8, Sendable, Equatable {
    case dependency = 0
    case matrix     = 1
}

/// Raw `MCC` (`0xFF75`) marker segment fragment prior to `Zmcc = 0...Ymcc` assembly.
struct Part2MCCSegmentFragment: Sendable, Equatable {
    let segmentIndex: Int      // Zmcc (UInt16)
    let stageIndex: Int        // Imcc (UInt8, 1...255)
    let lastSegmentIndex: Int? // Ymcc (UInt16, present iff Zmcc == 0)
    let collectionCount: Int?  // Qmcc (UInt16, present iff Zmcc == 0)
    let rawBytes: [UInt8]

    static func parse(_ payload: [UInt8]) throws -> Part2MCCSegmentFragment {
        guard payload.count >= 4 else {
            throw CodecError(.malformedInput, "MCC marker segment is shorter than minimum header.")
        }
        var reader = ByteReader(payload)
        let zmcc = Int(try reader.readUInt16())
        let imcc = Int(try reader.readUInt8())
        guard (1...255).contains(imcc) else {
            throw CodecError(.malformedInput, "MCC marker stage index Imcc (\(imcc)) must be in 1...255.")
        }
        if zmcc == 0 {
            guard payload.count > 7 else {
                throw CodecError(.malformedInput, "Initial MCC marker segment (Zmcc=0) is truncated.")
            }
            let ymcc = Int(try reader.readUInt16())
            let qmcc = Int(try reader.readUInt16())
            guard qmcc >= 1 else {
                throw CodecError(.malformedInput, "MCC marker Qmcc collection count must be >= 1.")
            }
            return Part2MCCSegmentFragment(
                segmentIndex: 0,
                stageIndex: imcc,
                lastSegmentIndex: ymcc,
                collectionCount: qmcc,
                rawBytes: Array(payload[7..<payload.count])
            )
        } else {
            return Part2MCCSegmentFragment(
                segmentIndex: zmcc,
                stageIndex: imcc,
                lastSegmentIndex: nil,
                collectionCount: nil,
                rawBytes: Array(payload[3..<payload.count])
            )
        }
    }

    func serialiseBody() throws -> [UInt8] {
        let headerLen = (segmentIndex == 0) ? 7 : 3
        let total = try checkedAdd(headerLen, rawBytes.count)
        guard total <= 65_533 else {
            throw CodecError(.invalidArgument, "MCC segment body (\(total) bytes) exceeds single-segment limit.")
        }
        var out: [UInt8] = []
        out.reserveCapacity(total)
        let zmcc16 = UInt16(segmentIndex)
        out.append(UInt8(zmcc16 >> 8))
        out.append(UInt8(zmcc16 & 0xFF))
        out.append(UInt8(stageIndex & 0xFF))
        if segmentIndex == 0 {
            let ymcc16 = UInt16(lastSegmentIndex ?? 0)
            let qmcc16 = UInt16(collectionCount ?? 1)
            out.append(UInt8(ymcc16 >> 8))
            out.append(UInt8(ymcc16 & 0xFF))
            out.append(UInt8(qmcc16 >> 8))
            out.append(UInt8(qmcc16 & 0xFF))
        }
        out.append(contentsOf: rawBytes)
        return out
    }
}

/// One component collection within an `MCC` (`0xFF75`) stage.
struct Part2MCCCollection: Sendable, Equatable {
    let decorrelationType: Part2MCCDecorrelationType
    let inputComponents: [Int]
    let outputComponents: [Int]
    let reversible: Bool
    let offsetTableIndex: Int    // 0 = none
    let transformTableIndex: Int // 0 = identity/null transform
}

/// Assembled `MCC` (`0xFF75`) transform stage (`Imcc`).
struct Part2MCCStage: Sendable, Equatable {
    let stageIndex: Int
    let collections: [Part2MCCCollection]

    static func assemble(
        fragments: [Part2MCCSegmentFragment],
        admitMetadataBytes: (Int) throws -> Void
    ) throws -> [Int: Part2MCCStage] {
        if fragments.isEmpty { return [:] }

        struct StageBuilder {
            var expectedLastIndex: Int
            var collectionCount: Int
            var parts: [Int: [UInt8]]
        }

        var builders: [Int: StageBuilder] = [:]
        for fragment in fragments {
            if fragment.segmentIndex == 0 {
                guard builders[fragment.stageIndex] == nil else {
                    throw CodecError(
                        .malformedInput,
                        "Duplicate MCC Zmcc=0 stage definition for stage \(fragment.stageIndex) in the same header."
                    )
                }
                guard let ymcc = fragment.lastSegmentIndex,
                      let qmcc = fragment.collectionCount else {
                    throw CodecError(.malformedInput, "Initial MCC segment is missing Ymcc or Qmcc.")
                }
                builders[fragment.stageIndex] = StageBuilder(
                    expectedLastIndex: ymcc,
                    collectionCount: qmcc,
                    parts: [0: fragment.rawBytes]
                )
            } else {
                guard var existing = builders[fragment.stageIndex] else {
                    throw CodecError(
                        .malformedInput,
                        "MCC marker segment Zmcc=\(fragment.segmentIndex) encountered before Zmcc=0 for stage \(fragment.stageIndex)."
                    )
                }
                guard existing.parts[fragment.segmentIndex] == nil else {
                    throw CodecError(
                        .malformedInput,
                        "Duplicate MCC marker segment index Zmcc=\(fragment.segmentIndex) for stage \(fragment.stageIndex)."
                    )
                }
                existing.parts[fragment.segmentIndex] = fragment.rawBytes
                builders[fragment.stageIndex] = existing
            }
        }

        var stages: [Int: Part2MCCStage] = [:]
        for (stageIndex, builder) in builders {
            let expectedParts = try checkedAdd(builder.expectedLastIndex, 1)
            guard builder.parts.count == expectedParts else {
                throw CodecError(
                    .malformedInput,
                    "MCC stage \(stageIndex) expected \(expectedParts) segment(s) (Ymcc=\(builder.expectedLastIndex)), found \(builder.parts.count)."
                )
            }
            var totalBytes = 0
            for z in 0...builder.expectedLastIndex {
                guard let part = builder.parts[z] else {
                    throw CodecError(.malformedInput, "MCC stage \(stageIndex) is missing segment Zmcc=\(z).")
                }
                totalBytes = try checkedAdd(totalBytes, part.count)
            }
            try admitMetadataBytes(totalBytes)
            var payload: [UInt8] = []
            payload.reserveCapacity(totalBytes)
            for z in 0...builder.expectedLastIndex {
                payload.append(contentsOf: builder.parts[z]!)
            }

            var reader = ByteReader(payload)
            var collections: [Part2MCCCollection] = []
            collections.reserveCapacity(builder.collectionCount)
            var seenStageOutputs = Set<Int>()

            for _ in 0..<builder.collectionCount {
                let xmcc = try reader.readUInt8()
                if xmcc == 2 || xmcc == 3 {
                    throw CodecError(
                        .unsupportedFeature,
                        "Part 2 wavelet-based multi-component transform (MCC Xmcc=\(xmcc)) is not supported."
                    )
                }
                guard let decorrelation = Part2MCCDecorrelationType(rawValue: xmcc) else {
                    throw CodecError(.malformedInput, "MCC collection specifies invalid Xmcc value \(xmcc).")
                }

                let nmccRaw = try reader.readUInt16()
                let wideIn = (nmccRaw & 0x8000) != 0
                let inCount = Int(nmccRaw & 0x7FFF)
                guard inCount >= 1 && inCount <= 16_384 else {
                    throw CodecError(.malformedInput, "MCC collection Nmcc input count (\(inCount)) is outside 1...16384.")
                }
                var inputs: [Int] = []
                inputs.reserveCapacity(inCount)
                for _ in 0..<inCount {
                    let idx = wideIn ? Int(try reader.readUInt16()) : Int(try reader.readUInt8())
                    inputs.append(idx)
                }

                let mmccRaw = try reader.readUInt16()
                let wideOut = (mmccRaw & 0x8000) != 0
                let outCount = Int(mmccRaw & 0x7FFF)
                guard outCount >= 1 && outCount <= 16_384 else {
                    throw CodecError(.malformedInput, "MCC collection Mmcc output count (\(outCount)) is outside 1...16384.")
                }
                var outputs: [Int] = []
                outputs.reserveCapacity(outCount)
                for _ in 0..<outCount {
                    let idx = wideOut ? Int(try reader.readUInt16()) : Int(try reader.readUInt8())
                    guard seenStageOutputs.insert(idx).inserted else {
                        throw CodecError(
                            .malformedInput,
                            "MCC stage \(stageIndex) assigns output component \(idx) more than once."
                        )
                    }
                    outputs.append(idx)
                }

                let b0 = try reader.readUInt8()
                let b1 = try reader.readUInt8()
                let b2 = try reader.readUInt8()
                guard (b0 & 0xFE) == 0 else {
                    throw CodecError(.malformedInput, "MCC collection Tmcc reserved upper bits (0x\(String(b0, radix: 16))) are non-zero.")
                }
                let reversible = (b0 & 0x01) != 0
                collections.append(
                    Part2MCCCollection(
                        decorrelationType: decorrelation,
                        inputComponents: inputs,
                        outputComponents: outputs,
                        reversible: reversible,
                        offsetTableIndex: Int(b1),
                        transformTableIndex: Int(b2)
                    )
                )
            }
            guard reader.remaining == 0 else {
                throw CodecError(
                    .malformedInput,
                    "MCC stage \(stageIndex) has \(reader.remaining) unconsumed trailing byte(s)."
                )
            }
            stages[stageIndex] = Part2MCCStage(stageIndex: stageIndex, collections: collections)
        }
        return stages
    }

    func serialiseFragments(maxPayloadBytesPerSegment: Int = 65_520) throws -> [Part2MCCSegmentFragment] {
        var raw: [UInt8] = []
        for coll in collections {
            raw.append(coll.decorrelationType.rawValue)
            let wideIn = coll.inputComponents.contains { $0 > 255 }
            let nmcc = (wideIn ? UInt16(0x8000) : 0) | UInt16(coll.inputComponents.count)
            raw.append(UInt8(nmcc >> 8))
            raw.append(UInt8(nmcc & 0xFF))
            for idx in coll.inputComponents {
                if wideIn {
                    let u = UInt16(idx)
                    raw.append(UInt8(u >> 8))
                    raw.append(UInt8(u & 0xFF))
                } else {
                    raw.append(UInt8(idx))
                }
            }
            let wideOut = coll.outputComponents.contains { $0 > 255 }
            let mmcc = (wideOut ? UInt16(0x8000) : 0) | UInt16(coll.outputComponents.count)
            raw.append(UInt8(mmcc >> 8))
            raw.append(UInt8(mmcc & 0xFF))
            for idx in coll.outputComponents {
                if wideOut {
                    let u = UInt16(idx)
                    raw.append(UInt8(u >> 8))
                    raw.append(UInt8(u & 0xFF))
                } else {
                    raw.append(UInt8(idx))
                }
            }
            raw.append(coll.reversible ? 1 : 0)
            raw.append(UInt8(coll.offsetTableIndex & 0xFF))
            raw.append(UInt8(coll.transformTableIndex & 0xFF))
        }

        let cap = max(16, maxPayloadBytesPerSegment)
        var chunks: [[UInt8]] = []
        var offset = 0
        while offset < raw.count {
            let end = min(raw.count, offset + cap)
            chunks.append(Array(raw[offset..<end]))
            offset = end
        }
        let ymcc = chunks.count - 1
        return chunks.enumerated().map { z, bytes in
            Part2MCCSegmentFragment(
                segmentIndex: z,
                stageIndex: stageIndex,
                lastSegmentIndex: (z == 0) ? ymcc : nil,
                collectionCount: (z == 0) ? collections.count : nil,
                rawBytes: bytes
            )
        }
    }
}

/// Multiple component transform ordering segment (`MCO`, `0xFF77`, ISO/IEC 15444-2 Annex A.3.10).
struct Part2MCOSegment: Sendable, Equatable {
    let stageIndices: [Int]

    static func parse(_ payload: [UInt8]) throws -> Part2MCOSegment {
        guard let first = payload.first else {
            throw CodecError(.malformedInput, "MCO marker segment is empty.")
        }
        let nmco = Int(first)
        guard payload.count == 1 + nmco else {
            throw CodecError(
                .malformedInput,
                "MCO marker segment length (\(payload.count)) disagrees with Nmco (\(nmco))."
            )
        }
        var stages: [Int] = []
        stages.reserveCapacity(nmco)
        for idx in payload.dropFirst() {
            guard idx != 0 else {
                throw CodecError(.malformedInput, "MCO marker stage reference Imco must be non-zero (1...255).")
            }
            stages.append(Int(idx))
        }
        return Part2MCOSegment(stageIndices: stages)
    }

    func serialiseBody() -> [UInt8] {
        var out: [UInt8] = [UInt8(stageIndices.count)]
        out.reserveCapacity(1 + stageIndices.count)
        for s in stageIndices {
            out.append(UInt8(s & 0xFF))
        }
        return out
    }
}

/// Validated, executable multi-component transform plan for a main header or tile.
struct Part2MCTPlan: Sendable, Equatable {
    struct ResolvedCollection: Sendable, Equatable {
        enum Kernel: Sendable, Equatable {
            case nullTransform
            /// Annex J.2.2.2 reversible dependency transform (`N == M`, integer coefficients + power-of-two divisors).
            case reversibleDependency(rows: [[Int64]], shifts: [Int])
            /// Annex J.2.2.1 irreversible dependency transform (`N == M`, strictly lower-triangular floats).
            case irreversibleDependency(rows: [[Double]])
            /// Annex J.3.2.2 reversible SERM matrix transform (`N == M`, `(M + 1)` integer elementary rows).
            case reversibleSERM(rows: [[Int64]], targetColumns: [Int], shifts: [Int])
            /// Annex J.3.2.1 irreversible `M x N` matrix transform (`M` rows, `N` columns).
            case irreversibleMatrix(rows: Int, cols: Int, elements: [Double])
        }

        let inputComponents: [Int]
        let outputComponents: [Int]
        let reversible: Bool
        let integerOffsets: [Int64]
        let floatOffsets: [Double]
        let kernel: Kernel
    }

    struct ResolvedStage: Sendable, Equatable {
        let stageIndex: Int
        let inputComponentCount: Int
        let outputComponentCount: Int
        let collections: [ResolvedCollection]
    }

    let stages: [ResolvedStage]
    let codestreamComponentCount: Int
    let outputComponentCount: Int
    let isAllReversible: Bool

    var isActive: Bool { !stages.isEmpty }

    private static func powerOfTwoShift(_ divisor: Int64, context: String) throws -> Int {
        guard divisor > 0, (divisor & (divisor - 1)) == 0 else {
            throw CodecError(.malformedInput, "\(context) divisor (\(divisor)) must be a positive power of two.")
        }
        let shift = divisor.trailingZeroBitCount
        guard shift <= 30 else {
            throw CodecError(.malformedInput, "\(context) divisor shift (\(shift)) exceeds 30 bits.")
        }
        return shift
    }

    static func resolve(
        codestreamComponentCount: Int,
        cbd: ComponentBitDepthSegment?,
        mctTables: [Part2MCTTable.Key: Part2MCTTable],
        mccStages: [Int: Part2MCCStage],
        mco: Part2MCOSegment?
    ) throws -> Part2MCTPlan? {
        guard let mco else {
            // If MCT/MCC exist without MCO, no multi-component stages are invoked (Nmco == 0 equivalent).
            return nil
        }
        if mco.stageIndices.isEmpty {
            // Explicit Nmco == 0 disables MCT stages (e.g. tile-part 0 override).
            return nil
        }
        guard let cbd else {
            throw CodecError(
                .malformedInput,
                "Codestream invokes Part 2 MCO multi-component transform stages without a CBD marker segment."
            )
        }

        var currentCount = codestreamComponentCount
        var resolvedStages: [ResolvedStage] = []
        resolvedStages.reserveCapacity(mco.stageIndices.count)
        var allReversible = true

        for (stagePos, stageID) in mco.stageIndices.enumerated() {
            guard let stage = mccStages[stageID] else {
                throw CodecError(
                    .malformedInput,
                    "MCO stage position \(stagePos) references undefined MCC stage \(stageID)."
                )
            }
            var resolvedCollections: [ResolvedCollection] = []
            resolvedCollections.reserveCapacity(stage.collections.count)
            var assignedOutputs = Set<Int>()
            var maxOutputIndex = -1

            for (collIdx, coll) in stage.collections.enumerated() {
                for inComp in coll.inputComponents {
                    guard inComp >= 0 && inComp < currentCount else {
                        throw CodecError(
                            .malformedInput,
                            "MCC stage \(stageID) collection \(collIdx) references out-of-range input component \(inComp) (available 0..<\(currentCount))."
                        )
                    }
                }
                for outComp in coll.outputComponents {
                    guard outComp >= 0, assignedOutputs.insert(outComp).inserted else {
                        throw CodecError(
                            .malformedInput,
                            "MCC stage \(stageID) collection \(collIdx) has invalid or duplicate output component \(outComp)."
                        )
                    }
                    if outComp > maxOutputIndex { maxOutputIndex = outComp }
                }

                let n = coll.inputComponents.count
                let m = coll.outputComponents.count
                if !coll.reversible {
                    allReversible = false
                }

                // Resolve optional offset table (O[0..<M]).
                var intOffsets = Array(repeating: Int64(0), count: m)
                var fltOffsets = Array(repeating: 0.0, count: m)
                if coll.offsetTableIndex != 0 {
                    let offsetKey = Part2MCTTable.Key(arrayType: .offset, tableIndex: coll.offsetTableIndex)
                    guard let offsetTable = mctTables[offsetKey] else {
                        throw CodecError(
                            .malformedInput,
                            "MCC stage \(stageID) collection \(collIdx) references missing MCT offset table \(coll.offsetTableIndex)."
                        )
                    }
                    guard offsetTable.elementCount == m else {
                        throw CodecError(
                            .malformedInput,
                            "MCT offset table \(coll.offsetTableIndex) has \(offsetTable.elementCount) element(s), expected \(m)."
                        )
                    }
                    for k in 0..<m {
                        fltOffsets[k] = offsetTable.valueAsDouble(at: k)
                        if coll.reversible {
                            intOffsets[k] = try offsetTable.valueAsInt64(at: k)
                        }
                    }
                }

                // Resolve transform coefficient table.
                let kernel: ResolvedCollection.Kernel
                if coll.transformTableIndex == 0 {
                    kernel = .nullTransform
                } else {
                    let expectedType: Part2MCTArrayType = (coll.decorrelationType == .dependency) ? .dependency : .decorrelation
                    let tableKey = Part2MCTTable.Key(arrayType: expectedType, tableIndex: coll.transformTableIndex)
                    guard let table = mctTables[tableKey] else {
                        throw CodecError(
                            .malformedInput,
                            "MCC stage \(stageID) collection \(collIdx) references missing MCT \(expectedType) table \(coll.transformTableIndex)."
                        )
                    }

                    switch (coll.decorrelationType, coll.reversible) {
                    case (.dependency, true):
                        guard n == m else {
                            throw CodecError(
                                .malformedInput,
                                "Reversible dependency MCC collection requires N == M, got \(n) -> \(m)."
                            )
                        }
                        let expectedCount = try checkedMultiply(m, m + 1) / 2 - 1
                        guard table.elementCount == expectedCount else {
                            throw CodecError(
                                .malformedInput,
                                "Reversible dependency MCT table \(coll.transformTableIndex) has \(table.elementCount) elements, expected \(expectedCount)."
                            )
                        }
                        var rows: [[Int64]] = [[]]
                        var shifts: [Int] = [0]
                        var cursor = 0
                        if m >= 2 {
                            for k in 1..<m {
                                var coeffs: [Int64] = []
                                coeffs.reserveCapacity(k)
                                for _ in 0..<k {
                                    coeffs.append(try table.valueAsInt64(at: cursor))
                                    cursor += 1
                                }
                                let divisor = try table.valueAsInt64(at: cursor)
                                cursor += 1
                                let shift = try powerOfTwoShift(
                                    divisor,
                                    context: "Reversible dependency MCT table \(coll.transformTableIndex) row \(k)"
                                )
                                rows.append(coeffs)
                                shifts.append(shift)
                            }
                        }
                        kernel = .reversibleDependency(rows: rows, shifts: shifts)

                    case (.dependency, false):
                        guard n == m else {
                            throw CodecError(
                                .malformedInput,
                                "Irreversible dependency MCC collection requires N == M, got \(n) -> \(m)."
                            )
                        }
                        let expectedCount = try checkedMultiply(m, m - 1) / 2
                        guard table.elementCount == expectedCount else {
                            throw CodecError(
                                .malformedInput,
                                "Irreversible dependency MCT table \(coll.transformTableIndex) has \(table.elementCount) elements, expected \(expectedCount)."
                            )
                        }
                        var rows: [[Double]] = [[]]
                        var cursor = 0
                        if m >= 2 {
                            for k in 1..<m {
                                var coeffs: [Double] = []
                                coeffs.reserveCapacity(k)
                                for _ in 0..<k {
                                    coeffs.append(table.valueAsDouble(at: cursor))
                                    cursor += 1
                                }
                                rows.append(coeffs)
                            }
                        }
                        kernel = .irreversibleDependency(rows: rows)

                    case (.matrix, true):
                        guard n == m else {
                            throw CodecError(
                                .malformedInput,
                                "Reversible SERM matrix MCC collection requires N == M, got \(n) -> \(m)."
                            )
                        }
                        let rowCount = m + 1
                        let expectedCount = try checkedMultiply(rowCount, m)
                        guard table.elementCount == expectedCount else {
                            throw CodecError(
                                .malformedInput,
                                "Reversible SERM MCT table \(coll.transformTableIndex) has \(table.elementCount) elements, expected \(expectedCount)."
                            )
                        }
                        var rows: [[Int64]] = []
                        var targets: [Int] = []
                        var shifts: [Int] = []
                        rows.reserveCapacity(rowCount)
                        targets.reserveCapacity(rowCount)
                        shifts.reserveCapacity(rowCount)
                        var cursor = 0
                        for step in 0..<rowCount {
                            var row: [Int64] = []
                            row.reserveCapacity(m)
                            for _ in 0..<m {
                                row.append(try table.valueAsInt64(at: cursor))
                                cursor += 1
                            }
                            let target = (step < m) ? (m - 1 - step) : (m - 1)
                            let shift = try powerOfTwoShift(
                                row[target],
                                context: "Reversible SERM MCT table \(coll.transformTableIndex) step \(step)"
                            )
                            rows.append(row)
                            targets.append(target)
                            shifts.append(shift)
                        }
                        kernel = .reversibleSERM(rows: rows, targetColumns: targets, shifts: shifts)

                    case (.matrix, false):
                        let expectedCount = try checkedMultiply(m, n)
                        guard table.elementCount == expectedCount else {
                            throw CodecError(
                                .malformedInput,
                                "Irreversible matrix MCT table \(coll.transformTableIndex) has \(table.elementCount) elements, expected \(expectedCount) (\(m)x\(n))."
                            )
                        }
                        var elements: [Double] = []
                        elements.reserveCapacity(expectedCount)
                        for idx in 0..<expectedCount {
                            elements.append(table.valueAsDouble(at: idx))
                        }
                        kernel = .irreversibleMatrix(rows: m, cols: n, elements: elements)
                    }
                }

                resolvedCollections.append(
                    ResolvedCollection(
                        inputComponents: coll.inputComponents,
                        outputComponents: coll.outputComponents,
                        reversible: coll.reversible,
                        integerOffsets: intOffsets,
                        floatOffsets: fltOffsets,
                        kernel: kernel
                    )
                )
            }

            let nextCount = maxOutputIndex + 1
            guard nextCount >= 1 && assignedOutputs.count == nextCount else {
                throw CodecError(
                    .malformedInput,
                    "MCC stage \(stageID) outputs do not form a contiguous 0..<\(nextCount) component set."
                )
            }
            resolvedStages.append(
                ResolvedStage(
                    stageIndex: stageID,
                    inputComponentCount: currentCount,
                    outputComponentCount: nextCount,
                    collections: resolvedCollections
                )
            )
            currentCount = nextCount
        }

        guard currentCount == cbd.components.count else {
            throw CodecError(
                .malformedInput,
                "Final Part 2 MCT stage produces \(currentCount) component(s), disagreeing with CBD count (\(cbd.components.count))."
            )
        }

        return Part2MCTPlan(
            stages: resolvedStages,
            codestreamComponentCount: codestreamComponentCount,
            outputComponentCount: currentCount,
            isAllReversible: allReversible
        )
    }

    // MARK: - Inverse (Synthesis / Decode) Execution

    private static func checkedMulAdd(_ acc: Int64, _ a: Int64, _ b: Int64) throws -> Int64 {
        let (prod, mulOverflow) = a.multipliedReportingOverflow(by: b)
        guard !mulOverflow else {
            throw CodecError(.malformedInput, "Integer overflow in Part 2 reversible MCT product.")
        }
        let (sum, addOverflow) = acc.addingReportingOverflow(prod)
        guard !addOverflow else {
            throw CodecError(.malformedInput, "Integer overflow in Part 2 reversible MCT accumulation.")
        }
        return sum
    }

    private static func checkedAdd64(_ a: Int64, _ b: Int64) throws -> Int64 {
        let (sum, overflow) = a.addingReportingOverflow(b)
        guard !overflow else {
            throw CodecError(.malformedInput, "Integer overflow in Part 2 reversible MCT addition.")
        }
        return sum
    }

    private static func checkedSub64(_ a: Int64, _ b: Int64) throws -> Int64 {
        let (diff, overflow) = a.subtractingReportingOverflow(b)
        guard !overflow else {
            throw CodecError(.malformedInput, "Integer overflow in Part 2 reversible MCT subtraction.")
        }
        return diff
    }

    /// Executes the inverse (synthesis) multi-component transform on reversible integer tile planes.
    func applyInverseReversible(
        planes: [[Int32]],
        pixelCount: Int,
        backend: Backend
    ) throws -> [[Int32]] {
        guard isAllReversible else {
            throw CodecError(.internalFailure, "applyInverseReversible called on an irreversible Part 2 MCT plan.")
        }
        var current: [[Int64]] = planes.map { $0.map(Int64.init) }

        for stage in stages {
            // Fast accelerated path for single-collection 3-component reversible dependency stage.
            if backend == .accelerated,
               stage.collections.count == 1,
               stage.outputComponentCount == 3,
               let coll = stage.collections.first,
               coll.inputComponents.count == 3,
               coll.outputComponents.count == 3,
               case .reversibleDependency(let rows, let shifts) = coll.kernel,
               let acceleratedOut = AcceleratedCodec.inversePart2ReversibleDep3(
                   c0: current[coll.inputComponents[0]],
                   c1: current[coll.inputComponents[1]],
                   c2: current[coll.inputComponents[2]],
                   a10: rows[1][0], shift1: shifts[1],
                   a20: rows[2][0], a21: rows[2][1], shift2: shifts[2],
                   offsets: coll.integerOffsets
               ) {
                var permuted = Array(repeating: [Int64](), count: 3)
                permuted[coll.outputComponents[0]] = acceleratedOut[0]
                permuted[coll.outputComponents[1]] = acceleratedOut[1]
                permuted[coll.outputComponents[2]] = acceleratedOut[2]
                current = permuted
                continue
            }

            var next = Array(repeating: Array(repeating: Int64(0), count: pixelCount), count: stage.outputComponentCount)
            for coll in stage.collections {
                let n = coll.inputComponents.count
                let m = coll.outputComponents.count
                switch coll.kernel {
                case .nullTransform:
                    for p in 0..<pixelCount {
                        for k in 0..<m {
                            let base = (k < n) ? current[coll.inputComponents[k]][p] : 0
                            next[coll.outputComponents[k]][p] = try Self.checkedAdd64(base, coll.integerOffsets[k])
                        }
                    }

                case .reversibleDependency(let rows, let shifts):
                    var outSample = Array(repeating: Int64(0), count: m)
                    for p in 0..<pixelCount {
                        outSample[0] = try Self.checkedAdd64(current[coll.inputComponents[0]][p], coll.integerOffsets[0])
                        if m >= 2 {
                            for k in 1..<m {
                                let row = rows[k]
                                let shift = shifts[k]
                                let half: Int64 = (shift > 0) ? (Int64(1) << (shift - 1)) : 0
                                var sum: Int64 = half
                                for j in 0..<k {
                                    sum = try Self.checkedMulAdd(sum, row[j], outSample[j])
                                }
                                let pred = sum >> shift
                                let withPred = try Self.checkedAdd64(current[coll.inputComponents[k]][p], pred)
                                outSample[k] = try Self.checkedAdd64(withPred, coll.integerOffsets[k])
                            }
                        }
                        for k in 0..<m {
                            next[coll.outputComponents[k]][p] = outSample[k]
                        }
                    }

                case .reversibleSERM(let rows, let targets, let shifts):
                    var vec = Array(repeating: Int64(0), count: m)
                    for p in 0..<pixelCount {
                        for k in 0..<m {
                            vec[k] = current[coll.inputComponents[k]][p]
                        }
                        for step in 0..<rows.count {
                            let row = rows[step]
                            let target = targets[step]
                            let shift = shifts[step]
                            let half: Int64 = (shift > 0) ? (Int64(1) << (shift - 1)) : 0
                            var sum: Int64 = half
                            for j in 0..<m where j != target {
                                sum = try Self.checkedMulAdd(sum, row[j], vec[j])
                            }
                            let delta = sum >> shift
                            vec[target] = try Self.checkedSub64(vec[target], delta)
                        }
                        for k in 0..<m {
                            next[coll.outputComponents[k]][p] = try Self.checkedAdd64(vec[k], coll.integerOffsets[k])
                        }
                    }

                case .irreversibleDependency, .irreversibleMatrix:
                    throw CodecError(.internalFailure, "Irreversible kernel encountered in reversible Part 2 MCT stage.")
                }
            }
            current = next
        }

        return current.map { plane in
            plane.map { Int32(clamping: $0) }
        }
    }

    /// Executes the inverse (synthesis) multi-component transform on floating-point tile planes.
    func applyInverseFloat(
        planes: [[Double]],
        pixelCount: Int,
        backend: Backend
    ) throws -> [[Double]] {
        var current = planes
        for stage in stages {
            if backend == .accelerated,
               stage.collections.count == 1,
               let coll = stage.collections.first,
               coll.inputComponents == [0, 1, 2],
               coll.outputComponents == [0, 1, 2],
               case .irreversibleMatrix(let r, let c, let elements) = coll.kernel,
               r == 3 && c == 3 {
                var out0 = Array(repeating: 0.0, count: pixelCount)
                var out1 = Array(repeating: 0.0, count: pixelCount)
                var out2 = Array(repeating: 0.0, count: pixelCount)
                AcceleratedCodec.applyLinear3x3(
                    in0: current[0], in1: current[1], in2: current[2],
                    matrix: elements,
                    offsets: coll.floatOffsets,
                    out0: &out0, out1: &out1, out2: &out2
                )
                current = [out0, out1, out2]
                continue
            }

            var next = Array(repeating: Array(repeating: 0.0, count: pixelCount), count: stage.outputComponentCount)
            for coll in stage.collections {
                let n = coll.inputComponents.count
                let m = coll.outputComponents.count
                switch coll.kernel {
                case .nullTransform:
                    for p in 0..<pixelCount {
                        for k in 0..<m {
                            let base = (k < n) ? current[coll.inputComponents[k]][p] : 0.0
                            next[coll.outputComponents[k]][p] = base + coll.floatOffsets[k]
                        }
                    }

                case .reversibleDependency(let rows, let shifts):
                    var outSample = Array(repeating: Int64(0), count: m)
                    for p in 0..<pixelCount {
                        let in0 = Int64(current[coll.inputComponents[0]][p].rounded())
                        outSample[0] = try Self.checkedAdd64(in0, coll.integerOffsets[0])
                        if m >= 2 {
                            for k in 1..<m {
                                let row = rows[k]
                                let shift = shifts[k]
                                let half: Int64 = (shift > 0) ? (Int64(1) << (shift - 1)) : 0
                                var sum: Int64 = half
                                for j in 0..<k {
                                    sum = try Self.checkedMulAdd(sum, row[j], outSample[j])
                                }
                                let pred = sum >> shift
                                let ink = Int64(current[coll.inputComponents[k]][p].rounded())
                                let withPred = try Self.checkedAdd64(ink, pred)
                                outSample[k] = try Self.checkedAdd64(withPred, coll.integerOffsets[k])
                            }
                        }
                        for k in 0..<m {
                            next[coll.outputComponents[k]][p] = Double(outSample[k])
                        }
                    }

                case .irreversibleDependency(let rows):
                    var outSample = Array(repeating: 0.0, count: m)
                    for p in 0..<pixelCount {
                        outSample[0] = current[coll.inputComponents[0]][p] + coll.floatOffsets[0]
                        if m >= 2 {
                            for k in 1..<m {
                                let row = rows[k]
                                var sum = current[coll.inputComponents[k]][p] + coll.floatOffsets[k]
                                for j in 0..<k {
                                    sum += row[j] * outSample[j]
                                }
                                outSample[k] = sum
                            }
                        }
                        for k in 0..<m {
                            next[coll.outputComponents[k]][p] = outSample[k]
                        }
                    }

                case .reversibleSERM(let rows, let targets, let shifts):
                    var vec = Array(repeating: Int64(0), count: m)
                    for p in 0..<pixelCount {
                        for k in 0..<m {
                            vec[k] = Int64(current[coll.inputComponents[k]][p].rounded())
                        }
                        for step in 0..<rows.count {
                            let row = rows[step]
                            let target = targets[step]
                            let shift = shifts[step]
                            let half: Int64 = (shift > 0) ? (Int64(1) << (shift - 1)) : 0
                            var sum: Int64 = half
                            for j in 0..<m where j != target {
                                sum = try Self.checkedMulAdd(sum, row[j], vec[j])
                            }
                            vec[target] = try Self.checkedSub64(vec[target], sum >> shift)
                        }
                        for k in 0..<m {
                            next[coll.outputComponents[k]][p] = Double(try Self.checkedAdd64(vec[k], coll.integerOffsets[k]))
                        }
                    }

                case .irreversibleMatrix(let rows, let cols, let elements):
                    for p in 0..<pixelCount {
                        for r in 0..<rows {
                            var sum = coll.floatOffsets[r]
                            let rowBase = r * cols
                            for c in 0..<cols {
                                sum += elements[rowBase + c] * current[coll.inputComponents[c]][p]
                            }
                            next[coll.outputComponents[r]][p] = sum
                        }
                    }
                }
            }
            current = next
        }
        return current
    }

    // MARK: - Encoder Plan Construction & Forward Execution

    struct EncodedMCTPackage: Sendable {
        let cbd: ComponentBitDepthSegment
        let mctTables: [Part2MCTTable]
        let mccStage: Part2MCCStage
        let mco: Part2MCOSegment
        let wireComponentFormats: [(signed: Bool, precision: Int)]
        /// Per-component synthesis energy weights `||col_c||_2` for irreversible PCRD/step scaling.
        let irreversibleColumnNorms: [Double]
    }

    /// Builds a conformant Annex I/J reversible dependency MCT package for `componentCount >= 1`.
    ///
    /// For 1-component greyscale, emits a single null-transform (`Tmcc = 0`) dependency stage with
    /// DC offset restoration when unsigned. For 3-component RGB, anchors prediction on component 1
    /// (green) via output permutation `[1, 0, 2]` so wire component 0 carries centered green (`B`-bit)
    /// and wire components 1 and 2 carry signed differences `R - G` and `B - G` (`(B + 1)`-bit signed),
    /// interoperable with Kakadu `8.4.1` and ISO/IEC 15444-2 Annex J.2.2.2.
    static func makeReversibleEncoderPackage(
        componentCount: Int,
        precision: Int,
        signed: Bool
    ) throws -> EncodedMCTPackage {
        let cbd = try ComponentBitDepthSegment(
            components: Array(
                repeating: ComponentBitDepthSegment.Component(signed: signed, precision: precision),
                count: componentCount
            )
        )
        let dcOffset: Int64 = signed ? 0 : (Int64(1) << (precision - 1))
        var offsets = Array(repeating: Int64(0), count: componentCount)
        offsets[0] = dcOffset
        let offsetElemType: Part2MCTElementType = (dcOffset <= Int64(Int16.max) && dcOffset >= Int64(Int16.min)) ? .int16 : .int32

        if componentCount == 1 {
            let tables: [Part2MCTTable]
            let offsetIdx: Int
            if dcOffset == 0 {
                tables = []
                offsetIdx = 0
            } else {
                tables = [
                    Part2MCTTable(
                        tableIndex: 1,
                        arrayType: .offset,
                        elementType: offsetElemType,
                        integerValues: offsets,
                        floatValues: []
                    )
                ]
                offsetIdx = 1
            }
            let collection = Part2MCCCollection(
                decorrelationType: .dependency,
                inputComponents: [0],
                outputComponents: [0],
                reversible: true,
                offsetTableIndex: offsetIdx,
                transformTableIndex: 0
            )
            return EncodedMCTPackage(
                cbd: cbd,
                mctTables: tables,
                mccStage: Part2MCCStage(stageIndex: 1, collections: [collection]),
                mco: Part2MCOSegment(stageIndices: [1]),
                wireComponentFormats: [(signed: true, precision: precision)],
                irreversibleColumnNorms: [1.0]
            )
        }

        let offsetTable = Part2MCTTable(
            tableIndex: 2,
            arrayType: .offset,
            elementType: offsetElemType,
            integerValues: offsets,
            floatValues: []
        )

        // Synthesis dependency table: out[0] = in[0] + O[0];
        // for k >= 1: out[k] = in[k] + out[0] + O[k] (row k has a_{k,0} = 1, a_{k,1..k-1} = 0, d_k = 1).
        var depValues: [Int64] = []
        for k in 1..<componentCount {
            depValues.append(1) // a_{k,0} = 1
            if k > 1 {
                depValues.append(contentsOf: repeatElement(Int64(0), count: k - 1))
            }
            depValues.append(1) // d_k = 2^0 = 1
        }
        let depTable = Part2MCTTable(
            tableIndex: 1,
            arrayType: .dependency,
            elementType: .int16,
            integerValues: depValues,
            floatValues: []
        )

        // For 3-component RGB, map wire [0, 1, 2] -> logical output [1 (G), 0 (R), 2 (B)].
        // For general N != 3, map wire [0..<N] -> logical output [0..<N].
        let outputOrder: [Int] = (componentCount == 3) ? [1, 0, 2] : Array(0..<componentCount)
        let collection = Part2MCCCollection(
            decorrelationType: .dependency,
            inputComponents: Array(0..<componentCount),
            outputComponents: outputOrder,
            reversible: true,
            offsetTableIndex: (dcOffset == 0) ? 0 : 2,
            transformTableIndex: 1
        )
        let mcc = Part2MCCStage(stageIndex: 1, collections: [collection])
        let mco = Part2MCOSegment(stageIndices: [1])

        // Wire component 0 carries centered anchor component (`precision`-bit signed),
        // and wire components 1..<N carry differences (`precision + 1`-bit signed).
        var wireFormats: [(signed: Bool, precision: Int)] = [(signed: true, precision: precision)]
        for _ in 1..<componentCount {
            wireFormats.append((signed: true, precision: min(38, precision + 1)))
        }

        let tables = (dcOffset == 0) ? [depTable] : [depTable, offsetTable]
        return EncodedMCTPackage(
            cbd: cbd,
            mctTables: tables,
            mccStage: mcc,
            mco: mco,
            wireComponentFormats: wireFormats,
            irreversibleColumnNorms: Array(repeating: 1.0, count: componentCount)
        )
    }

    /// Executes the forward (analysis) transform matching `makeReversibleEncoderPackage` on
    /// zero-centred (`sample - dcShift`) input planes.
    static func applyForwardReversibleEncoder(
        centeredPlanes: [[Int32]],
        backend: Backend
    ) -> [[Int32]] {
        let n = centeredPlanes.count
        if n <= 1 {
            return centeredPlanes
        }
        let pixelCount = centeredPlanes[0].count

        if n == 3 {
            // Centered [R - O, G - O, B - O] -> wire [Y0 = G - O, D1 = R - G, D2 = B - G].
            if backend == .accelerated,
               let accel = AcceleratedCodec.forwardPart2ReversibleDep3(
                   r: centeredPlanes[0], g: centeredPlanes[1], b: centeredPlanes[2], anchorOffset: 0
               ) {
                return accel
            }
            var w0 = Array(repeating: Int32(0), count: pixelCount)
            var w1 = Array(repeating: Int32(0), count: pixelCount)
            var w2 = Array(repeating: Int32(0), count: pixelCount)
            for i in 0..<pixelCount {
                let r = centeredPlanes[0][i]
                let g = centeredPlanes[1][i]
                let b = centeredPlanes[2][i]
                w0[i] = g
                w1[i] = r - g
                w2[i] = b - g
            }
            return [w0, w1, w2]
        }

        var wire = Array(repeating: Array(repeating: Int32(0), count: pixelCount), count: n)
        for i in 0..<pixelCount {
            let anchor = centeredPlanes[0][i]
            wire[0][i] = anchor
            for k in 1..<n {
                wire[k][i] = centeredPlanes[k][i] - anchor
            }
        }
        return wire
    }

    /// Builds a conformant Annex I/J irreversible `MATRIX` MCT package for `componentCount >= 1`.
    ///
    /// Uses the exact ITU-T T.800 / T.801 inverse ICT synthesis matrix for 3-component images, identity
    /// `[1.0]` for 1-component images, and an orthonormal `N x N` DCT-II synthesis basis (`A = C^T`,
    /// forward `A^{-1} = C`) for general `N`.
    static func makeIrreversibleEncoderPackage(
        componentCount: Int,
        precision: Int,
        signed: Bool
    ) throws -> (package: EncodedMCTPackage, forwardMatrix: [Double]) {
        let cbd = try ComponentBitDepthSegment(
            components: Array(
                repeating: ComponentBitDepthSegment.Component(signed: signed, precision: precision),
                count: componentCount
            )
        )
        let dcOffset: Double = signed ? 0.0 : Double(Int64(1) << (precision - 1))
        let offsets = Array(repeating: dcOffset, count: componentCount)

        let inverseMatrix: [Double]
        let forwardMatrix: [Double]
        if componentCount == 1 {
            inverseMatrix = [1.0]
            forwardMatrix = [1.0]
        } else if componentCount == 3 {
            inverseMatrix = [
                1.0,  0.0,       1.402,
                1.0, -0.344136, -0.714136,
                1.0,  1.772,     0.0
            ]
            // Exact mathematical inverse of the float32-rounded synthesis matrix so lossless float math is exact.
            let fInv = inverseMatrix.map { Double(Float($0)) }
            let det = fInv[0] * (fInv[4] * fInv[8] - fInv[5] * fInv[7])
                    - fInv[1] * (fInv[3] * fInv[8] - fInv[5] * fInv[6])
                    + fInv[2] * (fInv[3] * fInv[7] - fInv[4] * fInv[6])
            forwardMatrix = [
                 (fInv[4] * fInv[8] - fInv[5] * fInv[7]) / det,
                -(fInv[1] * fInv[8] - fInv[2] * fInv[7]) / det,
                 (fInv[1] * fInv[5] - fInv[2] * fInv[4]) / det,
                -(fInv[3] * fInv[8] - fInv[5] * fInv[6]) / det,
                 (fInv[0] * fInv[8] - fInv[2] * fInv[6]) / det,
                -(fInv[0] * fInv[5] - fInv[2] * fInv[3]) / det,
                 (fInv[3] * fInv[7] - fInv[4] * fInv[6]) / det,
                -(fInv[0] * fInv[7] - fInv[1] * fInv[6]) / det,
                 (fInv[0] * fInv[4] - fInv[1] * fInv[3]) / det
            ]
        } else {
            // Orthonormal DCT-II forward matrix C (rows k = frequency, cols n = component),
            // and synthesis matrix A = C^T so A * C = I.
            var fwd = Array(repeating: 0.0, count: componentCount * componentCount)
            var inv = Array(repeating: 0.0, count: componentCount * componentCount)
            let scale0 = (1.0 / Double(componentCount)).squareRoot()
            let scaleK = (2.0 / Double(componentCount)).squareRoot()
            for k in 0..<componentCount {
                let s = (k == 0) ? scale0 : scaleK
                for j in 0..<componentCount {
                    let v = s * Foundation.cos(Double.pi * (Double(j) + 0.5) * Double(k) / Double(componentCount))
                    fwd[k * componentCount + j] = v
                    inv[j * componentCount + k] = v
                }
            }
            forwardMatrix = fwd
            inverseMatrix = inv
        }

        var colNorms = Array(repeating: 1.0, count: componentCount)
        for col in 0..<componentCount {
            var sumSq = 0.0
            for row in 0..<componentCount {
                let v = Double(Float(inverseMatrix[row * componentCount + col]))
                sumSq += v * v
            }
            colNorms[col] = max(1e-6, sumSq.squareRoot())
        }

        let matrixTable = Part2MCTTable(
            tableIndex: 1,
            arrayType: .decorrelation,
            elementType: .float32,
            integerValues: [],
            floatValues: inverseMatrix
        )
        var tables: [Part2MCTTable] = [matrixTable]
        let offsetTableIdx: Int
        if dcOffset != 0 {
            tables.append(
                Part2MCTTable(
                    tableIndex: 2,
                    arrayType: .offset,
                    elementType: .float32,
                    integerValues: [],
                    floatValues: offsets
                )
            )
            offsetTableIdx = 2
        } else {
            offsetTableIdx = 0
        }

        let collection = Part2MCCCollection(
            decorrelationType: .matrix,
            inputComponents: Array(0..<componentCount),
            outputComponents: Array(0..<componentCount),
            reversible: false,
            offsetTableIndex: offsetTableIdx,
            transformTableIndex: 1
        )
        let mcc = Part2MCCStage(stageIndex: 1, collections: [collection])
        let mco = Part2MCOSegment(stageIndices: [1])
        let wireFormats = Array(repeating: (signed: true, precision: precision), count: componentCount)

        let pkg = EncodedMCTPackage(
            cbd: cbd,
            mctTables: tables,
            mccStage: mcc,
            mco: mco,
            wireComponentFormats: wireFormats,
            irreversibleColumnNorms: colNorms
        )
        return (pkg, forwardMatrix)
    }

    /// Executes the forward (analysis) matrix transform matching `makeIrreversibleEncoderPackage`
    /// on zero-centred (`sample - dcShift`) input planes.
    static func applyForwardIrreversibleEncoder(
        centeredPlanes: [[Double]],
        forwardMatrix: [Double],
        backend: Backend
    ) -> [[Double]] {
        let n = centeredPlanes.count
        if n <= 1 {
            return centeredPlanes
        }
        let pixelCount = centeredPlanes[0].count
        if backend == .accelerated && n == 3 {
            var out0 = Array(repeating: 0.0, count: pixelCount)
            var out1 = Array(repeating: 0.0, count: pixelCount)
            var out2 = Array(repeating: 0.0, count: pixelCount)
            AcceleratedCodec.applyLinear3x3(
                in0: centeredPlanes[0], in1: centeredPlanes[1], in2: centeredPlanes[2],
                matrix: forwardMatrix,
                offsets: [0.0, 0.0, 0.0],
                out0: &out0, out1: &out1, out2: &out2
            )
            return [out0, out1, out2]
        }

        var wire = Array(repeating: Array(repeating: 0.0, count: pixelCount), count: n)
        for p in 0..<pixelCount {
            for r in 0..<n {
                var sum = 0.0
                let base = r * n
                for c in 0..<n {
                    sum += forwardMatrix[base + c] * centeredPlanes[c][p]
                }
                wire[r][p] = sum
            }
        }
        return wire
    }
}
