// SPDX-License-Identifier: Apache-2.0
//
// JPIPDataBinGenerator.swift
// SwiftJ2KJPIP
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/JPIP/JPIPDataBinGenerator.swift
//
// Extended in Phase R3 (F04) with normative ITU-T Rec. T.808 (12/2022) V2 |
// ISO/IEC 15444-9 Annex A data-bin generation (`image/jpp-stream` Class 8/6/2/0
// and `image/jpt-stream` Class 8/6/4, 2D Part 1/15 and 3D Part 10 JP3D),
// ISO/IEC 15444-9 `phld` placeholder box construction/reassembly, and full
// progression-aware JPP/JPT codestream reconstruction.

import Foundation
@_exported import SwiftJ2K
@_exported import SwiftJ2K3D

/// Result of normative ITU-T Rec. T.808 wire data-bin generation for a view-window request.
public struct JPIPWireWindowGeneration: Sendable {
    /// Ordered normative data-bins for the requested view window and stream type.
    public let bins: [JPIPDataBin]
    /// Effective return media type (`jpp-stream` or `jpt-stream`).
    public let streamType: JPIPStreamType
    /// `true` when the generated window covers all components, layers, resolutions, and spatial extents.
    public let coversFullTarget: Bool

    public init(bins: [JPIPDataBin], streamType: JPIPStreamType, coversFullTarget: Bool) {
        self.bins = bins
        self.streamType = streamType
        self.coversFullTarget = coversFullTarget
    }
}

/// Generates JPIP data bins from JPEG 2000 codestream data and reconstructs
/// valid JPEG 2000 / JP2 / JP3D streams from cached JPIP data bins.
public struct JPIPDataBinGenerator: Sendable {
    /// Creates a new data bin generator.
    public init() {}

    /// Generates JPIP data bins from a JPEG 2000 file.
    public func generateDataBins(from url: URL) throws -> [JPIPDataBin] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try generateDataBins(from: data)
    }

    /// Generates JPIP data bins from codestream data.
    public func generateDataBins(from data: Data) throws -> [JPIPDataBin] {
        try generateDataBins(from: data, limits: .default, retainedBytes: 0).bins
    }

    package struct BoundedGeneration: Sendable {
        package let bins: [JPIPDataBin]
        package let peakWorkspaceBytes: Int
    }

    /// Borrows the compressed input and scans ranges without making raw/extracted byte copies.
    /// The first pass validates and admits every final payload and descriptor before allocation.
    package func generateDataBins(
        from data: Data, limits: ResourceLimits, retainedBytes: Int,
        maximumAdditionalCacheEntries: Int = 0
    ) throws -> BoundedGeneration {
        guard data.count >= 2 else {
            throw CodecError(.malformedInput, "Data too small for JPEG 2000 codestream")
        }
        guard retainedBytes >= 0, maximumAdditionalCacheEntries >= 0,
              data.count <= limits.maximumCompressedBytes,
              try Self.add(data.count, retainedBytes) <= limits.maximumMemoryBytes else {
            throw CodecError(.resourceLimitExceeded, "JPIP generator input and retained cache exceed memory limits.")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(limits.deadlineSeconds))
        func checkWork() throws {
            try Task.checkCancellation()
            guard ContinuousClock.now <= deadline else {
                throw CodecError(.resourceLimitExceeded, "JPIP data-bin generation deadline elapsed.")
            }
        }
        return try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var binCount = 0
            var payloadBytes = 0
            try enumerateBinRanges(bytes, checkWork: checkWork) { _, _, range in
                binCount = try Self.add(binCount, 1)
                payloadBytes = try Self.add(payloadBytes, range.count)
            }
            let (descriptorBytes, overflow) = binCount.multipliedReportingOverflow(by: MemoryLayout<JPIPDataBin>.stride)
            guard !overflow else {
                throw CodecError(.resourceLimitExceeded, "JPIP bin descriptor storage overflows Int.")
            }
            let (cacheDescriptorBytes, cacheOverflow) = min(binCount, maximumAdditionalCacheEntries)
                .multipliedReportingOverflow(by: MemoryLayout<JPIPCacheModel.CacheEntry>.stride)
            guard !cacheOverflow else {
                throw CodecError(.resourceLimitExceeded, "JPIP cache descriptor storage overflows Int.")
            }
            let workspace = try Self.add(retainedBytes, Self.add(payloadBytes, Self.add(descriptorBytes, cacheDescriptorBytes)))
            guard workspace <= limits.maximumWorkspaceBytes,
                  try Self.add(data.count, workspace) <= limits.maximumMemoryBytes else {
                throw CodecError(.resourceLimitExceeded, "JPIP bin payloads, descriptors and retained cache exceed combined limits.")
            }
            try checkWork()
            let bins = try Array<JPIPDataBin>(unsafeUninitializedCapacity: binCount) { buffer, initialisedCount in
                guard let destination = buffer.baseAddress, let source = bytes.baseAddress else {
                    throw CodecError(.internalFailure, "Missing admitted JPIP buffer storage.")
                }
                try enumerateBinRanges(bytes, checkWork: checkWork) { kind, id, range in
                    guard initialisedCount < binCount else {
                        throw CodecError(.internalFailure, "JPIP bin scan count changed between passes.")
                    }
                    let payload = Data(bytes: source.advanced(by: range.lowerBound), count: range.count)
                    destination.advanced(by: initialisedCount).initialize(to: JPIPDataBin(
                        binClass: kind, binID: id, data: payload, isComplete: true))
                    initialisedCount += 1
                }
                guard initialisedCount == binCount else {
                    throw CodecError(.internalFailure, "JPIP bin scan count changed between passes.")
                }
            }
            return BoundedGeneration(bins: bins, peakWorkspaceBytes: workspace)
        }
    }

    // MARK: - Normative ITU-T Rec. T.808 Wire Data-Bin Generation (2D & 3D, JPP & JPT)

    /// Generates normative ITU-T Rec. T.808 Annex A data-bins for a 2D (`.j2k`/`.jph`/`.jp2`)
    /// or 3D Part 10 (`.jp3d`) target filtered to the view window in `request`.
    public func generateWireDataBins(
        from fileData: Data,
        request: JPIPRequest? = nil,
        defaultStreamType: JPIPStreamType = .jppStream,
        limits: ResourceLimits = .default
    ) throws -> JPIPWireWindowGeneration {
        let streamType = request?.streamType ?? defaultStreamType
        if JP3DJPIPIndexer.isJP3DCodestream(fileData) {
            return try generate3DWireDataBins(from: fileData, streamType: streamType, request: request, limits: limits)
        }
        return try generate2DWireDataBins(from: fileData, streamType: streamType, request: request, limits: limits)
    }

    private static func buildPlaceholderBox(codestreamLength: Int) -> Data {
        // ISO/IEC 15444-9 Annex A.3.6.3 placeholder box (`phld`):
        // LBox(4) = 28, TBox(4) = "phld", Flags(4) = 1, OrigID(8) = 0,
        // OrigBH(8) = [UInt32BE(8 + codestreamLength), "jp2c"]
        let jp2cBoxLen = UInt32(min(UInt64(UInt32.max), UInt64(max(0, codestreamLength)) + 8))
        var phld = Data()
        phld.reserveCapacity(28)
        // LBox = 28
        phld.append(contentsOf: [0x00, 0x00, 0x00, 0x1C])
        // TBox = "phld"
        phld.append(contentsOf: [0x70, 0x68, 0x6C, 0x64])
        // Flags = 1
        phld.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
        // OrigID = 0 (64-bit)
        phld.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        // OrigBH = [jp2cBoxLen, "jp2c"]
        phld.append(contentsOf: [
            UInt8((jp2cBoxLen >> 24) & 0xFF),
            UInt8((jp2cBoxLen >> 16) & 0xFF),
            UInt8((jp2cBoxLen >> 8) & 0xFF),
            UInt8(jp2cBoxLen & 0xFF),
            0x6A, 0x70, 0x32, 0x63
        ])
        return phld
    }

    private func generate2DWireDataBins(
        from fileData: Data,
        streamType: JPIPStreamType,
        request: JPIPRequest?,
        limits: ResourceLimits
    ) throws -> JPIPWireWindowGeneration {
        let idx = try JPIPCodestreamIndexer.index(fileData, limits: limits)
        var bins: [JPIPDataBin] = []

        // 1. Metadata-bin 0 (Class 8):
        // - For JP2 containers: prefix boxes + 28-byte `phld` box (+ optional suffix boxes).
        //   Notice `libopenjpip` expects `phld` in its own message starting at `"phld"` at offset+4,
        //   or inside metadata-bin 0; emitting prefix at offset 0 (c=0) and `phld` at offset=prefix.count (c=1)
        //   satisfies BOTH ITU-T T.808 Annex A.3.6 AND OpenJPEG `v2.4.0` `parse_metadata`!
        // - For raw `.j2k`/`.jph`: empty 0-byte complete metadata-bin 0 (matching `kdu_server`).
        if let prefix = idx.jp2PrefixBeforeCodestream {
            let phld = Self.buildPlaceholderBox(codestreamLength: idx.codestreamByteCount)
            let suffix = idx.jp2SuffixAfterCodestream ?? Data()
            if !prefix.isEmpty {
                bins.append(JPIPDataBin(
                    binClass: .metadata,
                    binID: 0,
                    data: prefix,
                    isComplete: false,
                    msgOffset: 0
                ))
            }
            bins.append(JPIPDataBin(
                binClass: .metadata,
                binID: 0,
                data: phld,
                isComplete: suffix.isEmpty,
                msgOffset: prefix.count
            ))
            if !suffix.isEmpty {
                bins.append(JPIPDataBin(
                    binClass: .metadata,
                    binID: 0,
                    data: suffix,
                    isComplete: true,
                    msgOffset: prefix.count + phld.count
                ))
            }
        } else {
            bins.append(JPIPDataBin(
                binClass: .metadata,
                binID: 0,
                data: Data(),
                isComplete: true,
                msgOffset: 0
            ))
        }

        // If metadata-only was requested, stop after metadata-bin 0 + main header.
        bins.append(JPIPDataBin(
            binClass: .mainHeader,
            binID: 0,
            data: idx.mainHeader,
            isComplete: true,
            msgOffset: 0
        ))
        if request?.metadata == true {
            return JPIPWireWindowGeneration(bins: bins, streamType: streamType, coversFullTarget: false)
        }

        // 2. View-window filtering parameters
        let maxDecomp = idx.maxDecompositionLevels
        var maxResIndex = maxDecomp
        if let reslevels = request?.reslevels, reslevels > 0 {
            maxResIndex = max(0, maxDecomp - reslevels)
        } else if let fsiz = request?.fsiz, fsiz.width > 0, fsiz.height > 0 {
            let fullW = max(1, idx.width - idx.originX)
            let fullH = max(1, idx.height - idx.originY)
            if fsiz.width < fullW || fsiz.height < fullH {
                for r in 0...maxDecomp {
                    let shift = maxDecomp - r
                    let rw = (fullW + (1 << shift) - 1) >> shift
                    let rh = (fullH + (1 << shift) - 1) >> shift
                    if rw >= fsiz.width && rh >= fsiz.height {
                        maxResIndex = r
                        break
                    }
                }
            }
        }

        let totalLayers = max(1, idx.totalLayers)
        let keptLayers: Int
        if let reqLayers = request?.layers, reqLayers > 0 {
            keptLayers = min(totalLayers, reqLayers)
        } else {
            keptLayers = totalLayers
        }

        var spatialROI: (x0: Int, y0: Int, x1: Int, y1: Int)?
        if request?.roff != nil || request?.rsiz != nil {
            let fullW = max(1, idx.width - idx.originX)
            let fullH = max(1, idx.height - idx.originY)
            let roff = request?.roff ?? (x: 0, y: 0)
            let rsiz = request?.rsiz ?? (width: fullW, height: fullH)
            let scaleX: Double
            let scaleY: Double
            if let fsiz = request?.fsiz, fsiz.width > 0, fsiz.height > 0 {
                let effW = (request?.fsizRoundDirection == "round-down") ? min(fullW, fsiz.width) : fsiz.width
                let effH = (request?.fsizRoundDirection == "round-down") ? min(fullH, fsiz.height) : fsiz.height
                scaleX = Double(fullW) / Double(max(1, effW))
                scaleY = Double(fullH) / Double(max(1, effH))
            } else {
                scaleX = 1.0
                scaleY = 1.0
            }
            let x0 = idx.originX + max(0, Int(floor(Double(roff.x) * scaleX)))
            let y0 = idx.originY + max(0, Int(floor(Double(roff.y) * scaleY)))
            let x1 = min(idx.width, idx.originX + max(1, Int(ceil(Double(roff.x + rsiz.width) * scaleX))))
            let y1 = min(idx.height, idx.originY + max(1, Int(ceil(Double(roff.y + rsiz.height) * scaleY))))
            if x0 > idx.originX || y0 > idx.originY || x1 < idx.width || y1 < idx.height {
                spatialROI = (x0, y0, x1, y1)
            }
        }

        let requestedComps: Set<Int>?
        if let comps = request?.comps, !comps.isEmpty {
            // Preserve MCT triad (0, 1, 2) if colour transform may be active on >=3 components.
            var set = Set(comps)
            if idx.componentCount >= 3 && (!set.isDisjoint(with: [0, 1, 2])) {
                set.formUnion([0, 1, 2])
            }
            requestedComps = set.count < idx.componentCount ? set : nil
        } else {
            requestedComps = nil
        }

        let coversFull = (maxResIndex >= maxDecomp)
            && (keptLayers >= totalLayers)
            && (spatialROI == nil)
            && (requestedComps == nil)

        switch streamType {
        case .jptStream:
            for tile in idx.tiles {
                if let roi = spatialROI {
                    let halo = 8 << max(0, maxDecomp)
                    if tile.refX1 + halo <= roi.x0 || tile.refX0 - halo >= roi.x1
                        || tile.refY1 + halo <= roi.y0 || tile.refY0 - halo >= roi.y1 {
                        continue
                    }
                }
                bins.append(JPIPDataBin(
                    binClass: .tile,
                    binID: tile.tileIndex,
                    data: tile.completeTilePartsData,
                    isComplete: true,
                    tileIndex: tile.tileIndex,
                    msgOffset: 0
                ))
            }

        case .jppStream:
            var activeTileIDs = Set<Int>()
            var precinctBins: [JPIPDataBin] = []
            for prc in idx.precincts {
                guard prc.resolutionLevel <= maxResIndex else { continue }
                if let comps = requestedComps, !comps.contains(prc.componentIndex) {
                    continue
                }
                if let roi = spatialROI {
                    let shift = max(0, maxDecomp - prc.resolutionLevel)
                    let halo = 4 << shift
                    if prc.refX1 + halo <= roi.x0 || prc.refX0 - halo >= roi.x1
                        || prc.refY1 + halo <= roi.y0 || prc.refY0 - halo >= roi.y1 {
                        continue
                    }
                }
                activeTileIDs.insert(prc.tileIndex)
                var payload = Data()
                let layerLim = min(keptLayers, prc.layerPackets.count)
                for l in 0..<layerLim {
                    payload.append(prc.layerPackets[l])
                }
                let binComplete = (layerLim >= prc.layerPackets.count)
                precinctBins.append(JPIPDataBin(
                    binClass: .precinct,
                    binID: prc.inClassID,
                    data: payload,
                    isComplete: binComplete,
                    qualityLayer: keptLayers,
                    tileIndex: prc.tileIndex,
                    msgOffset: 0
                ))
            }

            for tile in idx.tiles where activeTileIDs.contains(tile.tileIndex) || spatialROI == nil {
                bins.append(JPIPDataBin(
                    binClass: .tileHeader,
                    binID: tile.tileIndex,
                    data: tile.tileHeaderMarkers,
                    isComplete: true,
                    tileIndex: tile.tileIndex,
                    msgOffset: 0
                ))
            }
            bins.append(contentsOf: precinctBins)
        }

        return JPIPWireWindowGeneration(
            bins: bins,
            streamType: streamType,
            coversFullTarget: coversFull
        )
    }

    private func generate3DWireDataBins(
        from fileData: Data,
        streamType: JPIPStreamType,
        request: JPIPRequest?,
        limits: ResourceLimits
    ) throws -> JPIPWireWindowGeneration {
        let idx = try JP3DJPIPIndexer.index(fileData, limits: limits)
        var bins: [JPIPDataBin] = [
            JPIPDataBin(binClass: .metadata, binID: 0, data: Data(), isComplete: true, msgOffset: 0),
            JPIPDataBin(binClass: .mainHeader, binID: 0, data: idx.mainHeader, isComplete: true, msgOffset: 0)
        ]
        if request?.metadata == true {
            return JPIPWireWindowGeneration(bins: bins, streamType: streamType, coversFullTarget: false)
        }

        let maxNL = idx.maxLevels
        var maxResIndex = maxNL
        if let reslevels = request?.reslevels, reslevels > 0 {
            maxResIndex = max(0, maxNL - reslevels)
        }
        let totalLayers = max(1, idx.totalLayers)
        let keptLayers = request?.layers.map { min(totalLayers, max(1, $0)) } ?? totalLayers

        var roiX: Range<Int>?
        var roiY: Range<Int>?
        if request?.roff != nil || request?.rsiz != nil {
            let roff = request?.roff ?? (0, 0)
            let rsiz = request?.rsiz ?? (idx.width, idx.height)
            let x0 = max(idx.originX, idx.originX + roff.x)
            let y0 = max(idx.originY, idx.originY + roff.y)
            let x1 = min(idx.width, x0 + max(1, rsiz.width))
            let y1 = min(idx.height, y0 + max(1, rsiz.height))
            if x0 > idx.originX || x1 < idx.width { roiX = x0..<x1 }
            if y0 > idx.originY || y1 < idx.height { roiY = y0..<y1 }
        }
        var roiZ: Range<Int>?
        if let zr = request?.zRange {
            let z0 = max(idx.originZ, idx.originZ + zr.offset)
            let z1 = min(idx.depth, z0 + max(1, zr.size))
            if z0 > idx.originZ || z1 < idx.depth { roiZ = z0..<z1 }
        }

        let coversFull = (maxResIndex >= maxNL)
            && (keptLayers >= totalLayers)
            && roiX == nil && roiY == nil && roiZ == nil

        switch streamType {
        case .jptStream:
            for tile in idx.tiles {
                let halo = 4 << max(0, maxNL)
                if let rx = roiX, tile.refX1 + halo <= rx.lowerBound || tile.refX0 - halo >= rx.upperBound { continue }
                if let ry = roiY, tile.refY1 + halo <= ry.lowerBound || tile.refY0 - halo >= ry.upperBound { continue }
                if let rz = roiZ, tile.refZ1 + halo <= rz.lowerBound || tile.refZ0 - halo >= rz.upperBound { continue }
                bins.append(JPIPDataBin(
                    binClass: .tile,
                    binID: tile.tileIndex,
                    data: tile.completeTilePartsData,
                    isComplete: true,
                    tileIndex: tile.tileIndex,
                    msgOffset: 0
                ))
            }

        case .jppStream:
            var activeTiles = Set<Int>()
            var precinctBins: [JPIPDataBin] = []
            for prc in idx.precincts {
                guard prc.resolutionLevel <= maxResIndex else { continue }
                let shift = max(0, maxNL - prc.resolutionLevel)
                let halo = 4 << shift
                if let rx = roiX, prc.refX1 + halo <= rx.lowerBound || prc.refX0 - halo >= rx.upperBound { continue }
                if let ry = roiY, prc.refY1 + halo <= ry.lowerBound || prc.refY0 - halo >= ry.upperBound { continue }
                if let rz = roiZ, prc.refZ1 + halo <= rz.lowerBound || prc.refZ0 - halo >= rz.upperBound { continue }
                activeTiles.insert(prc.tileIndex)

                var payload = Data()
                let lim = min(keptLayers, prc.layerPackets.count)
                for l in 0..<lim {
                    payload.append(prc.layerPackets[l])
                }
                precinctBins.append(JPIPDataBin(
                    binClass: .precinct,
                    binID: prc.inClassID,
                    data: payload,
                    isComplete: lim >= prc.layerPackets.count,
                    qualityLayer: keptLayers,
                    tileIndex: prc.tileIndex,
                    msgOffset: 0
                ))
            }
            for tile in idx.tiles where activeTiles.contains(tile.tileIndex) || (roiX == nil && roiY == nil && roiZ == nil) {
                bins.append(JPIPDataBin(
                    binClass: .tileHeader,
                    binID: tile.tileIndex,
                    data: tile.tileHeaderMarkers,
                    isComplete: true,
                    tileIndex: tile.tileIndex,
                    msgOffset: 0
                ))
            }
            bins.append(contentsOf: precinctBins)
        }

        return JPIPWireWindowGeneration(
            bins: bins,
            streamType: streamType,
            coversFullTarget: coversFull
        )
    }

    /// Checks whether the given data is an HTJ2K codestream.
    public func isHTJ2KCodestream(_ data: Data) -> Bool {
        let transcoder = J2KTranscoder()
        return (try? transcoder.isHTJ2K(data)) ?? false
    }

    // MARK: - Codestream & JP2 Container Reassembly

    /// Reassembles a JPEG 2000 codestream (or JP2 container when metadata bins are present)
    /// from an array of JPIP data bins (supporting partial `Msg-Offset` chunks, normative
    /// `image/jpp-stream` 2D & 3D precinct bins, normative `image/jpt-stream` tile bins,
    /// `phld` placeholder boxes, and local structural `generateDataBins` slices).
    public func reassembleCodestream(
        from bins: [JPIPDataBin],
        reconstructContainer: Bool = true,
        limits: ResourceLimits = .default
    ) -> Data {
        guard !bins.isEmpty else { return Data() }

        // 1. Merge any partial/segmented `Msg-Offset` bins via a local JPIPCacheModel.
        let totalInputBytes = bins.reduce(0) { $0 + max(0, $1.msgOffset) + $1.data.count }
        var merger = JPIPCacheModel(
            maxCacheSize: max(128 * 1024 * 1024, totalInputBytes + 1024 * 1024),
            maxEntries: max(65536, bins.count + 16)
        )
        for bin in bins {
            merger.addDataBin(bin)
        }
        let mergedBins = merger.allDataBins()

        guard let mainHeader = mergedBins.first(where: { $0.binClass == .mainHeader })?.data,
              !mainHeader.isEmpty else {
            return Data()
        }

        let tileHeaders = mergedBins.filter { $0.binClass == .tileHeader }.sorted { $0.binID < $1.binID }
        let tileBins = mergedBins.filter { $0.binClass == .tile || $0.binClass == .extendedTile }.sorted { $0.binID < $1.binID }
        let precinctBins = mergedBins.filter { $0.binClass == .precinct || $0.binClass == .extendedPrecinct }
        let metaBins = Dictionary(
            mergedBins.filter { $0.binClass == .metadata }.map { ($0.binID, $0.data) },
            uniquingKeysWith: { a, _ in a }
        )

        // Distinguish legacy `generateDataBins` (where `.tileHeader` begins with `0xFF 0x90` SOT)
        // from normative ITU-T T.808 JPP (`.precinct` present or `.tileHeader` excludes SOT)
        // and normative JPT (`.tile` begins with `0xFF 0x90` SOT).
        let firstTHStartsWithSOT: Bool = {
            guard let firstTH = tileHeaders.first?.data, firstTH.count >= 2 else { return false }
            return firstTH[firstTH.startIndex] == 0xFF && firstTH[firstTH.startIndex + 1] == 0x90
        }()
        let firstTileStartsWithSOT: Bool = {
            guard let firstT = tileBins.first?.data, firstT.count >= 2 else { return false }
            return firstT[firstT.startIndex] == 0xFF && firstT[firstT.startIndex + 1] == 0x90
        }()

        let codestream: Data
        if !precinctBins.isEmpty || (!firstTHStartsWithSOT && tileBins.isEmpty) {
            // Normative JPP-stream (2D or 3D Part 10 JP3D)
            var thDict: [Int: Data] = [:]
            for th in tileHeaders { thDict[th.binID] = th.data }
            var prcDict: [Int: Data] = [:]
            for prc in precinctBins { prcDict[prc.binID] = prc.data }

            if JP3DJPIPIndexer.isJP3DCodestream(mainHeader) {
                codestream = (try? JP3DJPIPIndexer.reassembleJPP3D(
                    mainHeader: mainHeader,
                    tileHeaders: thDict,
                    precinctBins: prcDict,
                    limits: limits
                )) ?? Data()
            } else {
                codestream = (try? JPIPCodestreamIndexer.reassembleJPP(
                    mainHeader: mainHeader,
                    tileHeaders: thDict,
                    precinctBins: prcDict,
                    limits: limits
                )) ?? Data()
            }
        } else if firstTileStartsWithSOT && tileHeaders.isEmpty {
            // Normative JPT-stream (`Class 6` + `Class 4`/`5` starting with SOT)
            var out = Data()
            out.append(mainHeader)
            let tileDict = Dictionary(tileBins.map { ($0.binID, $0.data) }, uniquingKeysWith: { a, _ in a })
            let totalTiles = Self.inferTotalTiles(fromMainHeader: mainHeader) ?? ((tileDict.keys.max() ?? -1) + 1)
            for tid in 0..<max(totalTiles, (tileDict.keys.max() ?? -1) + 1) {
                if let tData = tileDict[tid], !tData.isEmpty {
                    out.append(Self.repairTruncatedTilePartIfNeeded(tData, tileIndex: tid))
                } else {
                    // Valid 14-byte empty tile-part for omitted tile
                    out.append(contentsOf: [
                        0xFF, 0x90, 0x00, 0x0A,
                        UInt8((tid >> 8) & 0xFF), UInt8(tid & 0xFF),
                        0x00, 0x00, 0x00, 0x0E,
                        0x00, 0x01,
                        0xFF, 0x93
                    ])
                }
            }
            let tail = [UInt8](out.suffix(2))
            if tail.count < 2 || tail[0] != 0xFF || tail[1] != 0xD9 {
                out.append(contentsOf: [0xFF, 0xD9])
            }
            codestream = out
        } else {
            // Legacy structural `generateDataBins` layout (`SOT` inside `.tileHeader` + raw body in `.tile`)
            var output = Data()
            output.append(mainHeader)
            let tileDataByID = Dictionary(tileBins.map { ($0.binID, $0) }, uniquingKeysWith: { first, _ in first })
            var handledTileIDs = Set<Int>()
            for th in tileHeaders {
                output.append(th.data)
                let thBytes = [UInt8](th.data)
                let endsWithSOD = thBytes.count >= 2
                    && thBytes[thBytes.count - 2] == 0xFF
                    && thBytes[thBytes.count - 1] == 0x93
                if !endsWithSOD {
                    output.append(contentsOf: [0xFF, 0x93] as [UInt8])
                }
                if let tileBin = tileDataByID[th.binID] {
                    output.append(tileBin.data)
                    handledTileIDs.insert(th.binID)
                }
            }
            for tileBin in tileBins where !handledTileIDs.contains(tileBin.binID) {
                output.append(tileBin.data)
            }
            if !tileHeaders.isEmpty {
                let outBytes = [UInt8](output.suffix(2))
                if outBytes.count < 2 || outBytes[0] != 0xFF || outBytes[1] != 0xD9 {
                    output.append(contentsOf: [0xFF, 0xD9] as [UInt8])
                }
            }
            codestream = output
        }

        guard !codestream.isEmpty else { return Data() }
        guard reconstructContainer, let meta0 = metaBins[0], !meta0.isEmpty else {
            return codestream
        }
        return Self.reconstructJP2Container(metaBins: metaBins, codestream: codestream)
    }

    private static func inferTotalTiles(fromMainHeader mainHeader: Data) -> Int? {
        let bytes = [UInt8](mainHeader)
        guard bytes.count >= 42, bytes[0] == 0xFF, bytes[1] == 0x4F else { return nil }
        var cursor = 2
        var sizTileCount: Int?
        var tiles2D: Int?
        while cursor + 4 <= bytes.count {
            let m = UInt16(bytes[cursor]) << 8 | UInt16(bytes[cursor + 1])
            let segLen = Int(UInt16(bytes[cursor + 2]) << 8 | UInt16(bytes[cursor + 3]))
            guard segLen >= 2, cursor + 2 + segLen <= bytes.count else { break }
            if m == 0xFF51 && segLen >= 38 {
                let p = cursor + 2
                func u32(_ off: Int) -> Int {
                    Int(UInt32(bytes[p + off]) << 24 | UInt32(bytes[p + off + 1]) << 16
                        | UInt32(bytes[p + off + 2]) << 8 | UInt32(bytes[p + off + 3]))
                }
                let xsiz = u32(4), ysiz = u32(8)
                let xtsiz = max(1, u32(20)), ytsiz = max(1, u32(24))
                let xtosiz = u32(28), ytosiz = u32(32)
                let tw = max(1, (xsiz - xtosiz + xtsiz - 1) / xtsiz)
                let th = max(1, (ysiz - ytosiz + ytsiz - 1) / ytsiz)
                tiles2D = tw * th
                sizTileCount = tiles2D
            } else if m == 0xFF54 && segLen >= 19, let t2 = tiles2D {
                let p = cursor + 2
                func u32(_ off: Int) -> Int {
                    Int(UInt32(bytes[p + off]) << 24 | UInt32(bytes[p + off + 1]) << 16
                        | UInt32(bytes[p + off + 2]) << 8 | UInt32(bytes[p + off + 3]))
                }
                let zsiz = u32(3), ztsiz = max(1, u32(11)), ztosiz = u32(15)
                let td = max(1, (zsiz - ztosiz + ztsiz - 1) / ztsiz)
                sizTileCount = t2 * td
            }
            cursor += 2 + segLen
        }
        return sizTileCount
    }

    private static func repairTruncatedTilePartIfNeeded(_ tileData: Data, tileIndex: Int) -> Data {
        var bytes = [UInt8](tileData)
        guard bytes.count >= 14, bytes[0] == 0xFF, bytes[1] == 0x90 else {
            return Data([
                0xFF, 0x90, 0x00, 0x0A,
                UInt8((tileIndex >> 8) & 0xFF), UInt8(tileIndex & 0xFF),
                0x00, 0x00, 0x00, 0x0E,
                0x00, 0x01,
                0xFF, 0x93
            ])
        }
        let declaredPsot = Int(UInt32(bytes[6]) << 24 | UInt32(bytes[7]) << 16 | UInt32(bytes[8]) << 8 | UInt32(bytes[9]))
        if declaredPsot > bytes.count {
            let actual = UInt32(bytes.count)
            bytes[6] = UInt8((actual >> 24) & 0xFF)
            bytes[7] = UInt8((actual >> 16) & 0xFF)
            bytes[8] = UInt8((actual >> 8) & 0xFF)
            bytes[9] = UInt8(actual & 0xFF)
        }
        return Data(bytes)
    }

    private static func reconstructJP2Container(metaBins: [Int: Data], codestream: Data) -> Data {
        guard let meta0 = metaBins[0], !meta0.isEmpty else { return codestream }
        let bytes = [UInt8](meta0)

        // Check whether meta0 contains any ISO/IEC 15444-9 `phld` (`0x70686C64`) boxes.
        var cursor = 0
        var hasPhld = false
        while cursor + 8 <= bytes.count {
            let lbox = Int(UInt32(bytes[cursor]) << 24 | UInt32(bytes[cursor + 1]) << 16
                | UInt32(bytes[cursor + 2]) << 8 | UInt32(bytes[cursor + 3]))
            let tbox = UInt32(bytes[cursor + 4]) << 24 | UInt32(bytes[cursor + 5]) << 16
                | UInt32(bytes[cursor + 6]) << 8 | UInt32(bytes[cursor + 7])
            let boxLen = (lbox == 0) ? (bytes.count - cursor) : lbox
            guard boxLen >= 8, cursor + boxLen <= bytes.count else { break }
            if tbox == 0x7068_6C64 {
                hasPhld = true
                break
            }
            cursor += boxLen
        }

        if hasPhld {
            var out = Data()
            out.reserveCapacity(bytes.count + codestream.count + 64)
            cursor = 0
            var wroteCodestream = false
            while cursor + 8 <= bytes.count {
                let lbox = Int(UInt32(bytes[cursor]) << 24 | UInt32(bytes[cursor + 1]) << 16
                    | UInt32(bytes[cursor + 2]) << 8 | UInt32(bytes[cursor + 3]))
                let tbox = UInt32(bytes[cursor + 4]) << 24 | UInt32(bytes[cursor + 5]) << 16
                    | UInt32(bytes[cursor + 6]) << 8 | UInt32(bytes[cursor + 7])
                let boxLen = (lbox == 0) ? (bytes.count - cursor) : lbox
                guard boxLen >= 8, cursor + boxLen <= bytes.count else { break }

                if tbox == 0x7068_6C64 && boxLen >= 28 {
                    let flags = UInt32(bytes[cursor + 8]) << 24 | UInt32(bytes[cursor + 9]) << 16
                        | UInt32(bytes[cursor + 10]) << 8 | UInt32(bytes[cursor + 11])
                    var origID: UInt64 = 0
                    for k in 12..<20 { origID = (origID << 8) | UInt64(bytes[cursor + k]) }
                    let origTBox = UInt32(bytes[cursor + 24]) << 24 | UInt32(bytes[cursor + 25]) << 16
                        | UInt32(bytes[cursor + 26]) << 8 | UInt32(bytes[cursor + 27])

                    if origTBox == 0x6A70_3263 || (flags & 0x04) != 0 {
                        appendJP2Box(typeBytes: [0x6A, 0x70, 0x32, 0x63], payload: codestream, to: &out)
                        wroteCodestream = true
                    } else if (flags & 0x01) != 0, origID <= UInt64(Int.max), let subPayload = metaBins[Int(origID)] {
                        let tBytes = Array(bytes[(cursor + 24)..<(cursor + 28)])
                        // Recursively expand any nested phld inside sub-metadata bins if needed
                        appendJP2Box(typeBytes: tBytes, payload: subPayload, to: &out)
                    }
                } else {
                    out.append(contentsOf: bytes[cursor..<(cursor + boxLen)])
                }
                cursor += boxLen
            }
            if !wroteCodestream {
                appendJP2Box(typeBytes: [0x6A, 0x70, 0x32, 0x63], payload: codestream, to: &out)
            }
            return out
        }

        // Legacy `generateDataBins` prefix/suffix layout without `phld`
        var containerData = Data()
        containerData.reserveCapacity(meta0.count + 16 + codestream.count)
        containerData.append(meta0)
        appendJP2Box(typeBytes: [0x6A, 0x70, 0x32, 0x63], payload: codestream, to: &containerData)
        if let suffixMeta = metaBins[1] {
            containerData.append(suffixMeta)
        }
        return containerData
    }

    private static func appendJP2Box(typeBytes: [UInt8], payload: Data, to out: inout Data) {
        if payload.count <= Int(UInt32.max) - 8 {
            let boxLen = UInt32(payload.count + 8)
            out.append(contentsOf: [
                UInt8((boxLen >> 24) & 0xFF),
                UInt8((boxLen >> 16) & 0xFF),
                UInt8((boxLen >> 8) & 0xFF),
                UInt8(boxLen & 0xFF)
            ])
            out.append(contentsOf: typeBytes)
            out.append(payload)
        } else {
            let xlBoxLen = UInt64(payload.count) + 16
            out.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            out.append(contentsOf: typeBytes)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((xlBoxLen >> UInt64(shift)) & 0xFF))
            }
            out.append(payload)
        }
    }

    // MARK: - Borrowed range scanner

    private static func add(_ a: Int, _ b: Int) throws -> Int {
        let (value, overflow) = a.addingReportingOverflow(b)
        guard a >= 0, b >= 0, !overflow else {
            throw CodecError(.resourceLimitExceeded, "JPIP generator storage arithmetic overflow.")
        }
        return value
    }

    /// Emits non-overlapping byte ranges. Neither pass allocates intermediate byte arrays.
    private func enumerateBinRanges(
        _ bytes: UnsafeRawBufferPointer,
        checkWork: () throws -> Void,
        emit: (JPIPDataBinClass, Int, Range<Int>) throws -> Void
    ) throws {
        func malformed(_ message: String) -> CodecError { CodecError(.malformedInput, message) }
        func u16(_ p: Int) -> Int { (Int(bytes[p]) << 8) | Int(bytes[p + 1]) }
        func u32(_ p: Int) -> UInt32 {
            (UInt32(bytes[p]) << 24) | (UInt32(bytes[p + 1]) << 16) |
            (UInt32(bytes[p + 2]) << 8) | UInt32(bytes[p + 3])
        }
        try checkWork()
        var codestream = 0..<bytes.count
        var prefixEnd = 0
        var suffixStart = bytes.count
        if bytes[0] != 0xFF || bytes[1] != 0x4F {
            guard bytes.count >= 12, u32(0) == 12, u32(4) == 0x6A50_2020,
                  u32(8) == 0x0D0A_870A else { throw malformed("Invalid codestream: missing SOC marker") }
            var offset = 0
            var foundCodestream = false
            while offset < bytes.count {
                try checkWork()
                guard bytes.count - offset >= 8 else { throw malformed("Truncated JPIP container box.") }
                let length = u32(offset)
                let type = u32(offset + 4)
                var headerSize = 8
                let end: Int
                if length == 0 {
                    end = bytes.count
                } else if length == 1 {
                    guard bytes.count - offset >= 16 else { throw malformed("Truncated JPIP extended box length.") }
                    let extended = (UInt64(u32(offset + 8)) << 32) | UInt64(u32(offset + 12))
                    guard extended >= 16, extended <= UInt64(bytes.count - offset) else {
                        throw malformed("Invalid JPIP extended box bounds.")
                    }
                    headerSize = 16
                    end = offset + Int(extended)
                } else {
                    guard length >= 8, Int(length) <= bytes.count - offset else {
                        throw malformed("Invalid JPIP container box bounds.")
                    }
                    end = offset + Int(length)
                }
                if type == 0x6A70_3263 {
                    guard !foundCodestream, end - offset > headerSize else {
                        throw malformed("Empty or duplicate JPIP codestream box.")
                    }
                    foundCodestream = true
                    codestream = (offset + headerSize)..<end
                    prefixEnd = offset
                    suffixStart = end
                }
                offset = end
            }
            guard foundCodestream else { throw malformed("JPIP container is missing a codestream box.") }
        }
        let start = codestream.lowerBound
        let end = codestream.upperBound
        guard end - start >= 2, bytes[start] == 0xFF, bytes[start + 1] == 0x4F else {
            throw malformed("Invalid codestream: missing SOC marker")
        }
        if prefixEnd > 0 { try emit(.metadata, 0, 0..<prefixEnd) }

        var offset = start + 2
        var foundTile = false
        while end - offset >= 2 {
            try checkWork()
            if bytes[offset] == 0xFF && bytes[offset + 1] == 0x90 {
                foundTile = true
                break
            }
            if bytes[offset] == 0xFF && bytes[offset + 1] != 0xFF {
                let marker = bytes[offset + 1]
                if marker == 0xD9 { offset += 2; break }
                guard marker != 0x4F, marker != 0x93, end - offset >= 4 else {
                    throw malformed("Invalid marker in JPIP main header.")
                }
                let length = u16(offset + 2)
                guard length >= 2, length <= end - offset - 2 else {
                    throw malformed("Invalid JPIP main-header segment length.")
                }
                offset += 2 + length
            } else {
                offset += 1
            }
        }
        try emit(.mainHeader, 0, start..<(foundTile ? offset : end))
        var tileID = 0
        while foundTile && offset < end {
            try checkWork()
            guard end - offset >= 2 else { throw malformed("Truncated JPIP tile marker.") }
            if bytes[offset] == 0xFF && bytes[offset + 1] == 0xD9 { break }
            guard end - offset >= 12, bytes[offset] == 0xFF, bytes[offset + 1] == 0x90,
                  u16(offset + 2) == 10 else { throw malformed("Invalid JPIP SOT marker.") }
            let psot = Int(u32(offset + 6))
            let tileEnd: Int
            if psot == 0 {
                tileEnd = end
            } else {
                guard psot >= 14, psot <= end - offset else {
                    throw malformed("JPIP tile-part length is outside its codestream bounds.")
                }
                tileEnd = offset + psot
            }
            var sod = offset + 12
            while true {
                try checkWork()
                guard tileEnd - sod >= 2 else { throw malformed("JPIP tile part has no SOD marker.") }
                if bytes[sod] == 0xFF && bytes[sod + 1] == 0x93 { break }
                guard bytes[sod] == 0xFF else { throw malformed("Invalid JPIP tile-header marker.") }
                if bytes[sod + 1] == 0xFF { sod += 1; continue }
                guard bytes[sod + 1] != 0x90, bytes[sod + 1] != 0xD9,
                      tileEnd - sod >= 4 else { throw malformed("Invalid JPIP tile-header boundary.") }
                let length = u16(sod + 2)
                guard length >= 2, length <= tileEnd - sod - 2 else {
                    throw malformed("JPIP tile-header segment extends past Psot.")
                }
                sod += 2 + length
            }
            let dataStart = sod + 2
            var dataEnd = tileEnd
            if psot == 0 {
                var cursor = dataStart
                while end - cursor >= 2 {
                    if cursor & 0xFFFF == 0 { try checkWork() }
                    if bytes[cursor] == 0xFF && bytes[cursor + 1] == 0xD9 { break }
                    if bytes[cursor] == 0xFF && bytes[cursor + 1] == 0x90 {
                        throw malformed("A zero-length JPIP tile part must be the final tile part.")
                    }
                    cursor += 1
                }
                guard end - cursor >= 2 else { throw malformed("Zero-length JPIP tile part has no EOC marker.") }
                dataEnd = cursor
            }
            try emit(.tileHeader, tileID, offset..<sod)
            try emit(.tile, tileID, dataStart..<dataEnd)
            tileID = try Self.add(tileID, 1)
            offset = dataEnd
        }
        if foundTile {
            guard end - offset == 2, bytes[offset] == 0xFF, bytes[offset + 1] == 0xD9 else {
                throw malformed("JPIP codestream must finish with EOC after its final tile part.")
            }
        }
        if suffixStart < bytes.count { try emit(.metadata, 1, suffixStart..<bytes.count) }
    }
}
