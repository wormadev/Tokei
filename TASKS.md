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
- [ ] Fix is unreliable: `claude auth status` doesn't renew by itself. Decide on a fallback (open Terminal with `claude`)
- [ ] Check `codex login status` on a real Codex expiry (unverified)
- [x] Provider order in panel (drag or right-click in Settings)
- [x] Menu bar: icon, highest usage, or one provider
- [ ] Codex: optional token refresh with write-back to auth.json (CodexBar avoids it; risk of stranding a running CLI)
