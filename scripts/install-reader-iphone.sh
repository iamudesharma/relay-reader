#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEVICE=${READER_IPHONE_ID:-00008140-001405121462401C}
BUNDLE=${READER_BUNDLE_ID:-com.relay.relayReader}
FLUTTER=${FLUTTER:-flutter}
APP="$ROOT/build/ios/iphoneos/Runner.app"

cd "$ROOT"
"$FLUTTER" build ios --release
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE"

echo
echo "Relay Reader is installed. Launch it from the iPhone home screen."
echo "To update, rerun this script; normal use does not require Flutter."
