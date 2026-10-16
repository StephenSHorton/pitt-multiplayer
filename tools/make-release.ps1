<#
.SYNOPSIS
  Builds the player release zip: dist\PittMultiplayer-<version>.zip
.DESCRIPTION
  Contains PittAPI (loader\), the PittMultiplayer mod, the installer/uninstaller and
  double-click Install.bat / Uninstall.bat. No test mods, no ExampleMod, no game files.
  Keeps the repo layout so tools\install.ps1 works unchanged from the unzipped folder.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\make-release.ps1
#>
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$mp = Get-Content -Raw -LiteralPath (Join-Path $root 'mods\PittMultiplayer\mod.json') | ConvertFrom-Json
$api = Get-Content -Raw -LiteralPath (Join-Path $root 'loader\mod.json') | ConvertFrom-Json
$name = "PittMultiplayer-$($mp.version)"
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist "release\$name"
$zip = Join-Path $dist "$name.zip"

if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'mods'), (Join-Path $stage 'tools') | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'loader') -Destination (Join-Path $stage 'loader') -Recurse
Copy-Item -LiteralPath (Join-Path $root 'mods\PittMultiplayer') -Destination (Join-Path $stage 'mods\PittMultiplayer') -Recurse
foreach ($f in 'install.ps1', 'uninstall.ps1', 'common.ps1') {
    Copy-Item -LiteralPath (Join-Path $root "tools\$f") -Destination (Join-Path $stage "tools\$f")
}

$bat = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\{0}" {1}
echo.
pause
'@
Set-Content -LiteralPath (Join-Path $stage 'Install.bat') -Value ($bat -f 'install.ps1', '-WithMP -NoExampleMod') -Encoding ASCII
Set-Content -LiteralPath (Join-Path $stage 'Uninstall.bat') -Value ($bat -f 'uninstall.ps1', '') -Encoding ASCII

$readme = @"
PITT MULTIPLAYER $($mp.version)   (PittAPI $($api.version))
Steam co-op mod for Project P.I.T.T. v1.0.8

INSTALL
  1. Close Project P.I.T.T.
  2. Unzip this folder anywhere (e.g. your Desktop).
  3. Double-click Install.bat. It finds the game through Steam.
     (If Windows SmartScreen asks, choose "More info" > "Run anyway".)
  4. Start the game from Steam as usual. A "Multiplayer" button appears under Play.

PLAY TOGETHER
  - Host: Multiplayer > Host > wait for friends > Start.
  - Join: Multiplayer > Join > pick your friend's lobby.
    Or accept their Steam invite / click "Join Game" on them in your friends list.
  - Lobbies are friends-only, up to 10 players. You can join a game already in progress.
  - Everyone needs this SAME version of the mod. Mismatched lobbies show as disabled.

UNINSTALL
  Double-click Uninstall.bat. It removes only what Install.bat added.

NOTES
  - The mod never changes the game's files or your saves. Saves stay with the host.
  - Steam "Verify integrity of game files" leaves the mod alone.
  - Logs if something goes wrong:
    %APPDATA%\Godot\app_userdata\Project P.I.T.T\pittapi\pittapi.log
"@
Set-Content -LiteralPath (Join-Path $stage 'README.txt') -Value $readme -Encoding UTF8

if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
# Compress-Archive on Windows PowerShell 5.1 writes backslash entry names; write '/' (zip spec).
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$root = Split-Path -Parent $stage
$archive = [System.IO.Compression.ZipFile]::Open($zip, 'Create')
try {
  foreach ($f in Get-ChildItem -LiteralPath $stage -Recurse -File) {
    $entry = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $entry)
  }
} finally { $archive.Dispose() }
$count = (Get-ChildItem -LiteralPath $stage -Recurse -File).Count
Write-Host ("Built {0} ({1} files, {2:N0} KB)" -f $zip, $count, ((Get-Item -LiteralPath $zip).Length / 1KB))
