extends "res://tests/test_case.gd"
## Per-player panel rack (D13, MP2-DESIGN 6.11) and the GAMEPLAY mirror fields
## (6.10): a client racks a held panel through the host (recycled there, pushed on
## the peer's own host-side stack, the stack mirrored to that peer only), withdraws
## it (spawned at its rig hands, granted to it as held once tracked); remote
## channels/links, world flags and buffs travel as econ mirror fields.

const GpRig = preload("res://tests/fakes/mp2_gameplay/gp_rig.gd")
const FakeAdapter = preload("res://tests/fakes/mp2_gameplay/fake_gameplay_adapter.gd")

var rig = null


func before_all() -> void:
	rig = GpRig.new(tree, runner)


func after_all() -> void:
	await rig.cleanup()


func _pair() -> Array:
	await rig.cleanup()
	var h = rig.add_host()
	var c = rig.add_client(2)
	h.session.set_pose(2, Vector3(1, 0, 0))
	rig.start()
	return [h, c]


func test_store_and_withdraw() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var panel := FakeAdapter.FPooled.new()
	panel.pool_id = "panel"
	panel.add_to_group("panel")
	h.adapter.world.add_child(panel)
	var eid: int = h.bodies.add(panel, 2200, "pooled", "panel")
	h.grab.set_owner(eid, 2, "held")
	assert_eq(h.gp.rack.store(2, eid), "", "stored")
	assert_eq(h.adapter.pools.recycled, [panel], "recycled on the host")
	assert_eq(h.grab.revoked[-1], [eid, "rack"], "the client's hold ended first")
	assert_eq(h.gp.rack.stack_of(2), ["panel"], "the peer's own stack")
	assert_eq(c.adapter.gs.panel_stack, ["panel"], "mirrored to that peer")
	assert_eq(h.adapter.gs.panel_stack, [], "the host player's rack untouched")
	# withdraw: spawned at the rig, granted once BODIES tracks it
	assert_eq(h.gp.rack.withdraw(2), "", "withdrawn")
	var spawned = h.adapter.pools.spawned[-1][1]
	assert_eq(String(h.adapter.pools.spawned[-1][0]), "panel", "panel pool")
	assert_eq(h.grab.granted.size(), 0, "not tracked yet")
	var neid: int = h.bodies.add(spawned, 2201, "pooled", "panel")
	assert_eq(h.grab.granted, [[neid, 2, "held", true]], "granted as held with carry")
	assert_eq(c.adapter.gs.panel_stack, [], "stack mirrored empty")
	assert_eq(h.gp.rack.withdraw(2), "rack empty", "empty rack refused")


func test_store_refusals() -> void:
	var pc = await _pair()
	var h = pc[0]
	var duck := RigidBody3D.new()
	h.adapter.world.add_child(duck)
	h.bodies.add(duck, 2300)
	assert_eq(h.gp.rack.store(2, 2300), "not a panel", "only panels")
	var panel := FakeAdapter.FPooled.new()
	panel.pool_id = "panel"
	panel.add_to_group("panel")
	h.adapter.world.add_child(panel)
	h.bodies.add(panel, 2301, "pooled", "panel")
	h.grab.set_owner(2301, 3, "held")
	assert_eq(h.gp.rack.store(2, 2301), "held by another player", "someone else's panel")
	h.grab.set_owner(2301, 1, "")
	h.adapter.gs.rack_capacity = 0
	assert_eq(h.gp.rack.store(2, 2301), "rack full", "capacity from the shared upgrade")
	h.adapter.gs.rack_capacity = 4
	h.session.set_pose(2, Vector3(40, 0, 0))
	assert_eq(h.gp.rack.store(2, 2301), "too far", "reach")


func test_mirror_fields() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var fields: Dictionary = h.session.econ_host.fields
	for f in ["remote", "flags", "buffs"]:
		assert_true(fields.has(f), "field %s registered" % f)
	# remote channels: links by eid, states through set_remote_channel_state
	var fan_h := RigidBody3D.new()
	h.adapter.world.add_child(fan_h)
	h.bodies.add(fan_h, 2400)
	var fan_c := RigidBody3D.new()
	c.adapter.world.add_child(fan_c)
	c.bodies.add(fan_c, 2400)
	h.adapter.gs.remote_channels[1].append(fan_h)
	h.adapter.gs.remote_channel_states[1] = false
	var v = JSON.parse_string(JSON.stringify(fields.remote.read.call()))
	c.session.econ_host.fields.remote.apply.call(v)
	assert_eq(c.adapter.gs.remote_channels[1], [fan_c], "link rebuilt from the eid")
	assert_eq(c.adapter.gs.channel_sets, [[1, false]], "state through the game's setter")
	# flags
	h.adapter.gs.uv_unlocked = true
	h.adapter.gs.pickaxe_tier = 3
	c.session.econ_host.fields.flags.apply.call(JSON.parse_string(JSON.stringify(fields.flags.read.call())))
	assert_true(c.adapter.gs.uv_unlocked, "uv_unlocked")
	assert_eq(c.adapter.gs.pickaxe_tier, 3, "pickaxe tier")
	# buffs: stable while running, activated on the client, removed when gone
	h.session.now_ms = 50000
	c.session.now_ms = 50000
	h.adapter.gs.active_buffs = {"product_value": {"multiplier": 2.0, "time_remaining": 30.0, "duration": 60.0}}
	var b1 = fields.buffs.read.call()
	h.adapter.gs.active_buffs.product_value.time_remaining = 29.0
	h.session.now_ms = 51000
	var b2 = fields.buffs.read.call()
	assert_eq(b1, b2, "the field does not change every frame")
	c.session.econ_host.fields.buffs.apply.call(JSON.parse_string(JSON.stringify(b2)))
	var cb: Dictionary = c.adapter.gs.active_buffs
	assert_true(cb.has("product_value") and float(cb.product_value.multiplier) == 2.0, "buff on the client HUD")
	assert_true(absf(float(cb.product_value.time_remaining) - 30.0) < 0.01, "remaining from the end time")
	c.session.econ_host.fields.buffs.apply.call([])
	assert_false(c.adapter.gs.active_buffs.has("product_value"), "expired buff removed")
