#!/bin/bash
# Renders design/appIcon.svg into Resources/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

# sips keeps the transparent padding around the squircle; qlmanage would paint it white.
sips -s format png -z 1024 1024 design/appIcon.svg --out "$WORK/master.png" >/dev/null
for spec in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x 128:icon_128x128 \
            256:icon_128x128@2x 256:icon_256x256 512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
    sips -z "${spec%%:*}" "${spec%%:*}" "$WORK/master.png" --out "$ICONSET/${spec##*:}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
