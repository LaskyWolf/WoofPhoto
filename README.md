<div align="center">

# WoofPhoto

**A native iPhone client for your Immich server.**

Browse, edit and back up your photos in an app that mixes Photos and WoofMusic.

</div>

---

## Features

- **Library.** One grid for photos on the server and on the iPhone. Pinch for density, Years / Months / All, a scrubber by month, a badge on items not backed up yet.
- **Viewer.** Zoom transition from the grid, paging, pinch and double-tap zoom, video, Live Photos (touch and hold), Live Text, info panel with map and caption.
- **Editor.** Adjust sliders, Auto, filters, crop and straighten, markup, Clean Up, video trim, Live Photo key frame. Edits save to the server and can be reverted.
- **Collections.** Albums, shared albums, People, Pets, Places, Memories and memory movies, Trips, media types, Utilities (receipts, QR codes), Duplicates, Archive, Recently Deleted, Hidden behind Face ID.
- **Search.** Smart search as you type, suggestions, filters, text found by OCR.
- **Backup.** Choose device albums, upload in the background, Wi-Fi or cellular, free up space after upload.
- **Also.** Featured Photos widget, "Upload to Immich" share extension, offline viewing, OAuth sign-in.

Milestones are in [ROADMAP.md](ROADMAP.md). Decisions are in [FEASIBILITY.md](FEASIBILITY.md). The product brief is in [PRODUCT.md](PRODUCT.md).

## Install

You need iOS 26 or later.

1. Open the **Actions** tab of this repository and run the **Native app** workflow.
2. Download the `WoofPhoto-native` artifact from the finished run. It holds `WoofPhoto.ipa` and expires after one day.
3. Sign and install it with FlareStore. Keep the bundle ID `com.laskywolf.woofphoto`.

## Build on a Mac

You need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate && open WoofPhoto.xcodeproj
```

`WoofPhoto.xcodeproj`, the Info.plist files and the entitlements files are generated from `project.yml`. Do not commit them.

## Diagnostics

Sign in with your server address, email and password. The account button opens the diagnostics screen:

- **Count Timeline** shows the number of months and items.
- **Write Value for the Widget** feeds the **WoofPhoto Check** widget. It passes when it shows the same time and group as the app.
- **Open a Live Photo from the Server** passes when the photo plays while you touch and hold it.
- **AI Models** times the on-device models and shows their peak memory.

## Spatial prototype (in progress)

`prototype/spatial/` is a web page that turns a photo into a 3D scene from a depth map. The app does not use it: Spatial Scenes were removed from the app.

The current work compares depth models (Depth Anything 3 Base, Depth Anything V2 Base and a mix of both), with sliders for relief and midtones.

```bash
python3 prototype/spatial/serve.py 8000
```

Open `http://localhost:8000`. The page loads its libraries and models from CDNs.

`prototype/spatial/sharp/` is a local Python server that makes splat files. It needs `torch`, `transformers`, `onnxruntime`, `scipy` and `Pillow`. The header of `server.py` shows how to start it.

## Tech stack

- Swift 5 mode, SwiftUI, Liquid Glass, iOS 26 deployment target.
- WidgetKit and a Share extension, linked to the app by an App Group.
- Vision, VisionKit, Core ML and PencilKit.
- XcodeGen for the project, GitHub Actions on `macos-26` for the build.
- A small hand-written client for the Immich API (`ImmichClient.swift`).

## Project structure

```
WoofPhoto/          the app: views, editor, backup, offline store
Shared/             code shared by the app and both extensions
WoofPhotoWidget/    Featured Photos widget
ShareExtension/     "Upload to Immich" share extension
design/icon/        app icon sources
prototype/spatial/  web prototype for Spatial Scenes
project.yml         XcodeGen project definition
```
