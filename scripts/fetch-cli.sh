#!/bin/bash
# Downloads the pinned czkawka_cli release into ThirdParty/ (not in git, 25 MB).
set -e
cd "$(dirname "$0")/.."
VERSION=12.0.2
OUT=ThirdParty/czkawka_cli
[ -x "$OUT" ] && "$OUT" --version 2>/dev/null | grep -q "$VERSION" && exit 0
curl -fsSL -o "$OUT" "https://github.com/qarmin/czkawka/releases/download/$VERSION/mac_czkawka_cli_arm64"
chmod +x "$OUT"
xattr -c "$OUT" 2>/dev/null || true
"$OUT" --version | head -1
