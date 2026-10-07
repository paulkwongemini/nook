#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
app_bundle="build/Nook.app"
mkdir -p build/native-module-cache "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
xcrun swiftc -swift-version 5 -O -whole-module-optimization \
  -module-cache-path build/native-module-cache \
  -target "$(uname -m)-apple-macosx14.0" \
  Native/*.swift -o "$app_bundle/Contents/MacOS/Nook"
cp Native/Info.plist "$app_bundle/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_bundle/Contents/Resources/AppIcon.icns"
cp Native/Resources/notifications.js "$app_bundle/Contents/Resources/notifications.js"
mkdir -p "$app_bundle/Contents/Resources/ServiceIcons"
cp Native/Resources/ServiceIcons/*.png "$app_bundle/Contents/Resources/ServiceIcons/"
plutil -lint "$app_bundle/Contents/Info.plist"
codesign --force --sign - "$app_bundle"
codesign --verify --strict "$app_bundle"
printf 'Built: %s/%s\n' "$PWD" "$app_bundle"
