<#
  Claude-Summary-Tuner.ps1  -  measure and tame Claude Code's background "agent_summary" requests on Windows.

  WHAT IT DOES
    Claude Code (v2.1.232+) re-sends each background agent's whole transcript to the model about every
    30 seconds, just to show a 3-5 word status in the agents panel ("agent_summary"). Flamerix AI measured
    this at ~16% of spend in their setup (Anthropic reports ~2% on average). This script:
      1. installs Flamerix's Bun --preload hook (embedded below) through the BUN_OPTIONS user variable
         (written as --preload=<path>, the form that does not break the standalone bun CLI),
         in one of these modes: baseline (hook counts only), slow (every 5 min or custom), off;
      2. optionally runs a tiny local logger that records Claude Code's own OpenTelemetry cost events
         (no prompt text, no e-mail) so you can measure before/after;
      3. journals every change with a timestamp and tells you exactly which Claude processes still run
         the old setting;
      4. builds an HTML report (inline charts, nothing loaded from the internet);
      5. can re-run Flamerix's "Tested versions" A/B protocol (-Replicate).

  RUN IT  (no admin needed; Windows PowerShell 5.1 or PowerShell 7)
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Claude-Summary-Tuner.ps1
    "-ExecutionPolicy Bypass" applies to that one powershell process only. It does not change your
    machine's or your account's execution policy, and the script never calls Set-ExecutionPolicy.
    Look before you change anything (both change nothing):
      ... -File .\Claude-Summary-Tuner.ps1 -WhatIf                   (everything this tool can touch + current state)
      ... -File .\Claude-Summary-Tuner.ps1 -Mode off -WhatIf         (exactly what that command would change)
      ... -File .\Claude-Summary-Tuner.ps1 -Verify [-ExpectedHash <sha256>]   (SHA256 of this file, files on disk = embedded copies?)
      ... -File .\Claude-Summary-Tuner.ps1 -ListLostStartupApps      (startup apps missing from your Run key; read-only)
    Non-interactive examples:
      ... -File .\Claude-Summary-Tuner.ps1 -Mode baseline
      ... -File .\Claude-Summary-Tuner.ps1 -Mode slow            (5 minutes)
      ... -File .\Claude-Summary-Tuner.ps1 -Mode custom -Minutes 2.5
      ... -File .\Claude-Summary-Tuner.ps1 -Mode off [-Logger on [-Autostart on]] [-NoLogger]
      ... -File .\Claude-Summary-Tuner.ps1 -CheckRestart | -Status | -Report | -Replicate [-Yes]
      ... -File .\Claude-Summary-Tuner.ps1 -Logger on [-Autostart on] | -Logger off | -Autostart on|off
      ... -File .\Claude-Summary-Tuner.ps1 -Uninstall [-DeleteData]

  SECURITY  (details, full inventory and how to verify: SECURITY.md in the repository)
    * No admin, no downloads, no direct external requests by this script, no telemetry to the author, no Invoke-Expression,
      no encoded or compressed code. -Replicate launches usage-bearing Claude/provider requests. Plain text: the hook ($HookJs) and the optional
      logger ($CollectorPs) are embedded as readable here-strings right after this header.
    * Persistent writes use the "CHANGE GATE" helpers below. Preview takes a separate read-only route before
      any action handler: no child processes, socket probes, or writes. Behavioral regression tests cover it.
    * The logger and its autostart are opt-in (since v1.0.2): nothing listens on a port and nothing starts at
      logon unless you choose it. Telemetry variable values (OTEL_*, anything named like a key/token/header)
      are never printed.
    * v1.0.0 and v1.0.1 had a bug that removed OTHER apps' startup entries (HKCU Run key) whenever the logger was
      turned on. Fixed in v1.0.2; -ListLostStartupApps shows which entries are missing.

  RISK / TERMS  (please read)
    * Unofficial. Not affiliated with, sponsored or endorsed by Anthropic. "Claude" and "Claude Code" are
      trademarks of Anthropic, PBC.
    * It changes how the Claude Code client behaves at runtime (the binary itself is not modified).
      That may conflict with the terms of the service you use it with; checking that is on you.
    * Fail-open: a Claude Code update can silently stop the hook from matching. Re-check with -Status
      or -Replicate after updates.
    * Provided AS IS, without warranty of any kind. You use it at your own risk.

  PROJECT
    https://github.com/omgapnt/claude-summary-tuner   (README, issues, share your results)

  CREDITS / LICENSE
    Copyright (c) 2026 omgapnt. MIT License (full text: LICENSE in the repository).
    The embedded hook (no-agent-summary.js) is MIT (c) 2026 Flamerix AI, https://flamerix.ai
    (https://gist.github.com/flamerix-ai/c3905705cc4205e5de3011fa2e74efce), with a Windows path gate,
    a "slow" mode and a slowed counter added. This script is offered under the same MIT terms:
    Permission is hereby granted, free of charge, to any person obtaining a copy of this software, to deal
    in the software without restriction, subject to including this notice. THE SOFTWARE IS PROVIDED "AS IS",
    WITHOUT WARRANTY OF ANY KIND.
#>
[CmdletBinding()]
param(
  [ValidateSet('baseline', 'slow', 'custom', 'off')][string]$Mode,
  [double]$Minutes = 0,
  [ValidateSet('on', 'off')][string]$Logger,
  [switch]$NoLogger,
  [switch]$Status,
  [switch]$Report,
  [switch]$CheckRestart,
  [switch]$Replicate,
  [double]$ReplicateSlowMinutes = 0,
  [switch]$Uninstall,
  [switch]$DeleteData,
  [switch]$KeepData,
  [switch]$Yes,
  [switch]$NoOpen,
  [string]$DataDir,
  [int]$Port = 0,
  [string]$ReportTo,
  # -WhatIf (alias -DryRun): print every change the chosen action would make, make none.
  [Alias('DryRun')][switch]$WhatIf,
  # -Verify: SHA256 of this file, and whether the hook/logger files on disk match the copies embedded here.
  [switch]$Verify,
  [string]$ExpectedHash,
  # -Autostart on|off: start the logger at every logon (HKCU Run value). Off unless you turn it on.
  [ValidateSet('on', 'off')][string]$Autostart,
  # -ListLostStartupApps: read-only; lists startup apps Windows remembers that no longer have a Run value.
  [switch]$ListLostStartupApps
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Off
$ToolName = 'Claude-Summary-Tuner'
$ToolVersion = '1.0.2'
if (-not $DataDir) { $DataDir = Join-Path $env:LOCALAPPDATA 'cc-summary-tuner' }
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RunKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValueName = 'ClaudeSummaryTunerCollector'
$HookFileName = 'no-agent-summary.js'
$TunerVars = 'CC_AGENT_SUMMARY_MODE', 'CC_AGENT_SUMMARY_MIN_DELAY_MS', 'CC_AGENT_SUMMARY_LOG'
$OtelVarNames = 'CLAUDE_CODE_ENABLE_TELEMETRY', 'OTEL_LOGS_EXPORTER', 'OTEL_EXPORTER_OTLP_LOGS_PROTOCOL', 'OTEL_EXPORTER_OTLP_LOGS_ENDPOINT'
