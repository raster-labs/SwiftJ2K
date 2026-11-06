# Security policy and implementation requirements

Status: active (`SwiftJ2K v12.1.0` released 6 November 2026; see [Documentation/RELEASE-v12.1.0.md](Documentation/RELEASE-v12.1.0.md)). No vulnerability response-time SLA is promised here. The supported-version policy below applies to the `12.1.x` stable line.

## Reporting

Use the repository's **Private Vulnerability Reporting** option in the GitHub Security tab on `raster-labs/SwiftJ2K`. Do not post exploitable payloads, credentials or patient information in a public issue.

Include affected version/commit, platform, a minimal safe reproducer, expected/actual behaviour and impact. Use synthetic data where possible.

Checked on **6 November 2026** through the GitHub API (`gh api repos/raster-labs/SwiftJ2K/private-vulnerability-reporting`): private vulnerability reporting is **enabled** (`"enabled": true`), satisfying Precondition 2 of [Documentation/RELEASE.md](Documentation/RELEASE.md) (superseding the earlier 22 September 2026 pre-release check when it had not yet been enabled).

## Supported versions

| Version | Status |
| --- | --- |
| `12.1.x` (`v12.1.0`, active stable line) | Receives correctness and security fixes on `main`, released as patch versions, for the stable 2D `SwiftJ2K` codec and 2D `swiftj2k-cli` scope (`SwiftJ2K3D` and `SwiftJ2KJPIP` are experimental preview products in `12.1.0`, scheduled for full qualification in `12.2.0`) |
| `12.1.0-dev.*` development identifiers | No support; superseded by `v12.1.0` |
| Predecessor J2KSwift | Maintenance window under contract revision 0.8.0 item 6: security and correctness fixes only, in the predecessor repository, until its last in-house consumer (including JP3D/JPIP consumers awaiting `SwiftJ2K 12.2.0` and pre-OS 26 targets) has moved |

A report against an unsupported version is still welcome; it will be reproduced on `main` first.

## Threat model

Treat every compressed image, metadata field, interchange header and caller-supplied descriptor as untrusted. Attackers may attempt out-of-bounds access, integer overflow, decompression bombs, pathological entropy work, deeply nested containers, unbounded tasks/caches, malformed colour profiles, unsafe external references or leakage of previous frame memory. Core codecs do not access the network, spawn reference codecs or interpret embedded code.

Enforce the resource, deadline and ownership rules in the common contracts before allocating and while processing. Check slice indices and offset bases. Bound metadata, frame/component/tile counts and parse depth. Reject unsupported essential features. Do not use assertions/preconditions to validate hostile input. Do not emit success after partial decode or cancellation.

Use synthetic fixtures and sanitised diagnostics. Do not log raw images, patient fields, full filesystem paths or memory addresses by default. Initialise exported padding and prevent pool reuse while readers remain. Use scoped filesystem operations only in the CLI; reject detached input references/URLs in the initial stream profile. Atomic final-output publication and overwrite checks must not become path traversal or symlink vulnerabilities.

## Required verification

Run parser/descriptor mutation tests, bounded fuzzing, address/race checks on supported environments and allocation/cancellation stress. Record and fix crash/hang seeds. Review unsafe bridges and native kernels. Check third-party development tools/dependencies and pin reproducible versions. No unresolved severe memory-safety, data-corruption or input-triggered denial-of-service finding is acceptable at stable release.

Correctness and security gates cannot be waived by a benchmark improvement. See `Documentation/TESTING.md` and `Documentation/PERFORMANCE.md` for evidence requirements.
