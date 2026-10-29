# Changelog

## v1.0.1 (2026-10-29)

- **Fix: standalone `bun` broke.** `BUN_OPTIONS` is now written as `--preload=<path>` instead of `--preload <path>`.
  The space form made bun subcommands fail (`bun install` -> `Script not found "install"`, reported by Bedz01 on
  bun 1.4.3 and reproduced on Windows with bun 1.4.3). The `=` form was checked to load the hook in Claude Code
  2.1.312 and in the desktop app's bundled 2.1.309.
- **Upgrade path:** running the script with your current mode rewrites an old space-form value it owns (v1.0.0 or a
  manual `~/.local/share` install) and journals it as `reapply`, without starting a new measurement period. `-Status`
  and the menu warn while the old form is set.
- **Shareable reports:** the HTML report no longer contains the PC name, and paths are shown as `%LOCALAPPDATA%`,
  `%USERPROFILE%` etc. without the Windows user name (header, replicate table, action journal).
- **Desktop app:** `-Status` lists the desktop app's bundled Claude Code versions, runs the anchor check and hook
  load test on each, and warns when the app was started before the last mode change. `-CheckRestart` tells you to
  fully quit and reopen the app.
- **Version drift:** the Claude Code versions at install time are recorded. `-Status` warns (and changes nothing)
  when a CLI or desktop-app version differs, and suggests `-Replicate`.
- README: headline now cites Flamerix's measurement (up to ~16%) next to Anthropic's ~2% average; new desktop app
  section (5 / 5 / 0 on the bundled 2.1.309); Cowork mode listed as probably not covered; desktop-app replicate
  fixture added; screenshots regenerated.

## v1.0.0 (2026-10-29)

First public release.

- One-file PowerShell installer for Windows (PowerShell 5.1 and 7, no admin, no Node).
- Flamerix's `no-agent-summary.js` Bun preload hook, with a **Windows `Bun.main` gate** (`X:/~BUN/…`), a
  **slow mode** (default 5 min, custom ≥ 0.5 min) and a slowed counter.
- Modes: Baseline (`pass`), Slow, Custom, Off. Also Status, Restart check, Report, Replicate, Logger on/off, Uninstall.
- Local OpenTelemetry logger (127.0.0.1, autostart through an HKCU Run value) that records `claude_code.api_request`
  events by `query_source`.
- Timestamped action journal that marks when each change actually took effect.
- Self-contained HTML report with inline SVG charts.
- `-Replicate`: Flamerix's A/B protocol. On Windows with Claude Code 2.1.312, the forks were 5 / 5 / 0 (no hook /
  pass / off), plus 2 with slow at 1 min.
