#!/bin/bash
# Release build (Apple silicon only, like the bundled czkawka_cli), then dist/Winnow-<version>.dmg, .zip and .sha256.
set -e
cd "$(dirname "$0")/.."

scripts/bundle.sh --release

APP=build/Winnow.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
mkdir -p dist
DMG="dist/Winnow-$VERSION.dmg"
ZIP="dist/Winnow-$VERSION.zip"
STAGE=build/dmg
rm -rf "$STAGE" "$DMG" "$ZIP"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Winnow $VERSION" -srcfolder "$STAGE" -format UDZO -imagekey zlib-level=9 -quiet "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
# A fixed name too, so install.sh can use releases/latest/download/Winnow.zip without the rate-limited API.
cp "$ZIP" dist/Winnow.zip
rm -rf "$STAGE"
(cd dist && shasum -a 256 "Winnow-$VERSION.dmg" "Winnow-$VERSION.zip" Winnow.zip | tee "Winnow-$VERSION.sha256" > Winnow.sha256)
