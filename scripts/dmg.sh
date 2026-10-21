#!/usr/bin/env bash
# Builds Release and packages build/dmg/Tokei-<version>.dmg (app + Applications link).
# Signed with whatever identity Xcode picks (Apple Development today): not notarized, so other
# Macs need right-click > Open the first time. Developer ID + notarytool would remove that.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
VERSION="$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml | head -1)"
OUT="$REPO/build/dmg"
DMG="$OUT/Tokei-$VERSION.dmg"

xcodegen generate >/dev/null
xcodebuild -project Tokei.xcodeproj -scheme Tokei -configuration Release -derivedDataPath build build -quiet
APP="$REPO/build/Build/Products/Release/Tokei.app"
codesign --verify --deep --strict "$APP"

mkdir -p "$OUT"
rm -f "$DMG"
uvx --from "dmgbuild==1.6.7" dmgbuild -s "$REPO/scripts/dmg-settings.py" -D app="$APP" Tokei "$DMG"
hdiutil verify "$DMG" >/dev/null
echo "$DMG"
