// SPDX-License-Identifier: Apache-2.0
//
// Adapted from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   Sources/J2KFileFormat/J2KFileFormat.swift
//   Sources/J2KFileFormat/J2KDecoder+FileFormatSupport.swift
//   Sources/J2KFileFormat/J2KEncoder+FileFormatSupport.swift
//
// Changes for the SwiftJ2K contract:
// - Validates and reconciles the JP2 header superbox ('jp2h': ihdr, bpcc, colr,
//   pclr, cmap, cdef, res ) against the codestream SIZ marker on inspect/decode.
// - Applies palette expansion ('pclr' + 'cmap'), channel definitions ('cdef'
//   straight/premultiplied alpha and channel association ordering), colour
//   specifications ('colr' enumerated colourspaces and ICC profiles), and
//   resolution metadata ('res '/'resc'/'resd').
// - Enforces ResourceLimits.maximumMetadataBytes, maximumICCBytes, and
//   maximumNestingDepth across container boxes and codestream COM segments,
//   and implements MetadataPolicy.preserve vs MetadataPolicy.discardAncillary.

import Foundation

struct JP2ParsedContainer: Sendable {
    let format: String // "jp2", "jph", or "jpx"
    let fileType: JP2FileTypeBox
    let readerRequirements: JP2ReaderRequirementsBox?
    let header: JP2HeaderSuperbox
    let codestreamRange: Range<Int>
    let metadataEntries: [String: Data]
    let totalMetadataBytes: Int
    let discardedCount: Int
    let discardedBytes: Int
    let discardedKinds: [String]
}

enum JP2Container {
    static let jp2Format = "jp2"
    static let jphFormat = "jph"
    static let jpxFormat = "jpx"

    /// Returns `true` if `bytes` begins with a JPEG 2000 Signature box (`'jP  '`).
    static func isContainer(_ bytes: [UInt8]) -> Bool {
        if bytes.count >= 12 && Array(bytes[0..<12]) == JP2SignatureBox.fullBoxBytes {
            return true
        }
        if bytes.count >= 8 {
            let tbox = JP2BoxReader.readUInt32(bytes, at: 4)
            if JP2BoxType(rawValue: tbox) == .signature {
                return true
            }
        }
        return false
    }

    // MARK: - Container Parsing

    static func parse(
        _ bytes: [UInt8],
        limits: ResourceLimits,
        metadataPolicy: MetadataPolicy
    ) throws -> JP2ParsedContainer {
        var reader = try JP2BoxReader(bytes: bytes, depth: 1, limits: limits)

        // 1. First box MUST be the JPEG 2000 Signature box ('jP  ')
        guard let sigSlice = try reader.nextBox(), sigSlice.type == .signature else {
            throw CodecError(.malformedInput, "Container does not start with a JPEG 2000 Signature box ('jP  ').")
        }
        try JP2SignatureBox.validate(bytes: bytes, range: sigSlice.payloadRange)

        // 2. Second box MUST be the File Type box ('ftyp') (ISO/IEC 15444-1 I.5.2)
        guard let ftypSlice = try reader.nextBox(), ftypSlice.type == .fileType else {
            throw CodecError(.malformedInput, "File Type box ('ftyp') must immediately follow the signature box.")
        }
        let fileType = try JP2FileTypeBox.parse(bytes: bytes, range: ftypSlice.payloadRange)
        let format = try fileType.resolvedFormat()

        var rreq: JP2ReaderRequirementsBox?
        var header: JP2HeaderSuperbox?
        var codestreamRange: Range<Int>?

        var runningMetadataBytes = 0
        var preservedEntries: [String: Data] = [:]
        var discardedCount = 0
        var discardedBytes = 0
        var discardedKinds: [String] = []
        var kindCounters: [String: Int] = [:]

        func recordAncillary(kind: String, payloadRange: Range<Int>) throws {
            let len = payloadRange.count
            runningMetadataBytes = try checkedAdd(runningMetadataBytes, len)
            guard runningMetadataBytes <= limits.maximumMetadataBytes else {
                throw CodecError(.resourceLimitExceeded, "Container metadata (\(runningMetadataBytes) bytes) exceeds maximumMetadataBytes (\(limits.maximumMetadataBytes)).")
            }
            if metadataPolicy == .preserve {
                let count = kindCounters[kind, default: 0]
                kindCounters[kind] = count + 1
                let key = (count == 0) ? kind : "\(kind).\(count)"
                preservedEntries[key] = Data(bytes[payloadRange])
            } else {
                discardedCount += 1
                discardedBytes = try checkedAdd(discardedBytes, len)
                if !discardedKinds.contains(kind) {
                    discardedKinds.append(kind)
                }
            }
        }

        while let box = try reader.nextBox() {
            switch box.type {
            case .signature, .fileType:
                throw CodecError(.malformedInput, "Duplicate '\(box.type)' box at offset \(box.headerOffset).")

            case .readerRequirements:
                guard rreq == nil else {
                    throw CodecError(.malformedInput, "Duplicate 'rreq' box in container.")
                }
                guard header == nil else {
                    throw CodecError(.malformedInput, "'rreq' box must precede 'jp2h'.")
                }
                let parsedRreq = try JP2ReaderRequirementsBox.parse(bytes: bytes, range: box.payloadRange)
                rreq = parsedRreq
                if metadataPolicy == .preserve {
                    preservedEntries["rreq"] = Data(bytes[box.payloadRange])
                }

            case .jp2Header:
                guard header == nil else {
                    throw CodecError(.malformedInput, "Duplicate 'jp2h' superbox in container.")
                }
                guard codestreamRange == nil else {
                    throw CodecError(.malformedInput, "'jp2h' superbox must precede 'jp2c' codestream box.")
                }
                var hdrReader = try reader.childReader(for: box)
                let parsedHeader = try JP2HeaderSuperbox.parse(
                    reader: &hdrReader,
                    limits: limits,
                    runningMetadataBytes: &runningMetadataBytes
                )
                header = parsedHeader
                if let res = parsedHeader.resolution, metadataPolicy == .preserve {
                    preservedEntries["res"] = Data( try res.serialise() )
                }

            case .contiguousCodestream:
                guard header != nil else {
                    throw CodecError(.malformedInput, "Contiguous codestream box ('jp2c') encountered before 'jp2h'.")
                }
                guard !box.payloadRange.isEmpty else {
                    throw CodecError(.malformedInput, "Contiguous codestream box ('jp2c') is empty.")
                }
                if codestreamRange != nil {
                    if format == jp2Format || format == jphFormat {
                        throw CodecError(
                            .malformedInput,
                            "Duplicate 'jp2c' contiguous codestream box is invalid in \(format.uppercased()) containers."
                        )
                    } else {
                        throw CodecError(
                            .unsupportedFeature,
                            "Multiple 'jp2c' contiguous codestream boxes in JPX containers are not supported."
                        )
                    }
                }
                codestreamRange = box.payloadRange

            case .xml:
                try recordAncillary(kind: "xml", payloadRange: box.payloadRange)

            case .uuid:
                try JP2AncillaryMetadataValidator.validateUUID(bytes: bytes, range: box.payloadRange)
                try recordAncillary(kind: "uuid", payloadRange: box.payloadRange)

            case .uuidInfo:
                var uinfReader = try reader.childReader(for: box)
                try JP2AncillaryMetadataValidator.validateUUIDInfo(reader: &uinfReader)
                try recordAncillary(kind: "uinf", payloadRange: box.payloadRange)

            case .ipr:
                try recordAncillary(kind: "jp2i", payloadRange: box.payloadRange)

            case .association:
                var asocReader = try reader.childReader(for: box)
                try JP2AncillaryMetadataValidator.validateAssociation(reader: &asocReader)
                try recordAncillary(kind: "asoc", payloadRange: box.payloadRange)

            case .label:
                try recordAncillary(kind: "lbl", payloadRange: box.payloadRange)

            case .codestreamHeader, .compositingLayerHdr, .colourGroup:
                if !box.payloadRange.isEmpty {
                    var subReader = try reader.childReader(for: box)
                    while let _ = try subReader.nextBox() {}
                }

            case .free:
                break

            default:
                // Unknown box: enforce metadata ceiling conservatively.
                try recordAncillary(kind: box.type.fourCC, payloadRange: box.payloadRange)
            }
        }

        if fileType.brand == JP2FileTypeBox.brandJPX && rreq == nil {
            throw CodecError(.malformedInput, "JPX container ('jpx ' brand) is missing required Reader Requirements ('rreq') box.")
        }
        guard let validHeader = header else {
            throw CodecError(.malformedInput, "Container is missing required JP2 Header ('jp2h') superbox.")
        }
        guard let validCodestreamRange = codestreamRange else {
            throw CodecError(.malformedInput, "Container is missing required Contiguous Codestream ('jp2c') box.")
        }

        return JP2ParsedContainer(
            format: format,
            fileType: fileType,
            readerRequirements: rreq,
            header: validHeader,
            codestreamRange: validCodestreamRange,
            metadataEntries: preservedEntries,
            totalMetadataBytes: runningMetadataBytes,
            discardedCount: discardedCount,
            discardedBytes: discardedBytes,
            discardedKinds: discardedKinds
        )
    }

    // MARK: - Container Inspection & Reconciliation with Codestream SIZ

    struct ReconciledContainerProfile: Sendable {
        let container: JP2ParsedContainer
        let codestreamBytes: [UInt8]
        let part1Profile: Part1Profile
        let outputDescriptor: ImageDescriptor
        let combinedMetadata: ImageMetadata
        /// For palettised images, maps each output channel (`0..<outputChannels`) from codestream component & palette column.
        let paletteMapping: (palette: JP2PaletteBox, cmap: JP2ComponentMappingBox)?
        /// For `cdef` reordered channels, `channelPermutation[outputChannel] = sourceChannel`.
        let channelPermutation: [Int]?
        let discardedMetadataCount: Int
        let discardedMetadataBytes: Int
        let discardedMetadataKinds: [String]
    }

    static func inspectReconciled(
        _ bytes: [UInt8],
        limits: ResourceLimits,
        metadataPolicy: MetadataPolicy
    ) throws -> ReconciledContainerProfile {
        let container = try parse(bytes, limits: limits, metadataPolicy: metadataPolicy)
        if let rreq = container.readerRequirements {
            let eval = rreq.evaluate()
            if !eval.canDecodeCompletely {
                let codes = eval.unsupportedRequiredFeatures.map(String.init).joined(separator: ", ")
                let detail = codes.isEmpty
                    ? String(format: "unsatisfied DCM mask 0x%llx", eval.unsatisfiedDecodeMask)
                    : "unsupported required standard feature(s) [\(codes)]"
                throw CodecError(
                    .unsupportedFeature,
                    "Container Reader Requirements ('rreq') cannot be satisfied: \(detail)."
                )
            }
        }
        let csBytes = Array(bytes[container.codestreamRange])

        // Parse codestream syntax first to reconcile SIZ against ihdr/bpcc before checking unsupported features.
        let syntax = try CodestreamSyntax.parse(csBytes, limits: limits, metadataPolicy: metadataPolicy)
        let siz = syntax.size
        let ihdr = container.header.imageHeader

        let sizWidth = siz.width - siz.originX
        let sizHeight = siz.height - siz.originY
        guard Int(ihdr.width) == sizWidth && Int(ihdr.height) == sizHeight else {
            throw CodecError(
                .malformedInput,
                "Container 'ihdr' dimensions (\(ihdr.width)x\(ihdr.height)) do not match codestream SIZ (\(sizWidth)x\(sizHeight))."
            )
        }
        guard Int(ihdr.numComponents) == siz.components.count else {
            throw CodecError(
                .malformedInput,
                "Container 'ihdr' component count (\(ihdr.numComponents)) does not match codestream SIZ (\(siz.components.count))."
            )
        }

        for (index, comp) in siz.components.enumerated() {
            let expected: JP2ComponentBitDepth
            if let bpcc = container.header.bitsPerComponent {
                expected = bpcc.components[index]
            } else if let uniform = ihdr.uniformBitDepth {
                expected = uniform
            } else {
                throw CodecError(.malformedInput, "Container 'ihdr' specifies BPC=0xFF without 'bpcc' box.")
            }
            guard expected.bitDepth == comp.precision && expected.isSigned == comp.signed else {
                throw CodecError(
                    .malformedInput,
                    "Container bit-depth/sign (\(expected.bitDepth)-bit, signed=\(expected.isSigned)) for component \(index) disagrees with codestream SIZ (\(comp.precision)-bit, signed=\(comp.signed))."
                )
            }
        }

        // Enforce combined container + codestream COM metadata ceiling.
        let totalMeta = try checkedAdd(container.totalMetadataBytes, syntax.commentPayloadBytes)
        guard totalMeta <= limits.maximumMetadataBytes else {
            throw CodecError(
                .resourceLimitExceeded,
                "Combined container and codestream metadata (\(totalMeta) bytes) exceeds maximumMetadataBytes (\(limits.maximumMetadataBytes))."
            )
        }

        let part1 = try Part1Pipeline.inspect(csBytes, limits: limits, metadataPolicy: metadataPolicy)

        // Extract ICC profile and colour interpretation from 'colr' boxes.
        var iccProfile: Data?
        var enumColourSpace: UInt32?
        for colr in container.header.colourSpecifications {
            switch colr.method {
            case .enumerated(let cs):
                if enumColourSpace == nil { enumColourSpace = cs }
            case .restrictedICC(let data), .anyICC(let data):
                if iccProfile == nil { iccProfile = data }
            case .vendor:
                break
            }
        }

        // Determine channel count, precision, signedness, palette expansion, and cdef mapping.
        let outputComponentCount: Int
        let outputPrecision: Int
        let outputSigned: Bool
        var paletteMapping: (palette: JP2PaletteBox, cmap: JP2ComponentMappingBox)?

        if let pclr = container.header.palette, let cmap = container.header.componentMapping {
            guard !part1.signed else {
                throw CodecError(.malformedInput, "Palette index component in 'jp2c' must be unsigned.")
            }
            outputComponentCount = cmap.entries.count
            let firstEntry = cmap.entries[0]
            let firstDepth: JP2ComponentBitDepth = (firstEntry.mappingType == 1)
                ? pclr.columns[Int(firstEntry.paletteColumn)]
                : try JP2ComponentBitDepth(bitDepth: part1.precision, isSigned: part1.signed)
            guard firstDepth.bitDepth >= 1 && firstDepth.bitDepth <= 16 else {
                throw CodecError(.unsupportedFeature, "Palette column precision above 16 bits is not supported.")
            }
            for entry in cmap.entries {
                let depth: JP2ComponentBitDepth = (entry.mappingType == 1)
                    ? pclr.columns[Int(entry.paletteColumn)]
                    : try JP2ComponentBitDepth(bitDepth: part1.precision, isSigned: part1.signed)
                guard depth == firstDepth else {
                    throw CodecError(.unsupportedFeature, "Heterogeneous palette column precision or signedness is not supported.")
                }
            }
            outputPrecision = firstDepth.bitDepth
            outputSigned = firstDepth.isSigned
            paletteMapping = (pclr, cmap)
        } else {
            outputComponentCount = part1.componentCount
            outputPrecision = part1.precision
            outputSigned = part1.signed
        }

        // Apply Channel Definition ('cdef') roles, alpha mode, and channel permutation.
        var alphaMode: AlphaInterpretation = .absent
        var channelPermutation: [Int]?

        if let cdef = container.header.channelDefinition {
            for entry in cdef.entries {
                guard Int(entry.channelIndex) < outputComponentCount else {
                    throw CodecError(.malformedInput, "JP2 'cdef' references channel \(entry.channelIndex) >= \(outputComponentCount).")
                }
                if entry.channelType == 1 {
                    alphaMode = .straight
                } else if entry.channelType == 2 {
                    alphaMode = .premultiplied
                }
            }
            // Build permutation to canonical order (Asoc 1, 2, 3 colour channels, then Typ 1/2 alpha channel).
            if outputComponentCount == 3 || outputComponentCount == 4 {
                var perm = [Int](repeating: -1, count: outputComponentCount)
                for entry in cdef.entries {
                    let cn = Int(entry.channelIndex)
                    if entry.channelType == 0 && entry.association >= 1 && Int(entry.association) <= 3 {
                        let targetIdx = Int(entry.association) - 1
                        if targetIdx < outputComponentCount {
                            perm[targetIdx] = cn
                        }
                    } else if (entry.channelType == 1 || entry.channelType == 2) && outputComponentCount == 4 {
                        perm[3] = cn
                    }
                }
                if !perm.contains(-1) && Set(perm).count == outputComponentCount && perm != Array(0..<outputComponentCount) {
                    channelPermutation = perm
                }
            } else if outputComponentCount == 2 && alphaMode != .absent {
                // 2-channel greyscale + alpha: ensure colour (Asoc=1) is channel 0 and opacity (Typ=1/2) is channel 1.
                var perm = [-1, -1]
                for entry in cdef.entries {
                    let cn = Int(entry.channelIndex)
                    if entry.channelType == 0 {
                        perm[0] = cn
                    } else if entry.channelType == 1 || entry.channelType == 2 {
                        perm[1] = cn
                    }
                }
                if !perm.contains(-1) && Set(perm).count == 2 && perm != [0, 1] {
                    channelPermutation = perm
                }
            }
        } else if outputComponentCount == 4 {
            alphaMode = .straight
        }

        // Determine ColourInterpretation and ComponentRoles.
        let colour: ColourInterpretation
        let roles: [ComponentRole]
        let isRGBEnum = enumColourSpace == JP2ColourSpecificationBox.EnumeratedColourSpace.sRGB.rawValue
            || enumColourSpace == JP2ColourSpecificationBox.EnumeratedColourSpace.sYCC.rawValue
            || enumColourSpace == JP2ColourSpecificationBox.EnumeratedColourSpace.eSRGB.rawValue
            || enumColourSpace == JP2ColourSpecificationBox.EnumeratedColourSpace.rommRGB.rawValue
        let isGreyEnum = enumColourSpace == JP2ColourSpecificationBox.EnumeratedColourSpace.greyscale.rawValue
            || enumColourSpace == JP2ColourSpecificationBox.EnumeratedColourSpace.bilevel1.rawValue
            || enumColourSpace == JP2ColourSpecificationBox.EnumeratedColourSpace.bilevel2.rawValue

        if outputComponentCount == 1 {
            colour = (ihdr.unknownColourspace && !isGreyEnum && iccProfile == nil) ? .unknown : .greyscale
            roles = (colour == .greyscale) ? [.grey] : [.uninterpreted("c0")]
        } else if outputComponentCount == 2 && alphaMode != .absent {
            colour = .greyscale
            roles = [.grey, .alpha]
        } else if outputComponentCount == 3 && (isRGBEnum || !ihdr.unknownColourspace || iccProfile != nil) {
            colour = .rgb
            roles = [.red, .green, .blue]
        } else if outputComponentCount == 4 && alphaMode != .absent {
            colour = .rgb
            roles = [.red, .green, .blue, .alpha]
        } else {
            colour = .unknown
            var customRoles = (0..<outputComponentCount).map { ComponentRole.uninterpreted("c\($0)") }
            if alphaMode != .absent && !customRoles.isEmpty {
                customRoles[customRoles.count - 1] = .alpha
            }
            roles = customRoles
        }

        let storageBits = (outputPrecision <= 8 && !(outputComponentCount == 1 && !outputSigned)) ? 8 : 16
        let sampleBytes = storageBits / 8
        let rowBytes = try checkedMultiply(part1.width, sampleBytes)
        let planeBytes = try checkedMultiply(rowBytes, part1.height)
        var planes: [PlaneDescriptor] = []
        planes.reserveCapacity(outputComponentCount)
        for index in 0..<outputComponentCount {
            let planeOffset = try checkedMultiply(index, planeBytes)
            let planeEnd = try checkedAdd(planeOffset, planeBytes)
            planes.append(
                try PlaneDescriptor(
                    width: part1.width,
                    height: part1.height,
                    components: [index],
                    offset: planeOffset,
                    sampleStride: sampleBytes,
                    pixelStride: sampleBytes,
                    rowBytes: rowBytes,
                    byteCount: planeEnd
                )
            )
        }

        let descriptor = try ImageDescriptor(
            width: part1.width,
            height: part1.height,
            sampleType: outputSigned ? .signedInteger : .unsignedInteger,
            storageBits: storageBits,
            meaningfulBits: outputPrecision,
            byteOrder: .littleEndian,
            components: roles,
            colour: colour,
            alpha: alphaMode,
            planes: planes,
            iccProfile: iccProfile,
            limits: limits
        )

        var discardedCount = container.discardedCount
        var discardedBytes = container.discardedBytes
        var discardedKinds = container.discardedKinds
        if metadataPolicy == .discardAncillary && part1.commentCount > 0 {
            discardedCount += part1.commentCount
            discardedBytes = try checkedAdd(discardedBytes, part1.commentPayloadBytes)
            if !discardedKinds.contains("COM") {
                discardedKinds.append("COM")
            }
        }

        let metadata = ImageMetadata(entries: container.metadataEntries)
        _ = try metadata.validate(limits: limits, additionalBytes: iccProfile?.count ?? 0)

        return ReconciledContainerProfile(
            container: container,
            codestreamBytes: csBytes,
            part1Profile: part1,
            outputDescriptor: descriptor,
            combinedMetadata: metadata,
            paletteMapping: paletteMapping,
            channelPermutation: channelPermutation,
            discardedMetadataCount: discardedCount,
            discardedMetadataBytes: discardedBytes,
            discardedMetadataKinds: discardedKinds
        )
    }

    // MARK: - Container Decoding

    static func decode(
        reconciled: ReconciledContainerProfile,
        into destination: ImageDestination,
        options: DecodeOptions,
        allocations: Int,
        maxQualityLayers: Int? = nil
    ) throws -> DecodedImage {
        let clock = ContinuousClock()
        let started = clock.now
        let resolvedBackend = try AccelerationRuntime.resolve(options.executionPolicy)
        let destDesc = destination.descriptor
        let expectedDesc = reconciled.outputDescriptor
        guard destDesc.width == expectedDesc.width,
              destDesc.height == expectedDesc.height,
              destDesc.components.count == expectedDesc.components.count,
              destDesc.sampleType == expectedDesc.sampleType,
              destDesc.meaningfulBits == expectedDesc.meaningfulBits else {
            throw CodecError(.incompatibleImageLayout, "Destination descriptor does not match container image geometry or sample precision.")
        }
        do {
            options.progress?(try ProgressUpdate(phase: .inspecting, completedUnits: 0))
            try Task.checkCancellation()
        } catch {
            destination.invalidateAfterFailure()
            throw error
        }

        let sealedImage: Image
        let peakWorkspace: Int

        let isDefaultGreyscale16 = maxQualityLayers == nil &&
            reconciled.paletteMapping == nil &&
            reconciled.channelPermutation == nil &&
            destDesc.sampleType == .unsignedInteger &&
            destDesc.storageBits == 16 &&
            destDesc.components == [.grey] &&
            destDesc.planes.count == 1 &&
            destDesc.alpha == .absent
        let rawImage: Image
        if isDefaultGreyscale16,
           let losslessProfile = try? ScalarLosslessCodec.inspect(
               reconciled.codestreamBytes,
               limits: options.resourceLimits,
               metadataPolicy: options.metadataPolicy
           ) {
            (rawImage, peakWorkspace) = try ScalarLosslessCodec.decode(
                bytes: reconciled.codestreamBytes,
                profile: losslessProfile,
                into: destination,
                limits: options.resourceLimits,
                backend: resolvedBackend.backend,
                progress: options.progress
            )
        } else {
            (rawImage, peakWorkspace) = try Part1Pipeline.decode(
                bytes: reconciled.codestreamBytes,
                profile: reconciled.part1Profile,
                into: destination,
                limits: options.resourceLimits,
                backend: resolvedBackend.backend,
                progress: options.progress,
                paletteMapping: reconciled.paletteMapping,
                channelPermutation: reconciled.channelPermutation,
                maxQualityLayers: maxQualityLayers
            )
        }
        // Attach container metadata to the sealed Image view (same underlying storage & allocationID).
        sealedImage = try Image(
            descriptor: rawImage.descriptor,
            storage: rawImage.storage,
            metadata: reconciled.combinedMetadata,
            limits: options.resourceLimits
        )

        try Task.checkCancellation()
        let elapsed = clock.now - started
        let hasReducedLayers: Bool
        if let maxLayers = maxQualityLayers {
            hasReducedLayers = reconciled.part1Profile.tiles.contains { maxLayers < $0.defaultCodingStyle.layers }
        } else {
            hasReducedLayers = false
        }
        let fidelity: Fidelity = (reconciled.part1Profile.isReversibleLossless && !hasReducedLayers) ? .exactSamples : .lossy
        let report = OperationReport(
            backend: resolvedBackend.backend,
            fallbackReason: resolvedBackend.fallbackReason,
            fidelity: fidelity,
            copyEvents: [],
            pixelAllocationCount: allocations,
            peakPixelBytes: sealedImage.storage.byteCount,
            peakWorkspaceBytes: peakWorkspace,
            elapsedSeconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            discardedMetadataCount: (options.metadataPolicy == .discardAncillary) ? reconciled.discardedMetadataCount : nil,
            discardedMetadataBytes: (options.metadataPolicy == .discardAncillary) ? reconciled.discardedMetadataBytes : nil,
            discardedMetadataKinds: (options.metadataPolicy == .discardAncillary) ? reconciled.discardedMetadataKinds : []
        )
        options.progress?(try ProgressUpdate(phase: .completed, completedUnits: 1, totalUnits: 1))
        try Task.checkCancellation()
        return DecodedImage(image: sealedImage, report: report)
    }

    // MARK: - Container Wrapping (Encode / Transcode)

    struct WrappedContainerResult: Sendable {
        let bytes: [UInt8]
        let format: String
        let discardedMetadataCount: Int
        let discardedMetadataBytes: Int
        let discardedMetadataKinds: [String]
    }

    static func wrap(
        codestream: [UInt8],
        descriptor: ImageDescriptor,
        metadata: ImageMetadata,
        containerFormat: CodecOptions.ContainerFormat,
        isLossless: Bool,
        isHTJ2K: Bool,
        captureResolution: JP2GridResolution?,
        displayResolution: JP2GridResolution?,
        metadataPolicy: MetadataPolicy,
        limits: ResourceLimits
    ) throws -> WrappedContainerResult {
        // Validate ICC and metadata limits before constructing boxes.
        let iccBytes = descriptor.iccProfile?.count ?? 0
        guard iccBytes <= limits.maximumICCBytes else {
            throw CodecError(.resourceLimitExceeded, "ICC profile (\(iccBytes) bytes) exceeds maximumICCBytes (\(limits.maximumICCBytes)).")
        }
        _ = try metadata.validate(limits: limits, additionalBytes: iccBytes)

        if metadataPolicy == .discardAncillary && !metadata.requiredKeys.isEmpty {
            // Required keys cannot be silently discarded if they are ancillary.
            for req in metadata.requiredKeys {
                if ["xml", "uuid", "uinf", "jp2i", "asoc", "lbl"].contains(req) {
                    throw CodecError(.unsupportedFeature, "Required metadata key '\(req)' cannot be discarded under MetadataPolicy.discardAncillary.")
                }
            }
        }

        var writer = JP2BoxWriter(capacity: codestream.count + 256)

        // 1. Signature box ('jP  ')
        try writer.appendBox(type: .signature, payload: JP2SignatureBox.expectedPayload)

        // 2. File Type box ('ftyp')
        let ftyp: JP2FileTypeBox
        let formatName: String
        switch containerFormat {
        case .jp2:
            ftyp = try JP2FileTypeBox(
                brand: JP2FileTypeBox.brandJP2,
                minorVersion: 0,
                compatibleBrands: [JP2FileTypeBox.brandJP2]
            )
            formatName = jp2Format
        case .jph:
            ftyp = try JP2FileTypeBox(
                brand: JP2FileTypeBox.brandJPH,
                minorVersion: 0,
                compatibleBrands: [JP2FileTypeBox.brandJPH, JP2FileTypeBox.brandJP2]
            )
            formatName = jphFormat
        case .jpx:
            var cl = [JP2FileTypeBox.brandJPX, JP2FileTypeBox.brandJPXB]
            if !isHTJ2K {
                cl.insert(JP2FileTypeBox.brandJP2, at: 1)
            }
            ftyp = try JP2FileTypeBox(
                brand: JP2FileTypeBox.brandJPX,
                minorVersion: 0,
                compatibleBrands: cl
            )
            formatName = jpxFormat
        case .codestream:
            throw CodecError(.internalFailure, "JP2Container.wrap called with .codestream.")
        }
        try writer.appendBox(type: .fileType, payload: ftyp.serialise())

        // 3. Reader Requirements box ('rreq') for JPX (or if supplied in metadata)
        if containerFormat == .jpx {
            let rreqPayload: [UInt8]
            if metadataPolicy == .preserve,
               let customRreq = metadata.entries["rreq"],
               let parsed = try? JP2ReaderRequirementsBox.parse(bytes: [UInt8](customRreq), range: 0..<customRreq.count),
               parsed.standardFeatures.contains(where: { $0.knownFeature == .htj2kCodestream }) == isHTJ2K,
               parsed.evaluate().canDecodeCompletely {
                rreqPayload = parsed.serialise()
            } else {
                let defaultRreq = try JP2ReaderRequirementsBox.defaultJPX(
                    isLossless: isLossless,
                    isHTJ2K: isHTJ2K,
                    colour: descriptor.colour,
                    hasAlpha: descriptor.alpha != .absent,
                    isPremultipliedAlpha: descriptor.alpha == .premultiplied,
                    hasRestrictedICC: descriptor.iccProfile != nil
                )
                rreqPayload = defaultRreq.serialise()
            }
            try writer.appendBox(type: .readerRequirements, payload: rreqPayload)
        }

        // 4. JP2 Header superbox ('jp2h')
        let compDepth = try JP2ComponentBitDepth(
            bitDepth: descriptor.meaningfulBits,
            isSigned: descriptor.sampleType == .signedInteger
        )
        let hasIPR = (metadataPolicy == .preserve) && (metadata.entries["jp2i"] != nil)
        let ihdr = try JP2ImageHeaderBox(
            height: UInt32(descriptor.height),
            width: UInt32(descriptor.width),
            numComponents: UInt16(descriptor.components.count),
            uniformBitDepth: compDepth,
            compressionType: 7,
            unknownColourspace: descriptor.colour == .unknown && descriptor.iccProfile == nil,
            hasIntellectualProperty: hasIPR
        )

        var colrBoxes: [JP2ColourSpecificationBox] = []
        if let icc = descriptor.iccProfile {
            colrBoxes.append(try JP2ColourSpecificationBox(method: .restrictedICC(icc), precedence: 0, approximation: 0))
        }
        if descriptor.colour == .rgb {
            colrBoxes.append(try JP2ColourSpecificationBox(
                method: .enumerated(JP2ColourSpecificationBox.EnumeratedColourSpace.sRGB.rawValue),
                precedence: 0,
                approximation: 0
            ))
        } else if descriptor.colour == .greyscale || colrBoxes.isEmpty {
            colrBoxes.append(try JP2ColourSpecificationBox(
                method: .enumerated(JP2ColourSpecificationBox.EnumeratedColourSpace.greyscale.rawValue),
                precedence: 0,
                approximation: 0
            ))
        }

        // Channel Definition ('cdef') when alpha is present
        var cdefBox: JP2ChannelDefinitionBox?
        if descriptor.alpha != .absent {
            let alphaType: UInt16 = (descriptor.alpha == .premultiplied) ? 2 : 1
            var entries: [JP2ChannelDefinitionBox.Entry] = []
            for (idx, role) in descriptor.components.enumerated() {
                let cn = UInt16(idx)
                switch role {
                case .grey, .red:
                    entries.append(.init(channelIndex: cn, channelType: 0, association: 1))
                case .green:
                    entries.append(.init(channelIndex: cn, channelType: 0, association: 2))
                case .blue:
                    entries.append(.init(channelIndex: cn, channelType: 0, association: 3))
                case .alpha:
                    entries.append(.init(channelIndex: cn, channelType: alphaType, association: 0))
                case .uninterpreted:
                    entries.append(.init(channelIndex: cn, channelType: 0xFFFF, association: 0xFFFF))
                }
            }
            cdefBox = try JP2ChannelDefinitionBox(entries: entries)
        }

        // Resolution superbox ('res ')
        var resBox: JP2ResolutionBox?
        if captureResolution != nil || displayResolution != nil {
            resBox = try JP2ResolutionBox(capture: captureResolution, display: displayResolution)
        } else if metadataPolicy == .preserve, let rawRes = metadata.entries["res"] {
            let rawBytes = [UInt8](rawRes)
            var resReader = try JP2BoxReader(bytes: rawBytes, depth: 2, limits: limits)
            resBox = try JP2ResolutionBox.parse(reader: &resReader)
        }

        let jp2h = try JP2HeaderSuperbox(
            imageHeader: ihdr,
            bitsPerComponent: nil,
            colourSpecifications: colrBoxes,
            palette: nil,
            componentMapping: nil,
            channelDefinition: cdefBox,
            resolution: resBox
        )
        try writer.appendBox(type: .jp2Header, payload: try jp2h.serialise())

        // 5. Ancillary metadata boxes ('xml ', 'uuid', 'uinf', 'jp2i', 'asoc', 'lbl ')
        var discardedCount = 0
        var discardedBytes = 0
        var discardedKinds: [String] = []

        for key in metadata.entries.keys.sorted() {
            guard key != "rreq" && key != "res" else { continue }
            guard let payloadData = metadata.entries[key] else { continue }
            let baseKey = key.split(separator: ".").first.map(String.init) ?? key
            let boxType: JP2BoxType?
            switch baseKey {
            case "xml", "xml ":   boxType = .xml
            case "uuid":          boxType = .uuid
            case "uinf":          boxType = .uuidInfo
            case "jp2i":          boxType = .ipr
            case "asoc":          boxType = .association
            case "lbl", "lbl ":   boxType = .label
            default:              boxType = JP2BoxType(fourCC: baseKey)
            }
            guard let validType = boxType else { continue }

            let payloadBytes = [UInt8](payloadData)
            if validType == .uuid {
                try JP2AncillaryMetadataValidator.validateUUID(bytes: payloadBytes, range: 0..<payloadBytes.count)
            } else if validType == .uuidInfo {
                var r = try JP2BoxReader(bytes: payloadBytes, depth: 2, limits: limits)
                try JP2AncillaryMetadataValidator.validateUUIDInfo(reader: &r)
            } else if validType == .association {
                var r = try JP2BoxReader(bytes: payloadBytes, depth: 2, limits: limits)
                try JP2AncillaryMetadataValidator.validateAssociation(reader: &r)
            }

            if metadataPolicy == .preserve {
                try writer.appendBox(type: validType, payload: payloadBytes)
            } else {
                discardedCount += 1
                discardedBytes = try checkedAdd(discardedBytes, payloadBytes.count)
                if !discardedKinds.contains(baseKey) {
                    discardedKinds.append(baseKey)
                }
            }
        }

        // 6. Contiguous Codestream box ('jp2c')
        try writer.appendBox(type: .contiguousCodestream, payload: codestream)

        guard writer.bytes.count <= limits.maximumCompressedBytes else {
            throw CodecError(.resourceLimitExceeded, "Container output (\(writer.bytes.count) bytes) exceeds maximumCompressedBytes (\(limits.maximumCompressedBytes)).")
        }

        return WrappedContainerResult(
            bytes: writer.bytes,
            format: formatName,
            discardedMetadataCount: discardedCount,
            discardedMetadataBytes: discardedBytes,
            discardedMetadataKinds: discardedKinds
        )
    }

    /// Re-wraps a transcoded codestream inside its original parsed container header
    /// (`ihdr`, `bpcc`, `colr`, `pclr`, `cmap`, `cdef`, `res `) and ancillary metadata boxes,
    /// updating `ftyp` (`jp2 ` <-> `jph `, or `jpx ` with updated `rreq`) to match `targetIsHT`.
    static func rewrapPreservingHeader(
        reconciled: ReconciledContainerProfile,
        codestream: [UInt8],
        targetIsHT: Bool,
        limits: ResourceLimits
    ) throws -> [UInt8] {
        var writer = JP2BoxWriter(capacity: codestream.count + 256)
        try writer.appendBox(type: .signature, payload: JP2SignatureBox.expectedPayload)

        let sourceFormat = reconciled.container.format
        let ftyp: JP2FileTypeBox
        if sourceFormat == jpxFormat {
            var cl = [JP2FileTypeBox.brandJPX, JP2FileTypeBox.brandJPXB]
            if !targetIsHT {
                cl.insert(JP2FileTypeBox.brandJP2, at: 1)
            }
            ftyp = try JP2FileTypeBox(
                brand: JP2FileTypeBox.brandJPX,
                minorVersion: reconciled.container.fileType.minorVersion,
                compatibleBrands: cl
            )
        } else if targetIsHT {
            ftyp = try JP2FileTypeBox(
                brand: JP2FileTypeBox.brandJPH,
                minorVersion: 0,
                compatibleBrands: [JP2FileTypeBox.brandJPH, JP2FileTypeBox.brandJP2]
            )
        } else {
            ftyp = try JP2FileTypeBox(
                brand: JP2FileTypeBox.brandJP2,
                minorVersion: 0,
                compatibleBrands: [JP2FileTypeBox.brandJP2]
            )
        }
        try writer.appendBox(type: .fileType, payload: ftyp.serialise())

        if sourceFormat == jpxFormat {
            let desc = reconciled.outputDescriptor
            let rreq = try JP2ReaderRequirementsBox.defaultJPX(
                isLossless: reconciled.part1Profile.isReversibleLossless,
                isHTJ2K: targetIsHT,
                colour: desc.colour,
                hasAlpha: desc.alpha != .absent,
                isPremultipliedAlpha: desc.alpha == .premultiplied,
                hasRestrictedICC: desc.iccProfile != nil
            )
            try writer.appendBox(type: .readerRequirements, payload: rreq.serialise())
        }

        try writer.appendBox(type: .jp2Header, payload: try reconciled.container.header.serialise())

        for key in reconciled.container.metadataEntries.keys.sorted() {
            guard key != "rreq" && key != "res" else { continue }
            guard let payloadData = reconciled.container.metadataEntries[key] else { continue }
            let baseKey = key.split(separator: ".").first.map(String.init) ?? key
            let boxType: JP2BoxType?
            switch baseKey {
            case "xml", "xml ":   boxType = .xml
            case "uuid":          boxType = .uuid
            case "uinf":          boxType = .uuidInfo
            case "jp2i":          boxType = .ipr
            case "asoc":          boxType = .association
            case "lbl", "lbl ":   boxType = .label
            default:              boxType = JP2BoxType(fourCC: baseKey)
            }
            if let validType = boxType {
                try writer.appendBox(type: validType, payload: [UInt8](payloadData))
            }
        }

        try writer.appendBox(type: .contiguousCodestream, payload: codestream)
        guard writer.bytes.count <= limits.maximumCompressedBytes else {
            throw CodecError(.resourceLimitExceeded, "Container output (\(writer.bytes.count) bytes) exceeds maximumCompressedBytes (\(limits.maximumCompressedBytes)).")
        }
        return writer.bytes
    }
}
