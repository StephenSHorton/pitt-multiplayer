extends "res://tests/test_case.gd"
## MP2 review fixes (docs/mp/MP2-TEST-REPORT.md, review round 2), BODIES side, with
## the real BODIES module on a loopback pair:
##   - a puppet node recycled by client game code (the pause menu's Clear items
##     used to do it) is detected: the pool's LIFO reuse never lets two eids drive
##     one node, the lost eid comes back, a later despawn recycles only its own node
##   - building a world snapshot never swallows a meta change for the peers
##     already in the world
##   - only active puppets are driven; idle ones are re-checked round-robin
##   - SLEEP sends never take the whole tick while bodies are awake

const Mp2Rig = preload("res://tests/fakes/mp2_bodies/mp2_rig.gd")

var rig = null


func before_all() -> void:
	rig = Mp2Rig.new(tree, runner)


func after_all() -> void:
	await rig.cleanup()


func _host_id(h, node: Node) -> int:
	return int(h.api.entities.id_of(node))


func _node_of(c, eid: int) -> Node3D:
	var pb = c.bodies.client.puppets.get(eid, null)
	return pb.node() if pb != null else null


func test_locally_recycled_puppet_is_never_shared() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	var ducks: Array = []
	for i in 4:
		ducks.append(rig.spawn(h, "duck", Vector3(i * 0.6, 0.2, 0)))
	var ok: bool = await rig.until(func(): return c.bodies.client.puppets.size() >= 4, 3.0)
	assert_true(ok, "4 puppets")
	var lost_eid := _host_id(h, ducks[1])
	var lost_node := _node_of(c, lost_eid)
	assert_true(lost_node != null, "puppet node")
	# client game code recycles a puppet (outside the apply scope), then the host spawns
	c.pools.recycle(lost_node)
	var fresh: Node3D = rig.spawn(h, "duck", Vector3(3, 0.2, 2))
	await rig.physics(2)
	var fresh_eid := _host_id(h, fresh)
	ok = await rig.until(func(): return _node_of(c, fresh_eid) != null and _node_of(c, lost_eid) != null, 3.0)
	assert_true(ok, "both eids have a puppet again")
	var n_fresh := _node_of(c, fresh_eid)
	var n_lost := _node_of(c, lost_eid)
	assert_true(n_fresh != n_lost, "never one node for two eids")
	assert_true(int(c.bodies.client.counters.puppet_lost) >= 1, "the lost puppet was detected")
	assert_eq(int(n_lost.get_meta("pitt_mp_puppet")), lost_eid, "respawned under its own eid")
	assert_eq(c.bodies.client.pooled_count(), c.pools.active_total(), "pooled count matches the pools")
	# the host despawns the lost eid: only its own node goes back
	h.pools.recycle(ducks[1])
	ok = await rig.until(func(): return not c.bodies.client.puppets.has(lost_eid), 3.0)
	assert_true(ok, "despawned")
	assert_true(_node_of(c, fresh_eid) == n_fresh and n_fresh.visible, "the other eid keeps its node")
	assert_eq(int(c.bodies.stray.stray_spawns), 0, "no strays")


func test_wsnap_build_keeps_meta_changes_for_existing_peers() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	var thing = rig.spawn(h, "meta_thing", Vector3(0, 0.3, -2))
	await rig.physics(2)
	var eid := _host_id(h, thing)
	var ok: bool = await rig.until(func(): return _node_of(c, eid) != null, 3.0)
	assert_true(ok, "replicated")
	await rig.physics(30)
	thing.is_active = true
	h.bodies.host.build_wsnap()          # a late joiner's snapshot in the same frame
	ok = await rig.until(func(): return bool(_node_of(c, eid).is_active), 3.0)
	assert_true(ok, "the change still reaches the peer already in the world")


func test_only_active_puppets_are_driven() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	for i in 30:
		rig.spawn(h, "duck", Vector3((i % 6) * 0.6, 0.2, -int(i / 6.0) * 0.6))
	var ok: bool = await rig.until(func(): return c.bodies.client.puppets.size() >= 30, 3.0)
	assert_true(ok, "30 puppets")
	ok = await rig.until(func(): return h.bodies.host.awake.is_empty(), 8.0)
	assert_true(ok, "everything at rest on the host")
	ok = await rig.until(func(): return c.bodies.client.active.is_empty(), 4.0)
	assert_true(ok, "no puppet driven once all are at rest (%d active)" % c.bodies.client.active.size())
	# a puppet unfrozen by local code is re-frozen by the round-robin pass
	var any: RigidBody3D = c.bodies.client.puppets.values()[0].node()
	any.freeze = false
	await rig.physics(3)
	assert_true(any.freeze, "re-frozen by the verify pass")


func test_sleep_burst_leaves_room_for_awake_bodies() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var host = h.bodies.host
	var ps = host._peer(int(pc[1].session.my_peer_id()))
	# 300 bodies come to rest at once while one is moving
	for i in 300:
		rig.spawn(h, "duck", Vector3((i % 20) * 0.5, 0.2, -int(i / 20.0) * 0.5))
	await rig.physics(2)
	for eid in host.ents:
		ps.sleep_sched[eid] = {"t0": 0, "n": 0}
	ps.sleep_next_ms = 0
	var before := int(host.counters.sleep_capped)
	host._build_shared(Time.get_ticks_msec())
	assert_true(host._c_ents.size() > 0, "bodies awake")
	host._send_peer(ps, Time.get_ticks_msec())
	assert_true(int(host.counters.sleep_capped) > before, "the SLEEP burst was capped for this tick")
