extends "res://tests/test_case.gd"
## MP2 3.3 / 3.4 end to end in one process (host + client, loopback, each peer
## with its own physics world and pools, the REAL BODIES module):
## spawn with host ids, motion tracking, rest exactness and rest-only traffic,
## despawn, hidden bodies, same-frame reuse (L8), ownership (never sent to the
## owner), local_sim hand-back, D22, fixture bodies, host_follow / release,
## freeze_world (D16), entity_added / entity_removed.

const Mp2Rig = preload("res://tests/fakes/mp2_bodies/mp2_rig.gd")
const Codec = preload("res://gamedir/mods/PittMultiplayer/net/codec.gd")

var rig = null
var _e0 := 0


func before_all() -> void:
	rig = Mp2Rig.new(tree, runner)
	_e0 = core.guard.total_errors()


func after_all() -> void:
	await rig.cleanup()


func _host_id(h, node: Node) -> int:
	return int(h.api.entities.id_of(node))


func _puppet(c, eid: int):
	return c.bodies.client.puppets.get(eid, null) if c.bodies.client != null else null


func _client_node(c, eid: int) -> Node3D:
	var pb = _puppet(c, eid)
	return pb.node() if pb != null else null


func test_spawn_replicates_with_host_ids() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	assert_eq(c.session.get_state(), "in_game", "client in game")
	assert_true(h.session.world_live() and c.session.world_live(), "world_started on both")
	var ducks: Array = []
	for i in 20:
		ducks.append(rig.spawn(h, "duck", Vector3(i * 0.5, 1.0 + i * 0.1, 0)))
	var ok: bool = await rig.until(func(): return c.bodies.client.puppets.size() >= 20, 3.0)
	assert_true(ok, "20 puppets on the client (%d)" % c.bodies.client.puppets.size())
	for d in ducks:
		var eid := _host_id(h, d)
		assert_true(eid >= 1000, "host id %d" % eid)
		var n := _client_node(c, eid)
		assert_true(n != null, "puppet for %d" % eid)
		if n == null:
			continue
		assert_eq(int(c.api.entities.id_of(n)), eid, "client api.entities.id_of = host id (L7)")
		assert_eq(String(n.pool_id), "duck", "same pool")
		assert_true(n.freeze and n.freeze_mode == RigidBody3D.FREEZE_MODE_KINEMATIC, "frozen kinematic puppet")
		assert_eq(int(n.get_meta("pitt_mp_puppet")), eid, "puppet meta")
	assert_eq(c.bodies.kind_of(_host_id(h, ducks[0])), "pooled", "kind_of")
	assert_eq(c.bodies.pool_id_of(_host_id(h, ducks[0])), "duck", "pool_id_of")
	assert_true(c.grab.added.size() >= 20, "entity_added emitted on the client")
	assert_true(h.grab.added.size() >= 20, "entity_added emitted on the host")


func test_motion_tracks_and_rest_is_exact() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	var ducks: Array = []
	for i in 12:
		ducks.append(rig.spawn(h, "duck", Vector3(i * 0.6, 2.0, 0), Vector3(1.0, 3.0, 0.5)))
	await rig.until(func(): return c.bodies.client.puppets.size() >= 12, 3.0)
	# while moving: the puppet at render time rt vs the host's pose at rt
	var hist := {}
	var errs: Array = []
	for f in 40:
		await tree.physics_frame
		var hn: int = h.session.host_now()
		for d in ducks:
			var eid := _host_id(h, d)
			if not hist.has(eid):
				hist[eid] = []
			hist[eid].append([hn, d.global_position])
		var rt: int = c.session.host_now() - c.bodies.client.interp_delay
		for d in ducks:
			var eid := _host_id(h, d)
			var n := _client_node(c, eid)
			if n == null:
				continue
			var best = null
			for s in hist[eid]:
				if best == null or absi(int(s[0]) - rt) < absi(int(best[0]) - rt):
					best = s
			if best != null and absi(int(best[0]) - rt) <= 20:
				errs.append(n.global_position.distance_to(best[1]))
	errs.sort()
	assert_true(errs.size() > 50, "samples while moving (%d)" % errs.size())
	if errs.size() > 0:
		var p95: float = errs[int(errs.size() * 0.95)]
		assert_true(p95 <= 0.10, "moving pose error p95 %.3f m <= 0.10 (loopback, frame-aligned)" % p95)
	# rest: placed exactly
	var rested: bool = await rig.until(func():
		for d in ducks:
			if not d.sleeping:
				return false
		return true, 8.0)
	assert_true(rested, "host ducks came to rest")
	await rig.ms(400)
	var worst := 0.0
	for d in ducks:
		var n := _client_node(c, _host_id(h, d))
		if n != null:
			worst = maxf(worst, n.global_position.distance_to(d.global_position))
	assert_true(worst <= 0.01, "at rest within 1 cm (%.4f m)" % worst)


func test_resting_bodies_cost_only_the_refresh() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	for i in 30:
		rig.spawn(h, "duck", Vector3(i * 0.5, 0.16, 3))
	await rig.until(func(): return c.bodies.client.puppets.size() >= 30, 3.0)
	await rig.until(func(): return h.bodies.host.awake.is_empty(), 6.0)
	await rig.ms(3500)       # past the 250 ms / 1 s / 3 s repeats
	var r0: int = c.bodies.client.counters.records_rx
	await rig.ms(1000)
	var per_s: int = c.bodies.client.counters.records_rx - r0
	assert_true(per_s <= 36, "only the rest refresh (one body per tick) while everything sleeps: %d records/s" % per_s)
	assert_true(per_s >= 10, "the rest refresh keeps running (%d records/s)" % per_s)


func test_despawn_and_reuse() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	var ducks: Array = []
	for i in 10:
		ducks.append(rig.spawn(h, "duck", Vector3(i, 0.2, -2)))
	await rig.until(func(): return c.bodies.client.puppets.size() >= 10, 3.0)
	var gone_eid := _host_id(h, ducks[0])
	var t0 := Time.get_ticks_msec()
	h.pools.recycle(ducks[0])
	var ok: bool = await rig.until(func(): return _puppet(c, gone_eid) == null, 2.0)
	assert_true(ok, "despawned on the client")
	assert_true(Time.get_ticks_msec() - t0 <= 300, "within 300 ms (%d)" % (Time.get_ticks_msec() - t0))
	assert_has(c.grab.removed, gone_eid, "entity_removed on the client")
	assert_eq(c.pools.active_total(), 9, "the client's pool has exactly the 9 left")
	# the press case: recycle + spawn of the same node in one frame (L8)
	var old_eid := _host_id(h, ducks[1])
	var node: RigidBody3D = ducks[1]
	h.pools.recycle(node)
	var again: RigidBody3D = h.pools.spawn("duck", Vector3(5, 0.2, 5))
	assert_true(again == node, "the pool handed out the same node")
	await rig.physics(3)
	var new_eid := _host_id(h, again)
	assert_ne(new_eid, old_eid, "a NEW id on the host")
	ok = await rig.until(func(): return _puppet(c, old_eid) == null and _puppet(c, new_eid) != null, 2.0)
	assert_true(ok, "client: old eid gone, new eid present")
	assert_eq(c.pools.active_total(), 9, "no leftover duck")


func test_out_of_range_body_never_poisons_packets() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	var good: Array = []
	for i in 5:
		good.append(rig.spawn(h, "duck", Vector3(i, 2, 0), Vector3(0, 1, 0)))
	var lost: RigidBody3D = rig.spawn(h, "duck", Vector3(0, -9500, 0), Vector3(0, -3, 0))
	lost.gravity_scale = 0.0
	var ok: bool = await rig.until(func(): return c.bodies.client.puppets.size() >= 6, 3.0)
	assert_true(ok, "a body far out of the world still exists on the client (row clamped into range)")
	var r0: int = c.bodies.client.counters.records_rx
	await rig.ms(500)
	assert_eq(int(c.bodies.client.counters.decode_errors), 0, "no packet rejected")
	assert_true(c.bodies.client.counters.records_rx > r0, "the other bodies keep streaming")


func test_hidden_bodies() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	var d: RigidBody3D = rig.spawn(h, "duck", Vector3(0, 0.2, 0))
	await rig.until(func(): return c.bodies.client.puppets.size() >= 1, 3.0)
	var eid := _host_id(h, d)
	var n := _client_node(c, eid)
	var layer: int = n.collision_layer
	# the cannon stores a body: meta + hidden (cannon.gd _load_body)
	d.set_meta("in_cannon_barrel", true)
	d.visible = false
	var ok: bool = await rig.until(func(): return not n.visible, 2.0)
	assert_true(ok, "hidden on the client")
	assert_eq(n.collision_layer, 0, "no collision while hidden")
	assert_true(c.bodies.flags_of(eid) & Codec.RF_HIDDEN, "flags_of has HIDDEN")
	d.remove_meta("in_cannon_barrel")
	d.global_position = Vector3(20, 3, 0)
	d.visible = true
	ok = await rig.until(func(): return n.visible and n.global_position.distance_to(d.global_position) < 0.5, 2.0)
	assert_true(ok, "unhidden at the muzzle")
	assert_eq(n.collision_layer, layer, "collision restored")


func test_owner_never_receives_its_body() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	var d: RigidBody3D = rig.spawn(h, "duck", Vector3(0, 3, 0), Vector3(0, 2, 0))
	await rig.until(func(): return c.bodies.client.puppets.size() >= 1, 3.0)
	var eid := _host_id(h, d)
	var me: int = c.session.my_peer_id()
	h.grab.set_owner(eid, me, "held", 1)
	h.bodies.host_follow(eid, me)
	c.bodies.set_local_sim(eid, true)
	var n := _client_node(c, eid)
	assert_false(n.freeze, "local_sim: the client simulates its copy")
	assert_true(c.bodies.is_local_sim(eid), "is_local_sim")
	await rig.ms(150)
	var before: int = _puppet(c, eid).ring.size()
	var newest_t := int(_puppet(c, eid).newest().get("t", 0))
	for i in 10:
		h.bodies.host_follow_push(eid, {"p": Vector3(1, 2 + i * 0.1, 0), "q": Quaternion.IDENTITY,
			"l": Vector3(0, 1, 0), "a": Vector3.ZERO}, i)
		await tree.physics_frame
	await rig.ms(200)
	assert_eq(int(_puppet(c, eid).newest().get("t", 0)), newest_t, "no records of an owned body reach its owner")
	assert_true(d.freeze and d.freeze_mode == RigidBody3D.FREEZE_MODE_KINEMATIC, "host copy is a kinematic follower")
	assert_true(d.global_position.distance_to(Vector3(1, 2.9, 0)) < 0.3, "follows the held stream (%s)" % str(d.global_position))
	# release: exact state, dynamic again; the client returns to puppet mode with the new epoch
	h.bodies.host_release(eid, {"p": Vector3(2, 3, 0), "q": Quaternion.IDENTITY, "l": Vector3(4, 0, 0), "a": Vector3.ZERO})
	assert_false(d.freeze, "dynamic again")
	assert_true(d.linear_velocity.distance_to(Vector3(4, 0, 0)) < 0.01, "exact velocity")
	h.grab.set_owner(eid, 1, "", 2)
	c.bodies.set_local_sim(eid, false, 2)
	var ok: bool = await rig.until(func(): return not c.bodies.is_local_sim(eid), 1.5)
	assert_true(ok, "back to puppet mode once a record with epoch 2 arrived")
	assert_true(n.freeze, "frozen again")
	assert_true(before >= 1, "had records before")


## 0.2.2: a carried body with puppets resting on / in it (the crate with ducks):
## frozen KINEMATIC puppets would hold it down, so they ride (local sim) until
## the carry ends; a puppet away from it is left alone.
func test_carried_body_takes_its_riders_along() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	var crate: RigidBody3D = rig.spawn(h, "toy_gambling_wodden_crate", Vector3(0, 0.15, 3))
	var on_top: RigidBody3D = rig.spawn(h, "duck", Vector3(0, 0.45, 3))
	var away: RigidBody3D = rig.spawn(h, "duck", Vector3(2, 0.15, 3))
	await rig.until(func(): return c.bodies.client.puppets.size() >= 3, 3.0)
	await rig.ms(1200)       # settle on the host; the client draws the rest poses
	var ce := _host_id(h, crate)
	var de := _host_id(h, on_top)
	var ae := _host_id(h, away)
	var nc := _client_node(c, ce) as RigidBody3D
	var nd := _client_node(c, de) as RigidBody3D
	var na := _client_node(c, ae) as RigidBody3D
	assert_true(nd.freeze and na.freeze, "puppets before the carry")
	c.bodies.set_local_sim(ce, true)
	var ok: bool = await rig.until(func(): return c.bodies.is_local_sim(de), 1.0)
	assert_true(ok, "the duck on the carried body rides")
	assert_false(nd.freeze, "and simulates locally")
	assert_false(c.bodies.is_local_sim(ae), "the duck beside it stays a puppet")
	assert_true(na.freeze, "frozen")
	var y0 := nc.global_position.y
	var dy0 := nd.global_position.y
	for i in 30:
		nc.linear_velocity = Vector3(0, 2.0, 0)     # the game's carry sets the velocity every frame
		await tree.physics_frame
	assert_true(nc.global_position.y - y0 > 0.5, "the carried body rises (%.3f m)" % (nc.global_position.y - y0))
	assert_true(nd.global_position.y - dy0 > 0.5, "with its rider (%.3f m)" % (nd.global_position.y - dy0))
	c.bodies.set_local_sim(ce, false, 0)
	ok = await rig.until(func(): return not c.bodies.is_local_sim(ce) and not c.bodies.is_local_sim(de), 1.5)
	assert_true(ok, "the carry ended: both are puppets again")
	assert_true(nd.freeze and nd.freeze_mode == RigidBody3D.FREEZE_MODE_KINEMATIC, "the rider is frozen again")
	assert_eq(int(c.bodies.client.counters.riders_on), int(c.bodies.client.counters.riders_off), "every rider handed back")
	assert_true(c.bodies.client.carriers.is_empty(), "no carrier left")


func test_d22_small_products_pass_through_the_player() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	var d: RigidBody3D = rig.spawn(h, "duck", Vector3(0, 0.2, 1))
	var crate: RigidBody3D = rig.spawn(h, "toy_gambling_wodden_crate", Vector3(2, 0.2, 1))
	await rig.until(func(): return c.bodies.client.puppets.size() >= 2, 3.0)
	var nd := _client_node(c, _host_id(h, d))
	var nc := _client_node(c, _host_id(h, crate))
	assert_has(c.player.get_collision_exceptions(), nd, "the local player passes through a small product puppet")
	assert_false(nc in c.player.get_collision_exceptions(), "but stands on crates")


func test_fixture_bodies_and_static_ids() -> void:
	await rig.cleanup()
	var h = rig.add_host({}, -1)
	var fuse_h := _make_fuse(h)
	rig.start_host_world(h, 1)
	await rig.until(func(): return h.session.get_state() == "in_game")
	var c = rig.add_client("c")
	var fuse_c := _make_fuse(c)
	await rig.until(func(): return c.session.get_state() == "in_game", 8.0)
	var eid_h: int = h.bodies.eid_of(fuse_h)
	var eid_c: int = c.bodies.eid_of(fuse_c)
	assert_true(eid_h != 0 and eid_h == eid_c, "same static id on both peers (%d / %d)" % [eid_h, eid_c])
	assert_eq(h.bodies.kind_of(eid_h), "fixture_body", "fixture body")
	assert_true(fuse_c.freeze, "the client's fuse is a puppet")
	fuse_h.global_position = Vector3(3, 0.2, 3)
	fuse_h.sleeping = false
	var ok: bool = await rig.until(func(): return fuse_c.global_position.distance_to(fuse_h.global_position) < 0.05, 3.0)
	assert_true(ok, "the client's fuse follows the host's (%s vs %s)" % [str(fuse_c.global_position), str(fuse_h.global_position)])
	var child: Node = fuse_c.get_child(0)
	assert_eq(c.bodies.eid_of(child), eid_c, "eid_of walks up from a child collider")


func _make_fuse(p) -> RigidBody3D:
	var f := RigidBody3D.new()
	f.name = "Fuse"
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = Vector3(0.2, 0.2, 0.2)
	cs.shape = sh
	f.add_child(cs)
	f.gravity_scale = 0.0
	f.position = Vector3(-3, 1, -3)
	f.add_to_group("fuse")
	p.world.add_child(f)
	return f


func test_freeze_world_releases_puppets() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	var d: RigidBody3D = rig.spawn(h, "duck", Vector3(0, 0.2, 0))
	await rig.until(func(): return c.bodies.client.puppets.size() >= 1, 3.0)
	h.bodies.freeze_world()
	var n := _client_node(c, _host_id(h, d))
	var ok: bool = await rig.until(func(): return not n.freeze, 2.0)
	assert_true(ok, "phase 5 (D16): every puppet becomes a local dynamic body")
	var r0: int = c.bodies.client.counters.records_rx
	await rig.ms(300)
	assert_eq(c.bodies.client.counters.records_rx, r0, "no more body frames")


func test_meta_replicates_through_adapters() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	var m = rig.spawn(h, "meta_thing", Vector3(0, 0.2, 0))
	m.is_active = true
	m.value = 7
	m.set_meta("tst_val", 41)
	await rig.until(func(): return c.bodies.client.puppets.size() >= 1, 3.0)
	var eid := _host_id(h, m)
	var ok: bool = await rig.until(func():
		var n = _client_node(c, eid)
		return n != null and n.is_active and int(n.value) == 7 and int(n.get_meta("tst_val", 0)) == 41, 3.0)
	assert_true(ok, "save-schema meta and a GAMEPLAY adapter's meta applied")
	m.set_meta("tst_val", 42)
	h.bodies.meta_dirty(eid)
	ok = await rig.until(func(): return int(_client_node(c, eid).get_meta("tst_val", 0)) == 42, 2.0)
	assert_true(ok, "meta_dirty pushes the change")
	assert_true(c.gameplay.scope_ok, "adapter apply always ran inside the apply scope")
	assert_eq(int(c.bodies.meta_of(eid).get("tst", {}).get("v", 0)), 42, "meta_of on the client")
	assert_eq(_client_node(c, eid).called("apply_loaded_bag"), 0, "never apply_loaded_bag on clients")


func test_stray_guard_on_client() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	rig.spawn(h, "duck", Vector3(0, 0.2, 0))
	await rig.until(func(): return c.bodies.client.puppets.size() >= 1, 3.0)
	var s0: int = c.bodies.stray.stray_spawns
	var stray: RigidBody3D = c.pools.spawn("duck", Vector3(1, 1, 1))
	var debris: RigidBody3D = c.pools.spawn("debris_chunk", Vector3(1, 1, 1))
	await rig.physics(2)
	assert_false(stray in c.pools._pools.duck.active, "a stray pooled object is recycled at once")
	assert_false(debris in c.pools._pools.debris_chunk.active, "debris too")
	assert_eq(c.bodies.stray.stray_spawns, s0 + 1, "the duck counts as a stray")
	assert_true(c.bodies.stray.stray_expected >= 1, "debris is an expected, silent source")
	assert_eq(c.pools.active_total(), 1, "only the puppet is left")
	assert_eq(h.pools.active_total(), 1, "nothing changed on the host")


## Last: a script error aborts a test silently (it would look passed), so none may occur.
func test_zz_no_script_errors() -> void:
	assert_eq(core.guard.total_errors() - _e0, 0, "script errors during the suite (see headless-run.log)")
