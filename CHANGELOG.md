# Change log

## Unreleased — Milestone 6: HTJ2K and native J2K ↔ HTJ2K transcoding, 2026-10-26

- **HTJ2K (ISO/IEC 15444-15) lossless codec (`htj2k-codestream`).** Adapted the predecessor's OpenJPH-derived conformant Part 15 cleanup-pass block coder (`HTTables.swift`, `HTBlockCoder.swift`) under `Apache-2.0 AND BSD-2-Clause` per the owner's 26 October 2026 decision, with OpenJPH BSD-2-Clause notices retained in source and `THIRD_PARTY_NOTICES.md`. Added `CAP` (`0xFF50`) and `CPF` (`0xFF59`) marker parsing, validation and emission, `COD`/`COC` code-block style bits `0x40` (HT) and `0x80` (HT mixed), Clause B.10.6 mixed-mode per-block `isHT` detection, placeholder-pass accounting before the HT cleanup pass, and reversible 5/3 $K_{\max}$ gain handling (`htj2k_lossless_fail_min` reproducer verified). HT `SigProp`/`MagRef` refinement passes and multiple HT sets per code-block are rejected deterministically with `CodecError(.unsupportedFeature, ...)`.
- **Predecessor and fuzzing defects fixed.** Fixed `Lcup <= 4096` false rejection (raised to standard `Lcup <= 65535`, `Scup <= 4079`), `fuseMELAndVLC` bit-7 corruption on boundary-byte fusion after a `> 0x8F` VLC byte, `HTMELDecoder.read()` bit-7 unstuffing across 32-bit word boundaries, and 32-bit integer overflow in `HTBlockDecoder.decodeCleanup` / `Wavelet53.synthesise` on corrupted bitstreams.
- **Native compressed-to-compressed `J2K ↔ HTJ2K` transcoding.** `Transcoder` and `ScalarLosslessCodec.transcode` convert `jpeg2000-codestream` ↔ `htj2k-codestream` in both directions directly in the wavelet subband coefficient domain (`pixelAllocations == 0`, `copyEvents == 0`), supporting `--code-block` re-blocking and preserving multi-tile grids, image/tile origins, per-tile `COD`/`QCD` decomposition level overrides, and `COM` marker payloads. Requests that would require wavelet reconstruction (`decompositionLevels` changes) are rejected with `CodecError(.unsupportedFeature, ...)`.
- **CLI and validation.** `swiftj2k-cli` supports `--format htj2k` across `encode`, `decode`, `inspect`, `validate` and `transcode` (`j2k ↔ htj2k`). Added 120 OpenJPH 0.30.1 / Kakadu 8.4.1 HTJ2K fixtures and 15 new Swift Testing declarations (`93/93` passing in Debug, Release, ASan and TSan; `174/174` CLI checks passing; bounded fuzzing of HT decode and both transcode directions; controlled release benchmarks). Evidence in [Documentation/MILESTONE6.md](Documentation/MILESTONE6.md).

## 12.1.0 — target of the first stable; preparation executed 2026-09-22/23, release deferred by the owner on 2026-09-25 until the J2KSwift migration is complete (unreleased)

First stable line of SwiftJ2K, the successor to J2KSwift for the scalar lossless JPEG 2000 path. Contract 0.10.0. This entry consolidates the `12.1.0-dev.1` to `dev.6` development identifiers below; nothing in the library changed between `12.1.0-dev.6` and this version except the version string itself.

- **Capabilities.** Decoding of JPEG 2000 Part 1 codestreams with a single unsigned greyscale component of 1 to 16 bits and the 5/3 reversible transform: any tile grid and origin, quality layers, all code-block styles, all progression orders, precincts, SOP/EPH and tile-parts. Encoding of the same image class as a single-tile, single-layer, default-style codestream. Decode into caller-owned storage with zero pixel allocations and no copies, reported per operation. Resource limits, cancellation and error categories per the shared contract. The `swiftj2k-cli` CLI (`encode`, `decode`, `inspect`, `validate`, `capabilities`) over the NRRD interchange profile; `transcode` reserved. Not implemented and not claimed: HTJ2K, lossy coding, colour and signed components, containers, acceleration, native transcoding, JPIP, JP3D, multi-tile, multi-layer or non-default-style encoding.
- **Platforms.** Swift 6.2 minimum, Swift 6.4 qualified; macOS 26 and iOS 26 built and tested (iOS on the simulator); Linux arm64 (Ubuntu 24.04, Swift 6.2) built and tested in a container; macOS x86_64 under Rosetta built and CLI-tested. tvOS, watchOS, visionOS, Linux x86_64 and physical devices are unexecuted.
- **Release gates** executed on the preparation commit are listed in [Documentation/RELEASE-12.1.0.md](Documentation/RELEASE-12.1.0.md) with their evidence. No tag: the owner deferred the release until the migration programme in [IMPLEMENTATION.md](IMPLEMENTATION.md) (Milestones 6 to 13: HTJ2K, Part 1 breadth, containers, acceleration, `SwiftJ2K3D`, `SwiftJ2KJPIP`, CLI breadth, release preparation) is complete; the version string stays 12.1.0 as that target.
- **Executable renamed to `swiftj2k-cli`** (contract 0.10.0, CLI-01): product name, tool name reported by `--version`, help and JSON, `ManPages/swiftj2k-cli.1`, the installer and the CLI documentation. The library module stays `SwiftJ2K`. The rule exists because an executable that differs from a module name by case alone collides with it in Swift Build's per-product directories on case-insensitive filesystems, the defect Milestone 5 recorded for the `SwiftJ2K-Package` scheme. Nothing was ever released under the old name. The NRRD header key `swiftj2k.meaningfulbits` is unchanged: it names the library's interchange profile, not the executable.
- Supersedes the withdrawn unreleased 12.0.0 target and the Apple OS 27 floor (Decision D3, floors 26.0).

## 12.1.0-dev.6 — Milestone 5 release preparation, 2026-09-22 (unreleased)

- Release preparation without a tag. Fresh URL-based consumption of the repository at a pinned revision verified on macOS and Linux (one package in the dependency graph); `Examples/MigrationExample` added as the executable program reproduced in the rewritten MIGRATION.md; `THIRD_PARTY_NOTICES.md` records relicensed predecessor code, synthetic fixtures and every development oracle; SECURITY.md records the repository's actual security settings and a supported-version policy; `Documentation/RELEASE.md` is the procedure the explicit release task follows.
- Gates executed on the Swift 6.4 toolchain that Swift 6.2.3 could not run on this host: Swift Build engine debug/release builds and tests, AddressSanitizer, ThreadSanitizer and build-associated SPDX/CycloneDX SBOMs (schema validation still open). One-hour mutation fuzz campaigns per decode entry point (`Integration/FuzzHarness`, new), an Apple SDK build matrix (iOS, iOS Simulator, macOS; tvOS/watchOS/visionOS components not installed) and an iOS simulator test run. Evidence in [MILESTONE5.md](Documentation/MILESTONE5.md).
- `Scripts/validate-swift64.py` generates its fresh consumer at tools 6.2 and macOS 26.0 with a real round trip; SPDX headers added to three active files. No library or CLI behaviour change; capabilities unchanged. Contract 0.9.0's continuous-integration precondition remains unmet.

## 12.1.0-dev.5 — Milestone 4 feature, CLI and platform coverage, 2026-09-22 (unreleased)

- Decoder coverage of the remaining Part 1 greyscale syntax: any tile grid and image or tile origin (general-origin 5/3 lifting and band geometry on the reference grid), quality layers, all six code-block style bits (bypass with raw passes, reset, termination on each pass, vertically causal, predictable termination, segmentation symbols), codeword segments, all five progression orders, precincts, SOP/EPH, several tile-parts and tile-part header COD/COC/QCD/QCC overrides. 44 new OpenJPEG and Kakadu fixtures cover these, each cross-decoded by both tools.
- CLI: `encode`, `decode`, `inspect` and `validate` are wired to the library over the CLI-04 NRRD interchange profile with `-` for pipes, atomic output with `--overwrite`, format checks against the bytes, JSON reports, every contract exit status and cooperative SIGINT cancellation (130). `transcode` stays reserved. `Scripts/test-cli.py` now runs 147 process checks including the codec verbs.
- Every tile is decoded inside the destination's single write borrow, so a decode cancelled after admission has begun its write borrow before it invalidates the destination (Milestone 3 record updated).
- Platform: Linux (Ubuntu 24.04, Swift 6.2) build and test in a container and macOS x86_64 under Rosetta are recorded in MILESTONE4.md where they executed. Two Darwin-only assumptions were removed on the way: `OwnedImageStorage` no longer relies on `Mutex.withLockIfAvailable` returning `nil` on same-thread reentry (Linux traps instead), and the CLI publishes output files with POSIX `rename(2)` because swift-corelibs-foundation's `replaceItemAt` fails on Linux.
- Tests: the concurrent-borrow ownership test starts its second writer on a dedicated thread instead of the global dispatch queue, which the full parallel suite could starve past the test's five-second wait; 78 Swift Testing declarations.
- Not in this milestone: HTJ2K, 9/7 and quantised coding, colour and signed components, sub-sampling, JP2 containers, multi-tile or multi-layer *encoding*, acceleration and native transcoding.

## 12.1.0-dev.4 — Milestone 3 shared-storage proof, 2026-09-22 (unreleased)

- Prove the required-sharing path of the scalar lossless codec: decode writes final samples only into the caller's allocation, encode reads the sealed caller allocation once, and both report zero pixel allocations and no copy events. Task-local allocation telemetry (`StorageTelemetry`) counts every pixel and workspace allocation the module makes so the reports are checked against instrumentation, not address equality.
- Add TEST-09 evidence: sentinel-filled caller providers with prefix and row padding, different strides on each side of a round trip, both copy policies, concurrent readers with a refused writer, cancellation during decode and during encode, and mutation testing through a task-local `SharedPathMutation` hook (ignoring the row stride fails 3 of 3 checks, the wrong byte order 2 of 3).
- Extend the development-only contract harness with a real codestream: OpenJPEG and Kakadu fixtures decoded into a harness-owned sentinel allocation, viewed through the SwiftJLS adapter, re-encoded from the same owner and decoded by both reference tools; process allocator statistics and open-descriptor counts are recorded. The JPEG-LS leg of TEST-02 is attempted and recorded as unexecuted because SwiftJLS has no encoder yet.
- 77 Swift Testing declarations; evidence in [MILESTONE3.md](Documentation/MILESTONE3.md). No public API change; no codec capability change.

## 12.1.0-dev.3 — Milestone 2 migration baseline, 2026-09-22 (unreleased)

- Implement the scalar lossless JPEG 2000 Part 1 path for the shared profile: unsigned greyscale 1–16 bit, one tile at the origin, reversible 5/3 wavelet, no quantisation, default code-block style, one quality layer, raw codestream. `Encoder.encode`, `Decoder.inspect`, `Decoder.decode` and `Decoder.decode(_:into:)` now operate; capabilities advertise exactly this coverage.
- Migrate the MQ coder, EBCOT context formation, bit-plane coder, tag tree and 5/3 lifting kernels from J2KSwift `7acc9ae4` with provenance headers, Apache-2.0 SPDX identifiers and the unsafe-pointer, rate-control, bypass and tracing paths removed. Codestream syntax, tier-2 packet coding, tile geometry and the pipeline are new implementations fitted to the Milestone 1 image types. See [HISTORY.md](HISTORY.md) for the file-level record.
- Add `CodecOptions.decompositionLevels` and `codeBlockWidth`/`codeBlockHeight` with explicit validation; the default level count adapts to the image.
- Add deterministic synthetic fixtures with 51 OpenJPEG and Kakadu codestreams, cross-decoded by both tools, plus unsupported-feature variants; 69 Swift Testing declarations cover exact decode, round trips, oracle decoding of successor output, shared-storage identity and padding, truncation and bit-flip robustness, limits, cancellation and progress. Evidence: [MILESTONE2.md](Documentation/MILESTONE2.md).
- Decoding failures after admission now invalidate the destination; preflight rejections still leave it reusable.
- CLI: capability output, help and manual describe the library coverage; the CLI codec verbs stay reserved (exit 4) until the CLI milestone. The executable's reported Apple minimum returns to 26.0 and the Swift 6.4 wording to "6.2 minimum, 6.4 qualified", matching contract 0.5.0. `Scripts/test-cli.py` and `Scripts/validate-swift64.py` accept the Swift 6.2 toolchain's `swift package -help` form.
- Not in this milestone: HTJ2K, 9/7 irreversible and quantised (lossy) coding, multiple tiles or layers, colour or signed components, sub-sampling, JP2 containers, precinct-major progressions with several precincts, half-LSB reconstruction of truncated code-blocks, acceleration and native transcoding. Contract 0.9.0's continuous-integration precondition remains unmet (see MILESTONE2.md).

## 12.1.0-dev.1 — Swift 6.4 upgrade, 2026-09-19 (unreleased)

- Require Swift tools/compiler 6.4, retaining Swift 6 language mode and OS 26 deployment floors.
- Advance the coordinated common contract to 0.3.0 and the earlier unreleased 12.0.0 version target to 12.1.0.
- Adopt checked native-order span access for UInt16 samples with explicit endian conversion; preserve public API and owning-storage semantics.
- Add the supplied upgrade references, F01–F13 feature register, headless Swift Build validation and exact evidence. No codec capability, stable release or tag is added.

## Unreleased — application migration guide, 2026-09-18

- Added MIGRATION.md for humans and coding agents moving applications from J2KSwift, with verified dependency/API mappings, precision and ownership changes, explicit feature gaps, and staged rollout/rollback guidance.
- Linked the guide from README, agent instructions, contributor guidance, implementation and transcoding plans. Codec availability is unchanged.

## Unreleased — Milestone 1, 2026-09-18

- Final Milestone 1 review: prevent image publication when cancellation occurs inside provider sealing/validation; deterministic regressions and full checks pass.
- Added the independent Swift 6.2 package and common local API, checked descriptors, zero-initialised owning storage and exclusive lease lifecycle.
- Added safe synthetic 12/16-bit sample access, caller resource-budget validation and clearly unsupported codec/native-transcoder entry points.
- Refined the mirrored suite contract to 0.2.1 with concrete lease and preflight semantics.
- Debug/release, independent consumer, AddressSanitizer and ThreadSanitizer checks passed using Xcode 27 headlessly; see Documentation/MILESTONE1.md for exact results and unavailable gates.
- Added a separate four-module adapter experiment. No codec algorithm, CLI, accelerated backend or release tag is included.

## Unreleased — documentation foundation, 2026-09-17

- Defined the standalone SwiftJ2K successor and intended first stable version 12.0.0.
- Added the common API, memory, platform, CLI, testing and performance specifications, codec-specific agent instructions, source provenance and MIT licence.
- No source migration, implementation, package manifest, executable test, binary or release tag is included.
- No runtime behaviour, support matrix or performance result is claimed as verified.

## Documentation clarification — contract 0.1.1, 2026-09-17

- Aligned the suite policy, README and agent handoff with the staged implementation plan: contract feasibility first, codec migration second, shared-storage integration third.
- Added explicit Milestone 1 test evidence and labelled the later codec delivery sections to prevent accidental expansion of the first task.
- Mirrored all seven common documents and regenerated their SHA-256 manifest across the four repositories. API/memory behaviour, platform floors, intended library versions and release gates are unchanged.
- Verified documentation consistency and links; no codec code or executable tests were added or run.

## Native transcoding instructions — contract 0.2.0, 2026-09-18

- Added a common native format-pair API/CLI pattern and explicit in-memory ownership, fidelity and testing requirements for SwiftJ2K and SwiftJXL.
- Distinguished sample-exact J2K ↔ HTJ2K conversion from original-JPEG-byte restoration through JPEG XL. Neither operation requires an umbrella or sibling codec dependency.
- Recorded predecessor implementation/test findings in the relevant repositories; kept Milestone 1 scoped to feasibility. No native transcode placeholder is required in SwiftJLS/SwiftJLI.
- Updated all seven shared documents and their SHA-256 manifest. This is documentation only; no source migration, codec execution or performance claim.

The foundation document version is 0.2.0. It is separate from the intended library version.

## OS 27 and CLI foundation — 19 September 2026

Owner-authorised Apple platform floors now use 27.0. Development version 12.1.0-dev.2, common contract 0.4.0. The standalone `swiftj2k` provides help/version/capabilities, five diagnostic levels and a matching section 1 manual installed/updated with the binary. Codec commands remain unavailable. Endian-aware span overloads use the new floor without changing public ownership semantics. See [qualification and limitations](Documentation/Engineering/OS27CLI/README.md). Historical evidence and supplied documents remain unchanged.
## Apple floor restored to 26.0 — contract 0.5.0, 20 September 2026

- Revert the 0.4.0 Apple deployment raise: macOS, iOS/iPadOS, tvOS, visionOS and watchOS return to **26.0**. Xcode 27 is a public preview with a 27.2 beta, no generally available SDK or stable CI runner exists for OS 27, and Swift 6.4.0 rejects a 27.0 deployment target outright because its supported range ends at 26.5.x. The raise could not be validated on any supported configuration.
- Return `swift-tools-version` to **6.2**, keeping Swift 6.4 as the qualified primary toolchain. A manifest floor constrains consumer resolution, and every current consumer resolves at 6.2.
- Replace the OS-27-gated `RawSpan.load(fromByteOffset:as:_:)` and `OutputRawSpan.append(_:as:_:)` byte-order overloads with explicit fixed-width integer conversion. This restores the rule contract 0.3.0 already specified and was the sole reason the floor moved. Public API, ownership and fidelity semantics are unchanged.
- Relax `Scripts/validate-swift64.py` from one pinned preview-Xcode build to accepting Swift 6.2 or 6.4, recording the exact toolchain as evidence rather than enforcing it as an admission gate.
- Retain the OS 27 records under `Documentation/Engineering/OS27CLI` as superseded history for their platform claims; their CLI content remains current.
- Verified on Swift 6.2.4 and Swift 6.4.0, debug and release. No codec capability, stable release or tag is added.

## Shared-storage contract refined from measurement — contract 0.6.0, 20 September 2026

- Advance the coordinated common contract to **0.6.0**. Seven memory rules are amended and one testing rule is added, each from something an exploratory spike measured or broke across all four predecessor codecs in both directions.
- **MEM-03** requires a multi-plane layout to state the distance between plane origins rather than infer it from height and `rowBytes`; with padded rows the two defensible readings differ by one row's padding per plane and shear the image instead of failing.
- **MEM-05** records that read-only storage is shared rather than leased and admits concurrent readers, an asymmetry with destinations the contract did not previously state.
- **MEM-06** requires caller-storage entry points to take the owner rather than a pointer, which an `async` codec cannot otherwise satisfy under MEM-08.
- **MEM-07** requires a safe owning constructor to exist and to be the documented default; unsafe adoption becomes the named exception.
- **MEM-10** requires algorithm workspace to be bounded by a stated per-codec figure, and records that removing the hand-off copy does not by itself reduce peak memory.
- **MEM-12** requires a codec whose native sample order differs from the shared layout to convert on the shared path rather than relax MEM-03.
- **MEM-13** records that allocator telemetry is invalid under a sanitizer, and that encode-side proofs compare codestreams byte for byte rather than comparing samples.
- **TEST-09** collects the resulting evidence bar, including mutation testing to demonstrate the checks are load-bearing.
- This codec drives three of the seven amendments. Its encode and decode are `async`, so a pointer parameter cannot satisfy MEM-08 and the owner requirement in MEM-06 follows from it. Its decoder emits big-endian 16-bit samples against the shared layout's little-endian, which MEM-12 now requires it to convert on the shared path. Its spatial-domain `[Double]` workspace is four times the final frame, which MEM-10 now requires it to state.
- Updated all seven shared documents and their SHA-256 manifest. Documentation only: no source migration, codec execution, platform change or release. Every figure cited comes from a developer machine and none has been reproduced in continuous integration.

## Decision D1: codec libraries stay where they are — contract 0.7.0, 20 September 2026

- Advance the coordinated common contract to **0.7.0**, recording decision **D1**: the shipping codec libraries are the existing repositories, and codec sources are not relocated. Nothing is deleted and no source moves.
- This repository's role is settled: it holds this codec's copy of the seven shared documents, the reference implementation of the shared image layer, and its share of the cross-codec conformance harness. POL-03 already stated that the contract is a specification rather than a runtime module, so the Milestone 1 types built here become that reference rather than discarded work.
- Rationale, from measurement: the Milestone 3 spikes showed all four codec interiors contract-capable through single-point changes, and the obstacle to `requireSharedStorage` is the public image type. That layer is additive work of the same size in either repository, so migration buys nothing it does not also buy, while additionally relocating about 219,000 lines of codec source and 184,000 lines of tests with no CI to catch what breaks.
- Rationale, from arithmetic: the contract repositories hold about 1,000 lines of source each, so abandoning migration discards almost nothing built; three in-house consumers already resolve the existing libraries by URL at pinned released versions and none references a contract repository.
- J2KSwift keeps its codec, its 144,755 lines of source and its 129,822 lines of tests. It carries the largest in-place obligations: thirteen products including a daemon to inventory and split under POL-05, and a CompressionFamily dependency confined to two conformance files to extract so the core library resolves alone. DICOMKit and CompressionFamily both consume it by URL at pinned released versions.
- Updated all seven shared documents and their SHA-256 manifest. Documentation only: no source migration, codec execution, platform change or release. Continuous integration remains blocked and has verified none of this.

## Decision D2: codec libraries relocate into the successor repositories — contract 0.8.0, 22 September 2026

- Decision D2 supersedes D1. J2KSwift's codec relocates here; the predecessor becomes a maintenance project and is archived once its consumers have moved. Restores the direction of the repository foundation v0.1.0, reaffirmed by the owner as the guidance for this migration.
- Licence changed from MIT to **Apache-2.0** for this repository, its in-house source and its documentation, amending POL-07 and settling the split that 0.7.0 referred to the owner. LICENSE replaced, NOTICE added, SPDX identifiers updated (29 files).
- Recorded as preconditions rather than resolved: continuous integration must execute before any source moves (Actions billing is still locked, verified 22 September 2026), the POL-05 product inventory must be signed off, and the Apple 26.0 deployment floor against current consumer floors is referred to the owner.
- All seven shared documents stay byte-identical; `SUITE_POLICY.md` and the SHA-256 manifest advance together. No platform, precision, ownership, fidelity or testing rule changes. This revision authorises no codec milestone and no release.

## Product dispositions under POL-05 — 22 September 2026

- Inventoried every J2KSwift product and recorded it as retained, adapted or deferred in [IMPLEMENTATION.md](IMPLEMENTATION.md), as contract 0.8.0 §3 requires before any subsystem is relocated. Fourteen products become four: `SwiftJ2K`, `SwiftJ2K3D`, `SwiftJ2KJPIP` and `swiftj2k`. `J2KCore`, `J2KCodec`, `J2KFileFormat`, `J2KContract` and `J2KMetal` fold into the principal module; `J2K3D` and `JPIP` stay separate products and ship in 12.1.0 because DICOMKit imports them across seven files; `J2KDICOMHelpers`, the three daemon products, `j2kd` and `J2KTestApp` are deferred, none of them with an in-house importer.
- Measured at predecessor `2fa9a3d` with `swift package dump-package`, with an import census across DICOMKit, CompressionFamily, VoxeliaValidation, DICOMAdapter, RasterOneImage, OneImageViewer-iOS and telerad-dicom-viewer. Every deferred product has zero in-house importers.
- Deferred is not deleted: a deferred product stays with the predecessor through its maintenance window. No shared contract document changes, no source moves, and no release or milestone is authorised by this record.


## Contract 0.9.0: deployment floor stays at 26.0, migration sequence recorded — 22 September 2026

- Decision D3 settles the question 0.8.0 referred to the owner: the Apple deployment floor stays at exactly 26.0 (PLAT-01/02 unchanged), and a consumer raises its own floor to 26.0 in the same change that re-points it from J2KSwift to this repository. Until then J2KSwift remains its supported route. DICOMKit consumes J2KSwift from 11.0.3 at macOS 15 / iOS 18 / tvOS 18 / visionOS 2; CompressionFamily (floor macOS 13 / iOS 16) declares no dependency on J2KSwift and is never re-pointed.
- Corrected the continuous-integration record: J2KSwift now has a CI workflow (its pull request 488, merged 22 September 2026), and every successor carries the Milestone 1 contract workflow. All are written and unexecuted; Actions billing is still locked, verified the same day with `steps=0` on every job. No codec source moves before CI executes and passes here.
- Recorded the programme sequence: preconditions, then JLSwift → SwiftJLS as the pilot, then JLISwift, JXLSwift and J2KSwift, then consumers. This repository is last in sequence, and its migration is preceded by the CompressionFamily conformance extraction (0.8.0 item 4) and the fixture provenance audit, both done in or about J2KSwift before any source moves.
- Defined what may proceed before CI runs: documentation, inventories, provenance audits, pin selection, the 0.8.0 item 5 reconciliation choice, and dependency extraction inside the predecessor. Adding predecessor codec or codec-test files here is the line that is not crossed. J2KSwift's own tiered CI gate (its pull request 488) is the workflow the 0.8.0 record said did not exist.
- README now states the shared contract version it actually carries (it had read 0.7.0 since 0.8.0). All seven shared documents stay byte-identical; `SUITE_POLICY.md` and the SHA-256 manifest advance together. No platform, precision, ownership, fidelity or testing rule changes. This revision authorises no codec milestone and no release.

## CompressionFamily extraction recorded as done — 22 September 2026

- [IMPLEMENTATION.md](IMPLEMENTATION.md) now records that contract 0.8.0 §4 is satisfied for this codec: J2KSwift pull request 489 (merged 22 September 2026, `7acc9ae`) moved the two conformance files and their tests into the separate package `Adapters/J2KCompressionFamily` in the predecessor, and the J2KSwift root manifest declares no external dependency. Repository-specific documentation only; no shared contract document changes, so the byte-identity manifest is untouched. No source moves, no milestone or release authorised.

## Contract 0.10.0 mirrored: the executable naming rule — 23 September 2026

- Took contract revision **0.10.0** across from SwiftJLI, where it was prepared. CLI-01 renames the four successor executables to `swiftj2k-cli`, `swiftjls-cli`, `swiftjxl-cli` and `swiftjli-cli`, and adds the rule that no executable name may differ from a target or module name in the same package by case alone. `SUITE_POLICY.md`, `CLI_CONTRACT.md` and the SHA-256 manifest advance together; the other five shared documents were already byte-identical here and are untouched.
- The rule exists because Swift Build names each product's intermediates directory after the product. **This repository has the defect it describes.** `SwiftJ2K` and `swiftj2k` differ only in case, so on a case-insensitive filesystem — the macOS default — the library target and the executable product resolve to one directory and overwrite each other's dependency files. Measured here on 23 September 2026 with Apple Swift 6.2.3: `swift build --build-system swiftbuild` fails with `unable to open dependencies file (.../swiftj2k.build/Objects-normal/arm64/main.d)`. All four repositories were checked and all four reproduce it identically.
- **The rename itself is not done here.** This revision carries the amended CLI-01 text only; the executable is still `swiftj2k`. Renaming it — the product name, `ManPages/swiftj2k.1`, the installer tool name, the CLI documentation and the tool name the executable reports in help and JSON — is separately assigned work in this repository. SwiftJLI has completed its own, and its change records what the rename touches.
- Documentation only: no source, platform, precision, ownership, fidelity or testing rule changes, and no codec milestone, release or tag is authorised. Continuous integration remains blocked by the Actions billing lock and has verified none of this.
