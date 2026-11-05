# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

People who run their own Immich server and want to browse, edit and back up their photos on an iPhone. The app is released publicly on GitHub and sideloaded (FlareStore and similar), so users are strangers to the developer: every text, default and error must make sense without help.

## Product Purpose

A native SwiftUI client for Immich with every feature of Immich and of the iOS 26 Photos app: library timeline, viewer for photos, videos and Live Photos, editing, albums, people and pets, memories, places, trips, search, hidden and trash, backup from the device, a widget, offline viewing. Success: a user can leave the Photos app and use WoofPhoto as their only gallery.

## Positioning

A sibling of WoofMusic (the same developer's YouTube Music client): it carries WoofMusic's identity, while its gestures and structure stay familiar to Photos users. Spatial Scenes (M3) are planned as its own feature.

## Operating Context

- Used one-handed on an iPhone, often in the dark, scrolling large libraries (10,000+ items).
- The server is reached over the internet, a VPN such as Tailscale, or a LAN; the connection can drop, so offline states are common.
- Photos are the user's private content and may be sensitive. The interface must never describe, label or share content on its own.

## Capabilities and Constraints

- iOS 26 and later; SwiftUI; Liquid Glass system components.
- Built only in CI (no local Xcode); verification happens on the developer's iPhone, not in a simulator.
- The Immich API decides what data exists; the app does not invent metadata.
- Milestones: M1 every feature (done), M2 design and fixes, M3 Spatial Scenes.

## Brand Commitments

- WoofMusic comes first: WoofPhoto must feel like a sibling of WoofMusic (`~/Applications/WoofMusic`). Apple Photos lends the grid, viewer and gestures.
- The name is WoofPhoto.

## Evidence on Hand

- WoofMusic's source, design tokens, screenshots (`~/Applications/WoofMusic/.github/assets/`) and app icons (`~/Applications/WoofMusic/Trop/App Icons/`).
- No testimonials, user counts or press exist; none may be invented.

## Product Principles

1. Photos lead; the interface steps back while someone is looking at their pictures.
2. Every screen is finished: loading, empty, offline and error states are designed, not left as defaults.
3. Familiar gestures from Photos; WoofMusic's identity in everything else.
4. Nothing breaks for a stranger: defaults work on any Immich server, and every failure says what to do.

## Accessibility & Inclusion

Dynamic Type, VoiceOver labels, Reduce Motion, and Dark and Light Mode, as listed in the M2 roadmap.
