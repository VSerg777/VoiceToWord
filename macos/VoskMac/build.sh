#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/macos/VoskWordListener.app"
PACKAGE="$ROOT/macos/VoskWordListener-macOS-universal.zip"
TMP="/private/tmp/vosk-word-listener-build"
rm -rf "$APP" "$TMP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$TMP/Contents/MacOS" "$TMP/Contents/Frameworks"
swiftc -parse-as-library -swift-version 5 -O -I "$ROOT/macos/VoskMac/Resources" -L "$ROOT/macos/VoskMac/Resources" -framework AppKit -framework AVFoundation -framework ApplicationServices -framework AudioToolbox -framework CoreAudio \
  "$ROOT/macos/VoskMac/main.swift" -o "$TMP/Contents/MacOS/VoskWordListener"
cp "$ROOT/macos/VoskMac/Resources/libvosk.dylib" "$TMP/Contents/Frameworks/libvosk.dylib"
install_name_tool -id @rpath/libvosk.dylib "$TMP/Contents/Frameworks/libvosk.dylib"
install_name_tool -change libvosk.dylib @rpath/libvosk.dylib "$TMP/Contents/MacOS/VoskWordListener"
install_name_tool -add_rpath @executable_path/../Frameworks "$TMP/Contents/MacOS/VoskWordListener"
cp "$ROOT/macos/VoskMac/Info.plist" "$TMP/Contents/Info.plist"
xattr -cr "$TMP"
codesign --force --deep --sign - "$TMP"
cp "$TMP/Contents/MacOS/VoskWordListener" "$APP/Contents/MacOS/VoskWordListener"
cp "$TMP/Contents/Frameworks/libvosk.dylib" "$APP/Contents/Frameworks/libvosk.dylib"
cp "$TMP/Contents/Info.plist" "$APP/Contents/Info.plist"
xattr -c "$APP" || true
xattr -c "$APP/Contents/Frameworks/libvosk.dylib" || true
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
"$ROOT/macos/VoskMac/package-mac.sh"
echo "Built $APP and $PACKAGE"
