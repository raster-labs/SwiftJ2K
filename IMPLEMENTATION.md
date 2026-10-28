# SwiftJ2K — staged implementation instructions

Read AGENTS.md and every common contract document first. Milestone 1 feasibility is implemented; later codec milestones require their own owner-assigned task. Follow the common contract when predecessor conventions differ. Maintain performance, reliability and security together.

For applications upgrading from J2KSwift, use [MIGRATION.md](MIGRATION.md). This implementation plan is for codec developers, not a claim that application cutover is already possible.

## Source and destination

Predecessor: [Raster-Lab/J2KSwift](https://github.com/Raster-Lab/J2KSwift) at inspected SHA `768f6b53499b806fd0304962056e1fc7833f12e5`. Highest stable-shaped tag observed: `v11.0.3` (resolve independently before choosing it as a baseline). Target module/product: `SwiftJ2K`. Target CLI: `swiftj2k-cli`. Intended first stable library version: `12.1.0`.

Do not migrate code from moving main without recording the selected revision. Reproduce relevant source tests and inspect source-level capabilities. Existing test totals and benchmark claims are historical, not successor acceptance evidence.

## Milestones and exit evidence

| Milestone | Work | Exit evidence |
| --- | --- | --- |
| 1 — contract feasibility | Establish Swift 6.4 package, independent local API/owning-memory types, descriptor validation and safe adapter experiment; no codec algorithm migration | Compiling equivalent public calls, lifecycle/race/error tests, standalone consumer build and contract issues resolved explicitly |
| 2 — migration baseline | Inventory predecessor subsystems/products; select and migrate the smallest native scalar lossless path with Apache-2.0/provenance reconciliation | Pinned predecessor comparison, independent decode/encode validation, exact sample/precision results, no new runtime codec dependency |
| 3 — shared-storage path | Direct final decode into caller storage and encode from compatible sealed storage | Required-sharing copy/allocation/lifetime proof; first suite pair or corresponding codec extension passes |
| 4 — feature/platform coverage | Extend supported modes/layouts, CLI, optional acceleration and all required OS/architecture paths | Capability matrix, codec-specific regressions, platform results, security and performance evidence |
| 5 — release preparation | Validate clean versioned consumption, docs/examples, migration guide, licence/fixture notices and release gates | Reviewed complete evidence; stable tag only after explicit release task |

Work one owner-assigned milestone at a time. Preserve internal algorithm names where helpful, but provide the agreed common public module surface. Do not publish a stable version or announce complete platform support while required gates are missing.

### Milestone 2 status — executed 22 September 2026

Milestone 2 is implemented on branch `milestone2/scalar-lossless-j2k` against predecessor `7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca`; evidence is in [MILESTONE2.md](Documentation/MILESTONE2.md) and file-level provenance in [HISTORY.md](HISTORY.md). The migrated scalar path covers: raw JPEG 2000 Part 1 codestreams, one unsigned greyscale component of 1–16 bits, one tile at the origin, reversible 5/3 wavelet with 0–32 levels, no quantisation, default code-block style, one quality layer, any precinct partition, LRCP/RLCP/RPCL progression (PCRL/CPRL only with one precinct per resolution), SOP/EPH markers, several tile-parts, PLT/TLM/COM segments skipped. Everything else in the "Migration focus" list below remains a capability to add: HTJ2K, 9/7 and quantised coding, tiles, layers, colour and signed components, sub-sampling, ROI, POC, PPM/PPT, JP2/JPH containers, acceleration, the auxiliary products, and native transcoding. Contract 0.9.0's continuous-integration precondition was still unmet when this milestone was executed, so the branch is local evidence rather than a merge candidate.

### Milestone 3 status — executed 22 September 2026

The shared-storage path is proved for the scalar lossless codec: caller-destination decode and sealed-source encode with telemetry-checked zero pixel allocations and copies, sentinel padding, stride independence, mutation testing and the extended contract harness with both reference decoders ([MILESTONE3.md](Documentation/MILESTONE3.md)). The cross-codec JPEG-LS leg of the first suite pair is unexecuted because SwiftJLS advertises no encoder; it is the corresponding codec extension (SwiftJ2K re-encode from the same owner) that passes. Native transcoding remains at Milestone 1 capability.

### Milestone 4 status — executed 22 September 2026

Decoder coverage now spans the Part 1 greyscale lossless syntax: any tile grid and origin, quality layers, all code-block styles, all progression orders, precincts, SOP/EPH, tile-parts and tile-part overrides, validated against 44 OpenJPEG and Kakadu fixtures. The CLI codec verbs operate through the NRRD profile. Encoding remains single-tile, single-layer, default style. Still deferred: HTJ2K, 9/7 and quantised coding, colour, signed and sub-sampled components, ROI, POC, PPM/PPT, JP2/JPH containers, acceleration, the auxiliary products and native transcoding. Evidence and executed platforms: [MILESTONE4.md](Documentation/MILESTONE4.md).


### Milestone 5 status — executed 22 September 2026

Release preparation without a tag: fresh URL-based consumption on macOS and Linux, MIGRATION.md rewritten with an executable example, THIRD_PARTY_NOTICES.md, SECURITY.md's supported-version policy, RELEASE.md as the procedure for the explicit release task, and the previously unexecuted gates run on the Swift 6.4 toolchain (Swift Build engine, AddressSanitizer, ThreadSanitizer, SBOMs), plus one-hour fuzz campaigns per decode entry point, an Apple SDK build matrix and an iOS simulator run ([MILESTONE5.md](Documentation/MILESTONE5.md)). The DICOMKit audit of decision M3 was executed: `J2KDICOMCodestreamDetector` has no DICOMKit equivalent for its CAP-marker transfer-syntax sniff, so that file transplants to DICOMKit in DICOMKit's own task. Contract 0.9.0's continuous-integration precondition remained unmet; the stable tag waits for the release task.

### Release 12.1.0 task status — executed 22 September 2026

Owner-assigned release task following [Documentation/RELEASE.md](Documentation/RELEASE.md). Version set to 12.1.0 (commit `67273db`); every gate of the procedure executed on that commit and recorded in [Documentation/RELEASE-12.1.0.md](Documentation/RELEASE-12.1.0.md). The stable tag was **not** cut: contract 0.9.0's continuous-integration precondition (Actions jobs at `steps=0`) and the private-vulnerability-reporting precondition are unmet, both organisation-owner actions. When they hold, RELEASE.md steps 3 to 6 apply to the release pull request's merge commit.

### Owner decision, 25 September 2026: complete the migration before any release

The owner ruled that no release is created until the migration of J2KSwift is complete: "I need complete migration of J2KSwift then only to create a release work". This restores the order decision M2 below already implied (the first stable ships `SwiftJ2K3D` and `SwiftJ2KJPIP`, which do not exist yet). The 12.1.0 preparation on pull request 18 (executable rename to `swiftj2k-cli`, gate record, evidence) stands as preparation only; no tag, and the version string stays 12.1.0 as the target of the first stable. The release task is re-run in full on the commit that completes the programme below.

### Milestone 6 status — implemented subset; audit open, 26 October 2026

The Milestone 6 cleanup/placeholder HT and coefficient-transcoding subset is implemented on branch `antigravity/milestone6-htj2k-transcoding` (from `origin/milestone6/htj2k` `682fd7a3f60c9ec5b56c0a7cb0eb052e1558a0ce`, merge-base `be4e7a3ad352759e7a78a90f6a2e2c3b7aa0f748`); evidence and findings are in [MILESTONE6.md](Documentation/MILESTONE6.md). Following the owner's 26 October 2026 decision ("Adapt the existing coder with its notices (recommended)"), the predecessor's OpenJPH-derived conformant Part 15 block coder (`J2KHTConformant*` at `7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca`) was adapted into `Sources/SwiftJ2K/Codec/HTTables.swift` and `Sources/SwiftJ2K/Codec/HTBlockCoder.swift` with `Apache-2.0 AND BSD-2-Clause` SPDX headers, OpenJPH BSD-2-Clause licence notices and `THIRD_PARTY_NOTICES.md` disclosure, and with three predecessor defects fixed (`Lcup > 4096` limit, `fuseMELAndVLC` bit-7 corruption, and `HTMELDecoder.read()` unstuffing across 32-bit word boundaries). `CAP`, `CPF`, `COD`/`COC` HT style bits (`0x40`, `0x80`), HT packet-header segment rules, placeholder-pass accounting, mixed Part 1 / HTJ2K per-block decoding, HT lossless encoding, native wavelet-coefficient `J2K ↔ HTJ2K` transcoding (`pixelAllocations == 0`, `copyEvents == 0`), main-header and tile-part `COM` (`0xFF64`) preservation (`.preserve`, default) and explicit omission with `OperationReport` discard statistics (`.discardAncillary`), pre-allocation stage admission across geometry/workspace/packet/output buffers, and `swiftj2k-cli transcode` (`j2k ↔ htj2k`) are implemented and verified against OpenJPH `0.30.1`, Kakadu `8.4.1` and OpenJPEG `2.5.4`. HT `SigProp`/`MagRef` refinement passes and multiple active HT sets per code-block remain outside the Milestone 6 cleanup-pass subset and are rejected deterministically with `unsupportedFeature`.

### Milestone 7 status — executed 27 October 2026

Milestone 7 (Part 1 breadth) is implemented on branch `antigravity/milestone7-part1-breadth` from `origin/main` (`ed3dec9e40abbd63d1678881498512098d2247dc`) against pinned predecessor `7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca`; evidence, rate-distortion tables, capability matrix and the complete file-by-file Part 2 / perceptual / MJ2 audit and dispositions are in [MILESTONE7.md](Documentation/MILESTONE7.md), and file-level provenance is in [HISTORY.md](HISTORY.md). The Milestone 7 implementation adds: colour and multi-component (`1...N` components, RGB planar/interleaved, RGBA) with `RCT` and `ICT`; signed integer samples (`Ssiz` bit 7) and Part 1 DC level shift / extended guard-bit precision (`1...7` guard bits, 64-bit internal bit-plane coding up to 62 bit-planes); 9/7 CDF irreversible wavelet (`Wavelet97`) with scalar-derived (`Sqcd = 1`) and scalar-expounded (`Sqcd = 2`) dead-zone quantisation, midpoint dequantisation and PCRD-opt rate control (`.lossy` with `quality`, `targetBitsPerPixel`, `qualityLayers`, `layerBitrates`; and `.nearLossless(maximumAbsoluteError:)` with closed-loop error bound verification and `Fidelity.boundedError`); Region of Interest (`RGN` `0xFF5E` MaxShift $s \ge \max_b M_b$); multi-tile, multi-layer and explicit precinct encoding; all five progression orders plus `POC` (`0xFF5F`), `SOP`/`EPH` and all six Part 1 code-block style bits; and 2D/3D 8/16-bit signed/unsigned NRRD and lossy/near-lossless CLI flags in `swiftj2k-cli`. Validated against 22 per-feature OpenJPEG `2.5.4` and Kakadu `8.4.1` cross-decode fixtures (`108` of `108` tests and `184` of `184` CLI checks passing). All audited Part 2, perceptual and `MJ2*` files in the predecessor were found to be unwired, non-conformant or H.264/HEVC stubs and are retired/excluded as recorded in [MILESTONE7.md](Documentation/MILESTONE7.md).

### Milestone 8 status — executed 27 October 2026

Milestone 8 (JP2, JPH and JPX containers) is implemented on branch `antigravity/milestone8-containers` from `origin/main` (`ec1d39c5ca671c0377c1eb1f895bd2d08f888565`) against pinned predecessor `7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca`; evidence, box support matrix, fixed predecessor defects and the complete file-by-file `Sources/J2KFileFormat/` audit are in [MILESTONE8.md](Documentation/MILESTONE8.md), and file-level provenance is in [HISTORY.md](HISTORY.md). The Milestone 8 implementation adapts `J2KBox.swift`, `J2KReaderRequirements.swift`, `J2KBoxes.swift`, `J2KPart2Boxes.swift` (`jp2i`, `asoc`, `lbl `), and `J2KFileFormat.swift` into `Sources/SwiftJ2K/Container/` (`JP2BoxReaderWriter.swift`, `JP2ReaderRequirements.swift`, `JP2Boxes.swift`, `JP2Container.swift`), adding full `.jp2`, `.jph`, and single-codestream `.jpx` container reading, validation, encoding, and wavelet-domain transcoding (`jp2 ↔ jph ↔ jpx ↔ jpx-htj2k ↔ j2k ↔ htj2k`, `pixelAllocations == 0`, `copyEvents == 0`), palette (`pclr` + `cmap`) LUT expansion, channel definition (`cdef`) opacity and channel ordering, enumerated and ICC colour specifications (`colr`), standard 10-byte grid resolution boxes (`res `/`resc`/`resd`), ancillary metadata (`xml `, `uuid`, `uinf`/`ulst`/`url `, `jp2i`, `asoc`/`lbl `), and strict enforcement of `ResourceLimits.maximumMetadataBytes`, `maximumICCBytes`, `maximumNestingDepth`, and `MetadataPolicy` (`.preserve` vs `.discardAncillary`). Validated against 16 OpenJPEG `2.5.4` and Kakadu `8.4.1` container fixtures (`ContainerTests.swift` and `193` CLI checks passing). Multi-frame `J2KJPXAnimation.swift` and unwired JPM/Part 2 boxes are retired/excluded as recorded in [MILESTONE8.md](Documentation/MILESTONE8.md).

### Milestone 9 status — executed 28 October 2026

Milestone 9 (Metal and SIMD/NEON acceleration behind `executionPolicy`) is implemented on branch `antigravity/milestone9-acceleration` from `origin/main` (`de88d61`) against pinned predecessor `7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca`; evidence, platform availability matrix, fixed predecessor defects (`M9-AUD-001` through `M9-AUD-005`), byte-identity verification across all 209 fixtures, and warm/cold release benchmarks are in [MILESTONE9.md](Documentation/MILESTONE9.md), and file-level provenance is in [HISTORY.md](HISTORY.md).

### Milestone 10 status — executed 28 October 2026

Milestone 10 (`SwiftJ2K3D` volumetric JPEG 2000 / JP3D) is implemented on branch `antigravity/milestone10-swiftj2k3d` from `origin/main` (`ea30b51`) against pinned predecessor `7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca`; evidence, file-by-file provenance, fixed predecessor defects (`M10-AUD-001` signed voxel clamping, `M10-AUD-002` `SIZ` signed bit signalling, `M10-AUD-003` signed Z-delta residual slices, `M10-AUD-004` multi-spectral spatial dimension preservation, and `M10-AUD-005` checked arithmetic), `DICOMKit` consumer compatibility verification (`5/5` JP3D-importing files and `22/22` tests passing), and release benchmarks are in [MILESTONE10.md](Documentation/MILESTONE10.md), and file-level provenance is in [HISTORY.md](HISTORY.md). Migrates `Sources/J2K3D` (30 files / 8,923 lines), `Sources/J2KCore/J2KVolume*.swift` (2 files / 514 lines), and `Sources/J2KMetal/JP3DMetalDWT.swift` (1,430 lines) into the retained `SwiftJ2K3D` library product (Decision M2) together with the Contract **API-13** volumetric extension surface (`VolumeEncoder`, `VolumeDecoder`, `VolumeTranscoder`, `VolumeInfo`), with `490/490` `SwiftJ2K3DTests` and `122/122` `SwiftJ2KTests` passing.

### Milestone 11 status — executed 28 October 2026

Milestone 11 (`SwiftJ2KJPIP` interactive progressive streaming / ISO/IEC 15444-9) is implemented on branch `antigravity/milestone11-swiftj2kjpip` from `origin/main` (`be82d39`) against pinned predecessor `7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca`; evidence, file-by-file provenance, fixed predecessor defects (`M11-AUD-001` implementing `JPIPClient` image/region/quality/resolution/component retrieval and resolving `DICOMKit` Finding F1, `M11-AUD-002` in-process loopback routing and codestream reassembly re-enabling `JPIPClientServerIntegrationTests`, `M11-AUD-003` disjoint `JP3DViewport.intersection` crash fix, `M11-AUD-004` out-of-bounds `JPIPPrefetchEngine.tilesForViewport` crash fix, `M11-AUD-005` checked-arithmetic data-bin parsing, and `M11-AUD-006` inactive cache entry compression/decompression), `DICOMKit` JPIP consumer compatibility verification (`43/43` `DICOMKitTests` and `6/6` `dicom_jpipTests` passing), and release benchmarks are in [MILESTONE11.md](Documentation/MILESTONE11.md), and file-level provenance is in [HISTORY.md](HISTORY.md). Migrates `Sources/JPIP` (31 files / 14,005 lines) into the retained `SwiftJ2KJPIP` library product (Decision M2) together with the Contract **API-13** interactive streaming extension surface (`JPIPStreamingSession`, `JPIPSessionConfiguration`, `JPIPViewWindow`, `JPIPDeliveredImage`, `JPIPDeliveredVolumeSliceBins`), with `544/544` `SwiftJ2KJPIPTests`, `490/490` `SwiftJ2K3DTests`, and `122/122` `SwiftJ2KTests` passing.

**What remains, measured at predecessor `7acc9ae`** (files / lines; `SwiftJ2K` today has 17 files / 3,727 lines adapted from six of them):

| Predecessor area | Files / lines | Successor home | Programme milestone |
| --- | --- | --- | --- |
| `J2KCodec` HTJ2K block coder, HT codec, HT conformance tables, transcoder (`J2KHT*`, `J2KTranscoder`, `J2KGPU*HT*` scalar parts) | 23 / ~12,900 | `SwiftJ2K` internal `Codec/HT` | 6 |
| `J2KCore` `J2KHTConformanceAPI`, `J2KPart1Conformance`, `J2KMarker`, `J2KCodestreamIntegrity`, bit reader/writer | 8 / ~4,000 | `SwiftJ2K` internal | 6 and 7 |
| `J2KCodec` Part 1 breadth: `J2KEncoderPipeline`, `J2KDecoderPipeline` remainder, `J2KColorTransform`, `J2KMCT*`, `J2KQuantization`, `J2KRateControl`, `J2KTrellisQuantizer`, `J2KDWT2D*`, `J2KWaveletKernel*`, `J2KROI`, `J2KExtendedROI`, `J2KDCOffset`, `J2KExtendedPrecision`, `J2KTier2Coding`, `J2KProgressiveEncoding`, `J2KMultiTile*`, `J2KEncodingPresets`, `J2KAdvancedDecoding`, `J2KCodec` | ~30 / ~32,000 | `SwiftJ2K` | 7 |
| `J2KCodec` Part 2 and perceptual: `J2KArbitraryWavelet`, `J2KNonLinearTransform`, `J2KNLTMarker`, `J2KPart2CodestreamExtensions`, `J2KMCTDependency`, `J2KPerceptualEncoder`, `J2KVisualMasking`, `J2KVisualWeighting`, `J2KQualityMetrics`, `J2KAdaptiveBlockSize` | 10 / ~5,300 | `SwiftJ2K`, capability-gated | 7 (audit; owner disposition per feature) |
| `J2KCodec` Motion JPEG 2000: `MJ2*` | 5 / ~1,700 | **owner disposition needed** (not in the single-image contract) | 7 (audit only) |
| `J2KFileFormat`: JP2/JPH boxes, JPX animation, Part 2 boxes, reader requirements | 9 / 7,374 | `SwiftJ2K` internal `Container` | 8 |
| `J2KCodecNEON` (C kernels for HT and entropy coding) and `J2KCodec/ARM` | 10 / ~3,100 | `SwiftJ2K` internal, `executionPolicy` | 9 |
| `J2KMetal` (DWT, colour, MCT, quantiser, ROI, HT emit stages, shaders) | 25 / 25,447 | `SwiftJ2K` internal, `executionPolicy` (decision M1) | 9 |
| `J2K3D` (JP3D) | 30 / 8,923 | `SwiftJ2K3D` (retained, decision M2) | 10 |
| `JPIP` | 31 / 14,005 | `SwiftJ2KJPIP` (retained, decision M2) | 11 |
| `J2KCLICore` remainder: `Transcode`, `Convert`, `Compare`, `Info`, `Batch`, `MultiFileProcessor`, `ImageIO`/PNG/TIFF, `Encode3D`/`Decode3D`, JPIP client/server verbs, `Completions`, `Benchmark` | 27 / 9,569 | `swiftj2k-cli` (`DICOMSupport`, `Daemon*`, `OPJ*` wrappers and `Headless` retire with their products) | 6, 10, 11, 12 |
| Timings, telemetry, profilers, benchmarks (`*Timings`, `J2KPipelineProfiler`, `J2KBenchmark`, `J2KPerformanceOptimizer`, `J2KMemoryTracker`) | ~12 / ~2,500 | development-only under `Integration/` or dropped where `OperationReport` already covers them | each milestone as needed |

**Programme.** One owner-assigned milestone at a time, each on its own branch, each with the evidence record, provenance headers and the gate set of Milestones 2 to 5, and each merged only on the owner's request.

| Milestone | Work | Exit evidence |
| --- | --- | --- |
| 6 — HTJ2K | Part 15 block coder (MEL, VLC, MagSgn, cleanup), CAP/CPF/COD HT signalling, HT decode and encode for the current greyscale lossless profile (HT Rev Only, then HT Only and mixed), and lossless J2K ↔ HTJ2K transcoding in memory and through `swiftj2k-cli transcode` per TRANSCODING.md and POL-09. Audit the predecessor's recorded HTJ2K lossless failure case first | Sample-exact round trips against OpenJPH 0.30.1 and Kakadu 8.4.1 fixtures in both directions; transcode both directions with independent decode of the result; capability reports `htj2k`; fuzz of the HT entry points; harness pair added |
| 7 — Part 1 breadth | Colour and multi-component with RCT/ICT, signed samples, 9/7 irreversible with quantisation and rate control (`.lossy`, `.nearLossless`), ROI, multi-tile, multi-layer and precinct encoding, progression control, DC offset and extended precision; audit Part 2, perceptual and MJ2 files and record a feature-level disposition for each | Per-feature OpenJPEG and Kakadu cross-decode fixtures; rate-distortion table for lossy; capability matrix; benchmark record |
| 8 — containers | JP2 and JPH boxes, JPX where the predecessor supported it, reader requirements, colour specification and channel definition, metadata policy limits | Container fixtures from OpenJPEG/Kakadu; inspect/validate/decode through containers; metadata-bytes limit enforced |
| 9 — acceleration | Metal and NEON paths behind `executionPolicy` (PLAT-05, decision M1), reported in `OperationReport.backend` | Byte-identity of accelerated output against the scalar path on every fixture; availability guards on every platform in the matrix; benchmark record ([MILESTONE9.md](Documentation/MILESTONE9.md)) |
| 10 — `SwiftJ2K3D` | JP3D codec, slice-stack codec, ROI, progressive delivery, HTJ2K in JP3D, transcoder, as the retained product with the volume extension API (API-13) | DICOMKit's JP3D-importing files compile against it in DICOMKit's own task; predecessor JP3D fixtures round-trip ([MILESTONE10.md](Documentation/MILESTONE10.md)) |
| 11 — `SwiftJ2KJPIP` | JPIP client and server, transports, caches, progressive delivery, JP3D streaming, as the retained product | Client/server loopback tests; DICOMKit's JPIP client compiles against it in DICOMKit's own task ([MILESTONE11.md](Documentation/MILESTONE11.md)) |
| 12 — CLI and consumer breadth | Remaining `swiftj2k-cli` verbs and image I/O, batch and compare, shell completions; migration guide for every consumer named in the dispositions | 147-plus CLI conformance checks extended per verb; consumer builds |
| 13 — release preparation, again | The Milestone 5 scope re-executed on the completed codebase, then the release task | RELEASE.md gates on the release commit; tag only after the owner's explicit release task and the CI precondition |

### Migration focus

- The CompressionFamily coupling is already out of the predecessor: J2KSwift pull request 489 (merged 22 September 2026, `7acc9ae`) moved `Sources/J2KCore/CompressionFamilyConformance.swift` and `Sources/J2KCodec/CompressionFamilyConformance.swift` into the separate package `Adapters/J2KCompressionFamily`, and the J2KSwift root manifest declares no external dependency. Nothing from that adapter package migrates; provide the agreed local common surface instead. Do not copy the protocol source into each module and claim it is one shared Swift type.
- Adapt the real `J2KDecoder`/decoder pipeline final-output stage to caller-provided storage. Existing `J2KImage` uses per-component data; `J2KImageBuffer` has copy-on-write owned storage and its Data constructor copies. Those APIs do not prove direct decode-into support. Eliminate final-frame copy-out on the required shared path, while accounting for DWT/coefficient workspace.
- Route the initial unsigned greyscale lossless case through the conformant codec. Preserve declared component precision and sign rules. Inventory multi-tile, reversible/irreversible transform, subsampling, ROI, resolution/progressive, container and component capabilities before adapting them.
- HTJ2K uses the same Encoder/Decoder contract with explicit block-coding options. Standard-compliant HT block format is required for advertised HTJ2K. Isolate any predecessor custom/non-Part-15 representation as legacy experimental material; it must not be selected by standard format defaults or claimed interoperable.
- Review Metal session initialisation, shader resources, NEON/native kernels and platform imports for the new Linux/Watch/Intel matrix. Do not carry unconditional Apple framework access into common parsing or scalar execution. Preserve relevant warm/cold behaviour and record acceleration costs separately.
- Inventory `J2KFileFormat`, `J2KMetal`, `JPIP`, `J2K3D`, daemon/client/test-app products and `J2KDICOMHelpers`. The principal shared image API does not automatically replace those products. Record explicit migration/disposition per product; retain DICOM-specific helpers outside the domain-neutral core. Network/daemon features remain optional and are not required for in-process transcoding.

### Codec-specific tests

Test reversible integer DWT boundaries/overflow, quantisation/lossless-mode validation, entropy termination/truncation, tiles and edge code-block dimensions, component precision/signedness, JP2/codestream metadata and ROI/resolution errors. For HTJ2K, use independent Part-15-capable decoding; do not assume an ordinary JPEG 2000 decoder supports HT. Independently validate both predecessor and successor codestreams.

Carry forward reproducers for empty/zero-coefficient HT blocks, invalid pointer base addresses, malformed packet lengths and report/test-runner failures. Test CPU and each qualified accelerated path for exact lossless samples. Test optional product boundaries separately; a broken daemon or auxiliary product must not be silently removed from the inventory.

### Initial codec delivery — Milestones 2–4

The following codec work follows Milestone 1 contract feasibility. It is not part of the first coding task. Migrate the scalar path in Milestone 2, prove shared storage in Milestone 3, and extend features/CLI/platform coverage in Milestone 4.

Build on the validated common local memory types to implement the direct unsigned 16-bit decode-into path, then cooperate with the SwiftJLS adapter harness. Prove 12-in-16 and full 16-bit precision. Extend HTJ2K using the same proof once classic JPEG 2000 is validated. Do not begin with a broad GPU rewrite.


## Native transcoding work

Implement lossless J2K ↔ HTJ2K using [TRANSCODING.md](TRANSCODING.md) and the common native format-pair API/CLI. Audit the recorded predecessor limitations in Milestone 2; qualify the in-memory native operation in Milestone 3 and extend profiles in Milestone 4. Preserve the initial J2K → JPEG-LS proof and the Milestone 1 feasibility boundary.

## Product dispositions (POL-05)

Decided 22 September 2026 under contract 0.8.0 §3, which requires this inventory before any subsystem is relocated. Measured at predecessor J2KSwift `2fa9a3d` with `swift package dump-package`. "Imports" counts files across DICOMKit, CompressionFamily, VoxeliaValidation, DICOMAdapter, RasterOneImage, OneImageViewer-iOS and telerad-dicom-viewer containing a top-level `import <module>`.

POL-05 requires every product to be explicitly **retained** (migrates, stays a public product), **adapted** (migrates with a changed shape — folded into the principal module, renamed, or re-expressed through the common API) or **deferred** (does not migrate for the first stable; stays with the predecessor through the maintenance window). Deferred is not deleted.

| Predecessor product | Files / lines | Imports | Disposition | Successor | Basis |
| --- | --- | --- | --- | --- | --- |
| `J2KCore` | 22 / 8,927 | 15 | Adapted | internal target of `SwiftJ2K` | API-01 names the principal product and module exactly `SwiftJ2K` and allows internal targets to preserve useful algorithm boundaries |
| `J2KCodec` | 82 / 63,930 | 6 | Adapted | internal target of `SwiftJ2K` | API-01 |
| `J2KFileFormat` | 8 / 7,323 | 1 | Adapted | internal target of `SwiftJ2K` | API-01 |
| `J2KContract` | 7 / 1,106 | 0 | Adapted — folded in | `SwiftJ2K` | It exists because `CompressionMode`, `EncodedImage` and `ImageMetadata` already meant something else inside a module named `J2KSwift`. The rename dissolves the collision. Contract 0.8.0 §5 forbids two parallel surfaces in one module. |
| `J2KMetal` | 22 / 19,244 | 1 | Adapted | internal target, selected through `executionPolicy` | API-07 makes a backend a per-operation option reported back in `OperationReport`; PLAT-05 makes acceleration optional and availability-guarded |
| `J2K3D` (JP3D) | 29 / 8,879 | 5 | **Retained** | `SwiftJ2K3D` | API-13 treats volume coding as a clearly named extension operation rather than an interchangeable common one |
| `JPIP` | 30 / 13,955 | 2 | **Retained** | `SwiftJ2KJPIP` | API-13 names JPIP explicitly as not interchangeable with the single-image contract |
| `J2KDICOMHelpers` | 11 / 1,647 | 0 | Deferred — retired | none | POL-05 keeps transfer-syntax negotiation and photometric policy in consumers. DICOMKit already owns `DICOMCore/PhotometricInterpretation.swift` and `DICOMCore/TransferSyntaxConverter.swift`, and nothing imports this product. |
| `j2k` (exec) | 1 / 16 + `J2KCLICore` | — | Adapted — renamed | `swiftj2k-cli` | CLI-01 fixes the successor executable names |
| `j2kd` (exec) | 1 / 82 | — | Deferred | none | macOS-only XPC daemon; no importer, and a daemon-plus-fallback execution model is not part of the contract's operation surface |
| `J2KDaemonProtocol` | 1 / 177 | 0 | Deferred | none | as `j2kd` |
| `J2KDaemonCore` | 2 / 414 | 0 | Deferred | none | as `j2kd` |
| `J2KDaemonClient` | 1 / 275 | 0 | Deferred | none | as `j2kd` |
| `J2KTestApp` (exec) | 23 / 7,475 | 0 | Deferred — dev tooling | none | TESTING keeps development-only tools outside the shipped dependency graph |

**Product list after migration:** `SwiftJ2K`, `SwiftJ2K3D`, `SwiftJ2KJPIP` (libraries) and `swiftj2k-cli` (executable). Fourteen products become four.

`Sources/J2KCore/CompressionFamilyConformance.swift` and `Sources/J2KCodec/CompressionFamilyConformance.swift` were the entire CompressionFamily coupling. Contract 0.8.0 §4 is satisfied: J2KSwift pull request 489 (merged 22 September 2026, `7acc9ae`) moved them, with their pin-down tests, into the separate package `Adapters/J2KCompressionFamily` in the predecessor repository, which depends on J2KSwift by path and on CompressionFamily by URL. The J2KSwift root manifest now declares no external dependency, so `SwiftJ2K` resolves alone. The adapter package is predecessor-compatibility surface and does not migrate. CompressionFamily itself is untouched and stays available to predecessor consumers under POL-04.

### Decisions recorded with these dispositions

**M1 — `J2KMetal` becomes an internal target.** A caller requests acceleration through `executionPolicy` and reads back the backend actually used, instead of importing the backend module. This is a source change rather than a rename for DICOMKit's `Sources/DICOMCore/CodecBackend.swift`, its single importing file, and belongs in DICOMKit's separately assigned cutover task.

**M2 — `SwiftJ2K3D` and `SwiftJ2KJPIP` ship in the first stable 12.1.0.** DICOMKit imports the two across seven files — `DICOMCore/JP3DCodec.swift`, `DICOMKit/JP3DVolumeDocument.swift`, `DICOMKit/JP3DVolumeBridge.swift`, `DICOMKit/DICOMKit+Volume.swift`, `DICOMKit/DICOMVolume.swift`, `DICOMKit/DICOMJPIPClient.swift` and the `dicom-jpip` executable. Deferring them past 12.1.0 would leave DICOMKit unable to complete its cutover and extend the predecessor maintenance window indefinitely, so they migrate carrying their existing public surface. Aligning that surface with the common contract is later milestone work under API-13, not a condition of the move.

**M3 — `J2KDICOMHelpers` retires with the predecessor.** It is not transplanted into a consumer, because DICOMKit already implements the same domain. One audit before the predecessor is archived: confirm `J2KDICOMCodestreamDetector` has a DICOMKit equivalent. If it does not, that single file transplants to DICOMKit and the rest still retires. *Audit executed 22 September 2026 (Milestone 5): DICOMKit's `DICOMCore/J2KCodestreamInspector.swift` detects Part 2 multi-component transforms and the irreversible wavelet but has no CAP-marker (HTJ2K versus Part 1) transfer-syntax sniff; the single-file transplant is required and belongs to DICOMKit's task.*

**CLI surface.** Retained and adapted: the CLI-01 verbs `encode`, `decode`, `inspect` (renamed from `Info`), `validate` and `capabilities`, plus `transcode` under POL-09. Deferred to a CLI milestone after the first stable: `Batch`, `Benchmark`, `Compare`, `Convert`, `Completions`, `Headless`, `InProcBench` and the `Encode3D`/`Decode3D`/`JPIPClient`/`JPIPServer` commands. Deferred under POL-05: `DICOMSupport`. Deferred as predecessor-compatibility surface: `OPJCompress`, `OPJDecompress` and `OPJDump` — these are native Swift commands mirroring OpenJPEG's flag syntax, not shell-outs, so POL-01 does not forbid them; they are simply not part of the successor's contract surface.

## Required handover

Update CHANGELOG.md and migration provenance. Provide the exact commands, commits, fixture hashes and outcomes; report tests not run and why, unsupported cases, allocation/copy evidence and performance impact. Map each advertised feature to a test and capability entry. Keep DICOMKit/Voxelia source changes outside this repository task unless the owner separately assigns them.

## Owner-authorised OS 27 and CLI foundation

Before codec migration, the owner requested executable help, verbosity and UNIX manuals. Apple floors were briefly raised to 27.0 in contract 0.4.0 and returned to 26.0 in 0.5.0. This bounded CLI foundation implements help/version/capabilities only; codec commands remain explicitly unavailable. See [CLI.md](CLI.md) and [new evidence](Documentation/Engineering/OS27CLI/README.md). The later codec/CLI milestones still govern real payload operations.
