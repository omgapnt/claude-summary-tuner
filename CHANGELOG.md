# Changelog

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
