// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import SwiftJ2K
@testable import SwiftJ2K3D

/// Independent Kakadu entropy payloads, with only dimensional headers lifted to
/// depth one. This is HT packet evidence, not an external JP3D peer.
/// Generator outcomes and hashes are in Fixtures/R3PlanarHT and R3RefinementHT
/// in SwiftJ2KTests. Reproduce with Scripts/generate-r3-ht-fixtures.py.
@Suite("R3 independently generated HT payloads")
struct CodexR3IndependentHTTests {
    private let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("SwiftJ2KTests/Fixtures")

    private func segment(_ marker: UInt16, _ body: [UInt8]) -> [UInt8] {
        let length = body.count + 2
        return [UInt8(marker >> 8), UInt8(truncatingIfNeeded: marker),
                UInt8(length >> 8), UInt8(truncatingIfNeeded: length)] + body
    }

    private func liftToDepthOne(_ input: Data) throws -> Data {
        let bytes = [UInt8](input)
        var output: [UInt8] = [0xFF, 0x4F]
        var offset = 2
        while offset + 4 <= bytes.count {
            let marker = UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
            if marker == 0xFF90 {
                // Preserve every packet header, entropy byte and tile-part length.
                output.append(contentsOf: bytes[offset...])
                return Data(output)
            }
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard length >= 2, offset + 2 + length <= bytes.count else {
                throw CodecError(.malformedInput, "Truncated independent HT fixture")
            }
            var body = Array(bytes[(offset + 4)..<(offset + 2 + length)])
            switch marker {
            case 0xFF51:
                body[0] = 0x40; body[1] = 0
                output += segment(marker, body)
            case 0xFF50:
                guard body.count == 6, body.prefix(4) == [0, 2, 0, 0] else {
                    throw CodecError(.unsupportedFeature, "Unexpected independent CAP fixture")
                }
                output += segment(marker, [0, 0x42, 0, 0, 0, 0] + body.suffix(2))
                // Ndim=3; Zsiz=ZTsiz=1; ZOsiz=ZTOsiz=0; ZRsiz=1.
                output += segment(0xFF54, [3, 0, 0, 0, 1, 0, 0, 0, 0,
                                           0, 0, 0, 1, 0, 0, 0, 0, 1])
            case 0xFF52:
                guard body.count >= 10, body[5] == 0 else {
                    throw CodecError(.malformedInput, "Independent lift requires zero DWT levels; Part 1/10 filtering order is not assumed equivalent")
                }
                var dimensional = Array(body.prefix(5))
                dimensional += [body[5], body[5], 0, body[6] + 2, body[7] + 2,
                                0, body[8], body[9], body[9], body[9]]
                for precinct in body.dropFirst(10) { dimensional += [0, precinct] }
                output += segment(marker, dimensional)
            default:
                output += segment(marker, body)
            }
            offset += length + 2
        }
        throw CodecError(.malformedInput, "Independent fixture has no tile part")
    }

    @Test(arguments: ["g12_5x3_ramp_extremes", "g16_17x9_alternating", "g08_37x23_random"])
    func kakaduLayeredPayloadsDecodeExactly(name: String) async throws {
        let source = try Data(contentsOf: fixtures.appendingPathComponent("R3PlanarHT/\(name).kdu_ht_n0_layers_lrcp.j2k"))
        let lifted = try liftToDepthOne(source)
        let parsed = try JP3DCodestreamParser().parse(lifted)
        let geom = try JP3DGeometryBuilder.makeTileComponentGeometry(
            x0: 0, x1: parsed.siz.width, y0: 0, y1: parsed.siz.height,
            z0: 0, z1: 1, cod: parsed.cod)
        let packets = try JP3DTier2Coder.decodePackets(
            geometries: [geom], cod: parsed.cod, data: parsed.tiles[0].data,
            cancellation: {})
        let blocks = packets.contributions.flatMap { $0 }.flatMap { $0 }.flatMap { $0 }.flatMap { $0 }
        print("R3 independent HT \(name): " + blocks.map {
            "passes=\($0.passes), segments=" + $0.segments.map { "\($0.passes):\($0.data.count)" }.joined(separator: ",")
        }.joined(separator: ";"))
        let decoded = try await VolumeDecoder().decode(lifted)
        #expect(decoded.volume.depth == 1)
        // PGM sample payload has a fixed three-line header in these retained fixtures.
        let pgm = [UInt8](try Data(contentsOf: fixtures.appendingPathComponent("Lossless/\(name).pgm")))
        let newlines = pgm.indices.filter { pgm[$0] == 10 }
        let end = try #require(newlines.dropFirst(2).first)
        let payload = Array(pgm[(end + 1)...])
        let component = decoded.volume.components[0]
        if component.bitDepth <= 8 {
            #expect(Array(component.data) == payload)
        } else {
            let littleEndian = payload.indices.map { payload[$0 ^ 1] }
            #expect(Array(component.data) == littleEndian)
        }
        let transcoded = try await VolumeTranscoder().transcode(lifted, to: .jpeg2000)
        let redecode = try await VolumeDecoder().decode(transcoded.data)
        #expect(redecode.volume.components[0].data == component.data)
    }

    @Test(arguments: [4, 8, 12])
    func independentlyTruncatedRefinementPayloads(rate: Int) async throws {
        let folder = fixtures.appendingPathComponent("R3RefinementHT")
        let source = try Data(contentsOf: folder.appendingPathComponent("rate\(rate).ht.j2k"))
        let lifted = try liftToDepthOne(source)
        let parsed = try JP3DCodestreamParser().parse(lifted)
        let geom = try JP3DGeometryBuilder.makeTileComponentGeometry(
            x0: 0, x1: parsed.siz.width, y0: 0, y1: parsed.siz.height,
            z0: 0, z1: 1, cod: parsed.cod)
        let packets = try JP3DTier2Coder.decodePackets(
            geometries: [geom], cod: parsed.cod, data: parsed.tiles[0].data,
            cancellation: {})
        let blocks = packets.contributions.flatMap { $0 }.flatMap { $0 }.flatMap { $0 }.flatMap { $0 }
        let refined = blocks.filter { $0.segments.filter { !$0.data.isEmpty }.count > 1 }
        print("R3 independent refinement rate\(rate): \(refined.count)/\(blocks.count) blocks; " +
              refined.map { $0.segments.map { "\($0.passes):\($0.data.count)" }.joined(separator: ",") }.joined(separator: ";"))
        #expect(!refined.isEmpty)
        let decoded = try await VolumeDecoder().decode(lifted)
        let pgm = [UInt8](try Data(contentsOf: folder.appendingPathComponent("rate\(rate).ht.pgm")))
        let newlines = pgm.indices.filter { pgm[$0] == 10 }
        let end = try #require(newlines.dropFirst(2).first)
        let payload = Array(pgm[(end + 1)...])
        let littleEndian = payload.indices.map { payload[$0 ^ 1] }
        // T.800 E.1 permits decoder-selected reconstruction r for incomplete
        // magnitude planes, including reversible transforms. Match Kakadu's
        // r=1/2 here; the public volume path uses r=0 for reversible data.
        // This checks shared HT entropy decoding, not a direct JP3D peer.
        var peerSamples = [UInt8](repeating: 0, count: littleEndian.count)
        var refinementChanges = 0
        for (r, resolution) in geom.resolutions.enumerated() {
            for (p, precinct) in resolution.precincts.enumerated() {
                for (b, precinctBand) in precinct.bands.enumerated() {
                    let band = resolution.bands[precinctBand.bandIndex]
                    let kMax = parsed.qcd.magnitudeBitPlanes(for: band, resolution: r,
                        maxLevels: geom.maxLevels, componentBitDepth: 16,
                        usesReversibleMCT: false, roiShift: 0)
                    for (k, block) in precinctBand.blocks.enumerated() {
                        let contribution = packets.contributions[0][r][p][b][k]
                        let segments = contribution.segments.map { HTSegmentInput(data: $0.data, passes: $0.passes) }
                        let coefficients = try HTBlockDecoder.decodeHTCodeBlock(
                            segments: segments, zeroBitPlanes: contribution.zeroBitPlanes,
                            totalPasses: contribution.passes, width: block.width,
                            height: block.height, kMax: kMax, allowMultiHT: false,
                            midpointReconstruction: true)
                        let first = try #require(segments.first)
                        let cleanup = try HTBlockDecoder.decodeHTCodeBlock(
                            segments: [first], zeroBitPlanes: contribution.zeroBitPlanes,
                            totalPasses: first.passes, width: block.width,
                            height: block.height, kMax: kMax, allowMultiHT: false,
                            midpointReconstruction: true)
                        refinementChanges += zip(coefficients, cleanup).filter { $0 != $1 }.count
                        for y in 0..<block.height {
                            for x in 0..<block.width {
                                let sample = UInt16(clamping: coefficients[y * block.width + x] + 32768)
                                let index = ((block.y0 + y) * parsed.siz.width + block.x0 + x) * 2
                                peerSamples[index] = UInt8(truncatingIfNeeded: sample)
                                peerSamples[index + 1] = UInt8(sample >> 8)
                            }
                        }
                    }
                }
            }
        }
        print("R3 independent refinement rate\(rate): \(refinementChanges) samples changed by refinement")
        #expect(refinementChanges > 0)
        let agreesWithIndependentDecoder = peerSamples == littleEndian
        #expect(agreesWithIndependentDecoder)
        let transcoded = try await VolumeTranscoder().transcode(lifted, to: .jpeg2000)
        let redecode = try await VolumeDecoder().decode(transcoded.data)
        #expect(redecode.volume.components[0].data == decoded.volume.components[0].data)
    }
}
