#!/bin/bash
# Builds Teleport and assembles a real .app bundle.
#
# SwiftPM emits a bare executable; MapKit, the window chrome, and the Dock entry all
# need proper bundle structure and an Info.plist, so we wrap it here.
set -euo pipefail

cd "$(dirname "$0")"

CONFIGURATION="${1:-release}"
APP="Teleport.app"

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION"

BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/Teleport"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Teleport"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: enough for local use, and required for a hardened runtime-free launch.
echo "==> Signing"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "==> Done: $(pwd)/$APP"
