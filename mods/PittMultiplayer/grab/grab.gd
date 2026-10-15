extends RefCounted
## GRAB module (MP2-DESIGN 5, contract 10.3): host-authoritative grab
## ownership with client-side prediction.
##   host   : grab/ownership_host.gd   (table, own_req/own_rel/own_equip/own_unequip, held frames, timeouts)
##   client : grab/ownership_client.gd (prediction, deny/revoke undo, releases)
##   both   : grab/release_capture.gd  (release / throw / equip diff of main_camera)
##            grab/held_stream.gd      (frame kind 5)
## The main_camera extension (extensions/grab/main_camera_grab_ext.gd) calls
## the ext_* entry points; game nodes are touched only through
## game/grab_adapter.gd. GRAB reaches BODIES only through its 10.2 API and
## never calls into GAMEPLAY files (host_exec is used when GAMEPLAY is there).

signal owner_changed(eid: int, owner_peer: int, kind: String, epoch: int)

const OwnershipHost = preload("ownership_host.gd")
const OwnershipClient = preload("ownership_client.gd")
const ReleaseCapture = preload("release_capture.gd")
const HeldStream = preload("held_stream.gd")
const GrabAdapter = preload("../game/grab_adapter.gd")

const HOST := 1
const PHYSICS_PRIORITY := 99


## Physics-frame driver: after main_camera (priority 0), before the BODIES
## puppet driver (100).
class Ticker extends Node:
	var owner_mod = null

	func _init(m = null) -> void:
		owner_mod = m
		name = "PittMP_Grab"
		process_mode = Node.PROCESS_MODE_ALWAYS
		process_physics_priority = PHYSICS_PRIORITY

	func _physics_process(_delta: float) -> void:
		if owner_mod != null:
			owner_mod.physics_tick()


var session: Object = null
var role := ""
var adapter = GrabAdapter.new()
var host = null
var client = null
var capture = ReleaseCapture.new()
var stream = HeldStream.new()
var now_fn: Callable = Callable()    # tests: a fake clock; default Time.get_ticks_msec
var ticker: Ticker = null
var auto_ticker := true              # tests drive physics_tick() themselves
var _live := false
var _bodies_cached: Object = null
var _wired_bodies: Object = null


func _init() -> void:
	capture.sink = self


# ------------------------------------------------------------------ module duck type (10.1)

func mod_name() -> String:
	return "grab"


func msg_kinds() -> Dictionary:
	return {"ch3_c2h": ["own_req", "own_rel", "own_equip", "own_unequip"], "ch3_h2c": ["own"],
		"ch0_c2h": [], "ch0_h2c": [], "raw_c2h": [HeldStream.KIND]}


func on_session_start(p_session: Object, p_role: String) -> void:
	session = p_session
	role = p_role
	host = OwnershipHost.new(self) if role == "host" else null
	client = OwnershipClient.new(self) if role == "client" else null
	_bodies_cached = null
	capture.reset()
	stream.reset()


func on_world_started() -> void:
	if session == null:
		return
	_live = true
	_wire_bodies()
	if auto_ticker and ticker == null:
		ticker = Ticker.new(self)
		var parent: Node = session as Node
		if parent == null or not parent.is_inside_tree():
			var tree := Engine.get_main_loop() as SceneTree
			parent = tree.root if tree != null else null
		if parent != null:
			parent.add_child(ticker)


func on_world_stopped(_reason: String) -> void:
	if host != null:
		host.world_stopped()
	if client != null:
		client.world_stopped()
	capture.reset()
	_live = false
	_unwire_bodies()
	_free_ticker()


func on_msg(peer: int, k: String, msg: Dictionary) -> void:
	if not _live:
		return
	if host != null:
		match k:
			"own_req":
				host.on_own_req(peer, msg)
			"own_rel":
				host.on_own_rel(peer, msg)
			"own_equip":
				host.on_own_equip(peer, msg)
			"own_unequip":
				host.on_own_unequip(peer, msg)
	elif client != null and k == "own":
		client.on_own(msg)


func on_raw(peer: int, kind: int, bytes: PackedByteArray) -> void:
	if not _live or host == null or kind != HeldStream.KIND:
		return
	var f := HeldStream.decode(bytes)
	if f.is_empty():
		host.counters.held_rejected += 1
		return
	host.on_held_frame(peer, f)


func on_peer_world_ready(_peer: int) -> void:
	pass


func on_peer_left(peer: int) -> void:
	if host != null:
		host.peer_left(peer)


func wsnap_section() -> Dictionary:
	return host.wsnap_section() if host != null else {}


func apply_wsnap_section(d: Dictionary) -> void:
	if client != null:
		client.apply_wsnap_section(d)


func tick(now_ms: int) -> void:
	if not _live:
		return
	if host != null:
		host.tick(now())
	elif client != null:
		client.tick(now())


func counters() -> Dictionary:
	var out := {}
	if host != null:
		for k in host.counters:
			out["held_rejected" if k == "held_rejected" else "grab_" + k] = host.counters[k]
		out["grab_deny_reasons"] = host.deny_reasons.duplicate()
		out["grab_revoke_reasons"] = host.revoke_reasons.duplicate()
		out["grab_owned"] = host.rows.values().filter(func(r): return r.kind != "").size()
	if client != null:
		for k in client.counters:
			out["grab_" + k] = client.counters[k]
		out["grab_refusals"] = client.refusals.duplicate()
		out["grab_mine"] = client.mine.size()
	for k in capture.counters:
		out["grab_cap_" + k] = capture.counters[k]
	out["grab_held_tx"] = stream.sent
	return out


func teardown() -> void:
	if _live:
		on_world_stopped("teardown")
	_free_ticker()
	_unwire_bodies()
	host = null
	client = null
	session = null
	role = ""


# ------------------------------------------------------------------ API (10.3)

func owner_of(eid: int) -> int:
	if host != null:
		return host.owner_of(eid)
	if client != null:
		return client.owner_of(eid)
	return HOST


func hold_kind(eid: int) -> String:
	if host != null:
		return host.hold_kind(eid)
	if client != null:
		return client.hold_kind(eid)
	return ""


func epoch_of(eid: int) -> int:
	if host != null:
		return host.epoch_of(eid)
	if client != null:
		return client.epoch_of(eid)
	return 0


func is_mine(eid: int) -> bool:
	if client != null:
		return client.is_mine(eid)
	if host != null:
		return host.owner_of(eid) == HOST and host.hold_kind(eid) != ""
	return false


func can_take(eid: int, peer: int) -> String:
	return host.can_take(eid, peer) if host != null else "not_host"


func add_deny_rule(rule: Callable) -> void:
	if host != null:
		host.add_deny_rule(rule)


func revoke(eid: int, reason: String) -> void:
	if host != null:
		host.revoke(eid, reason)


func grant(eid: int, peer: int, kind: String = "held", carry: bool = true) -> void:
	if host != null:
		host.grant(eid, peer, kind, carry)


## Host, during owner_changed(eid, peer, "held") after an unequip: where the
## owner dropped the tool ({drop: Vector3, s: {p,q,l,a}}), {} if none.
func last_drop(eid: int) -> Dictionary:
	return host.last_drop.get(eid, {}) if host != null else {}


# ------------------------------------------------------------------ main_camera extension entry points

func ext_live() -> bool:
	return _live and session != null


## _begin_carry(obj): false = do not call super (refused).
func ext_begin_carry(_cam: Node, obj: Node, _keep_hands: bool) -> bool:
	var eid := _eid(obj)
	if eid <= 0:
		return true
	if host != null:
		return host.host_begin_carry(eid)
	if client != null:
		return client.begin_carry(eid, obj)
	return true


func ext_carry_started(_cam: Node, obj: Node) -> void:
	var eid := _eid(obj)
	if eid > 0 and client != null:
		client.carry_started(eid)


func ext_drop(_cam: Node, obj: Node, _force: bool) -> void:
	capture.mark_drop(obj)


func ext_drop_done(cam: Node, obj: Node) -> void:
	if obj != null and adapter.picked(cam) == obj:
		capture.unmark_drop(obj)      # invalid snap spot: still carried


func ext_release(cam: Node) -> void:
	var o := adapter.picked(cam)
	if o != null:
		capture.mark_drop(o)


# ------------------------------------------------------------------ release_capture sink

func capture_released(node: Node, info: Dictionary) -> void:
	var eid := _eid(node)
	if eid <= 0:
		return
	if host != null:
		host.host_player_set(eid, "")
	elif client != null:
		client.on_release(eid, info)


func capture_equipped(node: Node) -> void:
	var eid := _eid(node)
	if eid <= 0:
		return
	if host != null:
		host.host_player_set(eid, "equipped")
	elif client != null:
		client.on_equip(eid)


func capture_unequipped(node: Node, drop: Vector3, s: Dictionary) -> void:
	var eid := _eid(node)
	if eid <= 0:
		return
	if host != null:
		host.host_player_set(eid, "held")
	elif client != null:
		client.on_unequip(eid, drop, s)


# ------------------------------------------------------------------ physics frame

func physics_tick() -> void:
	if not _live:
		return
	var cam := camera()
	capture.physics_tick(adapter, cam)
	if client != null:
		var recs: Array = client.held_records(adapter.picked(cam))
		stream.maybe_send(session, now(), recs)
	elif host != null:
		host.physics_tick()


# ------------------------------------------------------------------ helpers for the parts

func now() -> int:
	return int(now_fn.call()) if now_fn.is_valid() else Time.get_ticks_msec()


func camera() -> Node:
	return adapter.camera()


func bodies() -> Object:
	if _bodies_cached != null and is_instance_valid(_bodies_cached):
		return _bodies_cached
	_bodies_cached = null
	if session != null and session.has_method("get_module"):
		_bodies_cached = session.get_module("bodies")
	return _bodies_cached


func my_peer_id() -> int:
	if session != null and session.has_method("my_peer_id"):
		return int(session.my_peer_id())
	return HOST


func send_world(peer: int, k: String, body: Dictionary) -> void:
	if session != null and session.has_method("send_world"):
		session.send_world(peer, k, body)


## Peers that get world messages: in game, plus those past their world-snapshot
## cut when the Session offers that list.
func world_peers() -> Array:
	if session == null:
		return []
	if session.has_method("world_peers"):
		return session.world_peers()
	return session.in_game_peers() if session.has_method("in_game_peers") else []


func peer_in_game(peer: int) -> bool:
	if session == null or not session.has_method("in_game_peers"):
		return false
	return peer in session.in_game_peers()


func pose_of(peer: int) -> Dictionary:
	if session != null and session.has_method("avatar_pose"):
		return session.avatar_pose(peer)
	return {"ok": false}


func max_grab_distance() -> float:
	return adapter.max_grab_distance()


## GAMEPLAY's host exec (exec_peer + PlayerEffectRedirect) when present.
func host_exec(peer: int, c: Callable) -> Variant:
	var gp: Object = session.get_module("gameplay") if session != null and session.has_method("get_module") else null
	if gp != null and gp.has_method("host_exec"):
		return gp.host_exec(peer, c)
	return c.call()


func emit_owner_changed(eid: int, owner_peer: int, kind: String, epoch: int) -> void:
	owner_changed.emit(eid, owner_peer, kind, epoch)


func _eid(node: Node) -> int:
	var b := bodies()
	if node == null or b == null:
		return 0
	return int(b.eid_of(node))


func _wire_bodies() -> void:
	var b := bodies()
	if b == null or b == _wired_bodies:
		return
	_unwire_bodies()
	if b.has_signal("entity_removed"):
		b.connect("entity_removed", _on_entity_removed)
	if b.has_signal("entity_added"):
		b.connect("entity_added", _on_entity_added)
	_wired_bodies = b


func _unwire_bodies() -> void:
	var b := _wired_bodies
	_wired_bodies = null
	if b == null or not is_instance_valid(b):
		return
	if b.has_signal("entity_removed") and b.is_connected("entity_removed", _on_entity_removed):
		b.disconnect("entity_removed", _on_entity_removed)
	if b.has_signal("entity_added") and b.is_connected("entity_added", _on_entity_added):
		b.disconnect("entity_added", _on_entity_added)


func _on_entity_removed(eid: int) -> void:
	if host != null:
		host.entity_removed(eid)
	elif client != null:
		var node: Node = bodies().node_of(eid) if bodies() != null else null
		client.entity_removed(eid)
		if node != null:
			capture.forget(node)


func _on_entity_added(eid: int, _node: Node) -> void:
	if client != null:
		client.entity_added(eid)


func _free_ticker() -> void:
	if ticker != null and is_instance_valid(ticker):
		ticker.owner_mod = null
		if ticker.is_inside_tree():
			ticker.get_parent().remove_child(ticker)
		ticker.queue_free()
	ticker = null
