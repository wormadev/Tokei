# Tokei

Menu bar AI plan usage (Claude, Codex) for macOS 26+, Liquid Glass UI. See SPEC.md.

## Build

- `xcodegen generate` after adding/removing files (project.yml is the source of truth; .xcodeproj is generated)
- `xcodebuild -project Tokei.xcodeproj -scheme Tokei -configuration Debug -derivedDataPath build build`
- Tests: `xcodebuild -project Tokei.xcodeproj -scheme Tokei -derivedDataPath build test`
- Release: `scripts/release.sh [--first-release] [--publish]` from a clean main: needs `release-notes/<version>.md` and a bumped `MARKETING_VERSION`; build number is main's commit count. Sparkle EdDSA private key: login Keychain, account `tokei`
- DMG: `scripts/dmg.sh` → `build/dmg/Tokei-<version>.dmg`. Apple Development signed only (no Developer ID on this Mac yet), so it is not notarized and other Macs need right-click > Open

## Design system

- One Liquid Glass surface: the panel. Content inside uses fills (`.fill.quaternary` cards), never glass on glass
- Font: SF (system). Accent: system accent only for small "on" states; usage bars use the system accent until 80% (orange) and 95% (red); pace is neutral unless it runs out (orange)
- Radius: panel 20, cards 8, inner 4. Spacing unit 4 (4/8/12)
- Type sizes: `.headline`, `.body`, `.callout`, `.caption`
- Limit row: name + pace ("10% in reserve · Lasts until reset", CodexBar wording), bar, then amount ("36% left") + "Resets in 1d 6h" (user's chosen layout)

## Constraints

- Never refresh Claude or Codex OAuth tokens: the refresh token belongs to the CLI and rotating it logs the CLI out
- Background refresh never triggers a Keychain prompt. Reading another app's Keychain item happens only after an explicit user action
- Tests use JSON fixtures, never live endpoints or real credentials
