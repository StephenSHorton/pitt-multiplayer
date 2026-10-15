extends "res://tests/test_case.gd"
## MP2 GRAB release / throw / equip handoff (MP2-DESIGN 5.3, 5.5, 5.6;
## 11.1 test_mp2_grab_release): state captured on the next physics frame,
## exact host restore, throw metas, placement, equip/unequip epochs, host
## player rows, the pause-menu release, the 30 Hz held stream.

const Rig = preload("res://tests/fakes/mp2_grab/grab_rig.gd")
const FakePanel = preload("res://tests/fakes/mp2_grab/fake_panel.gd")
const FakeTool = preload("res://tests/fakes/mp2_grab/fake_tool.gd")
const HeldStream = preload("res://gamedir/mods/PittMultiplayer/grab/held_stream.gd")

const DUCK := 1001
const PANEL := 1100
const TOOL := 1200


func _granted(r: Rig, c, eid: int) -> void:
	r.grab_body(c, eid)
	r.step()
	r.step()
	assert_true(c.grab.is_mine(eid), "granted")


func test_plain_drop_hands_back_exact_state() -> void:
	var r := Rig.new(runner, 2)
	r.body(DUCK)
	var c = r.c(0)
	_granted(r, c, DUCK)
	var n: RigidBody3D = c.nodes[DUCK]
	r.as_peer(c)
	c.cam.drop_object()
	r.step()                                   # release seen
	assert_eq(r.net.sent("own_rel").size(), 0, "not sent in the release frame")
	n.global_position = Vector3(0.5, 0.4, -1.2)  # the body moved for one physics step
	n.linear_velocity = Vector3(0, -1.5, 0.25)
	r.step()                                   # captured
	var rel: Array = r.net.sent("own_rel")
	assert_eq(rel.size(), 1, "own_rel sent once")
	assert_eq(int(rel[0].epoch), 1, "with the granted epoch")
	assert_false(bool(rel[0].thrown), "a plain drop is not a throw")
	assert_true(HeldStream.vec3(rel[0].s.p).is_equal_approx(Vector3(0.5, 0.4, -1.2)), "state of the next physics frame")
	var hr: Array = r.host.bodies.last("host_release")
	assert_eq(hr[1], DUCK, "host_release")
	assert_true((hr[2].p as Vector3).is_equal_approx(Vector3(0.5, 0.4, -1.2)), "exact pose")
	assert_true((hr[2].l as Vector3).is_equal_approx(Vector3(0, -1.5, 0.25)), "exact velocity")
	assert_eq(r.host.grab.owner_of(DUCK), 1, "host owns it again")
	assert_eq(r.host.grab.epoch_of(DUCK), 2, "epoch +2 over the hold")
	assert_eq(r.host.bodies.boosts.get(DUCK, 0.0), 2.0, "boosted 2 s")
	assert_false(c.bodies.is_local_sim(DUCK), "client copy back to puppet mode")
	assert_eq(c.bodies.unsim_epoch[DUCK], 2, "on the first host record of epoch 2")
	assert_eq(r.c(1).grab.owner_of(DUCK), 1, "others see the release")
	assert_true(r.own_msgs(c.id, "set").size() >= 1, "the owner learns the new epoch too")
	r.cleanup()


func test_throw_product_restores_throw_meta() -> void:
	var r := Rig.new(runner, 1)
	r.body(DUCK)
	var c = r.c(0)
	_granted(r, c, DUCK)
	r.as_peer(c)
	c.cam.stub_throw(Vector3(0, 1, -5))
	r.step()
	r.step()
	var rel: Dictionary = r.net.sent("own_rel")[0]
	assert_true(bool(rel.thrown), "thrown")
	assert_true(rel.has("throw_meta"), "throw meta sent")
	assert_true(int(rel.throw_meta.age_ms) >= 0 and int(rel.throw_meta.age_ms) < 500, "age in ms")
	var h: RigidBody3D = r.host.nodes[DUCK]
	assert_true(h.has_meta("player_throw_time"), "host: player_throw_time restored")
	var age := Time.get_ticks_msec() / 1000.0 - float(h.get_meta("player_throw_time"))
	assert_true(age >= 0.0 and age < 1.0, "host stamp = now - age (%.3f)" % age)
	assert_true((h.get_meta("player_throw_position") as Vector3).distance_to(c.cam.global_position) < 0.01,
		"host: the thrower's position")
	r.cleanup()


func test_throw_non_product_by_velocity_jump() -> void:
	var r := Rig.new(runner, 1)
	r.body(DUCK, Vector3(0, 0.65, -1.5), false)
	var c = r.c(0)
	_granted(r, c, DUCK)
	var n: RigidBody3D = c.nodes[DUCK]
	r.step()
	# the inline rMouse throw: no drop_object, an impulse
	n.linear_velocity = Vector3(0, 2, -6)
	c.cam.picked_object = null
	r.step()
	r.step()
	var rel: Dictionary = r.net.sent("own_rel")[0]
	assert_true(bool(rel.thrown), "velocity jump > 2 m/s = throw")
	assert_false(rel.has("throw_meta"), "no product metas")
	r.cleanup()


func test_invalid_snap_drop_keeps_carry() -> void:
	var r := Rig.new(runner, 1)
	r.body(DUCK)
	var c = r.c(0)
	_granted(r, c, DUCK)
	c.cam.refuse_drop = true
	r.as_peer(c)
	c.cam.drop_object()
	r.steps(3)
	assert_eq(c.cam.picked_object, c.nodes[DUCK], "still carried")
	assert_eq(r.net.sent("own_rel").size(), 0, "no release")
	assert_true(c.grab.is_mine(DUCK), "still mine")
	r.cleanup()


func test_pause_menu_release_is_a_normal_release() -> void:
	var r := Rig.new(runner, 1)
	r.body(DUCK)
	var c = r.c(0)
	_granted(r, c, DUCK)
	r.as_peer(c)
	c.cam.release_held_object()          # what world/pause_guard does through the adapter
	r.steps(2)
	var rel: Array = r.net.sent("own_rel")
	assert_eq(rel.size(), 1, "own_rel")
	assert_false(bool(rel[0].thrown), "not a throw")
	assert_eq(r.host.grab.owner_of(DUCK), 1, "host owns it, the body falls on both")
	r.cleanup()


func test_placed_panel_is_placed_on_the_host() -> void:
	var r := Rig.new(runner, 1)
	r.body(PANEL, Vector3(0, 0.65, -1.5), false, FakePanel)
	var c = r.c(0)
	_granted(r, c, PANEL)
	r.as_peer(c)
	c.cam.drop_object()                  # the stub defers place() like the game
	r.step()                             # release seen
	await wait_frames(1)                 # the deferred place() runs
	r.step()                             # captured
	var rel: Dictionary = r.net.sent("own_rel")[0]
	assert_eq(int(rel.get("panel_state", -1)), 1, "panel_state sent (placed next frame)")
	var hp = r.host.nodes[PANEL]
	assert_false("force_place" in hp.calls, "not yet: placed after 2 physics frames")
	r.steps(2)
	assert_has(hp.calls, "force_place", "host panel force_place")
	assert_eq(int(hp.state), 1, "host panel PLACED")
	assert_true(hp.freeze and hp.freeze_mode == RigidBody3D.FREEZE_MODE_STATIC, "STATIC on the host")
	assert_true((hp.global_position as Vector3).distance_to(c.nodes[PANEL].global_position) < 0.01, "pose within 1 cm")
	assert_has(r.host.bodies.dirty, PANEL, "meta pushed at once")
	r.cleanup()


func test_grant_unplaces_host_copy() -> void:
	var r := Rig.new(runner, 1)
	r.body(TOOL, Vector3(0, 0.65, -1.5), false, FakeTool)
	var hp = r.host.nodes[TOOL]
	hp.placed = true
	_granted(r, r.c(0), TOOL)
	assert_has(hp.calls, "unplace", "the host copy is unplaced when a client takes it")
	r.cleanup()


func test_equip_and_unequip_handoff() -> void:
	var r := Rig.new(runner, 2)
	r.body(TOOL, Vector3(0, 0.65, -1.5), false, FakeTool)
	var c = r.c(0)
	_granted(r, c, TOOL)
	r.as_peer(c)
	c.cam.stub_equip()
	r.step()
	var eq: Array = r.net.sent("own_equip")
	assert_eq(eq.size(), 1, "own_equip")
	assert_eq(int(eq[0].epoch), 1, "with the grant epoch")
	r.step()
	assert_eq(r.host.grab.hold_kind(TOOL), "equipped", "host: equipped")
	assert_eq(r.host.grab.epoch_of(TOOL), 2, "epoch 2")
	assert_eq(r.host.changes.back(), [TOOL, c.id, "equipped", 2], "owner_changed for GAMEPLAY's rig")
	assert_eq(r.host.bodies.owner_views[TOOL], [c.id, "equipped", 2], "BODIES flags NOCOLLIDE from the view")
	assert_true(c.bodies.is_local_sim(TOOL), "the equipped copy stays local")
	assert_eq(r.net.sent("own_rel").size(), 0, "equip is not a release")
	assert_eq(r.c(1).grab.hold_kind(TOOL), "equipped", "others know")
	assert_eq(int(c.grab.client.mine[TOOL].epoch), 2, "client epoch matches the host")
	# unequip: picked again, own_unequip with the drop spot, then held frames resume
	r.as_peer(c)
	c.cam.stub_unequip()
	r.step()
	var un: Array = r.net.sent("own_unequip")
	assert_eq(un.size(), 1, "own_unequip")
	assert_eq(int(un[0].epoch), 2, "epoch 2")
	assert_eq(un[0].drop.size(), 3, "drop spot")
	r.step()
	assert_eq(r.host.grab.hold_kind(TOOL), "held", "host: held again")
	assert_eq(r.host.grab.epoch_of(TOOL), 3, "epoch 3")
	assert_eq(r.host.bodies.last("host_follow")[1], TOOL, "follows the owner again")
	assert_false(r.host.grab.last_drop(TOOL).is_empty(), "GAMEPLAY reads the drop spot")
	var pushes_before: int = r.host.bodies.pushes.get(TOOL, []).size()
	r.steps(4, 40)
	assert_true(r.host.bodies.pushes.get(TOOL, []).size() > pushes_before, "held frames accepted at epoch 3")
	assert_eq(int(r.host.grab.counters().held_rejected), 0, "no rejected frames")
	r.cleanup()


func test_host_player_rows() -> void:
	var r := Rig.new(runner, 1)
	r.body(TOOL, Vector3(0, 0.65, -1.5), false, FakeTool)
	var h = r.host
	var c = r.c(0)
	r.grab_body(h, TOOL)
	r.step()
	assert_eq([h.grab.owner_of(TOOL), h.grab.hold_kind(TOOL)], [1, "held"], "host holds")
	assert_eq(c.grab.hold_kind(TOOL), "held", "client sees the host's hold")
	r.as_peer(h)
	h.cam.stub_equip()
	r.step()
	assert_eq(h.grab.hold_kind(TOOL), "equipped", "host equipped")
	r.as_peer(h)
	h.cam.stub_unequip()
	r.step()
	assert_eq(h.grab.hold_kind(TOOL), "held", "host unequipped")
	r.as_peer(h)
	h.cam.drop_object()
	r.steps(2)
	assert_eq(h.grab.hold_kind(TOOL), "", "host released")
	assert_eq(c.grab.hold_kind(TOOL), "", "client sees the release")
	assert_eq(h.grab.epoch_of(TOOL), 4, "4 changes")
	assert_eq(r.net.sent("own_rel").size(), 0, "the host never sends own_rel")
	assert_eq(h.bodies.count("host_release"), 0, "the host body was never a follower")
	r.cleanup()


func test_held_stream_rate_and_epoch() -> void:
	var r := Rig.new(runner, 1)
	r.body(DUCK)
	var c = r.c(0)
	_granted(r, c, DUCK)
	var before: int = c.session.raw_sent
	for i in 60:
		r.step(16)                               # ~1 s at 60 Hz
	var n: int = c.session.raw_sent - before
	assert_true(n >= 26 and n <= 31, "about 30 held frames per second (%d)" % n)
	assert_true(r.host.bodies.pushes[DUCK].size() >= 26, "all pushed")
	c.grab.stream.paused = true
	before = c.session.raw_sent
	r.steps(10)
	assert_eq(c.session.raw_sent, before, "test hook stops the stream")
	r.cleanup()


## Review fix: a release state far from the owner's eye is not trusted (a body
## released across the map, e.g. into the maw): the last accepted held frame is used.
func test_far_release_state_is_clamped() -> void:
	var r := Rig.new(runner, 1)
	r.body(DUCK)
	var c = r.c(0)
	r.pose(c.id, Vector3(0, 0, 0))
	_granted(r, c, DUCK)
	var n: RigidBody3D = c.nodes[DUCK]
	r.steps(3)                                 # a few held frames near the eye
	r.as_peer(c)
	c.cam.drop_object()
	r.step()
	n.global_position = Vector3(400, 2, -300)  # a forged / teleported release pose
	n.linear_velocity = Vector3(0, 0, 500)
	r.step()
	var hr: Array = r.host.bodies.last("host_release")
	assert_eq(hr[1], DUCK, "released")
	assert_true((hr[2].p as Vector3).length() < 10.0, "pose clamped near the owner (%s)" % hr[2].p)
	assert_true((hr[2].l as Vector3).length() <= 60.5, "velocity capped (%s)" % hr[2].l)
	assert_true(int(r.host.grab.host.counters.rel_clamped) >= 1, "counted")
	r.cleanup()
