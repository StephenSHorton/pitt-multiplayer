extends "../scenario_base.gd"
## MP2 GRAB loopback scenarios, client side (MP2-DESIGN 11.2 G1-G6), paired
## with grab_host.gd through report marks. Driven by the MP2 harness
## (scenario_mp2.gd, BODIES): `await run_grab(ids)` once in the shared world.
## Grabs go through the real main_camera._begin_carry (the GRAB extension).

const ORDER := ["G1", "G3", "G2", "G4", "G6", "G5"]


func grab() -> Object:
	return session.get_module("grab") if session.has_method("get_module") else null


func bodies() -> Object:
	return session.get_module("bodies") if session.has_method("get_module") else null


func cam() -> Camera3D:
	return tree().get_first_node_in_group("main_camera") as Camera3D


func run_grab(ids: Array = ORDER) -> void:
	if not report.check("grab_module_present", grab() != null and bodies() != null, ""):
		return
	for id in ORDER:
		if id in ids:
			await call("_" + String(id).to_lower())
	report.mark("grab_client_done")


## Waits for the host's "<g>_ready" mark and the puppet of its eid; faces it.
func _ready_body(g: String) -> RigidBody3D:
	var m: Dictionary = await wait_peer_mark(g + "_ready", 60.0)
	var eid := int(m.get(g + "_eid", 0))
	if not report.check(g + "_host_ready", eid > 0, ""):
		return null
	var ok: bool = await wait_for(func(): return bodies().node_of(eid) != null, 3.0)
	if not report.check(g + "_puppet_exists", ok, "eid %d" % eid):
		return null
	var n := bodies().node_of(eid) as RigidBody3D
	face(n.global_position)
	await sleep_ms(200)
	return n


func _eid(n: Node) -> int:
	return int(bodies().eid_of(n))


func _counter(k: String) -> int:
	return int(grab().counters().get(k, 0))


# ---------------------------------------------------------------- G1

func _g1() -> void:
	report.begin("G1_grab_throw")
	var n := await _ready_body("g1")
	if n == null:
		return
	var eid := _eid(n)
	var t0 := Time.get_ticks_msec()
	cam()._begin_carry(n)
	report.check("g1_predicted", cam().picked_object == n and bodies().is_local_sim(eid), "")
	var ok: bool = await wait_for(func(): return grab().is_mine(eid), 2.0)
	var lat := Time.get_ticks_msec() - t0
	report.value("g1_grant_ms", lat)
	report.check("g1_granted", ok, "%d ms" % lat)
	await sleep_ms(600)
	var p := n.global_position
	report.mark("g1_holding", {"g1_pos": [p.x, p.y, p.z]})
	await sleep_ms(600)
	var rel_before := _counter("grab_rel_tx")
	# release, then give the local copy a throw velocity (no throw upgrade needed); the
	# state the host gets is captured one physics frame later, so it carries this velocity
	cam().drop_object(true)
	n.linear_velocity = -cam().global_transform.basis.z * 4.0 + Vector3(0, 2.0, 0)
	ok = await wait_for(func(): return _counter("grab_rel_tx") > rel_before, 1.0)
	report.check("g1_own_rel_sent", ok, "")
	report.mark("g1_released")
	var land: Dictionary = await wait_peer_mark("g1_landed", 20.0)
	if land.is_empty():
		return
	var hl := Vector3(float(land.g1_land[0]), float(land.g1_land[1]), float(land.g1_land[2]))
	ok = await wait_for(func(): return n.global_position.distance_to(hl) < 0.1, 2.0)
	report.check("g1_client_converged_to_host", ok, "%.3f m" % n.global_position.distance_to(hl))
	report.check("g1_puppet_again", not bodies().is_local_sim(eid), "")
	await shot("mp2-g1-client-after-throw")


# ---------------------------------------------------------------- G3

func _g3() -> void:
	report.begin("G3_deny")
	var n := await _ready_body("g3")
	if n == null:
		return
	var denied0 := _counter("grab_denied")
	cam()._begin_carry(n)
	var ok: bool = await wait_for(func(): return _counter("grab_denied") > denied0, 2.0)
	report.check("g3_denied", ok, "")
	ok = await wait_for(func(): return cam().picked_object == null and not bodies().is_local_sim(_eid(n)), 1.0)
	report.check("g3_no_carry_remains", ok, "")
	report.mark("g3_done")


# ---------------------------------------------------------------- G2

func _g2() -> void:
	report.begin("G2_race")
	var m: Dictionary = await wait_peer_mark("g2_ready", 60.0)
	var eid := int(m.get("g2_eid", 0))
	var at := int(m.get("g2_at", 0))
	if not report.check("g2_host_ready", eid > 0, ""):
		return
	await wait_for(func(): return bodies().node_of(eid) != null, 3.0)
	var n := bodies().node_of(eid) as RigidBody3D
	if n == null:
		return
	face(n.global_position)
	while Report.unix_ms() < at:
		await tree().process_frame
	var t := Report.unix_ms()
	cam()._begin_carry(n)
	await sleep_ms(1500)
	var holds: bool = cam().picked_object == n
	report.mark("g2_result", {"g2_client_holds": holds, "g2_t": t})
	if not holds:
		report.check("g2_loser_undone", not bodies().is_local_sim(eid), "")
	await wait_peer_mark("g2_end", 20.0)
	if cam().picked_object == n:
		cam().release_held_object()
	await sleep_ms(500)


# ---------------------------------------------------------------- G4

func _g4() -> void:
	report.begin("G4_silence")
	var n := await _ready_body("g4")
	if n == null:
		return
	var eid := _eid(n)
	cam()._begin_carry(n)
	await wait_for(func(): return grab().is_mine(eid), 2.0)
	await sleep_ms(300)
	var rel0 := _counter("grab_rel_tx")
	grab().stream.paused = true
	report.mark("g4_paused", {"g4_paused_ms": Report.unix_ms()})
	var ok: bool = await wait_for(func(): return cam().picked_object == null, 3.0)
	grab().stream.paused = false
	report.check("g4_client_dropped", ok, "")
	report.check("g4_no_own_rel", _counter("grab_rel_tx") == rel0, "")
	await wait_peer_mark("g4_revoked", 10.0)


# ---------------------------------------------------------------- G6

func _g6() -> void:
	report.begin("G6_pause_release")
	var n := await _ready_body("g6")
	if n == null:
		return
	var eid := _eid(n)
	cam()._begin_carry(n)
	await wait_for(func(): return grab().is_mine(eid), 2.0)
	await sleep_ms(300)
	var rel0 := _counter("grab_rel_tx")
	# what world/pause_guard does when a menu opens: freeze the camera, which releases the carry
	session.adapter.set_camera_frozen(true)
	await sleep_ms(200)
	session.adapter.set_camera_frozen(false)
	var ok: bool = await wait_for(func(): return _counter("grab_rel_tx") > rel0, 1.0)
	report.check("g6_normal_release", ok and cam().picked_object == null, "")
	report.mark("g6_paused")
	await wait_peer_mark("g6_end", 10.0)


# ---------------------------------------------------------------- G5 (last: leaves the session)

func _g5() -> void:
	report.begin("G5_disconnect")
	var n := await _ready_body("g5")
	if n == null:
		return
	var eid := _eid(n)
	cam()._begin_carry(n)
	await wait_for(func(): return grab().is_mine(eid), 2.0)
	await sleep_ms(300)
	report.mark("g5_leaving")
	session.leave()
	await wait_peer_mark("g5_end", 15.0)
