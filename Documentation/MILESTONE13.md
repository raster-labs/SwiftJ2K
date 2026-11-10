# Milestone 13 — Release Preparation and Milestone 12 `DICOMKit` OS 26 Integration Evidence

Prepared on **5 November 2026** on isolated branch `codex/m13-swiftj2k-release-preparation` (`ab895cf719152b2dd692181933bf12d5b819ce27`) from `main` commit `76850bc2286184847a1ecd1dc3ea61ab449ac4bd` (tree `7b602a492ee7382ff54dc9d9b873a60f332df7c5`), verified across all `4/4` jobs of hosted Apple CI run `42007848976`, and merged into `SwiftJ2K` `main` via PR #31 at `57d7628fc9b9e4daa5af198eb8831599444f657b`; shared contract **0.10.0**, intended first stable version **12.1.0** ([VERSION](../VERSION)).

**No stable `v12.1.0` Git tag, GitHub release, binary distribution, or predecessor repository archival is performed in this milestone.** Per [IMPLEMENTATION.md](../IMPLEMENTATION.md), [RELEASE.md](RELEASE.md), and `TESTING.md` (`TEST-07`), cutting a stable tag requires a separate explicit owner release assignment after all required continuous-integration, remediation, interoperability, security, and provenance preconditions are closed or explicitly scoped by the owner.

---

## 1. Scope and Repository Identities

| Item | Value |
| --- | --- |
| `SwiftJ2K` Milestone 13 branch & head | `codex/m13-swiftj2k-release-preparation` @ `ab895cf719152b2dd692181933bf12d5b819ce27` (hosted Apple CI run `42007848976` `4/4` jobs passed) |
| `SwiftJ2K` merged `main` commit (PR #31) | `57d7628fc9b9e4daa5af198eb8831599444f657b` |
| `SwiftJ2K` base commit (`main`, merged PR #30) | `76850bc2286184847a1ecd1dc3ea61ab449ac4bd` (tree `7b602a492ee7382ff54dc9d9b873a60f332df7c5`) |
| `SwiftJ2K` `Sources/`, `Tests/`, `Scripts/`, `Package.swift`, `VERSION` delta | **Zero bytes changed** (`Sources/`, `Tests/`, `Scripts/`, `Package.swift`, and `VERSION` remain 100% byte-identical to `76850bc2286184847a1ecd1dc3ea61ab449ac4bd`) |
| Shared contract manifest (`COMMON_CONTRACT_SHA256.txt`) | **Verified unchanged** (`7/7` shared contract documents match SHA-256 manifest; contract `0.10.0`) |
| Historical Swift 6.4 records (`Documentation/Engineering/Swift64/**`) | **Verified byte-identical** |
| `DICOMKit` integration branch & head | `codex/m12-swiftj2k-dicomkit-integration` @ `814145be1a797986e165bdcf2d98d76f6ab6ebee` (`https://github.com/raster-labs/DICOMKit.git`, `15/15` hosted CI checks passed) |
| `DICOMKit` merged `main` commit (PR #236) | `2b50a70619323be748b94c08c363e6912277b1f0` |
| `DICOMKit` prepared base commit | `1abc1abf36d75bbba367b553e0828fd987169380` (tree `1458c87b8b16d12eb42167b84c26bf6a55ebf359`) |
| `DICOMKit` `M12-02` core routing commit | `bef7f59e797e12d902b580952e66eab75c9333d9` |
| `DICOMKit` `M12-03` OS 26 integration commit | `814145be1a797986e165bdcf2d98d76f6ab6ebee` (tree `00222a7736efa9e6595bdefaca0ce9f291baabb2`) |
| `DICOMKit` pinned predecessor (`J2KSwift`) | `11.0.3` @ `768f6b53499b806fd0304962056e1fc7833f12e5` (retained in root `DICOMKit/Package.resolved`) |
| `DICOMSwiftJ2KIntegration` pinned successor (`SwiftJ2K`) | `76850bc2286184847a1ecd1dc3ea61ab449ac4bd` (pinned in `Integrations/DICOMSwiftJ2KIntegration/Package.swift` and `Package.resolved`) |

Because `codex/m13-swiftj2k-release-preparation` (`ab895cf719152b2dd692181933bf12d5b819ce27`, merged at `57d7628fc9b9e4daa5af198eb8831599444f657b`) modifies release documentation and the Swift Testing `--skip` source-location suffix pattern (`(?:/.*)?$`) in `.github/workflows/contract.yml` only, keeping `Package.swift`, `VERSION`, `Sources/**`, `Tests/**`, and `Scripts/**` byte-identical to `76850bc2286184847a1ecd1dc3ea61ab449ac4bd`:
1. `DICOMKit`'s `Integrations/DICOMSwiftJ2KIntegration` package resolves the exact `SwiftJ2K` production source tree on `main`.
2. Hosted Apple CI run `42007848976` verified all `4/4` jobs on `ab895cf719152b2dd692181933bf12d5b819ce27`, and all source-bound `SwiftJ2K` R1, R2, and owner-revised R3 verification receipts recorded against `76850bc2286184847a1ecd1dc3ea61ab449ac4bd` / `eb0bcd6f314962575e9b45c0871f9139c0fb11ba` remain valid unchanged-input evidence.

---

## 2. Milestone 12 `DICOMKit` Consumer Integration Summary

Per the owner's deployment-floor decision (`M12_DEPLOYMENT_TARGET_COMPATIBILITY`), `DICOMKit` preserves its existing root platform support (`macOS 15`, `iOS 18`, `tvOS 18`, `visionOS 2`, and `DICOMStudio` `macOS 15.6`) and its `J2KSwift 11.0.3` pin for pre-OS 26 consumers and owner-held JP3D/JPIP features, while delivering real non-held 2D JPEG 2000 and HTJ2K integration for Apple OS 26 consumers in `Integrations/DICOMSwiftJ2KIntegration`:

1. **Immutable Per-Operation Provider Selection (`M12-02`, `DICOMCore` & `DICOMKit`)**:
   - Added `CodecProviderID` (`.j2kSwift`, `.swiftJ2K`, `.defaultRegistry`, `.custom(String)`), `J2KProviderFallbackPolicy` (`.strict` vs `.preselectPredecessorOnUnsupportedCapability`, preselecting before execution only and never retrying after codec execution starts), `J2KCompressedDomainTranscoder`, and `J2KCodecProvider` on `CodecRegistry` (`Sources/DICOMCore/ImageCodec.swift`).
   - Threaded `codecRegistry: CodecRegistry = .shared` across `CompressionManager`, `TransferSyntaxConverter` (`TranscodingConfiguration.codecRegistry`, `TranscodingResult.providerIDs`), `DICOMConverter` (`convertToDICOM`, `checkConversion`), and `DICOMFile` (`pixelData`, `tryPixelData`, `alignedPixelData`, `pixelDataRange`, `pixelDataParallel`). No mutable global provider switch exists.
   - Enforced checked arithmetic on Basic Offset Table (`UInt32.max` guard) and Extended Offset Table (monotone 8-byte offset + non-zero 8-byte length validation against fragment boundaries), canonical multi-frame native pixel normalisation, explicit lossy `ImageType` (`DERIVED`) and `(0028,2110)` provenance updates, and refusal of implicit 16-to-8-bit precision reduction or signedness alteration unless legacy opt-in flags are explicitly set on non-J2K routes.
2. **OS 26 `DICOMSwiftJ2KIntegration` Package and `dicom-swiftj2k` CLI (`M12-03`)**:
   - Added standalone SwiftPM package `Integrations/DICOMSwiftJ2KIntegration` (`.macOS(.v26)`, `.iOS(.v26)`, `.tvOS(.v26)`, `.visionOS(.v26)`) pinning `SwiftJ2K` at `76850bc2286184847a1ecd1dc3ea61ab449ac4bd` and referencing root `DICOMKit` via `path: "../.."`.
   - Implemented `SwiftJ2KDICOMCodec`, `SwiftJ2KDICOMTranscoder`, `J2KCodecProvider.swiftJ2K(options:)`, `CodecRegistry.swiftJ2K(options:fallbackPolicy:)`, and `CodecRegistry.j2kSwiftRollback` executing deterministically on `SwiftJ2K`'s verified scalar backend (`ExecutionPolicy.required(.scalarCPU)`) across 2D DICOM transfer syntaxes `.90` (JPEG 2000 Lossless Only), `.91` (JPEG 2000), `.201` (HTJ2K Lossless Only), `.202` (HTJ2K Lossless RPCL — enforcing PS3.5 §10.18.1 `RPCL`, base resolution ≤ 64, and `TLM`), and `.203` (HTJ2K lossless). `.92`/`.93` Part 2 encoding, Part 2 `MCT`/`MCC`/`MCO` or `Rsiz 0x8000` decoding, lossy `.203`, forced `.metal`/`.accelerate` backends, and held JP3D/JPIP syntaxes are refused before execution under `.strict` or preselect `.j2kSwift` before execution under `.preselectPredecessorOnUnsupportedCapability`.
   - Bridged async `SwiftJ2K` `Encoder` / `Decoder` / `Transcoder` into synchronous `DICOMCore` protocols via `SwiftJ2KSyncBridge` using a dedicated GCD-backed `TaskExecutor`, finite `ResourceLimits` + `PixelDecodeLimits` (`SwiftJ2KProviderOptions`), cooperative task cancellation and bounded join on deadline expiry, and caller-owned `ImageDestination` shared-storage decode (`decodeFrame(_:descriptor:frameIndex:into:)` copying from `SwiftJ2K`'s sealed `ImageDestination` inside the synchronous scope so zero caller pointers escape).
   - Repaired predecessor `J2KSwift 11.0.3`'s non-conformant reversible HTJ2K `CAP` marker (`Ccap^15 = 0x0020` falsely setting `HTIRV = 1` bit 5 and `MAGB = 0` on lossless 5/3 `.201`/`.202` outputs) via `J2KCodestreamInspector.conformingToReversibleHTJ2KCAP(_:)` wired into `J2KSwiftCodec.conformingCodestream(_:transferSyntaxUID:)`, enabling bidirectional `SwiftJ2K <-> J2KSwift` HTJ2K interoperability.
   - Added `dicom-swiftj2k` CLI (`compress`, `decompress`, `convert`, `info`, `--help`) supporting `--provider swiftj2k|j2kswift`, `--fallback strict|predecessor`, `--backend auto|scalar|accelerate|metal`, atomic output writes, and JSON telemetry output (`--report-json <path>`).
3. **Executed Milestone 12 Verification Evidence**:
   - **Root `DICOMKit` regression suite** (`swift test --filter "M12RoutingAndFrameSafetyTests|ConversionDiagnosticsTests|DICOMConverter"`): **`57/57` passed, `0` failures** (`20` `M12RoutingAndFrameSafetyTests` + `18` `ConversionDiagnosticsTests` + `19` `DICOMConverter Shared API`). Root `Package.swift` and `DICOMStudio.xcodeproj` have `0` diff lines.
   - **Nested OS 26 `DICOMSwiftJ2KIntegrationTests` (ordinary)**: **`9/9` passed, `0` failures**, recording exact scalar operation telemetry (`telemetry-report.json`):
     - `compress` (`.90` lossless encode, frames `0` & `1`): `backend = "scalarCPU"`, `fidelity = "exactSamples"`, `pixelAllocationCount = 0`, `peakPixelBytes = 2048`.
     - `convert` (`.90 -> .201` compressed-domain transcode): `backend = "scalarCPU"`, `fidelity = "exactSamples"`, `pixelAllocationCount = 0`, `peakPixelBytes = 0`, `frameIndex` recorded per frame (`0, 1, ...`).
     - `decodeFrame(_:descriptor:frameIndex:into:)` caller-owned decode: `backend = "scalarCPU"`, `fidelity = "exactSamples"`, `pixelAllocationCount = 0`, `copyEvents.isEmpty == true`.
   - **Nested OS 26 ThreadSanitizer** (`swift test --sanitize thread`): **`9/9` passed, `0` failures, `0` data races** (`4.512s`), including bounded concurrent `TaskGroup` execution and tight-budget `HospitalCodecLimits` refusal.
   - **Independent `pydicom 2.4.4` + `dicom-swiftj2k` CLI cross-codec matrix**: **`8/8` passed (`exit = 0`)** using temporary synthetic Part-10 files outside tracked repositories (`0` `.dcm` files retained), proving bidirectional `SwiftJ2K <-> J2KSwift` sample and metadata preservation (`RescaleSlope = 2`, `RescaleIntercept = -1024`, `WindowCenter = 40`, `WindowWidth = 400`, `PhotometricInterpretation`, `BitsAllocated = 16`, `BitsStored = 12`, `PixelRepresentation = 1`) across `.90`, `.201`, `.202`, non-canonical `0x0FFF`-masked negative 12-in-16 input normalisation, and 3-frame unsigned 16-bit `[0, 65535]` compressed-domain `.90 -> .201` transcoding.
   - **Repository payload guards**: `Scripts/check_no_dicom.py` and full Git-tree/archive scanner (`scan-m12-git-tree.py HEAD` on `814145be1a797986e165bdcf2d98d76f6ab6ebee` / tree `00222a7736efa9e6595bdefaca0ce9f291baabb2`) scanned **`7,579` tracked blobs with `0` findings (`status: "passed"`)**.

---

## 3. Reconciled Capability and Qualification Matrix

Historical readiness prose in earlier milestone documents must be read alongside the owner-approved scope holds and remediation tracker ([STATUS.md](Engineering/Remediation/STATUS.md), [R3_CAPABILITY_MATRIX.md](Engineering/Remediation/R3_CAPABILITY_MATRIX.md), and [R3_HELD_VALIDATION_LEDGER.json](Engineering/Remediation/R3_HELD_VALIDATION_LEDGER.json)):

| Subsystem / Capability | Product / Target | Current Implementation & Qualification Status | Release Readiness Boundary |
| --- | --- | --- | --- |
| 2D Part 1 lossless (5/3), near-lossless & lossy (9/7), `1..16`-bit signed/unsigned, `1..N` components, `RCT`/`ICT`, `RGN` ROI, multi-tile, multi-layer, precincts, `POC`, `SOP`/`EPH`, all 6 code-block styles | `SwiftJ2K` | **Implemented & locally verified** (`160` macOS core declarations + `153` iOS Simulator core declarations selected in `R3_HELD_VALIDATION_LEDGER.json`; R1/R2 accepted; M12 `DICOMKit` OS 26 integration verified) | Requires final exact-head hosted CI run, 5 hosted external-oracle checks, and paused R4 closure before `v12.1.0` tag |
| 2D Part 15 HTJ2K cleanup/refinement decode, lossless HT encode, and wavelet-domain `J2K <-> HTJ2K` transcoding (`pixelAllocationCount == 0`) | `SwiftJ2K` | **Implemented & locally verified** on supported single-HT-set 2D profiles (including `.201`/`.202`/`.203` in `DICOMSwiftJ2KIntegration`); `M6-AUD-007` remains tracked in paused R4; multiple non-empty HT sets and combined Part 10+15 direct interop are `ON_HOLD_BY_OWNER` | Requires closure of `M6-AUD-007` (paused R4) and explicit release-note disclosure of held multi-HT-set / Part 10+15 profiles |
| `JP2`, `JPH`, and single-codestream `JPX` containers (`ihdr`, `bpcc`, `colr`, `pclr`+`cmap`, `cdef`, `res `, `rreq`, `xml `, `uuid`, `uinf`, `jp2i`, `asoc`) | `SwiftJ2K` | **Implemented & R2-accepted** (`F07`, `F08`, `F12` closed and merged in PR #29) | Ready subject to release-commit CI and oracle gates |
| Metal GPU & Swift SIMD hardware acceleration behind `ExecutionPolicy` | `SwiftJ2K` | **Implemented & verified** (`100%` byte-identical output vs `.scalarCPU` on lossless/HTJ2K paths; `OperationReport.backend` & `fallbackReason` verified in M9, R2 `F09`, and M12) | Controlled release-commit benchmark comparison (`PERF-03`) paused in R4 |
| 2D `swiftj2k-cli` (`encode`, `decode`, `transcode`, `inspect`, `validate`, `convert`, `compare --mode 2d`, `batch`, `benchmark`, `capabilities`, `completions`) | `swiftj2k-cli` | **Implemented & verified** (`PUB-01`, `M12-CX-03`, `M12-CX-04`, and split 2D CLI tests `cliBatchBenchmarkAndCompletions()` / `cli2DRemediationSubprocessRegressions()` verified) | Ready for 2D scope subject to release-commit CLI conformance run |
| Part 10 JP3D volumetric codec (`JP3D*`, `VolumeEncoder`, `VolumeDecoder`, `VolumeTranscoder`) and CLI `encode3d`/`decode3d` | `SwiftJ2K3D`, `swiftj2k-cli` | **ON_HOLD_BY_OWNER / DEFERRED_TO_FUTURE_RELEASE** (3 November 2026 owner directive; `F01` and JP3D declarations in `1,213`-item `R3_HELD_VALIDATION_LEDGER.json` held; `DICOMKit` keeps JP3D on `J2KSwift 11.0.3`) | Must either remain explicitly marked experimental/deferred or await dedicated post-hold qualification before claiming stable 3D support |
| Part 9 JPIP interactive streaming (`JPIPClient`, `JPIPServer`, `JPIPStreamingSession`) and CLI `jpip` | `SwiftJ2KJPIP`, `swiftj2k-cli` | **ON_HOLD_BY_OWNER / DEFERRED_TO_FUTURE_RELEASE** (3 November 2026 owner directive; `F04`, `R3-C49-01`, `R3-C49-02`, and JPIP declarations in `1,213`-item `R3_HELD_VALIDATION_LEDGER.json` held; `DICOMKit` keeps JPIP on `J2KSwift 11.0.3`) | Must either remain explicitly marked deferred/experimental or await dedicated post-hold qualification before claiming stable JPIP support |
| Five direct external interoperability checks (`Combined Part 10+15`, `Native 3D JPIP`, `Exact WebSocket extension`, `Full 38-bit Part 2 synthesis`, `Multiple non-empty HT sets`) | `SwiftJ2K`, `SwiftJ2K3D`, `SwiftJ2KJPIP` | **ON_HOLD_BY_OWNER / DEFERRED / UNEXECUTED** (Owner Update 15, 2 November 2026; never claimed as passed) | Deferred by owner; never advertise as qualified |

---

## 4. Release Gate Mapping (`RELEASE.md` & `TESTING.md`)

Every release precondition and gate in [RELEASE.md](RELEASE.md) and [TESTING.md](TESTING.md) is mapped below against actual source-bound evidence as of **5 November 2026**:

| Gate / Precondition | Current Status | Bound Evidence / Receipt | Required Action Before Cutting `v12.1.0` |
| --- | --- | --- | --- |
| **Precondition 1 — Hosted CI execution** (`contract 0.9.0` / `0.10.0`) | **PASSED ON M13 PR HEAD (APPLE 2D SCOPE)** | PR #27 (R1), PR #29 (R2), Candidate 46 (`41570552682` `4/4` jobs), and **Milestone 13 PR #31 (`ab895cf719152b2dd692181933bf12d5b819ce27`, hosted Apple CI run `42007848976` `4/4` jobs green, merged at `57d7628fc9b9e4daa5af198eb8831599444f657b`)** passed exact-head hosted CI on enabled non-held 2D Apple scope; `DICOMKit` PR #236 (`814145be1a797986e165bdcf2d98d76f6ab6ebee`, merged at `2b50a70619323be748b94c08c363e6912277b1f0`) passed `15/15` hosted CI checks; Linux CI is `OUT_OF_CURRENT_SCOPE_BY_OWNER` | Re-run and archive exact-head hosted CI on the final release candidate commit |
| **Precondition 2 — Private vulnerability reporting enabled** (`SECURITY.md`) | **OPEN (ORGANISATION-OWNER ACTION)** | Checked in [SECURITY.md](../SECURITY.md): `private-vulnerability-reporting` was disabled when inspected; requires GitHub organisation-owner setting | Organisation owner enables private vulnerability reporting on `raster-labs/SwiftJ2K` and verifies via GitHub API |
| **Precondition 3 — Explicit owner release assignment** | **NOT ASSIGNED (GATED)** | Milestone 13 authorises release *preparation* (merged via PR #31 at `57d7628fc9b9e4daa5af198eb8831599444f657b`), not tagging or publishing `v12.1.0` | Owner issues explicit release-cut instruction after reviewing open gates |
| **Contract identity & Swift 6.4 validation** (`COMMON_CONTRACT_SHA256.txt`, `Swift64/**`) | **PASSED (EXECUTED IN M13)** | `shasum -a 256 -c Documentation/COMMON_CONTRACT_SHA256.txt` (`7/7` OK) and `git diff Sources/ Documentation/Engineering/Swift64/` empty on `57d7628fc9b9e4daa5af198eb8831599444f657b` and in hosted run `42007848976` | Re-verify on final release commit |
| **Core 2D unit/regression suite (macOS & iOS Simulator)** | **PASSED (HOSTED RUN `42007848976` & LOCAL)** | Hosted run `42007848976` passed `macOS 26` (`160` core declarations across ordinary, ASan, and TSan with `0` held executed) and `iOS Simulator 26` (`153` selected declarations: `148` passed + `5` oracle skips, `0` failed) on `ab895cf719152b2dd692181933bf12d5b819ce27` (`Sources/` & `Tests/` identical to `76850bc`) | Re-run on final release commit under release toolchain |
| **AddressSanitizer & ThreadSanitizer** | **PASSED ON 2D CORE & M12 ADAPTER; JPIP/3D HELD** | `SwiftJ2KTests` core partition (`160` declarations) passed ASan and TSan in hosted run `42007848976` (`ab895cf7`); `DICOMSwiftJ2KIntegrationTests` passed ThreadSanitizer (`9/9`, `0` races) in M12-03; JPIP/3D sanitizer suites (`R3-C49-01`) are `ON_HOLD_BY_OWNER` | Run release-commit ASan/TSan on enabled non-held release scope |
| **Five ordinary external-oracle declarations** (`OpenJPEG`, `Kakadu`, `OpenJPH`) | **UNEXECUTED ON HOSTED CI; PASSED IN LOCAL MILESTONES** | Local oracle suites passed in M2–M8 and R1/R2; `5` `@Test` declarations skip when external binaries are absent on hosted Apple runners (tracked under paused R4) | Execute with pinned OpenJPEG 2.5.4, Kakadu 8.4.1, and OpenJPH 0.30.1 on the release commit and archive receipt |
| **Paused Phase R4 items** (`M6-AUD-007`, historical binary provenance, `PERF-03` release benchmark) | **PAUSED_BY_OWNER / OPEN** | Paused on 4 November 2026 (`human-pause-20261104.json`); controller guard `005` statically accepted only, runtime unexecuted | Obtain scoped owner instruction to complete or disposition `M6-AUD-007`, provenance audit, and `PERF-03` benchmark before tagging |
| **Fuzzing & hostile-input bounds** (`SECURITY.md`, `TESTING.md`) | **BASELINE EXECUTED (M5/M6); FULL-SURFACE RELEASE RUN PENDING** | 1-hour decode fuzz campaigns executed in M5 (`MILESTONE5.md`), HT/transcode bounded fuzzing in M6 (`MILESTONE6.md`), and hostile truncation/overflow/EOT/BOT/budget negative tests in R1–R3 & M12 (`20/20` + `9/9`) | Execute release-commit bounded fuzzing across enabled entry points if required by final R4/release scope |
| **Downstream consumer qualification (`Examples/Consumer`, `MigrationExample`, `DICOMKit`)** | **PASSED & MERGED (EXECUTED IN M12 & M13)** | `DICOMKit` OS 26 `DICOMSwiftJ2KIntegration` (`814145be1a797986e165bdcf2d98d76f6ab6ebee`, merged via PR #236 at `2b50a70619323be748b94c08c363e6912277b1f0`: `57/57` root tests, `9/9` OS 26 tests + TSan, `8/8` `pydicom` CLI checks, `15/15` hosted CI checks); `Examples/Consumer` & `Examples/MigrationExample` verified in hosted run `42007848976` and locally | After `v12.1.0` tag exists, verify fresh `.package(url: ..., from: "12.1.0")` consumer resolution |
| **Licence, notices, and SBOMs** (`LICENSE`, `THIRD_PARTY_NOTICES.md`) | **RECONCILED IN M13; CLEAN-ROOM T.814 & MIT RELICENSING 10 NOV 2026** | Historical M13 snapshot verified `Apache-2.0` + retained `BSD-2-Clause` (`HTTables.swift`, `HTBlockCoder.swift`); superseded on `feat/clean-room-htj2k-t814` and `chore/relicense-mit` (10 Nov 2026, contract `0.11.0`), which replaced both files with a clean-room ITU-T Rec. T.814 implementation and relicensed the repository to `MIT` (`NOTICE` removed, zero shipped `BSD-2-Clause` code) as recorded in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md); zero external SwiftPM dependencies | Emit and schema-validate SPDX & CycloneDX SBOMs from the exact release commit |
| **No-DICOM / no-patient-data Git tree & archive guard** | **PASSED (EXECUTED IN M12 & M13)** | `DICOMKit` `814145be...` (`7,579` blobs, `0` findings) and `SwiftJ2K` candidate tree scanned including archive members (`0` findings) | Re-run before any future branch/release publication |

---

## 5. Verification Executed in Milestone 13

Executed on macOS arm64 with Swift 6.4 (`Apple Swift version 6.4` / Xcode toolchain) with at most one native job active at a time:

1. **Shared Contract SHA-256 Manifest Verification**:
   - Command: `(cd Documentation && shasum -a 256 -c COMMON_CONTRACT_SHA256.txt)`
   - Result: `exit = 0` (`CLI_CONTRACT.md`, `COMMON_API.md`, `MEMORY_CONTRACT.md`, `PERFORMANCE.md`, `PLATFORMS.md`, `SUITE_POLICY.md`, `TESTING.md`: all `OK`).
2. **Production Source and Historical Swift 6.4 Preservation Check**:
   - Command: `git diff --exit-code Sources/ Package.swift VERSION Documentation/Engineering/Swift64/`
   - Result: `exit = 0` (`0` bytes changed).
3. **Standalone Consumer / Migration Example Verification**:
   - Command: `swift run --scratch-path <external-scratch> --package-path Examples/MigrationExample MigrationExample`
   - Result: `exit = 0` (`Migration example passed: ... decode into caller storage with 0 pixel allocations and 0 copy events.`).
4. **Full Git-Tree and Archive Prohibited-Payload Scan**:
   - Scanned all tracked blobs (including recursive ZIP/TAR/gzip/bzip2/XZ archive inspection and fail-closed opaque archive detection) on `codex/m13-swiftj2k-release-preparation` `HEAD^{tree}` using `DICOMKit`'s `check_no_dicom.py` rules: **`0` findings (`status: "passed"`)**.

---

## 6. Remaining Owner Decisions Before Any Stable Release

1. **Product Packaging Decision for Held `SwiftJ2K3D` and `SwiftJ2KJPIP` Targets**:
   - Decide whether `12.1.0` ships with `SwiftJ2K3D` and `SwiftJ2KJPIP` explicitly documented as experimental/deferred products (keeping downstream `DICOMKit` JP3D/JPIP routes on `J2KSwift 11.0.3`), or waits until the owner lifts the 3 November 2026 JPIP/3D hold (`R3_HELD_VALIDATION_LEDGER.json`) and completes full JPIP/3D qualification.
2. **Scoped Phase R4 Completion Authority**:
   - Decide when to resume paused R4 (`M6-AUD-007`, historical binary provenance verification, the 5 hosted external-oracle checks, and controlled `PERF-03` release benchmarks).
3. **Repository Security & CI Preconditions**:
   - Enable GitHub private vulnerability reporting on `raster-labs/SwiftJ2K`, run exact-head hosted CI on the final release candidate, and issue an explicit release-cut assignment per [RELEASE.md](RELEASE.md).

> **Postscript — 6 November 2026 (`v12.1.0` Release Directive Executed):** Following Phase A (`SwiftJ2K` PR #33 merged at `e3666b3fae5fa6984e6061ac0260d3d5d1fc9297`, hosted CI run `42167469950` `4/4` jobs green) and Phase B (`DICOMKit` PR #237 merged at `1178e96de522acbb0d59b3c840a0b83ec2372c14`), and verification of GitHub Private Vulnerability Reporting (`"enabled": true`), the owner explicitly authorised releasing **`SwiftJ2K v12.1.0` (`12.1.0`)** for the qualified 2D `SwiftJ2K` codec and 2D `swiftj2k-cli` scope (consumed by `DICOMKit` via `from: "12.1.0"`), with **`SwiftJ2K3D` and `SwiftJ2KJPIP` documented as experimental preview products in `12.1.0` and scheduled for full qualification and enhancement in `12.2.0`**. See [RELEASE-v12.1.0.md](RELEASE-v12.1.0.md).
