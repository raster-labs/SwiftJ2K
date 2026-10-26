// SPDX-License-Identifier: Apache-2.0
//
// Scalar lossless JPEG 2000 Part 1 and Part 15 (HTJ2K) pipeline for the shared
// greyscale profile: one unsigned component of 1–16 bits, reversible 5/3
// wavelet, no quantisation, raw codestream, and native compressed-to-compressed
// J2K <-> HTJ2K transcoding in the wavelet coefficient domain.
//
// Provenance: new implementation for SwiftJ2K, fitted to the Milestone 1
// `Image`/`ImageDestination` contract. It replaces the predecessor's
// `EncoderPipeline`/`DecoderPipeline` (Raster-Lab/J2KSwift 7acc9ae4).
import Foundation

/// A validated description of one tile of a decodable codestream.
struct TileProfile: Sendable {
    let index: Int
    let x0: Int, x1: Int, y0: Int, y1: Int
    let codingStyle: CodingStyleSegment
    let quantization: QuantizationSegment
    let magnitudeBitPlanes: [Int]         // per QCD band index
    let geometry: TileGeometry
    let dataRanges: [Range<Int>]          // tile-part data ranges in part order
    var width: Int { x1 - x0 }
    var height: Int { y1 - y0 }
}

/// A validated description of a codestream the scalar path can decode or transcode.
struct LosslessProfile: Sendable {
    let width: Int                        // image area on the reference grid
    let height: Int
    let originX: Int, originY: Int        // XOsiz, YOsiz
    let tileWidth: Int, tileHeight: Int   // XTsiz, YTsiz
    let tileOriginX: Int, tileOriginY: Int
    let precision: Int
    let isHTJ2K: Bool
    let tiles: [TileProfile]
    var format: String { isHTJ2K ? ScalarLosslessCodec.htj2kFormat : ScalarLosslessCodec.format }
    var codeBlockCount: Int { tiles.reduce(0) { $0 + $1.geometry.codeBlockCount } }
    var largestTilePixels: Int { tiles.map { $0.width * $0.height }.max() ?? 0 }
    var largestTileBytes: Int { tiles.map { $0.dataRanges.reduce(0) { $0 + $1.count } }.max() ?? 0 }
}

/// Cooperative cancellation plus the operation deadline from `ResourceLimits`.
struct WorkGuard: Sendable {
    private let deadline: ContinuousClock.Instant
    init(limits: ResourceLimits) {
        deadline = ContinuousClock.now.advanced(by: .seconds(limits.deadlineSeconds))
    }
    func check() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now <= deadline else {
            throw CodecError(.resourceLimitExceeded, "Operation deadline elapsed.")
        }
    }
}

enum ScalarLosslessCodec {
    static let format = "jpeg2000-codestream"
    static let htj2kFormat = "htj2k-codestream"
    static let guardBits = 2

    // MARK: - Inspection

    static func inspect(_ bytes: [UInt8], limits: ResourceLimits) throws -> LosslessProfile {
        let parsed = try CodestreamSyntax.parse(bytes, limits: limits)
        let size = parsed.size
        guard size.capabilities & 0x8000 == 0 else {
            throw CodecError(.unsupportedFeature, "Rsiz signals Part 2 extensions (0x8000), which are not supported.")
        }
        if let cap = parsed.extendedCapabilities {
            guard !cap.multiHT else {
                throw CodecError(.unsupportedFeature, "Multiple HT sets per code-block (MULTIHT) are not supported.")
            }
            guard !cap.irreversible else {
                throw CodecError(.unsupportedFeature, "Irreversible HTJ2K coding (HTIRV) is not supported in the lossless profile.")
            }
            guard !cap.regionOfInterestPresent else {
                throw CodecError(.unsupportedFeature, "Region-of-interest (RGN) coding is not supported.")
            }
        }
        guard size.components.count == 1 else {
            throw CodecError(.unsupportedFeature, "Only single-component (greyscale) codestreams are supported.")
        }
        let component = size.components[0]
        guard !component.signed else { throw CodecError(.unsupportedFeature, "Signed components are not supported.") }
        guard component.precision <= 16 else {
            throw CodecError(.unsupportedFeature, "Component precision above 16 bits is not supported.")
        }
        guard component.horizontalSeparation == 1, component.verticalSeparation == 1 else {
            throw CodecError(.unsupportedFeature, "Sub-sampled components are not supported.")
        }
        // Tile grid (B.3).
        let tilesWide = Wavelet53.ceilDiv(size.width - size.tileOriginX, size.tileWidth)
        let tilesHigh = Wavelet53.ceilDiv(size.height - size.tileOriginY, size.tileHeight)
        guard tilesWide >= 1, tilesHigh >= 1, tilesWide * tilesHigh <= 65535 else {
            throw CodecError(.malformedInput, "Tile grid is empty or exceeds 65535 tiles.")
        }
        // Group tile-parts by tile and check their order.
        var partsByTile: [Int: [TilePartRecord]] = [:]
        for part in parsed.tileParts { partsByTile[part.tileIndex, default: []].append(part) }
        var tiles: [TileProfile] = []
        for (tileIndex, parts) in partsByTile.sorted(by: { $0.key < $1.key }) {
            guard tileIndex < tilesWide * tilesHigh else {
                throw CodecError(.malformedInput, "Tile-parts reference a tile the SIZ grid does not contain.")
            }
            let ordered = parts.sorted { $0.partIndex < $1.partIndex }
            for (expected, part) in ordered.enumerated() {
                guard part.partIndex == expected, part.partCount == 0 || part.partCount == ordered.count else {
                    throw CodecError(.malformedInput, "Tile-part indices are not contiguous.")
                }
            }
            let (cod, qcd) = parsed.effectiveParameters(tile: tileIndex)
            try validateCodingStyle(cod, quantization: qcd)
            let p = tileIndex % tilesWide, q = tileIndex / tilesWide
            let tx0 = max(size.tileOriginX + p * size.tileWidth, size.originX)
            let ty0 = max(size.tileOriginY + q * size.tileHeight, size.originY)
            let tx1 = min(size.tileOriginX + (p + 1) * size.tileWidth, size.width)
            let ty1 = min(size.tileOriginY + (q + 1) * size.tileHeight, size.height)
            guard tx1 > tx0, ty1 > ty0 else { throw CodecError(.malformedInput, "Tile has an empty area.") }
            let bandCount = 3 * cod.decompositionLevels + 1
            guard qcd.exponents.count >= bandCount else {
                throw CodecError(.malformedInput, "QCD lists fewer bands than the decomposition needs.")
            }
            var magnitudeBitPlanes: [Int] = []
            for exponent in qcd.exponents.prefix(bandCount) {
                let mb = qcd.guardBits + exponent - 1
                guard mb >= 1, mb <= BitPlaneCoder.maximumMagnitudeBitPlanes else {
                    throw CodecError(.malformedInput, "Band exponent and guard bits give an unusable bit-plane count.")
                }
                magnitudeBitPlanes.append(mb)
            }
            let geometry = try Tier2.makeTileGeometry(x0: tx0, x1: tx1, y0: ty0, y1: ty1, codingStyle: cod)
            tiles.append(TileProfile(index: tileIndex, x0: tx0, x1: tx1, y0: ty0, y1: ty1, codingStyle: cod,
                                     quantization: qcd, magnitudeBitPlanes: magnitudeBitPlanes, geometry: geometry,
                                     dataRanges: ordered.map(\.dataRange)))
        }
        guard tiles.count == tilesWide * tilesHigh else {
            throw CodecError(.malformedInput, "Codestream lacks tile-parts for \(tilesWide * tilesHigh - tiles.count) of its tiles.")
        }
        return LosslessProfile(width: size.width - size.originX, height: size.height - size.originY,
                               originX: size.originX, originY: size.originY,
                               tileWidth: size.tileWidth, tileHeight: size.tileHeight,
                               tileOriginX: size.tileOriginX, tileOriginY: size.tileOriginY,
                               precision: component.precision, isHTJ2K: parsed.isHTJ2K, tiles: tiles)
    }

    private static func validateCodingStyle(_ cod: CodingStyleSegment, quantization qcd: QuantizationSegment) throws {
        guard cod.reversible else { throw CodecError(.unsupportedFeature, "The irreversible 9/7 wavelet is not supported.") }
        if (cod.codeBlockStyle & 0x40) != 0 && (cod.codeBlockStyle & 0x80) == 0 {
            guard (cod.codeBlockStyle & 0x3E) == 0 else {
                throw CodecError(.malformedInput, "COD/COC sets reserved code-block style bits in HTJ2K mode.")
            }
        }
        guard cod.componentTransform == 0 else {
            throw CodecError(.malformedInput, "A component transform is signalled for a single component.")
        }
        guard qcd.style == .none else { throw CodecError(.unsupportedFeature, "Quantised (lossy) codestreams are not supported.") }
    }

    /// Bound on algorithm workspace (MEM-10): one `Int32` coefficient plane of
    /// the largest tile, the largest joined tile data, and per-block scratch.
    static func workspaceBytes(profile: LosslessProfile) throws -> Int {
        try workspaceBytes(planePixels: profile.largestTilePixels, joinedBytes: profile.largestTileBytes)
    }
    static func workspaceBytes(planePixels: Int, joinedBytes: Int) throws -> Int {
        let plane = try checkedMultiply(planePixels, 4)
        let blockScratch = BitPlaneCoder.maximumCoefficients * (4 + 4 + 1) + 66 * 66 + 4096
        return try checkedAdd(checkedAdd(plane, joinedBytes), blockScratch)
    }

    // MARK: - Shared Tile Tier-2 + Tier-1 Coefficient Decoding

    private static func decodeTileCoefficients(
        bytes: [UInt8],
        tile: TileProfile,
        work: WorkGuard,
        completed: inout Int,
        total: Int,
        progress: (@Sendable (ProgressUpdate) -> Void)?
    ) throws -> [Int32] {
        let tileBytes: [UInt8]
        let tileRange: Range<Int>
        if tile.dataRanges.count == 1 {
            tileBytes = bytes; tileRange = tile.dataRanges[0]
        } else {
            var joined: [UInt8] = []
            joined.reserveCapacity(tile.dataRanges.reduce(0) { $0 + $1.count })
            for range in tile.dataRanges { joined.append(contentsOf: bytes[range]) }
            tileBytes = joined; tileRange = 0..<joined.count
            StorageTelemetry.recordWorkspaceAllocation(bytes: joined.count)
        }
        let geometry = tile.geometry
        let style = CodeBlockStyle(bits: tile.codingStyle.codeBlockStyle)
        let contributions = try Tier2.decodePackets(
            geometry: geometry,
            codingStyle: tile.codingStyle,
            bytes: tileBytes,
            range: tileRange,
            cancellation: work.check
        )
        let stride = tile.width
        var plane = [Int32](repeating: 0, count: tile.width * tile.height)
        StorageTelemetry.recordWorkspaceAllocation(bytes: plane.count * 4)
        for resolution in geometry.resolutions {
            for (p, precinct) in resolution.precincts.enumerated() {
                for (b, precinctBand) in precinct.bands.enumerated() {
                    let band = resolution.bands[precinctBand.bandIndex]
                    let mb = tile.magnitudeBitPlanes[band.quantizationIndex]
                    for (k, block) in precinctBand.blocks.enumerated() {
                        try work.check()
                        let contribution = contributions[resolution.index][p][b][k]
                        completed += 1
                        guard contribution.included, contribution.passes > 0 else { continue }
                        let coefficients: [Int32]
                        if contribution.isHT {
                            // ISO/IEC 15444-15 Clause B.10.5: placeholder passes come in sets of 3
                            // before the single HT cleanup pass.
                            let htPasses = ((contribution.passes - 1) % 3) + 1
                            guard htPasses == 1, contribution.segments.count <= 1 else {
                                if style.bypass {
                                    throw CodecError(.unsupportedFeature, "HTJ2K SigProp and MagRef refinement passes are not supported in the lossless profile.")
                                }
                                throw CodecError(.malformedInput, "HTJ2K code-block has \(htPasses) passes in a single HT set without refinement signalling (0x01).")
                            }
                            let placeholderSets = (contribution.passes - 1) / 3
                            let effectiveMissingMSBs = contribution.zeroBitPlanes + placeholderSets
                            let rawBlock = contribution.segments.first?.data ?? []
                            coefficients = try HTBlockDecoder.decodeCleanup(
                                block: rawBlock,
                                width: block.width,
                                height: block.height,
                                kMax: mb,
                                missingMSBs: effectiveMissingMSBs
                            )
                        } else {
                            coefficients = try BitPlaneCoder.decode(
                                segments: contribution.segments, width: block.width, height: block.height,
                                orientation: band.orientation, zeroBitPlanes: contribution.zeroBitPlanes,
                                passCount: contribution.passes, magnitudeBitPlanes: mb, style: style
                            )
                        }
                        for row in 0..<block.height {
                            let planeRow = (band.planeY + block.y0 - band.y0 + row) * stride + band.planeX + block.x0 - band.x0
                            for column in 0..<block.width {
                                plane[planeRow + column] = coefficients[row * block.width + column]
                            }
                        }
                        if completed & 7 == 0 {
                            progress?(try ProgressUpdate(phase: .processing, completedUnits: completed, totalUnits: total))
                        }
                    }
                }
            }
        }
        return plane
    }

    // MARK: - Decoding

    static func decode(bytes: [UInt8], profile: LosslessProfile, into destination: ImageDestination,
                       limits: ResourceLimits, progress: (@Sendable (ProgressUpdate) -> Void)?) throws -> (Image, Int) {
        let descriptor = destination.descriptor
        guard descriptor.width == profile.width, descriptor.height == profile.height,
              descriptor.sampleType == .unsignedInteger, descriptor.storageBits == 16,
              descriptor.components == [.grey], descriptor.planes.count == 1,
              descriptor.meaningfulBits == profile.precision else {
            throw CodecError(.incompatibleImageLayout, "Destination descriptor does not match the codestream geometry or precision.")
        }
        let workspace = try workspaceBytes(profile: profile)
        guard workspace <= limits.maximumWorkspaceBytes else {
            throw CodecError(.resourceLimitExceeded, "Decoder workspace exceeds the operation limit.")
        }
        guard try checkedAdd(checkedAdd(bytes.count, destination.storage.byteCount), workspace) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Compressed input, destination and workspace exceed the memory budget.")
        }
        let work = WorkGuard(limits: limits)
        try work.check()
        do {
            return try decodeAdmitted(bytes: bytes, profile: profile, into: destination, workspace: workspace,
                                      work: work, progress: progress)
        } catch {
            destination.invalidateAfterFailure()
            throw error
        }
    }

    private static func decodeAdmitted(bytes: [UInt8], profile: LosslessProfile, into destination: ImageDestination,
                                       workspace: Int, work: WorkGuard,
                                       progress: (@Sendable (ProgressUpdate) -> Void)?) throws -> (Image, Int) {
        let descriptor = destination.descriptor
        let layout = descriptor.planes[0]
        let mutation = SharedPathMutation.active
        let rowBytes = mutation == .ignoreRowStride ? profile.width * layout.pixelStride : layout.rowBytes
        let order = mutation == .wrongByteOrder ? descriptor.byteOrder.opposite : descriptor.byteOrder
        let shift = Int32(1) << Int32(profile.precision - 1)
        let maximum = Int32((1 << profile.precision) - 1)
        let total = profile.codeBlockCount
        var completed = 0
        progress?(try ProgressUpdate(phase: .processing, completedUnits: 0, totalUnits: total))

        // All tiles are decoded inside the one exclusive write borrow of the
        // destination; each tile's workspace is released before the next.
        let image = try destination.write { output in
            for tile in profile.tiles {
                try work.check()
                let stride = tile.width
                var plane = try decodeTileCoefficients(
                    bytes: bytes,
                    tile: tile,
                    work: work,
                    completed: &completed,
                    total: total,
                    progress: progress
                )
                try Wavelet53.inverse(plane: &plane, stride: stride, x0: tile.x0, x1: tile.x1, y0: tile.y0, y1: tile.y1,
                                      levels: tile.codingStyle.decompositionLevels, cancellation: work.check)
                // Final-output stage: DC shift, clamp, write into the caller's plane.
                for row in 0..<tile.height {
                    try work.check()
                    let y = tile.y0 - profile.originY + row
                    let rowOffset = layout.offset + y * rowBytes
                    for column in 0..<tile.width {
                        let x = tile.x0 - profile.originX + column
                        let value = min(max(plane[row * stride + column] + shift, 0), maximum)
                        try storeUInt16(UInt16(value), into: output, at: rowOffset + x * layout.pixelStride, order: order)
                    }
                }
            }
        }
        return (image, workspace)
    }

    // MARK: - Encoding

    struct EncodeParameters: Sendable {
        let decompositionLevels: Int
        let codeBlockWidthExponent: Int
        let codeBlockHeightExponent: Int
        let blockCoding: CodecOptions.BlockCoding
    }

    private static func encodeTileBlocks(
        plane: [Int32],
        stride: Int,
        geometry: TileGeometry,
        qcd: QuantizationSegment,
        blockCoding: CodecOptions.BlockCoding,
        work: WorkGuard,
        completed: inout Int,
        total: Int,
        progress: (@Sendable (ProgressUpdate) -> Void)?
    ) throws -> [[[[CodeBlockEncoding]]]] {
        var encodings: [[[[CodeBlockEncoding]]]] = []
        var coefficients: [Int32] = []
        for resolution in geometry.resolutions {
            var perPrecinct: [[[CodeBlockEncoding]]] = []
            for precinct in resolution.precincts {
                var perBand: [[CodeBlockEncoding]] = []
                for precinctBand in precinct.bands {
                    let band = resolution.bands[precinctBand.bandIndex]
                    let mb = qcd.guardBits + qcd.exponents[band.quantizationIndex] - 1
                    var perBlock: [CodeBlockEncoding] = []
                    for block in precinctBand.blocks {
                        try work.check()
                        coefficients.removeAll(keepingCapacity: true)
                        for row in 0..<block.height {
                            let planeRow = (band.planeY + block.y0 - band.y0 + row) * stride + band.planeX + block.x0 - band.x0
                            coefficients.append(contentsOf: plane[planeRow..<planeRow + block.width])
                        }
                        let encoding: CodeBlockEncoding
                        switch blockCoding {
                        case .part1:
                            encoding = try BitPlaneCoder.encode(
                                coefficients: coefficients,
                                width: block.width,
                                height: block.height,
                                orientation: band.orientation,
                                magnitudeBitPlanes: mb
                            )
                        case .htj2k:
                            let coded = try HTBlockEncoder.encodeCleanup(
                                coefficients: coefficients,
                                width: block.width,
                                height: block.height,
                                bandShift: 0
                            )
                            encoding = CodeBlockEncoding(
                                data: coded,
                                passCount: coded.isEmpty ? 0 : 1,
                                zeroBitPlanes: coded.isEmpty ? mb : (mb - 1)
                            )
                        }
                        perBlock.append(encoding)
                        completed += 1
                        if completed & 7 == 0 {
                            progress?(try ProgressUpdate(phase: .processing, completedUnits: completed, totalUnits: total))
                        }
                    }
                    perBand.append(perBlock)
                }
                perPrecinct.append(perBand)
            }
            encodings.append(perPrecinct)
        }
        return encodings
    }

    static func encode(image: Image, parameters: EncodeParameters, limits: ResourceLimits,
                       progress: (@Sendable (ProgressUpdate) -> Void)?) throws -> ([UInt8], Int) {
        let descriptor = image.descriptor
        guard descriptor.sampleType == .unsignedInteger, descriptor.storageBits == 16,
              descriptor.components == [.grey], descriptor.planes.count == 1, descriptor.alpha == .absent else {
            throw CodecError(.unsupportedFeature, "Only unsigned 16-bit single-plane greyscale images can be encoded.")
        }
        guard descriptor.iccProfile == nil, image.metadata.entries.isEmpty else {
            throw CodecError(.unsupportedFeature, "Raw codestream output cannot carry ICC or metadata; none is silently dropped.")
        }
        let width = descriptor.width, height = descriptor.height, precision = descriptor.meaningfulBits
        let workspace = try workspaceBytes(planePixels: width * height, joinedBytes: 0)
        guard workspace <= limits.maximumWorkspaceBytes else {
            throw CodecError(.resourceLimitExceeded, "Encoder workspace exceeds the operation limit.")
        }
        guard try checkedAdd(image.storage.byteCount, workspace) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Image and workspace exceed the memory budget.")
        }
        let work = WorkGuard(limits: limits)
        try work.check()

        let isHT = parameters.blockCoding == .htj2k
        let cod = CodingStyleSegment(usesPrecincts: false, usesSOP: false, usesEPH: false, progression: 0,
                                     layers: 1, componentTransform: 0,
                                     decompositionLevels: parameters.decompositionLevels,
                                     codeBlockWidthExponent: parameters.codeBlockWidthExponent,
                                     codeBlockHeightExponent: parameters.codeBlockHeightExponent,
                                     codeBlockStyle: isHT ? 0x40 : 0, reversible: true, precinctExponents: [])
        let geometry = try Tier2.makeTileGeometry(x0: 0, x1: width, y0: 0, y1: height, codingStyle: cod)
        var exponents: [Int] = []
        for resolution in geometry.resolutions {
            for band in resolution.bands { exponents.append(precision + band.gain) }
        }
        let qcd = QuantizationSegment(style: .none, guardBits: guardBits, exponents: exponents, mantissas: [])

        // Input stage: read caller samples in place, validate the declared range.
        let shift = Int32(1) << Int32(precision - 1)
        let maximum = UInt16((1 << precision) - 1)
        let layout = descriptor.planes[0]
        let stride = width
        var plane = [Int32](repeating: 0, count: width * height)
        StorageTelemetry.recordWorkspaceAllocation(bytes: plane.count * 4)
        let mutation = SharedPathMutation.active
        let rowBytes = mutation == .ignoreRowStride ? width * layout.pixelStride : layout.rowBytes
        let order = mutation == .wrongByteOrder ? descriptor.byteOrder.opposite : descriptor.byteOrder
        try image.storage.withUnsafeBytes { bytes in
            guard bytes.count >= descriptor.requiredByteCount else {
                throw CodecError(.storageUnavailable, "Provider returned insufficient capacity.")
            }
            for y in 0..<height {
                try work.check()
                let rowOffset = layout.offset + y * rowBytes
                for x in 0..<width {
                    let sample = try loadUInt16(bytes, at: rowOffset + x * layout.pixelStride, order: order)
                    guard sample <= maximum else {
                        throw CodecError(.invalidArgument, "A sample exceeds the declared meaningful precision.")
                    }
                    plane[y * stride + x] = Int32(sample) - shift
                }
            }
        }
        try Wavelet53.forward(plane: &plane, stride: stride, x0: 0, x1: width, y0: 0, y1: height,
                              levels: cod.decompositionLevels, cancellation: work.check)

        let total = geometry.codeBlockCount
        var completed = 0
        progress?(try ProgressUpdate(phase: .processing, completedUnits: 0, totalUnits: total))
        let encodings = try encodeTileBlocks(
            plane: plane,
            stride: stride,
            geometry: geometry,
            qcd: qcd,
            blockCoding: parameters.blockCoding,
            work: work,
            completed: &completed,
            total: total,
            progress: progress
        )

        // Codestream assembly.
        var tile = ByteWriter(capacity: width * height / 2)
        try Tier2.encodePackets(geometry: geometry, encodings: encodings, into: &tile, cancellation: work.check)
        var out = ByteWriter(capacity: tile.count + 64)
        out.writeUInt16(Marker.soc)
        let size = ImageSizeSegment(capabilities: isHT ? 0x4000 : 0, width: width, height: height, originX: 0, originY: 0,
                                    tileWidth: width, tileHeight: height, tileOriginX: 0, tileOriginY: 0,
                                    components: [ComponentSignalling(precision: precision, signed: false,
                                                                     horizontalSeparation: 1, verticalSeparation: 1)])
        try CodestreamSyntax.writeSIZ(size, into: &out)
        if isHT {
            let cap = try ExtendedCapabilitiesSegment.losslessHTOnly(for: qcd)
            try CodestreamSyntax.writeCAP(cap, into: &out)
        }
        try CodestreamSyntax.writeCOD(cod, into: &out)
        try CodestreamSyntax.writeQCD(qcd, into: &out)
        let psot = 12 + 2 + tile.count
        guard psot <= Int(UInt32.max) else { throw CodecError(.resourceLimitExceeded, "Tile-part exceeds the Psot field.") }
        out.writeUInt16(Marker.sot)
        out.writeUInt16(10)
        out.writeUInt16(0)
        out.writeUInt32(UInt32(psot))
        out.writeUInt8(0)
        out.writeUInt8(1)
        out.writeUInt16(Marker.sod)
        out.writeBytes(tile.bytes)
        out.writeUInt16(Marker.eoc)
        return (out.bytes, workspace)
    }

    /// Extracts the decoded signed wavelet coefficient plane for each tile of `profile`
    /// without invoking inverse wavelet reconstruction or allocating pixel storage.
    internal static func extractTileCoefficients(
        bytes: [UInt8],
        profile: LosslessProfile
    ) throws -> [[Int32]] {
        let limits = try ResourceLimits()
        let work = WorkGuard(limits: limits)
        var completed = 0
        let total = max(1, profile.codeBlockCount)
        return try profile.tiles.map { tile in
            try decodeTileCoefficients(
                bytes: bytes,
                tile: tile,
                work: work,
                completed: &completed,
                total: total,
                progress: nil
            )
        }
    }

    // MARK: - Native Compressed-to-Compressed Transcoding (Coefficient Domain)

    /// Transcodes a lossless JPEG 2000 Part 1 or Part 15 (HTJ2K) codestream to `target`
    /// in the wavelet coefficient domain without allocating an intermediate `Image`
    /// or invoking inverse/forward wavelet transforms.
    static func transcode(
        bytes: [UInt8],
        profile: LosslessProfile,
        to target: TranscodeTarget,
        codecOptions: CodecOptions,
        limits: ResourceLimits,
        progress: (@Sendable (ProgressUpdate) -> Void)?
    ) throws -> ([UInt8], Int) {
        let workspace = try workspaceBytes(profile: profile)
        guard workspace <= limits.maximumWorkspaceBytes else {
            throw CodecError(.resourceLimitExceeded, "Transcoder workspace exceeds the operation limit.")
        }
        guard try checkedAdd(bytes.count, workspace) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Compressed input and workspace exceed the memory budget.")
        }
        let work = WorkGuard(limits: limits)
        try work.check()

        let isHT = (target == .htj2k)
        guard profile.isHTJ2K != isHT else {
            throw CodecError(
                .unsupportedFormat,
                "Transcoding requires converting between JPEG 2000 Part 1 and HTJ2K Part 15 (source is already \(profile.format))."
            )
        }
        let targetBlockCoding: CodecOptions.BlockCoding = isHT ? .htj2k : .part1
        let firstTile = profile.tiles[0]

        if let requested = codecOptions.decompositionLevels {
            for tile in profile.tiles where tile.codingStyle.decompositionLevels != requested {
                throw CodecError(
                    .unsupportedFeature,
                    "Changing wavelet decomposition levels (\(tile.codingStyle.decompositionLevels) -> \(requested)) requires wavelet reconstruction and is not supported on the coefficient transcoding path."
                )
            }
        }

        let xcb = codecOptions.codeBlockWidth.trailingZeroBitCount
        let ycb = codecOptions.codeBlockHeight.trailingZeroBitCount

        func makeTargetCOD(levels: Int) -> CodingStyleSegment {
            CodingStyleSegment(
                usesPrecincts: false, usesSOP: false, usesEPH: false, progression: 0,
                layers: 1, componentTransform: 0,
                decompositionLevels: levels,
                codeBlockWidthExponent: xcb,
                codeBlockHeightExponent: ycb,
                codeBlockStyle: isHT ? 0x40 : 0,
                reversible: true,
                precinctExponents: []
            )
        }

        func makeTargetQCD(for geometry: TileGeometry, tiles: [TileProfile]) -> QuantizationSegment {
            var exponents: [Int] = []
            for resolution in geometry.resolutions {
                for band in resolution.bands {
                    var exp = profile.precision + band.gain
                    for t in tiles where band.quantizationIndex < t.magnitudeBitPlanes.count {
                        let neededExp = t.magnitudeBitPlanes[band.quantizationIndex] - guardBits + 1
                        if neededExp > exp { exp = neededExp }
                    }
                    exponents.append(exp)
                }
            }
            return QuantizationSegment(style: .none, guardBits: guardBits, exponents: exponents, mantissas: [])
        }

        let targetTileGeometries: [TileGeometry] = try profile.tiles.map { tile in
            let tileCOD = makeTargetCOD(levels: tile.codingStyle.decompositionLevels)
            return try Tier2.makeTileGeometry(
                x0: tile.x0, x1: tile.x1, y0: tile.y0, y1: tile.y1, codingStyle: tileCOD
            )
        }
        let mainCOD = makeTargetCOD(levels: firstTile.codingStyle.decompositionLevels)
        let sameLevelsTiles = profile.tiles.filter {
            $0.codingStyle.decompositionLevels == firstTile.codingStyle.decompositionLevels
        }
        let mainQCD = makeTargetQCD(for: targetTileGeometries[0], tiles: sameLevelsTiles)
        let tileQCDs: [QuantizationSegment] = profile.tiles.enumerated().map { idx, tile in
            tile.codingStyle.decompositionLevels == firstTile.codingStyle.decompositionLevels
                ? mainQCD
                : makeTargetQCD(for: targetTileGeometries[idx], tiles: [tile])
        }

        var out = ByteWriter(capacity: max(bytes.count, 256))
        out.writeUInt16(Marker.soc)
        let size = ImageSizeSegment(
            capabilities: isHT ? 0x4000 : 0,
            width: profile.originX + profile.width,
            height: profile.originY + profile.height,
            originX: profile.originX,
            originY: profile.originY,
            tileWidth: profile.tileWidth,
            tileHeight: profile.tileHeight,
            tileOriginX: profile.tileOriginX,
            tileOriginY: profile.tileOriginY,
            components: [ComponentSignalling(precision: profile.precision, signed: false,
                                             horizontalSeparation: 1, verticalSeparation: 1)]
        )
        try CodestreamSyntax.writeSIZ(size, into: &out)
        if isHT {
            let allExponents = tileQCDs.flatMap(\.exponents)
            let capQCD = QuantizationSegment(style: .none, guardBits: guardBits, exponents: allExponents, mantissas: [])
            let cap = try ExtendedCapabilitiesSegment.losslessHTOnly(for: capQCD)
            try CodestreamSyntax.writeCAP(cap, into: &out)
        }
        try CodestreamSyntax.writeCOD(mainCOD, into: &out)
        try CodestreamSyntax.writeQCD(mainQCD, into: &out)

        let totalTargetBlocks = targetTileGeometries.reduce(0) { $0 + $1.codeBlockCount }
        let total = profile.codeBlockCount + totalTargetBlocks
        var completed = 0
        progress?(try ProgressUpdate(phase: .processing, completedUnits: 0, totalUnits: total))

        for (tileIndex, tile) in profile.tiles.enumerated() {
            try work.check()
            let plane = try decodeTileCoefficients(
                bytes: bytes,
                tile: tile,
                work: work,
                completed: &completed,
                total: total,
                progress: progress
            )
            let stride = tile.width
            let tileCOD = makeTargetCOD(levels: tile.codingStyle.decompositionLevels)
            let targetTileGeometry = targetTileGeometries[tileIndex]
            let tileQCD = tileQCDs[tileIndex]
            let encodings = try encodeTileBlocks(
                plane: plane,
                stride: stride,
                geometry: targetTileGeometry,
                qcd: tileQCD,
                blockCoding: targetBlockCoding,
                work: work,
                completed: &completed,
                total: total,
                progress: progress
            )
            var tileHeaderWriter = ByteWriter(capacity: 32)
            if tile.codingStyle.decompositionLevels != firstTile.codingStyle.decompositionLevels {
                try CodestreamSyntax.writeCOD(tileCOD, into: &tileHeaderWriter)
                try CodestreamSyntax.writeQCD(tileQCD, into: &tileHeaderWriter)
            }
            var tileWriter = ByteWriter(capacity: max(64, tile.width * tile.height / 2))
            try Tier2.encodePackets(geometry: targetTileGeometry, encodings: encodings, into: &tileWriter, cancellation: work.check)
            let psot = 12 + tileHeaderWriter.count + 2 + tileWriter.count
            guard psot <= Int(UInt32.max) else { throw CodecError(.resourceLimitExceeded, "Tile-part exceeds the Psot field.") }
            out.writeUInt16(Marker.sot)
            out.writeUInt16(10)
            out.writeUInt16(UInt16(tile.index))
            out.writeUInt32(UInt32(psot))
            out.writeUInt8(0)
            out.writeUInt8(1)
            out.writeBytes(tileHeaderWriter.bytes)
            out.writeUInt16(Marker.sod)
            out.writeBytes(tileWriter.bytes)
        }
        out.writeUInt16(Marker.eoc)
        return (out.bytes, workspace)
    }
}
