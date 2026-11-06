# SwiftJ2K `v12.1.0` (`12.1.0`) — Release Gate Record

Executed on **6 November 2026** following [RELEASE.md](RELEASE.md), [MILESTONE13.md](MILESTONE13.md), and the owner's 6 November 2026 release directive (`VERSION` = `12.1.0`, shared contract = `0.10.0`, Apple OS deployment floor = `26.0`, Swift `6.2` tools minimum / Swift `6.4` qualified in Swift `6` language mode).

*(Note: Historical [RELEASE-12.1.0.md](RELEASE-12.1.0.md) preserves the 22 September 2026 Milestone 5 pre-migration preparation record byte-for-byte.)*

---

## 1. Owner Scope Directive (`12.1.0` vs `12.2.0`)

Per the repository owner's explicit 6 November 2026 instruction:
1. **`SwiftJ2K v12.1.0` (`12.1.0`)** ships the qualified **2D `SwiftJ2K` library** and **2D `swiftj2k-cli` surface** as the first stable release, enabling downstream `DICOMKit` (`Integrations/DICOMSwiftJ2KIntegration`) to consume `SwiftJ2K` via SemVer (`from: "12.1.0"`) across all 2D DICOM JPEG 2000 and HTJ2K transfer syntaxes (`.90`, `.91`, `.92`, `.93`, `.201`, `.202`, and `.203`).
2. **`SwiftJ2K3D` (ISO/IEC 15444-10 JP3D volumetric codec) and `SwiftJ2KJPIP` (ISO/IEC 15444-9 JPIP interactive streaming)** — together with CLI `encode3d`, `decode3d`, and `jpip`, the `1,213` held declarations in [R3_HELD_VALIDATION_LEDGER.json](Engineering/Remediation/R3_HELD_VALIDATION_LEDGER.json), and the five held direct-interoperability checks — remain **experimental preview surfaces in `12.1.0`**, with full volumetric and streaming qualification and enhancement work scheduled for the **next feature version (`12.2.0`)**.
3. Downstream applications requiring JP3D or JPIP (or targeting pre-OS 26 platforms) continue to retain `J2KSwift 11.0.3` alongside `SwiftJ2K 12.1.0` until `12.2.0`.

---

## 2. Verified Release Preconditions (`RELEASE.md`)

| Precondition | Verification | Outcome |
| --- | --- | --- |
| **1. Hosted continuous integration executes with non-zero steps** | `gh run list --repo raster-labs/SwiftJ2K --branch main` (run `42167469950` on merged Phase A `main` `e3666b3fae5fa6984e6061ac0260d3d5d1fc9297`, plus exact-head CI on the `Release 12.1.0` PR and post-merge `main` commit before tagging) | **PASSED** (`4/4` jobs green: `macOS 26 / Xcode 26.6`, `iOS Simulator 26 / Xcode 26.6`, `Independent consumer`, `Shared contract`) |
| **2. Private vulnerability reporting enabled** | `gh api repos/raster-labs/SwiftJ2K/private-vulnerability-reporting` checked 6 November 2026 | **PASSED** (`{"enabled": true}`) |
| **3. Explicit owner release assignment** | Owner release directive on 6 November 2026 authorising `v12.1.0` release & tag with `SwiftJ2K3D`/`SwiftJ2KJPIP` scheduled for `12.2.0` | **PASSED** |

---

## 3. Executed Gates on the `12.1.0` Production Source Tree (`e3666b3fae5fa6984e6061ac0260d3d5d1fc9297`)

`codex/release-12.1.0` changes documentation and [ManPages/swiftj2k-cli.1](../ManPages/swiftj2k-cli.1) only (`0` bytes changed across `Package.swift` `79875182d97d66feb288350ba8b0d42226e107270b16cff8bc4f53a1028439dc`, `VERSION` `12.1.0`, `Sources/**`, `Tests/**`, and `Scripts/**` relative to `e3666b3fae5fa6984e6061ac0260d3d5d1fc9297`). Local gates were executed serially (at most one native build/test process active at a time) on `arm64-apple-macosx` with `Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)` (`Xcode 27.0 Build 27A266a`), OpenJPEG `2.5.4`, OpenJPH `0.30.1`, and Kakadu `8.4.1`:

| Gate | Command / Run | Result |
| --- | --- | --- |
| **Shared contract SHA-256 manifest** | `(cd Documentation && shasum -a 256 -c COMMON_CONTRACT_SHA256.txt)` | **PASSED** (`7/7` shared contract files `OK`, contract `0.10.0`) |
| **Hosted macOS 26 ordinary + ASan + TSan** | Hosted GitHub Actions (`macOS 26 / Xcode 26.6`, Swift `6.3.3`, run `42167469950` + `Release 12.1.0` PR/merge runs) | **PASSED** (`166/166` selected core 2D declarations compiled & reconciled across ordinary, AddressSanitizer, and ThreadSanitizer; `0` sanitizer findings; `0` held declarations executed) |
| **Hosted iOS Simulator 26** | Hosted GitHub Actions (`iOS Simulator 26 / Xcode 26.6`, run `42167469950` + `Release 12.1.0` PR/merge runs) | **PASSED** (`159` selected iOS Simulator declarations: `154` passed + `5` external-oracle skips on runner without third-party binaries, `0` failed) |
| **Release-mode core 2D unit + external-oracle suite** | `xcrun swift test --build-system native -c release --filter '^SwiftJ2KTests\.' --skip '<held-3D-JPIP-CLI-regex>'` (with `opj_decompress`, `ojph_expand`, `kdu_expand` on `PATH`) | **PASSED** (`166/166` declarations in `14` suites passed in Release mode in `1.369s`, including all **5** external-oracle declarations with `0` skips and `0` failures) |
| **Swift Build fresh local consumer & SBOM generation** | `./Scripts/validate.sh --checks consumer,sbom --output <scratch>` | **PASSED** (`status: "passed_requested_checks"`; fresh tools-`6.2` local consumer `exit = 0`; build-associated SPDX 3.0.1 SBOM `6dd61367e52c6358b209ccce0f4f917ea345b74a01ad6099e4a5b1a13c26f414` and CycloneDX 1.7 SBOM `85f16a11c7360feec46a7305e6a6bda9160c450c1af7a0c34818de9b53197785` emitted) |
| **CLI conformance & staged UNIX manual installation** | `python3 Scripts/test-cli.py --binary <release/swiftj2k-cli> --output <scratch>` and `./Scripts/install-cli.sh --binary <release/swiftj2k-cli> --prefix /usr/local --destdir <stage>` | **PASSED** (`246/246` black-box CLI process checks passed; release binary SHA-256 `9d367b1e8b4801158aa064f86f65446f8b2e68841087da5f5e1e190ae6564898`; manual SHA-256 `0c080190894f41d678d764ceea64cd718dd3f54708876f4bc21aa58666913610`; staged `swiftj2k-cli --version` reported `swiftj2k-cli 12.1.0`) |
| **Executable migration example** | `xcrun swift run --package-path Examples/MigrationExample MigrationExample` | **PASSED** (`115-byte lossless codestream; decode into caller storage with 0 pixel allocations and 0 copy events`) |
| **Apple SDK build matrix (installed SDKs)** | `xcrun xcodebuild -scheme SwiftJ2K -destination 'generic/platform=<macOS|iOS|iOS Simulator>' build` | **PASSED** (`macOS`, `iOS`, and `iOS Simulator` generic builds all succeeded with `exit = 0`) |
| **Downstream `DICOMKit` OS 26 integration** | `raster-labs/DICOMKit` Phase B PR #237 merged at `1178e96de522acbb0d59b3c840a0b83ec2372c14` + SemVer `from: "12.1.0"` integration | **PASSED** (`13/13` ordinary + ThreadSanitizer integration tests `0` races; `23/23` root `DICOMKit` regression tests; `55/55` `pydicom 2.4.4` + Kakadu/OpenJPEG/OpenJPH cross-codec checks across `.90`, `.91`, `.92`, `.93`, `.201`, `.202`, `.203`; `15/15` hosted PR checks + `8/8` `main` workflows) |
| **No-DICOM / no-patient-data Git tree & archive guard** | Full Git-tree and recursive archive scan (`check_no_dicom.py` + `scan-m12-git-tree.py HEAD`) | **PASSED** (`0` prohibited files or archive members) |

---

## 4. Unexecuted and Deferred Gates (Disclosed Explicitly per `RELEASE.md`)

Per [RELEASE.md](RELEASE.md) (*"Anything unexecuted is recorded as unexecuted in the release notes, never as passed"*), the following items were **not executed on the `v12.1.0` tag commit** or are **explicitly deferred by the owner**:

1. **`SwiftJ2K3D` (JP3D) and `SwiftJ2KJPIP` (JPIP) full test/sanitizer qualification (`1,213` declarations in `R3_HELD_VALIDATION_LEDGER.json`) and 5 direct-interoperability checks (`Combined Part 10+15`, `Native 3D JPIP`, `Exact WebSocket extension`, `Full 38-bit Part 2 synthesis`, `Multiple non-empty HT sets`)**: **Deferred to `12.2.0`** per the owner's 3 November and 6 November 2026 directives (`SwiftJ2K3D` and `SwiftJ2KJPIP` are experimental preview surfaces in `12.1.0`).
2. **Linux container builds and tests (`ubuntu-24.04` arm64/x86_64)**: **Unexecuted on `v12.1.0`** (`OUT_OF_CURRENT_SCOPE_BY_OWNER` under the 2 November 2026 Apple-only CI scope directive; baseline Ubuntu 24.04 arm64 execution was recorded earlier in [MILESTONE4.md](MILESTONE4.md)).
3. **Uninstalled Apple SDKs and physical devices (`tvOS`, `tvOS Simulator`, `watchOS`, `watchOS Simulator`, `visionOS`, `visionOS Simulator`, macOS `x86_64` Rosetta, physical iPhone/iPad)**: **Unexecuted** (SDKs/devices not installed on this release host).
4. **SwiftPM SBOM JSON schema validation**: **Skipped by toolchain** (both SPDX 3.0.1 and CycloneDX 1.7 SBOMs were emitted and build-associated, while the installed SwiftPM toolchain omits the local schema bundle).
5. **Cross-suite `Integration/ContractHarness`**: **Unexecuted in isolated release worktree** (`Integration/ContractHarness/Package.swift` references sibling `../../../SwiftJLS`, `SwiftJXL`, and `SwiftJLI` checkouts not mounted beside the isolated worktree; baseline `6/6` execution recorded in [MILESTONE3.md](MILESTONE3.md) and [MILESTONE5.md](MILESTONE5.md)).
6. **Paused Phase R4 items (`M6-AUD-007`, historical binary provenance verification, controlled `PERF-03` unloaded-host release benchmark, and release-commit 1-hour `Integration/FuzzHarness` re-run)**: **Paused / unexecuted on `v12.1.0`** (`human-pause-20261104.json`; baseline 1-hour fuzz campaigns and benchmarks are preserved in [MILESTONE5.md](MILESTONE5.md), [MILESTONE6.md](MILESTONE6.md), and [MILESTONE9.md](MILESTONE9.md)).
