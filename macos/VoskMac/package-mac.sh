#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/macos/VoskWordListener.app"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/vosk-mac-package.XXXXXX")"
mkdir -p "$STAGE/VoskWordListener/VoskWordListener.app/Contents/MacOS" "$STAGE/VoskWordListener/VoskWordListener.app/Contents/Frameworks"
cp "$APP/Contents/MacOS/VoskWordListener" "$STAGE/VoskWordListener/VoskWordListener.app/Contents/MacOS/"
cp "$APP/Contents/Frameworks/libvosk.dylib" "$STAGE/VoskWordListener/VoskWordListener.app/Contents/Frameworks/"
cp "$APP/Contents/Info.plist" "$STAGE/VoskWordListener/VoskWordListener.app/Contents/"
cp "$ROOT/macos/VoskMac/README-RU.md" "$STAGE/VoskWordListener/Instructions-Mac-RU.md"
cp "$ROOT/macos/VoskMac/THIRD-PARTY.md" "$STAGE/VoskWordListener/Third-Party-Licenses.md"
xattr -c "$STAGE/VoskWordListener/VoskWordListener.app" || true
codesign --force --deep --sign - "$STAGE/VoskWordListener/VoskWordListener.app"
codesign --verify --deep --strict "$STAGE/VoskWordListener/VoskWordListener.app"
cd "$STAGE"
/usr/bin/zip -qry "$ROOT/macos/VoskWordListener-macOS-universal.zip" VoskWordListener
