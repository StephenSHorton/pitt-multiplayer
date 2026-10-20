extends "../scenario_base.gd"
## MP2 GRAB loopback scenarios, client side (MP2-DESIGN 11.2 G1-G6), paired
## with grab_host.gd through report marks. Driven by the MP2 harness
## (scenario_mp2.gd, BODIES): `await run_grab(ids)` once in the shared world.
## Grabs go through the real main_camera._begin_carry (the GRAB extension).

const ORDER := ["G1", "G3", "G2", "G4", "G6", "G10", "G5"]
const Crate = preload("g10_crate.gd")


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


# ---------------------------------------------------------------- G10 a crate with ducks in it (0.2.2)

func _g10_inside(tag: String, crate: Node3D, ducks: Array) -> bool:
	var out := Crate.outside(crate, ducks)
	if tag in Crate.SPILL_OK:
		report.value(tag + "_client_spilled", out.size())
		return true
	if tag in Crate.SPILL_SOME:
		report.value(tag + "_client_spilled", out.size())
		return report.check(tag + "_client_ducks_inside_but_top_spill", not ducks.is_empty() and out.size() <= Crate.FULL_SPILL_MAX,
			"%d of %d outside (crate frame) %s" % [out.size(), ducks.size(), str(out)])
	return report.check(tag + "_client_ducks_inside", not ducks.is_empty() and out.is_empty(), "outside (crate frame) %s" % str(out))


func _g10() -> void:
	report.begin("G10_crate_with_ducks")
	for phase in ["e", "d", "f"]:
		var tag: String = "g10" + phase
		var m: Dictionary = await wait_peer_mark(tag + "_ready", 90.0)
		var eid := int(m.get("g10_eid", 0))
		if not report.check(tag + "_host_ready", eid > 0, ""):
			return
		var ok: bool = await wait_for(func(): return bodies().node_of(eid) != null, 3.0)
		if not report.check(tag + "_crate_puppet_exists", ok, "eid %d" % eid):
			return
		var crate := bodies().node_of(eid) as RigidBody3D
		var ducks: Array = []
		for de in m.get("g10_ducks", []):
			await wait_for(func(): return bodies().node_of(int(de)) != null, 3.0)
			if bodies().node_of(int(de)) != null:
				ducks.append(bodies().node_of(int(de)))
		if phase != "e":
			report.check(tag + "_all_duck_puppets", ducks.size() == (m.get("g10_ducks", []) as Array).size() and not ducks.is_empty(),
				"%d" % ducks.size())
			_g10_inside(tag + "_before", crate, ducks)
		var y0 := crate.global_position.y
		var c0: Dictionary = grab().counters()
		var picked: bool = await Crate.grab_by_input(self, crate, tag)
		report.check(tag + "_client_picked", picked and bodies().is_local_sim(eid), "picked %s local_sim %s" % [picked,
			bodies().is_local_sim(eid)])
		ok = await wait_for(func(): return grab().is_mine(eid), 2.0)
		report.check(tag + "_granted", ok, "")
		await Crate.lift(self)
		await sleep_ms(1200)
		var holding: bool = cam().picked_object == crate
		var c1: Dictionary = grab().counters()
		report.value(tag + "_grab_counters", {"denied": int(c1.get("grab_denied", 0)) - int(c0.get("grab_denied", 0)),
			"revoked": int(c1.get("grab_revoked", 0)) - int(c0.get("grab_revoked", 0)), "dy": crate.global_position.y - y0})
		report.check(tag + "_client_still_holding", holding, "")
		report.check(tag + "_client_lifted", crate.global_position.y - y0 >= Crate.LIFT_M, "dy %.3f m" % (crate.global_position.y - y0))
		if phase != "e":
			_g10_inside(tag + "_held", crate, ducks)
			await shot("mp2-g10%s-client-lifts-crate-with-ducks" % phase)
		# what the held crate touches (the game turns contact_monitor on while carrying)
		var contacts: Array = []
		for b in crate.get_colliding_bodies():
			contacts.append({"name": str(b.name), "eid": int(bodies().eid_of(b)), "frozen": b is RigidBody3D and b.freeze,
				"local_sim": bodies().is_local_sim(int(bodies().eid_of(b)))})
		report.value(tag + "_held_contacts", contacts)
		var mark_p := crate.global_position
		report.mark(tag + "_holding", {"g10_pos": Crate.arr(mark_p)})
		var drift := 0.0
		var t_mark := Time.get_ticks_msec()
		var drift_at := 0
		while Time.get_ticks_msec() - t_mark < 800:
			await tree().physics_frame
			var dd := crate.global_position.distance_to(mark_p)
			if dd > drift:
				drift = dd
				drift_at = Time.get_ticks_msec() - t_mark
		report.value(tag + "_client_drift_after_mark", {"max_m": drift, "at_ms": drift_at,
			"v": crate.linear_velocity.length() if crate is RigidBody3D else -1.0})
		await wait_peer_mark(tag + "_follow_checked", 10.0)
		await Crate.swing(self)
		await sleep_ms(500)
		report.check(tag + "_client_holding_after_swing", cam().picked_object == crate, "")
		if phase != "e":
			_g10_inside(tag + "_moved", crate, ducks)
		report.mark(tag + "_moved")
		await sleep_ms(600)
		await Crate.swing(self, -1.0)
		await Crate.lift(self, -1.0)
		await sleep_ms(500)
		var rel0 := _counter("grab_rel_tx")
		if cam().picked_object == crate:
			await Crate.press_lmb(self)
		ok = await wait_for(func(): return _counter("grab_rel_tx") > rel0, 1.0)
		report.check(tag + "_own_rel_sent", ok and cam().picked_object == null, "")
		report.mark(tag + "_released")
		var rv: Dictionary = await wait_peer_mark(tag + "_rest", 20.0)
		var rest: Dictionary = rv.get("g10_rest", {})
		var far := func() -> float:
			var worst := crate.global_position.distance_to(Crate.vec(rest.get("crate", [])))
			for d in ducks:
				var hp := Crate.vec(rest.get(str(int(bodies().eid_of(d))), []))
				worst = maxf(worst, (d as Node3D).global_position.distance_to(hp) if hp != Vector3.INF else 99.0)
			return worst
		ok = await wait_for(func(): return not rest.is_empty() and far.call() <= 0.05, 3.0)
		report.check(tag + "_client_converged_5cm", ok, "worst %.3f m" % far.call())
		report.check(tag + "_puppet_again", not bodies().is_local_sim(eid), "")
		if phase != "e":
			_g10_inside(tag + "_rest", crate, ducks)
		report.mark(tag + "_checked")
		if phase != "e":
			var inside_now := ducks.filter(func(dn): return is_instance_valid(dn) and Crate.inside(crate, (dn as Node3D).global_position))
			await _g10_host_control(eid, crate, inside_now, "g10h" if phase == "d" else "g10hf")
	await wait_peer_mark("g10_end", 30.0)


## Control: the host grabs the crate; this client sees it rise with the ducks inside.
func _g10_host_control(eid: int, crate: Node3D, ducks: Array, h: String) -> void:
	var hv: Dictionary = await wait_peer_mark(h + "_holding", 40.0)
	var hp := Crate.vec(hv.get("g10_pos", []))
	if report.check(h + "_host_holding_mark", hp != Vector3.INF, ""):
		# (a full crate still sways in the host's hands: the pose in the mark is one instant of it)
		# (the full crate sways in the host's own carry by up to about 0.3 m at the moment of the mark)
		var tol := 0.1 if h == "g10h" else 0.4
		var ok: bool = await wait_for(func(): return crate.global_position.distance_to(hp) <= tol, 2.0)
		report.check(h + "_client_sees_crate_lifted", ok, "%.3f m off (tolerance %.2f)" % [crate.global_position.distance_to(hp), tol])
		report.check(h + "_client_row_host_held", grab().owner_of(eid) == 1 and grab().hold_kind(eid) == "held", "owner %d kind %s" % [
			grab().owner_of(eid), grab().hold_kind(eid)])
		_g10_inside(h + "_held", crate, ducks)
		await shot("mp2-g10-client-sees-host-carry-ducks")
	report.mark(h + "_checked")
	await wait_peer_mark(h + "_released", 20.0)
