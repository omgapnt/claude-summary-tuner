
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
