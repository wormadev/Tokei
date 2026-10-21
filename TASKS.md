# Tasks

## v0.1
- [x] Providers: Claude, Codex (Cursor, Gemini, Copilot removed for now; in git history)
- [x] Refresher: persisted snapshots, stale-while-revalidate, refresh on panel open, backoff, 429, sleep/lock pause
- [x] Glass panel, status item with highest usage, right-click menu
- [x] Settings: General / Providers / Display
- [ ] Live check per provider with real accounts (Claude verified; Codex needs a fresh `codex` token)
- [x] App icon (Design/make-icon.swift)
- [ ] Release pipeline (Developer ID, notarize, Sparkle) like WormaSounds

- [x] Review fixes: Claude Connect/Keychain loss, multi-display panel, sleep vs lock, sign-out clears data, Gemini write-back race, Copilot save/cancel

## Later
- [x] Provider order in panel (drag or right-click in Settings)
- [x] Menu bar: icon, highest usage, or one provider
- [ ] Codex: optional token refresh with write-back to auth.json (CodexBar avoids it; risk of stranding a running CLI)
