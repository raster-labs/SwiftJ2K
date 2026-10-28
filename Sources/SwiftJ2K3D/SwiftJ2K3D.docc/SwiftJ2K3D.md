# ``SwiftJ2K3D``

Volumetric JPEG 2000 Part 10 (JP3D, ISO/IEC 15444-10) encoding, decoding, ROI extraction, progressive delivery, HTJ2K transcoding, and multi-spectral volume processing.

## Overview

`SwiftJ2K3D` is the retained 3D volumetric library product of `SwiftJ2K` (Decision M2). It provides both the contract-aligned volume codec surface (`VolumeEncoder`, `VolumeDecoder`, `VolumeTranscoder`) and the full `JP3D*` type hierarchy for seamless consumer migration (such as `DICOMKit`).

### Key Capabilities

- **3D Discrete Wavelet Transform (`JP3DWaveletTransform`, `JP3DMetalDWT`)**: Separable 3D Le Gall 5/3 reversible and CDF 9/7 irreversible wavelet transforms with symmetric, periodic, and zero-padding boundary extensions, plus Metal GPU acceleration on Apple Silicon.
- **Slice-Stack Volumetric Codec (`JP3DSliceStackCodec`)**: High-throughput `J3DS` v2 slice-stack payload format delegating per-slice 2D encoding, decoding, and lossless transcoding to `SwiftJ2K`'s Part 1 and Part 15 (HTJ2K) pipelines with optional lossless Z-axis first-order delta prediction (`JP3DZDeltaMode`).
- **Volumetric Encoder & Decoder (`JP3DEncoder`, `JP3DDecoder`, `VolumeEncoder`, `VolumeDecoder`)**: Lossless, lossy PSNR, target bitrate, visually lossless, lossless HTJ2K, and lossy HTJ2K modes with signed and unsigned voxel precision (`1...38` bits).
- **Region-of-Interest & Progressive Decoding (`JP3DROIDecoder`, `JP3DProgressiveDecoder`)**: Sub-volume decoding skipping unneeded tiles and Z-slices, multi-resolution thumbnail decoding, and quality-layer progressive refinement.
- **HTJ2K in JP3D & Lossless Transcoding (`JP3DHTJ2KCodec`, `JP3DTranscoder`, `VolumeTranscoder`)**: CAP (`0xFF50`) / CPF (`0xFF59`) marker signalling and wavelet-domain slice-by-slice transcoding between standard JP3D and HTJ2K without inverse/forward wavelet transforms.
- **Multi-Spectral Volumetric Processing (`JP3DMultiSpectralEncoder`, `JP3DMultiSpectralDecoder`, `JP3DSpectralAnalyser`)**: Spectral Karhunen-Loève decorrelation, inter-band prediction, normalized difference spectral indices (NDVI, NDWI, NDSI), and automated voxel classification.

## Topics

### Volume Codec Contract (API-13)

- ``VolumeEncoder``
- ``VolumeDecoder``
- ``VolumeTranscoder``
- ``VolumeEncoderConfiguration``
- ``VolumeDecoderConfiguration``
- ``VolumeEncodeOptions``
- ``VolumeDecodeOptions``
- ``EncodedVolume``
- ``DecodedVolume``
- ``VolumeInfo``

### Core Volume Types

- ``J2KVolume``
- ``J2KVolumeComponent``
- ``J2KVolumeMetadata``
- ``J2KVolumeModality``
- ``JP3DRegion``
- ``JP3DTile``
- ``JP3DPrecinct``
- ``JP3DTilingConfiguration``
- ``JP3DProgressionOrder``
- ``JP3DCompressionMode``
- ``JP3DZDeltaMode``
- ``J2K3DCoefficients``
- ``JP3DSubband``

### Wavelet Transform

- ``JP3DTransformMode``
- ``JP3DWaveletFilter``
- ``JP3DBoundaryExtension``
- ``JP3DTransformConfiguration``
- ``JP3DWaveletTransform``
- ``JP3DDecompositionResult``
- ``JP3DSubbandMetadata``
- ``JP3DMetalDWT``

### Volumetric Encoding & Decoding

- ``JP3DEncoder``
- ``JP3DEncoderConfiguration``
- ``JP3DEncoderResult``
- ``JP3DDecoder``
- ``JP3DDecoderConfiguration``
- ``JP3DDecoderResult``
- ``JP3DROIDecoder``
- ``JP3DROIDecodeResult``
- ``JP3DProgressiveDecoder``
- ``JP3DProgressiveResult``
- ``JP3DStreamWriter``
- ``JP3DCodestreamParser``
- ``JP3DCodestreamBuilder``

### HTJ2K & Transcoding

- ``JP3DHTJ2KConfiguration``
- ``JP3DHTJ2KBlockMode``
- ``JP3DHTMarkers``
- ``JP3DHTJ2KCodec``
- ``JP3DTranscoder``
- ``JP3DTranscoderConfiguration``
- ``JP3DTranscoderResult``

### Multi-Spectral Volumes

- ``JP3DMultiSpectralVolume``
- ``JP3DSpectralBand``
- ``JP3DSpectralMapping``
- ``JP3DMultiSpectralEncoder``
- ``JP3DMultiSpectralDecoder``
- ``JP3DSpectralAnalyser``
