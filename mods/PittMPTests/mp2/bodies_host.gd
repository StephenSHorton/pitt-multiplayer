extends RefCounted
## BODIES B-scenarios, host side (MP2-DESIGN 11.2). Mirrors bodies_client.gd
## mark by mark: B4 (pre-populated world before the join), B9 (tick), B1
## (spawn + impulses, rest), B5 (downstream bandwidth during B1), B2 (recycle,
## same-frame reuse), B7 (the client's money clamp, client side only).

## B4: 350 entities of mixed pools in the world before the join
const PRE_MIX := [["tool_box", 10], ["duck", 200], ["cash_register", 60], ["flat_duck", 50], ["duck_luck", 30]]   # pools that do not expire or burst on their own
const B1_COUNT := 50
const ANCHOR := Vector3(0, 6, 18)    # player_controller.gd RESPAWN_ANCHOR (open floor)

var s = null      # the scenario (report, helpers)


func run(p_s) -> void:
	s = p_s
	var r = s.report
	var b = s.bodies()
	# open floor first (the start elevator is tight)
	var p: Node3D = s.player()
	var target := ANCHOR
	if p != null and p.has_method("_find_clear_spot"):
		target = p.call("_find_clear_spot", ANCHOR)
	await s.cmd("player.teleport", {"position": [target.x, target.y, target.z]})
	await s.sleep_ms(500)

	r.begin("B4_prepopulate")
	var pre: Array = _spawn_mixed(PRE_MIX, -5.0)   # behind the host: the join spot and the later tests stay clear
	await s.sleep_ms(4000)
	var pre_eids: Array = []
	var pre_pools := {}
	for n in pre:
		if not is_instance_valid(n) or not n.is_inside_tree():
			continue
		var e := int(s.api.entities.id_of(n))
		if e == 0:
			continue
		pre_eids.append(e)
		pre_pools[str(e)] = b.pool_id_of(e)
	r.value("b4_prepopulated", pre_eids.size())
	r.check("pre_350_tracked", pre_eids.size() >= 340 and _all_tracked(b, pre_eids), "%d spawned, %d tracked" % [
		pre_eids.size(), b.host.ents.size() if b.host != null else 0])
	r.mark("join_now", {"pre_eids": pre_eids, "pre_pools": pre_pools})
	var cv: Dictionary = await s.wait_peer_mark("client_in_game", 300.0)
	if not r.check("client_joined", not cv.is_empty(), ""):
		return
	var peer := _client_peer()
	await s.wait_peer_mark("b4_checked", 30.0)
	# 3-instance run: the second client joins now (a late join with client 1 already in)
	var p2 := String(s.flag.get("peer2_report", ""))
	if p2 != "":
		r.begin("B4_second_client")
		r.mark("client1_in")
		var c2: Dictionary = await s.wait_mark_in(p2, "client_in_game", 300.0)
		r.check("client2_joined", not c2.is_empty(), "")
		await s.wait_mark_in(p2, "b4_checked", 30.0)
		r.check("three_players", s.session.in_game_peers().size() == 2, str(s.session.in_game_peers()))
	r.value("b4_wsnap_host", s.session.wsnap_stats)
	r.check("b4_wsnap_build_under_30ms", int(s.session.wsnap_stats.get("build_us", 999999)) < 30000,
		"%d us" % int(s.session.wsnap_stats.get("build_us", -1)))

	r.begin("B9_tick")
	r.check("host_tick_60", Engine.physics_ticks_per_second == 60, str(Engine.physics_ticks_per_second))
	r.check("performance_monitor_stopped", s.g("PerformanceMonitor") == null or not s.g("PerformanceMonitor").is_processing(), "")

	if s.wants("B1"):
		r.begin("B1_spawn_push")
		var ducks: Array = _spawn_grid("duck", B1_COUNT, 6.0, 1.5)
		await s.tree().physics_frame
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		for d in ducks:
			if d is RigidBody3D:
				d.apply_central_impulse(Vector3(rng.randf_range(-2, 2), rng.randf_range(2, 5), rng.randf_range(-2, 2)))
		await s.tree().physics_frame
		await s.tree().physics_frame
		var eids: Array = []
		for d in ducks:
			eids.append(int(s.api.entities.id_of(d)))
		r.check("b1_tracked", _all_tracked(b, eids), "")
		r.mark("b1_spawned", {"eids": eids})
		var t_meter := Time.get_ticks_msec()
		var rested: bool = await s.wait_for(func():
			for d in ducks:
				if is_instance_valid(d) and d is RigidBody3D and not d.sleeping and d.visible:
					return false
			return true, 12.0)
		r.check("b1_came_to_rest", rested, "")
		await s.sleep_ms(500)
		var poses := {}
		for d in ducks:
			if is_instance_valid(d) and d.visible:
				var gp: Vector3 = d.global_position
				poses[str(int(s.api.entities.id_of(d)))] = [gp.x, gp.y, gp.z]
		r.mark("b1_rest", {"poses": poses})
		# B5: downstream to the client during the motion (1 s windows)
		r.begin("B5_bandwidth")
		var per_peer := {}
		for pp in s.session.in_game_peers():
			var hist: Array = s.session.transport.meter_history(int(pp)) if s.session.transport != null else []
			var bps: Array = []
			for w in hist:
				if int(w.t) * 1000 >= t_meter - 1000:
					bps.append(int(w.tx))
			bps.sort()
			var budget: int = b.budget_bps(int(pp))
			if bps.is_empty():
				continue
			var p95: int = bps[mini(bps.size() - 1, int(bps.size() * 0.95))]
			per_peer[str(pp)] = {"windows": bps, "p95": p95, "max": bps.back(), "budget": budget}
			r.check("b5_downstream_p95_peer%d" % int(pp), p95 <= int(budget * 1.1) + 2000, "p95 %d B/s, max %d, budget %d" % [
				p95, bps.back(), budget])
		r.value("b5_tx_bps", per_peer)
		await s.wait_peer_mark("b1_checked", 30.0)

		if s.wants("B2"):
			r.begin("B2_recycle_reuse")
			var gone: Array = []
			for i in 20:
				var d = ducks[i]
				gone.append(int(s.api.entities.id_of(d)))
				s.pools().recycle(d)
			r.mark("b2_recycled", {"gone": gone})
			await s.sleep_ms(500)
			# the press case: recycle + respawn of the same node in one frame
			var victim = ducks[25]
			var old_eid := int(s.api.entities.id_of(victim))
			var at: Vector3 = victim.global_position + Vector3(0, 0.5, 0)    # before recycle parks it at y -10000
			s.pools().recycle(victim)
			var again = s.pools().spawn("duck", at)
			await s.tree().physics_frame
			await s.tree().physics_frame
			var new_eid := int(s.api.entities.id_of(again))
			r.check("b2_same_node_new_eid", again == victim and new_eid != old_eid and new_eid != 0,
				"same node %s, %d -> %d" % [again == victim, old_eid, new_eid])
			r.mark("b2_reuse", {"old": old_eid, "new": new_eid})
			await s.wait_peer_mark("b2_checked", 30.0)
	await s.wait_peer_mark("b7_checked", 30.0)
	r.begin("B_host_end")
	r.value("host_counters", b.counters())
	r.value("host_stats", b.host.stats() if b.host != null else {})


func _client_peer() -> int:
	for p in s.session.in_game_peers():
		return int(p)
	return 0


func _all_tracked(b, eids: Array) -> bool:
	if b.host == null:
		return false
	for e in eids:
		if not b.host.ents.has(int(e)):
			return false
	return true


## Mixed pools on a 20-wide grid in front of the host, two layers.
func _spawn_mixed(mix: Array, dist: float) -> Array:
	var out: Array = []
	var p: Node3D = s.player()
	if p == null or s.pools() == null:
		return out
	var fwd := -p.global_basis.z
	fwd.y = 0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3(0, 0, -1)
	var right := fwd.cross(Vector3.UP).normalized()
	var base: Vector3 = p.global_position + fwd * dist + Vector3(0, -0.3, 0)
	var away := fwd if dist >= 0.0 else -fwd    # rows grow away from the host
	var i := 0
	for pair in mix:
		for k in int(pair[1]):
			var layer := int(i / 200)
			var j := i % 200
			var c := (j % 20) - 10
			var row := int(j / 20)
			var pos := base + right * (c * 0.5) + away * (row * 0.5) + Vector3(0, 0.3 + layer * 0.9, 0)
			var obj = s.pools().spawn(String(pair[0]), pos)
			if obj != null:
				out.append(obj)
			i += 1
	return out


## n bodies on a grid in front of the host player (forward dist m, lift above).
func _spawn_grid(pool_id: String, n: int, dist: float, lift: float) -> Array:
	var out: Array = []
	var p: Node3D = s.player()
	if p == null or s.pools() == null:
		return out
	var fwd := -p.global_basis.z
	fwd.y = 0
	fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3(0, 0, -1)
	var right := fwd.cross(Vector3.UP).normalized()
	var base: Vector3 = p.global_position + fwd * dist + Vector3(0, -0.6 + lift, 0)
	var cols := 10
	for i in n:
		var c := (i % cols) - cols / 2
		var row := int(i / cols)
		var pos := base + right * (c * 0.45) + fwd * (row * 0.45) + Vector3(0, 0.3 + (row % 2) * 0.2, 0)
		var obj = s.pools().spawn(pool_id, pos)
		if obj != null:
			out.append(obj)
	return out
