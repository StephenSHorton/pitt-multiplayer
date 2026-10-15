<#
.SYNOPSIS
  Removes PittAPI from the game folder using <game>\mods\PittAPI\.install.json.
.DESCRIPTION
  Deletes only the files that install.ps1 recorded, then restores the original
  override.cfg from its backup (or deletes override.cfg if we created it).
  -TestsOnly removes just PittAPITests and the broken fixture.
  -RemoveUserData also deletes %APPDATA%\...\Project P.I.T.T\pittapi (logs,
  status, mod configs, sidecars). Game saves are never touched.
#>
param(
    [string]$GameDir = '',
    [switch]$TestsOnly,
    [switch]$RemoveUserData
)
. "$PSScriptRoot\common.ps1"

$game = Get-GameDir $GameDir
if (Test-GameRunning) { throw "projectpitt.exe is running. Close the game first." }
$coreDir = Join-Path $game 'mods\PittAPI'
$manifestPath = Join-Path $coreDir '.install.json'
if (-not (Test-Path -LiteralPath $manifestPath)) { throw "No PittAPI install record at $manifestPath" }
$m = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json

function Remove-Listed([string[]]$rels) {
    $dirs = @{}
    foreach ($rel in $rels) {
        $p = Join-Path $game $rel
        if (Test-Path -LiteralPath $p -PathType Leaf) { Remove-Item -LiteralPath $p -Force }
        $d = Split-Path $p -Parent
        while ($d -and $d.Length -gt (Join-Path $game 'mods').Length) { $dirs[$d] = $true; $d = Split-Path $d -Parent }
    }
    # remove now-empty folders, deepest first (only folders that held our files)
    foreach ($d in ($dirs.Keys | Sort-Object Length -Descending)) {
        if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -Force -LiteralPath $d)) { Remove-Item -LiteralPath $d -Force }
    }
}

if ($TestsOnly) {
    $testFiles = @($m.files | Where-Object { $_ -like 'mods\PittAPITests\*' -or $_ -like 'mods\_PittAPIBrokenFixture\*' })
    Remove-Listed $testFiles
    $m.files = @($m.files | Where-Object { $testFiles -notcontains $_ })
    $m.with_tests = $false
    Write-Utf8NoBom $manifestPath ($m | ConvertTo-Json -Depth 4)
    Write-Ok "removed the test mods ($($testFiles.Count) files)"
    exit 0
}

Remove-Listed @($m.files)
if (Test-Path -LiteralPath $manifestPath) { Remove-Item -LiteralPath $manifestPath -Force }
if ((Test-Path -LiteralPath $coreDir) -and -not (Get-ChildItem -Force -LiteralPath $coreDir)) { Remove-Item -LiteralPath $coreDir -Force }
$modsDir = Join-Path $game 'mods'
if ((Test-Path -LiteralPath $modsDir) -and -not (Get-ChildItem -Force -LiteralPath $modsDir)) { Remove-Item -LiteralPath $modsDir -Force }
Write-Ok "removed $($m.files.Count) files"

$override = Join-Path $game 'override.cfg'
if ($m.backup_file -and (Test-Path -LiteralPath (Join-Path $game $m.backup_file))) {
    Copy-Item -LiteralPath (Join-Path $game $m.backup_file) -Destination $override -Force
    Remove-Item -LiteralPath (Join-Path $game $m.backup_file) -Force
    Write-Ok "restored override.cfg from $($m.backup_file)"
} elseif ($m.override_created) {
    if (Test-Path -LiteralPath $override) { Remove-Item -LiteralPath $override -Force }
    Write-Ok "removed override.cfg (PittAPI created it)"
} elseif (Test-Path -LiteralPath $override) {
    $lines = @(Get-Content -LiteralPath $override | Where-Object { $_ -notmatch '^\s*PittAPI\s*=' })
    Write-Utf8NoBom $override (($lines -join "`r`n") + "`r`n")
    Write-Ok "removed the PittAPI line from override.cfg"
}

if ($RemoveUserData) {
    $ud = Join-Path (Get-UserDir) 'pittapi'
    if (Test-Path -LiteralPath $ud) { Remove-Item -Recurse -Force -LiteralPath $ud; Write-Ok "removed $ud" }
}
Write-Host 'PittAPI uninstalled.' -ForegroundColor Green
