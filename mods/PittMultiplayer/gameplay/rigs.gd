extends RefCounted
## Remote camera rigs (MP2-DESIGN 6.3, 6.4), host only. One Camera3D
## (current = false) per remote in-game peer under <world>/PittMP_Rigs/<slot>,
## posed every physics frame from that peer's newest avatar frame extrapolated to
## now: eye position (Session.avatar_pose) + yaw/pitch. An interact/tool_in that
## carries an aim snaps the rig to the exact aim for AIM_HOLD_MS.
## Tools a remote peer equips (GRAB owner_changed kind "equipped") are equipped on
## that peer's rig with the game's own equip() inside host_exec, so they aim and
## act from the remote player's view; unequip() puts them back in the world.

const EXTRAP_MAX_S := 0.15
const AIM_HOLD_MS := 200
## main_camera.update_equipped_item_properties poses these groups for the local camera
## only (every frame); a rig copies it, in the same order: group -> [position, rotation deg].
## Every other tool uses its own equipped_offset / equipped_rotation_deg, like the game.
## (0.2.2: the broom kept equip()'s built-in rotation on a rig and swept to the left.)
const GROUP_POSES := [
	["broom", Vector3(0.4, -1.0, -1.5), Vector3(0, 180, 0)],
	["fan", Vector3(0, -1.0, -1.0), Vector3(0, 90, 0)],
	["remote", Vector3(0.3, -0.3, -0.5), Vector3(0, 90, 50)],
	["golf_club", Vector3(0.5, -0.8, -1.2), Vector3(0, 180, 0)],
]

var gp = null
var _rigs: Dictionary = {}          # peer -> Camera3D
var _aim_until: Dictionary = {}     # peer -> ms
var _equipped: Dictionary = {}      # eid -> peer
var _root: Node3D = null
var _ctr := {"rigs": 0, "rig_equips": 0, "rig_unequips": 0}


func _init(p_gp) -> void:
	gp = p_gp


func counters() -> Dictionary:
	var c := _ctr.duplicate()
	c.rigs = _rigs.size()
	return c


func rig_of(peer: int) -> Camera3D:
	var r = _rigs.get(peer, null)
	return r if r != null and is_instance_valid(r) else null


func equipped_on(peer: int) -> Array:
	var out: Array = []
	for eid in _equipped:
		if int(_equipped[eid]) == peer:
			out.append(eid)
	return out


func add_peer(peer: int) -> Camera3D:
	var existing := rig_of(peer)
	if existing != null:
		return existing
	var root := _ensure_root()
	if root == null:
		return null
	var cam := Camera3D.new()
	cam.name = "Rig_%d" % int(gp.session.slot_of(peer) if gp.session != null and gp.session.has_method("slot_of") else peer)
	cam.current = false
	cam.set_meta("pitt_mp_rig_peer", peer)
	root.add_child(cam)
	_rigs[peer] = cam
	_pose(peer, cam, true)
	return cam


func remove_peer(peer: int) -> void:
	for eid in equipped_on(peer):
		_unequip(int(eid), peer)
	var cam := rig_of(peer)
	_rigs.erase(peer)
	_aim_until.erase(peer)
	if cam != null:
		cam.queue_free()


## Every tool equipped on a rig goes back into the world (game unequip()) before
## the rigs go: a tool still parented to a freed rig camera would be freed with it.
func unequip_all() -> void:
	for eid in _equipped.keys():
		_unequip(int(eid), int(_equipped[eid]))


func clear() -> void:
	unequip_all()
	for p in _rigs.keys():
		var cam := rig_of(int(p))
		if cam != null:
			cam.queue_free()
	_rigs.clear()
	_aim_until.clear()
	_equipped.clear()
	if _root != null and is_instance_valid(_root):
		_root.queue_free()
	_root = null


func snap_aim(peer: int, origin: Vector3, dir: Vector3) -> void:
	var cam := rig_of(peer)
	if cam == null or not cam.is_inside_tree() or dir.length_squared() < 0.0001:
		return
	var d := dir.normalized()
	var up := Vector3.UP if absf(d.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
	cam.global_transform = Transform3D(Basis.looking_at(d, up), origin)
	_aim_until[peer] = Time.get_ticks_msec() + AIM_HOLD_MS


func physics(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	for p in _rigs.keys():
		var cam := rig_of(int(p))
		if cam == null:
			continue
		if int(_aim_until.get(p, 0)) > now:
			continue
		_pose(int(p), cam, false)
	for eid in _equipped.keys():
		var n = gp.node_of(int(eid))
		if n == null or not is_instance_valid(n):
			continue
		_hand_pose(n)


func _pose(peer: int, cam: Camera3D, _first: bool) -> void:
	if not cam.is_inside_tree():
		return
	var pose: Dictionary = gp.avatar_pose(peer)
	if not bool(pose.get("ok", false)):
		return
	var age_s := clampf(float(gp.host_now() - int(pose.get("t_ms", 0))) / 1000.0, 0.0, EXTRAP_MAX_S)
	var vel: Vector3 = pose.get("vel", Vector3.ZERO)
	var eye: Vector3 = pose.get("eye", pose.get("pos", Vector3.ZERO))
	var b := Basis.from_euler(Vector3(float(pose.get("pitch", 0.0)), float(pose.get("yaw", 0.0)), 0.0))
	cam.global_transform = Transform3D(b, eye + vel * age_s)


func _hand_pose(n: Node) -> void:
	if not (n is Node3D):
		return
	var n3 := n as Node3D
	for gpose in GROUP_POSES:
		if n3.is_in_group(String(gpose[0])):
			n3.position = gpose[1]
			n3.rotation_degrees = gpose[2]
			return
	if "equipped_offset" in n3:
		n3.position = n3.get("equipped_offset")
	if "equipped_rotation_deg" in n3:
		n3.rotation_degrees = n3.get("equipped_rotation_deg")


func on_owner_changed(eid: int, owner_peer: int, kind: String, _epoch: int) -> void:
	if kind == "equipped" and owner_peer > 1:
		if int(_equipped.get(eid, 0)) == owner_peer:
			return
		var cam := rig_of(owner_peer)
		if cam == null:
			cam = add_peer(owner_peer)
		var n = gp.node_of(eid)
		if cam == null or n == null or not n.has_method("equip"):
			return
		_equipped[eid] = owner_peer
		gp.host_exec(owner_peer, func(): n.equip(cam))
		_hand_pose(n)
		_ctr.rig_equips += 1
	elif _equipped.has(eid):
		_unequip(eid, int(_equipped[eid]))


func on_entity_removed(eid: int) -> void:
	_equipped.erase(eid)


func _unequip(eid: int, peer: int) -> void:
	_equipped.erase(eid)
	var n = gp.node_of(eid)
	if n == null or not is_instance_valid(n) or not n.has_method("unequip"):
		return
	if not bool(n.get("is_equipped")):
		return
	var world = gp.adapter.current_scene() if gp.adapter != null else null
	if world == null:
		return
	var drop: Vector3 = (n as Node3D).global_position if n is Node3D else Vector3.ZERO
	gp.host_exec(peer, func(): n.unequip(world, drop))
	_ctr.rig_unequips += 1


func _ensure_root() -> Node3D:
	if _root != null and is_instance_valid(_root) and _root.is_inside_tree():
		return _root
	var parent: Node = gp.world_parent()
	if parent == null:
		return null
	var existing := parent.get_node_or_null("PittMP_Rigs") as Node3D
	if existing != null:
		_root = existing
		return _root
	_root = Node3D.new()
	_root.name = "PittMP_Rigs"
	parent.add_child(_root)
	return _root
