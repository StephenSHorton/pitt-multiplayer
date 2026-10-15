extends RefCounted
## Per-player panel rack (D13, MP2-DESIGN 6.11). GameState.panel_stack is the
## carried rack of the LOCAL player; the host keeps one stack per remote peer.
## Client (main_camera_interact_ext): racking a panel sends rack_store {eid};
## withdrawing sends rack_withdraw {}. Host: store recycles that entity and pushes
## its pool id on the peer's stack; withdraw pops it, spawns the panel at the
## peer's rig hands and grants it to the peer as held (grab.grant, carry) once the
## entity is tracked. Each peer's stack is mirrored to that peer only, as an
## fx {kind: "rack", args: {stack}} on ch3, and written into its GameState.panel_stack
## (HUD count via panel_stack_changed).

const HAND_OFFSET_M := 0.8
const STORE_REACH_M := 6.0
const BUSY_METAS := ["consumed", "orbit_in_orbit", "pending_maw_recycle", "in_cannon_barrel", "in_vacuum_bag",
	"pitt_mp_press_stroke"]
const RETURN_SPREAD_M := 0.6

var gp = null
var _stacks: Dictionary = {}        # peer -> Array[String] of pool ids
var _pending: Dictionary = {}       # node instance id -> peer (spawned for a withdraw, grant on track)
var _ctr := {"rack_stored": 0, "rack_withdrawn": 0, "rack_refused": 0, "rack_returned": 0}


func _init(p_gp) -> void:
	gp = p_gp


func counters() -> Dictionary:
	return _ctr.duplicate()


func clear() -> void:
	_stacks.clear()
	_pending.clear()


func stack_of(peer: int) -> Array:
	return _stacks.get(peer, []).duplicate()


## The racked panels were recycled out of the shared world: a leaving player's
## stack comes back as panels at its last pose (else next to the host player),
## so a disconnect never deletes bought panels from the host's world and save.
func on_peer_left(peer: int) -> void:
	return_stack(peer)
	for k in _pending.keys():
		if int(_pending[k]) == peer:
			_pending.erase(k)


## Host: spawn every panel of peer's stack back into the world. Returns how many.
func return_stack(peer: int) -> int:
	var st: Array = _stacks.get(peer, [])
	_stacks.erase(peer)
	if st.is_empty() or gp.role != "host" or gp.adapter == null:
		return 0
	var opm = gp.adapter.g("ObjectPoolManager")
	if opm == null:
		return 0
	var base := Vector3.INF
	var pose: Dictionary = gp.avatar_pose(peer)
	if bool(pose.get("ok", false)):
		base = Vector3(pose.get("pos", Vector3.ZERO)) + Vector3(0, 0.6, 0)
	else:
		var lp = gp.adapter.local_player() if gp.adapter.has_method("local_player") else null
		if lp is Node3D:
			base = (lp as Node3D).global_position + Vector3(0, 0.6, 0)
	if base == Vector3.INF:
		return 0
	var n := 0
	for i in st.size():
		var off := Vector3(float(i % 3) - 1.0, floorf(i / 9.0) * 0.3, float(int(floorf(i / 3.0)) % 3) - 1.0) * RETURN_SPREAD_M
		if opm.spawn(String(st[i]), base + off) != null:
			n += 1
	_ctr.rack_returned += n
	return n


## Host, world stopping while the session's world is still the host's (teardown
## or a lost lobby): every remote stack comes back.
func return_all() -> void:
	for peer in _stacks.keys():
		return_stack(int(peer))


func _capacity() -> int:
	var gs = gp.adapter.game_state() if gp.adapter != null else null
	if gs != null and gs.has_method("panel_rack_capacity"):
		return int(gs.panel_rack_capacity())
	return 0


static func _pool_id_of(node: Object) -> String:
	if node == null or not is_instance_valid(node):
		return ""
	var pid = node.get("pool_id")
	return String(pid) if pid != null else ""


# ------------------------------------------------------------------ host commands

func cmd_store(args: Dictionary, ctx) -> Variant:
	if gp.role != "host" or not gp.gate_live():
		return ctx.fail("the rack needs the host's running world", "ERR_UNAVAILABLE")
	var peer := int(ctx.origin_peer) if ctx.is_remote else 1
	if peer <= 1:
		return ctx.fail("the host racks through its own camera", "ERR_DENIED")
	var r := store(peer, int(args.get("eid", 0)))
	if r != "":
		_ctr.rack_refused += 1
		return ctx.fail(r, "ERR_FAILED")
	return {"count": _stacks[peer].size()}


func store(peer: int, eid: int) -> String:
	var node = gp.node_of(eid)
	if node == null or not (node is RigidBody3D):
		return "unknown panel"
	if not (node.is_in_group("panel") or _pool_id_of(node).begins_with("panel")):
		return "not a panel"
	for m in BUSY_METAS:
		if bool(node.get_meta(m, false)):
			return "busy"
	var pose: Dictionary = gp.avatar_pose(peer)
	if bool(pose.get("ok", false)) and Vector3(pose.get("pos", Vector3.ZERO)).distance_to((node as Node3D).global_position) > STORE_REACH_M:
		return "too far"
	var g = gp.get_grab()
	# held or equipped by anyone else, the host player included (its camera would
	# keep a joint on a recycled node the pool hands out next)
	if g != null and String(g.hold_kind(eid)) != "" and int(g.owner_of(eid)) != peer:
		return "held by another player"
	var st: Array = _stacks.get(peer, [])
	if st.size() >= _capacity():
		return "rack full"
	var pid := _pool_id_of(node)
	if pid == "":
		return "no pool id"
	if g != null and int(g.owner_of(eid)) == peer:
		g.revoke(eid, "rack")
	gp.host_exec(peer, func():
		if node.has_method("unplace"):
			node.unplace()
		var opm = gp.adapter.g("ObjectPoolManager")
		if opm != null:
			opm.recycle(node))
	st.append(pid)
	_stacks[peer] = st
	_ctr.rack_stored += 1
	_send_stack(peer)
	return ""


func cmd_withdraw(_args: Dictionary, ctx) -> Variant:
	if gp.role != "host" or not gp.gate_live():
		return ctx.fail("the rack needs the host's running world", "ERR_UNAVAILABLE")
	var peer := int(ctx.origin_peer) if ctx.is_remote else 1
	if peer <= 1:
		return ctx.fail("the host racks through its own camera", "ERR_DENIED")
	var r := withdraw(peer)
	if r != "":
		_ctr.rack_refused += 1
		return ctx.fail(r, "ERR_FAILED")
	return {"count": _stacks.get(peer, []).size()}


func withdraw(peer: int) -> String:
	var st: Array = _stacks.get(peer, [])
	if st.is_empty():
		return "rack empty"
	var rig = gp.rig_of(peer)
	var pos := Vector3.ZERO
	if rig != null and rig.is_inside_tree():
		pos = rig.global_position - rig.global_transform.basis.z * HAND_OFFSET_M
	else:
		var pose: Dictionary = gp.avatar_pose(peer)
		if not bool(pose.get("ok", false)):
			return "no avatar"
		pos = Vector3(pose.get("eye", pose.pos))
	var pid := String(st.pop_back())
	var opm = gp.adapter.g("ObjectPoolManager")
	var inst = opm.spawn(pid, pos) if opm != null else null
	if inst == null:
		st.append(pid)
		return "pool full"
	_stacks[peer] = st
	_pending[inst.get_instance_id()] = peer
	var eid := int(gp.eid_of(inst))
	if eid > 0:
		_grant(eid, inst, peer)
	_ctr.rack_withdrawn += 1
	_send_stack(peer)
	return ""


## Host: BODIES tracked a node; a withdrawn panel is granted to its peer.
func on_entity_added(eid: int, node: Node) -> void:
	if gp.role != "host" or node == null:
		return
	var key := node.get_instance_id()
	if _pending.has(key):
		_grant(eid, node, int(_pending[key]))


func _grant(eid: int, node: Object, peer: int) -> void:
	_pending.erase(node.get_instance_id())
	var g = gp.get_grab()
	if g != null and g.has_method("grant"):
		g.grant(eid, peer, "held", true)


func _send_stack(peer: int) -> void:
	gp.send_world(peer, "fx", {"list": [{"kind": "rack", "args": {"stack": _stacks.get(peer, []).duplicate()}}]})


# ------------------------------------------------------------------ client

func client_apply_stack(stack) -> bool:
	if typeof(stack) != TYPE_ARRAY:
		return false
	var gs = gp.adapter.game_state() if gp.adapter != null else null
	if gs == null:
		return false
	var ps = gs.get("panel_stack")
	if typeof(ps) != TYPE_ARRAY:
		return false
	ps.clear()
	for s in stack:
		ps.append(String(s))
	if gs.has_signal("panel_stack_changed"):
		gs.emit_signal("panel_stack_changed", ps.size(), _capacity())
	return true


## Client: what main_camera_interact_ext calls instead of the local rack.
func client_store(panel: Object) -> bool:
	var eid := int(gp.eid_of(panel))
	if eid <= 0:
		return false
	var gs = gp.adapter.game_state()
	if gs != null and typeof(gs.get("panel_stack")) == TYPE_ARRAY and gs.get("panel_stack").size() >= _capacity():
		return false
	if gp.api == null or not ("commands" in gp.api):
		return false
	gp.api.commands.execute(gp.CMD_RACK_STORE, {"eid": eid})
	return true


func client_withdraw() -> bool:
	var gs = gp.adapter.game_state()
	if gs == null or typeof(gs.get("panel_stack")) != TYPE_ARRAY or gs.get("panel_stack").is_empty():
		return false
	if gp.api == null or not ("commands" in gp.api):
		return false
	gp.api.commands.execute(gp.CMD_RACK_WITHDRAW, {})
	return true
