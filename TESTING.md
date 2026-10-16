# Testing PittAPI

`decomp/` below means your own local GDRE Tools recovery of the installed game. It is gitignored and not
part of this repo (see the README).

| When | Command | Needs |
|---|---|---|
| Every change | `powershell -ExecutionPolicy Bypass -File tools\test-headless.ps1` | Godot 4.7.2 console exe in `.tools\godot\` (or `PITTAPI_GODOT`), Python for steps 2-3 |
| Before a release / after a game update | `powershell -ExecutionPolicy Bypass -File tools\test-live.ps1 -Suites boot,menu,gameplay` | the game installed, Steam running, the game closed |
| After re-decompiling a new game build | `python tools\contract_check.py decomp loader\core\contract.gd mods\PittMultiplayer\net\contract_net.gd mods\PittMultiplayer\ui\contract_ui.gd` (`-v` lists every member) | `decomp/` |
| Multiplayer, two instances on one PC | `powershell -ExecutionPolicy Bypass -File tools\test-mp-loopback.ps1` (first time: `tools\mp-dev-setup.ps1`) | `decomp/`, Godot 4.7.2 (both exes) in `.tools\godot\`, Steam running |
| Multiplayer UI in the real game + a real Steam lobby | `powershell -ExecutionPolicy Bypass -File tools\test-mp-ui-live.ps1` (launches the game; screens in `dist\screens\live-*.png`, report `dist\mp-ui-live-report.json`) | the game installed, Steam running, the game closed |
| Multiplayer over real Steam | [`docs/mp/MANUAL-STEAM-TEST.md`](docs/mp/MANUAL-STEAM-TEST.md) | two PCs, two Steam accounts that are friends |

## Headless (`tools/test-headless.ps1`)

No game needed. About a minute, most of it the per-file parse check.

1. **Build** `dist/headless-project/` (gitignored): `tests/headless/*` becomes `res://tests/`, the stubs
   become `res://scripts/hud.gd` (a stand-in so ExampleMod's extension compiles) and
   `res://scenes_fake/thing.gd`, and `loader/` + `mods/*` are copied to `gamedir/mods/` (with a
   `.gdignore`). `project.godot` is generated from `tests/headless/project.godot.template`: our fakes are
   registered under the real autoload names, then `PittAPI` is loaded from its absolute path, the same way
   `override.cfg` loads it in the game. The test project's `user://` is
   `%APPDATA%\Godot\app_userdata\PittAPIHeadless` (wiped each run; the game's folder is never used).
2. **Parse check:** `--check-only` on every `.gd` file. `_PittAPIBrokenFixture/main.gd` must fail.
3. **Contract check:** `tools/contract_check.py` finds every contract member in `decomp/` (resolving
   `uid://` autoloads and `extends "res://..."` chains), for the core contract and the PittMultiplayer
   contracts (`net/contract_net.gd`, `ui/contract_ui.gd`, including `GREPS` literals such as the crate
   price steps). Skipped with a warning without `decomp/`.
4. **Manifests:** `tools/validate_manifests.py` against `loader/schema/mod.schema.json` (uses
   `jsonschema` when installed, otherwise a built-in check).
5. **Unit tests:** `tests/headless/run_tests.gd` runs every `tests/headless/suites/test_*.gd`, writes
   `dist/headless-report.json` and exits 0/1. A final `global.no_unexpected_core_errors` check fails the
   run if any engine error was attributed to PittAPI other than the deliberate ones raised by test code.

Options: `-Filter money` (only suites whose file name contains it), `-SkipParse`, `-KeepUserDir`.

Game-script stand-ins: `tests/headless/stubs/scripts/*` and every `tests/headless/fakes/mp_*/stubs/scripts/*`
are copied to `res://scripts/` so script extensions (ExampleMod's `hud.gd`, PittMultiplayer's
`upgradeUI.gd` / `hole.gd` / `pause_menu.gd` / `main_menu.gd`) compile headless.

The fakes (`tests/headless/fakes/`) are our own small stand-ins, including a `class_name BigInt` with the
game's method names; no game code is copied.

| Suite | Covers |
|---|---|
| `test_aa_live_suites` | runs the in-game boot + menu suites against the fakes (only real-game-only checks may fail) |
| `test_boot` | boot, mod states, status.json, log, contract (fakes satisfy it), toast layer, console, net stub, snapshot |
| `test_semver`, `test_manifest`, `test_resolution` | ranges; manifest validation; dependencies, version mismatch, missing deps and propagation, cycles, load-order ties, optional deps |
| `test_isolation` | parse error -> FAILED while others load; `_mod_init` error -> QUARANTINED; a throwing handler keeps being called until the threshold, then is quarantined (subscriptions, commands, console commands removed, node disabled, `mods.cfg` updated); attribution by file path |
| `test_extensions` | two mods chain on one script; autoload targets refused with `ERR_UNAVAILABLE`; `class_name` / non-path extends refused; ExampleMod's extension applied at boot |
| `test_events` | priority/order, wildcards, `off`, `once`, `last`, JSON-safe conversion, mod namespace + payload rejection, handler errors don't stop others, `wait` with timeout |
| `test_commands` | schema validation, handler failure, cheat gating, local sync completion, mod namespaces, **FakeRemoteAuthority** (completes one frame later after a JSON round trip: `done == false` on return, `completed`, `execute_async`, `wait()`), core command list, achievements suppression, phase/unlock/milestone, save isolation re-asserted every frame |
| `test_entities` | static ids deterministic (value checked against an independent djb2), API spawn/despawn + events, reconciler picks up game-side spawns and gives a reused pool node a new id, exhausted pool, tracking |
| `test_money` | delta/sign/reason, spend fails instead of flooring, amounts above int64, golden-statue bypass (`stat_changed("money")`), silent writes caught by the poll, `item.buy` + `item.level_changed`, auto-machine bug avoided, bank |
| `test_config`, `test_input`, `test_saves`, `test_log`, `test_serial`, `test_contract`, `test_facades` | per-mod config (validation, debounce, persistence); keybinds survive `apply_bindings`, conflicts, persistence, never touching `keybindings.cfg`, `input.action`; sidecar written atomically on a `_last_save_tick` change and read back on `save_loaded`, SafeFS refuses save files, read-only slot infos; log rotation and format; codecs; contract gating; console panel, HUD panels, player/state reads, orphan sidecars |
| `test_world` | a simulated World (player, camera, ExampleMod-extended HUD stub, BottomMaw): `world.ready`, `player.ready`, teleport/impulse, movement lock, `player.held_changed`, `product.sold` with entity id, banner/floating text, the extension hook, `phase.set` in world, static fixture ids, `world.exited` clears entities |

## Multiplayer (PittMultiplayer)

### Headless NET suites (`test_mp_net_*`, part of `test-headless.ps1`)

The protocol runs host + 1-3 clients **in one process** over `net/transport_loopback.gd` (deterministic
latency, jitter, loss, duplicate, reorder, stall). Each peer has its own `FakeApi` (a real loader
`Commands` registry, so `MpAuthority`, scope "local" and `dispatch_remote` are the production code),
`StubLobby` and `FakeGameAdapter`. The fake adapter **extends the real `game/game_adapter.gd`** and only
swaps where the game lives (per-peer fake autoloads and world nodes), so the adapter's mirror, post-hooks,
stat counters, unlock detach and snapshot collectors are exercised too. Helpers: `fakes/mp_net/mp_rig.gd`.

| Suite | Covers (risk ids from MP-DESIGN 13) |
|---|---|
| `test_mp_net_scope` | real core: L1 scope "local" (builtins never reach the host, R18; remote refusal), L2 provider gate, only one provider, install/uninstall restores LocalAuthority, session/peer fan-out, L3 `source:"net"` tagging and `money.changed.reason == "net"`, L4 `contract_check`, L5 isolate prefix follows the user root, L6 remote player ids; H-SP1 (PittMultiplayer loads inert) |
| `test_mp_net_codec` | JSON / zstd / avatar / chunk frames, caps, validator drops (stale sid, old seq, kind whitelist: R21/R22), rate limits, raw ENet packets polled without SceneMultiplayer (S1), loopback conditioning |
| `test_mp_net_session` | start + late join (one path), phase 0 and STARTING wait (R40), TRANSITION deferred (R4/R7), ENDING refused, version / mods / full rejects, client leave, host leave, host world exit ends the session (D7), lobby owner change = host left (R8), connection lost, abort during LOADING deferred (R23), idempotent teardown, cancel start |
| `test_mp_net_authority` | transport sender used and forged origin ignored, local scope stays local, remote cheats refused (R19), timeout and session end -> `ERR_UNAVAILABLE` (R42), state flushed before the result under jitter (R20) |
| `test_mp_net_econ` | money above int64 mirrored exactly (R9), post-hooks (remote tier, auto bench), MP2: client-local money writes reverted (money clamp) and counted, random interleavings with 2 clients and purchases converge, full econ heals drift |
| `test_mp_net_progression` | unlock replay once / unknown skipped, the client UnlockManager never judges, detach / restore, phase forward-only and phase 5, hole mirrored, `hole_ext` keeps the vanilla feeding path and blocks client completion |
| `test_mp_net_purchase` | rewire, fail closed (R12), recall local, double press sends once, host re-validation incl. `enabled_levels` (R11), no auto bench before the price check, crate escalation, tool/toy only in the buyer's world, pool-full local refusal |
| `test_mp_net_snapshot` | snapshot keys and strip table, shared builds, sha256 tamper check, non-slot session path (R14), client steps in order, encrypted session file deleted at the end |
| `test_mp_net_guards` | pause guard (same physics frame) + local freeze, InputMap erase / re-erase / restore (R15/R16), `pause_menu_ext`, puppets without groups / bodies / `PlayerController` name (R1), avatars both ways, relay, interpolation, time_scale 0 (R5), loss |
| `test_mp_net_achievements` | presence baseline grants nothing on join, a crossing fires once, `none`, cheat broadcast (R17), cache restored |
| `test_mp_net_two_process` | a second headless Godot (`--pittapi-instance=peer2`) over real ENet: mods mismatch rejected, snapshot join, command round trip, econ, avatars both ways, host leave |
| `test_mp_net_steam_lanes` | under the GodotSteam 4.19.1 lane limit every logical channel (0-3) still arrives as itself both ways (channel 3 shares lane 1 with a one-byte tag); bad tags refused |
| `test_mp_net_contract` | interface contract 5.4 for `net/session.gd` **and** the UI stream's `fakes/mp_ui/fake_session.gd`; composition in `main.gd` |

### Two-instance ENet loopback (`tools/test-mp-loopback.ps1`)

Two decomp editor instances on one PC (one Steam account cannot P2P to itself, so ENet on 127.0.0.1).

1. `tools\mp-dev-setup.ps1` (once, or `-Setup`): builds `dist\mp-dev\mods` (PittAPI, PittMultiplayer,
   PittMPTests), writes `decomp\override.cfg` (custom user dir **PittMP-Dev** = `%APPDATA%\PittMP-Dev`,
   PittAPI autoload), imports the project, and runs the T0 probe.
2. **T0 gate (R26):** the probe's user dir must end in `PittMP-Dev`, otherwise the run aborts. The real
   `%APPDATA%\Godot\app_userdata\Project P.I.T.T` is SHA-256-hashed before and after; any change fails.
3. Per instance (`--pittapi-instance=host` / `client`, PittAPI root `PittMP-Dev\pittapi-<role>`): writes
   `config\PittMultiplayer.cfg` (`transport="enet"`, port) and `mp_autotest.flag`; PittMPTests runs the
   scenario and writes `mp_report.json` after every step. The instances synchronise through each other's
   report marks.
4. Scenario: host isolated new game at phase 1 and dev lobby; client joins -> snapshot -> in_game within
   180 s with equal money and phase; avatars both ways, a 10 m host teleport seen within 300 ms; host
   `money.add` exact on the client; client income and feeding reach the host once; client buys an upgrade
   (and a tool, spawned only in its world) through the rewired terminal; host `phase.set 2` -> both settle;
   `unlock.force` replicated; client pause menu: tree never paused, host puppet keeps moving; client leaves
   and rejoins at phase 2; conditioned link (100 ms +- 30, 5 % loss: `-LatencyMs -JitterMs -Loss`); host
   leaves -> client on the main menu with `host_left`, isolation off, session file deleted.
5. Output: `dist\mp-loopback-report.json` (both reports + failures), instance logs in `dist\mp-dev\`.

Options: `-Headless` (console exe, no windows), `-KeepOpen`, `-TimeoutS`, `-Port`. `-HostLive`: the host is
the real game (`install.ps1 -WithTests -WithMP`; only stages allowed to launch the game), the client the
decomp instance; the real `PittMultiplayer.cfg` is restored and `projectpitt.exe` is killed afterwards.
`-ClientLive`: the reverse, the shipped release build is the CLIENT and the decomp instance the host (the
real game starts first: while a decomp instance runs, Steam treats app 4026250 as running). The live
scripts start `projectpitt.exe` directly with `SteamAppId`/`SteamGameId` set (Steam must be running), so
the game's `restartAppIfNecessary` does not go through Steam's launch-option dialog.
`-SteamLanes 4`: every ENet transport emulates the bundled GodotSteam 4.19.1 lane limit (a channel
>= `max_channels - 1` is sent on lane 0), the bug of the first two-PC Steam test (0.2.0: channel 3 was
dropped, so clients saw no new spawns and none of their interactions reached the host). `-Suite mp1` (default) runs this MP1 scenario, `-Suite mp2` the MP2 harness below,
`-Suite all` both (two runs; the MP1 report is kept as `dist\mp-loopback-report.mp1.json`).
A `Parse Error` / `Compile Error` in an instance log of the run fails it (a scenario file that does not
compile is otherwise skipped silently by its caller).

### MP2 shared world: headless BODIES suites (`test_mp2_bodies_*`)

`tests/headless/fakes/mp2_bodies/mp2_rig.gd` extends the NET rig: every peer gets its **own physics world**
(a SubViewport with its own World3D, so host and client bodies never touch), a fake ObjectPoolManager with
the real `_activate`/`_deactivate` effects, a **real loader entity registry** (L7-L9 production code, driven
every physics frame by `peer_driver.gd`), the real BODIES module and BODIES' doubles of GAMEPLAY
(`fake_gameplay.gd`: a meta adapter + a mirror field) and GRAB (`fake_grab.gd`: the 10.3 surface,
`set_owner_view` like GRAB). The rig suites end with `test_zz_no_script_errors` (a script error aborts a
test silently and would look like a pass).

| Suite | Covers (MP2-DESIGN) |
|---|---|
| `test_mp2_bodies_codec` | frames 4 / 5 round trip, quantisation (position <= 0.5 mm, rotation mean <= 0.1 deg / worst <= 0.25 deg), NaN / overrun / range / size rejection, <= 1200 B packing, ch3 whitelist and per-channel sequence, rate classes, held-frame limit (2.3-2.5) |
| `test_mp2_bodies_interp` | Hermite on a parabola, linear + slerp, extrapolation cap 250 ms, SNAP never interpolated, SLEEP exact, ring order, delay formula (3.4) |
| `test_mp2_bodies_priority` | weights, byte-budget selection, no starvation at 200 bodies, adaptive budget x0.7 / +10 % / floor (3.3) |
| `test_mp2_bodies_meta` | every save-schema field read, applied with the game setters, never `apply_loaded_bag/queue`, diff, adapter registry (3.5) |
| `test_mp2_bodies_entities` | L7 adopt / release (+ refusals), L8 same-frame reuse -> new id vs the cannon's hide/show, L9 `reused` (3.2) |
| `test_mp2_bodies_stray` | stray guard: count check, recycle, expected silent pools, `pitt_mp_local` (3.4) |
| `test_mp2_bodies_replication` | spawn with host ids, motion tracking, rest within 1 cm, rest-only traffic, despawn <= 300 ms, reuse, out-of-range bodies, hidden bodies, ownership (never sent to the owner) + host_follow / release + local_sim hand-back, D22, fixture bodies with equal static ids, freeze_world (D16), meta through adapters in apply scope, stray guard on a client |
| `test_mp2_bodies_wsnap` | late join with 350 entities (metas, a hidden one, `SaveManager.is_loading` held), churn during the join with ch1 delayed (cut + buffered ch3 replay), pool-full pending + retry, pools_hash reject, corrupt world snapshot, row codec (3.7) |
| `test_mp2_bodies_econ` | money clamp within one physics frame, bank / mining bank / statistics mirror (`stat_changed` once per change), mirror-field registry, netq, `net_stats` (3.8) |
| `test_mp2_bodies_contract` | 10.2 members of `bodies.gd` **and** both other streams' `fake_bodies.gd`, the Session's 10.1 registry, BODIES' doubles are modules, contract file format (10.8) |

### MP2 two-instance harness (`tools/test-mp-loopback.ps1 -Suite mp2 [-Scenario B1]`)

`mods/PittMPTests/mp2/scenario_mp2.gd` (flag role `mp2`, side `host` / `client`): the host opens a world,
moves to open floor and pre-populates it; the client joins (world snapshot), then the streams' scenario
files run in order. BODIES (`mp2/bodies_host.gd`, `mp2/bodies_client.gd`):

| Id | Checks |
|---|---|
| B4 | 60 bodies spawned before the join: all present on the client with the host eids, same pools, from the world snapshot, `api.entities.id_of(puppet)` = host id |
| B9 | 60 Hz on both peers, PerformanceMonitor stopped |
| B1 | 50 ducks spawned and pushed: puppets with the host eids, screenshot `loop-client-mp2-client-sees-host-ducks-moving.png`; at rest every puppet within 1 cm of the host pose |
| B5 | downstream to the client during B1: p95 of 1 s windows <= budget x 1.1 |
| B2 | 20 recycled -> gone on the client; same-frame recycle + respawn -> new eid on both, no leftover |
| B7 | a client-local `add_money` reverted within a frame and counted; `PittMultiplayer.contribute` unknown |
| D1 | the host holds LMB at the manual duck workbench (the game's own `interact_ray` -> `workbench.craft_item` spawn): the client sees the duck with the host eid within 1.5 s |
| H1 | client, right after the join and again at the end: the game's HUD money label (`hud.gd` `$Money`) is drawn on screen (visible, opaque, inside the viewport, its CanvasLayer shown), shows the host's money formatted as the game does, and `GameState.is_game_started` is true |
| D2 | the client holds LMB at its copy of the bench: the forwarded craft makes a duck on the host, the client sees it, no local craft; releasing stops the host's bench |
| G1-G6 | GRAB (`mp2/grab_host.gd`, `mp2/grab_client.gd`; MP2-DESIGN 11.2): grab + throw, deny, race, owner silence, pause release; G5 (disconnect) after the end checks |
| W1 | manual duck workbench (`mp2/coop_checks.gd`): the client holds LMB at the bench, its HUD progress bar shows and the host's stays hidden; then the host crafts, its bar shows and the client's stays hidden (0.2.2) |
| M1 | upgrade menu live refresh: the client has the menu open while the host buys through its own row (the client's row text changes without reopening) and while the host's money changes (credits follow); then the host has it open while the client buys (0.2.2) |
| T1 | the client equips a broom (carry + the `equip` key) and sweeps (the `interact` key) at 4 yaws: on the host the broom on the client's rig pushes along the rig's view and a duck in front of the client moves along the client's facing (0.2.2) |
| G10 | the client lifts the game's CRATE (pool `tool_box`) through the interact ray + an LMB click, empty, then with 3 ducks inside, then full (24 ducks in 3 layers) (`mp2/g10_crate.gd`): it rises >= 0.3 m on both peers, the ducks stay inside it on both while lifted and swung, everything converges within 5 cm after the drop; then the host lifts it as a control (0.2.2, the second two-PC Steam test) |
| end | client: no unexpected strays, orphan frames <= 1 %, local money writes only where expected, 60 Hz |

## Live (`tools/test-live.ps1`)

Runs the `PittAPITests` mod inside the real game.

1. Refuses to run while `projectpitt.exe` is running.
2. Installs with `-WithTests` (unless `-NoInstall`): adds `PittAPITests` and `_PittAPIBrokenFixture`.
3. Writes the one-shot flag `user://pittapi/autotest.flag`
   (`{"run_id","suites","quit":true,"timeout_s"}`), deletes the old report, and SHA-256-hashes every
   `savegame*`, `sandbox.save*` and `profile.cfg`.
4. Launches `steam://rungameid/4026250`.
5. Polls `user://pittapi/test_report.json` until `"finished": true` (written after every suite, so a
   crash still leaves partial results).
6. Kills `projectpitt.exe` if it is still running 10 s after the report, or on timeout.
7. Re-hashes the save files. **Any change fails the run.**
8. Prints failures and the INFO results; `-Uninstall` removes the test mods afterwards.

The test mod does nothing without the flag, and deletes the flag when it reads it, so a normal launch
never runs tests. `_`-prefixed fixture folders are only loaded while the flag exists.

Suites (`-Suites`):

- **boot** (read-only, after `game.boot_complete`): status.json states (PittAPITests and ExampleMod
  LOADED, the broken fixture FAILED with a compile reason), no disabled contract features, ExampleMod's
  `hud.gd` extension registered, all 20 autoloads + `big_int.gd` BLOCKED, log exists, versions, no
  errors attributed to PittAPI, a deliberate error is attributed to the test mod.
- **menu** (read-only, on the first main menu): phase/money reads, 10 slot infos, spawning unavailable,
  keybind register/rebind round trip into `pittapi/keybinds.cfg` with `keybindings.cfg` byte-identical,
  config round trip, command registry, a toast renders, event bus round trip, net stub, snapshot.
- **gameplay** (opt-in): an isolated new game. `achievements.suppress` (every achievement id marked
  granted for the session), `save.isolate` with `user://pittapi/test/run.save` (save locked + autosave
  off, re-asserted every frame; not a slot path, so `profile.cfg` is never touched), run state reset
  like the sandbox "new" path without clearing the sandbox slot, `_pending_new_game = true`,
  `_launch_game(world.tscn)`. Then: `world.ready` (`new_game`, `save_key == "run"`), player, pools,
  spawn/despawn/new id on respawn, reconciler within 0.3 s, `money.add` delta, overspend fails, money
  above int64, `item.buy` -> `item.level_changed`, banner/floating text, `perf.pin_physics`, teleport,
  all achievements granted, no test save written, save still locked, no PittAPI errors. Quits directly
  (the game has no save-on-close).
- **gameplay_phase** (opt-in, after gameplay): `phase.set 5` refused, `phase.set 2` -> `phase.changed`
  and `phase.settled` (runs the real cinematic; `checkpoint_save` is blocked by the save lock).

### Spikes S1-S3 (reported as INFO / checks)

| Spike | Where | Meaning of a failure |
|---|---|---|
| S1 `take_over_path` works in the release build (`.gdc` remaps) | gameplay `S1.extension_active_on_hud` (a real check) | extensions do not apply in the shipped build; scene-script extensions must be redesigned (node-level patching) |
| S2 release template reports script paths to the Logger | boot `S2.release_reports_file_paths` (INFO) | attribution falls back to the "current mod" scope, which still covers handlers and commands but not a mod's own `_process` errors |
| S4 release template reports GDScript VM runtime errors | boot `S4.release_reports_script_errors` (INFO; debug builds run the real check `guard.script_error_attributed_to_mod`) | expected false: release builds neither report nor abort on VM errors; `guard.error_attributed_to_mod` uses an engine error (`get_node` on a missing path) instead |
| S3 the `PittAPI` global works in later-compiled scripts | boot `S3.global_identifier_PittAPI` (INFO) | mods must use the `api` handle only (all bundled mods already do) |

Residual risks: `settings.cfg` / `pipeline_warm.cfg` may be
touched by the game's normal flow; the main menu rewrites `profile.cfg`'s `last_slot` with the same value
(the hash check would catch a real change). If the game crashes mid-run, no save was in flight.

## Manual smoke test

1. `tools\install.ps1`, start the game through Steam.
2. On the main menu a toast says "ExampleMod 1.0.0 loaded ...".
3. Open `%APPDATA%\Godot\app_userdata\Project P.I.T.T\pittapi\status.json`: PittAPI booted, ExampleMod
   LOADED, `contract.disabled` empty.
4. Set `dev_console=true` in `pittapi\config\pittapi.cfg`, restart, press `` ` ``, type `mods`, `state`,
   `events money.`.
5. In a game, press F7: the money is printed to the log and a toast.
6. `tools\uninstall.ps1` restores `override.cfg` (or removes it).
