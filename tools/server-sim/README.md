# Server simulation

Runs the app's Immich code on Linux against a mock server shaped after Immich's OpenAPI spec:
error messages, upload integrity, connection failures, and how an iPhone photo is matched with the server's copy
(by capture time, and by checksum). `fixtures.json` is made by `mock.py` on start.

```sh
tools/server-sim/run.sh
```

It needs Docker and compiles `Shared/ImmichCore.swift`, `WoofPhoto/Models.swift` and `WoofPhoto/Matching.swift`
with stand-ins for the iOS-only pieces (`shims.swift`). PhotoKit, SwiftUI and the Timeline are not covered.
