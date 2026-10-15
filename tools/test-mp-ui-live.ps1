<#
.SYNOPSIS
  Renders the multiplayer UI in the REAL game and hosts a real friends-only Steam lobby.
.DESCRIPTION
  1. refuses to run while projectpitt.exe is running
  2. installs PittAPI + PittMultiplayer + PittMPTests (-WithMP -WithTests)
  3. arms <user>\pittapi\mp_autotest.flag with role "ui_live" (PittMPTests/scenario_ui_live.gd)
     and forces transport=steam in PittMultiplayer.cfg (backed up and restored)
  4. hashes the save files, starts the game (Start-Game: projectpitt.exe with SteamAppId set)
  5. waits for the report (dist\mp-ui-live-report.json), kills projectpitt.exe
  6. re-hashes: any save change fails the run. Screens: dist\screens\live-*.png
  The scenario never enters a world, so no save is ever loaded or written.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\test-mp-ui-live.ps1
#>
param(
    [int]$TimeoutSec = 240,
    [string]$GameDir = '',
    [switch]$NoInstall
)
. "$PSScriptRoot\common.ps1"
$ErrorActionPreference = 'Continue'

if (Test-GameRunning) { Write-Bad 'projectpitt.exe is already running. Close it first.'; exit 2 }
$root = $script:RepoRoot
if (-not $root) { $root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }
$game = Get-GameDir $GameDir
if (-not $NoInstall) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install.ps1') -GameDir $game -WithMP -WithTests | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Bad 'install failed'; exit 2 }
    Write-Ok 'installed PittAPI + PittMultiplayer + PittMPTests'
}
$user = Get-UserDir
$pdir = Join-Path $user 'pittapi'
New-Item -ItemType Directory -Force (Join-Path $pdir 'config') | Out-Null
$cfgPath = Join-Path $pdir 'config\PittMultiplayer.cfg'
$cfgBackup = $null
if (Test-Path -LiteralPath $cfgPath) { $cfgBackup = Get-Content -Raw -LiteralPath $cfgPath }
Write-Utf8NoBom $cfgPath "[general]`n`ntransport=`"steam`"`n"

$screens = Join-Path $root 'dist\screens'
New-Item -ItemType Directory -Force $screens | Out-Null
Get-ChildItem -LiteralPath $screens -Filter 'live-*.png' -ErrorAction SilentlyContinue | Remove-Item -Force
$report = Join-Path $root 'dist\mp-ui-live-report.json'
if (Test-Path -LiteralPath $report) { Remove-Item -Force -LiteralPath $report }
$runId = 'ui-live-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$flag = [ordered]@{ role = 'ui_live'; run_id = $runId; timeout_s = [Math]::Max(60, $TimeoutSec - 30); quit = $true
    report = (ConvertTo-GodotPath $report); screens_dir = (ConvertTo-GodotPath $screens) }
Write-Utf8NoBom (Join-Path $pdir 'mp_autotest.flag') ($flag | ConvertTo-Json)

Write-Step 'Hashing save files (they must not change)'
$before = Get-SaveHashes $user
Write-Ok "$($before.Count) save files"

Write-Step "Launching the game"
Start-Game $GameDir
$t0 = Get-Date
$done = $null
while (((Get-Date) - $t0).TotalSeconds -lt $TimeoutSec) {
    Start-Sleep -Seconds 1
    if (Test-Path -LiteralPath $report) {
        try { $r = Get-Content -Raw -LiteralPath $report | ConvertFrom-Json } catch { $r = $null }
        if ($r -and $r.finished) { $done = $r; break }
    }
}
Start-Sleep -Seconds 6
Stop-Game
Start-Sleep -Seconds 2
if ($cfgBackup -ne $null) { Write-Utf8NoBom $cfgPath $cfgBackup } else { Remove-Item -Force -LiteralPath $cfgPath -ErrorAction SilentlyContinue }
$flagLeft = Join-Path $pdir 'mp_autotest.flag'
if (Test-Path -LiteralPath $flagLeft) { Remove-Item -Force -LiteralPath $flagLeft }

$fail = 0
if (-not $done) { Write-Bad 'no finished report (timeout)'; $fail++ }
else {
    foreach ($s in $done.steps) {
        if ($s.ok) { Write-Host ("    PASS {0}.{1} {2}" -f $s.step, $s.name, $s.msg) }
        else { Write-Bad ("{0}.{1}: {2}" -f $s.step, $s.name, $s.msg); $fail++ }
    }
    if ($done.fatal) { Write-Bad "fatal: $($done.fatal)"; $fail++ }
}
Write-Step 'Re-hashing save files'
$after = Get-SaveHashes $user
$changed = @()
foreach ($k in $before.Keys) { if (-not $after.ContainsKey($k) -or $after[$k] -ne $before[$k]) { $changed += $k } }
foreach ($k in $after.Keys) { if (-not $before.ContainsKey($k)) { $changed += $k } }
if ($changed.Count -gt 0) { Write-Bad ("save files changed: " + ($changed -join ', ')); $fail++ } else { Write-Ok 'save files unchanged' }
if (Test-GameRunning) { Write-Bad 'projectpitt.exe still running'; $fail++ }
if ($fail -eq 0) { Write-Host 'MP UI LIVE PASSED' -ForegroundColor Green; exit 0 }
Write-Host "MP UI LIVE FAILED ($fail)" -ForegroundColor Red
exit 1
