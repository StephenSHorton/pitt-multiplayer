extends RefCounted
## PittPlayer: the local player (multiplayer will add get_players()).

const Serial = preload("../core/serial.gd")

var _core: Object = null
var _mod := ""


func _init(core: Object, mod_id: String) -> void:
	_core = core
	_mod = mod_id


func get_local() -> Node3D:
	if not _core.bridge.in_world:
		return null
	return _core.bridge.get_player() as Node3D


func get_local_id() -> int:
	var p = get_local()
	return _core.entities.id_of(p) if p != null else 0


func get_camera() -> Camera3D:
	var tree: SceneTree = _core.get_tree()
	if tree == null:
		return null
	return tree.get_first_node_in_group("main_camera") as Camera3D


func get_position() -> Vector3:
	var p = get_local()
	return p.global_position if p != null else Vector3.ZERO


func get_look_transform() -> Transform3D:
	var c = get_camera()
	return c.global_transform if c != null else Transform3D.IDENTITY


## A point in front of the camera (default 3 m).
func get_look_point(distance: float = 3.0) -> Vector3:
	var t := get_look_transform()
	return t.origin - t.basis.z * distance


func get_held() -> int:
	var c = get_camera()
	if c == null or not _core.feature_ok("camera"):
		return 0
	return _core.bridge._id_for(c.picked_object)


func get_equipped() -> int:
	var c = get_camera()
	if c == null or not _core.feature_ok("camera"):
		return 0
	return _core.bridge._id_for(c.equipped_item)


func get_focus() -> int:
	var c = get_camera()
	if c == null or not _core.feature_ok("camera"):
		return 0
	var ray = c.get_node_or_null("InteractRay")
	if ray == null or not ("last_collider" in ray):
		return 0
	return _core.bridge._id_for(ray.last_collider)


func teleport(pos: Vector3) -> RefCounted:
	return _core.commands.execute("player.teleport", {"position": Serial.to_json_safe(pos)}, _mod)


func impulse(v: Vector3) -> RefCounted:
	return _core.commands.execute("player.impulse", {"impulse": Serial.to_json_safe(v)}, _mod)


## Local only (not a command): blocks movement via the game's golf_aim_mode meta.
func set_movement_locked(locked: bool) -> void:
	_core.set_movement_lock(_mod, locked)
