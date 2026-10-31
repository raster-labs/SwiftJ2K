# Codex R3 takeover evidence — NOT ACCEPTED

This directory preserves source-scoped evidence; it grants no engineering acceptance,
waiver, merge permission or R4 activation. STATUS.md is the canonical owner/queue record.

Read generated-index.json for original paths, repository-relative packaged paths,
SHA-256 identities, completed command/results, review scopes, excluded incomplete work
and the separately captured current Sources/Tests/Scripts/Package.swift identity.
Validation includes failed runs. A completed process or focused pass is not full R3
qualification. Missing/skipped/unavailable external gates are not successful tests.

Before/after source manifests are stored once per SHA-256 under manifests/. Their bytes
are unmodified, including any historical generated-cache entries; the index records the
original run roles. The current implementation-only identity deliberately excludes
Documentation and package contents, so generated evidence never hashes itself. It is
not a Git tree or proof that earlier runs qualified this later candidate.

All five direct external gates remain UNEXECUTED / UNWAIVED in external-gates.json:
combined Part10+15; native 3D JPIP; the exact repository WebSocket extension; direct
full38 Part2 output; and multiple transmitted nonempty HT sets. Shared-core refinement,
Part1/15 limb adapters, independently written synthesis, 2D peers, diagnostic decoder
patches and scripted loopback tests retain their narrower scope.

The packager copies exact receipt bytes and never invokes a compiler, test, codec,
server, network service or Git. Completed runs require result.json plus all receipt
files and a matching recorded native-log hash. Incomplete runs and incomplete review
pairs are excluded and listed. Benchmark/profile families are included only when their
own validation run is complete. No executables, build trees or generated source trees
are copied. Existing historical files are left intact.

XML reports beside completed validation receipts are copied without interpreting a
missing XCTest report as zero tests. Numbered sanitizer inventories are included only
when their owning validation command has finished; raw stdout/stderr, IDs and JSON
remain exact. Final sanitizer proof/decision receipts are separate from declaration
inventories and never change this package's NOT_ACCEPTED state or external gates.

Packaged receipt paths are immutable. A conflicting existing receipt causes a visible
error; the operator must reconcile it explicitly. Repeated runs update only the generated
index, first preserving the prior index under index-history/<sha256>.json. New source
identities use content-addressed paths. Missing or changed prior receipt objects abort
rather than silently dropping evidence. Run only with source writers stopped and the
coordinator's existing exclusive claim held; this tool does not acquire that claim.
