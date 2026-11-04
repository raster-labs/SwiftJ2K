// SPDX-License-Identifier: Apache-2.0
//
// JPIPProgressiveStreamingPipeline.swift
// SwiftJ2KJPIP
//
// Migrated from Raster-Lab/J2KSwift at 7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca:
//   - Sources/JPIP/JPIPProgressiveStreamingPipeline.swift
//
/// # JPIPProgressiveStreamingPipeline
///
/// Progressive streaming pipeline for multi-resolution tiled JPEG 2000 delivery.
///
/// Integrates multi-resolution tile management, real precinct data-bin extraction
/// (`JPIPDataBinGenerator`), and adaptive quality control for progressive streaming.

import Foundation
@_exported import SwiftJ2K
@_exported import SwiftJ2K3D

/// Streaming mode for progressive delivery.
public enum JPIPStreamingMode: Sendable {
    /// Resolution-progressive: deliver low resolution first, then refine.
    case resolutionProgressive

    /// Quality-progressive: deliver low quality first, then enhance.
    case qualityProgressive

    /// Hybrid: combination of resolution and quality progression.
    case hybrid
}

/// Streaming statistics.
public struct JPIPStreamingStatistics: Sendable {
    public var totalBytesDelivered: Int
    public var totalTilesDelivered: Int
    public var averageDeliveryRate: Double
    public var currentQualityLevel: Double
    public var currentResolutionLevel: Int
    public var deliveryTimeMs: Double

    public init() {
        self.totalBytesDelivered = 0
        self.totalTilesDelivered = 0
        self.averageDeliveryRate = 0.0
        self.currentQualityLevel = 0.0
        self.currentResolutionLevel = 0
        self.deliveryTimeMs = 0.0
    }
}

/// Configuration for progressive streaming.
public struct JPIPStreamingConfiguration: Sendable {
    public var mode: JPIPStreamingMode
    public var targetLatency: Double
    public var enableRateAdaptation: Bool
    public var minimumInitialLayers: Int
    public var maxConcurrentDeliveries: Int

    public init(
        mode: JPIPStreamingMode = .hybrid,
        targetLatency: Double = 100.0,
        enableRateAdaptation: Bool = true,
        minimumInitialLayers: Int = 1,
        maxConcurrentDeliveries: Int = 4
    ) {
        self.mode = mode
        self.targetLatency = targetLatency
        self.enableRateAdaptation = enableRateAdaptation
        self.minimumInitialLayers = minimumInitialLayers
        self.maxConcurrentDeliveries = maxConcurrentDeliveries
    }
}

/// Request for streaming a specific view window.
public struct JPIPViewWindowRequest: Sendable {
    public let region: (x: Int, y: Int, width: Int, height: Int)
    public let targetQualityLayers: Int?
    public let targetResolutionLevel: Int?
    public let components: [Int]?

    public init(
        region: (x: Int, y: Int, width: Int, height: Int),
        targetQualityLayers: Int? = nil,
        targetResolutionLevel: Int? = nil,
        components: [Int]? = nil
    ) {
        self.region = region
        self.targetQualityLayers = targetQualityLayers
        self.targetResolutionLevel = targetResolutionLevel
        self.components = components
    }
}

/// Progressive streaming pipeline for JPIP.
public actor JPIPProgressiveStreamingPipeline {
    private let tileManager: JPIPMultiResolutionTileManager
    private let qualityEngine: JPIPAdaptiveQualityEngine
    private let bandwidthEstimator: JPIPBandwidthEstimator
    private let deliveryScheduler: JPIPProgressiveDeliveryScheduler
    public var configuration: JPIPStreamingConfiguration
    private var bandwidthState: JPIPBandwidthState
    private var statistics: JPIPStreamingStatistics
    private var streamingStartTime: Date?
    private let dataBinGenerator: JPIPDataBinGenerator
    private var codestreamData: Data?

    /// Creates a progressive streaming pipeline.
    public init(
        imageSize: (width: Int, height: Int),
        tileConfiguration: JPIPTileConfiguration,
        streamingConfiguration: JPIPStreamingConfiguration = JPIPStreamingConfiguration(),
        codestreamData: Data? = nil
    ) {
        self.tileManager = JPIPMultiResolutionTileManager(
            imageSize: imageSize,
            configuration: tileConfiguration
        )
        self.qualityEngine = JPIPAdaptiveQualityEngine(
            maxQualityLayers: tileConfiguration.maxQualityLayers,
            maxResolutionLevels: tileConfiguration.resolutionLevels
        )
        self.bandwidthEstimator = JPIPBandwidthEstimator()
        self.deliveryScheduler = JPIPProgressiveDeliveryScheduler()
        self.configuration = streamingConfiguration
        self.bandwidthState = JPIPBandwidthState(availableBandwidth: 5_000_000)
        self.statistics = JPIPStreamingStatistics()
        self.dataBinGenerator = JPIPDataBinGenerator()
        self.codestreamData = codestreamData
    }

    /// Attaches a real JPEG 2000 / JP2 / JPH / JP3D codestream for normative precinct data-bin extraction.
    public func attachCodestream(_ data: Data) {
        self.codestreamData = data
    }

    /// Streams a view window progressively.
    public func streamViewWindow(_ request: JPIPViewWindowRequest) async -> [JPIPDataBin] {
        streamingStartTime = Date()

        await tileManager.updateViewport(request.region)
        let bandwidthEstimate = await bandwidthEstimator.getEstimate()

        self.bandwidthState = JPIPBandwidthState(
            availableBandwidth: bandwidthEstimate.bandwidth,
            bandwidthTrend: bandwidthEstimate.trend,
            congestionDetected: bandwidthEstimate.congestionDetected,
            roundTripTime: bandwidthEstimate.averageRTT
        )

        let qualityDecision = await qualityEngine.determineQuality(
            bandwidthState: bandwidthState,
            targetLatency: configuration.targetLatency
        )

        var dataBins: [JPIPDataBin] = []

        if let cs = codestreamData {
            var jpipReq = JPIPRequest(target: "pipeline.j2k")
            jpipReq.roff = (request.region.x, request.region.y)
            jpipReq.rsiz = (request.region.width, request.region.height)
            jpipReq.layers = request.targetQualityLayers ?? qualityDecision.targetQualityLayers
            jpipReq.comps = request.components
            jpipReq.streamType = .jppStream
            if let generated = try? dataBinGenerator.generateWireDataBins(
                from: cs,
                request: jpipReq,
                defaultStreamType: .jppStream
            ) {
                dataBins = generated.bins
            }
        }

        if dataBins.isEmpty {
            let prioritizedTiles = await tileManager.getPriorityQueue()
            switch configuration.mode {
            case .resolutionProgressive:
                dataBins = generateResolutionProgressiveBins(
                    tiles: prioritizedTiles,
                    qualityDecision: qualityDecision
                )
            case .qualityProgressive:
                dataBins = generateQualityProgressiveBins(
                    tiles: prioritizedTiles,
                    qualityDecision: qualityDecision
                )
            case .hybrid:
                dataBins = generateHybridProgressiveBins(
                    tiles: prioritizedTiles,
                    qualityDecision: qualityDecision
                )
            }
        }

        let deliveryWindow = JPIPDeliveryWindow(
            region: request.region,
            targetQualityLayers: request.targetQualityLayers ?? qualityDecision.targetQualityLayers,
            targetResolutionLevel: request.targetResolutionLevel ?? qualityDecision.targetResolutionLevel
        )

        await deliveryScheduler.schedule(
            dataBins,
            window: deliveryWindow,
            bandwidth: bandwidthEstimate.predictedBandwidth
        )

        let deliveredBins = await deliveryScheduler.deliverNextBatch()
        updateStatistics(dataBins: deliveredBins, qualityDecision: qualityDecision)

        if statistics.totalBytesDelivered == 0 && !deliveredBins.isEmpty {
            await qualityEngine.recordFirstByte()
        }

        if statistics.totalTilesDelivered >= 10 {
            await qualityEngine.recordInteractive()
        }

        return deliveredBins
    }

    public func updateBandwidthState(_ state: JPIPBandwidthState) {
        self.bandwidthState = state
    }

    public func getStatistics() -> JPIPStreamingStatistics {
        statistics
    }

    public func getQoEMetrics() async -> JPIPQoEMetrics {
        await qualityEngine.getQoEMetrics()
    }

    public func getBandwidthEstimate() async -> JPIPBandwidthEstimate {
        await bandwidthEstimator.getEstimate()
    }

    public func getDeliveryStatistics() async -> JPIPDeliveryStatistics {
        await deliveryScheduler.getStatistics()
    }

    public func recordTransfer(bytes: Int, duration: TimeInterval, rtt: Double) async {
        await bandwidthEstimator.recordTransfer(bytes: bytes, duration: duration, rtt: rtt)
    }

    public func adaptRate(measuredBandwidth: Int) async {
        guard configuration.enableRateAdaptation else { return }

        let duration = 1.0
        await bandwidthEstimator.recordTransfer(
            bytes: measuredBandwidth,
            duration: duration,
            rtt: bandwidthState.roundTripTime
        )

        let estimate = await bandwidthEstimator.getEstimate()

        self.bandwidthState = JPIPBandwidthState(
            availableBandwidth: estimate.bandwidth,
            bandwidthTrend: estimate.trend,
            congestionDetected: estimate.congestionDetected,
            roundTripTime: estimate.averageRTT
        )

        await deliveryScheduler.updateBandwidth(estimate.predictedBandwidth)

        if estimate.congestionDetected {
            await tileManager.setGranularityFactor(2.0)
        } else {
            await tileManager.setGranularityFactor(1.0)
        }
    }

    public func updateRoundTripTime(_ rtt: Double) async {
        self.bandwidthState = JPIPBandwidthState(
            availableBandwidth: bandwidthState.availableBandwidth,
            bandwidthTrend: bandwidthState.bandwidthTrend,
            congestionDetected: bandwidthState.congestionDetected,
            roundTripTime: rtt
        )

        await qualityEngine.recordLatency(rtt)
    }

    // MARK: - Private Schedule-Only Descriptor Helpers

    private func generateResolutionProgressiveBins(
        tiles: [JPIPPrioritizedTile],
        qualityDecision: JPIPQualityDecision
    ) -> [JPIPDataBin] {
        var bins: [JPIPDataBin] = []

        for resLevel in 0...qualityDecision.targetResolutionLevel {
            let tilesAtResolution = tiles.filter { $0.tile.resolutionLevel == resLevel }
            let sortedTiles = tilesAtResolution.sorted { $0.priority > $1.priority }

            for prioritizedTile in sortedTiles.prefix(configuration.maxConcurrentDeliveries) {
                let layers = min(configuration.minimumInitialLayers, prioritizedTile.targetLayers)
                bins.append(contentsOf: createDescriptorBinsForTile(
                    prioritizedTile.tile,
                    qualityLayers: layers
                ))
            }
        }

        return bins
    }

    private func generateQualityProgressiveBins(
        tiles: [JPIPPrioritizedTile],
        qualityDecision: JPIPQualityDecision
    ) -> [JPIPDataBin] {
        var bins: [JPIPDataBin] = []
        let targetTiles = tiles.filter {
            $0.tile.resolutionLevel == qualityDecision.targetResolutionLevel
        }

        for layer in 1...qualityDecision.targetQualityLayers {
            for prioritizedTile in targetTiles.prefix(configuration.maxConcurrentDeliveries)
                where layer <= prioritizedTile.targetLayers {
                bins.append(contentsOf: createDescriptorBinsForTile(
                    prioritizedTile.tile,
                    qualityLayers: layer
                ))
            }
        }

        return bins
    }

    private func generateHybridProgressiveBins(
        tiles: [JPIPPrioritizedTile],
        qualityDecision: JPIPQualityDecision
    ) -> [JPIPDataBin] {
        var bins: [JPIPDataBin] = []

        let previewResolution = max(0, qualityDecision.targetResolutionLevel - 2)
        let previewTiles = tiles.filter { $0.tile.resolutionLevel == previewResolution }

        for prioritizedTile in previewTiles.prefix(configuration.maxConcurrentDeliveries) {
            bins.append(contentsOf: createDescriptorBinsForTile(
                prioritizedTile.tile,
                qualityLayers: configuration.minimumInitialLayers
            ))
        }

        let targetTiles = tiles.filter {
            $0.tile.resolutionLevel == qualityDecision.targetResolutionLevel &&
            $0.priority >= .normal
        }

        for prioritizedTile in targetTiles.prefix(configuration.maxConcurrentDeliveries) {
            let targetLayers = min(
                qualityDecision.targetQualityLayers,
                prioritizedTile.targetLayers
            )

            bins.append(contentsOf: createDescriptorBinsForTile(
                prioritizedTile.tile,
                qualityLayers: targetLayers
            ))
        }

        return bins
    }

    private func createDescriptorBinsForTile(
        _ tile: JPIPTile,
        qualityLayers: Int
    ) -> [JPIPDataBin] {
        var bins: [JPIPDataBin] = []
        let tileID = tile.y * 100 + tile.x

        for layer in 0..<qualityLayers {
            let precinctID = tileID * 10 + layer
            var packetHeader = Data(capacity: 16)
            // Valid minimal JPEG 2000 zero-length packet header (`0x00`) + tile/layer metadata
            packetHeader.append(0x00)
            var tBE = UInt32(clamping: max(0, tileID)).bigEndian
            var rBE = UInt32(clamping: max(0, tile.resolutionLevel)).bigEndian
            var lBE = UInt32(clamping: max(0, layer)).bigEndian
            withUnsafeBytes(of: &tBE) { packetHeader.append(contentsOf: $0) }
            withUnsafeBytes(of: &rBE) { packetHeader.append(contentsOf: $0) }
            withUnsafeBytes(of: &lBE) { packetHeader.append(contentsOf: $0) }

            bins.append(JPIPDataBin(
                binClass: .precinct,
                binID: precinctID,
                data: packetHeader,
                isComplete: layer == qualityLayers - 1
            ))
        }

        return bins
    }

    private func updateStatistics(
        dataBins: [JPIPDataBin],
        qualityDecision: JPIPQualityDecision
    ) {
        let bytesDelivered = dataBins.reduce(0) { $0 + $1.data.count }
        statistics.totalBytesDelivered += bytesDelivered
        statistics.totalTilesDelivered += dataBins.count

        if let startTime = streamingStartTime {
            let elapsed = Date().timeIntervalSince(startTime)
            statistics.deliveryTimeMs = elapsed * 1000.0

            if elapsed > 0 {
                statistics.averageDeliveryRate = Double(statistics.totalBytesDelivered) / elapsed
            }
        }

        statistics.currentQualityLevel = Double(qualityDecision.targetQualityLayers) /
                                        Double(qualityEngine.maxQualityLayers)
        statistics.currentResolutionLevel = qualityDecision.targetResolutionLevel
    }
}
