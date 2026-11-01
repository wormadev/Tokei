# Tokei

Menu bar AI plan usage (Claude, Codex) for macOS 26+, Liquid Glass UI. See SPEC.md.

## Build

- `xcodegen generate` after adding/removing files (project.yml is the source of truth; .xcodeproj is generated)
- `xcodebuild -project Tokei.xcodeproj -scheme Tokei -configuration Debug -derivedDataPath build build`
- Tests: `xcodebuild -project Tokei.xcodeproj -scheme Tokei -derivedDataPath build test`
- Release: every merge to main that touches `Sources/**` or `project.yml` ships a patch release through `.github/workflows/release.yml`, which runs `scripts/release.sh --publish`. Version is the latest tag plus one patch, or `MARKETING_VERSION` in project.yml when higher (raise it there for a minor/major). Notes: `release-notes/<version>.md` if present, else the feat/fix commit subjects since the last tag, so PR titles are user-facing. Build number is main's commit count. Developer ID signed and notarized. Repo secrets: `MACOS_CERT_P12` (Developer ID Application cert), `MACOS_CERT_PASSWORD`, `SPARKLE_ED_KEY`, `RELEASE_TOKEN`, `NOTARY_KEY` (App Store Connect API .p8), `NOTARY_KEY_ID`, `NOTARY_ISSUER`. Local fallback: `scripts/release.sh [--publish]` from a clean main; Sparkle EdDSA private key in the login Keychain, account `tokei`; notarytool keychain profile `tokei-notary`
- DMG: `scripts/dmg.sh` → `build/dmg/Tokei-<version>.dmg`, a local build signed with whatever identity Xcode picks and not notarized; release DMGs come from `release.sh`

## Site and video

- `site/`: static website (no build step). Same structure as WormaSounds' site; fonts Fraunces 600 headings, Instrument Sans body, self-hosted in `site/fonts`. Accent #32ADE6 (the icon's blue). Screenshots never show the account email: capture with `-show.account NO` and avoid the provider pages in Settings
- `video/`: Remotion promo (bun, not npm). Render: `bunx remotion render Promo out/tokei.mp4 --port=3917` (port 3000 is taken on this Mac). Copies go to `site/img/tokei.mp4` and `docs/images/demo.gif`
- Deploy: Dokploy project Tokei, app `tokei-site` (static, context `site`), redeploys on pushes to main touching `site/**` (GitHub webhook). Domain tokei.worma.dev stays HTTPS with Let's Encrypt; never switch it to HTTP. Bump `?v=` on asset URLs when a file changes: Cloudflare caches css, js, fonts, images and video
- `server/`: Bun + SQLite app `tokei-server` in the same Dokploy project, routed at tokei.worma.dev/api. `/api/appcast.xml` counts opted-in installs (random `id`, Sparkle profile) per day and 302s to the GitHub appcast; `/api/stats` is public totals. Never store IPs. Tests: `cd server && bun test`
- Homebrew: `wormadev/homebrew-tap`, cask `tokei`; `scripts/release.sh --publish` bumps it

## Design system

- One Liquid Glass surface: the panel. Content inside uses fills (`.fill.quaternary` cards), never glass on glass
- Font: SF (system). Accent: system accent only for small "on" states; usage bars use the system accent until 80% (orange) and 95% (red); pace is neutral unless it runs out (orange)
- Radius: panel 20, cards 8, inner 4. Spacing unit 4 (4/8/12)
- Type sizes: `.headline`, `.body`, `.callout`, `.caption`
- Limit row: name + pace ("10% in reserve · Lasts until reset", CodexBar wording), bar, then amount ("36% left") + "Resets in 1d 6h" (user's chosen layout)

## Constraints

- Every app-changing merge to main gets a release (CI does it): don't hand-bump `MARKETING_VERSION` for a patch, and don't run `release.sh --publish` by hand for a merge CI already released
- Never refresh Claude or Codex OAuth tokens: the refresh token belongs to the CLI and rotating it logs the CLI out
- Background refresh never triggers a Keychain prompt. Reading another app's Keychain item happens only after an explicit user action
- Tests use JSON fixtures, never live endpoints or real credentials
