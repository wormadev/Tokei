#!/bin/bash
# Release build into build/release/: Tokei.app in a DMG plus a Sparkle appcast signed with the
# EdDSA key under $SPARKLE_ACCOUNT. Apple Development signed, not notarized (no Developer ID yet):
# a first install from the DMG needs Privacy & Security > Open Anyway; Sparkle updates after that
# install without it, and the Homebrew cask strips the quarantine flag.
#
#   release.sh [--notes FILE] [--first-release] [--publish]
#     --notes FILE        release notes, Markdown (default: release-notes/<version>.md)
#     --first-release     allow a missing (404) live appcast
#     --publish           tag v<version>, push the tag, create the GitHub release, bump the cask in $TAP_SLUG
set -euo pipefail

REPO_SLUG="wormadev/Tokei"
TAP_SLUG="wormadev/homebrew-tap"
FEED_URL="https://github.com/$REPO_SLUG/releases/latest/download/appcast.xml"
# What the app checks: counts opted-in installs (server/), then redirects to FEED_URL.
APP_FEED_URL="https://tokei.worma.dev/api/appcast.xml"
SPARKLE_ACCOUNT="tokei"
DMGBUILD="dmgbuild==1.6.7"
APP_NAME="Tokei"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$REPO/build/release"
DERIVED="$REPO/build/release-derived"
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"

PUBLISH=0
FIRST_RELEASE=0
NOTES=""
while (( $# )); do
  case "$1" in
    --notes) NOTES="${2:?--notes needs a file}"; shift 2 ;;
    --first-release) FIRST_RELEASE=1; shift ;;
    --publish) PUBLISH=1; shift ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
  esac
done

step() { echo; echo "== $*"; }
fail() { echo "$*" >&2; exit 1; }
project_setting() { sed -n "s/^ *$1: *\"\(.*\)\"$/\1/p" "$REPO/project.yml" | head -1; }

# Highest sparkle:version in the live appcast; 0 for a 404 only with --first-release.
last_feed_build() {
  local feed code
  feed="$(mktemp)"
  code="$(curl -sL -o "$feed" -w '%{http_code}' "$FEED_URL")" || fail "Can't fetch $FEED_URL."
  case "$code" in
    200) { grep -oE 'sparkle:version(>|=")[0-9]+' "$feed" | grep -oE '[0-9]+$'; echo 0; } | sort -n | tail -1 ;;
    404) [[ $FIRST_RELEASE == 1 ]] && echo 0 || fail "$FEED_URL returned 404: pass --first-release if no release exists yet." ;;
    *) fail "Fetching $FEED_URL returned HTTP $code." ;;
  esac
}

cd "$REPO"

step "Preconditions"
[[ -n "$(project_setting SPARKLE_PUBLIC_ED_KEY)" ]] || fail "SPARKLE_PUBLIC_ED_KEY in project.yml is empty."
grep -q "SPARKLE_FEED_URL: $APP_FEED_URL" project.yml || fail "SPARKLE_FEED_URL in project.yml is not $APP_FEED_URL."
[[ -z "$(git status --porcelain)" ]] || fail "Working tree has uncommitted changes: commit them so the tag matches the build."
[[ "$(git branch --show-current)" == main ]] || fail "Release from main: Sparkle's build number is main's commit count."
VERSION="$(project_setting MARKETING_VERSION)"
[[ -n "$VERSION" ]] || fail "No MARKETING_VERSION in project.yml."
# Sparkle compares CFBundleVersion: the commit count only grows on main.
BUILD="$(git rev-list --count HEAD)"
NOTES="${NOTES:-$REPO/release-notes/$VERSION.md}"
[[ -f "$NOTES" ]] || fail "No release notes at $NOTES: write them there (Markdown, committed) or pass --notes FILE."
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || fail "Tag v$VERSION already exists: bump MARKETING_VERSION in project.yml."
LAST="$(last_feed_build)"
(( BUILD > LAST )) || fail "Build $BUILD (commit count) is not above the live appcast's $LAST: Sparkle would ignore it."
echo "Version $VERSION, build $BUILD"

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
DMG="$OUT/updates/$APP_NAME-$VERSION.dmg"

step "Release build"
xcodegen generate >/dev/null
rm -rf "$OUT"
mkdir -p "$OUT/updates"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release -derivedDataPath "$DERIVED" \
  CURRENT_PROJECT_VERSION="$BUILD" build -quiet
codesign --verify --deep --strict "$APP"
[[ "$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")" == "$BUILD" ]] || fail "Built CFBundleVersion is not $BUILD."
[[ "$(plutil -extract SUFeedURL raw "$APP/Contents/Info.plist")" == "$APP_FEED_URL" ]] || fail "$APP has a foreign SUFeedURL."

step "DMG"
uvx --from "$DMGBUILD" dmgbuild -s "$REPO/scripts/dmg-settings.py" -D app="$APP" "$APP_NAME" "$DMG"
hdiutil verify "$DMG" >/dev/null
# Unversioned copy for releases/latest/download/Tokei.dmg; kept out of updates/ so generate_appcast
# sees one archive.
cp "$DMG" "$OUT/$APP_NAME.dmg"

step "Appcast"
cp "$NOTES" "$OUT/updates/$APP_NAME-$VERSION.md"
"$SPARKLE_BIN/generate_appcast" --account "$SPARKLE_ACCOUNT" --embed-release-notes \
  --download-url-prefix "https://github.com/$REPO_SLUG/releases/download/v$VERSION/" "$OUT/updates"
grep -q 'sparkle-signatures:' "$OUT/updates/appcast.xml" ||
  fail "appcast.xml is not signed: is the $SPARKLE_ACCOUNT EdDSA key in the login keychain?"

if [[ $PUBLISH == 0 ]]; then
  echo
  echo "Built $DMG ($VERSION, build $BUILD). Nothing was published; rerun with --publish."
  exit 0
fi

step "Publish"
git tag -a "v$VERSION" -m "$APP_NAME $VERSION ($BUILD)"
git push origin "v$VERSION"
gh release create "v$VERSION" --repo "$REPO_SLUG" --title "$APP_NAME $VERSION" --notes-file "$NOTES" \
  "$DMG" "$OUT/$APP_NAME.dmg" "$OUT/updates/appcast.xml"

step "Homebrew cask"
TAP="$OUT/tap"
gh repo clone "$TAP_SLUG" "$TAP" -- -q
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$TAP/Casks/tokei.rb"
git -C "$TAP" commit -qam "chore: tokei $VERSION"
git -C "$TAP" push -q
echo "Published $APP_NAME $VERSION: release, appcast and cask."
