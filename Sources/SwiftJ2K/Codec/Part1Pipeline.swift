// SPDX-License-Identifier: Apache-2.0
//
// General JPEG 2000 Part 1 (ISO/IEC 15444-1) and Part 15 (HTJ2K lossless)
// pipeline supporting:
// - 1 to N components (greyscale, RGB, RGBA, multi-component), planar & interleaved
// - Unsigned and signed 1–16 bit samples in 8-bit or 16-bit storage
// - Reversible 5/3 and irreversible 9/7 wavelet transforms
// - Reversible Colour Transform (RCT) and Irreversible Colour Transform (ICT)
// - Unquantised, scalar-derived (Sqcd=1), and scalar-expounded (Sqcd=2) quantisation
// - Lossless, near-lossless (bounded absolute error), and lossy PCRD-opt rate control
// - Multi-tile, multi-layer, explicit precincts, all 5 progression orders + POC,
//   SOP/EPH markers, all 6 code-block style flags, and RGN MaxShift ROI.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct Part1ComponentTileProfile: Sendable {
    let componentIndex: Int
    let codingStyle: CodingStyleSegment
    let quantization: QuantizationSegment
    let roiShift: Int
    let magnitudeBitPlanes: [Int]
    let stepSizes: [Double]
    let footprint: Tier2.TileGeometryFootprint
    let geometry: TileGeometry
}

struct Part1TileProfile: Sendable {
    let index: Int
    let x0: Int, x1: Int, y0: Int, y1: Int
    let defaultCodingStyle: CodingStyleSegment
    let progressionChanges: [ProgressionOrderChangeEntry]
    let part2MCTPlan: Part2MCTPlan?
    let components: [Part1ComponentTileProfile]
    let dataRanges: [Range<Int>]
    let comments: [[UInt8]]
    var width: Int { x1 - x0 }
    var height: Int { y1 - y0 }
}

struct Part1Profile: Sendable {
    let width: Int
    let height: Int
    let originX: Int, originY: Int
    let tileWidth: Int, tileHeight: Int
    let tileOriginX: Int, tileOriginY: Int
    let componentCount: Int
    let wireComponents: [ComponentSignalling]
    let precision: Int
    let signed: Bool
    let isHTJ2K: Bool
    let isReversibleLossless: Bool
    let tiles: [Part1TileProfile]
    let commentCount: Int
    let commentPayloadBytes: Int
    let retainedMetadataBytes: Int

    var format: String { isHTJ2K ? ScalarLosslessCodec.htj2kFormat : ScalarLosslessCodec.format }
    var isPart2MCT: Bool { tiles.contains { $0.part2MCTPlan != nil } }
    var workspaceComponentCount: Int { max(wireComponents.count, componentCount) }
    var codeBlockCount: Int {
        tiles.reduce(0) { acc, tile in
            acc + tile.components.reduce(0) { $0 + $1.geometry.codeBlockCount }
        }
    }
    var largestTilePixels: Int { tiles.map { $0.width * $0.height }.max() ?? 0 }
    var largestTileBytes: Int { tiles.map { $0.dataRanges.reduce(0) { $0 + $1.count } }.max() ?? 0 }

    func defaultDescriptor(limits: ResourceLimits) throws -> ImageDescriptor {
        if componentCount == 1 {
            if signed {
                return try ImageDescriptor.signedGreyscale16(
                    width: width, height: height, meaningfulBits: precision, limits: limits
                )
            } else {
                return try ImageDescriptor.greyscale16(
                    width: width, height: height, meaningfulBits: precision, limits: limits
                )
            }
        }
        let storageBits = precision <= 8 ? 8 : 16
        let sampleType: SampleType = signed ? .signedInteger : .unsignedInteger
        if componentCount == 3 {
            return try ImageDescriptor.rgbPlanar(
                width: width, height: height, storageBits: storageBits,
                meaningfulBits: precision, signed: signed, limits: limits
            )
        }
        return try ImageDescriptor.multiComponentPlanar(
            width: width, height: height, componentCount: componentCount,
            storageBits: storageBits, meaningfulBits: precision,
            sampleType: sampleType, limits: limits
        )
    }
}

enum Part1Pipeline {
    // MARK: - Inspection

    static func inspect(
        _ bytes: [UInt8],
        limits: ResourceLimits,
        metadataPolicy: MetadataPolicy = .preserve
    ) throws -> Part1Profile {
        let parsed = try CodestreamSyntax.parse(bytes, limits: limits, metadataPolicy: metadataPolicy)
        let size = parsed.size
        let hasPart2MCTMarkers = parsed.componentBitDepth != nil
            || !parsed.mctTables.isEmpty
            || !parsed.mccStages.isEmpty
            || parsed.mco != nil
            || parsed.tileOverrides.values.contains {
                !$0.mctFragments.isEmpty || !$0.mccFragments.isEmpty || $0.mco != nil
            }
        if (size.capabilities & 0x8000) != 0 {
            let allowedPart2Mask: UInt16 = hasPart2MCTMarkers ? 0xC102 : 0xC100
            guard (size.capabilities & ~allowedPart2Mask) == 0 else {
                throw CodecError(
                    .unsupportedFeature,
                    String(format: "Part 2 SIZ Rsiz capability 0x%04X is not supported.", size.capabilities)
                )
            }
            if !hasPart2MCTMarkers && (parsed.extendedCapabilities?.hasPart2 != true) {
                throw CodecError(
                    .unsupportedFeature,
                    String(format: "Part 2 SIZ Rsiz capability 0x%04X has no supported Part 2 extension.", size.capabilities)
                )
            }
        }
        if let cap = parsed.extendedCapabilities {
            guard !cap.multiHT else {
                throw CodecError(.unsupportedFeature, "Multiple HT sets per code-block (MULTIHT) are not supported.")
            }
            guard !cap.heterogeneousTileParts else {
                throw CodecError(.unsupportedFeature, "Heterogeneous HTJ2K tile-parts (HETERO) are not supported.")
            }
            guard !cap.regionOfInterestPresent else {
                throw CodecError(.unsupportedFeature, "Region-of-interest (RGN) coding is not supported in HTJ2K mode.")
            }
        }
        let wireComponentCount = size.components.count
        guard wireComponentCount >= 1 else {
            throw CodecError(.malformedInput, "SIZ declares no components.")
        }
        for comp in size.components {
            guard comp.horizontalSeparation == 1 && comp.verticalSeparation == 1 else {
                throw CodecError(.unsupportedFeature, "Sub-sampled components are not supported.")
            }
        }

        let tilesWide = Wavelet53.ceilDiv(size.width - size.tileOriginX, size.tileWidth)
        let tilesHigh = Wavelet53.ceilDiv(size.height - size.tileOriginY, size.tileHeight)
        guard tilesWide >= 1, tilesHigh >= 1, tilesWide * tilesHigh <= 65535 else {
            throw CodecError(.malformedInput, "Tile grid is empty or exceeds 65535 tiles.")
        }

        var partsByTile: [Int: [TilePartRecord]] = [:]
        for part in parsed.tileParts { partsByTile[part.tileIndex, default: []].append(part) }

        var tiles: [Part1TileProfile] = []
        var runningGeometryBytes = parsed.retainedMetadataBytes
        var allReversibleLossless = true
        var anyPart2MCTActive = false

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
            let p = tileIndex % tilesWide, q = tileIndex / tilesWide
            let tx0 = max(size.tileOriginX + p * size.tileWidth, size.originX)
            let ty0 = max(size.tileOriginY + q * size.tileHeight, size.originY)
            let tx1 = min(size.tileOriginX + (p + 1) * size.tileWidth, size.width)
            let ty1 = min(size.tileOriginY + (q + 1) * size.tileHeight, size.height)
            guard tx1 > tx0, ty1 > ty0 else {
                throw CodecError(.malformedInput, "Tile has an empty area.")
            }

            let part2Plan = try parsed.effectivePart2MCTPlan(tile: tileIndex) { addedBytes in
                runningGeometryBytes = try checkedAdd(runningGeometryBytes, addedBytes)
                guard runningGeometryBytes <= limits.maximumWorkspaceBytes,
                      try checkedAdd(bytes.count, runningGeometryBytes) <= limits.maximumMemoryBytes else {
                    throw CodecError(.resourceLimitExceeded, "Part 2 MCT tile tables exceed workspace or memory limits.")
                }
            }
            if part2Plan != nil {
                anyPart2MCTActive = true
            }
            if let plan = part2Plan, !plan.isAllReversible {
                allReversibleLossless = false
            }

            let (defaultCOD, _) = parsed.effectiveParameters(tile: tileIndex, component: 0)
            if (defaultCOD.componentTransform & 0x04) != 0 {
                throw CodecError(.unsupportedFeature, "Part 2 wavelet multi-component transform is not supported.")
            }
            if part2Plan != nil {
                guard defaultCOD.componentTransform == 0 || defaultCOD.componentTransform == 2 else {
                    throw CodecError(.malformedInput, "Invalid COD componentTransform (\(defaultCOD.componentTransform)) for Part 2 MCT tile.")
                }
            } else {
                guard defaultCOD.componentTransform <= 1 else {
                    throw CodecError(.malformedInput, "COD signals Part 2 componentTransform (\(defaultCOD.componentTransform)) without active MCO.")
                }
                if defaultCOD.componentTransform == 1 {
                    guard wireComponentCount >= 3 else {
                        throw CodecError(.malformedInput, "A component transform is signalled for fewer than 3 components.")
                    }
                }
            }

            var compProfiles: [Part1ComponentTileProfile] = []
            compProfiles.reserveCapacity(wireComponentCount)

            for c in 0..<wireComponentCount {
                let (cod, rawQCD) = parsed.effectiveParameters(tile: tileIndex, component: c)
                if (cod.codeBlockStyle & 0x40) != 0 && (cod.codeBlockStyle & 0x80) == 0 {
                    guard (cod.codeBlockStyle & 0x36) == 0 else {
                        throw CodecError(.malformedInput, "COD/COC sets reserved code-block style bits in HTJ2K mode.")
                    }
                    guard (cod.codeBlockStyle & 0x01) == 0 else {
                        throw CodecError(.unsupportedFeature, "HTJ2K SigProp and MagRef refinement passes are not supported.")
                    }
                }
                if !cod.reversible || rawQCD.style != .none {
                    allReversibleLossless = false
                }
                let qcd = try rawQCD.expanded(decompositionLevels: cod.decompositionLevels)
                let bandCount = 3 * cod.decompositionLevels + 1
                guard qcd.exponents.count >= bandCount else {
                    throw CodecError(.malformedInput, "QCD/QCC lists fewer bands than the decomposition needs.")
                }
                let roiShift = parsed.effectiveROIShift(tile: tileIndex, component: c)
                let footprint = try Tier2.preflightTileGeometry(x0: tx0, x1: tx1, y0: ty0, y1: ty1, codingStyle: cod)
                runningGeometryBytes = try checkedAdd(runningGeometryBytes, footprint.geometryBytes)
                guard runningGeometryBytes <= limits.maximumWorkspaceBytes,
                      try checkedAdd(bytes.count, runningGeometryBytes) <= limits.maximumMemoryBytes else {
                    throw CodecError(.resourceLimitExceeded, "Source tile geometry exceeds workspace or memory limits.")
                }
                let geometry = try Tier2.makeTileGeometry(x0: tx0, x1: tx1, y0: ty0, y1: ty1, codingStyle: cod)

                // Component dynamic range Rb = wirePrecision + rctAdjust + band.gain
                let wirePrecision = size.components[c].precision
                let rctAdjust = (part2Plan == nil && defaultCOD.componentTransform == 1 && cod.reversible && (c == 1 || c == 2)) ? 1 : 0
                let compRangePrecision = wirePrecision + rctAdjust

                var magnitudeBitPlanes: [Int] = []
                var stepSizes: [Double] = []
                magnitudeBitPlanes.reserveCapacity(bandCount)
                stepSizes.reserveCapacity(bandCount)

                for resolution in geometry.resolutions {
                    for band in resolution.bands {
                        let qIdx = band.quantizationIndex
                        let eps = qcd.exponents[qIdx]
                        let mb = qcd.guardBits + eps - 1
                        if qcd.style == .none {
                            guard mb >= 1, mb + roiShift <= BitPlaneCoder.maximumExtendedBitPlanes else {
                                throw CodecError(.malformedInput, "Band exponent and guard bits give an unusable bit-plane count.")
                            }
                            magnitudeBitPlanes.append(mb)
                            stepSizes.append(1.0)
                        } else {
                            let clampedMB = max(0, mb)
                            guard clampedMB + roiShift <= BitPlaneCoder.maximumExtendedBitPlanes else {
                                throw CodecError(.malformedInput, "Band exponent and guard bits give an unusable bit-plane count.")
                            }
                            magnitudeBitPlanes.append(clampedMB)
                            let mu = qIdx < qcd.mantissas.count ? qcd.mantissas[qIdx] : 0
                            stepSizes.append(Quantization.stepSize(
                                exponent: eps, mantissa: mu, precision: compRangePrecision, gain: band.gain
                            ))
                        }
                    }
                }

                compProfiles.append(Part1ComponentTileProfile(
                    componentIndex: c,
                    codingStyle: cod,
                    quantization: qcd,
                    roiShift: roiShift,
                    magnitudeBitPlanes: magnitudeBitPlanes,
                    stepSizes: stepSizes,
                    footprint: footprint,
                    geometry: geometry
                ))
            }

            let pocEntries = parsed.effectiveProgressionChanges(tile: tileIndex)
            tiles.append(Part1TileProfile(
                index: tileIndex,
                x0: tx0, x1: tx1, y0: ty0, y1: ty1,
                defaultCodingStyle: defaultCOD,
                progressionChanges: pocEntries,
                part2MCTPlan: part2Plan,
                components: compProfiles,
                dataRanges: ordered.map(\.dataRange),
                comments: ordered.flatMap(\.comments)
            ))
        }

        guard tiles.count == tilesWide * tilesHigh else {
            throw CodecError(.malformedInput, "Codestream lacks tile-parts for \(tilesWide * tilesHigh - tiles.count) of its tiles.")
        }

        if let cap = parsed.extendedCapabilities, cap.hasPart15 {
            let hasIrreversibleWavelet = tiles.contains { tile in
                tile.components.contains { !$0.codingStyle.reversible }
            }
            if cap.irreversible != hasIrreversibleWavelet {
                throw CodecError(.malformedInput, "CAP Ccap15 HTIRV/HTREV bit contradicts COD/COC wavelet transformation.")
            }
        }

        let logicalComponentCount: Int
        let logicalPrecision: Int
        let logicalSigned: Bool

        if anyPart2MCTActive || parsed.componentBitDepth != nil {
            guard let cbd = parsed.componentBitDepth else {
                throw CodecError(.malformedInput, "Part 2 MCT is active without a CBD marker segment.")
            }
            guard !cbd.components.isEmpty else {
                throw CodecError(.malformedInput, "CBD declares no output components.")
            }
            for wireComp in size.components {
                guard wireComp.precision >= 1 && wireComp.precision <= 28 else {
                    throw CodecError(.unsupportedFeature, "Part 2 wire SIZ component precision (\(wireComp.precision)) is not supported.")
                }
            }
            let firstCBD = cbd.components[0]
            for cbdComp in cbd.components {
                guard cbdComp.precision >= 1 && cbdComp.precision <= 16 else {
                    throw CodecError(.unsupportedFeature, "CBD output component precision above 16 bits is not supported.")
                }
                guard cbdComp.signed == firstCBD.signed && cbdComp.precision == firstCBD.precision else {
                    throw CodecError(.unsupportedFeature, "Heterogeneous CBD output component precision or signedness is not supported.")
                }
            }
            for tile in tiles {
                let tileOutCount = tile.part2MCTPlan?.outputComponentCount ?? wireComponentCount
                guard tileOutCount == cbd.components.count else {
                    throw CodecError(
                        .malformedInput,
                        "Tile \(tile.index) output component count (\(tileOutCount)) disagrees with CBD Ncbd (\(cbd.components.count))."
                    )
                }
            }
            logicalComponentCount = cbd.components.count
            logicalPrecision = firstCBD.precision
            logicalSigned = firstCBD.signed
        } else {
            let firstComp = size.components[0]
            for comp in size.components {
                guard comp.precision >= 1 && comp.precision <= 16 else {
                    throw CodecError(.unsupportedFeature, "Component precision above 16 bits is not supported.")
                }
                guard comp.signed == firstComp.signed && comp.precision == firstComp.precision else {
                    throw CodecError(.unsupportedFeature, "Heterogeneous component precision or signedness is not supported.")
                }
            }
            logicalComponentCount = wireComponentCount
            logicalPrecision = firstComp.precision
            logicalSigned = firstComp.signed
        }

        return Part1Profile(
            width: size.width - size.originX,
            height: size.height - size.originY,
            originX: size.originX,
            originY: size.originY,
            tileWidth: size.tileWidth,
            tileHeight: size.tileHeight,
            tileOriginX: size.tileOriginX,
            tileOriginY: size.tileOriginY,
            componentCount: logicalComponentCount,
            wireComponents: size.components,
            precision: logicalPrecision,
            signed: logicalSigned,
            isHTJ2K: parsed.isHTJ2K,
            isReversibleLossless: allReversibleLossless,
            tiles: tiles,
            commentCount: parsed.commentCount,
            commentPayloadBytes: parsed.commentPayloadBytes,
            retainedMetadataBytes: parsed.retainedMetadataBytes
        )
    }

    static func workspaceBytes(
        planePixels: Int,
        componentCount: Int,
        bytesPerCoeff: Int,
        joinedBytes: Int
    ) throws -> Int {
        let singlePlane = try checkedMultiply(planePixels, bytesPerCoeff)
        let allPlanes = try checkedMultiply(singlePlane, componentCount)
        let blockScratch = BitPlaneCoder.maximumCoefficients * (8 + 8 + 1) + 66 * 66 + 4096
        return try checkedAdd(checkedAdd(allPlanes, joinedBytes), blockScratch)
    }

    // MARK: - Decoding

    static func decode(
        bytes: [UInt8],
        profile: Part1Profile,
        into destination: ImageDestination,
        limits: ResourceLimits,
        backend: Backend = .scalarCPU,
        progress: (@Sendable (ProgressUpdate) -> Void)?,
        paletteMapping: (palette: JP2PaletteBox, cmap: JP2ComponentMappingBox)? = nil,
        channelPermutation: [Int]? = nil,
        maxQualityLayers: Int? = nil
    ) throws -> (Image, Int) {
        let descriptor = destination.descriptor
        let outputComponentCount = paletteMapping?.cmap.entries.count ?? profile.componentCount
        let outputPrecision: Int
        let outputSigned: Bool
        if let (pclr, cmap) = paletteMapping {
            var maxPrec = 1
            var anySigned = false
            for entry in cmap.entries {
                if entry.mappingType == 1 {
                    let col = Int(entry.paletteColumn)
                    maxPrec = max(maxPrec, pclr.columns[col].bitDepth)
                    if pclr.columns[col].isSigned { anySigned = true }
                } else {
                    maxPrec = max(maxPrec, profile.precision)
                    if profile.signed { anySigned = true }
                }
            }
            outputPrecision = maxPrec
            outputSigned = anySigned
        } else {
            outputPrecision = profile.precision
            outputSigned = profile.signed
        }
        let expectedSampleType: SampleType = outputSigned ? .signedInteger : .unsignedInteger
        let validStorageBits = descriptor.storageBits == 16 || (descriptor.storageBits == 8 && outputPrecision <= 8)
        let validComponents: Bool
        if outputComponentCount == 1 && paletteMapping == nil && channelPermutation == nil {
            validComponents = descriptor.components.count == 1
        } else {
            validComponents = descriptor.components.count == outputComponentCount
        }
        guard descriptor.width == profile.width,
              descriptor.height == profile.height,
              descriptor.sampleType == expectedSampleType,
              validStorageBits,
              validComponents,
              descriptor.meaningfulBits == outputPrecision else {
            throw CodecError(.incompatibleImageLayout, "Destination descriptor does not match the codestream geometry, components, signedness, or precision.")
        }

        let bytesPerCoeff = profile.isReversibleLossless ? 4 : 8
        let workspace = try checkedAdd(
            try workspaceBytes(
                planePixels: profile.largestTilePixels,
                componentCount: profile.workspaceComponentCount,
                bytesPerCoeff: bytesPerCoeff,
                joinedBytes: profile.largestTileBytes
            ),
            profile.retainedMetadataBytes
        )
        guard workspace <= limits.maximumWorkspaceBytes else {
            throw CodecError(.resourceLimitExceeded, "Decoder workspace exceeds the operation limit.")
        }
        guard try checkedAdd(checkedAdd(bytes.count, destination.storage.byteCount), workspace) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Compressed input, destination and workspace exceed the memory budget.")
        }

        let work = WorkGuard(limits: limits)
        try work.check()
        do {
            return try decodeAdmitted(
                bytes: bytes, profile: profile, into: destination,
                workspace: workspace, work: work, backend: backend, progress: progress,
                paletteMapping: paletteMapping,
                channelPermutation: channelPermutation,
                outputComponentCount: outputComponentCount,
                outputSigned: outputSigned,
                maxQualityLayers: maxQualityLayers
            )
        } catch {
            destination.invalidateAfterFailure()
            throw error
        }
    }

    private static func decodeAdmitted(
        bytes: [UInt8],
        profile: Part1Profile,
        into destination: ImageDestination,
        workspace: Int,
        work: WorkGuard,
        backend: Backend,
        progress: (@Sendable (ProgressUpdate) -> Void)?,
        paletteMapping: (palette: JP2PaletteBox, cmap: JP2ComponentMappingBox)?,
        channelPermutation: [Int]?,
        outputComponentCount: Int,
        outputSigned: Bool,
        maxQualityLayers: Int?
    ) throws -> (Image, Int) {
        let descriptor = destination.descriptor
        let mutation = SharedPathMutation.active
        let order = mutation == .wrongByteOrder ? descriptor.byteOrder.opposite : descriptor.byteOrder
        let wireShifts = profile.wireComponents.map { $0.signed ? 0 : (1 << ($0.precision - 1)) }
        let minVal = profile.signed ? -(1 << (profile.precision - 1)) : 0
        let maxVal = profile.signed ? ((1 << (profile.precision - 1)) - 1) : ((1 << profile.precision) - 1)

        // Pre-locate plane and sample offset for each output component index.
        var compLocations: [(plane: PlaneDescriptor, sampleOffset: Int, rowBytes: Int)] = []
        compLocations.reserveCapacity(outputComponentCount)
        for c in 0..<outputComponentCount {
            guard let plane = descriptor.planes.first(where: { $0.components.contains(c) }),
                  let idxInPlane = plane.components.firstIndex(of: c) else {
                throw CodecError(.incompatibleImageLayout, "Component \(c) is not mapped in destination planes.")
            }
            let rb = mutation == .ignoreRowStride ? profile.width * plane.pixelStride : plane.rowBytes
            compLocations.append((plane, idxInPlane * plane.sampleStride, rb))
        }

        let total = max(1, profile.codeBlockCount)
        var completed = 0
        progress?(try ProgressUpdate(phase: .processing, completedUnits: 0, totalUnits: total))
        try work.check()

        let image = try destination.write { output in
            for tile in profile.tiles {
                try work.check()
                let tileBytes: [UInt8]
                let tileRange: Range<Int>
                if tile.dataRanges.count == 1 {
                    tileBytes = bytes
                    tileRange = tile.dataRanges[0]
                } else {
                    let joinedCount = tile.dataRanges.reduce(0) { $0 + $1.count }
                    StorageTelemetry.recordWorkspaceAllocation(bytes: joinedCount)
                    var joined: [UInt8] = []
                    joined.reserveCapacity(joinedCount)
                    for r in tile.dataRanges { joined.append(contentsOf: bytes[r]) }
                    tileBytes = joined
                    tileRange = 0..<joined.count
                }

                let geometries = tile.components.map(\.geometry)
                let codingStyles = tile.components.map(\.codingStyle)
                let contributions = try Tier2.decodePacketsMulti(
                    geometries: geometries,
                    codingStyles: codingStyles,
                    progressionChanges: tile.progressionChanges,
                    maxQualityLayers: maxQualityLayers,
                    bytes: tileBytes,
                    range: tileRange,
                    cancellation: work.check
                )

                let stride = tile.width
                let planeCount = tile.width * tile.height
                let tileUsesReversibleIntPath = tile.components.allSatisfy {
                    $0.codingStyle.reversible && $0.quantization.style == .none
                } && (tile.part2MCTPlan?.isAllReversible ?? true)

                if tileUsesReversibleIntPath {
                    var intPlanes: [[Int32]] = []
                    intPlanes.reserveCapacity(profile.wireComponents.count)
                    for comp in tile.components {
                        let c = comp.componentIndex
                        StorageTelemetry.recordWorkspaceAllocation(bytes: planeCount * 4)
                        var plane = [Int32](repeating: 0, count: planeCount)
                        let style = CodeBlockStyle(bits: comp.codingStyle.codeBlockStyle)
                        for resolution in comp.geometry.resolutions {
                            for (p, precinct) in resolution.precincts.enumerated() {
                                for (b, precinctBand) in precinct.bands.enumerated() {
                                    let band = resolution.bands[precinctBand.bandIndex]
                                    let mb = comp.magnitudeBitPlanes[band.quantizationIndex]
                                    let effectiveMB = mb + comp.roiShift
                                    for (k, block) in precinctBand.blocks.enumerated() {
                                        try work.check()
                                        let contribution = contributions[c][resolution.index][p][b][k]
                                        completed += 1
                                        guard contribution.included, contribution.passes > 0, effectiveMB > 0 else { continue }
                                        if contribution.isHT {
                                            let htPasses = ((contribution.passes - 1) % 3) + 1
                                            if htPasses == 1 && contribution.segments.count <= 1 && !style.causal && comp.roiShift == 0 {
                                                let placeholderSets = (contribution.passes - 1) / 3
                                                let effectiveMissingMSBs = contribution.zeroBitPlanes + placeholderSets
                                                let rawBlock = contribution.segments.first?.data ?? []
                                                let coeffs = try AcceleratedCodec.decodeHTCleanup(
                                                    block: rawBlock, width: block.width, height: block.height,
                                                    kMax: mb, missingMSBs: effectiveMissingMSBs,
                                                    backend: backend
                                                )
                                                for row in 0..<block.height {
                                                    let planeRow = (band.planeY + block.y0 - band.y0 + row) * stride + band.planeX + block.x0 - band.x0
                                                    for col in 0..<block.width {
                                                        plane[planeRow + col] = coeffs[row * block.width + col]
                                                    }
                                                }
                                            } else {
                                                var coeffs64 = try HTBlockDecoder.decodeHTCodeBlock(
                                                    segments: contribution.segments.map {
                                                        HTSegmentInput(data: $0.data, passes: $0.passes)
                                                    },
                                                    zeroBitPlanes: contribution.zeroBitPlanes,
                                                    totalPasses: contribution.passes,
                                                    width: block.width,
                                                    height: block.height,
                                                    kMax: effectiveMB,
                                                    causal: style.causal,
                                                    allowMultiHT: false,
                                                    midpointReconstruction: false
                                                )
                                                if comp.roiShift > 0 {
                                                    try AcceleratedCodec.descaleROICoefficients(
                                                        coefficients: &coeffs64,
                                                        shift: comp.roiShift,
                                                        backend: backend
                                                    )
                                                }
                                                for row in 0..<block.height {
                                                    let planeRow = (band.planeY + block.y0 - band.y0 + row) * stride + band.planeX + block.x0 - band.x0
                                                    for col in 0..<block.width {
                                                        plane[planeRow + col] = Int32(clamping: coeffs64[row * block.width + col])
                                                    }
                                                }
                                            }
                                        } else {
                                            var (coeffs64, _) = try BitPlaneCoder.decodeRich(
                                                segments: contribution.segments,
                                                width: block.width, height: block.height,
                                                orientation: band.orientation,
                                                zeroBitPlanes: contribution.zeroBitPlanes,
                                                passCount: contribution.passes,
                                                magnitudeBitPlanes: effectiveMB,
                                                style: style
                                            )
                                            if comp.roiShift > 0 {
                                                try AcceleratedCodec.descaleROICoefficients(
                                                    coefficients: &coeffs64,
                                                    shift: comp.roiShift,
                                                    backend: backend
                                                )
                                            }
                                            for row in 0..<block.height {
                                                let planeRow = (band.planeY + block.y0 - band.y0 + row) * stride + band.planeX + block.x0 - band.x0
                                                for col in 0..<block.width {
                                                    plane[planeRow + col] = Int32(clamping: coeffs64[row * block.width + col])
                                                }
                                            }
                                        }
                                        if completed & 7 == 0 {
                                            progress?(try ProgressUpdate(phase: .processing, completedUnits: completed, totalUnits: total))
                                            try work.check()
                                        }
                                    }
                                }
                            }
                        }
                        try AcceleratedCodec.inverseWavelet53(
                            plane: &plane, stride: stride,
                            x0: tile.x0, x1: tile.x1, y0: tile.y0, y1: tile.y1,
                            levels: comp.codingStyle.decompositionLevels,
                            backend: backend,
                            cancellation: work.check
                        )
                        intPlanes.append(plane)
                    }

                    let activePart2MCT: Bool
                    if let mctPlan = tile.part2MCTPlan {
                        intPlanes = try mctPlan.applyInverseReversible(
                            planes: intPlanes,
                            pixelCount: planeCount,
                            backend: backend
                        )
                        activePart2MCT = true
                    } else {
                        if tile.defaultCodingStyle.componentTransform == 1 && intPlanes.count >= 3 {
                            try AcceleratedCodec.inverseRCT(planes: &intPlanes, backend: backend)
                        }
                        activePart2MCT = false
                    }

                    for outC in 0..<outputComponentCount {
                        let loc = compLocations[outC]
                        let mappedCh = channelPermutation?[outC] ?? outC
                        let cmapEntry = paletteMapping?.cmap.entries[mappedCh]
                        let srcComp = Int(cmapEntry?.componentIndex ?? UInt16(mappedCh))
                        let planeData = intPlanes[srcComp]
                        let postShift = activePart2MCT ? 0 : wireShifts[srcComp]
                        let usePalette = (cmapEntry?.mappingType == 1)
                        let pcol = Int(cmapEntry?.paletteColumn ?? 0)
                        let clampedPlane: [Int32]?
                        if !usePalette && backend == .accelerated && AcceleratedCodec.shouldUseMetal(sampleCount: planeCount) {
                            let shifted64 = planeData.map { Int64($0) + Int64(postShift) }
                            clampedPlane = try AcceleratedCodec.clampSamples64To32IfMetal(
                                samples: shifted64,
                                minVal: Int64(minVal),
                                maxVal: Int64(maxVal),
                                backend: backend
                            )
                        } else {
                            clampedPlane = nil
                        }
                        for row in 0..<tile.height {
                            try work.check()
                            let y = tile.y0 - profile.originY + row
                            let rowBase = loc.plane.offset + y * loc.rowBytes + loc.sampleOffset
                            for col in 0..<tile.width {
                                let x = tile.x0 - profile.originX + col
                                let csValue: Int
                                if let cp = clampedPlane {
                                    csValue = Int(cp[row * stride + col])
                                } else {
                                    csValue = min(max(Int(planeData[row * stride + col]) + postShift, minVal), maxVal)
                                }
                                let value: Int
                                if usePalette, let (pclr, _) = paletteMapping {
                                    let idx = max(0, min(pclr.numEntries - 1, csValue))
                                    value = Int(pclr.values[idx][pcol])
                                } else {
                                    value = csValue
                                }
                                try storeSampleInt(
                                    value, into: output, at: rowBase + x * loc.plane.pixelStride,
                                    storageBits: descriptor.storageBits, signed: outputSigned, order: order
                                )
                            }
                        }
                    }
                } else {
                    var doublePlanes: [[Double]] = []
                    doublePlanes.reserveCapacity(profile.wireComponents.count)
                    for comp in tile.components {
                        let c = comp.componentIndex
                        StorageTelemetry.recordWorkspaceAllocation(bytes: planeCount * 8)
                        var plane = [Double](repeating: 0.0, count: planeCount)
                        let style = CodeBlockStyle(bits: comp.codingStyle.codeBlockStyle)
                        let isUnquantized = comp.quantization.style == .none

                        for resolution in comp.geometry.resolutions {
                            for (p, precinct) in resolution.precincts.enumerated() {
                                for (b, precinctBand) in precinct.bands.enumerated() {
                                    let band = resolution.bands[precinctBand.bandIndex]
                                    let mb = comp.magnitudeBitPlanes[band.quantizationIndex]
                                    let effectiveMB = mb + comp.roiShift
                                    let step = comp.stepSizes[band.quantizationIndex]
                                    for (k, block) in precinctBand.blocks.enumerated() {
                                        try work.check()
                                        let contribution = contributions[c][resolution.index][p][b][k]
                                        completed += 1
                                        guard contribution.included, contribution.passes > 0, effectiveMB > 0 else { continue }
                                        let coeffs64: [Int64]
                                        let lastPlanes: [Int8]
                                        if contribution.isHT {
                                            let htPasses = ((contribution.passes - 1) % 3) + 1
                                            if htPasses == 1 && contribution.segments.count <= 1 && !style.causal
                                                && effectiveMB <= BitPlaneCoder.maximumMagnitudeBitPlanes {
                                                let placeholderSets = (contribution.passes - 1) / 3
                                                let effectiveMissingMSBs = contribution.zeroBitPlanes + placeholderSets
                                                let rawBlock = contribution.segments.first?.data ?? []
                                                let coeffs32 = try AcceleratedCodec.decodeHTCleanup(
                                                    block: rawBlock, width: block.width, height: block.height,
                                                    kMax: effectiveMB, missingMSBs: effectiveMissingMSBs,
                                                    backend: backend
                                                )
                                                coeffs64 = coeffs32.map { Int64($0) }
                                                let basePlane = Int8(clamping: max(0, effectiveMB - 1 - effectiveMissingMSBs))
                                                lastPlanes = [Int8](repeating: basePlane, count: coeffs32.count)
                                            } else {
                                                (coeffs64, lastPlanes) = try HTBlockDecoder.decodeHTCodeBlockWithPlanes(
                                                    segments: contribution.segments.map {
                                                        HTSegmentInput(data: $0.data, passes: $0.passes)
                                                    },
                                                    zeroBitPlanes: contribution.zeroBitPlanes,
                                                    totalPasses: contribution.passes,
                                                    width: block.width,
                                                    height: block.height,
                                                    kMax: effectiveMB,
                                                    causal: style.causal,
                                                    allowMultiHT: false,
                                                    midpointReconstruction: false
                                                )
                                            }
                                        } else {
                                            (coeffs64, lastPlanes) = try BitPlaneCoder.decodeRich(
                                                segments: contribution.segments,
                                                width: block.width, height: block.height,
                                                orientation: band.orientation,
                                                zeroBitPlanes: contribution.zeroBitPlanes,
                                                passCount: contribution.passes,
                                                magnitudeBitPlanes: effectiveMB,
                                                style: style
                                            )
                                        }
                                        for row in 0..<block.height {
                                            let planeRow = (band.planeY + block.y0 - band.y0 + row) * stride + band.planeX + block.x0 - band.x0
                                            for col in 0..<block.width {
                                                let idx = row * block.width + col
                                                let rawVal = coeffs64[idx]
                                                guard rawVal != 0 else { continue }
                                                let sign: Double = rawVal < 0 ? -1.0 : 1.0
                                                var mag = rawVal < 0 ? -rawVal : rawVal
                                                var lastP = max(0, Int(lastPlanes[idx]))
                                                if comp.roiShift > 0 {
                                                    let threshold = Int64(1) << comp.roiShift
                                                    if mag >= threshold {
                                                        mag >>= comp.roiShift
                                                        lastP = max(0, lastP - comp.roiShift)
                                                    }
                                                }
                                                guard mag > 0 else { continue }
                                                if isUnquantized && lastP == 0 {
                                                    plane[planeRow + col] = sign * Double(mag)
                                                } else {
                                                    let midpoint = 0.5 * Double(Int64(1) << min(lastP, 30))
                                                    plane[planeRow + col] = sign * (Double(mag) + midpoint) * step
                                                }
                                            }
                                        }
                                        if completed & 7 == 0 {
                                            progress?(try ProgressUpdate(phase: .processing, completedUnits: completed, totalUnits: total))
                                            try work.check()
                                        }
                                    }
                                }
                            }
                        }

                        if comp.codingStyle.reversible {
                            var intPlane = plane.map { Int32($0.rounded()) }
                            try AcceleratedCodec.inverseWavelet53(
                                plane: &intPlane, stride: stride,
                                x0: tile.x0, x1: tile.x1, y0: tile.y0, y1: tile.y1,
                                levels: comp.codingStyle.decompositionLevels,
                                backend: backend,
                                cancellation: work.check
                            )
                            plane = intPlane.map { Double($0) }
                        } else {
                            try AcceleratedCodec.inverseWavelet97(
                                plane: &plane, stride: stride,
                                x0: tile.x0, x1: tile.x1, y0: tile.y0, y1: tile.y1,
                                levels: comp.codingStyle.decompositionLevels,
                                backend: backend,
                                cancellation: work.check
                            )
                        }
                        doublePlanes.append(plane)
                    }

                    let activePart2MCT: Bool
                    if let mctPlan = tile.part2MCTPlan {
                        doublePlanes = try mctPlan.applyInverseFloat(
                            planes: doublePlanes,
                            pixelCount: planeCount,
                            backend: backend
                        )
                        activePart2MCT = true
                    } else {
                        if tile.defaultCodingStyle.componentTransform == 1 && doublePlanes.count >= 3 {
                            if tile.defaultCodingStyle.reversible {
                                var rctPlanes = [
                                    doublePlanes[0].map { Int32($0.rounded()) },
                                    doublePlanes[1].map { Int32($0.rounded()) },
                                    doublePlanes[2].map { Int32($0.rounded()) }
                                ]
                                try AcceleratedCodec.inverseRCT(planes: &rctPlanes, backend: backend)
                                doublePlanes[0] = rctPlanes[0].map { Double($0) }
                                doublePlanes[1] = rctPlanes[1].map { Double($0) }
                                doublePlanes[2] = rctPlanes[2].map { Double($0) }
                            } else {
                                AcceleratedCodec.inverseICT(planes: &doublePlanes, backend: backend)
                            }
                        }
                        activePart2MCT = false
                    }

                    for outC in 0..<outputComponentCount {
                        let loc = compLocations[outC]
                        let mappedCh = channelPermutation?[outC] ?? outC
                        let cmapEntry = paletteMapping?.cmap.entries[mappedCh]
                        let srcComp = Int(cmapEntry?.componentIndex ?? UInt16(mappedCh))
                        let planeData = doublePlanes[srcComp]
                        let postShift = activePart2MCT ? 0 : wireShifts[srcComp]
                        let usePalette = (cmapEntry?.mappingType == 1)
                        let pcol = Int(cmapEntry?.paletteColumn ?? 0)
                        let clampedPlane: [Int32]?
                        if !usePalette && backend == .accelerated && AcceleratedCodec.shouldUseMetal(sampleCount: planeCount) {
                            let rounded64 = planeData.map { Int64($0.rounded()) + Int64(postShift) }
                            clampedPlane = try AcceleratedCodec.clampSamples64To32IfMetal(
                                samples: rounded64,
                                minVal: Int64(minVal),
                                maxVal: Int64(maxVal),
                                backend: backend
                            )
                        } else {
                            clampedPlane = nil
                        }
                        for row in 0..<tile.height {
                            try work.check()
                            let y = tile.y0 - profile.originY + row
                            let rowBase = loc.plane.offset + y * loc.rowBytes + loc.sampleOffset
                            for col in 0..<tile.width {
                                let x = tile.x0 - profile.originX + col
                                let csValue: Int
                                if let cp = clampedPlane {
                                    csValue = Int(cp[row * stride + col])
                                } else {
                                    let rounded = Int(planeData[row * stride + col].rounded())
                                    csValue = min(max(rounded + postShift, minVal), maxVal)
                                }
                                let value: Int
                                if usePalette, let (pclr, _) = paletteMapping {
                                    let idx = max(0, min(pclr.numEntries - 1, csValue))
                                    value = Int(pclr.values[idx][pcol])
                                } else {
                                    value = csValue
                                }
                                try storeSampleInt(
                                    value, into: output, at: rowBase + x * loc.plane.pixelStride,
                                    storageBits: descriptor.storageBits, signed: outputSigned, order: order
                                )
                            }
                        }
                    }
                }
            }
        }
        return (image, workspace)
    }

    // MARK: - Encoding

    static func encode(
        image: Image,
        configuration: EncoderConfiguration,
        limits: ResourceLimits,
        backend: Backend = .scalarCPU,
        progress: (@Sendable (ProgressUpdate) -> Void)?
    ) throws -> ([UInt8], Int) {
        let descriptor = image.descriptor
        guard descriptor.sampleType == .unsignedInteger || descriptor.sampleType == .signedInteger else {
            throw CodecError(.unsupportedFeature, "Only integer sample types are supported.")
        }
        guard descriptor.storageBits == 8 || descriptor.storageBits == 16 else {
            throw CodecError(.unsupportedFeature, "Only 8-bit and 16-bit integer storage are supported.")
        }
        if configuration.codecOptions.containerFormat == .codestream {
            guard descriptor.iccProfile == nil, image.metadata.entries.isEmpty else {
                throw CodecError(.unsupportedFeature, "Raw codestream output cannot carry ICC or metadata; none is silently dropped.")
            }
        }

        let width = descriptor.width
        let height = descriptor.height
        let precision = descriptor.meaningfulBits
        let signed = descriptor.sampleType == .signedInteger
        let componentCount = descriptor.components.count
        let opts = configuration.codecOptions
        let isHT = opts.blockCoding == .htj2k
        let usePart2MCT = (opts.multiComponentTransform == .part2)

        // Resolve wavelet:
        let useReversibleWavelet: Bool
        switch opts.wavelet {
        case .reversible53:
            useReversibleWavelet = true
        case .irreversible97:
            useReversibleWavelet = false
        case .automatic:
            switch configuration.mode {
            case .lossless, .nearLossless:
                useReversibleWavelet = true
            case .lossy:
                useReversibleWavelet = false
            }
        }

        // Resolve colour transform:
        let componentTransform: UInt8
        if usePart2MCT {
            componentTransform = 0
        } else {
            switch opts.colourTransform {
            case .none:
                componentTransform = 0
            case .rct:
                guard componentCount >= 3 else {
                    throw CodecError(.invalidArgument, "RCT requires at least 3 components.")
                }
                guard useReversibleWavelet else {
                    throw CodecError(.invalidArgument, "RCT requires the reversible 5/3 wavelet.")
                }
                componentTransform = 1
            case .ict:
                guard componentCount >= 3 else {
                    throw CodecError(.invalidArgument, "ICT requires at least 3 components.")
                }
                guard !useReversibleWavelet else {
                    throw CodecError(.invalidArgument, "ICT requires the irreversible 9/7 wavelet.")
                }
                componentTransform = 1
            case .automatic:
                if componentCount >= 3 && descriptor.components[0] == .red && descriptor.components[1] == .green && descriptor.components[2] == .blue {
                    if case .nearLossless = configuration.mode, useReversibleWavelet {
                        componentTransform = 0
                    } else {
                        componentTransform = 1
                    }
                } else {
                    componentTransform = 0
                }
            }
        }

        let useReversibleUnquantized = useReversibleWavelet && (opts.quantizationStyle == .automatic || opts.quantizationStyle == .none)
        let part2Package: Part2MCTPlan.EncodedMCTPackage?
        let part2IrrevForwardMatrix: [Double]?
        let part2ReversibleCheckPlan: Part2MCTPlan?
        if usePart2MCT {
            if useReversibleUnquantized {
                let pkg = try Part2MCTPlan.makeReversibleEncoderPackage(
                    componentCount: componentCount,
                    precision: precision,
                    signed: signed
                )
                part2Package = pkg
                part2IrrevForwardMatrix = nil
                var tableMap: [Part2MCTTable.Key: Part2MCTTable] = [:]
                for t in pkg.mctTables {
                    tableMap[Part2MCTTable.Key(arrayType: t.arrayType, tableIndex: t.tableIndex)] = t
                }
                part2ReversibleCheckPlan = try Part2MCTPlan.resolve(
                    codestreamComponentCount: componentCount,
                    cbd: pkg.cbd,
                    mctTables: tableMap,
                    mccStages: [pkg.mccStage.stageIndex: pkg.mccStage],
                    mco: pkg.mco
                )
            } else {
                let (pkg, fwd) = try Part2MCTPlan.makeIrreversibleEncoderPackage(
                    componentCount: componentCount,
                    precision: precision,
                    signed: signed
                )
                part2Package = pkg
                part2IrrevForwardMatrix = fwd
                part2ReversibleCheckPlan = nil
            }
        } else {
            part2Package = nil
            part2IrrevForwardMatrix = nil
            part2ReversibleCheckPlan = nil
        }

        if let roi = opts.regionOfInterest {
            guard roi.x < width && roi.y < height else {
                throw CodecError(.invalidArgument, "Region of interest lies outside the image dimensions.")
            }
        }

        let tileWidth = opts.tileWidth ?? width
        let tileHeight = opts.tileHeight ?? height
        guard tileWidth >= 1, tileHeight >= 1 else {
            throw CodecError(.invalidArgument, "Tile dimensions must be positive.")
        }
        let tilesWide = Wavelet53.ceilDiv(width, tileWidth)
        let tilesHigh = Wavelet53.ceilDiv(height, tileHeight)
        guard tilesWide * tilesHigh <= 65535 else {
            throw CodecError(.invalidArgument, "Tile grid exceeds 65535 tiles.")
        }

        let minTileW = min(tileWidth, width - (tilesWide - 1) * tileWidth)
        let minTileH = min(tileHeight, height - (tilesHigh - 1) * tileHeight)
        let smallestImageDim = min(width, height)
        let deepestImage = Int.bitWidth - 1 - smallestImageDim.leadingZeroBitCount
        let smallestTileDim = max(1, min(minTileW, minTileH))
        let deepestTile = Int.bitWidth - 1 - smallestTileDim.leadingZeroBitCount

        let levels: Int
        if let requested = opts.decompositionLevels {
            guard requested <= deepestImage else {
                throw CodecError(.invalidArgument, "Decomposition levels exceed floor(log2(min(width, height))) = \(deepestImage) for this image.")
            }
            levels = requested
        } else {
            levels = min(5, deepestTile)
        }

        let usesPrecincts = !opts.precinctSizes.isEmpty
        var precinctExponents: [(width: Int, height: Int)] = []
        if usesPrecincts {
            for r in 0...levels {
                let pSize = opts.precinctSizes[min(r, opts.precinctSizes.count - 1)]
                precinctExponents.append((
                    width: pSize.width.trailingZeroBitCount,
                    height: pSize.height.trailingZeroBitCount
                ))
            }
        }

        let numLayers = !opts.layerBitrates.isEmpty ? opts.layerBitrates.count : opts.qualityLayers
        for poc in opts.progressionChanges {
            guard poc.endComponent <= componentCount else {
                throw CodecError(.invalidArgument, "POC endComponent (\(poc.endComponent)) exceeds image component count (\(componentCount)).")
            }
            guard poc.endResolution <= levels + 1 else {
                throw CodecError(.invalidArgument, "POC endResolution (\(poc.endResolution)) exceeds resolution count (\(levels + 1)).")
            }
            guard poc.endLayer <= numLayers else {
                throw CodecError(.invalidArgument, "POC endLayer (\(poc.endLayer)) exceeds layer count (\(numLayers)).")
            }
        }

        let largestTilePixels = min(tileWidth, width) * min(tileHeight, height)
        let workspace = try workspaceBytes(
            planePixels: largestTilePixels,
            componentCount: componentCount,
            bytesPerCoeff: useReversibleWavelet ? 4 : 8,
            joinedBytes: 0
        )
        guard workspace <= limits.maximumWorkspaceBytes else {
            throw CodecError(.resourceLimitExceeded, "Encoder workspace exceeds the operation limit.")
        }
        guard try checkedAdd(image.storage.byteCount, workspace) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Image and workspace exceed the memory budget.")
        }

        let work = WorkGuard(limits: limits)
        try work.check()

        let styleBits: UInt8 = isHT ? 0x40 : opts.codeBlockStyleBits
        let cod = CodingStyleSegment(
            usesPrecincts: usesPrecincts,
            usesSOP: opts.usesSOP,
            usesEPH: opts.usesEPH,
            progression: opts.progressionOrder.rawValue,
            layers: numLayers,
            componentTransform: componentTransform,
            decompositionLevels: levels,
            codeBlockWidthExponent: opts.codeBlockWidth.trailingZeroBitCount,
            codeBlockHeightExponent: opts.codeBlockHeight.trailingZeroBitCount,
            codeBlockStyle: styleBits,
            reversible: useReversibleWavelet,
            precinctExponents: precinctExponents
        )
        let style = CodeBlockStyle(bits: styleBits)
        let pocEntries: [ProgressionOrderChangeEntry] = opts.progressionChanges.map {
            ProgressionOrderChangeEntry(
                resolutionStart: $0.startResolution,
                componentStart: $0.startComponent,
                layerEnd: $0.endLayer,
                resolutionEnd: $0.endResolution,
                componentEnd: $0.endComponent,
                progression: $0.progressionOrder.rawValue
            )
        }

        // Pre-locate plane and sample offset for each component index.
        let mutation = SharedPathMutation.active
        let order = mutation == .wrongByteOrder ? descriptor.byteOrder.opposite : descriptor.byteOrder
        var compLocations: [(plane: PlaneDescriptor, sampleOffset: Int, rowBytes: Int)] = []
        compLocations.reserveCapacity(componentCount)
        for c in 0..<componentCount {
            guard let plane = descriptor.planes.first(where: { $0.components.contains(c) }),
                  let idxInPlane = plane.components.firstIndex(of: c) else {
                throw CodecError(.incompatibleImageLayout, "Component \(c) is not mapped in image planes.")
            }
            let rb = mutation == .ignoreRowStride ? width * plane.pixelStride : plane.rowBytes
            compLocations.append((plane, idxInPlane * plane.sampleStride, rb))
        }

        let shift = signed ? 0 : (1 << (precision - 1))
        let minVal = signed ? -(1 << (precision - 1)) : 0
        let maxVal = signed ? ((1 << (precision - 1)) - 1) : ((1 << precision) - 1)

        // Build per-component QCD/QCC segments:
        let maxEffectivePrecision: Int
        if let pkg = part2Package {
            maxEffectivePrecision = pkg.wireComponentFormats.map(\.precision).max() ?? precision
        } else {
            maxEffectivePrecision = precision + ((componentTransform == 1 && useReversibleWavelet && componentCount >= 3) ? 1 : 0)
        }
        var mainQCD: QuantizationSegment
        if useReversibleUnquantized {
            var exponents: [Int] = [maxEffectivePrecision]
            if levels >= 1 {
                for _ in 1...levels {
                    exponents.append(maxEffectivePrecision + 1)
                    exponents.append(maxEffectivePrecision + 1)
                    exponents.append(maxEffectivePrecision + 2)
                }
            }
            // Add +1 exponent headroom when guardBits == 1 so 5/3 high-pass bands never overflow mb
            if opts.guardBits == 1 {
                exponents = exponents.map { min(31, $0 + 1) }
            }
            mainQCD = QuantizationSegment(style: .none, guardBits: opts.guardBits, exponents: exponents, mantissas: [])
        } else {
            let derived = opts.quantizationStyle == .scalarDerived
            let effectiveBaseStep: Double?
            if let explicit = opts.baseStepSize {
                effectiveBaseStep = explicit
            } else if case .nearLossless(let bound) = configuration.mode {
                effectiveBaseStep = max(0.0625, Double(bound) * 0.2)
            } else if opts.quality == nil && (opts.targetBitsPerPixel != nil || !opts.layerBitrates.isEmpty) {
                // Fine step size so PCRD-opt controls the exact target bitrate
                effectiveBaseStep = 0.5
            } else {
                effectiveBaseStep = nil
            }
            mainQCD = Quantization.makeIrreversibleQuantization(
                levels: levels,
                precision: maxEffectivePrecision,
                guardBits: opts.guardBits,
                derived: derived,
                quality: opts.quality,
                baseStepSize: effectiveBaseStep
            )
        }
        let expandedQCD = try mainQCD.expanded(decompositionLevels: levels)
        let roiShift: Int
        if let roi = opts.regionOfInterest {
            let minRequiredShift = ROICoding.computeMaxShift(quantization: expandedQCD, requestedShift: nil)
            if let requested = roi.shift {
                guard requested >= minRequiredShift else {
                    throw CodecError(.invalidArgument, "Explicit ROI MaxShift (\(requested)) is smaller than the maximum subband bit-plane count (\(minRequiredShift)).")
                }
                roiShift = requested
            } else {
                roiShift = minRequiredShift
            }
        } else {
            roiShift = 0
        }

        let totalTiles = tilesWide * tilesHigh
        var encodedTilePayloads: [[UInt8]] = []
        encodedTilePayloads.reserveCapacity(totalTiles)
        var completedBlocks = 0
        let estimatedTotalBlocks = max(1, totalTiles * componentCount)
        progress?(try ProgressUpdate(phase: .processing, completedUnits: 0, totalUnits: estimatedTotalBlocks))
        try work.check()

        try image.storage.withUnsafeBytes { rawBytes in
            guard rawBytes.count >= descriptor.requiredByteCount else {
                throw CodecError(.storageUnavailable, "Provider returned insufficient capacity.")
            }

            for tileIndex in 0..<totalTiles {
                try work.check()
                let p = tileIndex % tilesWide, q = tileIndex / tilesWide
                let tx0 = p * tileWidth
                let ty0 = q * tileHeight
                let tx1 = min((p + 1) * tileWidth, width)
                let ty1 = min((q + 1) * tileHeight, height)
                let tw = tx1 - tx0
                let th = ty1 - ty0
                let tilePixels = tw * th
                let geometry = try Tier2.makeTileGeometry(x0: tx0, x1: tx1, y0: ty0, y1: ty1, codingStyle: cod)
                let geometries = [TileGeometry](repeating: geometry, count: componentCount)
                let codingStyles = [CodingStyleSegment](repeating: cod, count: componentCount)

                // Extract original level-shifted samples per component for this tile:
                var originalIntTile: [[Int32]] = []
                originalIntTile.reserveCapacity(componentCount)
                for c in 0..<componentCount {
                    let loc = compLocations[c]
                    StorageTelemetry.recordWorkspaceAllocation(bytes: tilePixels * 4)
                    var compPlane = [Int32](repeating: 0, count: tilePixels)
                    for row in 0..<th {
                        try work.check()
                        let y = ty0 + row
                        let rowBase = loc.plane.offset + y * loc.rowBytes + loc.sampleOffset
                        for col in 0..<tw {
                            let x = tx0 + col
                            let sample = try loadSampleInt(
                                rawBytes, at: rowBase + x * loc.plane.pixelStride,
                                storageBits: descriptor.storageBits, signed: signed, order: order
                            )
                            guard sample >= minVal && sample <= maxVal else {
                                throw CodecError(.invalidArgument, "A sample exceeds the declared meaningful precision.")
                            }
                            compPlane[row * tw + col] = Int32(sample)
                        }
                    }
                    try AcceleratedCodec.levelShiftSamples32IfMetal(
                        samples: &compPlane,
                        dcShift: Int32(shift),
                        backend: backend
                    )
                    originalIntTile.append(compPlane)
                }

                // Forward colour + wavelet + quantisation produces Int64 wavelet coefficient planes:
                var quantisedPlanes = [[Int64]](repeating: [Int64](repeating: 0, count: tilePixels), count: componentCount)

                if useReversibleWavelet && expandedQCD.style == .none {
                    var workingPlanes: [[Int32]]
                    if usePart2MCT {
                        workingPlanes = Part2MCTPlan.applyForwardReversibleEncoder(
                            centeredPlanes: originalIntTile,
                            backend: backend
                        )
                    } else {
                        workingPlanes = originalIntTile
                        if componentTransform == 1 && componentCount >= 3 {
                            try AcceleratedCodec.forwardRCT(planes: &workingPlanes, backend: backend)
                        }
                    }
                    for c in 0..<componentCount {
                        try AcceleratedCodec.forwardWavelet53(
                            plane: &workingPlanes[c], stride: tw,
                            x0: tx0, x1: tx1, y0: ty0, y1: ty1,
                            levels: levels, backend: backend, cancellation: work.check
                        )
                    }

                    // If near-lossless on 5/3 path, apply dead-zone subband rounding with closed-loop verification
                    if case .nearLossless(let maxErr) = configuration.mode {
                        var tau = Double(maxErr) * 1.8
                        for attempt in 0..<6 {
                            if attempt == 5 || tau < 1.0 {
                                for c in 0..<componentCount {
                                    for i in 0..<tilePixels { quantisedPlanes[c][i] = Int64(workingPlanes[c][i]) }
                                }
                                break
                            }
                            var trialPlanes = workingPlanes
                            for c in 0..<componentCount {
                                for resolution in geometry.resolutions {
                                    let nb = resolution.index == 0 ? levels : (levels - resolution.index + 1)
                                    for band in resolution.bands {
                                        let w = nb == 0 ? 1.0 : Quantization.synthesisWeight(
                                            orientation: band.orientation, decompositionLevel: nb, reversible: true
                                        )
                                        let qStep = Int32(max(1.0, floor(tau / w)))
                                        guard qStep > 1 else { continue }
                                        for row in 0..<band.height {
                                            let rBase = (band.planeY + row) * tw + band.planeX
                                            for col in 0..<band.width {
                                                let v = trialPlanes[c][rBase + col]
                                                trialPlanes[c][rBase + col] = (v / qStep) * qStep
                                            }
                                        }
                                    }
                                }
                            }
                            // Verify reconstruction error bound on this tile:
                            var reconPlanes = trialPlanes
                            for c in 0..<componentCount {
                                try AcceleratedCodec.inverseWavelet53(
                                    plane: &reconPlanes[c], stride: tw,
                                    x0: tx0, x1: tx1, y0: ty0, y1: ty1,
                                    levels: levels, backend: backend, cancellation: work.check
                                )
                            }
                            let recShift: Int
                            if let checkPlan = part2ReversibleCheckPlan {
                                reconPlanes = try checkPlan.applyInverseReversible(
                                    planes: reconPlanes,
                                    pixelCount: tilePixels,
                                    backend: backend
                                )
                                recShift = 0
                            } else {
                                if componentTransform == 1 && componentCount >= 3 {
                                    try AcceleratedCodec.inverseRCT(planes: &reconPlanes, backend: backend)
                                }
                                recShift = shift
                            }
                            var worstError = 0
                            outerCheck: for c in 0..<componentCount {
                                for i in 0..<tilePixels {
                                    let orig = min(max(Int(originalIntTile[c][i]) + shift, minVal), maxVal)
                                    let rec = min(max(Int(reconPlanes[c][i]) + recShift, minVal), maxVal)
                                    let err = abs(orig - rec)
                                    if err > worstError {
                                        worstError = err
                                        if worstError > maxErr { break outerCheck }
                                    }
                                }
                            }
                            if worstError <= maxErr {
                                for c in 0..<componentCount {
                                    for i in 0..<tilePixels { quantisedPlanes[c][i] = Int64(trialPlanes[c][i]) }
                                }
                                break
                            }
                            tau *= 0.5
                        }
                    } else {
                        for c in 0..<componentCount {
                            for i in 0..<tilePixels {
                                quantisedPlanes[c][i] = Int64(workingPlanes[c][i])
                            }
                        }
                    }
                } else {
                    // Floating-point / quantised path (9/7 or quantised 5/3):
                    var doublePlanes: [[Double]] = originalIntTile.map { $0.map { Double($0) } }
                    if let irrevFwd = part2IrrevForwardMatrix {
                        doublePlanes = Part2MCTPlan.applyForwardIrreversibleEncoder(
                            centeredPlanes: doublePlanes,
                            forwardMatrix: irrevFwd,
                            backend: backend
                        )
                    } else if componentTransform == 1 && componentCount >= 3 {
                        if useReversibleWavelet {
                            var rctPlanes = [originalIntTile[0], originalIntTile[1], originalIntTile[2]]
                            try AcceleratedCodec.forwardRCT(planes: &rctPlanes, backend: backend)
                            doublePlanes[0] = rctPlanes[0].map { Double($0) }
                            doublePlanes[1] = rctPlanes[1].map { Double($0) }
                            doublePlanes[2] = rctPlanes[2].map { Double($0) }
                        } else {
                            AcceleratedCodec.forwardICT(planes: &doublePlanes, backend: backend)
                        }
                    }
                    for c in 0..<componentCount {
                        if useReversibleWavelet {
                            var intP = doublePlanes[c].map { Int32($0.rounded()) }
                            try AcceleratedCodec.forwardWavelet53(
                                plane: &intP, stride: tw,
                                x0: tx0, x1: tx1, y0: ty0, y1: ty1,
                                levels: levels, backend: backend, cancellation: work.check
                            )
                            doublePlanes[c] = intP.map { Double($0) }
                        } else {
                            try AcceleratedCodec.forwardWavelet97(
                                plane: &doublePlanes[c], stride: tw,
                                x0: tx0, x1: tx1, y0: ty0, y1: ty1,
                                levels: levels, backend: backend, cancellation: work.check
                            )
                        }
                    }

                    // Quantise each subband by its step size from `expandedQCD`:
                    for c in 0..<componentCount {
                        let compRangePrecision: Int
                        if let pkg = part2Package {
                            compRangePrecision = pkg.wireComponentFormats[c].precision
                        } else {
                            let rctAdjust = (componentTransform == 1 && useReversibleWavelet && (c == 1 || c == 2)) ? 1 : 0
                            compRangePrecision = precision + rctAdjust
                        }
                        for resolution in geometry.resolutions {
                            for band in resolution.bands {
                                let qIdx = band.quantizationIndex
                                let eps = expandedQCD.exponents[qIdx]
                                let mu = qIdx < expandedQCD.mantissas.count ? expandedQCD.mantissas[qIdx] : 0
                                let step = expandedQCD.style == .none
                                    ? 1.0
                                    : Quantization.stepSize(exponent: eps, mantissa: mu, precision: compRangePrecision, gain: band.gain)
                                let mb = max(1, expandedQCD.guardBits + eps - 1)
                                AcceleratedCodec.quantizeSubband(
                                    doublePlane: doublePlanes[c],
                                    quantisedPlane: &quantisedPlanes[c],
                                    stride: tw,
                                    band: band,
                                    step: step,
                                    mb: mb,
                                    backend: backend
                                )
                            }
                        }
                    }
                }

                // Apply MaxShift ROI scaling to foreground coefficients if ROI is active:
                if let roi = opts.regionOfInterest, roiShift > 0 {
                    let rx0 = max(tx0, roi.x)
                    let ry0 = max(ty0, roi.y)
                    let rx1 = min(tx1, roi.x + roi.width)
                    let ry1 = min(ty1, roi.y + roi.height)
                    if rx1 > rx0 && ry1 > ry0 {
                        for c in 0..<componentCount {
                            for resolution in geometry.resolutions {
                                let nb = resolution.index == 0 ? levels : (levels - resolution.index + 1)
                                for band in resolution.bands {
                                    let bounds = ROICoding.subbandROIBounds(
                                        roiX0: rx0, roiX1: rx1, roiY0: ry0, roiY1: ry1,
                                        band: band, decompositionLevel: nb, reversible: useReversibleWavelet
                                    )
                                    guard bounds.x1 > bounds.x0 && bounds.y1 > bounds.y0 else { continue }
                                    let mb = max(1, expandedQCD.guardBits + expandedQCD.exponents[band.quantizationIndex] - 1)
                                    AcceleratedCodec.scaleROISubband(
                                        quantisedPlane: &quantisedPlanes[c],
                                        stride: tw,
                                        band: band,
                                        bounds: bounds,
                                        roiShift: roiShift,
                                        mb: mb,
                                        backend: backend
                                    )
                                }
                            }
                        }
                    }
                }

                // Determine whether PCRD-opt pass selection / multi-layer splitting is active:
                let needsPCRD = numLayers > 1
                    || opts.targetBitsPerPixel != nil
                    || !opts.layerBitrates.isEmpty
                    || (configuration.mode == .lossy && useReversibleWavelet && opts.quality != nil)

                struct HTCandidateSet {
                    let topBit: Int
                    let codedPerK: [[UInt8]]
                    let distReductionPerK: [Double]
                }

                // Encode all code-blocks of all components in this tile:
                var encodings: [[[[[CodeBlockEncoding]]]]] = []
                encodings.reserveCapacity(componentCount)
                var flatCoords: [(c: Int, r: Int, p: Int, b: Int, k: Int, coeffs: [Int64], width: Int, height: Int, orientation: BandOrientation, mb: Int, htCandidates: HTCandidateSet?)] = []

                for c in 0..<componentCount {
                    let compRangePrecision: Int
                    let mctColWeight: Double
                    if let pkg = part2Package {
                        compRangePrecision = pkg.wireComponentFormats[c].precision
                        mctColWeight = pkg.irreversibleColumnNorms[c]
                    } else {
                        let rctAdjust = (componentTransform == 1 && useReversibleWavelet && (c == 1 || c == 2)) ? 1 : 0
                        compRangePrecision = precision + rctAdjust
                        mctColWeight = 1.0
                    }
                    var compEncodings: [[[[CodeBlockEncoding]]]] = []
                    compEncodings.reserveCapacity(geometry.resolutions.count)

                    for (rIdx, resolution) in geometry.resolutions.enumerated() {
                        let nb = resolution.index == 0 ? levels : (levels - resolution.index + 1)
                        var resEncodings: [[[CodeBlockEncoding]]] = []
                        resEncodings.reserveCapacity(resolution.precincts.count)
                        for (pIdx, precinct) in resolution.precincts.enumerated() {
                            var precEncodings: [[CodeBlockEncoding]] = []
                            precEncodings.reserveCapacity(precinct.bands.count)
                            for (bIdx, precinctBand) in precinct.bands.enumerated() {
                                let band = resolution.bands[precinctBand.bandIndex]
                                let qIdx = band.quantizationIndex
                                let eps = expandedQCD.exponents[qIdx]
                                let mu = qIdx < expandedQCD.mantissas.count ? expandedQCD.mantissas[qIdx] : 0
                                let mb = max(1, expandedQCD.guardBits + eps - 1) + roiShift
                                let step = expandedQCD.style == .none
                                    ? 1.0
                                    : Quantization.stepSize(exponent: eps, mantissa: mu, precision: compRangePrecision, gain: band.gain)
                                let baseWeight = nb == 0 ? 1.0 : Quantization.synthesisWeight(
                                    orientation: band.orientation, decompositionLevel: nb, reversible: useReversibleWavelet
                                )
                                let weight = baseWeight * mctColWeight
                                var bandEncodings: [CodeBlockEncoding] = []
                                bandEncodings.reserveCapacity(precinctBand.blocks.count)

                                for (kIdx, block) in precinctBand.blocks.enumerated() {
                                    try work.check()
                                    var blockCoeffs: [Int64] = []
                                    blockCoeffs.reserveCapacity(block.width * block.height)
                                    for row in 0..<block.height {
                                        let planeRow = (band.planeY + block.y0 - band.y0 + row) * tw + band.planeX + block.x0 - band.x0
                                        blockCoeffs.append(contentsOf: quantisedPlanes[c][planeRow..<(planeRow + block.width)])
                                    }

                                    var enc: CodeBlockEncoding
                                    var htCandidateSet: HTCandidateSet? = nil
                                    if isHT {
                                        let coeffs32 = blockCoeffs.map { Int32(clamping: $0) }
                                        let maxMag: Int32 = coeffs32.reduce(0) { acc, v in
                                            let m = (v == Int32.min) ? Int32.max : abs(v)
                                            return max(acc, m)
                                        }
                                        if maxMag == 0 {
                                            enc = CodeBlockEncoding(
                                                data: [],
                                                passCount: 0,
                                                zeroBitPlanes: mb
                                            )
                                            if needsPCRD {
                                                htCandidateSet = HTCandidateSet(topBit: 0, codedPerK: [], distReductionPerK: [])
                                            }
                                        } else if needsPCRD {
                                            let topBit = min(mb, 32 - Int(UInt32(maxMag).leadingZeroBitCount))
                                            let wStep = weight * step
                                            var fullErrSq = 0.0
                                            for v in coeffs32 where v != 0 {
                                                let d = Double(abs(Int64(v))) * wStep
                                                fullErrSq += d * d
                                            }
                                            var codedPerK: [[UInt8]] = []
                                            var bytesPerK: [Int] = []
                                            var distPerK: [Double] = []
                                            codedPerK.reserveCapacity(topBit)
                                            bytesPerK.reserveCapacity(topBit)
                                            distPerK.reserveCapacity(topBit)
                                            for kPlanes in 1...topBit {
                                                let s = topBit - kPlanes
                                                let cand = try AcceleratedCodec.encodeHTCleanup(
                                                    coefficients: coeffs32,
                                                    width: block.width,
                                                    height: block.height,
                                                    bandShift: s,
                                                    backend: backend
                                                )
                                                let addMidpoint = (s > 0) || (expandedQCD.style != .none)
                                                let midOffset = addMidpoint ? (0.5 * Double(Int64(1) << min(s, 30))) : 0.0
                                                var errSq = 0.0
                                                for v in coeffs32 where v != 0 {
                                                    let a = Int64(v < 0 ? -Int64(v) : Int64(v))
                                                    let muShift = a >> s
                                                    let recon: Double
                                                    if muShift == 0 {
                                                        recon = 0.0
                                                    } else {
                                                        recon = Double(muShift << s) + midOffset
                                                    }
                                                    let diff = (Double(a) - recon) * wStep
                                                    errSq += diff * diff
                                                }
                                                codedPerK.append(cand)
                                                bytesPerK.append(cand.count)
                                                distPerK.append(max(0.0, fullErrSq - errSq))
                                            }
                                            let finest = codedPerK.last ?? []
                                            enc = CodeBlockEncoding(
                                                data: finest,
                                                passCount: finest.isEmpty ? 0 : 1,
                                                zeroBitPlanes: finest.isEmpty ? mb : max(0, mb - 1),
                                                passTerminatedBytes: bytesPerK,
                                                passDistortionReductions: distPerK
                                            )
                                            htCandidateSet = HTCandidateSet(
                                                topBit: topBit,
                                                codedPerK: codedPerK,
                                                distReductionPerK: distPerK
                                            )
                                        } else {
                                            let coded = try AcceleratedCodec.encodeHTCleanup(
                                                coefficients: coeffs32,
                                                width: block.width,
                                                height: block.height,
                                                bandShift: 0,
                                                backend: backend
                                            )
                                            enc = CodeBlockEncoding(
                                                data: coded,
                                                passCount: coded.isEmpty ? 0 : 1,
                                                zeroBitPlanes: coded.isEmpty ? mb : max(0, mb - 1)
                                            )
                                        }
                                    } else {
                                        enc = try BitPlaneCoder.encodeRich(
                                            coefficients: blockCoeffs,
                                            width: block.width,
                                            height: block.height,
                                            orientation: band.orientation,
                                            magnitudeBitPlanes: mb,
                                            style: style,
                                            computeDistortion: needsPCRD,
                                            synthesisWeight: weight,
                                            stepSize: step
                                        )
                                    }
                                    if needsPCRD {
                                        flatCoords.append((c, rIdx, pIdx, bIdx, kIdx, blockCoeffs, block.width, block.height, band.orientation, mb, htCandidateSet))
                                    }
                                    bandEncodings.append(enc)
                                }
                                precEncodings.append(bandEncodings)
                            }
                            resEncodings.append(precEncodings)
                        }
                        compEncodings.append(resEncodings)
                    }
                    encodings.append(compEncodings)
                    completedBlocks += 1
                    progress?(try ProgressUpdate(phase: .processing, completedUnits: completedBlocks, totalUnits: estimatedTotalBlocks))
                    try work.check()
                }

                if needsPCRD && !flatCoords.isEmpty {
                    let blockPassBytes = flatCoords.map { coord in
                        encodings[coord.c][coord.r][coord.p][coord.b][coord.k].passTerminatedBytes
                    }
                    let blockPassDistortions = flatCoords.map { coord in
                        encodings[coord.c][coord.r][coord.p][coord.b][coord.k].passDistortionReductions
                    }
                    let totalFullBytes = max(1, blockPassBytes.reduce(0) { $0 + ($1.last ?? 0) })

                    let layerByteBudgets: [Int]
                    if !opts.layerBitrates.isEmpty {
                        layerByteBudgets = opts.layerBitrates.map {
                            max(1, Int(($0 * Double(tilePixels) / 8.0).rounded()))
                        }
                    } else if let targetBpp = opts.targetBitsPerPixel {
                        let targetTotal = max(1, Int((targetBpp * Double(tilePixels) / 8.0).rounded()))
                        if numLayers == 1 {
                            layerByteBudgets = [targetTotal]
                        } else {
                            layerByteBudgets = (0..<numLayers).map { l in
                                max(1, Int((Double(targetTotal) * pow(2.0, Double(l - (numLayers - 1)))).rounded()))
                            }
                        }
                    } else if configuration.mode == .lossy && useReversibleWavelet, let q = opts.quality {
                        let clamped = max(0.05, min(1.0, q))
                        let targetTotal = max(1, Int((Double(totalFullBytes) * clamped * clamped).rounded()))
                        if numLayers == 1 {
                            layerByteBudgets = [targetTotal]
                        } else {
                            layerByteBudgets = (0..<numLayers).map { l in
                                max(1, Int((Double(targetTotal) * pow(2.0, Double(l - (numLayers - 1)))).rounded()))
                            }
                        }
                    } else {
                        // Multi-layer without rate truncation: progressive prefix layers ending at full quality
                        layerByteBudgets = (0..<numLayers).map { l in
                            if l == numLayers - 1 { return Int.max }
                            let frac = pow(2.0, Double(l + 1 - numLayers))
                            return max(1, Int((Double(totalFullBytes) * frac).rounded()))
                        }
                    }

                    if isHT {
                        let finalBudget = layerByteBudgets.last ?? Int.max
                        let finalAlloc = Quantization.allocatePassesPCRD(
                            blockPassBytes: blockPassBytes,
                            blockPassDistortionReductions: blockPassDistortions,
                            layerByteBudgets: [finalBudget]
                        )
                        var activeHTBlocks: [(idx: Int, bytes: Int, slope: Double)] = []
                        for (idx, coord) in flatCoords.enumerated() {
                            let chosenK = finalAlloc[idx].first ?? 0
                            guard let candSet = coord.htCandidates, chosenK >= 1, chosenK <= candSet.topBit else {
                                var emptyEnc = CodeBlockEncoding(data: [], passCount: 0, zeroBitPlanes: coord.mb)
                                emptyEnc.layerPassCounts = Array(repeating: 0, count: numLayers)
                                encodings[coord.c][coord.r][coord.p][coord.b][coord.k] = emptyEnc
                                continue
                            }
                            let bandShift = candSet.topBit - chosenK
                            let data = candSet.codedPerK[chosenK - 1]
                            let distRed = candSet.distReductionPerK[chosenK - 1]
                            var enc = CodeBlockEncoding(
                                data: data,
                                passCount: data.isEmpty ? 0 : 1,
                                zeroBitPlanes: data.isEmpty ? coord.mb : max(0, coord.mb - 1 - bandShift)
                            )
                            if numLayers == 1 || data.isEmpty {
                                enc.layerPassCounts = Array(repeating: 0, count: numLayers)
                                if !data.isEmpty { enc.layerPassCounts[0] = 1 }
                            } else {
                                enc.layerPassCounts = Array(repeating: 0, count: numLayers)
                                activeHTBlocks.append((idx: idx, bytes: data.count, slope: distRed / Double(max(1, data.count))))
                            }
                            encodings[coord.c][coord.r][coord.p][coord.b][coord.k] = enc
                        }
                        if numLayers > 1 && !activeHTBlocks.isEmpty {
                            activeHTBlocks.sort { lhs, rhs in
                                if lhs.slope != rhs.slope { return lhs.slope > rhs.slope }
                                return lhs.idx < rhs.idx
                            }
                            var cumTotalBytes = 0
                            for item in activeHTBlocks {
                                let coord = flatCoords[item.idx]
                                cumTotalBytes += item.bytes
                                var targetLayer = numLayers - 1
                                for l in 0..<numLayers where cumTotalBytes <= layerByteBudgets[l] {
                                    targetLayer = l
                                    break
                                }
                                encodings[coord.c][coord.r][coord.p][coord.b][coord.k].layerPassCounts[targetLayer] = 1
                            }
                        }
                    } else {
                        let allocatedCumulative = Quantization.allocatePassesPCRD(
                            blockPassBytes: blockPassBytes,
                            blockPassDistortionReductions: blockPassDistortions,
                            layerByteBudgets: layerByteBudgets
                        )

                        for (idx, coord) in flatCoords.enumerated() {
                            let cumPasses = allocatedCumulative[idx]
                            let finalPasses = cumPasses.last ?? 0
                            var enc = encodings[coord.c][coord.r][coord.p][coord.b][coord.k]
                            if finalPasses < enc.passCount {
                                enc = try BitPlaneCoder.encodeRich(
                                    coefficients: coord.coeffs,
                                    width: coord.width,
                                    height: coord.height,
                                    orientation: coord.orientation,
                                    magnitudeBitPlanes: coord.mb,
                                    style: style,
                                    maxPasses: finalPasses
                                )
                            }
                            var incremental: [Int] = []
                            incremental.reserveCapacity(numLayers)
                            var prev = 0
                            for cum in cumPasses {
                                let clamped = min(enc.passCount, max(prev, cum))
                                incremental.append(clamped - prev)
                                prev = clamped
                            }
                            enc.layerPassCounts = incremental
                            encodings[coord.c][coord.r][coord.p][coord.b][coord.k] = enc
                        }
                    }
                }

                var tileWriter = ByteWriter(capacity: max(64, tilePixels / 2))
                try Tier2.encodePacketsMulti(
                    geometries: geometries,
                    codingStyles: codingStyles,
                    progressionChanges: pocEntries,
                    encodings: encodings,
                    into: &tileWriter,
                    cancellation: work.check
                )
                encodedTilePayloads.append(tileWriter.bytes)
            }
        }

        // Assemble codestream:
        let totalTileBytes = encodedTilePayloads.reduce(0) { $0 + 14 + $1.count }
        var out = ByteWriter(capacity: 256 + totalTileBytes)
        out.writeUInt16(Marker.soc)

        let compSignallings: [ComponentSignalling]
        if let pkg = part2Package {
            compSignallings = pkg.wireComponentFormats.map {
                ComponentSignalling(
                    precision: $0.precision,
                    signed: $0.signed,
                    horizontalSeparation: 1,
                    verticalSeparation: 1
                )
            }
        } else {
            compSignallings = [ComponentSignalling](
                repeating: ComponentSignalling(
                    precision: precision,
                    signed: signed,
                    horizontalSeparation: 1,
                    verticalSeparation: 1
                ),
                count: componentCount
            )
        }
        let rsizCapabilities: UInt16
        if usePart2MCT {
            rsizCapabilities = isHT ? 0xC100 : 0x8100
        } else {
            rsizCapabilities = isHT ? 0x4000 : 0
        }
        let sizeSeg = ImageSizeSegment(
            capabilities: rsizCapabilities,
            width: width,
            height: height,
            originX: 0,
            originY: 0,
            tileWidth: tileWidth,
            tileHeight: tileHeight,
            tileOriginX: 0,
            tileOriginY: 0,
            components: compSignallings
        )
        try CodestreamSyntax.writeSIZ(sizeSeg, into: &out)
        if isHT {
            let cap = try ExtendedCapabilitiesSegment.htOnly(
                for: mainQCD,
                decompositionLevels: levels,
                irreversible: !useReversibleWavelet
            )
            try CodestreamSyntax.writeCAP(cap, into: &out)
            if !useReversibleWavelet {
                try CodestreamSyntax.writeCPF(
                    CorrespondingProfileSegment(values: [usePart2MCT ? 0x8002 : 0x0002]),
                    into: &out
                )
            }
        }
        try CodestreamSyntax.writeCOD(cod, into: &out)
        try CodestreamSyntax.writeQCD(mainQCD, into: &out)
        if let pkg = part2Package {
            try CodestreamSyntax.writeCBD(pkg.cbd, into: &out)
            for table in pkg.mctTables {
                try CodestreamSyntax.writeMCT(table, into: &out)
            }
            try CodestreamSyntax.writeMCC(pkg.mccStage, into: &out)
            try CodestreamSyntax.writeMCO(pkg.mco, into: &out)
        }

        if roiShift > 0 {
            for c in 0..<componentCount {
                try CodestreamSyntax.writeRGN(
                    RegionOfInterestSegment(component: c, style: 0, shift: roiShift),
                    componentCount: componentCount,
                    into: &out
                )
            }
        }
        if !pocEntries.isEmpty {
            try CodestreamSyntax.writePOC(pocEntries, componentCount: componentCount, into: &out)
        }

        for (tileIndex, payload) in encodedTilePayloads.enumerated() {
            let psot = 12 + 2 + payload.count
            guard psot <= Int(UInt32.max) else {
                throw CodecError(.resourceLimitExceeded, "Tile-part exceeds the Psot field.")
            }
            out.writeUInt16(Marker.sot)
            out.writeUInt16(10)
            out.writeUInt16(UInt16(tileIndex))
            out.writeUInt32(UInt32(psot))
            out.writeUInt8(0)
            out.writeUInt8(1)
            out.writeUInt16(Marker.sod)
            out.writeBytes(payload)
        }
        out.writeUInt16(Marker.eoc)
        return (out.bytes, workspace)
    }

    // MARK: - Lossless Multi-Component / Signed Wavelet-Domain Transcoding

    /// Transcodes any lossless reversible 5/3 JPEG 2000 Part 1 or Part 15 (HTJ2K) codestream
    /// (including signed, multi-component, RCT, Part 2 reversible MCT, and custom progression/precincts)
    /// directly in the wavelet subband coefficient domain with zero pixel allocations (`pixelAllocationCount == 0`).
    static func transcodeLosslessCoefficients(
        bytes: [UInt8],
        profile: Part1Profile,
        to target: TranscodeTarget,
        codecOptions: CodecOptions,
        metadataPolicy: MetadataPolicy = .preserve,
        limits: ResourceLimits,
        backend: Backend = .scalarCPU,
        progress: (@Sendable (ProgressUpdate) -> Void)?
    ) throws -> (Data, Int) {
        let targetIsHT = (target == .htj2k)
        guard profile.isHTJ2K != targetIsHT else {
            throw CodecError(
                .unsupportedFormat,
                "Transcoding requires converting between JPEG 2000 Part 1 and HTJ2K Part 15 (source is already \(profile.format))."
            )
        }
        guard profile.isReversibleLossless else {
            throw CodecError(
                .unsupportedFeature,
                "Zero-pixel-allocation wavelet transcoding requires a lossless reversible 5/3 codestream."
            )
        }
        guard profile.tiles.allSatisfy({ $0.components.allSatisfy { $0.roiShift == 0 } }) else {
            throw CodecError(
                .unsupportedFeature,
                "Lossless wavelet transcoding does not support RGN region-of-interest codestreams."
            )
        }
        if let requestedLevels = codecOptions.decompositionLevels {
            for tile in profile.tiles {
                for comp in tile.components where comp.codingStyle.decompositionLevels != requestedLevels {
                    throw CodecError(
                        .unsupportedFeature,
                        "Changing wavelet decomposition levels (\(comp.codingStyle.decompositionLevels) -> \(requestedLevels)) requires wavelet reconstruction and is not supported on the coefficient transcoding path."
                    )
                }
            }
        }

        let parsed = try CodestreamSyntax.parse(bytes, limits: limits, metadataPolicy: metadataPolicy)
        let wireCount = profile.wireComponents.count
        let workspace = try checkedAdd(
            try workspaceBytes(
                planePixels: profile.largestTilePixels,
                componentCount: wireCount,
                bytesPerCoeff: 4,
                joinedBytes: profile.largestTileBytes
            ),
            profile.retainedMetadataBytes
        )
        guard workspace <= limits.maximumWorkspaceBytes else {
            throw CodecError(.resourceLimitExceeded, "Transcoder workspace exceeds the operation limit.")
        }
        guard try checkedAdd(bytes.count, workspace) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Compressed input and transcoder workspace exceed the memory budget.")
        }

        let work = WorkGuard(limits: limits)
        try work.check()

        let xcb = codecOptions.codeBlockWidth.trailingZeroBitCount
        let ycb = codecOptions.codeBlockHeight.trailingZeroBitCount
        let targetStyleBits: UInt8 = targetIsHT ? 0x40 : codecOptions.codeBlockStyleBits
        let targetStyle = CodeBlockStyle(bits: targetStyleBits)

        func makeTargetCOD(from sourceCOD: CodingStyleSegment) -> CodingStyleSegment {
            let levels = sourceCOD.decompositionLevels
            let usesPrecincts: Bool
            var precinctExponents: [(Int, Int)] = []
            if !codecOptions.precinctSizes.isEmpty {
                usesPrecincts = true
                for r in 0...levels {
                    let pSize = codecOptions.precinctSizes[min(r, codecOptions.precinctSizes.count - 1)]
                    precinctExponents.append((pSize.width.trailingZeroBitCount, pSize.height.trailingZeroBitCount))
                }
            } else {
                usesPrecincts = sourceCOD.usesPrecincts
                precinctExponents = sourceCOD.precinctExponents
            }
            let progression: UInt8 = (codecOptions.progressionOrder != .lrcp)
                ? codecOptions.progressionOrder.rawValue
                : sourceCOD.progression
            return CodingStyleSegment(
                usesPrecincts: usesPrecincts,
                usesSOP: codecOptions.usesSOP || sourceCOD.usesSOP,
                usesEPH: codecOptions.usesEPH || sourceCOD.usesEPH,
                progression: progression,
                layers: 1,
                componentTransform: sourceCOD.componentTransform,
                decompositionLevels: levels,
                codeBlockWidthExponent: xcb,
                codeBlockHeightExponent: ycb,
                codeBlockStyle: targetStyleBits,
                reversible: true,
                precinctExponents: precinctExponents
            )
        }

        let targetPOCEntries: [ProgressionOrderChangeEntry] = codecOptions.progressionChanges.map {
            ProgressionOrderChangeEntry(
                resolutionStart: $0.startResolution,
                componentStart: $0.startComponent,
                layerEnd: 1,
                resolutionEnd: $0.endResolution,
                componentEnd: $0.endComponent,
                progression: $0.progressionOrder.rawValue
            )
        }

        let mainTargetCOD = makeTargetCOD(from: parsed.baseCodingStyle)
        var encodedTilePayloads: [[UInt8]] = []
        encodedTilePayloads.reserveCapacity(profile.tiles.count)
        let totalUnits = max(1, profile.codeBlockCount)
        var completedUnits = 0
        progress?(try ProgressUpdate(phase: .processing, completedUnits: 0, totalUnits: totalUnits))

        for tile in profile.tiles {
            try work.check()
            let tileBytes: [UInt8]
            let tileRange: Range<Int>
            if tile.dataRanges.count == 1 {
                tileBytes = bytes
                tileRange = tile.dataRanges[0]
            } else {
                let joinedCount = tile.dataRanges.reduce(0) { $0 + $1.count }
                StorageTelemetry.recordWorkspaceAllocation(bytes: joinedCount)
                var joined: [UInt8] = []
                joined.reserveCapacity(joinedCount)
                for r in tile.dataRanges { joined.append(contentsOf: bytes[r]) }
                tileBytes = joined
                tileRange = 0..<joined.count
            }

            let srcGeometries = tile.components.map(\.geometry)
            let srcCodingStyles = tile.components.map(\.codingStyle)
            let contributions = try Tier2.decodePacketsMulti(
                geometries: srcGeometries,
                codingStyles: srcCodingStyles,
                progressionChanges: tile.progressionChanges,
                maxQualityLayers: nil,
                bytes: tileBytes,
                range: tileRange,
                cancellation: work.check
            )

            let stride = tile.width
            let planeCount = tile.width * tile.height
            var targetGeometries: [TileGeometry] = []
            var targetCodingStyles: [CodingStyleSegment] = []
            var encodings: [[[[[CodeBlockEncoding]]]]] = []
            targetGeometries.reserveCapacity(wireCount)
            targetCodingStyles.reserveCapacity(wireCount)
            encodings.reserveCapacity(wireCount)

            for comp in tile.components {
                let c = comp.componentIndex
                StorageTelemetry.recordWorkspaceAllocation(bytes: planeCount * 4)
                var subbandPlane = [Int32](repeating: 0, count: planeCount)
                let srcStyle = CodeBlockStyle(bits: comp.codingStyle.codeBlockStyle)

                for resolution in comp.geometry.resolutions {
                    for (p, precinct) in resolution.precincts.enumerated() {
                        for (b, precinctBand) in precinct.bands.enumerated() {
                            let band = resolution.bands[precinctBand.bandIndex]
                            let mb = comp.magnitudeBitPlanes[band.quantizationIndex]
                            for (k, block) in precinctBand.blocks.enumerated() {
                                try work.check()
                                let contribution = contributions[c][resolution.index][p][b][k]
                                completedUnits += 1
                                guard contribution.included, contribution.passes > 0, mb > 0 else { continue }
                                if contribution.isHT {
                                    let htPasses = ((contribution.passes - 1) % 3) + 1
                                    if htPasses == 1 && contribution.segments.count <= 1 && !srcStyle.causal {
                                        let placeholderSets = (contribution.passes - 1) / 3
                                        let effectiveMissingMSBs = contribution.zeroBitPlanes + placeholderSets
                                        let rawBlock = contribution.segments.first?.data ?? []
                                        let coeffs = try AcceleratedCodec.decodeHTCleanup(
                                            block: rawBlock, width: block.width, height: block.height,
                                            kMax: mb, missingMSBs: effectiveMissingMSBs,
                                            backend: backend
                                        )
                                        for row in 0..<block.height {
                                            let planeRow = (band.planeY + block.y0 - band.y0 + row) * stride + band.planeX + block.x0 - band.x0
                                            for col in 0..<block.width {
                                                subbandPlane[planeRow + col] = coeffs[row * block.width + col]
                                            }
                                        }
                                    } else {
                                        let coeffs64 = try HTBlockDecoder.decodeHTCodeBlock(
                                            segments: contribution.segments.map {
                                                HTSegmentInput(data: $0.data, passes: $0.passes)
                                            },
                                            zeroBitPlanes: contribution.zeroBitPlanes,
                                            totalPasses: contribution.passes,
                                            width: block.width,
                                            height: block.height,
                                            kMax: mb,
                                            causal: srcStyle.causal,
                                            allowMultiHT: false,
                                            midpointReconstruction: false
                                        )
                                        for row in 0..<block.height {
                                            let planeRow = (band.planeY + block.y0 - band.y0 + row) * stride + band.planeX + block.x0 - band.x0
                                            for col in 0..<block.width {
                                                subbandPlane[planeRow + col] = Int32(clamping: coeffs64[row * block.width + col])
                                            }
                                        }
                                    }
                                } else {
                                    let (coeffs64, _) = try BitPlaneCoder.decodeRich(
                                        segments: contribution.segments,
                                        width: block.width, height: block.height,
                                        orientation: band.orientation,
                                        zeroBitPlanes: contribution.zeroBitPlanes,
                                        passCount: contribution.passes,
                                        magnitudeBitPlanes: mb,
                                        style: srcStyle
                                    )
                                    for row in 0..<block.height {
                                        let planeRow = (band.planeY + block.y0 - band.y0 + row) * stride + band.planeX + block.x0 - band.x0
                                        for col in 0..<block.width {
                                            subbandPlane[planeRow + col] = Int32(clamping: coeffs64[row * block.width + col])
                                        }
                                    }
                                }
                                if completedUnits & 7 == 0 {
                                    progress?(try ProgressUpdate(phase: .processing, completedUnits: min(completedUnits, totalUnits), totalUnits: totalUnits))
                                    try work.check()
                                }
                            }
                        }
                    }
                }

                let tgtCOD = makeTargetCOD(from: comp.codingStyle)
                let tgtGeom = try Tier2.makeTileGeometry(
                    x0: tile.x0, x1: tile.x1, y0: tile.y0, y1: ty1(tile), codingStyle: tgtCOD
                )
                targetCodingStyles.append(tgtCOD)
                targetGeometries.append(tgtGeom)

                var compEncodings: [[[[CodeBlockEncoding]]]] = []
                compEncodings.reserveCapacity(tgtGeom.resolutions.count)
                for resolution in tgtGeom.resolutions {
                    var resEncodings: [[[CodeBlockEncoding]]] = []
                    resEncodings.reserveCapacity(resolution.precincts.count)
                    for precinct in resolution.precincts {
                        var precEncodings: [[CodeBlockEncoding]] = []
                        precEncodings.reserveCapacity(precinct.bands.count)
                        for precinctBand in precinct.bands {
                            let band = resolution.bands[precinctBand.bandIndex]
                            let mb = comp.magnitudeBitPlanes[band.quantizationIndex]
                            var bandEncodings: [CodeBlockEncoding] = []
                            bandEncodings.reserveCapacity(precinctBand.blocks.count)
                            for block in precinctBand.blocks {
                                try work.check()
                                let enc: CodeBlockEncoding
                                if targetIsHT {
                                    var coeffs32: [Int32] = []
                                    coeffs32.reserveCapacity(block.width * block.height)
                                    for row in 0..<block.height {
                                        let planeRow = (band.planeY + block.y0 - band.y0 + row) * stride + band.planeX + block.x0 - band.x0
                                        coeffs32.append(contentsOf: subbandPlane[planeRow..<(planeRow + block.width)])
                                    }
                                    let coded = try AcceleratedCodec.encodeHTCleanup(
                                        coefficients: coeffs32,
                                        width: block.width,
                                        height: block.height,
                                        bandShift: 0,
                                        backend: backend
                                    )
                                    enc = CodeBlockEncoding(
                                        data: coded,
                                        passCount: coded.isEmpty ? 0 : 1,
                                        zeroBitPlanes: coded.isEmpty ? mb : max(0, mb - 1)
                                    )
                                } else {
                                    var coeffs64: [Int64] = []
                                    coeffs64.reserveCapacity(block.width * block.height)
                                    for row in 0..<block.height {
                                        let planeRow = (band.planeY + block.y0 - band.y0 + row) * stride + band.planeX + block.x0 - band.x0
                                        for col in 0..<block.width {
                                            coeffs64.append(Int64(subbandPlane[planeRow + col]))
                                        }
                                    }
                                    enc = try BitPlaneCoder.encodeRich(
                                        coefficients: coeffs64,
                                        width: block.width,
                                        height: block.height,
                                        orientation: band.orientation,
                                        magnitudeBitPlanes: mb,
                                        style: targetStyle
                                    )
                                }
                                bandEncodings.append(enc)
                            }
                            precEncodings.append(bandEncodings)
                        }
                        resEncodings.append(precEncodings)
                    }
                    compEncodings.append(resEncodings)
                }
                subbandPlane = []
                encodings.append(compEncodings)
            }

            let tilePOC = !targetPOCEntries.isEmpty
                ? targetPOCEntries
                : tile.progressionChanges.map {
                    ProgressionOrderChangeEntry(
                        resolutionStart: $0.resolutionStart,
                        componentStart: $0.componentStart,
                        layerEnd: 1,
                        resolutionEnd: $0.resolutionEnd,
                        componentEnd: $0.componentEnd,
                        progression: $0.progression
                    )
                }
            var tileWriter = ByteWriter(capacity: max(64, planeCount / 2))
            try Tier2.encodePacketsMulti(
                geometries: targetGeometries,
                codingStyles: targetCodingStyles,
                progressionChanges: tilePOC,
                encodings: encodings,
                into: &tileWriter,
                cancellation: work.check
            )
            encodedTilePayloads.append(tileWriter.bytes)
        }

        let totalTileBytes = encodedTilePayloads.reduce(0) { $0 + 32 + $1.count }
        var out = ByteWriter(capacity: 256 + totalTileBytes)
        out.writeUInt16(Marker.soc)

        let targetCapabilities = (parsed.size.capabilities & ~0x4000) | (targetIsHT ? 0x4000 : 0)
        let targetSIZ = ImageSizeSegment(
            capabilities: targetCapabilities,
            width: parsed.size.width,
            height: parsed.size.height,
            originX: parsed.size.originX,
            originY: parsed.size.originY,
            tileWidth: parsed.size.tileWidth,
            tileHeight: parsed.size.tileHeight,
            tileOriginX: parsed.size.tileOriginX,
            tileOriginY: parsed.size.tileOriginY,
            components: parsed.size.components
        )
        try CodestreamSyntax.writeSIZ(targetSIZ, into: &out)

        if targetIsHT {
            let cap = try ExtendedCapabilitiesSegment.htOnly(
                for: parsed.baseQuantization,
                componentQCDs: parsed.componentQuantizations,
                decompositionLevels: mainTargetCOD.decompositionLevels,
                irreversible: false
            )
            try CodestreamSyntax.writeCAP(cap, into: &out)
        }
        try CodestreamSyntax.writeCOD(mainTargetCOD, into: &out)
        try CodestreamSyntax.writeQCD(parsed.baseQuantization, into: &out)
        for compIdx in parsed.componentQuantizations.keys.sorted() {
            if let qcc = parsed.componentQuantizations[compIdx] {
                try CodestreamSyntax.writeQCC(
                    component: compIdx,
                    componentCount: wireCount,
                    qcc: qcc,
                    into: &out
                )
            }
        }
        if let cbd = parsed.componentBitDepth {
            try CodestreamSyntax.writeCBD(cbd, into: &out)
        }
        let sortedMCTKeys = parsed.mctTables.keys.sorted {
            if $0.arrayType.rawValue != $1.arrayType.rawValue {
                return $0.arrayType.rawValue < $1.arrayType.rawValue
            }
            return $0.tableIndex < $1.tableIndex
        }
        for key in sortedMCTKeys {
            if let table = parsed.mctTables[key] {
                try CodestreamSyntax.writeMCT(table, into: &out)
            }
        }
        for stageIdx in parsed.mccStages.keys.sorted() {
            if let stage = parsed.mccStages[stageIdx] {
                try CodestreamSyntax.writeMCC(stage, into: &out)
            }
        }
        if let mco = parsed.mco {
            try CodestreamSyntax.writeMCO(mco, into: &out)
        }
        if !targetPOCEntries.isEmpty {
            try CodestreamSyntax.writePOC(targetPOCEntries, componentCount: wireCount, into: &out)
        } else if !parsed.progressionChanges.isEmpty {
            let mainPOC = parsed.progressionChanges.map {
                ProgressionOrderChangeEntry(
                    resolutionStart: $0.resolutionStart,
                    componentStart: $0.componentStart,
                    layerEnd: 1,
                    resolutionEnd: $0.resolutionEnd,
                    componentEnd: $0.componentEnd,
                    progression: $0.progression
                )
            }
            try CodestreamSyntax.writePOC(mainPOC, componentCount: wireCount, into: &out)
        }
        if metadataPolicy == .preserve {
            if let crg = parsed.componentRegistration {
                try out.writeSegment(marker: Marker.crg, payload: crg)
            }
            for comment in parsed.mainHeaderComments {
                var comPayload = [UInt8]()
                comPayload.reserveCapacity(2 + comment.count)
                comPayload.append(0x00)
                comPayload.append(0x01)
                comPayload.append(contentsOf: comment)
                try out.writeSegment(marker: Marker.com, payload: comPayload)
            }
        }

        for (pos, tile) in profile.tiles.enumerated() {
            let payload = encodedTilePayloads[pos]
            var tileHeader = ByteWriter(capacity: 64)
            let tileDefaultCOD = makeTargetCOD(from: tile.defaultCodingStyle)
            if tileDefaultCOD != mainTargetCOD {
                try CodestreamSyntax.writeCOD(tileDefaultCOD, into: &tileHeader)
            }
            if let overrides = parsed.tileOverrides[tile.index] {
                if let tileQCD = overrides.quantization {
                    try CodestreamSyntax.writeQCD(tileQCD, into: &tileHeader)
                }
                for compIdx in overrides.componentQuantizations.keys.sorted() {
                    if let qcc = overrides.componentQuantizations[compIdx] {
                        try CodestreamSyntax.writeQCC(
                            component: compIdx,
                            componentCount: wireCount,
                            qcc: qcc,
                            into: &tileHeader
                        )
                    }
                }
                for frag in overrides.mctFragments {
                    try tileHeader.writeSegment(marker: Marker.mct, payload: try frag.serialiseBody())
                }
                for frag in overrides.mccFragments {
                    try tileHeader.writeSegment(marker: Marker.mcc, payload: try frag.serialiseBody())
                }
                if let tileMCO = overrides.mco {
                    try CodestreamSyntax.writeMCO(tileMCO, into: &tileHeader)
                }
                if targetPOCEntries.isEmpty && !overrides.progressionChanges.isEmpty {
                    let tPOC = overrides.progressionChanges.map {
                        ProgressionOrderChangeEntry(
                            resolutionStart: $0.resolutionStart,
                            componentStart: $0.componentStart,
                            layerEnd: 1,
                            resolutionEnd: $0.resolutionEnd,
                            componentEnd: $0.componentEnd,
                            progression: $0.progression
                        )
                    }
                    try CodestreamSyntax.writePOC(tPOC, componentCount: wireCount, into: &tileHeader)
                }
            }
            if metadataPolicy == .preserve {
                for comment in tile.comments {
                    var comPayload = [UInt8]()
                    comPayload.reserveCapacity(2 + comment.count)
                    comPayload.append(0x00)
                    comPayload.append(0x01)
                    comPayload.append(contentsOf: comment)
                    try tileHeader.writeSegment(marker: Marker.com, payload: comPayload)
                }
            }

            let psot = 12 + tileHeader.bytes.count + 2 + payload.count
            guard psot <= Int(UInt32.max) else {
                throw CodecError(.resourceLimitExceeded, "Tile-part exceeds the Psot field.")
            }
            out.writeUInt16(Marker.sot)
            out.writeUInt16(10)
            out.writeUInt16(UInt16(tile.index))
            out.writeUInt32(UInt32(psot))
            out.writeUInt8(0)
            out.writeUInt8(1)
            out.writeBytes(tileHeader.bytes)
            out.writeUInt16(Marker.sod)
            out.writeBytes(payload)
        }
        out.writeUInt16(Marker.eoc)
        guard out.bytes.count <= limits.maximumCompressedBytes else {
            throw CodecError(.resourceLimitExceeded, "Transcoded codestream exceeds the compressed-size limit.")
        }
        return (Data(out.bytes), workspace)
    }

    @inline(__always)
    private static func ty1(_ tile: Part1TileProfile) -> Int {
        tile.y1
    }
}
