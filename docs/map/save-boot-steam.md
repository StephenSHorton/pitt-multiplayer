# Subsystem map: save / boot / steam / menus / input

Source: a local decompile of Project P.I.T.T. v1.0.8 (Godot 4.7.2) in `decomp/` (gitignored, not part of this repo).
All paths are `res://` relative to that folder. Line numbers refer to the decompiled files.
Scripts ship in the .pck as compiled `.gdc` (see `decomp/.autoconverted/`), but `res://scripts/x.gd`
paths still resolve through the export remap, so `extends "res://scripts/x.gd"`, `load()` and
`take_over_path()` should all use the `.gd` path.

---

## 1. Boot flow (exact order)

1. Engine starts. `project.godot [steam] initialization/initialize_on_startup=true`,
   `embed_callbacks=false`, `multiplayer_peer/max_channels=4`, `app_id=4026250`. So GodotSteam may
   initialize Steam itself at engine startup (its project-settings path), before any autoload.
2. The 20 autoloads are instantiated in `project.godot [autoload]` order (lines 32-51):
   CameraFeedManager, ObjectPoolManager, PerformanceMonitor, LocalizationManager, GameState,
   ComboSystem, Steamworks, PostProcessManager, MusicManager, GameProgression, WorkbenchSpawning,
   InputManager, MenuManager, SaveManager, UnlockManager, LoadingScreen (a **scene**:
   `res://scenes/loading_screen.tscn`), ResourceWarmer, PortalPairManager, ScreenFade, ImpactAudio.
   What their `_ready()` methods do on boot:
   - `LocalizationManager._ready` -> `load_locale()` reads `user://locale.cfg`.
   - `Steamworks._ready` (`scripts/steamworks.gd:133`) -> `initialize_steam()` (L142):
     - **L146: outside the editor it calls `Steam.restartAppIfNecessary(app_id)` and quits the tree if that returns true**.
       The game dir has **no `steam_appid.txt`**, so starting `projectpitt.exe` directly (outside
       Steam) makes Steam relaunch the game and quits this process. Test launches must go through
       Steam, `steam://rungameid/4026250`, or a `steam_appid.txt` (that means changing the game dir, so the user decides).
     - L150: `Steam.steamInitEx(app_id, false)`. Sets `is_steam_initialized` when status==0.
     - L157: `Steam.isSubscribed()`. L162: `is_steam_deck`. L164: `_apply_steam_language()` (only when
       `locale.cfg` has no saved locale).
     - Deferred: `_connect_progression` (rich presence on `GameProgression.phase_changed`),
       `_connect_achievements` (connects `GameState.stat_changed`, `GameProgression.phase_changed`,
       `SaveManager.save_loaded`), `_connect_overlay` (`Steam.overlay_toggled` -> `MenuManager.request_auto_pause()`).
   - `InputManager._ready` (L126) -> `load_bindings()` reads `user://keybindings.cfg`, then `apply_bindings()`.
   - `MenuManager._ready` (L56) -> `load_settings()` reads `user://settings.cfg` and emits `settings_changed`,
     then `apply_gameplay_settings()` sets `SaveManager.autosave_enabled/autosave_interval`.
   - `SaveManager._ready` only sets `PROCESS_MODE_ALWAYS`. **No save is read at boot.**
   - `ComboSystem` preloads 4 mp3s (combo_system.gd L14-17). `LoadingScreen` loads
     `loading_screen.gd` and `assets/main_menu.tres`.
3. **Our override.cfg autoload runs here** (after all 20, before the main scene).
4. Main scene `run/main_scene="uid://diggqp0gdngbv"` = `res://scenes/splash_screen.tscn`
   (root `SplashScreen` CanvasLayer, group `splash_screen`, script `scripts/splash_screen.gd`).
   - `_ready` L37 -> `_start_background_load()` L103: `ResourceLoader.load_threaded_request("res://scenes/main_menu.tscn")`.
     **That threaded load compiles `main_menu.gd` and its preloads (`save_slot_row.tscn`, `rename_dialog.gd`).**
     So a `take_over_path` on those has to happen in our autoload's `_init`/`_ready`. Doing it from our autoload is early enough.
   - Logos fade; any key skips. `_finish_splash` L141 -> `change_scene_to_packed(main_menu)` L190.
5. `res://scenes/main_menu.tscn` (root `MainMenu` CanvasLayer, script `scripts/main_menu.gd`).
   `_ready` L30: `add_to_group("MainMenu")`, `SaveManager.set_active_slot(get_last_used_slot())`,
   `GameState.sandbox_mode=false`, `MenuManager.current_menu = MainMenu`, connects
   `InputManager.input_device_changed`, `PostProcessManager.load_graphics_settings()`, `_populate_slots()`.

## 2. Scene transitions

| From -> To | Code | Mechanism |
|---|---|---|
| Splash -> main menu | splash_screen.gd L187-192 | `change_scene_to_packed` (threaded preload) |
| Main menu -> **world** (Load) | main_menu.gd `_on_load_pressed` L219-239 | `set_active_slot`, `GameProgression.reset_run_state()`, phase preset from `peek_saved_phase()`, `SaveManager.should_load_on_ready = true`, `_launch_game("res://scenes/world.tscn")` |
| Main menu -> world (New) | `_on_new_game` L263-282 | picks first free slot if the selected slot is occupied, `quarantine_if_corrupt()`, `_pending_new_game = true`, `_launch_game` |
| Main menu -> world (Sandbox) | `_start_sandbox_load` L637 / `_start_sandbox_fresh` L651 | `GameState.sandbox_mode = true`, `set_active_save_path("user://sandbox.save")` |
| `_launch_game` | main_menu.gd L678-714 | hides menu, unpauses, captures mouse, collects `ObjectPoolManager.get_all_resource_paths()` + `WorkbenchSpawning.get_all_resource_paths()` + fixed scenes/music, then `LoadingScreen.load_resources_then_scene(paths, scene_path, _on_resources_loaded)` |
| `_on_resources_loaded(loaded: Dictionary)` | L717-734 | `await ObjectPoolManager.initialize(loaded)`, `WorkbenchSpawning/ComboSystem/GameProgression.initialize(loaded)`, `GameState.loaded_resources = loaded`; if new game: `GameProgression.setup_new_game()` (spawns starter crates); then `LoadingScreen.proceed_to_scene()` |
| LoadingScreen final | loading_screen.gd `_process_final_scene` L203-227 | `load(target_scene_path)`, `change_scene_to_packed` (L220), `ResourceWarmer.mark_warm()` |
| In-game Load (pause menu / F9) | save_manager.gd `begin_load_reload` L163-215 | resets every singleton, recycles all pooled objects, `should_load_on_ready = true`, `change_scene_to_file("res://scenes/world.tscn")` **directly (no LoadingScreen)** |
| Pause -> main menu | pause_menu.gd `_return_to_main_menu` L104-149 | full reset of the singletons, then `change_scene_to_file("res://scenes/main_menu.tscn")` |
| Ending | game_progression.gd L1171/L1438 | threaded load + change to `res://scenes/test_black_hole.tscn` (`ENDING_SCENE_PATH`, L59) |
| Credits -> menu | credits.gd L343 | `LoadingScreen.load_scene("res://scenes/main_menu.tscn")` |
| End-game menu fallback | menu_manager.gd L366/L375 | `change_scene_to_file(main_menu)` |

**Gameplay scene = `res://scenes/world.tscn`**, root node `World` (Node3D). Key nodes:
- `/root/World/PlayerController` (CharacterBody3D, group `player`, script `player_controller.gd`)
  - `.../CameraPivot` (group `head`), `.../CameraPivot/MainCamera` (group `main_camera`)
- `/root/World/HUD` (CanvasLayer, group `HUD`, `hud.gd`), `/root/World/HUD/PlayerHUD`
- `/root/World/PauseMenu` (instance of `pause_menu.tscn`, adds itself to group `PauseMenu`)
- `/root/World/Floor` (group `saveable_hole`), `/root/World/BottomMaw` (group `BottomMaw`), `WorldEnvironment`.

**When the world is ready.** `PlayerController._ready` (player_controller.gd L93-131):
if `SaveManager.should_load_on_ready` is set, it clears the flag, waits 2 process frames, calls
`SaveManager.load_game()`, then `await SaveManager.apply_deferred_load()`. Then
`ResourceWarmer.warm_up()`, mouse capture, `MenuManager.settings_changed.connect(update_settings)`,
and **`GameState.start_game()` last** (L131). Because `_ready` awaits, the node's `ready` signal fires
*before* the load finishes. There is no "world loaded" signal. Use these instead:
- loaded game: `SaveManager.save_loaded` (fires at the end of `load_game()`, before pool objects respawn),
  then wait until `SaveManager.pending_pool_data` and `SaveManager.pending_player_position` are both empty and `SaveManager.is_loading` is false.
- new game: `GameState.is_game_started` turns true (set by `start_game()` at the end of `_ready`).
  Note that `is_game_started` also comes back true from the save stats during `load_game` (save_manager.gd L958-959).

## 3. Save system (critical)

### Location
`user://` = `%APPDATA%/Godot/app_userdata/Project P.I.T.T/`
(no `application/config/use_custom_user_dir`). **Saves live here. No Steam Remote Storage API is used.**
But **Steam Auto-Cloud mirrors this folder**: `steam_autocloud.vdf` is present, and
`<Steam>/userdata/<account id>/4026250/remotecache.vdf` tracks
`Godot/app_userdata/Project P.I.T.T/locale.cfg` and `profile.cfg` (root 4 = WinAppDataRoaming).
The exact auto-cloud file patterns are not visible to us. Assume `*.cfg` and `*.save*` in the root get uploaded.
**Mods must not write to the user:// root.** Use `user://mods/...`, and accept that Auto-Cloud may sync or restore files behind our back.
Right now there is **no savegame on disk** (only locale.cfg, profile.cfg, shader_cache, vulkan).

### Files (save_manager.gd L6-18, L1778-1813)
| File | Meaning |
|---|---|
| `user://savegame.save` | slot 0 (`SAVE_FILE_PATH`) |
| `user://savegame_%d.save` with `%d = slot+1` | slots 1..9 (`slot_path()` L1809; slot 1 -> `savegame_2.save`) |
| `<path>.tmp` / `.bak` / `.corrupt` | temp write, previous good save, quarantined unreadable save |
| `user://sandbox.save` (+.bak/.tmp) | sandbox slot (`SANDBOX_SAVE_PATH`) |
| `user://profile.cfg` | ConfigFile: `[slots] last_slot`, `slot_N` = {name,timestamp,phase,money,play_time,products} cache; `[progress] game_completed`, `ending_<kind>` |
| `user://settings.cfg` | MenuManager.settings (sections controls/audio/ui/gameplay) |
| `user://keybindings.cfg` | `[keybindings] action=code`, `[gamepad_bindings] action=button, glyph_override` |
| `user://locale.cfg` | `[settings] locale` |
| `user://graphics_settings.cfg` | PostProcessManager |
| `user://pipeline_warm.cfg` | ResourceWarmer `[warm] version, driver` |
| `user://feed_capture/` | camera feed debug captures |

`MAX_SAVE_SLOTS = 10`. `active_slot`/`active_save_path` are set by `set_active_slot()` (L1829, which also
writes `last_slot` to profile.cfg) or `set_active_save_path()` (L1773).

### Format
- Saves are encrypted JSON: the stringified `save_data` is written through Godot's encrypted `FileAccess`
  with a password embedded in the game (`SAVE_PASSWORD`, `IS_ENCRYPTED`, around L14-15 and L311-312). That is Godot's
  `GDEC` encrypted-file container. To read or write it, use Godot's `FileAccess` with `SaveManager.SAVE_PASSWORD` read
  at runtime. Do not hand-roll the crypto, and do not copy the password into mod code or docs.
- Read: `_read_save_string` L456 tries encrypted first. If that fails or the text does not start with `{`,
  it **falls back to plaintext** (L466-474). So a plaintext JSON save also loads.
- `_read_and_parse` L479: has to parse to a Dictionary, otherwise it returns null. JSON numbers come back as
  float; the code casts with `int()`. BigInt money is stored as plain decimal **strings**.
- Top-level keys (built in `_save_game_impl` L273-301): `version, timestamp, game_state, unlocked_milestones,
  game_statistics, object_pools, player_position{x,y,z}, phase, demo_end_triggered, cameras, hole,
  vertical_gates, press_spawned, trading_terminal_spawned, bowling_set_spawned, workbenches,
  music{track_path,is_playing,combo_is_first_item}, minable_blocks, pickaxe, loop_puzzle, seen_items`.
  - `game_state` (L518-610): money strings, upgrades/tools/toys/products/combos `{level, enabled}` maps, remote, etc.
  - `object_pools` (L657-795): `{pool_id: {active_objects:[{position,rotation,visible,is_frozen,linear_velocity,...}], available_count}}`.

### Versioning and migration
- `"version"` comes from `application/config/version` ("1.0.8"), but only in the **initial** `save_data`
  dict (L53). `load_game` does `save_data = data` (L393), so after a load the version of the file it came
  from is carried forward, and `version` is **never checked**. There is no schema version.
- Migrations are heuristic: `RETIRED_POOL_IDS` skipped (L17, L1052), `_migrate_starter_crates` (L1991),
  phase >= PHASE_5 clamped to PHASE_4 (L431-433, L1620), unknown upgrade/tool/toy/product/combo keys
  **ignored on load** (`if name in GameState.x`, around L895-930). Unknown pool ids go to `ObjectPoolManager.spawn`, which returns null and skips the entry.
- Because `save_data` is reused, any **extra top-level key survives load and re-save**. It also
  **leaks into a New Game** started after a load in the same session, because `save_data` is never reset.
  If mod data piggybacks in the save, it has to be rewritten on every save. Better: keep mod data out of the save (see hooks).

### Write pipeline (atomic, `save_game(force)` L227 -> `_save_game_impl` L273)
Guards: `_is_saving`, `can_save()` (`save_locked`, `is_loading`, `MIN_SAVE_INTERVAL_MS = 5000`),
`_world_is_snapshotable()` (current_scene and a `player` node exist). The tree is paused synchronously for the duration of the call.
Steps: write `.tmp` -> re-read and verify -> delete old `.bak` -> rename save to `.bak` -> rename `.tmp` to the save -> set
`_last_save_tick` (**success only**, L342) -> `_write_slot_index()` (profile.cfg cache). There is a watchdog at 30 s (L72).
Load: `load_game()` L370 reads the primary; if it is unreadable it is quarantined to `.corrupt` and `.bak` is tried (L379-391).
Entry points: `autosave()` (timer `autosave_interval` default 300 s, only while unpaused and the game has started, L81-95),
`manual_save()` (pause menu), `checkpoint_save(label)` (phase 2/3/4 in game_progression.gd), quick save F5
(player_controller.gd L137), `save_before_exit()` (pause "save first"), `save_game(true)` at the ending (game_progression L1246).
`save_locked` is set by elevator.gd and game_progression (ending). **There is no save on window close**
(no `NOTIFICATION_WM_CLOSE_REQUEST` handling anywhere).

### Signals
`SaveManager.save_loaded` (no args), emitted at the end of `load_game()` L452. It is the only save signal.
There is **no saved / save_failed / slot_deleted signal**. Listeners include hud.gd L87, elevator L113, steamworks L333,
upgradeUI L317, ore_processor, pickaxe, fuse, loop_puzzle, torch_light, uv_lamp, uv_code, security_keypad, card_reader.

## 4. Steam (steamworks.gd)
- Init: see boot. **It calls `restartAppIfNecessary`.** APP_ID_FULL=4026250, APP_ID_DEMO=4636730 (`GameState.IS_DEMO=false`).
- `Steamworks._process` (L439) calls **`Steam.run_callbacks()` every frame** (`PROCESS_MODE_ALWAYS`, so it also runs while paused).
  Because `embed_callbacks=false`, this is the only pump. Lobby, P2P and NetworkingMessages callbacks for multiplayer
  are dispatched here. Mods must not add a second pump; connect to `Steam.*` signals instead.
- Rich presence: `_push_presence` (L239), keys `money` and `steam_display` (tokens `#Status_Duck/Cash/Pinata/Anomaly`),
  every 0.3 s while the game has started. `clear_presence()`. A multiplayer mod would add `connect` / `steam_player_group` keys.
- Achievements: `unlock_achievement(api_name)` (L291) queues until stats are ready (probe polling L663-701). Achievement and stat
  maps are constants `ACH_STAT`, `ACH_PHASE`, `ACH_GATE`, `ACH_FLOOR`, `ACH_ENDING`.
- Overlay: `Steam.overlay_toggled` -> `MenuManager.request_auto_pause()` (L186-220).
- Public fields: `is_steam_initialized: bool`, `is_steam_deck: bool`.
- Zero networking or lobby code in the game. `rename_dialog.gd` L137 uses `Steam.showFloatingGamepadTextInput`.

## 5. Menus and pause state (menu_manager.gd)
- State: `current_menu: CanvasLayer`, `previous_menu`, `game_paused: bool`, `upgrade_ui_displayed: bool`,
  `menu_stack: Array[CanvasLayer]`, `settings: Dictionary` (L27-53), `_menu_scene_cache`.
- Signal: `settings_changed` (no args), emitted by `load_settings()` and `save_settings()`.
- `open_menu(menu)` L107: pushes the current menu, shows `menu`, and **if it is not the MainMenu, sets `get_tree().paused = true`** and `game_paused = true`.
  `close_current_menu()` L139 / `go_back()` L166 pop the stack and unpause when it is empty. PauseMenu and MainMenu are hidden; other menus are `queue_free`d.
- `request_auto_pause()` L123 (overlay or controller loss), which requires `GameProgression.can_pause`.
- Menus are opened lazily from scene paths via `_instantiate_menu(path)` L231 and added to `current_scene`:
  `option_menu.tscn`, `audio_menu.tscn`, `visuals_menu.tscn`, `controls_menu.tscn`, `credits.tscn`,
  `session_complete.tscn`, `end_of_game.tscn`. ResourceWarmer pre-caches end_of_game, session_complete, credits and options **after the
  world is entered** (`warm_up()` from PlayerController._ready).
- Pause is opened by `PlayerController._unhandled_input` on the `esc` action (L173-193) when `GameProgression.can_pause`.
  `can_pause` becomes true after leaving the elevator (game_progression L108/L136, elevator L69).
- Pause menu nodes: `Background/MenuContainer/MenuButtons/{Resume, HBoxContainer/Save, HBoxContainer/Load, Delete, Options, Main Menu, Quit}`,
  plus `Unstuck` and `ClearItems` (found with find_child). Main menu: `Background/MenuButtons/{FeedbackButton, Play, Options, Credits, Quit}`,
  `Background/MenuLoad/{ScrollContainer/SlotContainer, Load, New, Sandbox, Rename, Delete, Return}`, `Background/MenuSandbox/{Continue, NewCopy, NewFresh, Return}`, `Background/Version`.
- `ConfirmDialog` (class_name, scripts/confirm_dialog.gd): `setup(title_key, body_key, on_confirm, confirm_key, cancel_key, click, hover, focus_node)`, `setup_alt(key, callable)`. It can be reused for mod UI.
- Options menu (option_menu.gd) has Controls/Visuals/Audio/Return and a language dropdown. `LocalizationManager.SUPPORTED_LOCALES` is used there.

## 6. Input (input_manager.gd)
- `project.godot [input]` defines only: left, right, up, down, lMouse, rMouse, mMouse, esc, interact, jump, sprint, crouch, equip.
  At boot `InputManager.apply_bindings()` creates and overwrites all actions in `default_bindings` (L7-30):
  up, down, left, right, sprint, jump, crouch, interact, rotate(R), equip(E), action(Q), reset(G), torch(T), rack(V),
  lMouse, rMouse, mMouse, esc, quick_save(F5), quick_load(F9), scroll_up, scroll_down. Gamepad map is L46-59, trigger map L62-65.
- Values are **physical keycodes** (`InputEventKey.physical_keycode`) or mouse button indices (1..9 = mouse).
- Signals: `input_device_changed(is_gamepad: bool)` L88, `bindings_changed` L94 (end of `apply_bindings`), `controller_type_changed(new_type)` L123.
- `load_bindings()` L264 reads **only keys present in `default_bindings` / `default_gamepad_bindings`**.
  `save_bindings()` L288 writes **every key in `current_bindings`**. `apply_bindings()` L301 erases and re-adds events for every key
  in `current_bindings`, then adds stick axes. `remap_action(action, code)` L367 requires `action in current_bindings` and **swaps** with the conflicting action.
  `reset_to_defaults()` L434 replaces `current_bindings` with a copy of `default_bindings`.
- Controls UI (`scenes/controls_menu.gd`, root `ControlMenu`): `_populate_keyboard_bindings()` L115 uses a **hard-coded local
  `action_names` dict**. Rows come from the `KeybindRow` preload (`scenes/keybind_row.tscn`, an HBoxContainer with children
  `ActionLabel` and `KeyButton`; the button has meta `action`, or `is_gamepad` for pad rows). The container is
  `Background/MenuContainer/VBoxContainer/ScrollContainer/KeybindContainer`. `populate_keybinds()` clears and rebuilds on device switch.
  Rebinds go through `InputManager.remap_action` / `remap_gamepad_action`, so a mod action in `current_bindings` works with the stock UI once a row exists.

**How to add a mod keybind:**
1. `InputManager.default_bindings[id] = KEY_X` (so reset-to-defaults covers it).
2. Read `user://keybindings.cfg [keybindings] id` yourself, because the game's `load_bindings` already ran and would never read it.
   Then set `InputManager.current_bindings[id] = value` and call `InputManager.apply_bindings()`.
3. The game's `save_bindings()` will now persist it automatically. If the mod is removed, the stale key in the cfg is ignored and dropped on the next save.
4. For UI, either use a script-extension of `scenes/controls_menu.gd` overriding `_populate_keyboard_bindings()` (call super, then append rows),
   or use the `node_added` path: watch for `ControlMenu` and re-append after `populate_keybinds()` / `input_device_changed`.
Use a prefix such as `mod_<modid>_<name>` to avoid clashes. Avoid keys used by the game (F5/F9/WASD/etc.), or a conflict swap will rebind a game action.

## 7. What is loaded before our loader (affects take_over_path)
- **Already instantiated, so take_over_path will NOT affect the live node**: all 20 autoload scripts
  (`scripts/camera_feed_manager.gd ... impact_audio.gd`, including save_manager, steamworks, menu_manager, input_manager,
  localization_manager, ressource_warmer, screen_fade, game_state, game_progression, unlock_manager, object_pool_manager)
  and `scripts/loading_screen.gd` (via `scenes/loading_screen.tscn`).
- Preloaded by autoloads: 4 mp3 in combo_system.gd. `BigInt` (`scripts/big_int.gd`) is effectively loaded via game_state's static use.
  Global `class_name` scripts: BigInt, ConfirmDialog, GamblingCrate (wodd_crate.gd), RecycleCube, TerminalControl, TradingTerminal (gambling_terminal.gd), ProductStream.
  These can be compiled early by any script that references the name, so treat them as not swappable.
- **Not yet loaded when our autoload runs** (take_over_path works if done in our `_init`/`_ready`):
  `splash_screen.gd` (the main scene, which loads right after us; do the take_over first),
  `main_menu.gd` / `main_menu.tscn` (threaded load starts in Splash `_ready`), `pause_menu.gd`, `option_menu.gd`,
  `scenes/controls_menu.gd`, `scenes/keybind_row.gd`, `player_controller.gd`, `hud.gd`, and everything in world.tscn.
  MenuManager caches PackedScenes in `_menu_scene_cache` on first open, so swap scripts before then.
- **Autoload wrapping**: to change autoload behaviour, either (a) connect to signals or poll its state,
  or (b) **replace the autoload entry in override.cfg** with our subclass, e.g.
  `SaveManager="*C:/.../save_manager_ext.gd"` where the file does `extends "res://scripts/save_manager.gd"`.
  Overriding an existing key should keep its position in the order. This is unverified; test it live. Only one mod (the loader) can own each replacement.
  Do not `set_script()` on a live autoload, because it resets all members.

## 8. Hook points (recommended)
See the structured list. Summary:
- Scene lifecycle: `get_tree().node_added`, or `SceneTree.scene_changed` (4.5+, check it exists), and match `current_scene.scene_file_path`.
- After load: `SaveManager.save_loaded`.
- After save: poll `SaveManager._last_save_tick` (changes only on success), or use an autoload-wrap of `save_game`.
- Settings: `MenuManager.settings_changed`. Input: `InputManager.bindings_changed`, `input_device_changed`.
- Phase: `GameProgression.phase_changed(new_phase:int)`. Stats: `GameState.stat_changed(stat_name, new_value)`, `money_updated(new_amount)`.
- Steam: `Steam.*` signals directly. Pumping is done by `Steamworks._process`. Gate on `Steamworks.is_steam_initialized`.
- Mod persistence: a sidecar `user://mods/<modid>/<slot-basename>.json`, keyed by `SaveManager.active_save_path`, written when
  `_last_save_tick` changes and read on `save_loaded`. Never touch `savegame*.save*`.

## 9. Multiplayer notes
- Pause is global `get_tree().paused`: `MenuManager.open_menu`, `SaveManager.save_game` (briefly), the overlay and controller-loss auto pause.
  In a multiplayer session, menus must not pause the tree for the host and clients (needs an autoload-wrap of MenuManager.open_menu or a PauseMenu extension).
  Network nodes must use `PROCESS_MODE_ALWAYS`.
- All singletons assume one player: `get_first_node_in_group("player")` everywhere (SaveManager, pause_menu unstuck, HUD),
  and one `main_camera`. Remote player avatars **must not** join group `player` / `main_camera` / `head`.
- Save authority: only the host should save. Clients need `SaveManager.autosave_enabled=false` and `save_locked=true`,
  and quick save/quick load (F5/F9) must be blocked on clients. `begin_load_reload` reloads the whole scene, so it needs a session-level protocol.
- World entry has to be synchronized: host picks slot -> clients receive a state snapshot. The save JSON (via `SaveManager._save_game_impl` collectors)
  is a ready-made full-state serializer: `_save_game_state()`, `_save_object_pools()`, etc. return Dictionaries.
- Steam callbacks are pumped by Steamworks (`run_callbacks` in `_process`). `steam/multiplayer_peer/max_channels=4` is already configured, and SteamMultiplayerPeer is available in the bundled GDExtension.
- RNG: not seeded. Physics is Jolt with interpolation, so it is not deterministic. Plan for host-authoritative physics.

## 10. Gotchas
- `restartAppIfNecessary` quits when launched outside Steam with no steam_appid.txt.
- No save on window close. No saved signal.
- `save_data` is persistent across loads and new games; extra keys leak.
- The Rename button in main_menu.tscn is wired to `_on_load_pressed` (connection line 1627); `_on_rename_pressed` (main_menu.gd L510) is never connected.
- `begin_load_reload` skips the LoadingScreen and pool initialize. Pools stay initialized from the first launch.
- The `player_controller._ready` load block appears twice (L105-118). It is harmless because the flag is cleared.
- Steam Auto-Cloud syncs user:// root files, so do not put big or temporary mod files there.
