extends RefCounted
## Host ownership table (MP2-DESIGN 5.1-5.6), host-authoritative.
##   eid -> Row {owner_peer, kind "" | "held" | "equipped", epoch (u16, wraps), since_ms, last_rx_ms}
## Default (no row): owner 1 (host), kind "", epoch 0. Every change bumps the
## epoch, is pushed to BODIES (set_owner_view), emitted as grab.owner_changed
## and sent as `own` on ch3: the addressed peer gets grant/deny/revoke, every
## other world peer gets `set`. Every `own` message carries the row AFTER the
## event: {ev, eid, peer (owner), kind, epoch, reason?, s?, carry?}.
## The host's own player (peer 1) goes through the same table (5.6, D12).

const HeldStream = preload("held_stream.gd")
const GrabAdapter = preload("../game/grab_adapter.gd")

const HOST := 1
const SILENCE_MS := 1500
const FAR_MS := 500
const REQ_SLACK_M := 2.0
const HELD_SLACK_M := 2.5
const REL_MAX_SPEED := 60.0
const BOOST_S := 2.0
const EPOCH_MASK := 0xFFFF
## a host-originated grant (rack withdraw) waits for the spawn + carry on the client
const GRANT_GRACE_MS := 1000
## revoke reasons where the host body goes back to its last streamed state;
## anything else (consumed, cannon, vacuum, terminal, press, cauldron: the game
## already took the body) only stops the follower (host_release(eid, {})).
const RELEASE_REASONS := ["silence", "far", "left", "ending", "host"]
const PLACE_DELAY_FRAMES := 2


class Row extends RefCounted:
	var eid := 0
	var owner := 1
	var kind := ""
	var epoch := 0
	var since_ms := 0
	var last_rx_ms := 0
	var await_ack := false       # granted, the owner has not shown it saw the grant yet
	var last_state: Dictionary = {}
	var far_since_ms := 0
	var last_frame_far := false


var grab = null                  # grab.gd (session, bodies, clock, signal)
var rows: Dictionary = {}        # eid -> Row
var deny_rules: Array = []       # Callable(eid, node, peer) -> String
var last_drop: Dictionary = {}   # eid -> {drop: Vector3, s: Dictionary} of the newest own_unequip
var _place_q: Array = []         # [{eid, peer, info, frames}]
var counters := {"grants": 0, "denies": 0, "revokes": 0, "releases": 0, "held_rx": 0, "held_rejected": 0,
	"held_early": 0, "rel_ignored": 0, "equip_ignored": 0, "host_refused": 0, "own_tx": 0,
	"rel_clamped": 0}
var deny_reasons: Dictionary = {}
var revoke_reasons: Dictionary = {}


func _init(p_grab = null) -> void:
	grab = p_grab


# ------------------------------------------------------------------ queries (10.3)

func owner_of(eid: int) -> int:
	return (rows[eid] as Row).owner if rows.has(eid) else HOST


func hold_kind(eid: int) -> String:
	return (rows[eid] as Row).kind if rows.has(eid) else ""


func epoch_of(eid: int) -> int:
	return (rows[eid] as Row).epoch if rows.has(eid) else 0


func row(eid: int) -> Row:
	if not rows.has(eid):
		var r := Row.new()
		r.eid = eid
		rows[eid] = r
	return rows[eid]


func add_deny_rule(rule: Callable) -> void:
	if rule.is_valid() and not deny_rules.has(rule):
		deny_rules.append(rule)


## "" or the deny reason for peer taking eid (5.2 step 2).
func can_take(eid: int, peer: int) -> String:
	var bodies = grab.bodies()
	if bodies == null or not bodies.is_replicated(eid):
		return "unknown"
	var node: Node = bodies.node_of(eid)
	if node == null or not is_instance_valid(node) or not node.is_inside_tree():
		return "unknown"
	if rows.has(eid):
		var r: Row = rows[eid]
		if r.kind != "" and r.owner != peer:
			return "owned"
	if GrabAdapter.busy_reason(node) != "":
		return "busy"
	if peer != HOST:
		if not grab.peer_in_game(peer):
			return "not_in_game"
		var pose: Dictionary = grab.pose_of(peer)
		if not bool(pose.get("ok", false)):
			return "far"
		var n3 := node as Node3D
		if n3 != null and _eye(pose).distance_to(n3.global_position) > grab.max_grab_distance() + REQ_SLACK_M:
			return "far"
	for rule in deny_rules:
		if not (rule as Callable).is_valid():
			continue
		var why = (rule as Callable).call(eid, node, peer)
		if typeof(why) == TYPE_STRING and String(why) != "":
			return String(why)
	return ""


static func _eye(pose: Dictionary) -> Vector3:
	var e = pose.get("eye", null)
	if e is Vector3:
		return e
	return pose.get("pos", Vector3.ZERO)


# ------------------------------------------------------------------ messages from clients

func on_own_req(peer: int, msg: Dictionary) -> void:
	var eid := int(msg.get("eid", 0))
	if eid <= 0:
		return
	if rows.has(eid):
		var cur: Row = rows[eid]
		if cur.owner == peer and cur.kind != "":
			# a repeated request: answer with the current row, no new epoch
			_send(peer, _own_body("grant", cur))
			return
	var why := can_take(eid, peer)
	if why != "":
		counters.denies += 1
		deny_reasons[why] = int(deny_reasons.get(why, 0)) + 1
		var r := rows.get(eid) as Row
		var body := {"ev": "deny", "eid": eid, "peer": r.owner if r != null else HOST,
			"kind": r.kind if r != null else "", "epoch": r.epoch if r != null else 0, "reason": why}
		_send(peer, body)
		return
	_grant(eid, peer, "held", true, false)


func on_own_rel(peer: int, msg: Dictionary) -> void:
	var eid := int(msg.get("eid", 0))
	var r := rows.get(eid) as Row
	if r == null or not _owner_msg_ok(r, peer, int(msg.get("epoch", -1)), ["held", "equipped"]):
		counters.rel_ignored += 1
		return
	var s := HeldStream.state_from_json(msg.get("s"))
	if s.is_empty():
		s = _fallback_state(r)
	s = _clamp_release(r, peer, s)
	var bodies = grab.bodies()
	if bodies != null:
		bodies.host_release(eid, s)
	var node: Node = bodies.node_of(eid) if bodies != null else null
	var tm = msg.get("throw_meta", null)
	if typeof(tm) == TYPE_DICTIONARY and node != null:
		var pos := HeldStream.vec3(tm.get("pos", [0, 0, 0]))
		pos = _clamp_to_reach(peer, pos if pos.is_finite() else Vector3.ZERO, 0.0)
		GrabAdapter.set_throw_meta(node, clampi(int(tm.get("age_ms", 0)), 0, 10000), pos)
	var info := {}
	if msg.has("panel_state"):
		info["panel_state"] = int(msg.panel_state)
	if bool(msg.get("placed", false)):
		info["placed"] = true
	if not info.is_empty():
		_place_q.append({"eid": eid, "peer": peer, "info": info, "frames": PLACE_DELAY_FRAMES})
	counters.releases += 1
	_change(r, HOST, "", -1, "set")
	if bodies != null:
		bodies.boost(eid, BOOST_S)


func on_own_equip(peer: int, msg: Dictionary) -> void:
	var eid := int(msg.get("eid", 0))
	var r := rows.get(eid) as Row
	if r == null or not _owner_msg_ok(r, peer, int(msg.get("epoch", -1)), ["held"]):
		counters.equip_ignored += 1
		return
	_change(r, peer, "equipped", -1, "set")


func on_own_unequip(peer: int, msg: Dictionary) -> void:
	var eid := int(msg.get("eid", 0))
	var r := rows.get(eid) as Row
	if r == null or not _owner_msg_ok(r, peer, int(msg.get("epoch", -1)), ["equipped"]):
		counters.equip_ignored += 1
		return
	var drop := HeldStream.vec3(msg.get("drop", null))
	var s := HeldStream.state_from_json(msg.get("s"))
	if not s.is_empty():
		s = _clamp_release(r, peer, s)
	if not drop.is_finite():
		drop = s.get("p", Vector3.ZERO) if not s.is_empty() else Vector3.ZERO
	drop = _clamp_to_reach(peer, drop, HELD_SLACK_M)
	last_drop[eid] = {"drop": drop, "s": s}
	# GAMEPLAY takes the host copy off the rig in owner_changed, then it follows the owner again
	_change(r, peer, "held", -1, "set")
	r.last_rx_ms = grab.now()
	r.last_state = s
	var bodies = grab.bodies()
	if bodies != null:
		bodies.host_follow(eid, peer)


## Messages from the owner carry the epoch it knows; 0 means "my request,
## before I saw the grant" and is accepted only while the grant is unacknowledged.
func _owner_msg_ok(r: Row, peer: int, epoch: int, kinds: Array) -> bool:
	if r.owner != peer or not (r.kind in kinds):
		return false
	if epoch == (r.epoch & EPOCH_MASK) or epoch == r.epoch:
		r.await_ack = false
		return true
	return epoch == 0 and r.await_ack


## Frame kind 5 from a client (5.2 step 4).
func on_held_frame(peer: int, frame: Dictionary) -> void:
	var now: int = grab.now()
	var t_ms := int(frame.get("t_ms", 0))
	for rec in frame.get("records", []):
		var eid := int(rec.get("eid", 0))
		var r := rows.get(eid) as Row
		if r == null or r.owner != peer or r.kind != "held":
			counters.held_rejected += 1
			continue
		var ep := int(rec.get("epoch", 0))
		if ep == 0 and r.await_ack:
			counters.held_early += 1
			r.last_rx_ms = maxi(r.last_rx_ms, now)
			continue
		if ep != (r.epoch & EPOCH_MASK):
			counters.held_rejected += 1
			continue
		var p: Vector3 = rec.get("p", Vector3.ZERO)
		var pose: Dictionary = grab.pose_of(peer)
		if bool(pose.get("ok", false)) and _eye(pose).distance_to(p) > grab.max_grab_distance() + HELD_SLACK_M:
			counters.held_rejected += 1
			r.last_frame_far = true
			continue
		r.last_frame_far = false
		r.await_ack = false
		r.last_rx_ms = now
		var st := {"p": p, "q": rec.get("q", Quaternion.IDENTITY), "l": rec.get("l", Vector3.ZERO),
			"a": rec.get("a", Vector3.ZERO)}
		r.last_state = st
		counters.held_rx += 1
		var bodies = grab.bodies()
		if bodies != null:
			bodies.host_follow_push(eid, st, t_ms)


# ------------------------------------------------------------------ host-side actions (10.3)

## GAMEPLAY rack withdraw (6.11): give a freshly spawned body to peer.
func grant(eid: int, peer: int, kind: String = "held", carry: bool = true) -> void:
	if peer == HOST:
		var r := row(eid)
		_change(r, HOST, kind, -1, "set")
		return
	_grant(eid, peer, kind, carry, true)


func _grant(eid: int, peer: int, kind: String, carry: bool, host_origin: bool) -> void:
	var r := row(eid)
	var bodies = grab.bodies()
	var node: Node = bodies.node_of(eid) if bodies != null else null
	if node != null and not host_origin:
		grab.host_exec(peer, func(): GrabAdapter.host_unplace(node))
	_bump(r, peer, kind)
	r.await_ack = true
	r.last_rx_ms = grab.now() + (GRANT_GRACE_MS if host_origin else 0)
	r.last_state = {}
	r.far_since_ms = 0
	r.last_frame_far = false
	if bodies != null and kind == "held":
		bodies.host_follow(eid, peer)
	counters.grants += 1
	var body := _own_body("grant", r)
	if host_origin:
		body["carry"] = carry
	_send(peer, body)
	_broadcast(_own_body("set", r), peer)
	grab.emit_owner_changed(eid, r.owner, r.kind, r.epoch)


## Takes eid back from its owner (5.4). No-op for an unowned body.
func revoke(eid: int, reason: String) -> void:
	var r := rows.get(eid) as Row
	if r == null or r.kind == "":
		return
	counters.revokes += 1
	revoke_reasons[reason] = int(revoke_reasons.get(reason, 0)) + 1
	var prev_owner := r.owner
	var prev_kind := r.kind
	if prev_owner == HOST:
		_change(r, HOST, "", -1, "set")
		return
	var bodies = grab.bodies()
	var s := {}
	if reason in RELEASE_REASONS:
		s = _fallback_state(r)
	if prev_kind == "equipped":
		# GAMEPLAY takes the tool off the rig in owner_changed; then it is dynamic again
		_change(r, HOST, "", prev_owner, "revoke", reason)
		if bodies != null:
			bodies.host_release(eid, _node_state(eid) if reason in RELEASE_REASONS else {})
		return
	if bodies != null:
		bodies.host_release(eid, s)
	_change(r, HOST, "", prev_owner, "revoke", reason, s)
	if bodies != null and reason in RELEASE_REASONS:
		bodies.boost(eid, BOOST_S)


# ------------------------------------------------------------------ host player (5.6)

## main_camera_grab_ext._begin_carry on the host: false = refused (a remote peer holds it).
func host_begin_carry(eid: int) -> bool:
	var r := rows.get(eid) as Row
	if r != null and r.kind != "" and r.owner != HOST:
		counters.host_refused += 1
		return false
	_change(row(eid), HOST, "held", -1, "set")
	return true


func host_player_set(eid: int, kind: String) -> void:
	var r := rows.get(eid) as Row
	if r == null:
		if kind == "":
			return
		r = row(eid)
	if r.owner != HOST:
		return
	if r.kind == kind:
		return
	_change(r, HOST, kind, -1, "set")


# ------------------------------------------------------------------ lifecycle

func tick(now: int) -> void:
	var bodies = grab.bodies()
	var reach: float = grab.max_grab_distance() + HELD_SLACK_M
	for eid in rows.keys():
		var r: Row = rows[eid]
		if r.owner == HOST or r.kind != "held":
			continue
		if now - r.last_rx_ms > SILENCE_MS:
			revoke(eid, "silence")
			continue
		var far := r.last_frame_far
		var node: Node3D = bodies.node_of(eid) as Node3D if bodies != null else null
		var pose: Dictionary = grab.pose_of(r.owner)
		if node != null and bool(pose.get("ok", false)) and _eye(pose).distance_to(node.global_position) > reach:
			far = true
		if far:
			if r.far_since_ms == 0:
				r.far_since_ms = now
			elif now - r.far_since_ms >= FAR_MS:
				revoke(eid, "far")
		else:
			r.far_since_ms = 0


## Host physics frame: deferred place() of released bodies (the client placed them).
func physics_tick() -> void:
	if _place_q.is_empty():
		return
	var keep: Array = []
	var bodies = grab.bodies()
	for item in _place_q:
		item.frames = int(item.frames) - 1
		if int(item.frames) > 0:
			keep.append(item)
			continue
		var eid := int(item.eid)
		if owner_of(eid) != HOST or bodies == null:
			continue
		var node: Node = bodies.node_of(eid)
		if node == null:
			continue
		var info: Dictionary = item.info
		grab.host_exec(int(item.peer), func(): GrabAdapter.host_place(node, info))
		bodies.meta_dirty(eid)
	_place_q = keep


func peer_left(peer: int) -> void:
	for eid in rows.keys():
		var r: Row = rows[eid]
		if r.owner == peer and r.kind != "":
			revoke(eid, "left")


func entity_removed(eid: int) -> void:
	rows.erase(eid)
	last_drop.erase(eid)


## World stops (teardown or phase 5): remote-held bodies are dynamic again at
## their last state; nothing is sent (replication is over).
func world_stopped() -> void:
	var bodies = grab.bodies()
	for eid in rows.keys():
		var r: Row = rows[eid]
		if r.owner != HOST and r.kind != "" and bodies != null:
			var was := r.kind
			if was == "equipped":
				# GAMEPLAY unequips it from the owner's rig (owner_changed) before its
				# freeze state is restored: back in the world, not under a freed camera
				r.kind = ""
				r.owner = HOST
				grab.emit_owner_changed(eid, HOST, "", r.epoch)
			bodies.host_release(eid, _fallback_state(r) if was == "held" else _node_state(eid))
	rows.clear()
	last_drop.clear()
	_place_q.clear()


func wsnap_section() -> Dictionary:
	var out: Array = []
	var keys := rows.keys()
	keys.sort()
	for eid in keys:
		var r: Row = rows[eid]
		if r.owner != HOST or r.kind != "" or r.epoch != 0:
			out.append([eid, r.owner, r.kind, r.epoch])
	return {"rows": out}


# ------------------------------------------------------------------ internals

func _bump(r: Row, owner: int, kind: String) -> void:
	r.owner = owner
	r.kind = kind
	r.epoch = (r.epoch + 1) & EPOCH_MASK
	if r.epoch == 0:
		r.epoch = 1          # 0 is "no grant seen" on the wire
	r.since_ms = grab.now()
	var bodies = grab.bodies()
	if bodies != null:
		bodies.set_owner_view(r.eid, r.owner, r.kind, r.epoch)


## Change + announce. direct_peer > 0 gets ev (revoke), everyone else `set`;
## direct_peer -1 = everyone gets `set` (the owner learns its new epoch).
func _change(r: Row, owner: int, kind: String, direct_peer: int, ev: String, reason: String = "", s: Dictionary = {}) -> void:
	_bump(r, owner, kind)
	r.await_ack = false
	r.far_since_ms = 0
	r.last_frame_far = false
	if owner == HOST:
		r.last_state = {}
	if direct_peer > 0 and direct_peer != HOST:
		var body := _own_body(ev, r)
		if reason != "":
			body["reason"] = reason
		if not s.is_empty():
			body["s"] = HeldStream.state_to_json(s)
		_send(direct_peer, body)
		_broadcast(_own_body("set", r), direct_peer)
	else:
		_broadcast(_own_body("set", r), -1)
	# the row is kept after a release: its epoch must survive for the next grant
	grab.emit_owner_changed(r.eid, r.owner, r.kind, r.epoch)


func _own_body(ev: String, r: Row) -> Dictionary:
	return {"ev": ev, "eid": r.eid, "peer": r.owner, "kind": r.kind, "epoch": r.epoch}


func _send(peer: int, body: Dictionary) -> void:
	if peer == HOST:
		return
	counters.own_tx += 1
	grab.send_world(peer, "own", body)


func _broadcast(body: Dictionary, except_peer: int) -> void:
	for p in grab.world_peers():
		if int(p) != except_peer and int(p) != HOST:
			_send(int(p), body)


## A release state the owner sends is only trusted near the owner's eye (the same
## reach as its held frames): a body is never released (or fed) across the map.
## Too far: the last accepted held frame (or the host copy), with the sent
## velocities capped.
func _clamp_release(r: Row, peer: int, s: Dictionary) -> Dictionary:
	var pose: Dictionary = grab.pose_of(peer)
	if s.is_empty() or not bool(pose.get("ok", false)):
		return s
	var reach: float = grab.max_grab_distance() + HELD_SLACK_M
	var p: Vector3 = s.get("p", Vector3.ZERO)
	if _eye(pose).distance_to(p) <= reach:
		return s
	counters.rel_clamped += 1
	var fb := r.last_state if not r.last_state.is_empty() else _node_state(r.eid)
	if fb.is_empty():
		return {}
	var out := fb.duplicate()
	out["l"] = (s.get("l", Vector3.ZERO) as Vector3).limit_length(REL_MAX_SPEED)
	out["a"] = (s.get("a", Vector3.ZERO) as Vector3).limit_length(REL_MAX_SPEED)
	return out


## A point the owner reports (throw origin, unequip drop): within reach of its eye.
func _clamp_to_reach(peer: int, p: Vector3, slack: float) -> Vector3:
	var pose: Dictionary = grab.pose_of(peer)
	if not bool(pose.get("ok", false)):
		return p
	var eye := _eye(pose)
	var reach: float = grab.max_grab_distance() + slack
	if eye.distance_to(p) <= reach:
		return p
	counters.rel_clamped += 1
	return eye + (p - eye).limit_length(reach)


func _fallback_state(r: Row) -> Dictionary:
	if not r.last_state.is_empty():
		return r.last_state
	return _node_state(r.eid)


func _node_state(eid: int) -> Dictionary:
	var bodies = grab.bodies()
	var node: Node = bodies.node_of(eid) if bodies != null else null
	return GrabAdapter.body_state(node) if node != null else {}
