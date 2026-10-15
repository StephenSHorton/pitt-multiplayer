<#
.SYNOPSIS
  Runs the PittAPITests suites inside the real game and checks that no save file changed.
.DESCRIPTION
  1. refuses to run while projectpitt.exe is running
  2. installs PittAPI with -WithTests (unless -NoInstall)
  3. writes the one-shot flag user://pittapi/autotest.flag, deletes the old report,
     and hashes every savegame*, sandbox.save* and profile.cfg in user://
  4. starts projectpitt.exe with SteamAppId set (Start-Game; Steam must be running)
  5. waits for user://pittapi/test_report.json with "finished": true
  6. kills projectpitt.exe if it is still running 10 s after the report (or on timeout)
  7. re-hashes the save files: ANY change fails the run
  8. prints a summary; exit code 0 = all passed and saves untouched
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\test-live.ps1 -Suites boot,menu,gameplay
#>
param(
    [string[]]$Suites = @('boot', 'menu'),
    [int]$TimeoutSec = 300,
    [string]$GameDir = '',
    [switch]$NoInstall,
    [switch]$Uninstall
)
. "$PSScriptRoot\common.ps1"
$ErrorActionPreference = 'Continue'

if ($Suites.Count -eq 1 -and $Suites[0] -like '*,*') { $Suites = $Suites[0] -split ',' }
if (Test-GameRunning) { Write-Bad 'projectpitt.exe is already running. Close it first.'; exit 2 }
$game = Get-GameDir $GameDir

if (-not $NoInstall) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install.ps1') -GameDir $game -WithTests
    if ($LASTEXITCODE -ne 0) { Write-Bad 'install failed'; exit 2 }
}

$user = Get-UserDir
$pdir = Join-Path $user 'pittapi'
New-Item -ItemType Directory -Force $pdir | Out-Null
$report = Join-Path $pdir 'test_report.json'
if (Test-Path -LiteralPath $report) { Remove-Item -Force -LiteralPath $report }
# test-owned persistent state: start every run from defaults
$testCfg = Join-Path $pdir 'config\PittAPITests.cfg'
if (Test-Path -LiteralPath $testCfg) { Remove-Item -Force -LiteralPath $testCfg }
$testKb = Join-Path $pdir 'keybinds.cfg'
if (Test-Path -LiteralPath $testKb) {
    $kept = @(); $skip = $false
    foreach ($line in Get-Content -LiteralPath $testKb) {
        if ($line -match '^\s*\[(.+)\]\s*$') { $skip = ($Matches[1] -eq 'PittAPITests') }
        if (-not $skip) { $kept += $line }
    }
    Write-Utf8NoBom $testKb (($kept -join "`n") + "`n")
}
$runId = 'live-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
$flag = [ordered]@{ run_id = $runId; suites = $Suites; quit = $true; timeout_s = [Math]::Max(60, $TimeoutSec - 30) }
Write-Utf8NoBom (Join-Path $pdir 'autotest.flag') ($flag | ConvertTo-Json -Compress)

Write-Step 'Hashing save files (they must not change)'
$before = Get-SaveHashes $user
$kbPath = Join-Path $user 'keybindings.cfg'
$kbBefore = if (Test-Path -LiteralPath $kbPath) { (Get-FileHash -LiteralPath $kbPath).Hash } else { '<none>' }
foreach ($k in $before.Keys) { Write-Host "    $k $($before[$k].Substring(0,16))" }
if ($before.Count -eq 0) { Write-Host '    (no save files yet)' }

Write-Step "Launching through Steam (run $runId, suites: $($Suites -join ','))"
Start-Game $GameDir
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$finished = $false
$lastCount = -1
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    if (Test-Path -LiteralPath $report) {
        try {
            $r = Get-Content -Raw -LiteralPath $report | ConvertFrom-Json
            $count = $r.summary.passed + $r.summary.failed
            if ($count -ne $lastCount) { Write-Host ("    progress: {0} passed, {1} failed" -f $r.summary.passed, $r.summary.failed); $lastCount = $count }
            if ($r.finished) { $finished = $true; break }
        } catch {}
    }
}
if ($finished) {
    $exitBy = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $exitBy -and (Test-GameRunning)) { Start-Sleep -Milliseconds 500 }
}
if (Test-GameRunning) { Write-Warn2 'killing projectpitt.exe'; Stop-Game; Start-Sleep -Seconds 2 }

Write-Step 'Re-hashing save files'
$after = Get-SaveHashes $user
$changed = @()
foreach ($k in ($before.Keys + $after.Keys | Sort-Object -Unique)) {
    if ($before[$k] -ne $after[$k]) { $changed += "$k ($($before[$k]) -> $($after[$k]))" }
}
$kbAfter = if (Test-Path -LiteralPath $kbPath) { (Get-FileHash -LiteralPath $kbPath).Hash } else { '<none>' }

$ok = $true
if ($changed.Count -gt 0) {
    $ok = $false
    Write-Bad 'SAVE FILES CHANGED:'
    $changed | ForEach-Object { Write-Host "         $_" -ForegroundColor Red }
    Write-Host '         A backup of user:// is in .tools\save-backup-*' -ForegroundColor Red
} else { Write-Ok 'save files unchanged' }
if ($kbBefore -ne $kbAfter) { Write-Warn2 'keybindings.cfg changed (the game rewrites it; PittAPI never writes it)' }

if (-not $finished) {
    $ok = $false
    Write-Bad "no finished report within $TimeoutSec s ($report)"
}
if (Test-Path -LiteralPath $report) {
    $r = Get-Content -Raw -LiteralPath $report | ConvertFrom-Json
    Write-Step ("Report: {0} passed, {1} failed, {2} skipped, {3} info" -f $r.summary.passed, $r.summary.failed, $r.summary.skipped, $r.summary.info)
    foreach ($s in $r.suites) {
        foreach ($t in $s.tests) {
            if ($t.info) { Write-Host ("    INFO {0}.{1}: {2} ({3})" -f $s.name, $t.name, $t.ok, $t.msg) -ForegroundColor Yellow }
            elseif (-not $t.ok) { Write-Host ("    FAIL {0}.{1}: {2}" -f $s.name, $t.name, $t.msg) -ForegroundColor Red }
        }
    }
    if ($r.fatal) { Write-Bad "fatal: $($r.fatal)" }
    if ($r.summary.failed -gt 0) { $ok = $false }
}

if ($Uninstall) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'uninstall.ps1') -GameDir $game -TestsOnly
}
$flagLeft = Join-Path $pdir 'autotest.flag'
if (Test-Path -LiteralPath $flagLeft) { Remove-Item -Force -LiteralPath $flagLeft; Write-Warn2 'the flag was never consumed (did PittAPI load?) - removed it' }

if ($ok) { Write-Host 'LIVE TESTS PASSED' -ForegroundColor Green; exit 0 }
Write-Host 'LIVE TESTS FAILED' -ForegroundColor Red
exit 1
