# WoofPhoto roadmap

WoofPhoto is a native SwiftUI client for an Immich server. It has every feature of Immich and of the iOS 26 Photos app, including backup from the camera roll and editing. Its look mixes the Photos app with WoofMusic. [FEASIBILITY.md](FEASIBILITY.md) has the feature map, the approach decision and the FlareStore limits.

## How to work through it

- Each milestone ends with an IPA signed with FlareStore and a check run on the iPhone. A milestone is done only when its check passes.
- Order: every feature working (M1), then design and fixes (M2), then Spatial Scenes (M3).
- M1 uses plain system components. M2 restyles them, so M1 spends no time on visual detail.
- Copy patterns from WoofTube and WoofMusic before writing new ones: tab bar, zoom transitions, image cache, settings screens, CI workflow.

## M0. Setup and spikes

- [x] Create the repository with `project.yml` (XcodeGen) and the CI workflow copied from WoofTube.
- [x] Write a small client for the endpoints in use (`ImmichClient.swift`). A generated client would need a build plugin, and every plugin problem costs a CI run from Linux.
- [x] Spike: a widget extension reads a value the app wrote to the App Group, after FlareStore signing.
- [x] Spike: build a `PHLivePhoto` from a Live Photo downloaded from Immich.
- [x] Spike: run Depth Anything V2 Small and LaMa with ONNX Runtime (the prototype's model files, no conversion) on the oldest target iPhone; record time and peak memory with the distribution and the development certificate.
- [x] Write each spike result into FEASIBILITY.md.

**Check:** the CI IPA installs, logs in to your server and prints the number of timeline buckets.

## M1. Every feature

### Sign-in

- [x] Server address with an error that names the cause (wrong URL, HTTP blocked, server down, VPN off).
- [x] Login with email and password; token in the Keychain.
- [ ] Sign out, switch server, and sign-in with OAuth if the server offers it.

### Library

- [ ] Grid from timeline buckets, thumbhash placeholders, thumbnails loaded on scroll. Fix: cells stay grey on the iPhone.
- [x] Pinch to change density.
- [x] Thumbnail disk cache with a size limit.
- [ ] Years / Months / All switch.
- [ ] Scrubber that jumps by month.
- [ ] Photos on the device and on the server in one grid, with a badge for items not backed up yet.

### Viewer

- [ ] Zoom transition from grid to viewer and back to the same cell.
- [ ] Paging, double-tap and pinch zoom, swipe down to close.
- [ ] Video playback with the system controls.
- [ ] Live Photos: touch and hold to play.
- [ ] Info panel: date, camera, lens, exposure, map, editable caption, people in the photo.
- [ ] Favorite, delete to trash, hide, share sheet, save to the device, copy.
- [ ] Live Text and Visual Look Up with VisionKit.
- [ ] Bursts and RAW + JPEG pairs shown as one stack.

### Editing

- [ ] Adjust (exposure, contrast, saturation, warmth and the other Photos sliders), filters, crop, rotate, straighten.
- [ ] Save the edit to the server and revert to the original.
- [ ] Trim videos; choose a Live Photo's key frame and turn its motion off.

### Collections

- [ ] Albums: list, create, rename, reorder, add and remove items, cover photo.
- [ ] Shared albums with likes and comments; partner sharing.
- [ ] People: grid of faces, person page, rename, merge, hide, set birthday.
- [ ] Pets: detect cats and dogs on the device and group them like People.
- [ ] Places: map with clustered photos.
- [ ] Memories: on this day and birthdays from the server.
- [ ] Memory movies: a slideshow video with music and titles, made on the device.
- [ ] Trips: photos taken far from home, grouped by place and date.
- [ ] Favorites, Recently Saved, Videos, Selfies, Portrait, Panoramas, Screenshots, RAW and the other media types.
- [ ] Utilities: Receipts, Handwriting, Illustrations, QR codes.
- [ ] Recently Deleted with restore and delete forever.
- [ ] Duplicates: compare and merge.
- [ ] Hidden: the locked folder behind Face ID.
- [ ] Archive.
- [ ] Pinned collections; collapse, reorder and hide sections.

### Search

- [ ] Smart search with results as you type.
- [ ] Suggestions for people, places and dates.
- [ ] Filters: media type, date range, camera, favorites.
- [ ] Text found by OCR in the results.

### Selection

- [ ] Drag across the grid to select.
- [ ] Actions on a selection: add to album, favorite, archive, hide, delete, share, download.
- [ ] Slideshow and AirPlay.

### Backup

- [ ] Choose the device albums to back up; upload new photos and videos with checksum dedup.
- [ ] Upload in the background, on Wi-Fi only or also on cellular, and only while charging if chosen.
- [ ] Progress, errors and a list of what is left.
- [ ] Free up space: delete from the device what the server already has.

### Other

- [ ] Featured Photos widget.
- [ ] Offline mode for photos already viewed.
- [ ] Settings: server, account, storage used by the cache, backup options.

**Check:** every item above works on the iPhone against your server, and edits made in the app appear in the Immich web app.

## M2. Design and fixes

- [ ] Design direction that mixes the iOS 26 Photos app with WoofMusic: read WoofMusic's views and write the result into DESIGN.md before restyling any screen.
- [ ] Restyle every M1 screen to that direction.
- [ ] App icon.
- [ ] Fix the bugs found while using M1.
- [ ] Performance: a library of 10,000+ items scrolls from top to bottom with no blank cells after one second.
- [ ] Dynamic Type, VoiceOver labels, Reduce Motion, Dark Mode.
- [ ] iPad layout with a sidebar.

**Check:** a pass through all tabs with VoiceOver and the largest text size finds no unreadable or unreachable control, and the 10,000-item scroll passes.

## M3. Spatial Scenes

Port of the web prototype (`prototype/spatial/index.html`). Each step reuses the prototype's logic; only the platform changes.

- [ ] Depth: Depth Anything V2 Small with ONNX Runtime (M0 spike), replacing Transformers.js.
- [ ] Layer split: depth snap, tears on the far side of sharp jumps, hole as wide as the maximum tilt, shadow band. Port `process()` to Swift with Accelerate for the box blur and erosion.
- [ ] Fast fill: port the push-pull `fill()` so a scene shows before the AI finishes.
- [ ] Inpainting: LaMa with ONNX Runtime on the hole's bounding box, replacing onnxruntime-web.
- [ ] Rendering: two displaced meshes (front with alpha, back layer) in Metal or RealityKit, with the prototype's shader.
- [ ] Motion: CoreMotion tilt replacing `DeviceOrientationEvent`; Reduce Motion turns it off.
- [ ] Loading animation from the prototype: scan sweep, depth rising, shimmer on rebuilt areas.
- [ ] Spatial button in the viewer's top bar, as in Photos.
- [ ] Cache the depth map and the filled background per asset, so a scene is built only once.
- [ ] Release each model after use; fall back to the fast fill when memory is low.

**Check:** on the oldest target iPhone, the cats test photo and your test drawings build in under 30 seconds without iOS closing the app, and match the web prototype's result.
