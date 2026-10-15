extends "res://tests/test_case.gd"
## PlayerEffectRedirect and pimp (MP2-DESIGN 6.6): a host-side call made for a
## remote peer that pushes or moves the host's own player (cannon recoil through
## get_first_node_in_group("player")) leaves the host player untouched and reaches
## the remote player as an impulse / teleport; impulses of one tick are summed;
## the host's own calls are not redirected; a qa_arm whack on a ghost goes to its
## player with the game's bonk values and counts a safety violation on the host.

const GpRig = preload("res://tests/fakes/mp2_gameplay/gp_rig.gd")
const MpGate = preload("res://gamedir/mods/PittMultiplayer/gameplay/mp_gate.gd")
const EXT := "res://gamedir/mods/PittMultiplayer/extensions/gameplay/"

var rig = null


func before_all() -> void:
	rig = GpRig.new(tree, runner)


func after_all() -> void:
	await rig.cleanup()


func _pair() -> Array:
	await rig.cleanup()
	var h = rig.add_host()
	var c = rig.add_client(2)
	rig.start()
	return [h, c]


func test_redirect_restores_host_player_and_forwards() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var p = h.adapter.player
	p.velocity = Vector3(1, 0, 0)
	p.external_velocity = Vector3(0, 0, 0.5)
	p.global_position = Vector3(5, 0, 5)
	var r = h.gp.host_exec(2, func():
		assert_eq(MpGate.exec_peer, 2, "exec_peer inside")
		p.velocity += Vector3(0, 3, 0)          # recoil-like velocity write
		p.external_velocity += Vector3(-2, 0, 0)
		return 42)
	assert_eq(r, 42, "return value passed through")
	assert_eq(MpGate.exec_peer, 0, "exec_peer restored")
	assert_true(p.velocity.is_equal_approx(Vector3(1, 0, 0)), "host velocity restored")
	assert_true(p.external_velocity.is_equal_approx(Vector3(0, 0, 0.5)), "host external velocity restored")
	h.gp.host_exec(2, func(): p.velocity += Vector3(0, 1, 0))
	h.gp.player_fx.tick(100000)
	var sent: Array = h.session.sent_of("pimp")
	assert_eq(sent.size(), 1, "one pimp per tick for the peer (summed)")
	var v: Array = sent[0][2].v
	assert_true(Vector3(v[0], v[1], v[2]).is_equal_approx(Vector3(-2, 4, 0)), "delta = velocity + external deltas (%s)" % [v])
	assert_eq(c.api.impulses.size(), 1, "client applied player.impulse")
	assert_true(c.api.impulses[0].is_equal_approx(Vector3(-2, 4, 0)), "same impulse on the client")


func test_teleport_and_host_own_calls() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var p = h.adapter.player
	p.global_position = Vector3(0, 0, 0)
	h.gp.host_exec(2, func(): p.global_position = Vector3(10, 0, 0))
	assert_true(p.global_position.is_equal_approx(Vector3.ZERO), "host player not moved")
	assert_eq(c.api.teleports.size(), 1, "teleport forwarded")
	assert_true(c.api.teleports[0].is_equal_approx(Vector3(10, 0, 0)), "to the jumped position")
	h.gp.host_exec(1, func(): p.velocity = Vector3(0, 9, 0))
	assert_true(p.velocity.is_equal_approx(Vector3(0, 9, 0)), "host's own call: not redirected")
	h.gp.host_exec(0, func(): p.velocity = Vector3(0, 7, 0))
	assert_true(p.velocity.is_equal_approx(Vector3(0, 7, 0)), "machine call: not redirected")
	h.gp.player_fx.tick(200000)
	assert_eq(h.session.sent_of("pimp").size(), 1, "only the teleport went out")


func test_client_pimp_kinds() -> void:
	var pc = await _pair()
	var c = pc[1]
	c.gp.on_msg(1, "pimp", {"respawn": true, "src": "x"})
	assert_eq(c.adapter.player.respawns, 1, "respawn")
	c.gp.on_msg(1, "pimp", {"v": [0, 1000, 0], "src": "x"})
	assert_eq(c.api.impulses.size(), 0, "absurd impulse ignored")
	c.gp.on_msg(1, "pimp", {"v": [1, 2, 3], "src": "x"})
	assert_eq(c.api.impulses.size(), 1, "impulse applied")


func test_qa_arm_whacks_a_ghost() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	h.session.set_pose(2, Vector3(2, 0, 0))
	h.gp.ghosts.physics(0.016)
	await wait_physics(3)        # sync_to_physics: the ghost moves on the physics step
	rig.as_peer(h)
	var arm: Node = GpRig.ext_script("qa_arm").new()
	var pivot := Node3D.new()
	arm.add_child(pivot)
	h.adapter.world.add_child(arm)
	arm.turret_pivot = pivot
	arm.player_bonk_impulse = 9.0
	arm.player_bonk_lift = 3.0
	arm._whacked = {}
	var ghost = h.gp.ghost_of(2)
	arm._whack(ghost)
	arm._whack(ghost)
	assert_eq(h.adapter.gs.safety_violations, 1, "one safety violation on the host")
	assert_has(arm.stub_calls, "_play_whack_audio", "whack audio")
	assert_false("_whack" in arm.stub_calls, "the game's own body branch not run for a ghost")
	h.gp.player_fx.tick(300000)
	assert_eq(c.api.impulses.size(), 1, "the remote player got one bonk")
	assert_true(c.api.impulses[0].is_equal_approx(Vector3(9, 3, 0)), "bonk impulse + lift (%s)" % c.api.impulses[0])
	# a client's arm copy never whacks
	rig.as_peer(c)
	var carm: Node = GpRig.ext_script("qa_arm").new()
	c.adapter.world.add_child(carm)
	carm._whack(c.adapter.player)
	carm._physics_process(0.016)
	assert_eq(carm.stub_calls, [], "client: state machine and whacks gated")
