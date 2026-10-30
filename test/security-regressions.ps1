# Synthetic security regression tests. No real Claude process, user environment write,
# real startup mutation, provider request, or live logger is used here.
param([Parameter(Mandatory=$true)][string]$TestRoot)
$ErrorActionPreference = 'Stop'
$candidate = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Claude-Summary-Tuner.ps1'))
$runRoot = Join-Path ([IO.Path]::GetFullPath($TestRoot)) ('regressions-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($runRoot)
$env:CST_NO_MAIN = '1'
. $candidate -DataDir (Join-Path $runRoot 'data') -NoOpen
$script:checks = 0
function Assert($condition, [string]$name) {
  if (-not $condition) { throw "FAIL: $name" }
  $script:checks++; Write-Host "PASS: $name"
}
function Select-Data([string]$name) {
  $script:DataDir = Join-Path $runRoot $name
  $script:ConfigPath = Join-Path $DataDir 'config.json'
  $script:JournalPath = Join-Path $DataDir 'actions.jsonl'
  $script:HookLogPath = Join-Path $DataDir 'hook.log'
  [void][IO.Directory]::CreateDirectory($DataDir)
}
# Replace all real environmental/process/registry capabilities before invoking action handlers.
function Get-UserEnv([string]$n) { if ($n -eq 'CC_AGENT_SUMMARY_MODE') { return $script:syntheticMode }; return $null }
function Set-UserEnv([string]$n,[string]$v) { $script:envWrites++ }
function Get-ItemProperty { return $null }
function Get-ClaudeProcesses { return @() }
function Stop-Collector { $script:stops++ }
function Find-Claude { return 'C:\synthetic\claude.exe' }
function Get-CCVersion { return '2.1.312' }
function Find-DesktopClaude { return @() }
function Test-HookLoads { return @{ok=$true;line='synthetic';out=''} }
function Get-CollectorHealth { return $null }
function Start-Collector { $script:starts++; return $null }
function Enable-Logger { $script:enables++; return $true }
function Show-RestartGuide {}
function Invoke-RestartCheck {}
function Read-Host { throw 'An unexpected prompt was reached' }
function Get-CimInstance { return $script:syntheticCollector }
function Stop-Process { $script:processStops++ }

# Collector stop must match this installation's exact script argument.
Select-Data 'stop-ownership'
$script:processStops = 0
$script:syntheticCollector = [pscustomobject]@{ Name='powershell.exe'; CommandLine='powershell.exe -File C:\another-tool\collector.ps1' }
Assert (-not (Stop-CollectorProcess 12345)) 'another collector with the same basename is not stopped'
$ownCollector = Join-Path $DataDir 'collector.ps1'
$script:syntheticCollector.CommandLine = 'powershell.exe -File "' + $ownCollector + '" -Port 47318'
Assert (Stop-CollectorProcess 12345) 'exact collector script path is accepted by stop ownership check'
Assert ($script:processStops -eq 1) 'only the owned synthetic collector reaches Stop-Process'

# A legacy/foreign config cannot authorize deleting matching data or a foreign subdirectory.
Select-Data 'foreign'
[IO.Directory]::CreateDirectory((Join-Path $DataDir 'replicate')) | Out-Null
foreach ($name in 'config.json','events-2026-10-30.tsv','report-1.html','replicate\notes.txt') {
  [IO.File]::WriteAllText((Join-Path $DataDir $name), 'foreign content')
}
$DeleteData = $true; $KeepData = $false; $Yes = $true
Invoke-Uninstall $false
foreach ($name in 'config.json','events-2026-10-30.tsv','report-1.html','replicate\notes.txt') {
  Assert ([IO.File]::ReadAllText((Join-Path $DataDir $name)) -ceq 'foreign content') "foreign file preserved: $name"
}
Assert (-not (Test-Path -LiteralPath (Get-OwnershipPath))) 'uninstall does not manufacture an ownership record'

# Existing logger setup must not manufacture a marker/config during uninstall either.
Select-Data 'legacy-logger'
[IO.File]::WriteAllText($ConfigPath, '{"loggerEnabled":true,"loggerVars":{},"mode":"off"}')
Invoke-Uninstall $false
Assert (((Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json).loggerEnabled) -eq $false) 'uninstall records logger off in the existing config (a later install asks again)'
Assert (-not (Test-Path -LiteralPath (Get-OwnershipPath))) 'legacy logger uninstall cannot claim ownership'

# Manifest records only newly created files, not pre-existing config or wildcard matches.
Select-Data 'owned'
[IO.File]::WriteAllText($ConfigPath, '{"foreign":true}')
Write-Text (Join-Path $DataDir 'actions.jsonl') 'owned'
Ensure-Dir (Join-Path $DataDir 'replicate\arm')
Write-Text (Join-Path $DataDir 'replicate\arm\output.json') 'owned result'
[IO.File]::WriteAllText((Join-Path $DataDir 'replicate\arm\notes.txt'), 'foreign notes')
$snapshot = Get-Ownership
Assert ($null -ne $snapshot) 'a valid new-file ownership record is created'
Assert (-not (Test-OwnedFile $ConfigPath)) 'existing generic config is not adopted'
$later = Join-Path $DataDir 'created-later.txt'; Write-Text $later 'later'
Assert (Remove-OwnData $null $snapshot) 'owned deletion succeeds with a pre-existing snapshot'
Assert (-not (Test-Path -LiteralPath (Join-Path $DataDir 'actions.jsonl'))) 'recorded top-level file deleted'
Assert (-not (Test-Path -LiteralPath (Join-Path $DataDir 'replicate\arm\output.json'))) 'recorded nested file deleted individually'
Assert (Test-Path -LiteralPath (Join-Path $DataDir 'replicate\arm\notes.txt')) 'unknown nested file preserved'
Assert (Test-Path -LiteralPath $later) 'files first recorded after snapshot are preserved'
Assert (Test-Path -LiteralPath $ConfigPath) 'unowned config preserved alongside owned files'
[IO.File]::WriteAllText((Join-Path $DataDir 'actions.jsonl'), 'new foreign content at a deleted path')
Remove-OwnData $null $snapshot | Out-Null
Assert ([IO.File]::ReadAllText((Join-Path $DataDir 'actions.jsonl')) -ceq 'new foreign content at a deleted path') 'repeat deletion does not claim a reused filename'
$outside = Join-Path $runRoot 'outside.txt'; [IO.File]::WriteAllText($outside, 'outside')
Remove-OwnFile $outside $outside
Assert (Test-Path -LiteralPath $outside) 'allowed argument cannot authorize outside deletion'
Assert (-not (Test-SafeDataPath ([IO.Path]::GetPathRoot($DataDir)))) 'drive root is refused'
$bad = Get-Ownership; $bad.files = @('..\outside.txt')
[IO.File]::WriteAllText((Get-OwnershipPath), ($bad | ConvertTo-Json -Depth 4))
Assert ($null -eq (Get-Ownership)) 'traversal entry invalidates ownership record'

# -Yes preserves owned data without -DeleteData, and no destructive prompt is silently answered.
Select-Data 'yes-keeps-data'
Write-Text (Join-Path $DataDir 'events-owned.tsv') 'measurement'
$DeleteData = $false; $Yes = $true
Invoke-Uninstall $true
Assert (Test-Path -LiteralPath (Join-Path $DataDir 'events-owned.tsv')) '-Uninstall -Yes keeps measurement data'
$promptReached = $false
try { AskYesNo 'destructive action?' $false | Out-Null } catch { $promptReached = $true }
Assert $promptReached '-Yes does not auto-answer AskYesNo'

# Both same-mode/reapply and changed-mode paths must honor -NoLogger.
foreach ($prior in 'baseline','off') {
  Select-Data ('nologger-' + $prior)
  $cfg = Get-Config; $cfg.mode=$prior; $cfg.minutes=0; $cfg.loggerEnabled=$true; $cfg.port=47318; $cfg.loggerAutostart=$true; Save-Config $cfg
  $script:starts=0; $script:enables=0; $script:syntheticMode='pass'; $NoLogger=$true; $Yes=$true
  Set-TunerMode 'baseline' 0 $false $false
  Assert ($script:starts -eq 0 -and $script:enables -eq 0) "-NoLogger prevents start/rewrite/autostart for prior mode $prior"
}
# An explicit autostart choice must be applied even if the existing collector is healthy.
function Get-CollectorHealth { return @{pid=123;stored=0} }
foreach ($prior in 'baseline','off') {
  Select-Data ('autostart-' + $prior)
  $cfg=Get-Config; $cfg.mode=$prior; $cfg.minutes=0; $cfg.loggerEnabled=$true; $cfg.port=47318; Save-Config $cfg
  $NoLogger=$false; $Autostart='off'; $script:starts=0; $script:enables=0
  Set-TunerMode 'baseline' 0 $true $false
  Assert ($script:enables -eq 1 -and $script:starts -eq 0) "explicit autostart choice applied to healthy prior mode $prior"
}

# Test actual CLI preview/verification dispatch in a fresh process, without these mocks.
$env:CST_NO_MAIN = ''
$hostPath = (Get-Process -Id $PID).Path
Select-Data 'cli'
$existingReport = Join-Path $DataDir 'report.html'
[IO.File]::WriteAllText($existingReport, 'existing report must not be opened or overwritten')
$beforeFiles = @(Get-ChildItem -LiteralPath $DataDir -Recurse -File | ForEach-Object { $_.FullName + ':' + [IO.File]::ReadAllText($_.FullName) }) -join "`n"
$envBefore = @('BUN_OPTIONS') + $TunerVars + $OtelVarNames | ForEach-Object { [Environment]::GetEnvironmentVariable($_,'User') }
$previews = @(
  @('-WhatIf'), @('-Mode','off','-WhatIf'), @('-Mode','baseline','-Logger','on','-WhatIf'),
  @('-Mode','custom','-Minutes','2.5','-DryRun'), @('-Logger','on','-WhatIf'), @('-Logger','off','-WhatIf'),
  @('-Autostart','on','-WhatIf'), @('-Autostart','off','-WhatIf'), @('-Status','-WhatIf'),
  @('-CheckRestart','-WhatIf'), @('-Replicate','-Yes','-WhatIf'), @('-Uninstall','-DeleteData','-WhatIf'),
  @('-Report','-ReportTo',$existingReport,'-WhatIf'), @('-Verify','-WhatIf'), @('-ListLostStartupApps','-WhatIf')
)
foreach ($argv in $previews) {
  $result = & $hostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $candidate -DataDir $DataDir @argv 2>&1 | Out-String
  Assert ($LASTEXITCODE -eq 0 -and $result -match 'No child process, socket, or write was performed') ('CLI preview completes without action: ' + ($argv -join ' '))
}
$afterFiles = @(Get-ChildItem -LiteralPath $DataDir -Recurse -File | ForEach-Object { $_.FullName + ':' + [IO.File]::ReadAllText($_.FullName) }) -join "`n"
Assert ($beforeFiles -ceq $afterFiles) 'all preview actions preserve existing file bytes and create no data files'
$envAfter = @('BUN_OPTIONS') + $TunerVars + $OtelVarNames | ForEach-Object { [Environment]::GetEnvironmentVariable($_,'User') }
Assert (($envBefore -join "`0") -ceq ($envAfter -join "`0")) 'preview does not alter persistent tool environment values'
$hash = Get-FileSha256 $candidate
& $hostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $candidate -DataDir $DataDir -Verify -ExpectedHash $hash | Out-Null
Assert ($LASTEXITCODE -eq 0) 'matching hash exits zero'
& $hostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $candidate -DataDir $DataDir -Verify -ExpectedHash ('0' * 64) | Out-Null
Assert ($LASTEXITCODE -eq 1) 'mismatching hash exits one'
& $hostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $candidate -DataDir $DataDir -NoLogger -Logger on | Out-Null
Assert ($LASTEXITCODE -eq 2) 'contradictory logger flags fail before any action'
& $hostPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $candidate -DataDir $DataDir -Verify -Mode off -WhatIf | Out-Null
Assert ($LASTEXITCODE -eq 2) 'multiple primary actions rejected consistently in preview'
Write-Host "SECURITY REGRESSIONS: $script:checks passed. Artifacts: $runRoot"
