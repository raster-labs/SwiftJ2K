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
        /// Owned codestream copy and retained container metadata, excluding the caller input.
        let containerWorkspaceBytes: Int
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
            if !eval.canDecodeCompletely
                && !permitsBaselineShiftedReaderRequirements(
                    bytes: bytes,
                    container: container,
                    rreq: rreq,
                    evaluation: eval,
                    limits: limits
                ) {
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
        let codestreamCopyBytes = container.codestreamRange.count
        let preliminaryContainerBytes = try checkedAdd(codestreamCopyBytes, container.totalMetadataBytes)
        guard codestreamCopyBytes <= limits.maximumWorkspaceBytes,
              try checkedAdd(bytes.count, preliminaryContainerBytes) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Container codestream and metadata copies exceed the inspection budget.")
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
                guard expectedRreqColourFeature(for: colr) != nil else {
                    throw CodecError(.unsupportedFeature, "This enumerated colour model is not supported; samples are not relabelled as RGB.")
                }
                if enumColourSpace == nil { enumColourSpace = cs }
            case .restrictedICC(let data), .anyICC(let data):
                if iccProfile == nil { iccProfile = data }
            case .vendor:
                throw CodecError(.unsupportedFeature, "Vendor colour interpretation cannot be discarded or inferred from channel count.")
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

        // Resolve colour channels from the declared model; channel count never invents alpha.
        let effectiveEnum = ihdr.unknownColourspace ? nil : enumColourSpace
        let modelRoles: [ComponentRole]
        let colour: ColourInterpretation
        if effectiveEnum == JP2ColourSpecificationBox.EnumeratedColourSpace.sRGB.rawValue {
            colour = .rgb
            modelRoles = [.red, .green, .blue]
        } else if effectiveEnum == JP2ColourSpecificationBox.EnumeratedColourSpace.greyscale.rawValue {
            colour = .greyscale
            modelRoles = [.grey]
        } else if let cs = effectiveEnum {
            colour = .unknown
            modelRoles = enumeratedColourRoles(cs, fallbackCount: outputComponentCount)
        } else if let icc = iccProfile {
            let model = try iccColourModel(icc)
            colour = model.colour
            modelRoles = model.roles
        } else {
            colour = .unknown
            modelRoles = []
        }

        var alphaMode: AlphaInterpretation = .absent
        var alphaIndex: Int?
        var sourceRoles = (0..<outputComponentCount).map { ComponentRole.uninterpreted("c\($0)") }
        var explicitChannels = Set<Int>()
        var assignedColourSlots = Set<Int>()
        if let cdef = container.header.channelDefinition {
            for entry in cdef.entries {
                let cn = Int(entry.channelIndex)
                guard cn < outputComponentCount else {
                    throw CodecError(.malformedInput, "JP2 'cdef' references an unavailable channel.")
                }
                explicitChannels.insert(cn)
                if entry.channelType == 1 || entry.channelType == 2 {
                    guard alphaIndex == nil, entry.association == 0 else {
                        throw CodecError(.unsupportedFeature, "Multiple or per-colour opacity associations cannot be represented by one image alpha interpretation.")
                    }
                    alphaIndex = cn
                    alphaMode = entry.channelType == 2 ? .premultiplied : .straight
                    sourceRoles[cn] = .alpha
                } else if entry.channelType == 0, entry.association > 0, entry.association != 0xFFFF,
                          !modelRoles.isEmpty {
                    let slot = Int(entry.association) - 1
                    guard slot < modelRoles.count, assignedColourSlots.insert(slot).inserted else {
                        throw CodecError(.malformedInput, "JP2 'cdef' has an invalid or duplicate colour association.")
                    }
                    sourceRoles[cn] = modelRoles[slot]
                }
            }
        }
        // Channels absent from cdef retain the default colour association. Explicitly unspecified
        // channels remain unspecified, even when the total count resembles grey-alpha or RGBA.
        var available = (0..<outputComponentCount).filter { !explicitChannels.contains($0) }
        for slot in modelRoles.indices where !assignedColourSlots.contains(slot) {
            guard !available.isEmpty else {
                throw CodecError(.malformedInput, "Container has fewer defined colour channels than its colour specification.")
            }
            sourceRoles[available.removeFirst()] = modelRoles[slot]
        }
        var permutation: [Int] = []
        for role in modelRoles {
            guard let index = sourceRoles.firstIndex(of: role) else {
                throw CodecError(.malformedInput, "Container colour association is incomplete.")
            }
            permutation.append(index)
        }
        let colourIndices = Set(permutation)
        permutation.append(contentsOf: (0..<outputComponentCount).filter { !colourIndices.contains($0) && $0 != alphaIndex })
        if let alphaIndex { permutation.append(alphaIndex) }
        let roles = permutation.map { sourceRoles[$0] }
        let channelPermutation: [Int]? = permutation == Array(0..<outputComponentCount) ? nil : permutation

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

        var metadataEntries = container.metadataEntries
        var requiredKeys: Set<String> = []
        let hasNativeEnumeration = effectiveEnum.map { $0 != 16 && $0 != 17 } ?? false
        if hasNativeEnumeration || (enumColourSpace == nil && iccProfile != nil) {
            // These are the standard colr payload bytes, not a private colour format. They remain
            // required even under discardAncillary, and are restored inside jp2h on encoding.
            for (index, colr) in container.header.colourSpecifications.enumerated() {
                let key = index == 0 ? "colr" : "colr.\(index)"
                metadataEntries[key] = Data(colr.serialise())
                requiredKeys.insert(key)
            }
        }
        let metadata = ImageMetadata(entries: metadataEntries, requiredKeys: requiredKeys)
        let retainedMetadataBytes = try metadata.validate(limits: limits, additionalBytes: iccProfile?.count ?? 0)
        let containerWorkspaceBytes = try checkedAdd(csBytes.count, max(container.totalMetadataBytes, retainedMetadataBytes))
        guard containerWorkspaceBytes <= limits.maximumWorkspaceBytes,
              try checkedAdd(bytes.count, containerWorkspaceBytes) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "Required container interpretation exceeds the inspection budget.")
        }

        return ReconciledContainerProfile(
            container: container,
            codestreamBytes: csBytes,
            part1Profile: part1,
            outputDescriptor: descriptor,
            combinedMetadata: metadata,
            containerWorkspaceBytes: containerWorkspaceBytes,
            paletteMapping: paletteMapping,
            channelPermutation: channelPermutation,
            discardedMetadataCount: discardedCount,
            discardedMetadataBytes: discardedBytes,
            discardedMetadataKinds: discardedKinds
        )
    }

    // MARK: - Container Decoding

    private static func containerCodecLimits(
        reconciled: ReconciledContainerProfile, limits: ResourceLimits
    ) throws -> ResourceLimits {
        try limits.reserving(
            workspaceBytes: reconciled.containerWorkspaceBytes,
            // The codec already admits its codestream input; reserve the other retained owners.
            memoryBytes: reconciled.containerWorkspaceBytes - reconciled.codestreamBytes.count
        )
    }

    private static func scalarDecodeProfile(
        reconciled: ReconciledContainerProfile, descriptor: ImageDescriptor,
        codecLimits: ResourceLimits, metadataPolicy: MetadataPolicy, maxQualityLayers: Int?
    ) -> LosslessProfile? {
        guard maxQualityLayers == nil,
              reconciled.paletteMapping == nil,
              reconciled.channelPermutation == nil,
              descriptor.sampleType == .unsignedInteger,
              descriptor.storageBits == 16,
              descriptor.components == [.grey],
              descriptor.planes.count == 1,
              descriptor.alpha == .absent else { return nil }
        return try? ScalarLosslessCodec.inspect(
            reconciled.codestreamBytes, limits: codecLimits, metadataPolicy: metadataPolicy
        )
    }

    /// Workspace for decoding into the reconciled descriptor, using the same core
    /// selection and retained-container allowance as the actual decode operation.
    static func decodeWorkspaceBytes(
        reconciled: ReconciledContainerProfile, limits: ResourceLimits,
        metadataPolicy: MetadataPolicy, maxQualityLayers: Int? = nil
    ) throws -> Int {
        let codecLimits = try containerCodecLimits(reconciled: reconciled, limits: limits)
        let coreWorkspace: Int
        if let profile = scalarDecodeProfile(
            reconciled: reconciled, descriptor: reconciled.outputDescriptor,
            codecLimits: codecLimits, metadataPolicy: metadataPolicy, maxQualityLayers: maxQualityLayers
        ) {
            coreWorkspace = try ScalarLosslessCodec.workspaceBytes(profile: profile)
        } else {
            let profile = reconciled.part1Profile
            coreWorkspace = try checkedAdd(
                try Part1Pipeline.workspaceBytes(
                    planePixels: profile.largestTilePixels, componentCount: profile.componentCount,
                    bytesPerCoeff: profile.isReversibleLossless ? 4 : 8, joinedBytes: profile.largestTileBytes
                ), profile.retainedMetadataBytes
            )
        }
        return try checkedAdd(coreWorkspace, reconciled.containerWorkspaceBytes)
    }

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

        let codecLimits = try containerCodecLimits(reconciled: reconciled, limits: options.resourceLimits)
        let sealedImage: Image
        let peakWorkspace: Int

        let rawImage: Image
        if let losslessProfile = scalarDecodeProfile(
            reconciled: reconciled, descriptor: destDesc, codecLimits: codecLimits,
            metadataPolicy: options.metadataPolicy, maxQualityLayers: maxQualityLayers
        ) {
            (rawImage, peakWorkspace) = try ScalarLosslessCodec.decode(
                bytes: reconciled.codestreamBytes,
                profile: losslessProfile,
                into: destination,
                limits: codecLimits,
                backend: resolvedBackend.backend,
                progress: options.progress
            )
        } else {
            (rawImage, peakWorkspace) = try Part1Pipeline.decode(
                bytes: reconciled.codestreamBytes,
                profile: reconciled.part1Profile,
                into: destination,
                limits: codecLimits,
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
            peakWorkspaceBytes: try checkedAdd(peakWorkspace, reconciled.containerWorkspaceBytes),
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

    /// Roles for a native enumerated model outside the shared grey/RGB enum. The numeric model
    /// and association are retained in the role name and standard colr metadata, without conversion.
    private static func enumeratedColourRoles(_ code: UInt32, fallbackCount: Int) -> [ComponentRole] {
        let count: Int
        switch JP2ColourSpecificationBox.EnumeratedColourSpace(rawValue: code) {
        case .bilevel1, .bilevel2, .greyscale: count = 1
        case .cmyk, .ycck: count = 4
        case .sRGB, .sYCC, .yCbCr1, .yCbCr2, .yCbCr3, .photoYCC, .cmy,
             .cieLab, .cieJab, .eSRGB, .rommRGB, .yPbPr1125, .yPbPr1250, .eSYCC: count = 3
        case nil: count = fallbackCount
        }
        return (0..<count).map { .uninterpreted("colr.\(code).\($0 + 1)") }
    }

    /// ICC.1 header bytes 16...19 identify the device-side model. Opaque profiles
    /// retain their exact bytes; recognizing the tuple does not perform a colour conversion.
    private static func iccColourModel(_ profile: Data) throws -> (colour: ColourInterpretation, roles: [ComponentRole]) {
        guard profile.count >= 128 else {
            throw CodecError(.malformedInput, "ICC-only colour specification has a truncated profile header.")
        }
        let signature = profile.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            String(decoding: bytes[16..<20], as: UTF8.self)
        }
        if signature == "RGB " { return (.rgb, [.red, .green, .blue]) }
        if signature == "GRAY" { return (.greyscale, [.grey]) }
        let count: Int
        switch signature {
        case "CMYK": count = 4
        case "XYZ ", "Lab ", "Luv ", "YCbr", "Yxy ", "HSV ", "HLS ", "CMY ": count = 3
        default:
            guard signature.hasSuffix("CLR"), let first = signature.first,
                  let channels = Int(String(first), radix: 16), (2...15).contains(channels) else {
                throw CodecError(.unsupportedFeature, "ICC device colour signature cannot be represented without guessing its channel tuple.")
            }
            count = channels
        }
        let name = signature.trimmingCharacters(in: .whitespaces)
        return (.unknown, (1...count).map { .uninterpreted("icc.\(name).\($0)") })
    }

    /// The complete ICC device-side tuple, excluding alpha and unspecified extras.
    static func iccComponentRoles(_ profile: Data) throws -> [ComponentRole] {
        try iccColourModel(profile).roles
    }

    private static func permitsJP2Colour(_ boxes: [JP2ColourSpecificationBox]) -> Bool {
        !boxes.isEmpty && boxes.allSatisfy { box in
            switch box.method {
            case .enumerated(let code): return [UInt32(16), 17, 18].contains(code)
            case .restrictedICC: return true
            case .anyICC, .vendor: return false
            }
        }
    }

    private static func permitsBaselineJPXColour(_ boxes: [JP2ColourSpecificationBox]) -> Bool {
        boxes.contains { box in
            switch box.method {
            case .enumerated(let code): return [UInt32(14), 16, 17, 18, 19, 20, 21, 24].contains(code)
            case .restrictedICC, .anyICC: return true
            case .vendor: return false
            }
        }
    }

    private static func colourBoxesForOutput(
        _ boxes: [JP2ColourSpecificationBox], format: CodecOptions.ContainerFormat
    ) throws -> [JP2ColourSpecificationBox] {
        guard !boxes.isEmpty else {
            throw CodecError(.unsupportedFeature, "Container output requires an explicit colour specification or ICC profile; an unknown component tuple cannot supply one.")
        }
        if format == .jp2, !permitsJP2Colour(boxes) {
            throw CodecError(.unsupportedFeature, "This colour specification requires JPX output; JP2 supports only enumerated sRGB, greyscale, sYCC and restricted ICC profiles.")
        }
        return try boxes.map {
            try JP2ColourSpecificationBox(method: $0.method, precedence: $0.precedence,
                approximation: format == .jpx ? max(1, $0.approximation) : 0)
        }
    }

    private static func retainedColourBoxes(_ metadata: ImageMetadata, limits: ResourceLimits) throws -> [JP2ColourSpecificationBox] {
        let keys = metadata.entries.keys.filter { $0 == "colr" || $0.hasPrefix("colr.") }.sorted {
            let lhs = $0 == "colr" ? 0 : (Int($0.dropFirst(5)) ?? Int.max)
            let rhs = $1 == "colr" ? 0 : (Int($1.dropFirst(5)) ?? Int.max)
            return lhs < rhs
        }
        var retainedBytes = 0
        return try keys.map { key in
            guard let payload = metadata.entries[key] else {
                throw CodecError(.invalidArgument, "Missing retained colour specification.")
            }
            let bytes = [UInt8](payload)
            return try JP2ColourSpecificationBox.parse(bytes: bytes, range: 0..<bytes.count,
                                                      limits: limits, runningMetadataBytes: &retainedBytes)
        }
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

        var colrBoxes = try retainedColourBoxes(metadata, limits: limits)
        if colrBoxes.isEmpty {
            if let icc = descriptor.iccProfile {
                let isOtherICC: Bool
                if descriptor.colour == .unknown {
                    isOtherICC = try iccColourModel(icc).colour == .unknown
                } else {
                    isOtherICC = false
                }
                colrBoxes.append(try JP2ColourSpecificationBox(method: isOtherICC ? .anyICC(icc) : .restrictedICC(icc)))
            }
            if descriptor.colour == .rgb {
                colrBoxes.append(try JP2ColourSpecificationBox(method: .enumerated(16)))
            } else if descriptor.colour == .greyscale {
                colrBoxes.append(try JP2ColourSpecificationBox(method: .enumerated(17)))
            }
        }
        // UnkC=1 does not exempt JP2/JPX from the mandatory colr box. Extended
        // enumerations and unrestricted ICC profiles retain a functional JPX route.
        colrBoxes = try colourBoxesForOutput(colrBoxes, format: containerFormat)
        let jp2Colour = permitsJP2Colour(colrBoxes)
        if descriptor.colour == .rgb || descriptor.colour == .greyscale {
            let expectedRoles: [ComponentRole] = descriptor.colour == .rgb ? [.red, .green, .blue] : [.grey]
            for box in colrBoxes {
                switch box.method {
                case .restrictedICC(let profile), .anyICC(let profile):
                    guard try iccComponentRoles(profile) == expectedRoles else {
                        throw CodecError(.unsupportedFeature, "The ICC device colour tuple conflicts with the image's explicit RGB or greyscale interpretation.")
                    }
                default: break
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
                compatibleBrands: [JP2FileTypeBox.brandJPH]
            )
            formatName = jphFormat
        case .jpx:
            var cl = [JP2FileTypeBox.brandJPX]
            if !isHTJ2K && jp2Colour { cl.append(JP2FileTypeBox.brandJP2) }
            if permitsBaselineJPXColour(colrBoxes) { cl.append(JP2FileTypeBox.brandJPXB) }
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

        let retainedICC = colrBoxes.lazy.compactMap { box -> Data? in
            switch box.method {
            case .restrictedICC(let profile), .anyICC(let profile): return profile
            default: return nil
            }
        }.first
        let colourRoles: [ComponentRole]
        if descriptor.colour == .rgb {
            colourRoles = [.red, .green, .blue]
        } else if descriptor.colour == .greyscale {
            colourRoles = [.grey]
        } else if let enumBox = colrBoxes.first(where: { if case .enumerated = $0.method { return true }; return false }),
                  case .enumerated(let code) = enumBox.method {
            colourRoles = enumeratedColourRoles(code, fallbackCount: descriptor.components.filter { $0 != .alpha }.count)
        } else if let icc = retainedICC ?? descriptor.iccProfile {
            colourRoles = try iccColourModel(icc).roles
        } else {
            colourRoles = []
        }
        guard colourRoles.allSatisfy(descriptor.components.contains) else {
            throw CodecError(.unsupportedFeature, "The selected view does not contain the complete tuple required by its colour specification.")
        }

        // 3. Reader Requirements box ('rreq') for JPX (or if supplied in metadata)
        if containerFormat == .jpx {
            let features = try colrBoxes.map { box -> JP2ReaderRequirementsBox.StandardFeature in
                guard let feature = expectedRreqColourFeature(for: box) else {
                    throw CodecError(.unsupportedFeature, "JPX requirements cannot describe this colour specification.")
                }
                return feature
            }
            let rreqPayload = try JP2ReaderRequirementsBox.defaultJPX(
                isLossless: isLossless, isHTJ2K: isHTJ2K, colour: descriptor.colour,
                hasAlpha: descriptor.alpha != .absent,
                isPremultipliedAlpha: descriptor.alpha == .premultiplied,
                hasRestrictedICC: descriptor.iccProfile != nil,
                colourFeatures: features
            ).serialise()
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
            unknownColourspace: false,
            hasIntellectualProperty: hasIPR
        )

        // cdef also distinguishes uninterpreted extras and non-canonical component ordering.
        var cdefBox: JP2ChannelDefinitionBox?
        if descriptor.alpha != .absent || descriptor.components != colourRoles {
            let alphaType: UInt16 = (descriptor.alpha == .premultiplied) ? 2 : 1
            var entries: [JP2ChannelDefinitionBox.Entry] = []
            for (idx, role) in descriptor.components.enumerated() {
                let cn = UInt16(idx)
                if let association = colourRoles.firstIndex(of: role) {
                    entries.append(.init(channelIndex: cn, channelType: 0, association: UInt16(association + 1)))
                } else if role == .alpha {
                    entries.append(.init(channelIndex: cn, channelType: alphaType, association: 0))
                } else {
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
            guard key != "rreq" && key != "res" && key != "colr" && !key.hasPrefix("colr.") else { continue }
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
        let sourceFormat = reconciled.container.format
        let outputFormat: CodecOptions.ContainerFormat = sourceFormat == jpxFormat ? .jpx : (targetIsHT ? .jph : .jp2)
        let sourceHeader = reconciled.container.header
        let outputColour = try colourBoxesForOutput(sourceHeader.colourSpecifications, format: outputFormat)
        let outputHeader = try JP2HeaderSuperbox(
            imageHeader: sourceHeader.imageHeader, bitsPerComponent: sourceHeader.bitsPerComponent,
            colourSpecifications: outputColour, palette: sourceHeader.palette,
            componentMapping: sourceHeader.componentMapping, channelDefinition: sourceHeader.channelDefinition,
            resolution: sourceHeader.resolution
        )
        var writer = JP2BoxWriter(capacity: codestream.count + 256)
        try writer.appendBox(type: .signature, payload: JP2SignatureBox.expectedPayload)

        let ftyp: JP2FileTypeBox
        if sourceFormat == jpxFormat {
            var cl = [JP2FileTypeBox.brandJPX]
            if !targetIsHT && permitsJP2Colour(outputColour) { cl.append(JP2FileTypeBox.brandJP2) }
            if permitsBaselineJPXColour(outputColour) { cl.append(JP2FileTypeBox.brandJPXB) }
            ftyp = try JP2FileTypeBox(
                brand: JP2FileTypeBox.brandJPX,
                minorVersion: reconciled.container.fileType.minorVersion,
                compatibleBrands: cl
            )
        } else if targetIsHT {
            ftyp = try JP2FileTypeBox(
                brand: JP2FileTypeBox.brandJPH,
                minorVersion: 0,
                compatibleBrands: [JP2FileTypeBox.brandJPH]
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
                hasRestrictedICC: desc.iccProfile != nil,
                colourFeatures: try outputColour.map { box in
                    guard let feature = expectedRreqColourFeature(for: box) else {
                        throw CodecError(.unsupportedFeature, "JPX requirements cannot describe this colour specification.")
                    }
                    return feature
                }
            )
            try writer.appendBox(type: .readerRequirements, payload: rreq.serialise())
        }

        try writer.appendBox(type: .jp2Header, payload: try outputHeader.serialise())

        for key in reconciled.container.metadataEntries.keys.sorted() {
            guard key != "rreq" && key != "res" && key != "colr" && !key.hasPrefix("colr.") else { continue }
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

    // MARK: - Bounded JPX 'rreq' Compatibility

    private static func expectedRreqColourFeature(
        for colr: JP2ColourSpecificationBox
    ) -> JP2ReaderRequirementsBox.StandardFeature? {
        switch colr.method {
        case .restrictedICC:
            return .restrictedICCProfile
        case .anyICC:
            return .anyICCProfile
        case .vendor:
            return nil
        case .enumerated(let cs):
            switch JP2ColourSpecificationBox.EnumeratedColourSpace(rawValue: cs) {
            case .sRGB:      return .sRGBEnumeratedColourSpace
            case .greyscale: return .greyscaleEnumeratedColourSpace
            case .bilevel1:  return .biLevel1EnumeratedColourSpace
            case .bilevel2:  return .biLevel2EnumeratedColourSpace
            case .yCbCr1:    return .yCbCr1EnumeratedColourSpace
            case .yCbCr2:    return .yCbCr2EnumeratedColourSpace
            case .yCbCr3:    return .yCbCr3EnumeratedColourSpace
            case .sYCC:      return .sYCCEnumeratedColourSpace
            case .eSRGB:     return .eSRGBEnumeratedColourSpace
            case .rommRGB:   return .rommRGBEnumeratedColourSpace
            default:         return nil
            }
        }
    }

    /// Compatibility for the complete single-codestream baseline layout exhibited by the
    /// independent Kakadu fixtures. This is deliberately separate from normative rreq evaluation.
    /// A writer comment grants no authority: actual box structure, coding, colour and opacity
    /// must fully match an exact feature set before the known disjoint-mask layout is admitted.
    private static func permitsBaselineShiftedReaderRequirements(
        bytes: [UInt8],
        container: JP2ParsedContainer,
        rreq: JP2ReaderRequirementsBox,
        evaluation: JP2ReaderRequirementsBox.SupportEvaluation,
        limits: ResourceLimits
    ) -> Bool {
        guard evaluation.understandsAllAspects, rreq.vendorFeatures.isEmpty,
              rreq.maskLength >= 2, rreq.standardFeatures.count >= 7,
              hasBaselineSingleLayerStructure(bytes, limits: limits) else { return false }

        let entries = rreq.standardFeatures
        var declared: Set<JP2ReaderRequirementsBox.StandardFeature> = []
        for entry in entries {
            guard let feature = entry.knownFeature,
                  JP2ReaderRequirementsBox.swiftJ2KSupportedFeatures.contains(feature),
                  declared.insert(feature).inserted else { return false }
        }

        // Read coding identity from the actual main header, not COM text or declared features.
        let range = container.codestreamRange
        guard range.count >= 4, bytes[range.lowerBound] == 0xFF, bytes[range.lowerBound + 1] == 0x4F else { return false }
        var pos = range.lowerBound + 2
        var hasHT = false
        var rsiz: UInt16?
        while pos + 2 <= range.upperBound {
            let marker = (UInt16(bytes[pos]) << 8) | UInt16(bytes[pos + 1])
            if marker == 0xFF90 || marker == 0xFF93 || marker == 0xFFD9 { break }
            if (0xFF30...0xFF3F).contains(marker) { pos += 2; continue }
            guard marker & 0xFF00 == 0xFF00, pos + 4 <= range.upperBound else { return false }
            let length = Int((UInt16(bytes[pos + 2]) << 8) | UInt16(bytes[pos + 3]))
            let (end, overflow) = (pos + 2).addingReportingOverflow(length)
            guard length >= 2, !overflow, end <= range.upperBound else { return false }
            let payload = pos + 4
            if marker == 0xFF51, end - payload >= 2 {
                rsiz = (UInt16(bytes[payload]) << 8) | UInt16(bytes[payload + 1])
            } else if marker == 0xFF50, end - payload >= 4 {
                let pcap = (UInt32(bytes[payload]) << 24) | (UInt32(bytes[payload + 1]) << 16)
                    | (UInt32(bytes[payload + 2]) << 8) | UInt32(bytes[payload + 3])
                hasHT = hasHT || (pcap & 0x0002_0000) != 0
            } else if marker == 0xFF52, end - payload >= 1 {
                hasHT = hasHT || (bytes[payload] & 0x40) != 0
            }
            pos = end
        }
        guard let rsiz else { return false }
        let ftyp = container.fileType
        guard ftyp.brand == JP2FileTypeBox.brandJPX else { return false }
        if hasHT {
            guard ftyp.compatibleBrands.contains(JP2FileTypeBox.brandJPH),
                  ftyp.compatibleBrands.contains("jhxb") || ftyp.compatibleBrands.contains(JP2FileTypeBox.brandJPXB) else { return false }
        } else {
            guard ftyp.compatibleBrands.contains(JP2FileTypeBox.brandJP2),
                  ftyp.compatibleBrands.contains(JP2FileTypeBox.brandJPXB) else { return false }
        }

        var expected: Set<JP2ReaderRequirementsBox.StandardFeature> = [
            .codestreamContiguous, .noCompositingRequired, .compositingLayerSingleCodestream, .noScalingRequired
        ]
        if hasHT {
            expected.insert(.htj2kCodestream)
        } else {
            guard rsiz <= 2 else { return false }
            expected.insert(.codestreamContainsNoExtensions)
            expected.insert(rsiz == 1 ? .profile0Codestream : (rsiz == 2 ? .profile1Codestream : .unrestrictedJPEG2000Part1))
        }
        let opacityEntries = container.header.channelDefinition?.entries.filter { $0.channelType == 1 || $0.channelType == 2 } ?? []
        guard opacityEntries.count <= 1, opacityEntries.allSatisfy({ $0.association == 0 }) else { return false }
        if let opacity = opacityEntries.first {
            expected.insert(opacity.channelType == 2 ? .premultipliedOpacityChannel : .opacityChannel)
        } else {
            expected.insert(.noOpacity)
        }
        guard !container.header.colourSpecifications.isEmpty else { return false }
        var colourFeatures: Set<JP2ReaderRequirementsBox.StandardFeature> = []
        for colr in container.header.colourSpecifications {
            guard let feature = expectedRreqColourFeature(for: colr) else { return false }
            colourFeatures.insert(feature)
            expected.insert(feature)
        }
        // Equality excludes extra, contradictory or invented declarations. A feature's presence
        // alone never proves the matching structure exists.
        guard declared == expected else { return false }

        let nsf = entries.count
        let bits = Int(rreq.maskLength) * 8
        let decodeClauses = nsf - max(0, colourFeatures.count - 1)
        guard decodeClauses > 0, decodeClauses < 64, nsf + decodeClauses <= bits, bits <= 64 else { return false }
        for (index, entry) in entries.enumerated() {
            guard entry.mask == UInt64(1) << (bits - 1 - index) else { return false }
        }
        guard rreq.fuam == evaluation.satisfiedMask else { return false }
        return rreq.dcm == ((UInt64(1) << decodeClauses) - 1) << (bits - nsf - decodeClauses)
    }

    /// The compatibility layout has exactly one empty codestream header and one empty layer
    /// header. Nonempty overrides, registration/scaling, compositions and unknown boxes are
    /// excluded. Ordinary normative rreq inputs do not use this compatibility path.
    private static func hasBaselineSingleLayerStructure(_ bytes: [UInt8], limits: ResourceLimits) -> Bool {
        do {
            var reader = try JP2BoxReader(bytes: bytes, limits: limits)
            var codestreamHeaders = 0
            var layerHeaders = 0
            while let box = try reader.nextBox() {
                switch box.type {
                case .codestreamHeader:
                    guard box.payloadRange.isEmpty else { return false }
                    codestreamHeaders += 1
                case .compositingLayerHdr:
                    guard box.payloadRange.isEmpty else { return false }
                    layerHeaders += 1
                case .jp2Header:
                    var header = try reader.childReader(for: box)
                    while let child = try header.nextBox() {
                        switch child.type {
                        case .imageHeader, .bitsPerComponent, .colourSpecification, .palette,
                             .componentMapping, .channelDefinition, .resolution: break
                        default: return false
                        }
                    }
                case .signature, .fileType, .readerRequirements, .contiguousCodestream,
                     .free, .xml, .uuid, .uuidInfo, .ipr, .label: break
                default: return false
                }
            }
            return codestreamHeaders == 1 && layerHeaders == 1
        } catch { return false }
    }
}
