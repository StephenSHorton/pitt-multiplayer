extends Node
## The Session surface the GAMEPLAY module uses (MP2-DESIGN 10.1), for one peer.
## send_world / send_msg are recorded and, when `link` is set (GpRig), delivered
## to the other side's gameplay module as JSON (round-tripped, like the wire).

const MpGate = preload("res://gamedir/mods/PittMultiplayer/gameplay/mp_gate.gd")

var api = null
var role := "host"
var my_peer := 1
var live := true
var modules: Dictionary = {}
var econ_host = null
var poses: Dictionary = {}        # peer -> avatar_pose dictionary
var in_game: Array = []           # host: in-game peers
var sent3: Array = []             # [peer, k, body] send_world
var sent0: Array = []             # [peer, k, body] send_msg
var logs: Array = []
var now_ms := -1                  # host_now override (-1 = wall clock)
## GpRig routing: host -> {peer: client session}; client -> host session
var link = null
var deliver := true
var mp2 := true


class FakeEcon extends RefCounted:
	var fields: Dictionary = {}   # name -> {read, apply}

	func register_field(n: String, read: Callable, apply: Callable) -> void:
		fields[n] = {"read": read, "apply": apply}


func _init(p_api = null, p_role: String = "host", p_peer: int = 1) -> void:
	api = p_api
	role = p_role
	my_peer = p_peer
	econ_host = FakeEcon.new()
	name = "FakeSession_%s_%d" % [p_role, p_peer]


func ext_live() -> bool:
	return live


func mp2_active() -> bool:
	return mp2


func get_module(n: String) -> Object:
	return modules.get(n, null)


func is_host() -> bool:
	return role == "host"


func my_peer_id() -> int:
	return my_peer


func host_now() -> int:
	return now_ms if now_ms >= 0 else Time.get_ticks_msec()


func in_game_peers() -> Array:
	return in_game.duplicate() if role == "host" else []


func slot_of(peer: int) -> int:
	return peer


func avatar_pose(peer: int) -> Dictionary:
	return poses.get(peer, {"ok": false, "pos": Vector3.ZERO, "yaw": 0.0, "pitch": 0.0, "vel": Vector3.ZERO,
		"t_ms": 0, "eye": Vector3.ZERO})


func set_pose(peer: int, pos: Vector3, yaw: float = 0.0, pitch: float = 0.0, vel: Vector3 = Vector3.ZERO) -> void:
	poses[peer] = {"ok": true, "pos": pos, "yaw": yaw, "pitch": pitch, "vel": vel, "t_ms": host_now(),
		"eye": pos + Vector3(0, 0.65, 0)}


func send_world(peer: int, k: String, body: Dictionary) -> Error:
	if role == "host" and peer == 0:
		for p in in_game:
			send_world(int(p), k, body)
		return OK
	if role == "host" and not (peer in in_game):
		return ERR_UNAVAILABLE
	sent3.append([peer, k, body.duplicate(true)])
	_route(peer, k, body)
	return OK


func send_msg(peer: int, k: String, body: Dictionary = {}) -> Error:
	sent0.append([peer, k, body.duplicate(true)])
	_route(peer, k, body)
	return OK


func _route(peer: int, k: String, body: Dictionary) -> void:
	if not deliver or link == null:
		return
	var wire = JSON.parse_string(JSON.stringify(body))
	if typeof(wire) != TYPE_DICTIONARY:
		push_error("FakeSession: %s is not JSON-safe" % k)
		return
	var target = null
	var from := my_peer
	if role == "host":
		target = link.get(peer, null) if typeof(link) == TYPE_DICTIONARY else null
	else:
		target = link
	if target == null:
		return
	var gp = target.get_module("gameplay")
	if gp != null:
		# one process, two peers: the gate must see the receiving peer while it applies
		var prev = MpGate.gp
		MpGate.gp = gp
		gp.on_msg(1 if role == "host" else from, k, wire)
		MpGate.gp = prev


func sent_of(k: String) -> Array:
	var out: Array = []
	for s in sent3 + sent0:
		if s[1] == k:
			out.append(s)
	return out


func log_info(m: String) -> void:
	logs.append("I " + m)


func log_warn(m: String) -> void:
	logs.append("W " + m)
