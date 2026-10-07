# 3D Model Creator

A macOS app that turns a folder of photos into a textured 3D model, using Apple's Object Capture photogrammetry (`PhotogrammetrySession` in RealityKit). Everything runs locally on your Mac.

It is built on Apple's sample [Building an object reconstruction app](https://developer.apple.com/documentation/realitykit/building-an-object-reconstruction-app) and replaces the sample's compact form with a full-window dark interface, a live model viewer and multi-format export.

## Features

- **Photos in, USDZ out** – pick or drag in a folder of HEIC, JPEG or PNG images and get a `.usdz` model.
- **Quality levels** – Preview, Reduced, Medium, Full and Raw, or a Custom level with your own polygon limit and texture resolution (1K–16K).
- **Several detail levels in one run** – processed from fastest to slowest, so the first model appears early.
- **Triangle or quad meshes.**
- **Object masking** – isolate the object or keep its surroundings.
- **iOS capture metadata** – detects depth, gravity and the capture bounding box, and lets you ignore the bounding box.
- **Live progress** – current stage, estimated time remaining, and cancel at any point.
- **Built-in viewer** – orbit the finished model without leaving the app.
- **Export** – USDZ, USDA, OBJ (with material and texture), STL, PLY and DAE.

## Requirements

- macOS 15 or later
- A Mac that supports Object Capture (Apple silicon recommended)
- Xcode 16 or later to build

## Getting started

```bash
git clone https://github.com/BoburToshpulatov/3D-Model-Creator.git
cd 3D-Model-Creator
open ObjectCaptureReconstruction.xcodeproj
```

In Xcode, select the `ObjectCaptureReconstruction` target, choose your team under **Signing & Capabilities**, then build and run.

## Usage

1. Choose the image folder, or drag it onto the Image Folder area.
2. Enter a model name and choose an output folder.
3. Pick the mesh type, quality and masking. The gear button opens the advanced options.
4. Click **Generate 3D Model**.
5. When the first model is ready, inspect it in the viewer, open the output folder in Finder, or click **Export Model** for another format.

Models are saved as `<name>-<detail>.usdz` in the output folder.

## Capture tips

- Take 50–100 sharp, overlapping photos from all around the object, including above and below.
- Use even, diffuse lighting and a plain surface. Shiny, transparent and very thin objects reconstruct poorly.
- Photos taken with guided Object Capture on iPhone or iPad include a bounding box and gravity, which give a cropped, upright model at real-world scale.
- For apps on Apple Vision Pro, Reduced or Medium detail is usually the right trade-off between quality and file size.

## Export formats

| Format | Written by | Notes |
|---|---|---|
| USDZ | Object Capture | The original output, ready for RealityKit and Quick Look |
| USDA | Model I/O | Text-based USD |
| OBJ | Model I/O | Exported as a folder with `.obj`, `.mtl` and the texture |
| STL | Model I/O | Geometry only, for 3D printing |
| PLY | Model I/O | Geometry only |
| DAE | SceneKit | COLLADA |

## Project layout

```
ObjectCaptureReconstruction/
├── ObjectCaptureReconstructionApp.swift   App, data model, views and export
├── Assets.xcassets                        App icon, accent color and symbols
└── ObjectCaptureReconstruction.entitlements
Configuration/SampleCode.xcconfig          Bundle identifier settings
```

The app is sandboxed and only reads and writes the folders you select.

## Limitations

- The **For developers** screen documents a proposed HTTP API for a server-side version of this pipeline. The app does not implement or call that API.
- Reconstruction time and memory use grow quickly with the number of photos and the detail level. Full and Raw can take a long time and produce very large files.

## Credits and license

Based on Apple's sample code from WWDC24 session 10107, [Discover Area Mode for Object Capture](https://developer.apple.com/wwdc24/10107/). Released under the MIT license; see [LICENSE.txt](LICENSE.txt).
