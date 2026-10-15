# Subsystem map: world-physics

Covers world machines/puzzles, tool/toy physics bodies, level structure, and the performance/audio/post-process managers in Project P.I.T.T. v1.0.8 (Godot 4.7.2, GDScript).
Source: a local decompile in `decomp/` (gitignored, not part of this repo). Paths below are relative to `decomp/`. Line numbers are from the decompiled files.

---

## 1. Engine / physics configuration

`project.godot`:

- `3d/physics_engine="Jolt Physics"`, `common/physics_interpolation=true` (lines 180-187). Jolt settings: `generate_all_kinematic_contacts=true`, `speculative_contact_distance=0.05`.
- There is no `physics_ticks_per_second` entry, so the default is 60 Hz. **But `PerformanceMonitor` changes it at runtime** (see section 6).
- Physics layers: 1 `environment`, 2 `player`, 3 `dragObject`, 4 `Products`, 9 `PlayerContainment`, 20 `tempPanels`.
- No game script calls `reset_physics_interpolation()`. Teleports (portal, fail-safe, loop reset) will visibly interpolate for one tick.

## 2. Level structure

Only one gameplay scene: `res://scenes/world.tscn` (root `World`, Node3D, 428 nodes). It is reached from `main_menu.gd` via `_launch_game("res://scenes/world.tscn")` (lines 236/282/651/663) → `loading_screen.gd:220 change_scene_to_packed`. `save_manager.gd:214` also does `change_scene_to_file("res://scenes/world.tscn")`.

Key top-level nodes under `/root/World` (these are the stable anchors for a mod; pooled objects are NOT here):

| Node | Type / script | Groups |
|---|---|---|
| `WorldEnvironment` | WorldEnvironment | `WorldEnvironment` |
| `HUD` (+`HUD/PlayerHUD`) | CanvasLayer, `hud.gd` | `HUD`, `PlayerHUD` |
| `Floor` | CSGCombiner3D, `hole.gd` (the growing maw hole; `Floor/WakeArea`) | `saveable_hole` |
| `PlayerController` | CharacterBody3D, `player_controller.gd` | `player` |
| `PlayerController/CameraPivot/MainCamera` | Camera3D, `main_camera.gd` | `head` (pivot), `main_camera` |
| `BottomMaw` | Area3D, `bottom_maw.gd` | `BottomMaw` |
| `FailSafe`, `FailSafe2..4` | Area3D, `fail_safe.gd` | |
| `ToolTube` (`TubeTool1..7`) | `tool_tube.gd` | `ToolTube` |
| `MawLight` | SpotLight3D | `maw_light` |
| `room_lights/*` | lights per unlock | `room_lights`, `light1`, `light_auto_cash`, ... |
| `Elevator` | `elevator.tscn` / `elevator.gd` | `security_elevator` (code) |
| `Pillars/Pillar*` | 12x `camera_pivot.tscn` (security cams, `camera_id` "1".."8"...) | `security_camera`, `saveable_camera`, `destructible` |
| `InterdictionArea3D` (+`Timer`) | `interdiction_area_3d.gd` | |
| `AlarmLight/AlarmLight1..12` | `alarm_light.gd` | `alarm_lights` |
| `AlarmAudio3D..4` | | `alarm_audio` |
| `UpperAreaGates` | `upper_area_gates.tscn` (3 gate puzzles) | `vertical_gate`, `saveable_gate`, `gate_shutters` |
| `Fuse`, `Fuse2`, `Fuse3` | `fuse.tscn` (`fuse_id` fuse_1/2/3) | `fuse`, `fuse_pickup`, `interactable` |
| `LoopPuzzle` | `loop_puzzle.tscn` (`loop_puzzle.gd`, child `LoopReveal`) | `loop_puzzle` |
| `MiningRoom` | `mining_room.tscn` (minable blocks, ore processor) | `saveable_block`, `ore_processor` |
| `CardReader` | `card_reader.gd` | |
| `SecurityKeypad` | `security_keypad.gd` | `security_keypad` |
| `SecurityRoom` (+`Dock`) | `security_room.gd` | `security_room` |
| `ScreenQuad` | MeshInstance3D, post-process shader | `retro` |
| `UpgradeTerminal`, `ManualDuckWorkbench` | | `interact` |

Fixtures spawned at runtime into `current_scene` (not pooled):

- **Press**: `upgradeUI.gd:1805-1817` instantiates `res://scenes/press.tscn` at `Vector3(9.0, 0.01, 21.0)`, `SaveManager.mark_press_spawn_in_flight()`, `add_child.call_deferred`. Only one allowed (`SaveManager.is_press_already_in_world_or_pending()`).
- **Trading terminal**: same pattern at `Vector3(11, 0.5, 13)`.
- **Bowling pin set**: `upgradeUI.gd:1865` at `Vector3(15, 0.01, 30)`.
- **Workbenches**: `workbench_spawning.gd` (WorkbenchSpawning autoload).

### Pooled objects (all tools/toys/products)

`ObjectPoolManager` (autoload) creates `Node "ObjectPools"` under `/root` (`object_pool_manager.gd:407-411`, `add_child.call_deferred`). **All pooled objects live at `/root/ObjectPools/<node>`, a sibling of `/root/World`**, not inside the world scene.

- `spawn(pool_id, position, rotation)` (`:481`) → `_activate` (`:692`): reparent to container, set `visible=true`, `process_mode=PAUSABLE`, `freeze=false`, `freeze_mode=KINEMATIC`, `sleeping=false`, zero velocities, then `on_pool_spawn()`.
- `recycle(obj)` (`:514`) → `_deactivate` (`:719`): `visible=false`, `process_mode=DISABLED`, `position=(0,-10000,0)`, `sleeping=true`, then `on_pool_recycle()`.
- `spawn` overwrites `obj.pool_id` with the requested key. The `@export pool_id` defaults in scripts do **not** always match POOL_CONFIG keys: roomba.gd says `"tool_roomba"` but the pool is `tool_broom_3`; feed_camera.gd says `"tool_feed_camera"` but the pool is `toy_feed_camera`; orbit_tool.gd says `"tool_orbit"` but the pool is `tool_orbit_tool`. **Always read `obj.pool_id` after spawn.**
- Objects get reparented in several places: equip puts them under the camera (`equip()` → `camera.add_child(self)`); the cannon puts them under `<cannon>/CannonStorage`; `cannon.fire()` puts them under `current_scene`; `unequip(world, pos)` puts them under the passed world node. **Node paths of tools are unstable**, so netcode needs its own IDs.
- Relevant pool caps (initial/max): `tool_portal 0/2`, `tool_auto_crafter 1/1`, `tool_scheduler 3/3`, `toy_speed_radar 1/1`, `toy_disco_ball 0/1`, `toy_golden_duck_statue 0/1`, `tool_qa_arm 2/4`, `toy_feed_camera 4/5`, `tool_piston 5/100`, `tool_cannon 3/100`, `duck 200/3000`, `candy 100/10000`.

Tool purchase spawn path: `upgradeUI.gd:1800 _spawn_tool_instance(tool_name, level)` → pool id `tool_<name>_<level+1>` (or `tool_<name>` at level 0). The portal spawns two (`portal_a`, `portal_b`). Then `_initialize_spawn_physics(instance)`.

### Scene root groups (tool scenes)

| Scene | Root | Script | Groups |
|---|---|---|---|
| piston / piston2 / piston3 | RigidBody3D | piston.gd / piston_2.gd / piston_3.gd | draggable, interact, metal, piston, toggle, tool |
| cannon / cannon2 | RigidBody3D | cannon.gd / cannon_2.gd | cannon, draggable, equipable, interact, metal, placable, toggle, tool |
| fan / fan2 / fan_3 | RigidBody3D | fan.gd (both) / fan_3.gd | draggable, equipable, fan, metal, toggle, tool |
| spring_pad / spring_pad2 | RigidBody3D | spring_pad.gd / spring_pad_2.gd | draggable, metal, placable, spring_pad, tool |
| bumper | RigidBody3D | bumper.gd | bumper, draggable, interact, metal, **toy** |
| gravity_inverter | RigidBody3D | gravity_inverter.gd | draggable, gravity_inverter, interact, metal, toggle, tool |
| portal | RigidBody3D | portal.gd | draggable, metal, portal, tool |
| roomba | RigidBody3D | roomba.gd | draggable, metal, placable, roomba, toggle, tool |
| qa_arm | RigidBody3D | qa_arm.gd | draggable, interact, metal, qa_arm, toggle, tool |
| proxy_intern | RigidBody3D | proxy_intern.gd | draggable, interact, proxy_intern, toggle, tool |
| feed_camera / feed_screen | RigidBody3D | feed_camera.gd / feed_screen.gd | feed_camera / feed_screen(+interact, placable, toggle), tool |
| tractor_beam, magnet(2), vacuum(2), orbit_tool, shift_scheduler, remote, broom, sponge | RigidBody3D | ... | tool (+toggle for most) |
| press | StaticBody3D | press.gd | devourable_fixture, metal (+`interact`, `press` added in `_ready`) |
| fuse / keycard | RigidBody3D | fuse.gd / keycard.gd | draggable, fuse / keycard, interact |

The `toggle` group feeds `GameState.update_toggle_tool_count()` (`game_state.gd:1316`), which counts nodes in `toggle` whose `is_active == true`.

## 3. The common tool "duck-typed interface"

None of these are formal; callers use `has_method`/`in` checks. A mod tool that implements them gets picked up by the save system, remote, scheduler, fail-safe, portal, press and so on.

| Member | Implemented by | Called by |
|---|---|---|
| `interact()` | piston, cannon, fan, fan_3, gravity_inverter, press, roomba, qa_arm, proxy_intern, keypad_button, loop_button, feed_screen, shift_scheduler, ... | interact_ray / main_camera (player subsystem) |
| `remote_toggle(on: bool)` | cannon (fires if on), fan, fan_3, gravity_inverter, magnet, orbit_tool, piston, proxy_intern, qa_arm, roomba, shift_scheduler, tractor_beam, vacuum(_2), remote | `GameState.apply_remote_tool_state` (`game_state.gd:1360`), shift_scheduler `_apply_state` (`:254`), fail_safe (`:21`) |
| `remote_pulse()` | cannon (`:523`) | scheduler |
| `place()` / `unplace()` | most tools | main_camera on drop/grab. With `GameState.upgrades["sticky tools"]["level"] > 0` and a non-product contact, they set `placed=true`, `freeze_mode=STATIC`, `freeze=true`. Otherwise `freeze=false`. Roomba: `placed=true` only, no freeze (`roomba.gd:647`). |
| `equip(camera)` / `unequip(world, drop_pos)` | broom, cannon, fan, fan_3, golf_club, gravity_inverter, orbit_tool, pickaxe, portal, remote, speed_radar, tractor_beam, vacuum | main_camera |
| `on_pool_spawn()` / `on_pool_recycle()` | all pooled | ObjectPoolManager |
| `object_name()`, `set_highlight(active, grabbed)`, `get_reset_basis()` | all | interact ray / HUD |
| fields `placed`, `is_active`, `is_equipped`, `pool_id` | | SaveManager `_save_pools` (`save_manager.gd:680-795`) serializes `position`, `rotation`, `visible`, `is_frozen`, velocities, `is_placed` / `panel_state`, `is_active`, metas, `get_bag_save_data()`, `get_queue_save_data()` (cannon), `get_piston_save_data()`, `scheduler_mode/interval/duration`, `camera_id`, `watched_camera_id`, `current_channel`, `_is_repell()`, `remote_channel` |
| `on_portal_teleport(source, dest)` | **no game script**: free hook | `portal_pair_manager.gd:286` |
| `on_whacked(force)` | (optional) | `qa_arm.gd _whack` |
| `recover_to_home()` | uv_lamp | fail_safe.gd:12 |

Metas used as cross-system flags (all on the body): `in_cannon_barrel`, `cannon_orig_layer/mask`, `piston_rider`, `piston_rider_freeze_mode`, `rider_pending_frame`, `fan_force_frame/accum`, `orbit_releaser_active`, `orbit_orig_freeze(_mode)`, `orbit_in_orbit`, `in_vacuum_bag`, `consumed`, `pending_maw_recycle`, `slotted`, `spring_pad_launch_count/time/mult`, `spring_pad_2_chain_count/time`, `bumper_bounce_count`, `player_throw_time/position`, `tint_color`, `auto_crafter` (on workbenches).

## 4. World machines: per-script map

### Portals: `scripts/portal.gd` (RigidBody3D, pool `tool_portal`) + `scripts/portal_pair_manager.gd` (autoload `PortalPairManager`)

- `PortalPairManager._portals` holds at most 2 portals. A third registration drops the oldest (`register_portal` `:64`). `is_pair_active()` (`:96`) requires both to be valid and not `is_equipped`.
- Crossing detection runs in `portal._physics_process` (`:109`) → `_process_near_bodies` (`:193`). It uses `NearArea`/`TriggerZone` overlaps and per-body side state (`_side_state`, `_prev_local`, `_contact_suppress`), and adds collision exceptions for bodies in front (`_reconcile_exceptions` `:317`).
- `_do_teleport(body)` (`:356`) → `PortalPairManager.teleport_body(body, source)` (`:259`):
  - RigidBody: `_teleport_rigid_body` (`:303`) mirrors the pose, uses `PhysicsServer3D.body_test_motion` for a safe exit (`_find_safe_exit_origin` `:220`), rotates the velocities, and clamps speed to `MAX_EXIT_SPEED=40`.
  - CharacterBody: yaw-only rotation, then `body.velocity` is set.
  - Then `source.clear_crossing_state`, `dest.seed_after_teleport`, `body.on_portal_teleport(source, dest)` if present, and `_lock_body` (lock = `TELEPORT_LOCK_FRAMES=4` **physics frames** via `Engine.get_physics_frames()`).
- Bodies whose `placed==true`, whose int `state==1`, or that are in group `slick_placed` are not teleported (`_is_placed_object` `:143`).
- `arm_body_for_portal()` is an empty stub (`:135`).

### Pistons: `scripts/piston.gd` → `piston_2.gd` → `piston_3.gd` (inheritance by path)

- Phase machine `enum PistonPhase{RETRACTED, EXTENDING, EXTENDED, RETRACTING}`: `_phase`, `_phase_timer`, `_current_offset` (0..`push_distance`=1.2).
- `_physics_process` (`:152`): when `is_active`, the timer runs, then `_advance_phase` (`:221`) → `_enter_phase` (`:236`, plays `$PistonAudio3D` on EXTENDING) and `_update_offset`. `_drive_pusher` (`:194`) sets the `$PusherBody` AnimatableBody3D (`sync_to_physics=true`) transform directly. It is **kinematic and fully determined by `_phase/_phase_timer/_current_offset`**.
- Sticky riders: with "sticky tools" > 0, `$PusherBody/StickyArea` adopts placed bodies tagged with meta `rider_pending_frame` within `rider_claim_window=15` physics frames. It makes them kinematic-frozen and each frame sets each rider's global transform to the pusher target transform times the rider's stored offset. Excluded groups: `product, portal, roomba, proxy_intern, player`.
- `toggle_piston()` (`:289`) flips `is_active` and calls `GameState.update_toggle_tool_count()`. `remote_toggle(on)` (`:294`) only sets it.
- Save: `get_piston_save_data()` (`:640`) returns `{offset, phase, timer}`; `apply_piston_save_data` (`:648`).
- piston_2: speed presets `preset_multipliers [4,2,1]`, `scroll_tune_up/down`, `set_preset(index, play_feedback)` (`:143`). **The preset index is not saved by SaveManager.**
- piston_3: weight-gated firing (`weight_thresholds [0.5,2.5,6.0]`, `_compute_front_mass` `:220`, overrides `_physics_process` `:166` and `_advance_phase` `:197`).

### Press: `scripts/press.gd` (StaticBody3D fixture)

- `interact()` (`:52`) → `start_pressing()` (`:82`). A tween moves `$Press` mesh `position:y` over `press_duration*0.4`, then calls `process_crushed_items` (`:119`), waits, raises the mesh, and on `tween.finished` sets `is_pressing=false` and `_spawn_pending_anomalies()`.
- The crush list is maintained by `$Area3D` `body_entered/exited` (groups transport/tool/toy/product/gambling). Only the mesh moves. **Crushing is pure logic, not physics.**
- Effects: cash_register `_on_depleted()`, pinata `_burst()`, product → `replace_with_flat_product` (recycle + spawn `flat_duck(_luck)`), gambling `break_crate()`, debris +1000, tool/toy → `calculate_tool_value` (50% of buy price). Then `GameState.add_money(total)`. Effigy + 3 fuel per duplicate spawns `anomaly` (max 3). If the player is inside: `player.respawn_safe()`.
- **No signals.** Hook = wrap `process_crushed_items` / `start_pressing`.

### Cannons: `scripts/cannon.gd` → `cannon_2.gd`

- `$IntakeArea` collects RigidBodies (`_seen_in_intake`). `_process` → `_try_auto_load` (`:280`) loads `product`/`candy` with `mass <= max_loadable_mass`, unfrozen. `_load_body` (`:318`) reparents into the `CannonStorage` child, hides the body, zeros its collision layers, and sets meta `in_cannon_barrel`.
- `fire()` (`:362`): pops the queue, reparents to `get_tree().current_scene`, positions at `$Muzzle`, applies a random spread of `fire_spread_deg=2` using **`randf_range`**, then a central impulse along the barrel direction of size `fire_impulse` (22, tier II 32). Products get meta `player_throw_time/position`. Returns bool.
- `interact()` and `remote_toggle(true)` / `remote_pulse()` call `fire()`. **There is no `is_active` field.**
- cannon_2 `_process` (`:122`) auto-fires every `auto_fire_interval=1.5` s when placed and not equipped.
- Save: `get_queue_save_data()` (`:1257`) returns `[{pool_id, tint_color?}]`; `apply_loaded_queue(arr)` (`:1284`).
- Trajectory preview: `_update_trajectory` (`:785`) uses shape queries (heavy, cosmetic, local only).

### Fans: `scripts/fan.gd` (fan + fan2 scenes), `fan_3.gd`

- `_physics_process` (`:57`): for each body in `$Blower/Airflow` in groups product/transport/tool/gambling/debris, an impulse along the fan's local X axis scaled by `blow_strength`, a distance falloff and delta, with a per-frame stacking cap (`fan_stack_cap_multiplier=2`), plus a random torque (`randf_range`). The player gets a much weaker `apply_external_force` (about 1% of that).
- The stacking cap key uses `Engine.get_process_frames()` inside `_physics_process`, so it is shared across multiple physics steps in one render frame.
- `toggle_fan()` / `interact()` / `remote_toggle(on)` → `update_fan_state()` (`:137`) (wind mesh, audio, toggle count). Exported default `is_active=true`, but `on_pool_spawn` sets it false.

### Spring pads: `scripts/spring_pad.gd` → `spring_pad_2.gd`

- `$LaunchArea.body_entered` → `_on_launch_body_entered` (`:195`). The player gets an `apply_external_impulse` along the pad's up axis scaled by `player_impulse`. RigidBodies (product/tool/transport/gambling/toy, unfrozen, not on per-body cooldown) get `_apply_launch` (`:282`): with `consistent_launch`, it **sets `linear_velocity` directly** (quantized speed via `speed_quantum=6`), snaps to the launch plane, and damps angular velocity.
- Products get bonus tickets. The pad connects to `BottomMaw.product_consumed` and awards `GameState.add_bonus` plus HUD `_spawn_special_bonus_text`.
- spring_pad_2 adds chain bounce multipliers (`spring_pad_2_chain_count` meta).

### Bumper: `scripts/bumper.gd` (toy, pool `toy_bumper`)

- `$BumperArea.body_entered` → `_on_bumper_body_entered` (`:143`) reflects velocity about the bumper's facing axis and applies a central impulse in the reflected direction, scaled by `impulse_strength` and the chain multiplier. Chain multipliers live in meta `bumper_bounce_count`. The player goes through `_bounce_player`. Audio pitch uses `randf_range`.

### Gravity inverter: `scripts/gravity_inverter.gd`

- `_physics_process` (`:94`) when `is_active`: `$OuterField`/`$InnerField` overlaps (capped at `max_active_targets=30`, nearest first, woken up) get an upward central force of `base_force` times their mass (16), plus 18 more in the inner field, with meta `orbit_releaser_active`. The player gets an upward `apply_external_impulse`. It uses `get_first_node_in_group("player")` (single player).
- `toggle_field()` (`:241`), `remote_toggle(on)` (`:267`).

### Black hole: `scripts/black_hole.gd` (Node3D, cosmetic) / `test_black_hole.gd`

- black_hole.gd only drives post-process shader params on the `retro` group mesh (`black_hole_active`, `black_hole_screen_pos`, ...). It is per-viewport and purely visual. It is only instanced in `test_black_hole.tscn` (a test scene); `test_black_hole.gd` applies forces to every RigidBody in the tree on a trigger (debug).

### Elevator: `scripts/elevator.gd` (`/root/World/Elevator`, StaticBody3D root)

- `_ready` (`:56`): if `GameProgression.current_phase > PHASE_0`, it skips the intro. Otherwise `start_sequence()` (`:164`) fades master bus and overlay, waits `elevator_duration=17` s, then `open_doors()`. It sets `SaveManager.save_locked=false` on ready.
- `$ExitDetector` body exit by the player → `GameProgression.on_player_exit_elevator()`.
- Secret ending: `on_hack_success()` (`:328`, via `call_group("security_elevator", ...)`) arms escape → `_run_escape_ride()` (`:362`): `SaveManager.save_locked=true`, `_halt_facility()` (maw `monitoring=false`, `automated_workbench.turn_off()`), shudders (`randf_range`), moves the elevator to `escape_dock_path`, `player.teleport_to_transform`, then `call_group("security_room", "begin_arrival")`.
- Restores its hacked state from a `SaveManager.save_loaded` handler (`_restore_hacked_state`).
- Doors are tweened Node3D positions. No signals.

### Gates (`scenes/upper_area_gates.tscn`, under `/root/World/UpperAreaGates`)

- `scripts/vertical_gate.gd` on `Gate1_Shutters` (gate_id defaults to `"gate_shutters"`), `Gate2_WeightPlate` (`"gate_weight_plate"`), `Gate3_PowerGenerator` (`"gate_power_generator"`).
  - **`signal gate_opened(gate_id: String)`** (`:31`), emitted in `solve()` (`:51`), which also calls `Steamworks.on_gate_opened(gate_id)` and `UnlockManager.queue_world_notification(notification_key)`.
  - `_open_animated` tweens `barrier_panels` and then zeroes the barrier StaticBody collision layer/mask. `apply_saved_state(solved)` (`:135`) does an instant open. `get_save_data()` returns `{gate_id, is_solved}`.
- `scripts/gate_shutters.gd` (`Gate1_Shutters/FuseBoxLogic`): `fuse_slots[i].body_entered` → `_on_fuse_slot_body_entered(body, slot_index)` (`:22`). It accepts group `fuse` with a unique `fuse_id`, force-releases it from the player's hand (`main_camera.release_held_object()`), freezes it STATIC, and zeroes its layers. At 3 fuses it waits 0.8 s, then `gate.solve()`. State: `_slot_fuse_map {slot_idx: fuse_id}`. Save: `get_shutters_save_data()` / `apply_shutters_saved_state`.
- `scripts/fuse.gd` (World `Fuse`, `Fuse2`, `Fuse3`, fuse_id `fuse_1/2/3`): `SaveManager.save_loaded` → `_on_loading` snaps the fuse to its slot or resets it to its base pose.
- `scripts/gate_weight_plate.gd` (`Gate2_WeightPlate/FreightPlatform`): `_physics_process` (`:39`) sums `RigidBody3D.mass` of `_bodies_on_plate` plus a flat `PLAYER_MASS=8.0` when `_player_on_plate` (a single bool). At `required_mass=30` it waits 1.2 s, then `gate.solve()`. **Not saved itself** (the gate's `is_solved` covers it).
- `scripts/gate_power_generator.gd` (`Gate3_PowerGenerator/GeneratorUnit`): consumes `product` bodies in `intake_area` (meta `consumed`, `ObjectPoolManager.recycle.call_deferred`) and adds `body.value` into `accumulated_value` until `required_value=500`, then `_trigger_power_up` → `gate.solve()`. It also polls overlaps every 0.25 s. Save: `get_generator_save_data()` returns `{accumulated_value, activated}`.

### Security chain: card reader → keypad → elevator → security room

- `scripts/card_reader.gd`: `keycard` RigidBody in `IntakeArea` → recycle, `GameState.keypad_revealed=true`, `call_group("security_keypad", "reveal")`, `Steamworks.unlock_achievement("SECRET")`, HUD notification.
- `scripts/keypad_button.gd` (StaticBody3D children of SecurityKeypad): `interact()` → `get_parent().button_pressed(button_value)`.
- `scripts/security_keypad.gd`: **`signal hack_succeeded`** (`:29`). `button_pressed(value)` (`:79`) builds a 4-digit `entry` and compares it to `GameState.get_escape_code()`. On success: `GameState.elevator_hacked=true`, `hack_succeeded.emit()`, `call_group("security_elevator", "on_hack_success")`.
- `scripts/security_room.gd`: **`signal ending_finished`** (`:98`). `begin_arrival()` → `on_player_arrived()` (`:235`). `_process` arms after a grace period and fires `_run_cascade` when the player is near its own monitor or after `fallback_after=45` s. `_the_cut()` (`:380`) sets `GameState.secret_ending_seen=true`, `SaveManager.mark_game_completed()`, `mark_ending_seen("secret")`; `_after_black` → `Steamworks.unlock_achievement("END_SECRET")`, `ending_finished.emit()`, `MenuManager.open_end_game_menu(true)`. It uses its own SubViewport self-feed (`self_cam.make_current()` each frame while running).

### Loop puzzle: `scripts/loop_puzzle.gd`, `loop_button.gd`, `loop_reveal.gd` (`/root/World/LoopPuzzle`)

- **`signal puzzle_solved`** (`:85`), emitted in `_solve()` (`:557`), which also calls `Steamworks.unlock_achievement("LOOP")` and `_open_target()` → `LoopReveal.reveal()` (`on_solve_target = NodePath("LoopReveal")`).
- Run recording: `start_area`/`end_area` body_entered (player only). `_physics_process` samples `_player.global_position` at `sample_rate=30`. A new best → `_set_new_best` (`:398`) → clone train on a MultiMesh.
- Economy: `energy`, `clone_count`, `speed_level`, `energy_level`, `best_time`, `best_path`. `on_button(action)` (`:476`) handles `"buy_clone"|"upgrade_speed"|"upgrade_energy"`. The win condition is `current_rate() >= target_rate (50)`, checked every `_process`.
- Reset areas: the player teleports to `respawn_point`. Loose RigidBodies get scattered back (`randf`).
- Save: `get_save_state()` / `apply_save_state(d)` (`:629/641`). SaveManager stores it in `pending_loop_puzzle`.
- `loop_reveal.gd`: `reveal()` / `reveal_instant()`. Slides walls/path and disables `reset_areas_to_disable` monitoring.

### Automation tools

- `scripts/roomba.gd` (pool `tool_broom_3`): `enum State{PATROL, DETOUR, APPROACH, PUSH, UNSTUCK}`, `var state`. It runs in `_physics_process` (`:132`) when `is_active`, drives itself with forces (`_apply_force_to`), and pushes `product` bodies toward the hole (`saveable_hole` group, `current_radius`). Toggled by `interact()` (`:580`) / `remote_toggle`. Note: `state` is an int, but portal/loop `_is_placed_object` check `placed` first, so this is fine.
- `scripts/qa_arm.gd`: `enum ArmState{OFF, READY, SWING, COOLDOWN}`. `_physics_process` (`:164`) predicts intercepts (`_find_intercept` `:323`), swings, and samples shape queries along the arc (`_sample_arc`). `_whack(body)` (`:424`) **sets `linear_velocity`** to `dir * _launch_speed()` and sets a random `angular_velocity` (`randf_range`). On the player it applies `apply_external_impulse` plus `GameState.record_safety_violation()`. The level comes from `GameState.tools["qa_arm"]["level"]`.
- `scripts/proxy_intern.gd` (pool `tool_auto_crafter`, max 1): `_update_latch` (`:113`) finds the nearest `workbench` with `start_crafting`, sets meta `auto_crafter` on it, and calls `bench.start_crafting()` while `is_active` (default true). Pure logic.
- `scripts/shift_scheduler.gd` (pool `tool_scheduler`): latches the nearest target with `remote_toggle` and calls `_target.remote_toggle(on)` on its schedule (`scheduler_mode`, `scheduler_interval`, `scheduler_duration`, all saved).
- `scripts/remote.gd` + `GameState.remote_channels` / `remote_channel_states` / **`signal remote_channel_toggled(channel_idx, state)`** (`game_state.gd:25`), `set_remote_channel_state` (`:1340`) → `apply_remote_tool_state(tool, on)` (`:1360`) → `tool.remote_toggle(on)`.

### Camera feeds

- `scripts/camera_feed_manager.gd` (autoload `CameraFeedManager`): `_cameras` registry, `register_camera`, `unregister_camera`, `get_cameras()`, `get_camera_by_id(id)`, `display_number(cam)`.
- `scripts/feed_camera.gd` (pool `toy_feed_camera`): `camera_id` is generated from the current microsecond tick count plus a random number (`_ensure_id` `:127`), so it is **machine-local**. Its `SubViewport` renders `UPDATE_ONCE` at `feed_fps=8` only while `_watcher_count > 0` (`add_watcher`/`remove_watcher`).
- `scripts/feed_screen.gd`: `watched_camera_id`. `_set_camera` calls add/remove watcher. `interact()` cycles cameras.
- `scripts/camera_pivot.gd` (wall security cams): `_integrate_forces` breaks when contact impulse ≥ `break_threshold=5` → `destroy_camera()` (`:84`) → `GameState.record_camera_destroyed()`, `Steamworks.unlock_achievement("BAD")`, `GameState.spend(100)`. It tracks `get_first_node_in_group("head")` (one player). Save `{camera_id, is_destroyed}`. The ID falls back to `"camera_"+instance_id` if unset (World sets "1".."8"...).
- `scripts/feed_capture_debug.gd`: F10 debug capture.

### Other world logic (brief)

- `hole.gd` (`/root/World/Floor`): grows `current_radius` toward `target_radius` from `BottomMaw.product_consumed`. It moves the collision StaticBodies, resizes `$WakeArea` (and wakes sleeping bodies inside), and adjusts `maw_light.spot_angle`. Save: `get_save_data()` returns `{current_radius, target_radius, current_phase, phase_nutrition_total, mega_combo_progress}`. If missing, it adds a user signal `product_consumed` to BottomMaw.
- `bottom_maw.gd`: **`signal product_consumed(product_type: String, nutrition_value: int, body_id: int)`** (`:11`). It is the central "item eaten" event (emitted `:141` for recycle cubes as `"recycle", 0`, and `:219` for products). Consumers: hole, spring_pad, basketball_hoop, golf_club, speed_radar.
- `fail_safe.gd`: out-of-bounds Area3D. RigidBodies: `recover_to_home()` if present; else for tools `unplace()` plus turn-off, then respawn at `(0,15,18)` with `randf` jitter and `ToolTube.trigger_wobble()`. The player: `respawn_safe()`, `GameState.spend(1)`, `ComboSystem.reset_combo()`.
- `interdiction_area_3d.gd`: restricted-area countdown (player) → `GameState.activate_alarm()` / `deactivate_alarm()`. Skipped once all cameras are destroyed (`are_cameras_destroyed()`).
- `alarm_light.gd`: `set_alarm(active)` (group `alarm_lights`). `tool_tube.gd`: cosmetic wobble, `trigger_wobble(moving_up)`.
- Field tools with `_physics_process` forces: `magnet.gd` (central force toward the magnet scaled by `pull_strength`, `_is_repell()`), `magnet_2.gd`, `tractor_beam.gd` (also `_apply_player_pull`), `vacuum.gd` (`_apply_suction_forces`, bag storage `in_vacuum_bag`, `get_bag_save_data`), `orbit_tool.gd` (`_apply_angular_repulsion`, `orbit_in_orbit`), `broom.gd`, `debris.gd`, `mining_ore.gd`, `ore_processor.gd`, `disco_ball.gd`, `basketball_hoop.gd`, `pin.gd` / `bowling_pin_set.gd`, `golf_club.gd`, `speed_radar.gd`, `stat_sign.gd`, `golden_duck_statue.gd`, `box*`, `crate.gd`, `cushion.gd`.
- Visual / static environment, no physics authority: `uv_code.gd`, `uv_graffiti.gd`, `uv_light.gd`, `uv_lamp.gd`, `erasable_text.gd` (SubViewport ink; saveable via `get_save_data`), `megastructure_corridor.gd`, `observatory_window.gd`, `torch_light.gd`, `maw_hit_effect.gd`, `stream_spawner.gd` / `product_stream.gd` (MultiMesh), `falling_object(_manager).gd` (main menu), `fall_sequence.gd` (ending).

## 5. Signals in this subsystem (exhaustive for the scope)

| Owner | Signal | Args | Meaning |
|---|---|---|---|
| `vertical_gate.gd` (UpperAreaGates/Gate*) | `gate_opened` | `gate_id: String` | gate puzzle solved |
| `security_keypad.gd` (World/SecurityKeypad) | `hack_succeeded` | none | correct escape code entered |
| `security_room.gd` (World/SecurityRoom) | `ending_finished` | none | secret ending done, before end menu |
| `loop_puzzle.gd` (World/LoopPuzzle) | `puzzle_solved` | none | loop rate ≥ target |
| `bottom_maw.gd` (World/BottomMaw) | `product_consumed` | `product_type: String, nutrition_value: int, body_id: int` | item eaten by the maw |
| `game_state.gd` (GameState) | `remote_channel_toggled` | `channel_idx: int, state: bool` | remote channel toggled |
| `game_progression.gd` | `phase_changed` | `new_phase: int` | hole phase changed (consumed by hole) |
| `save_manager.gd` | `save_loaded` | none | world objects re-apply state (elevator, fuse, card_reader, keypad, loop_puzzle...) |

Every tool/machine (piston, cannon, fan, spring pad, bumper, portal, gravity inverter, press, roomba, qa_arm, proxy_intern, elevator, gates' sub-logic) **declares no signals**. Observation means wrapping methods or polling.

Built-in signals to connect: `Area3D.body_entered/exited` on each machine's sensor (e.g. `Press/Area3D`, `Cannon/IntakeArea`, `SpringPad/LaunchArea`, `Bumper/BumperArea`, `Gate1_Shutters/FuseBoxLogic/Fusebox/FuseSlot1..3`, `Gate2_WeightPlate/FreightPlatform/PressureArea`, `Gate3_PowerGenerator/GeneratorUnit/IntakeArea`, `CardReader/IntakeArea`, `Elevator/ExitDetector`); `RigidBody3D.body_entered` (collision audio); `CanvasItem/Node3D.visibility_changed` on pooled nodes (fires on `_activate`/`_deactivate`).

## 6. Performance, audio and post-process managers (autoloads)

### PerformanceMonitor: `scripts/performance_monitor.gd`

- `process_mode=ALWAYS`. Every `check_interval=0.5` s it samples `Performance.TIME_PHYSICS_PROCESS` and FPS. `enum PerformanceState{NORMAL, DEGRADED, CRITICAL}`, `current_state`.
- `_apply_physics_settings(tick_rate, vel_it, pos_it, sleep)` (`:352`) **sets `Engine.physics_ticks_per_second` to 60, 40 or 30** and `Engine.max_physics_steps_per_frame` to 8, 4 or 2. It also writes `ProjectSettings` `physics/3d/solver/velocity_iterations`, `position_iterations` and `physics/jolt_physics_3d/simulation/sleep_time_threshold`. These runtime ProjectSettings writes probably have no effect under Jolt (unverified).
- On focus-out it stops checking. On focus-in it sets `max_physics_steps_per_frame=1` for 1 s.
- Getters: `get_performance_state()` (`:408`), `get_physics_time_ratio()`, `get_average_fps()`, `get_current_tick_rate()`, `get_debug_info()`. Debug keys F1-F4 run only when `UnlockManager.DEBUG`.

### PostProcessManager: `scripts/post_process_manager.gd`

- Local graphics settings stored in `user://graphics_settings.cfg`. `apply_graphics_preset(name)` (`:253`) edits the `WorldEnvironment` group env and the viewport AA. `apply_psx_toggle(enabled)` (`:423`) toggles the `retro` group mesh (`World/ScreenQuad`). `RenderingServer.global_shader_parameter_set("resolution"|"dither_amount"|"color_depth")`. `apply_fps_limit()` → `Engine.max_fps`. Purely client-local.

### MusicManager: `scripts/music_manager.gd`

- Owns one `AudioStreamPlayer` on bus `Music`, `process_mode=ALWAYS`, and adds an `AudioEffectHighPassFilter` to the Music bus in `_ready`. API: `play_music(stream, fade=true, custom_fade_time=-1)` (`:87`), `stop_music()`, `fade_out_music(t)`, `resume_music(stream)`, `set_filter_cutoff(cutoff, t)`, `get_current_track_path()`, field `no_filter`. The pause filter follows `get_tree().paused`.
- Callers: GameProgression (phase tracks, `:247/401/640`), combo_system `:436`, session_complete, SaveManager (resume on load), elevator (`stop_music` on hack).

### ImpactAudio: `scripts/impact_audio.gd`

- Global token bucket: `MAX_SOUNDS=4` per `WINDOW=0.1` s. `request(impact_force) -> bool` (`:20`) refuses soft hits (<3.0) when ≤2 tokens remain. Every RigidBody collision-audio handler calls it first.

### CameraFeedManager / PortalPairManager

See section 4. Both are registries with no signals and `PROCESS_MODE_ALWAYS`.

## 7. Hook points (best first)

| # | Target | Strategy | Notes |
|---|---|---|---|
| 1 | `UpperAreaGates/Gate*` `gate_opened(gate_id)` | signal-connect | find with `get_tree().get_nodes_in_group("vertical_gate")` after World ready |
| 2 | `SecurityKeypad.hack_succeeded`, `SecurityRoom.ending_finished`, `LoopPuzzle.puzzle_solved` | signal-connect | groups `security_keypad`, `security_room`, `loop_puzzle` |
| 3 | `BottomMaw.product_consumed` | signal-connect | group `BottomMaw`; body_id = instance id |
| 4 | `GameState.remote_channel_toggled` | signal-connect | autoload, safe from boot |
| 5 | `SaveManager.save_loaded` | signal-connect | re-sync world state after load |
| 6 | pooled object lifecycle | node-added + signal-connect | `get_tree().node_added` catches first instantiation under `/root/ObjectPools`; connect each node's `visibility_changed` (true = spawn, false = recycle); alternatively poll `ObjectPoolManager.get_active_units(pool_id)` (`:774`) |
| 7 | `ObjectPoolManager.spawn/recycle` | autoload-wrap | already instantiated before our loader, so take_over_path is useless. Options: replace the autoload entry in override.cfg (`ObjectPoolManager="*C:/.../pool_ext.gd"` extending the original; **unverified whether an override.cfg key with the same name keeps load order**), or use the visibility signal approach |
| 8 | `piston.gd` `_enter_phase`, `toggle_piston`, `remote_toggle` | script-extension(take_over_path) | subclasses piston_2/piston_3 `extends "res://scripts/piston.gd"` by path, so the takeover must happen before they load (fine: tool scenes load in the loading screen after our autoload) |
| 9 | `cannon.gd` `fire()` / `_load_body()` | script-extension(take_over_path) | cannon_2 extends by path; `fire` returns bool |
| 10 | `portal_pair_manager.gd` `teleport_body` | other: implement `on_portal_teleport(source, dest)` on mod bodies (free callback) | PortalPairManager is an autoload, so no takeover; for global observation, wrap via override.cfg or poll `portal._exception_bodies` |
| 11 | `press.gd` `start_pressing` / `process_crushed_items` | script-extension(take_over_path) | press.tscn loaded in main menu preload list (`main_menu.gd:700`) after boot, so takeover in our `_init` works |
| 12 | `spring_pad.gd _on_launch_body_entered`, `bumper.gd _on_bumper_body_entered` | signal-connect (`LaunchArea`/`BumperArea.body_entered`) for observation; take_over_path to modify | |
| 13 | `fan.gd`, `gravity_inverter.gd`, `magnet.gd`, `tractor_beam.gd`, `vacuum.gd`, `orbit_tool.gd` `_physics_process` | script-extension(take_over_path) | needed for multiplayer gating (only the authority applies forces) |
| 14 | `vertical_gate.solve`, `gate_shutters._on_fuse_slot_body_entered`, `gate_power_generator._on_intake_body_entered`, `gate_weight_plate._physics_process` | script-extension(take_over_path) | world.tscn-embedded scripts, loaded with world.tscn (after boot) |
| 15 | `elevator.gd on_hack_success/_run_escape_ride/start_sequence` | script-extension(take_over_path) | heavy single-player assumptions |
| 16 | `PerformanceMonitor` | other: runtime property set | `PerformanceMonitor.set_process(false)` plus `Engine.physics_ticks_per_second = 60` to pin ticks (required for MP); or read `current_state` |
| 17 | `MusicManager.play_music`, `PostProcessManager`, `ImpactAudio.request` | autoload (call API directly) | already instantiated; call their public methods; replacing them needs override.cfg |
| 18 | `CameraFeedManager.get_cameras()` | poll | cheap registry |
| 19 | `camera_pivot.destroy_camera` | script-extension(take_over_path) | **camera_pivot.gd is loaded at splash via main_menu.tscn** (still after autoloads, so takeover in our autoload `_init` works; too late if done after the main menu opens) |
| 20 | `loop_puzzle.on_button`, `_set_new_best`, `get_save_state` | script-extension(take_over_path) | |

take_over_path notes: scenes reference scripts by `uid://…` with a path fallback; the UID resolves to the path, and the ResourceCache then serves the taken-over script. The extension script must `extends "res://scripts/X.gd"` (compiled before takeover) and then call `take_over_path("res://scripts/X.gd")`. Scripts already loaded before our autoload: the autoload scripts themselves (`camera_feed_manager.gd`, `portal_pair_manager.gd`, `performance_monitor.gd`, `post_process_manager.gd`, `music_manager.gd`, `impact_audio.gd`, `object_pool_manager.gd`, `game_state.gd`, `save_manager.gd`, ...) and anything they `preload` (e.g. spring_pad/bumper preload only a font). Those cannot be swapped by takeover.

## 8. Multiplayer analysis: physics-driven vs logic-driven

**Physics-driven (host-authoritative; replicate transform/velocity snapshots):**

- Every unplaced pooled RigidBody3D: products (duck, cash_register, pinata, candy, anomaly, ...), tools, toys, debris, ores, fuses, keycards.
- Force/impulse/velocity writers that must run **only on the host**: fan/fan_3 (`apply_impulse`, random torque), magnet(_2), gravity_inverter, tractor_beam, vacuum, orbit_tool, spring pads (velocity set), bumper (impulse), qa_arm (velocity set, random angular), cannon `fire()` (random spread + impulse), roomba drive, press flat-product spawn, fail_safe/loop teleports, portal teleports, piston rider carrying, hole collision bodies (moved by radius), `camera_pivot._integrate_forces` break detection.
- Randomness (`randf*`) in cannon, fan, qa_arm, bumper, fail_safe, loop_puzzle, debris, minable_block, golden_duck_statue, elevator shudder makes lockstep impossible; snapshot sync is required.
- Placed tools (`placed=true` → `freeze_mode=STATIC`) are static: sync them once at placement, not per tick.
- Player-affecting forces (`apply_external_force/impulse` on the CharacterBody from fan, spring pad, bumper, gravity inverter, tractor beam, qa_arm) are applied to the `player` group's first node only. For remote players, the host must send the impulse to the owning client (or the client runs a local sensor).

**Kinematic but derivable from small state:** piston pusher (`_phase`, `_phase_timer`, `_current_offset`); sync these instead of transforms. Hole radius (`current_radius`/`target_radius`).

**Logic-driven (replicate events/state, not transforms):** `is_active` of toggle tools; remote channels; scheduler mode; cannon queue (`get_queue_save_data`); piston_2/3 presets; press cycle (`is_pressing` + crush results + money); gates (`is_solved`, `_slot_fuse_map`, `accumulated_value`, weight-plate activation); card reader / keypad (`GameState.keypad_revealed`, `elevator_hacked`, keypad `entry`); elevator sequence; security room ending; loop puzzle (`energy, clone_count, speed_level, energy_level, best_time, best_path, is_solved`); loop_reveal; security camera `is_destroyed`; feed camera bindings (`camera_id`, `watched_camera_id`; IDs must be host-assigned because `_ensure_id` uses time + randi); proxy_intern latch.

**Local-only / cosmetic (never replicate):** PostProcessManager, MusicManager (except as a consequence of replicated GameProgression phase), ImpactAudio buckets, feed SubViewport rendering, black_hole shader, cannon trajectory preview, launch/bounce Label3D texts, tool_tube wobble, alarm light spin, screenshake, security room self-feed.

**Single-player assumptions to patch for MP:**

- `get_first_node_in_group("player")` in cannon, elevator, gravity_inverter, security_room (3x), tractor_beam, golf_club, game_progression, save_manager.
- `get_first_node_in_group("main_camera")` in press, gate_shutters, gate_power_generator, loop_puzzle, elevator, vertical_gate, ... (used to force-release held objects and for screenshake).
- camera_pivot tracks the `head` group; gate_weight_plate has a single `_player_on_plate` bool; loop_puzzle has a single `_player`; interdiction_area has a single `player`; elevator `player_inside`; press `is_player_in/player`.
- `PortalPairManager` is global (2 portals per world). Fine for a shared world, but it uses physics-frame locks.
- PerformanceMonitor changes the tick rate per machine, so pin it in MP. Frame-count logic (portal `TELEPORT_LOCK_FRAMES=4`, piston `rider_claim_window=15`) then varies with tick rate.
- `get_tree().paused` is used by menus and SaveManager (`save_manager.gd:248`). MP must not pause the tree; MusicManager's filter is keyed on it.
- `SaveManager.save_locked` toggled by elevator.
