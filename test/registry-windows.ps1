# Windows-only test of the v1.0.2 Run-key fix, against a SCRATCH key (never the real Run key):
#   HKCU:\Software\ClaudeSummaryTunerTest\Run  and  ...\StartupApproved\Run
# v1.0.0/1.0.1 ran "New-Item <Run key> -Force", which deletes and recreates the key, so every other value was lost.
# Run:  powershell -NoProfile -ExecutionPolicy Bypass -File .\test\registry-windows.ps1 [-Script <path to .ps1>]
param([string]$Script = (Join-Path $PSScriptRoot '..\Claude-Summary-Tuner.ps1'))
if ($env:OS -ne 'Windows_NT') { Write-Host 'SKIP: registry test needs Windows'; exit 0 }
$env:CST_NO_MAIN = '1'
$tmpData = Join-Path $env:TEMP ('cst-regtest-' + [guid]::NewGuid().ToString('N'))
. $Script -DataDir $tmpData -NoOpen
$Root = 'HKCU:\Software\ClaudeSummaryTunerTest\' + [guid]::NewGuid().ToString('N')
$RunKeyPath = "$Root\Run"                       # overrides the script's real Run key for this test only
$StartupApprovedPath = "$Root\StartupApproved\Run"
$RunValueName = 'ClaudeSummaryTunerCollector'
$fail = 0
function Check($name, $got, $exp) { if ("$got" -ceq "$exp") { Write-Host "PASS $name" } else { Write-Host "FAIL $name : got [$got] expected [$exp]"; $script:fail++ } }
function Names($k) { if (-not (Test-Path -LiteralPath $k)) { return '' }; return ((Get-Item -LiteralPath $k).GetValueNames() | Sort-Object) -join ',' }
try {
  if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
  # Create only the isolated parent; production Set-RunValue assumes its CurrentVersion parent exists.
  $parent = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($Root.Substring(6)); $parent.Dispose()
  # 1. key does not exist yet: it is created, with only our value
  Set-RunValue '"C:\x\powershell.exe" -File collector.ps1'
  Check 'creates missing key' (Names $RunKeyPath) $RunValueName
  # 2. other values in the key survive Set-RunValue (the v1.0.0/1.0.1 bug wiped them)
  New-ItemProperty -LiteralPath $RunKeyPath -Name 'OneDrive' -Value '"C:\OneDrive.exe" /background' | Out-Null
  New-ItemProperty -LiteralPath $RunKeyPath -Name 'Steam' -Value '"C:\steam.exe" -silent' | Out-Null
  Set-RunValue '"C:\x\powershell.exe" -File collector.ps1 -Port 47319'
  Check 'other values survive Set-RunValue' (Names $RunKeyPath) "$RunValueName,OneDrive,Steam"
  Check 'other value data unchanged' ((Get-ItemProperty -LiteralPath $RunKeyPath -Name 'OneDrive').OneDrive) '"C:\OneDrive.exe" /background'
  Check 'our value updated' ((Get-ItemProperty -LiteralPath $RunKeyPath -Name $RunValueName).$RunValueName) '"C:\x\powershell.exe" -File collector.ps1 -Port 47319'
  # 3. a second Set-RunValue (mode change with logger on) still keeps them
  Set-RunValue '"C:\x\powershell.exe" -File collector.ps1 -Port 47319'
  Check 'other values survive repeat' (Names $RunKeyPath) "$RunValueName,OneDrive,Steam"
  # 4. Remove-RunValue removes only ours
  Remove-RunValue
  Check 'Remove-RunValue removes only ours' (Names $RunKeyPath) 'OneDrive,Steam'
  # 5. -WhatIf: nothing written
  $script:DryRun = $true; Set-RunValue 'whatif'; Remove-RunValue; $script:DryRun = $false
  Check 'dry run writes nothing' (Names $RunKeyPath) 'OneDrive,Steam'
  # 6. -ListLostStartupApps logic: names in StartupApproved\Run without a Run value
  New-Item -Path $StartupApprovedPath -Force | Out-Null   # scratch key only
  foreach ($n in 'OneDrive', 'Steam', 'Spotify', 'Discord') { New-ItemProperty -LiteralPath $StartupApprovedPath -Name $n -PropertyType Binary -Value ([byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) | Out-Null }
  Set-ItemProperty -LiteralPath $StartupApprovedPath -Name 'Discord' -Value ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
  $lost = @(Get-LostStartupApps | Sort-Object Name)
  Check 'lost apps' (($lost | ForEach-Object { "$($_.Name)=$($_.State)" }) -join ',') 'Discord=was disabled,Spotify=was enabled'
  Check 'lost check read-only' (Names $RunKeyPath) 'OneDrive,Steam'
} finally {
  if (Test-Path -LiteralPath $Root) { Remove-Item -LiteralPath $Root -Recurse -Force }
  if (Test-Path -LiteralPath $tmpData) { Remove-Item -LiteralPath $tmpData -Recurse -Force }
  $testParent = 'HKCU:\Software\ClaudeSummaryTunerTest'
  if ((Test-Path -LiteralPath $testParent) -and -not (Get-ChildItem -LiteralPath $testParent) -and -not (Get-Item -LiteralPath $testParent).ValueCount) { Remove-Item -LiteralPath $testParent }
}
Check 'scratch key cleaned up' (Test-Path -LiteralPath $Root) 'False'
"REGISTRY FAILURES: $fail"
if ($fail) { exit 1 }
