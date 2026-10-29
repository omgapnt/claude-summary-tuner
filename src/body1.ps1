
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
