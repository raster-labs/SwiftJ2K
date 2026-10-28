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
    let footprint: Tier2.TileGeometryFootprint
    let geometry: TileGeometry
    let dataRanges: [Range<Int>]          // tile-part data ranges in part order
    let comments: [[UInt8]]               // COM payloads in tile-part order
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
    let mainHeaderComments: [[UInt8]]
    let componentRegistration: [UInt8]?
    let commentCount: Int
    let commentPayloadBytes: Int
    var format: String { isHTJ2K ? ScalarLosslessCodec.htj2kFormat : ScalarLosslessCodec.format }
    var codeBlockCount: Int { tiles.reduce(0) { $0 + $1.geometry.codeBlockCount } }
    var largestTilePixels: Int { tiles.map { $0.width * $0.height }.max() ?? 0 }
    var largestTileBytes: Int { tiles.map { $0.dataRanges.reduce(0) { $0 + $1.count } }.max() ?? 0 }
    var totalSourceGeometryBytes: Int { tiles.reduce(0) { $0 + $1.footprint.geometryBytes } }
    var largestDecodeStateBytes: Int { tiles.map(\.footprint.decodeStateBytes).max() ?? 0 }
    var totalCommentSegmentBytes: Int {
        mainHeaderComments.reduce(0) { $0 + 4 + $1.count }
            + tiles.reduce(0) { $0 + $1.comments.reduce(0) { $0 + 4 + $1.count } }
    }
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

    static func inspect(
        _ bytes: [UInt8],
        limits: ResourceLimits,
        metadataPolicy: MetadataPolicy = .preserve
    ) throws -> LosslessProfile {
        let parsed = try CodestreamSyntax.parse(bytes, limits: limits, metadataPolicy: metadataPolicy)
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
        guard parsed.regionsOfInterest.isEmpty,
              parsed.progressionChanges.isEmpty,
              parsed.tileOverrides.values.allSatisfy({
                  $0.regionsOfInterest.isEmpty && $0.progressionChanges.isEmpty
              }) else {
            throw CodecError(.unsupportedFeature, "RGN or POC markers require the general Part 1 pipeline.")
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
        var runningSourceGeometryBytes = 0
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
            // Preflight exact geometry footprint before allocating TileGeometry arrays.
            let footprint = try Tier2.preflightTileGeometry(x0: tx0, x1: tx1, y0: ty0, y1: ty1, codingStyle: cod)
            runningSourceGeometryBytes = try checkedAdd(runningSourceGeometryBytes, footprint.geometryBytes)
            guard runningSourceGeometryBytes <= limits.maximumWorkspaceBytes,
                  try checkedAdd(bytes.count, runningSourceGeometryBytes) <= limits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "Source tile geometry exceeds workspace or memory limits.")
            }
            StorageTelemetry.recordStage("source-geometry", bytes: footprint.geometryBytes)
            let geometry = try Tier2.makeTileGeometry(x0: tx0, x1: tx1, y0: ty0, y1: ty1, codingStyle: cod)
            tiles.append(TileProfile(index: tileIndex, x0: tx0, x1: tx1, y0: ty0, y1: ty1, codingStyle: cod,
                                     quantization: qcd, magnitudeBitPlanes: magnitudeBitPlanes,
                                     footprint: footprint, geometry: geometry,
                                     dataRanges: ordered.map(\.dataRange),
                                     comments: ordered.flatMap(\.comments)))
        }
        guard tiles.count == tilesWide * tilesHigh else {
            throw CodecError(.malformedInput, "Codestream lacks tile-parts for \(tilesWide * tilesHigh - tiles.count) of its tiles.")
        }
        return LosslessProfile(width: size.width - size.originX, height: size.height - size.originY,
                               originX: size.originX, originY: size.originY,
                               tileWidth: size.tileWidth, tileHeight: size.tileHeight,
                               tileOriginX: size.tileOriginX, tileOriginY: size.tileOriginY,
                               precision: component.precision, isHTJ2K: parsed.isHTJ2K, tiles: tiles,
                               mainHeaderComments: parsed.mainHeaderComments,
                               componentRegistration: parsed.componentRegistration,
                               commentCount: parsed.commentCount,
                               commentPayloadBytes: parsed.commentPayloadBytes)
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
        backend: Backend = .scalarCPU,
        completed: inout Int,
        total: Int,
        progress: (@Sendable (ProgressUpdate) -> Void)?
    ) throws -> [Int32] {
        let tileBytes: [UInt8]
        let tileRange: Range<Int>
        if tile.dataRanges.count == 1 {
            tileBytes = bytes; tileRange = tile.dataRanges[0]
        } else {
            let joinedCount = tile.dataRanges.reduce(0) { $0 + $1.count }
            StorageTelemetry.recordStage("joined-tile-parts", bytes: 32 + joinedCount)
            StorageTelemetry.recordWorkspaceAllocation(bytes: joinedCount)
            var joined: [UInt8] = []
            joined.reserveCapacity(joinedCount)
            for range in tile.dataRanges { joined.append(contentsOf: bytes[range]) }
            tileBytes = joined; tileRange = 0..<joined.count
        }
        let geometry = tile.geometry
        let style = CodeBlockStyle(bits: tile.codingStyle.codeBlockStyle)
        StorageTelemetry.recordStage("decode-state", bytes: tile.footprint.decodeStateBytes)
        let contributions = try Tier2.decodePackets(
            geometry: geometry,
            codingStyle: tile.codingStyle,
            bytes: tileBytes,
            range: tileRange,
            cancellation: work.check
        )
        let stride = tile.width
        let planeCount = tile.width * tile.height
        StorageTelemetry.recordStage("coefficient-plane", bytes: planeCount * 4)
        StorageTelemetry.recordWorkspaceAllocation(bytes: planeCount * 4)
        var plane = [Int32](repeating: 0, count: planeCount)
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
                            coefficients = try AcceleratedCodec.decodeHTCleanup(
                                block: rawBlock,
                                width: block.width,
                                height: block.height,
                                kMax: mb,
                                missingMSBs: effectiveMissingMSBs,
                                backend: backend
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
                       limits: ResourceLimits, backend: Backend = .scalarCPU,
                       progress: (@Sendable (ProgressUpdate) -> Void)?) throws -> (Image, Int) {
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
                                      work: work, backend: backend, progress: progress)
        } catch {
            destination.invalidateAfterFailure()
            throw error
        }
    }

    private static func decodeAdmitted(bytes: [UInt8], profile: LosslessProfile, into destination: ImageDestination,
                                       workspace: Int, work: WorkGuard, backend: Backend,
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
                    backend: backend,
                    completed: &completed,
                    total: total,
                    progress: progress
                )
                try AcceleratedCodec.inverseWavelet53(
                    plane: &plane,
                    stride: stride,
                    x0: tile.x0,
                    x1: tile.x1,
                    y0: tile.y0,
                    y1: tile.y1,
                    levels: tile.codingStyle.decompositionLevels,
                    backend: backend,
                    cancellation: work.check
                )
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
        let backend: Backend

        init(
            decompositionLevels: Int,
            codeBlockWidthExponent: Int,
            codeBlockHeightExponent: Int,
            blockCoding: CodecOptions.BlockCoding,
            backend: Backend = .scalarCPU
        ) {
            self.decompositionLevels = decompositionLevels
            self.codeBlockWidthExponent = codeBlockWidthExponent
            self.codeBlockHeightExponent = codeBlockHeightExponent
            self.blockCoding = blockCoding
            self.backend = backend
        }
    }

    private static func encodeTileBlocks(
        plane: [Int32],
        stride: Int,
        geometry: TileGeometry,
        qcd: QuantizationSegment,
        blockCoding: CodecOptions.BlockCoding,
        backend: Backend = .scalarCPU,
        work: WorkGuard,
        maxRetainedEncodedBytes: Int = Int.max,
        runningEncodedBytes: inout Int,
        recordBlockStages: Bool = false,
        completed: inout Int,
        total: Int,
        progress: (@Sendable (ProgressUpdate) -> Void)?
    ) throws -> [[[[CodeBlockEncoding]]]] {
        var encodings: [[[[CodeBlockEncoding]]]] = []
        encodings.reserveCapacity(geometry.resolutions.count)
        var coefficients: [Int32] = []
        coefficients.reserveCapacity(BitPlaneCoder.maximumCoefficients)
        let shouldRecordBlockStage = recordBlockStages && StorageTelemetry.recorder != nil
        for resolution in geometry.resolutions {
            var perPrecinct: [[[CodeBlockEncoding]]] = []
            perPrecinct.reserveCapacity(resolution.precincts.count)
            for precinct in resolution.precincts {
                var perBand: [[CodeBlockEncoding]] = []
                perBand.reserveCapacity(precinct.bands.count)
                for precinctBand in precinct.bands {
                    let band = resolution.bands[precinctBand.bandIndex]
                    let mb = qcd.guardBits + qcd.exponents[band.quantizationIndex] - 1
                    var perBlock: [CodeBlockEncoding] = []
                    perBlock.reserveCapacity(precinctBand.blocks.count)
                    for block in precinctBand.blocks {
                        try work.check()
                        guard runningEncodedBytes <= maxRetainedEncodedBytes else {
                            throw CodecError(.resourceLimitExceeded, "Encoded code-block payloads exceed the workspace or memory admission budget.")
                        }
                        let blockMaxOutputBytes: Int
                        if maxRetainedEncodedBytes == Int.max {
                            blockMaxOutputBytes = Int.max
                        } else {
                            blockMaxOutputBytes = max(0, maxRetainedEncodedBytes - runningEncodedBytes - 32)
                        }
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
                                magnitudeBitPlanes: mb,
                                maximumOutputBytes: blockMaxOutputBytes
                            )
                        case .htj2k:
                            let coded = try AcceleratedCodec.encodeHTCleanup(
                                coefficients: coefficients,
                                width: block.width,
                                height: block.height,
                                bandShift: 0,
                                maximumOutputBytes: blockMaxOutputBytes,
                                backend: backend
                            )
                            encoding = CodeBlockEncoding(
                                data: coded,
                                passCount: coded.isEmpty ? 0 : 1,
                                zeroBitPlanes: coded.isEmpty ? mb : (mb - 1)
                            )
                        }
                        let blockRetainedBytes = encoding.data.isEmpty ? 0 : (32 + max(encoding.data.count, encoding.data.capacity))
                        let nextEncodedBytes = try checkedAdd(runningEncodedBytes, blockRetainedBytes)
                        guard nextEncodedBytes <= maxRetainedEncodedBytes else {
                            throw CodecError(.resourceLimitExceeded, "Retained code-block encodings exceed the workspace or memory admission budget.")
                        }
                        runningEncodedBytes = nextEncodedBytes
                        if shouldRecordBlockStage && blockRetainedBytes > 0 {
                            StorageTelemetry.recordStage("block-encoding", bytes: blockRetainedBytes)
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
        try AcceleratedCodec.forwardWavelet53(
            plane: &plane,
            stride: stride,
            x0: 0,
            x1: width,
            y0: 0,
            y1: height,
            levels: cod.decompositionLevels,
            backend: parameters.backend,
            cancellation: work.check
        )

        let total = geometry.codeBlockCount
        var completed = 0
        var encodeRunningBytes = 0
        progress?(try ProgressUpdate(phase: .processing, completedUnits: 0, totalUnits: total))
        let encodings = try encodeTileBlocks(
            plane: plane,
            stride: stride,
            geometry: geometry,
            qcd: qcd,
            blockCoding: parameters.blockCoding,
            backend: parameters.backend,
            work: work,
            runningEncodedBytes: &encodeRunningBytes,
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
        metadataPolicy: MetadataPolicy = .preserve,
        limits: ResourceLimits,
        backend: Backend = .scalarCPU,
        progress: (@Sendable (ProgressUpdate) -> Void)?
    ) throws -> (Data, Int) {
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

        // 1. Preflight target tile geometry footprints using checked scalar arithmetic
        // BEFORE allocating any target TileGeometry arrays.
        let targetFootprints: [Tier2.TileGeometryFootprint] = try profile.tiles.map { tile in
            let tileCOD = makeTargetCOD(levels: tile.codingStyle.decompositionLevels)
            return try Tier2.preflightTileGeometry(
                x0: tile.x0, x1: tile.x1, y0: tile.y0, y1: tile.y1, codingStyle: tileCOD
            )
        }
        let totalTargetBlocks = targetFootprints.reduce(0) { $0 + $1.codeBlockCount }
        let sourceGeometryBytes = profile.totalSourceGeometryBytes
        let targetGeometryBytes = try targetFootprints.reduce(0) { try checkedAdd($0, $1.geometryBytes) }
        let metadataCopyBytes = try checkedAdd(
            (metadataPolicy == .preserve) ? profile.totalCommentSegmentBytes : 0,
            profile.componentRegistration?.count ?? 0
        )
        let inputCopyBytes = try checkedAdd(32, bytes.count)
        let persistentStructureBytes = try checkedAdd(
            try checkedAdd(sourceGeometryBytes, targetGeometryBytes),
            try checkedAdd(inputCopyBytes, metadataCopyBytes)
        )
        var peakWorkspace = persistentStructureBytes
        guard peakWorkspace <= limits.maximumWorkspaceBytes else {
            throw CodecError(.resourceLimitExceeded, "Transcoder preflight target geometry exceeds the workspace limit.")
        }
        guard try checkedAdd(bytes.count, peakWorkspace) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Compressed input, target geometry and metadata exceed the memory budget.")
        }

        // Now that target geometry has been admitted, allocate targetTileGeometries.
        StorageTelemetry.recordStage("target-geometry", bytes: targetGeometryBytes)
        StorageTelemetry.recordWorkspaceAllocation(bytes: targetGeometryBytes)
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

        // 2. Preflight exact main-header byte count and admit `out` before reserving capacity.
        let mainCommentBytes = (metadataPolicy == .preserve)
            ? profile.mainHeaderComments.reduce(0) { $0 + 4 + $1.count }
            : 0
        let crgSegmentBytes = profile.componentRegistration.map { 4 + $0.count } ?? 0
        let exactMainHeaderBytes = try checkedAdd(
            2 + (4 + 38 + 3) + (isHT ? 10 : 0) + (4 + 12) + (4 + 2 + mainQCD.exponents.count),
            try checkedAdd(crgSegmentBytes, mainCommentBytes)
        )
        guard exactMainHeaderBytes <= limits.maximumCompressedBytes else {
            throw CodecError(.resourceLimitExceeded, "Transcoded main header exceeds the compressed-size limit.")
        }
        let headerOutAllocBytes = exactMainHeaderBytes
        let headerWorkspace = try checkedAdd(persistentStructureBytes, headerOutAllocBytes)
        peakWorkspace = max(peakWorkspace, headerWorkspace)
        guard peakWorkspace <= limits.maximumWorkspaceBytes,
              try checkedAdd(bytes.count, peakWorkspace) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Compressed input, workspace and header output exceed the admission budget.")
        }
        StorageTelemetry.recordStage("output-writer", bytes: headerOutAllocBytes)
        var out = try BoundedByteWriter(
            reserving: exactMainHeaderBytes, maximumBytes: exactMainHeaderBytes,
            maximumAllocationBytes: headerOutAllocBytes
        )
        try out.writeUInt16Checked(Marker.soc)
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
        if let crg = profile.componentRegistration {
            try out.writeSegment(marker: Marker.crg, payload: crg)
        }
        if metadataPolicy == .preserve {
            for comment in profile.mainHeaderComments {
                try out.writeSegment(marker: Marker.com, payload: comment)
            }
        }

        let total = profile.codeBlockCount + totalTargetBlocks
        var completed = 0
        progress?(try ProgressUpdate(phase: .processing, completedUnits: 0, totalUnits: total))
        let blockScratch = BitPlaneCoder.maximumCoefficients * (4 + 4 + 1) + 66 * 66 + 4096

        for (tileIndex, tile) in profile.tiles.enumerated() {
            try work.check()
            let tileDataBytes = tile.dataRanges.reduce(0) { $0 + $1.count }
            let tileJoinedExtra = tile.dataRanges.count > 1 ? (32 + tileDataBytes) : 0
            let planeBytes = try checkedMultiply(tile.width * tile.height, 4)
            let tileDecodeLive = try checkedAdd(
                try checkedAdd(persistentStructureBytes, out.allocatedBytes),
                try checkedAdd(
                    try checkedAdd(tile.footprint.decodeStateBytes, tileDataBytes + tileJoinedExtra),
                    try checkedAdd(planeBytes, blockScratch)
                )
            )
            peakWorkspace = max(peakWorkspace, tileDecodeLive)
            guard peakWorkspace <= limits.maximumWorkspaceBytes,
                  try checkedAdd(bytes.count, tileDecodeLive) <= limits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "Tile decode workspace exceeds workspace or memory limits.")
            }

            var plane = try decodeTileCoefficients(
                bytes: bytes,
                tile: tile,
                work: work,
                backend: backend,
                completed: &completed,
                total: total,
                progress: progress
            )
            let stride = tile.width
            let tileCOD = makeTargetCOD(levels: tile.codingStyle.decompositionLevels)
            let targetFootprint = targetFootprints[tileIndex]
            let targetTileGeometry = targetTileGeometries[tileIndex]
            let tileQCD = tileQCDs[tileIndex]

            // 3. Admit target block-encoding struct state before encoding blocks, and compute
            // the remaining byte budget for retained encoded block payloads.
            let liveBeforeBlockPayloads = try checkedAdd(
                try checkedAdd(persistentStructureBytes, out.allocatedBytes),
                try checkedAdd(
                    targetFootprint.encodeStateStructBytes,
                    try checkedAdd(planeBytes, blockScratch)
                )
            )
            guard liveBeforeBlockPayloads <= limits.maximumWorkspaceBytes,
                  try checkedAdd(bytes.count, liveBeforeBlockPayloads) <= limits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "Target block encoding state exceeds workspace or memory limits.")
            }
            let wsRemainingForBlocks = limits.maximumWorkspaceBytes - liveBeforeBlockPayloads
            let memRemainingForBlocks = limits.maximumMemoryBytes - (bytes.count + liveBeforeBlockPayloads)
            let compRemainingForBlocks = max(0, limits.maximumCompressedBytes - out.count)
            // Each non-empty block adds a 32-byte array header in `encodings` on top of payload bytes.
            let maxHeaderOverhead = try checkedMultiply(targetFootprint.codeBlockCount, 32)
            let maxRetainedEncodedBytes = min(
                min(wsRemainingForBlocks, memRemainingForBlocks),
                try checkedAdd(compRemainingForBlocks, maxHeaderOverhead)
            )

            var tileEncodedRetainedBytes = 0
            var encodings = try encodeTileBlocks(
                plane: plane,
                stride: stride,
                geometry: targetTileGeometry,
                qcd: tileQCD,
                blockCoding: targetBlockCoding,
                backend: backend,
                work: work,
                maxRetainedEncodedBytes: maxRetainedEncodedBytes,
                runningEncodedBytes: &tileEncodedRetainedBytes,
                recordBlockStages: true,
                completed: &completed,
                total: total,
                progress: progress
            )
            // Release the coefficient plane before packet assembly so `plane` and
            // `tileWriter` are never simultaneously live.
            plane = []

            var tileEncodedPayloadBytes = 0
            for res in encodings {
                for prec in res {
                    for band in prec {
                        for enc in band {
                            tileEncodedPayloadBytes = try checkedAdd(tileEncodedPayloadBytes, enc.data.count)
                        }
                    }
                }
            }
            StorageTelemetry.recordWorkspaceAllocation(bytes: tileEncodedPayloadBytes)
            let tileEncodeWorkspace = try checkedAdd(
                liveBeforeBlockPayloads,
                tileEncodedRetainedBytes
            )
            peakWorkspace = max(peakWorkspace, tileEncodeWorkspace)

            // 4. Preflight exact tileHeaderWriter size and bounded tileWriter capacity
            // BEFORE allocating tileHeaderWriter or tileWriter.
            let overrideHeaderBytes = (tile.codingStyle.decompositionLevels != firstTile.codingStyle.decompositionLevels)
                ? (16 + (6 + tileQCD.exponents.count))
                : 0
            let tileCommentBytes = (metadataPolicy == .preserve)
                ? tile.comments.reduce(0) { $0 + 4 + $1.count }
                : 0
            let exactTileHeaderBytes = try checkedAdd(overrideHeaderBytes, tileCommentBytes)
            let estimatedPacketHeaders = try checkedAdd(
                try checkedMultiply(targetFootprint.precinctCount, 8),
                try checkedMultiply(targetFootprint.codeBlockCount, 6)
            )
            let initialTileWriterCap = try checkedAdd(tileEncodedPayloadBytes, max(32, estimatedPacketHeaders))

            // While `Tier2.encodePackets` runs, `encodings` (struct + retained payloads) and
            // `tileHeaderWriter` + `tileWriter` are live alongside `out` (before appending).
            let liveDuringPacketEncode = try checkedAdd(
                try checkedAdd(persistentStructureBytes, out.allocatedBytes),
                try checkedAdd(targetFootprint.encodeStateStructBytes, tileEncodedRetainedBytes)
            )
            let headerWriterAlloc = exactTileHeaderBytes
            let minPacketWriterNeeded = try checkedAdd(headerWriterAlloc, tileEncodedPayloadBytes)
            guard try checkedAdd(liveDuringPacketEncode, minPacketWriterNeeded) <= limits.maximumWorkspaceBytes,
                  try checkedAdd(bytes.count, try checkedAdd(liveDuringPacketEncode, minPacketWriterNeeded)) <= limits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "Packet assembly workspace exceeds workspace or memory limits.")
            }
            let wsAvailForTileWriter = limits.maximumWorkspaceBytes - liveDuringPacketEncode - headerWriterAlloc
            let memAvailForTileWriter = limits.maximumMemoryBytes - bytes.count - liveDuringPacketEncode - headerWriterAlloc
            // Final codestream adds SOT (12) + tileHeader + SOD (2) + tileWriter + EOC (2) = 16 + tileHeader + tileWriter.
            let compAvailForTileWriter = limits.maximumCompressedBytes - out.count - 16 - exactTileHeaderBytes
            let maxTileWriterBytes = min(min(wsAvailForTileWriter, memAvailForTileWriter), compAvailForTileWriter)
            guard maxTileWriterBytes >= tileEncodedPayloadBytes else {
                throw CodecError(.resourceLimitExceeded, "Transcoded packet stream exceeds the compressed-size or memory limit.")
            }
            let reservedTileWriterCap = min(initialTileWriterCap, maxTileWriterBytes)
            StorageTelemetry.recordStage("packet-writer", bytes: headerWriterAlloc + reservedTileWriterCap)

            var tileHeaderWriter = try BoundedByteWriter(
                reserving: exactTileHeaderBytes, maximumBytes: exactTileHeaderBytes,
                maximumAllocationBytes: headerWriterAlloc
            )
            if tile.codingStyle.decompositionLevels != firstTile.codingStyle.decompositionLevels {
                try CodestreamSyntax.writeCOD(tileCOD, into: &tileHeaderWriter)
                try CodestreamSyntax.writeQCD(tileQCD, into: &tileHeaderWriter)
            }
            if metadataPolicy == .preserve {
                for comment in tile.comments {
                    try tileHeaderWriter.writeSegment(marker: Marker.com, payload: comment)
                }
            }
            var tileWriter = try BoundedByteWriter(
                reserving: reservedTileWriterCap, maximumBytes: maxTileWriterBytes,
                maximumAllocationBytes: min(wsAvailForTileWriter, memAvailForTileWriter)
            )
            try Tier2.encodePackets(geometry: targetTileGeometry, encodings: encodings, into: &tileWriter, cancellation: work.check)
            // Release retained block encodings before copying assembled packets into `out`.
            encodings = []

            let packetAssemblyBytes = try checkedAdd(tileHeaderWriter.count, tileWriter.count)
            StorageTelemetry.recordWorkspaceAllocation(bytes: packetAssemblyBytes)
            let packetAssemblyAlloc = try checkedAdd(tileHeaderWriter.allocatedBytes, tileWriter.allocatedBytes)
            let tilePacketWorkspace = try checkedAdd(
                liveDuringPacketEncode,
                try checkedAdd(tileHeaderWriter.allocatedBytes, tileWriter.peakAllocationBytes)
            )
            peakWorkspace = max(peakWorkspace, tilePacketWorkspace)
            guard peakWorkspace <= limits.maximumWorkspaceBytes,
                  try checkedAdd(bytes.count, tilePacketWorkspace) <= limits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "Transcoder packet assembly workspace exceeds the operation limit.")
            }

            let psot = 12 + tileHeaderWriter.count + 2 + tileWriter.count
            guard psot <= Int(UInt32.max) else { throw CodecError(.resourceLimitExceeded, "Tile-part exceeds the Psot field.") }
            let projectedOutputBytes = try checkedAdd(out.count, psot + 2)
            guard projectedOutputBytes <= limits.maximumCompressedBytes else {
                throw CodecError(.resourceLimitExceeded, "Transcoded output exceeds the compressed-size limit.")
            }
            // Encodings have been released. Admission includes both the old and
            // replacement output buffers during growth, before either is allocated.
            let appendOtherWorkspace = try checkedAdd(persistentStructureBytes, packetAssemblyAlloc)
            let appendOtherResident = try checkedAdd(bytes.count, appendOtherWorkspace)
            guard appendOtherWorkspace <= limits.maximumWorkspaceBytes,
                  appendOtherResident <= limits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "Packet workspace exceeds the output admission budget.")
            }
            let outputAllocationBudget = min(
                limits.maximumWorkspaceBytes - appendOtherWorkspace,
                limits.maximumMemoryBytes - appendOtherResident
            )
            try out.updateBudget(maximumBytes: projectedOutputBytes, maximumAllocationBytes: outputAllocationBudget)
            // Include EOC in the one reservation, avoiding a second whole-output
            // reallocation just to append its last two bytes.
            try out.reserveCapacity(projectedOutputBytes)
            peakWorkspace = max(peakWorkspace, try checkedAdd(appendOtherWorkspace, out.peakAllocationBytes))
            try out.writeUInt16Checked(Marker.sot)
            try out.writeUInt16Checked(10)
            try out.writeUInt16Checked(UInt16(tile.index))
            try out.writeUInt32Checked(UInt32(psot))
            try out.writeUInt8Checked(0)
            try out.writeUInt8Checked(1)
            try out.writeBytesChecked(from: tileHeaderWriter)
            try out.writeUInt16Checked(Marker.sod)
            try out.writeBytesChecked(from: tileWriter)
        }
        try out.writeUInt16Checked(Marker.eoc)
        guard out.count <= limits.maximumCompressedBytes else {
            throw CodecError(.resourceLimitExceeded, "Transcoded output exceeds the compressed-size limit.")
        }
        // The input/profile and owned output are still live while Data copies the
        // final bytes. Admit that overlap here, not after returning another Array.
        let publicationWorkspace = try checkedAdd(
            persistentStructureBytes, try checkedAdd(out.allocatedBytes, out.count)
        )
        guard publicationWorkspace <= limits.maximumWorkspaceBytes,
              try checkedAdd(bytes.count, publicationWorkspace) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Publishing transcoded Data exceeds the admission budget.")
        }
        try work.check()
        StorageTelemetry.recordStage("output-data", bytes: out.count)
        let output = try out.copyData()
        peakWorkspace = max(peakWorkspace, publicationWorkspace)
        return (output, peakWorkspace)
    }
}
