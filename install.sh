#!/bin/bash
# Installs the latest Winnow release.
#   curl -fsSL https://raw.githubusercontent.com/chengffei/winnow/main/install.sh | bash
#
# Files downloaded with curl carry no quarantine flag, so macOS opens the app without the
# "unidentified developer" prompt. In exchange the script checks what it downloaded:
# the published SHA-256, a valid code signature, and the expected bundle ID and team.
set -euo pipefail

[ "$(uname -m)" = arm64 ] || { echo "error: Winnow needs a Mac with Apple silicon" >&2; exit 1; }

REPO="chengffei/winnow"
BUNDLE_ID="com.chengffei.winnow"
TEAM_ID="TWK29JGBQJ"
DEST="${WINNOW_INSTALL_DIR:-/Applications}"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Fixed asset names on the latest release; the GitHub API is rate-limited for anonymous use.
BASE="https://github.com/$REPO/releases/latest/download"
ZIP_NAME="Winnow.zip"

echo "==> Downloading the latest Winnow"
curl -fsSL "$BASE/$ZIP_NAME" -o "$WORK/$ZIP_NAME"
curl -fsSL "$BASE/Winnow.sha256" -o "$WORK/sums"
(cd "$WORK" && grep " $ZIP_NAME\$" sums | shasum -a 256 -c - >/dev/null) \
    || { echo "error: checksum does not match" >&2; exit 1; }

ditto -x -k "$WORK/$ZIP_NAME" "$WORK/unzipped"
APP="$WORK/unzipped/Winnow.app"
codesign --verify --deep --strict "$APP" 2>/dev/null || { echo "error: invalid code signature" >&2; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = "$BUNDLE_ID" ] \
    || { echo "error: unexpected bundle ID" >&2; exit 1; }
codesign -dv "$APP" 2>&1 | grep -q "TeamIdentifier=$TEAM_ID" || { echo "error: unexpected signer" >&2; exit 1; }

pkill -x Winnow 2>/dev/null && sleep 1 || true
rm -rf "$DEST/Winnow.app"
ditto "$APP" "$DEST/Winnow.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Winnow.app/Contents/Info.plist")
echo "==> Installed Winnow $VERSION in $DEST"
[ -n "${WINNOW_NO_OPEN:-}" ] || open "$DEST/Winnow.app"
