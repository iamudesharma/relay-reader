#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEST="$ROOT/native"
CORE="$DEST/PhononCore.xcframework"
VERSION=v0.7.0
URL="https://github.com/gradium-ai/xn-ptts/releases/download/$VERSION/PhononCore.xcframework.zip"
SHA256=dfc50de08b15f32e2b18157ce83eff622a01ea2353d902593c1f823514fd8579

if [ -d "$CORE" ]; then
  echo "PhononCore.xcframework is already prepared."
  exit 0
fi

mkdir -p "$DEST"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/relay-phonon.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

echo "Downloading PhononCore.xcframework (~52 MB)…"
curl -L --fail --retry 3 --progress-bar -o "$TMP/core.zip" "$URL"

if command -v shasum >/dev/null 2>&1; then
  ACTUAL=$(shasum -a 256 "$TMP/core.zip" | awk '{print $1}')
else
  ACTUAL=$(sha256sum "$TMP/core.zip" | awk '{print $1}')
fi
if [ "$ACTUAL" != "$SHA256" ]; then
  echo "PhononCore checksum mismatch: expected $SHA256, got $ACTUAL" >&2
  exit 1
fi

unzip -q "$TMP/core.zip" -d "$TMP"
if [ ! -d "$TMP/PhononCore.xcframework" ]; then
  echo "PhononCore.xcframework was not found in the archive." >&2
  exit 1
fi
mv "$TMP/PhononCore.xcframework" "$CORE"
echo "PhononCore.xcframework is ready at $CORE"
