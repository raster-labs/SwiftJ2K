# Migrating applications from J2KSwift to SwiftJ2K

For application maintainers and coding agents. This guide covers **consumer application migration**; [IMPLEMENTATION.md](IMPLEMENTATION.md) governs migration of codec algorithms into this library. Suite contract **0.10.0**; successor at version **12.1.0** (tag state in [CHANGELOG.md](CHANGELOG.md)); predecessor pinned at [J2KSwift 7acc9ae4](https://github.com/Raster-Lab/J2KSwift/tree/7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca), the revision the codec was migrated from. Record your application's actual resolved revisions and compare them before applying the mappings below.

## Readiness (Milestones 2 through 12 complete)

**The successor implements the full qualified 2D, 3D, JPIP, and CLI surface and rejects unsupported extensions explicitly.** After Milestones 2 through 12, `SwiftJ2K`, `SwiftJ2K3D`, `SwiftJ2KJPIP`, and `swiftj2k-cli` provide:

| Feature / Subsystem | Decode | Encode / Transcode | Milestone Evidence |
| --- | --- | --- | --- |
| Part 1 lossless 5/3 & lossy/near-lossless 9/7, `1..16`-bit unsigned & signed, `1..N` components | yes | yes | [MILESTONE2.md](Documentation/MILESTONE2.md), [MILESTONE3.md](Documentation/MILESTONE3.md), [MILESTONE4.md](Documentation/MILESTONE4.md), [MILESTONE7.md](Documentation/MILESTONE7.md) |
| Part 15 HTJ2K (`htj2k`) cleanup pass & native compressed-domain `J2K ↔ HTJ2K` transcoding | yes | yes (zero pixel allocations on `transcode`) | [MILESTONE6.md](Documentation/MILESTONE6.md) |
| Colour transforms (`RCT`, `ICT`), `RGN` MaxShift ROI, multi-tile, multi-layer, precincts, `POC`, `SOP`/`EPH`, all 6 code-block styles | yes | yes | [MILESTONE7.md](Documentation/MILESTONE7.md) |
| JP2 (`jp2`), JPH (`jph`), and single-codestream JPX (`jpx`) box containers (`ihdr`, `bpcc`, `colr` enumerated & ICC, `pclr`+`cmap`, `cdef`, `res `, `rreq`, `xml `, `uuid`, `uinf`, `jp2i`, `asoc`) | yes | yes | [MILESTONE8.md](Documentation/MILESTONE8.md) |
| Internal Metal GPU & CPU SIMD/Accelerate hardware acceleration (`ExecutionPolicy`: `.automatic`, `.scalarCPU`, `.preferred(.accelerated)`, `.required(.accelerated)`) | yes | yes | [MILESTONE9.md](Documentation/MILESTONE9.md) |
| Part 10 JP3D volumetric codec (`SwiftJ2K3D`: `JP3DEncoder`, `JP3DDecoder`, `JP3DROIDecoder`, `JP3DProgressiveDecoder`, `JP3DTranscoder`, plus **API-13** `VolumeEncoder`, `VolumeDecoder`, `VolumeTranscoder`) | yes | yes | [MILESTONE10.md](Documentation/MILESTONE10.md) |
| Part 9 JPIP interactive streaming (`SwiftJ2KJPIP`: `JPIPClient`, `JPIPServer`, `JPIPSession`, `JPIPDataBinGenerator`, `JPIPWebSocketClient`/`Server`, plus **API-13** `JPIPContractSessionAdapter`) | yes | yes | [MILESTONE11.md](Documentation/MILESTONE11.md) |
| CLI (`swiftj2k-cli`: `encode`, `decode`, `transcode`, `inspect`, `validate`, `convert`, `compare`, `batch`, `encode3d`, `decode3d`, `jpip`, `benchmark`, `capabilities`, `completions` over `NRRD`, `PGM`, `PPM`, `PNM`, `PNG`, `TIFF`, `RAW`) | yes | yes | [MILESTONE12.md](Documentation/MILESTONE12.md) |
| HT refinement passes (`SigProp`/`MagRef`), sub-sampled components (`XRsiz`/`YRsiz != 1`), `PPM`/`PPT`, Part 2 `Rsiz` extensions, multi-codestream JPX compositing (`jpxb`/`comp`) | rejected with `unsupportedFeature` or `unsupportedFormat` | rejected | [MILESTONE6.md](Documentation/MILESTONE6.md)–[MILESTONE8.md](Documentation/MILESTONE8.md) |
| Predecessor daemon targets (`j2kd`, `J2KDaemon*`), `J2KDICOMHelpers`, `J2KTestApp`, `OPJ*` CLI aliases | retired / out of library scope | retired | [IMPLEMENTATION.md](IMPLEMENTATION.md), [MILESTONE12.md](Documentation/MILESTONE12.md) |

Executed evidence per milestone: [MILESTONE2.md](Documentation/MILESTONE2.md) through [MILESTONE12.md](Documentation/MILESTONE12.md). Contract 0.9.0's continuous-integration precondition remains tracked separately from local execution evidence. Keep the predecessor supplying any feature outside the supported table above if an application depends on it. An unsupported error must never become an empty file, a black image, or a silent fallback.

## Dependency, product and platform changes

| Application dependency | Predecessor | Successor and action |
| --- | --- | --- |
| Repository | `Raster-Lab/J2KSwift` | `Raster-Lab/SwiftJ2K` |
| Principal SwiftPM products/imports | `J2KCore`, `J2KCodec`, `J2KFileFormat`, `J2KMetal` | one principal product and module, `SwiftJ2K`; `import SwiftJ2K` in a new adapter target (also exports the `J2KImage`/`J2KEncoder`/`J2KDecoder`/`J2KTranscoder`/`J2KFormatDetector` compatibility bridge in `LegacyImageBridge.swift`) |
| Volumetric & JPIP SwiftPM products/imports | `J2K3D`, `JPIP` | retained products `SwiftJ2K3D` (`import SwiftJ2K3D`) and `SwiftJ2KJPIP` (`import SwiftJ2KJPIP`) per Decision M2 and Contract `API-13` |
| Shared protocol dependency | `CompressionFamily` conformances (now in J2KSwift's separate `Adapters/J2KCompressionFamily` package) | none; adapt local concrete types explicitly |
| Package dependencies | none | none; `swift package show-dependencies` on a consumer lists this repository alone |
| Minimum tools | consult the application pin; the pinned predecessor uses Swift 6.2 | Swift 6.2 tools minimum, Swift 6 language mode; Swift 6.4 is the qualified primary toolchain |
| Apple deployment floors | inspected predecessor manifest: macOS 15, iOS/tvOS 18, watchOS 10, visionOS 1 | all five floors are 26.0. Contract 0.9.0 Decision D3: a consumer raises its own floor to 26.0 in the same change that re-points it; until then the predecessor remains its supported route |
| Linux | Apple-only in practice | Ubuntu 24.04 arm64 build, tests and CLI executed in a container (MILESTONE4.md); x86_64 unexecuted |
| CLI | `j2k` | `swiftj2k-cli` with `encode`, `decode`, `transcode`, `inspect`, `validate`, `convert`, `compare`, `batch`, `encode3d`, `decode3d`, `jpip`, `benchmark`, `capabilities`, `completions` ([CLI.md](CLI.md)) |

In an isolated application branch, add the successor and pin it to a reviewed commit:

```swift
.package(url: "https://github.com/Raster-Lab/SwiftJ2K.git",
         revision: "<reviewed-milestone12-commit-sha>")
```

and `.product(name: "SwiftJ2K", package: "SwiftJ2K")` (plus `"SwiftJ2K3D"` and/or `"SwiftJ2KJPIP"` when volumetric or JPIP streaming is used) on the adapter target. Do not use `from: "12.1.0"` until that release exists ([RELEASE.md](Documentation/RELEASE.md)). Commit the application's `Package.resolved`. Package identities derive from repository or directory names, so give a standalone consumer a distinct name and directory, and never mount or clone this repository under a directory named differently from `SwiftJ2K` when a path dependency is used (the identity would change).

Keep old and new dependencies side by side only in the application during evaluation, qualifying symbols such as `J2KCodec.J2KDecoder` and `SwiftJ2K.Decoder`. The successor must not gain a dependency on the predecessor, another suite codec or a shared-foundation library. Remove the application's CompressionFamily dependency only after checking every remaining consumer.

## Operation and image mapping

Predecessor signatures are in [J2KCodec.swift](https://github.com/Raster-Lab/J2KSwift/blob/7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca/Sources/J2KCodec/J2KCodec.swift) and [J2KCore.swift](https://github.com/Raster-Lab/J2KSwift/blob/7acc9ae415e7d0bc7d441e0f0277d5e150bd19ca/Sources/J2KCore/J2KCore.swift); successor signatures in [CodecAPI.swift](Sources/SwiftJ2K/CodecAPI.swift), [Options.swift](Sources/SwiftJ2K/Options.swift), [Image.swift](Sources/SwiftJ2K/Image.swift) and [LegacyImageBridge.swift](Sources/SwiftJ2K/LegacyImageBridge.swift).

| Existing use | Successor shape | Migration consequence |
| --- | --- | --- |
| `J2KEncoder(configuration:)` with `quality`, `lossless`, rate control, transform selection | `try Encoder(configuration: EncoderConfiguration(mode: .lossless \| .nearLossless(maxError:) \| .lossy, codecOptions: CodecOptions(...)))` | Supports `.lossless` (5/3), `.nearLossless(maxError:)` and `.lossy` (`quality`, `bitsPerPixel`, `qualityLayerCount`, `wavelet`, `colourTransform`, `progressionOrder`, `tileWidth`/`tileHeight`, `precinctWidth`/`precinctHeight`, `roi`, `blockCoding: .part1 \| .htj2k`, `containerFormat: .codestream \| .jp2 \| .jph \| .jpx`). The predecessor default `J2KConfiguration()` is `quality: 0.9, lossless: false`; choose fidelity explicitly before cutover |
| `try await encoder.encode(image)` returning `Data` | `try await encoder.encode(image, options: EncodeOptions(resourceLimits:…))` returning `EncodedImage` | bytes in `.data`; `.encoding.mode` and `.encoding.format`; `.report` carries backend, fidelity, copy events and allocation counts |
| `J2KDecoder().decode(_:)` returning `J2KImage` | `try Decoder().decode(data, options:)` returning `DecodedImage` | samples through `.image.sampleInt(component:x:y:)`, `.image.sampleUInt16(x:y:)` or the storage borrow; `.image.metadata` carries JP2/JPH/JPX container metadata; `.report` carries operation telemetry |
| Decoder-owned final image, then copy into application memory | `decode(_:into:options:)` with an `ImageDestination` the application allocated | final samples land directly in caller storage; the report shows `pixelAllocationCount == 0` and no copy events (MILESTONE3.md) |
| Predecessor header parsing & `J2KFormatDetector` | `inspect(_:options:) -> ImageInfo` (or `J2KFormatDetector` compatibility bridge) | bounded container, main, and tile-part header parse without decoding; `descriptor`, `format`, `frameCount` |
| Component-owned `J2KImage` / `J2KImageBuffer` | `ImageDescriptor` + `ImageDestination` + sealed `Image` (or `J2KImage(contractImage:)` / `j2kImage.toContractImage(limits:)` bridge) | explicit precision, byte order, row stride and finite limits replace mutable per-component `Data` |
| `J2KError` cases | `CodecError.category` and `CancellationError` | map categories (`invalidArgument`, `malformedInput`, `unsupportedFormat`, `unsupportedFeature`, `incompatibleImageLayout`, `resourceLimitExceeded`, `storageUnavailable`, `backendUnavailable`, `ioFailure`, `internalFailure`) explicitly, never diagnostic strings |
| `J2KTranscoder` | `Transcoder.transcode(_:to:options:)` with `.jpeg2000`, `.htj2k`, `.jp2`, `.jph`, `.jpx` | native wavelet-coefficient transcoding between Part 1 and HTJ2K with `pixelAllocationCount == 0` ([TRANSCODING.md](TRANSCODING.md), [MILESTONE6.md](Documentation/MILESTONE6.md), [MILESTONE8.md](Documentation/MILESTONE8.md)) |
| `J2KDecoder.preWarm()`, Metal session controls | `ExecutionPolicy` (`.automatic`, `.scalarCPU`, `.preferred(.accelerated)`, `.required(.accelerated)`) | `J2KMetal` is now an internal subsystem of `SwiftJ2K` (Decision M1). `.automatic` and `.preferred(.accelerated)` select `.accelerated` when available and fall back to `.scalarCPU` with `OperationReport.fallbackReason`; `.required(.accelerated)` throws `backendUnavailable` when unavailable |
| `J2K3D` (`JP3DEncoder`, `JP3DDecoder`, `JP3DROIDecoder`, `JP3DProgressiveDecoder`, `JP3DTranscoder`) | `import SwiftJ2K3D`: retains legacy `JP3D*` types and adds contract-aligned **API-13** `VolumeEncoder`, `VolumeDecoder`, `VolumeTranscoder` | direct drop-in replacement for `import J2K3D` (`import SwiftJ2K3D` re-exports `SwiftJ2K`) ([MILESTONE10.md](Documentation/MILESTONE10.md)) |
| `JPIP` (`JPIPClient`, `JPIPServer`, `JPIPSession`) | `import SwiftJ2KJPIP`: retains `JPIP*` actors/types and adds contract-aligned **API-13** `JPIPContractSessionAdapter` (`DecodedImage` with `OperationReport`) | direct drop-in replacement for `import JPIP` (`import SwiftJ2KJPIP` re-exports `SwiftJ2K` and `SwiftJ2K3D`) ([MILESTONE11.md](Documentation/MILESTONE11.md)) |

Resource limits are finite on every operation and count row padding, retained storage and workspace; the defaults are TESTING.md's general profile, and applications may set smaller ones. `CopyPolicy.requireSharedStorage` is the default; `allowCopy` changes nothing on this path because no conversion is ever needed for the shared layout. Cancellation surfaces as `CancellationError`; a decode cancelled after it started writing invalidates its destination, a preflight rejection leaves the destination reusable. Progress callbacks fire at the phases `inspecting`, `processing` and `completed`.

## Adapting sample storage

The contract image descriptor supports `1..16` meaningful bits in 8-bit or 16-bit unsigned or signed integer samples across `1..N` planar or interleaved components with packed or padded rows. A 12-bit source in 16-bit words stays 12-bit (`meaningfulBits: 12`) even when every value fits eight bits. Do not reinterpret signed samples as unsigned, interleave planar components, truncate precision, infer colour meaning or apply windowing or rescaling; DICOM interpretation stays in the application. `J2KComponent.data` holds per-component bytes whose order the pinned predecessor may infer; determine the producer's byte order before converting.

A first adapter copies known samples into `ImageDestination.allocate(...).writeUInt16` (or `writeSamples`), which is an application-side, counted copy; the codec's own path then adds none. A provider that wants to avoid even that copy implements the `WritableImageStorage` lease lifecycle over its real allocation ([MEMORY_CONTRACT.md](Documentation/MEMORY_CONTRACT.md)); retaining a token beside `Data.withUnsafeBytes` or escaping an array pointer is not an owning provider.

The following program is [Examples/MigrationExample](Examples/MigrationExample), built and run as part of Milestone 5 and verified in Milestone 12. It links only the successor.

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

## Consumer-specific migration playbooks (`IMPLEMENTATION.md` dispositions)

| Consumer / Repository | Predecessor Imports | Successor Imports & Migration Playbook |
| --- | --- | --- |
| **DICOMKit** | `J2KCore`, `J2KCodec`, `J2KFileFormat`, `J2KMetal`, `J2K3D`, `JPIP`, `J2KDICOMHelpers` | 1. Raise Apple platform floors to `26.0` (Decision D3).<br>2. Replace `J2KCore`/`J2KCodec`/`J2KFileFormat`/`J2KMetal` with `SwiftJ2K`, `J2K3D` with `SwiftJ2K3D`, and `JPIP` with `SwiftJ2KJPIP`.<br>3. Transplant `J2KDICOMCodestreamDetector.swift` directly into `DICOMCore` (Decision M3) before retiring `J2KSwift`.<br>4. Existing `J2KImage`, `J2KEncoder`, `J2KDecoder`, `J2KTranscoder`, `JP3D*`, and `JPIP*` call sites compile directly via the compatibility bridge or can adopt `Encoder`/`Decoder`/`Transcoder`/`VolumeEncoder`/`JPIPContractSessionAdapter` with `ImageDestination` for zero-copy caller-owned decoding. |
| **CompressionFamily** (`Adapters/J2KCompressionFamily`) | `J2KCore`, `J2KCodec` | Per Contract `API-01` and `IMPLEMENTATION.md` disposition, `SwiftJ2K` has zero dependency on `CompressionFamily`. If `CompressionFamily` retains a JPEG 2000 adapter package, point that adapter package to `SwiftJ2K` and map its protocol methods to `SwiftJ2K.Encoder`, `SwiftJ2K.Decoder`, and `SwiftJ2K.Transcoder` with explicit `ImageDescriptor` and `ResourceLimits`. |
| **VoxeliaValidation** | `J2KCore`, `J2KCodec`, `J2K3D`, `j2k` CLI | Replace `import J2KCore`/`import J2K3D` with `import SwiftJ2K3D` (which re-exports `SwiftJ2K`). Replace CLI invocations of `j2k encode3d`/`decode3d`/`compare`/`benchmark` with `swiftj2k-cli encode3d`, `decode3d`, `compare --mode 3d`, and `benchmark`. |
| **DICOMAdapter** | `J2KCore`, `J2KCodec`, `J2KDICOMHelpers` | Point to `SwiftJ2K` (`import SwiftJ2K`); map DICOM pixel data descriptors (`BitsAllocated`, `BitsStored`, `PixelRepresentation`, `SamplesPerPixel`, `PlanarConfiguration`) directly to `ImageDescriptor` (`storageBits`, `meaningfulBits`, `sampleType`, `components`, `planes`) without implicit windowing or bit-depth reduction. |
| **RasterOneImage**, **OneImageViewer-iOS**, **telerad-dicom-viewer** | Transitive via `DICOMKit` (or direct `J2KCodec` / `JPIP` imports) | Raise Apple deployment floor to `26.0` when upgrading to the `SwiftJ2K`-backed `DICOMKit` revision. For interactive JPIP viewport streaming in `OneImageViewer-iOS` and `telerad-dicom-viewer`, use `SwiftJ2KJPIP`'s `JPIPContractSessionAdapter` (`requestRegionImage(region:resolutionLevel:maxQualityLayers:)`). |

## Command-line scripts (`j2k` and `opj_*` to `swiftj2k-cli`)

| Predecessor `j2k` / `opj_*` use | `swiftj2k-cli` equivalent |
| --- | --- |
| `j2k encode -i in.pgm -o out.j2k` / `opj_compress -i in.png -o out.jp2` | `swiftj2k-cli encode -i in.pgm -o out.j2k` or `swiftj2k-cli encode -i in.png -o out.jp2 --output-format jp2` (supports `nrrd`, `pgm`, `ppm`, `pnm`, `png`, `tiff`, `raw` inputs and `j2k`, `htj2k`, `jp2`, `jph`, `jpx` outputs) |
| `j2k decode -i in.j2k -o out.png` / `opj_decompress -i in.jp2 -o out.tif` | `swiftj2k-cli decode -i in.j2k -o out.png [--overwrite]` or `swiftj2k-cli decode -i in.jp2 -o out.tiff` |
| `j2k transcode -i in.j2k -o out.jph --codec htj2k-lossless` | `swiftj2k-cli transcode -i in.j2k -o out.jph --output-format jph` (wavelet-coefficient domain, zero pixel allocations) |
| `j2k info -i in.j2k` / `opj_dump -i in.j2k` | `swiftj2k-cli inspect -i in.j2k [--json]` |
| `j2k validate -i in.j2k` | `swiftj2k-cli validate -i in.j2k [--json]` |
| `j2k convert -i in.pgm -o out.png` | `swiftj2k-cli convert -i in.pgm -o out.png [--bit-depth 8\|16]` |
| `j2k compare -i orig.pgm -r dec.png` | `swiftj2k-cli compare -i orig.pgm -r dec.png [--mode 2d\|3d] [--bit-exact] [--max-error N] [--min-psnr DB] [--json]` |
| `j2k batch encode -i ./dir -o ./out` | `swiftj2k-cli batch encode\|decode\|transcode\|encode3d\|decode3d -i ./dir -o ./out [--threads 1..8] [--filter GLOB] [--exclude GLOB] [--json]` |
| `j2k encode3d` / `j2k decode3d` | `swiftj2k-cli encode3d -i ./slices -o vol.j3d --codec htj2k-lossless` / `swiftj2k-cli decode3d -i vol.j3d -o vol.nrrd [--region X,Y,Z,W,H,D]` |
| `j2k jpip client` / `j2k jpip server` | `swiftj2k-cli jpip client --single-file img.jp2 -o out.png` / `swiftj2k-cli jpip server --data-dir ./imgs --port 8080` |
| `j2k benchmark` / `InProcBench` | `swiftj2k-cli benchmark -i img.nrrd --runs 5 --warmup 1 --compare-all [--format text\|json\|csv]` (strictly in-process, zero external shell-outs) |
| `j2k completions bash\|zsh\|fish` | `swiftj2k-cli completions bash\|zsh\|fish` |
| `DICOMSupport`, `DaemonInstall`, `DaemonPing`, `Headless` | retired from codec CLI (`DICOM` parsing belongs in `DICOMKit`; daemon targets are out of codec library scope) |

## Features and auxiliary products requiring separate decisions

| Existing dependency or behaviour | Application action before cutover |
| --- | --- |
| `J2KMetal`, `J2KDecoder.preWarm()` | `J2KMetal` is an internal subsystem of `SwiftJ2K` (Decision M1). Select hardware acceleration via `ExecutionPolicy` (`.automatic`, `.scalarCPU`, `.preferred(.accelerated)`, `.required(.accelerated)`) ([MILESTONE9.md](Documentation/MILESTONE9.md)) |
| `J2K3D` | retained as the `SwiftJ2K3D` library product (`import SwiftJ2K3D`, Decision M2, Milestone 10). Preserves `J2KVolume`, `J2KVolumeComponent`, `J2KVolumeMetadata`, `JP3DEncoder`, `JP3DDecoder`, `JP3DROIDecoder`, `JP3DProgressiveDecoder`, `JP3DTranscoder`, `JP3DHTJ2K*`, `JP3DMultiSpectral*`, and `JP3DMetalDWT` so `DICOMKit`'s five JP3D-importing files compile by replacing `import J2KCore`/`import J2K3D` with `import SwiftJ2K`/`import SwiftJ2K3D`, while adding the contract-aligned **API-13** `VolumeEncoder`, `VolumeDecoder`, and `VolumeTranscoder` types ([MILESTONE10.md](Documentation/MILESTONE10.md)) |
| `JPIP` | retained as the `SwiftJ2KJPIP` library product (`import SwiftJ2KJPIP`, Decision M2, Milestone 11). Preserves `JPIPClient`, `JPIPServer`, `JPIPSession`, `JPIPRequest`, `JPIPResponse`, `JPIPDataBinGenerator`, `JPIPCacheManager`, and `JPIPWebSocket*` so `DICOMKit`'s JPIP consumers compile by replacing `import JPIP` with `import SwiftJ2KJPIP`, while adding the contract-aligned **API-13** `JPIPContractSessionAdapter` ([MILESTONE11.md](Documentation/MILESTONE11.md)) |
| `J2KDICOMHelpers` | retires with the predecessor (Decision M3). Audit executed 22 September 2026: DICOMKit's `DICOMCore/J2KCodestreamInspector.swift` covers Part 2 multi-component and irreversible-wavelet detection but has no equivalent of `J2KDICOMCodestreamDetector`'s CAP-marker (HTJ2K versus Part 1) transfer-syntax sniff, and the `htj2kLossless` identifiers found in DICOMKit live in its DICOMStudio application layer. Under Decision M3 that single file transplants to DICOMKit in DICOMKit's own task before the predecessor is archived |
| `j2kd`, `J2KDaemonProtocol`, `J2KDaemonCore`, `J2KDaemonClient`, `J2KTestApp` | deferred / retired; no successor equivalent in the codec package |

Predecessor transcoder success is not by itself an oracle. Keep original compressed fixtures immutable; file-format bytes are not rewritten because a package is renamed.

## Migration sequence

1. Record the application's lockfile revision, imported products, supported OS versions, call sites, pixel layouts, precision and signedness, metadata obligations, CLI and service use and representative licensed fixtures. Record baseline outputs and known failures from that exact application and predecessor combination.
2. Add a separate successor adapter target on an application feature branch, raising that target's Apple floor to 26.0 (Decision D3). Build [Examples/MigrationExample](Examples/MigrationExample) and [Examples/Consumer](Examples/Consumer) first. Keep the predecessor backend selected explicitly for anything outside the supported capabilities; no hidden fallback inside SwiftJ2K.
3. Map the descriptor (`ImageDescriptor`) and the error categories (`CodecError.Category`). Add boundary, stride, precision and lifetime tests for the adapter. Preserve unsupported functionality and list it as a blocker; do not remove tests or reduce bit depth to obtain a green build.
4. Before enabling the successor route for each profile, validate old encode → new decode and new encode → old or independent decode (OpenJPEG, OpenJPH, and Kakadu are the oracles this repository uses). Compare every logical sample, meaningful precision and interpretation. A self-round-trip, a successful build or a matching buffer address is insufficient.
5. Measure the application's copies, allocations, cancellation, failure cleanup, latency and peak memory under the real workload, on every supported deployment target.
6. Cut over one qualified profile at a time behind an application-controlled switch. Retain the previous package pin, adapter and fixtures for rollback. Remove predecessor dependencies only after no production call site or optional product needs them.
7. Report changed call sites, exact before and after revisions, executed commands, results, conversion costs, blockers and rollback steps in the application pull request. Storage-only work is partial migration.

Re-pointing DICOMKit, and the applications that reach the codecs through it, is a separate owner-assigned task (contract 0.8.0 item 7); this guide does not authorise a coding agent to modify a downstream application. A completed application migration requires working successor operations for every enabled profile, passing independent fidelity, metadata and platform tests, and an exercised rollback route.
