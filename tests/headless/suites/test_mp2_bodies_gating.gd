extends "res://tests/test_case.gd"
## MP2 3.3 host send path (0.2.3: P4 change gating and net-rest, P7 SLEEP order,
## P10 followers set, P11 overload shedding, P1 stats), the real host replicator
## alone on a fake clock, its packets decoded by a stub session:
##   - still awake bodies (frozen KINEMATIC, or awake in Jolt) go to rest once and
##     then cost nothing but the rest refresh; one that moves wakes again
##   - a moving body keeps the full 30 Hz; one in steady straight-line motion (LIN) or
##     spinning (ANG) is thinned, and the real client Interp fed with the decoded
##     packets never holds it and draws it where it is
##   - a held still body is only refreshed (1 Hz); a lost record heals within it
##   - a mass sleep under a full budget delivers every first SLEEP within a few ticks
##     while the awake bodies keep a share of every tick
##   - hidden frozen bodies count as resting; one fired right after loading (shown
##     while the barrel meta is still set) streams with SNAP on the next tick
##   - gated awake bodies leave the room they do not use to the first SLEEPs
##   - followers have their own set
##   - overload sheds candidates (and physics steps), not a lone peer's bytes
##   - peer_budget_info / stats / counters carry the P1 fields; bad netq values are safe

const Codec = preload("res://gamedir/mods/PittMultiplayer/net/codec.gd")
const MetaSync = preload("res://gamedir/mods/PittMultiplayer/world/bodies/meta_sync.gd")
const Interp = preload("res://gamedir/mods/PittMultiplayer/world/bodies/interp.gd")
const PEER := 2


class ClockRep extends "res://gamedir/mods/PittMultiplayer/world/bodies/replicator_host.gd":
	var t := 100000

	func _now() -> int:
		return t


class StubSession extends RefCounted:
	const Codec = preload("res://gamedir/mods/PittMultiplayer/net/codec.gd")
	var rep = null
	var in_game: Array = [2]
	var drop := false
	var recs: Array = []        # {t, eid, flags, p, q, l, a, hm (the packet's host ms)}
	var bad_packets := 0

	func in_game_peers() -> Array:
		return in_game

	func avatar_pose(_peer: int) -> Dictionary:
		return {"ok": true, "pos": Vector3.ZERO}

	func host_now() -> int:
		return rep.t

	func send_unreliable(_peer: int, pkt: PackedByteArray) -> void:
		if drop:
			return
		var d := Codec.decode_bodies(pkt)
		if d.is_empty():
			bad_packets += 1
			return
		for r in d.records:
			recs.append({"t": rep.t, "eid": int(r.eid), "flags": int(r.flags), "p": r.p, "q": r.q,
				"l": r.l, "a": r.a, "hm": int(d.host_ms)})

	func send_world(_peer: int, _k: String, _msg: Dictionary) -> void:
		pass


class StubAdapter extends RefCounted:
	var load_ratio := 0.0
	var limits: Array = []
	var limited := false

	func physics_load() -> float:
		return load_ratio

	func limit_physics_steps(on: bool) -> void:
		if on != limited:
			limits.append(on)
		limited = on

	func physics_steps_limited() -> bool:
		return limited


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
var _e0 := 0


func before_all() -> void:
	_e0 = core.guard.total_errors()


func _setup() -> Array:
	_teardown()
	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.size = Vector2i(8, 8)
	_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_vp.name = "GatingWorld"
	runner.add_child(_vp)
	_world = Node3D.new()
	_vp.add_child(_world)
	var b := StubBodies.new()
	b.meta_sync = MetaSync.new()
	b.adapter = StubAdapter.new()
	var s := StubSession.new()
	b.session = s
	var rep := ClockRep.new(b, ["duck"], "normal")
	s.rep = rep
	return [rep, s, b]


func _teardown() -> void:
	if _vp != null and is_instance_valid(_vp):
		_vp.queue_free()
	_vp = null
	_world = null


var _next_eid := 1000


## A body in the test world: frozen KINEMATIC (still unless moved by the test), or
## dynamic without gravity and never sleeping (awake in Jolt, but still).
func _body(rep, pos: Vector3, kinematic: bool = true) -> Array:
	var n := RigidBody3D.new()
	var cs := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.1
	cs.shape = sh
	n.add_child(cs)
	n.gravity_scale = 0.0
	n.can_sleep = false
	if kinematic:
		n.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		n.freeze = true
	_world.add_child(n)
	n.global_position = pos
	_next_eid += 1
	rep.track(_next_eid, n, "pooled", "duck")
	return [_next_eid, n]


func _tick(rep, n: int = 1) -> void:
	for i in n:
		rep.t += 33
		rep.physics_step()


func _count(s, eid: int, t_from: int, sleep: int = -1) -> int:
	var k := 0
	for r in s.recs:
		if int(r.eid) != eid or int(r.t) < t_from:
			continue
		if sleep == 1 and not (int(r.flags) & Codec.RF_SLEEP):
			continue
		if sleep == 0 and (int(r.flags) & Codec.RF_SLEEP):
			continue
		k += 1
	return k


func test_still_awake_bodies_go_quiet() -> void:
	var h := _setup()
	var rep = h[0]
	var s = h[1]
	var still: Array = []
	for i in 20:
		still.append(_body(rep, Vector3(i * 0.5, 1.0, 0.0), true))
	for i in 5:
		still.append(_body(rep, Vector3(i * 0.5, 1.0, 3.0), false))
	rep.peer_ready(PEER)
	assert_eq(rep.awake.size(), 25, "all awake at first (kinematic / never-sleeping)")
	_tick(rep, 3)
	for b in still:
		assert_true(_count(s, b[0], 0, 0) >= 1, "body %d sent once while awake" % b[0])
	_tick(rep, 27)
	assert_eq(rep.awake.size(), 0, "net-rest: nothing still is awake after about 1 s (%d)" % rep.awake.size())
	assert_eq(rep._watch.size(), 25, "watched by pose (Jolt / the game keeps them awake)")
	_tick(rep, 120)        # past the 250 ms / 1 s / 3 s repeats
	var t0: int = rep.t
	_tick(rep, 30)
	var motion := 0
	var total := 0
	for b in still:
		motion += _count(s, b[0], t0 + 1, 0)
		total += _count(s, b[0], t0 + 1)
	assert_eq(motion, 0, "no motion records of still bodies")
	assert_true(total <= 31, "only the rest refresh (one body per tick): %d records/s for 25 bodies" % total)
	var firsts := 0
	for b in still:
		firsts += 1 if _count(s, b[0], 0, 1) >= 1 else 0
	assert_eq(firsts, 25, "every still body got its SLEEP")
	assert_eq(int(rep.counters.first_sleeps), 25, "exactly one first SLEEP each (no rest / wake cycling)")
	assert_eq(int(rep.counters.net_rest_wakes), 0, "no wake while still")
	# one of them moves: it wakes and streams at once
	var mover: Array = still[3]
	(mover[1] as Node3D).global_position += Vector3(0.0, 0.0, 0.05)
	var t1: int = rep.t
	_tick(rep, 2)
	assert_true(rep.awake.has(mover[0]), "a watched body that moved is awake again")
	assert_true(_count(s, mover[0], t1 + 1, 0) >= 1, "and sent")
	var jolt: Array = still[22]
	(jolt[1] as RigidBody3D).linear_velocity = Vector3(1.0, 0.0, 0.0)
	await wait_physics(4)
	_tick(rep, 2)
	assert_true(rep.awake.has(jolt[0]), "a net-rested Jolt body that starts moving wakes (%s)" % str((jolt[1] as Node3D).global_position))
	assert_eq(s.bad_packets, 0, "every packet decodes")
	rep.clear()
	_teardown()


func test_moving_body_keeps_the_full_rate() -> void:
	var h := _setup()
	var rep = h[0]
	var s = h[1]
	for i in 20:
		_body(rep, Vector3(i * 0.5, 1.0, 0.0), true)
	var m: Array = _body(rep, Vector3(0, 1, 5), true)
	rep.peer_ready(PEER)
	_tick(rep, 90)          # past the spawn boost; the still ones are at rest
	var t0: int = rep.t
	for i in 30:
		var a := float(i) * 0.1
		(m[1] as Node3D).global_position = Vector3(cos(a), 1.0, 5.0 + sin(a))
		_tick(rep, 1)
	var n := _count(s, m[0], t0 + 1, 0)
	assert_true(n >= 29, "a moving body is sent every tick (%d of 30)" % n)
	assert_true(rep.awake.has(m[0]), "awake")
	assert_eq(rep.awake.size(), 1, "the still ones are not")
	rep.clear()
	_teardown()


func test_held_still_body_is_refreshed_and_a_lost_record_heals() -> void:
	var h := _setup()
	var rep = h[0]
	var s = h[1]
	var b: Array = _body(rep, Vector3(1, 1, 1), true)
	var eid: int = b[0]
	rep.peer_ready(PEER)
	rep.set_owner(eid, 1, "held", 1)      # held by the host player: never net-rests
	_tick(rep, 75)                         # past the 2 s boost
	var t0: int = rep.t
	_tick(rep, 90)
	var n := _count(s, eid, t0 + 1)
	assert_true(rep.awake.has(eid), "a held body stays awake")
	assert_true(n >= 2 and n <= 4, "a still held body is only refreshed, about 1 Hz (%d records in 3 s)" % n)
	assert_true(int(rep.counters.gated) > 0, "gated ticks counted")
	assert_true(int(rep.counters.refreshes) >= 2, "forced refreshes counted")
	assert_true(int(rep.counters.refreshes) <= _count(s, eid, 0), "only refreshes actually sent are counted")
	# its record is lost on the way; the forced refresh repairs it
	(b[1] as Node3D).global_position = Vector3(1.5, 1.0, 1.0)
	s.drop = true
	_tick(rep, 1)
	s.drop = false
	var t_move: int = rep.t
	var healed := -1
	for i in 40:
		_tick(rep, 1)
		for r in s.recs:
			if int(r.eid) == eid and int(r.t) > t_move and (r.p as Vector3).distance_to(Vector3(1.5, 1, 1)) < 0.01:
				healed = int(r.t) - t_move
				break
		if healed >= 0:
			break
	assert_true(healed >= 0 and healed <= 1100, "the new pose arrives within the refresh period (%d ms)" % healed)
	rep.clear()
	_teardown()


func test_mass_sleep_first_sleeps_go_first() -> void:
	var h := _setup()
	var rep = h[0]
	var s = h[1]
	var movers: Array = []
	for i in 100:
		movers.append(_body(rep, Vector3(i * 0.3, 1.0, 10.0), true))
	var sleepers: Array = []
	for i in 300:
		sleepers.append(_body(rep, Vector3((i % 20) * 0.3, 1.0, -int(i / 20.0) * 0.3), true))
	rep.peer_ready(PEER)
	var step := 0
	# the movers fill the budget; the 300 still bodies all net-rest on the same tick
	var rested_tick := -1
	var done_tick := -1
	var ps = null
	var mover_recs_during: Array = []
	for k in 200:
		step += 1
		for mv in movers:
			(mv[1] as Node3D).global_position.y = 1.0 + 0.2 * sin(float(step) * 0.2 + float(mv[0]))
		var t_before: int = rep.t
		_tick(rep, 1)
		ps = rep.peers.get(PEER, null)
		if rested_tick < 0 and rep.awake.size() <= 100:
			rested_tick = k
		if rested_tick >= 0:
			var got := 0
			for mv in movers:
				got += _count(s, mv[0], t_before + 1, 0)
			mover_recs_during.append(got)
			var firsts := 0
			for sl in sleepers:
				if _count(s, sl[0], 0, 1) >= 1:
					firsts += 1
			if firsts == 300:
				done_tick = k
				break
	assert_true(rested_tick >= 0, "the still bodies came to rest")
	var room: int = 48000 * 33 / 1000 - 2 * (Codec.BODIES_HEADER + 40)
	var bound: int = ceili(300.0 * Codec.BODY_BASE / (room * 0.6)) + 2
	assert_true(done_tick >= 0 and done_tick - rested_tick <= bound,
		"every first SLEEP within %d ticks of the mass sleep (%d)" % [bound, done_tick - rested_tick])
	var starved := 0
	for g in mover_recs_during:
		if int(g) == 0:
			starved += 1
	assert_true(starved <= 1, "the moving bodies keep a share of the ticks meanwhile (%s)" % str(mover_recs_during))
	assert_true(int(rep.counters.sleep_capped) > 0, "the burst was capped")
	assert_true(ps != null and ps.sleep_first.size() == 0, "first-SLEEP queue drained")
	rep.clear()
	_teardown()


func test_hidden_frozen_bodies_rest_and_followers_set() -> void:
	var h := _setup()
	var rep = h[0]
	var b: Array = _body(rep, Vector3(0, 1, 0), true)
	(b[1] as Node3D).visible = false      # stored in a cannon / vacuum bag
	var f: Array = _body(rep, Vector3(2, 1, 0), false)
	rep.peer_ready(PEER)
	_tick(rep, 2)
	assert_false(rep.awake.has(b[0]), "a hidden frozen body counts as resting")
	assert_false(rep._watch.has(b[0]), "and is not watched every tick")
	rep.follow(f[0], 3)
	assert_true(rep._followers.has(f[0]), "a follower is in the followers set")
	_tick(rep, 30)
	assert_true(rep.awake.has(f[0]), "a follower never net-rests")
	rep.release(f[0], {})
	assert_false(rep._followers.has(f[0]), "released: out of the set")
	(b[1] as Node3D).visible = true
	_tick(rep, 1)
	assert_true(rep.awake.has(b[0]), "unhidden: awake again")
	rep.clear()
	_teardown()


func test_dry_follower_extrapolates_the_observed_motion() -> void:
	var h := _setup()
	var rep = h[0]
	var f: Array = _body(rep, Vector3(2, 1, 0), false)
	rep.peer_ready(PEER)
	_tick(rep, 1)
	rep.follow(f[0], 3)
	# a full crate hangs still in the hands while its carry velocity reads 4 m/s up
	for i in 4:
		rep.follow_push(f[0], {"p": Vector3(2, 1.5, 0), "q": Quaternion.IDENTITY, "l": Vector3(0, 4, 0),
			"a": Vector3.ZERO}, 1000 + i * 33)
		rep.t += 33
	var n := f[1] as Node3D
	var x0: int = rep.counters.follow_extrap
	for k in 10:
		rep._drive_followers(rep.t + 150 + k * 16)
	assert_true(int(rep.counters.follow_extrap) > x0, "the stream ran dry: extrapolated")
	assert_true(n.global_position.distance_to(Vector3(2, 1.5, 0)) < 0.02,
		"a still body is not thrown along its carry velocity (%s)" % str(n.global_position))
	# moving frames: the observed motion, capped by the sender's velocity
	var buf := [{"rx": 0, "t": 100, "p": Vector3.ZERO, "l": Vector3(1, 0, 0)},
		{"rx": 5, "t": 133, "p": Vector3(0.033, 0, 0), "l": Vector3(1, 0, 0)}]
	assert_true(rep._follow_extrap_v(buf).distance_to(Vector3(1, 0, 0)) < 0.01, "steady motion: its velocity")
	buf[1].l = Vector3(0.5, 0, 0)
	assert_true(rep._follow_extrap_v(buf).distance_to(Vector3(0.5, 0, 0)) < 0.01, "never faster than the sender says")
	assert_eq(rep._follow_extrap_v([buf[0]]), Vector3.ZERO, "one frame alone holds still")
	rep.clear()
	_teardown()


func test_overload_sheds_candidates_not_a_lone_peers_bytes() -> void:
	var h := _setup()
	var rep = h[0]
	var s = h[1]
	var ad = h[2].adapter
	var movers: Array = []
	for i in 400:
		movers.append(_body(rep, Vector3((i % 20) * 0.5, 1.0, int(i / 20.0) * 0.5), true))
	rep.peer_ready(PEER)
	ad.load_ratio = 5.0          # the replicator's own (real) time is subtracted from it
	var step := 0
	for k in 160:
		step += 1
		for mv in movers:
			(mv[1] as Node3D).global_position.y = 1.0 + 0.2 * sin(float(step) * 0.2 + float(mv[0]))
		_tick(rep, 1)
	assert_eq(rep.overload, 0.5, "overloaded after 5 s")
	assert_eq(ad.limits, [true], "fewer physics catch-up steps while overloaded")
	var ps = rep.peers[PEER]
	assert_eq(rep._budget_bytes(ps, 0.033, 1), ps.budget.bytes_for(0.033, 1.0, 1.0), "a lone peer's bytes are not halved")
	assert_true(rep._budget_bytes(ps, 0.033, 2) < ps.budget.bytes_for(0.033, 1.0, 1.0), "two peers: halved as before")
	assert_true(int(rep.counters.cand_shed) > 0, "candidates shed")
	var t0: int = rep.t
	for k in 90:
		step += 1
		for mv in movers:
			(mv[1] as Node3D).global_position.y = 1.0 + 0.2 * sin(float(step) * 0.2 + float(mv[0]))
		_tick(rep, 1)
	var missing := 0
	for mv in movers:
		if _count(s, mv[0], t0 + 1) == 0:
			missing += 1
	assert_eq(missing, 0, "every moving body still sent within 3 s while shedding")
	ad.load_ratio = 0.0
	for k in 160:
		_tick(rep, 1)
	assert_eq(rep.overload, 1.0, "calm again")
	assert_eq(ad.limits, [true, false], "physics steps restored")
	rep.clear()
	_teardown()


func test_peer_budget_info_and_stats() -> void:
	var h := _setup()
	var rep = h[0]
	for i in 3:
		_body(rep, Vector3(i, 1, 0), true)
	rep.peer_ready(PEER)
	rep.on_netq(PEER, {"rx_pkts": 90, "gaps": 10, "late": 2, "interp_ms": 120, "puppets": 3, "rtt_ms": 48})
	rep.on_netq(PEER, {"rx_pkts": 90, "gaps": 10, "late": 2, "interp_ms": 120, "puppets": 3, "rtt_ms": 48})
	_tick(rep, 40)
	var info: Dictionary = rep.peer_budget_info(PEER)
	for k in ["bps", "eff_bps", "downs", "ups", "min_rtt", "configured", "overload", "physics_load", "self_us",
			"n_candidates", "awake_hidden", "awake_kinematic", "awake_follow", "awake_moving", "sleep_backlog",
			"sleep_oldest_ms", "rtt_ms", "loss", "interp_ms", "late", "puppets", "body_bytes", "body_bps"]:
		assert_true(info.has(k), "peer_budget_info has %s" % k)
	assert_eq(int(info.get("rtt_ms", 0)), 48, "last netq rtt")
	assert_eq(int(info.get("interp_ms", 0)), 120, "last netq interp")
	assert_true(absf(float(info.get("loss", 0.0)) - 0.1) < 0.001, "last netq loss")
	assert_eq(int(info.get("configured", 0)), 48000, "budget field read with get()")
	assert_true(int(info.get("body_bytes", 0)) > 0, "body-frame bytes counted")
	assert_eq(rep.peer_budget_info(99), {}, "unknown peer")
	var st: Dictionary = rep.stats()
	for k in ["tracked", "awake", "peers", "overload", "host_scale", "self_us", "physics_load", "n_candidates"]:
		assert_true(st.has(k), "stats has %s" % k)
	assert_true(st.peers[PEER].has("budget_bps") and st.peers[PEER].has("records"), "old per-peer keys kept")
	assert_true(rep.counters.has("host_stats"), "stats() reach the counters (and so the session dump)")
	assert_true(rep.counters.has("sleep_backlog") and rep.counters.has("n_candidates"), "flat gauges")
	# junk from the wire never stops the sender
	rep.on_netq(PEER, {"rx_pkts": null, "gaps": "x", "late": [], "interp_ms": {}, "rtt_ms": 1e30})
	_tick(rep, 2)
	assert_eq(int(rep.peer_budget_info(PEER).get("late", 0)), -1, "a bad value reads -1")
	rep.clear()
	_teardown()



## A dynamic body without gravity or damping: it keeps its velocities exactly (Jolt).
func _free_body(rep, pos: Vector3, v: Vector3, w: Vector3) -> Array:
	var b: Array = _body(rep, pos, false)
	var n: RigidBody3D = b[1]
	n.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	n.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	n.linear_damp = 0.0
	n.angular_damp = 0.0
	n.linear_velocity = v
	n.angular_velocity = w
	(rep.ents[b[0]]).boost_until = 0       # past the spawn boost at once
	return b


## Real physics frames on the fake clock: each frame the client side first takes the
## records that arrived (into a real Interp ring) and draws the body `behind_ms`
## behind the host, then the host steps. -> {modes, max_err_m, max_err_deg, gaps, n}
## stop_frame >= 0: from that frame on, the body is stopped dead right after the host
## sends it a record, and the error is measured only from 40 ms after the stop.
func _drive_client(rep, s, b: Array, frames: int, behind_ms: int, stop_frame: int = -1) -> Dictionary:
	var eid: int = b[0]
	var n: RigidBody3D = b[1]
	var hz := maxi(1, Engine.physics_ticks_per_second)
	var t_base: int = rep.t
	var ring: Array = []
	var seen := 0
	var out := {"modes": {}, "max_err_m": 0.0, "max_err_deg": 0.0, "gaps": [], "n": 0, "measured": 0}
	var last_t := -1
	var stopped_t := -1
	for f in frames:
		await wait_physics(1)
		rep.t = t_base + roundi(float(f + 1) * 1000.0 / float(hz))
		while seen < s.recs.size():
			var r: Dictionary = s.recs[seen]
			seen += 1
			if int(r.eid) != eid:
				continue
			Interp.ring_push(ring, {"t": int(r.hm), "p": r.p, "q": r.q, "l": r.l, "a": r.a,
				"flags": int(r.flags), "epoch": 0})
			if last_t >= 0:
				(out.gaps as Array).append(int(r.hm) - last_t)
			last_t = int(r.hm)
			out.n = int(out.n) + 1
		if ring.size() >= 2 and (stop_frame < 0 or (stopped_t >= 0 and rep.t - behind_ms >= stopped_t + 40)):
			var rt: int = rep.t - behind_ms
			var smp: Dictionary = Interp.sample(ring, rt)
			var mode := String(smp.get("mode", ""))
			out.modes[mode] = int(out.modes.get(mode, 0)) + 1
			out.measured = int(out.measured) + 1
			# where the body really was at rt (it moves and turns uniformly)
			var back := float(rep.t - rt) / 1000.0
			var p_true: Vector3 = n.global_position - n.linear_velocity * back
			var q_now: Quaternion = n.global_basis.get_rotation_quaternion()
			var q_true := q_now
			var wl := n.angular_velocity.length()
			if wl > 0.0001:
				q_true = (Quaternion(n.angular_velocity / wl, -wl * back) * q_now).normalized()
			out.max_err_m = maxf(float(out.max_err_m), (smp.p as Vector3).distance_to(p_true))
			out.max_err_deg = maxf(float(out.max_err_deg), Interp.angle_deg(smp.q, q_true))
		var before: int = s.recs.size()
		rep.physics_step()
		if stop_frame >= 0 and f >= stop_frame and stopped_t < 0:
			for i in range(before, s.recs.size()):
				if int(s.recs[i].eid) == eid:
					n.linear_velocity = Vector3.ZERO
					n.angular_velocity = Vector3.ZERO
					stopped_t = rep.t
					break
	out["stopped_t"] = stopped_t
	return out


func test_straight_line_body_is_thinned_but_never_held() -> void:
	var h := _setup()
	var rep = h[0]
	var s = h[1]
	var b: Array = _free_body(rep, Vector3(0, 1, 0), Vector3(1.0, 0.0, 0.0), Vector3.ZERO)
	rep.peer_ready(PEER)
	var hz := maxi(1, Engine.physics_ticks_per_second)
	var r: Dictionary = await _drive_client(rep, s, b, hz * 3, 20)
	var max_gap := 0
	for g in r.gaps:
		max_gap = maxi(max_gap, int(g))
	assert_true(int(r.n) >= 8, "records keep coming (%d in 3 s)" % int(r.n))
	assert_true(int(r.n) <= 60, "a straight line at constant velocity is thinned below 30 Hz (%d in 3 s)" % int(r.n))
	assert_true(max_gap <= 102 and max_gap <= int(rep._extrap_min_ms) + 2,
		"at most about 100 ms apart, within the client's shortest extrapolation (%d ms, cap %d)" % [max_gap, rep._extrap_min_ms])
	assert_eq(int(r.modes.get("hold", 0)), 0, "the client never holds it (%s)" % str(r.modes))
	assert_true(float(r.max_err_m) < 0.005, "drawn where it is (%.4f m)" % float(r.max_err_m))
	assert_eq(s.bad_packets, 0, "every packet decodes")
	rep.clear()
	_teardown()


func test_spinning_body_drawn_as_it_turns() -> void:
	var h := _setup()
	var rep = h[0]
	var s = h[1]
	var b: Array = _free_body(rep, Vector3(0, 1, 0), Vector3.ZERO, Vector3(0.0, 2.0, 0.0))
	rep.peer_ready(PEER)
	var hz := maxi(1, Engine.physics_ticks_per_second)
	var r: Dictionary = await _drive_client(rep, s, b, hz * 3, 40)
	assert_true(int(r.n) >= 8, "records keep coming (%d in 3 s)" % int(r.n))
	assert_eq(int(r.modes.get("hold", 0)), 0, "never held (%s)" % str(r.modes))
	assert_true(float(r.max_err_deg) < 1.0, "the client's rotation follows the spin (%.2f deg, client rotates: %s)"
		% [float(r.max_err_deg), str(rep._client_rotates)])
	rep.clear()
	_teardown()


## The reviewer's case: a spin stops dead right after a record with ANG. A client that
## turns q by ANG must get the stop on the next tick (the host predicts that turn), not
## keep turning until the moving-record refresh; one that holds rotation is right anyway.
func test_spin_stopped_after_a_record_is_drawn_still() -> void:
	var h := _setup()
	var rep = h[0]
	var s = h[1]
	var b: Array = _free_body(rep, Vector3(0, 1, 0), Vector3.ZERO, Vector3(0.0, 2.0, 0.0))
	rep.peer_ready(PEER)
	var hz := maxi(1, Engine.physics_ticks_per_second)
	var r: Dictionary = await _drive_client(rep, s, b, hz * 2, 20, hz)
	assert_true(int(r.stopped_t) > 0, "stopped right after a record")
	assert_true(int(r.measured) >= 20, "drawn after the stop (%d frames, %s)" % [int(r.measured), str(r.modes)])
	assert_true(float(r.max_err_deg) < 1.0, "drawn still from 40 ms after the stop (%.2f deg, client rotates: %s)"
		% [float(r.max_err_deg), str(rep._client_rotates)])
	# the Interp with per-body caps (EXTRAP_MIN_MS) is the one that turns q by ANG
	var cm: Dictionary = (Interp as Script).get_script_constant_map()
	assert_eq(rep._client_rotates, cm.has("EXTRAP_MIN_MS"), "the host's client model matches Interp")
	rep.clear()
	_teardown()


func test_fired_right_after_loading_streams_next_tick() -> void:
	var h := _setup()
	var rep = h[0]
	var s = h[1]
	# enough resting bodies that the rest scan needs several ticks for a lap
	for i in 400:
		var r: Array = _body(rep, Vector3((i % 20) * 0.5, 1.0, -3.0 - int(i / 20.0) * 0.5), true)
		(r[1] as RigidBody3D).freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	var b: Array = _body(rep, Vector3(0, 1, 0), true)
	var n: RigidBody3D = b[1]
	var eid: int = b[0]
	# loaded into a cannon: frozen (pooled bodies are KINEMATIC), hidden, barrel meta
	n.visible = false
	n.set_meta("in_cannon_barrel", true)
	rep.peer_ready(PEER)
	_tick(rep, 3)
	assert_false(rep.awake.has(eid), "a loaded projectile is resting")
	# fired a few frames later, in the game's order: shown, meta dropped, unfrozen, pushed
	rep._rest_scan_keys = rep.ents.keys()
	rep._rest_scan_i = 0              # the scan is at the start of a lap: it will not reach it
	n.visible = true
	n.remove_meta("in_cannon_barrel")
	n.freeze = false
	n.linear_velocity = Vector3(0.0, 0.0, 10.0)
	var t1: int = rep.t
	_tick(rep, 1)
	assert_true(rep.awake.has(eid), "awake on the next send tick")
	var snap := false
	for rec in s.recs:
		if int(rec.eid) == eid and int(rec.t) > t1 and (int(rec.flags) & Codec.RF_SNAP) != 0 \
				and (int(rec.flags) & Codec.RF_SLEEP) == 0:
			snap = true
	assert_true(snap, "and sent with SNAP at once")
	rep.clear()
	_teardown()


func test_gated_awake_bodies_leave_the_room_to_first_sleeps() -> void:
	var h := _setup()
	var rep = h[0]
	var s = h[1]
	# 100 held still bodies: awake, but gated (only the 1 Hz refresh)
	for i in 100:
		var b: Array = _body(rep, Vector3(i * 0.3, 1.0, 10.0), true)
		rep.set_owner(b[0], 1, "held", 1)
	rep.peer_ready(PEER)
	_tick(rep, 75)                  # past their boost
	var sleepers: Array = []
	for i in 300:
		sleepers.append(_body(rep, Vector3((i % 20) * 0.3, 1.0, -int(i / 20.0) * 0.3), true))
	var rested_tick := -1
	var done_tick := -1
	for k in 120:
		_tick(rep, 1)
		if rested_tick < 0 and rep.awake.size() <= 100:
			rested_tick = k
		if rested_tick >= 0:
			var firsts := 0
			for sl in sleepers:
				if _count(s, sl[0], 0, 1) >= 1:
					firsts += 1
			if firsts == 300:
				done_tick = k
				break
	assert_true(rested_tick >= 0, "the still bodies came to rest")
	var room: int = 48000 * 33 / 1000 - 2 * (Codec.BODIES_HEADER + 40)
	var bound: int = ceili(300.0 * Codec.BODY_BASE / float(room)) + 1
	assert_true(done_tick >= 0 and done_tick - rested_tick <= bound,
		"with every awake body gated the first SLEEPs get the whole tick: within %d ticks (%d)" % [bound, done_tick - rested_tick])
	rep.clear()
	_teardown()


## Last: a script error aborts a test silently (it would look passed), so none may occur.
func test_zz_no_script_errors() -> void:
	assert_eq(core.guard.total_errors() - _e0, 0, "script errors during the suite (see headless-run.log)")
