# Subsystem map: player-interaction

Source: a local decompile of Project P.I.T.T. v1.0.8 (Godot 4.7.2) in `decomp/` (gitignored, not part of this repo). All paths are relative to `decomp/` (`res://`). Line numbers are from the decompiled scripts.

**Main finding:** none of the player-interaction scripts declare a single `signal`. Carry, throw, equip, interact and HUD all run through direct method calls and duck-typed `has_method()` checks. Mod hooks therefore have to (a) poll state on the camera, (b) wrap scripts with `take_over_path`, or (c) use `SceneTree.node_added`. The only usable signals nearby belong to the autoloads (GameState, SaveManager, MenuManager, InputManager, ComboSystem) and to BottomMaw.

---

## 1. Where the player lives

The player is **not** instanced from `scenes/player_controller.tscn`. That scene is a stale prefab that nothing references. The live player is written **inline in `scenes/world.tscn`**, starting at line 1241:

```
/root/World                                   (Node3D, current_scene; loaded by main_menu.gd:236/282/651/663, save_manager.gd:214)
├─ HUD                       CanvasLayer  group "HUD"          script hud.gd
│  ├─ RotationModePanelIndicator, CoplanarModePanelIndicator (Panel)
│  ├─ Crosshair, TextureProgressBar(group "WorkbenchProgress"), Money(Label)
│  ├─ ComboBar, ComboResult, GamblingResult (instances)
│  ├─ IntroLabel, DeathLabel, NotificationLabel (Label, font_size 130, centred)
│  └─ PlayerHUD              CanvasLayer  group "PlayerHUD"
│     └─ interact_label, controls_label, rotation_step_label, save_label
├─ PlayerController          CharacterBody3D group "player"  script player_controller.gd
│  │   process_mode=3 (ALWAYS), collision_layer=2, collision_mask=262157
│  ├─ CameraPivot            Node3D group "head" (NO script — camera_pivot.gd is something else, see §7)
│  │  └─ MainCamera          Camera3D group "main_camera" script main_camera.gd
│  │     ├─ InteractRay      RayCast3D script interact_ray.gd (target (0,0,-2.5), mask 524301)
│  │     ├─ Hands            Marker3D (0,0,-3)  — carry target point
│  │     ├─ Generic6DOFJoint3D (node_a=../StaticBody3D; node_b = held body or itself)
│  │     ├─ StaticBody3D     (joint anchor)
│  │     ├─ TorchLight       SpotLight3D group "torch_light"
│  │     └─ UVLight          SpotLight3D group "uv_light"
│  ├─ FootstepAudio3D, TextAudio3D, NotificationAudio3D, JumpAudio3D, SlideAudio3D,
│  │  AirWooshAudio3D, TorchAudio3D, PlaceAudio, SnapModeToggleAudio, GridSnapAudio,
│  │  PanelSnapAudio, RotateResetAudio, RotateTickAudio, PickupAudio, DropAudio,
│  │  ThrowAudio, InteractAudio, DistanceAdjustAudio, EquipAudio, UnequipAudio
│  └─ OmniLight3D group "body_light"
└─ ToolTube                  Node3D group "ToolTube" script tool_tube.gd (world.tscn:1673)
```

Ways to look the player up, from most to least robust:
- `get_tree().get_first_node_in_group("player")`. 26 game scripts do this.
- `get_tree().get_first_node_in_group("main_camera")`. 28 scripts do this.
- `get_tree().get_first_node_in_group("HUD")`. 25 scripts do this.
- `get_tree().get_first_node_in_group("head")`. Only `camera_pivot.gd:22` uses it (security cameras).
- `get_viewport().get_camera_3d()`. Used by black_hole, golf_club, interact_ray, observatory_window, ore_processor and pickaxe.

### Hard-coded relative NodePaths (these break if the player is re-parented or duplicated)

| Script | Line | Path |
|---|---|---|
| main_camera.gd | 3 | `$".."` (CameraPivot) |
| main_camera.gd | 9 | `$"../.."` (PlayerController) |
| main_camera.gd | 10,11 | `$"../../../HUD/RotationModePanelIndicator"`, `.../CoplanarModePanelIndicator` |
| main_camera.gd | 12-24 | `$"../../PlaceAudio"` … `$"../../EquipAudio"` |
| interact_ray.gd | 4-6 | `$"../../../../HUD/PlayerHUD/interact_label"`, `controls_label`, `rotation_step_label` |
| hud.gd | 11,12 | `$"../PlayerController/TextAudio3D"`, `$"../PlayerController/NotificationAudio3D"` |
| player_controller.gd | 13-22 | `$CameraPivot/MainCamera`, `$CameraPivot`, `$CollisionShape3D`, audio nodes, `$GroundRaycast`, `$FloorTypeRaycast` |

`main_camera.gd` and `interact_ray.gd` reach up past the player into the World to find the HUD. Because of this, you **cannot instance a second PlayerController under World** and have it work without fixing those paths.

---

## 2. player_controller.gd (CharacterBody3D, 1068 lines, no class_name, no signals)

### Fields worth reading or writing
- Constants: `BASE_SPEED=3.5`, `SPRINT_MULTIPLIER=1.6`, `JUMP_VELOCITY=5`, `RESPAWN_ANCHOR=Vector3(0,6,18)`.
- Exports: `MOUSE_SENSITIVITY` (0.005), `GAMEPAD_SENSITIVITY` (3.0), dive slam params (`dive_slam_*`), `surface_footsteps: Dictionary[String,AudioStream]`, `shell_mask`, `interior_mask`, `respawn_clear_mask`.
- State: `mouse_captured`, `is_sprinting`, `is_crouching`, `is_sliding`, `slide_timer`, `is_air_diving`, `stand_requested`, `external_velocity: Vector3` (decays at `external_velocity_decay`=6), `torch_mode: int` (enum `TorchMode{OFF,TORCH,UV}`), `anti_clip_suspended: bool`, `last_safe_position`, `distance_traveled`.
- Tunables stored as plain vars (mods can write them freely): `sprint_fov_boost`, `crouch_speed_factor`, `slide_boost`, `slide_duration`, `air_dive_accel`, `air_dive_max_fall`, `air_dive_kick`, `standing_height`, `crouching_height`, `max_jump_hold_time`, `extra_jump_force`.
- Meta `"golf_aim_mode"`: set by golf_club.gd:249 and read at :232. When set, movement is blocked.

### Methods
- `_ready()` (94): handles `SaveManager.should_load_on_ready` (the same block appears twice by mistake, 105-119), `SaveManager.pending_sandbox_grant`, `ResourceWarmer.warm_up()`, captures the mouse, connects `MenuManager.settings_changed -> update_settings`, then calls `GameState.start_game()`.
- `_input` (136): handles quick_save, quick_load and torch, showing results through `hud.show_restrict_message(tr(...))`.
- `_unhandled_input` (171): esc/pause, and mouse look. Mouse look does `rotate_y` on the body and `main_camera.rotate_x`, clamped to ±PI/2.
- `_physics_process` (212): one monolithic function. It reads `GameState.upgrades["sprint"|"crouch"|"slide"|"jump"|"prop_surf"]["level"]` and `MenuManager.settings.gameplay.*`, calls `move_and_slide()`, adds `external_velocity`, carries the player along with moving rigid floors, and runs `_anti_clip_check`.
- Public API that game objects already call:
  - `apply_external_force(force: Vector3)` (712). Only x and z are applied. Used by tractor_beam, fans and others.
  - `apply_external_impulse(impulse: Vector3)` (719).
  - `is_touching(body) -> bool` (728).
  - `teleport_to(pos: Vector3)` (785) and `teleport_to_transform(xform)` (912). These zero `velocity` and `external_velocity`.
  - `respawn_safe(anchor := RESPAWN_ANCHOR, maw_radius_hint := -1.0)` (789). Called from bottom_maw:300, fail_safe:59, game_progression:1455, interdiction_area_3d:99, pause_menu:272, press:159 and save_manager:1302/1304.
  - `update_settings()` (654), `_cycle_torch()` (689). `_cycle_torch` toggles every node in the groups `torch_light` and `uv_light`.
- Save: `SaveManager._save_player_position()` (save_manager.gd:795) and `_load_player_position()` (:1262) look up group `"player"` and store only `global_position`. Camera yaw and pitch are not saved.

---

## 3. main_camera.gd (Camera3D, 2135 lines): grab, carry, throw, equip, interact

This is the hub. **No signals.** Its public state is plain vars:

| Field | Type | Meaning |
|---|---|---|
| `picked_object` | RigidBody3D | currently carried body (null if none) |
| `equipped_item` | RigidBody3D | tool parented under the camera |
| `hovered_object` | RigidBody3D | ray target being highlighted |
| `locked` | bool | true while mMouse is held to rotate an object. The player uses it to block look (player_controller:195) |
| `snap_mode`, `snap_tier`, `POSITION_SNAP`, `ROTATION_SNAP`, `SNAP_POINT_RADIUS`, `snap_axis_lock` | | placement snapping |
| `pick_cooldown` | float | 0.1 s between grab and drop |
| exports | | `pull_power`=8, `rotation_power`, `held_rotation_inertia`=1000, `max_held_rotation_speed`, `knockback_power`=5 (throw), `max_grab_distance`=3.5, `zoom_speed`, `min_distance`=1.5, `surf_follow_power`, `surf_max_follow_speed`, `snap_search_radius` |

### Carry pipeline
- `handle_input()` (425) runs at the end of every `_physics_process` (218→342). It polls `Input.is_action_just_pressed(...)` directly, so injected `InputEvent`s only work through `Input.parse_input_event` or `Input.action_press`.
- **Grab**: lMouse with `equipped_item == null` and `pick_cooldown <= 0` calls `pick_object()` (682).
  - If the collider has `collect_on_grab()`, that is called and nothing is carried (uv_lamp uses this).
  - Otherwise, if `collider is RigidBody3D and is_in_group("draggable")`, it calls `_begin_carry(obj, keep_hands=false)` (693).
- `_begin_carry` does the following, in order: `_release_from_piston`, `obj.unplace()` if present, `lock_rotation=true`, `_disable_held_gravity` (meta `_held_gravity_scale`), `_stiffen_held_inertia` (meta `_held_inertia`), `_enable_held_contact_monitor` (meta `_held_contact_monitor`/`_held_max_contacts`), points the joint's `node_b` at the object, `set_highlight(true,false)`, positions `hands` at the clamped distance, and plays pickup_audio.
- **Hold**: in `_physics_process` (284-340) it sets the held body's linear velocity to the offset toward `hands` scaled by `pull_power`. The carried object follows by velocity, not by teleport. It force-drops (`drop_object(true)`) when `distance > max_grab_distance`, or when the player is standing on the held object while the `prop_surf` upgrade is 0.
- **Drop**: `drop_object(force := false)` (735). It restores gravity, inertia and contact monitor, then calls `obj.force_place()` (snap) or `obj.call_deferred("place")`, or just plays drop audio. It sets meta `rider_pending_frame`, clears `picked_object` and resets the joint (its `node_b` points back at the joint itself). If a panel was dropped and `auto_rack` is on, it calls `_refill_from_panel_stack`.
- `release_held_object()` (982) is a safe external "let go" (`drop_object(true)`). It is used by player_controller:166, gate_shutters:43, interdiction_area_3d:97, object_pool_manager:653 and uv_lamp:90.
- **Throw**: rMouse with `GameState.upgrades["throw"]["level"] > 0` (568-617). This is **inline and does not go through `drop_object()`**. It applies a central impulse along the camera's forward axis scaled by `knockback_power` and the throw level, plus a random torque impulse, adds collision layer bit 2 to the player's `collision_mask`, and clears `picked_object`. Products get meta `player_throw_time` and `player_throw_position`. A plain drop of a product also sets these (558-560).
- Rotate (mMouse) uses `rotate_object()` (1060). Reset rotation uses `"reset"` and the upgrade `reset_rotation` (619-646). Snap uses `"rotate"` and the upgrade `snap_grid`, via `toggle_snap_mode`/`enter_snap_mode`/`exit_snap_mode`.
- Panel rack: `_try_rack_store()`, `_try_withdraw_panel()`, `_rack_panel()` and `_refill_from_panel_stack()`. These use `GameState.panel_stack` and `ObjectPoolManager.spawn/recycle`.
- `apply_screenshake(intensity, duration)` (649) is public. It respects `MenuManager.settings.gameplay.screen_shake`.

### Equip pipeline (tools)
- The `"equip"` action (445-477):
  - If an item is already equipped: it calls the item's `unequip()` with the current scene and a drop position, then the item **becomes `picked_object`** (you are now carrying it).
  - Otherwise it grabs the target if nothing is held. If the held object `is_in_group("equipable")` and `GameState.upgrades["equip"]["level"] > 0`, it calls the item's `equip()` with the camera and clears `picked_object`.
- `update_equipped_item_properties()` (1716) runs every `_process`. It forces the local pose by group (`broom`, `fan`, `remote`, `golf_club`, `cannon`). Other items fall back to their `equipped_offset` / `equipped_rotation_deg` properties.
- Input dispatch to the equipped item (`_is_remote_equipped()` means the item has `remote_lmb_pressed`):
  - `equipped_lmb_held()` while lMouse is held (pickaxe)
  - `equipped_lmb_pressed()` / `equipped_lmb_released()` (vacuum, pickaxe, tractor_beam)
  - `equipped_rmb_pressed()` (vacuum, tractor_beam)
  - `remote_lmb_pressed()`, `cycle_channel(±1)` on scroll, and `try_interact_with_target(target)` on interact (remote)
  - If the item has no lmb methods, lMouse calls `_do_interact()`
  - golf_club reads `_input` itself and calls `set_input_as_handled()`
- `_do_interact()` (2091): if a remote is equipped it calls `try_interact_with_target`. Otherwise it calls `equipped_item.interact()`, then `picked_object.interact()`, then the ray collider's `interact()`. It plays interact_audio and returns a bool.
- Scroll on a looked-at target calls `scroll_tune_up/down()`; rMouse calls `scroll_tune_cycle()`. Targets come from `_get_scroll_tune_target()`, which reads `InteractRay.last_collider`.

### Duck-typed contract a mod object must implement to act like a vanilla object
- Grabbable: `RigidBody3D` in group `"draggable"`. Optional: `set_highlight(active: bool, grabbed: bool=false)`, `object_name() -> String` (the HUD label), `place()`, `unplace()`, `force_place()`, `get_reset_basis() -> Basis`, `interact()`, `collect_on_grab()`.
- Equipable: also in group `"equipable"`, with `equip(camera: Camera3D)` and `unequip(world: Node3D, drop_pos: Vector3)`. The vanilla pattern is: save and zero `collision_layer`/`collision_mask`, `remove_child`, then `camera.add_child(self)`. Optional: `equipped_offset: Vector3`, `equipped_rotation_deg: Vector3`, `get_equipped_controls_text(ctrl_func: Callable, looking_at_toggle: bool, looking_at_linked: bool) -> String`, the `equipped_*` input methods listed above, `is_equipped: bool`.
- Remote-linkable: group `"toggle"` plus `remote_toggle(on: bool)`.
- Pooled: `pool_id: String`, `on_pool_spawn()`, `on_pool_recycle()`.
- Interact-ray prompts (interact_ray.gd:219-226): the collider must be in one of the groups `interact`, `draggable`, `equipable`, `workbench`, `automated_workbench`, `terminal`, `toggle`, `press`. Hold-to-use terminals implement `supports_hold()`, `hold_duration()`, `hold_progress(p)`, `hold_complete()`, `hold_cancel()`, `hold_label()` and `hold_prompt()`.

---

## 4. interact_ray.gd (RayCast3D, 750 lines)

- `last_collider: Node3D` is the current focus target. It is read by main_camera `_get_scroll_tune_target` (via `get("last_collider")`).
- `_process` (164): updates the snap label, mirrors `camera.picked_object` into `last_collider`, then calls `update_ui_labels()` (281). That function fills `interact_label` from the target's `object_name()` and `controls_label` from `get_controls_for_object()` (307).
- `refresh_controls()` (639) and `hide_ui_labels()` (297) are called by main_camera after state changes.
- `_ctrl(key)` (102) turns a `CTRL_*` translation key plus the `CTRL_ACTION_MAP` (27-64) into a prompt with the bound key name filled in. It is passed as `ctrl_func` to `get_equipped_controls_text`. Mods can reuse it: `ray._ctrl("CTRL_USE")`.
- Hold progress: `_push_hold(p)` (564) calls `HUD.show_hold_progress(p, label)`. `_cancel_hold()` calls `hide_hold_progress()`.
- Connects `GameState.money_updated` and `InputManager.input_device_changed`.

---

## 5. hud.gd (CanvasLayer `/root/World/HUD`, group "HUD", 1059 lines). Toast/notification surface

Public display methods and their callers:

| Method | Line | Target | Notes |
|---|---|---|---|
| `show_notification_message(message)` | 765 | `NotificationLabel` (font 130, full-screen centre) | kills the previous tween, **screen-shakes the camera (0.25,0.5)**, plays NotificationAudio3D, fades in → `display_time`(2.0) → `fade_time`(1.0). 10 callers (pickaxe, uv_lamp, card_reader, torch_light, unlock_manager, …) |
| `show_restrict_message(message)` | 743 | `DeathLabel` | same style with TextAudio3D. Used for "Game saved", "Please wait", interdiction messages |
| `hide_restrict_message()` | 910 | | |
| `show_autosave_notification()` | 915 | `PlayerHUD/save_label` | small label, fixed text (the `VISUALS_AUTOSAVE` translation plus an ellipsis) |
| `show_hold_progress(p: float, text := "")` / `hide_hold_progress()` | 1042 / 1057 | runtime-built bar | |
| `_spawn_special_bonus_text(text, color)` | 446 | new Label added to `current_scene` | floats up and fades over 3 s. **This is the best existing "small toast"**. golf_club:988 calls it externally |
| `show_intro()`, `show_death()`, `show_idle_warning()`, `show_result(level,bonus)`, `show_roll_result(mult,payout)` | | | game-specific |
| `update_money_display(amount)` | 490 | `Money` label | connected to `GameState.money_updated` |

- `PIXEL_FONT` is a preload of `res://assets/PublicPixel-rv0pA.ttf` (hud.gd:52). Reuse it for a consistent mod UI style.
- `_ready` (84) connects GameState (`money_updated`, `panel_stack_changed`, `buff_updated`, `buff_expired`), `SaveManager.save_loaded`, and the ComboSystem signals (`combo_started`, `combo_updated`, `combo_ended`, `combo_broken`, `chain_combo_triggered`, `diversity_bonus_triggered`, `rhythm_bonus_triggered`, `mega_combo_activated`).
- **Recommendation:** the mod toast API should **own its own CanvasLayer** (high `layer`, `process_mode=ALWAYS`, parented to `/root` so it survives scene changes and also works in the main menu), and use `PIXEL_FONT` with a VBox stack of labels. Offer `hud.show_notification_message` only as a "big banner" passthrough when `get_first_node_in_group("HUD")` exists, because it shakes the screen and plays a sound. All HUD methods assume `main_camera` exists (`main_camera.apply_screenshake` is called without a null check), so never call them outside World.

---

## 6. Tools and held items

Every tool scene root is a RigidBody3D. No tool declares a signal. All of them reparent themselves under the Camera3D in `equip()`.

| Scene | Script | Root groups | Notable API |
|---|---|---|---|
| remote.tscn | remote.gd | draggable, equipable, remote, tool | `remote_lmb_pressed`, `cycle_channel`, `try_interact_with_target`, `try_link_tool`, `unlink_tool`, `unlink_all`, `is_tool_linked`, `remote_toggle`. Channel state is **global** in `GameState.remote_channels / remote_channel_states / remote_max_channels / remote_slots_per_channel` (signals `GameState.remote_channel_toggled(channel_idx:int,state:bool)`, `remote_tier_changed`) |
| golf_club.tscn | golf_club.gd | draggable, equipable, golf_club, metal, toggle, toy | own `_input` while equipped. `State{IDLE,AIM}`. Sets meta `golf_aim_mode` on the camera **and** on `get_first_node_in_group("player")`. Connects `BottomMaw.product_consumed`. Hole-in-one awards `GameState.add_money` plus `hud._spawn_special_bonus_text` |
| broom.tscn / broom2.tscn | broom.gd | broom, draggable, equipable, toggle, tool, wood | `interact()` sweeps (trajectory preview) |
| vacuum.tscn / vacuum2.tscn | vacuum.gd / vacuum_2.gd (`extends "res://scripts/vacuum.gd"`) | draggable, equipable, toggle, tool, vacuum | `equipped_lmb_pressed/released`, `equipped_rmb_pressed`, `toggle_vacuum`, `_ingest`, `_release_one`, `get_bag_save_data()`, `apply_loaded_bag()`. Ingested bodies are **reparented** into internal `_storage` |
| pickaxe.tscn | pickaxe.gd | draggable, equipable, interact, pickaxe | `equipped_lmb_pressed/held`, `_resolve_hit()` uses `get_parent() as Camera3D`. `GameState.pickaxe_tier`, `pickaxe_found`. Connects `SaveManager.save_loaded`. `recover_to_home()` goes to group `pickaxe_rack` |
| orbit_tool.tscn | orbit_tool.gd | draggable, interact, orbit_tool, toggle, tool | not in `equipable` despite having equip/unequip. `toggle_orbit`, `_capture_body`, `_release_all`. Feeds group `cauldron` |
| tractor_beam.tscn | tractor_beam.gd | draggable, equipable, metal, toggle, tool, tractor_beam | `equipped_lmb_pressed -> toggle_beam`. Exports `pulls_player`, `player_pull_strength`. `_apply_player_pull` caches `get_first_node_in_group("player")` and calls `apply_external_force` |
| magnet.tscn / magnet2.tscn | magnet.gd / magnet_2.gd (`extends "res://scripts/magnet.gd"`) | draggable, metal, toggle, tool (+interact on magnet2) | not equipable. `toggle_magnet`, `_is_repell`. magnet.gd:83 checks `is_in_group("player")` to affect the player |
| uv_lamp.tscn | uv_lamp.gd | draggable, interact, toggle, uv_lamp (+adds interactable) | `collect_on_grab -> interact()`: sets `GameState.uv_unlocked`, `Steamworks.unlock_achievement("INVISIBLE")`, notification, `release_held_object`, `queue_free` |
| keycard.tscn | keycard.gd | draggable, interact, keycard | passive: pooled (`pool_id="keycard"`), `set_highlight`, `object_name`. Consumed by card_reader.gd |
| (world.tscn ToolTube) | tool_tube.gd | ToolTube | cosmetic wobble of `TubeTool1..7`. `trigger_wobble(moving_up := false)` is called by bottom_maw:305/372, debris:368 and fail_safe:53 |
| (unused) | draggable.gd | none | `this_name`, `value`, `object_name()`. Not attached to any scene |

Most tools come from `ObjectPoolManager.POOL_CONFIG` (object_pool_manager.gd:28-330). Pools are built in `ObjectPoolManager.initialize(loaded)`, which is called from `main_menu.gd:718` **after** our autoload. The pool container is `/root/ObjectPools`, so it lives outside World and pooled instances survive world reloads.

---

## 7. camera_pivot.gd is NOT the player's pivot

`scripts/camera_pivot.gd` is attached to `scenes/camera_pivot.tscn`, a **security camera** prop (RigidBody3D). It looks up the first node in group `head` (line 22) and turns to track the player's head every physics frame. It adds itself to the groups `destructible`, `security_camera` and `saveable_camera`, and has `destroy_camera()`, `get_save_data()` and `apply_saved_state(state)`. The player's `CameraPivot` node in world.tscn has no script.

---

## 8. Hook points (recommended strategy)

1. **World/player ready**: connect `get_tree().node_added` in our autoload and filter for `node.is_in_group("player")`. Groups from the .tscn are assigned before `node_added` fires. Alternatively, poll `get_tree().current_scene.name == "World"`. Then `await node.ready` and resolve `MainCamera` and `InteractRay` from the player (`player.get_node("CameraPivot/MainCamera")`) and the HUD from the group. This needs no script replacement.
2. **Grab/drop/throw/equip events**: poll in our `_physics_process`. Keep `prev_picked`/`prev_equipped` and diff `cam.picked_object`/`cam.equipped_item` each physics frame, then emit our own `held_changed(old,new)` and `equipped_changed(old,new)`. To tell a throw from a drop, check the `player_throw_time` meta (products only) or a velocity spike. This is zero-risk and robust to game updates.
3. **Precise interaction events (pre/post, cancellable)**: wrap main_camera.gd using `take_over_path`. Load `res://scripts/main_camera.gd`, create a subclass script that `extends` it and overrides `pick_object()`, `_begin_carry()`, `drop_object(force)`, `release_held_object()` and `_do_interact()`, then call `take_over_path("res://scripts/main_camera.gd")`. **This must happen in our autoload before world.tscn is loaded** (LoadingScreen loads it from main_menu). main_camera.gd is not preloaded by any autoload, so this is feasible. The inline throw block in `handle_input()` cannot be intercepted without overriding the whole of `handle_input()` (about 220 lines). Prefer polling for throws.
4. **Movement modifiers**: write the player's tunables directly (`player.slide_boost` etc.), use `apply_external_force/impulse`, `teleport_to`, `respawn_safe`, and the meta `golf_aim_mode` (blocks movement). The constants `BASE_SPEED`, `SPRINT_MULTIPLIER` and `JUMP_VELOCITY` cannot be changed at runtime. Changing them requires a take_over_path subclass of player_controller.gd that overrides `_physics_process` (a full copy, which is fragile). Speed can be adjusted indirectly through `GameState.upgrades["sprint"]["level"]`.
5. **HUD/toast**: use our own CanvasLayer (see §5). For the "interact label" style, write to `HUD/PlayerHUD/interact_label`. Note that interact_ray rewrites it every frame while a target is focused.
6. **Custom interactables/tools**: no hook needed. Implement the duck-typed contract in §3 and add the groups. Spawn through `get_tree().current_scene.add_child`, or register with ObjectPoolManager (see the pool map).
7. **Death/respawn**: `BottomMaw` signal `product_consumed(product_type: String, nutrition_value: int, body_id: int)` (bottom_maw.gd:11). For the player the signal is not emitted with "player" (it goes through `_handle_body_cleanup`). To detect respawn, take over player_controller.gd and override `respawn_safe()`/`teleport_to_transform()`, or poll for position jumps. HUD `show_death()` is called from bottom_maw:312.
8. **Settings/input**: `MenuManager.settings_changed`, `InputManager.input_device_changed(is_gamepad: bool)` and `InputManager.bindings_changed` can be connected directly (autoloads exist before us).

### take_over_path caveats
- It only affects loads that happen afterwards. Scripts already compiled into a cached PackedScene keep the old script. World and the tool scenes are loaded only after the main menu (`LoadingScreen.load_resources_then_scene`), so taking over in our autoload's `_init`/`_ready` is early enough.
- `vacuum_2.gd` and `magnet_2.gd` use `extends "res://scripts/vacuum.gd"` / `"res://scripts/magnet.gd"`. If you take over the base, the subclass resolves to **our** override when it is compiled later. The override must extend the *original* loaded resource (not its path), or you get a cyclic inheritance.
- None of the subsystem scripts is an autoload, and none is preloaded by an autoload script (verified by grep). Autoload singletons the subsystem depends on (`GameState`, `SaveManager`, `MenuManager`, `InputManager`, `ObjectPoolManager`, `Steamworks`, `ResourceWarmer`) are already instantiated before our loader and **cannot** be taken over.

---

## 9. Single-local-player assumptions (blockers for Steam multiplayer)

- `get_first_node_in_group("player")` appears in 26 scripts and `"main_camera"` in 28. Both always resolve to the one local player. Examples: tractor_beam pull, golf_club aim meta, gravity_inverter, fall_sequence, pause_menu respawn, save_manager position, spring pads, fans, elevator.
- `is_in_group("player")` body checks appear in 16 scripts (bumper, fan, fan_3, magnet, spring_pad, press, bottom_maw, …). A remote-player puppet **must not** be in group `"player"` unless these interactions are meant to apply to it locally. Use a separate `"remote_player"` group, and decide per interaction which peer is authoritative.
- `get_viewport().get_camera_3d()` (6 scripts) and `get_first_node_in_group("head")` (security cameras) track only the local camera.
- `main_camera` holds the only carry state (`picked_object`, `equipped_item`). Carrying works by writing `linear_velocity` every physics frame on the local machine. This needs ownership/authority transfer of the RigidBody for netcode: only the carrier simulates it, and the others receive transforms. The joint `node_b` and the metas (`_held_gravity_scale`, `_held_inertia`, `_held_contact_monitor`, `rider_pending_frame`, `piston_rider`, `player_throw_time`) are per-body. They must be replicated or re-derived on authority handoff.
- Equip **reparents the tool node under the local Camera3D** and zeroes its collision. A remote player's equipped tool would need a proxy attachment on the puppet. The real node can't be under two cameras.
- Remote channels, panel stack, upgrades, money, `uv_unlocked`, `torch_unlocked`, `pickaxe_tier`/`pickaxe_found` are **global in GameState**. These are effectively host-owned shared state. Upgrade levels (`GameState.upgrades[...]`) gate player abilities (sprint/crouch/slide/jump/throw/equip/snap_grid/prop_surf/reset_rotation/sticky tools), so they apply to everyone equally unless they are made per-player.
- HUD methods are single-screen. `show_notification_message` and friends screen-shake the local camera. A network "toast to all" should be a mod RPC that calls the local toast on each peer.
- Input is polled globally (`Input.is_action_just_pressed`) inside `main_camera.handle_input()` and `player_controller._physics_process`. A puppet using these scripts would react to local input. Remote players must be lightweight puppets (no player_controller.gd / main_camera.gd), not duplicated PlayerControllers.
- `player_controller._ready()` calls `GameState.start_game()` and triggers save loading, so a second instance would start the game twice.
- The save stores only one player position (`_save_player_position`).
- Pause (`get_tree().paused`, `MenuManager.game_paused`) stops the local physics of the player and camera. In multiplayer, pause must not pause the tree.
- Steam: Steamworks autoload calls (`unlock_achievement`, e.g. uv_lamp:82) fire locally. That is fine per-peer, but host-driven events need to unlock on each client deliberately.

---

## 10. Suggested mod-API surface derived from this map

```
Pitt.player.get_node() -> CharacterBody3D | null        # group "player"
Pitt.player.get_camera() -> Camera3D | null             # group "main_camera"
Pitt.player.get_position()/teleport(pos)/respawn()      # teleport_to / respawn_safe
Pitt.player.push(force)/impulse(v)                      # apply_external_force / apply_external_impulse
Pitt.player.get_held()/get_equipped()                   # cam.picked_object / cam.equipped_item
Pitt.player.drop()                                      # cam.release_held_object()
Pitt.player.shake(i, t)                                 # cam.apply_screenshake
signals: player_ready(player), player_left, held_changed(old,new), equipped_changed(old,new),
         thrown(body), interacted(target)   (poll-based first; take_over_path upgrade later)
Pitt.hud.toast(text, color=WHITE, duration=3.0)         # own CanvasLayer, PIXEL_FONT
Pitt.hud.banner(text)                                   # passthrough to HUD.show_notification_message
Pitt.hud.hold_progress(p, text)/hide_hold_progress()
```
For multiplayer readiness, give every player-facing call an optional `peer_id` (defaulting to the local one) and route through a `PlayerRegistry` abstraction instead of `get_first_node_in_group("player")`. In single-player the registry holds one entry.
