# Plan: UI polish, refresh redesign, settings rework, feature ideas

Status: planning only, no code. Written against main at c084aaf (0.1.3). Each item is small enough for one PR and has checks a reviewer can tick. Order inside each part is the build order.

Priority across parts: refresh first (it touches trust in the numbers), then UI polish, then settings, then features.

## 1. Refresh redesign

Today: a refresh button with a rotating icon in the header, a per-provider "now / 2m ago" label, a mini spinner per card, an "Agent aware" background picker (every 5 min while an agent works, 15 min idle), an on/off "Refresh when opening the panel" toggle, exponential backoff to 30 min, 429 waits 5 min.

Problems found:
- SPEC says opening the panel refreshes anything older than 60 s; the code calls `refreshStale()` with its 120 s default (StatusBarController.swift:73, Refresher.swift:88). One of them is wrong.
- Three spinners can show at once (header icon, card spinner, row spinner). The header icon spins while any provider loads, so a slow Codex call makes Claude look stale.
- Failures already show "Couldn't update · retrying in 4m" with the error on hover (PanelView.swift:141). 429 gets the same wording as any other failure.
- "Refresh when opening the panel" off is a trap: the panel shows old numbers with no hint. In the screenshot it is off.

R1. One loading signal per provider. The header button only spins for a manual refresh and stops when all providers finish. Cards show progress by fading the "ago" label to "Updating..." instead of a spinner. Numbers never blank (stale-while-revalidate stays).
- [ ] Manual refresh: header icon spins, then stops when the last provider answers
- [ ] Background refresh: no header spin; the card's label reads "Updating..." then "now"
- [ ] No layout shift during a refresh (row heights equal before and after, screenshot diff)

R2. Name the rate limit. Keep the existing "Couldn't update · retrying in ..." line; for a 429 say "Rate limited · retrying in 5m" so the user knows waiting is the fix.
- [ ] Fixture 429 response: label reads "Rate limited", retry time matches Retry-After (min 5 min)
- [ ] Offline refresh still reads "Couldn't update" and the numbers stay

R3. Settle the open-panel rule. Open the panel: refresh any provider older than 60 s (SPEC value) and drop the toggle (see S2). A user who wants zero network can pick "Never" in background refresh, which also turns off refresh-on-open.
- [ ] Open the panel 30 s after a refresh: no request (check the log)
- [ ] Open the panel 90 s after: one request per enabled provider
- [ ] "Never": opening the panel sends nothing; the manual button still works

R4. Refresh near a reset. When a window resets within the next interval, schedule a refresh 30 s after the reset time so the bar drops to 0 right away instead of showing "unknown" for up to 15 min.
- [ ] Session resetting in 2 min with a 15-min interval: the new number shows within 1 min of the reset
- [ ] Refresher scheduling test covers it with a fixture (no live network)

## 2. UI polish (panel)

Seen in docs/images/panel-full.png:
- The session sparkline is spiky and taller in feel than the bars; three sparklines stack into a lot of grey.
- Every row repeats "· Lasts until reset", which is noise when everything is fine.
- The pace text sits on the title line and competes with it; "2% in reserve" is hard to read.
- The footer "Claude Code this week 100%" has no explanation.
- The header title "Tokei" uses space the provider name already gives.

U1. Quieter pace. Show the pace phrase only when it says something: hide "Lasts until reset" when it lasts; show "Runs out in 1d 2h" in orange when it doesn't. Keep "x% in reserve" as a hover. (Design note in CLAUDE.md names the CodexBar wording; the user picked that layout, so this needs his yes before building.)
- [ ] Healthy row: title line shows only the name
- [ ] Row on pace to run out: orange "Runs out in ..." on the title line
- [ ] Pace toggle in Display still hides it entirely

U2. Calmer sparklines. One height (16 pt), smoothed line, no fill, drawn under the bar at 50% opacity; the session sparkline covers the current 5 h window only.
- [ ] All sparklines the same height; panel height drops (screenshot before/after)
- [ ] Sparkline toggle off: rows keep the same spacing as today

U3. Footer clarity. The number is the share of this week's usage that went to each client (ClaudeProvider.swift:241). Label it "Share of this week: Claude Code 100%", and hide the row when one client has 100% (it says nothing then).
- [ ] A new user can say what the footer number means from its label alone (Yara reads it cold)

U4. Header. Drop the "Tokei" title; the header holds the update pill (when present), the refresh button and the gear.
- [ ] Panel header height unchanged or smaller; update pill still shows when an update waits

Every UI item: light and dark screenshots, no email visible (`-show.account NO`), design system rules (cards 8, spacing 4/8/12, no glass on glass).

## 3. Settings rework

Today: a sidebar with General, Display, then Providers (Claude, Codex). SPEC says "three tabs (General, Providers, Display)"; the build has a sidebar instead. General mixes refresh, notifications, sign-in renewal, menu bar numbers, launch at login and updates.

S1. Group by what the user wants, five sections in a fixed order inside General: Refresh, Notifications, Menu bar, Sign-in, App (launch at login, updates, install count). Each section has a header, not a footer paragraph doing the header's job.
- [ ] Every existing setting is still reachable, same keys (no migration), same defaults
- [ ] No section footer longer than one line at the default window width

S2. Fewer controls. Remove "Refresh when opening the panel" (R3). Turn "Menu bar numbers" (two toggles that stack) into one picker: None, Session, Weekly, Both.
- [ ] Upgrade from 0.1.3 with both toggles on: picker shows "Both"; with one on: that one; both off: "None"
- [ ] Menu bar output identical to 0.1.3 for each of the four cases

S3. Update SPEC to describe the sidebar as built (General, Display, one page per provider).
- [ ] SPEC and the build match

## 4. Feature ideas (research, ranked)

Ranked by value to the user against size. Each needs the user's pick before a spec.

1. Threshold alerts: notify at 80% and 95% of a limit (one per window). Small; uses the existing Notifier. Most-asked in CodexBar issues {{per a skim, not counted}}.
2. "Runs out at" in the menu bar: when pace says a limit runs out before reset, show the time instead of the percent. Small; builds on U1.
3. Keyboard shortcut to open the panel (global). Small.
4. History view: 7-day chart per limit in a window, from the snapshots already stored. Medium.
5. Codex live check and expiry (TASKS open items). Needed before telling Codex users it works; small, needs a Codex account.
6. Multiple Claude accounts (personal + work). Large; credentials model changes. Park.
7. Widgets. SPEC lists widgets as a non-goal; keep it out unless the user reverses that.

## Not in this plan

Token refresh (non-goal, breaks the CLIs), new providers, notarization (TASKS).
