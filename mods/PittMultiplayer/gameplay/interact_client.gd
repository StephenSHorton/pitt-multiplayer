extends RefCounted
## Client side of world.interact (MP2-DESIGN 6.2). MpGate.input / input_predict
## call forward() for a gated method reached from the local player's input
## dispatchers. The node is resolved to its replicated eid (a child collider walks
## up to the nearest tracked ancestor; the path from that ancestor travels as
## `p`), and the call goes to the host as
##   interact {eid, verb, p?, arg?, aim?}   or   tool_in {...}
## (tool_in when the node is the tool this player has equipped). The host runs the
## same method on its node.
## Repeats are collapsed: the same eid/path/verb within REPEAT_MS is sent once
## (the dispatchers call some methods every frame while a button is held, and a
## subclass extension may gate the same call twice), and hold-to-craft is sent as
## one start and one stop per hold.

const REPEAT_MS := 150
const HELD_REPEAT_MS := 100        # equipped_lmb_held while the button is held (10 Hz)
const LAST_MAX := 256

var gp = null
var _last: Dictionary = {}         # key -> ms
var _holding: Dictionary = {}      # "eid|p" -> true: start_crafting sent, stop pending
var _ctr := {"interact_tx": 0, "tool_in_tx": 0, "interact_unresolved": 0, "interact_collapsed": 0}


func _init(p_gp) -> void:
	gp = p_gp


func counters() -> Dictionary:
	return _ctr.duplicate()


func clear() -> void:
	_last.clear()
	_holding.clear()


static func _rel_path(b, eid: int, node: Object) -> String:
	var root = b.node_of(eid)
	if root != null and node is Node and root != node and (root as Node).is_ancestor_of(node):
		return String((root as Node).get_path_to(node))
	return ""


## A start_crafting was sent for this bench and its stop is pending.
func holding(node: Object) -> bool:
	if _holding.is_empty() or node == null or not is_instance_valid(node):
		return false
	var b = gp.get_bodies()
	if b == null:
		return false
	var eid := int(b.eid_of(node))
	return eid > 0 and _holding.has("%d|%s" % [eid, _rel_path(b, eid, node)])


## Called through MpGate (client, input scope).
func forward(node: Object, verb: String, args: Array) -> void:
	if node == null or not is_instance_valid(node):
		return
	var b = gp.get_bodies()
	if b == null:
		gp.count("no_bodies")
		return
	var eid := int(b.eid_of(node))
	if eid <= 0:
		_ctr.interact_unresolved += 1
		return
	var rel := _rel_path(b, eid, node)
	var hkey := "%d|%s" % [eid, rel]
	if verb == "start_crafting":
		if _holding.has(hkey):
			return
		_holding[hkey] = true
	elif verb == "stop_crafting":
		if not _holding.has(hkey):
			return
		_holding.erase(hkey)
	else:
		if verb == "interact" and node.has_method("start_crafting"):
			# a bench's interact() starts crafting on the host: its release must reach it too
			_holding[hkey] = true
		var key := "%s|%s" % [hkey, verb]
		var now := Time.get_ticks_msec()
		var window := HELD_REPEAT_MS if verb == "equipped_lmb_held" else REPEAT_MS
		if _last.has(key) and now - int(_last[key]) < window:
			_ctr.interact_collapsed += 1
			return
		if _last.size() >= LAST_MAX:
			_last.clear()
		_last[key] = now
	var kind := "tool_in" if _is_my_equipped(b.node_of(eid), node) else "interact"
	var msg := {"eid": eid, "verb": verb}
	if rel != "":
		msg["p"] = rel
	if not args.is_empty():
		msg["arg"] = encode_args(args, b)
	var aim: Dictionary = gp.adapter.local_aim() if gp.adapter != null else {}
	if not aim.is_empty():
		msg["aim"] = {"o": _v(aim.o), "d": _v(aim.d)}
	if gp.send_world(1, kind, msg) == OK:
		_ctr[kind + "_tx"] += 1


## Explicit sends from extensions outside the input scope (loop puzzle run end).
func send(node: Object, verb: String, args: Array) -> void:
	forward(node, verb, args)


func _is_my_equipped(root: Object, node: Object) -> bool:
	if gp.adapter == null:
		return false
	var eq = gp.adapter.equipped_item()
	if eq == null or not is_instance_valid(eq):
		return false
	return eq == root or eq == node


static func _v(v: Vector3) -> Array:
	return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]


## JSON-safe argument list: nodes as {"eid": n}, Vector3 as {"v3": [x,y,z]},
## PackedVector3Array as {"pv3": [x,y,z, ...]}.
static func encode_args(args: Array, bodies) -> Array:
	var out: Array = []
	for a in args:
		match typeof(a):
			TYPE_OBJECT:
				var eid := 0
				if a != null and is_instance_valid(a) and bodies != null:
					eid = int(bodies.eid_of(a))
				out.append({"eid": eid})
			TYPE_VECTOR3:
				out.append({"v3": _v(a)})
			TYPE_PACKED_VECTOR3_ARRAY:
				var flat: Array = []
				for p in a:
					flat.append_array([snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)])
				out.append({"pv3": flat})
			TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_NIL:
				out.append(a)
			TYPE_STRING_NAME:
				out.append(String(a))
			_:
				out.append(null)
	return out


## Inverse of encode_args on the host; null for anything malformed.
static func decode_args(raw, bodies) -> Variant:
	if raw == null:
		return []
	if typeof(raw) != TYPE_ARRAY or raw.size() > 4:
		return null
	var out: Array = []
	for a in raw:
		if typeof(a) == TYPE_DICTIONARY:
			if a.has("eid"):
				var n = bodies.node_of(int(a.eid)) if bodies != null and int(a.eid) > 0 else null
				if n == null:
					return null
				out.append(n)
			elif a.has("v3"):
				var v = _vec(a.v3)
				if v == null:
					return null
				out.append(v)
			elif a.has("pv3"):
				var f = a.pv3
				if typeof(f) != TYPE_ARRAY or f.size() % 3 != 0 or f.size() > 3 * 4096:
					return null
				var pv := PackedVector3Array()
				for i in range(0, f.size(), 3):
					var e = _vec([f[i], f[i + 1], f[i + 2]])
					if e == null:
						return null
					pv.append(e)
				out.append(pv)
			else:
				return null
		elif typeof(a) in [TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_NIL]:
			if typeof(a) == TYPE_FLOAT and (is_nan(a) or is_inf(a)):
				return null
			out.append(a)
		else:
			return null
	return out


static func _vec(a) -> Variant:
	if typeof(a) != TYPE_ARRAY or a.size() != 3:
		return null
	for c in a:
		if not (typeof(c) in [TYPE_INT, TYPE_FLOAT]) or is_nan(float(c)) or absf(float(c)) > 100000.0:
			return null
	return Vector3(float(a[0]), float(a[1]), float(a[2]))
