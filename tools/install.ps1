<#
.SYNOPSIS
  Installs PittAPI (and ExampleMod) into the Project P.I.T.T game folder.
.DESCRIPTION
  - copies loader\ to <game>\mods\PittAPI and mods\ExampleMod to <game>\mods\ExampleMod
    (-WithTests also copies PittAPITests and the deliberately broken fixture;
     -WithMP copies PittMultiplayer, and with -WithTests also PittMPTests)
  - backs up any existing override.cfg to override.cfg.pittapi-backup-<timestamp>
    and merges our [autoload] line into it (other sections and keys are kept)
  - records everything in <game>\mods\PittAPI\.install.json so uninstall.ps1 can undo it
  Never touches the .pck, the game's scripts, or anything in %APPDATA% (saves).
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\install.ps1
  powershell -ExecutionPolicy Bypass -File tools\install.ps1 -WithTests
  powershell -ExecutionPolicy Bypass -File tools\install.ps1 -WithMP
#>
param(
    [string]$GameDir = '',
    [switch]$WithTests,
    [switch]$WithMP,
    [switch]$NoExampleMod
)
. "$PSScriptRoot\common.ps1"

$root = $script:RepoRoot
$game = Get-GameDir $GameDir
Write-Step "Game folder: $game"
if (Test-GameRunning) { throw "projectpitt.exe is running. Close the game first." }

$buildid = Get-GameBuildId $game
if ($buildid -and $buildid -ne $script:PittBuildId) {
    Write-Warn2 "game buildid is $buildid; PittAPI was built against $($script:PittBuildId). Installing anyway; the contract check will disable anything that changed."
}

$mods = Join-Path $game 'mods'
$coreDir = Join-Path $mods 'PittAPI'
$manifestPath = Join-Path $coreDir '.install.json'
$override = Join-Path $game 'override.cfg'

# previous install: remove its files first (keeps the original override.cfg backup info)
$prev = $null
if (Test-Path -LiteralPath $manifestPath) {
    $prev = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    Write-Step "Updating an existing install from $($prev.installed_at)"
    foreach ($rel in $prev.files) {
        $p = Join-Path $game $rel
        if (Test-Path -LiteralPath $p -PathType Leaf) { Remove-Item -LiteralPath $p -Force }
    }
    # and the folders that are empty now (e.g. the test mods after -WithTests -> -WithMP)
    $dirs = @($prev.files | ForEach-Object { Split-Path (Join-Path $game $_) -Parent } | Sort-Object -Unique | Sort-Object Length -Descending)
    foreach ($d in $dirs) {
        while ($d -and $d.Length -gt $mods.Length -and (Test-Path -LiteralPath $d -PathType Container) -and
                -not (Get-ChildItem -Force -LiteralPath $d | Select-Object -First 1)) {
            Remove-Item -LiteralPath $d -Force
            $d = Split-Path $d -Parent
        }
    }
}

# ---------------------------------------------------------------- copy files
$sources = @(@{ src = (Join-Path $root 'loader'); dst = 'mods\PittAPI' })
if (-not $NoExampleMod) { $sources += @{ src = (Join-Path $root 'mods\ExampleMod'); dst = 'mods\ExampleMod' } }
if ($WithTests) {
    $sources += @{ src = (Join-Path $root 'mods\PittAPITests'); dst = 'mods\PittAPITests' }
    $sources += @{ src = (Join-Path $root 'mods\_PittAPIBrokenFixture'); dst = 'mods\_PittAPIBrokenFixture' }
}
if ($WithMP) {
    $sources += @{ src = (Join-Path $root 'mods\PittMultiplayer'); dst = 'mods\PittMultiplayer' }
    if ($WithTests) { $sources += @{ src = (Join-Path $root 'mods\PittMPTests'); dst = 'mods\PittMPTests' } }
}
$files = @()
foreach ($s in $sources) {
    $srcRoot = (Resolve-Path -LiteralPath $s.src).Path
    foreach ($f in Get-ChildItem -Recurse -File -LiteralPath $srcRoot) {
        if ($f.Name -like '*.uid' -or $f.Name -eq '.install.json') { continue }
        $rel = Join-Path $s.dst $f.FullName.Substring($srcRoot.Length + 1)
        $dst = Join-Path $game $rel
        New-Item -ItemType Directory -Force (Split-Path $dst -Parent) | Out-Null
        Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
        $files += $rel
    }
    Write-Ok "$($s.dst)"
}

# ---------------------------------------------------------------- override.cfg
$entryPath = ConvertTo-GodotPath (Join-Path $coreDir 'pittapi.gd')
$ourLine = "PittAPI=`"*$entryPath`""
$backup = $null
$created = $false
if ($prev) {
    $backup = $prev.backup_file
    $created = [bool]$prev.override_created
}
if (Test-Path -LiteralPath $override) {
    $text = Get-Content -Raw -LiteralPath $override
    if (-not $prev) {
        $backup = "override.cfg.pittapi-backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $override -Destination (Join-Path $game $backup)
        Write-Ok "backed up the existing override.cfg to $backup"
    }
    $lines = [System.Collections.ArrayList]@($text -split "`r?`n")
    # drop any old PittAPI line
    for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match '^\s*PittAPI\s*=') { $lines.RemoveAt($i) } }
    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*\[autoload\]\s*$') { $idx = $i; break } }
    if ($idx -ge 0) { $lines.Insert($idx + 1, $ourLine) }
    else {
        while ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }
        if ($lines.Count -gt 0) { [void]$lines.Add('') }
        [void]$lines.Add('[autoload]'); [void]$lines.Add($ourLine)
    }
    Write-Utf8NoBom $override (($lines -join "`r`n").TrimEnd() + "`r`n")
    Write-Ok "merged the PittAPI autoload into override.cfg"
} else {
    Write-Utf8NoBom $override ("[autoload]`r`n" + $ourLine + "`r`n")
    $created = $true
    Write-Ok "wrote override.cfg"
}

# ---------------------------------------------------------------- record
$manifest = [ordered]@{
    installed_at = (Get-Date).ToString('s')
    pittapi_version = ((Get-Content -Raw -LiteralPath (Join-Path $root 'loader\mod.json') | ConvertFrom-Json).version)
    game_buildid = $buildid
    game_dir = $game
    override_created = $created
    backup_file = $backup
    with_tests = [bool]$WithTests
    with_mp = [bool]$WithMP
    files = $files
}
Write-Utf8NoBom $manifestPath ($manifest | ConvertTo-Json -Depth 4)
Write-Ok "install record: $manifestPath ($($files.Count) files)"
Write-Host ''
Write-Host "PittAPI installed. Start the game through Steam; status: %APPDATA%\Godot\app_userdata\Project P.I.T.T\pittapi\status.json" -ForegroundColor Green
