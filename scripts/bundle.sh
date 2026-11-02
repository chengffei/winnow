#!/bin/bash
# Builds build/Winnow.app with the pinned czkawka_cli inside. Usage: scripts/bundle.sh [--release] [--open]
set -e
cd "$(dirname "$0")/.."

CONFIG=debug
OPEN=0
for arg in "$@"; do
    case "$arg" in
        --release) CONFIG=release ;;
        --open) OPEN=1 ;;
    esac
done

# SwiftPM from Command Line Tools lacks the SwiftUI macro plugins; use Xcode's toolchain.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
swift build -c "$CONFIG" --product WinnowApp
scripts/fetch-cli.sh

APP=build/Winnow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/WinnowApp" "$APP/Contents/MacOS/Winnow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/ThirdPartyNotices.txt Resources/AppIcon.icns "$APP/Contents/Resources/"
cp ThirdParty/czkawka_cli "$APP/Contents/Resources/czkawka_cli"

IDENTITY=$(security find-identity -v -p codesigning | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"')
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP/Contents/Resources/czkawka_cli"
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with ${IDENTITY:-ad-hoc})"

if [ "$OPEN" = 1 ]; then
    pkill -f "$PWD/$APP/Contents/MacOS/Winnow" || true
    open "$APP"
fi
