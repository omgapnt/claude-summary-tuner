
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
  $d = 'y/N'; if ($def) { $d = 'Y/n' }
  $a = Read-Host "$q [$d]"
  if (-not $a) { return $def }
  return ($a.Trim().ToLower() -in 'y', 'yes', 'j', 'ja')
}

# ================================================================== CHANGE GATE
# EVERY persistent change this script can make goes through the functions in this section and nowhere else
# (test/unit.ps1 parses the script and fails if any other function writes files, environment variables or the
# registry, or starts/stops processes). That makes the whole "what can it change" review this one section:
#   files      : Ensure-Dir, Write-Text, Append-Text, Remove-OwnFile, Remove-OwnData  (the data folder, see SECURITY.md)
#   user env   : Set-UserEnv          (only BUN_OPTIONS, CC_AGENT_SUMMARY_*, and the 4 logger OTEL variables)
#   registry   : Set-RunValue, Remove-RunValue  (only HKCU\...\Run\ClaudeSummaryTunerCollector, opt-in autostart)
#   processes  : Start-CollectorProcess, Stop-CollectorProcess, Stop-ClaudeDaemon, Start-ReplicateChild
# With -WhatIf / -DryRun each of them prints "WOULD ..." and does nothing.
$script:DryRun = [bool]$WhatIf
$script:Planned = New-Object System.Collections.Generic.List[string]
function Write-Plan([string]$what) { $script:Planned.Add($what); Write-Host "  WOULD $what" -ForegroundColor Magenta }
function Test-SecretName([string]$n) {
  # Values of these variables are never printed (OTEL headers often hold an API key).
  return [bool]($n -match '(?i)^OTEL_|HEADER|KEY|TOKEN|SECRET|PASSW|AUTH|CREDENTIAL|COOKIE')
}
function Show-EnvValue([string]$n, [string]$v) {
  if ($null -eq $v -or $v -eq '') { return '(not set)' }
  if (Test-SecretName $n) { return '(set, value not shown)' }
  return "'$v'"
}
function Test-InsideDataDir([string]$p) {
  if (-not $p) { return $false }
  try { $full = [IO.Path]::GetFullPath($p); $root = [IO.Path]::GetFullPath($DataDir).TrimEnd('\', '/') } catch { return $false }
  return $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($root + '/', [StringComparison]::OrdinalIgnoreCase)
}
function Ensure-Dir([string]$p) {
  # File system folders only (never a registry path).
  if (Test-Path -LiteralPath $p) { return }
  if ($script:DryRun) { Write-Plan "create folder $p"; return }
  [void][IO.Directory]::CreateDirectory($p)
}
function Write-Text([string]$p, [string]$t) {
  if ($script:DryRun) { Write-Plan "$(if (Test-Path -LiteralPath $p) { 'overwrite' } else { 'create' }) file $p ($($Utf8NoBom.GetByteCount($t)) bytes)"; return }
  $created = -not (Test-Path -LiteralPath $p)
  [IO.File]::WriteAllText($p, $t, $Utf8NoBom)
  if ($created) { Register-OwnFile $p }
}
function Append-Text([string]$p, [string]$t) {
  if ($script:DryRun) { Write-Plan "append $($Utf8NoBom.GetByteCount($t)) bytes to $p"; return }
  $created = -not (Test-Path -LiteralPath $p)
  [IO.File]::AppendAllText($p, $t, $Utf8NoBom)
  if ($created) { Register-OwnFile $p }
}
# Ownership is recorded only when this process creates a new file. Existing files are never
# adopted by filename. Old installations without this manifest are preserved by -DeleteData.
function Test-SafeDataPath([string]$p) {
  try {
    $root = [IO.Path]::GetFullPath($DataDir).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath($p)
    if ($root -notmatch '^[A-Za-z]:\\' -or $root.Length -le 3) { return $false }
    foreach ($protected in @($env:USERPROFILE, $env:SystemRoot, $env:ProgramFiles, $env:ProgramData)) {
      if ($protected -and $root -eq [IO.Path]::GetFullPath($protected).TrimEnd('\', '/')) { return $false }
    }
    if ($full -ne $root -and -not (Test-InsideDataDir $full)) { return $false }
    $itemPath = $full
    while ($itemPath) {
      if (Test-Path -LiteralPath $itemPath) {
        if ((Get-Item -LiteralPath $itemPath -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) { return $false }
      }
      $parent = Split-Path $itemPath -Parent
      if ($parent -eq $itemPath) { break }; $itemPath = $parent
    }
    return $true
  } catch { return $false }
}
function Get-OwnershipPath { return (Join-Path $DataDir '.cst-owned-files.json') }
function Get-Ownership {
  $path = Get-OwnershipPath
  if (-not (Test-SafeDataPath $path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
  try {
    $m = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    $id = [guid]::Empty
    if ($m.tool -cne 'Claude-Summary-Tuner' -or $m.schema -ne 1 -or
        -not [guid]::TryParse([string]$m.installId, [ref]$id) -or
        [string]$m.root -ne [IO.Path]::GetFullPath($DataDir).TrimEnd('\', '/')) { return $null }
    foreach ($relative in @($m.files)) {
      if (-not $relative -or [IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)' -or
          -not (Test-SafeDataPath (Join-Path $DataDir $relative))) { return $null }
    }
    return $m
  } catch { return $null }
}
function Register-OwnFile([string]$p) {
  if ($script:DryRun -or -not (Test-InsideDataDir $p) -or -not (Test-SafeDataPath $p)) { return }
  $path = Get-OwnershipPath; $m = Get-Ownership
  if (-not $m) {
    # Never replace an invalid/pre-existing marker or claim a legacy installation's files.
    if (Test-Path -LiteralPath $path) { return }
    $m = [pscustomobject]@{ tool = 'Claude-Summary-Tuner'; schema = 1; installId = [guid]::NewGuid().ToString(); root = [IO.Path]::GetFullPath($DataDir).TrimEnd('\', '/'); files = @() }
  }
  $relative = [IO.Path]::GetFullPath($p).Substring($m.root.Length + 1)
  if ($relative -eq '.cst-owned-files.json') { return }
  $m.files = @(@($m.files) + $relative | Select-Object -Unique)
  [IO.File]::WriteAllText($path, ($m | ConvertTo-Json -Depth 4), $Utf8NoBom)
}
function Test-OwnedFile([string]$p) {
  if (-not (Test-SafeDataPath $p)) { return $false }
  $m = Get-Ownership; if (-not $m) { return $false }
  return [bool](@($m.files) | Where-Object { [IO.Path]::GetFullPath((Join-Path $DataDir $_)) -eq [IO.Path]::GetFullPath($p) })
}
function Remove-OwnFile([string]$p, [string]$allowed) {
  # $allowed is retained for compatibility; it can never authorize an outside/untracked file.
  if (-not $p -or -not (Test-Path -LiteralPath $p -PathType Leaf)) { return }
  if (-not (Test-OwnedFile $p)) { Warn "not deleting $p (not recorded as a file created by this installation)"; return }
  if ($script:DryRun) { Write-Plan "delete $p"; return }
  # Forget first: if deletion or the process fails, preserve the leftover file as untracked.
  # This also prevents a subsequent uninstall claiming a new foreign file at the old path.
  $m = Get-Ownership
  $m.files = @($m.files | Where-Object { [IO.Path]::GetFullPath((Join-Path $DataDir $_)) -ne [IO.Path]::GetFullPath($p) })
  [IO.File]::WriteAllText((Get-OwnershipPath), ($m | ConvertTo-Json -Depth 4), $Utf8NoBom)
  Remove-Item -LiteralPath $p -Force -ErrorAction Stop
}
function Remove-OwnData([string]$keep, $ownership) {
  # Use the snapshot taken BEFORE uninstall performs any writes. No glob or recursive deletion.
  if (-not $ownership) { Warn 'No pre-existing ownership record; legacy/untracked data was preserved.'; return $false }
  $current = Get-Ownership
  if (-not $current -or $current.installId -ne $ownership.installId) { Warn 'Ownership changed; data was preserved.'; return $false }
  foreach ($relative in @($ownership.files)) {
    $p = Join-Path $DataDir $relative
    if ($keep -and [IO.Path]::GetFullPath($p) -eq [IO.Path]::GetFullPath($keep)) { continue }
    Remove-OwnFile $p
  }
  # Keep the manifest and directories. Unknown files (including future collector logs) stay untouched.
  return $true
}
function Set-UserEnv([string]$n, [string]$v) {
  # Per-user environment variable (HKCU\Environment), no admin. Only called for the names listed in SECURITY.md.
  if ($script:DryRun) {
    $cur = [Environment]::GetEnvironmentVariable($n, 'User')
    if ([string]$cur -eq [string]$v) { return }
    if ([string]::IsNullOrEmpty($v)) { Write-Plan "remove user variable $n (now $(Show-EnvValue $n $cur))" } else { Write-Plan "set user variable $n = $(Show-EnvValue $n $v) (now $(Show-EnvValue $n $cur))" }
    return
  }
  if ([string]::IsNullOrEmpty($v)) { [Environment]::SetEnvironmentVariable($n, $null, 'User') }
  else { [Environment]::SetEnvironmentVariable($n, $v, 'User') }
}
function Set-RunValue([string]$cmd) {
  # The ONLY registry write: the opt-in logger autostart. Visible in Task Manager > Startup apps; -Autostart off removes it.
  # v1.0.2 fix: v1.0.0/1.0.1 called "New-Item <Run key> -Force" here, which deletes and recreates the whole Run key
  # and so removed every other app's startup entry. The key is now only created when it does not exist, never -Force.
  if ($script:DryRun) { Write-Plan "set registry value $RunKeyPath\$RunValueName = $cmd"; return }
  if (-not (Test-Path -LiteralPath $RunKeyPath)) { New-Item -Path $RunKeyPath | Out-Null }
  Set-ItemProperty -LiteralPath $RunKeyPath -Name $RunValueName -Value $cmd
}
function Remove-RunValue {
  if (-not (Get-ItemProperty -LiteralPath $RunKeyPath -Name $RunValueName -ErrorAction SilentlyContinue)) { return }
  if ($script:DryRun) { Write-Plan "delete registry value $RunKeyPath\$RunValueName"; return }
  Remove-ItemProperty -LiteralPath $RunKeyPath -Name $RunValueName -ErrorAction SilentlyContinue
}
function Start-CollectorProcess($c) {
  # Starts the local logger (powershell.exe running the collector.ps1 this script wrote) without a console window,
  # because it is a background listener. It shows in Task Manager as powershell.exe with collector.ps1 in its
  # command line; -Logger off stops it.
  if ($script:DryRun) { Write-Plan "start the logger: $($c.full)"; return }
  Start-Process -FilePath $c.file -ArgumentList $c.args -WindowStyle Hidden | Out-Null
}
function Stop-CollectorProcess([int]$cp) {
  # Require this installation's exact -File path, not a collector.ps1 substring.
  $p = Get-CimInstance Win32_Process -Filter "ProcessId=$cp" -ErrorAction SilentlyContinue
  $collectorPath = [IO.Path]::GetFullPath((Join-Path $DataDir 'collector.ps1'))
  $fileArgument = '(?i)(?:^|\s)-File\s+"?' + [regex]::Escape($collectorPath) + '(?:"|\s|$)'
  if (-not ($p -and $p.Name -eq 'powershell.exe' -and [string]$p.CommandLine -match $fileArgument)) { return $false }
  if ($script:DryRun) { Write-Plan "stop the logger process (PID $cp)"; return $false }
  Stop-Process -Id $cp -Force -ErrorAction SilentlyContinue; return $true
}
function Stop-ClaudeDaemon([string]$exe) {
  # Only after you confirm in the restart check: runs Claude Code's own "claude daemon stop --any".
  if ($script:DryRun) { Write-Plan "run: $exe daemon stop --any"; return '' }
  return (Invoke-Isolated $exe @('daemon', 'stop', '--any') @{}).out
}
function Start-ReplicateChild([string]$exe, [string]$argStr, [string]$dir, [string]$inF, [string]$outF, [string]$errF) {
  # -Replicate only: one "claude -p --model haiku" test run; stopped after 15 minutes if it hangs.
  if ($script:DryRun) { Write-Plan "run: $exe $argStr"; return $true }
  $p = Start-Process -FilePath $exe -ArgumentList $argStr -WorkingDirectory $dir -RedirectStandardInput $inF -RedirectStandardOutput $outF -RedirectStandardError $errF -NoNewWindow -PassThru
  if (-not $p.WaitForExit(900000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; return $false }
  return $true
}
# ================================================================== end of CHANGE GATE

# ------------------------------------------------------------------ config + journal
$ConfigPath = Join-Path $DataDir 'config.json'
$JournalPath = Join-Path $DataDir 'actions.jsonl'
$HookLogPath = Join-Path $DataDir 'hook.log'
function Get-Config {
  $c = $null
  if (Test-Path -LiteralPath $ConfigPath) { try { $c = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json } catch { $c = $null } }
  if (-not $c) { $c = New-Object PSObject }
  foreach ($k in 'hookPath', 'hookBunPath', 'port', 'loggerEnabled', 'mode', 'minutes', 'legacyLogs', 'loggerVars', 'anchorCache', 'ccVersions', 'desktopCcVersions', 'toolVersion', 'loggerAutostart') {
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
  # v1.0.1: always the '=' form. The space form ('--preload <path>') breaks standalone bun subcommands
  # (bun install -> 'Script not found "install"', seen with bun 1.4.3), because BUN_OPTIONS reaches every bun.
  $rest = Remove-OurPreload $current
  if ($rest) { return "$rest --preload=$hookBunPath" }
  return "--preload=$hookBunPath"
}
function Test-OldPreloadForm([string]$s) {
  # True if BUN_OPTIONS holds our hook in the old space form (v1.0.0 or a manual install).
  $t = @(Split-BunOptions $s)
  for ($i = 0; $i -lt $t.Count - 1; $i++) { if ($t[$i] -eq '--preload' -and $t[$i + 1] -match 'no-agent-summary\.js$') { return $true } }
  return $false
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
    # Windows' own FileSystemObject is used only to read the 8.3 short name of a path that contains spaces.
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
function Find-DesktopClaude {
  # The Claude desktop app keeps its own Claude Code builds in %APPDATA%\Claude\claude-code\<version>\<hash>\claude.exe
  $o = @(); if (-not $env:APPDATA) { return $o }
  $root = Join-Path $env:APPDATA 'Claude\claude-code'
  foreach ($v in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name)) {
    $exe = Get-ChildItem -LiteralPath $v.FullName -Recurse -Filter 'claude.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe) { $o += [pscustomobject]@{ Version = $v.Name; Path = $exe.FullName } }
  }
  return $o
}
function Get-VersionDrift($recorded, $current) {
  # Versions present now that were not there when the mode was last set (the hook matches source strings,
  # so a new build should be re-verified). Returns @() when nothing was recorded.
  $r = @($recorded | Where-Object { $_ }); if (-not $r.Count) { return @() }
  return @($current | Where-Object { $_ -and $_ -notin $r })
}
function Hide-UserPaths([string]$s) {
  # Anonymises a text for sharing: user-profile paths become %USERPROFILE% etc., any C:\Users\<name> -> %USERNAME%.
  if (-not $s) { return $s }
  foreach ($v in @(@('LOCALAPPDATA', $env:LOCALAPPDATA), @('APPDATA', $env:APPDATA), @('TEMP', $env:TEMP), @('USERPROFILE', $env:USERPROFILE))) {
    if (-not $v[1] -or $v[1].Length -lt 4) { continue }
    foreach ($form in @($v[1], ($v[1] -replace '\\', '/'), ($v[1] -replace '/', '\\'))) { $s = [regex]::Replace($s, [regex]::Escape($form), "%$($v[0])%", 'IgnoreCase') }
  }
  $s = [regex]::Replace($s, '(?i)([A-Z]:(?:\\|/|\\\\)Users(?:\\|/|\\\\))[^\\/\s<>''"&;]+', '$1%USERNAME%')
  if ($env:COMPUTERNAME -and $env:COMPUTERNAME.Length -ge 3) { $s = [regex]::Replace($s, '(?i)(?<![A-Za-z0-9])' + [regex]::Escape($env:COMPUTERNAME) + '(?![A-Za-z0-9])', '%COMPUTERNAME%') }
  if ($env:USERNAME -and $env:USERNAME.Length -ge 3) { $s = [regex]::Replace($s, '(?i)(?<![A-Za-z0-9])' + [regex]::Escape($env:USERNAME) + '(?![A-Za-z0-9])', '%USERNAME%') }
  return $s
}
function Invoke-Isolated([string]$exe, [string[]]$argv, [hashtable]$envOverride) {
  if ($script:DryRun) { Write-Plan 'check Claude version/hook after approval (not executed in preview)'; return @{ out = ''; code = 0 } }
  # Runs a child (claude.exe) with extra/removed variables set for THIS process only ('Process' scope, gone when
  # the script exits); nothing persistent is touched. Used for 'claude --version' and the hook self-test.
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
  if ($script:DryRun) { Write-Plan 'test hook loading after approval (not executed in preview)'; return @{ ok = $true; line = 'not executed (preview)'; out = '' } }
  $tmp = Join-Path $env:TEMP ("cst-selftest-" + [guid]::NewGuid().ToString('N') + '.log')
  $r = Invoke-Isolated $exe @('--version') @{ BUN_OPTIONS = $bunOptions; CC_AGENT_SUMMARY_MODE = 'pass'; CC_AGENT_SUMMARY_LOG = $tmp; CC_AGENT_SUMMARY_MIN_DELAY_MS = $null }
  $line = $null
  # The hook itself writes this temp log (in %TEMP%) during the self-test; it is read and deleted right here.
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
