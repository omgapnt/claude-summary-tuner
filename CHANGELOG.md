# Changelog

## v1.0.2 (2026-10-30)

- **Fix: v1.0.0 and v1.0.1 removed other apps' startup entries.** When the logger was turned on, those versions
  ran `New-Item -Force` on `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`, which deletes and recreates the
  key. Every other app's entry in it was lost. v1.0.2 creates the key only if it is missing and sets or removes
  only its own `ClaudeSummaryTunerCollector` value. The lost entries cannot be restored automatically: run
  `-ListLostStartupApps` (read-only) to see which apps Windows still lists as startup apps but that have no Run
  value any more, then turn "start with Windows" back on in each app's settings, or repair or reinstall it.
- **Logger and autostart are opt-in.** Baseline no longer starts the logger by itself. You are asked (default
  no), or you pass `-Logger on`. Autostart at logon is a separate choice (`-Autostart on|off`). An existing logger
  and autostart entry from an earlier version are kept as they are. `-NoLogger` never starts, rewrites or
  autostarts the logger, also in Baseline. `-Yes` no longer answers these questions.
- **No secret values on screen.** `-Status`, the telemetry conflict check and `-WhatIf` show only the names of
  `OTEL_*` variables and of variables named like keys, tokens, headers or secrets.
- **New read-only options:** `-WhatIf` (alias `-DryRun`) shows what an action would change, without writing
  anything, starting a process or opening a socket. `-Verify [-ExpectedHash <sha256>]` prints the script's SHA256,
  its signature status (not signed) and the embedded hook's hash, and checks that the hook and logger on disk
  match the embedded copies. `-ListLostStartupApps`.
- **Safer uninstall:** `-DeleteData` deletes only files that this version recorded as created by itself, by exact
  path. Nothing is deleted by wildcard or recursively, and files from older versions are kept. `-Uninstall -Yes`
  keeps your data.
- **Logger hardening:** size caps (64 KB headers, 8 MB bodies, 32 MB after gzip), a 10-second deadline per
  request, storage caps (128 MB per day, 512 MB in total), malformed input is never written to the log, and it now
  only stops a process that runs this installation's own `collector.ps1`.
- **Removed:** the `%ProgramData%` fallback for the hook file. If your profile path has spaces and no 8.3 short
  name, pass `-DataDir` with a path without spaces.
- **Docs:** new `SECURITY.md`; README section "Is this safe?". Releases now include `SHA256SUMS`.
- **Tests:** new `test/registry-windows.ps1` (scratch key), `test/security-regressions.ps1` and
  `test/collector-integration.py`; `test/unit.ps1` now also checks that no `New-Item -Force` is used and that every
  persistent change goes through the script's small set of change functions.

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
