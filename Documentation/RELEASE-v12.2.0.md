# SwiftJ2K `v12.2.0` (`12.2.0`) — Release Gate Record

Executed on **11 November 2026** following [RELEASE.md](RELEASE.md), [STATUS.md](Engineering/Remediation/STATUS.md), and the owner's release directive (`VERSION` = `12.2.0`, shared contract = `0.11.0`, `MIT` licence, Apple OS deployment floor = `26.0`, Swift `6.2` tools minimum / Swift `6.4` qualified in Swift `6` language mode).

*(Note: Historical [RELEASE-v12.1.0.md](RELEASE-v12.1.0.md) preserves the 6 November 2026 `v12.1.0` 2D stable release gate record, and [RELEASE-12.1.0.md](RELEASE-12.1.0.md) preserves the 22 September 2026 Milestone 5 pre-migration preparation record byte-for-byte.)*

---

## 1. Release Scope (`12.2.0`)

1. **Clean-room ITU-T Rec. T.814 HTJ2K block coder & suite-wide MIT relicensing (`POL-07`, contract `0.11.0`):** `SwiftJ2K v12.2.0` replaces all OpenJPH-adapted `BSD-2-Clause` HTJ2K block-coding code (`HTTables.swift`, `HTBlockCoder.swift`, and `SIMDAcceleration.swift`) with a 100% clean-room, first-principles Swift implementation of ITU-T Rec. T.814 (06/2019) | ISO/IEC 15444-15:2019 ([PR #35](https://github.com/raster-labs/SwiftJ2K/pull/35)) and transitions the repository and all in-house source, synthetic fixtures, and documentation to the **MIT License** (`Copyright (c) 2026 Raster Images Private Limited`, [PR #36](https://github.com/raster-labs/SwiftJ2K/pull/36)).
2. **Full `SwiftJ2K`, `SwiftJ2K3D`, `SwiftJ2KJPIP`, and `swiftj2k-cli 12.2.0` qualification:** Phases R3 ([PR #37](https://github.com/raster-labs/SwiftJ2K/pull/37)) and R4 ([PR #38](https://github.com/raster-labs/SwiftJ2K/pull/38)) lift the 3 November 2026 runtime validation hold on **`SwiftJ2K3D`** (ISO/IEC 15444-10 JP3D volumetric codec) and **`SwiftJ2KJPIP`** (ITU-T T.808 / ISO/IEC 15444-9 JPIP interactive progressive streaming) (`0` held declarations in [R3_HELD_VALIDATION_LEDGER.json](Engineering/Remediation/R3_HELD_VALIDATION_LEDGER.json), `schemaVersion: 2`), qualifying all three library products (`SwiftJ2K`, `SwiftJ2K3D`, `SwiftJ2KJPIP`) and the full `swiftj2k-cli 12.2.0` surface (`encode`, `decode`, `transcode`, `inspect`, `validate`, `convert`, `compare`, `batch`, `encode3d`, `decode3d`, `jpip client`/`server`, `benchmark`, `capabilities`, `completions`).
3. **Explicit owner-held & unexecuted boundaries:** The five direct third-party external interoperability checks (`EXT-INTEROP-01`..`05` in [R3_CAPABILITY_MATRIX.md](Engineering/Remediation/R3_CAPABILITY_MATRIX.md)) remain `ON_HOLD_BY_OWNER / DEFERRED / UNEXECUTED`, and Linux container CI remains `OUT_OF_CURRENT_SCOPE_BY_OWNER`.

---

## 2. Verified Release Preconditions (`RELEASE.md`)

| Precondition | Verification | Outcome |
| --- | --- | --- |
| **1. Hosted continuous integration executes with non-zero steps** | `gh run list --repo raster-labs/SwiftJ2K` (run `42802476208` on merged R3 `main` `5e8f434`, run `42803268843` on R4 PR #38 `7402aa0`, plus exact-head CI on `release/12.2.0` / `main`) | **PASSED** (`4/4` jobs green: `macOS 26 / Xcode 26.6`, `iOS Simulator 26 / Xcode 26.6`, `Independent consumer`, `Shared contract`) |
| **2. Private vulnerability reporting enabled** | `gh api repos/raster-labs/SwiftJ2K/private-vulnerability-reporting` checked 11 November 2026 | **PASSED** (`{"enabled": true}`) |
| **3. Explicit owner release assignment** | Owner release directive on 11 November 2026 authorising `v12.2.0` release & tag and preserving `release/12.2.0` in GitHub | **PASSED** |

---

## 3. Executed Gates for `12.2.0` ([Evidence/R3/v12.2.0-r3-completion/](Engineering/Remediation/Evidence/R3/v12.2.0-r3-completion/) & [Evidence/R4/](Engineering/Remediation/Evidence/R4/))

| Gate | Command / Run | Result |
| --- | --- | --- |
| **Shared contract SHA-256 manifest** | `(cd Documentation && shasum -a 256 -c COMMON_CONTRACT_SHA256.txt)` | **PASSED** (`7/7` shared contract files `OK`, contract `0.11.0`) |
| **Hosted macOS 26 ordinary + ASan + TSan (`1,385` declarations)** | Hosted GitHub Actions (`macOS 26 / Xcode 26.6`, Swift `6.3.3`, runs `42796953595`, `42802476208`, `42803268843`, and `release/12.2.0` CI) | **PASSED** (`1,385` macOS declarations across `[660, 725]` sanitizer partitions: `1,380` passed + `5` external-oracle skips on runner without third-party binaries; `0` held declarations; `0` sanitizer findings) |
| **Hosted iOS Simulator 26 (`1,375` declarations)** | Hosted GitHub Actions (`iOS Simulator 26 / Xcode 26.6`, runs `42796953595`, `42802476208`, `42803268843`, and `release/12.2.0` CI) | **PASSED** (`1,375` selected iOS Simulator declarations: `1,370` passed + `5` external-oracle skips, `0` failed, `0` held) |
| **Local macOS Debug, Release, ASan, & TSan + external-oracle suites** | `swift test --build-system native -c debug` / `-c release` / `--sanitize=address` / `--sanitize=thread` (with `opj_decompress 2.5.4`, `ojph_expand 0.30.1`, `kdu_expand 8.4.1`) | **PASSED** (`1,380/1,380` pre-rebase declarations + `5/5` `CleanRoomT814Tests` declarations = `1,385/1,385` passed including all **5** external-oracle declarations with `0` skips and `0` failures; [Evidence/R3/](Engineering/Remediation/Evidence/R3/v12.2.0-r3-completion/), [Evidence/R4/validation/](Engineering/Remediation/Evidence/R4/validation/)) |
| **External-peer & multi-process loopback interop (`22/22`)** | `OpenJP3D 2.4.0`, `Kakadu kdu_server v8.4.1`, `OpenJPIP 2.4.0`, and separate-process `swiftj2k-cli jpip` 2D/3D HTTP & WebSocket | **PASSED** (`22/22` bit-exact checks passed; `peers/f01-f04-external-peers-v12.2.0.json` `e231c2a4...`) |
| **CLI conformance & staged UNIX manual installation** | `python3 Scripts/test-cli.py --binary <release/swiftj2k-cli>` and `./Scripts/install-cli.sh --binary <release/swiftj2k-cli> --prefix /usr/local --destdir <stage>` | **PASSED** (`246/246` black-box CLI process checks passed across 2D, 3D, and JPIP; staged `swiftj2k-cli --version` reported `swiftj2k-cli 12.2.0`; `cli/cli-summary.json` `db21a403...`, `validation/cli-staged-install.json` `736c10be...`) |
| **Independent consumers, migration example, & 6 SBOMs** | `./Scripts/validate.sh --checks consumer,sbom`, `Examples/Consumer`, `Examples/MigrationExample`, and 3-product `FreshAllProductsConsumer` (`SwiftJ2K` + `SwiftJ2K3D` + `SwiftJ2KJPIP`) | **PASSED** (`status: "passed_requested_checks"`; `0` pixel allocations and `0` copy events in `MigrationExample`; all **6** SPDX 3.0.1 & CycloneDX 1.7 SBOMs emitted across `SwiftJ2K`, `SwiftJ2K3D`, and `SwiftJ2KJPIP`; `validation/consumer-migration-sbom-summary.json` `aba8b146...`) |
| **Controlled release benchmarks (`M6-AUD-007`, `PERF-02`, `PERF-03`)** | 5-warmup + 20-iteration unloaded release benchmarks on Apple M4 (`arm64`) across 5 revisions (`fabe127`, `5941aa8`, `1ef8a25`, `v12.1.0`, `12.2.0`), 2D lossless/transcode, 3D `32×32×16` JP3D, and separate-process JPIP | **PASSED** (100% byte-identical codestreams across all 5 revisions; `pixelAllocations == 0`; `12.2.0` vs `v12.1.0` median `api_ms` within `[-3.78%, +1.64%]`; `0.99–11.24 ms` coefficient transcode beating shared-sample decode+encode on all 8 cases; `benchmarks/m6-aud-007-contemporaneous-ab.json` `c20c99cd...`, `perf02-2d-lossless-and-transcode.json` `744b2767...`, `perf03-2d-3d-jpip-release.json` `8ccca59b...`) |
| **Extended 2D/3D/JPIP release fuzz qualification (`TEST-05`)** | `Integration/FuzzHarness` (`9 × 120s` = `1,080` CPU-seconds, seed `20261107`) across `decode`, `decodeInto`, `transcodeToHT`, `transcodeToJ2K`, `decode3d`, `transcode3d`, `jpipStream`, `jpipRequest`, `jpipWebSocketFrame` | **PASSED** (`5,025,480` total iterations, `0` unexpected errors, `0` slow inputs `> 2,000 ms`, max `189.716 ms`, peak RSS `<= 783 MiB`; `fuzz/fuzz-campaign-manifest.json` `07a78151...`) |

---

## 4. Unexecuted and Deferred Gates (Disclosed Explicitly per `RELEASE.md`)

Per [RELEASE.md](RELEASE.md) (*"Anything unexecuted is recorded as unexecuted in the release notes, never as passed"*), the following items remain **unexecuted or deferred by the owner** on `v12.2.0`:

1. **Five direct third-party external interoperability gates (`EXT-INTEROP-01`..`05`: `Combined Part 10+15`, `Native 3D JPIP`, `Exact WebSocket extension`, `Full 38-bit Part 2 synthesis`, `Multiple non-empty HT sets`)**: **`ON_HOLD_BY_OWNER / DEFERRED / UNEXECUTED`** per explicit owner scope decision ([R3_CAPABILITY_MATRIX.md](Engineering/Remediation/R3_CAPABILITY_MATRIX.md)).
2. **Tag-time `3,600s`-per-entry release fuzz campaigns**: **Unexecuted at `3,600s`/entry** (`9 × 120s` = `1,080` CPU-seconds / `5,025,480` iterations executed in Phase R4; historical 1-hour 2D campaigns recorded in [MILESTONE5.md](MILESTONE5.md)).
3. **Linux container builds and tests (`ubuntu-24.04` arm64/x86_64)**: **`OUT_OF_CURRENT_SCOPE_BY_OWNER`** under the 2 November 2026 Apple-only CI scope directive.
4. **Uninstalled Apple SDKs and physical devices (`tvOS`, `tvOS Simulator`, `watchOS`, `watchOS Simulator`, `visionOS`, `visionOS Simulator`, macOS `x86_64` Rosetta, physical iPhone/iPad)**: **Unexecuted** (SDKs/devices not installed on the release host).
5. **SwiftPM SBOM JSON schema validation**: **Skipped by toolchain** (all 6 SPDX 3.0.1 and CycloneDX 1.7 SBOMs emitted and hashed; installed toolchain omits the local schema bundle).
6. **Cross-suite `Integration/ContractHarness`**: **Unexecuted in standalone repository checkout** (sibling `../SwiftJLS`, `../SwiftJXL`, `../SwiftJLI` checkouts absent; baseline `6/6` execution recorded in [MILESTONE3.md](MILESTONE3.md) and [MILESTONE5.md](MILESTONE5.md)).
