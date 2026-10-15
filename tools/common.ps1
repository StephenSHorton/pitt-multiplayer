# Shared helpers for the PittAPI scripts (Windows PowerShell 5.1 compatible).
# Dot-source it:  . "$PSScriptRoot\common.ps1"

$ErrorActionPreference = 'Stop'

$script:PittAppId = '4026250'
$script:PittBuildId = '25122572'
$script:PittExe = 'projectpitt.exe'
$script:RepoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok([string]$msg) { Write-Host "    OK  $msg" -ForegroundColor Green }
function Write-Warn2([string]$msg) { Write-Host "    WARN $msg" -ForegroundColor Yellow }
function Write-Bad([string]$msg) { Write-Host "    FAIL $msg" -ForegroundColor Red }

# Steam install dir from the registry, falling back to the default location.
function Get-SteamDir {
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam')) {
        try {
            $p = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($name in @('SteamPath', 'InstallPath')) {
                if ($p.$name -and (Test-Path -LiteralPath $p.$name)) { return ($p.$name -replace '/', '\') }
            }
        } catch {}
    }
    $default = 'C:\Program Files (x86)\Steam'
    if (Test-Path -LiteralPath $default) { return $default }
    return $null
}

# Every Steam library folder (libraryfolders.vdf).
function Get-SteamLibraries {
    $steam = Get-SteamDir
    $libs = @()
    if (-not $steam) { return $libs }
    $libs += $steam
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        foreach ($line in Get-Content -LiteralPath $vdf) {
            if ($line -match '^\s*"path"\s*"(.+)"\s*$') {
                $p = $Matches[1] -replace '\\\\', '\'
                if ((Test-Path -LiteralPath $p) -and ($libs -notcontains $p)) { $libs += $p }
            }
        }
    }
    return $libs
}

# The game folder (contains projectpitt.exe). -GameDir wins when given.
function Get-GameDir([string]$Override = '') {
    if ($Override) {
        if (-not (Test-Path -LiteralPath (Join-Path $Override $script:PittExe))) { throw "No $script:PittExe in $Override" }
        return (Resolve-Path -LiteralPath $Override).Path
    }
    foreach ($lib in Get-SteamLibraries) {
        $manifest = Join-Path $lib "steamapps\appmanifest_$script:PittAppId.acf"
        if (Test-Path -LiteralPath $manifest) {
            $installdir = 'Project P.I.T.T'
            foreach ($line in Get-Content -LiteralPath $manifest) {
                if ($line -match '^\s*"installdir"\s*"(.+)"\s*$') { $installdir = $Matches[1] }
            }
            $dir = Join-Path $lib "steamapps\common\$installdir"
            if (Test-Path -LiteralPath (Join-Path $dir $script:PittExe)) { return $dir }
        }
    }
    $fallback = 'C:\Program Files (x86)\Steam\steamapps\common\Project P.I.T.T'
    if (Test-Path -LiteralPath (Join-Path $fallback $script:PittExe)) { return $fallback }
    throw "Could not find Project P.I.T.T. Pass -GameDir."
}

# Installed buildid from appmanifest_4026250.acf, or $null.
function Get-GameBuildId([string]$GameDir) {
    $steamapps = Split-Path (Split-Path $GameDir -Parent) -Parent
    $manifest = Join-Path $steamapps "appmanifest_$script:PittAppId.acf"
    if (-not (Test-Path -LiteralPath $manifest)) { return $null }
    foreach ($line in Get-Content -LiteralPath $manifest) {
        if ($line -match '^\s*"buildid"\s*"(\d+)"\s*$') { return $Matches[1] }
    }
    return $null
}

# The game's user:// folder (saves live here; Steam Auto-Cloud syncs it).
function Get-UserDir {
    return (Join-Path $env:APPDATA 'Godot\app_userdata\Project P.I.T.T')
}

function Test-GameRunning {
    return [bool](Get-Process -Name ($script:PittExe -replace '\.exe$', '') -ErrorAction SilentlyContinue)
}

function Stop-Game {
    Get-Process -Name ($script:PittExe -replace '\.exe$', '') -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

# SHA-256 of every save-like file in user:// (savegame*, sandbox.save*, profile.cfg).
function Get-SaveHashes([string]$UserDir) {
    $h = @{}
    if (-not (Test-Path -LiteralPath $UserDir)) { return $h }
    Get-ChildItem -LiteralPath $UserDir -File | Where-Object {
        $_.Name -like 'savegame*' -or $_.Name -like 'sandbox.save*' -or $_.Name -eq 'profile.cfg'
    } | ForEach-Object {
        $h[$_.Name] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
    return $h
}

function Get-GodotExe {
    if ($env:PITTAPI_GODOT -and (Test-Path -LiteralPath $env:PITTAPI_GODOT)) { return $env:PITTAPI_GODOT }
    $p = Join-Path $script:RepoRoot '.tools\godot\Godot_v4.7.2-stable_win64_console.exe'
    if (Test-Path -LiteralPath $p) { return $p }
    throw "Godot 4.7.2 console exe not found (set PITTAPI_GODOT)"
}

function Get-PythonExe {
    foreach ($c in @('python', 'py', 'python3')) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

# Writes UTF-8 without BOM (Godot's ConfigFile and override.cfg parser want plain UTF-8).
function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function ConvertTo-GodotPath([string]$p) { return ($p -replace '\\', '/') }

# Starts the installed game. Directly with SteamAppId / SteamGameId set (Steam must be
# running): restartAppIfNecessary then returns false, so no Steam launch-option dialog
# can hold the start; falls back to steam://rungameid when the exe is not found.
function Start-Game([string]$GameDir = '') {
    try { $dir = Get-GameDir $GameDir } catch { $dir = $null }
    if ($dir) {
        $env:SteamAppId = $script:PittAppId
        $env:SteamGameId = $script:PittAppId
        Start-Process -FilePath (Join-Path $dir $script:PittExe) -WorkingDirectory $dir | Out-Null
        return
    }
    Start-Process "steam://rungameid/$($script:PittAppId)"
}
