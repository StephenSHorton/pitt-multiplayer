# Subsystem map: production-objects

Project P.I.T.T. v1.0.8 (Godot 4.7.2, GDScript). This covers the production and economy loop: products, how they spawn (object pool), how they are sold or consumed and how money is credited, and the workbenches.
All paths below are relative to `decomp/` (a local decompile, gitignored and not part of this repo). Line numbers are from the decompiled sources.

---

## 1. The loop in one picture

```
 player holds LMB on a workbench / auto-workbench timer / ProxyIntern / ShiftScheduler
            |
            v
 workbench.start_crafting() -> _process accumulates craft_progress -> craft_item()/_spawn_*()
            |      luck roll: randf()*100 <= GameState.upgrades.luck.level  -> "*_luck" pool
            v
 ObjectPoolManager.spawn(pool_id) ---> RigidBody3D product (groups: product + family [+ lucky])
            |   GameState.add_product(key) ; GameState.stat_changed("products_crafted.<key>", n)
            v
 physics play (tools, press, gambling crates, terminal, golden statue blessing ...)
            |
   +--------+-------------------+-----------------------------+----------------------------+
   v                            v                             v                            v
 BottomMaw (Area3D)       Press (hydraulic)           GamblingTerminal              GoldenDuckStatue
 GameState.add_money()    duck -> flat_duck,          sweep -> GameState.bank        bless: money.add_int
 product_consumed signal  pinata burst, register      roll -> bank_cash_out ->      (no money_updated!)
 -> Hole grows ->         deplete, crate break,       RecycleCube(recycle_value)
 GameProgression phases   tools/debris -> add_money   -> maw -> add_money
            |
            v
 ObjectPoolManager.recycle(body) 3 s later (bottom_maw.gd:280-286)
```

Product family keys are inconsistent across the code base. Keep this table to hand:

| Family | Pool ids | Node groups (from .tscn) | `GameState.products` key (upgrades) | `products_crafted`/`consumed` key | WorkbenchSpawning key |
|---|---|---|---|---|---|
| Duck | `duck`, `duck_luck`, `flat_duck`, `flat_duck_luck` | `draggable, duck, product` (+`lucky`) | `duck` | `duck` / `lucky_duck` | `duck` |
| Cash register ("crown") | `cash_register`, `cash_register_luck` | `cash_register, draggable, metal, product` (+`lucky`) | `crown` | `cash_register` / `lucky_cash_register` | `cash_register` |
| Pinata ("bear") | `pinata`, `pinata_luck` | `draggable, pinata, product, wood` (+`lucky`) | `bear` | `pinata` / `lucky_pinata` | `pinata` |
| Candy (pinata loot) | `candy`, `candy_luck` | `candy, draggable, product` (+`lucky`) | uses `bear` | `candy` / `lucky_candy` | none |
| Anomaly ("effigy") | `anomaly`, `anomaly_luck` | `anomaly, draggable, product` (+`luck`,`lucky`) | `effigy` | `anomaly` / `lucky_anomaly` | `anomaly` |

The mapping constants are `WorkbenchSpawning.PRODUCT_TO_WORKBENCH` / `WORKBENCH_TO_PRODUCT` (`scripts/workbench_spawning.gd:83-95`).

Base values (`value` export or scene override): duck 1 (`duck.gd:4`), flat duck 1, cash register `base_value` 50 (`cash_register.gd:13`; `value` is runtime and **drains** on impacts), pinata 10000 (scene override of `pinata.gd:11`), candy 1250 (scene override of `candy.gd:9`; **decays** over time), anomaly 1000000 scene `value`, but `on_pool_spawn` re-derives it from `reference_value` and grade (`anomaly.gd:489-531`).

---

## 2. ObjectPoolManager (autoload, `scripts/object_pool_manager.gd`)

* It is autoload #2 and is instantiated **before** our override.cfg loader. `take_over_path` cannot replace it.
* `_ready()` (l.407) creates a plain Node named `ObjectPools` and adds it to the tree root (deferred), so all pooled nodes live under **`/root/ObjectPools`** and persist across scene changes.
* `POOL_CONFIG` (l.26-387) maps pool_id to `{path, initial, max}`. There are 74 pools: products, tools (`tool_*`), toys (`toy_*`), gambling crates, `debris_chunk(_large)`, `recycle_cube`, `ore_*`, `keycard`, and so on.
* `initialize(loaded_resources: Dictionary)` (l.414) is **async** and runs only after the main menu's "Play" resource load: `main_menu.gd:717-719` `_on_resources_loaded` -> `await ObjectPoolManager.initialize(loaded)`, then `WorkbenchSpawning.initialize(loaded)`, then `ComboSystem/GameProgression.initialize`. It is guarded by `_initialized` and pre-instantiates `initial` copies per pool, deactivated.
* `class Pool { scene: PackedScene; max_size: int; available: Array[Node3D]; active: Array[Node3D] }` (l.393); `var _pools: Dictionary` (l.399). `SaveManager` reads `_pools` directly (`save_manager.gd:184, 662, 1237, 1250`).

### Public API (all synchronous except initialize)
| Method | Line | Notes |
|---|---|---|
| `spawn(pool_id: String, position := Vector3.ZERO, rotation := Vector3.ZERO) -> Node3D` | 481 | Pops from `available`, otherwise instantiates if `available+active < max`, otherwise `push_warning("exhausted")` and returns **null**. Sets `obj.pool_id = pool_id` if the property exists, calls `_activate`, appends to `active`. `rotation` is **global Euler radians** (assigned to `global_rotation`). |
| `recycle(obj: Node3D)` | 514 | Resolves the pool via `obj.pool_id` or a scan. **An object with no known pool gets `queue_free()`.** Clears portal locks and remote links and strips about 25 metas (`consumed`, `pending_maw_recycle`, `gambled`, `starter_crate`, bumper/spring/broom/orbit/piston/vacuum/cannon metas), restores gravity_scale/collision layers, then `_deactivate`. |
| `recycle_all_active()` | 614 | Used by credits / `game_progression.gd:1427`. |
| `count_loose_items()` / `purge_loose_items()` | 631 / 648 | Use `PURGE_POOL_IDS` (products + debris) and skip `PURGE_OWNER_METAS` and starter crates. |
| `is_pool_full(id)`, `get_active_units(id) -> Array[Node3D]` (a copy), `pool_headroom(id)`, `get_active_pool_id(obj)`, `active_count_for_family(prefix)`, `print_stats()` | 765-812 | Read-only helpers, safe for a mod API. |
| `static get_all_resource_paths()` | 439 | Used by the main menu to build the loading list. |

### Activation contract (what a correct spawn gets for free)
`_activate` (l.692): reparent to `/root/ObjectPools` if moved (vacuum/cannon reparent bodies), set global position and rotation, `visible = true`, `process_mode = PAUSABLE`, `remove_meta("consumed")`; for a RigidBody3D: `freeze=false`, `freeze_mode=KINEMATIC`, `sleeping=false`, zero velocities; then **`obj.on_pool_spawn()`** if present.
`_deactivate` (l.719): `visible=false`, `process_mode=DISABLED`, `position=(0,-10000,0)`, sleep, zero velocities, then **`obj.on_pool_recycle()`**.

`on_pool_spawn` implementations reset per-life state: `duck.gd:100` (spawn audio unless `SaveManager.is_loading`, metas `player_throw_time/position`), `flat_duck.gd:181`, `cash_register.gd:342` (value = base_value, rack), `pinata.gd:408`, `candy.gd:118` (decay clock), `anomaly.gd:489` (grade/value), `recycle_cube.gd:54`, `wodd_crate.gd:864`, `mining_ore.gd:59`, `debris.gd:442`, `golden_duck_statue.gd:563`, `box_carry_4.gd:279`, `box_cushion_3.gd:178`.

### Correct mod spawning recipe
```gdscript
var obj := ObjectPoolManager.spawn("duck_luck", pos, Vector3.ZERO)   # may be null!
if obj == null: return                                               # pool exhausted / unknown / not initialized
if obj is RigidBody3D:
    obj.apply_central_impulse(imp)          # or set linear_velocity AFTER spawn (spawn zeroes it)
var key := "lucky_duck"
GameState.add_product(key)                  # only if it should count as "crafted" (stats, achievements, rate)
var crafted: int = GameState.products_crafted[key]
GameState.stat_changed.emit("products_crafted.%s" % key, crafted)   # the same stat the benches emit
```
* Never `instantiate()` a product scene yourself. It would not be saved (`_save_object_pools` iterates pool.active only), it would be `queue_free`'d instead of pooled on recycle, purge would not see it, and achievement counts via `active_count_for_family` would miss it.
* To remove an object, call `ObjectPoolManager.recycle(obj)`. Set `obj.set_meta("consumed", true)` first if other systems could double-count it in the same frame (maw, ore processor and pinata all check it).
* Spawn only after `ObjectPoolManager._initialized == true` (it is a private var, but readable).
* Gambling loot sets `set_meta("gambled", true)`, which cuts nutrition to 1% (`bottom_maw.gd:44,210`) and is saved.
* Candy must have `tint_color` meta set and `_apply_tint()` called (`pinata.gd:363-366`).
* Anomaly: call `set_crude_source(src)` and then `set_grade(g)` (0 crude, 1 unstable, 2 pure) after spawn (`anomaly_workbench.gd:1506-1514`).
* RecycleCube: `cube.setup(value, edge, mass)` (`recycle_cube.gd:35`) is what makes the maw pay `recycle_value`.

---

## 3. Workbenches

### Instantiation
* **Manual duck workbench** is baked into `scenes/world.tscn:1492` as `/root/World/ManualDuckWorkbench` (instance of `manual_duck_workbench.tscn`, script `workbench.gd`, groups `devourable_fixture, metal, workbench` plus `interact`).
* All others are spawned by the **WorkbenchSpawning** autoload (`scripts/workbench_spawning.gd`, autoload #11, instantiated before our loader). Dicts `auto_workbenches` (duck, cash_register, pinata) and `manual_workbenches` (cash_register, pinata, anomaly) at l.11-81 hold `scene/position/spawned/instance` plus decal and light group names.
  * `spawn_manual_workbench(type, skip_ceremony=false)` l.217 and `spawn_auto_workbench(type, skip_ceremony=false)` l.163 call `scene.instantiate()` and `get_tree().current_scene.add_child()` at a fixed position, then wait 3 s for the lights. These are not pooled.
  * Triggers: `GameProgression.phase_changed` -> `_on_phase_changed` l.129 (phase>=2 cash, >=3 pinata, >=4 anomaly); `auto_machine_purchased(product_type, level)` l.147 (called on an upgrade purchase at level 0).
  * Persistence: `get_save_data()` l.272 / `load_save_data()` l.299 / `reset()` l.338. The auto entry stores `is_turned_on`.
* Groups: manual benches `workbench, interact, metal`; auto benches `automated_workbench, metal` (pinata also `interact`); the anomaly cauldron also self-adds `cauldron` (`anomaly_workbench.gd:324`).

### Driving
* `interact_ray.gd:467 handle_workbench_interaction()` is called while the crosshair is on a `workbench` and either `Input.is_action_pressed("lMouse")` or the `auto_craft` setting is on. It calls `start_crafting()` if `not is_crafting`, and on release `_stop_crafting_if_manual` -> `stop_crafting()` (skipped if meta `auto_crafter` is set).
* `proxy_intern.gd:181` (the "auto crafter" tool) sets meta `auto_crafter` on the bench and calls `start_crafting()`. `shift_scheduler.gd:249` calls `interact()`.
* Auto benches: `turn_on()/turn_off()` toggle `is_turned_on` (requires `GameState.products[k].auto_machine.level > 0`), and `_process` fires `start_crafting()` every `get_auto_craft_time()`.

### Craft completion (where products are born)
| Script | Completion fn (line) | Spawns | Stats |
|---|---|---|---|
| `workbench.gd` (manual duck) | `craft_item()` l.241 | `duck`/`duck_luck` at `global_position+(-0.25,1.5,0)`, sets velocity | `add_product("duck"/"lucky_duck")` + `stat_changed("products_crafted.*")` |
| `manual_cash_workbench.gd` | `_spawn_cash_register()` l.423 | `cash_register(_luck)` at `target_spawn_point`, impulse | same, key `cash_register`/`lucky_cash_register` |
| `manual_pinata_workbench.gd` | `_spawn_pinata()` l.657 | `pinata(_luck)` | same |
| `automatic_duck_workbench.gd` | `craft_item()` l.343 | `duck(_luck)` | also `products_autocrafted[*] += 1`, `stat_changed("products_autocrafted.*")` |
| `automatic_cash_workbench.gd` | `_spawn_cash_register()` l.567 | `cash_register(_luck)` | autocrafted |
| `automatic_pinata_workbench.gd` | `_spawn_pinata()` l.716 | `pinata(_luck)` | autocrafted |
| `anomaly_workbench.gd` (cauldron) | `_complete_ritual()` l.489 -> `_spawn_effigy(lucky_count, grade, from_gambled, crude_source)` l.1493 / `_spawn_keycard()` l.1580 | consumes 3 ingredients (groups duck/cash_register/pinata) via `ObjectPoolManager.recycle` (l.531); spawns `anomaly(_luck)` with `set_grade` | `add_product("anomaly"/"lucky_anomaly")` |

Craft time formulas use `GameState.products[<key>]["craft_speed"]["level"]` and `GameState.get_buff_multiplier(BUFF_CRAFT_SPEED)` (`workbench.gd:67`). The luck chance is `GameState.upgrades["luck"]["level"]` percent.
The single shared HUD progress bar is `get_first_node_in_group("WorkbenchProgress")` (`world.tscn:942`, HUD/TextureProgressBar).

**No workbench emits a signal.** The only observable events are `GameState.stat_changed("products_crafted.<key>" | "products_autocrafted.<key>" | "total_products", value)`, and these do not include the node.

The cauldron's ingredient state is held in `held_ingredients: {instance_id: type}`, `lucky_held`, `_committed_ingredients`, `_ritual_ingredient_ids: Array[int]`, `duck_count/crown_count/bear_count`, `is_ritualizing`, `cooldown_timer`, `min_purity` (`anomaly_workbench.gd:220-320`). It is keyed by instance_id.

---

## 4. Consumption and money crediting

### BottomMaw (`scripts/bottom_maw.gd`, node `/root/World/BottomMaw`, group `BottomMaw`; `world.tscn:1528`)
* `signal product_consumed(product_type: String, nutrition_value: int, body_id: int)` (l.11). This is **the** economy signal. It is emitted at l.219 for products (product_type is `duck|cash_register|pinata|candy|anomaly`, prefixed `lucky_` when lucky, `nutrition_value` = credited money, or 1% of it if gambled) and at l.141 for recycle cubes (`"recycle", 0, id`). `body_id` = `body.get_instance_id()`.
* Existing listeners: `hole.gd:77` (maw growth / phase progression), `basketball_hoop.gd:85`, `golf_club.gd:135`, `speed_radar.gd:105`, `spring_pad.gd:164` (bonus toys that look up `body_id`).
* `_on_body_entered(body)` (l.128) checks in order: skip `maw_inert`/`devourable_fixture` groups and `consumed`/`pending_maw_recycle` metas; group `recycle` -> `add_money(meta recycle_value)`; group `product` -> `set_meta("consumed")`, value = `body.value * (craft_value level+1)`, x10 if lucky, bumper multipliers, x`BUFF_PRODUCT_VALUE` -> **`GameState.add_money(base_value, product_type)`** (l.205), `products_consumed[type] += 1`, `ComboSystem.add_to_combo(type, body.value)` (l.191), rate events, long-range/ricochet feed stats; `debris` -> `GameState.spend(1000)`; tools/toys/gambling are re-dropped from the ToolTube at (0,15,18) (`_recycle` l.315); player -> respawn + `_maw_fine()`.
* `_handle_body_cleanup` (l.278) waits **3 s** (`create_timer(3)`) and then `ObjectPoolManager.recycle(body)`. During those 3 s the body still exists with meta `pending_maw_recycle`.
* The main menu scene also contains a BottomMaw (`main_menu.tscn`, bottom_maw.gd).

### GameState (autoload #5, `scripts/game_state.gd`)
* `money: BigInt` (l.7), `total_money_gained`, `total_money_spent`, `bank: float` (l.11, terminal bank), `mining_bank: int` (l.45).
* Signals: `money_updated(new_amount)` (l.15), `stat_changed(stat_name: String, new_value)` (l.13), `bank_updated(new_amount)` (l.16), `buff_updated/buff_expired` (l.158-159).
* `add_money(amount, product_type := "")` l.840 (emits `money_updated`, `stat_changed("total_money_gained")`), `add_bonus(amount)` l.854, `spend(amount)` l.868, `can_afford` l.864, `bank_deposit` l.877, `bank_cash_out(mult) -> int` l.885 (does NOT itself add money; the caller spawns a RecycleCube), `add_product(type)` l.961, `get_product_deposit_value(body)` l.892 (10% of maw value), `get_crate_deposit_value` l.1466, `get_tool_deposit_value` l.925.
* Other `add_money` callers: `press.gd:197` (crushed tools/debris), `erasable_text.gd:500`, `golf_club.gd:985`. `add_bonus` callers: combos (`hud.gd:670`), basketball_hoop, speed_radar, spring_pad.
* **Bypass (gotcha):** `golden_duck_statue.gd:209` and `:388` do `GameState.money.add_int()` directly and emit only `stat_changed("money", ...)`, **not** `money_updated`. `ore_processor.gd:104` and `mining_ore.gd:146` do `GameState.mining_bank += ...` and emit no signal at all.

### Other sinks
* **Press** (`scripts/press.gd`, spawned by `upgradeUI._spawn_tool_instance("press")` l.1804, group `press`): `process_crushed_items()` l.119. A cash register is `_on_depleted()`, a pinata is `_burst()`, a duck is `replace_with_flat_product()` l.238 (recycle, then spawn `flat_duck(_luck)` and `flatten_mesh_world_y()` one frame later), a gambling crate is `break_crate()`, debris adds +1000, tools are valued with `calculate_tool_value`. Anomaly fuel duplicates via `_spawn_pending_anomalies()` l.202.
* **Gambling/Trading terminal** (`scripts/gambling_terminal.gd`, `scenes/gambling_terminal.tscn`, group `trading_terminal`): `sweep_products()` l.128 / `sweep_tools()` l.132 -> `_sweep` -> `_arc_to_intake` (adds group `terminal_pull`) -> `_bank_and_despawn` l.442 -> `GameState.bank_deposit(v)` + `_despawn` (recycle). `roll_or_stop()` l.136 -> `_resolve(mult)` l.191 -> `GameState.bank_cash_out(mult)` -> `_spawn_recycle_cube(payout)` l.716. The cube pays out when fed to the maw.
* **Golden duck statue** (`scripts/golden_duck_statue.gd`, pool `toy_golden_duck_statue`): blesses products entering its area (`_on_bless_body_entered` l.191, per-body cooldown keyed by instance_id); `interact()` l.376 pets it for a reward.
* **Gambling crates** (`wodd_crate.gd`, `class_name GamblingCrate`; `metal_crate.gd`, `plush_crate.gd`, `anomaly_crate.gd` override only `_init` fields): `break_crate()` l.191 (on impact >= `break_threshold` or cumulative damage, from the press, or `on_whacked` l.916) is async (`await _play_opening_sequence`). It then calls `_spawn_loot` -> `_spawn_products(count, lucky)` l.618 (meta `gambled`), `_spawn_tool(name)` l.660, `_apply_buff()` -> `GameState.activate_buff` l.710, then recycles itself. The starter crates come from `GameProgression.setup_new_game()` (`game_progression.gd:177-182`, meta `starter_crate`).
* **Self-destructing products** (they recycle themselves from physics callbacks): `pinata._burst()` l.159 (spawns 1 to N `candy`/`candy_luck` in `_spawn_candies` l.303), `cash_register._on_depleted()` l.216 (value drained by rack impacts `_drain_value` l.197), `candy._expire()` l.228 (decay timer).
* **Mining**: `minable_block.gd` (StaticBody3D in `mining_room.tscn`, groups `minable`, `saveable_block`; `take_hit(amount)` l.129; `_break_block` l.205 -> `_spawn_ore()` l.255 spawns `ore_pool_id`); `mining_ore.gd` (pool `ore_*`, `ore_value`); `ore_processor.gd` (group `ore_processor`, `_on_intake_body_entered` l.86 -> `mining_bank += ore_value`, recycle deferred; it also buys pickaxe tiers and the UV lamp).
* **Debris** (`debris.gd`, pools `debris_chunk(_large)`, spawned by `game_progression.gd:778/1122` as hazards): destroys tools on impact during `destruction_window`, then recycles them and respawns them through the tube (`_respawn_tool_via_tube` l.328). Feeding debris to the maw costs 1000. `SaveManager.RETIRED_POOL_IDS` excludes debris from loading.
* **Hole** (`hole.gd`, `/root/World/Floor`, CSGCombiner3D, group `saveable_hole`): `_on_product_consumed` l.167 accumulates `phase_nutrition_total` (scaled by `PRODUCT_NUTRITION_SCALE`), `_calculate_target_radius` l.180, `_check_phase_completion` l.228 -> `GameProgression.change_phase()`. This is the game's progression driver.
* **Cosmetic only (no gameplay):** `product_stream.gd` (`class_name ProductStream`, `@tool` MultiMesh along a Path3D), `stream_spawner.gd` (used only by `test_black_hole.tscn`), `falling_object.gd` / `falling_object_manager.gd` (main-menu falling ducks; uses `instantiate()`, not the pool). `crate.gd`, `box.gd`, `box_carry_2.gd`, `box_cushion_3.gd`, `box_carry_4.gd` are tool "transport" boxes (pools `tool_box*`). The cushion boxes add group `on_cushion` to bodies inside them, which suppresses pinata burst and register drain.

---

## 5. Hook points (best strategy first)

| # | Target | Strategy | Why / caveats |
|---|---|---|---|
| H1 | `BottomMaw.product_consumed(product_type, nutrition_value, body_id)` | **signal-connect**. Find the node via `get_tree().node_added` (group `BottomMaw`, groups exist before enter_tree) or `get_first_node_in_group("BottomMaw")` after scene change. | This is the canonical "sold" event. `body_id` is an instance id of a pooled node that will be reused, so resolve it immediately with `instance_from_id`. It does not fire for debris (spend) or tools. |
| H2 | `BottomMaw.body_entered` (Area3D) | signal-connect (our handler runs after the maw's own, which was connected in `_ready`) | Gives the actual body plus metas (`consumed` already set). Use for debris, tools, players and recycle cubes. |
| H3 | `GameState.money_updated`, `stat_changed`, `bank_updated`, `buff_updated` | signal-connect (autoload already exists when our autoload runs) | `stat_changed("products_crafted.X")` = crafted event (no node). `stat_changed("money")` is needed to catch the golden statue bypass. There is no signal for `mining_bank`. |
| H4 | `ObjectPoolManager.spawn/recycle` | **autoload-wrap**: in our autoload `_ready`, `var c = ObjectPoolManager._container; ObjectPoolManager.set_script(load("res://.../pool_wrap.gd"))` where pool_wrap `extends "res://scripts/object_pool_manager.gd"`, overrides `spawn()`/`recycle()` (call `super`, then emit `object_spawned(obj, pool_id)` / `object_recycled(obj, pool_id)`), then restore `_container = c`. | `take_over_path` is impossible because the autoload is already instantiated. At our autoload time `initialize()` has not run yet (it runs after the menu), so only `_container` needs restoring (`_pools` is empty and `_initialized` is false). Node identity is preserved, so the `ObjectPoolManager` global still points to it. Verify that `set_script` on a node in the tree keeps `_ready` from re-running (it should). The fallback is polling `pool.active` sizes each physics frame. |
| H5 | Product scripts `on_pool_spawn` / `on_pool_recycle` (`duck.gd`, `lucky_duck.gd`, `flat_duck*.gd`, `cash_register.gd`, `pinata.gd`, `candy.gd`, `anomaly.gd`, `recycle_cube.gd`, `wodd_crate.gd` …) | script-extension via `take_over_path` | Works: product scenes are loaded by `LoadingScreen` only after "Play" (`main_menu.gd:688-713`), well after our autoload, and no autoload preloads them (checked: there is no `preload` of scenes/scripts in any autoload; ResourceWarmer loads only fonts, audio and menus). The extension must `extends "res://scripts/duck.gd"` and keep `class_name` scripts in mind (`GamblingCrate` is extended by metal/plush/anomaly crates, so taking over `wodd_crate.gd` changes their base too). `duck.gd` has no `on_pool_recycle`, so add one. |
| H6 | Workbench craft completion: `workbench.gd:craft_item`, `manual_cash_workbench.gd:_spawn_cash_register`, `manual_pinata_workbench.gd:_spawn_pinata`, `automatic_*:craft_item/_spawn_*`, `anomaly_workbench.gd:_spawn_effigy/_complete_ritual` | script-extension via `take_over_path` (override, call `super`, emit `product_crafted(bench, node, key)`) | Benches load with world.tscn / WorkbenchSpawning's `initialize(loaded)`, so after our loader. To get the spawned node, combine with H4 (the last spawned object of the right pool in the same frame) because the craft functions do not return it. |
| H7 | `start_crafting()/stop_crafting()` on benches; `turn_on()/turn_off()` on auto benches | script-extension (same scripts as H6) | Needed to intercept player input for netcode (client -> host request). |
| H8 | `WorkbenchSpawning.spawn_auto_workbench/spawn_manual_workbench` | node-added (filter groups `workbench`/`automated_workbench`/`cauldron`) or poll `WorkbenchSpawning.auto_workbenches[k].instance` | Autoload, so take_over_path is impossible; set_script wrap is possible but unnecessary. |
| H9 | `GameProgression.phase_changed(new_phase:int)` | signal-connect | Drives bench unlocks and hole radius. |
| H10 | `gambling_terminal.gd`, `press.gd`, `golden_duck_statue.gd`, `ore_processor.gd`, `minable_block.gd`, `wodd_crate.gd:break_crate`, `pinata.gd:_burst`, `cash_register.gd:_on_depleted`, `candy.gd:_expire` | script-extension via `take_over_path` | No signals. Needed for host authority (clients must not run these locally). |
| H11 | `hole.gd` | signal-connect to the same `product_consumed`; read `phase_nutrition_total`, `current_radius`, `get_phase_progress()` | `rollback_to_safe_margin()` and `sandbox_rollback_nutrition()` exist for sandbox use. |
| H12 | `SaveManager.save_loaded` signal (`save_manager.gd:4`); `SaveManager.is_loading` | signal-connect / read | Pool objects are re-spawned during load (`_load_object_pools` l.1034) with `is_loading=true`. A mod API should suppress "spawned" events for remote replication while loading, or treat them as a snapshot. |

---

## 6. Entity identity (for the multiplayer project)

* `get_instance_id()` is used everywhere as an identity key (maw `body_id`, cauldron `held_ingredients`, statue `_bless_cooldowns`, terminal `_claimed`). It is **not stable**: pooled nodes are reused across lives, and ids differ per peer.
* Pooled node names under `/root/ObjectPools` are auto-generated by `add_child` and are not deterministic between peers, so NodePaths cannot be used for RPC routing.
* Recommended: the host assigns a monotonically increasing `net_id` at spawn (H4 wrapper) and stores it as meta `pitt_net_id`, with a registry `{net_id: node}`. On recycle, remove it from the registry and clear the meta (recycle does not clear unknown metas, so clear ours explicitly). Replicate as `(net_id, pool_id, transform, velocity, extra_state)`.
* Per-entity extra state that must be replicated: `value` (cash_register drain, candy decay, anomaly grade), metas `gambled`, `tint_color`, `crude_source`, `starter_crate`, `consumed`, `pending_maw_recycle`, `panel_ricochet`, `bumper_bounce_count`, `player_throw_time/position`; flat duck `is_flattened`; pinata `cumulative_damage`; crate `cumulative_damage/is_opening`. The save format in `_save_object_pools` (`save_manager.gd:657-795`) is a ready-made per-object snapshot schema to reuse for late-join sync.
* Static or singleton entities need deterministic keys: the manual duck bench `/root/World/ManualDuckWorkbench`; benches by WorkbenchSpawning key (`auto:duck`, `manual:anomaly`, …); `BottomMaw`; `Floor` (hole); press (group `press`, at most one, `SaveManager.is_press_spawned`); terminal (group `trading_terminal`, `is_trading_terminal_spawned`); ore processor (group `ore_processor`); minable blocks via `get_save_data().block_id` = `"<parent>_<name>"` (`minable_block.gd:295`).

---

## 7. Gotchas

1. `ObjectPoolManager.spawn` returns null when the pool is exhausted (`max`), when the pool_id is unknown, or before `initialize()` has run (main menu). Always null-check.
2. `spawn()` zeroes velocity and unfreezes in `_activate`, so set velocity and impulses after spawn. `rotation` is a global Euler in radians.
3. `recycle()` on an object without a known pool does `queue_free()`. Never recycle scene-baked nodes such as the workbench, maw or press.
4. The maw recycles 3 s after contact. During that window the body is alive with meta `pending_maw_recycle` and still active in the pool (so `count`/`get_active_units` include it).
5. Product family naming mismatch: `crown`=cash_register, `bear`=pinata/candy, `effigy`=anomaly. Groups `crown`, `bear` and `effigy` are checked in code but are not on the shipped scenes (scenes use `cash_register`, `pinata`, `anomaly`).
6. The anomaly script default `pool_id = "effigy"` (`anomaly.gd:32`) is overridden by the scene/spawn (`"anomaly"`). Rely on `spawn()` setting `pool_id`.
7. `golden_duck_statue` credits money without `money_updated`, and `mining_bank` changes are silent.
8. The cash register value drains and candy value decays, so "value" is time- and physics-dependent. Read `body.value` at consumption time rather than at spawn.
9. `on_cushion` group / `terminal_pull` group / meta `consumed` suppress bursting and draining. A mod that moves products should respect them.
10. `SaveManager.is_loading` mutes spawn audio and sets `collision_cooldown`. Mod spawns during load should respect it.
11. Flat ducks from the press are not counted in `products_crafted`.
12. The single HUD progress bar (`WorkbenchProgress`) and `main_camera` group are singletons. Workbench code assumes one local player.
13. Saves: `SaveManager.SAVE_FILE_PATH = "user://savegame.save"` (slot 0), `user://savegame_<n+1>.save` for slot n>=1 (`slot_path` l.1809), `user://sandbox.save`, `user://profile.cfg`. They are **encrypted** JSON with a password embedded in the game (`SAVE_PASSWORD`, `IS_ENCRYPTED`, l.14-15) and written via `.tmp`/`.bak`. `user://` = `%APPDATA%/Godot/app_userdata/Project P.I.T.T`. It currently has no save file (fresh install), and `steam_autocloud.vdf` is present, so Steam Auto-Cloud syncs this folder (no ISteamRemoteStorage calls in scripts).
14. Taking over `wodd_crate.gd` (`class_name GamblingCrate`) affects metal/plush/anomaly crates, which `extends GamblingCrate`. Make sure the global class cache resolves to the taken-over script, or take over every subclass too.

---

## 8. Multiplayer notes (design only, no netcode now)

* **Authority:** every economy mutation runs locally from physics callbacks (`_on_body_entered` in the maw, pinata, register, crate, terminal collector, statue, ore processor). In MP the host must be the only peer running them. On clients these product bodies should be **kinematic/frozen puppets** driven by host snapshots (or have their scripts' gameplay branches gated by an `is_host` check via script-extension), otherwise a client's maw would double-credit money.
* **Determinism: none.** `randf()` is used for luck rolls, launch offsets, candy counts and crate rarity, and the physics is non-deterministic, so lockstep is impossible. Use a host-authoritative state sync.
* **Shared economy:** `GameState.money`, upgrades, `products_*` stats, buffs and `bank` are single globals, a natural shared co-op wallet. The host broadcasts `money_updated`/`stat_changed`, and clients apply them without re-running logic. Achievements (`steamworks.gd:327` listens to `stat_changed`) would fire on every client applying stats, so decide per-player or host-only.
* **Input to request:** workbench crafting (`interact_ray.gd:467`), auto bench toggles, terminal levers/roll (`sweep_products/sweep_tools/roll_or_stop`), statue pet (`interact`), cauldron purity tune (`scroll_tune_up/down`) must become client->host RPC requests.
* **Pools:** both peers must have identical POOL_CONFIG (same game build). Client mirrors should spawn through the pool too (cheap, and correct `on_pool_spawn` visuals) under host-assigned `net_id`. Watch the max sizes (`duck` 3000, `candy` 10000).
* **Bandwidth:** thousands of active RigidBodies is possible (candy bursts, duck spam). Plan for interest management / sleeping-body suppression and quantised transforms.
* **Singletons that assume one player:** `main_camera` group (picked_object, drop_object, release_held_object), HUD `WorkbenchProgress`, the `player` group (maw respawn and fine), `interact_ray`, and the ToolTube drop position.
* **Scene lifecycle:** pools live at `/root/ObjectPools` across scene changes; benches and world fixtures live under `current_scene` (`/root/World`). `SaveManager.begin_load_reload` recycles all active objects, which is a good "resync" point.
* GodotSteam (`SteamMultiplayerPeer`, lobbies, `SteamNetworkingMessages`) is available in the bundled GDExtension for the transport.
