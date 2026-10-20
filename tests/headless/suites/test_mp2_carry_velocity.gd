extends "res://tests/test_case.gd"
## MP2 5.2 step 5 (0.2.3): a held frame's velocity is the game carry's pull toward
## the owner's hands (a full crate hanging still reads about 4 m/s), not the body's
## motion. The host must not hand it on:
##   - records of a client-held body to a third peer carry the motion the held
##     frames show (still -> about 0, no LIN; moving -> its real velocity)
##   - the owner's release keeps the velocity it sent (a throw stays a throw)
##   - a release the host decides itself (silence revoke) moves at the observed
##     velocity of the last held frames, not the carry pull
## The real host replicator on a fake clock (its packets decoded per peer by a stub
## session) and the GRAB rig (host + client, fake bodies).

const Codec = preload("res://gamedir/mods/PittMultiplayer/net/codec.gd")
const MetaSync = preload("res://gamedir/mods/PittMultiplayer/world/bodies/meta_sync.gd")
const HeldStream = preload("res://gamedir/mods/PittMultiplayer/grab/held_stream.gd")
const Rig = preload("res://tests/fakes/mp2_grab/grab_rig.gd")
const THIRD := 2         # sees the body only through host records
const OWNER := 3         # carries it and streams held frames
const DUCK := 1001


class ClockRep extends "res://gamedir/mods/PittMultiplayer/world/bodies/replicator_host.gd":
	var t := 100000

	func _now() -> int:
		return t


class StubSession extends RefCounted:
	const Codec = preload("res://gamedir/mods/PittMultiplayer/net/codec.gd")
	var rep = null
	var in_game: Array = [2, 3]
	var recs: Array = []        # {peer, t, eid, flags, p, l}

	func in_game_peers() -> Array:
		return in_game

	func avatar_pose(_peer: int) -> Dictionary:
		return {"ok": true, "pos": Vector3.ZERO}

	func host_now() -> int:
		return rep.t

	func send_unreliable(peer: int, pkt: PackedByteArray) -> void:
		var d := Codec.decode_bodies(pkt)
		if d.is_empty():
			return
		for r in d.records:
			recs.append({"peer": peer, "t": rep.t, "eid": int(r.eid), "flags": int(r.flags), "p": r.p, "l": r.l})

	func send_world(_peer: int, _k: String, _msg: Dictionary) -> void:
		pass


class StubBodies extends RefCounted:
	var session = null
	var meta_sync = null
	var adapter = null

	func emit_added(_eid: int, _node: Node) -> void:
		pass

	func emit_removed(_eid: int) -> void:
		pass

	func log_warn(_m: String) -> void:
		pass

	func toast(_k: String) -> void:
		pass


var _vp: SubViewport = null
var _world: Node3D = null


func _setup() -> Array:
	_teardown()
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.size = Vector2i(8, 8)
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_vp.name = "CarryWorld"
	runner.add_child(_vp)
	_world = Node3D.new()
	_vp.add_child(_world)
	var b := StubBodies.new()
	b.meta_sync = MetaSync.new()
	var s := StubSession.new()
	b.session = s
	var rep := ClockRep.new(b, ["duck"], "normal")
	s.rep = rep
	return [rep, s]


func _teardown() -> void:
	if _vp != null and is_instance_valid(_vp):
		_vp.queue_free()
	_vp = null
	_world = null


## A dynamic body (no gravity, never sleeping) tracked by the replicator, held by
## OWNER: a frozen KINEMATIC follower of its stream, as GRAB sets it up.
func _held_body(rep, pos: Vector3) -> Array:
	var n := RigidBody3D.new()
	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.1
	cs.shape = sh
	n.add_child(cs)
	n.gravity_scale = 0.0
	n.can_sleep = false
	_world.add_child(n)
	n.global_position = pos
	rep.track(DUCK, n, "pooled", "duck")
	rep.peer_ready(THIRD)
	rep.peer_ready(OWNER)
	rep.t += 33
	rep.physics_step()
	rep.set_owner(DUCK, OWNER, "held", 1)
	rep.follow(DUCK, OWNER)
	return [DUCK, n]


## One held frame per send tick (30 Hz, sender spacing 33 ms), then the tick.
func _stream(rep, frames: int, p0: Vector3, step: Vector3, carry_l: Vector3) -> void:
	for i in frames:
		rep.follow_push(DUCK, {"p": p0 + step * float(i), "q": Quaternion.IDENTITY, "l": carry_l,
			"a": Vector3.ZERO}, rep.t)
		rep.t += 33
		rep.physics_step()


func _recs(s, peer: int, t_from: int) -> Array:
	var out: Array = []
	for r in s.recs:
		if int(r.peer) == peer and int(r.eid) == DUCK and int(r.t) >= t_from:
			out.append(r)
	return out


func test_still_held_body_reaches_a_third_peer_without_its_carry_velocity() -> void:
	var h := _setup()
	var rep = h[0]
	var s = h[1]
	_held_body(rep, Vector3(2, 1.5, 0))
	var t0: int = rep.t
	# a full crate hangs still in the owner's hands; its carry pull reads 4 m/s up
	_stream(rep, 20, Vector3(2, 1.5, 0), Vector3.ZERO, Vector3(0, 4, 0))
	var got := _recs(s, THIRD, t0 + 1)
	assert_true(got.size() >= 5, "the third peer gets records of the held body (%d)" % got.size())
	var worst := 0.0
	var lin := 0
	for r in got.slice(1):
		worst = maxf(worst, (r.l as Vector3).length())
		if int(r.flags) & Codec.RF_LIN:
			lin += 1
	assert_true(worst < 0.05, "a still held body is sent still, not at the carry pull (max |l| %.2f m/s)" % worst)
	assert_eq(lin, 0, "no LIN record: the third peer holds it instead of extrapolating 4 m/s")
	assert_true((rep.ents[DUCK].l as Vector3).length() < 0.05, "the host's sampled velocity (change gate) is still too")
	assert_eq(_recs(s, OWNER, t0 + 1).size(), 0, "never sent to the owner")
	rep.clear()
	_teardown()


func test_moving_held_body_keeps_its_real_velocity() -> void:
	var h := _setup()
	var rep = h[0]
	var s = h[1]
	_held_body(rep, Vector3(0, 1.5, 0))
	var t0: int = rep.t
	# carried along x at 1 m/s (0.033 m per 33 ms frame); the carry pull reads more
	_stream(rep, 20, Vector3(0, 1.5, 0), Vector3(0.033, 0, 0), Vector3(1.3, 0.8, 0))
	var got := _recs(s, THIRD, t0 + 1)
	assert_true(got.size() >= 5, "records sent (%d)" % got.size())
	var last: Dictionary = got.back()
	assert_true((last.l as Vector3).distance_to(Vector3(1, 0, 0)) < 0.05,
		"the observed motion, 1 m/s along x (%s)" % str(last.l))
	assert_true(int(last.flags) & Codec.RF_LIN, "with LIN")
	# the observed step never exceeds the sender's own speed
	_stream(rep, 4, (last.p as Vector3) + Vector3(0.1, 0, 0), Vector3(0.033, 0, 0), Vector3(0.5, 0, 0))
	assert_true((rep.ents[DUCK].l as Vector3).length() <= 0.5 + 0.001, "capped by the sender's |l|")
	rep.clear()
	_teardown()


func test_throw_keeps_the_senders_velocity() -> void:
	var h := _setup()
	var rep = h[0]
	var s = h[1]
	var b: Array = _held_body(rep, Vector3(2, 1.5, 0))
	_stream(rep, 10, Vector3(2, 1.5, 0), Vector3.ZERO, Vector3(0, 4, 0))
	var throw_l := Vector3(0, 2, -6)
	rep.release(DUCK, {"p": Vector3(2, 1.5, 0), "q": Quaternion.IDENTITY, "l": throw_l, "a": Vector3.ZERO})
	rep.set_owner(DUCK, 1, "", 2)
	assert_true((b[1] as RigidBody3D).linear_velocity.is_equal_approx(throw_l), "the host body flies at the thrown velocity")
	var t0: int = rep.t
	rep.t += 33
	rep.physics_step()
	var got := _recs(s, THIRD, t0 + 1)
	assert_true(got.size() >= 1, "the release is sent at once (boost)")
	assert_true((got.back().l as Vector3).distance_to(throw_l) < 0.05,
		"the third peer gets the thrown velocity (%s)" % str(got.back().l))
	rep.clear()
	_teardown()


func test_observed_l_helper() -> void:
	var a := {"p": Vector3.ZERO, "l": Vector3(0, 4, 0), "t": 1000, "rx": 50}
	var b := {"p": Vector3.ZERO, "l": Vector3(0, 4, 0), "t": 1033, "rx": 80}
	assert_eq(HeldStream.observed_l(a, b), Vector3.ZERO, "still frames: still")
	b.p = Vector3(0.033, 0, 0)
	b.l = Vector3(2, 0, 0)
	assert_true(HeldStream.observed_l(a, b).distance_to(Vector3(1, 0, 0)) < 0.001, "the step over the sender's spacing")
	b.l = Vector3(0.4, 0, 0)
	assert_true(HeldStream.observed_l(a, b).distance_to(Vector3(0.4, 0, 0)) < 0.001, "never faster than the sender's l")
	assert_eq(HeldStream.observed_l({}, b), Vector3.ZERO, "no previous state: still")
	b.l = Vector3(2, 0, 0)
	b.t = 0
	assert_true(HeldStream.observed_l(a, b).distance_to(Vector3(1.1, 0, 0)) < 0.001, "no sender time: the arrival spacing")
	assert_eq(HeldStream.observed_l({"p": Vector3.ZERO, "l": Vector3.ZERO}, b), Vector3.ZERO,
		"a previous release state without times: still")


func test_reordered_frames_hold_still() -> void:
	# an older frame (by the sender's clock) arriving after a newer one: its step
	# points backwards, so it reads as still, never as a reversed throw
	var a := {"p": Vector3(0.066, 0, 0), "l": Vector3(2, 0, 0), "t": 1066, "rx": 50}
	var b := {"p": Vector3(0.033, 0, 0), "l": Vector3(2, 0, 0), "t": 1033, "rx": 80}
	assert_eq(HeldStream.observed_l(a, b), Vector3.ZERO, "reordered: still")
	b.t = 1066
	assert_eq(HeldStream.observed_l(a, b), Vector3.ZERO, "a repeated sender time: still")
	b.t = 1066 + 600
	b.p = Vector3(0.066 + 0.03, 0, 0)
	assert_true(HeldStream.observed_l(a, b).distance_to(Vector3(1, 0, 0)) < 0.001,
		"a long sender gap still falls back to the arrival spacing")
	var buf := [{"rx": 0, "t": 133, "p": Vector3(0.033, 0, 0), "l": Vector3(1, 0, 0)},
		{"rx": 5, "t": 100, "p": Vector3.ZERO, "l": Vector3(1, 0, 0)}]
	assert_eq(ClockRep._follow_extrap_v(buf), Vector3.ZERO, "follower: a reordered newest frame holds still")
	buf[1].t = 133
	assert_eq(ClockRep._follow_extrap_v(buf), Vector3.ZERO, "follower: a repeated sender time holds still")


func test_reordered_frame_does_not_reverse_a_revoke_release() -> void:
	var r := _held_rig()
	var c = r.c(0)
	_frames(r, c, 6, Vector3(0, 0.65, -1.5), Vector3(0, 0, 0.066), Vector3(0, 0.5, 3))
	# a late copy of an earlier frame: older sender time, earlier pose
	var ep: int = r.host.grab.host.rows[DUCK].epoch & 0xFF
	r.host.grab.host.on_held_frame(c.id, {"t_ms": r.net.clock_ms - 66, "seq": 6, "records": [
		{"eid": DUCK, "epoch": ep, "p": Vector3(0, 0.65, -1.5 + 0.066 * 4.0), "q": Quaternion.IDENTITY,
			"l": Vector3(0, 0.5, 3), "a": Vector3.ZERO}]})
	r.step(33)
	r.steps(100, 20)
	assert_eq(r.host.grab.counters().grab_revoke_reasons, {"silence": 1}, "revoked for silence")
	var hr: Array = r.host.bodies.last("host_release")
	assert_true((hr[2].l as Vector3).length() < 0.05,
		"not flung backwards by the reordered step (%s)" % str(hr[2].l))
	r.cleanup()


## The client's held frames, fed straight to the host (its own stream paused).
func _frames(r: Rig, c, n: int, p0: Vector3, step: Vector3, carry_l: Vector3) -> void:
	var ep: int = r.host.grab.host.rows[DUCK].epoch & 0xFF
	for i in n:
		r.host.grab.host.on_held_frame(c.id, {"t_ms": r.net.clock_ms, "seq": i & 0xFF, "records": [
			{"eid": DUCK, "epoch": ep, "p": p0 + step * float(i), "q": Quaternion.IDENTITY, "l": carry_l,
				"a": Vector3.ZERO}]})
		r.step(33)


func _held_rig() -> Rig:
	var r := Rig.new(runner, 1)
	r.body(DUCK)
	r.grab_body(r.c(0), DUCK)
	r.step()
	r.step()
	assert_true(r.c(0).grab.is_mine(DUCK), "granted")
	r.c(0).grab.stream.paused = true
	return r


func test_silence_revoke_releases_at_the_observed_velocity() -> void:
	var r := _held_rig()
	var c = r.c(0)
	_frames(r, c, 6, Vector3(0, 0.65, -1.5), Vector3.ZERO, Vector3(0, 4, 0))
	assert_eq(r.host.grab.hold_kind(DUCK), "held", "held while frames flow")
	assert_true((r.host.bodies.pushes[DUCK].back()[0].l as Vector3).is_equal_approx(Vector3(0, 4, 0)),
		"the follower still gets the frame as sent")
	r.steps(100, 20)
	assert_eq(r.host.grab.counters().grab_revoke_reasons, {"silence": 1}, "revoked for silence")
	var hr: Array = r.host.bodies.last("host_release")
	assert_true((hr[2].p as Vector3).is_equal_approx(Vector3(0, 0.65, -1.5)), "at the last streamed pose")
	assert_true((hr[2].l as Vector3).length() < 0.05, "a still crate is dropped, not flung at its carry pull (%s)" % str(hr[2].l))
	r.cleanup()


func test_silence_revoke_of_a_moving_body_keeps_its_motion() -> void:
	var r := _held_rig()
	var c = r.c(0)
	_frames(r, c, 6, Vector3(0, 0.65, -1.5), Vector3(0, 0, 0.066), Vector3(0, 0.5, 3))
	r.steps(100, 20)
	var hr: Array = r.host.bodies.last("host_release")
	assert_true((hr[2].l as Vector3).distance_to(Vector3(0, 0, 2)) < 0.05,
		"the observed 2 m/s (%s)" % str(hr[2].l))
	r.cleanup()


func test_own_rel_keeps_the_thrown_velocity_after_still_frames() -> void:
	var r := _held_rig()
	var c = r.c(0)
	_frames(r, c, 6, Vector3(0, 0.65, -1.5), Vector3.ZERO, Vector3(0, 4, 0))
	var thrown := Vector3(0, 3, -9)
	r.host.grab.host.on_own_rel(c.id, {"eid": DUCK, "epoch": r.host.grab.host.rows[DUCK].epoch & 0xFF,
		"s": HeldStream.state_to_json({"p": Vector3(0, 0.65, -1.5), "q": Quaternion.IDENTITY, "l": thrown,
			"a": Vector3.ZERO})})
	var hr: Array = r.host.bodies.last("host_release")
	assert_true((hr[2].l as Vector3).is_equal_approx(thrown), "a throw keeps the sender's velocity (%s)" % str(hr[2].l))
	r.cleanup()
