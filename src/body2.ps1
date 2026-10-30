
# ------------------------------------------------------------------ hook file
function Install-HookFile($cfg) {
  # The hook lives in the data folder (%LOCALAPPDATA%\cc-summary-tuner by default). Bun cannot load a preload path
  # with spaces, so a path with spaces falls back to its 8.3 short name. v1.0.2 removed the old shared fallback
  # (%ProgramData%\cc-summary-tuner\<SID>): another local user could pre-create that folder and plant code there.
  $p = Join-Path $DataDir $HookFileName
  try {
    Ensure-Dir $DataDir; Write-Text $p $HookJs
    if ($script:DryRun -and -not (Test-Path -LiteralPath $p)) { $bp = $p -replace '\\', '/' } else { $bp = ConvertTo-BunPath $p }
    if ($bp -and $bp -match '^[A-Za-z]:/[^\s"'']+$') { $cfg.hookPath = $p; $cfg.hookBunPath = $bp; return $true }
    Warn "The data folder path '$DataDir' contains spaces and has no short (8.3) name, so Bun cannot load the hook from it."
    Warn 'Run the script again with -DataDir pointing to a folder without spaces that only your account can write to (for example inside your own profile).'
  } catch { Warn "Could not write $p : $($_.Exception.Message)" }
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
      $kind = 'Desktop app (main)'
    } elseif ($path -like '*\Claude\claude-code\*') { $kind = 'Desktop app Code session' }
    elseif ($cmd -match '\bdaemon\s+run') { $kind = 'Daemon' }
    elseif ($cmd -match '--bg-pty-host') { $kind = 'Daemon pty host' }
    elseif ($cmd -match '--chrome-native-host') { $kind = 'Chrome bridge'; $relevant = $false }
    elseif ($cmd -match '(^|\s)(-p|--print)(\s|$)') { $kind = 'Headless (-p)' }
    elseif ($cmd -match '\s--bg(\s|$)|bg-spare|--bg-session') { $kind = 'Background session' }
    $created = $null; if ($p.CreationDate) { $created = ([datetime]$p.CreationDate).ToUniversalTime() }
    $hook = '-'
    if ($kind -ne 'Desktop app (main)' -and $relevant) {
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
        $found += "$scope environment: $k (value not shown)"
      }
    }
  }
  $settings = Join-Path $env:USERPROFILE '.claude\settings.json'
  foreach ($f in @($settings, "$env:ProgramFiles\ClaudeCode\managed-settings.json", "$env:ProgramData\ClaudeCode\managed-settings.json")) {
    if ($f -and (Test-Path -LiteralPath $f)) {
      try {
        $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
        if ($j.env) { foreach ($p in $j.env.PSObject.Properties) { if ($p.Name -match '^(OTEL_|CLAUDE_CODE_ENABLE_TELEMETRY$)') { $found += "$f : env.$($p.Name) (value not shown)" } } }
        if ($j.otelHeadersHelper) { $found += "$f : otelHeadersHelper is set" }
      } catch { if ($f -ne $settings) { $found += "$f exists (could not parse)" } }
    }
  }
  foreach ($k in 'HKLM:\SOFTWARE\Policies\ClaudeCode', 'HKCU:\SOFTWARE\Policies\ClaudeCode') { if (Test-Path $k) { $found += "Managed policy registry key present: $k (may pin telemetry)" } }
  return $found
}

# ------------------------------------------------------------------ collector
function Test-PortFree([int]$p) {
  if ($script:DryRun) { return $true }
  # Binds 127.0.0.1:<port> for a moment to see whether it is free, then releases it. Loopback only.
  try { $t = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, $p); $t.Start(); $t.Stop() } catch { return $false }
  return $true
}
function Find-FreePort([int]$start) { for ($p = $start; $p -lt $start + 50; $p++) { if (Test-PortFree $p) { return $p } }; return 0 }
function Get-CollectorHealth([int]$p) {
  if ($script:DryRun) { return $null }
  if (-not $p) { return $null }
  # Asks OUR logger on 127.0.0.1 (this PC) for its status. This is the only HTTP request the script makes, and
  # it never leaves the machine (proxy disabled so it cannot be routed anywhere else).
  try {
    $rq = [Net.HttpWebRequest]::Create("http://127.0.0.1:$p/health"); $rq.Proxy = $null; $rq.Timeout = 2000
    $rs = $rq.GetResponse(); $sr = New-Object IO.StreamReader($rs.GetResponseStream()); $j = $sr.ReadToEnd(); $sr.Dispose(); $rs.Close()
    $o = $j | ConvertFrom-Json; if ($o.app -eq 'claude-summary-tuner') { return $o }
  } catch { Write-Verbose "no logger on port $p" }
  return $null
}
function Get-CollectorCommand([int]$p) {
  # The exact command line used to start the logger (and, only if you enable autostart, stored in the Run value).
  # -ExecutionPolicy Bypass applies to this one process only; -WindowStyle Hidden / conhost --headless keep a
  # background listener from leaving a console window open. Nothing else is started.
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
function Test-RunValue { return [bool](Get-ItemProperty -Path $RunKeyPath -Name $RunValueName -ErrorAction SilentlyContinue) }
function Get-AutostartWanted($cfg) {
  # v1.0.2: autostart is opt-in. Installs from v1.0.0/1.0.1 that already have the Run value keep it (it is never
  # removed behind your back); -Autostart off removes it.
  if ($null -ne $cfg.loggerAutostart) { return [bool]$cfg.loggerAutostart }
  return (Test-RunValue)
}
function Start-Collector($cfg) {
  Write-Text (Join-Path $DataDir 'collector.ps1') $CollectorPs
  $c = Get-CollectorCommand ([int]$cfg.port)
  if (Get-AutostartWanted $cfg) { Set-RunValue $c.full }
  if (-not (Get-CollectorHealth ([int]$cfg.port))) { Start-CollectorProcess $c }
  if ($script:DryRun) { return $null }
  for ($i = 0; $i -lt 20; $i++) { $h = Get-CollectorHealth ([int]$cfg.port); if ($h) { return $h }; Start-Sleep -Milliseconds 500 }
  return $null
}
function Stop-Collector($cfg) {
  $pidFile = Join-Path $DataDir 'collector.pid'
  if (Test-Path -LiteralPath $pidFile) {
    $cp = [int]((Get-Content -LiteralPath $pidFile -Raw).Trim())
    if (Stop-CollectorProcess $cp) { Say "  stopped collector (PID $cp)" }
    Remove-OwnFile $pidFile
  }
  Remove-RunValue
}
function Set-LoggerAutostart($cfg, [bool]$on) {
  if ($on) {
    if (-not $cfg.loggerEnabled -or -not $cfg.port) { Warn 'The logger is not set up; turn it on first (-Logger on).'; return }
    $cfg.loggerAutostart = $true; Save-Config $cfg
    Set-RunValue (Get-CollectorCommand ([int]$cfg.port)).full
    Good "  Logger autostart on: HKCU\...\Run\$RunValueName (Task Manager > Startup apps). Undo: -Autostart off"
  } else {
    $cfg.loggerAutostart = $false; Save-Config $cfg
    Remove-RunValue
    Good '  Logger autostart off (Run value removed). A running logger keeps running until you log off; -Logger off stops it now.'
  }
  Add-Journal 'autostart' @{ on = $on } | Out-Null
}
function Read-Consent([string]$q) {
  # Explicit yes/no for opt-in features. Deliberately NOT answered by -Yes.
  $a = Read-Host "$q [y/N]"
  return ([string]$a).Trim().ToLower() -in 'y', 'yes', 'j', 'ja'
}
function Get-LoggerWanted($cfg, [bool]$interactive, [string]$modeName) {
  # v1.0.2: the logger is opt-in. -NoLogger always wins; -Logger on opts in; an existing logger is kept as it is.
  if ($NoLogger -or $Logger -eq 'off') { return $false }
  if ($Logger -eq 'on') { return $true }
  if ($cfg.loggerEnabled) { return $true }
  if (-not $interactive) {
    if ($modeName -eq 'baseline') { Say '  Logger not turned on (opt-in). The hook log still counts summary timers; add -Logger on to also record cost per request.' }
    return $false
  }
  Say '  Optional local logger: a small PowerShell listener on 127.0.0.1 (this PC only) that records Claude Code''s own' 'Gray'
  Say '  cost events (time, model, query_source, tokens, cost estimate; no prompts or responses). It sets 4 user' 'Gray'
  Say '  variables (CLAUDE_CODE_ENABLE_TELEMETRY, OTEL_LOGS_EXPORTER, OTEL_EXPORTER_OTLP_LOGS_PROTOCOL/_ENDPOINT). -Logger off undoes it.' 'Gray'
  $q = 'Turn on the local logger?'; if ($modeName -eq 'baseline') { $q = 'Turn on the local logger (recommended for a baseline measurement)?' }
  return (Read-Consent $q)
}
function Get-AutostartChoice($cfg, [bool]$interactive) {
  if ($Autostart -eq 'on') { return $true }
  if ($Autostart -eq 'off') { return $false }
  if ($null -ne $cfg.loggerAutostart -or (Test-RunValue)) { return (Get-AutostartWanted $cfg) }   # keep what is there
  if (-not $interactive) { return $false }
  Say "  Autostart would add the value $RunValueName to HKCU\...\CurrentVersion\Run (visible in Task Manager > Startup apps)" 'Gray'
  Say '  so the logger starts hidden at every logon. Without it, the logger runs until you log off; run -Logger on to start it again.' 'Gray'
  return (Read-Consent 'Start the logger at every logon?')
}
function Enable-Logger($cfg, [bool]$interactive) {
  if ($NoLogger) { Say '  -NoLogger: logger configuration left alone.'; return $false }
  $conf = Get-OtelConflicts $cfg
  if ($conf.Count) {
    Warn 'Claude Code telemetry is already configured on this machine:'
    $conf | ForEach-Object { Say "   - $_" 'Yellow' }
    Say '   Turning on this logger would redirect Claude Code''s log events to this PC only, and settings.json/managed' 'Yellow'
    Say '   settings may override it anyway. Default is to leave telemetry alone (the hook still works).' 'Yellow'
    if (-not ($interactive -and (Read-Consent 'Set up the local logger anyway?'))) { Say '  Logger skipped.'; return $false }
  }
  if (-not $cfg.port -or -not ((Get-CollectorHealth ([int]$cfg.port)) -or (Test-PortFree ([int]$cfg.port)))) {
    $start = 47318; if ($Port) { $start = $Port }
    $cfg.port = Find-FreePort $start
    if (-not $cfg.port) { Warn 'No free local port found (47318-47367). Logger not set up.'; return $false }
  }
  $auto = Get-AutostartChoice $cfg $interactive
  $vars = [ordered]@{
    CLAUDE_CODE_ENABLE_TELEMETRY     = '1'
    OTEL_LOGS_EXPORTER               = 'otlp'
    OTEL_EXPORTER_OTLP_LOGS_PROTOCOL = 'http/json'
    OTEL_EXPORTER_OTLP_LOGS_ENDPOINT = "http://127.0.0.1:$($cfg.port)/v1/logs"
  }
  foreach ($k in $vars.Keys) { Set-UserEnv $k $vars[$k] }
  $cfg.loggerVars = New-Object PSObject -Property $vars
  $cfg.loggerEnabled = $true
  $cfg.loggerAutostart = $auto
  Save-Config $cfg
  if (-not $auto) { Remove-RunValue }
  $h = Start-Collector $cfg
  $as = 'no autostart (-Autostart on to start it at every logon)'; if ($auto) { $as = "starts hidden at every logon (HKCU Run value $RunValueName; -Autostart off removes it)" }
  if ($h) { Good "  Logger running on 127.0.0.1:$($cfg.port) (PID $($h.pid)); $as." }
  elseif (-not $script:DryRun) { Warn "Logger did not answer on 127.0.0.1:$($cfg.port). See $(Join-Path $DataDir 'collector.log')." }
  Add-Journal 'logger_on' @{ port = $cfg.port; healthy = [bool]$h; autostart = $auto } | Out-Null
  return $true
}
function Disable-Logger($cfg, [switch]$Uninstalling) {
  Stop-Collector $cfg
  foreach ($k in $OtelVarNames) {
    $cur = Get-UserEnv $k; $ours = $null
    if ($cfg.loggerVars -and $cfg.loggerVars.PSObject.Properties[$k]) { $ours = [string]$cfg.loggerVars.$k }
    if ($cur -and $ours -and $cur -eq $ours) { Set-UserEnv $k $null }
    elseif ($cur) { Say "  left $k alone (not set by this tool; value not shown)" }
  }
  $cfg.loggerEnabled = $false; $cfg.loggerVars = $null; $cfg.loggerAutostart = $null
  if (-not $Uninstalling) { Save-Config $cfg; Add-Journal 'logger_off' @{} | Out-Null }
  elseif (Test-Path -LiteralPath $ConfigPath) { Save-Config $cfg }   # uninstall: record 'logger off' so a later install asks again; never creates a new file
  Good '  Logger stopped and removed from autostart. Data kept.'
}
