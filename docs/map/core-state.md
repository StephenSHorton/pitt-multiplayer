# Subsystem map: core-state

Project P.I.T.T. v1.0.8 (Godot 4.7.2, GDScript). Source: the read-only decompile at `decomp/`.
All line numbers below are from `decomp/scripts/*.gd`.

## TL;DR

- **Money** is `GameState.money: BigInt` (an arbitrary-precision RefCounted, base 1e18 limbs, never negative).
  Mutate through `GameState.add_money / add_bonus / spend`, which emit `GameState.money_updated(money)`.
  `money_updated` passes the **live BigInt reference**, so clone it before you keep it.
- **Phases** are `GameProgression.current_phase` (enum `Phase` 0..5). The hole/maw (`scripts/hole.gd`) drives them by calling
  `GameProgression.change_phase()`. The signal `GameProgression.phase_changed(new_phase:int)` fires **late** for phases 2-4,
  after a cinematic of several seconds. It **never fires for PHASE_5**, and it **does fire on load** (from `SaveManager.load_game`).
- **Unlocks** are data-driven: `UnlockManager.milestones` (~135 entries) are evaluated on every `GameState.stat_changed`
  and `phase_changed`. An unlock sets `enabled` / `enabled_levels[i]` on the GameState item dicts.
  `UnlockManager.milestone_unlocked(id, data)` is the only unlock signal.
- **Purchases have no signal.** Upgrades go through `GameState.buy(category, key, subkey)`. Tool and toy purchases are
  inlined in `upgradeUI.gd` button lambdas (`GameState.spend` + spawn).
- **Combos**: `ComboSystem` signals `combo_started/updated/ended/broken/...`. The **combo payout is done by the HUD**
  (`show_result` in hud.gd calls `GameState.add_bonus` with the total, around line 670), not by ComboSystem.
- **Session lifecycle** has no signals. You have to infer it from scene changes plus `SaveManager.save_loaded`,
  `GameState.is_game_started` and `GameProgression.elevator_exited`.
- **Saves**: `user://savegame.save` (slot 0) and `user://savegame_{slot+1}.save` (slots 1..9), plus `user://sandbox.save`,
  `.bak`, `.tmp` and `.corrupt` variants. They are encrypted JSON with a password embedded in the game
  (const `SaveManager.SAVE_PASSWORD`, save_manager.gd:14). `user://profile.cfg` holds the last slot, the slot index and ending flags.
  That folder (`%APPDATA%/Godot/app_userdata/Project P.I.T.T`) is Steam Auto-Cloud synced (`steam_autocloud.vdf` is present).
  **No savegame files exist yet** on this machine. Only `profile.cfg` (last_slot=0), `locale.cfg` and caches are there.

## Autoload order and take_over_path viability

project.godot `[autoload]`: CameraFeedManager, ObjectPoolManager, PerformanceMonitor, LocalizationManager, **GameState**
(`res://scripts/game_state.gd`), **ComboSystem** (`combo_system.gd`), **Steamworks** (`steamworks.gd`), PostProcessManager,
MusicManager, **GameProgression** (`game_progression.gd`), WorkbenchSpawning, InputManager, **MenuManager**, **SaveManager**,
**UnlockManager** (uid cnm5rtvwqwhpv = `unlock_manager.gd`), LoadingScreen, ResourceWarmer (`ressource_warmer.gd`),
PortalPairManager, ScreenFade, ImpactAudio.

| Script | Kind | take_over_path from our loader? |
|---|---|---|
| game_state.gd, combo_system.gd, game_progression.gd, unlock_manager.gd, save_manager.gd, steamworks.gd, menu_manager.gd | autoload, instantiated before us | **No.** The instance already exists and the script is cached. Use signals or poll, or (untested) override the autoload entry itself in override.cfg (see below). |
| big_int.gd | `class_name BigInt` global class | Not needed and not safe (already loaded by GameState). Use it as is. |
| upgradeUI.gd (scenes/upgrade_ui.tscn, instanced by scenes/upgrade_terminal.tscn, instanced in scenes/world.tscn:1614) | scene script | **Yes.** It loads only when world.tscn loads (via LoadingScreen, after main menu). Call take_over_path in the loader's `_init/_ready`. |
| upgrade_terminal.gd, hud.gd, hole.gd, bottom_maw.gd | world.tscn scene scripts | Yes (same reasoning). |
| session_complete.gd, end_of_game.gd | menus loaded on demand by `MenuManager._instantiate_menu` (menu_manager.gd:235 `load(path)`) | Yes. |
| cash_register.gd, stat_sign.gd, shift_scheduler.gd | pooled scenes, loaded by main_menu `_launch_game` → LoadingScreen → `ObjectPoolManager.initialize(loaded)` | Yes, if done before New Game/Continue is pressed. |

The splash screen only threaded-loads main_menu.tscn, and ResourceWarmer `_warm_menus` runs from `player_controller._ready`
(in world). So none of the scene scripts above are cached before our autoload runs.

**Untested but promising "autoload-wrap"**: override.cfg can probably also *redefine* an existing key, for example
`GameState="*C:/abs/mods/game_state_ext.gd"`, where that script does `extends "res://scripts/game_state.gd"`. Godot would then
instantiate our subclass under the same name and in the same slot. This would let us override `buy()`, `add_money()`, `spend()` and so on
at boot. It needs a live check that (a) ordering is preserved and (b) `res://` extends from an absolute-path script resolves.
Do NOT try to swap a live autoload node at runtime: GDScript globals are bound to the original instance, and its signal
connections stay on it.

## BigInt (`scripts/big_int.gd`, `class_name BigInt extends RefCounted`)

- `const BASE = 10^18`, `BASE_DIGITS = 18`, `var limbs: Array[int]` (little-endian).
- Constructors: `static from_int(v:int)` (negatives clamp to 0), `static from_string(s)` (accepts an int string, or a float string
  that gets floored; a leading `-` is stripped; garbage gives 0).
- In-place ops: `add_int(v)` (ignores v<=0), `add_big(o)`, `sub_int(v)`, `sub_big(o)` (**floors at 0**: if `self <= other`
  the result is 0), `clone()`, `is_zero()`, `compare(o)` / `compare_int(v)` (returns -1/0/1), `to_plain_string()`, `to_float()`.
- No multiply/divide and no negatives. `add_int` takes an int64, so amounts above 9.2e18 need `add_big(BigInt.from_string(...))`.
- Serialized in saves as `to_plain_string()`. `GameState.format_big_number(v)` and `format_compact_number(v)` accept a BigInt, an int or a float.

## GameState (`scripts/game_state.gd`, autoload `/root/GameState`)

### Signals
| Signal | Args | Emitted by |
|---|---|---|
| `stat_changed` | `(stat_name: String, new_value)` | game_state add_money(:851 "total_money_gained"), add_product(:975 "total_products"), _on_combo_ended(:1162-1163 "max_combo","total_combos"), record_camera_destroyed, break_wodden_gambling_crate, etc. Also emitted externally: bottom_maw.gd:215-216 (`"products_consumed.<type>"`, `"total_products_consumed"`), workbenches (`"products_crafted.<key>"`, `"products_autocrafted.<key>"`), golden_duck_statue.gd:211/390 (`"money"`). |
| `money_updated` | `(new_amount: BigInt)` (the live `money` object) | add_money, add_bonus, spend, save_manager.gd:825 on load |
| `bank_updated` | `(new_amount: float)` | bank_deposit / bank_cash_out (gambling terminal "bank"), load |
| `new_high_combo` | `(combo_level:int)` | _on_combo_ended :1156 |
| `buff_updated` | `(buff_type, multiplier, time_remaining, duration)` | activate_buff and every frame while active (:671) |
| `buff_expired` | `(buff_type)` | _process |
| `panel_stack_changed` | `(count, capacity)` | panel rack push/pop/dump |
| `remote_channel_toggled`, `remote_tier_changed` | | remote tool |

### Currency fields
- `money: BigInt` (:7), `total_money_gained: BigInt` (:8), `total_money_spent: BigInt` (:9), `bank: float` (:11, a separate gambling bank),
  `total_bonus_earned: BigInt`, `combo_bonus_total: BigInt` (never incremented in the decompile), `money_per_product: {key: BigInt}`, `mining_bank: int`.
- `add_money(amount, product_type="")` (:840): `int(round(amount))`, then adds to money and total_money_gained, records the rate event
  "money" (plus "money_<type>"), emits `money_updated` and `stat_changed("total_money_gained", ...)`.
- `add_bonus(amount)` (:854): same, plus `total_bonus_earned` and the "bonus" rate. Emits **only** `money_updated` (no stat_changed).
- `can_afford(amount)` (:864), `spend(amount)` (:868): `money.sub_int`, `total_money_spent.add_int`, "spent" rate, `money_updated`.
- **Bypass**: golden_duck_statue.gd:209,388 does `GameState.money.add_int()` directly and emits only `stat_changed("money", money)`,
  not `money_updated`. A money watcher must listen to both, or poll.
- Other spend sites (not purchases): bottom_maw.gd:238 `spend(1000)` and :307 `spend(_maw_fine())` (player falls in the maw),
  camera_pivot.gd:102 `spend(100)`, fail_safe.gd:66 `spend(1)`.
- Rates: `record_rate_event(key, amount)` / `get_rate_per_min(key)` use a 60 s window. Keys: money, bonus, spent, craft, feed, plus `_<type>` variants.

**Set money safely (API):** assign a new BigInt built with `BigInt.from_string` to `GameState.money`, then emit
`money_updated` with it. This is what the load path does (save_manager.gd around 824-825). Using add_money instead inflates `total_money_gained`, which feeds the milestones
(`stat_threshold` on total_money_gained) and Steam achievements (`Steamworks._on_stat_changed`).

### Item tables (Dictionaries, mutable and live)
- `upgrades` (:192): sprint, slide, jump, crouch, throw, equip, luck, reset_rotation, snap_grid, prop_surf, panel_rack, remote_tier.
  Shape: `{level, prices[], enabled, tooltip[], enabled_levels[] (added at runtime)}`.
- `tools` (:273): box, broom, sponge, magnet, fan, panel, press, pickaxe, trading, remote, piston, spring_pad, vacuum, cannon,
  tractor_beam, gravity_inverter, orbit_tool, portal, auto_crafter, scheduler, qa_arm. Shape: `{level, prices[] (mostly 99999
  placeholders), buy_prices[] (per-tier purchase price), enabled, tooltip[], enabled_levels[] (size = buy_prices)}`.
- `toys` (:423): golf_club, bumper, stat_sign, feed_camera, feed_screen, basketball_hoop, gambling_{wodden,metal,plush,anomaly}_crate,
  speed_radar, bowling_pin_set, catapult, disco_ball, golden_duck_statue, stat_sign_big, feed_screen_big. Shape: `{level, buy_prices[1],
  enabled, tooltip}`. They have no `prices`, so no `enabled_levels`. Crate prices escalate on each buy (upgradeUI.gd:1546-1555),
  and those prices are saved.
- `products` (:528): **duck** (phase 1), **crown** (= cash register, phase 2), **bear** (= pinata/candy, phase 3), **effigy**
  (= anomaly, phase 4). Each has `{enabled, craft_speed{level,prices}, craft_value{enabled,level,prices}, auto_machine{enabled,level,prices}}`
  (plus per-sub enabled_levels).
- `combos` (:605): time_extension, time_stability, bonus_amplifier, chain_combos, diversity_tracker, rhythm_tracker, mega_combo.
- Counters keyed by product **instance type** (`duck, lucky_duck, cash_register, lucky_cash_register, pinata, lucky_pinata, candy,
  lucky_candy, anomaly, lucky_anomaly`): `products_crafted`, `products_autocrafted`, `products_consumed`, `money_per_product`.
- Effects read the level live everywhere (for example `GameState.upgrades["luck"]["level"]` in 10+ places), so setting `level` takes effect immediately.

### buy() (:1062)
`buy(category: "upgrades"|"tools"|"toys"|"products"|"combos", key, subkey="") -> bool`. It uses `dict.prices[level]`, and
`spend` + `level += 1` when affordable. Side effects: remote_tier → `apply_remote_tier()`; sprint+crouch → enables slide;
`Steamworks.check_consumerism()`. **Game bug**: for `products/*/auto_machine` it calls `WorkbenchSpawning.auto_machine_purchased(key, lvl)`
*before* the affordability check (:1083), so at level 0 the auto workbench spawns even if the purchase fails.
`buy()` does not check `enabled`. The UI does the gating.

### Lifecycle methods
- `start_game()` (:693): sets `is_game_started=true` and `game_start_time`. Called by player_controller.gd:133 at the end of world `_ready`
  (after any load).
- `reset_stats()` (:700) and `reset_all()` (:734): full wipe, including item tables (level/enabled/enabled_levels), the remote, buffs and secrets.
  Called on return to menu, credits, end-of-game and reload.
- `get_final_statistics()` (:1207), `calculate_efficiency_grade()` (:1174).
- `IS_DEMO = false` (const), `sandbox_mode: bool`.

## GameProgression (`scripts/game_progression.gd`, autoload)

- `signal phase_changed(new_phase: int)` (:3). `enum Phase {PHASE_0..PHASE_5}` (:9). `var current_phase` (:18), `elevator_exited`,
  `can_pause`, `ending_active`, `demo_end_triggered`.
- Meaning: 0 = elevator/pre-start, 1 = ducks, 2 = cash registers ("crown"), 3 = pinatas/candy ("bear"), 4 = anomalies ("effigy"),
  5 = ending (the maw consumes everything).
- `change_phase(new_phase)` (:139): returns early if equal. It sets `current_phase` **immediately**, then:
  - PHASE_1: `phase_changed.emit(1)` right away (:162).
  - PHASE_2/3/4: starts the async `_trigger_phase_N_transition()`. `phase_changed.emit(N)` happens at the **end** (:250, :404, :643),
    followed by `SaveManager.checkpoint_save("phase_N")`. In between, `current_phase` is already N, but listeners have not been told.
    Phase 3 manipulates `Engine.time_scale` (:684-740).
  - PHASE_5: `_trigger_ending_sequence()` (:1155). **No phase_changed.** It sets `SaveManager.autosave_enabled=false`,
    `save_locked=true` and `mark_game_completed()`, then runs the suction and `on_player_consumed()` (:1373), which changes the scene to
    `res://scenes/test_black_hole.tscn`. That path leads to fall_sequence.gd:195 → `MenuManager.open_end_game_menu()`.
- Callers of change_phase: hole.gd:233/238/243 (phase 2/3/4 when `target_radius >= PHASE_RADIUS_RANGES[p].max`), hole.gd:252 (5),
  game_progression.gd:117 (1, on first elevator exit, via `on_player_exit_elevator()` from elevator.gd:319), and pause_menu.gd:174
  `next_phase()` (debug only, gated by `UnlockManager.DEBUG`).
- `current_phase` is assigned directly (no signal) in main_menu.gd:232/647/661, save_manager.gd:209/435, pause_menu.gd:111,
  credits.gd:328 and end_of_game.gd:360.
- `setup_new_game()` (:177) spawns 10 starter crates. Called from main_menu.gd:726 only for a new game.
- `reset_run_state()` (:1593).
- Phase progress lives on the hole node (`scripts/hole.gd`, world node `Floor`, group **`saveable_hole`**): `phase_nutrition_total`,
  `target_radius`, `get_phase_progress() -> 0..1`, `NUTRITION_PER_RADIUS_UNIT`, `PHASE_RADIUS_RANGES`. It is fed by the
  `BottomMaw` node's `product_consumed(product_type, nutrition_value, body_id)` signal. **Gotcha:** game_progression.gd:1173/1231 and
  player_controller.gd look up group `"maw_hole"`, which no node is in, so those lookups return null.

## ComboSystem (`scripts/combo_system.gd`, autoload)

Signals (:3-10):
| Signal | Declared args | Actually emitted with |
|---|---|---|
| `combo_started` | (combo_level) | `(1)` :153 |
| `combo_updated` | (combo_level, time_remaining, next_bonus) | **2 args**: `(current_combo, progress 0..1)` :107 and :212. Handlers must take 2 params. |
| `combo_ended` | (combo_level, total_bonus) | :430, only if `current_combo > 1`. `total_bonus` is a float. |
| `combo_broken` | () | a 1-hit combo timing out (:436), or `reset_combo()` (:479, maw fall) |
| `chain_combo_triggered` | (chain_level, bonus) | end_combo when chain_combos is unlocked |
| `mega_combo_activated` | (multiplier) | |
| `diversity_bonus_triggered`, `rhythm_bonus_triggered` | | declared, not emitted in the core |

State: `current_combo`, `combo_timer`, `is_combo_active`, `total_bonus`, `current_chain_level`, `mega_combo_active`, `bowling_multiplier`,
`config{}`. API: `add_to_combo(product_type, item_value) -> int` (called by bottom_maw.gd:191 per feed; it also calls the main_camera screenshake),
`end_combo()`, `reset_combo()`, `reset_runtime()`, `get_combo_info()`, `get_chain_info()`, `is_feature_unlocked(name)` (= `GameState.combos[name].level > 0`).
The timer runs in `_physics_process`. Time uses `Time.get_ticks_msec()`.

**Payout path**: `combo_ended` → hud.gd `_on_combo_ended` → `show_result` → `GameState.add_bonus` (hud.gd around line 670).
`GameState._on_combo_ended` only updates max_combo/total_combos.

## UnlockManager (`scripts/unlock_manager.gd`, autoload)

- `signal milestone_unlocked(milestone_id: String, milestone_data: Dictionary)` (:4). Listener: upgradeUI.gd:313 (refreshes the "new" badges).
- `var unlocked_milestones: Array[String]` (:7). `var milestones: Dictionary` (:40-~1490): ~135 entries.
  Types: `stat_threshold` (102), `combined_stat_threshold` (15), `phase_reached` (14), `floor_product_count`, `group_all_flagged`,
  `group_flagged_count`, `state_flag`. Optional `requires:[ids]`, `min_phase`, `notification` (tr key), `category`.
  Action keys: `batch`, `unlock_upgrade|tool|toy|combo|product` (set `enabled=true`), and `unlock_*_level: [key, lvl]`
  (or `[product, subkey, lvl]`), which set `enabled_levels[lvl]=true`.
- Evaluation: `check_milestones()` (:1632) runs on every `GameState.stat_changed` (:1614), every `phase_changed` (:1624), and each 1 s while a
  floor milestone is pending. `_get_stat("a.b")` reads `GameState.get(a)[b]`.
- API: `force_unlock(id)` (:2259), `force_unlock_all()` (:2271), `debug_apply_all(force)` (:2310, also gives about $1e18, torch and UV),
  `is_unlocked(id)`, `get_progress(id)`, `is_tool_level_enabled(...)` and similar, `get_milestone_for_item(cat,key,lvl)`, `reset()`, `get_save_data()`,
  `load_save_data(arr)`.
- **Persistence model**: saves store `unlocked_milestones` plus each item's `level` and `enabled`. `enabled_levels` is **not saved**. It is rebuilt by
  replaying milestone actions in `load_save_data` (:2189), and unknown ids are skipped. So:
  - A mod that **adds milestones** at runtime (`UnlockManager.milestones["mod_x"] = {...}`) gets save persistence for free, provided it registers them
    before `SaveManager.load_game()` runs (world `_ready`). The loader autoload runs early enough.
  - A mod that pokes `enabled_levels` directly loses the change on the next load. Re-apply it on `SaveManager.save_loaded`.
  - Items a mod adds to GameState tables need `enabled_levels` made by hand (`_ensure_enabled_levels` runs at `_ready` and in reset/load).
- Refresh the terminal after a programmatic unlock: call `update_ui()` on the first node in group `UpgradeUI` (option_menu.gd does the same, around line 93).

## Upgrade terminal / UpgradeUI

- World node `UpgradeTerminal` (world.tscn:1614, groups interact/devourable_fixture/metal/terminal) uses script upgrade_terminal.gd.
  `interact()` (:163) → `UpgradeUI.show_menu()`. It duplicates the UI into its SubViewport as a **mirror** (`set_meta("is_mirror")`,
  removed from the group, PROCESS_MODE_DISABLED, :57-70). An extension's `_ready` must early-return when `has_meta("is_mirror")`, as upgradeUI.gd:290 does.
- `UpgradeUI` (Control, group **`UpgradeUI`**, scenes/upgrade_ui.tscn). `signal unseen_state_changed(has_unseen: bool)` (:256).
  `show_menu()` (:556) sets `MenuManager.upgrade_ui_displayed=true`. `hide_menu()` (:586). `update_ui()` (:607), `update_credits()`.
  `acknowledged_items` ("seen" badges, saved as `seen_items`).
- Purchase code paths (all are button `pressed` lambdas):
  - upgrades/products/combos: `_create_upgrade_row` (:1176) → `GameState.buy(category,key,subkey)` (:1196).
  - tools: `_create_tool_buy_row` (:1302) → `can_afford`, then `spend(buy_prices[level])`, `purchased_once[tool]=true`, `_spawn_tool_instance(tool, level)` (:1804).
    The spawn uses pool id `tool_<name>` or `tool_<name>_<lvl+1>`. press and trading instantiate scenes. The portal spawns 2.
  - toys: `_create_toy_buy_row` (:1509) → `spend(buy_prices[0])` → `_spawn_toy_instance` (:1863) via pool `toy_<name>`.
  - `_recall_tool` (recall mode) for RECALLABLE_TOOLS.
- There is no purchase signal. Strategies: (1) take_over_path on upgradeUI.gd and override `_spawn_tool_instance` / `_spawn_toy_instance`
  (called only after a successful buy). For upgrades, wrap the result by watching `level` changes. (2) Diff item `level`s and
  `total_money_spent` on `money_updated`. (3) Autoload-wrap `GameState.buy`.

## Session lifecycle (no dedicated signals)

| Event | Code path | Detect via |
|---|---|---|
| New game | main_menu.gd:263 `_on_new_game` → `set_active_slot`, `_pending_new_game=true` → `_launch_game("res://scenes/world.tscn")` (:670) → LoadingScreen → `_on_resources_loaded` (:717): pool/workbench/combo/progression `initialize(loaded)`, `GameState.loaded_resources = loaded`, `setup_new_game()`. Phase 0. On elevator exit → `change_phase(1)`. | `phase_changed(1)` while `GameState.total_play_time`≈0; or a scene change to world plus `SaveManager.should_load_on_ready==false` |
| Continue / load slot | main_menu.gd:219 `_on_load_pressed` → `reset_run_state`, `current_phase = peek_saved_phase()`, `should_load_on_ready=true` → world → player_controller.gd:109 `SaveManager.load_game()` → `apply_deferred_load()` → `GameState.start_game()` | **`SaveManager.save_loaded`** (emitted at the end of load_game, save_manager.gd:452). `phase_changed(saved_phase)` fires just before it. |
| In-game reload | `SaveManager.begin_load_reload()` (:163) | same |
| Sandbox | main_menu.gd:557+ (`GameState.sandbox_mode=true`, path `user://sandbox.save`; `apply_sandbox_grant` → `debug_apply_all(true)`) | `GameState.sandbox_mode` |
| Gameplay started | player_controller.gd:133 `GameState.start_game()` | poll `GameState.is_game_started` |
| Save | `SaveManager.save_game(force)` (:227) → `_save_game_impl` (:273). Autosave every 300 s; checkpoint saves at phases 2-4; `save_before_exit()` | no signal (poll `_last_save_tick`, or wrap) |
| Quit to menu | pause_menu.gd:101 `_return_to_main_menu` (reset_all, UnlockManager.reset, ComboSystem.reset_runtime, WorkbenchSpawning.reset, recycle pools, change scene to main_menu) | scene change to main_menu |
| Ending (main) | hole → PHASE_5 → `_trigger_ending_sequence` → black hole scene → fall_sequence.gd:195 `MenuManager.open_end_game_menu()` → end_of_game.gd `show_end_game(secret=false)` (:92; achievement END_MAIN, `mark_ending_seen("main")`) → `_on_main_menu_pressed` (:351; reset_all + credits) | `GameProgression.ending_active` becoming true; end_of_game node added |
| Ending (secret) | security_room.gd:435 `open_end_game_menu(true)` | same |
| Session complete screen | session_complete.gd `show_session_complete()` (:99) via `MenuManager.open_session_complete_menu()`. **Only called from `_trigger_demo_end`, so it is dead in the full game (`IS_DEMO=false`).** | n/a |

Scene changes can be observed through `get_tree().node_added`, or by polling `get_tree().current_scene.scene_file_path`.

## Small world objects in this list

- **cash_register.gd** (RigidBody3D, pool ids `cash_register` and `cash_register_luck`, groups cash_register/draggable/metal/product[/lucky]):
  this is the phase-2 *product*. `value:int` starts at `base_value=50` and is set again on `on_pool_spawn()`. Hits open the rack and drain value
  (`_drain_value`, `drain_per_unit=10`). At 0 it is destroyed/recycled. `on_whacked(force)` is the golf-club entry point. It awards no money itself.
  Money comes when it is fed to the maw (bottom_maw.gd computes `value * (crown.craft_value.level+1)` and so on). Spawned by automatic_cash_workbench.gd:572.
- **stat_sign.gd** (toy `toy_stat_sign` / `stat_sign_big`): `_pages: Array[{title:Callable, value:Callable}]`, built in `_build_pages()` (:128) and rebuilt on
  `phase_changed`. It polls every 0.5 s. It is a good read-only reference for derived stats (ROI, rates, phase progress via the `saveable_hole` group).
  To add pages, take_over_path and append in an overridden `_build_pages`.
- **shift_scheduler.gd** (tool `tool_scheduler`): this is a timer that toggles the nearest `press`/`toggle`/`remote` body (modes OFF/PULSE_ON/PULSE_OFF/SQUARE,
  interval and duration). It is **not** a work-shift/session scheduler. It has no global state.

## Steamworks coupling (important for cheats and the API)

- `Steamworks._on_stat_changed` unlocks achievements from `ACH_STAT` thresholds. `phase_changed` → `_on_phase_changed_for_achievements`
  (ACH_PHASE). `check_consumerism()` runs after each buy. Rich presence includes money and phase.
- `unlock_achievement(api)` (steamworks.gd:291) returns early when `_granted[api]` is true. An API "cheat mode" could pre-fill
  `Steamworks._granted` for all ACH ids so that no achievement fires while cheats are active.

## Recommended hook points

| Need | Hook | Strategy |
|---|---|---|
| Money changed | `GameState.money_updated(BigInt)` and `GameState.stat_changed("money", ...)` (golden duck bypass) | signal-connect. Clone the BigInt. Optional 0.25 s poll of `money.to_plain_string()` as a safety net. |
| Earned vs spent | `stat_changed("total_money_gained")`, diff of `total_money_spent` | signal-connect plus diff |
| Phase change | `GameProgression.phase_changed(int)` for the *settled* phase; poll `current_phase` for the *started* phase (2-4 and 5) | signal-connect plus poll (5 never emits) |
| Unlock | `UnlockManager.milestone_unlocked(id, data)` | signal-connect |
| Add unlock content | insert into `UnlockManager.milestones` from the loader, before load | data injection |
| Purchase | upgradeUI.gd `_spawn_tool_instance` / `_spawn_toy_instance`, and level diffs for buy() | script-extension (take_over_path) on upgradeUI.gd |
| Combo | `ComboSystem.combo_started/updated(2 args)/ended/broken` | signal-connect |
| Session start/load | `SaveManager.save_loaded`; `GameState.is_game_started` poll; `SceneTree.node_added` for world/main_menu | signal-connect plus poll |
| Session end | poll `GameProgression.ending_active`; node_added for the end_of_game CanvasLayer | poll / node-added |
| Phase progress | `get_first_node_in_group("saveable_hole").get_phase_progress()` | poll |
| Override GameState methods | override.cfg `GameState="*.../game_state_ext.gd"` (extends res://scripts/game_state.gd) | autoload-wrap (UNVERIFIED) |

## Multiplayer readiness notes

- All economy, unlock and phase state lives in single-instance autoload singletons. Assume one shared wallet (co-op), authoritative on the host.
  Clients should send purchase *requests*. The host runs `buy()`/`spend()` and replicates money as a string (BigInt is not a Variant type).
- The combo bonus is paid by the **HUD** (hud.gd:670). Replicating `combo_ended` to clients that have a HUD would double-pay, so payouts must be gated to the host.
- `ComboSystem.add_to_combo` grabs the local `main_camera` and shakes it. Combo state is global (not per player) and time-based (`Time.get_ticks_msec`).
- Phase transitions are long coroutines with global side effects: `Engine.time_scale` slow-mo (phase 3), audio, post-process, lights,
  `SaveManager.checkpoint_save`. Clients should run the cosmetic transition locally when told; only the host runs hole.gd's completion check.
- PHASE_5 changes the whole scene (`change_scene_to_packed(test_black_hole)`). That needs a coordinated scene change for all peers.
- `get_tree().paused = true` is used by save_game (briefly), menus, session_complete and end_of_game. In MP, pausing must become local-UI-only.
- `get_first_node_in_group("player")` appears in 18 places, which assumes one player.
- Milestones are deterministic from replicated stats, but it is safer to replicate `unlocked_milestones` and replay them through `_execute_action`
  (in the same way as `load_save_data`).
- Toy crate prices escalate per purchase (`toys[*].buy_prices[0]`). This is state that must be synced.
- Steam achievements fire locally from `stat_changed` and `phase_changed`. Mirrored stats on clients will grant clients achievements (probably desired).
- Saves are host-only. `SaveManager.save_data` keeps unknown top-level keys (it is replaced by the loaded dict and re-serialized whole), so a mod can stash
  `save_data["mod_xyz"]`. That key persists only once a save has been loaded or written in that session.
