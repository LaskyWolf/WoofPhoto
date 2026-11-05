# WoofPhoto

A native SwiftUI client for an [Immich](https://immich.app) server, with every feature of Immich and of the iOS 26 Photos app, in a look that mixes Photos with WoofMusic.

The app is at milestone M1: the Library grid works; the M0 test screen sits behind the account button. [ROADMAP.md](ROADMAP.md) lists the milestones; [FEASIBILITY.md](FEASIBILITY.md) explains the decisions behind them.

## Install

You need iOS 26 or later.

1. Open the **Actions** tab of this repository and run the **Native app** workflow.
2. Download the `WoofPhoto-native` artifact from the finished run. It contains `WoofPhoto.ipa` and expires after one day.
3. Sign and install it with FlareStore. Keep the bundle ID `com.laskywolf.woofphoto`.

## Build on a Mac

You need Xcode 26.

```bash
brew install xcodegen
```

```bash
xcodegen generate && open WoofPhoto.xcodeproj
```

## M0 checks on the iPhone

1. Sign in with your Immich server address, email and password. Tap **Count Timeline**: it shows the number of months and items.
2. Tap **Write Value for the Widget**, then add the **WoofPhoto Check** widget to the Home Screen. It passes when it shows the same time and group as the app.
3. Open **Live Photo**. It passes when the photo plays while you touch and hold it.
4. Open **AI Models** and run both. Write down the times and the peak memory.

## Spatial Scenes prototype

`prototype/spatial` is the web version of Spatial Scenes that M3 ports to the app. To run it:

```bash
python3 prototype/spatial/serve.py
```

Then open http://localhost:8765.
