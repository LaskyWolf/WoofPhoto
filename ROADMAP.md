# WoofPhoto roadmap

WoofPhoto is a native SwiftUI client for an Immich server that looks and behaves like the iOS 26 Photos app. It browses, searches and organises the library. Backup from the camera roll and editing stay in the official Immich app, installed next to this one. [FEASIBILITY.md](FEASIBILITY.md) has the feature map, the approach decision and the FlareStore limits.

## How to work through it

- Each milestone ends with an IPA signed with FlareStore and a check run on the iPhone. A milestone is done only when its check passes.
- Each milestone adds whole screens that work end to end (API, cache, UI). No milestone leaves half-built screens behind.
- Order: a complete gallery first (M1–M5), then Spatial Scenes (M6). M0 still runs the Core ML spike, so a memory problem shows up before M6 and not during it.
- Copy patterns from WoofTube and WoofMusic before writing new ones: tab bar, zoom transitions, image cache, settings screens, CI workflow.

## M0. Setup and spikes

- [x] Create the repository with `project.yml` (XcodeGen) and the CI workflow copied from WoofTube.
- [x] Write a small client for the endpoints in use (`ImmichClient.swift`). A generated client would need a build plugin, and every plugin problem costs a CI run from Linux.
- [ ] Spike: a widget extension reads a value the app wrote to the App Group, after FlareStore signing.
- [ ] Spike: build a `PHLivePhoto` from a Live Photo downloaded from Immich.
- [x] Spike: run Depth Anything V2 Small and LaMa with ONNX Runtime (the prototype's model files, no conversion) on the oldest target iPhone; record time and peak memory with the distribution and the development certificate.
- [ ] Write each spike result into FEASIBILITY.md.

**Check:** the CI IPA installs, logs in to your server and prints the number of timeline buckets.

## M1. Login and Library grid

- [ ] Server URL screen with a reachability test and an error that names the cause (wrong URL, HTTP blocked, server down).
- [ ] Login with email and password; store the token in the Keychain.
- [ ] Library tab: grid from timeline buckets, thumbhash placeholders, thumbnails loaded on scroll.
- [ ] Pinch to change density, and the Years / Months / All switch.
- [ ] Scrubber that jumps by month.
- [ ] Thumbnail disk cache with a size limit.

**Check:** a library of 10,000+ items scrolls from top to bottom with no blank cells after one second.

## M2. Viewer

- [ ] Zoom transition from grid to viewer and back to the same cell.
- [ ] Paging, double-tap and pinch zoom, swipe down to close.
- [ ] Video playback with the system controls.
- [ ] Live Photos (spike result from M0).
- [ ] Info panel: date, camera, lens, exposure, map, editable caption.
- [ ] Favorite, delete to trash, share sheet, save to the device.
- [ ] Live Text and Visual Look Up with VisionKit.
- [ ] "Edit in Immich" button that opens the official app, if it accepts a link to an asset; otherwise leave it out.

**Check:** open a photo, a video and a Live Photo; each opens from its cell and closes back into it.

## M3. Collections tab

- [ ] Albums: list, create, rename, add and remove items, shared albums with likes and comments.
- [ ] People: grid of faces, person page, rename, merge.
- [ ] Places: map with clustered photos.
- [ ] Memories row (on this day, birthdays).
- [ ] Favorites, Recently Added, Videos, Screenshots, RAW and the other media types.
- [ ] Utilities: Recently Deleted, Duplicates, Hidden (locked folder behind Face ID).
- [ ] Pinned collections; collapse, reorder and hide sections.

**Check:** every section opens, and edits made in the app appear in the Immich web app.

## M4. Search

- [ ] Smart search with results as you type.
- [ ] Suggestions for people, places and dates.
- [ ] Filters: media type, date range, camera, favorites.
- [ ] Text found by OCR in the results.

**Check:** searches for a person's name, a city, "beach" and a word printed in a photo each return the expected photos.

## M5. Selection and organising

- [ ] Drag across the grid to select.
- [ ] Actions on a selection: add to album, favorite, archive, hide, delete, share.
- [ ] Slideshow and AirPlay.

**Check:** select 50 items with one drag and add them to a new album; the album appears in the web app with all 50.

## M6. Spatial Scenes

Port of the web prototype (`prototype/spatial/index.html`). Each step reuses the prototype's logic; only the platform changes.

- [ ] Depth: Depth Anything V2 Small as a Core ML model, replacing Transformers.js.
- [ ] Layer split: depth snap, tears on the far side of sharp jumps, hole as wide as the maximum tilt, shadow band. Port `process()` to Swift with Accelerate for the box blur and erosion.
- [ ] Fast fill: port the push-pull `fill()` so a scene shows before the AI finishes.
- [ ] Inpainting: LaMa as a Core ML model on the hole's bounding box, replacing onnxruntime-web.
- [ ] Rendering: two displaced meshes (front with alpha, back layer) in Metal or RealityKit, with the prototype's shader.
- [ ] Motion: CoreMotion tilt replacing `DeviceOrientationEvent`; Reduce Motion turns it off.
- [ ] Loading animation from the prototype: scan sweep, depth rising, shimmer on rebuilt areas.
- [ ] Spatial button in the viewer's top bar, as in Photos.
- [ ] Cache the depth map and the filled background per asset, so a scene is built only once.
- [ ] Release each model after use; fall back to the fast fill when memory is low.

**Check:** on the oldest target iPhone, the cats test photo and your test drawings build in under 30 seconds without iOS closing the app, and match the web prototype's result.

## M7. Polish

- [ ] Featured Photos widget (needs the App Group spike from M0 to pass).
- [ ] Offline mode for photos already viewed.
- [ ] Dynamic Type, VoiceOver labels, Reduce Motion, Dark Mode.
- [ ] iPad layout with a sidebar.
- [ ] WoofPhoto app icon.

**Check:** a pass through all tabs with VoiceOver and the largest text size finds no unreadable or unreachable control.

## Out of scope

- Backup from the camera roll and editing: the official Immich app does both.
- Pets in People, Trips, memory movies.
