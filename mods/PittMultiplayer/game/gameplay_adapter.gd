extends RefCounted
## GameplayAdapter: the GAMEPLAY stream's only reader/writer of game autoloads
## and world nodes outside the extensions (MP-DESIGN 1 rule 2, MP2 10.4). Every
## member is reached by name and listed in gameplay/contract_gameplay.gd.
## tests/headless/fakes/mp2_gameplay/fake_gameplay_adapter.gd implements the
## same members for headless suites.

var api = null


func setup(p_api) -> void:
	api = p_api


func kind() -> String:
	return "game"


func tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func g(n: String) -> Object:
	var t := tree()
	return t.root.get_node_or_null(NodePath(n)) if t != null else null


func group_first(name: String) -> Node:
	var t := tree()
	return t.get_first_node_in_group(name) if t != null else null


func current_scene() -> Node:
	var t := tree()
	return t.current_scene if t != null else null


## The world scene root while in the world, else null.
func world_root() -> Node:
	var s := current_scene()
	if s == null or s.scene_file_path != "res://scenes/world.tscn":
		return null
	return s


func local_player() -> Node3D:
	return group_first("player") as Node3D


func main_camera() -> Camera3D:
	return group_first("main_camera") as Camera3D


func hud() -> Node:
	return group_first("HUD")


func upgrade_ui() -> Node:
	return group_first("UpgradeUI")


func combo_system() -> Node:
	return g("ComboSystem")


func game_state() -> Node:
	return g("GameState")


## {o: Vector3, d: Vector3} of the local camera (interact aim), {} without one.
func local_aim() -> Dictionary:
	var cam := main_camera()
	if cam == null or not cam.is_inside_tree():
		return {}
	var t := cam.global_transform
	return {"o": t.origin, "d": -t.basis.z}


## The local player's CameraPivot offset from the body origin (rigs, MP2 6.3).
func camera_pivot_offset() -> Vector3:
	var p := local_player()
	if p == null:
		return Vector3(0, 0.65, 0)
	var pivot := p.get_node_or_null("CameraPivot") as Node3D
	return pivot.position if pivot != null else Vector3(0, 0.65, 0)


func equipped_item() -> Object:
	var cam := main_camera()
	return cam.get("equipped_item") if cam != null else null


func picked_object() -> Object:
	var cam := main_camera()
	return cam.get("picked_object") if cam != null else null


# ------------------------------------------------------------------ host player state (PlayerEffectRedirect)

func player_state() -> Dictionary:
	var p := local_player()
	if p == null:
		return {}
	var ev = p.get("external_velocity")
	return {"vel": p.get("velocity"), "ext": ev if ev is Vector3 else Vector3.ZERO,
		"pos": p.global_position, "golf": p.get_meta("golf_aim_mode", false)}


func restore_player_state(s: Dictionary) -> void:
	var p := local_player()
	if p == null or s.is_empty():
		return
	p.set("velocity", s.vel)
	if "external_velocity" in p:
		p.set("external_velocity", s.ext)
	if p.global_position.distance_to(s.pos) > 0.001:
		p.global_position = s.pos
	p.set_meta("golf_aim_mode", s.golf)


# ------------------------------------------------------------------ local player effects (client, pimp)

func player_impulse(v: Vector3) -> void:
	if api != null and "commands" in api and api.commands != null:
		api.commands.execute("player.impulse", {"impulse": [v.x, v.y, v.z]})


func player_teleport(pos: Vector3) -> void:
	if api != null and "commands" in api and api.commands != null:
		api.commands.execute("player.teleport", {"position": [pos.x, pos.y, pos.z]})


func player_respawn() -> void:
	var p := local_player()
	if p != null and p.has_method("respawn_safe"):
		p.respawn_safe()


func release_held_object() -> void:
	var camera := main_camera()
	if camera != null and camera.has_method("release_held_object"):
		camera.release_held_object()


# ------------------------------------------------------------------ money / stats (host)

func spend(amount: int) -> void:
	var gs := game_state()
	if gs != null and amount > 0:
		gs.spend(amount)


func record_safety_violation() -> void:
	var gs := game_state()
	if gs != null and gs.has_method("record_safety_violation"):
		gs.record_safety_violation()


func reset_combo() -> void:
	var cs := combo_system()
	if cs != null and cs.has_method("reset_combo"):
		cs.reset_combo()


func maw_fine() -> int:
	var maw := g("/root/World/BottomMaw")
	if maw == null:
		maw = group_first("BottomMaw")
	if maw != null and maw.has_method("_maw_fine"):
		return int(maw._maw_fine())
	return 1


# ------------------------------------------------------------------ achievements / notifications

func unlock_achievement(id: String) -> void:
	var st := g("Steamworks")
	if st != null and st.has_method("unlock_achievement"):
		st.unlock_achievement(id)


func notify(key: String) -> void:
	var h := hud()
	if h != null and h.has_method("show_notification_message"):
		h.show_notification_message(h.tr(key) if h.has_method("tr") else key)


# ------------------------------------------------------------------ GameState mirror fields (6.10)

func gs_get(name: String, default_value = null):
	var gs := game_state()
	if gs == null or not (name in gs):
		return default_value
	return gs.get(name)


func gs_set(name: String, value) -> void:
	var gs := game_state()
	if gs != null and name in gs:
		gs.set(name, value)
