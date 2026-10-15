<#
.SYNOPSIS
  Two-instance multiplayer test over ENet localhost (MP-DESIGN 10.2).
.DESCRIPTION
  Host and client are two decomp editor instances ("<godot> --path decomp", which
  skips Steam's restartAppIfNecessary), each with its own PittAPI root
  (--pittapi-instance=host / client) inside the custom user dir PittMP-Dev.
  One Steam account cannot P2P to itself, so the transport is ENet on 127.0.0.1.
  Each instance is armed with <root>\mp_autotest.flag and runs the PittMPTests
  scenario; both write machine-readable reports (after every step):
    %APPDATA%\PittMP-Dev\pittapi-host\mp_report.json
    %APPDATA%\PittMP-Dev\pittapi-client\mp_report.json
  and this script writes the combined dist\mp-loopback-report.json.

  T0 gate (R26): aborts unless the probe's user dir ends in PittMP-Dev. The real
  save folder (%APPDATA%\Godot\app_userdata\Project P.I.T.T) is SHA-256-hashed
  before and after; any change fails the run.

  -HostLive: the HOST is the real game (steam://rungameid/4026250, installed with
  -WithMP -WithTests; only stages allowed to launch the game may use it), the
  client is the decomp instance. The real game's PittMultiplayer.cfg is backed up
  and restored; projectpitt.exe is killed afterwards.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File tools\test-mp-loopback.ps1
  powershell -ExecutionPolicy Bypass -File tools\test-mp-loopback.ps1 -Setup -Headless
  powershell -ExecutionPolicy Bypass -File tools\test-mp-loopback.ps1 -HostLive
  powershell -ExecutionPolicy Bypass -File tools\test-mp-loopback.ps1 -Suite mp2
  powershell -ExecutionPolicy Bypass -File tools\test-mp-loopback.ps1 -Suite mp2 -Scenario B1
.PARAMETER Suite
  mp1 (default): the MP1 scenario (scenario_host / scenario_client).
  mp2: the MP2 harness (PittMPTests/mp2/scenario_mp2.gd, flag role "mp2" with side
  host|client): BODIES B-scenarios, then the other streams'. all: mp1, then mp2.
.PARAMETER Clients
  mp2 only: 2 adds a third instance (side "client2", PittAPI root pittapi-client2) that joins
  after the first client (a late join into a 3-player session), checks the B-scenarios from a
  third peer and both other avatars, then runs the end checks.
.PARAMETER Scenario
  mp2 only: run one scenario id (B1, B2, ...); the join and the end checks always run.
#>
param(
    [int]$Port = 27450,
    [int]$TimeoutS = 900,
    [switch]$Setup,
    [switch]$Headless,
    [switch]$HostLive,
    [switch]$KeepOpen,
    [int]$LatencyMs = 100,
    [int]$JitterMs = 30,
    [double]$Loss = 0.05,
    [ValidateSet('mp1', 'mp2', 'all')][string]$Suite = 'mp1',
    [string]$Scenario = '',
    [ValidateSet(1, 2)][int]$Clients = 1
)
if ($Suite -eq 'all') {
    $pass = @{}
    foreach ($k in $PSBoundParameters.Keys) { if ($k -ne 'Suite') { $pass[$k] = $PSBoundParameters[$k] } }
    & $PSCommandPath @pass -Suite mp1
    $rc1 = $LASTEXITCODE
    Copy-Item -Force (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\mp-loopback-report.json') (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist\mp-loopback-report.mp1.json') -ErrorAction SilentlyContinue
    & $PSCommandPath @pass -Suite mp2
    $rc2 = $LASTEXITCODE
    if ($rc1 -eq 0 -and $rc2 -eq 0) { exit 0 }
    exit 1
}
. "$PSScriptRoot\mp-dev-setup.ps1" -FunctionsOnly
$ErrorActionPreference = 'Continue'

$root = $script:RepoRoot
$decomp = Join-Path $root 'decomp'
$devDist = Join-Path $root 'dist\mp-dev'
$consoleGodot = Get-GodotExe
$windowGodot = Join-Path (Split-Path $consoleGodot -Parent) 'Godot_v4.7.2-stable_win64.exe'
$exe = if ($Headless -or -not (Test-Path -LiteralPath $windowGodot)) { $consoleGodot } else { $windowGodot }
$devUser = Get-DevUserDir
$realUser = Get-UserDir
$runId = (Get-Date -Format 'yyyyMMdd-HHmmss')
$failures = @()

# ---------------------------------------------------------------- setup + T0
if ($Setup -or -not (Test-Path -LiteralPath (Join-Path $decomp 'override.cfg')) -or -not (Test-Path -LiteralPath (Join-Path $devDist 'mods\PittAPI\pittapi.gd'))) {
    & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'mp-dev-setup.ps1')
    if ($LASTEXITCODE -ne 0) { Write-Bad 'mp-dev-setup failed'; exit 1 }
} else {
    # always run the current sources
    & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'mp-dev-setup.ps1') -ModsOnly | Out-Null
}
Write-Step 'T0 gate: the decomp instance must use the PittMP-Dev user dir'
$probe = Invoke-MpProbe -Godot $consoleGodot -Decomp $decomp -OutDir $devDist
if (-not $probe -or -not ($probe.user_dir -replace '\\', '/').TrimEnd('/').EndsWith('PittMP-Dev')) {
    Write-Bad "user dir is '$($probe.user_dir)': aborting (never run a dev instance on the real save folder)"
    exit 1
}
Write-Ok "user dir $($probe.user_dir) (ENet $($probe.enet), Steam $($probe.steam))"
$devUser = ($probe.user_dir -replace '/', '\').TrimEnd('\')
if (-not $probe.enet) { Write-Bad 'ENetMultiplayerPeer missing in this Godot build'; exit 1 }

# ---------------------------------------------------------------- save guard (before)
Write-Step "Hashing the real save folder $realUser"
$saveBefore = Get-SaveHashes $realUser
$treeBefore = if ($HostLive) { @{} } else { Get-TreeHashes $realUser }
Write-Ok ("{0} save files, {1} files total" -f $saveBefore.Count, $treeBefore.Count)

# ---------------------------------------------------------------- per-role config + flag
function Set-Role([string]$Role, [string]$PittRoot, [string]$PeerReport, [string]$ReportPath, [string]$Peer2Report = '', [string]$JoinAfter = 'join_now') {
    New-Item -ItemType Directory -Force (Join-Path $PittRoot 'config') | Out-Null
    $cfg = @"
[general]

transport="enet"
dev_address="127.0.0.1"
dev_port=$Port
dev_targets="127.0.0.1:$Port"
dev_name="$(if ($Role -eq 'host') { 'Host' } elseif ($Role -eq 'client2') { 'Client 2' } else { 'Client' })"
achievements="none"
"@
    Write-Utf8NoBom (Join-Path $PittRoot 'config\PittMultiplayer.cfg') ($cfg -replace "`r`n", "`n")
    if (Test-Path -LiteralPath $ReportPath) { Remove-Item -Force -LiteralPath $ReportPath }
    $flagRole = if ($Suite -eq 'mp2') { 'mp2' } else { $Role }
    $flag = [ordered]@{
        role = $flagRole; side = $Role; scenario = $Scenario; join_after = $JoinAfter; peer2_report = $Peer2Report
        host_live = [bool]($HostLive -and $Role -eq 'host')
        run_id = $runId; timeout_s = $TimeoutS - 30; quit = (-not $KeepOpen)
        report = (ConvertTo-GodotPath $ReportPath); peer_report = (ConvertTo-GodotPath $PeerReport)
        address = '127.0.0.1'; port = $Port
        screens_dir = (ConvertTo-GodotPath (Join-Path $root 'dist\screens'))
        conditioning = [ordered]@{ latency_ms = $LatencyMs; jitter_ms = $JitterMs; loss = $Loss }
    }
    Write-Utf8NoBom (Join-Path $PittRoot 'mp_autotest.flag') ($flag | ConvertTo-Json -Depth 4)
}

$clientRoot = Join-Path $devUser 'pittapi-client'
$clientReport = Join-Path $clientRoot 'mp_report.json'
if ($HostLive) {
    if (Test-GameRunning) { Write-Bad 'projectpitt.exe is running; close it first'; exit 1 }
    $hostRoot = Join-Path $realUser 'pittapi'
    $cfgPath = Join-Path $hostRoot 'config\PittMultiplayer.cfg'
    $cfgBackup = $null
    if (Test-Path -LiteralPath $cfgPath) { $cfgBackup = Get-Content -Raw -LiteralPath $cfgPath }
    Write-Step 'Installing PittAPI + PittMultiplayer + PittMPTests into the game'
    & powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'install.ps1') -WithTests -WithMP | Out-Null
} else {
    $hostRoot = Join-Path $devUser 'pittapi-host'
}
$hostReport = Join-Path $hostRoot 'mp_report.json'
$client2Root = Join-Path $devUser 'pittapi-client2'
$client2Report = Join-Path $client2Root 'mp_report.json'
$three = ($Suite -eq 'mp2' -and $Clients -eq 2)
if (Test-Path -LiteralPath $client2Report) { Remove-Item -Force -LiteralPath $client2Report }
Set-Role 'host' $hostRoot $clientReport $hostReport $(if ($three) { ConvertTo-GodotPath $client2Report } else { '' })
Set-Role 'client' $clientRoot $hostReport $clientReport
if ($three) { Set-Role 'client2' $client2Root $hostReport $client2Report '' 'client1_in' }

# ---------------------------------------------------------------- launch
New-Item -ItemType Directory -Force $devDist | Out-Null
function Start-DevInstance([string]$Role, [string]$Pos) {
    $a = @('--path', "`"$decomp`"")
    if ($exe -eq $consoleGodot) { $a += '--headless' } else { $a += @('--windowed', '--resolution', '960x540', '--position', $Pos) }
    $a += @('--', "--pittapi-instance=$Role")
    $log = Join-Path $devDist "$Role.log"
    return Start-Process -FilePath $exe -ArgumentList $a -PassThru -WindowStyle Normal `
        -RedirectStandardOutput $log -RedirectStandardError (Join-Path $devDist "$Role.err.log")
}

$procs = @()
if ($HostLive) {
    Write-Step 'Launching the real game as host (steam://rungameid/4026250)'
    Start-Process "steam://rungameid/$($script:PittAppId)"
} else {
    Write-Step "Launching host ($([IO.Path]::GetFileName($exe)))"
    $procs += Start-DevInstance 'host' '0,40'
}
$t0 = Get-Date
$lobbyReady = $false
while (((Get-Date) - $t0).TotalSeconds -lt 240) {
    $h = Read-JsonFile $hostReport
    if ($h -and $h.marks -and $h.marks.lobby_ready) { $lobbyReady = $true; break }
    if ($h -and $h.finished) { break }
    Start-Sleep -Milliseconds 500
}
if (-not $lobbyReady) { Write-Bad 'host never reported lobby_ready'; $failures += 'host:lobby_ready' }
else {
    Write-Ok ("host lobby ready after {0:n0} s" -f ((Get-Date) - $t0).TotalSeconds)
    Write-Step 'Launching client'
    $procs += Start-DevInstance 'client' '970,40'
    if ($three) { Write-Step 'Launching client 2'; $procs += Start-DevInstance 'client2' '485,600' }
}

# ---------------------------------------------------------------- wait for both reports
$deadline = (Get-Date).AddSeconds($TimeoutS)
$lastLine = ''
while ((Get-Date) -lt $deadline -and $lobbyReady) {
    $h = Read-JsonFile $hostReport
    $c = Read-JsonFile $clientReport
    $c2 = if ($three) { Read-JsonFile $client2Report } else { $null }
    $line = "host: {0} pass {1} fail | client: {2} pass {3} fail" -f $h.summary.passed, $h.summary.failed, $c.summary.passed, $c.summary.failed
    if ($three) { $line += " | client2: {0} pass {1} fail" -f $c2.summary.passed, $c2.summary.failed }
    if ($line -ne $lastLine) { Write-Host "    $line"; $lastLine = $line }
    if ($h -and $h.finished -and $c -and $c.finished -and (-not $three -or ($c2 -and $c2.finished))) { break }
    $alive = @($procs | Where-Object { -not $_.HasExited })
    if (-not $HostLive -and $alive.Count -eq 0) { break }
    Start-Sleep -Seconds 1
}

# ---------------------------------------------------------------- stop
Start-Sleep -Seconds 3
foreach ($p in $procs) { if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } }
if ($HostLive) {
    Start-Sleep -Seconds 5
    Stop-Game
    if ($cfgBackup -ne $null) { Write-Utf8NoBom $cfgPath $cfgBackup } elseif (Test-Path -LiteralPath $cfgPath) { Remove-Item -Force -LiteralPath $cfgPath }
    Write-Ok 'real PittMultiplayer.cfg restored'
}

# ---------------------------------------------------------------- results
$h = Read-JsonFile $hostReport
$c = Read-JsonFile $clientReport
$c2 = if ($three) { Read-JsonFile $client2Report } else { $null }
$pairs = @(@('host', $h), @('client', $c))
if ($three) { $pairs += ,@('client2', $c2) }
foreach ($pair in $pairs) {
    $name = $pair[0]; $r = $pair[1]
    if (-not $r) { Write-Bad "$name wrote no report"; $failures += "$($name):no-report"; continue }
    if (-not $r.finished) { $failures += "$($name):unfinished" ; Write-Bad "$name did not finish" }
    if ($r.fatal) { $failures += "$($name):fatal"; Write-Bad "$name fatal: $($r.fatal)" }
    foreach ($s in $r.steps) {
        if (-not $s.ok) { Write-Bad ("{0} {1}.{2}: {3}" -f $name, $s.step, $s.name, $s.msg); $failures += "$($name):$($s.step).$($s.name)" }
        elseif ($s.info) { Write-Host ("    INFO {0} {1}.{2}: {3}" -f $name, $s.step, $s.name, $s.msg) }
    }
    Write-Ok ("{0}: {1} passed, {2} failed" -f $name, $r.summary.passed, $r.summary.failed)
}

Write-Step 'Re-hashing the real save folder'
$saveDiff = Compare-Hashes $saveBefore (Get-SaveHashes $realUser)
$treeDiff = if ($HostLive) { @() } else { Compare-Hashes $treeBefore (Get-TreeHashes $realUser) }
foreach ($d in ($saveDiff + $treeDiff)) { Write-Bad "real user dir $d"; $failures += "real-user-dir:$d" }
if (($saveDiff + $treeDiff).Count -eq 0) { Write-Ok 'real save folder unchanged' }

$combined = [ordered]@{ run_id = $runId; host_live = [bool]$HostLive; failures = $failures; host = $h; client = $c;
    real_user_dir_changes = ($saveDiff + $treeDiff) }
$combined['suite'] = $Suite
if ($three) { $combined['client2'] = $c2 }
$combined['scenario'] = $Scenario
Write-Utf8NoBom (Join-Path $root 'dist\mp-loopback-report.json') ($combined | ConvertTo-Json -Depth 12)
Write-Host ''
if ($failures.Count -eq 0) { Write-Host 'MP LOOPBACK PASSED' -ForegroundColor Green; exit 0 }
Write-Host ('MP LOOPBACK FAILED: ' + ($failures -join ', ')) -ForegroundColor Red
exit 1
