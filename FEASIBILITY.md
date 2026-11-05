# WoofPhoto: feasibility

## Verdict

The project is possible.

- A SwiftUI app on iOS 26 gets the stock look from system components: tab bar, Liquid Glass, zoom transitions, sheets, menus, SF Symbols.
- The Immich server already provides most of the data the Photos app shows: timeline, albums, people, places, smart search, memories, favorites, trash, locked folder, duplicates.
- Three areas need real engineering: Spatial Scenes, camera-roll backup, and working within the certificate's limits (memory, extensions, revokes).

## Approach: new SwiftUI app, official app kept for backup and editing

| | New SwiftUI app | Fork of the official Flutter app |
|---|---|---|
| Apple Photos look | System components: Liquid Glass, zoom transitions, scrolling and gestures match iOS exactly. | Flutter draws its own widgets. Cupertino widgets imitate iOS, and Liquid Glass and the native zoom transition are not available. |
| Features on day one | None; each screen is written. | All of them, including backup, sync and editing. |
| Upstream updates | The server API changes slowly and is versioned. | The mobile app gets large refactors every month; every restyled screen conflicts on merge. |
| Spatial Scenes | Swift and Metal directly. | A Flutter plugin wrapping the same Swift code. |
| Reuse | Patterns from WoofTube and WoofMusic, same build pipeline. | None. |

Decision: a new SwiftUI app.

- Backup from the camera roll and editing are out of scope. The official Immich app stays installed next to this one and keeps doing both. FlareStore has no app limit, so two apps cost nothing.
- Pets in People, Trips and memory movies are out of scope.
- Spatial Scenes is a port of the local web prototype (`prototype/spatial/index.html`), not new research.

Labels used below:
- **Verified**: checked in a primary source or in an existing repository.
- **Inference**: reasoned from evidence, not tested.
- **Unknown**: must be tested in a spike before the milestone that depends on it.

## Build and install

Reuse the WoofTube setup (**verified** in its repository):

- SwiftUI app, Xcode project generated from `project.yml` with XcodeGen.
- A GitHub Actions workflow on a `macos-26` runner builds an unsigned IPA. No Mac is needed.
- FlareStore signs and installs the IPA with your paid certificate.

## Feature map

Status values:
- **Ready**: the Immich API has it; only the iOS UI is missing.
- **On device**: no server support needed; iOS frameworks do it.
- **Partial**: Immich covers part of it.
- **Missing**: neither Immich nor iOS provides it; we build it.

| Apple Photos feature | Immich | Status | Notes |
|---|---|---|---|
| Library grid, Years / Months / All, pinch to change density | Timeline buckets (`/timeline/buckets`, `/timeline/bucket`) | Ready | Bucket responses are columnar and include thumbhashes for instant placeholders. |
| Library / Collections / Search tabs | — | On device | Plain `TabView`. |
| Viewer: paging, pinch zoom, swipe down to close, zoom transition | Thumbnail and original endpoints | Ready | `navigationTransition(.zoom)` gives the stock transition. |
| Info panel: date, camera, lens, map, caption | Asset EXIF and description | Ready | |
| Live Photos | Motion part stored as a linked video | Partial | **Unknown:** whether `PHLivePhoto` accepts the downloaded photo and video pair. Fallback: play the video on long press. |
| Favorites | Favorites | Ready | |
| Hidden album with Face ID | Locked folder (PIN) | Ready | Face ID via `LocalAuthentication` on top of the server PIN. |
| Recently Deleted | Trash | Ready | |
| Duplicates (merge) | Duplicate detection and resolve | Ready | |
| Albums, shared albums | Albums, shared albums, activity (likes, comments) | Ready | |
| People & Pets | People (faces) | Partial | Immich recognises people only. Pets are out of scope. |
| Memories (on this day) | Memories, birthday memories (v3.3) | Ready | |
| Memory movies with music and titles | — | Out of scope | — |
| Trips | — | Out of scope | — |
| Map / Places | Map markers, places | Ready | MapKit with clustered annotations. |
| Natural-language search | Smart search (CLIP), Search v2 (v3.2), OCR (v2.3) | Ready | |
| Live Text, Visual Look Up, subject lift | OCR text only | On device | VisionKit `ImageAnalysisInteraction` works on any image. |
| Editing: adjust, filters, crop | Mobile editing (v3.0) | Out of scope | Done in the official Immich app. |
| Spatial Scenes | — | Missing | Apple's API (`ImagePresentationComponent`) is visionOS only; Apple says it is not available on iOS. Port the web prototype from this folder. |
| Media types: Videos, Selfies, Portrait, Panoramas, Screenshots, RAW | Type and EXIF filters | Partial | Videos and RAW are direct filters. Selfies, portraits and panoramas need EXIF rules. |
| Utilities: Receipts, Handwriting, Illustrations, QR codes | Smart search queries | Partial | Saved CLIP queries; quality is lower than Apple's classifiers. |
| Pinned collections, customise and collapse sections | — | On device | Stored on device. |
| Shared Library | Partner sharing | Partial | Different model: partners share whole libraries, not a merged library. |
| Burst, RAW + JPEG grouping | Stacks | Ready | |
| Drag to multi-select | — | On device | |
| Slideshow, AirPlay | — | On device | AVKit. |
| Camera-roll backup | Upload endpoint, checksum dedup | Out of scope | Done in the official Immich app. |
| Device photos and server photos in one grid | — | Out of scope | Needs backup; the official app covers it. |
| Featured Photos widget | — | On device | Needs a widget extension and an App Group (see FlareStore section). |
| Use as wallpaper | — | On device | No public API. "Save to Photos" lets the user set it from Settings. |

The official Immich iOS app exists and is written in Flutter. This project gives the same server a native Photos look; it does not replace the server or the web app.

## Sideloading with FlareStore

The app is signed with a paid FlareStore certificate. FlareStore's FAQ states (**vendor claims**, not tested by us):

- No limit on the number of signed apps.
- The certificate is valid for one year from redemption.
- The certificate carries the full entitlement set, including app groups, keychain sharing, push notifications, iCloud and the increased memory limit. CarPlay and Apple Watch are excluded.
- Apps that need extra memory require a development certificate.
- Since v1.5.0, an app extension can get its own provisioning profile.

Background task identifiers already work with FlareStore in your KDE Connect fork (**verified** in that project).

| Problem | Impact | Mitigation |
|---|---|---|
| Apple can revoke the certificate. FlareStore offers no revoke protection plan. | The app stops opening, and backup stops with it. | Show "Last backup" on the Library header, and a banner when it is older than 3 days. |
| The certificate expires one year after redemption. | Same as a revoke, on a known date. | Re-sign before the date. |
| The increased memory limit needs a development certificate, according to the FAQ. | With a distribution certificate, iOS can close the app while it builds a Spatial Scene. The models peaked at about 300 MB (depth) and 600 MB (LaMa) in the desktop benchmark. | Sign with the development certificate if your plan includes it. In any case run the models one after the other, use quantized models, and fall back to the fast non-AI fill. |
| Extensions (widget, share extension) need their own profile and a shared App Group with the app. **Unknown:** whether FlareStore's per-extension profile keeps the App Group working. | The widget or "Upload to Immich" from the share sheet cannot read the login or the cache. | Test it in the M0 spike before building on it. |
| Changing the bundle ID breaks push and Keychain sharing for that copy. | None if the bundle ID stays the same. | Keep one fixed bundle ID; don't use FlareStore's custom bundle ID option for this app. |
| iOS decides when background tasks run. | Backup is slower than Apple's iCloud sync, which runs as a system service. | Upload on open and resume, plus `BGProcessingTask` while charging. This is the same limit the official app has. |
| An Immich server on the home network over plain HTTP is blocked by App Transport Security. | Login fails with a network error. | Add `NSAllowsLocalNetworking` and the Local Network usage text. Recommend HTTPS for access outside home. |
| The look copies Apple Photos. | Using system components is fine. Apple's Photos icon or name is not. | Name: WoofPhoto, with its own icon. |

## Spikes to run first

- [ ] Sign a hello-world IPA built by CI with FlareStore, including a widget extension that reads a value written by the app through the App Group.
- [ ] Log in and count the timeline months with `ImmichClient.swift`.
- [ ] Build a `PHLivePhoto` from a Live Photo downloaded from Immich.
- [ ] Run Depth Anything V2 Small and LaMa with ONNX Runtime on the oldest target iPhone, and record time and peak memory.

## Sources

- [Immich timeline API (generated client docs)](https://docs.rs/crate/immich_api_rs/latest/source/docs/TimelineApi.md)
- [Immich mobile backup](https://docs.immich.app/features/mobile-backup)
- [Immich FAQ (iOS background tasks)](https://docs.immich.app/FAQ/)
- [Immich release notes](https://releasebot.io/updates/immich)
- [Immich v2.3.0 release](https://immich.app/blog/v2.3.0-release)
- [iOS 26 Photos: tabs and Spatial Scenes (AppleInsider)](https://appleinsider.com/articles/25/06/12/photos-in-ios-26-brings-back-tabs-and-generates-spatial-photos)
- [iOS 26 Photos changes (9to5Mac)](https://9to5mac.com/2025/08/28/ios-26-fixed-the-photos-app-its-more-powerful-than-ever/)
- [Spatial3DImage availability](https://developer.apple.com/documentation/realitykit/imagepresentationcomponent/spatial3dimage.md)
- [Spatial scenes API on iOS (Apple forums)](https://developer.apple.com/forums/thread/831722)
- [Supported capabilities (iOS)](https://developer.apple.com/help/account/reference/supported-capabilities-ios)
- [FlareStore FAQ](https://flarestore.app/faq/)
- [FlareStore changelog](https://flarestore.app/changelog/)
- [FlareStore certificates](https://flarestore.app/certs/)
- [ImmichLens, a native Apple TV and Mac client](https://github.com/LavaToaster/immich-lens)
