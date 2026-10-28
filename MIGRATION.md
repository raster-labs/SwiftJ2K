# Migrating applications from J2KSwift to SwiftJ2K

For application maintainers and coding agents. This guide covers **consumer application migration**; [IMPLEMENTATION.md](IMPLEMENTATION.md) governs migration of codec algorithms into this library. Suite contract **0.10.0**; successor at version **12.1.0** (tag state in [CHANGELOG.md](CHANGELOG.md)); predecessor pinned at [J2KSwift 7acc9ae4](https://github.com/Raster-Lab/J2KSwift/tree/7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca), the revision the codec was migrated from. Record your application's actual resolved revisions and compare them before applying the mappings below.

## Readiness

**The successor implements one qualified profile and rejects everything else.** After Milestones 2 to 4 the library encodes, decodes and inspects lossless JPEG 2000 Part 1 codestreams for one unsigned greyscale component of 1 to 16 bits stored in 16-bit samples:

| Feature | Decode | Encode |
| --- | --- | --- |
| Reversible 5/3 wavelet, no quantisation, raw codestream | yes | yes |
| Tiles, image and tile origins | any | one tile at the origin |
| Quality layers | any | one |
| Code-block styles (all six bits), progression orders, precincts, SOP/EPH, tile-parts | all | default style, LRCP, one tile-part |
| HTJ2K, 9/7 and quantised (lossy) coding, colour, signed and sub-sampled components, ROI, POC, PPM/PPT, JP2/JPH containers | rejected with `unsupportedFeature` or `unsupportedFormat` | rejected |
| Metal acceleration, JPIP, JP3D, the daemon, native J2K ↔ HTJ2K transcoding | absent | absent |

Executed evidence per milestone: [MILESTONE2.md](Documentation/MILESTONE2.md), [MILESTONE3.md](Documentation/MILESTONE3.md), [MILESTONE4.md](Documentation/MILESTONE4.md), [MILESTONE5.md](Documentation/MILESTONE5.md). Contract 0.9.0's continuous-integration precondition is still unmet, so none of that evidence has been reproduced by CI. Keep the predecessor supplying every feature outside the table until the successor implements and independently qualifies it. An unsupported error must not become an empty file, a black image or a successful migration result.

## Dependency, product and platform changes

| Application dependency | Predecessor | Successor and action |
| --- | --- | --- |
| Repository | `Raster-Lab/J2KSwift` | `Raster-Lab/SwiftJ2K` |
| Principal SwiftPM products/imports | `J2KCore`, `J2KCodec`, `J2KFileFormat`, `J2KMetal` | one principal product and module, `SwiftJ2K`; `import SwiftJ2K` in a new adapter target |
| Volumetric & JPIP SwiftPM products/imports | `J2K3D`, `JPIP` | retained products `SwiftJ2K3D` (`import SwiftJ2K3D`) and `SwiftJ2KJPIP` (`import SwiftJ2KJPIP`) per Decision M2 and Contract `API-13` |
| Shared protocol dependency | `CompressionFamily` conformances (now in J2KSwift's separate `Adapters/J2KCompressionFamily` package) | none; adapt local concrete types explicitly |
| Package dependencies | none | none; `swift package show-dependencies` on a consumer lists this repository alone |
| Minimum tools | consult the application pin; the pinned predecessor uses Swift 6.2 | Swift 6.2 tools minimum, Swift 6 language mode; Swift 6.4 is the qualified primary toolchain |
| Apple deployment floors | inspected predecessor manifest: macOS 15, iOS/tvOS 18, watchOS 10, visionOS 1 | all five floors are 26.0. Contract 0.9.0 Decision D3: a consumer raises its own floor to 26.0 in the same change that re-points it; until then the predecessor remains its supported route |
| Linux | Apple-only in practice | Ubuntu 24.04 arm64 build, tests and CLI executed in a container (MILESTONE4.md); x86_64 unexecuted |
| CLI | `j2k` | `swiftj2k-cli` with `encode`, `decode`, `inspect`, `validate`, `capabilities` over the NRRD interchange profile ([CLI.md](CLI.md)) |

In an isolated application branch, add the successor and pin it to a reviewed commit:

```swift
.package(url: "https://github.com/Raster-Lab/SwiftJ2K.git",
         revision: "45a36992f2daab547cc058097b648f71053e3cab")   // Milestone 4 merge; pick your reviewed commit
```

and `.product(name: "SwiftJ2K", package: "SwiftJ2K")` on the adapter target. Do not use `from: "12.1.0"` until that release exists ([RELEASE.md](Documentation/RELEASE.md)). Commit the application's `Package.resolved`. Package identities derive from repository or directory names, so give a standalone consumer a distinct name and directory, and never mount or clone this repository under a directory named differently from `SwiftJ2K` when a path dependency is used (the identity would change).

Keep old and new dependencies side by side only in the application during evaluation, qualifying symbols such as `J2KCodec.J2KDecoder` and `SwiftJ2K.Decoder`. The successor must not gain a dependency on the predecessor, another suite codec or a shared-foundation library. Remove the application's CompressionFamily dependency only after checking every remaining consumer.

## Operation and image mapping

Predecessor signatures are in [J2KCodec.swift](https://github.com/Raster-Lab/J2KSwift/blob/7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca/Sources/J2KCodec/J2KCodec.swift) and [J2KCore.swift](https://github.com/Raster-Lab/J2KSwift/blob/7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca/Sources/J2KCore/J2KCore.swift); successor signatures in [CodecAPI.swift](Sources/SwiftJ2K/CodecAPI.swift), [Options.swift](Sources/SwiftJ2K/Options.swift) and [Image.swift](Sources/SwiftJ2K/Image.swift).

| Existing use | Successor shape | Migration consequence |
| --- | --- | --- |
| `J2KEncoder(configuration:)` with `quality`, `lossless`, rate control, transform selection | `try Encoder(configuration: EncoderConfiguration(mode: .lossless, codecOptions: CodecOptions(decompositionLevels:codeBlockWidth:codeBlockHeight:)))` | `.lossless` is the only mode that succeeds; `.nearLossless` and `.lossy` throw `unsupportedFeature`. There is no quality number to translate. The predecessor default `J2KConfiguration()` is `quality: 0.9, lossless: false`; choose fidelity explicitly before cutover |
| `try await encoder.encode(image)` returning `Data` | `try await encoder.encode(image, options: EncodeOptions(resourceLimits:…))` returning `EncodedImage` | bytes in `.data`; `.encoding.mode`; `.report` carries backend, fidelity, copy events and allocation counts |
| `J2KDecoder().decode(_:)` returning `J2KImage` | `try Decoder().decode(data, options:)` returning `DecodedImage` | samples through `.image.sampleUInt16(x:y:)` or the storage borrow; `.report` |
| Decoder-owned final image, then copy into application memory | `decode(_:into:options:)` with an `ImageDestination` the application allocated | final samples land directly in caller storage; the report shows `pixelAllocationCount == 0` and no copy events (MILESTONE3.md) |
| Predecessor header parsing | `inspect(_:options:) -> ImageInfo` | bounded main and tile-part header parse without decoding; `descriptor`, `format`, `frameCount` |
| Component-owned `J2KImage` / `J2KImageBuffer` | `ImageDescriptor` + `ImageDestination` + sealed `Image` | explicit precision, byte order, row stride and finite limits replace mutable per-component `Data` |
| `J2KError` cases | `CodecError.category` and `CancellationError` | map categories (`invalidArgument`, `malformedInput`, `unsupportedFormat`, `unsupportedFeature`, `incompatibleImageLayout`, `resourceLimitExceeded`, `storageUnavailable`, `backendUnavailable`, `ioFailure`, `internalFailure`) explicitly, never diagnostic strings |
| `J2KTranscoder` | `Transcoder.transcode(_:to:options:)` with `.jpeg2000` / `.htj2k` | signature only; `capabilities` is empty and every call throws `unsupportedFeature` ([TRANSCODING.md](TRANSCODING.md)) |
| `J2KDecoder.preWarm()`, Metal session controls | `ExecutionPolicy` (`.automatic`, `.scalarCPU`, `.preferred(.accelerated)`, `.required(.accelerated)`) | `J2KMetal` is now an internal subsystem of `SwiftJ2K` (Decision M1). `.automatic` and `.preferred(.accelerated)` select `.accelerated` when available and fall back to `.scalarCPU` with `OperationReport.fallbackReason`; `.required(.accelerated)` throws `backendUnavailable` when unavailable |

Resource limits are finite on every operation and count row padding, retained storage and workspace; the defaults are TESTING.md's general profile, and applications may set smaller ones. `CopyPolicy.requireSharedStorage` is the default; `allowCopy` changes nothing on this path because no conversion is ever needed for the shared layout. Cancellation surfaces as `CancellationError`; a decode cancelled after it started writing invalidates its destination, a preflight rejection leaves the destination reusable. Progress callbacks fire at the phases `inspecting`, `processing` and `completed`.

## Adapting sample storage

The qualified profile is unsigned, one greyscale plane, 16-bit storage, little-endian samples, explicit meaningful precision (1 to 16), packed or padded rows. A 12-bit source in 16-bit words stays 12-bit (`meaningfulBits: 12`) even when every value fits eight bits. Do not reinterpret signed samples as unsigned, interleave planar components, truncate precision, infer colour meaning or apply windowing or rescaling; DICOM interpretation stays in the application. `J2KComponent.data` holds per-component bytes whose order the pinned predecessor may infer; determine the producer's byte order before converting.

A first adapter copies known samples into `ImageDestination.allocate(...).writeUInt16`, which is an application-side, counted copy; the codec's own path then adds none. A provider that wants to avoid even that copy implements the `WritableImageStorage` lease lifecycle over its real allocation ([MEMORY_CONTRACT.md](Documentation/MEMORY_CONTRACT.md)); retaining a token beside `Data.withUnsafeBytes` or escaping an array pointer is not an owning provider.

The following program is [Examples/MigrationExample](Examples/MigrationExample), built and run as part of Milestone 5. It links only the successor.

```swift
import Foundation
import SwiftJ2K

// 1. Samples the application already holds: 12 meaningful bits in 16-bit
//    words, five samples per row, rows padded to 16 bytes.
let width = 5, height = 3, rowBytes = 16
var plane = [UInt16](repeating: 0xA5A5, count: rowBytes / 2 * height)
for y in 0..<height {
    for x in 0..<width { plane[y * rowBytes / 2 + x] = UInt16((x * 731 + y * 1093) % 4096) }
}

// 2. Finite limits on every operation, and a descriptor that states the layout.
let limits = try ResourceLimits(maximumCompressedBytes: 1 << 20, maximumDecodedBytes: 1 << 20,
                                maximumWorkspaceBytes: 8 << 20, maximumPixels: 1 << 20,
                                maximumDimension: 4096, deadlineSeconds: 10, maximumMemoryBytes: 16 << 20)
let descriptor = try ImageDescriptor.greyscale16(width: width, height: height, meaningfulBits: 12,
                                                 rowBytes: rowBytes, limits: limits)

// 3. Source image: one explicit, counted copy of the application's samples.
let source = try ImageDestination.allocate(descriptor: descriptor, limits: limits)
    .writeUInt16 { x, y in plane[y * rowBytes / 2 + x] }

// 4. Lossless encode. `mode` replaces the predecessor's quality/lossless flags.
let encoder = try Encoder(configuration: .init(mode: .lossless, codecOptions: .init(decompositionLevels: 1)))
let encoded = try await encoder.encode(source, options: .init(resourceLimits: limits))

// 5. Inspect first, then decode into storage the application owns.
let decoder = try Decoder()
let info = try decoder.inspect(encoded.data, options: .init(resourceLimits: limits))
guard info.descriptor.width == width, info.descriptor.height == height, info.descriptor.meaningfulBits == 12 else {
    throw CodecError(.internalFailure, "Inspection disagrees with the source.")
}
let destination = try ImageDestination.allocate(descriptor: descriptor, limits: limits)
let decoded = try await decoder.decode(encoded.data, into: destination,
                                       options: .init(resourceLimits: limits, copyPolicy: .requireSharedStorage))

// 6. Lossless means every logical sample, and the report says what the codec did.
for y in 0..<height {
    for x in 0..<width where try decoded.image.sampleUInt16(x: x, y: y) != plane[y * rowBytes / 2 + x] {
        throw CodecError(.internalFailure, "Round trip changed sample (\(x), \(y)).")
    }
}
guard decoded.report.copyEvents.isEmpty, decoded.report.pixelAllocationCount == 0 else {
    throw CodecError(.internalFailure, "The shared-storage path copied or allocated pixels.")
}

// 7. Unsupported or malformed input stays an error; it never becomes empty output.
do {
    _ = try await decoder.decode(Data([0xFF, 0x4F, 0xFF, 0x51]), options: .init(resourceLimits: limits))
    throw CodecError(.internalFailure, "A truncated codestream decoded.")
} catch let error as CodecError where error.category == .malformedInput {}

print("Migration example passed: \(encoded.data.count)-byte lossless codestream; decode into caller storage with \(decoded.report.pixelAllocationCount ?? -1) pixel allocations and \(decoded.report.copyEvents.count) copy events.")
```

## Command-line scripts

| `j2k` use | `swiftj2k-cli` equivalent |
| --- | --- |
| encode a raw greyscale image | `swiftj2k-cli encode -i image.nrrd -o out.j2k --precision 12`; input is the NRRD profile in CLI.md (attached header, `uint16`, 2-D, raw, `swiftj2k.meaningfulbits:=N`), not PGM or DICOM |
| decode to a raw image | `swiftj2k-cli decode -i in.j2k -o image.nrrd [--overwrite]` |
| `Info` | `swiftj2k-cli inspect -i in.j2k --json` |
| validate a stream | `swiftj2k-cli validate -i in.j2k` (full in-memory decode, exit status only) |
| pipes | `-` for stdin and binary stdout on every codec verb |
| exit codes | 0, 2 usage, 3 malformed, 4 unsupported, 5 resource limit or deadline, 6 I/O, 7 internal, 130 interrupted |
| `Batch`, `Benchmark`, `Compare`, `Convert`, `Completions`, `Headless`, `InProcBench`, `Encode3D`, `Decode3D`, `JPIPClient`, `JPIPServer`, `DICOMSupport`, `OPJ*` | none yet; keep those scripts on `j2k` (IMPLEMENTATION.md, CLI surface) |

## Features and auxiliary products requiring separate decisions

| Existing dependency or behaviour | Application action before cutover |
| --- | --- |
| HTJ2K, lossy and 9/7 coding, colour, JP2/JPH, ROI, progressive or resolution decode, component transforms | keep on the predecessor; await implemented capability entries with independent oracles |
| `J2KFileFormat`, `J2KMetal`, `J2KDecoder.preWarm()` | no successor equivalent yet; `J2KMetal` becomes an internal target selected through `executionPolicy` when it migrates (IMPLEMENTATION.md, decision M1) |
| `J2K3D` | retained as the `SwiftJ2K3D` library product (`import SwiftJ2K3D`, decision M2, Milestone 10). Preserves `J2KVolume`, `J2KVolumeComponent`, `J2KVolumeMetadata`, `JP3DEncoder`, `JP3DDecoder`, `JP3DROIDecoder`, `JP3DProgressiveDecoder`, `JP3DTranscoder`, `JP3DHTJ2K*`, `JP3DMultiSpectral*`, and `JP3DMetalDWT` so `DICOMKit`'s five JP3D-importing files compile by replacing `import J2KCore`/`import J2K3D` with `import SwiftJ2K`/`import SwiftJ2K3D`, while adding the contract-aligned **API-13** `VolumeEncoder`, `VolumeDecoder`, and `VolumeTranscoder` types ([MILESTONE10.md](Documentation/MILESTONE10.md)) |
| `JPIP` | retained as the future product `SwiftJ2KJPIP` (decision M2); not yet migrated |
| `J2KDICOMHelpers` | retires with the predecessor (decision M3). Audit executed 22 September 2026: DICOMKit's `DICOMCore/J2KCodestreamInspector.swift` covers Part 2 multi-component and irreversible-wavelet detection but has no equivalent of `J2KDICOMCodestreamDetector`'s CAP-marker (HTJ2K versus Part 1) transfer-syntax sniff, and the `htj2kLossless` identifiers found in DICOMKit live in its DICOMStudio application layer. Under decision M3 that single file transplants to DICOMKit in DICOMKit's own task before the predecessor is archived |
| `j2kd`, `J2KDaemonProtocol`, `J2KDaemonCore`, `J2KDaemonClient`, `J2KTestApp` | deferred; no successor equivalent |
| Native J2K ↔ HTJ2K transcode | [TRANSCODING.md](TRANSCODING.md); not implemented |

Predecessor transcoder success is not by itself an oracle. Keep original compressed fixtures immutable; file-format bytes are not rewritten because a package is renamed.

## Migration sequence

1. Record the application's lockfile revision, imported products, supported OS versions, call sites, pixel layouts, precision and signedness, metadata obligations, CLI and service use and representative licensed fixtures. Record baseline outputs and known failures from that exact application and predecessor combination.
2. Add a separate successor adapter target on an application feature branch, raising that target's Apple floor to 26.0 (Decision D3). Build the example above first. Keep the predecessor backend selected explicitly for everything outside the qualified profile; no hidden fallback inside SwiftJ2K.
3. Map only the supported descriptor and the error categories. Add boundary, stride, precision and lifetime tests for the adapter. Preserve unsupported functionality and list it as a blocker; do not remove tests or reduce bit depth to obtain a green build.
4. Before enabling the successor route for the qualified profile, validate old encode → new decode and new encode → old or independent decode (OpenJPEG and Kakadu are the oracles this repository uses). Compare every logical sample, meaningful precision and interpretation. A self-round-trip, a successful build or a matching buffer address is insufficient.
5. Measure the application's copies, allocations, cancellation, failure cleanup, latency and peak memory under the real workload, on every supported deployment target.
6. Cut over one qualified profile at a time behind an application-controlled switch. Retain the previous package pin, adapter and fixtures for rollback. Remove predecessor dependencies only after no production call site or optional product needs them.
7. Report changed call sites, exact before and after revisions, executed commands, results, conversion costs, blockers and rollback steps in the application pull request. Storage-only work is partial migration.

Re-pointing DICOMKit, and the applications that reach the codecs through it, is a separate owner-assigned task (contract 0.8.0 item 7); this guide does not authorise a coding agent to modify a downstream application. A completed application migration requires working successor operations for every enabled profile, passing independent fidelity, metadata and platform tests, and an exercised rollback route.
