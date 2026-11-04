// SPDX-License-Identifier: Apache-2.0
//
// JP3DProgressiveDelivery.swift
// SwiftJ2KJPIP
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/JPIP/JP3DProgressiveDelivery.swift
//
/// # JP3DProgressiveDelivery
///
/// Bandwidth-aware progressive delivery actor for Part 10 JP3D volumetric data.
///
/// Schedules normative ITU-T Rec. T.808 VBAS-encoded 3D precinct/header data-bin
/// updates according to the chosen progression mode, adapting to bandwidth and
/// quality adjustments in real time.

import Foundation
@_exported import SwiftJ2K
@_exported import SwiftJ2K3D

/// A partial volume update delivered during progressive streaming.
public struct JP3DProgressiveUpdate: Sendable {
    /// The region this update covers.
    public let region: JP3DStreamingRegion
    /// Partial encoded VBAS data-bin stream payload for the region.
    public let data: Data
    /// Quality layer of this update.
    public let qualityLayer: Int
    /// Resolution level of this update.
    public let resolutionLevel: Int
    /// Whether this is the final update for the requested region.
    public let isComplete: Bool
    /// Fraction of the total request completed (`0.0`–`1.0`).
    public let completionFraction: Double

    /// Creates a progressive update.
    public init(
        region: JP3DStreamingRegion,
        data: Data,
        qualityLayer: Int,
        resolutionLevel: Int,
        isComplete: Bool,
        completionFraction: Double = 0.0
    ) {
        self.region = region
        self.data = data
        self.qualityLayer = qualityLayer
        self.resolutionLevel = resolutionLevel
        self.isComplete = isComplete
        self.completionFraction = min(1.0, max(0.0, completionFraction))
    }
}

/// Bandwidth-managed progressive delivery actor for JP3D volumes.
public actor JP3DProgressiveDelivery {
    // MARK: - Configuration

    /// Maximum bandwidth to use for delivery, in bytes per second.
    public private(set) var maxBandwidthBPS: Double
    /// Progression mode controlling bin ordering.
    public private(set) var progressionMode: JP3DProgressionMode
    /// Minimum resolution level to begin from.
    public private(set) var minimumResolutionLevel: Int

    // MARK: - State

    private var isCancelled: Bool = false
    private var currentNetwork: JP3DNetworkCondition
    private var pendingBins: [JP3DDataBin] = []
    private var deliveredBytes: Int = 0
    private var deliveredBins: Int = 0
    private var startTime: Date?
    private var qualityCap = Int.max
    private var codestreamData: Data?
    private let dataBinGenerator = JPIPDataBinGenerator()

    // MARK: - Initialiser

    /// Creates a progressive delivery actor.
    public init(
        maxBandwidthBPS: Double = 10_000_000,
        progressionMode: JP3DProgressionMode = .adaptive,
        minimumResolutionLevel: Int = 0,
        codestreamData: Data? = nil
    ) {
        self.maxBandwidthBPS = max(0, maxBandwidthBPS)
        self.progressionMode = progressionMode
        self.minimumResolutionLevel = max(0, minimumResolutionLevel)
        self.currentNetwork = JP3DNetworkCondition(bandwidthBPS: maxBandwidthBPS)
        self.codestreamData = codestreamData
    }

    /// Attaches a Part 10 `.jp3d` codestream so progressive updates emit real 3D precinct VBAS deltas.
    public func attachCodestream(_ data: Data) {
        self.codestreamData = data
    }

    // MARK: - Delivery Control

    /// Cancels any in-progress delivery.
    public func cancel() {
        isCancelled = true
        pendingBins.removeAll()
    }

    /// Updates the bandwidth estimate, adjusting future scheduling.
    public func updateBandwidth(_ bandwidthBPS: Double) {
        maxBandwidthBPS = max(0, bandwidthBPS)
        currentNetwork = JP3DNetworkCondition(
            bandwidthBPS: bandwidthBPS,
            latencySeconds: currentNetwork.latencySeconds,
            packetLoss: currentNetwork.packetLoss
        )
    }

    /// Adjusts the target quality layer for ongoing delivery.
    public func adjustQuality(_ quality: Int) {
        qualityCap = max(0, quality)
        pendingBins = pendingBins.filter { $0.qualityLayer <= qualityCap }
    }

    /// Responds to a network condition change.
    public func handleNetworkChange(_ condition: JP3DNetworkCondition) {
        currentNetwork = condition
        maxBandwidthBPS = condition.bandwidthBPS
    }

    // MARK: - Delivery Estimation

    /// Estimates the time to deliver a region at the given bandwidth.
    public func estimateDeliveryTime(region: JP3DStreamingRegion, bandwidth: Double) -> Double {
        guard bandwidth > 0 else { return .infinity }
        let voxels = region.xRange.count * region.yRange.count * region.zRange.count
        let estimatedBytes = Double(voxels) * 2.0
        return estimatedBytes / bandwidth
    }

    // MARK: - Progressive Delivery

    /// Starts progressive delivery for a region, returning ordered updates.
    public func startDelivery(volume: J2KVolume, region: JP3DStreamingRegion) async -> [JP3DProgressiveUpdate] {
        isCancelled = false
        startTime = Date()
        deliveredBytes = 0
        deliveredBins = 0

        guard region.isValid && !region.isEmpty else {
            return []
        }

        // Resolve real Part 10 JP3D codestream when voxel samples or attached codestream are present.
        var activeCodestream = codestreamData
        if activeCodestream == nil,
           !volume.components.isEmpty,
           volume.components.allSatisfy({ !$0.data.isEmpty }) {
            activeCodestream = try? await JP3DEncoder(configuration: .lossless).encode(volume).data
        }

        var sentState = JPIPCacheModel(maxCacheSize: 256 * 1024 * 1024, maxEntries: 100_000)
        var updates: [JP3DProgressiveUpdate] = []

        let maxResolution = region.resolutionLevel
        let maxQuality = min(region.qualityLayer, qualityCap)

        let steps = resolveProgression(
            progressionMode: progressionMode,
            maxResolution: maxResolution,
            maxQuality: maxQuality,
            region: region
        )

        let totalSteps = steps.count
        for (index, step) in steps.enumerated() {
            if isCancelled { break }
            if currentNetwork.bandwidthBPS == 0 {
                continue
            }

            let isLast = index == totalSteps - 1
            let fraction = totalSteps > 1 ? Double(index + 1) / Double(totalSteps) : 1.0

            let stepRegion = step.zSlice.map { z in
                JP3DStreamingRegion(
                    xRange: region.xRange,
                    yRange: region.yRange,
                    zRange: z..<(z + 1),
                    qualityLayer: step.quality,
                    resolutionLevel: step.resolution
                )
            } ?? region

            let stepData = makeStepData(
                codestream: activeCodestream,
                region: stepRegion,
                resolutionLevel: step.resolution,
                qualityLayer: step.quality,
                stepIndex: index,
                isLast: isLast,
                sentState: &sentState
            )

            let update = JP3DProgressiveUpdate(
                region: stepRegion,
                data: stepData,
                qualityLayer: step.quality,
                resolutionLevel: step.resolution,
                isComplete: isLast,
                completionFraction: fraction
            )
            updates.append(update)
            deliveredBytes += stepData.count
            deliveredBins += 1
        }

        return updates
    }

    // MARK: - Statistics

    public var statistics: JP3DStreamingStatistics {
        let elapsed = startTime.map { Date().timeIntervalSince($0) } ?? 0
        let avgBW = elapsed > 0 ? Double(deliveredBytes) / elapsed : 0
        return JP3DStreamingStatistics(
            bytesDelivered: deliveredBytes,
            binsDelivered: deliveredBins,
            averageBandwidthBPS: avgBW,
            elapsedSeconds: elapsed
        )
    }

    // MARK: - Private Helpers

    private struct ProgressionStep {
        let resolution: Int
        let quality: Int
        let zSlice: Int?
    }

    private func resolveProgression(
        progressionMode: JP3DProgressionMode,
        maxResolution: Int,
        maxQuality: Int,
        region: JP3DStreamingRegion
    ) -> [ProgressionStep] {
        var steps: [ProgressionStep] = []
        switch progressionMode {
        case .resolutionFirst:
            for r in 0...maxResolution {
                steps.append(ProgressionStep(resolution: r, quality: maxQuality, zSlice: nil))
            }
        case .qualityFirst:
            for q in 0...maxQuality {
                steps.append(ProgressionStep(resolution: maxResolution, quality: q, zSlice: nil))
            }
        case .sliceBySliceForward, .sliceBySliceReverse, .sliceBySliceBidirectional:
            let slices = sliceOrder(mode: progressionMode, zRange: region.zRange)
            for z in slices {
                steps.append(ProgressionStep(resolution: maxResolution, quality: maxQuality, zSlice: z))
            }
        case .viewDependent, .distanceOrdered:
            steps.append(ProgressionStep(resolution: maxResolution, quality: maxQuality, zSlice: nil))
        case .adaptive:
            for r in 0...maxResolution {
                for q in 0...maxQuality {
                    steps.append(ProgressionStep(resolution: r, quality: q, zSlice: nil))
                }
            }
        }
        return steps.isEmpty
            ? [ProgressionStep(resolution: maxResolution, quality: maxQuality, zSlice: nil)]
            : steps
    }

    private func sliceOrder(mode: JP3DProgressionMode, zRange: Range<Int>) -> [Int] {
        let slices = Array(zRange)
        switch mode {
        case .sliceBySliceReverse:
            return slices.reversed()
        case .sliceBySliceBidirectional:
            var result: [Int] = []
            let mid = zRange.lowerBound + zRange.count / 2
            var lo = mid, hi = mid + 1
            while lo >= zRange.lowerBound || hi < zRange.upperBound {
                if lo >= zRange.lowerBound { result.append(lo); lo -= 1 }
                if hi < zRange.upperBound { result.append(hi); hi += 1 }
            }
            return result
        default:
            return slices
        }
    }

    private func makeStepData(
        codestream: Data?,
        region: JP3DStreamingRegion,
        resolutionLevel: Int,
        qualityLayer: Int,
        stepIndex: Int,
        isLast: Bool,
        sentState: inout JPIPCacheModel
    ) -> Data {
        if let cs = codestream, JP3DJPIPIndexer.isJP3DCodestream(cs) {
            var req = JPIPRequest(target: "volume.jp3d")
            req.roff = (region.xRange.lowerBound, region.yRange.lowerBound)
            req.rsiz = (region.xRange.count, region.yRange.count)
            req.zRange = (region.zRange.lowerBound, region.zRange.count)
            req.layers = max(1, qualityLayer + 1)
            if max(0, region.resolutionLevel - resolutionLevel) > 0 {
                req.reslevels = max(0, region.resolutionLevel - resolutionLevel)
            }
            req.streamType = .jppStream

            if let generated = try? dataBinGenerator.generateWireDataBins(
                from: cs,
                request: req,
                defaultStreamType: .jppStream
            ) {
                var deltaBins: [JPIPDataBin] = []
                for bin in generated.bins {
                    let already = sentState.deliveredPrefixLength(binClass: bin.binClass, binID: bin.binID)
                    if bin.data.count > already {
                        let tail = Data(bin.data[already..<bin.data.count])
                        let inc = JPIPDataBin(
                            binClass: bin.binClass,
                            binID: bin.binID,
                            data: tail,
                            isComplete: bin.isComplete,
                            msgOffset: already
                        )
                        deltaBins.append(inc)
                        sentState.addDataBin(inc)
                    } else if bin.isComplete && !sentState.hasCompleteDataBin(binClass: bin.binClass, binID: bin.binID) {
                        let inc = JPIPDataBin(
                            binClass: bin.binClass,
                            binID: bin.binID,
                            data: Data(),
                            isComplete: true,
                            msgOffset: already
                        )
                        deltaBins.append(inc)
                        sentState.addDataBin(inc)
                    }
                }
                let eor: JPIPEORMessage = isLast
                    ? JPIPEORMessage(reason: .windowDone)
                    : JPIPEORMessage(reason: .qualityLimitReached)
                return JPIPWireCodec.encodeStream(bins: deltaBins, eor: eor)
            }
        }

        // Metadata-only `J2KVolume` schedule descriptor encoded as a valid VBAS precinct message.
        let descriptorBin = JPIPDataBin(
            binClass: .precinct,
            binID: stepIndex,
            data: Data(),
            isComplete: isLast
        )
        let eor = JPIPEORMessage(reason: isLast ? .windowDone : .qualityLimitReached)
        return JPIPWireCodec.encodeStream(bins: [descriptorBin], eor: eor)
    }
}
