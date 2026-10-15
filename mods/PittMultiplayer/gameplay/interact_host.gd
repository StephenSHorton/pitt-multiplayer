extends RefCounted
## Host side of world.interact / tool_in (MP2-DESIGN 6.2, 6.4). Validates the
## sender (in game), the target (a replicated eid, plus an optional path to a
## descendant), the verb (whitelist below, with argument shapes), the reach
## (avatar within NEAR_M, FAR_M for terminals and benches; tool_in only for a tool
## the sender has equipped) and a per-peer rate (20/s, burst 40), then runs the
## same method on the host node inside host_exec (MpGate.exec_peer +
## PlayerEffectRedirect). Afterwards the entity's meta is pushed at once.

const InteractClient = preload("interact_client.gd")

const NEAR_M := 4.5
const FAR_M := 6.0
const SLACK_M := 1.5
const RATE_PER_S := 20.0
const RATE_BURST := 40.0
const FAR_GROUPS := ["terminal", "workbench", "automated_workbench", "press", "push_button"]

## verb -> argument shapes ("b" bool, "i" int, "f" number, "n" replicated node, "pv" path)
const INTERACT_VERBS := {
	"interact": "", "toggle_fan": "", "toggle_magnet": "", "toggle_field": "", "toggle_beam": "",
	"toggle_vacuum": "", "toggle_orbit": "", "toggle_arm": "", "toggle_piston": "",
	"scroll_tune_up": "", "scroll_tune_down": "", "scroll_tune_cycle": "",
	"flip_mode": "b", "cycle_filter": "i", "cycle_preset": "i",
	"start_crafting": "", "stop_crafting": "", "turn_on": "", "turn_off": "", "hold_complete": "",
	"collect_on_grab": "", "mp_remote_run": "fpv",
}
## tool_in only (input to a tool the sender has equipped); INTERACT_VERBS are allowed too
const TOOL_VERBS := {
	"equipped_lmb_pressed": "", "equipped_lmb_released": "", "equipped_lmb_held": "",
	"equipped_rmb_pressed": "", "remote_lmb_pressed": "", "cycle_channel": "i",
	"try_interact_with_target": "n", "mp_golf_shot": "nf", "mp_remote_lmb": "b",
}
## no reach check (the run ends wherever the end area is; equipped tools sit on the rig)
const NO_REACH := ["mp_remote_run"]

var gp = null
var _bucket: Dictionary = {}        # peer -> {t, ms}
var _ctr := {"interact_ok": 0, "interact_rejected": 0, "interact_rate": 0, "interact_far": 0,
	"interact_bad_verb": 0, "interact_unknown": 0, "interact_not_owner": 0}
var last_reject := ""


func _init(p_gp) -> void:
	gp = p_gp


func counters() -> Dictionary:
	return _ctr.duplicate()


func clear() -> void:
	_bucket.clear()


func on_peer_left(peer: int) -> void:
	_bucket.erase(peer)


func tick(_now_ms: int) -> void:
	pass


func on_msg(peer: int, kind: String, msg: Dictionary) -> void:
	var r := handle(peer, kind, msg)
	if r != "":
		last_reject = r
		_ctr.interact_rejected += 1
		gp.count("interact_rejected")


## "" when executed, else the reject reason (tests).
func handle(peer: int, kind: String, msg: Dictionary) -> String:
	if peer <= 1 or not (peer in gp._in_game()):
		return "not_in_game"
	if not _take_token(peer):
		_ctr.interact_rate += 1
		return "rate"
	var b = gp.get_bodies()
	if b == null:
		return "no_bodies"
	var eid := int(msg.get("eid", 0))
	var root: Node = b.node_of(eid) if eid > 0 else null
	if root == null or not is_instance_valid(root):
		_ctr.interact_unknown += 1
		return "unknown"
	var target: Node = root
	var rel := String(msg.get("p", ""))
	if rel != "":
		if rel.begins_with("/") or rel.contains("..") or rel.length() > 200:
			return "bad_path"
		target = root.get_node_or_null(NodePath(rel))
		if target == null or not root.is_ancestor_of(target):
			return "bad_path"
	var verb := String(msg.get("verb", ""))
	var shape = INTERACT_VERBS.get(verb, null)
	if shape == null and kind == "tool_in":
		shape = TOOL_VERBS.get(verb, null)
	if shape == null or not target.has_method(verb):
		_ctr.interact_bad_verb += 1
		return "bad_verb"
	var args = InteractClient.decode_args(msg.get("arg", null), b)
	if args == null or not _shape_ok(String(shape), args):
		return "bad_args"
	if kind == "tool_in":
		var g = gp.get_grab()
		if g == null or int(g.owner_of(eid)) != peer or String(g.hold_kind(eid)) != "equipped":
			_ctr.interact_not_owner += 1
			return "not_owner"
	elif not (verb in NO_REACH):
		if not _in_reach(peer, root, target):
			_ctr.interact_far += 1
			return "far"
	var aim = msg.get("aim", null)
	if typeof(aim) == TYPE_DICTIONARY:
		var o = InteractClient._vec(aim.get("o", null))
		var d = InteractClient._vec(aim.get("d", null))
		if o != null and d != null:
			gp.rigs.snap_aim(peer, o, d)
	var t := target
	var a: Array = args
	gp.host_exec(peer, func(): return t.callv(verb, a))
	b.meta_dirty(eid)
	b.boost(eid, 2.0)
	_ctr.interact_ok += 1
	return ""


func _shape_ok(shape: String, args: Array) -> bool:
	if shape == "fpv":
		return args.size() == 2 and typeof(args[0]) in [TYPE_INT, TYPE_FLOAT] \
			and typeof(args[1]) == TYPE_PACKED_VECTOR3_ARRAY
	if args.size() != shape.length():
		return false
	for i in shape.length():
		var a = args[i]
		match shape[i]:
			"b":
				if typeof(a) != TYPE_BOOL:
					return false
			"i":
				if typeof(a) != TYPE_INT and not (typeof(a) == TYPE_FLOAT and a == floorf(a)):
					return false
				args[i] = clampi(int(a), -1, 1)
			"f":
				if not (typeof(a) in [TYPE_INT, TYPE_FLOAT]):
					return false
				args[i] = clampf(float(a), 0.0, 1.0)
			"n":
				if not (a is Node):
					return false
	return true


func _in_reach(peer: int, root: Node, target: Node) -> bool:
	var pose: Dictionary = gp.avatar_pose(peer)
	if not bool(pose.get("ok", false)):
		return false
	var n3 := target as Node3D
	if n3 == null:
		n3 = root as Node3D
	if n3 == null or not n3.is_inside_tree():
		return true
	var limit := NEAR_M
	for g in FAR_GROUPS:
		if target.is_in_group(g) or root.is_in_group(g):
			limit = FAR_M
	var eye: Vector3 = pose.get("eye", pose.get("pos", Vector3.ZERO))
	return eye.distance_to(n3.global_position) <= limit + SLACK_M


func _take_token(peer: int) -> bool:
	var now := Time.get_ticks_msec()
	var s: Dictionary = _bucket.get(peer, {"t": RATE_BURST, "ms": now})
	s.t = minf(RATE_BURST, float(s.t) + float(now - int(s.ms)) * RATE_PER_S / 1000.0)
	s.ms = now
	_bucket[peer] = s
	if s.t < 1.0:
		return false
	s.t -= 1.0
	return true
