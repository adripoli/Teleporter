#!/bin/bash
# Builds both front ends: the Teleport .app bundle, and the simplyteleporter CLI.
#
# SwiftPM emits bare executables; MapKit, the window chrome, and the Dock entry all
# need proper bundle structure and an Info.plist, so we wrap the GUI one here. The CLI
# needs none of that and is just copied next to this script.
#
#   ./build.sh                    release, host architecture only — the fast inner loop
#   ./build.sh debug              debug, host architecture only
#   ./build.sh release --universal   arm64 + x86_64, what ships in a release
set -euo pipefail

cd "$(dirname "$0")"

CONFIGURATION="release"
ARCH_FLAGS=()

for argument in "$@"; do
    case "$argument" in
        debug|release) CONFIGURATION="$argument" ;;
        --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
        *) echo "unknown argument: $argument" >&2; exit 2 ;;
    esac
done

APP="Teleport.app"

# macOS still ships bash 3.2, where "${array[@]}" on an *empty* array trips `set -u`.
# The `[@]+` guard expands to nothing at all in that case instead of erroring, so
# every use of ARCH_FLAGS below has to go through it.
echo "==> Building ($CONFIGURATION${ARCH_FLAGS:+, universal})"
swift build -c "$CONFIGURATION" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}

BIN_PATH="$(swift build -c "$CONFIGURATION" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/Teleport" "$APP/Contents/MacOS/Teleport"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature: enough for local use, and required for a hardened runtime-free launch.
# Deep, because a universal binary is signed per-slice and the bundle seal has to cover both.
echo "==> Signing"
codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "==> Copying simplyteleporter"
cp "$BIN_PATH/simplyteleporter" ./simplyteleporter
codesign --force --sign - --timestamp=none ./simplyteleporter >/dev/null 2>&1

echo "==> Done: $(pwd)/$APP"
echo "         $(pwd)/simplyteleporter"
