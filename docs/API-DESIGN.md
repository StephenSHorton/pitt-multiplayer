# PittAPI design

A mod loader and modding API for **Project P.I.T.T. v1.0.8** (Steam app 4026250, buildid 25122572, Godot 4.7.2-stable, GDScript only).

Status: design, not built yet. Steam multiplayer (`MULTIPLAYER-UI-SPEC.md`) builds on this API. **No netcode is part of this project.** The API only has to be ready for it.

The subsystem maps in `docs/map/*.md` are the reference for game internals. Line numbers below are for `decomp/scripts/*.gd` (v1.0.8). That folder is read-only reference material: we never commit it and never redistribute it.

---

## 0. Facts this design relies on

Each item was checked against the decompiled source or tested with the Godot 4.7.2 console binary (`.tools/godot`). The probes were throwaway projects in the session scratchpad.

| # | Fact | Evidence |
|---|---|---|
| F1 | `override.cfg` `[autoload] X="*C:/abs/x.gd"` loads an external script. It runs after the 20 game autoloads and before SplashScreen. | Live smoke test (orchestrator). |
| F2 | A script loaded from an absolute path can `extends "res://..."`, and `preload("sibling.gd")` resolves relative to that absolute path. | Probe: `ext/child.gd` extends `res://base.gd` and preloads `sib.gd`, printing `child>base:sib`. |
| F3 | `take_over_path` chains. Each later extension that `extends` the same `res://` path stacks on the one before it. | Probe: `child2>child>base:sib`. |
| F4 | A scene that references a script by **uid** gets the taken-over script when it is loaded or instanced afterwards. | Probe: `.tscn` with `uid=` and a wrong `path=` printed `child2>base`. |
| F5 | `SceneTree.scene_changed` and `node_added` exist in 4.7.2. | Probe: `ClassDB.class_has_signal` returned true for both. |
| F6 | A parse error in a mod script gives a `GDScript` with `can_instantiate() == false` and does not crash. A runtime error aborts only the current function, which returns `null`. | Probe (`broken.gd`, `rt.gd`). |
| F7 | `OS.add_logger(Logger)` receives `_log_error(function, file, line, code, rationale, editor_notify, error_type, script_backtraces)`, including parse and runtime errors **with the offending script's file path**. | Probe captured `[".../rt.gd", 4, "Invalid access ..."]`. Tested on an editor/debug binary. The game runs a release template, so we still need to confirm the path is reported there (spike S2). |
| F8 | The pck ships scripts as binary tokens (`res://scripts/hud.gdc` plus a remap). The `res://scripts/*.gd` paths remain the resource-cache keys. | `grep -a` on `projectpitt.pck`. take_over_path on remapped paths is the Godot Mod Loader pattern (spike S1 confirms it live). |
| F9 | The only autoloads are the 20 in `project.godot`. Only `BigInt` (`big_int.gd`) among the class_name scripts is referenced by autoloads, so it is loaded before us. No autoload preloads a gameplay script. `splash_screen.gd` threads `main_menu.tscn` from its `_ready`, which runs after our autoload. | `project.godot` [autoload] and greps of the autoload scripts. |
| F10 | Saves: `SAVE_FILE_PATH="user://savegame.save"`, `slot_path(n)="user://savegame_%d.save" % (n+1)`, `SANDBOX_SAVE_PATH="user://sandbox.save"`, `PROFILE_PATH="user://profile.cfg"`, `MAX_SAVE_SLOTS=10`, `IS_ENCRYPTED=true`, `SAVE_PASSWORD` const. The write is atomic: tmp, verify, rename old file to .bak, rename tmp into place (save_manager.gd:273-356). | save_manager.gd:6-15, 1809. |
| F11 | `_write_slot_index()` **returns early when `active_save_path` is not a slot path** (`slot_from_path < 0`), so profile.cfg is not touched. `set_active_save_path(path)` accepts any path. `save_game()` gives up when `save_locked` is set (`can_save`), and so do `autosave`/`checkpoint_save`. `save_before_exit` returns early when `save_locked`. Nothing saves on window close. | save_manager.gd:147, 358, 1773, 1966. |
| F12 | Every achievement write goes through `Steamworks.unlock_achievement`, the only `Steam.setAchievement` caller (steamworks.gd:315). It returns early when `_granted[api]` is set. `_probe_ids` lists every achievement id. Steamworks does **not** check `sandbox_mode`. | grep `setAchievement` / `storeStats`; steamworks.gd:291, 653. |
| F13 | `ObjectPoolManager.spawn(pool_id, position=Vector3.ZERO, rotation=Vector3.ZERO) -> Node3D` returns null for an unknown pool or an exhausted pool. `_pools` is empty until `initialize()`, which runs from `main_menu._on_resources_loaded`. `_pools[id].active` is the live list. `_activate` sets `visible=true`, and `_deactivate` sets `visible=false` and `PROCESS_MODE_DISABLED`. Cannon storage also sets `body.visible=false` (cannon.gd:335), so visibility alone **cannot** be used to detect despawns. | object_pool_manager.gd:399-520, 692-736. |
| F14 | `InputManager.apply_bindings()` erases and rebuilds only the actions in `current_bindings`. `save_bindings()` writes every key in `current_bindings` to `user://keybindings.cfg`. | input_manager.gd:264-340. |
| F15 | `GameState.add_money(amount, product_type="")`, `add_bonus(amount)`, `spend(amount)` and `can_afford(amount)` all go through `int(round(amount))`, so they are int64. `money_updated.emit(money)` passes the live BigInt. `buy(category, key, subkey="") -> bool`. | game_state.gd:840-870, 1062. |
| F16 | `combo_updated` is declared with 3 args but emitted with 2 (combo_system.gd:104, 211). | grep. |

### Spikes (do these first in the build phase; each takes about 15 minutes in the live game)

- **S1** Confirm `take_over_path("res://scripts/hud.gd")` from our autoload takes effect in the release build, where scripts are `.gdc`-remapped.
- **S2** Confirm the `Logger` file attribution (F7) in the release template.
- **S3** Check that the identifier `PittAPI` (an autoload added through override.cfg) can be used as a global in mod scripts that are compiled later. The fallback is the `api` handle passed to `_mod_init`, which is always available.
- **S4** Optional. Find out whether redefining an existing autoload key in override.cfg (for example `SaveManager="*C:/.../save_manager_ext.gd"`) keeps its order slot. Nothing in v1 depends on this. It would only add "exact" hooks later.

---

## 1. Goals and non-goals

**Goals:**
- One safe loader.
- A stable, versioned API, so mods don't touch game internals directly.
- Every state change is a serializable Command.
- Every observation is a serializable Event.
- Stable entity ids.
- Saves are never put at risk.
- Automated headless tests and live tests.

**Non-goals for v1:**
- Netcode.
- Replacing autoload scripts.
- Asset or pck patching.
- A mod browser UI.

---

## 2. Architecture

```
override.cfg  ->  PittAPI autoload  (<game>/mods/PittAPI/pittapi.gd)
                   ├─ Log            (user://pittapi/pittapi.log, rotating)
                   ├─ ErrorGuard     (OS Logger; attributes errors to mods by file path)
                   ├─ Contract       (boot self-check of every game member the bridge uses)
                   ├─ ModLoader      (discover → validate → sort → load → init)
                   ├─ Extensions     (take_over_path registry, applied in _init phase)
                   ├─ Authority      (LocalAuthority now; SteamAuthority later)
                   ├─ Commands       (registry + dispatcher; the ONLY mutation path)
                   ├─ Events         (bus; typed, JSON-safe payloads)
                   ├─ GameBridge     (game signals + polling → Events)
                   ├─ Entities       (stable ids for pooled/static objects)
                   └─ facades: state, spawn, player, hud, input, config, saves, console, achievements
mods/<ModId>/mod.json + entry.gd   (each entry is a Node under /root/PittAPI/Mods/<id>)
```

Boot order inside the PittAPI autoload:

1. `_init()`:
   - Open the log.
   - Install ErrorGuard.
   - Read every manifest.
   - Apply all **script extensions** from every enabled mod, in load order. This has to happen before SplashScreen threads main_menu.tscn (F9).
   - Mods do not run code at this point. Extensions are declared in mod.json.
2. `_ready()`:
   - Run the contract self-check.
   - Build the facades.
   - Instantiate each mod entry in load order and call `_mod_init(api: PittAPIContext)`.
   - Connect GameBridge.
   - Emit `game.boot_complete`.
3. The SplashScreen loads, then the main menu. GameBridge emits `scene.changed` events from there.

### Repo layout and install layout

```
pitt-multiplayer/                       (git)
  loader/            → installs to <game>/mods/PittAPI/
  mods/ExampleMod/   → <game>/mods/ExampleMod/
  mods/PittAPITests/ → <game>/mods/PittAPITests/   (installed only with -WithTests)
  tests/headless/    (fakes + runner; never installed)
  tools/*.ps1, tools/contract_check.py
  docs/, README.md, TESTING.md
```

`<game>` is `"C:/Program Files (x86)/Steam/steamapps/common/Project P.I.T.T"`. At runtime it is computed as `OS.get_executable_path().get_base_dir()`. When the editor is running or `OS.has_feature("editor")`, the env var `PITTAPI_GAME_DIR` overrides it.

---

## 3. Loader

### 3.1 override.cfg (written by tools/install.ps1)

```ini
[autoload]
PittAPI="*C:/Program Files (x86)/Steam/steamapps/common/Project P.I.T.T/mods/PittAPI/pittapi.gd"
```

The installer does this:
- Backs up any existing `override.cfg` to `override.cfg.pittapi-backup-<timestamp>`.
- If the existing file has other sections, merges ours into it. Otherwise writes ours.
- Writes `mods/PittAPI/.install.json` with `{installed_at, game_buildid, backup_file, files[]}`.

Uninstall reverses the install from that file:
- Restores the backup, or deletes override.cfg if there was none.
- Deletes only the files listed in `.install.json`.

Install refuses to run while `projectpitt.exe` is running. It warns, but continues, if the Steam `appmanifest_4026250.acf` buildid is not 25122572.

Steam "Verify integrity" does not remove override.cfg or mods/, because they are extra files. A game update can still break hooks, which is what the contract check (3.6) is for.

### 3.2 Manifest: `mods/<ModId>/mod.json`

```json
{
  "id": "ExampleMod",
  "name": "Example Mod",
  "version": "1.2.0",
  "api_version": "^1.0",
  "entry": "main.gd",
  "dependencies": { "SomeLib": ">=0.3.0" },
  "optional_dependencies": { "OtherMod": "*" },
  "load_order": 100,
  "extensions": ["extensions/hud_ext.gd"],
  "game_versions": ["1.0.8"],
  "multiplayer": "client_required",
  "enabled": true
}
```

- `id` must match `^[A-Za-z][A-Za-z0-9_]{1,63}$` and the folder name. Ids are unique.
- `api_version` and the dependency values are semver ranges (`^`, `~`, `>=`, `<`, `*`, exact). The parser is `core/semver.gd`, our own code.
- `load_order` is an int, default 100, lower loads first. A dependency always loads before its dependents whatever the numbers say.
- `multiplayer` takes `client_required | host_only | local_only`. It is metadata for the future lobby version check (MP spec: `pittapi_version` lobby data). Each value is checked against the schema.
- Mods are enabled unless `user://pittapi/mods.cfg [enabled] <id>=false` says otherwise. The game folder is not touched to disable a mod.

### 3.3 Resolution

The loader goes through these steps:

1. **Discover.** Scan `<game>/mods/*/mod.json`. It skips `PittAPI` (core), folders that start with `_` or `.`, and disabled mods.
2. **Validate the schema.** On failure the mod is marked `FAILED(reason)` and skipped.
3. **Check versions.** `api_version` is checked against `PittAPI.VERSION` (`1.0.0`), and `game_versions` against `ProjectSettings application/config/version` (it says `"1.0.8"`). A game version mismatch is only a warning, unless `strict_game_version` is set.
4. **Build the dependency graph.** Missing or out-of-range dependencies mark the mod `FAILED`, and that failure passes to its dependents. Cycles are detected and the whole cycle is `FAILED`.
5. **Sort.** Topological sort; ties are broken by `(load_order, id)`.
6. **Compile.** Each script in `extensions` and `entry` is loaded and checked with `can_instantiate()` (F6). A failure marks the mod `FAILED` before anything of it is applied. Extensions from one mod are applied all-or-nothing.

The state of each mod (`LOADED | FAILED | DISABLED | QUARANTINED`, with the reason) is written to the log and to `user://pittapi/status.json`. The dev console and tests read that file.

### 3.4 Error isolation

GDScript has no try/catch, so isolation has four layers:

1. **Before running anything.** Script compilation failures are caught by `can_instantiate()`, and manifest errors by schema validation.
2. **Containment by construction.**
   - Each mod's entry is its own `Node` under `/root/PittAPI/Mods/<id>`, with `process_mode` inherited.
   - Every call into mod code goes through `ModContext.invoke(callable, args)`.
   - A runtime error only aborts that call, which returns null (F6), and the loop that dispatches events carries on to the next handler.
   - The API never relies on a value a mod returns unless it is validated (type checked; null means "no answer").
3. **Attribution and quarantine.**
   - ErrorGuard is a `Logger` subclass registered through `OS.add_logger`. It maps `file` (and `script_backtraces[0]` when present) to a mod by path prefix (`<game>/mods/<id>/`).
   - Every error is counted for its mod and logged with the mod id.
   - Past `quarantine_threshold` errors (default 50 in 10 s, or any error during `_mod_init`):
     - the mod is set `QUARANTINED`;
     - its event subscriptions, commands, keybinds and console commands are removed;
     - its node gets `process_mode = DISABLED`;
     - a toast tells the player.
   - Script extensions cannot be unapplied at runtime, so a quarantined mod's extensions stay active. The log says so, and the mod is auto-disabled for the next boot (`mods.cfg`).
   - If S2 shows the release template drops file info, attribution falls back to the "current mod" stack that `ModContext.invoke` keeps.
4. **Things a mod cannot do through the API.** It cannot write saves, change profile.cfg, pause the tree in an MP session (later), or call into another mod's private nodes. A mod can still poke game globals directly, because GDScript has no sandbox. The policy (sections 5 and 8) says it must not, and code review is the enforcement.

### 3.5 Logging

```gdscript
# api.log (a PittLogger bound to the mod id)
func debug(msg: String, data: Variant = null) -> void
func info(msg: String, data: Variant = null) -> void
func warn(msg: String, data: Variant = null) -> void
func error(msg: String, data: Variant = null) -> void
```

- Line format: `2026-10-14T18:51:54.123 [INFO ] [ExampleMod] msg {json}`.
- File: `user://pittapi/pittapi.log`. It rotates at 2 MB and keeps `.1` to `.3`.
- Each line is also printed to stdout, which the console exe and `--verbose` show.
- `user://pittapi/config/pittapi.cfg` sets `log_level`.

### 3.6 Contract self-check (game-update resilience)

`loader/core/contract.gd` lists every game member the bridge or facades touch. Examples: `GameState.money` / `add_money` / `money_updated`, `SaveManager.save_locked` / `active_save_path` / `_last_save_tick`, `ObjectPoolManager._pools`, `UnlockManager.milestones`, `Steamworks._granted` / `_probe_ids`, `main_menu._launch_game`.

At boot:
- Autoload members are checked with `has_method`, `has_signal` and `in`.
- Scene-script members are checked when the scene loads.

Each API feature belongs to one contract group. If any member of a group is missing, that feature is **disabled**: its calls return `ERR_UNAVAILABLE` and it is logged. Nothing crashes. `tools/contract_check.py` runs the same list against `decomp/` text, so a new game build can be diffed in CI-like fashion right after re-decompiling.

---

## 4. Script extensions

### 4.1 API

Extensions are declared in mod.json `extensions`, because they must be applied in `_init`, before any mod code runs. Each extension script must:
- `extends "res://scripts/<target>.gd"`, using the path, not a class_name;
- call `super.<method>()` unless it deliberately replaces the method;
- carry no `class_name`. External scripts aren't in the global class cache, so a class_name there is ignored at best and a conflict at worst.

```gdscript
# loader side (internal)
func apply_extension(mod_id: String, ext_path: String) -> Error
#   1. s := load(ext_path) as GDScript ; fail if null or !s.can_instantiate()
#   2. base := s.get_base_script(); target := base.resource_path   (must start with res://)
#   3. refuse if target in BLOCKED (4.2) → ERR_UNAVAILABLE with explanation
#   4. s.take_over_path(target)      # F3: later mods stack automatically
#   5. record {mod_id, target, ext_path, chain_index}
# api.extensions (read-only for mods)
func list() -> Array[Dictionary]            # [{target, chain:[{mod, path}]}]
func is_extended(target: String) -> bool
```

Rules:
- A mod that extends a script whose instances already exist (pooled tools persist across world reloads) only affects instances created afterwards. That is fine, because all gameplay scripts are first loaded at Play time, after our `_init`.
- An extension of a base script, such as `piston.gd`, affects subclasses (`piston_2.gd`, `piston_3.gd`) only if they load later, which they do.
- Overrides of `_ready` on `upgradeUI.gd` must keep the `is_mirror` early return (upgradeUI.gd:290).
- **Lifecycle-safe hooks preferred:** extensions should be thin. They call `PittAPI.events.emit_internal("...")` or a hook point and contain no logic of their own, so the logic lives in the mod node, where isolation applies.

### 4.2 Cannot be extended this way (BLOCKED list, enforced)

These scripts are already loaded and their nodes already built before our `_init` runs (F1, F9). Taking over their path would only affect *new* instances, and none ever get made.

| Script | Why | Fallback |
|---|---|---|
| All 20 autoload scripts: `object_pool_manager`, `performance_monitor`, `game_state`, `combo_system`, `steamworks`, `post_process_manager`, `music_manager`, `game_progression`, `workbench_spawning`, `input_manager`, `menu_manager`, `save_manager`, plus the uid-referenced `camera_feed_manager`, `localization_manager`, `unlock_manager`, `loading_screen`, `ressource_warmer`, `portal_pair_manager`, `screen_fade`, `impact_audio` | Instantiated before us | (a) Connect to their signals. (b) Poll their fields (GameBridge). (c) Intercept at a scene-script call site that *is* extendable, for example `upgradeUI._spawn_tool_instance` for purchases or `hud.show_result` for combo payouts. (d) Later, if S4 passes, replace the autoload key with a subclass. |
| `big_int.gd` (BigInt) | Parsed as a dependency of the autoloads | Use it as-is through `api.state` helpers. |
| `loading_screen.tscn` script | Autoload scene | Same as above |
| Already-instanced scenes | Taking over affects only new instances | Use node-level patching: on `node_added`, connect signals or set fields. |

Scripts that are **safe** because they first load after our `_init`:
- Everything reachable from `main_menu.tscn` (`main_menu.gd`, `camera_pivot.gd`, `bottom_maw.gd`, `falling_object_manager.gd`, which are loaded at splash time but after us).
- `world.tscn` and the pooled tool/product scenes (`hud`, `main_camera`, `player_controller`, `interact_ray`, `upgradeUI`, `hole`, `press`, `piston*`, ...).
- Lazily loaded menus (`controls_menu`, `pause_menu`).

The BLOCKED check uses the `[autoload]` list read from `ProjectSettings` at runtime, so new autoloads in a game update are blocked automatically.

---

## 5. Save safety

**Where saves live** (F10). They are all in `user://` = `%APPDATA%/Godot/app_userdata/Project P.I.T.T/`, which Steam Auto-Cloud syncs. The game's files there:
- `savegame.save` (slot 0)
- `savegame_2.save` … `savegame_10.save` (slots 1-9)
- `sandbox.save`
- `.tmp`, `.bak` and `.corrupt` siblings of each
- `profile.cfg` (slot index, last_slot, endings seen)
- `settings.cfg`, `keybindings.cfg`, `graphics_settings.cfg`, `locale.cfg`, `pipeline_warm.cfg`

Saves are encrypted JSON, using `open_encrypted_with_pass` with `SAVE_PASSWORD`. There is a backup of this machine's user:// at `.tools/save-backup-20261014-185154`.

**Policy:**
1. PittAPI and mods **never write, rename or delete** any `savegame*`, `sandbox.save*` or `profile.cfg` file. Nothing in the API gives mods a path to those files. `api.saves` is read-only metadata (`get_slot_infos()` wraps `SaveManager.get_all_slot_infos()`).
2. Mods don't put data into `SaveManager.save_data`. Its top-level keys outlive a re-save but leak into a New Game, and data inside game structures is silently dropped when the mod is missing. Mod data goes in a **sidecar**: `user://pittapi/saves/<save-key>/<mod_id>.json`, where `<save-key>` is the active_save_path basename (`savegame`, `savegame_3`, `sandbox`). It is plain JSON, written atomically (`.tmp`, then rename). It is:
   - written on `save.saved`, which is detected when `SaveManager._last_save_tick` changes (it is set only after a successful rename, save_manager.gd:342);
   - read on `save.loaded`;
   - deleted when the game deletes the slot (we notice the slot file disappearing and empty `get_slot_info`).

   ```gdscript
   # api.saves
   func get_active_save_key() -> String
   func get_slot_infos() -> Array[Dictionary]
   func mod_data_get(key: String, default: Variant = null) -> Variant   # in-memory, per active save
   func mod_data_set(key: String, value: Variant) -> void              # JSON-safe only; flushed on save.saved
   signal mod_data_loaded()
   ```
3. **Mod-injected milestones** (`UnlockManager.milestones`) are allowed through `cmd unlock.register_milestone`, because the game itself stores only ids and skips unknown ones on load (unlock_manager.gd:2189). They must be registered in `_mod_init`, which runs before any load_game. The ids are namespaced `mod.<id>.<name>`.
4. No mod-content keys go into `GameState.upgrades`/`tools`/`toys`/… in v1. They would be dropped on load and lost on the next save (save-boot-steam map).
5. **Test isolation** (section 9.3): `SaveManager.set_active_save_path("user://pittapi/test/run.save")` plus `save_locked = true` and `autosave_enabled = false`. Because of F11 this can touch neither the slots nor profile.cfg.
6. **Cheat-class commands** (`money.set`, `phase.set`, `unlock.force`) are tagged `cheat`. If one runs on a real slot, the sidecar is stamped `{"cheated": true}` and a one-time confirm toast appears. They never touch the save files.
7. The API exposes no `quit()` that would skip `save_before_exit`. Quitting stays the game's job.

---

## 6. API surface

The handle that `_mod_init(api)` receives is a `PittAPIContext` bound to the mod: it has the mod's id, logger, config and paths. The global `PittAPI` gives the same facades without a mod binding (S3).

```gdscript
# mods/ExampleMod/main.gd
extends Node
var api  # PittAPIContext

func _mod_init(p_api) -> void:
    api = p_api
    api.events.on("money.changed", _on_money)
    api.commands.register("example.double_money", _cmd_double, {"cheat": true})
    api.input.register_action("toggle_panel", KEY_F7, "Toggle example panel")
    api.console.register("hello", func(args): return "hi " + " ".join(args))

func _mod_shutdown() -> void: pass   # quarantine / game exit

func _on_money(ev: PittEvent) -> void:
    api.log.info("money now %s" % ev.payload.money)
```

### 6.1 Context

```gdscript
class_name-less PittAPIContext (RefCounted)
var mod_id: String
var mod_dir: String                 # <game>/mods/<id>/
var version: String                 # mod version
var api_version: String             # PittAPI.VERSION
var log: PittLogger
var config: PittConfig
var events: PittEvents
var commands: PittCommands
var entities: PittEntities
var state: PittState
var spawn: PittSpawn
var player: PittPlayer
var hud: PittHud
var input: PittInput
var saves: PittSaves
var console: PittConsole
var net: PittNet                    # authority info (local stub)
func has_mod(id: String) -> bool
func get_mod_api(id: String) -> Object   # other mod's exported object (entry's `get_public_api()`), or null
```

### 6.2 Events

```gdscript
# PittEvent (RefCounted, immutable after emit)
var name: String          # "money.changed"
var payload: Dictionary   # JSON-safe only (validated in debug)
var seq: int              # monotonically increasing per session
var t_ms: int             # Time.get_ticks_msec()
var origin: int           # peer id; 1 = local/host for now
var source: String        # "game" | "api" | "mod:<id>"

# PittEvents
func on(name: String, handler: Callable, priority: int = 0) -> int     # returns sub id; "*" and "prefix.*" allowed
func once(name: String, handler: Callable) -> int
func off(sub_id: int) -> void
func emit(name: String, payload: Dictionary = {}) -> void   # mods may emit only "mod.<own id>.*"
func last(name: String) -> PittEvent                         # last event of that name (for late subscribers)
func wait(name: String, timeout_s: float = 0.0) -> PittEvent # await-able helper (null on timeout)
```

`PittSerial.to_json_safe(v)` is the only check on payloads. It allows `null`, `bool`, `int`, `float`, `String`, and Array/Dictionary of these. It converts `Vector3` to `[x,y,z]`, `Transform3D` to its 12 floats, `BigInt` to a decimal string, `StringName` to `String`, and Node/Object to an **entity id** (or null). This keeps every payload ready to send over the network unchanged.

**Event catalog v1.** Each event lists its payload and its source; ✓ means connected to a real signal, ~ means derived by polling or diffing.

| Event | Payload | Source |
|---|---|---|
| `game.boot_complete` | `{api_version, game_version, mods:[{id,version,state}]}` | loader |
| `scene.changed` | `{path, kind: "splash"\|"main_menu"\|"world"\|"ending"\|"other"}` | ✓ `SceneTree.scene_changed` (F5) |
| `world.ready` | `{new_game: bool, save_key, sandbox: bool}` | ~ `GameState.is_game_started` false→true while scene=world (set last in player_controller.gd:131) |
| `world.exited` | `{}` | ~ is_game_started true→false or a scene change away from the world |
| `money.changed` | `{money: "123", delta: "45", sign: 1\|-1\|0, reason: "add"\|"bonus"\|"spend"\|"set"\|"direct"}` | ✓ `money_updated`, plus `stat_changed("money")` (golden statue bypass), plus a 0.5 s compare poll. Delta comes from the previous `clone()` |
| `bank.changed` | `{bank: float}` | ✓ `bank_updated` |
| `stat.changed` | `{stat, value}` (BigInt→string) | ✓ `stat_changed` (throttled per stat to 10 Hz) |
| `phase.changed` | `{from, to, source: "transition"\|"load"\|"poll"}` | ~ poll `GameProgression.current_phase` every frame (catches direct writes and PHASE_5), plus ✓ `phase_changed` marking the settle. Load is detected by `SaveManager.is_loading` |
| `phase.settled` | `{phase}` | ✓ `phase_changed` (late for 2-4) |
| `ending.started` | `{secret: bool}` | ~ `GameProgression.ending_active` |
| `combo.started` / `combo.updated` / `combo.ended` / `combo.broken` / `combo.mega` | `{level}` / `{level, progress}` / `{level, bonus}` / `{}` / `{multiplier}` | ✓ ComboSystem signals (2-arg handler for `combo_updated`, F16) |
| `unlock.milestone` | `{id, category, replay: false}` | ✓ `milestone_unlocked` |
| `item.level_changed` | `{category, key, level, enabled}` | ~ diff of GameState upgrades/tools/toys/products/combos levels on `money_updated` and `stat_changed` (no purchase signal exists) |
| `product.crafted` | `{key, auto: bool}` | ✓ `stat_changed("products_crafted.<k>" / "products_autocrafted.<k>")` |
| `product.sold` | `{product_type, lucky, value, entity_id}` | ✓ BottomMaw `product_consumed`, resolved straight away (the body id is reused after the 3 s recycle). Not emitted for recycle cubes |
| `product.recycled` | `{value, entity_id}` | ✓ BottomMaw `product_consumed("recycle", 0, ...)`; value = the cube's `recycle_value` meta (what `GameState.add_money` was paid) |
| `entity.spawned` / `entity.despawned` | `{entity_id, pool_id, position}` / `{entity_id, pool_id}` | API spawns: immediate. Game spawns: ~ pool reconciler (6.4) |
| `player.ready` | `{entity_id}` | ✓ `node_added` with group `player` |
| `player.held_changed` / `player.equipped_changed` | `{entity_id\|null, prev\|null, thrown: bool}` | ~ per-physics-frame diff of `main_camera.picked_object` / `equipped_item`. `thrown` is detected through the `player_throw_time` meta |
| `gate.opened` | `{gate_id}` | ✓ vertical_gate `gate_opened` |
| `save.loaded` | `{save_key, slot}` | ✓ `save_loaded`, plus a `save.applied` event once `pending_pool_data` is empty and `is_loading` is false |
| `save.saved` | `{save_key, slot}` | ~ `SaveManager._last_save_tick` changed |
| `ui.menu_changed` | `{menu: String\|null, paused: bool}` | ~ `MenuManager.current_menu` |
| `input.action` | `{action, pressed}` | mod keybinds (6.8) |
| `command.executed` | `{id, name, args, ok, error, origin}` | Commands (for audit and later replication) |
| `mod.<id>.*` | free-form, JSON-safe | mods |

### 6.3 Commands and authority (the multiplayer seam)

Every API that **changes** game state is a thin wrapper around `commands.execute`. Reads are direct.

```gdscript
# PittCommands
func register(name: String, handler: Callable, opts: Dictionary = {}) -> Error
#   opts: { schema: {arg: TYPE_* or [TYPE_*, ...]}, cheat: bool, authority_only: bool = true,
#           replicate: "events"|"none", description: String, scope: "authority"|"local",
#           remote: bool = false }
#   remote: a multiplayer host accepts this command from clients. Hosts (PittMultiplayer)
#   refuse every other authority command sent by a client with ERR_DENIED.
#   handler: func(args: Dictionary, ctx: PittCommandCtx) -> Variant   (return value must be JSON-safe)
#   mods may only register "<mod_id>.*" names; core owns unprefixed ones.
func execute(name: String, args: Dictionary = {}) -> PittCommandResult
func execute_async(name: String, args: Dictionary = {}) -> PittCommandResult   # await-able; resolves next frame at latest
func list() -> Array[Dictionary]
func describe(name: String) -> Dictionary

# PittCommandResult (RefCounted)
var id: int; var ok: bool; var value: Variant; var error: String; var done: bool
signal completed(result)
# Locally done == true on return of execute(). Mod code MUST check `done` / await `completed`
# so it keeps working when commands become remote.

# PittCommandCtx: { origin_peer: int, mod_id: String, is_replay: bool, cmd_id: int }

# Envelope (the wire format, already used internally):
# { "v":1, "id":int, "name":String, "args":Dictionary(JSON-safe), "mod":String, "origin":int, "t":int }
```

**Authority interface** (`core/authority.gd`):

```gdscript
# PittAuthority (base)
func is_authority() -> bool                   # Local: true
func local_peer_id() -> int                   # Local: 1
func submit(envelope: Dictionary) -> void     # Local: validate + dispatch now, then complete(result)
func complete(envelope: Dictionary, result: Dictionary) -> void
signal peers_changed()
```

The Commands dispatcher does the following for each call:
1. Validates the name, the schema and JSON-safety.
2. Checks permissions: a cheat command is rejected when `PittAPI.config.cheats_allowed` is false. The default is true in single player; the future MP host decides.
3. Hands the envelope to `authority.submit`.
4. Runs the handler on the authority.
5. Wraps the handler in an ErrorGuard scope. A null return together with a logged error becomes `ok=false`.
6. Emits `command.executed`.

**Core commands v1** (the facades call these):

| Command | Args | Effect (game call) |
|---|---|---|
| `money.add` | `{amount: String\|int, reason?: "add"\|"bonus"}` | `GameState.add_money(int)` / `add_bonus`. Strings above int64 use `money.add_big(BigInt.from_string)` plus `money_updated.emit`. Counts toward `total_money_gained` and so toward milestones (documented) |
| `money.spend` | `{amount}` → `{ok:bool}` | `can_afford` then `spend`. Fails instead of flooring at 0 |
| `money.set` (cheat) | `{amount: String}` | `GameState.money = BigInt.from_string(s); money_updated.emit(money)`, the same as the load path (save_manager.gd:824) |
| `bank.set` (cheat) | `{amount: float}` | `GameState.bank = x; bank_updated.emit(x)` |
| `item.buy` | `{category, key, subkey?}` | `GameState.buy(...)`. Upgrades, products and combos only. Tools and toys: `item.buy_tool` uses the UpgradeUI path (call the node's existing purchase handler through an extension hook) |
| `phase.set` (cheat) | `{phase: 1..4}` | `GameProgression.change_phase(p)`. Refuses 5 (the irreversible ending) unless `{allow_ending:true}` |
| `unlock.force` (cheat) | `{id}` | `UnlockManager.force_unlock(id)`, then `UpgradeUI.update_ui()` |
| `unlock.register_milestone` | `{id, def: Dictionary}` | Inserts into `UnlockManager.milestones` (namespaced id). Init phase only |
| `entity.spawn` | `{pool_id, position:[x,y,z], rotation?:[x,y,z], velocity?:[x,y,z], meta?:{}}` → `{entity_id}` | `ObjectPoolManager.spawn`, null-checked; velocity is set after spawn (F13) |
| `entity.despawn` | `{entity_id}` | `ObjectPoolManager.recycle(node)`. Refused for non-pooled (static) entities |
| `entity.set_transform` / `entity.impulse` | `{entity_id, position, rotation}` / `{entity_id, impulse}` | Direct |
| `player.teleport` | `{position}` or `{transform}` | `player_controller.teleport_to` / `teleport_to_transform` |
| `player.impulse` | `{impulse}` | `apply_external_impulse` |
| `achievements.suppress` | `{}` | Prefills `Steamworks._granted[id]=true` for every id in `_probe_ids` (F12). Session-only; needed for tests and cheats |
| `perf.pin_physics` | `{hz: 60}` | `PerformanceMonitor.set_process(false)`; sets `Engine.physics_ticks_per_second` (an MP prerequisite) |

### 6.4 Entity registry

```gdscript
# PittEntities
func id_of(node: Node) -> int             # 0 if untracked
func get_node(entity_id: int) -> Node     # null if gone / despawned
func track(node: Node, static_key: String = "") -> int  # mods tracking their own nodes
func untrack(entity_id: int) -> void
func describe(entity_id: int) -> Dictionary  # {id, kind:"pooled"|"static"|"mod", pool_id, key, position, rotation, value?, metas{gambled,tint_color,...}}
func list(filter: Dictionary = {}) -> Array[int]   # {pool_id, kind, within:{center:[..], radius}}
func key_of(entity_id: int) -> String
```

- **Ids** are `int`, allocated by the authority from a per-session counter that starts at 1000. Ids 1..999 are player slots (`register_player(node, peer)`: the local player is 1, other peers get the next free slot). Only the authority allocates dynamic ids. The id is stored as node meta `pittapi_eid`.
- **Pooled objects:**
  - API spawns register right away.
  - Game spawns are caught by the **pool reconciler**. Every physics frame it compares `sum(pool.active.size())` with the last value, and every 0.25 s it does a full set diff over `ObjectPoolManager._pools[*].active` (F13). Visibility is not reliable because of the cannon.
  - New members get an id and `entity.spawned`. Members that leave get `entity.despawned`, and the meta is removed, so a reused pool instance gets a **new** id.
  - This fixes the instance-id reuse problem noted in the maps.
- **Static fixtures** get deterministic keys, the same on every peer: `static:/root/World/BottomMaw`, `static:/root/World/Floor`, `workbench:manual:duck` and `workbench:auto:<k>` (WorkbenchSpawning keys), `press`, `trading_terminal`, `gate:<gate_id>`, `block:<parent>_<name>`. Their ids are hashed from the key, `abs(hash(key)) % 2^31 | 1<<31`, so the mapping is the same everywhere without negotiation.
- On `world.exited` everything is cleared. Pooled objects persist under `/root/ObjectPools` but are re-registered on the next `world.ready`.

### 6.5 State accessors (reads; writes via commands)

```gdscript
# PittState
func get_money() -> String                 # GameState.money.to_plain_string()
func get_money_float() -> float            # to_float(), display only
func money_compare(amount: String) -> int  # -1/0/1
func can_afford(amount: String) -> bool
func add_money(amount: Variant, reason := "add") -> PittCommandResult   # → money.add
func spend(amount: Variant) -> PittCommandResult
func set_money(amount: String) -> PittCommandResult                       # cheat
func get_bank() -> float
func get_phase() -> int                    # GameProgression.current_phase
func get_phase_name(p: int = -1) -> String # "elevator","duck","crown","bear","effigy","ending"
func get_phase_progress() -> float         # hole (group saveable_hole).get_phase_progress(), -1 if no world
func set_phase(p: int) -> PittCommandResult                               # cheat
func is_in_world() -> bool                 # current scene == res://scenes/world.tscn and is_game_started
func is_sandbox() -> bool
func is_unlocked(milestone_id: String) -> bool
func get_unlocked() -> Array[String]       # copy
func get_item(category: String, key: String) -> Dictionary   # deep-copied, JSON-safe
func get_stat(path: String) -> Variant     # same paths as UnlockManager._get_stat ("products_consumed.duck")
func snapshot() -> Dictionary              # JSON-safe summary (money, bank, phase, unlocked, item levels) — later the late-join seed
static func bigint_from(v: Variant) -> BigInt     # int|String|BigInt → new BigInt (always cloned)
```

### 6.6 Spawning

```gdscript
# PittSpawn
func pools() -> Array[String]             # ObjectPoolManager._pools.keys() ([] before Play)
func is_ready() -> bool                   # ObjectPoolManager._initialized
func headroom(pool_id: String) -> int     # pool_headroom
func spawn(pool_id: String, position: Vector3, rotation := Vector3.ZERO, opts := {}) -> PittCommandResult
#   value.entity_id; opts.velocity, opts.meta
func despawn(entity_id: int) -> PittCommandResult
```

Spawns always go through `ObjectPoolManager`; nothing is ever `instantiate()`d. Fixtures that are not pooled (press, trading terminal, bowling set) can't be spawned in v1. Calls made before Play fail with `ERR_UNAVAILABLE`.

### 6.7 Player

```gdscript
# PittPlayer  (local player now; MP will add get_players() -> Array[int] of player entity ids)
func get_local() -> Node3D                # /root/World/PlayerController or null
func get_camera() -> Camera3D             # group main_camera
func get_position() -> Vector3
func get_look_transform() -> Transform3D
func get_held() -> int                    # entity id or 0  (main_camera.picked_object)
func get_equipped() -> int                # entity id or 0  (main_camera.equipped_item)
func get_focus() -> int                   # interact_ray.last_collider
func teleport(pos: Vector3) -> PittCommandResult
func impulse(v: Vector3) -> PittCommandResult
func set_movement_locked(locked: bool) -> void   # player meta golf_aim_mode (local-only, not a command)
```

### 6.8 HUD

PittAPI owns a `CanvasLayer` (layer 90, `PROCESS_MODE_ALWAYS`) under `/root/PittAPI/UI`. It uses the game's `res://assets/PublicPixel-rv0pA.ttf`, loaded with `load()` so the game's file is never copied. Because it lives outside World, it works on the main menu too.

```gdscript
# PittHud
func toast(text: String, opts := {}) -> void       # small stacked toast; opts {duration=3.0, color, icon}
func banner(text: String) -> void                  # passthrough to HUD.show_notification_message (world only; no-op otherwise)
func floating_text(text: String, color := Color.WHITE) -> void   # HUD._spawn_special_bonus_text (world only)
func add_panel(id: String, control: Control) -> void   # mod overlay controls, removed on quarantine
func remove_panel(id: String) -> void
```

Toasts are local, not commands. Later, multiplayer adds an `rpc_toast` event that each peer shows locally.

### 6.9 Input (mod keybinds)

The design keeps `keybindings.cfg` clean (F14). Our actions are **not** added to `InputManager.current_bindings`, because `save_bindings` would write them into the game's file.

```gdscript
# PittInput
func register_action(name: String, default_key: Key, label: String = "", default_pad: JoyButton = -1) -> String
#   creates InputMap action "mod_<id>_<name>", physical keycode event; persisted in user://pittapi/keybinds.cfg
func rebind(name: String, key: Key) -> Error
func get_key_name(name: String) -> String          # InputManager.get_key_name(code)
func is_pressed(name: String) -> bool
func conflicts(name: String) -> Array[String]      # game actions via InputManager.get_action_for_key + other mods
```

`apply_bindings()` never erases our actions, because they aren't in `current_bindings`. We still re-assert them on `InputManager.bindings_changed`. A `_unhandled_input` dispatcher emits `input.action`. The ExampleMod shows `node_added` injection of rows into the controls menu (`ControlMenu .../KeybindContainer`). That is an optional v1.1 core feature.

### 6.10 Per-mod config

```gdscript
# PittConfig  → user://pittapi/config/<mod_id>.cfg  (ConfigFile, section per group)
func define(key: String, default: Variant, opts := {}) -> void   # opts {section="general", type, min, max, options[], description}
func get_value(key: String, section := "general") -> Variant
func set_value(key: String, value: Variant, section := "general") -> void   # validates, saves (debounced 0.5 s)
signal changed(section: String, key: String, value: Variant)
```

Global PittAPI settings live in `user://pittapi/config/pittapi.cfg`:
- `log_level`
- `dev_console=false`
- `console_key=KEY_QUOTELEFT`
- `cheats_allowed=true`
- `quarantine_threshold`
- `strict_game_version`
- `entity_reconcile_gate=true` (false: the hosting pool reconciler runs its full diff every physics frame again, see MP2-DESIGN L8)

### 6.11 Console (optional, dev)

The console is only enabled when `dev_console=true`. It is a `LineEdit` and log view in the PittAPI CanvasLayer. While it is open it sets the player meta `golf_aim_mode` and releases the mouse, but it never pauses the tree.

```gdscript
# PittConsole
func register(name: String, handler: Callable, help: String = "") -> void   # handler(args: PackedStringArray) -> String
func run(line: String) -> String
```

Built-in console commands:
- `help`, `mods`, `cmd <name> <json>` (any command), `events [filter]` (live tail), `state`
- `spawn <pool> [n]` (at the camera's look point), `money <add|set> <n>`, `phase <n>`
- `ents [pool]`, `log <n>`

### 6.12 Net (stub)

```gdscript
# PittNet
func is_authority() -> bool          # true
func local_peer_id() -> int          # 1
func is_multiplayer() -> bool        # false
func get_peers() -> Array[int]       # [1]
signal session_started(); signal session_ended()   # never emitted in v1
```

---

## 7. How the future Steam layer plugs in

No v1 code changes are needed. The MP mod (or the `PittAPI-Net` core module) does the following:

1. **Provides a `SteamAuthority`** that extends `PittAuthority` and calls `PittAPI._set_authority(a)` when a session starts.
   - On the host, `is_authority()` returns true. `submit()` runs locally, the same as now, and broadcasts `command.executed` plus the resulting events to clients.
   - On a client, `submit()` serializes the envelope, sends it to the host over `Steam.sendMessageToUser` on channel 1 (or through `SteamMultiplayerPeer` with `project.godot steam/multiplayer_peer/max_channels=4`), and completes the `PittCommandResult` when the reply arrives. That is why mods must honour `done` and `completed`.
2. **Replicates events.** Events already carry JSON-safe payloads and `origin`.
   - The host forwards events tagged `replicate` (money, phase, unlock, item.level_changed, entity.spawned/despawned) on a reliable channel.
   - Clients apply them with internal *replay* commands (`ctx.is_replay = true`, for example `money.set`, `unlock.force` through `_execute_action` replay, `phase.set_cosmetic`). The replay commands bypass the cheat flags and gameplay side effects.
   - `PittState.snapshot()`, plus the per-entity schema in `SaveManager._save_object_pools`, gives the late-join seed.
3. **Entity ids are already authority-allocated.** Clients spawn mirrors from `entity.spawned {entity_id, pool_id}` through the same pool ids and record the host id in the meta. Transform snapshots, which are not events, stream on an unreliable channel keyed by entity id. Static entities use the deterministic key hashes.
4. **Gates host-only logic.** These are separate MP-phase extensions: maw payout, hole growth, combo payout (`hud.show_result`), workbench crafting and force writers (fan, magnet, …). Each one checks `PittAPI.net.is_authority()`. The extension mechanism (section 4) already supports them, and the maps list the call sites.
5. **Prerequisites already in the v1 API:**
   - `achievements.suppress` / per-client unlock policy;
   - `perf.pin_physics`;
   - save policy (clients: `save_locked=true`, `autosave_enabled=false`, applied through a `session.client_mode` command);
   - no pausing the tree in a session (an MP-phase extension of `menu_manager` call sites; MenuManager is BLOCKED, so it uses the `pause_menu.gd` / `node_added` workaround from the maps).
6. **Version gating.** The lobby data `pittapi_version` and the list of `client_required` mods, as `[id@version]`, come from `game.boot_complete`.

---

## 8. Mod authoring rules (README excerpt)

- Mutate game state only through `api.commands`. Reading game globals directly is tolerated, but use the facades where they exist.
- No `class_name`. Use `preload("relative.gd")` (F2).
- Payloads and command args must be JSON-safe.
- No file I/O outside `api.config`, `api.saves.mod_data_*` and `mod_dir`.
- Extensions must be thin and call `super`.

---

## 9. Testing

### 9.1 Static checks (`tools/test-headless.ps1`, step 1)

1. Copy `loader/`, `mods/` and `tests/headless/` into `dist/headless-project/`, which is gitignored and holds a generated `project.godot`.
2. Run `Godot_v4.7.2-stable_win64_console.exe --headless --path dist/headless-project --check-only -s <file>` for every `.gd` file. Any parse error fails the run.
3. Run `python tools/contract_check.py decomp/ loader/core/contract.gd`. It checks that every member the contract names exists in the decompiled scripts at a matching signature. It is skipped with a warning if `decomp/` is missing.
4. Validate every `mod.json` against `loader/schema/mod.schema.json`, using Python `jsonschema` if installed or a minimal built-in check otherwise.

### 9.2 Headless unit tests (step 2)

`tests/headless/run_tests.gd` (extends SceneTree) is a tiny xUnit:
- `assert_eq`, `assert_true`, `assert_error_logged`;
- runs every `tests/headless/suites/test_*.gd`;
- writes `dist/headless-report.json` and exits with code 0 or 1.

The generated `project.godot` registers **fakes** under the real autoload names:
- `GameState`: BigInt-like money, the signals, `add_money`, `spend`, `buy`
- `GameProgression`
- `ComboSystem`
- `UnlockManager`
- `SaveManager`: paths go to `user://` of the throwaway project, `_last_save_tick`
- `ObjectPoolManager`: `_pools`, Pool with `active`/`available`, spawn/recycle using plain `Node3D`
- `InputManager`
- `MenuManager`
- `Steamworks`: `_granted`, `_probe_ids`, `unlock_achievement` records calls

`fake_big_int.gd` is our own minimal `class_name BigInt` with the same method names (the game's file is never copied). After the fakes, `PittAPI` loads from the copied loader with `PITTAPI_GAME_DIR=dist/headless-project/gamedir`.

Suites:
- `test_semver`
- `test_manifest`: valid, invalid id, missing entry
- `test_resolution`: deps, cycles, version mismatch, load order ties
- `test_isolation`:
  - a fixture mod with a parse error is FAILED and the others still load;
  - a mod whose handler throws is still called, then quarantined at the threshold;
  - an error inside `_mod_init` means quarantine.
- `test_extensions`:
  - extends a fake `res://scenes_fake/thing.gd`;
  - two mods chain;
  - an autoload target is refused with ERR_UNAVAILABLE.
- `test_events`: ordering, priority, wildcard, `off`, JSON-safety rejection, `last()`.
- `test_commands`:
  - schema validation;
  - cheat gating;
  - LocalAuthority completes synchronously;
  - a **FakeRemoteAuthority** that completes one frame later proves `execute_async` and `done` semantics.
  - This is the MP-readiness test.
- `test_entities`: pool reconciler assigns new ids on reuse; static key hash is stable.
- `test_money`: delta and sign via the BigInt diff; the direct-write (statue) path through the poll.
- `test_config`: defaults, validation, persistence.
- `test_input`: action created; it survives a fake `apply_bindings`; conflicts.
- `test_saves`:
  - the sidecar is written atomically on a fake `_last_save_tick` change;
  - the API never opens a `savegame*` path (a FileAccess wrapper spy).

### 9.3 Live tests: the `PittAPITests` mod (`tools/test-live.ps1`)

**Arming.** The mod is installed only by `install.ps1 -WithTests`. It does nothing unless the **flag file** `user://pittapi/autotest.flag` exists. The file holds JSON: `{"run_id":"…","suites":["boot","menu","gameplay"],"quit":true,"timeout_s":240}`. The mod **deletes the flag on read**, so a later normal launch never runs tests.

**Script steps:**
1. Refuse to run if `projectpitt.exe` is already running.
2. Install with `-WithTests`.
3. Write the flag, remove any old `test_report.json`, and record a SHA-256 of every `savegame*`, `sandbox.save*` and `profile.cfg` file in user://.
4. `Start-Process "steam://rungameid/4026250"`. This must go through Steam because of `restartAppIfNecessary` (steamworks.gd:146).
5. Poll for `user://pittapi/test_report.json` with `"finished": true` until the timeout.
6. Kill `projectpitt.exe` if it is still running 10 s after the report, or on timeout.
7. **Re-hash the save files. Any change fails the run** (the save-safety check), and the hashes are printed.
8. Print a summary and exit with code 0 or 1. With `-Uninstall`, the test mod is removed afterwards.

**Report** (`user://pittapi/test_report.json`):

```json
{"run_id":"…","api_version":"1.0.0","game_version":"1.0.8","finished":true,
 "summary":{"passed":41,"failed":0,"skipped":2},
 "suites":[{"name":"boot","tests":[{"name":"loader.mods_loaded","ok":true,"ms":1,"msg":""}]}],
 "errors_captured":[…ErrorGuard lines during run…]}
```

It is written after each suite, with `finished:false` until the end, so a crash still leaves partial results.

**Suites:**

- **boot.** Runs in `_mod_init`. Read-only.
  - status.json shows PittAPITests and ExampleMod LOADED, and a deliberately broken fixture mod `_PittAPIBrokenFixture` FAILED. That fixture is installed only with tests; folders starting with `_` are skipped unless the test flag is present.
  - The contract check reports no disabled features.
  - The extension registry shows the ExampleMod `hud.gd` extension.
  - The BLOCKED list contains all 20 autoload names.
  - The log file exists.
  - `PittAPI.VERSION` is semver.
- **menu.** Runs on `scene.changed(kind=main_menu)`. Read-only.
  - `state.get_phase()` is an int.
  - `state.get_money()` is a digit string.
  - `saves.get_slot_infos()` has 10 entries.
  - `spawn.is_ready()` is false and `spawn.spawn` returns ERR_UNAVAILABLE.
  - Input register/rebind round-trips into `user://pittapi/keybinds.cfg`, and `keybindings.cfg` is byte-identical before and after.
  - Config round-trip.
  - The command registry lists the core commands.
  - A toast renders: the node exists and is visible.
  - The event bus is checked with a self-emitted `mod.PittAPITests.ping`.
- **gameplay.** Optional (`"gameplay"` in the flag). It uses an **isolated run**, justified by F11. From the main menu, the mod:
  1. runs `achievements.suppress` (F12), so no real achievement can be granted during the tests;
  2. `SaveManager.save_locked = true; SaveManager.autosave_enabled = false`;
  3. `SaveManager.set_active_save_path("user://pittapi/test/run.save")`. This is not a slot path, so `_write_slot_index` is a no-op and profile.cfg is untouched. Save_locked means even that path is never written. It also means no `.bak`/`.tmp` rotation of a real slot can happen;
  4. sets `GameState.sandbox_mode = false`, `GameProgression.reset_run_state()`, `GameProgression.current_phase = PHASE_1` and `SaveManager.pending_camera_data = {}`, the same as `_start_sandbox_fresh` but without `clear_sandbox_slot()` (main_menu.gd:654). `should_load_on_ready` stays false;
  5. gets the main menu node (group `MainMenu`), sets `_pending_new_game = true` and calls `_launch_game("res://scenes/world.tscn")`. The game then does its real init: pools, `setup_new_game`, world load.

  Then, after `world.ready`, it checks:
  - `world.ready.new_game == true` and `save_key == "run"`;
  - `player.get_local()` is not null and `player.ready` fired;
  - `spawn.pools()` is non-empty;
  - `spawn("duck", pos)` returns an entity id, `entity.spawned` fired, `describe()` gives `pool_id "duck"`, `despawn` emits `entity.despawned`, and a re-spawn gets a different id;
  - the pool reconciler picks up a game-side `ObjectPoolManager.spawn` call within 0.3 s;
  - `money.add 100` produces `money.changed{delta:"100",sign:1}`, and the money string is old+100;
  - `money.spend` above the balance gives ok=false;
  - `money.set "1000000000000000000000"` (above int64) round-trips;
  - `combo`: feeding is not simulated; only the subscription is checked;
  - `item.level_changed` fires after `item.buy` of a cheap upgrade, made affordable with `money.set`;
  - `hud.banner` / `floating_text` run without errors;
  - `perf.pin_physics(60)` gives `Engine.physics_ticks_per_second == 60`;
  - no ErrorGuard errors attributed to PittAPI.
  - `phase.set` is **not** tested by default (it runs cinematics and `checkpoint_save`, which is blocked by save_locked anyway). The opt-in `"gameplay_phase"` suite does test it.

  At the end:
  - the report is written;
  - the test mod asserts that `user://pittapi/test/` contains no save file (proving `save_locked` held);
  - it calls `get_tree().quit()` directly. That bypasses the pause-menu `save_before_exit`, and nothing saves on close (F11).

  Residual risks, documented:
  - Steam rich presence updates during the run (harmless).
  - `settings.cfg` and `pipeline_warm.cfg` may be touched by the game's normal flow, as on any launch. They are not save data.
  - If the game crashes mid-run, no save was in flight, because saving was locked from the start.

### 9.4 What runs when

| When | Command |
|---|---|
| Every change | `tools/test-headless.ps1` (about 10 s, no game needed) |
| Before a release or after a game update | `tools/test-live.ps1 -Suites boot,menu,gameplay` (game must be closed, Steam running) |
| After re-decompiling a new game build | `python tools/contract_check.py` |

`TESTING.md` documents all of the above, plus manual smoke steps: install, launch, open the console, run `mods`.

---

## 10. Files to build

```
loader/
  mod.json                          # id "PittAPI", core:true
  pittapi.gd                        # autoload root: VERSION, boot phases, facade wiring, _set_authority
  schema/mod.schema.json
  core/log.gd                       # PittLogger + file sink with rotation
  core/error_guard.gd               # Logger subclass, per-mod attribution, quarantine
  core/semver.gd
  core/manifest.gd                  # parse/validate mod.json
  core/mod_loader.gd                # discover/resolve/sort/compile/init, status.json, mods.cfg
  core/mod_context.gd               # PittAPIContext + invoke()
  core/extensions.gd                # take_over_path registry + BLOCKED from ProjectSettings autoloads
  core/contract.gd                  # game member contract + feature groups
  core/serial.gd                    # to_json_safe / Vector/Transform/BigInt codecs
  core/events.gd                    # PittEvents + PittEvent
  core/commands.gd                  # PittCommands, PittCommandResult, PittCommandCtx, envelope
  core/authority.gd                 # PittAuthority (base) + LocalAuthority
  core/builtin_commands.gd          # money.*, bank.set, item.buy, phase.set, unlock.*, entity.*, player.*, achievements.suppress, perf.pin_physics
  core/game_bridge.gd               # signal connections + pollers (money, phase, items, held/equipped, saves, menu)
  core/entities.gd                  # registry + pool reconciler + static keys
  api/state.gd  api/spawn.gd  api/player.gd  api/hud.gd  api/input.gd
  api/config.gd api/saves.gd  api/console.gd api/net.gd
  ui/toast_layer.gd  ui/console_panel.gd
mods/ExampleMod/      mod.json, main.gd, extensions/hud_ext.gd (adds a floating "+API" line on combo end via super.show_result)
mods/PittAPITests/    mod.json, main.gd (flag handling, sequencing, quit), runner.gd (assertions/report),
                      suites/suite_boot.gd, suite_menu.gd, suite_gameplay.gd, suite_gameplay_phase.gd
mods/_PittAPIBrokenFixture/  mod.json, main.gd (deliberate parse error; installed only with -WithTests)
tests/headless/       run_tests.gd, project.godot.template, fakes/{fake_big_int,game_state,game_progression,
                      combo_system,unlock_manager,save_manager,object_pool_manager,input_manager,menu_manager,steamworks}.gd,
                      fixtures/mods/*, suites/test_*.gd
tools/common.ps1      # game dir discovery (Steam libraryfolders.vdf), user:// path, process helpers
tools/install.ps1     # -WithTests, -GameDir; backs up/merges override.cfg; copies loader+mods; .install.json
tools/uninstall.ps1   # restore override.cfg backup; remove only listed files
tools/test-headless.ps1
tools/test-live.ps1   # -Suites, -TimeoutSec, -Uninstall; save hash guard
tools/contract_check.py
README.md  TESTING.md  docs/API-DESIGN.md
```

## 11. Build order

1. Spikes S1 to S3, using the live game and a 20-line probe mod.
2. Core modules: log, serial, semver, manifest, loader. Then the headless runner, the fakes and the static checks.
3. Events, commands and authority, then the game bridge and entities.
4. The facades.
5. ExampleMod.
6. PittAPITests (boot and menu suites, then gameplay).
7. Installer and test scripts.
8. Docs.
