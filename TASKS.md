# Tasks

## v0.1
- [x] Providers: Claude, Codex (Cursor, Gemini, Copilot removed for now; in git history)
- [x] Refresher: persisted snapshots, stale-while-revalidate, refresh on panel open, backoff, 429, sleep/lock pause
- [x] Glass panel, status item with highest usage, right-click menu
- [x] Settings: General / Providers / Display
- [ ] Live check per provider with real accounts (Claude verified; Codex needs a fresh `codex` token)
- [x] App icon (Design/make-icon.swift)
- [x] Release pipeline: GitHub releases + Sparkle updates (scripts/release.sh)
- [ ] Developer ID signing + notarization (needs a Developer ID certificate)

- [x] Review fixes: Claude Connect/Keychain loss, multi-display panel, sleep vs lock, sign-out clears data, Gemini write-back race, Copilot save/cancel

## Later
- [x] Expired sign-in: dimmed rings + badge, notification, Fix button, no stale numbers past reset
- [x] Opt-in auto-renew, refresh at token expiry
- [x] Fix is unreliable (`claude auth status` doesn't renew by itself): Open Terminal fallback runs `claude`
- [ ] Check `codex login status` on a real Codex expiry (unverified)
- [x] Provider order in panel (drag or right-click in Settings)
- [x] Menu bar: icon, highest usage, or one provider
- [ ] Codex: optional token refresh with write-back to auth.json (CodexBar avoids it; risk of stranding a running CLI)

## Production readiness (review 2026-11-11)

App: providers and core
- [x] Banked resets per kind (5-hour, weekly, Fable, full) with a Reset per kind, instead of one summed count
- [x] `security` Keychain read gets a deadline; a hung read no longer blocks Claude refresh until relaunch
- [x] `cedar_ember` decodes leniently; a shape change can't break usage
- [x] 403 that isn't a JSON auth error is not "sign-in rejected"
- [x] Unique window ids (duplicate weekly/session entries)
- [x] `Executable.run` timeout: SIGKILL after grace, timeout is an error
- [x] Missing `expiresAt` is unknown, not expired
- [x] Clamp `Retry-After` to the 30 min cap
- [x] No auth header across cross-host redirects
- [x] More CLI install paths (nvm, volta, mise, asdf, pnpm, ~/.claude/local)

App: refresh and UI
- [x] Panel open refreshes despite a non-429 backoff
- [x] Renewal: 429 after renew is unknown, not expired; terminal poll honors retryAt
- [x] Main menu (Cmd-W, Cmd-C)
- [x] Close panel before Sparkle's window
- [x] Pace marker orange only when it runs out
- [x] Panel height and position from the status item's screen
- [x] Launch at login: no re-entrant toggle, requiresApproval hint
- [x] No "limit reset" alert from a stale snapshot or another account
- [x] No menu bar badge for a provider that was never signed in
- [x] Settings window deminiaturizes on show
- [x] VoiceOver labels: refresh, gear, usage bar, sidebar status dot
- [x] Status-page fetch outside the tracked refresh task
- [x] Banked-reset notice clears after the next successful refresh
- [x] Tests use their own UserDefaults, never live endpoints

Release
- [x] PR workflow: build + tests; tests before a release build
- [x] Release created before/with the tag, rerun-safe; cask bump retryable
- [x] Notes fallback for merges with no first-parent feat/fix
- [x] Pin actions by SHA, pin xcodegen and dmgbuild deps, scope GH_TOKEN
- [x] Job timeout, HEAD == origin/main check, cert cleanup

Server and site
- [x] Appcast redirect survives a failed DB write; NODE_ENV=production; healthcheck
- [x] Fetch-handler tests (302 on DB failure, 429, 404)
- [x] Remove "not notarized / Open Anyway" from site and README
- [x] Video respects reduced motion; og/twitter meta
- [x] Privacy page names Cloudflare as proxy; SPEC.md matches the app

Needs a decision
- [x] Settings redesign: pick a variant
- [x] Background Keychain read vs the "only after explicit user action" rule (Connect gate was removed in a7ea2fb; SPEC and CLAUDE.md still describe it)
- [x] Sign-in expiry notification on local token expiry can alert daily
- [x] Homebrew cask still strips quarantine (other repo)
- [x] main protected, CI checks `app` and `server` required (they first run on the PR that adds ci.yml)
- [ ] Dokploy: Requests logging off for tokei-server; origin reachable only via Cloudflare; uptime monitor on /api/appcast.xml
