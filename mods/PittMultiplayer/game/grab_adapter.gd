extends RefCounted
## GrabAdapter: the ONLY file of the GRAB stream that reads or writes game
## nodes (MP2-DESIGN 5, MP1 rule 2). It touches the local main_camera (the
## carry state the game keeps there) and the carried bodies. Every game member
## used here is in grab/contract_grab.gd. Tests drive it with a stand-in
## camera (tests/headless/fakes/mp2_grab/stubs/scripts/main_camera.gd) through
## `camera_override`.

## Metas the game uses as protocol while a body is being taken by a machine
## (MP2-DESIGN 5.2): such a body is never grabbed in a session.
const BUSY_METAS := ["consumed", "pending_maw_recycle", "in_cannon_barrel", "in_vacuum_bag"]
const BUSY_GROUPS := ["terminal_pull"]
const DEFAULT_MAX_GRAB := 3.5
## a throw sets player_throw_time at the release frame; older stamps are not this throw
const THROW_FRESH_S := 0.5

var camera_override: Node = null


func camera() -> Node:
	if camera_override != null:
		return camera_override if is_instance_valid(camera_override) else null
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var cam := tree.get_first_node_in_group("main_camera")
	return cam if cam != null and cam.is_inside_tree() else null


func picked(cam: Node) -> RigidBody3D:
	if cam == null or not is_instance_valid(cam):
		return null
	var o = cam.get("picked_object")
	return o if o is RigidBody3D and is_instance_valid(o) else null


func equipped(cam: Node) -> RigidBody3D:
	if cam == null or not is_instance_valid(cam):
		return null
	var o = cam.get("equipped_item")
	return o if o is RigidBody3D and is_instance_valid(o) else null


func max_grab_distance() -> float:
	var cam := camera()
	if cam != null:
		var v = cam.get("max_grab_distance")
		if typeof(v) in [TYPE_FLOAT, TYPE_INT] and float(v) > 0.0:
			return float(v)
	return DEFAULT_MAX_GRAB


## The game's safe drop (main_camera.gd:982 -> drop_object(true)).
func release_held(camera: Node) -> void:
	if is_instance_valid(camera) and camera.has_method("release_held_object"):
		camera.release_held_object()


## Revoke/deny of an equipped body: the game's own unequip of the item (the
## handle_input equip toggle without picking it up again), then clear the slot.
func force_unequip(cam: Node) -> void:
	var item := equipped(cam)
	if item == null:
		return
	var c3 := cam as Node3D
	var drop := c3.global_position - c3.global_transform.basis.z * 1.0 if c3 != null else item.global_position
	var tree := cam.get_tree()
	var world: Node3D = tree.current_scene as Node3D if tree != null else null
	if world == null:
		world = cam.get_parent() as Node3D
	if item.has_method("unequip") and world != null:
		item.unequip(world, drop)
	cam.set("equipped_item", null)
	var ray = cam.get("interact_ray")
	if ray != null and is_instance_valid(ray) and ray.has_method("refresh_controls"):
		ray.refresh_controls()


static func body_state(node: Node) -> Dictionary:
	var b := node as RigidBody3D
	if b == null or not b.is_inside_tree():
		var n3 := node as Node3D
		if n3 == null:
			return {}
		return {"p": n3.global_position, "q": n3.global_transform.basis.get_rotation_quaternion(),
			"l": Vector3.ZERO, "a": Vector3.ZERO}
	return {"p": b.global_position, "q": b.global_transform.basis.get_rotation_quaternion(),
		"l": b.linear_velocity, "a": b.angular_velocity}


static func velocity(node: Node) -> Vector3:
	var b := node as RigidBody3D
	return b.linear_velocity if b != null else Vector3.ZERO


## {placed: bool} for tools, {panel_state: int} for panels (the save schema's
## split, save_manager.gd:710-713), {} otherwise.
static func placement(node: Node) -> Dictionary:
	if node == null or not is_instance_valid(node):
		return {}
	if "state" in node and "PanelState" in node:
		return {"panel_state": int(node.get("state"))}
	if "placed" in node:
		return {"placed": bool(node.get("placed"))}
	return {}


static func now_s() -> float:
	return Time.get_ticks_msec() / 1000.0


## {age_ms, pos: Vector3} when the body carries a fresh player throw stamp
## (main_camera.gd:602-604), else {}.
static func throw_meta(node: Node) -> Dictionary:
	if node == null or not is_instance_valid(node) or not node.has_meta("player_throw_time"):
		return {}
	var t := float(node.get_meta("player_throw_time", 0.0))
	if t <= 0.0:
		return {}
	var age := now_s() - t
	if age < 0.0 or age > 10.0:
		return {}
	var pos = node.get_meta("player_throw_position", Vector3.ZERO)
	return {"age_ms": int(age * 1000.0), "pos": pos if pos is Vector3 else Vector3.ZERO}


static func throw_is_fresh(node: Node) -> bool:
	var m := throw_meta(node)
	return not m.is_empty() and int(m.age_ms) <= int(THROW_FRESH_S * 1000.0)


## Host: restore the thrower's stamp so the maw's long-range feed stat counts
## (bottom_maw.gd:222-230 reads both metas).
static func set_throw_meta(node: Node, age_ms: int, pos: Vector3) -> void:
	if node == null or not is_instance_valid(node):
		return
	node.set_meta("player_throw_time", maxf(now_s() - age_ms / 1000.0, 0.001))
	node.set_meta("player_throw_position", pos)


## "" or the reason a machine owns the body right now.
static func busy_reason(node: Node) -> String:
	if node == null or not is_instance_valid(node):
		return "unknown"
	for m in BUSY_METAS:
		if node.has_meta(m) and node.get_meta(m) != null and node.get_meta(m) != false:
			return "busy"
	for gname in BUSY_GROUPS:
		if node.is_in_group(gname):
			return "busy"
	return ""


static func is_product(node: Node) -> bool:
	return node != null and is_instance_valid(node) and node.is_in_group("product")


## Host: the client placed the body on release. Panels and feed fixtures have
## force_place (no contact test); other tools run their own place(), which may
## decide differently on the host (the host result wins, BODIES sends it).
static func host_place(node: Node, info: Dictionary) -> void:
	if node == null or not is_instance_valid(node):
		return
	var want := int(info.get("panel_state", 0)) == 1 or bool(info.get("placed", false))
	if not want:
		return
	if node.has_method("force_place"):
		node.force_place()
	elif node.has_method("place"):
		node.place()


## Host: a client takes a placed body (its own copy ran unplace() in _begin_carry).
static func host_unplace(node: Node) -> void:
	if node != null and is_instance_valid(node) and node.has_method("unplace"):
		node.unplace()
