# Photon — Native macOS RAW Photo Editor

Photon is a fully local, non-destructive RAW photo editor for macOS, functionally modelled on
Adobe Lightroom Classic: same tool names, same slider behaviour, same non-destructive editing
model, same AI-assisted masking — but with no cloud, no account, no subscription, and no
telemetry. Built in Swift/SwiftUI (AppKit where needed) and optimised for Apple Silicon.

## Highlights

- **Non-destructive everywhere.** Every edit — slider, mask, crop, heal, preset — is stored as a
  data-only instruction set (`DevelopSettings`) attached to the source photo. Pixels are only
  baked at export. History, Snapshots, and Virtual Copies fall out of this model for free.
- **GPU-resident pipeline.** RAW decode via `CIRAWFilter` feeds a Core Image graph augmented
  with custom Metal `CIKernel`s (tone-curve LUT, HSL bands, clarity/texture/dehaze, grain,
  calibration, mask compositing). No CPU round-trips between filter stages.
- **AI masking on the Neural Engine.** Select Subject / Sky / People / Object are driven by the
  Vision framework (`VNGenerateForegroundInstanceMaskRequest`,
  `VNGeneratePersonSegmentationRequest`, saliency, face landmarks) so masking stays fast on
  battery.
- **Metal compute for composite workflows.** Focus stacking, HDR merge (32-bit float, with
  ghost suppression), and panorama stitching (perspective / cylindrical / spherical) run as
  custom Metal compute kernels over unified memory.
- **Local catalog.** A SQLite catalog (folders, collections, keywords, ratings, labels, flags,
  history, snapshots, presets) lives under a user-chosen library location. Photos are
  referenced in place by default, with an optional managed-copy import.

## Repository layout

```
project.yml                  XcodeGen manifest — run `xcodegen generate` to produce Photon.xcodeproj
Packages/PhotonCore/         Platform-independent SwiftPM package: edit-state model, image math
                             (tone curve, HSL remap, colour grading, mask blending), preset XMP
                             serialisation. Unit-tested via `swift test`.
Photon/Sources/              The macOS app target (SwiftUI + AppKit interop)
  App/                       App entry, global state, module switching
  Catalog/                   SQLite catalog, import, folder scanning, thumbnails
  Rendering/                 CIRAWFilter decode, settings → CIImage graph, preview cache, tiling
  Shaders/                   Metal sources: CI kernels + compute kernels (stack/HDR/pano)
  Library/                   Grid, filmstrip, metadata, filter bar, import dialog
  Develop/                   All develop panels, curve editor, crop, heal, history
  Masking/                   Masking panel, Vision services, mask renderer
  Presets/                   Preset store and browser
  Composite/                 Focus stacking, HDR merge, panorama services
  Export/                    Batch export, naming templates, watermarking
Photon/Resources/            Assets, entitlements, Info.plist
```

## Building

Requires **macOS 14+ (Sonoma)**, **Xcode 15+**, and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate
open Photon.xcodeproj
```

The image-math core builds and tests anywhere Swift runs:

```sh
cd Packages/PhotonCore && swift test
```

## Design notes

- **Sky selection**: Vision has no public semantic sky segmentation request. Photon looks for a
  bundled Core ML segmentation model (`SkySegmentation.mlmodelc`) and routes it through the
  Neural Engine; when absent it falls back to a gradient/colour-prior heuristic and flags the
  mask as "approximate" in the UI. Subject/people/object masking use pure Vision APIs.
- **People sub-masks** (skin, hair, clothing, eyes, lips, teeth): built from
  `VNGeneratePersonSegmentationRequest` intersected with `VNDetectFaceLandmarksRequest`
  regions; documented per-part accuracy varies with pose, mirroring Lightroom's behaviour of
  refining these masks per image.
- **No network**: there is no networking code in the app target. The sandbox entitlements grant
  file access only (user-selected read/write + security-scoped bookmarks for the library and
  referenced folders).
