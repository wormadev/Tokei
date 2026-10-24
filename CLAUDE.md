# Tokei

Menu bar AI plan usage (Claude, Codex) for macOS 26+, Liquid Glass UI. See SPEC.md.

## Build

- `xcodegen generate` after adding/removing files (project.yml is the source of truth; .xcodeproj is generated)
- `xcodebuild -project Tokei.xcodeproj -scheme Tokei -configuration Debug -derivedDataPath build build`
- Tests: `xcodebuild -project Tokei.xcodeproj -scheme Tokei -derivedDataPath build test`
- Release: `scripts/release.sh [--first-release] [--publish]` from a clean main: needs `release-notes/<version>.md` and a bumped `MARKETING_VERSION`; build number is main's commit count. Sparkle EdDSA private key: login Keychain, account `tokei`
- DMG: `scripts/dmg.sh` → `build/dmg/Tokei-<version>.dmg`. Apple Development signed only (no Developer ID on this Mac yet), so it is not notarized: other Macs need Open Anyway in System Settings > Privacy & Security after the first launch (the Homebrew cask strips the quarantine flag instead)

## Site and video

- `site/`: static website (no build step). Same structure as WormaSounds' site; fonts Fraunces 600 headings, Instrument Sans body, self-hosted in `site/fonts`. Accent #32ADE6 (the icon's blue). Screenshots never show the account email: capture with `-show.account NO` and avoid the provider pages in Settings
- `video/`: Remotion promo (bun, not npm). Render: `bunx remotion render Promo out/tokei.mp4 --port=3917` (port 3000 is taken on this Mac). Copies go to `site/img/tokei.mp4` and `docs/images/demo.gif`
- Deploy: Dokploy project Tokei, app `tokei-site` (static, context `site`), redeploys on pushes to main touching `site/**` (GitHub webhook). Domain tokei.worma.dev stays HTTPS with Let's Encrypt; never switch it to HTTP. Bump `?v=` on asset URLs when a file changes: Cloudflare caches css, js, fonts, images and video
- Homebrew: `wormadev/homebrew-tap`, cask `tokei`; `scripts/release.sh --publish` bumps it

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
