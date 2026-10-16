#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
mkdir -p build/native-module-cache
swift_flags=(-swift-version 5 -module-cache-path build/native-module-cache -target "$(uname -m)-apple-macosx14.0")
xcrun swiftc "${swift_flags[@]}" Native/NavigationPolicy.swift NativeTests/main.swift -o build/native-policy-tests
build/native-policy-tests
xcrun swiftc "${swift_flags[@]}" Native/CameraSettings.swift NativeTests/CameraSettingsTests.swift -o build/native-camera-settings-tests
build/native-camera-settings-tests
xcrun swiftc "${swift_flags[@]}" Native/CameraSettings.swift Native/CameraPTZ.swift NativeTests/CameraPTZTests.swift -o build/native-camera-ptz-tests
build/native-camera-ptz-tests
xcrun swiftc "${swift_flags[@]}" Native/CameraPiP.swift NativeTests/CameraPiPTests.swift -o build/native-camera-pip-tests
build/native-camera-pip-tests
xcrun swiftc "${swift_flags[@]}" Native/CameraVideoView.swift NativeTests/CameraVideoViewTests.swift -o build/native-camera-video-tests
build/native-camera-video-tests
connection_tests="build/tests/Camera Connection Tests.app"
mkdir -p "$connection_tests/Contents/MacOS"
xcrun swiftc "${swift_flags[@]}" Native/CameraSettings.swift Native/CameraControlsView.swift Native/CameraVideoView.swift Native/CameraView.swift NativeTests/CameraConnectionTests.swift -o "$connection_tests/Contents/MacOS/CameraConnectionTests"
cp Native/Info.plist "$connection_tests/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier local.nook.native.connection-tests.$(uuidgen)" "$connection_tests/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable CameraConnectionTests' "$connection_tests/Contents/Info.plist"
"$connection_tests/Contents/MacOS/CameraConnectionTests"
node --test NativeTests/notifications.test.cjs
# The optional playback checks use a local, silent fixture, never the user's camera.
if [[ "${NOOK_TEST_CAMERA:-0}" == "1" ]]; then
  ffmpeg -hide_banner -loglevel error -f lavfi -i 'testsrc=size=1280x720:rate=10' \
    -f lavfi -i 'anullsrc=r=44100:cl=mono' \
    -t 30 -c:v libx264 -pix_fmt yuv420p -c:a aac -y build/camera-fixture.mp4
fi
smoke="build/tests/Nook Smoke.app"
mkdir -p "$smoke/Contents/MacOS" "$smoke/Contents/Resources"
xcrun swiftc "${swift_flags[@]}" Native/NavigationPolicy.swift Native/ServiceIcons.swift Native/SidebarButton.swift Native/NotificationBridge.swift Native/CameraSettings.swift Native/CameraPTZ.swift Native/CameraControlsView.swift Native/CameraPlayer.swift Native/CameraVideoView.swift Native/CameraView.swift Native/CameraPiP.swift Native/Workspace.swift NativeTests/WebSmoke.swift -o "$smoke/Contents/MacOS/NookSmoke"
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

# Optional integration checks use installed VLC/FFmpeg and an isolated test Keychain item.
if [[ "${NOOK_TEST_CAMERA:-0}" == "1" ]]; then
  build/native-camera-settings-tests --keychain
  xcrun swiftc "${swift_flags[@]}" Native/CameraPlayer.swift NativeTests/CameraPlayerSmoke.swift -o build/native-camera-player-smoke
  build/native-camera-player-smoke build/camera-fixture.mp4
fi
