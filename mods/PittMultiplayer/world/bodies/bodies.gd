extends Node
## BODIES module (MP2-DESIGN 3, API 10.2): one host-simulated shared world.
## Host: replicator_host (entities + fixtures -> ents/meta on ch3, frames 4 on
## ch2). Client: replicator_client (puppets) + stray guard. Both: the fixtures
## registry and the meta registry. Registered with the Session by main.gd;
## the Session routes ents/meta/netq and frame kind 4 here.
## BODIES never calls GAMEPLAY or GRAB: it only exposes 10.2 and emits signals.

const Codec = preload("../../net/codec.gd")
const Proto = preload("../../net/proto.gd")
const Budget = preload("budget.gd")
const MetaSync = preload("meta_sync.gd")
const Fixtures = preload("fixtures.gd")
const StrayGuard = preload("stray_guard.gd")
const ReplicatorHost = preload("replicator_host.gd")
const ReplicatorClient = preload("replicator_client.gd")
const WorldSnapshot = preload("world_snapshot.gd")
const BodiesAdapter = preload("../../game/bodies_adapter.gd")

signal entity_added(eid: int, node: Node)
signal entity_removed(eid: int)

const NAME := "bodies"
const PHYSICS_HZ := 60

var api = null
var adapter = null
var session = null
var role := ""
var detail := "normal"
var meta_sync = MetaSync.new()
var fixtures = null
var stray = null
var host = null                   # ReplicatorHost
var client = null                 # ReplicatorClient
var pool_ids: Array = []
var _subs: Array = []
var _started := false
var _apply_depth := 0
var _fixture_meta: Dictionary = {}   # client: static fixture eid -> {kind: {field: v}}
var _kinds_dirty := false
var _log: Array = []
var counters_extra := {"stray_checks": 0, "netq_tx": 0, "netq_rx": 0, "pools_hash_mismatch": 0}


func _init(p_api = null, p_adapter = null) -> void:
	name = "PittMP_Bodies"
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_physics_priority = 100
	api = p_api
	adapter = p_adapter
	if adapter == null:
		adapter = BodiesAdapter.new()
		adapter.setup(api)
	fixtures = Fixtures.new(api, adapter)
	fixtures.on_added = _on_fixture_added
	fixtures.on_removed = _on_fixture_removed
	stray = StrayGuard.new(adapter)
	stray.log_cb = log_warn


# ================================================================== module duck type (10.1)

func mod_name() -> String:
	return NAME


func msg_kinds() -> Dictionary:
	return {"ch3_h2c": ["ents", "meta"], "ch3_c2h": [], "ch0_c2h": ["netq"], "ch0_h2c": [], "raw_c2h": [],
		"raw_h2c": [Proto.FRAME_BODIES]}


func on_session_start(p_session: Object, p_role: String) -> void:
	session = p_session
	role = p_role
	if session != null and "config" in session:
		var d := String(session.config.get("physics_detail", "normal"))
		detail = d if Budget.DETAIL.has(d) else "normal"
	pool_ids = adapter.pool_ids()


## D21/2.1: the host's rules for the shared world.
func welcome_rules() -> Dictionary:
	if pool_ids.is_empty():
		pool_ids = adapter.pool_ids()
	return {"physics_detail": detail, "budget_bps": Budget.detail_bps(detail), "tick_hz": PHYSICS_HZ,
		"pools": pool_ids.duplicate(), "pools_hash": WorldSnapshot.pools_hash(pool_ids)}


## Client: "" when the host's pool table matches ours, else a reason (version reject).
func check_welcome_rules(r: Dictionary) -> String:
	if pool_ids.is_empty():
		pool_ids = adapter.pool_ids()
	var mine := WorldSnapshot.pools_hash(pool_ids)
	var theirs := String(r.get("pools_hash", ""))
	if theirs != mine:
		counters_extra.pools_hash_mismatch += 1
		return "object pool tables differ (host %s, here %s)" % [theirs, mine]
	return ""


func on_world_started() -> void:
	if role == "host":
		_host_start()
	else:
		_client_prepare()
	_started = true


func on_world_stopped(reason: String) -> void:
	if reason == "ending":
		# D16: replication stops; every peer runs the game's own ending locally
		if host != null:
			host.freeze_world()
		if client != null:
			client.freeze_world()


func on_msg(peer: int, k: String, msg: Dictionary) -> void:
	match k:
		"netq":
			if host != null:
				counters_extra.netq_rx += 1
				host.on_netq(peer, msg)
		"ents":
			if client != null:
				client.on_ents(msg)
		"meta":
			if client != null:
				client.on_meta(msg)


func on_raw(_peer: int, kind: int, bytes: PackedByteArray) -> void:
	if kind == Proto.FRAME_BODIES and client != null:
		client.on_frame(bytes)


func on_peer_world_ready(peer: int) -> void:
	if host != null:
		host.peer_ready(peer)


func on_peer_left(peer: int) -> void:
	if host != null:
		host.peer_left(peer)


func wsnap_section() -> Dictionary:
	if host == null:
		_host_start()
	return host.build_wsnap()


func apply_wsnap_section(d: Dictionary) -> void:
	_client_prepare()
	var theirs := String(d.get("pools_hash", ""))
	if theirs != "" and theirs != WorldSnapshot.pools_hash(pool_ids):
		counters_extra.pools_hash_mismatch += 1
		log_warn("world snapshot pool table differs from ours")
	var fx = d.get("fixtures", {})
	if typeof(fx) == TYPE_DICTIONARY:
		begin_apply()
		for k in fx:
			if String(k).is_valid_int() and typeof(fx[k]) == TYPE_DICTIONARY:
				apply_fixture_meta(int(String(k)), fx[k])
		end_apply()
	client.begin_wsnap(d)


func wsnap_apply_done() -> bool:
	return client == null or client.apply_done()


func tick(now_ms: int) -> void:
	if client != null and _started and session != null and session.get_state() == "in_game":
		_stray_check()
		if client.netq_due(now_ms):
			var q: Dictionary = client.take_netq()
			q["strays"] = int(stray.stray_spawns)
			q["local_money_writes"] = int(session.econ_client.local_money_writes) if "econ_client" in session else 0
			q["rtt_ms"] = int(session.clock.rtt_ms) if "clock" in session and session.clock != null else -1
			session.send_msg(1, "netq", q)
			counters_extra.netq_tx += 1


func counters() -> Dictionary:
	var out := counters_extra.duplicate()
	if host != null:
		for k in host.counters:
			out[k] = host.counters[k]
		out["tracked"] = host.ents.size()
		out["awake"] = host.awake.size()
	if client != null:
		for k in client.counters:
			out[k] = client.counters[k]
		out["puppets"] = client.puppets.size()
		out["interp_ms"] = client.interp_delay
	out["stray_spawns"] = stray.stray_spawns
	out["stray_expected"] = stray.stray_expected
	out["fixture_collisions"] = fixtures.collisions
	out["meta_errors"] = meta_sync.errors
	return out


func teardown() -> void:
	for id in _subs:
		if api != null and "events" in api and api.events != null:
			api.events.off(id)
	_subs.clear()
	if host != null:
		host.clear()
		host = null
		_net_call("set_reconcile_mode", [{"full_every_frame": false, "detect_reuse": false}])
	if client != null:
		client.clear()
		client = null
	fixtures.clear()
	_fixture_meta.clear()
	adapter.unpin_physics()
	_started = false
	_apply_depth = 0
	session = null
	role = ""


# ================================================================== role start

func _host_start() -> void:
	if host != null:
		return
	pool_ids = adapter.pool_ids()
	host = ReplicatorHost.new(self, pool_ids, detail)
	_net_call("set_reconcile_mode", [{"full_every_frame": true, "detect_reuse": true}])
	if api != null and "events" in api and api.events != null:
		_subs.append(api.events.on("entity.spawned", _on_entity_spawned))
		_subs.append(api.events.on("entity.despawned", _on_entity_despawned))
	# everything already in the world (the reconciler ran before the session)
	if api != null and "entities" in api and api.entities != null:
		for eid in api.entities.list({"kind": "pooled"}):
			var n = api.entities.get_node(eid)
			if n != null:
				var d: Dictionary = api.entities.describe(eid)
				host.track(eid, n, "pooled", String(d.get("pool_id", "")))
	fixtures.scan()
	adapter.pin_physics(PHYSICS_HZ)
	if session != null:
		session.eye_offset = adapter.eye_offset()


func _client_prepare() -> void:
	if client != null:
		return
	if pool_ids.is_empty():
		pool_ids = adapter.pool_ids()
	client = ReplicatorClient.new(self, pool_ids)
	fixtures.scan()
	adapter.pin_physics(PHYSICS_HZ)
	if session != null:
		session.eye_offset = adapter.eye_offset()


func _on_entity_spawned(ev) -> void:
	if host == null:
		return
	var p: Dictionary = ev.payload
	var eid := int(p.get("entity_id", 0))
	var n = api.entities.get_node(eid) if api != null and "entities" in api else null
	if n != null:
		host.track(eid, n, "pooled", String(p.get("pool_id", "")))


func _on_entity_despawned(ev) -> void:
	if host == null:
		return
	host.untrack(int(ev.payload.get("entity_id", 0)))


func _on_fixture_added(key: String, eid: int, node: Node, is_body: bool) -> void:
	if role == "host":
		if host != null:
			host.track(eid, node, "fixture_body" if is_body else "fixture", key)
	elif client != null and is_body and not client.puppets.has(eid):
		var pb = ReplicatorClient.PuppetBody.new()
		pb.eid = eid
		pb.ref = weakref(node)
		pb.kind = "fixture_body"
		pb.key = key
		client.puppets[eid] = pb
		client.puppetize(pb)
		emit_added(eid, node)


func _on_fixture_removed(_key: String, eid: int) -> void:
	if host != null:
		host.untrack(eid)
	if client != null:
		client.despawn(eid)
	_fixture_meta.erase(eid)


# ================================================================== per frame

func _physics_process(_delta: float) -> void:
	if session == null or not _started:
		if client != null and client.applying:
			client.physics_step()      # the world snapshot applies before the world goes live
		return
	fixtures.poll()
	if _kinds_dirty:
		_refresh_kinds()
	if host != null:
		host.physics_step()
	elif client != null:
		client.physics_step()
		_stray_check()


func _stray_check() -> void:
	if client == null or client.frozen:
		return
	counters_extra.stray_checks += 1
	stray.check(client.pooled_count(), _recycle_stray)


func _recycle_stray(node: Node) -> void:
	begin_apply()
	adapter.recycle(node)
	end_apply()


func _refresh_kinds() -> void:
	_kinds_dirty = false
	if host == null:
		return
	for eid in host.ents:
		var e = host.ents[eid]
		var n = e.node()
		if n != null:
			var kinds: Array = meta_sync.kinds_for(n, e.kind)
			for k in kinds:
				if not (k in e.meta_kinds):
					e.meta_force = true
			e.meta_kinds = kinds


# ================================================================== helpers for the replicators

## Flat PittAPI apply scope with a depth count (adapters may call into code that
## ends the scope; it is re-asserted after each external call).
func begin_apply() -> void:
	_apply_depth += 1
	if _apply_depth == 1:
		_net_call("begin_apply", [1])


func end_apply() -> void:
	if _apply_depth <= 0:
		return
	_apply_depth -= 1
	if _apply_depth == 0:
		_net_call("end_apply", [])


func _reassert_apply() -> void:
	if _apply_depth > 0 and api != null and "net" in api and api.net != null and api.net.has_method("is_applying") \
			and not bool(api.net.is_applying()):
		api.net.begin_apply(1)


func apply_meta(node: Object, changed: Dictionary, pool_id: String = "") -> void:
	begin_apply()
	meta_sync.apply(node, changed, pool_id)
	_reassert_apply()
	end_apply()


func apply_fixture_meta(eid: int, changed: Dictionary) -> void:
	var key: String = fixtures.key_of_eid(eid)
	if key == "":
		return
	var node = fixtures.node_of_key(key)
	if node == null:
		return
	if not _fixture_meta.has(eid):
		_fixture_meta[eid] = {}
	meta_sync.merge_into(_fixture_meta[eid], changed)
	apply_meta(node, changed, "")


func fixture_node(key: String) -> Node:
	return fixtures.node_of_key(key)


func fixture_eid(key: String) -> int:
	return fixtures.eid_of_key(key)


func adopt(node: Node, eid: int, pool_id: String) -> void:
	var r = _net_call("adopt_entity", [node, eid, pool_id])
	if typeof(r) == TYPE_INT and r != OK:
		log_warn("adopt_entity(%d) failed: %s" % [eid, error_string(r)])


func release(eid: int) -> void:
	_net_call("release_entity", [eid])


func _net_call(method: String, args: Array) -> Variant:
	if api == null or not ("net" in api) or api.net == null or not api.net.has_method(method):
		return null
	return api.net.callv(method, args)


func emit_added(eid: int, node: Node) -> void:
	entity_added.emit(eid, node)


func emit_removed(eid: int) -> void:
	entity_removed.emit(eid)


func log_warn(msg: String) -> void:
	_log.append(msg)
	if _log.size() > 100:
		_log.pop_front()
	if session != null and session.has_method("log_warn"):
		session.log_warn(msg)


func toast(key: String) -> void:
	if api != null and "hud" in api and api.hud != null:
		api.hud.toast(tr(key))


# ================================================================== 10.2 both roles

func node_of(eid: int) -> Node:
	if host != null:
		var e = host.ents.get(eid, null)
		return e.node() if e != null else null
	if client != null:
		var pb = client.puppets.get(eid, null)
		if pb != null:
			return pb.node()
	var key: String = fixtures.key_of_eid(eid)
	return fixtures.node_of_key(key) if key != "" else null


## 0 if not replicated; walks up from a child collider to the tracked ancestor.
func eid_of(node: Object) -> int:
	var n = node
	var depth := 0
	while n != null and is_instance_valid(n) and depth < 12:
		if n is Node:
			if n.has_meta(ReplicatorClient.PUPPET_META):
				var pe := int(n.get_meta(ReplicatorClient.PUPPET_META))
				if is_replicated(pe):
					return pe
			if api != null and "entities" in api and api.entities != null:
				var id: int = api.entities.id_of(n)
				if id != 0 and is_replicated(id):
					return id
			n = n.get_parent()
		else:
			break
		depth += 1
	return 0


func is_replicated(eid: int) -> bool:
	if host != null:
		return host.ents.has(eid)
	if client != null and client.puppets.has(eid):
		return true
	return fixtures.by_eid.has(eid)


func kind_of(eid: int) -> String:
	if host != null:
		var e = host.ents.get(eid, null)
		return String(e.kind) if e != null else ""
	if client != null:
		var pb = client.puppets.get(eid, null)
		if pb != null:
			return String(pb.kind)
	return "fixture" if fixtures.by_eid.has(eid) else ""


func pool_id_of(eid: int) -> String:
	if host != null:
		var e = host.ents.get(eid, null)
		return String(e.pool_id) if e != null else ""
	if client != null:
		var pb = client.puppets.get(eid, null)
		return String(pb.pool_id) if pb != null else ""
	return ""


## Last known record flags (HELD, HIDDEN, NOCOLLIDE, SLEEP).
func flags_of(eid: int) -> int:
	if host != null:
		return host.flags_of(eid)
	if client != null:
		var pb = client.puppets.get(eid, null)
		if pb == null:
			return 0
		var f := int(pb.last_flags) & (Codec.RF_HELD | Codec.RF_NOCOLLIDE | Codec.RF_SLEEP)
		if pb.hidden:
			f |= Codec.RF_HIDDEN
		if pb.owner_kind != "":
			f |= Codec.RF_HELD
		return f
	return 0


## Last applied (client) / last sent (host) meta {kind: {field: value}}.
func meta_of(eid: int) -> Dictionary:
	if host != null:
		var e = host.ents.get(eid, null)
		return e.meta_last.duplicate(true) if e != null else {}
	if client != null:
		var pb = client.puppets.get(eid, null)
		if pb != null:
			return pb.meta.duplicate(true)
	return _fixture_meta.get(eid, {}).duplicate(true)


## GRAB calls this on every ownership change (both roles).
func set_owner_view(eid: int, owner_peer: int, kind: String, epoch: int) -> void:
	if host != null:
		host.set_owner(eid, owner_peer, kind, epoch)
	elif client != null:
		var pb = client.puppets.get(eid, null)
		if pb != null:
			pb.owner = owner_peer
			pb.owner_kind = kind


func register_meta(kind: String, matcher: Callable, read: Callable, apply: Callable, rate_hz: float = 4.0) -> void:
	meta_sync.register(kind, matcher, read, apply, rate_hz)
	_kinds_dirty = true


## Static id of a fixture key (GAMEPLAY adds the keys it creates, e.g. bowling pins).
func register_fixture(key: String, node: Node) -> int:
	return fixtures.register(key, node)


func unregister_fixture(key: String) -> void:
	fixtures.unregister(key)


# ================================================================== 10.2 host only

func host_follow(eid: int, peer: int) -> void:
	if host != null:
		host.follow(eid, peer)


func host_follow_push(eid: int, state: Dictionary, t_ms: int) -> void:
	if host != null:
		host.follow_push(eid, state, t_ms)


func host_release(eid: int, state: Dictionary) -> void:
	if host != null:
		host.release(eid, state)


func boost(eid: int, seconds: float) -> void:
	if host != null:
		host.boost(eid, seconds)


func meta_dirty(eid: int) -> void:
	if host != null:
		host.meta_dirty(eid)


func mark_snap(eid: int) -> void:
	if host != null:
		host.mark_snap(eid)


func freeze_world() -> void:
	if host != null:
		host.freeze_world()


## Pending lifecycle out now (GRAB may call this before an `own` message; also
## done by set_owner_view on the host).
func flush_lifecycle() -> void:
	if host != null:
		host.flush_lifecycle()


func budget_bps(peer: int) -> int:
	return host.budget_bps(peer) if host != null else Budget.detail_bps(detail)


# ================================================================== 10.2 client only

func set_local_sim(eid: int, on: bool, min_epoch: int = 0) -> void:
	if client != null:
		client.set_local_sim(eid, on, min_epoch)


func is_local_sim(eid: int) -> bool:
	return client != null and client.is_local_sim(eid)


## Newest host record {p, q, l, a, flags, epoch, host_ms} ({} if none).
func host_state(eid: int) -> Dictionary:
	return client.host_state(eid) if client != null else {}
