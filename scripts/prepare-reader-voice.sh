#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODEL="$ROOT/models/kokoro-int8-v1"
ASSETS="$ROOT/assets/kokoro-v1"
SOURCE=https://huggingface.co/csukuangfj/kokoro-int8-multi-lang-v1_0/resolve/57adb37fc0e8d4bd430cfc1b8f8c2294945b9af2

mkdir -p "$MODEL" "$ASSETS"
while read -r hash name; do
  if ! printf '%s  %s\n' "$hash" "$MODEL/$name" | shasum -a 256 -c --status; then
    curl --retry 2 -fLsS "$SOURCE/$name" -o "$MODEL/$name.partial"
    printf '%s  %s\n' "$hash" "$MODEL/$name.partial" | shasum -a 256 -c --status
    mv "$MODEL/$name.partial" "$MODEL/$name"
  fi
  cp "$MODEL/$name" "$ASSETS/$name"
done <<'HASHES'
75635ea3b85a32d00094dcdd61a258aba87c160f7c264c304a7b3ae9d734195e model.int8.onnx
1c5a5b983d3d50d8586d437a51f3faa2da7919ce76a013c081e65671a3447c29 voices.bin
6ebb6bb288f20f3ae8d004d3c2ca27697da27c037d75e81a60e2a6a663f95425 tokens.txt
7daaab53a181be9885b853a8582bf1838186317e5dadacbcef9c426d6fa0da14 lexicon-us-en.txt
c4cbb37316f62210dff52718a7afcaae24f50c032cc75ab47ae67b831d1049e7 lexicon-gb-en.txt
cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30 LICENSE
HASHES
printf '%s\n' "Kokoro assets prepared in $ASSETS"
