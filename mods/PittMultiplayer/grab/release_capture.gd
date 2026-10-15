extends RefCounted
## Release / throw / equip detection (MP2-DESIGN 5.3, 5.5). Runs every physics
## frame after main_camera (GRAB's helper node, process_physics_priority 99)
## and diffs main_camera.picked_object / equipped_item:
##   picked A -> not A, equipped A          equip
##   picked A -> not A (not equipped)       release; a throw unless drop_object
##                                          ran for A (plain drop / forced drop),
##                                          judged by the fresh player_throw_time
##                                          meta (products) or a velocity jump > 2 m/s
##   equipped A -> picked A                 unequip
##   equipped A -> gone                     release
## A release is captured on the NEXT physics frame (the throw impulse and the
## deferred place() have run by then): {s, thrown, placed | panel_state, throw_meta}.

const GrabAdapter = preload("../game/grab_adapter.gd")

const THROW_JUMP_MS := 2.0

var sink = null                 # grab.gd: capture_released(node, info), capture_equipped(node), capture_unequipped(node, drop, s)
var _prev_picked: WeakRef = null
var _prev_equipped: WeakRef = null
var _prev_vel := Vector3.ZERO
var _dropped: Dictionary = {}   # instance id -> WeakRef: drop_object ran for it this frame
var _caps: Array = []           # [{node: WeakRef, thrown, v_before}]
var counters := {"releases": 0, "throws": 0, "equips": 0, "unequips": 0}


func _init(p_sink = null) -> void:
	sink = p_sink


## drop_object(force) is about to run for node (any reason except a throw).
func mark_drop(node: Node) -> void:
	if node != null:
		_dropped[node.get_instance_id()] = weakref(node)


## drop_object returned without dropping (invalid snap spot).
func unmark_drop(node: Node) -> void:
	if node != null:
		_dropped.erase(node.get_instance_id())


## Stop tracking node (it was force-unequipped or despawned by us).
func forget(node: Node) -> void:
	if node == null:
		return
	if _ref(_prev_equipped) == node:
		_prev_equipped = null
	if _ref(_prev_picked) == node:
		_prev_picked = null
	_dropped.erase(node.get_instance_id())


func reset() -> void:
	_prev_picked = null
	_prev_equipped = null
	_dropped.clear()
	_caps.clear()


func physics_tick(adapter, cam: Node) -> void:
	_flush_captures()
	var picked: RigidBody3D = adapter.picked(cam)
	var equipped: RigidBody3D = adapter.equipped(cam)
	var pp := _ref(_prev_picked)
	var pe := _ref(_prev_equipped)
	if pp != null and pp != picked:
		if equipped == pp:
			counters.equips += 1
			sink.capture_equipped(pp)
		else:
			var marked := _dropped.has(pp.get_instance_id())
			var thrown := false
			if not marked:
				thrown = GrabAdapter.throw_is_fresh(pp) or (GrabAdapter.velocity(pp) - _prev_vel).length() > THROW_JUMP_MS
			_caps.append({"node": weakref(pp), "thrown": thrown})
	elif pp == null and equipped != null and equipped != pe and picked != equipped:
		# picked and equipped within one frame (the equip key on a free body)
		counters.equips += 1
		sink.capture_equipped(equipped)
	if pe != null and pe != equipped:
		if picked == pe:
			counters.unequips += 1
			sink.capture_unequipped(pe, pe.global_position, GrabAdapter.body_state(pe))
		elif not _captured(pe):
			_caps.append({"node": weakref(pe), "thrown": false})
	# picked and dropped between two of our frames (pick + pause-menu release in one frame)
	for id in _dropped:
		var dn: Node = (_dropped[id] as WeakRef).get_ref()
		if dn != null and is_instance_valid(dn) and dn != pp and dn != picked and dn != equipped and not _captured(dn):
			_caps.append({"node": weakref(dn), "thrown": false})
	_dropped.clear()
	_prev_picked = weakref(picked) if picked != null else null
	_prev_equipped = weakref(equipped) if equipped != null else null
	_prev_vel = GrabAdapter.velocity(picked) if picked != null else Vector3.ZERO


## The captures queued last frame (the body has stepped once since the release).
func _flush_captures() -> void:
	if _caps.is_empty():
		return
	var caps := _caps
	_caps = []
	for c in caps:
		var node: Node = (c.node as WeakRef).get_ref()
		if node == null or not is_instance_valid(node) or not node.is_inside_tree():
			continue
		var info := {"s": GrabAdapter.body_state(node), "thrown": bool(c.thrown)}
		var pl := GrabAdapter.placement(node)
		for k in pl:
			info[k] = pl[k]
		if GrabAdapter.is_product(node):
			var tm := GrabAdapter.throw_meta(node)
			if not tm.is_empty():
				info["throw_meta"] = tm
		counters.releases += 1
		if bool(c.thrown):
			counters.throws += 1
		sink.capture_released(node, info)


func _captured(node: Node) -> bool:
	for c in _caps:
		if (c.node as WeakRef).get_ref() == node:
			return true
	return false


static func _ref(w: WeakRef) -> Node:
	if w == null:
		return null
	var o = w.get_ref()
	return o if o != null and is_instance_valid(o) else null
