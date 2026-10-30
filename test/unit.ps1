# Unit tests for Claude-Summary-Tuner.ps1 (runs on Linux/macOS/Windows with PowerShell 7: pwsh ./test/unit.ps1).
# Uses synthetic data only; writes to temp folders; regenerates test/fixtures/sample-report.html.
param([string]$TestRoot = [IO.Path]::GetTempPath())
$ErrorActionPreference = 'Stop'
$TestRoot = Join-Path ([IO.Path]::GetFullPath($TestRoot)) ('unit-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($TestRoot)
$env:CST_NO_MAIN = '1'
$env:LOCALAPPDATA = Join-Path $TestRoot 'localappdata'; $env:USERPROFILE = Join-Path $TestRoot 'home'; $env:TEMP = Join-Path $TestRoot 'temp'
[void][IO.Directory]::CreateDirectory($env:TEMP)
$DataDirArg = Join-Path $TestRoot 'data'
. (Join-Path $PSScriptRoot '../Claude-Summary-Tuner.ps1') -DataDir $DataDirArg -NoOpen
$fail = 0
function Check($name, $got, $exp) { if ("$got" -ceq "$exp") { Write-Host "PASS $name" } else { Write-Host "FAIL $name : got [$got] expected [$exp]"; $script:fail++ } }
# BUN_OPTIONS merge
Check 'merge empty' (Merge-BunOptions '' 'C:/x/no-agent-summary.js') '--preload=C:/x/no-agent-summary.js'
Check 'merge keeps others' (Merge-BunOptions '--smol  --preload C:/other/tool.js' 'C:/x/no-agent-summary.js') '--smol --preload C:/other/tool.js --preload=C:/x/no-agent-summary.js'
Check 'merge replaces legacy' (Merge-BunOptions '--preload C:/Users/Alice/.local/share/no-agent-summary.js' 'C:/x/no-agent-summary.js') '--preload=C:/x/no-agent-summary.js'
Check 'merge idempotent' (Merge-BunOptions (Merge-BunOptions '--smol' 'C:/x/no-agent-summary.js') 'C:/x/no-agent-summary.js') '--smol --preload=C:/x/no-agent-summary.js'
Check 'merge eq-form' (Merge-BunOptions '--preload=C:/a/no-agent-summary.js --hot' 'C:/x/no-agent-summary.js') '--hot --preload=C:/x/no-agent-summary.js'
Check 'upgrade v1.0.0 space form' (Merge-BunOptions '--preload C:/x/no-agent-summary.js' 'C:/x/no-agent-summary.js') '--preload=C:/x/no-agent-summary.js'
Check 'upgrade space form keeps others' (Merge-BunOptions '--smol --preload C:/x/no-agent-summary.js --hot' 'C:/x/no-agent-summary.js') '--smol --hot --preload=C:/x/no-agent-summary.js'
Check 'old form detected' (Test-OldPreloadForm '--preload C:/x/no-agent-summary.js') 'True'
Check 'old manual form detected' (Test-OldPreloadForm '--smol --preload C:/Users/Alice/.local/share/no-agent-summary.js') 'True'
Check 'eq form not old' (Test-OldPreloadForm '--preload=C:/x/no-agent-summary.js') 'False'
Check 'other space preload not ours' (Test-OldPreloadForm '--preload C:/other/tool.js') 'False'
Check 'remove' (Remove-OurPreload '--smol --preload C:/x/no-agent-summary.js') '--smol'
Check 'remove only ours' (Remove-OurPreload '--preload C:/x/no-agent-summary.js') ''
Check 'remove eq form (uninstall)' (Remove-OurPreload '--smol --preload=C:/x/no-agent-summary.js') '--smol'
Check 'remove keeps foreign eq' (Remove-OurPreload '--preload=C:/other/tool.js --preload=C:/x/no-agent-summary.js') '--preload=C:/other/tool.js'
# version drift
Check 'drift none' ((Get-VersionDrift @('2.1.312') @('2.1.312')) -join ',') ''
Check 'drift new' ((Get-VersionDrift @('2.1.312') @('2.1.315')) -join ',') '2.1.315'
Check 'drift nothing recorded' ((Get-VersionDrift @() @('2.1.315')) -join ',') ''
Check 'drift desktop' ((Get-VersionDrift @('2.1.309') @('2.1.309', '2.1.320')) -join ',') '2.1.320'
# anonymising
$env:USERNAME = 'Zed99'; $env:COMPUTERNAME = 'DESK-77'; $env:APPDATA = 'C:\Users\Zed99\AppData\Roaming'; $saveLad = $env:LOCALAPPDATA; $env:LOCALAPPDATA = 'C:\Users\Zed99\AppData\Local'
Check 'hide localappdata' (Hide-UserPaths 'C:\Users\Zed99\AppData\Local\cc-summary-tuner') '%LOCALAPPDATA%\cc-summary-tuner'
Check 'hide fwd slashes' (Hide-UserPaths 'C:/Users/Zed99/AppData/Local/cc-summary-tuner/no-agent-summary.js') '%LOCALAPPDATA%/cc-summary-tuner/no-agent-summary.js'
Check 'hide other user path' (Hide-UserPaths 'D:\Users\Someone\x') 'D:\Users\%USERNAME%\x'
Check 'hide names' (Hide-UserPaths 'host DESK-77 user zed99 ok') 'host %COMPUTERNAME% user %USERNAME% ok'
$env:LOCALAPPDATA = $saveLad
Check 'preload paths' ((Get-PreloadPaths '--smol --preload C:/a.js --preload=C:/b.js') -join ',') 'C:/a.js,C:/b.js'
Check 'bunpath no space' (ConvertTo-BunPath 'C:\Users\Bob\AppData\Local\cc-summary-tuner\no-agent-summary.js') 'C:/Users/Bob/AppData/Local/cc-summary-tuner/no-agent-summary.js'
Check 'parse num comma' (ParseNum '2,5') '2.5'
Check 'parse num' (ParseNum '0.000123') '0.000123'
Check 'fmt invariant' (Fmt 1234.5 '0.0') '1234.5'
[Threading.Thread]::CurrentThread.CurrentCulture = 'de-CH'
Check 'fmt under de-CH' (Fmt 0.25 '0.00') '0.25'
Check 'money' (Money 0.0123) '$0.012'
# synthetic data: journal + events + hook log
Ensure-Dir $DataDir
$now = NowUtc; $t0 = $now.AddDays(-4)
$cfg = Get-Config; $cfg.mode = 'slow'; $cfg.minutes = 5; Save-Config $cfg
function J($t, $o) { $o['t'] = IsoUtc $t; Append-Text $JournalPath (((New-Object PSObject -Property $o) | ConvertTo-Json -Compress) + "`r`n") }
J $t0.AddMinutes(-5) @{ action = 'logger_on'; port = 47318 }
J $t0 @{ action = 'mode'; mode = 'baseline'; minutes = 0; cc_version = '2.1.312' }
J $t0.AddMinutes(20) @{ action = 'effective'; ref = (IsoUtc $t0); how = 'no old process left' }
$t1 = $now.AddDays(-2)
J $t1 @{ action = 'mode'; mode = 'slow'; minutes = 5; cc_version = '2.1.312' }
J $t1.AddMinutes(30) @{ action = 'effective'; ref = (IsoUtc $t1); how = 'user confirmed' }
J $t1.AddMinutes(40) @{ action = 'replicate'; cc_version = '2.1.312'; forks = '5 / 5 / 0'; folder = 'C:\Users\Zed99\AppData\Local\cc-summary-tuner\replicate\x' }
J $now.AddHours(-2) @{ action = 'reapply'; mode = 'slow'; minutes = 5; tool_version = '1.0.1'; rewrote_old_form = $true }
$cols = 't','event','session','model','query_source','cost_usd','input_tokens','output_tokens','cache_read_tokens','cache_creation_tokens','duration_ms','version','agent','tag','status'
$sb = New-Object Text.StringBuilder; [void]$sb.AppendLine(($cols -join "`t"))
$rnd = New-Object Random 7
for ($m = 0; $m -lt 4 * 24 * 60; $m += 3) {
  $t = $t0.AddMinutes($m); if ($t.Hour -lt 7) { continue }
  $slowp = $t -ge $t1
  [void]$sb.AppendLine((@((IsoUtc $t), 'api_request', 's1', 'claude-opus-5', 'repl_main_thread', (0.02 + $rnd.NextDouble()*0.05).ToString($Inv), 100, 300, 20000, 500, 3000, '2.1.312', '', '', '') -join "`t"))
  if (-not $slowp -or ($m % 30 -eq 0)) { [void]$sb.AppendLine((@((IsoUtc $t.AddSeconds(30)), 'api_request', 's1', 'claude-opus-5', 'agent_summary', (0.015).ToString($Inv), 5, 10, 40000, 0, 900, '2.1.312', '', '', '') -join "`t")) }
  if ($m % 9 -eq 0) { [void]$sb.AppendLine((@((IsoUtc $t.AddSeconds(50)), 'api_request', 's1', 'claude-haiku-4-5', 'agent:builtin:general-purpose', '0.004', 10, 50, 1000, 0, 800, '2.1.312', 'general-purpose', '', '') -join "`t")) }
}
[void]$sb.AppendLine((@((IsoUtc $now.AddHours(-1)), 'api_request', 'r', 'claude-haiku-4-5', 'agent_summary', '0.001', 1, 1, 1, 1, 1, '2.1.312', '', 'replicate-x-pass', '') -join "`t"))
Write-Text (Join-Path $DataDir ('events-' + $now.ToString('yyyy-MM-dd') + '.tsv')) $sb.ToString()
$hl = @("$(IsoUtc $t0.AddMinutes(10)) pid=100 preload active mode=pass bun=1.4.4 hooked=x", "$(IsoUtc $t0.AddMinutes(11)) pid=100 summary timer #1 passed (control, setTimeout, delay=30000)", "$(IsoUtc $t1.AddMinutes(-1)) pid=100 exit: 0 summary timer(s) suppressed, 40 matched",
  "$(IsoUtc $t1.AddMinutes(31)) pid=200 preload active mode=slow min_delay=300000 bun=1.4.4 hooked=x", "$(IsoUtc $t1.AddMinutes(32)) pid=200 summary timer #1 slowed (setTimeout, delay=30000 -> 300000)", "$(IsoUtc $now.AddMinutes(-3)) pid=200 exit: 0 summary timer(s) suppressed, 12 slowed, 12 matched")
Write-Text $HookLogPath (($hl -join "`r`n") + "`r`n")
$ev = @(Read-Events); Check 'tagged excluded' (@($ev | ? { $_.tag }).Count) 0
Check 'tagged included' (@(Read-Events -IncludeTagged | ? { $_.tag }).Count) 1
$p = @(Get-Periods (Read-Journal) ($ev | Sort-Object t)); Check 'periods' ($p.label -join '|') 'baseline|slow 5 min'
$st = @($p | % { Get-PeriodStats $_ $ev (Read-HookLog $cfg) })
Check 'hook evidence baseline matched' $st[0].matched 40
Check 'hook evidence slow slowed' $st[1].slowed 12
Write-Host ("share baseline {0:P1} slow {1:P1}" -f ($st[0].asCost/$st[0].cost), ($st[1].asCost/$st[1].cost))
if ($st[1].asCost / $st[1].activeH -ge $st[0].asCost / $st[0].activeH) { Write-Host 'FAIL slow should be lower'; $fail++ } else { Write-Host 'PASS slow lower per active h' }
$out = New-Report
$html = Get-Content $out -Raw
Check 'html has svg' ([bool]($html -match '<svg')) 'True'
Check 'no CDN' ([bool]($html -match '(src|href)=.https?:')) 'False'
Check 'svg numbers invariant' ([bool]($html -match "width='\d+,\d")) 'False'
Check 'report has no PC name' ([bool]($html -match 'DESK-77')) 'False'
Check 'report has no user name' ([bool]($html -match '(?i)zed99')) 'False'
Check 'report has no Users path' ([bool]($html -match '(?i)[A-Z]:[\\/]Users[\\/](?!%USERNAME%)')) 'False'
Check 'reapply does not split periods' ((@(Get-Periods (Read-Journal) ($ev | Sort-Object t))).label -join '|') 'baseline|slow 5 min'
Copy-Item $out (Join-Path $PSScriptRoot 'fixtures/sample-report.html')
# ---- v1.0.2: secrets are never printed
Check 'secret name otel headers' (Show-EnvValue 'OTEL_EXPORTER_OTLP_HEADERS' 'Authorization=Bearer sk-123') '(set, value not shown)'
Check 'secret name any otel' (Show-EnvValue 'OTEL_LOGS_EXPORTER' 'otlp') '(set, value not shown)'
Check 'secret name api key' (Show-EnvValue 'MY_API_KEY' 'abc') '(set, value not shown)'
Check 'secret name token' (Show-EnvValue 'GITHUB_TOKEN' 'abc') '(set, value not shown)'
Check 'plain value shown' (Show-EnvValue 'BUN_OPTIONS' '--smol') "'--smol'"
New-Item -ItemType Directory -Force (Join-Path $env:USERPROFILE '.claude') | Out-Null
Set-Content -LiteralPath (Join-Path $env:USERPROFILE '.claude/settings.json') -Value '{"env":{"OTEL_EXPORTER_OTLP_HEADERS":"Authorization=Bearer sk-SECRET-42","OTEL_EXPORTER_OTLP_ENDPOINT":"https://otel.example.com"}}'
$conf = (Get-OtelConflicts (Get-Config)) -join "`n"
Check 'conflicts list names' ([bool]($conf -match 'OTEL_EXPORTER_OTLP_HEADERS')) 'True'
Check 'conflicts hide header value' ([bool]($conf -match 'sk-SECRET-42|Bearer')) 'False'
Check 'conflicts hide endpoint value' ([bool]($conf -match 'otel\.example\.com')) 'False'
# Ownership/deletion and action-level safety tests are in security-regressions.ps1.
# ---- v1.0.2: static checks on the script itself
$tok = $null; $perr = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot '../Claude-Summary-Tuner.ps1'), [ref]$tok, [ref]$perr)
$cmds = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true))
$forceNewItem = @($cmds | Where-Object { $_.GetCommandName() -eq 'New-Item' -and ($_.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Force' }) })
Check 'no New-Item -Force anywhere (it recreates registry keys)' $forceNewItem.Count 0
Check 'collector has no New-Item -Force' ([bool]($CollectorPs -match 'New-Item[^\r\n]*-Force')) 'False'
$gate = 'Register-OwnFile', 'Ensure-Dir', 'Write-Text', 'Append-Text', 'Remove-OwnFile', 'Remove-OwnData', 'Set-UserEnv', 'Set-RunValue', 'Remove-RunValue', 'Start-CollectorProcess', 'Stop-CollectorProcess', 'Stop-ClaudeDaemon', 'Start-ReplicateChild'
# Not persistent, reviewed: Process-scope variables for child processes, and the self-test's own temp file.
$allowed = @('Invoke-Isolated|SetEnvironmentVariable', 'Invoke-Replicate|SetEnvironmentVariable', 'Test-HookLoads|Remove-Item')
$writers = 'New-Item', 'Set-Item', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-Item', 'Remove-ItemProperty', 'Move-Item', 'Copy-Item', 'Rename-Item', 'Set-Content', 'Add-Content', 'Out-File', 'Start-Process', 'Stop-Process', 'Set-ExecutionPolicy', 'Invoke-Expression', 'Invoke-WebRequest', 'Invoke-RestMethod'
$members = 'WriteAllText', 'AppendAllText', 'WriteAllBytes', 'WriteAllLines', 'CreateDirectory', 'Delete', 'SetEnvironmentVariable', 'SetValue', 'DeleteValue', 'DeleteSubKeyTree', 'DownloadString', 'DownloadFile'
function FuncOf($n) { $p = $n.Parent; while ($p) { if ($p -is [System.Management.Automation.Language.FunctionDefinitionAst]) { return $p.Name }; $p = $p.Parent }; return '(top level)' }
$viol = @()
foreach ($c in $cmds) { $nm = $c.GetCommandName(); if ($nm -in $writers) { $f = FuncOf $c; if ($f -notin $gate -and "$f|$nm" -notin $allowed) { $viol += "$f -> $nm (line $($c.Extent.StartLineNumber))" } } }
foreach ($m in @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true))) {
  $nm = [string]$m.Member.Value; if ($nm -notin $members) { continue }
  $f = FuncOf $m; if ($f -in $gate -or "$f|$nm" -in $allowed) { continue }
  $viol += "$f -> .$nm (line $($m.Extent.StartLineNumber))"
}
if ($viol.Count) { $viol | ForEach-Object { Write-Host "  gate violation: $_" } }
Check 'every persistent change goes through the CHANGE GATE' $viol.Count 0
if ($env:OS -eq 'Windows_NT') { & (Join-Path $PSScriptRoot 'registry-windows.ps1'); if ($LASTEXITCODE) { $fail++ } } else { Write-Host 'SKIP registry test (Windows only: test/registry-windows.ps1)' }
"FAILURES: $fail"
if ($fail) { exit 1 }
