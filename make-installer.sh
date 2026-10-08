#!/bin/bash
# Builds VideoRandomizer-<version>.pkg, a standard macOS installer that puts
# VideoRandomizer.app in /Applications (or ~/Applications for a single user).
# Set SIGN_ID="Developer ID Installer: Name (TEAMID)" to sign the package.
set -euo pipefail
cd "$(dirname "$0")"

APP=VideoRandomizer.app
ID=local.videorandomizer
[ -d "$APP" ] || ./build.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
PKG="VideoRandomizer-$VERSION.pkg"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Stage a clean copy: no AppleDouble files from volumes without extended attributes.
mkdir -p "$TMP/root/Applications" "$TMP/resources"
ditto --norsrc --noextattr "$APP" "$TMP/root/Applications/$APP"
find "$TMP/root" -name '._*' -delete
codesign --verify --strict "$TMP/root/Applications/$APP"

# Not relocatable: always install to Applications, even if another copy exists elsewhere.
cat > "$TMP/component.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
    <dict>
        <key>RootRelativeBundlePath</key><string>Applications/$APP</string>
        <key>BundleIsRelocatable</key><false/>
        <key>BundleIsVersionChecked</key><false/>
        <key>BundleHasStrictIdentifier</key><true/>
        <key>BundleOverwriteAction</key><string>upgrade</string>
    </dict>
</array>
</plist>
PLIST
pkgbuild --root "$TMP/root" --component-plist "$TMP/component.plist" \
    --identifier "$ID" --version "$VERSION" --install-location / \
    "$TMP/component.pkg" >/dev/null

cp LICENSE "$TMP/resources/LICENSE.txt"
cat > "$TMP/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>VideoRandomizer</title>
    <license file="LICENSE.txt"/>
    <options customize="never" hostArchitectures="arm64,x86_64"/>
    <domains enable_localSystem="true" enable_currentUserHome="true"/>
    <volume-check><allowed-os-versions><os-version min="12.0"/></allowed-os-versions></volume-check>
    <choices-outline><line choice="app"/></choices-outline>
    <choice id="app" visible="false"><pkg-ref id="$ID"/></choice>
    <pkg-ref id="$ID" version="$VERSION">component.pkg</pkg-ref>
</installer-gui-script>
XML
rm -f "$PKG"
productbuild --distribution "$TMP/distribution.xml" --package-path "$TMP" \
    --resources "$TMP/resources" ${SIGN_ID:+--sign "$SIGN_ID"} "$TMP/$PKG" >/dev/null
cp "$TMP/$PKG" "$PKG"
echo "Built $PWD/$PKG"
