extends "res://tests/test_case.gd"
## MP2 GRAB tolerance (fix plan P9 / P1 grab counters; MP2-DESIGN 5.2 step 4,
## 5.4): latency-aware held reach measured from the last held state, far after
## 1.0 s, a link stall freezes a hold instead of a silence revoke, the held
## header sequence counts lost frames, deny reason no_pose, revokes of grants
## that never carried, and the client trusting its GRAB row over a stale HELD.

const Rig = preload("res://tests/fakes/mp2_grab/grab_rig.gd")
const HeldStream = preload("res://gamedir/mods/PittMultiplayer/grab/held_stream.gd")
const Codec = preload("res://gamedir/mods/PittMultiplayer/net/codec.gd")
const PuppetBody = preload("res://gamedir/mods/PittMultiplayer/world/bodies/puppet_body.gd")

const DUCK := 1001


func _held(n: int = 1) -> Rig:
	var r := Rig.new(runner, n)
	r.body(DUCK)
	r.grab_body(r.c(0), DUCK)
	r.step()
	r.step()
	assert_true(r.c(0).grab.is_mine(DUCK), "granted")
	return r


func _rec(eid: int, epoch: int, p: Vector3) -> Dictionary:
	return {"eid": eid, "epoch": epoch, "p": p, "q": Quaternion.IDENTITY, "l": Vector3.ZERO, "a": Vector3.ZERO}


func test_no_far_revoke_at_6_5_m() -> void:
	var r := _held(1)
	var c = r.c(0)
	# the body (client copy at z -1.5) trails 6.5 m from the owner's eye: the old
	# 6.0 m reach revoked this, the held reach (2 x 3.5 + 1 = 8 m) keeps it
	r.pose(c.id, Vector3(0, 0, 5))
	r.steps(100, 20)                    # 2 s of frames
	assert_eq(r.host.grab.hold_kind(DUCK), "held", "still held at 6.5 m")
	assert_eq(r.host.grab.counters().grab_revokes, 0, "no revoke")
	assert_eq(int(r.host.grab.counters().held_rejected), 0, "no frame rejected")
	# past the reach it still ends: 8.5 m
	r.pose(c.id, Vector3(0, 0, 7))
	r.steps(60, 20)
	assert_eq(r.host.grab.counters().grab_revoke_reasons, {"far": 1}, "revoked far at 8.5 m")
	r.cleanup()


func test_held_reach_grows_with_speed_and_is_capped() -> void:
	var r := Rig.new(runner, 1)
	var h = r.host.grab.host
	for c in [[Vector3.ZERO, 8.0, "2 x max_grab_distance + 1 m"], [Vector3(6, 0, 0), 8.9, "+ speed x 0.15 s"],
			[Vector3(40, 0, 0), 9.0, "hard cap 9 m"]]:
		var got: float = h.held_reach({"ok": true, "vel": c[0]})
		assert_true(absf(got - float(c[1])) < 0.001, "%s (%.3f)" % [c[2], got])
	assert_true(absf(h.held_reach({"ok": true}) - 8.0) < 0.001, "a pose without velocity")
	r.cleanup()


func test_far_is_measured_from_the_held_state_not_the_follower() -> void:
	var r := _held(1)
	r.steps(5, 20)
	r.host.bodies.apply_follow = false
	# the follower node lags far behind (e.g. a snap pending); the held state is near
	r.host.nodes[DUCK].global_position = Vector3(0, 0.6, -30)
	r.steps(80, 20)
	assert_eq(r.host.grab.hold_kind(DUCK), "held", "no far revoke from the follower's position")
	r.cleanup()


func test_epoch_zero_far_frame_is_rejected() -> void:
	var r := Rig.new(runner, 1)
	r.body(DUCK)
	var c = r.c(0)
	r.grab_body(c, DUCK)
	r.deliver()                         # granted, not yet acknowledged
	var h = r.host.grab
	h.on_raw(c.id, 5, HeldStream.encode(r.net.clock_ms, [_rec(DUCK, 0, Vector3(0, 0.6, -9.5))]))
	assert_eq(r.host.bodies.pushes.get(DUCK, []).size(), 0, "a far epoch-0 frame is not pushed")
	assert_eq(int(h.counters().held_rejected), 1, "rejected")
	h.on_raw(c.id, 5, HeldStream.encode(r.net.clock_ms, [_rec(DUCK, 0, Vector3(0, 0.6, -1.2))]))
	assert_eq(r.host.bodies.pushes.get(DUCK, []).size(), 1, "a near epoch-0 frame is pushed")
	assert_eq(int(h.counters().grab_held_early), 1, "counted early")
	r.cleanup()


func test_link_stall_freezes_instead_of_revoking() -> void:
	var r := _held(1)
	var c = r.c(0)
	r.steps(5, 20)
	var hs = r.host.session
	hs._last_rx[c.id] = r.net.clock_ms     # the last packet of any kind from that peer
	c.grab.stream.paused = true
	r.steps(150, 20)                       # 3 s of nothing at all
	assert_eq(r.host.grab.hold_kind(DUCK), "held", "frozen, not revoked")
	assert_eq(r.host.grab.counters().grab_revokes, 0, "no revoke")
	assert_eq(int(r.host.grab.counters().grab_link_stalls), 1, "one stall counted")
	assert_true(r.host.grab.host.rows[DUCK].stalled, "row frozen")
	# the link comes back with frames: the hold just continues
	c.grab.stream.paused = false
	for i in 100:
		r.step(20)
		hs._last_rx[c.id] = r.net.clock_ms
	assert_eq(r.host.grab.hold_kind(DUCK), "held", "still held after the stall")
	assert_false(r.host.grab.host.rows[DUCK].stalled, "unfrozen")
	assert_eq(r.host.grab.counters().grab_revokes, 0, "no revoke")
	r.cleanup()


func test_link_back_without_frames_revokes_for_silence_from_the_resume() -> void:
	var r := _held(1)
	var c = r.c(0)
	r.steps(5, 20)
	var hs = r.host.session
	hs._last_rx[c.id] = r.net.clock_ms
	c.grab.stream.paused = true
	r.steps(100, 20)                       # 2 s stalled
	assert_eq(r.host.grab.hold_kind(DUCK), "held", "frozen")
	var t1: int = r.net.clock_ms
	var revoked_at := -1
	for i in 120:
		r.step(20)
		hs._last_rx[c.id] = r.net.clock_ms   # pings etc. flow again, no held frames
		if r.host.grab.hold_kind(DUCK) == "" and revoked_at < 0:
			revoked_at = r.net.clock_ms
	var dt := revoked_at - t1
	assert_true(dt >= 1300 and dt <= 1700, "silence counted from the resume (%d ms)" % dt)
	assert_eq(r.host.grab.counters().grab_revoke_reasons, {"silence": 1}, "reason silence")
	r.cleanup()


func test_held_sequence_gaps_are_counted() -> void:
	var r := Rig.new(runner, 1)
	var c = r.c(0)
	var h = r.host.grab
	var rec := _rec(4242, 1, Vector3.ZERO)       # no row: rejected, the header still counts
	for s in [0, 1, 4, 4, 3, 5]:
		h.on_raw(c.id, 5, HeldStream.encode(r.net.clock_ms, [rec], s))
	assert_eq(int(h.counters().grab_held_gaps), 2, "2 and 3 lost; a repeat and a step back count nothing")
	for s in [100, 200, 255, 1]:
		h.on_raw(c.id, 5, HeldStream.encode(r.net.clock_ms, [rec], s))
	assert_eq(int(h.counters().grab_held_gaps), 2 + 94 + 99 + 54 + 1, "gaps across the u8 wrap")
	# an older sender writes 0 every time: nothing counted
	var r2 := Rig.new(runner, 1)
	for i in 5:
		r2.host.grab.on_raw(r2.c(0).id, 5, HeldStream.encode(r2.net.clock_ms, [rec], 0))
	assert_eq(int(r2.host.grab.counters().grab_held_gaps), 0, "seq 0 forever: no gaps")
	r.cleanup()
	r2.cleanup()


func test_client_stream_writes_the_sequence() -> void:
	var r := Rig.new(runner, 1)
	var c = r.c(0)
	var rec := _rec(DUCK, 1, Vector3.ZERO)
	var a: PackedByteArray = c.grab.stream.maybe_send(c.session, 0, [rec])
	var b: PackedByteArray = c.grab.stream.maybe_send(c.session, 100, [rec])
	assert_eq(int(a[1]), 0, "first frame seq 0")
	assert_eq(int(b[1]), 1, "second frame seq 1")
	assert_eq(int(HeldStream.decode(b).seq), 1, "decoded seq")
	var cb := Codec.encode_held(5, [rec], 300)
	assert_eq(int(cb[1]), 300 & 0xFF, "codec writes the low byte")
	assert_eq(int(Codec.decode_held(cb).seq), 300 & 0xFF, "codec decodes it")
	HeldStream.use_fallback(true)
	assert_eq(int(HeldStream.decode(HeldStream.encode(5, [rec], 9)).seq), 9, "fallback round trip")
	HeldStream.use_fallback(false)
	r.cleanup()


func test_no_pose_is_its_own_deny_reason() -> void:
	var r := Rig.new(runner, 1)
	r.body(DUCK)
	var c = r.c(0)
	r.host.session.poses.erase(c.id)
	r.host.grab.on_msg(c.id, "own_req", {"eid": DUCK, "seen_epoch": 0})
	r.deliver()
	assert_eq(String(r.own_msgs(c.id, "deny")[0].reason), "no_pose", "no avatar pose: no_pose, not far")
	assert_eq(r.host.grab.counters().grab_deny_reasons, {"no_pose": 1}, "counted by reason")
	r.cleanup()


## A rack grant whose panel never carried: no far check before the first held
## frame (nothing to measure), the silence revoke after the grace is counted.
func test_grant_never_carried_is_counted_and_not_far() -> void:
	var r := Rig.new(runner, 1)
	r.body(DUCK)
	var c = r.c(0)
	r.host.bodies.nodes[1500] = r.host.nodes[DUCK]
	r.pose(c.id, Vector3(0, 0, 20))       # far from the host copy
	r.host.grab.grant(1500, c.id, "held", true)
	r.steps(100, 20)                       # 2 s, within grant grace + silence (2.5 s)
	assert_eq(r.host.grab.hold_kind(1500), "held", "no far revoke without a held state")
	r.steps(40, 20)
	assert_eq(r.host.grab.hold_kind(1500), "", "silence revoke after the grace")
	assert_eq(r.host.grab.counters().grab_revoke_reasons, {"silence": 1}, "reason silence")
	assert_eq(int(r.host.grab.counters().grab_grant_never_carried), 1, "counted as never carried")
	r.cleanup()


func test_carried_grant_revoke_is_not_never_carried() -> void:
	var r := _held(1)
	r.host.grab.revoke(DUCK, "consumed")
	assert_eq(int(r.host.grab.counters().grab_grant_never_carried), 0, "had held frames")
	r.cleanup()


## The busy client sends rack_store for a fresh rack grant; rack.gd revokes it
## "rack" before any held frame. That worked as designed: not never-carried.
func test_rack_store_of_fresh_grant_is_not_never_carried() -> void:
	var r := Rig.new(runner, 1)
	r.body(DUCK)
	var c = r.c(0)
	r.host.bodies.nodes[1500] = r.host.nodes[DUCK]
	r.host.grab.grant(1500, c.id, "held", true)
	r.host.grab.revoke(1500, "rack")
	assert_eq(r.host.grab.hold_kind(1500), "", "revoked")
	assert_eq(r.host.grab.counters().grab_revoke_reasons, {"rack": 1}, "reason rack")
	assert_eq(int(r.host.grab.counters().grab_grant_never_carried), 0, "not counted")
	r.cleanup()


## A HELD flag from a record older than the client's GRAB row (the release `set`
## arrived, a stale or reordered record still says held): the row wins.
func test_stale_held_flag_yields_to_the_row() -> void:
	var r := Rig.new(runner, 1)
	r.body(DUCK)
	var c = r.c(0)
	c.bodies.flags[DUCK] = 16
	c.grab.client.rows[DUCK] = {"owner": 1, "kind": "", "epoch": 4}
	c.bodies.host_states[DUCK] = {"epoch": 3}
	r.grab_body(c, DUCK)
	assert_eq(c.cam.picked_object, c.nodes[DUCK], "older record: carried")
	r.cleanup()
	# a record of a newer grant (another peer, its `set` not here yet) keeps the flag
	var r2 := Rig.new(runner, 1)
	r2.body(DUCK)
	var c2 = r2.c(0)
	c2.bodies.flags[DUCK] = 16
	c2.grab.client.rows[DUCK] = {"owner": 1, "kind": "", "epoch": 4}
	c2.bodies.host_states[DUCK] = {"epoch": 5}
	r2.grab_body(c2, DUCK)
	assert_true(c2.cam.picked_object == null, "newer record: refused")
	assert_eq(c2.grab.client.refusals, {"held": 1}, "as held")
	r2.cleanup()


func test_puppet_flags_follow_the_newest_record() -> void:
	var pb := PuppetBody.new()
	pb.push({"t": 200, "flags": 0})
	pb.push({"t": 100, "flags": 16})        # reordered: older than the newest
	assert_eq(pb.last_flags, 0, "an older record does not bring HELD back")
	pb.push({"t": 300, "flags": 16})
	assert_eq(pb.last_flags, 16, "the newest record sets the flags")
