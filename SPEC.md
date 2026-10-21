# Quota

Menu bar app showing AI coding plan usage for Claude, Codex, Cursor, Gemini and Copilot. A from-scratch replacement for CodexBar (MIT, used as reference for endpoints only, no code copied). macOS 26+, Liquid Glass.

## Goals

- Show at a glance: session (5h) and weekly usage per provider, reset time, account email and plan.
- Everything else is opt-in via Settings > Display: spend/credits, per-model limits, 7-day history sparkline, absolute reset times.
- Refresh that is fast, quiet and visible:
  - Last snapshot persisted to disk and shown instantly on launch.
  - Values never blank out during a refresh (stale-while-revalidate); rows have fixed layout, numbers animate.
  - Opening the panel refreshes any provider older than 60 s. Manual refresh button + Cmd-R. "Updated 2m ago" per provider.
  - Background interval configurable (default 5 min). Paused while the screen is locked or the Mac sleeps. Exponential backoff on errors (max 30 min); 429 honours Retry-After.
  - No surprise Keychain prompts: background refresh never triggers one. Claude's Keychain read only after the user clicks Connect in Settings.
- Settings: one window, three tabs (General, Providers, Display). Every setting is a plain toggle or picker.

## Non-goals

- No token refresh for Claude/Codex: their refresh tokens belong to the CLIs and rotating them breaks the CLI. Expired token -> "Run `claude`" / "Run `codex`".
- No browser cookie import, no CLI/PTY scraping, no widgets, no Sparkle (yet), no other providers.

## Data sources

| Provider | Credential | Endpoint |
|---|---|---|
| Claude | `~/.claude/.credentials.json` if unexpired, else Keychain `Claude Code-credentials` (after Connect) | `GET api.anthropic.com/api/oauth/usage` (+ `/api/oauth/profile` for email), header `anthropic-beta: oauth-2025-04-20` |
| Codex | `$CODEX_HOME/auth.json` or `~/.codex/auth.json` | `GET chatgpt.com/backend-api/wham/usage`, `ChatGPT-Account-Id` |
| Cursor | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, key `cursorAuth/accessToken` | `GET cursor.com/api/usage-summary`, `/api/auth/me`, cookie `WorkosCursorSessionToken=<sub>%3A%3A<jwt>` |
| Gemini | `~/.gemini/oauth_creds.json`; refresh with client id/secret from env or the installed gemini-cli package | `POST cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`, `:retrieveUserQuota` |
| Copilot | Own GitHub device flow (client `Iv1.b507a08c87ecfe98`, scope `read:user`), token in own Keychain item | `GET api.github.com/copilot_internal/user`, `/user` |

## Architecture

- `Sources/Core`: models, HTTP helper, JWT, Keychain, snapshot store.
- `Sources/Providers`: one `UsageProvider` per service: read credentials, fetch, map to `Snapshot`.
- `Sources/App`: `Refresher` (scheduling, backoff, persistence), status item + glass panel, settings window.
- `Sources/UI`: SwiftUI views.
- Tests: parser tests against JSON fixtures, refresher scheduling tests. No live network in tests.
