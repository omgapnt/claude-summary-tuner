<#
  Claude-Summary-Tuner.ps1  -  measure and tame Claude Code's background "agent_summary" requests on Windows.

  WHAT IT DOES
    Claude Code (v2.1.232+) re-sends each background agent's whole transcript to the model about every
    30 seconds, just to show a 3-5 word status in the agents panel ("agent_summary"). Flamerix AI measured
    this at ~16% of all Claude Code spend. This script:
      1. installs Flamerix's Bun --preload hook (embedded below) through the BUN_OPTIONS user variable,
         in one of these modes: baseline (hook counts only), slow (every 5 min or custom), off;
      2. optionally runs a tiny local logger that records Claude Code's own OpenTelemetry cost events
         (no prompt text, no e-mail) so you can measure before/after;
      3. journals every change with a timestamp and tells you exactly which Claude processes still run
         the old setting;
      4. builds an HTML report (inline charts, nothing loaded from the internet);
      5. can re-run Flamerix's "Tested versions" A/B protocol (-Replicate).

  RUN IT  (no admin needed; Windows PowerShell 5.1 or PowerShell 7)
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Claude-Summary-Tuner.ps1
    Non-interactive examples:
      ... -File .\Claude-Summary-Tuner.ps1 -Mode baseline
      ... -File .\Claude-Summary-Tuner.ps1 -Mode slow            (5 minutes)
      ... -File .\Claude-Summary-Tuner.ps1 -Mode custom -Minutes 2.5
      ... -File .\Claude-Summary-Tuner.ps1 -Mode off
      ... -File .\Claude-Summary-Tuner.ps1 -CheckRestart | -Status | -Report | -Replicate [-Yes]
      ... -File .\Claude-Summary-Tuner.ps1 -Logger off | -Logger on
      ... -File .\Claude-Summary-Tuner.ps1 -Uninstall [-DeleteData]

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
  [string]$ReportTo

)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Off
$ToolName = 'Claude-Summary-Tuner'
$ToolVersion = '1.0.0'
if (-not $DataDir) { $DataDir = Join-Path $env:LOCALAPPDATA 'cc-summary-tuner' }
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$RunKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValueName = 'ClaudeSummaryTunerCollector'
$HookFileName = 'no-agent-summary.js'
$TunerVars = 'CC_AGENT_SUMMARY_MODE', 'CC_AGENT_SUMMARY_MIN_DELAY_MS', 'CC_AGENT_SUMMARY_LOG'
$OtelVarNames = 'CLAUDE_CODE_ENABLE_TELEMETRY', 'OTEL_LOGS_EXPORTER', 'OTEL_EXPORTER_OTLP_LOGS_PROTOCOL', 'OTEL_EXPORTER_OTLP_LOGS_ENDPOINT'
