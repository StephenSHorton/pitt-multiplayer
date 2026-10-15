extends RefCounted
## Player effects (MP2-DESIGN 6.6).
## Host: host_exec(peer, c) runs c with MpGate.exec_peer = peer and, for a remote
## peer, wraps it in the PlayerEffectRedirect: the host player's velocity,
## external_velocity, position and golf_aim_mode meta are snapshotted before and
## restored after, and the deltas go to the peer as `pimp` (v from the velocity
## deltas, teleport when the position jumped more than TELEPORT_M). Example: a
## cannon equipped on a remote rig fires on the host; its recoil (cannon.gd:424,
## get_first_node_in_group("player")) would hit the host player, the redirect
## moves it to the owner.
## Impulses of one tick are summed per peer and sent at most SEND_HZ times a second.
## Client: pimp {v} -> player.impulse (local scope), {respawn} -> respawn_safe,
## {teleport} -> player.teleport.

const MpGate = preload("mp_gate.gd")

const TELEPORT_M := 1.0
const MIN_IMPULSE := 0.01
const SEND_HZ := 30.0

var gp = null
var _pending: Dictionary = {}       # peer -> {v: Vector3, src}
var _last_send_ms := 0
var redirected := 0


func _init(p_gp) -> void:
	gp = p_gp


func clear() -> void:
	_pending.clear()


func host_exec(peer: int, c: Callable) -> Variant:
	var prev := MpGate.exec_peer
	MpGate.exec_peer = peer
	var snap: Dictionary = {}
	if peer > 1 and gp.adapter != null:
		snap = gp.adapter.player_state()
	var r = c.call()
	if not snap.is_empty():
		var after: Dictionary = gp.adapter.player_state()
		if not after.is_empty():
			var dv: Vector3 = (after.vel - snap.vel) + (after.ext - snap.ext)
			var jumped: bool = after.pos.distance_to(snap.pos) > TELEPORT_M
			gp.adapter.restore_player_state(snap)
			if dv.length() > MIN_IMPULSE:
				queue_impulse(peer, dv, "redirect")
				redirected += 1
			if jumped:
				_send(peer, {"teleport": [after.pos.x, after.pos.y, after.pos.z], "src": "redirect"})
				redirected += 1
	MpGate.exec_peer = prev
	return r


func queue_impulse(peer: int, v: Vector3, src: String) -> void:
	if peer <= 1 or not v.is_finite():
		return
	var e: Dictionary = _pending.get(peer, {"v": Vector3.ZERO, "src": src})
	e.v += v
	_pending[peer] = e


func send_respawn(peer: int, src: String) -> void:
	_send(peer, {"respawn": true, "src": src})


func tick(now_ms: int) -> void:
	if _pending.is_empty():
		return
	if now_ms - _last_send_ms < int(1000.0 / SEND_HZ):
		return
	_last_send_ms = now_ms
	var batch := _pending
	_pending = {}
	for peer in batch:
		var v: Vector3 = batch[peer].v
		if v.length() > MIN_IMPULSE:
			_send(int(peer), {"v": [v.x, v.y, v.z], "src": String(batch[peer].src)})


func _send(peer: int, body: Dictionary) -> void:
	if gp.send_world(peer, "pimp", body) == OK:
		gp.count("pimp_tx")


func client_on_pimp(msg: Dictionary) -> void:
	gp.count("pimp_rx")
	if gp.adapter == null:
		return
	if bool(msg.get("respawn", false)):
		gp.adapter.player_respawn()
		return
	var tp = msg.get("teleport", null)
	if typeof(tp) == TYPE_ARRAY and tp.size() == 3:
		gp.adapter.player_teleport(Vector3(float(tp[0]), float(tp[1]), float(tp[2])))
		return
	var v = msg.get("v", null)
	if typeof(v) == TYPE_ARRAY and v.size() == 3:
		var imp := Vector3(float(v[0]), float(v[1]), float(v[2]))
		if imp.is_finite() and imp.length() < 200.0:
			gp.adapter.player_impulse(imp)
