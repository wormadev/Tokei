# Tasks

## v0.1
- [x] Providers: Claude, Codex, Cursor, Gemini, Copilot (fixture-tested parsers)
- [x] Refresher: persisted snapshots, stale-while-revalidate, refresh on panel open, backoff, 429, sleep/lock pause
- [x] Glass panel, status item with highest usage, right-click menu
- [x] Settings: General / Providers / Display
- [ ] Live check per provider with real accounts (needs user: Claude Connect, Copilot sign-in, fresh `codex` token)
- [ ] App icon
- [ ] Release pipeline (Developer ID, notarize, Sparkle) like WormaSounds

## Later
- [ ] Provider order in panel (drag in Settings)
- [ ] Gemini: newer gemini-cli may keep creds in Keychain service "gemini" (seen on this Mac); unconfirmed
- [ ] Codex: optional token refresh with write-back to auth.json (CodexBar avoids it; risk of stranding a running CLI)
