# Milestone 12 Evidence — CLI and Consumer Breadth

- **Milestone:** 12 — CLI and consumer breadth (`swiftj2k-cli` remaining verbs and multi-format image I/O, `batch` and `compare`, shell `completions`, and consumer migration guide & verification across all products)
- **Date:** 28 October 2026
- **Branch:** `antigravity/milestone12-cli-consumer-breadth`
- **Base commit (`origin/main`):** `b76e60adc9b2219fdba496e408d42d8fc44671b1`
- **Pinned predecessor revision:** [`Raster-Lab/J2KSwift@7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca`](https://github.com/Raster-Lab/J2KSwift/commit/7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca)
- **Common contract version:** `0.10.0` (verified byte-identical against `Documentation/COMMON_CONTRACT_SHA256.txt`)
- **Target library version:** `12.1.0` (unreleased; first stable tag waits for Milestone 13 release preparation and CI precondition)

---

## 1. Executive Summary

Milestone 12 completes the functional migration of `Raster-Lab/J2KSwift` into `SwiftJ2K` by auditing and migrating the remaining `J2KCLI` / `J2KCLICore` command-line surface into `swiftj2k-cli` and updating the consumer migration guide (`MIGRATION.md`) and verification examples (`Examples/Consumer`, `Examples/MigrationExample`) for every consumer named in the `IMPLEMENTATION.md` product dispositions (`DICOMKit`, `CompressionFamily`, `VoxeliaValidation`, `DICOMAdapter`, `RasterOneImage`, `OneImageViewer-iOS`, and `telerad-dicom-viewer`).

Specifically, Milestone 12 delivers:
1. **Multi-format 2D and 3D image I/O (`Sources/SwiftJ2KCLI/CLIImageIO.swift`):** Checked-arithmetic readers and writers for `PGM` (`P5`), `PPM` (`P6`), `PNM`, `PNG` (ISO/IEC 15948 with `zlib` `IDAT`, all 5 scanline filters, and `sBIT` significant-bits preservation), uncompressed `TIFF` (Baseline 6.0 little/big-endian, 8/12/16-bit, `SampleFormat` signed/unsigned, `SMaxSampleValue` precision preservation, chunky and planar), raw binary `RAW` (`--dimensions`, `--bit-depth`, `--components`, `--signed`), 2D/3D `NRRD`, and 3D slice directories.
2. **Remaining `swiftj2k-cli` verbs (`Sources/SwiftJ2KCLI/CLIVerbs.swift` & `main.swift`):**
   - `convert`: Uncompressed format conversion (`nrrd`, `pgm`, `ppm`, `pnm`, `png`, `tiff`, `raw`) with optional `--bit-depth 8|16` scaling and atomic file replacement.
   - `compare`: 2D and 3D quality comparison (`--mode 2d|3d`, `--bit-exact`, `--max-error`, `--min-psnr`, `--json`) computing per-component and overall MSE, MAE, MaxError, PSNR, and bit-exactness across compressed or uncompressed inputs.
   - `batch`: Bounded-concurrency (`withTaskGroup`, `--threads 1..8`) batch processor for `encode`, `decode`, `transcode`, `encode3d`, and `decode3d` with `--input-list`, `--recursive`, `--filter`, `--exclude`, `--output-suffix`, `--continue-on-error`, `--progress`, and `--json`.
   - `encode3d` and `decode3d`: Part 10 JP3D volumetric compression and decompression (`SwiftJ2K3D`) over slice directories, 3D NRRD volumes, and 3D RAW volumes (`--codec j2k-lossless|j2k-lossy|htj2k-lossless|htj2k-lossy`, `--tile-size`, `--levels`, `--progression`, `--spacing`, `--origin`, `--slice-range`, `--region`, `--resolution-level/--scale`, `--layers`, `--slice-naming`).
   - `jpip`: Part 9 interactive JPIP streaming (`SwiftJ2KJPIP`) via `jpip client` and `jpip server`, supporting both remote `--server URL` endpoints and self-contained loopback `--single-file` / `--data-dir` execution, spatial `--region`, `--resolution-level`, `--quality-layers`, `--components`, `--coding-preference`, and `--once` server readiness verification.
   - `benchmark`: Strictly in-process encode and decode performance benchmarking (`--runs`, `--warmup`, `--encode-only`, `--decode-only`, `--htj2k`, `--compare-all`, `--format text|json|csv`) with zero external shell-outs (`POL-01`).
   - `completions`: Shell completion script generation for `bash`, `zsh`, and `fish`.
3. **Five predecessor CLI defects fixed (`M12-AUD-001` through `M12-AUD-005`):** Resolved 16-bit big-endian/signedness metric corruption in `Compare.swift`, sequential loop ignoring `--threads` in `MultiFileProcessor.swift`, non-standard `CZlib` and unchecked integer arithmetic in `PNGSupport.swift`/`TIFFSupport.swift`, runtime `opj_compress`/`opj_decompress` shell-outs in `Benchmark.swift` (`POL-01`), and raw `exit(1)` / non-atomic writes / `stderr` path leakage across CLI verbs (`CLI-05`–`CLI-08`).

---

## 2. Predecessor CLI Inventory, Audit, and Dispositions (`7acc9ae4`)

### 2.1 Predecessor Source Files (`Sources/J2KCLI` & `Sources/J2KCLICore` — 28 files, 9,585 lines)

| Predecessor Path (`7acc9ae4`) | Blob SHA | Lines | Disposition | Successor Path / Rationale |
| --- | --- | ---: | --- | --- |
| `Sources/J2KCLI/Entry.swift` | `9ef86151` | 16 | Adapted | `Sources/SwiftJ2KCLI/main.swift` (`drive()` entry point with `SIGINT`/`SIGPIPE` handling and contract exit codes `0, 2, 3, 4, 5, 6, 7, 130`) |
| `Sources/J2KCLICore/CLIMain.swift` | `fb671645` | 269 | Adapted | `Sources/SwiftJ2KCLI/main.swift` (top-level command router and global help/version/verbosity dispatcher) |
| `Sources/J2KCLICore/CLIArgumentParser.swift` | `258ab125` | 145 | Adapted | `Sources/SwiftJ2KCLI/main.swift` (`parse(_:)` option parser with pre-open validation) |
| `Sources/J2KCLICore/OutputFormatter.swift` | `6cd7170b` | 168 | Adapted | `Sources/SwiftJ2KCLI/main.swift` & `CLIVerbs.swift` (`report(_:json:to:)`, deterministic sorted-key JSON and text/CSV formatting) |
| `Sources/J2KCLICore/ProgressReporter.swift` | `a2909866` | 145 | Adapted | `Sources/SwiftJ2KCLI/main.swift` & `CLIVerbs.swift` (5-level cumulative stderr diagnostics and `--progress` reporting) |
| `Sources/J2KCLICore/Encode.swift` | `e13d7be6` | 538 | Adapted | `Sources/SwiftJ2KCLI/main.swift` (`encode` verb supporting `nrrd`, `pgm`, `ppm`, `pnm`, `png`, `tiff`, `raw` inputs and `j2k`, `htj2k`, `jp2`, `jph`, `jpx` outputs) |
| `Sources/J2KCLICore/Decode.swift` | `635b3ba4` | 405 | Adapted | `Sources/SwiftJ2KCLI/main.swift` (`decode` verb supporting `nrrd`, `pgm`, `ppm`, `pnm`, `png`, `tiff`, `raw` outputs) |
| `Sources/J2KCLICore/Transcode.swift` | `b53f0be9` | 382 | Adapted | `Sources/SwiftJ2KCLI/main.swift` (`transcode` verb operating in the wavelet coefficient domain with `pixelAllocations == 0`) |
| `Sources/J2KCLICore/Info.swift` | `d0795866` | 480 | Adapted | `Sources/SwiftJ2KCLI/main.swift` (`inspect` and `validate` verbs, renamed per Contract `CLI-02`) |
| `Sources/J2KCLICore/Convert.swift` | `3da7129c` | 260 | Adapted | `Sources/SwiftJ2KCLI/CLIVerbs.swift` (`runConvertCommand`) |
| `Sources/J2KCLICore/Compare.swift` | `7b6127c7` | 217 | Adapted / Fixed | `Sources/SwiftJ2KCLI/CLIVerbs.swift` (`runCompareCommand`, `runCompare3D`; fixed `M12-AUD-001` 16-bit endian/signedness bug) |
| `Sources/J2KCLICore/Batch.swift` | `9ef8fa19` | 457 | Adapted | `Sources/SwiftJ2KCLI/CLIVerbs.swift` (`runBatchCommand` supporting `encode`, `decode`, `transcode`, `encode3d`, `decode3d`) |
| `Sources/J2KCLICore/MultiFileProcessor.swift` | `d1cb8be3` | 287 | Adapted / Fixed | `Sources/SwiftJ2KCLI/CLIVerbs.swift` (`discoverBatchInputs` & bounded `withTaskGroup` worker pool; fixed `M12-AUD-002`) |
| `Sources/J2KCLICore/ImageIO.swift` | `b274568e` | 476 | Adapted / Fixed | `Sources/SwiftJ2KCLI/CLIImageIO.swift` (`parsePGMOrPPM`, `formatPGM`, `formatPPM`, `parseRAW`, `formatRAW`, 2D/3D `NRRD`, slice directories) |
| `Sources/J2KCLICore/PNGSupport.swift` | `39b38aa1` | 336 | Adapted / Fixed | `Sources/SwiftJ2KCLI/CLIImageIO.swift` (`parsePNG`, `formatPNG` using standard `zlib`, `sBIT` preservation, and checked arithmetic; fixed `M12-AUD-003`) |
| `Sources/J2KCLICore/TIFFSupport.swift` | `5d80333d` | 491 | Adapted / Fixed | `Sources/SwiftJ2KCLI/CLIImageIO.swift` (`parseTIFF`, `formatTIFF` with `SMaxSampleValue`, `SampleFormat`, and checked arithmetic; fixed `M12-AUD-003`) |
| `Sources/J2KCLICore/Encode3D.swift` | `0750a8b1` | 450 | Adapted | `Sources/SwiftJ2KCLI/CLIVerbs.swift` (`runEncode3DCommand` backed by `SwiftJ2K3D`) |
| `Sources/J2KCLICore/Decode3D.swift` | `591aa384` | 438 | Adapted | `Sources/SwiftJ2KCLI/CLIVerbs.swift` (`runDecode3DCommand` backed by `SwiftJ2K3D` `JP3DDecoder` and `JP3DROIDecoder`) |
| `Sources/J2KCLICore/JPIPClient.swift` | `d0c954dc` | 275 | Adapted | `Sources/SwiftJ2KCLI/CLIVerbs.swift` (`runJPIPClient` backed by `SwiftJ2KJPIP` `JPIPContractSessionAdapter` and loopback `JPIPServer`) |
| `Sources/J2KCLICore/JPIPServer.swift` | `b9ca0bc2` | 238 | Adapted | `Sources/SwiftJ2KCLI/CLIVerbs.swift` (`runJPIPServer` backed by `SwiftJ2KJPIP` `JPIPServer`) |
| `Sources/J2KCLICore/Benchmark.swift` | `20d9ccab` | 530 | Adapted / Fixed | `Sources/SwiftJ2KCLI/CLIVerbs.swift` (`runBenchmarkCommand`; removed runtime `opj_*` shell-outs per `POL-01`, `M12-AUD-004`) |
| `Sources/J2KCLICore/Completions.swift` | `f8228aa5` | 274 | Adapted | `Sources/SwiftJ2KCLI/CLIVerbs.swift` (`runCompletionsCommand` for `bash`, `zsh`, `fish`) |
| `Sources/J2KCLICore/DICOMSupport.swift` | `c8ebbcdd` | 473 | Retired | Retired per `IMPLEMENTATION.md` §Product dispositions (`POL-05`): DICOM container parsing belongs in `DICOMKit`, not the domain-neutral codec CLI |
| `Sources/J2KCLICore/DaemonInstall.swift` | `046a5d42` | 150 | Retired | Retired per `IMPLEMENTATION.md` §Product dispositions: `j2kd` XPC daemon is deferred/out of codec contract scope |
| `Sources/J2KCLICore/DaemonPing.swift` | `d86c25fc` | 109 | Retired | Retired with `j2kd` daemon |
| `Sources/J2KCLICore/Headless.swift` | `781fb1d3` | 75 | Retired | Retired per `IMPLEMENTATION.md` §CLI surface (`swiftj2k-cli` is natively headless on all platforms) |
| `Sources/J2KCLICore/InProcBench.swift` | `4c992ba9` | 308 | Folded / Retired | Folded into `swiftj2k-cli benchmark` (`runBenchmarkCommand` is 100% in-process) |
| `Sources/J2KCLICore/OPJCompress.swift`, `OPJDecompress.swift`, `OPJDump.swift` | `9ef823bc`, `b89ec0ae`, `48091cb2` | 1,189 | Retired | Retired per `IMPLEMENTATION.md` §CLI surface (predecessor OpenJPEG flag compatibility shims are not part of the `CLI_CONTRACT.md` surface) |

### 2.2 Predecessor CLI Test Files (`Tests/J2KCLITests` — 20 files, 3,522 lines)

| Predecessor Test File (`7acc9ae4`) | Blob SHA | Lines | Successor Coverage |
| --- | --- | ---: | --- |
| `ArgumentParserTests.swift`, `CLICommandTests.swift`, `CLIIntegrationTests.swift`, `CLIRealIntegrationTests.swift` | `4bc8a3b4`, `df9ee067`, `3f86bc70`, `598c4438` | 917 | Covered by `Scripts/test-cli.py` (246 process checks) and `Tests/SwiftJ2KTests/CLIBreadthAndConsumerTests.swift` |
| `EncodeDecodeTests.swift`, `TranscodeTests.swift`, `InfoValidateTests.swift` | `c435e187`, `d4cf8098`, `ca15df5b` | 531 | Covered by `Scripts/test-cli.py` (`encode`, `decode`, `transcode`, `inspect`, `validate`) |
| `ConvertCompareTests.swift`, `ImageIOTests.swift`, `PGMPPMTests.swift` | `07ef07e4`, `36222c9a`, `dfbd10c5` | 645 | Covered by `Scripts/test-cli.py` and `CLIBreadthAndConsumerTests.swift` (`PGM`, `PPM`, `PNG`, `TIFF`, `RAW`, `NRRD`, `convert`, `compare`) |
| `BatchTests.swift`, `MultiFileTests.swift` | `3389b2d3`, `94bf933f` | 351 | Covered by `Scripts/test-cli.py` and `CLIBreadthAndConsumerTests.swift` (`batch encode|decode|transcode`, `--threads 2`, `--filter`) |
| `JP3DCLITests.swift` | `99123a63` | 212 | Covered by `Scripts/test-cli.py` and `CLIBreadthAndConsumerTests.swift` (`encode3d`, `decode3d`, 3D `compare`) |
| `JPIPCLITests.swift` | `4fc1308b` | 164 | Covered by `Scripts/test-cli.py` and `CLIBreadthAndConsumerTests.swift` (`jpip client`, `jpip server --once`) |
| `BenchmarkCLITests.swift`, `CompletionsTests.swift`, `ErrorHandlingTests.swift`, `PipeIOTests.swift`, `ProgressOutputTests.swift` | `e42cb64f`, `7f5d2a7c`, `c23052b1`, `327eb263`, `562c1e9d` | 569 | Covered by `Scripts/test-cli.py` (`benchmark`, `completions`, pipes, verbosity `1..5`, exit codes `0, 2, 3, 4, 5, 6, 130`) |
| `DICOMTests.swift` | `a2666d50` | 133 | Retired with `DICOMSupport.swift` (`POL-05`) |

---

## 3. Predecessor CLI Defects Fixed in Milestone 12

1. **`M12-AUD-001` — 16-bit endianness and signedness corruption in `Compare.swift` (`Sources/J2KCLICore/Compare.swift:753–758`):**
   - *Predecessor defect:* `Compare.swift` read 16-bit `J2KComponent.data` unconditionally as unsigned big-endian (`(UInt16(d[i*2]) << 8) | UInt16(d[i*2+1])`), ignoring both little-endian storage and signed (`Int16`) components. Comparing a decoded 16-bit little-endian image against a 16-bit reference produced bogus MSE/PSNR values.
   - *Fix:* `runCompareCommand` and `runCompare3D` in `Sources/SwiftJ2KCLI/CLIVerbs.swift` evaluate all sample differences through descriptor-aware `readLogicalSample` and `readVolumeComponentSample`, preserving exact byte order, `meaningfulBits` peak $(2^B - 1)$, and signed two's-complement values.
2. **`M12-AUD-002` — Sequential execution ignoring `--threads` in `MultiFileProcessor.swift` (`Sources/J2KCLICore/MultiFileProcessor.swift:1561`):**
   - *Predecessor defect:* `processFilesInParallel` accepted a `threads` parameter but executed a sequential `for` loop (`// Simplified sequential execution for Swift 6 compatibility`).
   - *Fix:* `runBatchCommand` in `Sources/SwiftJ2KCLI/CLIVerbs.swift` uses a bounded `withTaskGroup` worker pool capped at `maxConcurrency = min(8, lim.maximumWorkers)` (`--threads 1..8`) while preserving deterministic input-index ordering in the aggregated report.
3. **`M12-AUD-003` — Non-standard `CZlib` dependency and unchecked arithmetic in `PNGSupport.swift` / `TIFFSupport.swift`:**
   - *Predecessor defect:* `PNGSupport.swift` imported a non-standard `CZlib` module (failing on standard macOS/Linux toolchains that expose `zlib`) and computed `width * height * channels * bytesPerSample` and TIFF strip offsets without overflow checks or `ResourceLimits` admission.
   - *Fix:* `Sources/SwiftJ2KCLI/CLIImageIO.swift` imports standard `zlib`, uses `checkedAdd` and `checkedMultiply` throughout `parsePNG`, `formatPNG`, `parseTIFF`, `formatTIFF`, `parsePGMOrPPM`, and `parseRAW`, enforces `ResourceLimits.maximumDimension`, `maximumCompressedBytes`, and `maximumDecodedBytes` before allocation, and preserves sub-16-bit precision (`12`-bit medical images) via PNG `sBIT` and TIFF `SMaxSampleValue` tags.
4. **`M12-AUD-004` — Runtime shell-outs to external `opj_compress`/`opj_decompress` in `Benchmark.swift` (`Sources/J2KCLICore/Benchmark.swift:3331`):**
   - *Predecessor defect:* `Benchmark.swift` invoked external executables (`opj_compress`, `opj_decompress`) via `Process()` at runtime, violating Contract `POL-01`.
   - *Fix:* `runBenchmarkCommand` in `Sources/SwiftJ2KCLI/CLIVerbs.swift` executes all benchmark presets (`j2k-lossless`, `htj2k-lossless`, `j2k-lossy`) strictly in-process using `SwiftJ2K.Encoder` and `SwiftJ2K.Decoder`.
5. **`M12-AUD-005` — Direct `exit(1)` calls, non-atomic writes, and `stderr` path leakage (`CLI-05`–`CLI-08`):**
   - *Predecessor defect:* Verb implementations called `exit(1)` directly, wrote output files in-place without `--overwrite` checks or temporary file rollback, and printed input/output file paths in error messages.
   - *Fix:* All Milestone 12 verbs route errors through `exitStatus(for:)` (`0, 2, 3, 4, 5, 6, 7, 130`), write outputs atomically via `publish(_:to:overwrite:)`, and emit path-free diagnostics on `stderr`.

---

## 4. Verification and Benchmark Evidence

### 4.1 Common Contract Integrity

```text
$ shasum -a 256 -c Documentation/COMMON_CONTRACT_SHA256.txt
Documentation/SUITE_POLICY.md: OK
Documentation/COMMON_API.md: OK
Documentation/MEMORY_CONTRACT.md: OK
Documentation/CLI_CONTRACT.md: OK
Documentation/TESTING.md: OK
Documentation/PERFORMANCE.md: OK
Documentation/PLATFORMS.md: OK
```

### 4.2 Unit Test Suites (`SwiftJ2KTests`, `SwiftJ2K3DTests`, `SwiftJ2KJPIPTests`)

- `SwiftJ2KTests`: `125/125` tests passing (including `CLIBreadthAndConsumerTests` covering `M12-AUD-001` through `M12-AUD-005` and consumer bridge round-trips).
- `SwiftJ2K3DTests`: `490/490` tests passing.
- `SwiftJ2KJPIPTests`: `544/544` tests passing.
- **Total Swift unit tests:** `1,159/1,159` passing (`0` failures).

### 4.3 Black-Box CLI Conformance Suite (`Scripts/test-cli.py`)

```text
$ python3 Scripts/test-cli.py --binary .build/release/swiftj2k-cli --output /tmp/cli-evidence-m12
swiftj2k-cli: 246 process checks passed
```

Covers all 13 commands (`encode`, `decode`, `transcode`, `inspect`, `validate`, `convert`, `compare`, `batch`, `encode3d`, `decode3d`, `jpip`, `benchmark`, `capabilities`, `completions`, plus `help` and `version`) across `NRRD`, `PGM`, `PPM`, `PNG`, `TIFF`, `RAW`, `J2K`, `HTJ2K`, `JP2`, `JPH`, `JPX`, and `JP3D`.

### 4.4 Independent Consumer & Migration Examples

```text
$ swift run --package-path Examples/Consumer
Independent SwiftJ2K/SwiftJ2K3D/SwiftJ2KJPIP consumer passed; 106-byte Part 1, 126-byte HTJ2K, 353-byte JP3D codestreams and JPIP session round-tripped.

$ swift run --package-path Examples/MigrationExample
Migration example passed: 115-byte lossless codestream; decode into caller storage with 0 pixel allocations and 0 copy events.
```

### 4.5 Release Benchmark Evidence (`swiftj2k-cli benchmark`)

Executed on Apple Silicon (`arm64-apple-macosx`, release build `-c release`, fixture `Tests/SwiftJ2KTests/Fixtures/Lossless/g16_256x256_smooth.opj.j2k`, $256 \times 256$ 16-bit greyscale, `--runs 10 --warmup 2 --compare-all --json`):

| Preset | Backend | Compressed Size | Ratio | Encode Median (ms) | Encode Throughput (MP/s) | Decode Median (ms) | Decode Throughput (MP/s) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `j2k-lossless` | `accelerated` | 64,328 B | 2.04× | 10.06 ms | 6.52 MP/s | 10.80 ms | 6.07 MP/s |
| `htj2k-lossless` | `accelerated` | 72,777 B | 1.80× | 1.60 ms | 40.93 MP/s | 1.40 ms | 46.73 MP/s |
| `j2k-lossy` | `accelerated` | 61,484 B | 2.13× | 13.76 ms | 4.76 MP/s | 11.99 ms | 5.47 MP/s |

---

## 5. Milestones 1–12 Audit Remediation Update — 30 October 2026 (Phases R1 & R2 Accepted and Merged into `main` at `46be90fc`; Phase R3 CLI `F01`/`F04` Submitted Pending Audit; Phase R4 Open)

Independent audit review of PR #27 (`24b18814c29362f3726321d6618d460da3606e8d`) identified four Milestone 12 CLI findings (`M12-CX-01`–`M12-CX-04`), CLI propagation of `F01`–`F12`, and the Linux `zlib` compilation failure (`M12-CI`, GitHub Actions run `40684586676` / Linux job `122803568965`). Canonical tracking lives in [Engineering/Remediation/STATUS.md](Engineering/Remediation/STATUS.md), with executed receipts under `Documentation/Engineering/Remediation/Evidence/{R1,R2,R3}/`.

- **Phase R1 (`R1_ACCEPTED` by Codex at `c4706d58cc5dde4828ea71f324817590f0671e78`, PR #28 GitHub Actions run `40864296519` all `7/7` jobs passed; merged into `main` via PR #27 at `7ffdc6e2245c3af5c07ea99d008e3effa687241c`)**:
  - **`M12-CX-01`, `R1-CI-01`, & `R1-CI-02` (`R1_ACCEPTED`)**: Removed duplicate `[UInt8](data)` input copies across `parseTIFF`, `parsePNG`, `parsePGMOrPPM`, and `parseRAW`; eliminated intermediate `stripBytes` copying for single-strip TIFFs; admitted 16-bit greyscale contract storage before strip buffering; wrapped multi-strip tag arrays and assembled strip buffers in ARC-tracked `TIFFOwnedTagList` / `TIFFOwnedStripBuffer` (`deinit`-only `.exit` telemetry) with simultaneous `old + new` overlap admission; and verified across all `4` Linux debug/release jobs and macOS debug/ASan/TSan.
  - **`M12-CX-02` & CLI `F02`/`F03`/`F05` (`R1_ACCEPTED`)**: Hardened `decode3d --region`, `--slice-range`, `jpip client --region`, and `encode --roi` with checked arithmetic and dimension bounds (clean exit `2`, no `SIGTRAP`); rejected `--resolution-level > 32` with exit `2`; extended 3D NRRD/RAW/compare I/O to `1...38`-bit signed/unsigned integers without `Float` truncation; and propagated `--max-memory`, `--timeout`, and `--threads` across `encode3d`, `decode3d`, `compare`, and `jpip`.
  - **`M12-CI` (R1 scope `R1_ACCEPTED` at `c4706d58`)**: Replaced `#if canImport(zlib)` in `CLIImageIO.swift` with an internal `CZlibShim` C target (`Sources/CZlibShim`, `.linkedLibrary("z")`) including `<zlib.h>` directly for portable Darwin and Linux compilation.
- **Phase R2 (`R2_ACCEPTED` by Codex at `7e7cfb77079e663eb076d76bd022a8ce5ad77ff1`, PR #29 GitHub Actions run `41026445369` all `7/7` jobs passed; merged into `main` at `46be90fc3bf50429956725ee592687d8ff8e7344`, tree `64769ea508a0e2b33281e29ae47cd3b61d789240`)**:
  - **`M12-CX-03` (`P1`, `R2_ACCEPTED`)**: Implemented normative W3C PNG Clause 11.3.2.4 `sBIT` handling in `CLIImageIO.swift`, including mandatory pre-`PLTE` and pre-`IDAT` chunk ordering, exact per-colour-type channel count and `1...sampleBits` bounds, right-shifting on read, left-bit-replicating on write, and deterministic rejection of unequal per-channel `sBIT` (`rc=4`) or unscaled out-of-range samples (`rc=2`).
  - **`M12-CX-04` (`P2`, `R2_ACCEPTED`)**: Implemented deliberate Baseline TIFF 6.0 `PhotometricInterpretation` (tag `262`) and `ExtraSamples` (tag `338`) handling in `CLIImageIO.swift`, distinguishing missing, `0` (unspecified extra channel — preserved with `.uninterpreted` role, never mislabelled as alpha), `1` (associated/premultiplied alpha), and `2` (unassociated/straight alpha), inverting `WhiteIsZero` (`0`) colour channels, expanding supported `Palette Color` (`3`) LUTs, and rejecting unsupported photometric layouts (`rc=4`).
  - **CLI Propagation of `F07`–`F12` (`R2_ACCEPTED`)**: Propagated `--copy-policy` and `--metadata-policy` across `encode3d`, `decode3d`, and `jpip client`, enabled negative `--origin` coordinates and 3D NRRD `space dimension`/`space directions`/`space origin` read/write, and hardened `jpip client --components` parsing.
- **Phase R3 (`submitted` on `antigravity/r3-standards-remediation` from `main` `46be90fc3bf50429956725ee592687d8ff8e7344`, incorporating `R3_REWORK` repairs on top of `2b2d79a1716fe55d40836fbcd4e7c50ed6bbb9f6`; `Codex acceptance: pending independent audit`)**:
  - **CLI `F01` (`encode3d`, `decode3d`, `transcode`, `inspect`, `validate`)**: `encode3d` and 3D `transcode` emit strictly normative ITU-T T.809 Part 10 JP3D (including normative ITU-T T.801 Part 2 `Pcap^2 = 0x4000_0000` + `CBD`/`MCT`/`MCC`/`MCO` `19 + (B - 19)` reversible component bit-split when `34...38`-bit wavelet coefficients reach `|coeff| >= 2^37`, and reconciled Part 10 + Part 15 HT-in-JP3D with normative T.814 Table A.2 `Ccap^15`, `MIXED` `0xC0` for `> 26`-bit, and multi-layer `MULTIHT` `SigProp`/`MagRef` refinement passes) detected via `0xFF54` `NSI`; `inspect` and `validate` report Part 10 3D codestream dimensions, `Zsiz`, `CAP`, and HT signalling accurately; verified directly against unmodified OpenJPEG `v2.4.0` `opj_jp3d_compress` and diagnostic `opj_jp3d_decompress` (`Evidence/R3/f01-openjp3d-interop.txt`).
  - **CLI `F04` (`jpip server` & `jpip client`)**: `jpip server` binds real TCP HTTP/1.1 + RFC 6455 WebSocket listeners (`--host`, `--port`, `--max-requests`, `--once`, `--3d`, printing `boundPort` for `--port 0` process discovery), and `jpip client` exchanges real Annex A `image/jpp-stream` and `image/jpt-stream` data-bins over `http://` and `ws://` (`--stream-type jpp|jpt`, `--len` with Clause C.6.1 EOR exclusion, `--stateless`, `--3d`, `--box` mapped onto normative `fvsiz`/`rvoff`/`rvsiz`, `--slice-range`, `--region`, `--resolution-level`, `--quality-layers`, `--components`, `--raw-stream-out`); verified directly against Kakadu `kdu_server v8.4.1`, `/usr/bin/curl --http1.1`, unmodified OpenJPEG `v2.4.0` `opj_jpip_transcode`, and process-separated 2D/3D HTTP & WebSocket endpoints (`Evidence/R3/f04-*.txt`).
  - **Executed Local Test Declarations at Phase R3 Rework (`submitted`)**:
    - `SwiftJ2KTests`: `159` Swift Testing `@Test` declarations (`159/159` passing locally; `5` external-decoder oracle declarations remain skipped/unexecuted on hosted CI runners without installed `opj`/`ojph`/`kdu` binaries).
    - `SwiftJ2K3DTests`: `525` declarations (`490` XCTest methods + `35` Swift Testing `@Test` declarations, including `12` in `R3VolumeRemediationTests.swift`), `525/525` passing locally (`Evidence/R3/swift-test-3d.txt`).
    - `SwiftJ2KJPIPTests`: `582` declarations (`544` XCTest methods + `38` Swift Testing `@Test` declarations, including `15` in `R3JPIPRemediationTests.swift` and `4` in `CodexR3IndependentTests.swift`), `582/582` passing locally (`Evidence/R3/swift-test-jpip.txt`).
    - **Total package unit test declarations**: `1,266` (`1,034` XCTest + `232` Swift Testing `@Test`), **`1,266 / 1,266` passing locally** (`Evidence/R3/swift-test-full.txt`); `Scripts/test-cli.py`: **`246 / 246` process checks passing locally** (`Evidence/R3/test-cli.txt`); `Examples/Consumer` and `Examples/MigrationExample`: passing.
- **Remaining Open Milestone 12 Gaps (Phase R3 Audit & Phase R4 Qualification)**:
  - Independent Codex R3 re-audit and exact-head hosted Linux/macOS CI verification of `antigravity/r3-standards-remediation`, followed by Phase R4 end-to-end qualification (preserving explicit `UNEXECUTED` / `UNWAIVED` status for hosted-CI external-oracle declarations and missing direct external peers for combined `NSI`+`Ccap^15`, 3D JPIP over `NSI`, and JPIP-over-WebSocket).

