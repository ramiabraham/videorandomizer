#!/bin/bash
# Regenerates Icon/AppIcon.icns from make-icon.swift.
set -euo pipefail
cd "$(dirname "$0")"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SET="$TMP/AppIcon.iconset"
mkdir "$SET"
swift make-icon.swift "$TMP/icon.png"
for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$TMP/AppIcon.icns"
cp "$TMP/AppIcon.icns" AppIcon.icns
cp "$TMP/icon.png" AppIcon.png
