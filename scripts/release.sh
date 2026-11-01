#!/bin/bash
# Release build into build/release/: Tokei.app in a DMG plus a Sparkle appcast signed with the
# EdDSA key under $SPARKLE_ACCOUNT. Apple Development signed, not notarized (no Developer ID yet):
# a first install from the DMG needs Privacy & Security > Open Anyway; Sparkle updates after that
# install without it, and the Homebrew cask strips the quarantine flag.
#
# Version: the latest v* tag plus one patch, or MARKETING_VERSION in project.yml when that is higher
# (raise it there for a minor or major release). Notes: release-notes/<version>.md if it exists, else
# the feat/fix commit subjects since the last tag. .github/workflows/release.yml runs this on merges.
# SPARKLE_KEY_FILE: sign the appcast with this EdDSA key file instead of the login keychain item.
#
#   release.sh [--notes FILE] [--first-release] [--publish]
#     --notes FILE        release notes, Markdown (default: release-notes/<version>.md, else generated)
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

# Next patch after the latest v* tag, or the project.yml floor when that is higher.
next_version() {
  local floor last next
  floor="$(project_setting MARKETING_VERSION)"
  last="$(git tag -l 'v*' --sort=-v:refname | head -1)"
  last="${last#v}"
  [[ -z "$last" ]] && { echo "$floor"; return; }
  next="$(echo "$last" | awk -F. '{ printf "%d.%d.%d", $1, $2, $3 + 1 }')"
  printf '%s\n%s\n' "$next" "$floor" | sort -V | tail -1
}

# feat/fix subjects since the last tag as Markdown bullets: "feat(x): add y (#3)" -> "- New: add y".
generated_notes() {
  local range
  range="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null)" && range="$range..HEAD" || range=HEAD
  git log --first-parent --format=%s "$range" |
    sed -nE -e 's/ \(#[0-9]+\)$//' -e 's/^feat(\([^)]*\))?!?: (.*)/- New: \2/p' -e 's/^fix(\([^)]*\))?!?: (.*)/- Fixed: \2/p'
}

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
[[ -n "$(project_setting MARKETING_VERSION)" ]] || fail "No MARKETING_VERSION in project.yml."
VERSION="$(next_version)"
# Sparkle compares CFBundleVersion: the commit count only grows on main.
BUILD="$(git rev-list --count HEAD)"
[[ -z "$NOTES" && -f "$REPO/release-notes/$VERSION.md" ]] && NOTES="$REPO/release-notes/$VERSION.md"
if [[ -z "$NOTES" ]]; then
  NOTES="$(mktemp)"
  generated_notes > "$NOTES"
  [[ -s "$NOTES" ]] || fail "No feat/fix commits since the last tag: nothing to release, or write release-notes/$VERSION.md."
fi
[[ -f "$NOTES" ]] || fail "No release notes at $NOTES."
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || fail "Tag v$VERSION already exists."
LAST="$(last_feed_build)"
(( BUILD > LAST )) || fail "Build $BUILD (commit count) is not above the live appcast's $LAST: Sparkle would ignore it."
echo "Version $VERSION, build $BUILD"
cat "$NOTES"

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
DMG="$OUT/updates/$APP_NAME-$VERSION.dmg"

step "Release build"
xcodegen generate >/dev/null
rm -rf "$OUT"
mkdir -p "$OUT/updates"
# Manual signing: automatic signing needs an Xcode account, which CI doesn't have.
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Development" build -quiet
codesign --verify --deep --strict "$APP"
[[ "$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")" == "$BUILD" ]] || fail "Built CFBundleVersion is not $BUILD."
[[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" == "$VERSION" ]] || fail "Built version is not $VERSION."
[[ "$(plutil -extract SUFeedURL raw "$APP/Contents/Info.plist")" == "$APP_FEED_URL" ]] || fail "$APP has a foreign SUFeedURL."

step "DMG"
uvx --from "$DMGBUILD" dmgbuild -s "$REPO/scripts/dmg-settings.py" -D app="$APP" "$APP_NAME" "$DMG"
hdiutil verify "$DMG" >/dev/null
# Unversioned copy for releases/latest/download/Tokei.dmg; kept out of updates/ so generate_appcast
# sees one archive.
cp "$DMG" "$OUT/$APP_NAME.dmg"

step "Appcast"
cp "$NOTES" "$OUT/updates/$APP_NAME-$VERSION.md"
if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then KEY_ARGS=(--ed-key-file "$SPARKLE_KEY_FILE"); else KEY_ARGS=(--account "$SPARKLE_ACCOUNT"); fi
"$SPARKLE_BIN/generate_appcast" "${KEY_ARGS[@]}" --embed-release-notes \
  --download-url-prefix "https://github.com/$REPO_SLUG/releases/download/v$VERSION/" "$OUT/updates"
grep -q 'sparkle-signatures:' "$OUT/updates/appcast.xml" ||
  fail "appcast.xml is not signed: is the $SPARKLE_ACCOUNT EdDSA key in the login keychain (or SPARKLE_KEY_FILE set)?"

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
