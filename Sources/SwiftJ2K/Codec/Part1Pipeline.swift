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
    let precision: Int
    let signed: Bool
    let isHTJ2K: Bool
    let isReversibleLossless: Bool
    let tiles: [Part1TileProfile]
    let commentCount: Int
    let commentPayloadBytes: Int

    var format: String { isHTJ2K ? ScalarLosslessCodec.htj2kFormat : ScalarLosslessCodec.format }
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
                throw CodecError(.unsupportedFeature, "Region-of-interest (RGN) coding is not supported in HTJ2K mode.")
            }
        }
        let componentCount = size.components.count
        guard componentCount >= 1 else {
            throw CodecError(.malformedInput, "SIZ declares no components.")
        }
        let firstComp = size.components[0]
        for comp in size.components {
            guard comp.precision >= 1 && comp.precision <= 16 else {
                throw CodecError(.unsupportedFeature, "Component precision above 16 bits is not supported.")
            }
            guard comp.horizontalSeparation == 1 && comp.verticalSeparation == 1 else {
                throw CodecError(.unsupportedFeature, "Sub-sampled components are not supported.")
            }
            guard comp.signed == firstComp.signed && comp.precision == firstComp.precision else {
                throw CodecError(.unsupportedFeature, "Heterogeneous component precision or signedness is not supported.")
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
        var runningGeometryBytes = 0
        var allReversibleLossless = true

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

            let (defaultCOD, _) = parsed.effectiveParameters(tile: tileIndex, component: 0)
            if defaultCOD.componentTransform == 1 {
                guard componentCount >= 3 else {
                    throw CodecError(.malformedInput, "A component transform is signalled for fewer than 3 components.")
                }
            }

            var compProfiles: [Part1ComponentTileProfile] = []
            compProfiles.reserveCapacity(componentCount)

            for c in 0..<componentCount {
                let (cod, rawQCD) = parsed.effectiveParameters(tile: tileIndex, component: c)
                if (cod.codeBlockStyle & 0x40) != 0 && (cod.codeBlockStyle & 0x80) == 0 {
                    guard (cod.codeBlockStyle & 0x3E) == 0 else {
                        throw CodecError(.malformedInput, "COD/COC sets reserved code-block style bits in HTJ2K mode.")
                    }
                    guard cod.reversible && rawQCD.style == .none else {
                        throw CodecError(.unsupportedFeature, "Irreversible or quantised HTJ2K codestreams are not supported.")
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

                // Component dynamic range Rb = precision + rctAdjust + band.gain
                let rctAdjust = (defaultCOD.componentTransform == 1 && cod.reversible && (c == 1 || c == 2)) ? 1 : 0
                let compRangePrecision = firstComp.precision + rctAdjust

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
                components: compProfiles,
                dataRanges: ordered.map(\.dataRange),
                comments: ordered.flatMap(\.comments)
            ))
        }

        guard tiles.count == tilesWide * tilesHigh else {
            throw CodecError(.malformedInput, "Codestream lacks tile-parts for \(tilesWide * tilesHigh - tiles.count) of its tiles.")
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
            componentCount: componentCount,
            precision: firstComp.precision,
            signed: firstComp.signed,
            isHTJ2K: parsed.isHTJ2K,
            isReversibleLossless: allReversibleLossless,
            tiles: tiles,
            commentCount: parsed.commentCount,
            commentPayloadBytes: parsed.commentPayloadBytes
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
        progress: (@Sendable (ProgressUpdate) -> Void)?
    ) throws -> (Image, Int) {
        let descriptor = destination.descriptor
        let expectedSampleType: SampleType = profile.signed ? .signedInteger : .unsignedInteger
        let validStorageBits = descriptor.storageBits == 16 || (descriptor.storageBits == 8 && profile.precision <= 8)
        let validComponents: Bool
        if profile.componentCount == 1 {
            validComponents = descriptor.components == [.grey]
        } else {
            validComponents = descriptor.components.count == profile.componentCount
        }
        guard descriptor.width == profile.width,
              descriptor.height == profile.height,
              descriptor.sampleType == expectedSampleType,
              validStorageBits,
              validComponents,
              descriptor.meaningfulBits == profile.precision else {
            throw CodecError(.incompatibleImageLayout, "Destination descriptor does not match the codestream geometry, components, signedness, or precision.")
        }

        let bytesPerCoeff = profile.isReversibleLossless ? 4 : 8
        let workspace = try workspaceBytes(
            planePixels: profile.largestTilePixels,
            componentCount: profile.componentCount,
            bytesPerCoeff: bytesPerCoeff,
            joinedBytes: profile.largestTileBytes
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
                workspace: workspace, work: work, progress: progress
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
        progress: (@Sendable (ProgressUpdate) -> Void)?
    ) throws -> (Image, Int) {
        let descriptor = destination.descriptor
        let mutation = SharedPathMutation.active
        let order = mutation == .wrongByteOrder ? descriptor.byteOrder.opposite : descriptor.byteOrder
        let shift = profile.signed ? 0 : (1 << (profile.precision - 1))
        let minVal = profile.signed ? -(1 << (profile.precision - 1)) : 0
        let maxVal = profile.signed ? ((1 << (profile.precision - 1)) - 1) : ((1 << profile.precision) - 1)

        // Pre-locate plane and sample offset for each component index.
        var compLocations: [(plane: PlaneDescriptor, sampleOffset: Int, rowBytes: Int)] = []
        compLocations.reserveCapacity(profile.componentCount)
        for c in 0..<profile.componentCount {
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
                    bytes: tileBytes,
                    range: tileRange,
                    cancellation: work.check
                )

                let stride = tile.width
                let planeCount = tile.width * tile.height
                let tileUsesReversibleIntPath = tile.components.allSatisfy {
                    $0.codingStyle.reversible && $0.quantization.style == .none
                }

                if tileUsesReversibleIntPath {
                    var intPlanes: [[Int32]] = []
                    intPlanes.reserveCapacity(profile.componentCount)
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
                                            guard htPasses == 1, contribution.segments.count <= 1 else {
                                                throw CodecError(.unsupportedFeature, "HTJ2K refinement passes are not supported.")
                                            }
                                            let placeholderSets = (contribution.passes - 1) / 3
                                            let effectiveMissingMSBs = contribution.zeroBitPlanes + placeholderSets
                                            let rawBlock = contribution.segments.first?.data ?? []
                                            let coeffs = try HTBlockDecoder.decodeCleanup(
                                                block: rawBlock, width: block.width, height: block.height,
                                                kMax: mb, missingMSBs: effectiveMissingMSBs
                                            )
                                            for row in 0..<block.height {
                                                let planeRow = (band.planeY + block.y0 - band.y0 + row) * stride + band.planeX + block.x0 - band.x0
                                                for col in 0..<block.width {
                                                    plane[planeRow + col] = coeffs[row * block.width + col]
                                                }
                                            }
                                        } else {
                                            let (coeffs64, _) = try BitPlaneCoder.decodeRich(
                                                segments: contribution.segments,
                                                width: block.width, height: block.height,
                                                orientation: band.orientation,
                                                zeroBitPlanes: contribution.zeroBitPlanes,
                                                passCount: contribution.passes,
                                                magnitudeBitPlanes: effectiveMB,
                                                style: style
                                            )
                                            for row in 0..<block.height {
                                                let planeRow = (band.planeY + block.y0 - band.y0 + row) * stride + band.planeX + block.x0 - band.x0
                                                for col in 0..<block.width {
                                                    let rawVal = coeffs64[row * block.width + col]
                                                    let descaled = comp.roiShift > 0
                                                        ? ROICoding.descaleCoefficient(rawVal, shift: comp.roiShift)
                                                        : rawVal
                                                    plane[planeRow + col] = Int32(clamping: descaled)
                                                }
                                            }
                                        }
                                        if completed & 7 == 0 {
                                            progress?(try ProgressUpdate(phase: .processing, completedUnits: completed, totalUnits: total))
                                        }
                                    }
                                }
                            }
                        }
                        try Wavelet53.inverse(
                            plane: &plane, stride: stride,
                            x0: tile.x0, x1: tile.x1, y0: tile.y0, y1: tile.y1,
                            levels: comp.codingStyle.decompositionLevels,
                            cancellation: work.check
                        )
                        intPlanes.append(plane)
                    }

                    if tile.defaultCodingStyle.componentTransform == 1 && intPlanes.count >= 3 {
                        ColourTransform.inverseRCT(planes: &intPlanes)
                    }

                    for c in 0..<profile.componentCount {
                        let loc = compLocations[c]
                        let planeData = intPlanes[c]
                        for row in 0..<tile.height {
                            try work.check()
                            let y = tile.y0 - profile.originY + row
                            let rowBase = loc.plane.offset + y * loc.rowBytes + loc.sampleOffset
                            for col in 0..<tile.width {
                                let x = tile.x0 - profile.originX + col
                                let value = min(max(Int(planeData[row * stride + col]) + shift, minVal), maxVal)
                                try storeSampleInt(
                                    value, into: output, at: rowBase + x * loc.plane.pixelStride,
                                    storageBits: descriptor.storageBits, signed: profile.signed, order: order
                                )
                            }
                        }
                    }
                } else {
                    var doublePlanes: [[Double]] = []
                    doublePlanes.reserveCapacity(profile.componentCount)
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
                                        let (coeffs64, lastPlanes) = try BitPlaneCoder.decodeRich(
                                            segments: contribution.segments,
                                            width: block.width, height: block.height,
                                            orientation: band.orientation,
                                            zeroBitPlanes: contribution.zeroBitPlanes,
                                            passCount: contribution.passes,
                                            magnitudeBitPlanes: effectiveMB,
                                            style: style
                                        )
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
                                        }
                                    }
                                }
                            }
                        }

                        if comp.codingStyle.reversible {
                            var intPlane = plane.map { Int32($0.rounded()) }
                            try Wavelet53.inverse(
                                plane: &intPlane, stride: stride,
                                x0: tile.x0, x1: tile.x1, y0: tile.y0, y1: tile.y1,
                                levels: comp.codingStyle.decompositionLevels,
                                cancellation: work.check
                            )
                            plane = intPlane.map { Double($0) }
                        } else {
                            try Wavelet97.inverse(
                                plane: &plane, stride: stride,
                                x0: tile.x0, x1: tile.x1, y0: tile.y0, y1: tile.y1,
                                levels: comp.codingStyle.decompositionLevels,
                                cancellation: work.check
                            )
                        }
                        doublePlanes.append(plane)
                    }

                    if tile.defaultCodingStyle.componentTransform == 1 && doublePlanes.count >= 3 {
                        if tile.defaultCodingStyle.reversible {
                            var rctPlanes = [
                                doublePlanes[0].map { Int32($0.rounded()) },
                                doublePlanes[1].map { Int32($0.rounded()) },
                                doublePlanes[2].map { Int32($0.rounded()) }
                            ]
                            ColourTransform.inverseRCT(planes: &rctPlanes)
                            doublePlanes[0] = rctPlanes[0].map { Double($0) }
                            doublePlanes[1] = rctPlanes[1].map { Double($0) }
                            doublePlanes[2] = rctPlanes[2].map { Double($0) }
                        } else {
                            ColourTransform.inverseICT(planes: &doublePlanes)
                        }
                    }

                    for c in 0..<profile.componentCount {
                        let loc = compLocations[c]
                        let planeData = doublePlanes[c]
                        for row in 0..<tile.height {
                            try work.check()
                            let y = tile.y0 - profile.originY + row
                            let rowBase = loc.plane.offset + y * loc.rowBytes + loc.sampleOffset
                            for col in 0..<tile.width {
                                let x = tile.x0 - profile.originX + col
                                let rounded = Int(planeData[row * stride + col].rounded())
                                let value = min(max(rounded + shift, minVal), maxVal)
                                try storeSampleInt(
                                    value, into: output, at: rowBase + x * loc.plane.pixelStride,
                                    storageBits: descriptor.storageBits, signed: profile.signed, order: order
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
        // Note: For RCT, components 1 and 2 have +1 nominal dynamic range bit.
        // Putting the max precision in main QCD (precision + (componentTransform == 1 && useReversibleWavelet ? 1 : 0))
        // avoids even needing separate QCC markers, while staying 100% conformant!
        let maxEffectivePrecision = precision + ((componentTransform == 1 && useReversibleWavelet && componentCount >= 3) ? 1 : 0)
        var mainQCD: QuantizationSegment
        if useReversibleWavelet && (opts.quantizationStyle == .automatic || opts.quantizationStyle == .none) {
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
                            compPlane[row * tw + col] = Int32(sample - shift)
                        }
                    }
                    originalIntTile.append(compPlane)
                }

                // Forward colour + wavelet + quantisation produces Int64 wavelet coefficient planes:
                var quantisedPlanes = [[Int64]](repeating: [Int64](repeating: 0, count: tilePixels), count: componentCount)

                if useReversibleWavelet && expandedQCD.style == .none {
                    var workingPlanes = originalIntTile
                    if componentTransform == 1 && componentCount >= 3 {
                        ColourTransform.forwardRCT(planes: &workingPlanes)
                    }
                    for c in 0..<componentCount {
                        try Wavelet53.forward(
                            plane: &workingPlanes[c], stride: tw,
                            x0: tx0, x1: tx1, y0: ty0, y1: ty1,
                            levels: levels, cancellation: work.check
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
                                try Wavelet53.inverse(
                                    plane: &reconPlanes[c], stride: tw,
                                    x0: tx0, x1: tx1, y0: ty0, y1: ty1,
                                    levels: levels, cancellation: work.check
                                )
                            }
                            if componentTransform == 1 && componentCount >= 3 {
                                ColourTransform.inverseRCT(planes: &reconPlanes)
                            }
                            var worstError = 0
                            outerCheck: for c in 0..<componentCount {
                                for i in 0..<tilePixels {
                                    let orig = min(max(Int(originalIntTile[c][i]) + shift, minVal), maxVal)
                                    let rec = min(max(Int(reconPlanes[c][i]) + shift, minVal), maxVal)
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
                    if componentTransform == 1 && componentCount >= 3 {
                        if useReversibleWavelet {
                            var rctPlanes = [originalIntTile[0], originalIntTile[1], originalIntTile[2]]
                            ColourTransform.forwardRCT(planes: &rctPlanes)
                            doublePlanes[0] = rctPlanes[0].map { Double($0) }
                            doublePlanes[1] = rctPlanes[1].map { Double($0) }
                            doublePlanes[2] = rctPlanes[2].map { Double($0) }
                        } else {
                            ColourTransform.forwardICT(planes: &doublePlanes)
                        }
                    }
                    for c in 0..<componentCount {
                        if useReversibleWavelet {
                            var intP = doublePlanes[c].map { Int32($0.rounded()) }
                            try Wavelet53.forward(
                                plane: &intP, stride: tw,
                                x0: tx0, x1: tx1, y0: ty0, y1: ty1,
                                levels: levels, cancellation: work.check
                            )
                            doublePlanes[c] = intP.map { Double($0) }
                        } else {
                            try Wavelet97.forward(
                                plane: &doublePlanes[c], stride: tw,
                                x0: tx0, x1: tx1, y0: ty0, y1: ty1,
                                levels: levels, cancellation: work.check
                            )
                        }
                    }

                    // Quantise each subband by its step size from `expandedQCD`:
                    for c in 0..<componentCount {
                        let rctAdjust = (componentTransform == 1 && useReversibleWavelet && (c == 1 || c == 2)) ? 1 : 0
                        let compRangePrecision = precision + rctAdjust
                        for resolution in geometry.resolutions {
                            for band in resolution.bands {
                                let qIdx = band.quantizationIndex
                                let eps = expandedQCD.exponents[qIdx]
                                let mu = qIdx < expandedQCD.mantissas.count ? expandedQCD.mantissas[qIdx] : 0
                                let step = expandedQCD.style == .none
                                    ? 1.0
                                    : Quantization.stepSize(exponent: eps, mantissa: mu, precision: compRangePrecision, gain: band.gain)
                                let invStep = 1.0 / step
                                let mb = max(1, expandedQCD.guardBits + eps - 1)
                                let maxMag = (Int64(1) << mb) - 1
                                for row in 0..<band.height {
                                    let rBase = (band.planeY + row) * tw + band.planeX
                                    for col in 0..<band.width {
                                        let val = doublePlanes[c][rBase + col]
                                        let qMag = min(maxMag, Int64(floor(abs(val) * invStep)))
                                        quantisedPlanes[c][rBase + col] = val < 0 ? -qMag : qMag
                                    }
                                }
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
                                    let maxShiftedMag = (Int64(1) << min(61, mb + roiShift)) - 1
                                    for sy in bounds.y0..<bounds.y1 {
                                        let rowIdx = (band.planeY + (sy - band.y0)) * tw + band.planeX + (bounds.x0 - band.x0)
                                        for offset in 0..<(bounds.x1 - bounds.x0) {
                                            let v = quantisedPlanes[c][rowIdx + offset]
                                            guard v != 0 else { continue }
                                            let mag = v < 0 ? -v : v
                                            let shifted = min(maxShiftedMag, mag << roiShift)
                                            quantisedPlanes[c][rowIdx + offset] = v < 0 ? -shifted : shifted
                                        }
                                    }
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

                // Encode all code-blocks of all components in this tile:
                var encodings: [[[[[CodeBlockEncoding]]]]] = []
                encodings.reserveCapacity(componentCount)
                var flatCoords: [(c: Int, r: Int, p: Int, b: Int, k: Int, coeffs: [Int64], width: Int, height: Int, orientation: BandOrientation, mb: Int)] = []

                for c in 0..<componentCount {
                    let rctAdjust = (componentTransform == 1 && useReversibleWavelet && (c == 1 || c == 2)) ? 1 : 0
                    let compRangePrecision = precision + rctAdjust
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
                                let weight = nb == 0 ? 1.0 : Quantization.synthesisWeight(
                                    orientation: band.orientation, decompositionLevel: nb, reversible: useReversibleWavelet
                                )
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
                                    if isHT {
                                        let coeffs32 = blockCoeffs.map { Int32(clamping: $0) }
                                        let coded = try HTBlockEncoder.encodeCleanup(
                                            coefficients: coeffs32,
                                            width: block.width,
                                            height: block.height,
                                            bandShift: 0
                                        )
                                        enc = CodeBlockEncoding(
                                            data: coded,
                                            passCount: coded.isEmpty ? 0 : 1,
                                            zeroBitPlanes: coded.isEmpty ? mb : (mb - 1)
                                        )
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
                                        flatCoords.append((c, rIdx, pIdx, bIdx, kIdx, blockCoeffs, block.width, block.height, band.orientation, mb))
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
        var out = ByteWriter(capacity: 128 + totalTileBytes)
        out.writeUInt16(Marker.soc)

        let compSignallings = [ComponentSignalling](
            repeating: ComponentSignalling(
                precision: precision,
                signed: signed,
                horizontalSeparation: 1,
                verticalSeparation: 1
            ),
            count: componentCount
        )
        let sizeSeg = ImageSizeSegment(
            capabilities: isHT ? 0x4000 : 0,
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
            let cap = try ExtendedCapabilitiesSegment.losslessHTOnly(for: mainQCD)
            try CodestreamSyntax.writeCAP(cap, into: &out)
        }
        try CodestreamSyntax.writeCOD(cod, into: &out)
        try CodestreamSyntax.writeQCD(mainQCD, into: &out)

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
}
