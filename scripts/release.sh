#!/bin/bash
# Release build into build/release/: Tokei.app in a DMG plus a Sparkle appcast signed with the
# EdDSA key under $SPARKLE_ACCOUNT. Developer ID signed and notarized, so the DMG opens without a
# Gatekeeper prompt.
#
# Version: the latest v* tag plus one patch, or MARKETING_VERSION in project.yml when that is higher
# (raise it there for a minor or major release). Notes: release-notes/<version>.md if it exists, else
# the feat/fix commit subjects since the last tag. .github/workflows/release.yml runs this on merges.
# SPARKLE_KEY_FILE: sign the appcast with this EdDSA key file instead of the login keychain item.
# NOTARY_KEY_FILE, NOTARY_KEY_ID, NOTARY_ISSUER: App Store Connect API key for notarytool; unset, it
# uses the "$NOTARY_PROFILE" keychain profile (xcrun notarytool store-credentials).
#
#   release.sh [--notes FILE] [--first-release] [--publish]
#     --notes FILE        release notes, Markdown (default: release-notes/<version>.md, else generated)
#     --first-release     allow a missing (404) live appcast
#     --publish           create the GitHub release and its v<version> tag, bump the cask in $TAP_SLUG
#
# Rerunning --publish is safe: before the release is published nothing is tagged, so a rerun redoes the
# same version; once HEAD carries a v* tag, a rerun only bumps the cask.
set -euo pipefail

REPO_SLUG="wormadev/Tokei"
TAP_SLUG="wormadev/homebrew-tap"
FEED_URL="https://github.com/$REPO_SLUG/releases/latest/download/appcast.xml"
# What the app checks: counts opted-in installs (server/), then redirects to FEED_URL.
APP_FEED_URL="https://tokei.worma.dev/api/appcast.xml"
SPARKLE_ACCOUNT="tokei"
DMGBUILD=(--from "dmgbuild==1.6.7" --with "ds-store==1.3.3" --with "mac-alias==2.2.3")
APP_NAME="Tokei"
SIGN_IDENTITY="Developer ID Application"
NOTARY_PROFILE="tokei-notary"

# CI passes the token here, unexported, so xcodebuild, uvx and their packages never see it.
RELEASE_TOKEN="${RELEASE_TOKEN:-}"
export -n RELEASE_TOKEN

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
with_token() { if [[ -n "$RELEASE_TOKEN" ]]; then GH_TOKEN="$RELEASE_TOKEN" "$@"; else "$@"; fi; }
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

# "feat(x): add y (#3)" -> "- New: add y"; drops everything but feat/fix.
as_bullets() {
  sed -nE -e 's/ \(#[0-9]+\)$//' -e 's/^feat(\([^)]*\))?!?: (.*)/- New: \2/p' -e 's/^fix(\([^)]*\))?!?: (.*)/- Fixed: \2/p'
}

# feat/fix subjects since the last tag as Markdown bullets, else a generic line.
generated_notes() {
  local range notes
  range="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null)" && range="$range..HEAD" || range=HEAD
  # Squash merges carry the PR title in the subject, merge commits in the body.
  notes="$(git log --first-parent --format='%s%n%b' "$range" | as_bullets)"
  # A plain merge of feat/fix commits has neither: look at every commit.
  [[ -n "$notes" ]] || notes="$(git log --format='%s' "$range" | as_bullets)"
  [[ -n "$notes" ]] || notes="- Maintenance and reliability improvements."
  echo "$notes"
}

# Idempotent, so a rerun can retry a failed push.
bump_cask() {
  local dmg="$1" tap="$OUT/tap" sha
  rm -rf "$tap"
  with_token gh repo clone "$TAP_SLUG" "$tap" -- -q
  sha="$(shasum -a 256 "$dmg" | cut -d' ' -f1)"
  sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$sha\"/" "$tap/Casks/tokei.rb"
  if git -C "$tap" diff --quiet; then echo "Cask is already at $VERSION."; return; fi
  git -C "$tap" commit -qam "chore: tokei $VERSION"
  with_token git -C "$tap" push -q
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
git fetch -q origin --tags
[[ -n "${CI:-}" || "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] ||
  fail "HEAD is not origin/main: pull or push first so the release is what main has."
PUBLISHED="$(git tag --points-at HEAD --list 'v*' | sort -V | tail -1)"
if [[ $PUBLISH == 1 && -n "$PUBLISHED" ]]; then
  VERSION="${PUBLISHED#v}"
  step "Homebrew cask ($PUBLISHED is already released from HEAD)"
  mkdir -p "$OUT/published"
  with_token gh release download "$PUBLISHED" --repo "$REPO_SLUG" --pattern "$APP_NAME-$VERSION.dmg" \
    --dir "$OUT/published" --clobber
  bump_cask "$OUT/published/$APP_NAME-$VERSION.dmg"
  echo "Bumped the cask to $APP_NAME $VERSION."
  exit 0
fi
[[ -n "$(project_setting MARKETING_VERSION)" ]] || fail "No MARKETING_VERSION in project.yml."
VERSION="$(next_version)"
# Sparkle compares CFBundleVersion: the commit count only grows on main.
BUILD="$(git rev-list --count HEAD)"
[[ -z "$NOTES" && -f "$REPO/release-notes/$VERSION.md" ]] && NOTES="$REPO/release-notes/$VERSION.md"
if [[ -z "$NOTES" ]]; then
  NOTES="$(mktemp)"
  generated_notes > "$NOTES"
fi
[[ -f "$NOTES" ]] || fail "No release notes at $NOTES."
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || fail "Tag v$VERSION already exists."
LAST="$(last_feed_build)"
(( BUILD > LAST )) || fail "Build $BUILD (commit count) is not above the live appcast's $LAST: Sparkle would ignore it."
echo "Version $VERSION, build $BUILD"
cat "$NOTES"

APP="$DERIVED/Build/Products/Release/$APP_NAME.app"
DMG="$OUT/updates/$APP_NAME-$VERSION.dmg"

step "Tests"
xcodegen generate >/dev/null
# Unsigned: CI has no Xcode account for the Automatic signing that Debug uses.
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO test -quiet

step "Release build"
rm -rf "$OUT"
mkdir -p "$OUT/updates"
# Manual signing: automatic signing needs an Xcode account, which CI doesn't have.
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGN_IDENTITY" OTHER_CODE_SIGN_FLAGS=--timestamp \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build -quiet
# Xcode leaves Sparkle's helpers ad-hoc signed, which notarization rejects: sign inside out, then the app.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
for code in "$SPARKLE_FW"/Versions/B/XPCServices/*.xpc "$SPARKLE_FW/Versions/B/Autoupdate" \
  "$SPARKLE_FW/Versions/B/Updater.app" "$SPARKLE_FW" "$APP"; do
  codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime --preserve-metadata=entitlements "$code"
done
codesign --verify --deep --strict "$APP"
[[ "$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist")" == "$BUILD" ]] || fail "Built CFBundleVersion is not $BUILD."
[[ "$(plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")" == "$VERSION" ]] || fail "Built version is not $VERSION."
[[ "$(plutil -extract SUFeedURL raw "$APP/Contents/Info.plist")" == "$APP_FEED_URL" ]] || fail "$APP has a foreign SUFeedURL."

step "DMG"
uvx "${DMGBUILD[@]}" dmgbuild -s "$REPO/scripts/dmg-settings.py" -D app="$APP" "$APP_NAME" "$DMG"
hdiutil verify "$DMG" >/dev/null
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

step "Notarize"
if [[ -n "${NOTARY_KEY_FILE:-}" ]]; then
  NOTARY_ARGS=(--key "$NOTARY_KEY_FILE" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
else
  NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
fi
xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait | tee "$OUT/notary.log"
grep -q "status: Accepted" "$OUT/notary.log" || fail "Notarization was not accepted (xcrun notarytool log <id> ${NOTARY_ARGS[*]})."
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature "$DMG" || fail "Gatekeeper rejects $DMG."
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
# gh uploads to a draft and publishes last, so a failed upload leaves a draft and no tag.
for id in $(with_token gh api "repos/$REPO_SLUG/releases" --jq ".[] | select(.draft and .tag_name == \"v$VERSION\") | .id"); do
  with_token gh api -X DELETE "repos/$REPO_SLUG/releases/$id" >/dev/null
done
# GitHub creates the tag when the release is published, not before.
with_token gh release create "v$VERSION" --repo "$REPO_SLUG" --target "$(git rev-parse HEAD)" \
  --title "$APP_NAME $VERSION" --notes-file "$NOTES" "$DMG" "$OUT/$APP_NAME.dmg" "$OUT/updates/appcast.xml"
git fetch -q origin --tags

step "Homebrew cask"
bump_cask "$DMG"
echo "Published $APP_NAME $VERSION: release, appcast and cask."
