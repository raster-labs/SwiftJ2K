# Release procedure for SwiftJ2K (12.1.0 & 12.2.0+)

Prepared in Milestone 5 (22 September 2026, contract 0.9.0), reconciled in Milestone 13 (5 November 2026, contract 0.10.0; see [MILESTONE13.md](MILESTONE13.md)), **executed on 6 November 2026 for `SwiftJ2K v12.1.0` (`12.1.0`)** ([RELEASE-v12.1.0.md](RELEASE-v12.1.0.md)), and **executed on 11 November 2026 for `SwiftJ2K v12.2.0` (`12.2.0`)** ([RELEASE-v12.2.0.md](RELEASE-v12.2.0.md); contract **0.11.0**, MIT licence; `SwiftJ2K` + `SwiftJ2K3D` + `SwiftJ2KJPIP` + `swiftj2k-cli 12.2.0`, archived under [Engineering/Remediation/Evidence/R3/v12.2.0-r3-completion/](Engineering/Remediation/Evidence/R3/v12.2.0-r3-completion/) and [Engineering/Remediation/Evidence/R4/](Engineering/Remediation/Evidence/R4/); see [Engineering/Remediation/STATUS.md](Engineering/Remediation/STATUS.md)). IMPLEMENTATION.md: "stable tag only after explicit release task". TESTING.md TEST-07: "No new stable version tag until required correctness, interoperability, platform, security and performance gates are complete."

## Preconditions the release task must verify first

1. **Continuous integration executes.** Contract 0.9.0 requires a successor workflow run with non-zero steps before any codec source moves and before any stable tag. Check the latest run on `main`:
   ```sh
   gh run list --branch main --limit 1 --json databaseId --jq '.[0].databaseId' | xargs -I{} gh api repos/Raster-Lab/SwiftJ2K/actions/runs/{}/jobs --jq '.jobs[] | "\(.name): \(.conclusion) steps=\(.steps|length)"'
   ```
   Every job at `steps=0` means the Actions billing lock is still in place and the release cannot proceed. Milestones 2 to 5 were all executed under that condition and say so.
2. **Private vulnerability reporting is enabled** on the repository (SECURITY.md). `gh api repos/Raster-Lab/SwiftJ2K/private-vulnerability-reporting` must report `"enabled": true`. Organisation-owner action.
3. **The owner has assigned the release task explicitly.** Milestone 5 completion is not that assignment.

## Gates at the release commit

Run all of these on the exact commit to be tagged and archive the outputs under `Documentation/Engineering/Release-12.1.0/Evidence` with absolute host paths removed, as the milestone records do. Commands assume the repository root, Xcode 26.2 (Apple Swift 6.2.3) and the swift.org 6.4 toolchain; substitute the identifiers actually present and record them.

| Gate | Command | Pass condition |
| --- | --- | --- |
| Xcode / Swift 6.4 toolchain, native engine, debug and release | `swift test --build-system native -c debug` and `-c release` (scoped per `Documentation/Engineering/Remediation/R3_HELD_VALIDATION_LEDGER.json` while JPIP/3D remains owner-held, or full union once lifted) | All enabled non-held core 2D declarations pass (`160` macOS core declarations; `1,213` JPIP/3D declarations explicitly recorded per owner hold in `MILESTONE13.md`), plus the 5 external-oracle declarations when OpenJPEG/Kakadu/OpenJPH are present |
| Swift 6.4, Swift Build engine, consumer, repetitions, SBOM | `DEVELOPER_DIR=… TOOLCHAINS=… ./Scripts/validate.sh --output <new dir>` | `report.json` status `passed`; both SPDX and CycloneDX SBOMs emitted and schema-validated |
| Sanitizers | `./Scripts/validate.sh --checks asan,tsan --output <new dir>` (or partitioned sanitizer workflow per `.github/workflows/contract.yml`) | AddressSanitizer and ThreadSanitizer pass with zero findings across enabled release scope |
| Linux arm64 container | `docker run --rm --platform linux/arm64 -v "$PWD":/SwiftJ2K -w /SwiftJ2K swift:6.2-noble swift test` then release build, CLI checks and `Examples/Consumer` | Passes when Linux CI scope is active (`OUT_OF_CURRENT_SCOPE_BY_OWNER` during R3/M13; record honestly if unexecuted) |
| CLI conformance | `python3 Scripts/test-cli.py --binary <release swiftj2k-cli> --output <new dir>` | All enabled 2D CLI checks pass (`246/246` full checks when JPIP/3D verbs are included; record held 3D/JPIP boundaries explicitly) |
| Contract harness | `xcrun swift run --package-path Integration/ContractHarness ContractHarness` | 6 of 6 |
| Fuzz campaign | `Integration/FuzzHarness` for one hour per enabled decode/transcode entry point, seed recorded | zero unexpected errors, zero traps, no input over the deadline |
| Release benchmark | Controlled release benchmark on an unloaded host (`PERF-03`; paused R4 item) | no median regression over 5% against the accepted baseline (`PERF-03`) |
| Apple SDK matrix | `xcodebuild -scheme SwiftJ2K -destination 'generic/platform=<iOS|iOS Simulator|tvOS|tvOS Simulator|watchOS|watchOS Simulator|visionOS|visionOS Simulator>' build` | every installed Apple OS 26 SDK builds; record uninstalled SDKs as unexecuted |
| Downstream & fresh URL consumers | `Examples/MigrationExample`, `DICOMKit/Integrations/DICOMSwiftJ2KIntegration`, and a fresh package outside the repository with `.package(url: "https://github.com/raster-labs/SwiftJ2K.git", revision: "<release commit>")` | standalone consumer resolves this repository alone and round-trips; `DICOMSwiftJ2KIntegration` passes unit, TSan, and cross-codec checks ([MILESTONE13.md](MILESTONE13.md)) |

Anything unexecuted is recorded as unexecuted in the release notes, never as passed.

## Version and tag steps

1. Set `VERSION` to `12.1.0`; update the version string in `Sources/SwiftJ2KCLI/main.swift`, the `.TH` line of `ManPages/swiftj2k-cli.1`, the version lines in `README.md` and `CLI.md`, and turn the top CHANGELOG entry into `## 12.1.0 — <date>` with the executed gates listed.
2. Commit as `Release 12.1.0` and open a pull request; merge only after the gates above have been archived.
3. Tag the merge commit with an annotated tag and push it:
   ```sh
   git tag -a v12.1.0 -m "SwiftJ2K 12.1.0" <merge commit> && git push origin v12.1.0
   ```
4. Create the GitHub release from the tag with the CHANGELOG entry as its body. Attach nothing that was not built from the tagged commit.
5. Verify consumption from the tag with a fresh package using `.package(url: …, from: "12.1.0")`, and verify installation with `Scripts/install-cli.sh --prefix <staging>`.
6. Start the next development line: `VERSION` to `12.1.1-dev.1` (or `12.2.0-dev.1` for a feature line) on `main`.

## After the release

- Tags are never deleted or moved (POL-07). A defective release is followed by a patch release.
- SECURITY.md's supported-version table becomes effective.
- Predecessor J2KSwift enters its maintenance window (contract 0.8.0 item 6); consumers re-point in their own owner-assigned tasks (MIGRATION.md).
