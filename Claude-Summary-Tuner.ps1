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

# ------------------------------------------------------------------ embedded files
# The hook. MIT (c) 2026 Flamerix AI (https://flamerix.ai), Windows gate + slow mode added.
$HookJs = @'
// no-agent-summary.js v2 + Windows gate + "slow" mode + slowed counter (patched for Claude-Summary-Tuner, 2026-10-29).
// Bun --preload hook that switches off (or slows) Claude Code's `agent_summary`
// side-query. Unofficial, not affiliated with Anthropic. Tested on Linux, Claude Code 2.1.301.
// Install, env vars, verification and fail-open caveats: README.md.
//
// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Flamerix AI (https://flamerix.ai). Provided "as is", without warranty;
// full license text: README.md.
//
// Anchors: the summarizer's debug-log line and its query-source id, both inside the timer
// callback on 2.1.301.
const IN_COMPILED_BUN =
  typeof Bun !== "undefined" && typeof Bun.main === "string" && (Bun.main.startsWith("/$bunfs/") || /^[A-Za-z]:[\\/]~BUN[\\/]/.test(Bun.main));

function install() {
  const fs = require("fs");
  const ANCHORS = ["[AgentSummary] Timer fired", "agent_summary"];
  const RAW_MODE = process.env.CC_AGENT_SUMMARY_MODE || "off";
  const MODE = ["pass", "slow"].includes(RAW_MODE) ? RAW_MODE : "off";
  // slow: keep the per-agent status line, but stretch each summary timer to at least this many ms
  // (default 5 min). Fewer full-transcript re-reads; the status just updates less often.
  const MIN_DELAY = Math.max(30000, Number(process.env.CC_AGENT_SUMMARY_MIN_DELAY_MS) || 300000);
  if (RAW_MODE !== MODE) process.stderr.write(`[no-agent-summary] unknown mode ${RAW_MODE}, forcing off\n`);
  const LOG = process.env.CC_AGENT_SUMMARY_LOG;
  const log = (s) => { if (LOG) { try { fs.appendFileSync(LOG, `${new Date().toISOString()} pid=${process.pid} ${s}\n`); } catch {} } };

  const verdict = new WeakMap(); // fn -> bool (is the summary timer callback)
  function isSummaryTimer(fn) {
    if (typeof fn !== "function") return false;
    let v = verdict.get(fn);
    if (v === undefined) {
      try {
        const src = Function.prototype.toString.call(fn);
        v = ANCHORS.some((a) => src.includes(a));
      } catch { v = false; }
      verdict.set(fn, v);
    }
    return v;
  }

  let matched = 0;
  let suppressed = 0;
  let slowed = 0;
  const PROMISIFY = Symbol.for("nodejs.util.promisify.custom");
  const wrappers = new Map(); // original timer fn -> its wrapper: one wrapper per original
  const hookedFns = new WeakSet();
  function wrap(orig, name) {
    if (typeof orig !== "function") return orig;
    if (wrappers.has(orig)) return wrappers.get(orig);
    const hooked = function (fn, delay, ...args) {
      if (isSummaryTimer(fn)) {
        matched++;
        if (MODE === "off") {
          suppressed++;
          if (matched <= 20) log(`summary timer #${matched} suppressed (${name}, delay=${delay})`);
          const t = orig(() => {}, 2 ** 31 - 1); // clear*-compatible handle of the same kind, never fires
          if (t && typeof t.unref === "function") t.unref();
          return t;
        }
        if (MODE === "slow") {
          const d = Math.max(Number(delay) || 0, MIN_DELAY);
          slowed++;
          if (matched <= 20) log(`summary timer #${matched} slowed (${name}, delay=${delay} -> ${d})`);
          return orig(fn, d, ...args);
        }
        if (matched <= 20) log(`summary timer #${matched} passed (control, ${name}, delay=${delay})`);
      }
      return orig(fn, delay, ...args);
    };
    Object.defineProperty(hooked, "name", { value: name });
    // util.promisify(setTimeout) reads these; without the custom one it calls the wrapper
    // callback-last and node throws ERR_INVALID_ARG_TYPE.
    if (orig.__promisify__) hooked.__promisify__ = orig.__promisify__;
    if (orig[PROMISIFY]) hooked[PROMISIFY] = orig[PROMISIFY];
    wrappers.set(orig, hooked);
    hookedFns.add(hooked);
    return hooked;
  }

  // require("timers/promises").setTimeout(delay, value) takes no callback, so there is no source
  // to match an anchor in; it stays unwrapped.
  const timers = (() => { try { return require("timers"); } catch { return null; } })();
  const hookedApis = [];
  for (const name of ["setTimeout", "setInterval"]) {
    globalThis[name] = wrap(globalThis[name], name);
    if (hookedFns.has(globalThis[name])) hookedApis.push(`global.${name}`);
    if (timers) {
      try { timers[name] = wrap(timers[name], name); } catch {}
      if (hookedFns.has(timers[name])) hookedApis.push(`timers.${name}`);
    }
  }

  const active = `preload active mode=${MODE}${MODE === "slow" ? " min_delay=" + MIN_DELAY : ""} bun=${Bun.version} hooked=${hookedApis.join(",")}`;
  log(active);
  if (LOG) process.on("exit", () => log(`exit: ${suppressed} summary timer(s) suppressed, ${slowed} slowed, ${matched} matched`));
  const MARKER = process.env.CC_AGENT_SUMMARY_MARKER;
  if (MARKER) {
    try { fs.writeFileSync(MARKER, `${active} pid=${process.pid}\n`); }
    catch (e) { process.stderr.write(`[no-agent-summary] cannot write marker ${MARKER}: ${e.message}\n`); }
  }
}

if (IN_COMPILED_BUN) install();
'@
$CollectorPs = @'
# Claude-Summary-Tuner local collector. Receives Claude Code OpenTelemetry log events (OTLP/HTTP JSON)
# on 127.0.0.1 only and appends the cost-relevant fields of api_request / api_error / user_prompt
# events to a daily TSV file. It never stores prompt or response text, e-mail or account ids.
param([Parameter(Mandatory = $true)][string]$DataDir, [Parameter(Mandatory = $true)][int]$Port)
$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$logFile = Join-Path $DataDir 'collector.log'
function Write-CLog([string]$m) {
  try {
    if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 1MB) { Move-Item $logFile "$logFile.old" -Force }
    [IO.File]::AppendAllText($logFile, ((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') + " pid=$PID $m`r`n"), $utf8)
  } catch {}
}
$created = $false
$mutex = New-Object System.Threading.Mutex($true, "Local\ClaudeSummaryTunerCollector-$Port", [ref]$created)
if (-not $created) { Write-CLog "another collector already owns port $Port, exiting"; exit 0 }
[IO.File]::WriteAllText((Join-Path $DataDir 'collector.pid'), "$PID", $utf8)
$script:received = 0; $script:stored = 0; $started = (Get-Date).ToUniversalTime().ToString('o')
$Cols = 't', 'event', 'session', 'model', 'query_source', 'cost_usd', 'input_tokens', 'output_tokens', 'cache_read_tokens', 'cache_creation_tokens', 'duration_ms', 'version', 'agent', 'tag', 'status'

function Get-AnyValue($v) {
  if ($null -eq $v) { return $null }
  foreach ($k in 'stringValue', 'intValue', 'doubleValue', 'boolValue') {
    if ($v.PSObject.Properties[$k]) { return $v.$k }
  }
  return $null
}
function Get-Attrs($list) {
  $h = @{}
  if ($list) { foreach ($a in $list) { $h[[string]$a.key] = Get-AnyValue $a.value } }
  return $h
}
function ConvertTo-Field([object]$x) { if ($null -eq $x) { return '' }; return (([string]$x) -replace "[`t`r`n]", ' ') }

function Save-Logs([byte[]]$bytes, [string]$encoding) {
  if ($encoding -match 'gzip') {
    $ms = New-Object IO.MemoryStream(, $bytes); $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Decompress)
    $out = New-Object IO.MemoryStream; $gz.CopyTo($out); $bytes = $out.ToArray(); $gz.Dispose()
  }
  $json = $utf8.GetString($bytes)
  if (-not $json.Trim()) { return }
  $doc = ConvertFrom-Json $json
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($rl in @($doc.resourceLogs)) {
    if ($null -eq $rl) { continue }
    $r = Get-Attrs $rl.resource.attributes
    foreach ($sl in @($rl.scopeLogs)) {
      if ($null -eq $sl) { continue }
      foreach ($lr in @($sl.logRecords)) {
        if ($null -eq $lr) { continue }
        $script:received++
        $a = Get-Attrs $lr.attributes
        $ev = [string]$a['event.name']
        if (-not $ev) { $ev = [string](Get-AnyValue $lr.body) }
        $ev = $ev -replace '^claude_code\.', ''
        if ($ev -notin 'api_request', 'api_error', 'user_prompt') { continue }
        $t = $a['event.timestamp']
        if (-not $t -and $lr.timeUnixNano) { $t = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]([decimal]$lr.timeUnixNano / 1000000)).UtcDateTime.ToString('o') }
        $ver = $r['service.version']; if (-not $ver) { $ver = $a['app.version'] }
        $tag = $a['cc_tuner.tag']; if (-not $tag) { $tag = $r['cc_tuner.tag'] }
        $vals = @($t, $ev, $a['session.id'], $a['model'], $a['query_source'], $a['cost_usd'], $a['input_tokens'], $a['output_tokens'],
          $a['cache_read_tokens'], $a['cache_creation_tokens'], $a['duration_ms'], $ver, $a['agent.name'], $tag, $a['status_code'])
        $lines.Add((($vals | ForEach-Object { ConvertTo-Field $_ }) -join "`t"))
      }
    }
  }
  if ($lines.Count -gt 0) {
    $file = Join-Path $DataDir ('events-' + (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd') + '.tsv')
    $text = ''
    if (-not (Test-Path $file)) { $text = ($Cols -join "`t") + "`r`n" }
    $text += ($lines -join "`r`n") + "`r`n"
    [IO.File]::AppendAllText($file, $text, $utf8)
    $script:stored += $lines.Count
  }
}
function Get-Health { return ('{"ok":true,"app":"claude-summary-tuner","pid":' + $PID + ',"port":' + $Port + ',"started":"' + $started + '","received":' + $script:received + ',"stored":' + $script:stored + '}') }

function Invoke-Route([string]$method, [string]$path, [byte[]]$body, [string]$enc) {
  if ($method -eq 'GET' -and $path -eq '/health') { return @(200, (Get-Health)) }
  if ($method -eq 'POST' -and $path -like '/v1/logs*') {
    try { Save-Logs $body $enc } catch { Write-CLog "parse error: $($_.Exception.Message)" }
    return @(200, '{}')
  }
  if ($method -eq 'POST' -and $path -like '/v1/*') { return @(200, '{}') }  # metrics/traces: accepted and dropped
  return @(404, '{}')
}

$listener = $null; $tcp = $null
for ($try = 0; $try -lt 30 -and -not $listener -and -not $tcp; $try++) {
  try {
    $l = New-Object Net.HttpListener; $l.Prefixes.Add("http://127.0.0.1:$Port/"); $l.Start(); $listener = $l
    Write-CLog "listening (HttpListener) on http://127.0.0.1:$Port/"
  } catch {
    $msg = $_.Exception.Message
    try {
      $t = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $Port); $t.Start(); $tcp = $t
      Write-CLog "HttpListener failed ($msg); listening (TcpListener) on 127.0.0.1:$Port"
    } catch {
      Write-CLog "port $Port unavailable ($msg / $($_.Exception.Message)); retry in 20 s"
      Start-Sleep -Seconds 20
    }
  }
}
if (-not $listener -and -not $tcp) { Write-CLog 'giving up: could not bind'; exit 1 }

while ($true) {
  try {
    if ($listener) {
      $ctx = $listener.GetContext(); $req = $ctx.Request
      $ms = New-Object IO.MemoryStream; $req.InputStream.CopyTo($ms)
      $res = Invoke-Route $req.HttpMethod $req.Url.AbsolutePath $ms.ToArray() ([string]$req.Headers['Content-Encoding'])
      $out = $utf8.GetBytes([string]$res[1])
      $ctx.Response.StatusCode = [int]$res[0]; $ctx.Response.ContentType = 'application/json'
      $ctx.Response.ContentLength64 = $out.Length; $ctx.Response.OutputStream.Write($out, 0, $out.Length); $ctx.Response.Close()
    } else {
      $client = $tcp.AcceptTcpClient(); $client.ReceiveTimeout = 10000; $ns = $client.GetStream()
      $buf = New-Object byte[] 65536; $acc = New-Object IO.MemoryStream; $hdrEnd = -1
      while ($hdrEnd -lt 0) {
        $n = $ns.Read($buf, 0, $buf.Length); if ($n -le 0) { break }
        $acc.Write($buf, 0, $n); $s = [Text.Encoding]::ASCII.GetString($acc.ToArray()); $hdrEnd = $s.IndexOf("`r`n`r`n")
      }
      if ($hdrEnd -ge 0) {
        $all = $acc.ToArray(); $head = [Text.Encoding]::ASCII.GetString($all, 0, $hdrEnd); $hl = $head -split "`r`n"
        $parts = $hl[0] -split ' '; $len = 0; $enc = ''
        foreach ($h in $hl) { if ($h -match '^(?i)content-length:\s*(\d+)') { $len = [int]$matches[1] }; if ($h -match '^(?i)content-encoding:\s*(.+)$') { $enc = $matches[1] }; if ($h -match '^(?i)expect:\s*100-continue') { $c = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n"); $ns.Write($c, 0, $c.Length) } }
        $body = New-Object IO.MemoryStream; $start = $hdrEnd + 4
        if ($all.Length -gt $start) { $body.Write($all, $start, $all.Length - $start) }
        while ($body.Length -lt $len) { $n = $ns.Read($buf, 0, $buf.Length); if ($n -le 0) { break }; $body.Write($buf, 0, $n) }
        $res = Invoke-Route $parts[0] (($parts[1] -split '\?')[0]) $body.ToArray() $enc
        $out = $utf8.GetBytes([string]$res[1])
        $hdr = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $($res[0]) OK`r`nContent-Type: application/json`r`nContent-Length: $($out.Length)`r`nConnection: close`r`n`r`n")
        $ns.Write($hdr, 0, $hdr.Length); $ns.Write($out, 0, $out.Length)
      }
      $client.Close()
    }
  } catch { Write-CLog "request error: $($_.Exception.Message)"; Start-Sleep -Milliseconds 200 }
}
'@

# ------------------------------------------------------------------ helpers
$Inv = [Globalization.CultureInfo]::InvariantCulture
function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Head([string]$m) { Write-Host ''; Write-Host "== $m ==" -ForegroundColor Cyan }
function Warn([string]$m) { Write-Host "WARNING: $m" -ForegroundColor Yellow }
function Good([string]$m) { Write-Host $m -ForegroundColor Green }
function Fmt([double]$x, [string]$f = '0.##') { return $x.ToString($f, $Inv) }
function NowUtc { return (Get-Date).ToUniversalTime() }
function IsoUtc([datetime]$d) { return $d.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ', $Inv) }
function ParseIso([string]$s) {
  if (-not $s) { return $null }
  try { return [DateTimeOffset]::Parse($s, $Inv, [Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime } catch { return $null }
}
function LocalStr([datetime]$utc) {
  $l = $utc.ToLocalTime(); $off = [TimeZoneInfo]::Local.GetUtcOffset($l)
  $sign = '+'; if ($off.Ticks -lt 0) { $sign = '-' }
  return $l.ToString('yyyy-MM-dd HH:mm', $Inv) + " (UTC$sign" + ([Math]::Abs($off.Hours)).ToString('0') + $(if ($off.Minutes) { ':' + ([Math]::Abs($off.Minutes)).ToString('00') } else { '' }) + ')'
}
function ParseNum([string]$s) {
  if (-not $s) { return 0.0 }
  $d = 0.0
  if ([double]::TryParse($s.Trim().Replace(',', '.'), [Globalization.NumberStyles]::Float, $Inv, [ref]$d)) { return $d }
  return 0.0
}
function Ask([string]$q, [string]$def = '') {
  $a = Read-Host $q
  if (-not $a) { return $def }
  return $a.Trim()
}
function AskYesNo([string]$q, [bool]$def = $false) {
  if ($Yes) { return $true }
  $d = 'y/N'; if ($def) { $d = 'Y/n' }
  $a = Read-Host "$q [$d]"
  if (-not $a) { return $def }
  return ($a.Trim().ToLower() -in 'y', 'yes', 'j', 'ja')
}
function Ensure-Dir([string]$p) { if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function Write-Text([string]$p, [string]$t) { [IO.File]::WriteAllText($p, $t, $Utf8NoBom) }
function Append-Text([string]$p, [string]$t) { [IO.File]::AppendAllText($p, $t, $Utf8NoBom) }

# ------------------------------------------------------------------ config + journal
$ConfigPath = Join-Path $DataDir 'config.json'
$JournalPath = Join-Path $DataDir 'actions.jsonl'
$HookLogPath = Join-Path $DataDir 'hook.log'
function Get-Config {
  $c = $null
  if (Test-Path -LiteralPath $ConfigPath) { try { $c = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json } catch { $c = $null } }
  if (-not $c) { $c = New-Object PSObject }
  foreach ($k in 'hookPath', 'hookBunPath', 'port', 'loggerEnabled', 'mode', 'minutes', 'legacyLogs', 'loggerVars', 'anchorCache') {
    if (-not $c.PSObject.Properties[$k]) { $c | Add-Member -NotePropertyName $k -NotePropertyValue $null }
  }
  return $c
}
function Save-Config($c) { Ensure-Dir $DataDir; Write-Text $ConfigPath ($c | ConvertTo-Json -Depth 6) }
function Add-Journal([string]$action, [hashtable]$extra = @{}) {
  Ensure-Dir $DataDir
  $o = [ordered]@{ t = (IsoUtc (NowUtc)); action = $action }
  foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] }
  Append-Text $JournalPath ((New-Object PSObject -Property $o | ConvertTo-Json -Compress -Depth 5) + "`r`n")
  return $o.t
}
function Read-Journal {
  $out = @()
  if (Test-Path -LiteralPath $JournalPath) {
    foreach ($l in [IO.File]::ReadAllLines($JournalPath)) { if ($l.Trim()) { try { $out += ($l | ConvertFrom-Json) } catch {} } }
  }
  return $out
}

# ------------------------------------------------------------------ user environment
function Get-UserEnv([string]$n) { return [Environment]::GetEnvironmentVariable($n, 'User') }
function Set-UserEnv([string]$n, [string]$v) {
  if ([string]::IsNullOrEmpty($v)) { [Environment]::SetEnvironmentVariable($n, $null, 'User') }
  else { [Environment]::SetEnvironmentVariable($n, $v, 'User') }
}

# BUN_OPTIONS is split on whitespace by Bun; quotes are NOT honoured (a quoted path silently fails to load)
# and backslashes are eaten. So: forward slashes, no spaces, and keep every other option as it was.
function Split-BunOptions([string]$s) { if (-not $s) { return @() }; return @($s.Trim() -split '\s+' | Where-Object { $_ }) }
function Remove-OurPreload([string]$s) {
  $t = @(Split-BunOptions $s); $keep = New-Object System.Collections.Generic.List[string]
  for ($i = 0; $i -lt $t.Count; $i++) {
    if ($t[$i] -eq '--preload' -and $i + 1 -lt $t.Count -and $t[$i + 1] -match 'no-agent-summary\.js$') { $i++; continue }
    if ($t[$i] -match '^--preload=.*no-agent-summary\.js$') { continue }
    $keep.Add($t[$i])
  }
  return ($keep -join ' ')
}
function Merge-BunOptions([string]$current, [string]$hookBunPath) {
  $rest = Remove-OurPreload $current
  if ($rest) { return "$rest --preload $hookBunPath" }
  return "--preload $hookBunPath"
}
function Get-PreloadPaths([string]$s) {
  $t = @(Split-BunOptions $s); $o = @()
  for ($i = 0; $i -lt $t.Count; $i++) {
    if ($t[$i] -eq '--preload' -and $i + 1 -lt $t.Count) { $o += $t[$i + 1]; $i++ }
    elseif ($t[$i] -match '^--preload=(.+)$') { $o += $matches[1] }
  }
  return $o
}
function ConvertTo-BunPath([string]$p) {
  # Bun-safe form of a Windows path: forward slashes, no whitespace. Falls back to the 8.3 short name.
  $f = $p -replace '\\', '/'
  if ($f -notmatch '\s') { return $f }
  try {
    $fso = New-Object -ComObject Scripting.FileSystemObject
    $sp = $fso.GetFile($p).ShortPath
    if ($sp -and $sp -notmatch '\s') { return ($sp -replace '\\', '/') }
  } catch {}
  return $null
}

# ------------------------------------------------------------------ Claude Code discovery
function Find-Claude {
  $cands = @()
  $native = Join-Path $env:USERPROFILE '.local\bin\claude.exe'
  if (Test-Path -LiteralPath $native) { $cands += $native }
  foreach ($c in @(Get-Command claude -All -ErrorAction SilentlyContinue)) { if ($c.Source -and $c.Source -notin $cands) { $cands += $c.Source } }
  foreach ($p in $cands) { if ($p -like '*.exe') { return $p } }
  if ($cands.Count) { return $cands[0] }
  return $null
}
function Invoke-Isolated([string]$exe, [string[]]$argv, [hashtable]$envOverride) {
  # Runs a child with extra/removed variables in THIS process only; nothing persistent is touched.
  $saved = @{}
  foreach ($k in $envOverride.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process'); [Environment]::SetEnvironmentVariable($k, $envOverride[$k], 'Process') }
  $eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = ($null | & $exe @argv 2>&1 | ForEach-Object { "$_" } | Out-String); return @{ out = $out; code = $LASTEXITCODE } }
  catch { return @{ out = $_.Exception.Message; code = -1 } }
  finally { $ErrorActionPreference = $eap; foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') } }
}
$NoHookEnv = @{ BUN_OPTIONS = $null; CC_AGENT_SUMMARY_MODE = $null; CC_AGENT_SUMMARY_LOG = $null; CC_AGENT_SUMMARY_MIN_DELAY_MS = $null }
function Get-CCVersion([string]$exe) {
  if (-not $exe) { return $null }
  $r = Invoke-Isolated $exe @('--version') $NoHookEnv
  if ($r.out -match '(\d+\.\d+\.\d+)') { return $matches[1] }
  return $null
}
function Test-HookLoads([string]$exe, [string]$bunOptions) {
  $tmp = Join-Path $env:TEMP ("cst-selftest-" + [guid]::NewGuid().ToString('N') + '.log')
  $r = Invoke-Isolated $exe @('--version') @{ BUN_OPTIONS = $bunOptions; CC_AGENT_SUMMARY_MODE = 'pass'; CC_AGENT_SUMMARY_LOG = $tmp; CC_AGENT_SUMMARY_MIN_DELAY_MS = $null }
  $line = $null
  if (Test-Path -LiteralPath $tmp) { $line = (Get-Content -LiteralPath $tmp | Where-Object { $_ -match 'preload active' } | Select-Object -First 1); Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  return @{ ok = [bool]$line; line = $line; out = $r.out.Trim() }
}
function Find-BinaryAnchors([string]$path) {
  # Streams the binary and looks for the hook's anchors (Latin-1 and UTF-16LE encodings).
  $anchors = @('[AgentSummary] Timer fired', 'agent_summary')
  $l1 = [Text.Encoding]::GetEncoding(28591)
  $pats = @()
  foreach ($a in $anchors) { $pats += @{ a = $a; s = $a }; $pats += @{ a = $a; s = $l1.GetString([Text.Encoding]::Unicode.GetBytes($a)) } }
  $found = @{}; foreach ($a in $anchors) { $found[$a] = $false }
  $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
  try {
    $buf = New-Object byte[] (16MB); $carry = ''
    while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
      $s = $carry + $l1.GetString($buf, 0, $n)
      foreach ($p in $pats) { if (-not $found[$p.a] -and $s.IndexOf($p.s, [StringComparison]::Ordinal) -ge 0) { $found[$p.a] = $true } }
      if (($found.Values | Where-Object { -not $_ }).Count -eq 0) { break }
      $carry = $s.Substring([Math]::Max(0, $s.Length - 128))
    }
  } finally { $fs.Dispose() }
  return $found
}

# ------------------------------------------------------------------ hook file
function Install-HookFile($cfg) {
  # Prefer the data folder. If its Bun-safe form is impossible (spaces and no 8.3 names), use ProgramData\<SID>.
  $cands = @((Join-Path $DataDir $HookFileName))
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  if ($env:ProgramData) { $cands += (Join-Path (Join-Path (Join-Path $env:ProgramData 'cc-summary-tuner') $sid) $HookFileName) }
  foreach ($p in $cands) {
    try {
      Ensure-Dir (Split-Path $p -Parent); Write-Text $p $HookJs
      $bp = ConvertTo-BunPath $p
      if ($bp -and $bp -match '^[A-Za-z]:/[^\s"'']+$') { $cfg.hookPath = $p; $cfg.hookBunPath = $bp; return $true }
      Warn "Path '$p' contains spaces and has no short (8.3) name; trying another location."
    } catch { Warn "Could not write $p : $($_.Exception.Message)" }
  }
  return $false
}

# ------------------------------------------------------------------ hook log evidence
function Get-HookLogFiles($cfg) {
  $f = @()
  if (Test-Path -LiteralPath $HookLogPath) { $f += $HookLogPath }
  $cand = @($cfg.legacyLogs) + @((Join-Path $env:LOCALAPPDATA 'no-agent-summary.log'))
  $ul = Get-UserEnv 'CC_AGENT_SUMMARY_LOG'; if ($ul) { $cand += [Environment]::ExpandEnvironmentVariables($ul) }
  foreach ($l in ($cand | Select-Object -Unique)) { if ($f -contains $l) { continue }; if ($l -and (Test-Path -LiteralPath $l) -and $l -ne $HookLogPath) { $f += $l } }
  return $f
}
function Read-HookLog($cfg) {
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($f in (Get-HookLogFiles $cfg)) {
    foreach ($l in [IO.File]::ReadAllLines($f)) {
      if ($l -match '^(\S+)\s+pid=(\d+)\s+(.*)$') {
        $t = ParseIso $matches[1]; if (-not $t) { continue }
        $rows.Add([pscustomobject]@{ t = $t; pid = [int]$matches[2]; msg = $matches[3] })
      }
    }
  }
  return $rows
}

# ------------------------------------------------------------------ running Claude processes
function Get-ClaudeProcesses($hookRows) {
  $procs = @()
  try { $all = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction Stop) } catch { $all = @() }
  foreach ($p in $all) {
    $cmd = [string]$p.CommandLine; $path = [string]$p.ExecutablePath
    $kind = 'Session'; $relevant = $true
    if ($path -like '*\WindowsApps\Claude_*' -or $path -like '*\AnthropicClaude\*' -or $path -like '*\Programs\Claude\*') {
      if ($cmd -match '--type=') { continue }
      $kind = 'Desktop app (restart it)'
    } elseif ($path -like '*\Claude\claude-code\*') { $kind = 'Desktop app Code session' }
    elseif ($cmd -match '\bdaemon\s+run') { $kind = 'Daemon' }
    elseif ($cmd -match '--bg-pty-host') { $kind = 'Daemon pty host' }
    elseif ($cmd -match '--chrome-native-host') { $kind = 'Chrome bridge'; $relevant = $false }
    elseif ($cmd -match '(^|\s)(-p|--print)(\s|$)') { $kind = 'Headless (-p)' }
    elseif ($cmd -match '\s--bg(\s|$)|bg-spare|--bg-session') { $kind = 'Background session' }
    $created = $null; if ($p.CreationDate) { $created = ([datetime]$p.CreationDate).ToUniversalTime() }
    $hook = '-'
    if ($kind -ne 'Desktop app (restart it)') {
      $hook = 'NO'
      if ($hookRows -and $created) {
        $ln = $hookRows | Where-Object { $_.pid -eq $p.ProcessId -and $_.msg -like 'preload active*' -and $_.t -ge $created.AddSeconds(-10) } | Select-Object -Last 1
        if ($ln -and $ln.msg -match 'mode=(\S+)(?: min_delay=(\d+))?') {
          $hook = 'yes: ' + $matches[1]; if ($matches[2]) { $hook += ' ' + (Fmt ([double]$matches[2] / 60000)) + ' min' }
        }
      }
    }
    $procs += [pscustomobject]@{ PID = $p.ProcessId; Started = $created; Kind = $kind; Hook = $hook; Relevant = $relevant; Path = $path }
  }
  return $procs | Sort-Object Started
}
function Show-Processes($procs) {
  if (-not $procs) { Say '  (no Claude processes running)'; return }
  $procs | ForEach-Object {
    $s = '-'; if ($_.Started) { $s = LocalStr $_.Started }
    [pscustomobject]@{ PID = $_.PID; Started = $s; Kind = $_.Kind; 'Hook loaded' = $_.Hook }
  } | Format-Table -AutoSize | Out-String -Width 160 | Write-Host
}

# ------------------------------------------------------------------ existing OpenTelemetry config
function Get-OtelConflicts($cfg) {
  $found = @()
  $ours = @{}; if ($cfg.loggerVars) { foreach ($p in $cfg.loggerVars.PSObject.Properties) { $ours[$p.Name] = [string]$p.Value } }
  foreach ($scope in 'User', 'Machine') {
    $vars = [Environment]::GetEnvironmentVariables($scope)
    foreach ($k in $vars.Keys) {
      if ($k -match '^(OTEL_|CLAUDE_CODE_ENABLE_TELEMETRY$|BETA_TRACING_ENDPOINT$)') {
        if ($scope -eq 'User' -and $ours.ContainsKey($k) -and $ours[$k] -eq [string]$vars[$k]) { continue }
        $found += "$scope environment: $k=$($vars[$k])"
      }
    }
  }
  $settings = Join-Path $env:USERPROFILE '.claude\settings.json'
  foreach ($f in @($settings, "$env:ProgramFiles\ClaudeCode\managed-settings.json", "$env:ProgramData\ClaudeCode\managed-settings.json")) {
    if ($f -and (Test-Path -LiteralPath $f)) {
      try {
        $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
        if ($j.env) { foreach ($p in $j.env.PSObject.Properties) { if ($p.Name -match '^(OTEL_|CLAUDE_CODE_ENABLE_TELEMETRY$)') { $found += "$f : env.$($p.Name)=$($p.Value)" } } }
        if ($j.otelHeadersHelper) { $found += "$f : otelHeadersHelper is set" }
      } catch { if ($f -ne $settings) { $found += "$f exists (could not parse)" } }
    }
  }
  foreach ($k in 'HKLM:\SOFTWARE\Policies\ClaudeCode', 'HKCU:\SOFTWARE\Policies\ClaudeCode') { if (Test-Path $k) { $found += "Managed policy registry key present: $k (may pin telemetry)" } }
  return $found
}

# ------------------------------------------------------------------ collector
function Test-PortFree([int]$p) {
  try { $l = New-Object Net.HttpListener; $l.Prefixes.Add("http://127.0.0.1:$p/"); $l.Start(); $l.Stop(); $l.Close() } catch { return $false }
  try { $t = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $p); $t.Start(); $t.Stop() } catch { return $false }
  return $true
}
function Find-FreePort([int]$start) { for ($p = $start; $p -lt $start + 50; $p++) { if (Test-PortFree $p) { return $p } }; return 0 }
function Get-CollectorHealth([int]$p) {
  if (-not $p) { return $null }
  try { $wc = New-Object Net.WebClient; $wc.Proxy = $null; $j = $wc.DownloadString("http://127.0.0.1:$p/health"); $wc.Dispose(); $o = $j | ConvertFrom-Json; if ($o.app -eq 'claude-summary-tuner') { return $o } } catch {}
  return $null
}
function Get-CollectorCommand([int]$p) {
  $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $script = Join-Path $DataDir 'collector.ps1'
  $psArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`" -DataDir `"$DataDir`" -Port $p"
  # conhost --headless keeps the console invisible even when Windows Terminal is the default terminal app.
  $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
  if ((Test-Path $conhost) -and [Environment]::OSVersion.Version.Build -ge 17763) {
    return @{ file = $conhost; args = "--headless `"$ps`" $psArgs"; full = "`"$conhost`" --headless `"$ps`" $psArgs" }
  }
  return @{ file = $ps; args = $psArgs; full = "`"$ps`" $psArgs" }
}
function Start-Collector($cfg) {
  Write-Text (Join-Path $DataDir 'collector.ps1') $CollectorPs
  $c = Get-CollectorCommand ([int]$cfg.port)
  New-Item -Path $RunKeyPath -Force -ErrorAction SilentlyContinue | Out-Null
  Set-ItemProperty -Path $RunKeyPath -Name $RunValueName -Value $c.full
  if (-not (Get-CollectorHealth ([int]$cfg.port))) { Start-Process -FilePath $c.file -ArgumentList $c.args -WindowStyle Hidden | Out-Null }
  for ($i = 0; $i -lt 20; $i++) { $h = Get-CollectorHealth ([int]$cfg.port); if ($h) { return $h }; Start-Sleep -Milliseconds 500 }
  return $null
}
function Stop-Collector($cfg) {
  $pidFile = Join-Path $DataDir 'collector.pid'
  if (Test-Path -LiteralPath $pidFile) {
    $cp = [int]((Get-Content -LiteralPath $pidFile -Raw).Trim())
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$cp" -ErrorAction SilentlyContinue
    if ($p -and [string]$p.CommandLine -like '*collector.ps1*') { Stop-Process -Id $cp -Force -ErrorAction SilentlyContinue; Say "  stopped collector (PID $cp)" }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
  }
  Remove-ItemProperty -Path $RunKeyPath -Name $RunValueName -ErrorAction SilentlyContinue
}
function Enable-Logger($cfg, [bool]$interactive) {
  $conf = Get-OtelConflicts $cfg
  if ($conf.Count) {
    Warn 'Claude Code telemetry is already configured on this machine:'
    $conf | ForEach-Object { Say "   - $_" 'Yellow' }
    Say '   Turning on this logger would redirect Claude Code''s log events to this PC only, and settings.json/managed' 'Yellow'
    Say '   settings may override it anyway. Default is to leave telemetry alone (the hook still works).' 'Yellow'
    if (-not ($interactive -and (AskYesNo 'Set up the local logger anyway?' $false))) { Say '  Logger skipped.'; return $false }
  }
  if (-not $cfg.port -or -not ((Get-CollectorHealth ([int]$cfg.port)) -or (Test-PortFree ([int]$cfg.port)))) {
    $start = 47318; if ($Port) { $start = $Port }
    $cfg.port = Find-FreePort $start
    if (-not $cfg.port) { Warn 'No free local port found (47318-47367). Logger not set up.'; return $false }
  }
  $vars = [ordered]@{
    CLAUDE_CODE_ENABLE_TELEMETRY     = '1'
    OTEL_LOGS_EXPORTER               = 'otlp'
    OTEL_EXPORTER_OTLP_LOGS_PROTOCOL = 'http/json'
    OTEL_EXPORTER_OTLP_LOGS_ENDPOINT = "http://127.0.0.1:$($cfg.port)/v1/logs"
  }
  foreach ($k in $vars.Keys) { Set-UserEnv $k $vars[$k] }
  $cfg.loggerVars = New-Object PSObject -Property $vars
  $cfg.loggerEnabled = $true
  Save-Config $cfg
  $h = Start-Collector $cfg
  if ($h) { Good "  Logger running on 127.0.0.1:$($cfg.port) (PID $($h.pid)); starts hidden at every logon." }
  else { Warn "Logger did not answer on 127.0.0.1:$($cfg.port). See $(Join-Path $DataDir 'collector.log')." }
  Add-Journal 'logger_on' @{ port = $cfg.port; healthy = [bool]$h } | Out-Null
  return $true
}
function Disable-Logger($cfg) {
  Stop-Collector $cfg
  foreach ($k in $OtelVarNames) {
    $cur = Get-UserEnv $k; $ours = $null
    if ($cfg.loggerVars -and $cfg.loggerVars.PSObject.Properties[$k]) { $ours = [string]$cfg.loggerVars.$k }
    if ($cur -and $ours -and $cur -eq $ours) { Set-UserEnv $k $null }
    elseif ($cur) { Say "  left $k=$cur alone (not set by this tool)" }
  }
  $cfg.loggerEnabled = $false; $cfg.loggerVars = $null; Save-Config $cfg
  Add-Journal 'logger_off' @{} | Out-Null
  Good '  Logger stopped and removed from autostart. Data kept.'
}

# ------------------------------------------------------------------ modes
function Get-ModeLabel([string]$m, [double]$min) {
  switch ($m) { 'baseline' { 'baseline (hook counts only, summaries unchanged)' } 'off' { 'off (no agent summaries)' } 'slow' { "slow (one summary per agent at most every $(Fmt $min) min)" } 'none' { 'no hook' } default { $m } }
}
function Detect-Legacy($cfg) {
  # A manual install (e.g. ~/.local/share/no-agent-summary.js) is adopted: its log is kept as evidence and its
  # preload is replaced by ours. The old .js file is left in place because running sessions may still load it.
  $bo = Get-UserEnv 'BUN_OPTIONS'; $legacy = @()
  foreach ($p in (Get-PreloadPaths $bo)) { if ($p -match 'no-agent-summary\.js$' -and $p -ne $cfg.hookBunPath) { $legacy += $p } }
  $ll = Get-UserEnv 'CC_AGENT_SUMMARY_LOG'
  if ($ll) { $ll = [Environment]::ExpandEnvironmentVariables($ll) }
  if ($ll -and $ll -ne $HookLogPath) {
    $list = @(); if ($cfg.legacyLogs) { $list = @($cfg.legacyLogs) }
    if ($ll -notin $list) { $list += $ll; $cfg.legacyLogs = $list }
  }
  if ($legacy.Count) {
    Say "  Found an earlier manual install: $($legacy -join ', ') (mode $(Get-UserEnv 'CC_AGENT_SUMMARY_MODE'))." 'Yellow'
    Say '  It will be replaced by this tool''s copy. The old file stays where it is (running sessions may still use it);' 'Yellow'
    Say '  you can delete it once every Claude Code process has been restarted.' 'Yellow'
    Add-Journal 'migrate' @{ legacy_preload = ($legacy -join ' '); legacy_mode = (Get-UserEnv 'CC_AGENT_SUMMARY_MODE'); legacy_log = $ll } | Out-Null
  }
}
function Set-TunerMode([string]$m, [double]$min, [bool]$wantLogger, [bool]$interactive) {
  $cfg = Get-Config; Ensure-Dir $DataDir
  $exe = Find-Claude
  if (-not $exe) { Warn 'Claude Code (claude.exe) was not found on PATH or in %USERPROFILE%\.local\bin. Install it first.'; return }
  $ver = Get-CCVersion $exe
  Head "Setting mode: $(Get-ModeLabel $m $min)"
  Say "  Claude Code $ver at $exe"
  if ($exe -notlike '*.exe') { Warn 'This looks like an npm/script install. The hook only works with the native (Bun) claude.exe.' }
  if (-not (Install-HookFile $cfg)) { Warn 'Could not place the hook in a path Bun can load (no spaces allowed). Aborting.'; return }
  Detect-Legacy $cfg
  $prevMode = $cfg.mode; $prevMin = $cfg.minutes
  $hookMode = @{ baseline = 'pass'; slow = 'slow'; off = 'off' }[$m]
  $newBo = Merge-BunOptions (Get-UserEnv 'BUN_OPTIONS') $cfg.hookBunPath
  $test = Test-HookLoads $exe $newBo
  if (-not $test.ok) {
    Warn "Self-test failed: claude --version did not load the hook. Output: $($test.out)"
    Warn 'Nothing was changed.'; return
  }
  Good "  Self-test OK: $($test.line -replace '^\S+\s+pid=\d+\s+','')"
  Set-UserEnv 'BUN_OPTIONS' $newBo
  Set-UserEnv 'CC_AGENT_SUMMARY_MODE' $hookMode
  Set-UserEnv 'CC_AGENT_SUMMARY_LOG' $HookLogPath
  if ($hookMode -eq 'slow') { Set-UserEnv 'CC_AGENT_SUMMARY_MIN_DELAY_MS' ([string][int64]([Math]::Round($min * 60000))) } else { Set-UserEnv 'CC_AGENT_SUMMARY_MIN_DELAY_MS' $null }
  $cfg.mode = $m; $cfg.minutes = $min; Save-Config $cfg
  $id = Add-Journal 'mode' @{ mode = $m; minutes = $min; hook_mode = $hookMode; prev_mode = $prevMode; prev_minutes = $prevMin; cc_version = $ver; bun_options = $newBo }
  Good "  Saved for your Windows account (user environment variables). Logged at $(LocalStr (ParseIso $id))."
  if ($wantLogger -and -not ($cfg.loggerEnabled -and (Get-CollectorHealth ([int]$cfg.port)))) { Enable-Logger $cfg $interactive | Out-Null }
  elseif ($cfg.loggerEnabled) { $h = Start-Collector $cfg; if ($h) { Say "  Logger already on (127.0.0.1:$($cfg.port))." } }
  Show-RestartGuide
  Invoke-RestartCheck $id $interactive
}
function Show-RestartGuide {
  Write-Host ''
  Write-Host '  +--------------------------------------------------------------------------------------+' -ForegroundColor Magenta
  Write-Host '  |  NOTHING CHANGES UNTIL YOU RESTART CLAUDE CODE. A process only reads these settings     |' -ForegroundColor Magenta
  Write-Host '  |  when it starts, and passes them to whatever it starts. Please:                        |' -ForegroundColor Magenta
  Write-Host '  |   1. Exit EVERY Claude Code session (type /exit; resume later with  claude -c ).        |' -ForegroundColor Magenta
  Write-Host '  |   2. Close the terminal TABS/WINDOWS they ran in and open NEW ones (old tabs keep the    |' -ForegroundColor Magenta
  Write-Host '  |      old settings). Same for VS Code / Cursor / JetBrains: restart the editor.          |' -ForegroundColor Magenta
  Write-Host '  |   3. Stop the background daemon:  claude daemon stop --any   (ends background sessions)|' -ForegroundColor Magenta
  Write-Host '  |   4. Fully quit the Claude desktop app (tray icon > Quit) and start it again.           |' -ForegroundColor Magenta
  Write-Host '  |  The measurement only counts from the moment no old process is left (checked below).    |' -ForegroundColor Magenta
  Write-Host '  +--------------------------------------------------------------------------------------+' -ForegroundColor Magenta
}
function Get-StaleProcesses([datetime]$since) {
  $cfg = Get-Config
  $procs = Get-ClaudeProcesses (Read-HookLog $cfg)
  return @($procs | Where-Object { $_.Relevant -and $_.Started -and $_.Started -lt $since })
}
function Get-PendingModeAction {
  $j = Read-Journal; $last = $j | Where-Object { $_.action -in 'mode', 'uninstall' } | Select-Object -Last 1
  if (-not $last -or $last.action -ne 'mode') { return $null }
  if ($j | Where-Object { $_.action -eq 'effective' -and $_.ref -eq $last.t }) { return $null }
  return $last
}
function Invoke-RestartCheck([string]$refId, [bool]$interactive) {
  if (-not $refId) { $p = Get-PendingModeAction; if (-not $p) { Good 'Nothing pending: the last mode change is already effective.'; return }; $refId = $p.t }
  $since = ParseIso $refId
  while ($true) {
    $stale = Get-StaleProcesses $since
    Head "Claude processes started BEFORE the change at $(LocalStr $since)"
    if (-not $stale.Count) {
      $t = Add-Journal 'effective' @{ ref = $refId; how = 'no old process left' }
      Good "  None left. The new setting is fully in effect from $(LocalStr (ParseIso $t)) (logged)."
      return
    }
    Show-Processes $stale
    if (-not $interactive) { Say "  $($stale.Count) old process(es) still running. Restart them, then run this script with -CheckRestart." 'Yellow'; return }
    $hasDaemon = [bool]($stale | Where-Object { $_.Kind -like 'Daemon*' -or $_.Kind -eq 'Background session' })
    Say '  [R] re-check   [D] stop the daemon now (ends background sessions)   [C] count from now anyway   [L] later (-CheckRestart)'
    $a = (Ask 'Choice' 'R').ToUpper()
    if ($a -eq 'D') {
      if (-not $hasDaemon) { Say '  No old daemon process in the list.' }
      if (AskYesNo '  This ends all background Claude Code sessions and their agents. Stop the daemon?' $false) {
        $exe = Find-Claude; $r = Invoke-Isolated $exe @('daemon', 'stop', '--any') @{}; Say ('  ' + $r.out.Trim()); Start-Sleep -Seconds 2
        Add-Journal 'daemon_stop' @{ ref = $refId } | Out-Null
      }
    } elseif ($a -eq 'C') {
      $t = Add-Journal 'effective' @{ ref = $refId; how = 'user confirmed'; stale_pids = (@($stale | ForEach-Object { $_.PID }) -join ',') }
      Warn "Counting from $(LocalStr (ParseIso $t)) although $($stale.Count) old process(es) still run; the report marks this."
      return
    } elseif ($a -eq 'L') { Say '  OK. Run again with -CheckRestart (or menu item 6) after restarting. Until then the report treats this as a transition.'; return }
  }
}

# ------------------------------------------------------------------ status
function Read-Events([switch]$IncludeTagged) {
  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($f in @(Get-ChildItem -LiteralPath $DataDir -Filter 'events-*.tsv' -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $first = $true; $idx = @{}
    foreach ($l in [IO.File]::ReadLines($f.FullName)) {
      $c = $l.Split("`t")
      if ($first) { for ($i = 0; $i -lt $c.Count; $i++) { $idx[$c[$i]] = $i }; $first = $false; continue }
      $g = { param($n) if ($idx.ContainsKey($n) -and $idx[$n] -lt $c.Count) { $c[$idx[$n]] } else { '' } }
      $t = ParseIso (& $g 't'); if (-not $t) { continue }
      $tag = & $g 'tag'
      if ($tag -and -not $IncludeTagged) { continue }
      $rows.Add([pscustomobject]@{ t = $t; ev = (& $g 'event'); session = (& $g 'session'); model = (& $g 'model'); qs = (& $g 'query_source'); cost = (ParseNum (& $g 'cost_usd'));
          inTok = (ParseNum (& $g 'input_tokens')); outTok = (ParseNum (& $g 'output_tokens')); cr = (ParseNum (& $g 'cache_read_tokens')); cw = (ParseNum (& $g 'cache_creation_tokens'));
          ver = (& $g 'version'); agent = (& $g 'agent'); tag = $tag })
    }
  }
  return $rows
}
function Show-Status {
  $cfg = Get-Config
  Head "$ToolName $ToolVersion - status"
  $m = Get-UserEnv 'CC_AGENT_SUMMARY_MODE'; $bo = Get-UserEnv 'BUN_OPTIONS'
  Say "  Data folder        : $DataDir"
  Say "  Mode (saved)       : $(if ($cfg.mode) { Get-ModeLabel $cfg.mode ([double]$cfg.minutes) } elseif ($bo -match 'no-agent-summary\.js') { 'not installed by this tool, but a manual install of the hook is active (it is adopted on the first mode change)' } else { 'not installed' })"
  Say "  CC_AGENT_SUMMARY_MODE=$m  MIN_DELAY_MS=$(Get-UserEnv 'CC_AGENT_SUMMARY_MIN_DELAY_MS')"
  Say "  BUN_OPTIONS        : $bo"
  $pre = Get-PreloadPaths $bo
  foreach ($p in $pre) { $ok = Test-Path -LiteralPath ($p -replace '/', '\'); Say "    preload $p -> $(if ($ok) { 'file exists' } else { 'MISSING FILE: Claude Code will fail to start!' })" $(if ($ok) { 'Gray' } else { 'Red' }) }
  $exe = Find-Claude; $ver = Get-CCVersion $exe
  Say "  Claude Code        : $ver ($exe)"
  $desk = @(Get-ChildItem -LiteralPath (Join-Path $env:APPDATA 'Claude\claude-code') -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
  if ($desk.Count) { Say "  Desktop app CLI    : $($desk -join ', ') (bundled; runs Code-tab sessions)" }
  if ($exe -and $exe -like '*.exe' -and $ver) {
    $cache = @{}; if ($cfg.anchorCache) { foreach ($p in $cfg.anchorCache.PSObject.Properties) { $cache[$p.Name] = $p.Value } }
    if (-not $cache.ContainsKey($ver)) { Say '  (scanning the binary for the summary timer anchor once for this version...)'; $a = Find-BinaryAnchors $exe; $cache[$ver] = [bool]$a['[AgentSummary] Timer fired']; $cfg.anchorCache = New-Object PSObject -Property $cache; Save-Config $cfg }
    if ($cache[$ver]) { Good "  Static check       : anchor '[AgentSummary] Timer fired' present in $ver" } else { Warn "anchor '[AgentSummary] Timer fired' NOT found in $ver - the hook probably matches nothing now (fail-open)." }
  }
  if ($cfg.mode -and $bo) { $t = Test-HookLoads $exe $bo; if ($t.ok) { Good '  Hook load test     : OK' } else { Warn "hook does NOT load with the saved BUN_OPTIONS: $($t.out)" } }
  $h = Get-CollectorHealth ([int]$cfg.port)
  $run = (Get-ItemProperty -Path $RunKeyPath -Name $RunValueName -ErrorAction SilentlyContinue).$RunValueName
  Say "  Logger             : $(if ($cfg.loggerEnabled) { 'on' } else { 'off' }), port $($cfg.port), autostart $(if ($run) { 'yes' } else { 'no' }), $(if ($h) { "running (PID $($h.pid), $($h.stored) events stored since start)" } else { 'NOT running' })"
  if ($cfg.loggerEnabled -and -not $h) { Warn "the logger is not running. Re-run this script with -Logger on, or check $(Join-Path $DataDir 'collector.log')." }
  $ev = Read-Events
  $req = @($ev | Where-Object { $_.ev -eq 'api_request' })
  $as = @($req | Where-Object { $_.qs -eq 'agent_summary' })
  $d1 = (NowUtc).AddDays(-1)
  Say "  Data               : $($req.Count) API requests recorded ($(@($req | Where-Object { $_.t -ge $d1 }).Count) in the last 24 h), $($as.Count) agent_summary"
  if ($req.Count) { Say "  Last request       : $(LocalStr ($req | Select-Object -Last 1).t)" }
  $pend = Get-PendingModeAction
  if ($pend) { Warn "the last mode change ($(LocalStr (ParseIso $pend.t))) is not confirmed effective yet. Restart Claude Code, then run -CheckRestart." }
  else {
    $eff = Read-Journal | Where-Object { $_.action -eq 'effective' } | Select-Object -Last 1
    if ($eff -and $cfg.mode -eq 'off') {
      $after = @($as | Where-Object { $_.t -gt (ParseIso $eff.t) })
      if ($after.Count) { Warn "$($after.Count) agent_summary request(s) since mode 'off' took effect. The hook may no longer match (Claude Code update?) or a process runs without it." }
    }
  }
  $hr = Read-HookLog $cfg
  $procs = Get-ClaudeProcesses $hr
  Head 'Running Claude processes'
  Show-Processes $procs
  $unhooked = @($procs | Where-Object { $_.Relevant -and $_.Hook -eq 'NO' -and $_.Kind -ne 'Desktop app (restart it)' })
  if ($cfg.mode -and $unhooked.Count) { Warn "$($unhooked.Count) Claude Code process(es) run WITHOUT the hook (started before the install, from an old terminal, or BUN_OPTIONS did not reach them)." }
  $conf = Get-OtelConflicts $cfg
  if ($conf.Count) { Say '  Other telemetry settings found:' 'Yellow'; $conf | ForEach-Object { Say "   - $_" 'Yellow' } }
}

# ------------------------------------------------------------------ uninstall
function Invoke-Uninstall([bool]$interactive) {
  $cfg = Get-Config
  Head 'Uninstall'
  $delete = $false
  if ($DeleteData) { $delete = $true } elseif ($KeepData) { $delete = $false } elseif ($interactive) { $delete = AskYesNo "Also delete the measurement data in $DataDir ?" $false }
  if ($cfg.loggerEnabled -or (Get-ItemProperty -Path $RunKeyPath -Name $RunValueName -ErrorAction SilentlyContinue)) { Disable-Logger $cfg }
  else { Stop-Collector $cfg }
  $bo = Get-UserEnv 'BUN_OPTIONS'
  if ($bo) { $rest = Remove-OurPreload $bo; Set-UserEnv 'BUN_OPTIONS' $rest; if ($rest) { Say "  BUN_OPTIONS kept with: $rest" } else { Say '  BUN_OPTIONS removed' } }
  foreach ($k in $TunerVars) { if (Get-UserEnv $k) { Set-UserEnv $k $null; Say "  removed $k" } }
  $running = @(Get-ClaudeProcesses $null | Where-Object { $_.Relevant -and $_.Kind -ne 'Desktop app (restart it)' })
  $stub = "// Removed by $ToolName. Running Claude Code processes may still list this file in BUN_OPTIONS;`n// it does nothing. Delete it after every Claude Code process has been restarted.`n"
  foreach ($hp in @($cfg.hookPath)) {
    if (-not $hp -or -not (Test-Path -LiteralPath $hp)) { continue }
    if ($running.Count) { Write-Text $hp $stub; Say "  $($running.Count) Claude process(es) still run with the old settings, so the hook file was replaced by a do-nothing stub instead of deleted (a missing preload file would stop Claude Code from starting): $hp" 'Yellow' }
    else { Remove-Item -LiteralPath $hp -Force; Say "  deleted $hp" }
  }
  Add-Journal 'uninstall' @{ deleted_data = $delete } | Out-Null
  if ($delete) {
    Get-ChildItem -LiteralPath $DataDir -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $cfg.hookPath } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Get-ChildItem -LiteralPath $DataDir -Force -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $DataDir -Force -ErrorAction SilentlyContinue }
    Say "  data deleted"
  } else { Say "  data kept in $DataDir (reports still work: run with -Report)" }
  Good 'Uninstalled. Restart Claude Code sessions, terminals, the daemon and the desktop app for it to take full effect.'
}

# ------------------------------------------------------------------ report
function HtmlEnc([object]$s) { return [System.Net.WebUtility]::HtmlEncode([string]$s) }
function Money([double]$x) { if ($x -ge 100) { return '$' + (Fmt $x '0') }; if ($x -ge 1) { return '$' + (Fmt $x '0.00') }; return '$' + (Fmt $x '0.000') }
function Pct([double]$a, [double]$b) { if ($b -le 0) { return '-' }; return (Fmt (100 * $a / $b) '0.0') + '%' }
function Get-Periods($journal, $events) {
  $acts = @($journal | Where-Object { $_.action -in 'mode', 'uninstall' } | Sort-Object { ParseIso $_.t })
  $now = NowUtc; $periods = @()
  $firstEv = $null; if ($events.Count) { $firstEv = $events[0].t }
  if ($firstEv -and (-not $acts.Count -or $firstEv -lt (ParseIso $acts[0].t))) {
    $end = $now; if ($acts.Count) { $end = ParseIso $acts[0].t }
    $periods += [pscustomobject]@{ label = 'before tuner (no hook)'; mode = 'none'; start = $firstEv; end = $end; confirmed = 'n/a'; ref = $null }
  }
  for ($i = 0; $i -lt $acts.Count; $i++) {
    $a = $acts[$i]; if ($a.action -ne 'mode') { continue }
    $t = ParseIso $a.t; $end = $now; if ($i + 1 -lt $acts.Count) { $end = ParseIso $acts[$i + 1].t }
    $eff = $journal | Where-Object { $_.action -eq 'effective' -and $_.ref -eq $a.t } | Select-Object -First 1
    $start = $t; $conf = 'NOT confirmed (old sessions may still run)'
    if ($eff) { $start = ParseIso $eff.t; $conf = [string]$eff.how }
    if ($start -ge $end) { continue }
    $lbl = $a.mode; if ($a.mode -eq 'slow') { $lbl = "slow $(Fmt ([double]$a.minutes)) min" }
    $periods += [pscustomobject]@{ label = $lbl; mode = $a.mode; start = $start; end = $end; confirmed = $conf; ref = $a.t; changeAt = $t }
  }
  return $periods
}
function Get-PeriodStats($p, $events, $hookRows) {
  $ev = @($events | Where-Object { $_.ev -eq 'api_request' -and $_.t -ge $p.start -and $_.t -lt $p.end })
  $as = @($ev | Where-Object { $_.qs -eq 'agent_summary' })
  $buckets = @{}; foreach ($e in $ev) { $buckets[[int64]([Math]::Floor($e.t.Ticks / 3000000000))] = 1 }   # 5-minute buckets
  $activeH = $buckets.Count * 5 / 60
  $cost = ($ev | Measure-Object cost -Sum).Sum; if (-not $cost) { $cost = 0 }
  $asCost = ($as | Measure-Object cost -Sum).Sum; if (-not $asCost) { $asCost = 0 }
  $hr = @($hookRows | Where-Object { $_.t -ge $p.start -and $_.t -lt $p.end })
  $sup = 0; $slo = 0; $mat = 0
  foreach ($r in $hr) { if ($r.msg -match '^exit: (\d+) summary timer\(s\) suppressed, (?:(\d+) slowed, )?(\d+) matched') { $sup += [int]$matches[1]; if ($matches[2]) { $slo += [int]$matches[2] }; $mat += [int]$matches[3] } }
  $loads = @($hr | Where-Object { $_.msg -like 'preload active*' })
  $modes = ($loads | ForEach-Object { if ($_.msg -match 'mode=(\S+)') { $matches[1] } } | Group-Object | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ', '
  $vers = (@($ev | Where-Object { $_.ver } | ForEach-Object { $_.ver } | Sort-Object -Unique)) -join ', '
  return [pscustomobject]@{
    p = $p; reqs = $ev.Count; cost = [double]$cost; asReqs = $as.Count; asCost = [double]$asCost; activeH = $activeH
    hours = ($p.end - $p.start).TotalHours; versions = $vers; hookLoads = $loads.Count; hookModes = $modes
    timerLines = @($hr | Where-Object { $_.msg -like 'summary timer #*' }).Count; matched = $mat; suppressed = $sup; slowed = $slo
  }
}
function New-HBarSvg($items, [string]$unit) {
  # items: label, value, color, text
  $w = 760; $rowH = 26; $lw = 230; $h = [Math]::Max(1, $items.Count) * $rowH + 10
  $max = ($items | Measure-Object value -Maximum).Maximum; if (-not $max -or $max -le 0) { $max = 1 }
  $sb = New-Object Text.StringBuilder
  [void]$sb.Append("<svg viewBox='0 0 $w $h' width='100%' style='max-width:${w}px' xmlns='http://www.w3.org/2000/svg' font-family='Segoe UI,Arial' font-size='12'>")
  $y = 5
  foreach ($it in $items) {
    $bw = [Math]::Max(1, ($w - $lw - 120) * $it.value / $max)
    [void]$sb.Append("<text x='$($lw - 8)' y='$(Fmt ($y + 17))' text-anchor='end' fill='#ddd'>$(HtmlEnc $it.label)</text>")
    [void]$sb.Append("<rect x='$lw' y='$(Fmt ($y + 4))' width='$(Fmt $bw)' height='$(Fmt ($rowH - 8))' rx='3' fill='$($it.color)'/>")
    [void]$sb.Append("<text x='$(Fmt ($lw + $bw + 6))' y='$(Fmt ($y + 17))' fill='#bbb'>$(HtmlEnc $it.text)</text>")
    $y += $rowH
  }
  [void]$sb.Append('</svg>'); return $sb.ToString()
}
function New-TimelineSvg($events, $journal, [datetime]$from, [datetime]$to) {
  $span = ($to - $from).TotalHours; $bh = 1; if ($span -gt 48) { $bh = 6 }; if ($span -gt 24 * 14) { $bh = 24 }
  $b0 = New-Object DateTime ($from.Year, $from.Month, $from.Day, 0, 0, 0, [DateTimeKind]::Utc)
  $n = [int][Math]::Ceiling(($to - $b0).TotalHours / $bh); if ($n -lt 1) { $n = 1 }
  $as = New-Object double[] $n; $ot = New-Object double[] $n
  foreach ($e in $events) { if ($e.ev -ne 'api_request') { continue }; $i = [int][Math]::Floor(($e.t - $b0).TotalHours / $bh); if ($i -ge 0 -and $i -lt $n) { if ($e.qs -eq 'agent_summary') { $as[$i] += $e.cost } else { $ot[$i] += $e.cost } } }
  $max = 0.0; for ($i = 0; $i -lt $n; $i++) { if ($as[$i] + $ot[$i] -gt $max) { $max = $as[$i] + $ot[$i] } }; if ($max -le 0) { $max = 1 }
  $W = 960; $Hh = 300; $L = 60; $R = 20; $mTop = 30; $B = 50; $pw = $W - $L - $R; $ph = $Hh - $mTop - $B; $bw = $pw / $n
  $sb = New-Object Text.StringBuilder
  [void]$sb.Append("<svg viewBox='0 0 $W $Hh' width='100%' style='max-width:${W}px' xmlns='http://www.w3.org/2000/svg' font-family='Segoe UI,Arial' font-size='11'>")
  foreach ($g in 0, 0.5, 1) { $yy = $mTop + $ph * (1 - $g); [void]$sb.Append("<line x1='$L' x2='$($W - $R)' y1='$(Fmt $yy)' y2='$(Fmt $yy)' stroke='#333'/><text x='$($L - 6)' y='$(Fmt ($yy + 4))' text-anchor='end' fill='#999'>$(HtmlEnc (Money ($max * $g)))</text>") }
  for ($i = 0; $i -lt $n; $i++) {
    $x = $L + $i * $bw; $h1 = $ph * $ot[$i] / $max; $h2 = $ph * $as[$i] / $max
    if ($h1 -gt 0) { [void]$sb.Append("<rect x='$(Fmt ($x + 0.5))' y='$(Fmt ($mTop + $ph - $h1))' width='$(Fmt ([Math]::Max(0.5, $bw - 1)))' height='$(Fmt $h1)' fill='#5b6b8c'/>") }
    if ($h2 -gt 0) { [void]$sb.Append("<rect x='$(Fmt ($x + 0.5))' y='$(Fmt ($mTop + $ph - $h1 - $h2))' width='$(Fmt ([Math]::Max(0.5, $bw - 1)))' height='$(Fmt $h2)' fill='#ff6b3d'><title>$(HtmlEnc (LocalStr ($b0.AddHours($i * $bh)))): agent_summary $(HtmlEnc (Money $as[$i])), other $(HtmlEnc (Money $ot[$i]))</title></rect>") }
  }
  $ticks = [Math]::Min(8, $n)
  for ($k = 0; $k -le $ticks; $k++) { $i = [int]($n * $k / $ticks); $x = $L + $i * $bw; $d = $b0.AddHours($i * $bh).ToLocalTime(); [void]$sb.Append("<text x='$(Fmt $x)' y='$($Hh - $B + 16)' text-anchor='middle' fill='#999'>$(HtmlEnc $d.ToString('MM-dd HH:mm', $Inv))</text>") }
  $num = 0
  foreach ($a in @($journal | Where-Object { $_.action -in 'mode', 'effective', 'logger_on', 'logger_off', 'uninstall', 'replicate' })) {
    $t = ParseIso $a.t; if ($t -lt $b0 -or $t -gt $b0.AddHours($n * $bh)) { continue }
    $num++; $x = $L + ($t - $b0).TotalHours / $bh * $bw
    $col = @{ mode = '#b388ff'; effective = '#4caf50'; logger_on = '#29b6f6'; logger_off = '#29b6f6'; uninstall = '#ef5350'; replicate = '#ffca28' }[$a.action]
    $txt = $a.action; if ($a.action -eq 'mode') { $txt = "mode: $($a.mode)$(if ($a.mode -eq 'slow') { ' ' + (Fmt ([double]$a.minutes)) + 'm' })" }
    [void]$sb.Append("<line x1='$(Fmt $x)' x2='$(Fmt $x)' y1='$($mTop - 4)' y2='$($mTop + $ph)' stroke='$col' stroke-dasharray='4 3' stroke-width='1.5'><title>$(HtmlEnc (LocalStr $t)) $(HtmlEnc $txt)</title></line><text x='$(Fmt ($x + 3))' y='$(Fmt ($mTop - 8 + ($num % 2) * 11))' fill='$col'>$num</text>")
    $script:markerLegend += "<li><span style='color:$col'>$num</span> $(HtmlEnc (LocalStr $t)) - $(HtmlEnc $txt)</li>"
  }
  [void]$sb.Append("<text x='$L' y='$($Hh - 8)' fill='#999'>bucket = $bh h. Orange = agent_summary, blue-grey = everything else (Claude Code's cost estimate).</text></svg>")
  return $sb.ToString()
}
function New-Report {
  $cfg = Get-Config
  $journal = @(Read-Journal); $events = @(Read-Events | Sort-Object t); $hookRows = Read-HookLog $cfg
  $req = @($events | Where-Object { $_.ev -eq 'api_request' })
  $periods = @(Get-Periods $journal $events)
  $stats = @($periods | ForEach-Object { Get-PeriodStats $_ $events $hookRows })
  # ---- console summary
  Head 'Report'
  if (-not $req.Count) { Warn 'No API requests recorded yet (replicate test runs are not counted here). Is the logger on (-Status)? Did you restart Claude Code after turning it on?' }
  $stats | ForEach-Object {
    $ph = 0; if ($_.activeH -gt 0) { $ph = $_.asCost / $_.activeH }
    [pscustomobject]@{ Period = $_.p.label; From = (LocalStr $_.p.start); 'Active h' = (Fmt $_.activeH '0.0'); Requests = $_.reqs; 'Est. cost' = (Money $_.cost); 'agent_summary reqs' = $_.asReqs; 'agent_summary cost' = (Money $_.asCost); 'Share of cost' = (Pct $_.asCost $_.cost); 'AS $/active h' = (Money $ph) }
  } | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
  # ---- HTML
  $script:markerLegend = ''
  $sb = New-Object Text.StringBuilder
  $title = "Claude Code agent_summary report - $env:COMPUTERNAME - $(LocalStr (NowUtc))"
  [void]$sb.Append("<!doctype html><html><head><meta charset='utf-8'><title>$(HtmlEnc $title)</title><style>body{background:#14161c;color:#e6e6e6;font:14px/1.5 'Segoe UI',Arial,sans-serif;margin:24px auto;max-width:1040px;padding:0 16px}h1{font-size:22px}h2{font-size:17px;margin-top:32px;border-bottom:1px solid #333;padding-bottom:4px}table{border-collapse:collapse;width:100%;margin:8px 0}th,td{border-bottom:1px solid #2a2d36;padding:5px 8px;text-align:right;font-variant-numeric:tabular-nums}th{color:#aab;font-weight:600;background:#1b1e26;font-size:12px}table{font-size:13px}td:first-child,th:first-child{text-align:left}.warn{color:#ffca28}.muted{color:#8a8f9c}.card{display:inline-block;background:#1b1e26;border-radius:8px;padding:10px 16px;margin:4px 8px 4px 0}.card b{font-size:20px;display:block}code{background:#222;padding:1px 4px;border-radius:3px}ul{margin:4px 0}</style></head><body>")
  [void]$sb.Append("<h1>$(HtmlEnc $title)</h1><p class='muted'>Generated by $ToolName $ToolVersion. Data folder: <code>$(HtmlEnc $DataDir)</code>. Times are local ($(HtmlEnc ([TimeZoneInfo]::Local.Id))).</p>")
  $tc = ($req | Measure-Object cost -Sum).Sum; if (-not $tc) { $tc = 0 }
  $asAll = @($req | Where-Object { $_.qs -eq 'agent_summary' }); $ac = ($asAll | Measure-Object cost -Sum).Sum; if (-not $ac) { $ac = 0 }
  [void]$sb.Append("<div><span class='card'>API requests<b>$($req.Count)</b></span><span class='card'>Est. cost<b>$(HtmlEnc (Money $tc))</b></span><span class='card'>agent_summary requests<b>$($asAll.Count) ($(Pct $asAll.Count $req.Count))</b></span><span class='card'>agent_summary est. cost<b>$(HtmlEnc (Money $ac)) ($(Pct $ac $tc))</b></span></div>")
  [void]$sb.Append("<h2>Periods (split at the moments each change took effect)</h2><table><tr><th>Period</th><th>From</th><th>To</th><th>Effective?</th><th>Active h</th><th>Requests</th><th>Est. cost</th><th>agent_summary reqs</th><th>agent_summary cost</th><th>share of cost</th><th>share of reqs</th><th>AS reqs / active h</th><th>AS $ / active h</th><th>total $ / active h</th><th>CC versions</th></tr>")
  foreach ($s in $stats) {
    $ah = $s.activeH; $f = { param($x) if ($ah -gt 0) { $x / $ah } else { 0 } }
    [void]$sb.Append("<tr><td>$(HtmlEnc $s.p.label)</td><td>$(HtmlEnc (LocalStr $s.p.start))</td><td>$(HtmlEnc (LocalStr $s.p.end))</td><td>$(HtmlEnc $s.p.confirmed)</td><td>$(Fmt $ah '0.0')</td><td>$($s.reqs)</td><td>$(HtmlEnc (Money $s.cost))</td><td>$($s.asReqs)</td><td>$(HtmlEnc (Money $s.asCost))</td><td>$(Pct $s.asCost $s.cost)</td><td>$(Pct $s.asReqs $s.reqs)</td><td>$(Fmt (& $f $s.asReqs) '0.0')</td><td>$(HtmlEnc (Money (& $f $s.asCost)))</td><td>$(HtmlEnc (Money (& $f $s.cost)))</td><td>$(HtmlEnc $s.versions)</td></tr>")
  }
  [void]$sb.Append("</table><p class='muted'>Active hour = 5-minute slots with at least one API request, so idle nights do not dilute the comparison. Requests between a change and the moment it took effect (old sessions still running) are left out. Replicate test runs are left out.</p>")
  if ($stats.Count) {
    $items = @($stats | ForEach-Object { $v = 0; if ($_.activeH -gt 0) { $v = $_.asCost / $_.activeH }; [pscustomobject]@{ label = $_.p.label; value = $v; color = '#ff6b3d'; text = "$(Money $v) per active h ($(Pct $_.asCost $_.cost) of cost)" } })
    [void]$sb.Append('<h2>agent_summary cost per active hour, by period</h2>' + (New-HBarSvg $items '$'))
  }
  if ($req.Count) {
    [void]$sb.Append('<h2>Timeline</h2>' + (New-TimelineSvg $events $journal $req[0].t (NowUtc)) + "<ul class='muted'>$($script:markerLegend)</ul>")
    foreach ($dim in @(@('qs', 'query_source (what the request was for)'), @('model', 'model'))) {
      $g = @($req | Group-Object { $v = $_.($dim[0]); if ($v) { $v } else { '(none)' } } | ForEach-Object { [pscustomobject]@{ k = $_.Name; n = $_.Count; c = [double](($_.Group | Measure-Object cost -Sum).Sum); i = [double](($_.Group | Measure-Object inTok -Sum).Sum); cr = [double](($_.Group | Measure-Object cr -Sum).Sum); cw = [double](($_.Group | Measure-Object cw -Sum).Sum); o = [double](($_.Group | Measure-Object outTok -Sum).Sum) } } | Sort-Object c -Descending)
      [void]$sb.Append("<h2>Share by $(HtmlEnc $dim[1]) - all periods</h2>")
      $items = @($g | Select-Object -First 12 | ForEach-Object { $col = '#5b6b8c'; if ($_.k -eq 'agent_summary') { $col = '#ff6b3d' }; [pscustomobject]@{ label = $_.k; value = $_.c; color = $col; text = "$(Money $_.c) ($(Pct $_.c $tc)), $($_.n) reqs ($(Pct $_.n $req.Count))" } })
      [void]$sb.Append((New-HBarSvg $items '$'))
      [void]$sb.Append('<table><tr><th>' + (HtmlEnc $dim[0]) + '</th><th>requests</th><th>% reqs</th><th>est. cost</th><th>% cost</th><th>input</th><th>cache read</th><th>cache write</th><th>output</th></tr>')
      foreach ($r in $g) { [void]$sb.Append("<tr><td>$(HtmlEnc $r.k)</td><td>$($r.n)</td><td>$(Pct $r.n $req.Count)</td><td>$(HtmlEnc (Money $r.c))</td><td>$(Pct $r.c $tc)</td><td>$(Fmt $r.i '0')</td><td>$(Fmt $r.cr '0')</td><td>$(Fmt $r.cw '0')</td><td>$(Fmt $r.o '0')</td></tr>") }
      [void]$sb.Append('</table>')
    }
  }
  [void]$sb.Append("<h2>Hook evidence (from the hook log)</h2><table><tr><th>Period</th><th>hook loads (processes)</th><th>modes seen</th><th>timer lines logged</th><th>matched (at exit)</th><th>slowed</th><th>suppressed</th></tr>")
  foreach ($s in $stats) { [void]$sb.Append("<tr><td>$(HtmlEnc $s.p.label)</td><td>$($s.hookLoads)</td><td>$(HtmlEnc $s.hookModes)</td><td>$($s.timerLines)</td><td>$($s.matched)</td><td>$($s.slowed)</td><td>$($s.suppressed)</td></tr>") }
  [void]$sb.Append("</table><p class='muted'>Each Claude Code process writes one 'preload active' line when the hook loads and a total when it exits. A period in slow/off mode with hook loads but zero matched timers while agents ran means the hook no longer recognises the summary timer (fail-open).</p>")
  $reps = @(Get-ChildItem -LiteralPath (Join-Path $DataDir 'replicate') -Filter 'results.json' -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)
  if ($reps.Count) {
    [void]$sb.Append("<h2>Replicate runs (Flamerix 'Tested versions' protocol)</h2><table><tr><th>When</th><th>version</th><th>sha256</th><th>static</th><th>summary forks: no hook / pass / off</th><th>timer fired</th><th>slow arm</th><th>agent_summary requests (telemetry)</th><th>est. cost</th><th>debug files</th></tr>")
    foreach ($f in $reps) {
      try { $r = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
      [void]$sb.Append("<tr><td>$(HtmlEnc (LocalStr (ParseIso $r.t)))</td><td>$(HtmlEnc $r.version)</td><td><code>$(HtmlEnc $r.sha12)</code></td><td>$(HtmlEnc $r.static)</td><td><b>$(HtmlEnc $r.forks)</b></td><td>$(HtmlEnc $r.fired)</td><td>$(HtmlEnc $r.slow)</td><td>$(HtmlEnc $r.telemetry)</td><td>$(HtmlEnc $r.cost)</td><td class='muted' style='text-align:left'>$(HtmlEnc $f.DirectoryName)</td></tr>")
    }
    [void]$sb.Append("</table><p class='muted'>Flamerix's published row for 2.1.312: 5 / 5 / 0.</p>")
  }
  [void]$sb.Append('<h2>Action journal</h2><table><tr><th>When</th><th>Action</th><th>Details</th></tr>')
  foreach ($a in $journal) { $d = ($a.PSObject.Properties | Where-Object { $_.Name -notin 't', 'action', 'bun_options' -and $null -ne $_.Value -and "$($_.Value)" -ne '' } | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '; '; [void]$sb.Append("<tr><td>$(HtmlEnc (LocalStr (ParseIso $a.t)))</td><td>$(HtmlEnc $a.action)</td><td style='text-align:left'>$(HtmlEnc $d)</td></tr>") }
  [void]$sb.Append("</table><h2>Caveats</h2><ul><li><b>cost_usd is Claude Code's own estimate</b> at API list prices, not an invoice. On a Pro/Max subscription it stands for rate-limit headroom you use up, not money.</li><li>Periods differ in workload. Compare per-active-hour numbers and the agent_summary <i>share</i>, and collect a few days per period. The summary only runs while background agents/subagents run.</li><li><b>Fail-open:</b> a Claude Code update can rename what the hook looks for. Then summaries silently come back. Check the CC versions column, the hook evidence table and run <code>-Status</code> / <code>-Replicate</code> after updates.</li><li>Processes that started before a change keep the old setting; periods start only when none was left (or when you confirmed). The Claude desktop app's Code tab runs its own bundled Claude Code; whether it passes your user environment through is not documented - check the process table in <code>-Status</code> for 'Hook loaded'.</li><li>The logger stores only: time, event type, session id, model, query_source, token counts, cost estimate, duration, Claude Code version and agent type. No prompts, responses, e-mail or account ids. Only what reaches 127.0.0.1 on this PC.</li><li>Unofficial tool; changing client behaviour may conflict with the service terms. Hook (c) Flamerix AI, MIT.</li></ul></body></html>")
  $out = $ReportTo; if (-not $out) { $out = Join-Path $DataDir ('report-' + (Get-Date).ToString('yyyyMMdd-HHmm', $Inv) + '.html') }
  Ensure-Dir (Split-Path $out -Parent); Write-Text $out $sb.ToString()
  Good "  HTML report: $out"
  if (-not $NoOpen) { try { Invoke-Item -LiteralPath $out } catch {} }
  return $out
}

# ------------------------------------------------------------------ replicate Flamerix's protocol
$ReplicatePrompt = "This is a timing test, do exactly this. Use the Agent tool exactly once to start ONE general-purpose subagent in the foreground and wait for it to finish. Give the subagent exactly this task: Run the shell command 'sleep 20' eight times, strictly one at a time, one tool call per step, never in parallel and never in the background (in PowerShell 'Start-Sleep 20' is the same). After the eighth, reply with the single word done. Do not run any commands yourself. When the subagent has finished, reply with the single word done."
function Invoke-Replicate([bool]$interactive) {
  $cfg = Get-Config; Ensure-Dir $DataDir
  $exe = Find-Claude
  if (-not $exe -or $exe -notlike '*.exe') { Warn "Native claude.exe not found ($exe)."; return }
  Head 'Replicate Flamerix''s "Tested versions" protocol'
  $ver = Get-CCVersion $exe
  Say "  1/2 Static check of $exe ..."
  $sha = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash.ToLower().Substring(0, 12)
  $anch = Find-BinaryAnchors $exe
  $static = 'missing'; if ($anch['[AgentSummary] Timer fired'] -and $anch['agent_summary']) { $static = 'OK' }
  Say "      version $ver, sha256 $sha, anchors: '[AgentSummary] Timer fired'=$($anch['[AgentSummary] Timer fired']), 'agent_summary'=$($anch['agent_summary'])"
  $slowMin = $ReplicateSlowMinutes
  if ($interactive -and -not $slowMin) { $a = Ask '  Optional 4th arm: hook in slow mode. Minutes (0.5-240, empty = skip)' ''; if ($a) { $slowMin = ParseNum $a } }
  if ($slowMin -and ($slowMin -lt 0.5 -or $slowMin -gt 240)) { Warn 'Slow minutes must be 0.5-240; skipping the slow arm.'; $slowMin = 0 }
  $arms = @('nohook', 'pass', 'off'); if ($slowMin) { $arms += 'slow' }
  Say "  2/2 Live A/B: $($arms.Count) runs of 'claude -p --model haiku', each with one subagent doing 8 x 'sleep 20' (~3-4 min per run)."
  Say '      Uses your Claude login and a small amount of Haiku usage (typically a few US cents per run).' 'Yellow'
  Say '      Settings are set for these child processes only; your saved settings are not touched.' 'Yellow'
  if (-not $Yes -and -not ($interactive -and (AskYesNo '  Start the live runs?' $true))) { if (-not $interactive) { Say '  Add -Yes to run non-interactively.' }; return }
  if (-not (Install-HookFile $cfg)) { Warn 'Could not place the hook file.'; return }
  Save-Config $cfg
  $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss', $Inv)
  $runDir = Join-Path (Join-Path $DataDir 'replicate') $stamp; Ensure-Dir $runDir
  $cport = [int]$cfg.port; if ($Port) { $cport = $Port }
  $health = $null; if ($cport) { $health = Get-CollectorHealth $cport }
  if ($health) { Say "      Logger is running on port $cport, so the runs' API requests are also recorded (tagged, kept out of normal periods)." } else { Say '      Logger not running: counting from the debug logs only.' }
  $res = [ordered]@{}
  foreach ($arm in $arms) {
    $dir = Join-Path $runDir $arm; Ensure-Dir $dir
    $dbg = Join-Path $dir 'debug.log'; $hl = Join-Path $dir 'hook.log'; $outF = Join-Path $dir 'output.json'; $errF = Join-Path $dir 'stderr.txt'; $inF = Join-Path $dir 'stdin.txt'; Write-Text $inF ''
    $envO = @{ BUN_OPTIONS = $null; CC_AGENT_SUMMARY_MODE = $null; CC_AGENT_SUMMARY_LOG = $null; CC_AGENT_SUMMARY_MIN_DELAY_MS = $null; CLAUDE_CODE_AGENT_PROGRESS_SUMMARIES = '1'; CLAUDE_CODE_SUBAGENT_MODEL = 'haiku' }
    if ($arm -ne 'nohook') {
      $envO.BUN_OPTIONS = Merge-BunOptions (Remove-OurPreload ([Environment]::GetEnvironmentVariable('BUN_OPTIONS', 'Process'))) $cfg.hookBunPath
      $envO.CC_AGENT_SUMMARY_MODE = $arm; $envO.CC_AGENT_SUMMARY_LOG = $hl
      if ($arm -eq 'slow') { $envO.CC_AGENT_SUMMARY_MIN_DELAY_MS = [string][int64]($slowMin * 60000) }
    } else {
      $rest = Remove-OurPreload ([Environment]::GetEnvironmentVariable('BUN_OPTIONS', 'Process')); if ($rest) { $envO.BUN_OPTIONS = $rest }
    }
    if ($health) {
      $ra = [Environment]::GetEnvironmentVariable('OTEL_RESOURCE_ATTRIBUTES', 'Process'); $tag = "cc_tuner.tag=replicate-$stamp-$arm"
      $envO.CLAUDE_CODE_ENABLE_TELEMETRY = '1'; $envO.OTEL_LOGS_EXPORTER = 'otlp'; $envO.OTEL_EXPORTER_OTLP_LOGS_PROTOCOL = 'http/json'
      $envO.OTEL_EXPORTER_OTLP_LOGS_ENDPOINT = "http://127.0.0.1:$cport/v1/logs"; $envO.OTEL_RESOURCE_ATTRIBUTES = $(if ($ra) { "$ra,$tag" } else { $tag })
    }
    $argStr = "-p `"$ReplicatePrompt`" --model haiku --debug-file `"$dbg`" --setting-sources project --strict-mcp-config --permission-mode dontAsk --permission-prompts none --allowedTools `"Agent,Task,Bash(sleep *),PowerShell(sleep *),PowerShell(Start-Sleep *)`" --no-session-persistence --output-format json"
    Say "      [$arm] running... (started $(Get-Date -Format 'HH:mm:ss'))"
    $saved = @{}; foreach ($k in $envO.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k, 'Process'); [Environment]::SetEnvironmentVariable($k, $envO[$k], 'Process') }
    $t0 = Get-Date
    try {
      $p = Start-Process -FilePath $exe -ArgumentList $argStr -WorkingDirectory $dir -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF -NoNewWindow -PassThru
      if (-not $p.WaitForExit(900000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Warn "[$arm] timed out after 15 min and was stopped." }
    } finally { foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k], 'Process') } }
    $secs = [int]((Get-Date) - $t0).TotalSeconds
    $d = ''; if (Test-Path -LiteralPath $dbg) { $d = [IO.File]::ReadAllText($dbg) }
    $fork = ([regex]::Matches($d, [regex]::Escape('[AgentSummary] Forking'))).Count
    $fired = ([regex]::Matches($d, [regex]::Escape('[AgentSummary] Timer fired'))).Count
    $steps = ([regex]::Matches($d, 'tool_dispatch_start tool=(Bash|PowerShell)\b')).Count
    $o = $null; try { $o = Get-Content -LiteralPath $outF -Raw | ConvertFrom-Json } catch {}
    $hookLine = ''; if (Test-Path -LiteralPath $hl) { $hookLine = ((Get-Content -LiteralPath $hl) -join ' | ') }
    $cost = 0.0; if ($o -and $o.total_cost_usd) { $cost = [double]$o.total_cost_usd }
    $res[$arm] = [ordered]@{ forks = $fork; fired = $fired; steps = $steps; seconds = $secs; cost = $cost; is_error = $(if ($o) { $o.is_error } else { $true }); result = $(if ($o) { [string]$o.result } else { (Get-Content -LiteralPath $errF -Raw -ErrorAction SilentlyContinue) }); hook_log = $hookLine; debug_file = $dbg }
    Say "      [$arm] $secs s, shell steps=$steps, summary forks=$fork, timer fired=$fired, est. cost $(Money $cost)$(if ($res[$arm].is_error) { ', ERROR: ' + $res[$arm].result })"
  }
  $tele = ''
  if ($health) {
    Start-Sleep -Seconds 8
    $tev = @(Read-Events -IncludeTagged | Where-Object { $_.tag -like "replicate-$stamp-*" -and $_.ev -eq 'api_request' })
    $tele = ($arms | ForEach-Object { $a = $_; @($tev | Where-Object { $_.tag -eq "replicate-$stamp-$a" -and $_.qs -eq 'agent_summary' }).Count }) -join ' / '
  }
  $forks = "$($res['nohook'].forks) / $($res['pass'].forks) / $($res['off'].forks)"
  $firedS = "$($res['nohook'].fired) / $($res['pass'].fired) / $($res['off'].fired)"
  $slowS = ''; if ($slowMin) { $slowS = "slow $(Fmt $slowMin) min: forks $($res['slow'].forks), fired $($res['slow'].fired)" }
  $total = 0.0; foreach ($k in $res.Keys) { $total += $res[$k].cost }
  $summary = [ordered]@{ t = (IsoUtc (NowUtc)); version = $ver; sha12 = $sha; static = $static; forks = $forks; fired = $firedS; slow = $slowS; telemetry = $tele; cost = (Money $total); exe = $exe; arms = $res }
  Write-Text (Join-Path $runDir 'results.json') ((New-Object PSObject -Property $summary) | ConvertTo-Json -Depth 6)
  Add-Journal 'replicate' @{ cc_version = $ver; sha12 = $sha; static = $static; forks = $forks; fired = $firedS; slow = $slowS; telemetry_agent_summary = $tele; folder = $runDir } | Out-Null
  Head 'Result (same format as the gist''s Tested versions table)'
  Say '| version | sha256 | static | summary forks in a ~2.5-min agent run: no hook / hook `pass` / hook `off` | notes |'
  Say '|---|---|---|---|---|'
  $notes = "timer fired $firedS; shell steps $($res['nohook'].steps)/$($res['pass'].steps)/$($res['off'].steps); $(Fmt $res['nohook'].seconds)/$(Fmt $res['pass'].seconds)/$(Fmt $res['off'].seconds) s"
  if ($slowS) { $notes += "; $slowS" }; if ($tele) { $notes += "; agent_summary API requests (telemetry) $tele" }
  Say "| $ver | ``$sha`` | $static | **$forks** | $notes |" 'White'
  Say "  Flamerix's 2.1.312 row: | 2.1.312 | ``4f4178ce41d8`` | OK | **5 / 5 / 0** | (Linux x64) |"
  Say "  Saved: $runDir (debug files, hook logs, output). Est. cost of this test: $(Money $total)."
  if ($res['nohook'].forks -eq 0 -and $res['pass'].forks -eq 0) { Warn 'No summary forks even without the hook: on this version/account the summary did not run in -p mode (the gist saw the same on 2.1.257/2.1.280), so this A/B is inconclusive. The timer-fired counts still show whether the hook matched.' }
}

# ------------------------------------------------------------------ menu
function Read-Minutes {
  while ($true) {
    $a = Ask '  Minutes between summaries per agent (0.5 - 1440, e.g. 2 or 2.5)' ''
    if (-not $a) { return 0 }
    $v = ParseNum $a
    if ($v -ge 0.5 -and $v -le 1440) { return $v }
    Warn 'Please enter a number between 0.5 and 1440.'
  }
}
function Show-Menu {
  $cfg = Get-Config
  Write-Host ''
  Write-Host "  $ToolName $ToolVersion  -  agent_summary tuner for Claude Code" -ForegroundColor Cyan
  Write-Host '  Unofficial; may conflict with service terms; MIT, hook (c) Flamerix AI. Fails open after updates.' -ForegroundColor DarkGray
  $cur = 'not installed'; if ($cfg.mode) { $cur = Get-ModeLabel $cfg.mode ([double]$cfg.minutes) }
  Write-Host "  Current: $cur; logger $(if ($cfg.loggerEnabled) { 'on' } else { 'off' })" -ForegroundColor DarkGray
  Write-Host ''
  Write-Host '   1  Baseline - measure only (hook counts, summaries unchanged) + logger'
  Write-Host '   2  Slow     - one summary per agent at most every 5 minutes'
  Write-Host '   3  Custom   - choose the minutes yourself'
  Write-Host '   4  Off      - no agent summaries at all (agent panel status stops updating)'
  Write-Host '   5  Status'
  Write-Host '   6  Restart check (confirm all Claude Code processes picked up the change)'
  Write-Host '   7  Report (HTML with charts)'
  Write-Host '   8  Replicate Flamerix''s test (A/B runs, costs a few cents of Haiku)'
  Write-Host '   9  Logger on/off'
  Write-Host '  10  Uninstall everything'
  Write-Host '   Q  Quit'
  return (Ask '  Choose' 'Q').ToUpper()
}
function Invoke-Interactive {
  while ($true) {
    $c = Show-Menu; $cfg = Get-Config
    $wantLogger = -not $NoLogger
    switch ($c) {
      '1' { Set-TunerMode 'baseline' 0 $true $true }
      '2' { Set-TunerMode 'slow' 5 $wantLogger $true }
      '3' { $m = Read-Minutes; if ($m) { Set-TunerMode 'slow' $m $wantLogger $true } }
      '4' { Set-TunerMode 'off' 0 $wantLogger $true }
      '5' { Show-Status }
      '6' { Invoke-RestartCheck $null $true }
      '7' { New-Report | Out-Null }
      '8' { Invoke-Replicate $true }
      '9' { if ($cfg.loggerEnabled) { Disable-Logger $cfg } else { Enable-Logger $cfg $true | Out-Null } }
      '10' { if (AskYesNo 'Remove the hook, settings, logger and autostart?' $false) { Invoke-Uninstall $true } }
      'Q' { return }
      default { Warn 'Unknown choice.' }
    }
  }
}

# ------------------------------------------------------------------ main
if ($env:CST_NO_MAIN) { return }   # used by the test harness to load the functions only
if ($env:OS -ne 'Windows_NT' -and -not $env:CST_ALLOW_NON_WINDOWS) { Write-Host 'This script is for Windows.'; exit 1 }
if ($Mode) {
  $min = 0
  if ($Mode -eq 'slow') { $min = 5; if ($Minutes) { $min = $Minutes } }
  if ($Mode -eq 'custom') { if ($Minutes -lt 0.5 -or $Minutes -gt 1440) { Warn '-Mode custom needs -Minutes between 0.5 and 1440.'; exit 2 }; $min = $Minutes }
  $m = $Mode; if ($m -eq 'custom') { $m = 'slow' }
  Set-TunerMode $m $min (($Mode -eq 'baseline') -or -not $NoLogger) $false
} elseif ($Logger) { $cfg = Get-Config; if ($Logger -eq 'on') { Enable-Logger $cfg $false | Out-Null } else { Disable-Logger $cfg } }
elseif ($CheckRestart) { Invoke-RestartCheck $null ([Environment]::UserInteractive -and -not $Yes) }
elseif ($Status) { Show-Status }
elseif ($Report) { New-Report | Out-Null }
elseif ($Replicate) { Invoke-Replicate (-not $Yes) }
elseif ($Uninstall) { Invoke-Uninstall (-not ($DeleteData -or $KeepData)) }
else { Invoke-Interactive }
