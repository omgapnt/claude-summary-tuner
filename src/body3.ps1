
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
  $oldBo = Get-UserEnv 'BUN_OPTIONS'
  $wasOldForm = Test-OldPreloadForm $oldBo
  $newBo = Merge-BunOptions $oldBo $cfg.hookBunPath
  if ($wasOldForm) { Say '  Rewriting BUN_OPTIONS from the old space form (--preload <path>) to --preload=<path> (fixes standalone bun install).' 'Yellow' }
  $desk = @(Find-DesktopClaude)
  $test = Test-HookLoads $exe $newBo
  if (-not $test.ok) {
    Warn "Self-test failed: claude --version did not load the hook. Output: $($test.out)"
    Warn 'Nothing was changed.'; return
  }
  Good "  Self-test OK: $($test.line -replace '^\S+\s+pid=\d+\s+','')"
  foreach ($d in $desk) {
    $dt = Test-HookLoads $d.Path $newBo
    if ($dt.ok) { Good "  Self-test OK for the desktop app's Claude Code $($d.Version)" } else { Warn "the desktop app's Claude Code $($d.Version) did not load the hook in the self-test: $($dt.out)" }
  }
  Set-UserEnv 'BUN_OPTIONS' $newBo
  Set-UserEnv 'CC_AGENT_SUMMARY_MODE' $hookMode
  Set-UserEnv 'CC_AGENT_SUMMARY_LOG' $HookLogPath
  if ($hookMode -eq 'slow') { Set-UserEnv 'CC_AGENT_SUMMARY_MIN_DELAY_MS' ([string][int64]([Math]::Round($min * 60000))) } else { Set-UserEnv 'CC_AGENT_SUMMARY_MIN_DELAY_MS' $null }
  $same = ($prevMode -eq $m) -and ([double]$prevMin -eq [double]$min) -and ((Get-UserEnv 'CC_AGENT_SUMMARY_MODE') -eq $hookMode)
  $cfg.mode = $m; $cfg.minutes = $min; $cfg.ccVersions = @($ver); $cfg.desktopCcVersions = @($desk | ForEach-Object { $_.Version }); $cfg.toolVersion = $ToolVersion; Save-Config $cfg
  if ($same) {
    # Same mode as before (e.g. an upgrade): no new measurement period. Running processes already use the same hook
    # file and mode, so no restart is needed for the summaries; only new processes see the rewritten BUN_OPTIONS.
    $id = Add-Journal 'reapply' @{ mode = $m; minutes = $min; tool_version = $ToolVersion; cc_version = $ver; desktop_cc = ($cfg.desktopCcVersions -join ','); rewrote_old_form = $wasOldForm }
    Good "  Mode unchanged; settings re-applied for $ToolName $ToolVersion. Logged at $(LocalStr (ParseIso $id))."
    if ($wasOldForm) { Say '  Already running Claude Code processes keep working. Terminals opened before now still hold the old form, so open a new terminal before running bun.' }
    if ($wantLogger -and -not ($cfg.loggerEnabled -and (Get-CollectorHealth ([int]$cfg.port)))) { Enable-Logger $cfg $interactive | Out-Null }
    elseif ($cfg.loggerEnabled) { $h = Start-Collector $cfg; if ($h) { Say "  Logger already on (127.0.0.1:$($cfg.port))." } }
    return
  }
  $id = Add-Journal 'mode' @{ mode = $m; minutes = $min; hook_mode = $hookMode; prev_mode = $prevMode; prev_minutes = $prevMin; cc_version = $ver; desktop_cc = ($cfg.desktopCcVersions -join ','); tool_version = $ToolVersion; bun_options = $newBo }
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
function Show-DesktopAdvice($procs) {
  $d = @($procs | Where-Object { $_.Kind -like 'Desktop app*' })
  if ($d.Count) { Say '  The Claude desktop app was started before the change: fully quit it (tray icon > Quit, not just closing the window) and open it again, so its Code tab gets the new setting.' 'Yellow' }
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
    Show-DesktopAdvice $stale
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
  if (Test-OldPreloadForm $bo) {
    $again = '-Mode baseline'; if ($cfg.mode -eq 'off') { $again = '-Mode off' } elseif ($cfg.mode -eq 'slow') { $again = "-Mode custom -Minutes $(Fmt ([double]$cfg.minutes))" }
    Warn "BUN_OPTIONS uses the old space form (--preload <path>). It breaks standalone bun commands such as 'bun install' (Script not found). Re-run this script with $again to rewrite it as --preload=<path>; your mode stays the same."
  }
  $exe = Find-Claude; $ver = Get-CCVersion $exe
  Say "  Claude Code        : $ver ($exe)"
  $desk = @(Find-DesktopClaude)
  if ($desk.Count) { Say "  Desktop app's CLI  : $(($desk | ForEach-Object { $_.Version }) -join ', ') (bundled with the Claude desktop app; runs its Code-tab sessions)" }
  $cache = @{}; if ($cfg.anchorCache) { foreach ($p in $cfg.anchorCache.PSObject.Properties) { $cache[$p.Name] = $p.Value } }
  $bins = @(); if ($exe -and $exe -like '*.exe' -and $ver) { $bins += [pscustomobject]@{ Label = "$ver"; Version = $ver; Path = $exe } }
  foreach ($d in $desk) { $bins += [pscustomobject]@{ Label = "$($d.Version) (desktop app)"; Version = $d.Version; Path = $d.Path } }
  foreach ($b in $bins) {
    if (-not $cache.ContainsKey($b.Version)) { Say "  (scanning $($b.Label) for the summary timer anchor once...)"; $a = Find-BinaryAnchors $b.Path; $cache[$b.Version] = [bool]$a['[AgentSummary] Timer fired']; $cfg.anchorCache = New-Object PSObject -Property $cache; Save-Config $cfg }
    if ($cache[$b.Version]) { Good "  Static check       : anchor '[AgentSummary] Timer fired' present in $($b.Label)" } else { Warn "anchor '[AgentSummary] Timer fired' NOT found in $($b.Label) - the hook probably matches nothing there (fail-open)." }
  }
  if ($cfg.mode -and $bo) {
    foreach ($b in $bins) { $t = Test-HookLoads $b.Path $bo; if ($t.ok) { Good "  Hook load test     : OK ($($b.Label))" } else { Warn "hook does NOT load in $($b.Label) with the saved BUN_OPTIONS: $($t.out)" } }
  }
  if ($cfg.mode) {
    # Version drift: the hook matches source strings, so a Claude Code build it was never checked against may not match.
    $recCli = @($cfg.ccVersions); $recDesk = @($cfg.desktopCcVersions)
    if (-not ($recCli | Where-Object { $_ })) { $lm = Read-Journal | Where-Object { $_.action -in 'mode', 'reapply' -and $_.cc_version } | Select-Object -Last 1; if ($lm) { $recCli = @($lm.cc_version) } }
    $drift = @(Get-VersionDrift $recCli @($ver))
    if ($recDesk | Where-Object { $_ }) { $drift += @(Get-VersionDrift $recDesk @($desk | ForEach-Object { $_.Version }) | ForEach-Object { "$_ (desktop app)" }) }
    if ($drift.Count) { Warn "Claude Code changed since the mode was set (then: $((@($recCli) + @($recDesk) | Where-Object { $_ } | Select-Object -Unique) -join ', '); new: $($drift -join ', ')). The hook matches text inside the program, so re-verify with -Replicate (about `$0.03 of Haiku). Nothing was changed." }
    else { Say "  Version check      : same Claude Code version(s) as when the mode was set" }
  }
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
  $unhooked = @($procs | Where-Object { $_.Relevant -and $_.Hook -eq 'NO' -and $_.Kind -ne 'Desktop app (main)' })
  if ($cfg.mode -and $unhooked.Count) { Warn "$($unhooked.Count) Claude Code process(es) run WITHOUT the hook (started before the install, from an old terminal, or BUN_OPTIONS did not reach them)." }
  $lastChange = Read-Journal | Where-Object { $_.action -eq 'mode' } | Select-Object -Last 1
  if ($cfg.mode -and $lastChange) {
    $since = ParseIso $lastChange.t
    $oldDesk = @($procs | Where-Object { $_.Kind -eq 'Desktop app (main)' -and $_.Started -and $_.Started -lt $since })
    if ($oldDesk.Count) { Warn "the Claude desktop app was started before the last mode change ($(LocalStr $since)). Fully quit it (tray icon > Quit) and open it again so its Code tab uses the new setting." }
    elseif (@($procs | Where-Object { $_.Kind -eq 'Desktop app (main)' }).Count) { Say "  Desktop app        : started after the last mode change, so its Code tab inherits the current setting" }
  }
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
  $running = @(Get-ClaudeProcesses $null | Where-Object { $_.Relevant -and $_.Kind -ne 'Desktop app (main)' })
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
