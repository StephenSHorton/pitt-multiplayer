extends "res://tests/test_case.gd"
## MP2 3.7 late join: world_req -> world snapshot (cut) -> batched apply with
## SaveManager.is_loading held -> buffered ch3 replayed after the cut -> ready.
## 350 entities with metas and a hidden one; activity during the join with
## ch1 delayed (reordered delivery); pool-full pending + retry; pools_hash
## mismatch; a corrupt world snapshot aborts.

const Mp2Rig = preload("res://tests/fakes/mp2_bodies/mp2_rig.gd")
const Snapshot = preload("res://gamedir/mods/PittMultiplayer/sync/snapshot.gd")
const WorldSnapshot = preload("res://gamedir/mods/PittMultiplayer/world/bodies/world_snapshot.gd")

var rig = null
var _e0 := 0


func before_all() -> void:
	rig = Mp2Rig.new(tree, runner)
	_e0 = core.guard.total_errors()


func after_all() -> void:
	rig.hub.channel_delay_ms = {}
	await rig.cleanup()


func _eids(p) -> Array:
	var out: Array = []
	if p.bodies.host != null:
		for e in p.bodies.host.ents:
			if p.bodies.host.ents[e].kind == "pooled":
				out.append(int(e))
	elif p.bodies.client != null:
		for e in p.bodies.client.puppets:
			if p.bodies.client.puppets[e].kind == "pooled":
				out.append(int(e))
	out.sort()
	return out


func test_late_join_350_entities() -> void:
	await rig.cleanup()
	var h = rig.add_host({}, 1)
	await rig.until(func(): return h.session.get_state() == "in_game")
	var nodes: Array = []
	for i in 350:
		var pid := "duck" if i % 7 != 0 else "candy"
		if i % 50 == 0:
			pid = "meta_thing"
		var n = rig.spawn(h, pid, Vector3((i % 20) * 0.5, 0.16 + int(i / 20) * 0.35, -5))
		if pid == "meta_thing":
			n.is_active = true
			n.set_meta("tint_color", Color(0.25, 0.5, 0.75, 1))
		nodes.append(n)
	nodes[3].set_meta("in_cannon_barrel", true)
	nodes[3].visible = false
	await rig.physics(3)
	assert_eq(h.bodies.host.ents.size(), 350, "350 tracked on the host")
	var t0 := Time.get_ticks_msec()
	var c = rig.add_client("late")
	var ok: bool = await rig.until(func(): return c.session.get_state() == "in_game", 10.0)
	assert_true(ok, "late joiner in game")
	assert_true(Time.get_ticks_msec() - t0 < 5000, "join took %d ms" % (Time.get_ticks_msec() - t0))
	assert_eq(c.bodies.client.puppets.size(), 350, "350 puppets")
	assert_eq(_eids(c), _eids(h), "the same eids")
	assert_true(c.bodies.client.counters.wsnap_rows >= 350, "came from the world snapshot")
	assert_true(c.badapter.loading_log.has(true), "SaveManager.is_loading held while applying (spawn audio muted)")
	assert_false(c.badapter.loading, "and restored")
	assert_eq(c.bodies.stray.stray_spawns, 0, "zero strays")
	await rig.until(func(): return h.bodies.host.awake.is_empty(), 8.0)
	await rig.ms(400)
	var worst := 0.0
	for n in nodes:
		var eid: int = h.api.entities.id_of(n)
		var pb = c.bodies.client.puppets.get(eid, null)
		if pb == null:
			fail("no puppet for %d" % eid)
			continue
		if n.visible:
			worst = maxf(worst, pb.node().global_position.distance_to(n.global_position))
	assert_true(worst < 0.05, "poses match (%.4f m)" % worst)
	var m_eid: int = h.api.entities.id_of(nodes[0])
	var mn = c.bodies.client.puppets[m_eid].node()
	assert_true(mn.is_active, "is_active applied")
	assert_true(mn.called("_apply_tint") >= 1, "tint applied through _apply_tint")
	var hid_eid: int = h.api.entities.id_of(nodes[3])
	assert_false(c.bodies.client.puppets[hid_eid].node().visible, "a body in a cannon arrives hidden")
	assert_true(int(c.session.counters_all().get("wsnaps_served", 0)) == 0, "client counters")
	assert_eq(int(h.session.counters.wsnaps_served), 1, "one world snapshot served")


func test_activity_during_join_converges() -> void:
	await rig.cleanup()
	var h = rig.add_host({}, 1)
	await rig.until(func(): return h.session.get_state() == "in_game")
	var nodes: Array = []
	for i in 60:
		nodes.append(rig.spawn(h, "duck", Vector3(i * 0.4, 0.2, 2)))
	await rig.physics(3)
	rig.hub.channel_delay_ms = {1: 250}     # world-snapshot chunks overtaken by ch3
	var c = rig.add_client("busy")
	await rig.until(func(): return c.session._world_flow != "", 6.0)
	# churn while the joiner fetches and applies its world snapshot
	for k in 30:
		if k % 3 == 0 and not nodes.is_empty():
			h.pools.recycle(nodes.pop_front())
		nodes.append(rig.spawn(h, "duck", Vector3(k * 0.3, 1.0, -1)))
		await rig.physics(1)
	var ok: bool = await rig.until(func(): return c.session.get_state() == "in_game", 8.0)
	rig.hub.channel_delay_ms = {}
	assert_true(ok, "joined while the world changed")
	ok = await rig.until(func(): return _eids(c) == _eids(h), 3.0)
	assert_true(ok, "client and host agree on every entity (%d vs %d)" % [_eids(c).size(), _eids(h).size()])
	assert_true(int(c.session.counters.world_buffered) > 0, "ch3 messages were buffered and replayed after the cut")
	assert_eq(c.pools.active_total(), _eids(h).size(), "no leftovers in the client's pools")


func test_pool_full_pending_then_retry() -> void:
	await rig.cleanup()
	var h = rig.add_host({}, 1)
	await rig.until(func(): return h.session.get_state() == "in_game")
	var c = rig.add_client("full")
	await rig.until(func(): return c.session.get_state() == "in_game", 8.0)
	# the client's "tiny" pool (max 2) is busy with two deliberate local objects
	var l1: Node3D = c.pools.spawn("tiny", Vector3(0, 5, 0))
	var l2: Node3D = c.pools.spawn("tiny", Vector3(1, 5, 0))
	l1.set_meta("pitt_mp_local", true)
	l2.set_meta("pitt_mp_local", true)
	var t1 = rig.spawn(h, "tiny", Vector3(0, 0.2, 0))
	await rig.ms(300)
	var eid: int = h.api.entities.id_of(t1)
	assert_true(c.bodies.client.pending.has(eid), "the eid stays pending while the pool is full")
	assert_true(int(c.bodies.client.counters.client_pool_full) >= 1, "client_pool_full counted")
	c.pools.recycle(l1)
	var ok: bool = await rig.until(func(): return c.bodies.client.puppets.has(eid), 2.0)
	assert_true(ok, "retried every 0.5 s and spawned once room was free")


func test_pools_hash_mismatch_rejects() -> void:
	await rig.cleanup()
	var h = rig.add_host({}, 1)
	await rig.until(func(): return h.session.get_state() == "in_game")
	var c = rig.make_peer("modded")
	c.bodies.pool_ids = ["duck", "extra_modded_pool"]
	c.lobby.enter({"id": "loop:1", "owner_id": "loop:1", "is_owner": false}, {"kind": "loopback", "role": "client", "hub": rig.hub})
	var ok: bool = await rig.until(func(): return not c.ended.is_empty(), 5.0)
	assert_true(ok, "the joiner ends")
	if ok:
		assert_eq(String(c.ended[0][0]), "version", "rejected as a version mismatch (2.1)")


func test_corrupt_world_snapshot_aborts() -> void:
	await rig.cleanup()
	var h = rig.add_host({}, 1)
	await rig.until(func(): return h.session.get_state() == "in_game")
	rig.hub.channel_delay_ms = {1: 400}     # chunks trail the header: the receive is observable
	var c = rig.add_client("corrupt")
	await rig.until(func(): return c.session._world_flow == "requested" and c.session._wrx != null, 8.0)
	var w = c.session._wrx
	if w == null:
		rig.hub.channel_delay_ms = {}
		fail("never saw the world snapshot header")
		return
	w.sha = "00"     # as if a chunk had been corrupted in transit
	var ok: bool = await rig.until(func(): return not c.ended.is_empty(), 5.0)
	rig.hub.channel_delay_ms = {}
	assert_true(ok, "aborted")
	if ok:
		assert_eq(String(c.ended[0][0]), "protocol", "protocol error")


func test_rows_round_trip() -> void:
	var row := WorldSnapshot.wsnap_ent_row(1001, 3, Vector3(1, 2, 3), Quaternion(Vector3.UP, 1), Vector3(0, 1, 0),
		Vector3(0, 0, 2), 5, 2, 9, {"g": {"is_active": true}})
	var d := WorldSnapshot.parse_wsnap_ent(JSON.parse_string(JSON.stringify(row)))
	assert_eq(int(d.eid), 1001, "eid")
	assert_eq(int(d.pool_idx), 3, "pool index")
	assert_true((d.p as Vector3).distance_to(Vector3(1, 2, 3)) < 0.001, "pose")
	assert_eq(int(d.owner), 2, "owner")
	assert_eq(int(d.epoch), 9, "epoch")
	assert_true(bool(d.meta.g.is_active), "meta")
	assert_true(WorldSnapshot.parse_wsnap_ent([1, 2, "x"]).is_empty(), "malformed rows rejected")
	var far := WorldSnapshot.wsnap_ent_row(1, 0, Vector3(9000, -10000, 0), Quaternion.IDENTITY, Vector3.ZERO, Vector3.ZERO,
		0, 1, 0, {})
	var fd := WorldSnapshot.parse_wsnap_ent(far)
	assert_false(fd.is_empty(), "the host clamps a far body into range (its entity still exists)")
	assert_true(absf((fd.p as Vector3).y) < 8000.0, "clamped")
	far[2] = 9000.0
	assert_true(WorldSnapshot.parse_wsnap_ent(far).is_empty(), "the client rejects positions beyond 8000 m")
	assert_eq(WorldSnapshot.pools_hash(["b", "a"]), WorldSnapshot.pools_hash(["a", "b"]), "pools_hash order-independent")


## Last: a script error aborts a test silently (it would look passed), so none may occur.
func test_zz_no_script_errors() -> void:
	assert_eq(core.guard.total_errors() - _e0, 0, "script errors during the suite (see headless-run.log)")
