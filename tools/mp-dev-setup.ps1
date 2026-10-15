<#
.SYNOPSIS
  One-time setup of the decomp editor instance for two-instance multiplayer tests.
.DESCRIPTION
  - builds dist\mp-dev\mods\ (loader -> PittAPI, PittMultiplayer, PittMPTests)
  - writes decomp\override.cfg (decomp is gitignored): a custom user dir
    "PittMP-Dev" (so the dev instances NEVER touch the real save folder) and
    the PittAPI autoload from dist\mp-dev
  - imports the decomp project once (--headless --import, can take minutes)
  - T0 gate: a probe run must report a user dir ending in PittMP-Dev, else abort
  Steam: the Steamworks autoload skips restartAppIfNecessary under the editor
  feature, so the decomp instance starts without the Steam client relaunching it.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\mp-dev-setup.ps1
  powershell -ExecutionPolicy Bypass -File tools\mp-dev-setup.ps1 -SkipImport
  . "$PSScriptRoot\mp-dev-setup.ps1" -FunctionsOnly   # (test-mp-loopback.ps1: helpers only)
#>
param(
    [switch]$SkipImport,
    [switch]$ModsOnly,
    [switch]$FunctionsOnly
)
. "$PSScriptRoot\common.ps1"
$ErrorActionPreference = 'Continue'

# ================================================================ helpers (also used by test-mp-loopback.ps1)

# T0 probe: runs a tiny SceneTree script in the decomp project and returns
# {user_dir, enet, steam, smp, editor} (or $null). Nothing is written to user://.
function Invoke-MpProbe([string]$Godot, [string]$Decomp, [string]$OutDir) {
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    $probe = Join-Path $OutDir 'mp_probe.gd'
    $src = @'
extends SceneTree
func _init() -> void:
	var d := {"user_dir": OS.get_user_data_dir(), "enet": ClassDB.class_exists("ENetMultiplayerPeer"),
		"steam": Engine.has_singleton("Steam"), "smp": ClassDB.class_exists("SteamMultiplayerPeer"),
		"editor": OS.has_feature("editor")}
	print("PITTMP_PROBE " + JSON.stringify(d))
	quit(0)
'@
    Write-Utf8NoBom $probe ($src -replace "`r`n", "`n")
    $out = & $Godot --headless --path $Decomp -s (ConvertTo-GodotPath $probe) 2>&1 | Out-String
    $line = ($out -split "`n" | Where-Object { $_ -match 'PITTMP_PROBE ' } | Select-Object -First 1)
    if (-not $line) { return $null }
    return (($line -replace '^.*PITTMP_PROBE ', '').Trim() | ConvertFrom-Json)
}

# Godot puts a custom user dir directly under %APPDATA% (verified by the T0 probe).
function Get-DevUserDir { return (Join-Path $env:APPDATA 'PittMP-Dev') }

# SHA-256 of every file under a folder (relative path -> hash).
function Get-TreeHashes([string]$Dir, [string[]]$ExcludeDirs = @()) {
    $h = @{}
    if (-not (Test-Path -LiteralPath $Dir)) { return $h }
    Get-ChildItem -LiteralPath $Dir -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($Dir.Length).TrimStart('\')
        $skip = $false
        foreach ($x in $ExcludeDirs) { if ($rel -like "$x\*") { $skip = $true } }
        if (-not $skip) {
            try { $h[$rel] = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } catch { $h[$rel] = 'locked' }
        }
    }
    return $h
}

function Compare-Hashes($Before, $After) {
    $diff = @()
    foreach ($k in $Before.Keys) { if (-not $After.ContainsKey($k)) { $diff += "deleted: $k" } elseif ($After[$k] -ne $Before[$k]) { $diff += "changed: $k" } }
    foreach ($k in $After.Keys) { if (-not $Before.ContainsKey($k)) { $diff += "created: $k" } }
    return $diff
}

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json) } catch { return $null }
}

if ($FunctionsOnly) { return }
# ================================================================ setup

$root = $script:RepoRoot
$decomp = Join-Path $root 'decomp'
if (-not (Test-Path -LiteralPath (Join-Path $decomp 'project.godot'))) { throw "decomp\project.godot not found (decompile the game first)" }
$godot = Get-GodotExe
$devDist = Join-Path $root 'dist\mp-dev'
$devMods = Join-Path $devDist 'mods'

function Build-DevMods {
    Write-Step "Building $devMods"
    if (Test-Path -LiteralPath $devMods) { Remove-Item -Recurse -Force -LiteralPath $devMods }
    New-Item -ItemType Directory -Force $devMods | Out-Null
    Copy-Item -Recurse -Force (Join-Path $root 'loader') (Join-Path $devMods 'PittAPI')
    foreach ($m in @('PittMultiplayer', 'PittMPTests')) {
        Copy-Item -Recurse -Force (Join-Path $root "mods\$m") (Join-Path $devMods $m)
    }
    # keep Godot from importing the copies as part of some project
    Write-Utf8NoBom (Join-Path $devDist '.gdignore') ''
    Write-Ok "PittAPI, PittMultiplayer, PittMPTests"
}

Build-DevMods
if ($ModsOnly) { exit 0 }

# ---------------------------------------------------------------- override.cfg
$override = Join-Path $decomp 'override.cfg'
$marker = '; PittMP dev instance (tools/mp-dev-setup.ps1)'
if ((Test-Path -LiteralPath $override) -and -not ((Get-Content -Raw -LiteralPath $override) -like "*$marker*")) {
    $bak = "$override.backup-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $override -Destination $bak
    Write-Warn2 "existing decomp\override.cfg backed up to $bak"
}
$autoload = ConvertTo-GodotPath (Join-Path $devMods 'PittAPI\pittapi.gd')
$cfg = @"
$marker
; decomp/ is gitignored. The custom user dir keeps both dev instances away from
; %APPDATA%\Godot\app_userdata\Project P.I.T.T (the real saves).
[application]

config/use_custom_user_dir=true
config/custom_user_dir_name="PittMP-Dev"

[autoload]

PittAPI="*$autoload"
"@
Write-Utf8NoBom $override ($cfg -replace "`r`n", "`n")
Write-Ok "wrote $override"

# ---------------------------------------------------------------- import
if (-not $SkipImport) {
    Write-Step 'Importing the decomp project (headless, can take minutes)'
    $t0 = Get-Date
    & $godot --headless --path $decomp --import 2>&1 | Out-File -Encoding utf8 (Join-Path $devDist 'import.log')
    Write-Ok ("import finished in {0:n0} s (log dist\mp-dev\import.log)" -f ((Get-Date) - $t0).TotalSeconds)
}

# ---------------------------------------------------------------- T0 probe
$probe = Invoke-MpProbe -Godot $godot -Decomp $decomp -OutDir $devDist
if (-not $probe) { Write-Bad 'probe produced no output'; exit 1 }
Write-Ok ("probe: user dir {0}, ENet {1}, Steam singleton {2}, SteamMultiplayerPeer {3}" -f $probe.user_dir, $probe.enet, $probe.steam, $probe.smp)
if (-not ($probe.user_dir -replace '\\', '/').TrimEnd('/').EndsWith('PittMP-Dev')) {
    Write-Bad "T0 gate: the decomp instance's user dir is $($probe.user_dir), not ...\PittMP-Dev. Aborting."
    exit 1
}
Write-Host ''
Write-Host 'mp-dev setup done. Run: powershell -ExecutionPolicy Bypass -File tools\test-mp-loopback.ps1' -ForegroundColor Green
exit 0
