# Milestone 11 — `SwiftJ2KJPIP` Interactive Progressive Streaming (JPIP / ISO/IEC 15444-9)

**Status:** Implemented on branch `antigravity/milestone11-swiftj2kjpip` from `origin/main` (`be82d39`) against pinned predecessor `Raster-Lab/J2KSwift` [`7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca`](https://github.com/Raster-Lab/J2KSwift/commit/7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca).
**Contract:** `0.10.0` (verified byte-identical against `Documentation/COMMON_CONTRACT_SHA256.txt`).
**Toolchain:** Apple Swift `6.4-dev` (`Swift 6` language mode, complete concurrency checking) on macOS 26.4 (`arm64-apple-macosx26.0`, Apple M3 Max).

---

## 1. Scope and Summary

Milestone 11 migrates and adapts the predecessor's JPEG 2000 Interactive Protocol (ISO/IEC 15444-9 / JPIP) product (`Sources/JPIP`, 31 files / 14,005 lines) and its 17 test files (`Tests/JPIPTests/*` plus `Tests/JP3DTests/JP3DStreamingTests.swift` and `JP3DHTj2KJPIPWorkflowTests`) into the retained library product **`SwiftJ2KJPIP`** per Decision M2 (`IMPLEMENTATION.md` lines 83, 96, 140, 157) and Contract **API-13**:

1. **Legacy Image & Codec Bridge (`Sources/SwiftJ2K/LegacyImageBridge.swift`)**:
   - Provides `J2KImage`, `J2KComponent`, `J2KColorSpace`, `J2KConfiguration`, `J2KProgressionOrder`, `J2KSubband`, `J2KQualityOfService`, `J2KFormat`, `J2KFormatDetector`, `J2KEncodingConfiguration`, `J2KEncodingPreset`, `J2KBitrateMode`, `J2KEncoder`, `J2KDecoder` (with `decodeSync` supporting `maxQualityLayers`, `resolutionLevel`, `components`, and spatial `region`), and `J2KTranscoder` (`TranscodingConfiguration`, `TranscodingDirection`, `TranscodingStage`, `TranscodingProgressUpdate`, `TranscodingResult`, `isHTJ2K`).
   - Re-exported by `SwiftJ2KJPIP` (`@_exported import SwiftJ2K`, `@_exported import SwiftJ2K3D`) so consumers importing `SwiftJ2KJPIP` (such as `DICOMKit`'s `DICOMJPIPClient.swift` and `dicom-jpip`) have seamless access to `J2KImage`, `J2KComponent`, `J2KError`, and `JP3D*` streaming types.

2. **Retained `SwiftJ2KJPIP` Library Product (`Sources/SwiftJ2KJPIP/`)**:
   - **JPIP Client, Server, Transport, and Loopback Routing**: `JPIPClient`, `JPIPServer`, `JPIPTransport`, `JPIPLoopbackRegistry` (enabling deterministic in-process `localhost`/`127.0.0.1` loopback routing and direct `JPIPClient(server:)` binding alongside remote HTTP/HTTPS URLSession transport), `JPIPRequest`, `JPIPResponse`, `JPIPRequestQueue`, `JPIPSession`, and `JPIPServerSession`.
   - **Data-Bin Generation, Codestream Reassembly, and Caching**: `JPIPDataBinGenerator` (codestream parsing into `.mainHeader`, `.tileHeader`, `.precinct`, `.tile`, and `.metadata` `JPIPDataBin` packets, plus `reassembleCodestream(from:)` for complete codestream reconstruction), `JPIPCacheModel`, `JPIPPrecinctCache`, `JPIPClientCacheManager` (resolution-aware LRU eviction, per-image policies, deduplication, RLE inactive-entry compression/decompression, and persistent storage warm-up), and `JPIPSessionPersistence`.
   - **Bandwidth Estimation, Throttling, Progressive Delivery, and Server Push**: `JPIPBandwidthEstimator`, `JPIPBandwidthThrottle`, `JPIPAdaptiveQualityEngine`, `JPIPMultiResolutionTileManager`, `JPIPProgressiveDeliveryScheduler`, `JPIPProgressiveStreamingPipeline`, and `JPIPServerPush` (`JPIPViewportPredictionEngine`, `JPIPPrefetchEngine`, `JPIPServerPushManager`).
   - **WebSocket, Network.framework, HTJ2K Negotiation, and 3D Volumetric Streaming**: `JPIPWebSocketTransport`, `JPIPWebSocketClient`, `JPIPWebSocketServer`, `JPIPNetworkFramework`, `JPIPHTJ2KSupport`, `JPIPTranscodingService` (on-the-fly Part 1 ↔ HTJ2K transcoding with caching), and 3D JP3D JPIP actors (`JP3DStreamingTypes`, `JP3DCacheManager`, `JP3DProgressiveDelivery`, `JP3DJPIPClient`, `JP3DJPIPServer`).

3. **Contract API-13 Interactive Streaming Extension Surface (`Sources/SwiftJ2KJPIP/JPIPCodecAPI.swift`)**:
   - **Rationale (`API-13`)**: Single-shot `SwiftJ2K.Encoder`/`SwiftJ2K.Decoder` operate statelessly on complete in-memory buffers and cannot represent persistent JPIP sessions/channels (`cid`, `cnew`, `cclose`), spatial/resolution view-window queries (`fsiz`, `roff`, `rsiz`, `layers`, `comps`), incremental data-bin caches (`JPIPDataBin`), server push, or 3D volumetric viewports (`JP3DViewport`, `JP3DStreamingRegion`).
   - Provides `JPIPSessionConfiguration`, `JPIPDeliveryMode`, `JPIPStreamingOptions`, `JPIPViewWindow`, `JPIPDeliveredImage`, `JPIPDeliveredVolumeSliceBins`, and the `JPIPStreamingSession` actor bridging 2D and 3D JPIP streaming with the common contract's owning `Image`, `ResourceLimits`, `ExecutionPolicy`, `CopyPolicy`, `MetadataPolicy`, `ProgressUpdate`, and `OperationReport`.

---

## 2. Predecessor Audit and File-by-File Dispositions (`7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca`)

### 2.1 File-by-File Inventory and Dispositions

All 31 files in `Sources/JPIP` (14,005 lines) at `7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca` were audited and migrated into `Sources/SwiftJ2KJPIP/`:

| Predecessor file (`7acc9ae4`) | Lines | Git blob SHA | Disposition | Successor file & notes |
| --- | ---: | --- | --- | --- |
| `Sources/JPIP/JPIP.docc/JPIP.md` | 50 | `16a02cf7c1d2aa69ac56ff3665a6833165a29ab4` | Retained / Adapted | `Sources/SwiftJ2KJPIP/SwiftJ2KJPIP.docc/SwiftJ2KJPIP.md` |
| `Sources/JPIP/JPIP.swift` | 271 | `c7eed96073a2f9001ae0a5031943b02941a83a87` | Retained / Fixed | `Sources/SwiftJ2KJPIP/JPIP.swift` — implemented `requestImage`, `requestRegion`, `requestProgressiveQuality`, `requestResolutionLevel`, `requestComponents`, and structured `requestMetadata` (`M11-AUD-001`) |
| `Sources/JPIP/JPIPTransport.swift` | 104 | `4f905108ddfd9cff6b33660c70d25a29ec8a6934` | Retained / Fixed | `Sources/SwiftJ2KJPIP/JPIPTransport.swift` — added `JPIPLoopbackRegistry` and direct `JPIPTransport(server:)` in-process routing (`M11-AUD-002`) |
| `Sources/JPIP/JPIPServer.swift` | 555 | `32de21491fed93ed3c61d84c3de1dc5add0bc290` | Retained / Fixed | `Sources/SwiftJ2KJPIP/JPIPServer.swift` — registers/unregisters with `JPIPLoopbackRegistry`, reassembles valid codestreams in `generateImageData`, and enriches `generateMetadata` with image dimensions/components/bitDepth (`M11-AUD-002`) |
| `Sources/JPIP/JPIPDataBinGenerator.swift` | 299 | `53e74cf97efd267637a06d40e19b6f5c0e2ca765` | Retained / Fixed | `Sources/SwiftJ2KJPIP/JPIPDataBinGenerator.swift` — hardened marker/box length parsing with checked arithmetic and added `reassembleCodestream(from:)` (`M11-AUD-005`) |
| `Sources/JPIP/JPIPClientCacheManager.swift` | 1,175 | `69eadbf1bc1a84c4207124ca5c48034b9f9b0b10` | Retained / Fixed | `Sources/SwiftJ2KJPIP/JPIPClientCacheManager.swift` — fixed `compressInactiveEntries()` to clear uncompressed `dataBin.data` and added `decompressData(_:)` in `getDataBin` and `saveToPersistentStorage` (`M11-AUD-006`) |
| `Sources/JPIP/JPIPServerPush.swift` | 1,592 | `138f3cfc3aa9b329fa9d32486f9f932b12f3b2f0` | Retained / Fixed | `Sources/SwiftJ2KJPIP/JPIPServerPush.swift` — guarded `startTileX <= endTileX && startTileY <= endTileY` in `JPIPPrefetchEngine.tilesForViewport` (`M11-AUD-004`) |
| `Sources/JPIP/JP3DStreamingTypes.swift` | 538 | `24d2b4eb222278cdec08309fe0fd652a5a763bf1` | Retained / Fixed | `Sources/SwiftJ2KJPIP/JP3DStreamingTypes.swift` — guarded `xLo < xHi && yLo < yHi && zLo < zHi` in `JP3DViewport.intersection(_:)` (`M11-AUD-003`) |
| `Sources/JPIP/JPIPNetworkFramework.swift` | 584 | `0f9ecfbc5c16a39dd32dcaca8c362915e33acde7` | Retained / Fixed | `Sources/SwiftJ2KJPIP/JPIPNetworkFramework.swift` — fixed Swift 6 `@Sendable` closure capture in `receiveData(from:)` |
| `Sources/JPIP/JPIPRequest.swift` | 230 | `d05ac075277b34ad12aaa7c378af3c5101c9f1d3` | Retained | `Sources/SwiftJ2KJPIP/JPIPRequest.swift` |
| `Sources/JPIP/JPIPRequestQueue.swift` | 183 | `b5c2e3889caa0500985d157d39d00419d09f176f` | Retained | `Sources/SwiftJ2KJPIP/JPIPRequestQueue.swift` |
| `Sources/JPIP/JPIPResponse.swift` | 164 | `94ea7a25a3686006040bc3bf3eb2d342bca9cd60` | Retained | `Sources/SwiftJ2KJPIP/JPIPResponse.swift` |
| `Sources/JPIP/JPIPServerSession.swift` | 161 | `30bc7ca3a905cf4071461bf49d14c5998dfe709f` | Retained | `Sources/SwiftJ2KJPIP/JPIPServerSession.swift` |
| `Sources/JPIP/JPIPSessionManager.swift` | 384 | `277504c8cf490c673724d4852b2a41486514fb1a` | Retained | `Sources/SwiftJ2KJPIP/JPIPSessionManager.swift` |
| `Sources/JPIP/JPIPSessionPersistence.swift` | 1,110 | `e9d9632ce75ae739f868a4e9abd24bf52bbd8670` | Retained | `Sources/SwiftJ2KJPIP/JPIPSessionPersistence.swift` |
| `Sources/JPIP/JPIPPrecinctCache.swift` | 328 | `abf539a2900a5e6defa658170c530013939f08ed` | Retained | `Sources/SwiftJ2KJPIP/JPIPPrecinctCache.swift` |
| `Sources/JPIP/JPIPAdaptiveQualityEngine.swift` | 411 | `66553f2e8b247bf7a97f9f2826aa88750de03b75` | Retained | `Sources/SwiftJ2KJPIP/JPIPAdaptiveQualityEngine.swift` |
| `Sources/JPIP/JPIPBandwidthEstimator.swift` | 387 | `b68d339b765a3552c2a6bcf8a7ff249f201c3b3b` | Retained | `Sources/SwiftJ2KJPIP/JPIPBandwidthEstimator.swift` |
| `Sources/JPIP/JPIPBandwidthThrottle.swift` | 229 | `8c1d6bc34b2af47891a66615cb818d5e70a9cb7b` | Retained | `Sources/SwiftJ2KJPIP/JPIPBandwidthThrottle.swift` |
| `Sources/JPIP/JPIPMultiResolutionTileManager.swift` | 454 | `1f9ee8c145d2734e60b301f9594f6cd157f9667f` | Retained | `Sources/SwiftJ2KJPIP/JPIPMultiResolutionTileManager.swift` |
| `Sources/JPIP/JPIPProgressiveDeliveryScheduler.swift` | 561 | `5c9d4e5f59769f1d00d6a737dac08d0475b72869` | Retained | `Sources/SwiftJ2KJPIP/JPIPProgressiveDeliveryScheduler.swift` |
| `Sources/JPIP/JPIPProgressiveStreamingPipeline.swift` | 548 | `488f009d1d44934840e453d3007167cfbb899226` | Retained | `Sources/SwiftJ2KJPIP/JPIPProgressiveStreamingPipeline.swift` |
| `Sources/JPIP/JPIPHTJ2KSupport.swift` | 181 | `1614f0da3843bb69692afdbd5687a5ac89cd27f8` | Retained | `Sources/SwiftJ2KJPIP/JPIPHTJ2KSupport.swift` |
| `Sources/JPIP/JPIPTranscodingService.swift` | 263 | `ac41ac0aa458d21f13b6be83db77312d8dfe62d2` | Retained | `Sources/SwiftJ2KJPIP/JPIPTranscodingService.swift` |
| `Sources/JPIP/JPIPWebSocketClient.swift` | 330 | `68e0f23900b32a4b62b0f17e889edcd0eab5ba90` | Retained | `Sources/SwiftJ2KJPIP/JPIPWebSocketClient.swift` |
| `Sources/JPIP/JPIPWebSocketServer.swift` | 729 | `4a6ec13633eb56a22df4898374d1c62443aa4896` | Retained | `Sources/SwiftJ2KJPIP/JPIPWebSocketServer.swift` |
| `Sources/JPIP/JPIPWebSocketTransport.swift` | 795 | `09c2ce3d9b73a1e4918cb58ca17a9a75704679c9` | Retained | `Sources/SwiftJ2KJPIP/JPIPWebSocketTransport.swift` |
| `Sources/JPIP/JP3DCacheManager.swift` | 306 | `8f9d468570e23786473802d125b286f8edc799a3` | Retained | `Sources/SwiftJ2KJPIP/JP3DCacheManager.swift` |
| `Sources/JPIP/JP3DJPIPClient.swift` | 313 | `00e082952b7712d7cc204dcdd20e85fba17019c4` | Retained | `Sources/SwiftJ2KJPIP/JP3DJPIPClient.swift` |
| `Sources/JPIP/JP3DJPIPServer.swift` | 425 | `a1d66605d3e6551fe67b2de49c4313269cba66bf` | Retained | `Sources/SwiftJ2KJPIP/JP3DJPIPServer.swift` |
| `Sources/JPIP/JP3DProgressiveDelivery.swift` | 345 | `f09a2c2cbfe3cf79c48ec41e86007b8e0d63020e` | Retained | `Sources/SwiftJ2KJPIP/JP3DProgressiveDelivery.swift` |
| *(New in Milestone 11)* | — | — | New (Bridge) | `Sources/SwiftJ2K/LegacyImageBridge.swift` — `J2KImage`, `J2KComponent`, `J2KEncoder`, `J2KDecoder`, `J2KTranscoder`, `J2KFormatDetector` |
| *(New in Milestone 11)* | — | — | New (`API-13`) | `Sources/SwiftJ2KJPIP/JPIPCodecAPI.swift` — `JPIPSessionConfiguration`, `JPIPDeliveryMode`, `JPIPStreamingOptions`, `JPIPViewWindow`, `JPIPDeliveredImage`, `JPIPDeliveredVolumeSliceBins`, `JPIPStreamingSession` |

### 2.2 Predecessor Defects Identified and Fixed in Milestone 11

| Finding ID | Predecessor location (`7acc9ae4`) | Defect description | Fix in `SwiftJ2KJPIP` & regression test |
| --- | --- | --- | --- |
| `M11-AUD-001` | `Sources/JPIP/JPIP.swift:92, 111, 152, 177, 203` | Every image retrieval entry point in `JPIPClient` (`requestImage`, `requestRegion`, `requestProgressiveQuality`, `requestResolutionLevel`, `requestComponents`) unconditionally threw `J2KError.notImplemented(...)` after receiving `JPIPResponse`, which was the root cause of `DICOMKit` Finding F1 (`DICOMJPIPClient` retrieval unavailable). | Implemented `decodeImageResponse` in `JPIPClient`, recording received data bins in the session cache model and decoding full images, spatial regions, reduced resolution levels, progressive quality layers, and component subsets via `J2KDecoder.decodeSync`. Verified by `JPIPContractTests.testJPIPClientEndToEndImageRegionQualityResolutionAndComponents` and `DICOMJPIPClientEndToEndRetrievalTests`. |
| `M11-AUD-002` | `Sources/JPIP/JPIPServer.swift`, `Sources/JPIP/JPIPTransport.swift`, `Tests/JPIPTests/JPIPClientServerIntegrationTests.swift:16` | `JPIPServer` did not bind a TCP socket or register an in-process loopback endpoint, while `JPIPTransport` always used `URLSession` over TCP and `JPIPServer.generateImageData` concatenated raw data-bin payloads without `SOC`/`EOC` codestream framing. Consequently, `JPIPClientServerIntegrationTests` was completely disabled via `override class var defaultTestSuite`. | Added `JPIPLoopbackRegistry` for in-process `localhost`/`127.0.0.1` server routing by port plus `JPIPClient(server:)` / `JPIPTransport(server:)`, updated `JPIPServer.generateImageData` to reassemble valid codestreams from data bins, and re-enabled `JPIPClientServerIntegrationTests` (`9/9` passing). |
| `M11-AUD-003` | `Sources/JPIP/JP3DStreamingTypes.swift:192`, `Tests/JP3DTests/JP3DStreamingTests.swift:96` | `JP3DViewport.intersection(_:)` evaluated `(xLo..<xHi).isEmpty` *after* constructing `xLo..<xHi`, trapping at runtime (`Fatal error: Range requires lowerBound <= upperBound`) whenever two viewports were disjoint (`xLo > xHi`). `JP3DViewportTests.testViewportNoIntersection` was skipped in CI. | Guarded `xLo < xHi && yLo < yHi && zLo < zHi` before forming `Range` values and un-skipped `JP3DViewportTests.testViewportNoIntersection` (`4/4` passing). |
| `M11-AUD-004` | `Sources/JPIP/JPIPServerPush.swift:590`, `Tests/JPIPTests/JPIPServerPushTests.swift:318` | `JPIPPrefetchEngine.tilesForViewport` computed `startTileX = max(0, viewport.x / tileWidth)` and `endTileX = min(tilesX - 1, ...)`, trapping in `startTileX...endTileX` when velocity prediction projected a viewport past the right or bottom image boundary (`startTileX > endTileX`). `JPIPServerPushManagerTests.testDequeuePushItems` was skipped in CI. | Guarded `startTileX <= endTileX && startTileY <= endTileY` before forming `startTileY...endTileY` and `startTileX...endTileX`, and un-skipped `JPIPServerPushManagerTests.testDequeuePushItems` (`11/11` passing). |
| `M11-AUD-005` | `Sources/JPIP/JPIPDataBinGenerator.swift:180, 211, 249` | `findCodestreamStart`, `extractMainHeader`, and `extractTileParts` used unchecked integer shifts and additions (`Int(data[offset]) << 24 \| ...`, `offset + Int(tilePartLength)`) that could overflow or trap on crafted box/SOT lengths. | Replaced with checked `multipliedReportingOverflow` / `addingReportingOverflow` arithmetic and added `reassembleCodestream(from:)`. Verified by `JPIPContractTests.testDataBinGeneratorCheckedArithmeticAndReassembly`. |
| `M11-AUD-006` | `Sources/JPIP/JPIPClientCacheManager.swift:790, 585` | `compressInactiveEntries()` stored `entry.compressedData` and decremented `totalMemoryUsage` without clearing `entry.dataBin.data`, and `getDataBin` returned `entry.dataBin` without decompressing `entry.compressedData`. | `compressInactiveEntries()` now replaces `entry.dataBin.data` with empty `Data()` when compressed, and `getDataBin` / `saveToPersistentStorage` transparently decompress `entry.compressedData` via `decompressData(_:)`. Verified by `JPIPContractTests.testCacheManagerCompressInactiveEntriesReclaimsMemoryAndDecompressesOnRead`. |

---

## 3. Exit Gate 1 — `DICOMKit` JPIP Consumer Compatibility Verification

Per `IMPLEMENTATION.md` lines 88, 96, and 157, `DICOMKit` consumes `JPIP` in two targets:
1. `Sources/DICOMKit/DICOMJPIPClient.swift`
2. `Sources/dicom-jpip/main.swift` and `Sources/dicom-jpip/JPIPSyntaxes.swift`

Without modifying the external `/Users/raster/Documents/DICOMKit_22Oct/DICOMKit` repository (`AGENTS.md`), `DICOMJPIPClient.swift`, `JPIPSyntaxes.swift`, `Tests/DICOMKitTests/JPIPTests.swift`, and `Tests/dicom-jpipTests/JPIPSyntaxesTests.swift` were copied into an isolated verification package depending on `/Users/raster/Documents/SwiftJ2K` (`SwiftJ2K`, `SwiftJ2K3D`, `SwiftJ2KJPIP`) with `import JPIP` / `import J2KCore` replaced by `import SwiftJ2KJPIP` / `import SwiftJ2K` and `@available(*, unavailable)` removed from `fetchImage`, `fetchRegion`, `fetchProgressiveQuality`, and `fetchResolutionLevel`:

- **Command**: `swift test --package-path <scratch>/DICOMKitJPIPCheck`
- **Outcome**: Exit `0` — all `DICOMKit` JPIP source files compiled cleanly, **6 / 6** XCTests in `dicom_jpipTests` (`JPIPSyntaxesTests`) passed in `0.001s`, and **43 / 43** Swift Testing tests across **10 suites** in `DICOMKitTests` (including `DICOMJPIPClientEndToEndRetrievalTests` exercising `fetchImage`, `fetchRegion`, `fetchProgressiveQuality`, and `fetchResolutionLevel` against a live `JPIPServer`) passed in `0.028s`.
- **Permanent In-Repo Regression Gate**: `JPIPContractTests.testDICOMKitJPIPConsumerSurfaceCompatibility` in [`Tests/SwiftJ2KJPIPTests/JPIPContractTests.swift`](../Tests/SwiftJ2KJPIPTests/JPIPContractTests.swift) permanently exercises the exact `JPIPServer.Configuration`, `JPIPServer`, `JPIPClient`, and `J2KImage` signatures used by `DICOMKit`.

---

## 4. Exit Gate 2 — Test Suite and Verification Results

| Gate | Command | Result |
| --- | --- | --- |
| Common contract SHA-256 integrity | `(cd Documentation && shasum -a 256 -c COMMON_CONTRACT_SHA256.txt)` | Exit `0` — all 7 contract files (`CLI_CONTRACT.md`, `COMMON_API.md`, `MEMORY_CONTRACT.md`, `PERFORMANCE.md`, `PLATFORMS.md`, `SUITE_POLICY.md`, `TESTING.md`) `OK` |
| `SwiftJ2KJPIPTests` JPIP test suite | `swift test --filter SwiftJ2KJPIPTests` | Exit `0` — **544 / 544** XCTest methods passed (`0` failures, `0` skips) across 18 test files (including re-enabled `JPIPClientServerIntegrationTests`, `JP3DHTj2KJPIPWorkflowTests`, `JP3DViewportTests.testViewportNoIntersection`, `JPIPServerPushManagerTests.testDequeuePushItems`, and `JPIPContractTests`) |
| Full package test suite (`SwiftJ2KTests` + `SwiftJ2K3DTests` + `SwiftJ2KJPIPTests`) | `swift test` | Exit `0` — **544 / 544** `SwiftJ2KJPIPTests` + **490 / 490** `SwiftJ2K3DTests` + **122 / 122** `SwiftJ2KTests` passed (`0` failures) |
| Release build | `swift build -c release` | Exit `0` — `SwiftJ2K`, `SwiftJ2K3D`, `SwiftJ2KJPIP`, and `swiftj2k-cli` built cleanly in release mode |
| CLI regression suite | `python3 Scripts/test-cli.py --binary .build/out/Products/Release/swiftj2k-cli --output <dir>` | Exit `0` — **197 / 197** process checks passed |

---

## 5. Controlled Release Benchmarks (`swift run -c release`)

Measured on Apple M3 Max (`arm64-apple-macosx26.0`, Swift `6.4-dev`, `-c release`, 11 iterations after warmup) on a lossless 8-bit greyscale Part 1 `.jp2` image (`128 × 128` = 16,384 pixels, 2,402 compressed bytes, 3 data bins):

| Operation | Median wall-clock (ms) | Notes |
| --- | ---: | --- |
| `JPIPDataBinGenerator.generateDataBins` | `0.001` | Parses JP2 boxes and `SOC`/`SOT`/`SOD`/`EOC` markers into `JPIPDataBin` packets |
| `JPIPDataBinGenerator.reassembleCodestream` | `0.001` | Reconstructs contiguous JPEG 2000 codestream from header and tile data bins |
| `JPIPClient.requestImage` (`128 × 128` loopback) | `1.489` | Full session/channel negotiation + data-bin generation + lossless decode |
| `JPIPClient.requestRegion` (`64 × 64` ROI loopback) | `1.494` | Spatial view-window request (`roff=16,16`, `rsiz=64,64`) + region decode |
| `JPIPTranscodingService.transcode` (`J2K → HTJ2K`) | `1.363` | On-the-fly lossless Part 1 to Part 15 container/codestream transcoding |

---

## 6. Remaining Limitations and Open Programme Gates

1. **Continuous-Integration Precondition (`Contract 0.10.0`)**: GitHub Actions billing on `Raster-Lab` remains locked (`steps=0`), so all verification evidence in this milestone is local execution evidence on macOS 26.4 (`arm64`).
2. **Loopback vs. Remote Socket Server Binding**: `JPIPServer` routes in-process `localhost`/`127.0.0.1` traffic deterministically via `JPIPLoopbackRegistry` (and `JPIPNetworkFramework` provides Apple `Network.framework` `NWListener`/`NWConnection` primitives), while `JPIPTransport` uses `URLSession` for non-loopback remote HTTP/HTTPS servers.
3. **Downstream `DICOMKit` Repository Cutover**: Per `AGENTS.md` and `IMPLEMENTATION.md` Decision M2, `/Users/raster/Documents/DICOMKit_22Oct/DICOMKit` was not modified during this task; re-pointing `DICOMKit`'s `Package.swift` and removing `@available(*, unavailable)` in `DICOMJPIPClient.swift` belongs to a separately assigned `DICOMKit` migration task.

---

## 7. Milestones 1–12 Audit Remediation Update — 29 October 2026 (Phase R1 Accepted at `c4706d58`; Phase R2 Submitted Pending Audit; Phase R3 Open)

Independent audit review at `b76e60a` / `24b1881` established that Milestone 11 is **not yet accepted as complete** for full ISO/IEC 15444-9 network/data-bin/3D/WebSocket conformance. Canonical tracking lives in [Engineering/Remediation/STATUS.md](Engineering/Remediation/STATUS.md) (`Evidence/R1/{pre,post}-fix-receipts.txt`, `Evidence/R2/{pre,post}-fix-receipts.txt`, `Evidence/R2/test-summary.txt`).

- **Phase R1 (`R1_ACCEPTED` by Codex at `c4706d58cc5dde4828ea71f324817590f0671e78`, PR #28 GitHub Actions run `40864296519` all `7/7` jobs passed)**:
  - **`F03` & `M12-CX-02` (`R1_ACCEPTED`)**: Bounded `JPIPViewWindow.resolutionLevel` to `0...32` and validated spatial region coordinates with checked addition (`addingReportingOverflow`) across `JPIPViewWindow` and `JPIPClient`.
  - **`F05` (`R1_ACCEPTED`)**: Enforced pre-allocation `ResourceLimits` (`maximumCompressedBytes`, `maximumDecodedBytes`, `maximumWorkspaceBytes`, `maximumMemoryBytes`) and monotonic `deadlineSeconds` across `JPIPStreamingSession.deliverImage` and `deliverVolumeRegion`, preserving `CodecError(.resourceLimitExceeded, ...)` through `J2KDecoder.decodeWithInfo`.
  - **`F06` & `F13` (`R1_ACCEPTED`)**: `JPIPStreamingSession.deliverImage` reports `.lossy` whenever the codestream uses irreversible transforms or the view window requests reduced resolution, truncated quality layers, or a component subset; both `deliverImage` and `deliverVolumeRegion` re-check cancellation and deadlines after `.completed` callbacks.
  - **Accepted `SwiftJ2KJPIPTests` count at Phase R1 (`c4706d58`)**: `544` XCTest methods + `4` Swift Testing `@Test` declarations (`R1JPIPRemediationTests.swift`) = **`548` tests passing** across Linux debug/release and macOS debug/ASan/TSan in PR #28 run `40864296519`.
- **Phase R2 (`submitted` on `antigravity/r2-semantics-remediation`; `Codex acceptance: pending independent audit`)**:
  - **`F07` (`submitted`)**: Retained JP2/JPH/JPX container header framing (`ihdr`, `pclr`, `cmap`, `cdef`, `colr`) in `JPIPDataBinGenerator` metadata bin `0` across generation, reassembly, and server-side HTJ2K `codingPreference` transcoding, and reconciled container palette/channel/ICC semantics in `J2KDecoder` so `JPIPStreamingSession.deliverImage` matches direct `Decoder().decode` sample-for-sample.
  - **`F09` (`submitted`)**: Enforced `CopyPolicy` (`.requireSharedStorage` rejected with `CodecError(.incompatibleImageLayout, ...)` across `deliverImage` and `deliverVolumeRegion`) and `ExecutionPolicy` (propagating `executionPolicy` into `J2KDecoder.decodeWithInfo` and `VolumeDecoder`), and replaced fabricated `data.count / 16` discarded-metadata heuristics with actual container/codestream `discardedMetadataCount`/`Bytes`/`Kinds`, `CopyEvent` records, and measured `peakWorkspaceBytes`.
  - **`F10` (`submitted`)**: Composed `JPIPViewWindow` constraints (`region` + `resolutionLevel` + `maxQualityLayers` + ordered `components`) simultaneously instead of via mutually exclusive `if / else if` branches, validated spatial and component bounds deterministically (`CodecError(.invalidArgument, ...)`), and enforced `JPIPSessionConfiguration` `maxCachedDataBins`, `maxCacheSizeBytes`, and stateless `.full` vs cached `.incremental` `deliveryMode`.
  - **Executed `SwiftJ2KJPIPTests` count at Phase R2 (`submitted`)**: `544` XCTest methods + `8` Swift Testing `@Test` declarations (`4` in `R1JPIPRemediationTests.swift` + `4` in `R2JPIPRemediationTests.swift`) = **`552` tests passing locally**.
- **Remaining Open Milestone 11 Gap (Phase R3 — Not Claimed Closed)**:
  - **`F04` (Phase R3 — `open`)**: Real ISO/IEC 15444-9 HTTP/socket and WebSocket network/data-bin exchange and non-simulated 3D JPIP delivery.
