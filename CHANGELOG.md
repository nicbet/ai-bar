# Changelog

## Unreleased

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

### Changed

- **Transcript scanning is about 10× faster.** Lines are found and filtered as raw bytes, only usage fields are decoded, and timestamp formatters are shared. The estimated-cost scan over a week of transcripts went from 65 s to 6 s; the incremental reader behind the simulated window reads a week in about 2.5 s and updates in milliseconds.
