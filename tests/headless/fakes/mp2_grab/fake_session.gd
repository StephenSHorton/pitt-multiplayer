extends RefCounted
## GRAB's double of the Session module registry (MP2-DESIGN 10.1) plus a tiny
## in-memory network (FakeNet) joining one host and N clients. ch3 is reliable
## and ordered per direction; ch2 (frame kind 5) can drop. Every JSON message
## goes through JSON.stringify/parse like the real wire (numbers come back as
## floats). Delivery happens in FakeNet.pump(), optionally after a latency on
## the shared fake clock.


class FakeNet extends RefCounted:
	var sessions: Dictionary = {}     # peer -> FakeSession
	var clock_ms := 10000
	var latency_ms := 0
	var drop_unreliable := 0.0        # 0..1
	var rng := RandomNumberGenerator.new()
	var q: Array = []                 # [{at, from, to, k, msg} | {at, from, to, raw}]
	var log: Array = []               # every delivered JSON message [from, to, k, msg]

	func _init() -> void:
		rng.seed = 7

	func now() -> int:
		return clock_ms

	func advance(ms: int) -> void:
		clock_ms += ms

	func add(s) -> void:
		sessions[s.peer] = s
		s.net = self

	func post(from: int, to: int, k: String, body: Dictionary) -> void:
		var msg := body.duplicate(true)
		msg["k"] = k
		var wire = JSON.parse_string(JSON.stringify(msg))
		q.append({"at": clock_ms + latency_ms, "from": from, "to": to, "k": k, "msg": wire})

	func post_raw(from: int, to: int, bytes: PackedByteArray) -> void:
		if drop_unreliable > 0.0 and rng.randf() < drop_unreliable:
			return
		q.append({"at": clock_ms + latency_ms, "from": from, "to": to, "raw": bytes})

	## Delivers everything due (in send order). Returns the number delivered.
	func pump() -> int:
		var n := 0
		var guard := 0
		while guard < 1000:
			guard += 1
			var idx := -1
			for i in q.size():
				if int(q[i].at) <= clock_ms:
					idx = i
					break
			if idx < 0:
				break
			var m: Dictionary = q[idx]
			q.remove_at(idx)
			var dst = sessions.get(int(m.to), null)
			if dst == null:
				continue
			n += 1
			if m.has("raw"):
				dst.deliver_raw(int(m.from), m.raw)
			else:
				log.append([int(m.from), int(m.to), String(m.k), m.msg])
				dst.deliver(int(m.from), String(m.k), m.msg)
		return n

	func sent(k: String, to: int = -1) -> Array:
		var out: Array = []
		for e in log:
			if e[2] == k and (to < 0 or e[1] == to):
				out.append(e[3])
		return out


var net: FakeNet = null
var peer := 1
var role := "host"
var modules: Array = []
var poses: Dictionary = {}           # peer -> {ok, pos, eye, ...}
var in_game: Array = []              # host: in-game client peers
var raw_sent := 0


func _init(p_role: String = "host", p_peer: int = 1) -> void:
	role = p_role
	peer = p_peer


func register_module(m: Object) -> void:
	modules.append(m)


func get_module(name: String) -> Object:
	for m in modules:
		if m.has_method("mod_name") and String(m.mod_name()) == name:
			return m
	return null


func is_host() -> bool:
	return role == "host"


func my_peer_id() -> int:
	return peer


func host_now() -> int:
	return net.clock_ms if net != null else 0


func in_game_peers() -> Array:
	return in_game.duplicate()


func slot_of(p: int) -> int:
	return p


func peer_of_slot(slot: int) -> int:
	return slot


func send_world(to: int, k: String, body: Dictionary) -> Error:
	if role == "host" and to == 0:
		for p in in_game:
			net.post(peer, int(p), k, body)
		return OK
	net.post(peer, to, k, body)
	return OK


func send_unreliable(to: int, bytes: PackedByteArray) -> Error:
	raw_sent += 1
	net.post_raw(peer, to, bytes)
	return OK


func send_msg(to: int, k: String, body: Dictionary = {}) -> Error:
	net.post(peer, to, k, body)
	return OK


func avatar_pose(p: int) -> Dictionary:
	return poses.get(p, {"ok": false})


func local_pose() -> Dictionary:
	return poses.get(peer, {"ok": false})


func set_pose(p: int, pos: Vector3) -> void:
	poses[p] = {"ok": true, "pos": pos, "eye": pos + Vector3(0, 0.65, 0), "yaw": 0.0, "pitch": 0.0,
		"vel": Vector3.ZERO, "t_ms": host_now()}


func deliver(from: int, k: String, msg: Dictionary) -> void:
	var src := from if role == "host" else 1
	for m in modules:
		if m.has_method("msg_kinds") and m.has_method("on_msg"):
			var kinds: Dictionary = m.msg_kinds()
			var list: Array = kinds.get("ch3_c2h" if role == "host" else "ch3_h2c", [])
			if k in list:
				m.on_msg(src, k, msg)


func deliver_raw(from: int, bytes: PackedByteArray) -> void:
	if bytes.is_empty():
		return
	for m in modules:
		if m.has_method("msg_kinds") and m.has_method("on_raw"):
			if int(bytes[0]) in m.msg_kinds().get("raw_c2h", []):
				m.on_raw(from, int(bytes[0]), bytes)
