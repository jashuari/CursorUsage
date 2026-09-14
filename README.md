# Cursor Usage — menu bar meter

A tiny native macOS menu bar app that shows your Cursor included-usage for the
current billing period, with the same per-model breakdown as
`cursor.com/dashboard` → Usage:

```
Cursor Models                128.3M tokens   49.1%
    composer-2.5-fast         83.2M tokens   29.7%
    auto-smart                31.4M tokens   10.4%
Other Models                  41.3M tokens  100.0%
    auto-smart                36.9M tokens   82.7%
    claude-opus-4-8-…          4.4M tokens   17.3%
On-demand / extra spend                      $12.40
```

Menu bar shows `41%` (left, or used — toggle in the popover), coloured orange
at 70% used and red at 90%.

Zero dependencies. Swift 5.9, macOS 14+. ~15 MB idle.

## Run

```bash
make run        # debug build, runs in the foreground
make install    # release .app → /Applications, launches it
```

On its first launch from /Applications the app registers itself as a Login
Item (System Settings → General → Login Items & Extensions), so it comes back
after every reboot. Turn it off there or with the "Login item" switch in the
popover — the two stay in sync.

## How it works

- **Auth**: reads `cursorAuth/accessToken` from Cursor.app's own state DB
  (`~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`),
  derives the user id from the JWT `sub`, and sends it as the
  `WorkosCursorSessionToken` cookie. Read-only; re-read on every refresh, so it
  tracks whatever session Cursor.app currently holds. Nothing is stored.
- **Data**: `GET /api/usage-summary` (plan %, lane %, billing cycle, on-demand
  spend) and `POST /api/dashboard/get-filtered-usage-events` windowed to the
  billing cycle, aggregated per model client-side.
- **Refresh**: every 5 min, plus when you open the popover if data is >60 s old.

Both endpoints are undocumented and can change without notice. When they do,
`make dump` prints the raw payloads so the decoder can be fixed quickly.

## Known gap: the Cursor-vs-Other lane split

Cursor's dashboard puts `auto-smart` in *both* groups, so the split isn't by
model name — it's some per-event field the dashboard uses. The app looks for a
few plausible field names (`usageLane`, `lane`, `usageType`, …) and otherwise
falls back to a name heuristic (composer/cursor-/auto → Cursor Models). The
footer tells you which rule was applied. Run `make dump`, look at one
`auto-smart` event from each group, and adjust `LaneClassifier` in
`UsageReport.swift`.

Per-model % is computed as the model's share of its lane's charged cents times
the lane's `autoPercentUsed` / `apiPercentUsed` from usage-summary, which is
what makes the child rows sum to the group row like the dashboard.

## Files

| File | Role |
| --- | --- |
| `CursorAuth.swift` | SQLite read of Cursor.app token → cookie |
| `CursorAPI.swift` | HTTP client + Decodable models, pagination |
| `UsageReport.swift` | Aggregation into lanes / per-model rows |
| `UsageStore.swift` | Refresh timer, state for the UI |
| `PopoverView.swift` | SwiftUI popover |
| `App.swift` | `@main` entry, NSStatusItem + NSPopover glue, `--dump` CLI mode |
