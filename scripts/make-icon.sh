#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
MASTER="$PWD/assets/CooyeyeIcon-1024.png"
[[ -f "$MASTER" ]] || { echo "Missing icon: $MASTER" >&2; exit 1; }
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
ICONSET="$TMP/CooyeyeIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 128 256 512; do
  sips -s format png -z "$SIZE" "$SIZE" "$MASTER" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE=$((SIZE*2))
  sips -s format png -z "$DOUBLE" "$DOUBLE" "$MASTER" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$PWD/assets/CooyeyeIcon.icns"
echo "Generated assets/CooyeyeIcon.icns"
