#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Builds NeuralBrowser with SwiftPM (release) and wraps it into
# build/NeuralBrowser.app with an Info.plist and an ad-hoc signature.
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/build/NeuralBrowser.app"
VERSION="${VERSION:-0.1.0}"

cd "$ROOT"
swift build -c "$CONFIG" 2>&1 | grep -E "error|warning:|Compiling|Build complete" | grep -v "^\[" || true
BIN="$(swift build -c "$CONFIG" --show-bin-path)/NeuralBrowser"
[ -x "$BIN" ] || { echo "build failed: $BIN missing" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/NeuralBrowser"
strip -x "$APP/Contents/MacOS/NeuralBrowser" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>org.neuralbrowser.app</string>
  <key>CFBundleName</key><string>NeuralBrowser</string>
  <key>CFBundleDisplayName</key><string>NeuralBrowser</string>
  <key>CFBundleExecutable</key><string>NeuralBrowser</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>LSMinimumSystemVersion</key><string>15.4</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>Web URL</string>
    <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
  </dict></array>
</dict>
</plist>
PLIST

# Ad-hoc signature (no developer account needed). Set ENTITLEMENTS=path to add some.
if [ -n "${ENTITLEMENTS:-}" ]; then
  codesign --force --sign - --timestamp=none --entitlements "$ENTITLEMENTS" "$APP"
else
  codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --strict "$APP" && echo "Built and signed: $APP ($(du -sh "$APP" | cut -f1))"
