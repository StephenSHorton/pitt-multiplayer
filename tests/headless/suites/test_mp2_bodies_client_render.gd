extends "res://tests/test_case.gd"
## MP2 3.4 client rendering (P6 / P7 / P8 / P1 client stats): v is the curve's
## derivative, Hermite only over short spans, rotation extrapolates, the
## extrapolation cap follows the update interval, sparse records draw motion
## every frame with blends that end, rotation blends, release hand-off without
## a backward jump, set_local_sim clears the ring, the local pose is kept when
## the host stays silent, client stats reach counters / dump(), the avatar
## puppet's delay adapts to late frames (P12).
## The replicator runs on a test clock (ReplicatorClient with _now / _host_now
## overridden) and nodes that are plain Node3Ds: deterministic, no physics.

const Codec = preload("res://gamedir/mods/PittMultiplayer/net/codec.gd")
const Interp = preload("res://gamedir/mods/PittMultiplayer/world/bodies/interp.gd")
const PuppetBody = preload("res://gamedir/mods/PittMultiplayer/world/bodies/puppet_body.gd")
const Mp2Rig = preload("res://tests/fakes/mp2_bodies/mp2_rig.gd")
const AvatarPuppet = preload("res://gamedir/mods/PittMultiplayer/world/puppet.gd")

const LIN := 1
const FRAME_MS := 16


class ClockClient extends "res://gamedir/mods/PittMultiplayer/world/bodies/replicator_client.gd":
	var t_now := 100000
	var t_host := 500000

	func _now() -> int:
		return t_now

	func _host_now() -> int:
		return t_host


class StubAdapter extends RefCounted:
	var player: Node3D = null

	func local_player() -> Node3D:
		return player

	func physics_load() -> float:
		return 0.25


class StubBodies extends RefCounted:
	var adapter = StubAdapter.new()


var _nodes: Array = []
var _e0 := 0


func before_all() -> void:
	_e0 = core.guard.total_errors()


func after_all() -> void:
	for n in _nodes:
		if is_instance_valid(n):
			n.queue_free()
	_nodes.clear()


func _s(t: int, p: Vector3, l: Vector3 = Vector3.ZERO, flags: int = LIN, q: Quaternion = Quaternion.IDENTITY,
		a: Vector3 = Vector3.ZERO, epoch: int = 0) -> Dictionary:
	return {"t": t, "p": p, "q": q, "l": l, "a": a, "flags": flags, "epoch": epoch}


func _client(b = null) -> ClockClient:
	var c := ClockClient.new(b, [])
	c.interp_delay = 100
	return c


func _puppet(c: ClockClient, eid: int, at: Vector3 = Vector3.ZERO) -> PuppetBody:
	var n := Node3D.new()
	runner.add_child(n)
	n.global_position = at
	_nodes.append(n)
	var pb := PuppetBody.new()
	pb.eid = eid
	pb.ref = weakref(n)
	pb.kind = "fixture_body"     # no pool, no D22: only the driving is under test
	c.puppets[eid] = pb
	return pb


func _feed(c: ClockClient, pb: PuppetBody, s: Dictionary) -> void:
	if pb.push(s):
		c.active[pb.eid] = true
	pb.last_rx_ms = c.t_now


func _step(c: ClockClient, ms: int = FRAME_MS) -> void:
	c.t_now += ms
	c.t_host += ms
	c.physics_step()


# ------------------------------------------------------------------ interp (pure)

## v must be dp/dt of the curve sample() returns, in every mode.
func _check_derivative(ring: Array, rt: int, tag: String) -> void:
	var s := Interp.sample(ring, rt)
	var a := Interp.sample(ring, rt - 1)
	var b := Interp.sample(ring, rt + 1)
	var fd := ((b.p as Vector3) - (a.p as Vector3)) / 0.002
	assert_true((s.v as Vector3).distance_to(fd) < 0.05,
		"%s (%s): v %s = dp/dt %s" % [tag, s.mode, str(s.v), str(fd)])


func test_v_is_the_derivative_of_p() -> void:
	var g := Vector3(0, -9.81, 0)
	var v0 := Vector3(2, 5, 0)
	var short: Array = []
	for i in 4:
		var t := i * 0.05
		short.append(_s(i * 50, v0 * t + g * (0.5 * t * t), v0 + g * t))
	_check_derivative(short, 70, "Hermite over 50 ms")
	var long := [_s(0, Vector3.ZERO, Vector3(3, 0, 0)), _s(400, Vector3(1, 0, 2), Vector3(-3, 0, 0))]
	_check_derivative(long, 150, "lerp over 400 ms")
	var sleep_end := [_s(0, Vector3(0, 2, 0), Vector3(0, -4, 0)), _s(300, Vector3.ZERO, Vector3.ZERO, Codec.RF_SLEEP)]
	_check_derivative(sleep_end, 120, "into a SLEEP state")
	_check_derivative([_s(0, Vector3.ZERO, Vector3(4, 0, 1))], 80, "extrapolation")
	# standing still: v = 0 in before, hold and sleep
	var r := [_s(100, Vector3(1, 0, 0), Vector3(5, 0, 0)), _s(133, Vector3(1.165, 0, 0), Vector3(5, 0, 0))]
	assert_eq(String(Interp.sample(r, 50).mode), "before", "before")
	assert_eq(Interp.sample(r, 50).v, Vector3.ZERO, "before: v = 0 (the pose does not move)")
	var held := Interp.sample(r, 2000)
	assert_eq(String(held.mode), "hold", "hold")
	assert_eq(held.v, Vector3.ZERO, "hold: v = 0")
	var sl := Interp.sample(sleep_end, 5000)
	assert_eq(String(sl.mode), "sleep", "sleep")
	assert_eq(sl.v, Vector3.ZERO, "sleep: v = 0")


func test_hermite_only_over_short_spans() -> void:
	# a bounce between two records 400 ms apart: Hermite tangents x 0.4 s would
	# swing the curve far off the segment; lerp stays on it
	var ring := [_s(0, Vector3.ZERO, Vector3(0, -8, 0)), _s(400, Vector3(2, 0, 0), Vector3(0, 8, 0))]
	var mid := Interp.sample(ring, 200)
	assert_true((mid.p as Vector3).distance_to(Vector3(1, 0, 0)) < 0.0001, "long span: linear (%s)" % str(mid.p))
	var near := [_s(0, Vector3.ZERO, Vector3(10, 0, 0)), _s(100, Vector3(1, 0, 0), Vector3(10, 0, 0))]
	assert_true((Interp.sample(near, 50).p as Vector3).distance_to(Vector3(0.5, 0, 0)) < 0.0001, "100 ms: Hermite")


func test_rotation_extrapolates_from_angular_velocity() -> void:
	var w := Vector3(0, PI, 0)        # half a turn per second about +Y
	var flags := LIN | Codec.RF_ANG
	var one := [_s(0, Vector3.ZERO, Vector3(1, 0, 0), flags, Quaternion.IDENTITY, w)]
	var s := Interp.sample(one, 100)
	assert_eq(String(s.mode), "extrap", "extrap")
	assert_true(absf(Interp.angle_deg(s.q, Quaternion(Vector3.UP, PI * 0.1)) ) < 0.01,
		"100 ms at 180 deg/s: 18 deg (%.3f off)" % Interp.angle_deg(s.q, Quaternion(Vector3.UP, PI * 0.1)))
	# the cap applies to rotation too: past it the pose holds where it got to
	var h := Interp.sample(one, 5000)
	assert_eq(String(h.mode), "hold", "then hold")
	assert_true(Interp.angle_deg(h.q, Quaternion(Vector3.UP, PI * 0.25)) < 0.01, "held at the 250 ms cap (45 deg)")
	# spinning in place (no LIN) still turns
	var spin := [_s(0, Vector3.ZERO, Vector3.ZERO, Codec.RF_ANG, Quaternion.IDENTITY, w)]
	var sp := Interp.sample(spin, 50)
	assert_eq(String(sp.mode), "extrap", "ANG alone extrapolates")
	assert_true(Interp.angle_deg(sp.q, Quaternion(Vector3.UP, PI * 0.05)) < 0.01, "9 deg")
	assert_eq(sp.p, Vector3.ZERO, "without LIN the position stays")
	# RF_ANG with a zero vector: no rotation, no engine error
	var z := Interp.sample([_s(0, Vector3.ZERO, Vector3.ZERO, Codec.RF_ANG)], 50)
	assert_eq(z.q, Quaternion.IDENTITY, "zero angular velocity: unchanged")


func test_extrapolation_cap_follows_the_update_interval() -> void:
	var v := Vector3(5, 0, 0)
	var fast: Array = []
	for i in 3:
		fast.append(_s(i * 33, v * (i * 0.033), v))
	assert_eq(Interp.extrap_cap(fast), Interp.EXTRAP_MIN_MS, "30 Hz: the 100 ms floor")
	var f := Interp.sample(fast, 66 + 1000)
	assert_eq(String(f.mode), "hold", "hold")
	assert_true((f.p as Vector3).distance_to(fast[2].p + v * 0.1) < 0.0001, "overshoot at most 100 ms of motion (0.5 m, not 1.25)")
	var sparse: Array = []
	for i in 3:
		sparse.append(_s(i * 500, v * (i * 0.5), v))
	assert_eq(Interp.extrap_cap(sparse), 550, "records 500 ms apart: 550 ms")
	var sp := Interp.sample(sparse, 1000 + 450)
	assert_eq(String(sp.mode), "extrap", "still moving 450 ms past the newest record")
	assert_eq(Interp.update_interval([_s(0, Vector3.ZERO), _s(5000, Vector3.ZERO), _s(5033, Vector3.ZERO)]), 33,
		"a wake after a long rest does not widen the interval")
	assert_eq(Interp.extrap_cap([_s(0, Vector3.ZERO)]), Interp.MAX_EXTRAP_MS, "one record: 250 ms as before")


# ------------------------------------------------------------------ driving

## A body on a circle (radius 3 m, 1 rad/s) seen through records 500 ms apart:
## extrapolation drifts off the curve, every record bends it. The drawn pose
## must move every frame, each record must start at most one blend, and every
## blend must end before the next record.
func test_sparse_records_draw_motion_every_frame_and_blends_end() -> void:
	var c := _client()
	var pb := _puppet(c, 7, Vector3(0, 0, 3))
	var n := pb.node()
	var t0: int = c.t_host
	var sent := 0
	var queue: Array = []
	var last_p := Vector3.INF
	var still_frames := 0
	var frames := 0
	var cleared_in := {}
	var blends0 := 0
	for f in 300:
		var host_t: int = c.t_host
		# a record every 500 ms of host time, delivered 50 ms later
		if host_t - t0 >= sent * 500:
			var tt := float(host_t - t0) / 1000.0
			queue.append([host_t + 50, _s(host_t, Vector3(3 * sin(tt), 0, 3 * cos(tt)), Vector3(3 * cos(tt), 0, -3 * sin(tt)))])
			sent += 1
		while not queue.is_empty() and int(queue[0][0]) <= c.t_host:
			_feed(c, pb, queue.pop_front()[1])
		if f == 60:
			blends0 = int(c.counters.blends)
		_step(c)
		if f >= 60:            # past the first records (spawn snap, ring filling)
			frames += 1
			if n.global_position.distance_to(last_p) < 0.0001:
				still_frames += 1
			if pb.corr0 == Vector3.ZERO:
				cleared_in[(c.t_host - t0) / 500] = true
		last_p = n.global_position
	assert_eq(still_frames, 0, "the drawn pose moved on every one of %d frames" % frames)
	var records_seen := sent - 60 * FRAME_MS / 500
	var blends := int(c.counters.blends) - blends0
	assert_true(blends > 0, "records bent the curve: blends ran")
	assert_true(blends <= records_seen + 1, "at most one blend per record (%d blends, %d records)" % [blends, records_seen])
	var windows := 0
	for wi in range((60 * FRAME_MS) / 500 + 1, (300 * FRAME_MS) / 500):
		windows += 1
		assert_true(cleared_in.has(wi), "the correction reached zero between records (window %d)" % wi)
	assert_true(windows >= 5, "windows checked (%d)" % windows)
	# then the body stops: a SLEEP record; the puppet settles exactly and goes idle
	var rest := Vector3(1, 0, 1)
	_feed(c, pb, _s(c.t_host, rest, Vector3.ZERO, Codec.RF_SLEEP))
	for i in 40:
		_step(c)
	assert_eq(pb.corr0, Vector3.ZERO, "no correction left")
	assert_true(n.global_position.distance_to(rest) < 0.0001, "rest pose exact")
	assert_true(pb.idle, "idle until the next record")


func test_rotation_correction_blends() -> void:
	var c := _client()
	var pb := _puppet(c, 8)
	var n := pb.node()
	_feed(c, pb, _s(c.t_host - 300, Vector3.ZERO, Vector3.ZERO, Codec.RF_SLEEP))
	_step(c)
	assert_true(Interp.angle_deg(n.global_basis.get_rotation_quaternion(), Quaternion.IDENTITY) < 0.01, "start")
	# the host turned it by 60 deg while the record was on the way
	var turned := Quaternion(Vector3.UP, deg_to_rad(60.0))
	_feed(c, pb, _s(c.t_host - 200, Vector3.ZERO, Vector3.ZERO, Codec.RF_SLEEP, turned))
	var worst := 0.0
	var prev := n.global_basis.get_rotation_quaternion()
	for i in 20:
		_step(c)
		var q := n.global_basis.get_rotation_quaternion()
		worst = maxf(worst, Interp.angle_deg(prev, q))
		prev = q
	assert_true(worst < 15.0, "blended over frames, no 60 deg pop (largest step %.1f deg)" % worst)
	assert_true(Interp.angle_deg(prev, turned) < 0.01, "reaches the host rotation")
	assert_true(pb.idle, "and rests")


func test_still_poses_are_written_once() -> void:
	var c := _client()
	var pb := _puppet(c, 9)
	var n := pb.node()
	_feed(c, pb, _s(c.t_host - 1000, Vector3(1, 2, 3), Vector3(1, 0, 0)))
	_step(c)
	assert_true(n.global_position.distance_to(Vector3(1.25, 2, 3)) < 0.0001, "held at the 250 ms cap")
	_step(c)                                     # the first still frame is written
	var d = c._drv[9]
	var w := int(d.writes)
	for i in 5:
		_step(c)
	assert_eq(int(d.writes), w, "hold: no transform write while nothing changes")
	n.global_position = Vector3(9, 9, 9)         # game code moves the frozen body
	_step(c)
	assert_true(n.global_position.distance_to(Vector3(1.25, 2, 3)) < 0.0001,
		"moved off the still pose: written again (%s)" % str(n.global_position))
	assert_eq(int(d.writes), w + 1, "one write puts it back")
	n.global_basis = Basis(Vector3.UP, 0.5)      # a rotation alone counts too
	_step(c)
	assert_true(n.global_basis.get_rotation_quaternion().is_equal_approx(Quaternion.IDENTITY), "rotation restored")
	_step(c)
	_step(c)
	assert_eq(int(d.writes), w + 2, "and still again after that")


# ------------------------------------------------------------------ release (P8)

func test_set_local_sim_clears_the_ring() -> void:
	var c := _client()
	var pb := _puppet(c, 10)
	for i in 4:
		_feed(c, pb, _s(c.t_host - 400 + i * 33, Vector3(i, 0, 0), Vector3(1, 0, 0), LIN, Quaternion.IDENTITY, Vector3.ZERO, 3))
	_step(c)
	assert_eq(pb.ring.size(), 4, "records before the grab")
	c.set_local_sim(10, true, 0)
	assert_true(pb.local_sim, "local sim")
	assert_eq(pb.ring.size(), 0, "set_local_sim(on) drops every pre-grab state")
	assert_eq(pb.last_epoch, -1, "and the epoch it saw")
	assert_true(c.host_state(10).is_empty(), "no host state during the carry")


## A throw at 10 m/s over a 100 ms RTT link: the host restores the release
## state when own_rel arrives (50 ms later) and streams the new epoch, which
## reaches the client another 50 ms later and is drawn interp_delay behind.
## The drawn body must never move back along the throw by more than 0.3 m,
## whatever interp_delay the link gives (a plain 150 ms blend to the delayed
## stream stops it dead at 100 ms and pulls it back beyond that).
func test_release_throw_has_no_backward_jump() -> void:
	for delay in [100, 150, 200]:
		_throw(delay)


func _throw(delay: int) -> void:
	var c := _client()
	c.interp_delay = delay
	var pb := _puppet(c, 11)
	var n := pb.node()
	var one_way := 50
	# pre-grab: at rest at the origin (epoch 1)
	_feed(c, pb, _s(c.t_host - 500, Vector3.ZERO, Vector3.ZERO, Codec.RF_SLEEP, Quaternion.IDENTITY, Vector3.ZERO, 1))
	_step(c)
	c.set_local_sim(11, true, 0)
	# carried to x = 0.5, then thrown along +x
	n.global_position = Vector3(0.5, 1, 0)
	var speed := 10.0
	var c0: int = c.t_host
	c.set_local_sim(11, false, 2)
	var h_rel := c0 + one_way                  # the host restores the release state here
	var queue: Array = []
	var next_rec := h_rel
	var max_x := -INF
	var worst_back := 0.0
	var handed_at := -1
	for f in 150:
		# the host stream: exact straight flight from the release state, 30 Hz
		while next_rec <= c.t_host:
			var x := 0.5 + speed * float(next_rec - h_rel) / 1000.0
			queue.append([next_rec + one_way, _s(next_rec, Vector3(x, 1, 0), Vector3(speed, 0, 0), LIN,
				Quaternion.IDENTITY, Vector3.ZERO, 2)])
			next_rec += 33
		while not queue.is_empty() and int(queue[0][0]) <= c.t_host:
			_feed(c, pb, queue.pop_front()[1])
		# the client's own simulation while it still owns the body
		if pb.local_sim:
			n.global_position += Vector3(speed * FRAME_MS / 1000.0, 0, 0)
		_step(c)
		if handed_at < 0 and not pb.local_sim:
			handed_at = f
		var x_now := n.global_position.x
		max_x = maxf(max_x, x_now)
		worst_back = maxf(worst_back, max_x - x_now)
	assert_true(handed_at > 0, "delay %d: handed back to the host stream (frame %d)" % [delay, handed_at])
	assert_true(worst_back <= 0.3, "delay %d: never more than 0.3 m back along the throw (%.3f m)" % [delay, worst_back])
	# once the lead has faded the puppet shows the host stream at rt exactly
	var rt: int = c.t_host - c.interp_delay
	var truth := 0.5 + speed * float(rt - h_rel) / 1000.0
	assert_true(absf(n.global_position.x - truth) < 0.05, "delay %d: on the host stream at rt (%.3f vs %.3f)" % [delay, n.global_position.x, truth])
	assert_eq(pb.corr0, Vector3.ZERO, "delay %d: no correction left" % delay)


func test_release_without_host_records_keeps_the_local_pose() -> void:
	var c := _client()
	var pb := _puppet(c, 12)
	var n := pb.node()
	_feed(c, pb, _s(c.t_host - 500, Vector3.ZERO, Vector3.ZERO, Codec.RF_SLEEP, Quaternion.IDENTITY, Vector3.ZERO, 1))
	_step(c)
	c.set_local_sim(12, true, 0)
	n.global_position = Vector3(3, 0.2, 1)        # dropped here
	c.set_local_sim(12, false, 2)
	var snaps0 := int(c.counters.snaps)
	for i in (Interp.MAX_EXTRAP_MS + c.RELEASE_WAIT_MS + c.RELEASE_GIVEUP_MS) / FRAME_MS + 4:
		_step(c)
	assert_false(pb.local_sim, "back to puppet mode after the wait")
	assert_eq(int(c.counters.release_kept_local), 1, "counted")
	assert_eq(n.global_position, Vector3(3, 0.2, 1), "the local pose is kept, never the pre-grab one")
	# the next host record: a blend from the local pose, not a snap
	_feed(c, pb, _s(c.t_host - 150, Vector3(3.2, 0.2, 1), Vector3.ZERO, Codec.RF_SLEEP, Quaternion.IDENTITY, Vector3.ZERO, 2))
	_step(c)
	assert_true(n.global_position.distance_to(Vector3(3, 0.2, 1)) < 0.05, "starts at the local pose")
	for i in 20:
		_step(c)
	assert_eq(int(c.counters.snaps), snaps0, "no snap")
	assert_true(n.global_position.distance_to(Vector3(3.2, 0.2, 1)) < 0.0001, "then the host pose")


## A denied / undone grab of a sleeping body ends in its own epoch: the host
## never moved it and may send nothing for a long time, so the state the ring
## held before the grab is handed back to (a blend, no 3 s wait).
func test_denied_grab_returns_to_the_pre_grab_pose() -> void:
	var c := _client()
	var pb := _puppet(c, 13)
	var n := pb.node()
	var rest := Vector3(2, 0.1, -1)
	_feed(c, pb, _s(c.t_host - 500, rest, Vector3.ZERO, Codec.RF_SLEEP, Quaternion.IDENTITY, Vector3.ZERO, 4))
	_step(c)
	c.set_local_sim(13, true, 0)
	assert_eq(pb.ring.size(), 0, "ring cleared for the prediction")
	n.global_position = rest + Vector3(0, 0.4, 0.3)   # the predicted carry lifted it
	_step(c)
	c.set_local_sim(13, false, 4)                     # deny: same epoch
	for i in (c.interp_delay + int(c.BLEND_MS)) / FRAME_MS + 2:
		_step(c)
	assert_false(pb.local_sim, "a puppet again")
	assert_true(n.global_position.distance_to(rest) < 0.0001, "back on the host pose (%s)" % str(n.global_position))
	assert_eq(int(c.counters.release_kept_local), 0, "not the no-record path")
	assert_eq(int(c.counters.snaps), 1, "blended, not snapped (the one snap is the spawn)")


# ------------------------------------------------------------------ stats (P1)

func test_client_stats_keys_and_staleness() -> void:
	var b := StubBodies.new()
	var me := Node3D.new()
	runner.add_child(me)
	_nodes.append(me)
	b.adapter.player = me
	var c := _client(b)
	var near := _puppet(c, 20, Vector3(2, 0, 0))
	var far := _puppet(c, 21, Vector3(40, 0, 0))
	for pb in [near, far]:
		_feed(c, pb, _s(c.t_host - 150, pb.node().global_position, Vector3(3, 0, 0)))
	for i in 30:
		_step(c)          # no new records for 480 ms
	var st := c.stats()
	for k in ["cl_frame_p95_ms", "cl_frame_max_ms", "cl_physics_load", "cl_phys_active", "cl_stale_p95_ms", "cl_stale_n", "cl_active"]:
		assert_true(st.has(k), "stats() has %s" % k)
	assert_eq(st.cl_physics_load, 0.25, "physics_load from the adapter")
	assert_eq(int(st.cl_stale_n), 5, "sampled every 6th frame, only the near moving body")
	assert_true(int(st.cl_stale_p95_ms) >= 400 and int(st.cl_stale_p95_ms) <= 480, "staleness p95 %d ms" % int(st.cl_stale_p95_ms))
	assert_true(c.counters.has("cl_stale_p95_ms"), "published into counters (mp stats line, dump)")
	var q := c.take_netq()
	assert_true(q.has("frame_p95_ms") and q.has("stale_p95_ms"), "netq carries them to the host")


## A near moving body the host stops sending leaves the active set after
## DRIVE_IDLE_MS; its staleness keeps being sampled past that (regime A).
func test_starved_body_staleness_passes_the_idle_cut() -> void:
	var b := StubBodies.new()
	var me := Node3D.new()
	runner.add_child(me)
	_nodes.append(me)
	b.adapter.player = me
	var c := _client(b)
	var pb := _puppet(c, 22, Vector3(1, 0, 0))
	_feed(c, pb, _s(c.t_host - 150, pb.node().global_position, Vector3(3, 0, 0)))
	for i in 200:
		_step(c)          # 3.2 s without a record
	assert_false(c.active.has(22), "dropped from the driven set (DRIVE_IDLE_MS)")
	var st := c.stats()
	var worst := 0
	for ms in c._stale:
		worst = maxi(worst, int(ms))
	assert_true(worst > c.DRIVE_IDLE_MS + 1000, "still sampled after the idle cut (largest %d ms)" % worst)
	assert_true(int(st.cl_stale_p95_ms) > c.DRIVE_IDLE_MS, "p95 shows the starvation (%d ms)" % int(st.cl_stale_p95_ms))
	# a hidden puppet is not something a viewer sees move
	var n0: int = c._stale.size()
	pb.hidden = true
	for i in 12:
		_step(c)
	assert_eq(c._stale.size(), n0, "hidden: not sampled")


## Frame times come from every rendered frame (SceneTree.process_frame), not
## from physics steps: frames without a physics step are sampled too.
func test_frame_times_sample_rendered_frames() -> void:
	var c := _client()
	c.physics_step()      # hooks process_frame
	var n0: int = c._ft.size()
	for i in 12:
		await tree.process_frame
	assert_true(c._ft.size() - n0 >= 10, "%d samples over 12 rendered frames, 1 physics step" % (c._ft.size() - n0))


func test_client_stats_in_session_dump() -> void:
	var rig = Mp2Rig.new(tree, runner)
	var pc = await rig.pair()
	var c = pc[1]
	await rig.ms(1300)
	var d: Dictionary = c.session.dump()
	var cs: Dictionary = d.get("counters", {})
	assert_true(cs.has("cl_frame_p95_ms") and cs.has("cl_physics_load") and cs.has("cl_phys_active")
		and cs.has("cl_stale_p95_ms"), "client stats in the session dump (%s)" % str(cs.keys()))
	assert_true(float(cs.get("cl_frame_max_ms", 0.0)) > 0.0, "frame times measured")
	await rig.cleanup()


# ------------------------------------------------------------------ avatar puppet delay (P12)

func test_avatar_puppet_delay_adapts_to_lateness() -> void:
	var p := AvatarPuppet.new()
	p.setup(2, 5, "x", false)
	runner.add_child(p)
	_nodes.append(p)
	assert_eq(p.interp_delay, 100, "100 ms before any frame")
	var host := [10000]
	p.clock = func(): return host[0]
	# frames 50 ms apart that arrive 120 ms after they were taken (a slow link)
	for i in 60:
		host[0] += 50
		p.push({"t_ms": host[0] - 120, "pos": Vector3(i * 0.25, 0, 0), "yaw": 0.0, "pitch": 0.0,
			"vel": Vector3(5, 0, 0), "seq": i + 1, "flags": 0}, host[0])
	assert_eq(p.interp_delay, 170, "120 late + 17 spacing + 33: the render time stays behind the newest frame")
	p.update_pose(host[0], host[0])
	var newest_t: int = host[0] - 120
	assert_true(host[0] - p.interp_delay < newest_t, "interpolating, not extrapolating")
	# a LAN: frames 10 ms late keep the 100 ms floor
	var q := AvatarPuppet.new()
	q.setup(3, 6, "y", false)
	runner.add_child(q)
	_nodes.append(q)
	q.clock = func(): return host[0]
	for i in 30:
		host[0] += 50
		q.push({"t_ms": host[0] - 10, "pos": Vector3.ZERO, "yaw": 0.0, "pitch": 0.0, "vel": Vector3.ZERO,
			"seq": i + 1, "flags": 0}, host[0])
	assert_eq(q.interp_delay, 100, "the floor stays 100 ms")


## Last: a script error aborts a test silently (it would look passed), so none may occur.
func test_zz_no_script_errors() -> void:
	assert_eq(core.guard.total_errors() - _e0, 0, "script errors during the suite (see headless-run.log)")
