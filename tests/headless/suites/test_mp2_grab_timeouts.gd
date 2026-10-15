extends "res://tests/test_case.gd"
## MP2 GRAB revocation and timeouts (MP2-DESIGN 5.4; 11.1 test_mp2_grab_protocol
## revoke cases, G4): silence 1.5 s, frames keep a hold alive, far for 0.5 s,
## GAMEPLAY capture revokes, a client's released request with no answer.

const Rig = preload("res://tests/fakes/mp2_grab/grab_rig.gd")

const DUCK := 1001


func _held(n: int = 1) -> Rig:
	var r := Rig.new(runner, n)
	r.body(DUCK)
	r.grab_body(r.c(0), DUCK)
	r.step()
	r.step()
	assert_true(r.c(0).grab.is_mine(DUCK), "granted")
	return r


func test_silence_revokes_after_1500_ms() -> void:
	var r := _held(2)
	var c = r.c(0)
	r.steps(10, 20)                    # frames flowing
	var last_push: Dictionary = r.host.bodies.pushes[DUCK].back()[0]
	c.grab.stream.paused = true        # G4 test hook
	var t0: int = r.net.clock_ms
	var revoked_at := -1
	for i in 120:
		r.step(20)
		if r.host.grab.hold_kind(DUCK) == "" and revoked_at < 0:
			revoked_at = r.net.clock_ms
	var dt := revoked_at - t0
	assert_true(dt >= 1300 and dt <= 1700, "revoked 1.5 s +- 0.2 after the last frame (%d ms after the pause)" % dt)
	assert_eq(r.host.grab.counters().grab_revoke_reasons, {"silence": 1}, "reason silence")
	var hr: Array = r.host.bodies.last("host_release")
	assert_true((hr[2].p as Vector3).is_equal_approx(last_push.p), "released at the last streamed state")
	var rv: Array = r.own_msgs(c.id, "revoke")
	assert_eq(rv.size(), 1, "revoke to the owner")
	assert_eq(String(rv[0].reason), "silence", "with the reason")
	assert_true(rv[0].has("s"), "and the host state")
	assert_true(c.cam.picked_object == null, "client force-dropped")
	assert_eq(r.net.sent("own_rel").size(), 0, "no own_rel for a revoke")
	assert_false(c.bodies.is_local_sim(DUCK), "puppet again")
	assert_eq(c.bodies.unsim_epoch[DUCK], 2, "blends to the revoke epoch")
	assert_eq(r.c(1).grab.owner_of(DUCK), 1, "others got set")
	r.cleanup()


func test_frames_keep_the_hold_alive() -> void:
	var r := _held(1)
	r.steps(150, 20)                    # 3 s of carrying
	assert_eq(r.host.grab.hold_kind(DUCK), "held", "still held")
	assert_eq(r.host.grab.counters().grab_revokes, 0, "no revoke")
	r.cleanup()


func test_far_owner_revokes_after_500_ms() -> void:
	var r := _held(1)
	var c = r.c(0)
	r.steps(5, 20)
	# the owner's avatar runs away; the body stays (frames would be rejected anyway)
	c.grab.stream.paused = true
	r.pose(c.id, Vector3(0, 0, 12))
	var t0: int = r.net.clock_ms
	r.steps(20, 20)                     # 400 ms
	assert_eq(r.host.grab.hold_kind(DUCK), "held", "not before 0.5 s")
	r.steps(10, 20)
	assert_eq(r.host.grab.hold_kind(DUCK), "", "revoked")
	assert_eq(r.host.grab.counters().grab_revoke_reasons, {"far": 1}, "reason far")
	assert_true(r.net.clock_ms - t0 < 1500, "before silence would have")
	r.cleanup()


func test_far_frames_count_and_revoke() -> void:
	var r := _held(1)
	var c = r.c(0)
	# the client streams poses 9 m away (desync / cheat): rejected, then revoked
	var n: RigidBody3D = c.nodes[DUCK]
	n.global_position = Vector3(0, 0.6, -9)
	r.steps(40, 20)
	assert_true(int(r.host.grab.counters().held_rejected) >= 10, "far frames rejected")
	assert_eq(r.host.grab.counters().grab_revoke_reasons, {"far": 1}, "revoked far")
	r.cleanup()


func test_gameplay_capture_revoke_only_stops_following() -> void:
	var r := _held(1)
	r.host.grab.revoke(DUCK, "consumed")
	var hr: Array = r.host.bodies.last("host_release")
	assert_eq(hr[2], {}, "host_release(eid, {}): the game already took the body")
	assert_eq(r.host.grab.owner_of(DUCK), 1, "host owns it")
	r.step()
	assert_true(r.c(0).cam.picked_object == null, "client dropped")
	assert_eq(String(r.own_msgs(r.c(0).id, "revoke")[0].reason), "consumed", "reason")
	assert_false(r.host.bodies.boosts.has(DUCK), "no boost for a consumed body")
	# revoking an unowned body is a no-op
	r.host.grab.revoke(DUCK, "consumed")
	assert_eq(r.host.grab.counters().grab_revokes, 1, "no second revoke")
	r.cleanup()


func test_released_request_without_answer_times_out() -> void:
	var r := Rig.new(runner, 1)
	r.body(DUCK)
	var c = r.c(0)
	r.net.latency_ms = 100000           # the host never answers in this test
	r.grab_body(c, DUCK)
	r.as_peer(c)
	c.cam.drop_object()
	r.steps(3)
	assert_true(c.bodies.is_local_sim(DUCK), "local while waiting")
	r.steps(200, 20)
	assert_false(c.bodies.is_local_sim(DUCK), "gave up after 3 s: puppet again")
	assert_eq(int(c.grab.counters().grab_pend_timeouts), 1, "counted")
	r.cleanup()
