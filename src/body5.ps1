
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
  if ($cfg.mode -and (Test-OldPreloadForm (Get-UserEnv 'BUN_OPTIONS'))) { Write-Host '  Upgrade note: choose your current mode again once to rewrite BUN_OPTIONS as --preload=<path> (fixes standalone bun install).' -ForegroundColor Yellow }
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
