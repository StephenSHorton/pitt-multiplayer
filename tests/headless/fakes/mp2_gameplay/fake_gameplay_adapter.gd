extends RefCounted
## Same members as game/gameplay_adapter.gd over a small per-peer test world:
## a player body (velocity / external_velocity / respawn_safe), a camera, a combo
## system with the game's fields and signals, a GameState with the mirrored
## members, a HUD, the terminal stub (upgradeUI) and a pool manager. Everything
## the modules do to the game is recorded here.

## the terminal: res://scripts/upgradeUI.gd when PittMultiplayer's extension took it
## over at boot, else that extension loaded on top of the stub
const UI_EXT := "res://gamedir/mods/PittMultiplayer/extensions/upgrade_ui_ext.gd"


class FPlayer extends CharacterBody3D:
	var external_velocity := Vector3.ZERO
	var respawns := 0

	func respawn_safe() -> void:
		respawns += 1


class FCamera extends Camera3D:
	var picked_object = null
	var equipped_item = null
	var releases := 0

	func release_held_object() -> void:
		releases += 1
		picked_object = null


class FCombo extends Node:
	signal combo_started(combo_level)
	signal combo_updated(combo_level, time_remaining, next_bonus)
	signal combo_ended(combo_level, total_bonus)
	signal combo_broken
	signal chain_combo_triggered(chain_level, bonus)
	signal diversity_bonus_triggered(product_types, bonus)
	signal rhythm_bonus_triggered(consistency, bonus)
	signal mega_combo_activated(multiplier)
	var current_combo: int = 0
	var combo_timer: float = 0.0
	var is_combo_active: bool = false
	var total_bonus: float = 0.0
	var current_chain_level: int = 0
	var diversity_multiplier: float = 1.0
	var rhythm_consistency: float = 0.0
	var mega_combo_progress: int = 0
	var mega_combo_active: bool = false
	var mega_combo_multiplier: float = 1.0
	var bowling_multiplier: float = 1.0
	var hits := 0
	var resets := 0

	func _physics_process(_delta: float) -> void:
		pass      # the game's ComboSystem runs its timer here (physics processing on)

	func get_current_time_window() -> float:
		return 3.0

	func _play_combo_hit_sound() -> void:
		hits += 1

	func reset_combo() -> void:
		resets += 1
		is_combo_active = false
		current_combo = 0
		combo_broken.emit()


class FGameState extends Node:
	signal panel_stack_changed(count: int, capacity: int)
	signal buff_updated(buff_type: String, multiplier: float, time_remaining: float, duration: float)
	signal buff_expired(buff_type: String)
	var remote_channels: Array = [[], [], []]
	var remote_channel_states: Array = [true, true, true]
	var active_buffs: Dictionary = {}
	var panel_stack: Array = []
	var mining_bank: int = 0
	var pickaxe_tier: int = 1
	var pickaxe_found: bool = false
	var uv_unlocked: bool = false
	var torch_unlocked: bool = false
	var keypad_revealed: bool = false
	var elevator_hacked: bool = false
	var secret_ending_seen: bool = false
	var remote_max_channels: int = 1
	var safety_violations: int = 0
	var spent: Array = []
	var rack_capacity := 4
	var channel_sets: Array = []

	func spend(amount) -> void:
		spent.append(int(amount))

	func record_safety_violation() -> void:
		safety_violations += 1

	func panel_rack_capacity() -> int:
		return rack_capacity

	## a fresh buff: full time left
	func activate_buff(buff_type: String, multiplier: float, duration: float) -> void:
		var fresh := {"multiplier": multiplier, "duration": duration}
		fresh["time_remaining"] = duration
		active_buffs[buff_type] = fresh
		emit_signal("buff_updated", buff_type, multiplier, duration, duration)

	func set_remote_channel_state(idx: int, on: bool) -> void:
		remote_channel_states[idx] = on
		channel_sets.append([idx, on])


class FHud extends CanvasLayer:
	var texts: Array = []
	var notes: Array = []

	func _spawn_special_bonus_text(text: String, color: Color):
		texts.append([text, color.to_html()])

	func show_notification_message(message):
		notes.append(String(message))


class FPooled extends RigidBody3D:
	var pool_id := ""


class FPools extends Node:
	var spawned: Array = []       # [pool_id, node]
	var recycled: Array = []
	var full := false

	func spawn(pool_id: String, pos: Vector3 = Vector3.ZERO, _rot = null) -> Node:
		if full:
			return null
		var b := FPooled.new()
		b.pool_id = pool_id
		b.position = pos
		add_child(b)
		spawned.append([pool_id, b])
		return b

	func recycle(n: Node) -> void:
		recycled.append(n)


var api = null
var world: Node3D = null
var player: FPlayer = null
var camera: FCamera = null
var combo: FCombo = null
var gs: FGameState = null
var hud_node: FHud = null
var ui_node: Node = null
var pools: FPools = null
var achievements: Array = []
var maw_fine_value := 7
var _tree: SceneTree = null


func _init(tree: SceneTree, parent: Node, p_name: String = "peer") -> void:
	_tree = tree
	world = Node3D.new()
	world.name = "GpWorld_%s_%d" % [p_name, Time.get_ticks_usec()]
	parent.add_child(world)
	player = FPlayer.new()
	player.name = "Player"
	world.add_child(player)
	camera = FCamera.new()
	camera.name = "Camera"
	player.add_child(camera)
	camera.position = Vector3(0, 0.65, 0)
	combo = FCombo.new()
	world.add_child(combo)
	gs = FGameState.new()
	world.add_child(gs)
	hud_node = FHud.new()
	world.add_child(hud_node)
	var ui_script: Script = load("res://scripts/upgradeUI.gd")
	if not ui_script.get_script_constant_map().has("_MP_FIXTURE_TOOLS"):
		ui_script = load(UI_EXT)
	ui_node = ui_script.new()
	ui_node.name = "UpgradeUI"
	world.add_child(ui_node)
	pools = FPools.new()
	world.add_child(pools)


func free_all() -> void:
	if world != null and is_instance_valid(world):
		world.queue_free()
	world = null


func kind() -> String:
	return "fake"


func tree() -> SceneTree:
	return _tree


func g(n: String) -> Object:
	match n:
		"ObjectPoolManager":
			return pools
		"GameState":
			return gs
		"ComboSystem":
			return combo
	return null


func group_first(_name: String) -> Node:
	return null


func current_scene() -> Node:
	return world


func world_root() -> Node:
	return world


func local_player() -> Node3D:
	return player


func main_camera() -> Camera3D:
	return camera


func hud() -> Node:
	return hud_node


func upgrade_ui() -> Node:
	return ui_node


func combo_system() -> Node:
	return combo


func game_state() -> Node:
	return gs


func local_aim() -> Dictionary:
	if not camera.is_inside_tree():
		return {}
	var t := camera.global_transform
	return {"o": t.origin, "d": -t.basis.z}


func camera_pivot_offset() -> Vector3:
	return Vector3(0, 0.65, 0)


func equipped_item() -> Object:
	return camera.equipped_item


func picked_object() -> Object:
	return camera.picked_object


func player_state() -> Dictionary:
	return {"vel": player.velocity, "ext": player.external_velocity, "pos": player.global_position,
		"golf": player.get_meta("golf_aim_mode", false)}


func restore_player_state(s: Dictionary) -> void:
	player.velocity = s.vel
	player.external_velocity = s.ext
	player.global_position = s.pos
	player.set_meta("golf_aim_mode", s.golf)


func player_impulse(v: Vector3) -> void:
	api.commands.execute("player.impulse", {"impulse": [v.x, v.y, v.z]})


func player_teleport(pos: Vector3) -> void:
	api.commands.execute("player.teleport", {"position": [pos.x, pos.y, pos.z]})


func player_respawn() -> void:
	player.respawn_safe()


func release_held_object() -> void:
	camera.release_held_object()


func spend(amount: int) -> void:
	gs.spend(amount)


func record_safety_violation() -> void:
	gs.record_safety_violation()


func reset_combo() -> void:
	combo.reset_combo()


func maw_fine() -> int:
	return maw_fine_value


func unlock_achievement(id: String) -> void:
	achievements.append(id)


func notify(key: String) -> void:
	hud_node.show_notification_message(key)


func gs_get(n: String, default_value = null):
	return gs.get(n) if n in gs else default_value


func gs_set(n: String, value) -> void:
	if n in gs:
		gs.set(n, value)
