# Tokei

Menu bar AI plan usage (Claude, Codex) for macOS 26+, Liquid Glass UI. See SPEC.md.

## Build

- `xcodegen generate` after adding/removing files (project.yml is the source of truth; .xcodeproj is generated)
- `xcodebuild -project Tokei.xcodeproj -scheme Tokei -configuration Debug -derivedDataPath build build`
- Tests: `xcodebuild -project Tokei.xcodeproj -scheme Tokei -derivedDataPath build test`

## Design system

- One Liquid Glass surface: the panel. Content inside uses fills (`.fill.quaternary` cards), never glass on glass
- Font: SF (system). Accent: system accent only for small "on" states; usage bars are neutral until 80% (orange) and 95% (red)
- Radius: panel 20, cards 8, inner 4. Spacing unit 4 (4/8/12)
- Type sizes: `.headline`, `.body`, `.callout`, `.caption`

## Constraints

- Never refresh Claude or Codex OAuth tokens: the refresh token belongs to the CLI and rotating it logs the CLI out
- Background refresh never triggers a Keychain prompt. Reading another app's Keychain item happens only after an explicit user action
- Tests use JSON fixtures, never live endpoints or real credentials
