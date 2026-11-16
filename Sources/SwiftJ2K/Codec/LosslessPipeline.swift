// SPDX-License-Identifier: MIT
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
import Synchronization

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
    var isHTOnlyFast: Bool { (codingStyle.codeBlockStyle & 0xC0) == 0x40 }
}

/// A validated description of a codestream the scalar path can decode or transcode.
struct LosslessProfile: Sendable {
    let width: Int                        // image area on the reference grid
    let height: Int
    let originX: Int, originY: Int        // XOsiz, YOsiz
    let tileWidth: Int, tileHeight: Int   // XTsiz, YTsiz
    let tileOriginX: Int, tileOriginY: Int
    let precision: Int
    let signed: Bool
    let isHTJ2K: Bool
    let tiles: [TileProfile]
    let mainHeaderComments: [[UInt8]]
    let componentRegistration: [UInt8]?
    let commentCount: Int
    let commentPayloadBytes: Int
    let retainedMetadataBytes: Int
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
    var decompositionLevels: Int {
        tiles.map(\.codingStyle.decompositionLevels).min() ?? 0
    }
    func effectiveReductionLevels(reductionLevels: Int) -> Int {
        var effective = min(max(0, reductionLevels), decompositionLevels)
        while effective > 0 {
            let rx0 = Wavelet53.ceilDivPowerOfTwo(originX, effective)
            let rx1 = Wavelet53.ceilDivPowerOfTwo(originX + width, effective)
            let ry0 = Wavelet53.ceilDivPowerOfTwo(originY, effective)
            let ry1 = Wavelet53.ceilDivPowerOfTwo(originY + height, effective)
            if rx1 > rx0 && ry1 > ry0 {
                break
            }
            effective -= 1
        }
        return effective
    }
    func reducedDimensions(reductionLevels: Int) -> (width: Int, height: Int) {
        let effective = effectiveReductionLevels(reductionLevels: reductionLevels)
        guard effective > 0 else { return (width, height) }
        let rx0 = Wavelet53.ceilDivPowerOfTwo(originX, effective)
        let rx1 = Wavelet53.ceilDivPowerOfTwo(originX + width, effective)
        let ry0 = Wavelet53.ceilDivPowerOfTwo(originY, effective)
        let ry1 = Wavelet53.ceilDivPowerOfTwo(originY + height, effective)
        return (rx1 - rx0, ry1 - ry0)
    }
}

/// Cooperative cancellation plus the operation deadline from `ResourceLimits`.
struct WorkGuard: Sendable {
    private let deadline: ContinuousClock.Instant
    private let alwaysCheck: Bool
    init(limits: ResourceLimits) {
        deadline = ContinuousClock.now.advanced(by: .seconds(limits.deadlineSeconds))
        alwaysCheck = limits.deadlineSeconds <= 0.05
    }
    @inline(__always)
    func check() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now <= deadline else {
            throw CodecError(.resourceLimitExceeded, "Operation deadline elapsed.")
        }
    }
    @inline(__always)
    func checkAmortized(_ iter: Int) throws {
        if alwaysCheck || (iter & 63) == 0 {
            try check()
        }
    }
}

internal final class AtomicByteAccumulator: Sendable {
    private let value = Atomic<Int>(0)
    private let limit: Int

    init(initial: Int = 0, limit: Int) {
        value.store(initial, ordering: .relaxed)
        self.limit = limit
    }

    var current: Int { value.load(ordering: .acquiring) }

    @inline(__always)
    func remainingBeforeEncode() throws -> Int {
        let cur = value.load(ordering: .relaxed)
        guard cur <= limit else {
            throw CodecError(.resourceLimitExceeded, "Encoded code-block payloads exceed the workspace or memory admission budget.")
        }
        return limit == Int.max ? Int.max : max(0, limit - cur - 32)
    }

    @inline(__always)
    func tryAdd(_ delta: Int) throws {
        guard delta > 0 else { return }
        while true {
            let cur = value.load(ordering: .relaxed)
            let (next, overflow) = cur.addingReportingOverflow(delta)
            if overflow || next > limit {
                throw CodecError(.resourceLimitExceeded, "Retained code-block encodings exceed the workspace or memory admission budget.")
            }
            if value.compareExchange(expected: cur, desired: next, ordering: .acquiringAndReleasing).exchanged {
                return
            }
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
        metadataPolicy: MetadataPolicy = .preserve,
        allowSignedWaveletTranscode: Bool = false
    ) throws -> LosslessProfile {
        let parsed = try CodestreamSyntax.parse(bytes, limits: limits, metadataPolicy: metadataPolicy)
        let size = parsed.size
        guard size.capabilities & 0x8000 == 0 else {
            throw CodecError(.unsupportedFeature, "Rsiz signals Part 2 extensions (0x8000), which are not supported.")
        }
        guard parsed.componentBitDepth == nil,
              parsed.mctTables.isEmpty,
              parsed.mccStages.isEmpty,
              parsed.mco == nil,
              parsed.tileOverrides.values.allSatisfy({
                  $0.mctFragments.isEmpty && $0.mccFragments.isEmpty && $0.mco == nil
              }),
              parsed.extendedCapabilities?.hasPart2 != true else {
            throw CodecError(.unsupportedFeature, "Part 2 multi-component transform markers require the general pipeline.")
        }
        if let cap = parsed.extendedCapabilities {
            guard !cap.multiHT else {
                throw CodecError(.unsupportedFeature, "Multiple HT sets per code-block (MULTIHT) are not supported.")
            }
            guard !cap.heterogeneousTileParts else {
                throw CodecError(.unsupportedFeature, "Heterogeneous HTJ2K tile-parts (HETERO) are not supported.")
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
        if !allowSignedWaveletTranscode {
            guard !component.signed else { throw CodecError(.unsupportedFeature, "Signed components are not supported.") }
        }
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
        var runningSourceGeometryBytes = parsed.retainedMetadataBytes
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
                               precision: component.precision, signed: component.signed, isHTJ2K: parsed.isHTJ2K, tiles: tiles,
                               mainHeaderComments: parsed.mainHeaderComments,
                               componentRegistration: parsed.componentRegistration,
                               commentCount: parsed.commentCount,
                               commentPayloadBytes: parsed.commentPayloadBytes,
                               retainedMetadataBytes: parsed.retainedMetadataBytes)
    }

    private static func validateCodingStyle(_ cod: CodingStyleSegment, quantization qcd: QuantizationSegment) throws {
        guard cod.reversible else { throw CodecError(.unsupportedFeature, "The irreversible 9/7 wavelet is not supported.") }
        if (cod.codeBlockStyle & 0x40) != 0 && (cod.codeBlockStyle & 0x80) == 0 {
            guard (cod.codeBlockStyle & 0x3E) == 0 else {
                throw CodecError(.malformedInput, "COD/COC sets reserved code-block style bits in HTJ2K mode.")
            }
            guard (cod.codeBlockStyle & 0x01) == 0 else {
                throw CodecError(.unsupportedFeature, "HTJ2K code-block style bit 0 (0x01) is not supported.")
            }
        }
        guard cod.componentTransform == 0 else {
            throw CodecError(.malformedInput, "A component transform is signalled for a single component.")
        }
        guard qcd.style == .none else { throw CodecError(.unsupportedFeature, "Quantised (lossy) codestreams are not supported.") }
    }

    /// Bound on algorithm workspace (MEM-10): one `Int32` coefficient plane of
    /// the largest tile, the largest joined tile data, per-block scratch, plus
    /// any retained ancillary/header parser metadata live on `profile`.
    static func workspaceBytes(profile: LosslessProfile) throws -> Int {
        try checkedAdd(
            try workspaceBytes(planePixels: profile.largestTilePixels, joinedBytes: profile.largestTileBytes),
            profile.retainedMetadataBytes
        )
    }
    static func workspaceBytes(planePixels: Int, joinedBytes: Int) throws -> Int {
        let plane = try checkedMultiply(planePixels, 4)
        let blockScratch = BitPlaneCoder.maximumCoefficients * (4 + 4 + 1) + 66 * 66 + 4096
        return try checkedAdd(checkedAdd(plane, joinedBytes), blockScratch)
    }

    // MARK: - Shared Tile Tier-2 + Tier-1 Coefficient Decoding

    private struct LosslessDecodeBlockTask: Sendable {
        let resIdx: Int
        let precIdx: Int
        let pbIdx: Int
        let cbIdx: Int
        let width: Int
        let height: Int
        let planeOffset: Int
        let orientation: BandOrientation
        let mb: Int
    }

    private struct LosslessEncodeBlockTask: Sendable {
        let resIdx: Int
        let precIdx: Int
        let pbIdx: Int
        let cbIdx: Int
        let width: Int
        let height: Int
        let planeOffset: Int
        let orientation: BandOrientation
        let mb: Int
    }

    private static func decodeTileCoefficients(
        bytes: [UInt8],
        tile: TileProfile,
        work: WorkGuard,
        backend: Backend = .scalarCPU,
        maxResolutionLevel: Int? = nil,
        planeWidth: Int? = nil,
        planeHeight: Int? = nil,
        maxExtraWorkspaceBytes: Int = Int.max,
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
            maxResolutionLevel: maxResolutionLevel,
            bytes: tileBytes,
            range: tileRange,
            cancellation: work.check
        )
        let stride = planeWidth ?? tile.width
        let height = planeHeight ?? tile.height
        let planeCount = stride * height
        StorageTelemetry.recordStage("coefficient-plane", bytes: planeCount * 4)
        StorageTelemetry.recordWorkspaceAllocation(bytes: planeCount * 4)
        var plane = [Int32](repeating: 0, count: planeCount)
        guard planeCount > 0 else { return plane }

        let effectiveMaxRes = min(maxResolutionLevel ?? (geometry.resolutions.count - 1), geometry.resolutions.count - 1)
        let requestedWorkers: Int
        if progress != nil {
            requestedWorkers = 1
        } else {
            let budgetWorkers = maxExtraWorkspaceBytes == Int.max ? Int.max : (1 + max(0, maxExtraWorkspaceBytes / 65_536))
            requestedWorkers = min(AcceleratedCodec.activeWorkerLimit, budgetWorkers)
        }

        if requestedWorkers <= 1 {
            let preRecordedHT = backend == .accelerated && tile.isHTOnlyFast
            if preRecordedHT {
                AcceleratedCodec.recordSIMDDispatch()
            }
            var ebcotWorkspace = EBCOTWorkspace()
            try plane.withUnsafeMutableBufferPointer { planeBuf in
                guard let planeBase = planeBuf.baseAddress else { return }
                for resolution in geometry.resolutions where resolution.index <= effectiveMaxRes {
                    for (p, precinct) in resolution.precincts.enumerated() {
                        for (b, precinctBand) in precinct.bands.enumerated() {
                            let band = resolution.bands[precinctBand.bandIndex]
                            let mb = tile.magnitudeBitPlanes[band.quantizationIndex]
                            for (k, block) in precinctBand.blocks.enumerated() {
                                try work.checkAmortized(completed)
                                let contribution = contributions[resolution.index][p][b][k]
                                completed += 1
                                if contribution.included && contribution.passes > 0 {
                                    let blockOffset = (band.planeY + block.y0 - band.y0) * stride + band.planeX + block.x0 - band.x0
                                    try decodeSingleLosslessBlock(
                                        contribution: contribution,
                                        width: block.width,
                                        height: block.height,
                                        orientation: band.orientation,
                                        mb: mb,
                                        style: style,
                                        backend: backend,
                                        destination: planeBase.advanced(by: blockOffset),
                                        stride: stride,
                                        ebcotWorkspace: &ebcotWorkspace,
                                        recordTelemetry: !preRecordedHT
                                    )
                                }
                                if progress != nil && (completed & 7 == 0) {
                                    progress?(try ProgressUpdate(phase: .processing, completedUnits: min(completed, total), totalUnits: total))
                                    try work.check()
                                }
                            }
                        }
                    }
                }
            }
            return plane
        }

        var tasks: [LosslessDecodeBlockTask] = []
        tasks.reserveCapacity(min(tile.geometry.codeBlockCount, 4096))
        var scannedBlocks = 0
        for resolution in geometry.resolutions where resolution.index <= effectiveMaxRes {
            for (p, precinct) in resolution.precincts.enumerated() {
                for (b, precinctBand) in precinct.bands.enumerated() {
                    let band = resolution.bands[precinctBand.bandIndex]
                    let mb = tile.magnitudeBitPlanes[band.quantizationIndex]
                    for (k, block) in precinctBand.blocks.enumerated() {
                        scannedBlocks += 1
                        let contribution = contributions[resolution.index][p][b][k]
                        guard contribution.included, contribution.passes > 0 else { continue }
                        let blockOffset = (band.planeY + block.y0 - band.y0) * stride + band.planeX + block.x0 - band.x0
                        tasks.append(LosslessDecodeBlockTask(
                            resIdx: resolution.index,
                            precIdx: p,
                            pbIdx: b,
                            cbIdx: k,
                            width: block.width,
                            height: block.height,
                            planeOffset: blockOffset,
                            orientation: band.orientation,
                            mb: mb
                        ))
                    }
                }
            }
        }
        completed += scannedBlocks
        guard !tasks.isEmpty else { return plane }

        let workerCount = BoundedParallelPool.effectiveWorkers(requested: requestedWorkers, jobCount: tasks.count)
        let preRecordedHT = backend == .accelerated && tile.isHTOnlyFast
        if preRecordedHT {
            AcceleratedCodec.recordSIMDDispatch()
        }
        var workspaces = (0..<workerCount).map { _ in EBCOTWorkspace() }
        try plane.withUnsafeMutableBufferPointer { planeBuf in
            guard planeBuf.baseAddress != nil else { return }
            let sendablePlane = UnsafeSendableMutableBuffer(planeBuf)
            try workspaces.withUnsafeMutableBufferPointer { wsBuf in
                let sendableWS = UnsafeSendableMutableBuffer(wsBuf)
                try BoundedParallelPool.forEach(jobCount: tasks.count, maxWorkers: workerCount) { [tasks] jobIdx, workerIdx in
                    try work.checkAmortized(jobIdx)
                    let task = tasks[jobIdx]
                    let contribution = contributions[task.resIdx][task.precIdx][task.pbIdx][task.cbIdx]
                    try decodeSingleLosslessBlock(
                        contribution: contribution,
                        width: task.width,
                        height: task.height,
                        orientation: task.orientation,
                        mb: task.mb,
                        style: style,
                        backend: backend,
                        destination: sendablePlane.baseAddress.advanced(by: task.planeOffset),
                        stride: stride,
                        ebcotWorkspace: &sendableWS.baseAddress[workerIdx],
                        recordTelemetry: !preRecordedHT
                    )
                }
            }
        }
        _ = plane[0]
        return plane
    }

    private static func decodeTileCoefficientsAsync(
        bytes: [UInt8],
        tile: TileProfile,
        work: WorkGuard,
        backend: Backend = .scalarCPU,
        maxResolutionLevel: Int? = nil,
        planeWidth: Int? = nil,
        planeHeight: Int? = nil,
        maxExtraWorkspaceBytes: Int = Int.max,
        completed: inout Int
    ) async throws -> [Int32] {
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
            maxResolutionLevel: maxResolutionLevel,
            bytes: tileBytes,
            range: tileRange,
            cancellation: work.check
        )
        let stride = planeWidth ?? tile.width
        let height = planeHeight ?? tile.height
        let planeCount = stride * height
        StorageTelemetry.recordStage("coefficient-plane", bytes: planeCount * 4)
        StorageTelemetry.recordWorkspaceAllocation(bytes: planeCount * 4)
        guard planeCount > 0 else { return [] }

        let effectiveMaxRes = min(maxResolutionLevel ?? (geometry.resolutions.count - 1), geometry.resolutions.count - 1)
        let budgetWorkers = maxExtraWorkspaceBytes == Int.max ? Int.max : (1 + max(0, maxExtraWorkspaceBytes / 65_536))
        let requestedWorkers = min(AcceleratedCodec.activeWorkerLimit, budgetWorkers)

        var tasks: [LosslessDecodeBlockTask] = []
        tasks.reserveCapacity(min(tile.geometry.codeBlockCount, 4096))
        var scannedBlocks = 0
        for resolution in geometry.resolutions where resolution.index <= effectiveMaxRes {
            for (p, precinct) in resolution.precincts.enumerated() {
                for (b, precinctBand) in precinct.bands.enumerated() {
                    let band = resolution.bands[precinctBand.bandIndex]
                    let mb = tile.magnitudeBitPlanes[band.quantizationIndex]
                    for (k, block) in precinctBand.blocks.enumerated() {
                        scannedBlocks += 1
                        let contribution = contributions[resolution.index][p][b][k]
                        guard contribution.included, contribution.passes > 0 else { continue }
                        let blockOffset = (band.planeY + block.y0 - band.y0) * stride + band.planeX + block.x0 - band.x0
                        tasks.append(LosslessDecodeBlockTask(
                            resIdx: resolution.index,
                            precIdx: p,
                            pbIdx: b,
                            cbIdx: k,
                            width: block.width,
                            height: block.height,
                            planeOffset: blockOffset,
                            orientation: band.orientation,
                            mb: mb
                        ))
                    }
                }
            }
        }
        completed += scannedBlocks
        guard !tasks.isEmpty else {
            return [Int32](repeating: 0, count: planeCount)
        }

        let workerCount = BoundedParallelPool.effectiveWorkers(requested: requestedWorkers, jobCount: tasks.count)
        let preRecordedHT = backend == .accelerated && tile.isHTOnlyFast
        if preRecordedHT {
            AcceleratedCodec.recordSIMDDispatch()
        }

        final class SendableDecodeScratch: @unchecked Sendable {
            var plane: [Int32]
            let planePtr: UnsafeMutablePointer<Int32>
            let workers: Int
            let ebcot: UnsafeMutablePointer<EBCOTWorkspace>
            init(planeCount: Int, workers: Int) {
                let n = max(1, workers)
                let safeCount = max(1, planeCount)
                self.plane = [Int32](repeating: 0, count: safeCount)
                self.planePtr = self.plane.withUnsafeMutableBufferPointer { $0.baseAddress! }
                self.workers = n
                self.ebcot = UnsafeMutablePointer<EBCOTWorkspace>.allocate(capacity: n)
                for i in 0..<n {
                    self.ebcot.advanced(by: i).initialize(to: EBCOTWorkspace())
                }
            }
            deinit {
                ebcot.deinitialize(count: workers)
                ebcot.deallocate()
            }
        }
        let scratch = SendableDecodeScratch(planeCount: planeCount, workers: workerCount)
        try await BoundedParallelPool.forEachAsync(jobCount: tasks.count, maxWorkers: workerCount) { [tasks] jobIdx, workerIdx in
            try work.checkAmortized(jobIdx)
            let task = tasks[jobIdx]
            let contribution = contributions[task.resIdx][task.precIdx][task.pbIdx][task.cbIdx]
            try decodeSingleLosslessBlock(
                contribution: contribution,
                width: task.width,
                height: task.height,
                orientation: task.orientation,
                mb: task.mb,
                style: style,
                backend: backend,
                destination: scratch.planePtr.advanced(by: task.planeOffset),
                stride: stride,
                ebcotWorkspace: &scratch.ebcot[workerIdx],
                recordTelemetry: !preRecordedHT
            )
        }
        return withExtendedLifetime(scratch) {
            let out = scratch.plane
            scratch.plane = []
            return out
        }
    }

    @inline(__always)
    private static func decodeSingleLosslessBlock(
        contribution: CodeBlockContribution,
        width: Int,
        height: Int,
        orientation: BandOrientation,
        mb: Int,
        style: CodeBlockStyle,
        backend: Backend,
        destination: UnsafeMutablePointer<Int32>,
        stride: Int,
        ebcotWorkspace: inout EBCOTWorkspace,
        recordTelemetry: Bool = true
    ) throws {
        if contribution.isHT {
            let htPasses = ((contribution.passes - 1) % 3) + 1
            if htPasses == 1 && contribution.segments.count <= 1 && !style.causal {
                let placeholderSets = (contribution.passes - 1) / 3
                let effectiveMissingMSBs = contribution.zeroBitPlanes + placeholderSets
                let rawBlock = contribution.segments.first?.data ?? []
                try AcceleratedCodec.decodeHTCleanupStrided(
                    block: rawBlock[...],
                    width: width,
                    height: height,
                    kMax: mb,
                    missingMSBs: effectiveMissingMSBs,
                    destination: destination,
                    stride: stride,
                    backend: backend,
                    recordTelemetry: recordTelemetry
                )
            } else {
                let coeffs64 = try HTBlockDecoder.decodeHTCodeBlock(
                    segments: contribution.segments.map {
                        HTSegmentInput(data: $0.data, passes: $0.passes)
                    },
                    zeroBitPlanes: contribution.zeroBitPlanes,
                    totalPasses: contribution.passes,
                    width: width,
                    height: height,
                    kMax: mb,
                    causal: style.causal,
                    allowMultiHT: false,
                    midpointReconstruction: false
                )
                for row in 0..<height {
                    let dstRow = destination.advanced(by: row * stride)
                    let srcBase = row * width
                    for col in 0..<width {
                        dstRow[col] = Int32(clamping: coeffs64[srcBase + col])
                    }
                }
            }
        } else {
            try BitPlaneCoder.decodeStrided(
                segments: contribution.segments,
                destination: destination,
                destinationStride: stride,
                width: width,
                height: height,
                orientation: orientation,
                zeroBitPlanes: contribution.zeroBitPlanes,
                passCount: contribution.passes,
                magnitudeBitPlanes: mb,
                style: style,
                workspace: &ebcotWorkspace
            )
        }
    }

    // MARK: - Decoding

    static func decodeAsync(
        bytes: [UInt8],
        profile: LosslessProfile,
        into destination: ImageDestination,
        limits: ResourceLimits,
        backend: Backend = .scalarCPU,
        progress: (@Sendable (ProgressUpdate) -> Void)?,
        resolutionReductionLevels: Int = 0
    ) async throws -> (Image, Int) {
        if profile.tiles.count != 1 || progress != nil {
            return try decode(
                bytes: bytes,
                profile: profile,
                into: destination,
                limits: limits,
                backend: backend,
                progress: progress,
                resolutionReductionLevels: resolutionReductionLevels
            )
        }
        let descriptor = destination.descriptor
        let effectiveReduction = profile.effectiveReductionLevels(reductionLevels: resolutionReductionLevels)
        let (expectedW, expectedH) = profile.reducedDimensions(reductionLevels: effectiveReduction)
        guard !profile.signed,
              descriptor.width == expectedW, descriptor.height == expectedH,
              descriptor.sampleType == .unsignedInteger, descriptor.storageBits == 16,
              descriptor.components == [.grey], descriptor.planes.count == 1,
              descriptor.meaningfulBits == profile.precision else {
            throw CodecError(.incompatibleImageLayout, "Destination descriptor does not match the codestream geometry or precision.")
        }
        let workspace = try workspaceBytes(profile: profile)
        guard workspace <= limits.maximumWorkspaceBytes else {
            throw CodecError(.resourceLimitExceeded, "Decoder workspace exceeds the operation limit.")
        }
        let totalBaseMemory = try checkedAdd(checkedAdd(bytes.count, destination.storage.byteCount), workspace)
        guard totalBaseMemory <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Compressed input, destination and workspace exceed the memory budget.")
        }
        let extraWorkspace = min(limits.maximumWorkspaceBytes - workspace, limits.maximumMemoryBytes - totalBaseMemory)
        let work = WorkGuard(limits: limits)
        try work.check()

        let tile = profile.tiles[0]
        let keepLevels = max(0, tile.codingStyle.decompositionLevels - effectiveReduction)
        let maxRes: Int? = effectiveReduction > 0 ? keepLevels : nil
        let rOriginX = Wavelet53.ceilDivPowerOfTwo(profile.originX, effectiveReduction)
        let rOriginY = Wavelet53.ceilDivPowerOfTwo(profile.originY, effectiveReduction)
        let rtx0 = Wavelet53.ceilDivPowerOfTwo(tile.x0, effectiveReduction)
        let rtx1 = Wavelet53.ceilDivPowerOfTwo(tile.x1, effectiveReduction)
        let rty0 = Wavelet53.ceilDivPowerOfTwo(tile.y0, effectiveReduction)
        let rty1 = Wavelet53.ceilDivPowerOfTwo(tile.y1, effectiveReduction)
        let stride = rtx1 - rtx0
        let tileH = rty1 - rty0

        var completed = 0
        var plane = try await decodeTileCoefficientsAsync(
            bytes: bytes,
            tile: tile,
            work: work,
            backend: backend,
            maxResolutionLevel: maxRes,
            planeWidth: stride,
            planeHeight: tileH,
            maxExtraWorkspaceBytes: extraWorkspace,
            completed: &completed
        )
        if keepLevels == 0 && backend == .accelerated {
            if AcceleratedCodec.shouldUseMetal(sampleCount: plane.count) {
                try MetalAccelerationEngine.shared.levelShiftSamples32(samples: &plane, dcShift: 0)
            } else {
                AcceleratedCodec.recordSIMDDispatch()
            }
        } else {
            try AcceleratedCodec.inverseWavelet53(
                plane: &plane,
                stride: stride,
                x0: rtx0,
                x1: rtx1,
                y0: rty0,
                y1: rty1,
                levels: keepLevels,
                backend: backend,
                cancellation: work.check
            )
        }
        do {
            let layout = descriptor.planes[0]
            let mutation = SharedPathMutation.active
            let rowBytes = mutation == .ignoreRowStride ? expectedW * layout.pixelStride : layout.rowBytes
            let order = mutation == .wrongByteOrder ? descriptor.byteOrder.opposite : descriptor.byteOrder
            let shift = Int32(1) << Int32(profile.precision - 1)
            let maximum = Int32((1 << profile.precision) - 1)
            let outX0 = rtx0 - rOriginX
            let outY0 = rty0 - rOriginY
            let image = try destination.write { output in
                guard stride > 0, tileH > 0 else { return }
                let maxWriteEnd = layout.offset + (outY0 + tileH - 1) * rowBytes + (outX0 + stride) * layout.pixelStride
                if mutation == .none && layout.pixelStride == 2 && order == .littleEndian &&
                    outX0 >= 0 && outY0 >= 0 && maxWriteEnd <= output.count,
                   let outBase = output.baseAddress {
                    try writeClampedGreyscale16LE(
                        plane: plane,
                        stride: stride,
                        tileH: tileH,
                        outBase: outBase,
                        outCount: output.count,
                        layoutOffset: layout.offset,
                        rowBytes: rowBytes,
                        outX0: outX0,
                        outY0: outY0,
                        shift: shift,
                        maximum: maximum,
                        extraWorkspace: extraWorkspace,
                        allowParallel: true,
                        work: work
                    )
                } else {
                    for row in 0..<tileH {
                        try work.checkAmortized(row)
                        let y = outY0 + row
                        let rowOffset = layout.offset + y * rowBytes
                        for column in 0..<stride {
                            let x = outX0 + column
                            let value = min(max(plane[row * stride + column] + shift, 0), maximum)
                            try storeUInt16(UInt16(value), into: output, at: rowOffset + x * layout.pixelStride, order: order)
                        }
                    }
                }
            }
            return (image, workspace)
        } catch {
            destination.invalidateAfterFailure()
            throw error
        }
    }

    static func decode(bytes: [UInt8], profile: LosslessProfile, into destination: ImageDestination,
                       limits: ResourceLimits, backend: Backend = .scalarCPU,
                       progress: (@Sendable (ProgressUpdate) -> Void)?,
                       resolutionReductionLevels: Int = 0) throws -> (Image, Int) {
        let descriptor = destination.descriptor
        let effectiveReduction = profile.effectiveReductionLevels(reductionLevels: resolutionReductionLevels)
        let (expectedW, expectedH) = profile.reducedDimensions(reductionLevels: effectiveReduction)
        guard !profile.signed,
              descriptor.width == expectedW, descriptor.height == expectedH,
              descriptor.sampleType == .unsignedInteger, descriptor.storageBits == 16,
              descriptor.components == [.grey], descriptor.planes.count == 1,
              descriptor.meaningfulBits == profile.precision else {
            throw CodecError(.incompatibleImageLayout, "Destination descriptor does not match the codestream geometry or precision.")
        }
        let workspace = try workspaceBytes(profile: profile)
        guard workspace <= limits.maximumWorkspaceBytes else {
            throw CodecError(.resourceLimitExceeded, "Decoder workspace exceeds the operation limit.")
        }
        let totalBaseMemory = try checkedAdd(checkedAdd(bytes.count, destination.storage.byteCount), workspace)
        guard totalBaseMemory <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Compressed input, destination and workspace exceed the memory budget.")
        }
        let extraWorkspace = min(limits.maximumWorkspaceBytes - workspace, limits.maximumMemoryBytes - totalBaseMemory)
        let work = WorkGuard(limits: limits)
        try work.check()
        do {
            return try decodeAdmitted(bytes: bytes, profile: profile, into: destination, workspace: workspace,
                                      extraWorkspace: extraWorkspace, effectiveReduction: effectiveReduction,
                                      expectedWidth: expectedW, expectedHeight: expectedH,
                                      work: work, backend: backend, progress: progress)
        } catch {
            destination.invalidateAfterFailure()
            throw error
        }
    }

    private static func decodeAdmitted(bytes: [UInt8], profile: LosslessProfile, into destination: ImageDestination,
                                       workspace: Int, extraWorkspace: Int, effectiveReduction: Int,
                                       expectedWidth: Int, expectedHeight: Int,
                                       work: WorkGuard, backend: Backend,
                                       progress: (@Sendable (ProgressUpdate) -> Void)?) throws -> (Image, Int) {
        let descriptor = destination.descriptor
        let layout = descriptor.planes[0]
        let mutation = SharedPathMutation.active
        let rowBytes = mutation == .ignoreRowStride ? expectedWidth * layout.pixelStride : layout.rowBytes
        let order = mutation == .wrongByteOrder ? descriptor.byteOrder.opposite : descriptor.byteOrder
        let shift = Int32(1) << Int32(profile.precision - 1)
        let maximum = Int32((1 << profile.precision) - 1)
        let rOriginX = Wavelet53.ceilDivPowerOfTwo(profile.originX, effectiveReduction)
        let rOriginY = Wavelet53.ceilDivPowerOfTwo(profile.originY, effectiveReduction)
        let total = profile.codeBlockCount
        var completed = 0
        progress?(try ProgressUpdate(phase: .processing, completedUnits: 0, totalUnits: total))
        try work.check()

        // All tiles are decoded inside the one exclusive write borrow of the
        // destination; each tile's workspace is released before the next.
        let image = try destination.write { output in
            for tile in profile.tiles {
                try work.check()
                let keepLevels = max(0, tile.codingStyle.decompositionLevels - effectiveReduction)
                let maxRes: Int? = effectiveReduction > 0 ? keepLevels : nil
                let rtx0 = Wavelet53.ceilDivPowerOfTwo(tile.x0, effectiveReduction)
                let rtx1 = Wavelet53.ceilDivPowerOfTwo(tile.x1, effectiveReduction)
                let rty0 = Wavelet53.ceilDivPowerOfTwo(tile.y0, effectiveReduction)
                let rty1 = Wavelet53.ceilDivPowerOfTwo(tile.y1, effectiveReduction)
                let stride = rtx1 - rtx0
                let tileH = rty1 - rty0
                guard stride > 0, tileH > 0 else { continue }

                var plane = try decodeTileCoefficients(
                    bytes: bytes,
                    tile: tile,
                    work: work,
                    backend: backend,
                    maxResolutionLevel: maxRes,
                    planeWidth: stride,
                    planeHeight: tileH,
                    maxExtraWorkspaceBytes: extraWorkspace,
                    completed: &completed,
                    total: total,
                    progress: progress
                )
                if keepLevels == 0 && backend == .accelerated {
                    if AcceleratedCodec.shouldUseMetal(sampleCount: plane.count) {
                        try MetalAccelerationEngine.shared.levelShiftSamples32(samples: &plane, dcShift: 0)
                    } else {
                        AcceleratedCodec.recordSIMDDispatch()
                    }
                } else {
                    try AcceleratedCodec.inverseWavelet53(
                        plane: &plane,
                        stride: stride,
                        x0: rtx0,
                        x1: rtx1,
                        y0: rty0,
                        y1: rty1,
                        levels: keepLevels,
                        backend: backend,
                        cancellation: work.check
                    )
                }
                // Final-output stage: DC shift, clamp, write into the caller's plane.
                let outX0 = rtx0 - rOriginX
                let outY0 = rty0 - rOriginY
                let maxWriteEnd = layout.offset + (outY0 + tileH - 1) * rowBytes + (outX0 + stride) * layout.pixelStride
                if mutation == .none && layout.pixelStride == 2 && order == .littleEndian &&
                    outX0 >= 0 && outY0 >= 0 && maxWriteEnd <= output.count,
                   let outBase = output.baseAddress {
                    try writeClampedGreyscale16LE(
                        plane: plane,
                        stride: stride,
                        tileH: tileH,
                        outBase: outBase,
                        outCount: output.count,
                        layoutOffset: layout.offset,
                        rowBytes: rowBytes,
                        outX0: outX0,
                        outY0: outY0,
                        shift: shift,
                        maximum: maximum,
                        extraWorkspace: extraWorkspace,
                        allowParallel: progress == nil,
                        work: work
                    )
                } else {
                    for row in 0..<tileH {
                        try work.checkAmortized(row)
                        let y = outY0 + row
                        let rowOffset = layout.offset + y * rowBytes
                        for column in 0..<stride {
                            let x = outX0 + column
                            let value = min(max(plane[row * stride + column] + shift, 0), maximum)
                            try storeUInt16(UInt16(value), into: output, at: rowOffset + x * layout.pixelStride, order: order)
                        }
                    }
                }
            }
        }
        return (image, workspace)
    }

    private static func writeClampedGreyscale16LE(
        plane: [Int32],
        stride: Int,
        tileH: Int,
        outBase: UnsafeMutableRawPointer,
        outCount: Int,
        layoutOffset: Int,
        rowBytes: Int,
        outX0: Int,
        outY0: Int,
        shift: Int32,
        maximum: Int32,
        extraWorkspace: Int,
        allowParallel: Bool,
        work: WorkGuard
    ) throws {
        try plane.withUnsafeBufferPointer { planeBuf in
            guard let pBase = planeBuf.baseAddress else { return }
            let budgetWorkers = extraWorkspace == Int.max ? Int.max : (1 + max(0, extraWorkspace / 65_536))
            let rowWorkers = allowParallel ? min(AcceleratedCodec.activeWorkerLimit, budgetWorkers) : 1
            let simdEnd = stride & ~3
            if rowWorkers > 1 && !BoundedParallelPool.isInsideParallelRegion && stride * tileH >= 262_144 && rowBytes >= stride * 2 {
                let chunkRows = 64
                let chunkCount = (tileH + chunkRows - 1) / chunkRows
                let sendablePlane = UnsafeSendableBuffer(planeBuf)
                let sendableOut = UnsafeSendableMutableRawPointer(baseAddress: outBase, count: outCount)
                try BoundedParallelPool.forEach(jobCount: chunkCount, maxWorkers: rowWorkers) { chunkIdx, _ in
                    try work.checkAmortized(chunkIdx)
                    let startRow = chunkIdx * chunkRows
                    let endRow = min(tileH, startRow + chunkRows)
                    let srcPtr = sendablePlane.baseAddress
                    let dstPtr = sendableOut.baseAddress
                    for row in startRow..<endRow {
                        let srcRow = srcPtr.advanced(by: row * stride)
                        var dstByteOffset = layoutOffset + (outY0 + row) * rowBytes + outX0 * 2
                        var col = 0
                        while col < simdEnd {
                            let v0 = UInt16(truncatingIfNeeded: min(max(srcRow[col] + shift, 0), maximum)).littleEndian
                            let v1 = UInt16(truncatingIfNeeded: min(max(srcRow[col + 1] + shift, 0), maximum)).littleEndian
                            let v2 = UInt16(truncatingIfNeeded: min(max(srcRow[col + 2] + shift, 0), maximum)).littleEndian
                            let v3 = UInt16(truncatingIfNeeded: min(max(srcRow[col + 3] + shift, 0), maximum)).littleEndian
                            let packed = UInt64(v0) | (UInt64(v1) << 16) | (UInt64(v2) << 32) | (UInt64(v3) << 48)
                            dstPtr.storeBytes(of: packed, toByteOffset: dstByteOffset, as: UInt64.self)
                            dstByteOffset += 8
                            col += 4
                        }
                        while col < stride {
                            let v = UInt16(truncatingIfNeeded: min(max(srcRow[col] + shift, 0), maximum)).littleEndian
                            dstPtr.storeBytes(of: v, toByteOffset: dstByteOffset, as: UInt16.self)
                            dstByteOffset += 2
                            col += 1
                        }
                    }
                }
            } else {
                for row in 0..<tileH {
                    try work.checkAmortized(row)
                    let srcRow = pBase.advanced(by: row * stride)
                    var dstByteOffset = layoutOffset + (outY0 + row) * rowBytes + outX0 * 2
                    var col = 0
                    while col < simdEnd {
                        let v0 = UInt16(truncatingIfNeeded: min(max(srcRow[col] + shift, 0), maximum)).littleEndian
                        let v1 = UInt16(truncatingIfNeeded: min(max(srcRow[col + 1] + shift, 0), maximum)).littleEndian
                        let v2 = UInt16(truncatingIfNeeded: min(max(srcRow[col + 2] + shift, 0), maximum)).littleEndian
                        let v3 = UInt16(truncatingIfNeeded: min(max(srcRow[col + 3] + shift, 0), maximum)).littleEndian
                        let packed = UInt64(v0) | (UInt64(v1) << 16) | (UInt64(v2) << 32) | (UInt64(v3) << 48)
                        outBase.storeBytes(of: packed, toByteOffset: dstByteOffset, as: UInt64.self)
                        dstByteOffset += 8
                        col += 4
                    }
                    while col < stride {
                        let v = UInt16(truncatingIfNeeded: min(max(srcRow[col] + shift, 0), maximum)).littleEndian
                        outBase.storeBytes(of: v, toByteOffset: dstByteOffset, as: UInt16.self)
                        dstByteOffset += 2
                        col += 1
                    }
                }
            }
        }
    }

    // MARK: - Encoding

    struct EncodeParameters: Sendable {
        let decompositionLevels: Int
        let codeBlockWidthExponent: Int
        let codeBlockHeightExponent: Int
        let blockCoding: CodecOptions.BlockCoding
        let progressionOrder: CodecOptions.ProgressionOrder
        let backend: Backend

        init(
            decompositionLevels: Int,
            codeBlockWidthExponent: Int,
            codeBlockHeightExponent: Int,
            blockCoding: CodecOptions.BlockCoding,
            progressionOrder: CodecOptions.ProgressionOrder = .lrcp,
            backend: Backend = .scalarCPU
        ) {
            self.decompositionLevels = decompositionLevels
            self.codeBlockWidthExponent = codeBlockWidthExponent
            self.codeBlockHeightExponent = codeBlockHeightExponent
            self.blockCoding = blockCoding
            self.progressionOrder = progressionOrder
            self.backend = backend
        }
    }

    @inline(__always)
    private static func encodeSingleLosslessBlock(
        planeBase: UnsafePointer<Int32>,
        planeOffset: Int,
        stride: Int,
        width: Int,
        height: Int,
        orientation: BandOrientation,
        mb: Int,
        blockCoding: CodecOptions.BlockCoding,
        backend: Backend,
        blockMaxOutputBytes: Int,
        ebcotWorkspace: inout EBCOTWorkspace,
        htWorkspace: inout HTBlockEncoder.Workspace,
        useMetalHTOverride: Bool? = nil,
        recordTelemetry: Bool = true
    ) throws -> CodeBlockEncoding {
        let srcPtr = planeBase.advanced(by: planeOffset)
        switch blockCoding {
        case .part1:
            return try BitPlaneCoder.encodeStrided(
                source: srcPtr,
                sourceStride: stride,
                width: width,
                height: height,
                orientation: orientation,
                magnitudeBitPlanes: mb,
                maximumOutputBytes: blockMaxOutputBytes,
                workspace: &ebcotWorkspace,
                allocateLayerMetadata: false
            )
        case .htj2k:
            let coded = try AcceleratedCodec.encodeHTCleanupStrided(
                source: srcPtr,
                stride: stride,
                width: width,
                height: height,
                bandShift: 0,
                maximumOutputBytes: blockMaxOutputBytes,
                backend: backend,
                workspace: &htWorkspace,
                useMetalHTOverride: useMetalHTOverride,
                recordTelemetry: recordTelemetry
            )
            return CodeBlockEncoding(
                losslessSingleLayer: coded,
                passCount: coded.isEmpty ? 0 : 1,
                zeroBitPlanes: coded.isEmpty ? mb : (mb - 1)
            )
        }
    }

    private static func buildLosslessEncodeSchedule(
        geometry: TileGeometry,
        qcd: QuantizationSegment,
        stride: Int
    ) -> (tasks: [LosslessEncodeBlockTask], emptyGrid: [[[[CodeBlockEncoding]]]]) {
        var tasks: [LosslessEncodeBlockTask] = []
        tasks.reserveCapacity(geometry.codeBlockCount)
        let placeholder = CodeBlockEncoding(losslessSingleLayer: [], passCount: 0, zeroBitPlanes: 0)
        var encodings: [[[[CodeBlockEncoding]]]] = []
        encodings.reserveCapacity(geometry.resolutions.count)
        for resolution in geometry.resolutions {
            var perPrecinct: [[[CodeBlockEncoding]]] = []
            perPrecinct.reserveCapacity(resolution.precincts.count)
            for (p, precinct) in resolution.precincts.enumerated() {
                var perBand: [[CodeBlockEncoding]] = []
                perBand.reserveCapacity(precinct.bands.count)
                for (b, precinctBand) in precinct.bands.enumerated() {
                    let band = resolution.bands[precinctBand.bandIndex]
                    let mb = qcd.guardBits + qcd.exponents[band.quantizationIndex] - 1
                    let perBlock = [CodeBlockEncoding](repeating: placeholder, count: precinctBand.blocks.count)
                    for (k, block) in precinctBand.blocks.enumerated() {
                        let offset = (band.planeY + block.y0 - band.y0) * stride + band.planeX + block.x0 - band.x0
                        tasks.append(LosslessEncodeBlockTask(
                            resIdx: resolution.index,
                            precIdx: p,
                            pbIdx: b,
                            cbIdx: k,
                            width: block.width,
                            height: block.height,
                            planeOffset: offset,
                            orientation: band.orientation,
                            mb: mb
                        ))
                    }
                    perBand.append(perBlock)
                }
                perPrecinct.append(perBand)
            }
            encodings.append(perPrecinct)
        }
        return (tasks, encodings)
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
        maxExtraWorkspaceBytes: Int = Int.max,
        runningEncodedBytes: inout Int,
        recordBlockStages: Bool = false,
        completed: inout Int,
        total: Int,
        progress: (@Sendable (ProgressUpdate) -> Void)?
    ) throws -> [[[[CodeBlockEncoding]]]] {
        let shouldRecordBlockStage = recordBlockStages && StorageTelemetry.recorder != nil
        let requestedWorkers: Int
        if progress != nil {
            requestedWorkers = 1
        } else {
            let effExtra = min(maxRetainedEncodedBytes, maxExtraWorkspaceBytes)
            let budgetWorkers = effExtra == Int.max ? Int.max : (1 + max(0, effExtra / 65_536))
            requestedWorkers = min(AcceleratedCodec.activeWorkerLimit, budgetWorkers)
        }

        if requestedWorkers <= 1 {
            var encodings: [[[[CodeBlockEncoding]]]] = []
            encodings.reserveCapacity(geometry.resolutions.count)
            let useMetalHT = (blockCoding == .htj2k) && AcceleratedCodec.shouldClassifyHTQuadsOnMetal(backend: backend)
            let preRecordedHT = (blockCoding == .htj2k) && backend == .accelerated && geometry.codeBlockCount > 0
            if preRecordedHT {
                AcceleratedCodec.recordSIMDDispatch()
            }
            var ebcotWS = EBCOTWorkspace()
            var htWS = HTBlockEncoder.Workspace()
            try plane.withUnsafeBufferPointer { planeBuf in
                guard let planeBase = planeBuf.baseAddress else { return }
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
                                try work.checkAmortized(completed)
                                guard runningEncodedBytes <= maxRetainedEncodedBytes else {
                                    throw CodecError(.resourceLimitExceeded, "Encoded code-block payloads exceed the workspace or memory admission budget.")
                                }
                                let blockMaxOutputBytes: Int = maxRetainedEncodedBytes == Int.max
                                    ? Int.max
                                    : max(0, maxRetainedEncodedBytes - runningEncodedBytes - 32)
                                let planeOffset = (band.planeY + block.y0 - band.y0) * stride + band.planeX + block.x0 - band.x0
                                let encoding = try encodeSingleLosslessBlock(
                                    planeBase: planeBase,
                                    planeOffset: planeOffset,
                                    stride: stride,
                                    width: block.width,
                                    height: block.height,
                                    orientation: band.orientation,
                                    mb: mb,
                                    blockCoding: blockCoding,
                                    backend: backend,
                                    blockMaxOutputBytes: blockMaxOutputBytes,
                                    ebcotWorkspace: &ebcotWS,
                                    htWorkspace: &htWS,
                                    useMetalHTOverride: useMetalHT,
                                    recordTelemetry: !preRecordedHT
                                )
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
                                if progress != nil && (completed & 7 == 0) {
                                    progress?(try ProgressUpdate(phase: .processing, completedUnits: min(completed, total), totalUnits: total))
                                    try work.check()
                                }
                            }
                            perBand.append(perBlock)
                        }
                        perPrecinct.append(perBand)
                    }
                    encodings.append(perPrecinct)
                }
            }
            return encodings
        }

        let (tasks, emptyGrid) = buildLosslessEncodeSchedule(geometry: geometry, qcd: qcd, stride: stride)
        var encodings = emptyGrid
        guard !tasks.isEmpty else { return encodings }

        let workerCount = BoundedParallelPool.effectiveWorkers(requested: requestedWorkers, jobCount: tasks.count)
        let useMetalHT = (blockCoding == .htj2k) && AcceleratedCodec.shouldClassifyHTQuadsOnMetal(backend: backend)
        let preRecordedHT = (blockCoding == .htj2k) && backend == .accelerated
        if preRecordedHT {
            AcceleratedCodec.recordSIMDDispatch()
        }
        let accumulator = AtomicByteAccumulator(initial: runningEncodedBytes, limit: maxRetainedEncodedBytes)
        var flatResults = [CodeBlockEncoding](
            repeating: CodeBlockEncoding(losslessSingleLayer: [], passCount: 0, zeroBitPlanes: 0),
            count: tasks.count
        )
        var ebcotWorkspaces = (0..<workerCount).map { _ in EBCOTWorkspace() }
        var htWorkspaces = (0..<workerCount).map { _ in HTBlockEncoder.Workspace() }

        try plane.withUnsafeBufferPointer { planeBuf in
            guard planeBuf.baseAddress != nil else { return }
            let sendablePlane = UnsafeSendableBuffer(planeBuf)
            try flatResults.withUnsafeMutableBufferPointer { resBuf in
                let sendableRes = UnsafeSendableMutableBuffer(resBuf)
                try ebcotWorkspaces.withUnsafeMutableBufferPointer { ewsBuf in
                    let sendableEWS = UnsafeSendableMutableBuffer(ewsBuf)
                    try htWorkspaces.withUnsafeMutableBufferPointer { hwsBuf in
                        let sendableHWS = UnsafeSendableMutableBuffer(hwsBuf)
                        try BoundedParallelPool.forEach(jobCount: tasks.count, maxWorkers: workerCount) { jobIdx, workerIdx in
                            try work.checkAmortized(jobIdx)
                            let task = tasks[jobIdx]
                            let blockMaxOutputBytes = try accumulator.remainingBeforeEncode()
                            let enc = try encodeSingleLosslessBlock(
                                planeBase: sendablePlane.baseAddress,
                                planeOffset: task.planeOffset,
                                stride: stride,
                                width: task.width,
                                height: task.height,
                                orientation: task.orientation,
                                mb: task.mb,
                                blockCoding: blockCoding,
                                backend: backend,
                                blockMaxOutputBytes: blockMaxOutputBytes,
                                ebcotWorkspace: &sendableEWS.baseAddress[workerIdx],
                                htWorkspace: &sendableHWS.baseAddress[workerIdx],
                                useMetalHTOverride: useMetalHT,
                                recordTelemetry: !preRecordedHT
                            )
                            let blockRetainedBytes = enc.data.isEmpty ? 0 : (32 + max(enc.data.count, enc.data.capacity))
                            try accumulator.tryAdd(blockRetainedBytes)
                            if shouldRecordBlockStage && blockRetainedBytes > 0 {
                                StorageTelemetry.recordStage("block-encoding", bytes: blockRetainedBytes)
                            }
                            sendableRes.baseAddress[jobIdx] = enc
                        }
                    }
                }
            }
        }
        runningEncodedBytes = accumulator.current
        completed += tasks.count
        for (idx, task) in tasks.enumerated() {
            encodings[task.resIdx][task.precIdx][task.pbIdx][task.cbIdx] = flatResults[idx]
        }
        return encodings
    }

    private static func encodeTileBlocksAsync(
        plane: [Int32],
        stride: Int,
        geometry: TileGeometry,
        qcd: QuantizationSegment,
        blockCoding: CodecOptions.BlockCoding,
        backend: Backend = .scalarCPU,
        work: WorkGuard,
        maxRetainedEncodedBytes: Int = Int.max,
        maxExtraWorkspaceBytes: Int = Int.max,
        runningEncodedBytes: inout Int,
        recordBlockStages: Bool = false,
        completed: inout Int,
        total: Int,
        progress: (@Sendable (ProgressUpdate) -> Void)?
    ) async throws -> [[[[CodeBlockEncoding]]]] {
        let shouldRecordBlockStage = recordBlockStages && StorageTelemetry.recorder != nil
        let requestedWorkers: Int
        if progress != nil {
            requestedWorkers = 1
        } else {
            let effExtra = min(maxRetainedEncodedBytes, maxExtraWorkspaceBytes)
            let budgetWorkers = effExtra == Int.max ? Int.max : (1 + max(0, effExtra / 65_536))
            requestedWorkers = min(AcceleratedCodec.activeWorkerLimit, budgetWorkers)
        }
        if requestedWorkers <= 1 {
            return try encodeTileBlocks(
                plane: plane,
                stride: stride,
                geometry: geometry,
                qcd: qcd,
                blockCoding: blockCoding,
                backend: backend,
                work: work,
                maxRetainedEncodedBytes: maxRetainedEncodedBytes,
                maxExtraWorkspaceBytes: maxExtraWorkspaceBytes,
                runningEncodedBytes: &runningEncodedBytes,
                recordBlockStages: recordBlockStages,
                completed: &completed,
                total: total,
                progress: progress
            )
        }

        let (tasks, emptyGrid) = buildLosslessEncodeSchedule(geometry: geometry, qcd: qcd, stride: stride)
        var encodings = emptyGrid
        guard !tasks.isEmpty else { return encodings }

        let workerCount = BoundedParallelPool.effectiveWorkers(requested: requestedWorkers, jobCount: tasks.count)
        let accumulator = AtomicByteAccumulator(initial: runningEncodedBytes, limit: maxRetainedEncodedBytes)
        final class SendableEncodingsCollector: @unchecked Sendable {
            let count: Int
            let items: UnsafeMutablePointer<CodeBlockEncoding>
            init(count: Int) {
                self.count = count
                self.items = UnsafeMutablePointer<CodeBlockEncoding>.allocate(capacity: max(1, count))
                self.items.initialize(
                    repeating: CodeBlockEncoding(losslessSingleLayer: [], passCount: 0, zeroBitPlanes: 0),
                    count: max(1, count)
                )
            }
            deinit {
                items.deinitialize(count: max(1, count))
                items.deallocate()
            }
        }
        let collector = SendableEncodingsCollector(count: tasks.count)
        final class SendableWorkerScratch: @unchecked Sendable {
            let workers: Int
            let ebcot: UnsafeMutablePointer<EBCOTWorkspace>
            let ht: UnsafeMutablePointer<HTBlockEncoder.Workspace>
            init(workers: Int) {
                let n = max(1, workers)
                self.workers = n
                self.ebcot = UnsafeMutablePointer<EBCOTWorkspace>.allocate(capacity: n)
                self.ht = UnsafeMutablePointer<HTBlockEncoder.Workspace>.allocate(capacity: n)
                for i in 0..<n {
                    self.ebcot.advanced(by: i).initialize(to: EBCOTWorkspace())
                    self.ht.advanced(by: i).initialize(to: HTBlockEncoder.Workspace())
                }
            }
            deinit {
                ebcot.deinitialize(count: workers)
                ebcot.deallocate()
                ht.deinitialize(count: workers)
                ht.deallocate()
            }
        }
        let scratch = SendableWorkerScratch(workers: workerCount)
        let useMetalHT = (blockCoding == .htj2k) && AcceleratedCodec.shouldClassifyHTQuadsOnMetal(backend: backend)
        let preRecordedHT = (blockCoding == .htj2k) && backend == .accelerated
        if preRecordedHT {
            AcceleratedCodec.recordSIMDDispatch()
        }

        try await BoundedParallelPool.forEachAsync(jobCount: tasks.count, maxWorkers: workerCount) { jobIdx, workerIdx in
            try work.checkAmortized(jobIdx)
            let task = tasks[jobIdx]
            let blockMaxOutputBytes = try accumulator.remainingBeforeEncode()
            let enc = try plane.withUnsafeBufferPointer { planeBuf -> CodeBlockEncoding in
                guard let planeBase = planeBuf.baseAddress else {
                    return CodeBlockEncoding(data: [], passCount: 0, zeroBitPlanes: task.mb)
                }
                return try encodeSingleLosslessBlock(
                    planeBase: planeBase,
                    planeOffset: task.planeOffset,
                    stride: stride,
                    width: task.width,
                    height: task.height,
                    orientation: task.orientation,
                    mb: task.mb,
                    blockCoding: blockCoding,
                    backend: backend,
                    blockMaxOutputBytes: blockMaxOutputBytes,
                    ebcotWorkspace: &scratch.ebcot[workerIdx],
                    htWorkspace: &scratch.ht[workerIdx],
                    useMetalHTOverride: useMetalHT,
                    recordTelemetry: !preRecordedHT
                )
            }
            let blockRetainedBytes = enc.data.isEmpty ? 0 : (32 + max(enc.data.count, enc.data.capacity))
            try accumulator.tryAdd(blockRetainedBytes)
            if shouldRecordBlockStage && blockRetainedBytes > 0 {
                StorageTelemetry.recordStage("block-encoding", bytes: blockRetainedBytes)
            }
            collector.items[jobIdx] = enc
        }
        runningEncodedBytes = accumulator.current
        completed += tasks.count
        for (idx, task) in tasks.enumerated() {
            encodings[task.resIdx][task.precIdx][task.pbIdx][task.cbIdx] = collector.items[idx]
        }
        return encodings
    }

    private struct PreparedLosslessEncode {
        let width: Int
        let height: Int
        let precision: Int
        let workspace: Int
        let extraWorkspace: Int
        let isHT: Bool
        let cod: CodingStyleSegment
        let geometry: TileGeometry
        let qcd: QuantizationSegment
        let plane: [Int32]
        let work: WorkGuard
    }

    private static func prepareLosslessEncode(
        image: Image,
        parameters: EncodeParameters,
        limits: ResourceLimits
    ) throws -> PreparedLosslessEncode {
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
        let baseMem = try checkedAdd(image.storage.byteCount, workspace)
        guard baseMem <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Image and workspace exceed the memory budget.")
        }
        let extraWorkspace = min(limits.maximumWorkspaceBytes - workspace, limits.maximumMemoryBytes - baseMem)
        let work = WorkGuard(limits: limits)
        try work.check()

        let isHT = parameters.blockCoding == .htj2k
        let cod = CodingStyleSegment(usesPrecincts: false, usesSOP: false, usesEPH: false,
                                     progression: parameters.progressionOrder.rawValue,
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
            let maxReadEnd = layout.offset + (height - 1) * rowBytes + width * layout.pixelStride
            if mutation == .none && layout.pixelStride == 2 && order == .littleEndian &&
                height > 0 && width > 0 && maxReadEnd <= bytes.count,
               let rawBase = bytes.baseAddress {
                try plane.withUnsafeMutableBufferPointer { planeBuf in
                    guard let dstBase = planeBuf.baseAddress else { return }
                    let budgetWorkers = extraWorkspace == Int.max ? Int.max : (1 + max(0, extraWorkspace / 65_536))
                    let rowWorkers = min(AcceleratedCodec.activeWorkerLimit, budgetWorkers)
                    let fastEnd = width & ~3
                    if rowWorkers > 1 && !BoundedParallelPool.isInsideParallelRegion && width * height >= 262_144 {
                        let chunkRows = 64
                        let chunkCount = (height + chunkRows - 1) / chunkRows
                        let sendableSrc = UnsafeSendableRawPointer(baseAddress: rawBase, count: bytes.count)
                        let sendableDst = UnsafeSendableMutableBuffer(planeBuf)
                        try BoundedParallelPool.forEach(jobCount: chunkCount, maxWorkers: rowWorkers) { chunkIdx, _ in
                            try work.checkAmortized(chunkIdx)
                            let startY = chunkIdx * chunkRows
                            let endY = min(height, startY + chunkRows)
                            let srcPtr = sendableSrc.baseAddress
                            let dstPtr = sendableDst.baseAddress
                            for y in startY..<endY {
                                let dstRow = dstPtr.advanced(by: y * stride)
                                var srcOffset = layout.offset + y * rowBytes
                                var x = 0
                                while x < fastEnd {
                                    let packed = srcPtr.loadUnaligned(fromByteOffset: srcOffset, as: UInt64.self)
                                    let host64 = UInt64(littleEndian: packed)
                                    let s0 = UInt16(truncatingIfNeeded: host64)
                                    let s1 = UInt16(truncatingIfNeeded: host64 >> 16)
                                    let s2 = UInt16(truncatingIfNeeded: host64 >> 32)
                                    let s3 = UInt16(truncatingIfNeeded: host64 >> 48)
                                    if (s0 > maximum) || (s1 > maximum) || (s2 > maximum) || (s3 > maximum) {
                                        throw CodecError(.invalidArgument, "A sample exceeds the declared meaningful precision.")
                                    }
                                    dstRow[x] = Int32(s0) - shift
                                    dstRow[x + 1] = Int32(s1) - shift
                                    dstRow[x + 2] = Int32(s2) - shift
                                    dstRow[x + 3] = Int32(s3) - shift
                                    srcOffset += 8
                                    x += 4
                                }
                                while x < width {
                                    let s = UInt16(littleEndian: srcPtr.loadUnaligned(fromByteOffset: srcOffset, as: UInt16.self))
                                    guard s <= maximum else {
                                        throw CodecError(.invalidArgument, "A sample exceeds the declared meaningful precision.")
                                    }
                                    dstRow[x] = Int32(s) - shift
                                    srcOffset += 2
                                    x += 1
                                }
                            }
                        }
                    } else {
                        for y in 0..<height {
                            try work.checkAmortized(y)
                            let dstRow = dstBase.advanced(by: y * stride)
                            var srcOffset = layout.offset + y * rowBytes
                            var x = 0
                            while x < fastEnd {
                                let packed = rawBase.loadUnaligned(fromByteOffset: srcOffset, as: UInt64.self)
                                let host64 = UInt64(littleEndian: packed)
                                let s0 = UInt16(truncatingIfNeeded: host64)
                                let s1 = UInt16(truncatingIfNeeded: host64 >> 16)
                                let s2 = UInt16(truncatingIfNeeded: host64 >> 32)
                                let s3 = UInt16(truncatingIfNeeded: host64 >> 48)
                                if (s0 > maximum) || (s1 > maximum) || (s2 > maximum) || (s3 > maximum) {
                                    throw CodecError(.invalidArgument, "A sample exceeds the declared meaningful precision.")
                                }
                                dstRow[x] = Int32(s0) - shift
                                dstRow[x + 1] = Int32(s1) - shift
                                dstRow[x + 2] = Int32(s2) - shift
                                dstRow[x + 3] = Int32(s3) - shift
                                srcOffset += 8
                                x += 4
                            }
                            while x < width {
                                let s = UInt16(littleEndian: rawBase.loadUnaligned(fromByteOffset: srcOffset, as: UInt16.self))
                                guard s <= maximum else {
                                    throw CodecError(.invalidArgument, "A sample exceeds the declared meaningful precision.")
                                }
                                dstRow[x] = Int32(s) - shift
                                srcOffset += 2
                                x += 1
                            }
                        }
                    }
                }
            } else {
                for y in 0..<height {
                    try work.checkAmortized(y)
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
        }
        if cod.decompositionLevels == 0 && parameters.backend == .accelerated {
            if AcceleratedCodec.shouldUseMetal(sampleCount: plane.count) {
                try MetalAccelerationEngine.shared.levelShiftSamples32(samples: &plane, dcShift: 0)
            } else {
                AcceleratedCodec.recordSIMDDispatch()
            }
        } else {
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
        }
        return PreparedLosslessEncode(
            width: width,
            height: height,
            precision: precision,
            workspace: workspace,
            extraWorkspace: extraWorkspace,
            isHT: isHT,
            cod: cod,
            geometry: geometry,
            qcd: qcd,
            plane: plane,
            work: work
        )
    }

    private static func assembleLosslessCodestream(
        prepared: PreparedLosslessEncode,
        encodings: [[[[CodeBlockEncoding]]]]
    ) throws -> ([UInt8], Int) {
        var tile = ByteWriter(capacity: prepared.width * prepared.height / 2)
        try Tier2.encodePackets(
            geometry: prepared.geometry,
            encodings: encodings,
            codingStyle: prepared.cod,
            into: &tile,
            cancellation: prepared.work.check
        )
        var out = ByteWriter(capacity: tile.count + 64)
        out.writeUInt16(Marker.soc)
        let size = ImageSizeSegment(capabilities: prepared.isHT ? 0x4000 : 0, width: prepared.width, height: prepared.height, originX: 0, originY: 0,
                                    tileWidth: prepared.width, tileHeight: prepared.height, tileOriginX: 0, tileOriginY: 0,
                                    components: [ComponentSignalling(precision: prepared.precision, signed: false,
                                                                     horizontalSeparation: 1, verticalSeparation: 1)])
        try CodestreamSyntax.writeSIZ(size, into: &out)
        if prepared.isHT {
            let cap = try ExtendedCapabilitiesSegment.losslessHTOnly(for: prepared.qcd)
            try CodestreamSyntax.writeCAP(cap, into: &out)
        }
        try CodestreamSyntax.writeCOD(prepared.cod, into: &out)
        try CodestreamSyntax.writeQCD(prepared.qcd, into: &out)
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
        return (out.bytes, prepared.workspace)
    }

    static func encode(image: Image, parameters: EncodeParameters, limits: ResourceLimits,
                       progress: (@Sendable (ProgressUpdate) -> Void)?) throws -> ([UInt8], Int) {
        let prepared = try prepareLosslessEncode(image: image, parameters: parameters, limits: limits)
        let total = prepared.geometry.codeBlockCount
        var completed = 0
        var encodeRunningBytes = 0
        progress?(try ProgressUpdate(phase: .processing, completedUnits: 0, totalUnits: total))
        try prepared.work.check()
        let encodings = try encodeTileBlocks(
            plane: prepared.plane,
            stride: prepared.width,
            geometry: prepared.geometry,
            qcd: prepared.qcd,
            blockCoding: parameters.blockCoding,
            backend: parameters.backend,
            work: prepared.work,
            maxExtraWorkspaceBytes: prepared.extraWorkspace,
            runningEncodedBytes: &encodeRunningBytes,
            completed: &completed,
            total: total,
            progress: progress
        )
        return try assembleLosslessCodestream(prepared: prepared, encodings: encodings)
    }

    static func encodeAsync(image: Image, parameters: EncodeParameters, limits: ResourceLimits,
                            progress: (@Sendable (ProgressUpdate) -> Void)?) async throws -> ([UInt8], Int) {
        let prepared = try prepareLosslessEncode(image: image, parameters: parameters, limits: limits)
        let total = prepared.geometry.codeBlockCount
        var completed = 0
        var encodeRunningBytes = 0
        progress?(try ProgressUpdate(phase: .processing, completedUnits: 0, totalUnits: total))
        try prepared.work.check()
        let encodings = try await encodeTileBlocksAsync(
            plane: prepared.plane,
            stride: prepared.width,
            geometry: prepared.geometry,
            qcd: prepared.qcd,
            blockCoding: parameters.blockCoding,
            backend: parameters.backend,
            work: prepared.work,
            maxExtraWorkspaceBytes: prepared.extraWorkspace,
            runningEncodedBytes: &encodeRunningBytes,
            completed: &completed,
            total: total,
            progress: progress
        )
        return try assembleLosslessCodestream(prepared: prepared, encodings: encodings)
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

    private struct PreparedLosslessTranscode: ~Copyable {
        let work: WorkGuard
        let isHT: Bool
        let targetBlockCoding: CodecOptions.BlockCoding
        let firstTile: TileProfile
        let xcb: Int
        let ycb: Int
        let progression: UInt8
        let targetFootprints: [Tier2.TileGeometryFootprint]
        let targetTileGeometries: [TileGeometry]
        let tileQCDs: [QuantizationSegment]
        let persistentStructureBytes: Int
        var peakWorkspace: Int
        var out: BoundedByteWriter
        let total: Int

        func makeTargetCOD(levels: Int) -> CodingStyleSegment {
            CodingStyleSegment(
                usesPrecincts: false, usesSOP: false, usesEPH: false, progression: progression,
                layers: 1, componentTransform: 0,
                decompositionLevels: levels,
                codeBlockWidthExponent: xcb,
                codeBlockHeightExponent: ycb,
                codeBlockStyle: isHT ? 0x40 : 0,
                reversible: true,
                precinctExponents: []
            )
        }
    }

    private static func prepareLosslessTranscode(
        bytes: [UInt8],
        profile: LosslessProfile,
        to target: TranscodeTarget,
        codecOptions: CodecOptions,
        metadataPolicy: MetadataPolicy,
        limits: ResourceLimits
    ) throws -> PreparedLosslessTranscode {
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
        let targetProgression = codecOptions.progressionOrder.rawValue

        func makeTargetCOD(levels: Int) -> CodingStyleSegment {
            CodingStyleSegment(
                usesPrecincts: false, usesSOP: false, usesEPH: false, progression: targetProgression,
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

        let targetFootprints: [Tier2.TileGeometryFootprint] = try profile.tiles.map { tile in
            let tileCOD = makeTargetCOD(levels: tile.codingStyle.decompositionLevels)
            return try Tier2.preflightTileGeometry(
                x0: tile.x0, x1: tile.x1, y0: tile.y0, y1: tile.y1, codingStyle: tileCOD
            )
        }
        let totalTargetBlocks = targetFootprints.reduce(0) { $0 + $1.codeBlockCount }
        let sourceGeometryBytes = profile.totalSourceGeometryBytes
        let targetGeometryBytes = try targetFootprints.reduce(0) { try checkedAdd($0, $1.geometryBytes) }
        let rawMetadataCopyBytes = try checkedAdd(
            (metadataPolicy == .preserve) ? profile.totalCommentSegmentBytes : 0,
            profile.componentRegistration?.count ?? 0
        )
        let metadataCopyBytes = max(rawMetadataCopyBytes, profile.retainedMetadataBytes)
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
            components: [ComponentSignalling(precision: profile.precision, signed: profile.signed,
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

        return PreparedLosslessTranscode(
            work: work,
            isHT: isHT,
            targetBlockCoding: targetBlockCoding,
            firstTile: firstTile,
            xcb: xcb,
            ycb: ycb,
            progression: targetProgression,
            targetFootprints: targetFootprints,
            targetTileGeometries: targetTileGeometries,
            tileQCDs: tileQCDs,
            persistentStructureBytes: persistentStructureBytes,
            peakWorkspace: peakWorkspace,
            out: out,
            total: profile.codeBlockCount + totalTargetBlocks
        )
    }

    private static func assembleTranscodedTile(
        bytes: [UInt8],
        tile: TileProfile,
        tileIndex: Int,
        encodings: inout [[[[CodeBlockEncoding]]]],
        tileEncodedRetainedBytes: Int,
        liveBeforeBlockPayloads: Int,
        metadataPolicy: MetadataPolicy,
        limits: ResourceLimits,
        state: inout PreparedLosslessTranscode
    ) throws {
        let tileCOD = state.makeTargetCOD(levels: tile.codingStyle.decompositionLevels)
        let targetFootprint = state.targetFootprints[tileIndex]
        let targetTileGeometry = state.targetTileGeometries[tileIndex]
        let tileQCD = state.tileQCDs[tileIndex]

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
        let tileEncodeWorkspace = try checkedAdd(liveBeforeBlockPayloads, tileEncodedRetainedBytes)
        state.peakWorkspace = max(state.peakWorkspace, tileEncodeWorkspace)

        let overrideHeaderBytes = (tile.codingStyle.decompositionLevels != state.firstTile.codingStyle.decompositionLevels)
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

        let liveDuringPacketEncode = try checkedAdd(
            try checkedAdd(state.persistentStructureBytes, state.out.allocatedBytes),
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
        let compAvailForTileWriter = limits.maximumCompressedBytes - state.out.count - 16 - exactTileHeaderBytes
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
        if tile.codingStyle.decompositionLevels != state.firstTile.codingStyle.decompositionLevels {
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
        try Tier2.encodePackets(
            geometry: targetTileGeometry,
            encodings: encodings,
            codingStyle: tileCOD,
            into: &tileWriter,
            cancellation: state.work.check
        )
        encodings = []

        let packetAssemblyBytes = try checkedAdd(tileHeaderWriter.count, tileWriter.count)
        StorageTelemetry.recordWorkspaceAllocation(bytes: packetAssemblyBytes)
        let packetAssemblyAlloc = try checkedAdd(tileHeaderWriter.allocatedBytes, tileWriter.allocatedBytes)
        let tilePacketWorkspace = try checkedAdd(
            liveDuringPacketEncode,
            try checkedAdd(tileHeaderWriter.allocatedBytes, tileWriter.peakAllocationBytes)
        )
        state.peakWorkspace = max(state.peakWorkspace, tilePacketWorkspace)
        guard state.peakWorkspace <= limits.maximumWorkspaceBytes,
              try checkedAdd(bytes.count, tilePacketWorkspace) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Transcoder packet assembly workspace exceeds the operation limit.")
        }

        let psot = 12 + tileHeaderWriter.count + 2 + tileWriter.count
        guard psot <= Int(UInt32.max) else { throw CodecError(.resourceLimitExceeded, "Tile-part exceeds the Psot field.") }
        let projectedOutputBytes = try checkedAdd(state.out.count, psot + 2)
        guard projectedOutputBytes <= limits.maximumCompressedBytes else {
            throw CodecError(.resourceLimitExceeded, "Transcoded output exceeds the compressed-size limit.")
        }
        let appendOtherWorkspace = try checkedAdd(state.persistentStructureBytes, packetAssemblyAlloc)
        let appendOtherResident = try checkedAdd(bytes.count, appendOtherWorkspace)
        guard appendOtherWorkspace <= limits.maximumWorkspaceBytes,
              appendOtherResident <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Packet workspace exceeds the output admission budget.")
        }
        let outputAllocationBudget = min(
            limits.maximumWorkspaceBytes - appendOtherWorkspace,
            limits.maximumMemoryBytes - appendOtherResident
        )
        try state.out.updateBudget(maximumBytes: projectedOutputBytes, maximumAllocationBytes: outputAllocationBudget)
        try state.out.reserveCapacity(projectedOutputBytes)
        state.peakWorkspace = max(state.peakWorkspace, try checkedAdd(appendOtherWorkspace, state.out.peakAllocationBytes))
        try state.out.writeUInt16Checked(Marker.sot)
        try state.out.writeUInt16Checked(10)
        try state.out.writeUInt16Checked(UInt16(tile.index))
        try state.out.writeUInt32Checked(UInt32(psot))
        try state.out.writeUInt8Checked(0)
        try state.out.writeUInt8Checked(1)
        try state.out.writeBytesChecked(from: tileHeaderWriter)
        try state.out.writeUInt16Checked(Marker.sod)
        try state.out.writeBytesChecked(from: tileWriter)
    }

    private static func finalizeLosslessTranscode(
        bytes: [UInt8],
        limits: ResourceLimits,
        state: inout PreparedLosslessTranscode
    ) throws -> (Data, Int) {
        try state.out.writeUInt16Checked(Marker.eoc)
        guard state.out.count <= limits.maximumCompressedBytes else {
            throw CodecError(.resourceLimitExceeded, "Transcoded output exceeds the compressed-size limit.")
        }
        let publicationWorkspace = try checkedAdd(
            state.persistentStructureBytes, try checkedAdd(state.out.allocatedBytes, state.out.count)
        )
        guard publicationWorkspace <= limits.maximumWorkspaceBytes,
              try checkedAdd(bytes.count, publicationWorkspace) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Publishing transcoded Data exceeds the admission budget.")
        }
        try state.work.check()
        StorageTelemetry.recordStage("output-data", bytes: state.out.count)
        let output = try state.out.copyData()
        state.peakWorkspace = max(state.peakWorkspace, publicationWorkspace)
        return (output, state.peakWorkspace)
    }

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
        var state = try prepareLosslessTranscode(
            bytes: bytes, profile: profile, to: target, codecOptions: codecOptions,
            metadataPolicy: metadataPolicy, limits: limits
        )
        var completed = 0
        progress?(try ProgressUpdate(phase: .processing, completedUnits: 0, totalUnits: state.total))
        try state.work.check()
        let blockScratch = BitPlaneCoder.maximumCoefficients * (4 + 4 + 1) + 66 * 66 + 4096

        for (tileIndex, tile) in profile.tiles.enumerated() {
            try state.work.check()
            let tileDataBytes = tile.dataRanges.reduce(0) { $0 + $1.count }
            let tileJoinedExtra = tile.dataRanges.count > 1 ? (32 + tileDataBytes) : 0
            let planeBytes = try checkedMultiply(tile.width * tile.height, 4)
            let tileDecodeLive = try checkedAdd(
                try checkedAdd(state.persistentStructureBytes, state.out.allocatedBytes),
                try checkedAdd(
                    try checkedAdd(tile.footprint.decodeStateBytes, tileDataBytes + tileJoinedExtra),
                    try checkedAdd(planeBytes, blockScratch)
                )
            )
            state.peakWorkspace = max(state.peakWorkspace, tileDecodeLive)
            guard state.peakWorkspace <= limits.maximumWorkspaceBytes,
                  try checkedAdd(bytes.count, tileDecodeLive) <= limits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "Tile decode workspace exceeds workspace or memory limits.")
            }
            let tileDecodeExtra = min(
                limits.maximumWorkspaceBytes - tileDecodeLive,
                limits.maximumMemoryBytes - (bytes.count + tileDecodeLive)
            )

            var plane = try decodeTileCoefficients(
                bytes: bytes,
                tile: tile,
                work: state.work,
                backend: backend,
                maxExtraWorkspaceBytes: tileDecodeExtra,
                completed: &completed,
                total: state.total,
                progress: progress
            )
            let targetFootprint = state.targetFootprints[tileIndex]
            let liveBeforeBlockPayloads = try checkedAdd(
                try checkedAdd(state.persistentStructureBytes, state.out.allocatedBytes),
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
            let compRemainingForBlocks = max(0, limits.maximumCompressedBytes - state.out.count)
            let maxHeaderOverhead = try checkedMultiply(targetFootprint.codeBlockCount, 32)
            let maxRetainedEncodedBytes = min(
                min(wsRemainingForBlocks, memRemainingForBlocks),
                try checkedAdd(compRemainingForBlocks, maxHeaderOverhead)
            )

            var tileEncodedRetainedBytes = 0
            var encodings = try encodeTileBlocks(
                plane: plane,
                stride: tile.width,
                geometry: state.targetTileGeometries[tileIndex],
                qcd: state.tileQCDs[tileIndex],
                blockCoding: state.targetBlockCoding,
                backend: backend,
                work: state.work,
                maxRetainedEncodedBytes: maxRetainedEncodedBytes,
                maxExtraWorkspaceBytes: min(wsRemainingForBlocks, memRemainingForBlocks),
                runningEncodedBytes: &tileEncodedRetainedBytes,
                recordBlockStages: true,
                completed: &completed,
                total: state.total,
                progress: progress
            )
            plane = []
            try assembleTranscodedTile(
                bytes: bytes, tile: tile, tileIndex: tileIndex, encodings: &encodings,
                tileEncodedRetainedBytes: tileEncodedRetainedBytes, liveBeforeBlockPayloads: liveBeforeBlockPayloads,
                metadataPolicy: metadataPolicy, limits: limits, state: &state
            )
        }
        return try finalizeLosslessTranscode(bytes: bytes, limits: limits, state: &state)
    }

    static func transcodeAsync(
        bytes: [UInt8],
        profile: LosslessProfile,
        to target: TranscodeTarget,
        codecOptions: CodecOptions,
        metadataPolicy: MetadataPolicy = .preserve,
        limits: ResourceLimits,
        backend: Backend = .scalarCPU,
        progress: (@Sendable (ProgressUpdate) -> Void)?
    ) async throws -> (Data, Int) {
        var state = try prepareLosslessTranscode(
            bytes: bytes, profile: profile, to: target, codecOptions: codecOptions,
            metadataPolicy: metadataPolicy, limits: limits
        )
        var completed = 0
        progress?(try ProgressUpdate(phase: .processing, completedUnits: 0, totalUnits: state.total))
        try state.work.check()
        let blockScratch = BitPlaneCoder.maximumCoefficients * (4 + 4 + 1) + 66 * 66 + 4096

        for (tileIndex, tile) in profile.tiles.enumerated() {
            try state.work.check()
            let tileDataBytes = tile.dataRanges.reduce(0) { $0 + $1.count }
            let tileJoinedExtra = tile.dataRanges.count > 1 ? (32 + tileDataBytes) : 0
            let planeBytes = try checkedMultiply(tile.width * tile.height, 4)
            let tileDecodeLive = try checkedAdd(
                try checkedAdd(state.persistentStructureBytes, state.out.allocatedBytes),
                try checkedAdd(
                    try checkedAdd(tile.footprint.decodeStateBytes, tileDataBytes + tileJoinedExtra),
                    try checkedAdd(planeBytes, blockScratch)
                )
            )
            state.peakWorkspace = max(state.peakWorkspace, tileDecodeLive)
            guard state.peakWorkspace <= limits.maximumWorkspaceBytes,
                  try checkedAdd(bytes.count, tileDecodeLive) <= limits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "Tile decode workspace exceeds workspace or memory limits.")
            }
            let tileDecodeExtra = min(
                limits.maximumWorkspaceBytes - tileDecodeLive,
                limits.maximumMemoryBytes - (bytes.count + tileDecodeLive)
            )

            var plane = try decodeTileCoefficients(
                bytes: bytes,
                tile: tile,
                work: state.work,
                backend: backend,
                maxExtraWorkspaceBytes: tileDecodeExtra,
                completed: &completed,
                total: state.total,
                progress: progress
            )
            let targetFootprint = state.targetFootprints[tileIndex]
            let liveBeforeBlockPayloads = try checkedAdd(
                try checkedAdd(state.persistentStructureBytes, state.out.allocatedBytes),
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
            let compRemainingForBlocks = max(0, limits.maximumCompressedBytes - state.out.count)
            let maxHeaderOverhead = try checkedMultiply(targetFootprint.codeBlockCount, 32)
            let maxRetainedEncodedBytes = min(
                min(wsRemainingForBlocks, memRemainingForBlocks),
                try checkedAdd(compRemainingForBlocks, maxHeaderOverhead)
            )

            var tileEncodedRetainedBytes = 0
            var encodings = try await encodeTileBlocksAsync(
                plane: plane,
                stride: tile.width,
                geometry: state.targetTileGeometries[tileIndex],
                qcd: state.tileQCDs[tileIndex],
                blockCoding: state.targetBlockCoding,
                backend: backend,
                work: state.work,
                maxRetainedEncodedBytes: maxRetainedEncodedBytes,
                maxExtraWorkspaceBytes: min(wsRemainingForBlocks, memRemainingForBlocks),
                runningEncodedBytes: &tileEncodedRetainedBytes,
                recordBlockStages: true,
                completed: &completed,
                total: state.total,
                progress: progress
            )
            plane = []
            try assembleTranscodedTile(
                bytes: bytes, tile: tile, tileIndex: tileIndex, encodings: &encodings,
                tileEncodedRetainedBytes: tileEncodedRetainedBytes, liveBeforeBlockPayloads: liveBeforeBlockPayloads,
                metadataPolicy: metadataPolicy, limits: limits, state: &state
            )
        }
        return try finalizeLosslessTranscode(bytes: bytes, limits: limits, state: &state)
    }
}
