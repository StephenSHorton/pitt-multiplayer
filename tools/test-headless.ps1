<#
.SYNOPSIS
  PittAPI headless checks: parse-check every script, contract check, manifest
  validation, then the unit tests against fake autoloads. No game needed.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\test-headless.ps1
  powershell -ExecutionPolicy Bypass -File tools\test-headless.ps1 -Filter money -SkipParse
#>
param(
    [string]$Filter = '',
    [switch]$SkipParse,
    [switch]$KeepUserDir
)
. "$PSScriptRoot\common.ps1"
# native tools write to stderr; do not turn that into terminating errors (PS 5.1)
$ErrorActionPreference = 'Continue'

$root = $script:RepoRoot
$godot = Get-GodotExe
$dist = Join-Path $root 'dist'
$proj = Join-Path $dist 'headless-project'
$report = Join-Path $dist 'headless-report.json'
$failures = @()

Write-Step "Building $proj"
if (Test-Path -LiteralPath $proj) { Remove-Item -Recurse -Force -LiteralPath $proj }
New-Item -ItemType Directory -Force $proj | Out-Null
$tests = Join-Path $proj 'tests'
New-Item -ItemType Directory -Force $tests | Out-Null
foreach ($item in Get-ChildItem (Join-Path $root 'tests\headless')) {
    if ($item.Name -in @('project.godot.template', 'stubs')) { continue }
    Copy-Item -Recurse -Force $item.FullName (Join-Path $tests $item.Name)
}
Copy-Item -Recurse -Force (Join-Path $root 'tests\headless\stubs\*') $proj
# multiplayer streams keep their own game-script stand-ins (e.g. fakes\mp_net\stubs\scripts\hole.gd
# becomes res://scripts/hole.gd) so their script extensions compile headless. MP1 streams (mp_*)
# first, then the MP2 streams (mp2_*): a later stream's stand-in of the same script is a superset
# (it adds what its own extension of that script calls) and wins.
$mpDirs = @(Get-ChildItem -Directory (Join-Path $root 'tests\headless\fakes') -Filter 'mp_*' | Sort-Object Name)
$mpDirs += @(Get-ChildItem -Directory (Join-Path $root 'tests\headless\fakes') -Filter 'mp2_*' | Sort-Object Name)
foreach ($mpFakes in $mpDirs) {
    $mpStubs = Join-Path $mpFakes.FullName 'stubs'
    if (Test-Path -LiteralPath $mpStubs) { Copy-Item -Recurse -Force (Join-Path $mpStubs '*') $proj }
}
$gamedir = Join-Path $proj 'gamedir'
$modsDir = Join-Path $gamedir 'mods'
New-Item -ItemType Directory -Force $modsDir | Out-Null
Write-Utf8NoBom (Join-Path $gamedir '.gdignore') ''
Copy-Item -Recurse -Force (Join-Path $root 'loader') (Join-Path $modsDir 'PittAPI')
foreach ($m in Get-ChildItem -Directory (Join-Path $root 'mods')) {
    Copy-Item -Recurse -Force $m.FullName (Join-Path $modsDir $m.Name)
}
$pittapiPath = ConvertTo-GodotPath (Join-Path $modsDir 'PittAPI\pittapi.gd')
$tpl = Get-Content -Raw -LiteralPath (Join-Path $root 'tests\headless\project.godot.template')
Write-Utf8NoBom (Join-Path $proj 'project.godot') ($tpl -replace '\{\{PITTAPI_PATH\}\}', $pittapiPath)

$userDir = Join-Path $env:APPDATA 'Godot\app_userdata\PittAPIHeadless'
if (-not $KeepUserDir -and (Test-Path -LiteralPath $userDir)) { Remove-Item -Recurse -Force -LiteralPath $userDir }

Write-Step 'Importing (builds the global class cache for the fake BigInt)'
& $godot --headless --path $proj --import 2>&1 | Out-Null

# ---------------------------------------------------------------- 1. parse check
if (-not $SkipParse) {
    Write-Step 'Parse-checking every script (--check-only)'
    $expectedFail = @('_PittAPIBrokenFixture\main.gd')
    $files = @()
    $files += Get-ChildItem -Recurse -File -Filter *.gd $modsDir
    $files += Get-ChildItem -Recurse -File -Filter *.gd $tests | Where-Object { $_.FullName -notlike '*\fixtures\*' }
    $files += Get-ChildItem -Recurse -File -Filter *.gd (Join-Path $proj 'scripts')
    $checked = 0
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($proj.Length + 1)
        $out = & $godot --headless --path $proj --check-only -s (ConvertTo-GodotPath $f.FullName) 2>&1 | Out-String
        $code = $LASTEXITCODE
        $shouldFail = $false
        foreach ($e in $expectedFail) { if ($rel.EndsWith($e)) { $shouldFail = $true } }
        $checked++
        if ($shouldFail) {
            if ($code -eq 0) { Write-Bad "$rel should fail to parse but passed"; $failures += "parse:$rel(expected-fail)" }
            else { Write-Ok "$rel fails to parse, as intended" }
        } elseif ($code -ne 0 -or $out -match 'Parse Error') {
            Write-Bad $rel
            ($out -split "`n" | Where-Object { $_ -match 'ERROR' } | Select-Object -First 6) | ForEach-Object { Write-Host "         $_" }
            $failures += "parse:$rel"
        }
    }
    Write-Ok "$checked scripts checked"
}

# ---------------------------------------------------------------- 2. contract check
$py = Get-PythonExe
Write-Step 'Contract check against decomp/'
if (-not $py) {
    Write-Warn2 'python not found; skipping contract check'
} elseif (-not (Test-Path -LiteralPath (Join-Path $root 'decomp\scripts'))) {
    Write-Warn2 'decomp/ missing; skipping contract check'
} else {
    & $py (Join-Path $root 'tools\contract_check.py') (Join-Path $root 'decomp') (Join-Path $root 'loader\core\contract.gd')
    if ($LASTEXITCODE -ne 0) { $failures += 'contract' }
    # mod contracts (PittMultiplayer: NET, UI, and the MP2 streams BODIES, GAMEPLAY, GRAB)
    foreach ($mc in @('mods\PittMultiplayer\net\contract_net.gd', 'mods\PittMultiplayer\ui\contract_ui.gd',
            'mods\PittMultiplayer\world\bodies\contract_bodies.gd', 'mods\PittMultiplayer\gameplay\contract_gameplay.gd',
            'mods\PittMultiplayer\grab\contract_grab.gd')) {
        $mcPath = Join-Path $root $mc
        if (Test-Path -LiteralPath $mcPath) {
            & $py (Join-Path $root 'tools\contract_check.py') (Join-Path $root 'decomp') $mcPath
            if ($LASTEXITCODE -ne 0) { $failures += "contract:$mc" }
        }
    }
}

# ---------------------------------------------------------------- 3. manifests
Write-Step 'Validating mod.json files'
if ($py) {
    & $py (Join-Path $root 'tools\validate_manifests.py') (Join-Path $root 'loader\schema\mod.schema.json') (Join-Path $root 'loader') (Join-Path $root 'mods')
    if ($LASTEXITCODE -ne 0) { $failures += 'manifests' }
} else {
    Write-Warn2 'python not found; manifest schema check skipped (the headless tests still validate them)'
}

# ---------------------------------------------------------------- 4. unit tests
Write-Step 'Running headless unit tests'
$env:PITTAPI_HEADLESS_REPORT = $report
$env:PITTAPI_TEST_FILTER = $Filter
if (Test-Path -LiteralPath $report) { Remove-Item -Force -LiteralPath $report }
$log = Join-Path $dist 'headless-run.log'
& $godot --headless --path $proj 2>&1 | Tee-Object -FilePath $log | ForEach-Object {
    $line = "$_"
    if ($line -match '^\s+(PASS|FAIL) ' -or $line -match 'HEADLESS RESULT') { Write-Host $line }
}
$testCode = $LASTEXITCODE
Remove-Item Env:\PITTAPI_HEADLESS_REPORT -ErrorAction SilentlyContinue
Remove-Item Env:\PITTAPI_TEST_FILTER -ErrorAction SilentlyContinue
if (-not (Test-Path -LiteralPath $report)) {
    Write-Bad "no report written (exit $testCode); see $log"
    $failures += 'tests:no-report'
} else {
    $r = Get-Content -Raw -LiteralPath $report | ConvertFrom-Json
    if ($r.fatal) { Write-Bad "fatal: $($r.fatal)"; $failures += 'tests:fatal' }
    if ($r.summary.failed -gt 0 -or $testCode -ne 0) { $failures += "tests:$($r.summary.failed) failed" }
    Write-Ok ("unit tests: {0} passed, {1} failed (report {2})" -f $r.summary.passed, $r.summary.failed, $report)
}

Write-Host ''
if ($failures.Count -eq 0) {
    Write-Host 'HEADLESS CHECKS PASSED' -ForegroundColor Green
    exit 0
}
Write-Host ('HEADLESS CHECKS FAILED: ' + ($failures -join ', ')) -ForegroundColor Red
exit 1
