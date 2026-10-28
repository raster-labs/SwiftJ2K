# Milestone 10 — `SwiftJ2K3D` Volumetric JPEG 2000 (JP3D / ISO/IEC 15444-10)

**Status:** Implemented on branch `antigravity/milestone10-swiftj2k3d` from `origin/main` (`ea30b51`) against pinned predecessor `Raster-Lab/J2KSwift` [`7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca`](https://github.com/Raster-Lab/J2KSwift/commit/7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca).
**Contract:** `0.10.0` (verified byte-identical against `Documentation/COMMON_CONTRACT_SHA256.txt`).
**Toolchain:** Apple Swift `6.4-dev` (`Swift 6` language mode, complete concurrency checking) on macOS 26.4 (`arm64-apple-macosx26.0`, Apple M3 Max).

---

## 1. Scope and Summary

Milestone 10 migrates and adapts the predecessor's volumetric JPEG 2000 (ISO/IEC 15444-10 / JP3D) product (`Sources/J2K3D`, 30 files / 8,923 lines), its core volume types (`Sources/J2KCore/J2KVolume.swift`, `Sources/J2KCore/J2KVolumeMetadata.swift`), and its Metal-accelerated 3D wavelet transform (`Sources/J2KMetal/JP3DMetalDWT.swift`) into the retained library product **`SwiftJ2K3D`** per Decision M2 (`IMPLEMENTATION.md` lines 74, 87, 131, 141, 149) and Contract **API-13**:

1. **Core Volumetric Types (`Sources/SwiftJ2K/Volume.swift`)**:
   - `J2KVolume`, `J2KVolumeComponent`, `J2KVolumeMetadata`, `J2KVolumeModality`, and `J2KError` (bridged to `CodecError` via `asCodecError`) reside in `SwiftJ2K` and are re-exported by `SwiftJ2K3D` (`@_exported import SwiftJ2K`), so consumers importing `SwiftJ2K` or `SwiftJ2K3D` (or both, as `DICOMKit` does after replacing `J2KCore` and `J2K3D`) have seamless access to all volumetric types.
   - Internal `package enum Slice2DBridge` bridges per-slice 2D lossless and lossy Part 1 (EBCOT) and Part 15 (HTJ2K) encoding and decoding directly into `SwiftJ2K`'s `Encoder`, `Decoder`, `Part1Pipeline`, and `Transcoder`.
   - Extended `Tier2.decodePacketsMulti` and `Part1Pipeline.decode` (`Sources/SwiftJ2K/Codec/Tier2.swift`, `Sources/SwiftJ2K/Codec/Part1Pipeline.swift`) with an optional `maxQualityLayers: Int? = nil` parameter to support multi-layer quality truncation during progressive 3D decoding.

2. **Retained `SwiftJ2K3D` Library Product (`Sources/SwiftJ2K3D/`)**:
   - **Volumetric Geometry, Tiling, and 3D Wavelet Transform**: `JP3DRegion`, `JP3DTile`, `JP3DPrecinct`, `JP3DTilingConfiguration`, `JP3DTileDecomposer`, `JP3DWaveletTransform` (separable 3D reversible 5/3 LeGall and irreversible 9/7 CDF lifting with symmetric, periodic, and zero-padding boundaries, arbitrary `levelsX`, `levelsY`, `levelsZ`), and `JP3DMetalDWT` (Metal GPU-accelerated 3D DWT with automatic CPU fallback).
   - **Rate Control, Packet Formation, and Codestream Framing**: `JP3DRateController`, `JP3DPacketSequencer` (all five 3D progression orders: `LRCPS`, `RLCPS`, `PCRLS`, `SLRCP`, `CPRLS`), `JP3DCodestreamBuilder`, `JP3DCodestreamParser`, and `JP3DStreamWriter`.
   - **Slice-Stack Fast Path (`JP3DSliceStackCodec`)**: Encodes, decodes, and transcodes 3D tiles slice-by-slice along Z using `SwiftJ2K`'s accelerated 2D Part 1 and Part 15 (HTJ2K) pipelines (`"J3DS"` v2 tile framing), with optional lag-1 Z-axis inter-slice residual prediction (`JP3DZDeltaMode`: `.auto`, `.always`, `.never`).
   - **Volumetric Encoder, Decoder, ROI Decoder, Progressive Decoder, HTJ2K, Transcoder, and Multi-Spectral Codec**: `JP3DEncoder`, `JP3DDecoder`, `JP3DROIDecoder`, `JP3DProgressiveDecoder`, `JP3DHTJ2KConfiguration`/`JP3DHTJ2KBlockCoder`/`JP3DHTJ2KValidator`, `JP3DTranscoder`, `JP3DMultiSpectralEncoder`, `JP3DMultiSpectralDecoder`, `JP3DSpectralAnalysis`, plus all `+PreWarm` and `+ProgressStream` extensions.

3. **Contract API-13 Volumetric Extension Surface (`Sources/SwiftJ2K3D/VolumeCodecAPI.swift`)**:
   - Rationale (`API-13`): Single-image `Encoder`/`Decoder` operate on 2D `ImageDescriptor` (`width × height`), which cannot represent 3D voxel grids (`width × height × depth`), 3D tile decompositions (`tileSizeX × tileSizeY × tileSizeZ`), 3D wavelet levels (`levelsX, levelsY, levelsZ`), 3D regions of interest (`JP3DRegion`), or Z-axis inter-slice prediction (`JP3DZDeltaMode`).
   - Provides immutable, `Sendable`, contract-aligned `VolumeEncoder` (`VolumeEncoderConfiguration`, `VolumeEncodeOptions`, `EncodedVolume`), `VolumeDecoder` (`VolumeDecoderConfiguration`, `VolumeDecodeOptions`, `DecodedVolume`, `inspect(_:options:) -> VolumeInfo`), and `VolumeTranscoder` (`transcode(_:to:options:) -> EncodedVolume`), enforcing `ResourceLimits`, `ExecutionPolicy`, `MetadataPolicy`, cooperative task cancellation (`Task.checkCancellation()`), `ProgressUpdate` callbacks, and `OperationReport` generation.

---

## 2. Predecessor Audit and File-by-File Dispositions (`7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca`)

### 2.1 File-by-File Inventory and Dispositions

All 30 files in `Sources/J2K3D` (8,923 lines), 2 volumetric files in `Sources/J2KCore` (514 lines), and 1 volumetric Metal file in `Sources/J2KMetal` (1,430 lines) at `7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca` were audited and migrated:

| Predecessor file (`7acc9ae4`) | Lines | Git blob SHA | Disposition | Successor file & notes |
| --- | ---: | --- | --- | --- |
| `Sources/J2KCore/J2KVolume.swift` | 355 | `8f1b20e8fe942ce1a66e30f3ce33690b17f0ea25` | Retained / Adapted | `Sources/SwiftJ2K/Volume.swift` — `J2KVolume`, `J2KVolumeComponent` with checked arithmetic in `validate()`, `voxelCount`, `sizeInBytes` |
| `Sources/J2KCore/J2KVolumeMetadata.swift` | 159 | `6632d15de5a2dd7488c7183c9e4b3900ce62e3d5` | Retained / Adapted | `Sources/SwiftJ2K/Volume.swift` — `J2KVolumeMetadata`, `J2KVolumeModality` |
| `Sources/J2K3D/J2K3D.docc/J2K3D.md` | 44 | `49360930c19c4dc5b185c05031c2a1d83ecc2adc` | Retained / Adapted | `Sources/SwiftJ2K3D/SwiftJ2K3D.docc/SwiftJ2K3D.md` |
| `Sources/J2K3D/JP3DTypes.swift` | 241 | `54d490dad681da6d9185665d041df1c7c4a4e309` | Retained | `Sources/SwiftJ2K3D/JP3DTypes.swift` — `JP3DRegion`, `JP3DTile`, `JP3DPrecinct`; `@_exported import SwiftJ2K` |
| `Sources/J2K3D/JP3DConfiguration.swift` | 438 | `7ccf2ed79cf30c3de8e6a3330c011bbe9ebeaadf` | Retained | `Sources/SwiftJ2K3D/JP3DConfiguration.swift` — `JP3DWaveletFilter`, `JP3DTransformConfiguration`, `JP3DProgressionOrder`, `JP3DCompressionMode`, `JP3DZDeltaMode`, `J2K3DCoefficients`, `JP3DSubband` |
| `Sources/J2K3D/JP3DTiling.swift` | 188 | `3240f5a9ba42e78dffb8852e3010490c915f86bf` | Retained | `Sources/SwiftJ2K3D/JP3DTiling.swift` — `JP3DTilingConfiguration`, `JP3DTileDecomposer` (handles signed 8/16/32-bit two's-complement voxel extraction) |
| `Sources/J2K3D/JP3DWaveletTransform.swift` | 735 | `99ee4cf776f47ea771f2ceedb4cf73c391cc8be4` | Retained | `Sources/SwiftJ2K3D/JP3DWaveletTransform.swift` — 3D forward and inverse 5/3 and 9/7 wavelet transform actor |
| `Sources/J2K3D/JP3DRateControl.swift` | 228 | `c8c33e9b3cab3f8a83619b163f62b3e26a6e8965` | Retained | `Sources/SwiftJ2K3D/JP3DRateControl.swift` — dead-zone quantiser, PSNR step calculation, multi-layer truncation |
| `Sources/J2K3D/JP3DPacketFormation.swift` | 478 | `0a47384bd47621012b8e7ab3577672b56cbb7a0f` | Retained / Fixed | `Sources/SwiftJ2K3D/JP3DPacketFormation.swift` — `JP3DPacket`, `JP3DPacketSequencer`, `JP3DCodestreamBuilder` (fixed `M10-AUD-002`: `appendSIZ` now sets bit 7 `0x80` of `Ssiz` when `signed == true`) |
| `Sources/J2K3D/JP3DCodestreamParser.swift` | 419 | `520e927b9f8ea7c1f01ec8ae81c778a4ea021ffc` | Retained / Fixed | `Sources/SwiftJ2K3D/JP3DCodestreamParser.swift` — `JP3DSIZInfo`, `JP3DCODInfo`, `JP3DParsedTile`, `JP3DCodestreamParser` (hardened with checked arithmetic, `M10-AUD-005`) |
| `Sources/J2K3D/JP3DStreamWriter.swift` | 433 | `3c85dcbf91786c5a381b1fce3b858fed610518fd` | Retained | `Sources/SwiftJ2K3D/JP3DStreamWriter.swift` — incremental tile-by-tile JP3D stream writer |
| `Sources/J2K3D/JP3DSliceStackCodec.swift` | 1,314 | `444a0ff22e447a1924f1f150f5b6f91ecb996075` | Retained / Fixed | `Sources/SwiftJ2K3D/JP3DSliceStackCodec.swift` — `"J3DS"` per-slice 2D Part 1 / HTJ2K codec with Z-delta prediction and wavelet-domain slice transcoding (fixed `M10-AUD-003`: signed 16-bit residual slices for negative Z-delta residuals) |
| `Sources/J2K3D/JP3DEncoder.swift` | 621 | `23a28c81d2dab0a8e99ceb7bc2664104af7a71bd` | Retained / Fixed | `Sources/SwiftJ2K3D/JP3DEncoder.swift` — `JP3DEncoder`, `JP3DEncoderConfiguration`, `JP3DEncoderResult` (fixed `M10-AUD-001` signed packing and `M10-AUD-002` `SIZ` signed signalling) |
| `Sources/J2K3D/JP3DDecoder.swift` | 680 | `30bd7bea2f073ac4b87c4f9db1c6f099a8d4785c` | Retained / Fixed | `Sources/SwiftJ2K3D/JP3DDecoder.swift` — `JP3DDecoder`, `JP3DDecoderConfiguration`, `JP3DDecoderResult`, partial-resolution and ROI convenience overloads, `peekMetadata` (fixed `M10-AUD-001`: signed voxel clamping and two's-complement serialisation) |
| `Sources/J2K3D/JP3DROIDecoder.swift` | 570 | `62b125efd854f8fc534877072548f213d928ed9d` | Retained / Fixed | `Sources/SwiftJ2K3D/JP3DROIDecoder.swift` — 3D spatial region-of-interest decoder (fixed `M10-AUD-001` signed voxel clamping and serialisation) |
| `Sources/J2K3D/JP3DProgressiveDecoder.swift` | 300 | `18bba94f65f227e517b8dfd6b7b1ca58638a93c2` | Retained | `Sources/SwiftJ2K3D/JP3DProgressiveDecoder.swift` — progressive quality-layer and resolution-level volumetric delivery |
| `Sources/J2K3D/JP3DHTJ2K.swift` | 491 | `c3092737972f6ee01b08cde1dbe9b025b33c4b4c` | Retained | `Sources/SwiftJ2K3D/JP3DHTJ2K.swift` — `JP3DHTJ2KConfiguration`, `JP3DHTJ2KBlockMode`, `JP3DHTJ2KEncodedTile`, `JP3DHTJ2KBlockCoder`, `JP3DHTJ2KValidator` |
| `Sources/J2K3D/JP3DTranscoder.swift` | 618 | `e74472d107f5d234eae153d6482b62e462b071f6` | Retained / Fixed | `Sources/SwiftJ2K3D/JP3DTranscoder.swift` — lossless and lossy JP3D Part 1 ↔ HTJ2K transcoder with wavelet-domain slice-stack fast path |
| `Sources/J2K3D/JP3DMultiSpectralTypes.swift` | 276 | `fe9e12c9c5e0f653bd0165c1bb9c4361a022e33b` | Retained | `Sources/SwiftJ2K3D/JP3DMultiSpectralTypes.swift` — spectral band, wavelength, and multi-spectral volume types |
| `Sources/J2K3D/JP3DMultiSpectralEncoder.swift` | 235 | `e054d45a4bdc6a7656ff8298cc83c524fd63a5b2` | Retained / Fixed | `Sources/SwiftJ2K3D/JP3DMultiSpectralEncoder.swift` — multi-spectral 3D encoder with inter-band spectral DWT (fixed `M10-AUD-004` spatial dimension preservation in `"JP3M"` band header) |
| `Sources/J2K3D/JP3DMultiSpectralDecoder.swift` | 165 | `aee3dec8bbbdd7d9f90a1dff5a77d12ee2ec38c7` | Retained / Fixed | `Sources/SwiftJ2K3D/JP3DMultiSpectralDecoder.swift` — multi-spectral 3D decoder with `"JP3M"` and legacy `"JP3D"` band header support |
| `Sources/J2K3D/JP3DSpectralAnalysis.swift` | 203 | `6f69d978c16b537bd404399689358eda801f0988` | Retained | `Sources/SwiftJ2K3D/JP3DSpectralAnalysis.swift` — NDVI/NDWI spectral index computation, correlation matrix, band classification |
| `Sources/J2K3D/JP3DEncoder+PreWarm.swift` | 35 | `a70d2d7f248ee8937003df43336aaae5f2c70986` | Retained | `Sources/SwiftJ2K3D/JP3DEncoder+PreWarm.swift` |
| `Sources/J2K3D/JP3DEncoder+ProgressStream.swift` | 22 | `27461d30b236f19ec837ba93aace5d96b077d6dc` | Retained | `Sources/SwiftJ2K3D/JP3DEncoder+ProgressStream.swift` |
| `Sources/J2K3D/JP3DDecoder+ProgressStream.swift` | 58 | `64565458da6d488d639f3e59deced7bd3b6f6be1` | Retained | `Sources/SwiftJ2K3D/JP3DDecoder+ProgressStream.swift` |
| `Sources/J2K3D/JP3DROIDecoder+ProgressStream.swift` | 22 | `d3bdd7914d778fabc258672c1b9f308350bfcf69` | Retained | `Sources/SwiftJ2K3D/JP3DROIDecoder+ProgressStream.swift` |
| `Sources/J2K3D/JP3DProgressiveDecoder+PreWarm.swift` | 17 | `f33a732e5fda5406d0e5566c99f29f9577d24d81` | Retained | `Sources/SwiftJ2K3D/JP3DProgressiveDecoder+PreWarm.swift` |
| `Sources/J2K3D/JP3DStreamWriter+PreWarm.swift` | 17 | `ac74e028456fb2350b29b307978ab818099445f8` | Retained | `Sources/SwiftJ2K3D/JP3DStreamWriter+PreWarm.swift` |
| `Sources/J2K3D/JP3DStreamWriter+ProgressStream.swift` | 22 | `496b4a0945c430b9e4f35c03d0c5544fd9d8faff` | Retained | `Sources/SwiftJ2K3D/JP3DStreamWriter+ProgressStream.swift` |
| `Sources/J2K3D/JP3DTranscoder+PreWarm.swift` | 19 | `3042dc33faecade3c0af2a7af8cf58bc83d7240b` | Retained | `Sources/SwiftJ2K3D/JP3DTranscoder+PreWarm.swift` |
| `Sources/J2K3D/JP3DMultiSpectralEncoder+PreWarm.swift` | 17 | `a7a50c43b50078e277a8a066fbe95a49189f72b4` | Retained | `Sources/SwiftJ2K3D/JP3DMultiSpectralEncoder+PreWarm.swift` |
| `Sources/J2K3D/JP3DMultiSpectralDecoder+PreWarm.swift` | 17 | `422008374e533999182efc43169d95d303fdca20` | Retained | `Sources/SwiftJ2K3D/JP3DMultiSpectralDecoder+PreWarm.swift` |
| `Sources/J2KMetal/JP3DMetalDWT.swift` | 1,430 | `8eccda21afc91c1f516c9b008bd4c36b1c26ec36` | Retained / Adapted | `Sources/SwiftJ2K3D/JP3DMetalDWT.swift` — Metal-accelerated 3D 5/3 and 9/7 DWT with runtime MSL compilation and CPU fallback |
| *(New in Milestone 10)* | — | — | New (`API-13`) | `Sources/SwiftJ2K3D/VolumeCodecAPI.swift` — `VolumeInfo`, `VolumeEncoder`, `VolumeDecoder`, `VolumeTranscoder`, `VolumeEncoderConfiguration`, `VolumeEncodeOptions`, `EncodedVolume`, `VolumeDecoderConfiguration`, `VolumeDecodeOptions`, `DecodedVolume` |

### 2.2 Predecessor Defects Identified and Fixed in Milestone 10

| Finding ID | Predecessor location (`7acc9ae4`) | Defect description | Fix in `SwiftJ2K3D` & regression test |
| --- | --- | --- | --- |
| `M10-AUD-001` | `JP3DDecoder.swift:448`, `JP3DROIDecoder.swift:525`, `JP3DEncoder.swift:593` | `assembleVolumeComponents` clamped reconstructed voxel values to `[0, maxVal]` (`let clamped = max(0, min(maxVal, buffer[i]))`), clamping all negative signed CT Hounsfield units (e.g. `-1024` air, `-500` lung) to `0` on decode. | Clamps signed components to `[-2^(B-1), 2^(B-1) - 1]` and packs two's-complement 8/16/32-bit little-endian samples. Verified by `VolumeContractTests.testSigned16BitCTHounsfieldLosslessRoundTrip`, `testSigned16BitCTHounsfieldROIDecoderRoundTrip`, and `testSigned8BitLosslessRoundTrip`. |
| `M10-AUD-002` | `JP3DPacketFormation.swift:318` | `JP3DCodestreamBuilder.appendSIZ` wrote `UInt8(bitDepth - 1)` for `Ssiz` without setting bit 7 (`0x80`) when `signed == true`, causing `JP3DCodestreamParser` to always read `siz.signed == false`. | `appendSIZ` now encodes `UInt8((bitDepth - 1) & 0x7F) \| (signed ? 0x80 : 0x00)`, and `JP3DEncoder`/`JP3DTranscoder` pass `volume.components[0].signed`. Verified by `VolumeContractTests.testSigned16BitCTHounsfieldLosslessRoundTrip`. |
| `M10-AUD-003` | `JP3DSliceStackCodec.swift:312` | When `zDeltaMode` was active on unsigned volumes, inter-slice residual slices (`z >= 1`) were encoded as unsigned slices after wrapping negative residuals modulo `65536` (`-1 -> 65535`), destroying compression efficiency and corrupting bit depths `< 16`. | Encodes Z-delta residual slices (`z >= 1`) as signed 16-bit 2D slices via `Slice2DBridge.encodeSlice(..., bitDepth: 16, signed: true)` while retaining backward compatibility with unsigned v2 residual streams on decode. Verified by `VolumeContractTests.testUnsignedZDeltaNegativeResidualRoundTrip` and `testSigned16BitCTHounsfieldHTJ2KAndZDeltaRoundTrip`. |
| `M10-AUD-004` | `JP3DMultiSpectralEncoder.swift:178`, `JP3DMultiSpectralDecoder.swift:118` | The 12-byte `"JP3D"` multi-spectral band header recorded only `sampleCount` (`width * height * depth`), so `JP3DMultiSpectralDecoder` reconstructed every decoded band with dimensions `1 × 1 × sampleCount` instead of `width × height × depth`. | Extended the band header (`"JP3M"`, 24 bytes) to store `(width, height, depth, sampleCount)` while preserving backward compatibility with legacy 12-byte `"JP3D"` band headers. Verified by `JP3DMultiSpectralTests`. |
| `M10-AUD-005` | `JP3DCodestreamParser.swift`, `JP3DSliceStackCodec.swift`, `JP3DHTJ2K.swift`, `J2KVolume.swift` | Unchecked `width * height * depth` and marker payload length multiplications could trap on crafted oversized headers. | Replaced with `multipliedReportingOverflow` / `addingReportingOverflow` checked arithmetic throwing `J2KError` / `CodecError(.malformedInput, ...)`. Verified by `JP3DComplianceTests` and `VolumeContractTests`. |

---

## 3. Exit Gate 1 — `DICOMKit` JP3D Consumer Compatibility Verification

Per `IMPLEMENTATION.md` lines 87 and 149, `DICOMKit` imports JP3D across five volumetric source files:
1. `Sources/DICOMCore/JP3DCodec.swift`
2. `Sources/DICOMKit/JP3DVolumeDocument.swift`
3. `Sources/DICOMKit/JP3DVolumeBridge.swift`
4. `Sources/DICOMKit/DICOMKit+Volume.swift`
5. `Sources/DICOMKit/DICOMVolume.swift`

*(Note: the remaining two of the seven files mentioned in Decision M2 — `DICOMKit/DICOMJPIPClient.swift` and the `dicom-jpip` executable — import `JPIP`, which is Milestone 11 `SwiftJ2KJPIP` per `IMPLEMENTATION.md` line 88.)*

Without modifying the external `/Users/raster/Documents/DICOMKit_22Oct/DICOMKit` repository (`AGENTS.md`), all five JP3D-importing files and their two test suites (`Tests/DICOMCoreTests/JP3DCodecTests.swift` and `Tests/DICOMKitTests/JP3DSliceGeometryTests.swift`) were copied into an isolated verification package depending on `/Users/raster/Documents/SwiftJ2K` (`SwiftJ2K` + `SwiftJ2K3D`) with `import J2KCore` / `import J2K3D` replaced by `import SwiftJ2K` / `import SwiftJ2K3D`:

- **Command**: `swift test --package-path <scratch>/DICOMKitJP3DCheck`
- **Outcome**: Exit `0` — all 5 `DICOMKit` files compiled with zero source changes beyond the module import rename, and **22 / 22 tests** in `JP3DCodecTests` (17 tests) and `JP3DSliceGeometryTests` (5 tests) passed in `0.119s`.
- **Permanent In-Repo Regression Gate**: `VolumeContractTests.testDICOMKitJP3DConsumerSurfaceCompatibility` in [`Tests/SwiftJ2K3DTests/VolumeContractTests.swift`](../Tests/SwiftJ2K3DTests/VolumeContractTests.swift) permanently exercises the exact `J2KVolume`, `J2KVolumeComponent`, `JP3DCompressionMode`, `JP3DEncoderConfiguration`, `JP3DEncoder`, and `JP3DDecoder` signatures used by `DICOMKit`.

---

## 4. Exit Gate 2 — Test Suite and Verification Results

| Gate | Command | Result |
| --- | --- | --- |
| Common contract SHA-256 integrity | `(cd Documentation && shasum -a 256 -c COMMON_CONTRACT_SHA256.txt)` | Exit `0` — all 7 contract files (`CLI_CONTRACT.md`, `COMMON_API.md`, `MEMORY_CONTRACT.md`, `PERFORMANCE.md`, `PLATFORMS.md`, `SUITE_POLICY.md`, `TESTING.md`) `OK` |
| `SwiftJ2K3DTests` volumetric test suite | `swift test --filter SwiftJ2K3DTests` | Exit `0` — **490 / 490** XCTest methods passed (`0` failures) across 10 test files (`JP3DCoreTypeTests`, `JP3DWaveletTests`, `JP3DEncoderTests`, `JP3DDecoderTests`, `JP3DHTJ2KTests`, `JP3DMultiSpectralTests`, `JP3DIntegrationTests`, `JP3DComplianceTests`, `JP3DParityAndSurfaceTests`, `VolumeContractTests`) |
| Full package test suite (`SwiftJ2KTests` + `SwiftJ2K3DTests`) | `swift test` | Exit `0` — **490 / 490** `SwiftJ2K3DTests` + **122 / 122** `SwiftJ2KTests` Swift Testing suites passed (`0` failures) |
| Release build | `swift build -c release` | Exit `0` — `SwiftJ2K`, `SwiftJ2K3D`, and `swiftj2k-cli` built cleanly in release mode |
| CLI regression suite | `python3 Scripts/test-cli.py --binary .build/out/Products/Release/swiftj2k-cli --output <dir>` | Exit `0` — **197 / 197** process checks passed (`"status": "passed"`) |

---

## 5. Controlled Release Benchmarks (`swift run -c release`)

Measured on Apple M3 Max (`arm64-apple-macosx26.0`, Swift `6.4-dev`, `-c release`, 11 iterations after `preWarm(includeWarmupDispatch: true)`) on a synthetic signed 16-bit CT Hounsfield volume (`64 × 64 × 16` = 65,536 voxels, 131,072 uncompressed bytes, Hounsfield range `[-1024, +2047]`):

| Operation | Median wall-clock (ms) | Throughput (MVoxel/s) | Compressed size (bytes) | Compression ratio |
| --- | ---: | ---: | ---: | ---: |
| `JP3DEncoder` Part 1 Lossless (`5/3` + EBCOT) | `5.58 ms` | `11.74 MVoxel/s` | `5,681 B` | `23.07×` |
| `JP3DDecoder` Part 1 Lossless (`5/3` + EBCOT) | `4.91 ms` | `13.35 MVoxel/s` | — | — |
| `JP3DEncoder` HTJ2K + Z-Delta Lossless (`.losslessHTJ2K`, `zDeltaMode: .always`) | `1.46 ms` (**3.82× faster**) | `44.89 MVoxel/s` | `5,322 B` | `24.63×` |
| `JP3DDecoder` HTJ2K + Z-Delta Lossless | `1.38 ms` (**3.56× faster**) | `47.49 MVoxel/s` | — | — |
| `JP3DROIDecoder` (`16 × 16 × 4` sub-volume ROI) | `0.67 ms` (**7.33× faster** than full decode) | — | — | — |
| `VolumeTranscoder` Part 1 → HTJ2K (`.htj2k`) | `6.44 ms` | `10.18 MVoxel/s` | `5,322 B` | `24.63×` |
| `VolumeTranscoder` HTJ2K → Part 1 (`.jpeg2000`) | `7.02 ms` | `9.34 MVoxel/s` | `5,681 B` | `23.07×` |

---

## 6. Remaining Limitations and Next Milestones

- **JPIP (`SwiftJ2KJPIP`)**: Network streaming and JPIP client/server types (`Sources/JPIP/*`, including `JPIP3DStreamingTypes.swift`) remain scheduled for **Milestone 11** (`IMPLEMENTATION.md` line 88).
- **3D CLI Verbs (`Encode3D` / `Decode3D`)**: Volumetric CLI commands remain scheduled for **Milestone 12** (`IMPLEMENTATION.md` lines 76, 89, 153).
