# Changelog

All notable changes to AI Bar. Versions follow `CFBundleShortVersionString` in `Resources/Info.plist`.

## 1.1 — 2026-11-16

Anthropic removed the 5-hour limit from some Claude plans. These changes keep AI Bar accurate without it and keep the 5-hour pacing that came with it.

### Fixed

- **Weekly usage was shown as the 5-hour window.** Since the usage API stopped sending a 5-hour window (`five_hour: null`), AI Bar fell back to the first entry of `limits`, which is the weekly limit, and showed it on the ring as the 5-hour window. Its pace tick never appeared, and the weekly bar and weekly history stopped. Both windows are now optional, and a `limits` entry is only used when it is recognisably weekly. Codex is parsed the same way.

### Added

- **Main ring setting** (Settings → Display): Auto, 5-hour or Weekly. Auto shows the 5-hour window when the provider reports a real one, otherwise weekly. The menu bar follows the main ring, and the bar under the ring shows the other window.
- **Pace tick on the bar**, like the ring's, and pace labels for both windows in the detail window.
- **Simulated 5-hour windows** (Settings → Pacing, on by default) for providers without a real 5-hour window:
  - opens on first usage: a transcript change, or the weekly percentage going up;
  - budget per window: weekly headroom left ÷ windows left before the weekly reset, at 1–4 windows a day; changing the setting re-budgets the open window;
  - progress between whole weekly percents is estimated from local transcript cost, using a learned cost per weekly percent, clamped to the whole-percent readings;
  - saved across restarts; history is recorded as `five_hour_simulated` and charted in the detail window.
- Estimated values under 10% show one decimal (`0.6%`).
- The version is shown in the popover header and at the bottom of Settings.

### Changed

- **Transcript scanning is about 10× faster.** Lines are found and filtered as raw bytes, only usage fields are decoded, and timestamp formatters are shared. The estimated-cost scan over a week of transcripts went from 65 s to 6 s; the incremental reader behind the simulated window reads a week in about 2.5 s and updates in milliseconds.

## 1.0 — 2026-10-20

Everything up to 2026-10-20. The app reported version 1.0 throughout and was not tagged, so it is listed as one release.

### Added

- Menu bar app showing Claude and Codex usage from their OAuth usage APIs: a ring per provider with the 5-hour window and a pacing tick, a weekly limit bar, and usage history recorded to SQLite (2026-08-27).
- Provider detection on launch and each poll, with setup cards and login instructions for missing providers; the menu bar only shows enabled, available providers (2026-08-27).
- Settings window: provider toggles with status, refresh interval (1–15 minutes) (2026-08-27).
- Detail window per provider with usage history charts (24h / 7d / 30d) (2026-08-27).
- App icon (2026-08-29).
- Estimated daily API cost from Claude Code and Codex transcripts, priced by model at published API rates, in the menu bar, popover and detail view; off by default, in Settings → Display (2026-09-23).
- Spending window: daily cost chart (14 / 30 / 90 days) split by provider, and a receipt-style per-model breakdown for any day. Daily costs are stored, and up to 90 days are backfilled from existing transcripts (2026-09-24).
- Today button in the spending window (2026-09-25).
- `make snapshot` renders the README screenshots from sample data, in light and dark (2026-10-01).
- `make signing-cert` creates a local code-signing certificate so every build has the same identity; `make bundle` uses it when present, otherwise signs ad hoc (2026-10-20).

### Changed

- Pricing tables refreshed from the official pages, with a row per model; model IDs match by longest prefix, including Bedrock, Vertex and `[1m]` IDs. 1-hour cache writes are priced at 2× input, fast mode applies its multiplier, and `<synthetic>` entries are skipped (2026-09-24).
- The spending window opens on two weeks and on today (2026-09-25).
- Menu bar icons and text match the size of other status items (2026-09-28).
- README: building from source, the signing certificate, keychain access, and a trademark notice (2026-10-20).

### Fixed

- Claude's card shows "reset inactive" when there is no active window, keeping both cards aligned (2026-08-29).
- Claude subagent transcripts are included in cost estimates, and usage is bucketed by local day instead of the UTC date (2026-09-24).

### Security

- The Claude Code keychain item is read with the Security framework instead of `/usr/bin/security`, so the keychain prompt and an "Always Allow" grant apply to AI Bar alone rather than to any program that runs `security`. The login check matches attributes only and never prompts (2026-10-20).
