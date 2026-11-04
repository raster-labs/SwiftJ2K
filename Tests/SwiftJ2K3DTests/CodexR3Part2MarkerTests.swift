// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2K3D

@Suite("Codex R3 normative Part 2 synthesis markers")
struct CodexR3Part2MarkerTests {
    private func stream(_ count: Int) throws -> Data {
        let split = try JP3DPart2BitSplitDescriptor.buildMarkerSegments(
            logicalBitDepths: [Int](repeating: 38, count: count),
            logicalSigned: [Bool](repeating: true, count: count))
        return JP3DCodestreamBuilder().buildPreallocated(
            tileData: [Data([0])], width: 1, height: 1, depth: 1,
            components: 2 * count, bitDepth: 20, signed: true,
            levelsX: 0, levelsY: 0, levelsZ: 0,
            tileSizeX: 1, tileSizeY: 1, tileSizeZ: 1, isLossless: true,
            htj2kConfiguration: nil, capacity: 0, part2BitSplit: split)
    }

    private func marker(_ wanted: UInt16, in data: Data) throws -> Int {
        var cursor = 2
        while cursor + 4 <= data.count {
            let marker = UInt16(data[cursor]) << 8 | UInt16(data[cursor + 1])
            if marker == wanted { return cursor }
            if marker == 0xFF90 { break }
            let length = Int(data[cursor + 2]) << 8 | Int(data[cursor + 3])
            cursor += length + 2
        }
        throw J2KError.decodingError("Missing test marker")
    }

    @Test("Index widths cross 8-bit boundaries without truncation", arguments: [1, 128, 129, 256, 257])
    func componentIndexBoundaries(_ count: Int) throws {
        let data = try stream(count)
        let parsed = try JP3DCodestreamParser().parse(data)
        #expect(parsed.siz.rsiz == 0xC100)
        #expect(parsed.cod.multipleComponentTransform == 2)
        #expect(parsed.part2BitSplit?.logicalComponentCount == count)
        let mcc = try marker(0xFF75, in: data)
        #expect(data[mcc + 11] == 1)
        let nmcc = Int(data[mcc + 12]) << 8 | Int(data[mcc + 13])
        #expect(nmcc == (count > 128 ? 0x8002 : 2))
    }

    @Test("Invalid signalling is rejected before synthesis", arguments: [0, 1, 2])
    func rejectInconsistentMarkers(_ mutation: Int) throws {
        var data = try stream(1)
        switch mutation {
        case 0: data[6] = 0x40 // Clear Part 2 and MCT capability bits.
                data[7] = 0
        case 1: let mcc = try marker(0xFF75, in: data)
                data[mcc + 11] = 9 // Reserved Xmcc bits are not index-width flags.
        default: let cod = try marker(0xFF52, in: data)
                 data[cod + 8] = 0 // Array synthesis requires COD MCT=2.
        }
        #expect(throws: (any Error).self) { try JP3DCodestreamParser().parse(data) }
    }

    @Test("Oversized or inconsistent descriptions fail without integer traps")
    func rejectInvalidDescriptions() {
        for count in [0, 4_681, 8_193] {
            #expect(throws: (any Error).self) {
                try JP3DPart2BitSplitDescriptor.buildMarkerSegments(
                    logicalBitDepths: [Int](repeating: 38, count: count),
                    logicalSigned: [Bool](repeating: true, count: count))
            }
        }
        #expect(throws: (any Error).self) {
            try JP3DPart2BitSplitDescriptor.buildMarkerSegments(logicalBitDepths: [38], logicalSigned: [])
        }
    }
}
