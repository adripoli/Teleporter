#!/bin/bash
# Installs the simplyteleporter CLI (and optionally Teleport.app) from a GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/adripoli/Teleporter/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/adripoli/Teleporter/main/install.sh | bash -s -- --app
#
# Nothing here needs sudo unless you point it at a directory that does.
set -euo pipefail

REPO="adripoli/Teleporter"
VERSION="${TELEPORT_VERSION:-latest}"
BIN_DIR="${TELEPORT_BIN_DIR:-}"
WANT_APP=0

for argument in "$@"; do
    case "$argument" in
        --app) WANT_APP=1 ;;
        --version=*) VERSION="${argument#--version=}" ;;
        --bin-dir=*) BIN_DIR="${argument#--bin-dir=}" ;;
        -h|--help)
            sed -n '2,8p' "$0" 2>/dev/null || true
            echo "  --app              also install Teleport.app into /Applications"
            echo "  --version=v1.0.0   install a specific release (default: latest)"
            echo "  --bin-dir=DIR      where to put simplyteleporter"
            exit 0
            ;;
        *) echo "unknown option: $argument" >&2; exit 2 ;;
    esac
done

say()  { printf '\033[1;35m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m  ! \033[0m%s\n' "$1"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

# --- Preflight --------------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "Teleport is macOS only (this is $(uname -s))."

# The app targets macOS 26. The CLI is built against the same SDK, so both need it.
MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$MAJOR" -lt 26 ]; then
    die "macOS 26 or later required (this is $(sw_vers -productVersion))."
fi

command -v curl >/dev/null || die "curl is required."

# --- Resolve the release ----------------------------------------------------------

if [ "$VERSION" = "latest" ]; then
    say "Looking up the latest release"
    # Read the tag out of the API response without taking a dependency on jq.
    VERSION="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
        | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
    [ -n "$VERSION" ] || die "Could not determine the latest release. Pass --version=vX.Y.Z."
fi

# Artifact names carry the bare version; the tag carries a leading v.
NUMBER="${VERSION#v}"
BASE="https://github.com/$REPO/releases/download/$VERSION"
TARBALL="simplyteleporter-$NUMBER-macos-universal.tar.gz"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

say "Downloading simplyteleporter $VERSION"
curl -fsSL "$BASE/$TARBALL" -o "$WORK/$TARBALL" \
    || die "Download failed. Check that $VERSION exists at https://github.com/$REPO/releases"

# Checksums are published with every release; refuse to install a file that doesn't match.
if curl -fsSL "$BASE/SHA256SUMS.txt" -o "$WORK/SHA256SUMS.txt" 2>/dev/null; then
    ( cd "$WORK" && grep " $TARBALL\$" SHA256SUMS.txt | shasum -a 256 -c --status - ) \
        || die "Checksum mismatch on $TARBALL — refusing to install."
    say "Checksum verified"
else
    warn "No SHA256SUMS.txt in this release; skipping checksum verification."
fi

tar -xzf "$WORK/$TARBALL" -C "$WORK"
[ -f "$WORK/simplyteleporter" ] || die "Archive did not contain simplyteleporter."

# --- Install the CLI --------------------------------------------------------------

# Prefer a directory already on PATH that we can write to, rather than reaching for sudo.
if [ -z "$BIN_DIR" ]; then
    if [ -w /usr/local/bin ] 2>/dev/null; then
        BIN_DIR="/usr/local/bin"
    else
        BIN_DIR="$HOME/.local/bin"
    fi
fi
mkdir -p "$BIN_DIR" || die "Cannot create $BIN_DIR"

install -m 755 "$WORK/simplyteleporter" "$BIN_DIR/simplyteleporter" \
    || die "Cannot write to $BIN_DIR. Re-run with --bin-dir=<somewhere writable>."

# Downloaded files carry a quarantine flag that makes Gatekeeper block an ad-hoc signed
# binary outright. Clearing it here is the whole reason this script beats a manual download.
xattr -d com.apple.quarantine "$BIN_DIR/simplyteleporter" 2>/dev/null || true

say "Installed $BIN_DIR/simplyteleporter"

# --- Install the app --------------------------------------------------------------

if [ "$WANT_APP" -eq 1 ]; then
    ZIP="Teleport-$NUMBER-macos-universal.zip"
    say "Downloading Teleport.app"
    curl -fsSL "$BASE/$ZIP" -o "$WORK/$ZIP" || die "Could not download $ZIP"
    ditto -x -k "$WORK/$ZIP" "$WORK/app"
    rm -rf "/Applications/Teleport.app"
    ditto "$WORK/app/Teleport.app" "/Applications/Teleport.app" \
        || die "Cannot write to /Applications."
    xattr -dr com.apple.quarantine "/Applications/Teleport.app" 2>/dev/null || true
    say "Installed /Applications/Teleport.app"
fi

# --- Post-install notes -----------------------------------------------------------

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        warn "$BIN_DIR is not on your PATH. Add it:"
        echo "      echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc && exec zsh"
        ;;
esac

# Teleport drives pymobiledevice3; without it the CLI starts and immediately stops.
if ! command -v pymobiledevice3 >/dev/null \
    && [ ! -x "$HOME/.local/bin/pymobiledevice3" ] \
    && [ ! -x /opt/homebrew/bin/pymobiledevice3 ] \
    && [ ! -x /usr/local/bin/pymobiledevice3 ]; then
    warn "pymobiledevice3 is not installed — Teleport needs it to talk to the phone:"
    echo "      pipx install pymobiledevice3"
fi

printf '\n\033[1;32mDone.\033[0m Plug in an unlocked iPhone and run: simplyteleporter\n\n'
