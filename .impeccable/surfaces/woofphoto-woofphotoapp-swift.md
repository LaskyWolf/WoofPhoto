---
version: 1
slug: "woofphoto-woofphotoapp-swift"
primary_target: "WoofPhoto/WoofPhotoApp.swift"
related_targets: []
---

# Surface: WoofPhoto app (all tabs)

Mode: Operate (photo library). Audience: Immich users on iPhone, one hand, often at night. Constraint: native iOS 26 controls and Photos gestures; WoofMusic identity first.

## Direction contract

THESIS: WoofPhoto is WoofMusic's sibling for photos. It refuses the stock Photos look (white bars, segmented controls, plain lists) and uses WoofMusic's home feed, with your photos as the colour.

OWN-WORLD: Black ground; secondarySystemBackground cards with 18pt corners; bold large titles in a custom header row with 36pt round icon buttons and the account avatar; capsule filter chips (40pt) filled with the user's accent from WoofMusic's 12 presets; cards shrink when pressed; icons move when tapped; Liquid Glass tab bar with Search as its own circle.

STORY: You scroll your library, open a photo, swipe it down into the mini viewer, keep browsing, and tap the mini viewer to return to it.

FIRST VIEWPORT: Library: header row ("Library", select, avatar), chips Years/Months/All, edge-to-edge grid with month titles, tab bar below with the mini viewer above it when a photo is open. Collections: header, chips, Keep Looking fanned stack, Memories as 3-column cards with titles on the photo, Trips as wide cards.

FORM: Home Feed, chosen by the user from three directions; seed: none (unavailable).

SIGNATURE: the mini viewer, a capsule above the tab bar holding the open photo (thumbnail, date, place, close). It opens with a zoom and folds back when you swipe down.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
