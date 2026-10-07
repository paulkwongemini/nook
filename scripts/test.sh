#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
mkdir -p build/native-module-cache
swift_flags=(-swift-version 5 -module-cache-path build/native-module-cache -target "$(uname -m)-apple-macosx14.0")
xcrun swiftc "${swift_flags[@]}" Native/NavigationPolicy.swift NativeTests/main.swift -o build/native-policy-tests
build/native-policy-tests
node --test NativeTests/notifications.test.cjs
smoke="build/tests/Nook Smoke.app"
mkdir -p "$smoke/Contents/MacOS" "$smoke/Contents/Resources"
xcrun swiftc "${swift_flags[@]}" Native/NavigationPolicy.swift Native/ServiceIcons.swift Native/SidebarButton.swift Native/NotificationBridge.swift Native/Workspace.swift NativeTests/WebSmoke.swift -o "$smoke/Contents/MacOS/NookSmoke"
cp Native/Info.plist "$smoke/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.nook.native.tests' "$smoke/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable NookSmoke' "$smoke/Contents/Info.plist"
cp Native/Resources/notifications.js "$smoke/Contents/Resources/notifications.js"
cp Resources/AppIcon.icns "$smoke/Contents/Resources/AppIcon.icns"
mkdir -p "$smoke/Contents/Resources/ServiceIcons"
cp Native/Resources/ServiceIcons/*.png "$smoke/Contents/Resources/ServiceIcons/"
codesign --force --sign - "$smoke"
store_id="$(uuidgen)"
trap '"$smoke/Contents/MacOS/NookSmoke" cleanup "$store_id"' EXIT
"$smoke/Contents/MacOS/NookSmoke" write "$store_id"
"$smoke/Contents/MacOS/NookSmoke" read "$store_id"
