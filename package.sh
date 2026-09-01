#!/bin/bash
# Builds universal binaries and lays out everything a GitHub release needs in dist/:
#
#   Teleport-<version>.dmg                          drag-to-Applications disk image
#   Teleport-<version>-macos-universal.zip          the same .app, for scripted installs
#   simplyteleporter-<version>-macos-universal.tar.gz   the CLI on its own
#   SHA256SUMS.txt                                  checksums over all three
#
# The .app ships in both shapes on purpose: humans want the DMG, and install.sh wants a
# zip it can unpack without mounting anything.
set -euo pipefail

cd "$(dirname "$0")"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DIST="dist"
STAGE="$DIST/.stage"

echo "==> Packaging Teleport $VERSION"

./build.sh release --universal

# Refuse to ship a single-architecture build by accident: the whole point of the release
# artifacts is that they run natively on both Apple Silicon and Intel.
for binary in "Teleport.app/Contents/MacOS/Teleport" "simplyteleporter"; do
    if ! lipo -archs "$binary" | grep -q arm64 || ! lipo -archs "$binary" | grep -q x86_64; then
        echo "error: $binary is not universal (got: $(lipo -archs "$binary"))" >&2
        exit 1
    fi
done
echo "==> Verified universal: $(lipo -archs simplyteleporter)"

rm -rf "$DIST"
mkdir -p "$STAGE"

# --- Disk image -------------------------------------------------------------------
# The Applications symlink is what turns the mounted window into a drag-and-drop install.
echo "==> Building disk image"
DMG_ROOT="$STAGE/dmg"
mkdir -p "$DMG_ROOT"
cp -R "Teleport.app" "$DMG_ROOT/"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create \
    -volname "Teleport $VERSION" \
    -srcfolder "$DMG_ROOT" \
    -ov -format UDZO \
    "$DIST/Teleport-$VERSION.dmg" >/dev/null

# --- Archives ---------------------------------------------------------------------
# ditto rather than zip: it is the only one that preserves the code signature and the
# bundle's symlinks intact, so the unzipped .app still launches.
echo "==> Building archives"
ditto -c -k --sequesterRsrc --keepParent \
    "Teleport.app" "$DIST/Teleport-$VERSION-macos-universal.zip"

CLI_ROOT="$STAGE/cli"
mkdir -p "$CLI_ROOT"
cp "simplyteleporter" "$CLI_ROOT/"
tar -czf "$DIST/simplyteleporter-$VERSION-macos-universal.tar.gz" -C "$CLI_ROOT" simplyteleporter

# --- Checksums --------------------------------------------------------------------
rm -rf "$STAGE"
# Named explicitly rather than globbed, so the checksum file can never end up
# listing itself and the set is obvious from reading the script.
( cd "$DIST" && shasum -a 256 \
    "Teleport-$VERSION.dmg" \
    "Teleport-$VERSION-macos-universal.zip" \
    "simplyteleporter-$VERSION-macos-universal.tar.gz" \
    > SHA256SUMS.txt )

echo "==> Done"
ls -lh "$DIST"
