#!/bin/bash
# Builds VideoRandomizer.app (universal arm64 + x86_64, ad-hoc signed) next to this script.
# Requires only the Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")"

APP=VideoRandomizer.app
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for arch in arm64 x86_64; do
    swiftc -O -wmo -swift-version 5 -target "$arch-apple-macos12.0" \
        -framework AppKit -framework AVFoundation \
        Sources/*.swift -o "$TMP/VideoRandomizer-$arch"
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
lipo -create "$TMP"/VideoRandomizer-* -output "$APP/Contents/MacOS/VideoRandomizer"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>VideoRandomizer</string>
    <key>CFBundleDisplayName</key><string>VideoRandomizer</string>
    <key>CFBundleIdentifier</key><string>local.videorandomizer</string>
    <key>CFBundleExecutable</key><string>VideoRandomizer</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 ramiabraham. MIT License.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSRemovableVolumesUsageDescription</key><string>VideoRandomizer plays video clips stored on this volume.</string>
</dict>
</plist>
EOF

# Volumes without extended-attribute support (exFAT) leave AppleDouble files that break signing.
dot_clean -m "$APP" 2>/dev/null || true
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
