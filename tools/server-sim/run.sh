#!/bin/sh
# Runs WoofPhoto's server code (Shared/ImmichCore.swift, Models.swift, Matching.swift) against a mock Immich server.
# Needs Docker. Usage: tools/server-sim/run.sh
set -e
cd "$(dirname "$0")"
HERE=$(pwd)
ROOT=$(cd ../.. && pwd)
WORK=$(mktemp -d)
trap 'kill $MOCK 2>/dev/null; rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Sources/sim"
cp "$HERE/Package.swift" "$HERE/mock.py" "$WORK/"
HDR='#if canImport(FoundationNetworking)
import FoundationNetworking
#endif'
sed 's/^import os$//' "$ROOT/Shared/ImmichCore.swift" > "$WORK/Sources/sim/ImmichCore.swift"
cp "$ROOT/Shared/FileLog.swift" "$ROOT/WoofPhoto/Matching.swift" "$HERE/shims.swift" "$HERE/main.swift" "$WORK/Sources/sim/"
python3 -c "m=open('$ROOT/WoofPhoto/Models.swift').read(); open('$WORK/Sources/sim/Models.swift','w').write(m[:m.index('extension TimeBucket {')])"
for f in "$WORK"/Sources/sim/*.swift; do printf '%s\n' "$HDR" | cat - "$f" > "$f.tmp" && mv "$f.tmp" "$f"; done
cd "$WORK"
python3 mock.py 18283 >/dev/null 2>&1 &
MOCK=$!; sleep 1
docker run --rm --network host -v "$WORK":/w -w /w swift:6.0 swift run sim 18283 2>&1 | grep -v "warning:\|^ *[0-9]* |\|^ *|\|^\["
