extends "../scenario_base.gd"
## MP2 GRAB loopback scenarios, host side (MP2-DESIGN 11.2 G1-G6). Driven by
## the MP2 harness (scenario_mp2.gd, BODIES) once both peers are in the shared
## world: `await run_grab(ids)`. Every step is paired with grab_client.gd
## through report marks ("g<n>_*"); every check is about what THIS instance sees.
## G5 (disconnect) ends the client's session, so it runs last. G10: a crate with
## ducks in it, grabbed through the real input path (g10_crate.gd).

const ORDER := ["G1", "G3", "G2", "G4", "G6", "G10", "G5"]
const CLIENT_SLOT := 2
const Crate = preload("g10_crate.gd")

var _changes: Array = []        # [unix_ms, eid, owner, kind, epoch]


func grab() -> Object:
	return session.get_module("grab") if session.has_method("get_module") else null


func bodies() -> Object:
	return session.get_module("bodies") if session.has_method("get_module") else null


func client_peer() -> int:
	return int(session.peer_of_slot(CLIENT_SLOT)) if session.has_method("peer_of_slot") else 2


func run_grab(ids: Array = ORDER) -> void:
	if not report.check("grab_module_present", grab() != null and bodies() != null, ""):
		return
	grab().owner_changed.connect(func(eid, o, k, e): _changes.append([Report.unix_ms(), eid, o, k, e]))
	for id in ORDER:
		if id in ids:
			await call("_" + String(id).to_lower())
	report.mark("grab_host_done")


## A duck 1.5 m in front of the client's avatar (it falls onto the floor there).
func _spawn_for_client() -> int:
	var pose: Dictionary = session.avatar_pose(client_peer())
	if not bool(pose.get("ok", false)):
		return 0
	var fwd := Vector3(0, 0, -1).rotated(Vector3.UP, float(pose.yaw))
	var at: Vector3 = pose.pos + fwd * 1.5 + Vector3(0, 0.6, 0)
	var r = await cmd("entity.spawn", {"pool_id": "duck", "position": [at.x, at.y, at.z]})
	var eid := int(r.value.get("entity_id", 0)) if r.ok and typeof(r.value) == TYPE_DICTIONARY else 0
	await sleep_ms(800)          # settle; BODIES streams it to the client
	return eid


func _node(eid: int) -> Node3D:
	return bodies().node_of(eid) as Node3D if bodies() != null else null


func _last_change(eid: int) -> Array:
	for i in range(_changes.size() - 1, -1, -1):
		if int(_changes[i][1]) == eid:
			return _changes[i]
	return []


# ---------------------------------------------------------------- G1 grab + throw, the host sees it land

func _g1() -> void:
	report.begin("G1_grab_throw")
	var eid := await _spawn_for_client()
	if not report.check("g1_spawned", eid > 0, ""):
		return
	var e0: int = grab().epoch_of(eid)
	report.mark("g1_ready", {"g1_eid": eid})
	var held: Dictionary = await wait_peer_mark("g1_holding", 20.0)
	if not report.check("g1_client_holding", not held.is_empty(), ""):
		return
	report.check("g1_host_table_owner", grab().owner_of(eid) == client_peer() and grab().hold_kind(eid) == "held",
		"owner %d kind %s" % [grab().owner_of(eid), grab().hold_kind(eid)])
	await sleep_ms(150)
	var cp := Vector3(float(held.g1_pos[0]), float(held.g1_pos[1]), float(held.g1_pos[2]))
	var n := _node(eid)
	var d := n.global_position.distance_to(cp) if n != null else 99.0
	report.value("g1_follow_err_m", d)
	report.check("g1_host_copy_follows_10cm", d <= 0.10, "%.3f m" % d)
	var rel: Dictionary = await wait_peer_mark("g1_released", 20.0)
	report.check("g1_client_released", not rel.is_empty(), "")
	var ok: bool = await wait_for(func(): return grab().owner_of(eid) == 1 and grab().hold_kind(eid) == "", 3.0)
	report.check("g1_back_to_host", ok, "")
	report.check("g1_epoch_plus_2", grab().epoch_of(eid) == e0 + 2, "%d -> %d" % [e0, grab().epoch_of(eid)])
	var rb := _node(eid) as RigidBody3D
	report.check("g1_host_body_dynamic", rb != null and not rb.freeze, "")
	await sleep_ms(2500)
	var land := _node(eid).global_position if _node(eid) != null else Vector3.ZERO
	report.mark("g1_landed", {"g1_land": [land.x, land.y, land.z]})
	await shot("mp2-g1-host-sees-landing")


# ---------------------------------------------------------------- G3 deny a body a machine owns

func _g3() -> void:
	report.begin("G3_deny")
	var eid := await _spawn_for_client()
	if not report.check("g3_spawned", eid > 0, ""):
		return
	var n := _node(eid)
	n.set_meta("consumed", true)       # host-only: the maw is eating it
	report.mark("g3_ready", {"g3_eid": eid})
	var done: Dictionary = await wait_peer_mark("g3_done", 20.0)
	report.check("g3_client_done", not done.is_empty(), "")
	report.check("g3_still_host", grab().owner_of(eid) == 1 and grab().hold_kind(eid) == "", "")
	var c: Dictionary = grab().counters()
	report.check("g3_denied_busy", int(c.get("grab_deny_reasons", {}).get("busy", 0)) >= 1, str(c.get("grab_deny_reasons", {})))
	n.remove_meta("consumed")


# ---------------------------------------------------------------- G2 race: both grab at the same instant

func _g2() -> void:
	report.begin("G2_race")
	var eid := await _spawn_for_client()
	if not report.check("g2_spawned", eid > 0, ""):
		return
	# the host player must be in reach too (the game drops a carry that is too far away)
	var dn := _node(eid)
	var pose: Dictionary = session.avatar_pose(client_peer())
	if dn != null and bool(pose.get("ok", false)):
		var away: Vector3 = dn.global_position - Vector3(pose.pos)
		away.y = 0
		var hp: Vector3 = dn.global_position + away.normalized() * 1.4
		await cmd("player.teleport", {"position": [hp.x, float(pose.pos.y), hp.z]})
		await sleep_ms(400)
		face(dn.global_position)
	var at := Report.unix_ms() + 2500
	report.mark("g2_ready", {"g2_eid": eid, "g2_at": at})
	while Report.unix_ms() < at:
		await tree().process_frame
	var cam = tree().get_first_node_in_group("main_camera")
	var n := _node(eid) as RigidBody3D
	if cam != null and n != null:
		cam._begin_carry(n)
	var t_host := Report.unix_ms()
	await sleep_ms(1500)
	var host_holds: bool = cam != null and cam.picked_object == n
	var res: Dictionary = await wait_peer_mark("g2_result", 20.0)
	var client_holds := bool(res.get("g2_client_holds", false))
	report.value("g2_skew_ms", absi(t_host - int(res.get("g2_t", t_host))))
	report.check("g2_exactly_one_owner", host_holds != client_holds, "host %s client %s" % [host_holds, client_holds])
	var owner: int = grab().owner_of(eid)
	report.check("g2_table_matches", (owner == 1) == host_holds, "owner %d" % owner)
	if host_holds and cam != null:
		cam.call("release_held_object")
	report.mark("g2_end")
	await sleep_ms(500)


# ---------------------------------------------------------------- G4 owner silence revokes after 1.5 s

func _g4() -> void:
	report.begin("G4_silence")
	var eid := await _spawn_for_client()
	if not report.check("g4_spawned", eid > 0, ""):
		return
	report.mark("g4_ready", {"g4_eid": eid})
	var p: Dictionary = await wait_peer_mark("g4_paused", 20.0)
	if not report.check("g4_client_paused", not p.is_empty(), ""):
		return
	var ok: bool = await wait_for(func(): return grab().hold_kind(eid) == "", 4.0)
	var ch := _last_change(eid)
	var dt := int(ch[0]) - int(p.get("g4_paused_ms", 0)) if not ch.is_empty() else -1
	report.value("g4_revoke_after_ms", dt)
	report.check("g4_revoked_1500_pm_200", ok and dt >= 1300 and dt <= 1700, "%d ms" % dt)
	report.check("g4_reason_silence", int(grab().counters().get("grab_revoke_reasons", {}).get("silence", 0)) >= 1, "")
	report.mark("g4_revoked")


# ---------------------------------------------------------------- G6 the client opens the pause menu while holding

func _g6() -> void:
	report.begin("G6_pause_release")
	var eid := await _spawn_for_client()
	if not report.check("g6_spawned", eid > 0, ""):
		return
	report.mark("g6_ready", {"g6_eid": eid})
	var p: Dictionary = await wait_peer_mark("g6_paused", 20.0)
	report.check("g6_client_paused", not p.is_empty(), "")
	var ok: bool = await wait_for(func(): return grab().owner_of(eid) == 1 and grab().hold_kind(eid) == "", 3.0)
	report.check("g6_released_normally", ok, "")
	var rb := _node(eid) as RigidBody3D
	report.check("g6_body_dynamic", rb != null and not rb.freeze, "")
	report.mark("g6_end")


# ---------------------------------------------------------------- G5 disconnect while holding

func _g5() -> void:
	report.begin("G5_disconnect")
	var eid := await _spawn_for_client()
	if not report.check("g5_spawned", eid > 0, ""):
		return
	report.mark("g5_ready", {"g5_eid": eid})
	var h: Dictionary = await wait_peer_mark("g5_leaving", 20.0)
	report.check("g5_client_leaving", not h.is_empty(), "")
	var ok: bool = await wait_for(func(): return grab().hold_kind(eid) == "", 5.0)
	report.check("g5_revoked_on_leave", ok, "")
	report.check("g5_reason_left", int(grab().counters().get("grab_revoke_reasons", {}).get("left", 0)) >= 1, "")
	var rb := _node(eid) as RigidBody3D
	var y0 := rb.global_position.y if rb != null else 0.0
	report.check("g5_body_dynamic", rb != null and not rb.freeze, "")
	await sleep_ms(1000)
	report.value("g5_dy", (rb.global_position.y - y0) if rb != null else 0.0)
	report.mark("g5_end")


# ---------------------------------------------------------------- G10 a crate with ducks in it (0.2.2)
# The second two-PC Steam test: "the client can't pick up the crate tool when there
# are ducks in it". The host spawns the game's CRATE in front of the client; the
# client grabs it through the real input path, first empty ("e"), then with three
# ducks inside ("d"); then the host grabs it as a control ("h"). Every peer checks
# that the crate rose and that the ducks stayed inside it.

func _g10_ducks_inside(tag: String, crate: Node3D, ducks: Array) -> void:
	var out := Crate.outside(crate, ducks)
	if tag in Crate.SPILL_OK:
		report.value(tag + "_host_spilled", out.size())
		return
	if tag in Crate.SPILL_SOME:
		report.value(tag + "_host_spilled", out.size())
		report.check(tag + "_host_ducks_inside_but_top_spill", not ducks.is_empty() and out.size() <= Crate.FULL_SPILL_MAX,
			"%d of %d outside (crate frame) %s" % [out.size(), ducks.size(), str(out)])
		return
	report.check(tag + "_host_ducks_inside", not ducks.is_empty() and out.is_empty(), "outside (crate frame) %s" % str(out))


## Where the host copy's error comes from: the held stream (last accepted state,
## its age, the follower buffer) against the client's marked pose and the node.
func _follow_diag(eid: int, crate: Node3D, cp: Vector3) -> Dictionary:
	var out := {}
	var gh = grab().get("host")
	var row = gh.rows.get(eid, null) if gh != null else null
	if row != null and not (row.last_state as Dictionary).is_empty():
		var sp: Vector3 = row.last_state.get("p", Vector3.ZERO)
		out["node_vs_stream_m"] = crate.global_position.distance_to(sp)
		out["stream_vs_client_m"] = sp.distance_to(cp) if cp != Vector3.INF else -1.0
		out["stream_age_ms"] = int(grab().now()) - int(row.last_rx_ms)
		out["stalled"] = bool(row.stalled) if "stalled" in row else false
	var bh = bodies().get("host")
	var e = bh.ents.get(eid, null) if bh != null else null
	if e != null:
		out["follow_n"] = (e.follow as Array).size()
		out["follow_out_vs_node_m"] = (e.follow_out as Vector3).distance_to(crate.global_position)
		if not (e.follow as Array).is_empty():
			out["buf_last_vs_client_m"] = (e.follow.back().p as Vector3).distance_to(cp) if cp != Vector3.INF else -1.0
			out["buf_last_l"] = (e.follow.back().l as Vector3).length()
		out["overload"] = float(bh.get("overload")) if bh.get("overload") != null else -1.0
		out["follow_extrap"] = int(bh.counters.get("follow_extrap", -1))
	var c: Dictionary = grab().counters()
	for k in ["grab_held_rx", "held_rejected", "grab_held_early", "grab_held_gaps", "grab_link_stalls"]:
		out[k] = c.get(k, -1)
	out["fps"] = Engine.get_frames_per_second()
	out["steps_cap"] = Engine.max_physics_steps_per_frame
	return out


func _g10() -> void:
	report.begin("G10_crate_with_ducks")
	var pose: Dictionary = session.avatar_pose(client_peer())
	if not report.check("g10_client_pose", bool(pose.get("ok", false)), ""):
		report.mark("g10e_ready", {"g10_eid": 0})
		return
	var yaw := float(pose.yaw)
	var fwd := Vector3(0, 0, -1).rotated(Vector3.UP, yaw)
	var at: Vector3 = Vector3(pose.pos) + fwd * 2.0
	at.y = float(pose.pos.y) - 0.975 + 0.1
	# the earlier G scenarios left their ducks in front of the client
	for n in tree().get_nodes_in_group("product"):
		if n is RigidBody3D and n.visible and (n as Node3D).global_position.distance_to(at) < 3.0:
			g("ObjectPoolManager").recycle(n)
	await sleep_ms(500)
	var r = await cmd("entity.spawn", {"pool_id": Crate.POOL, "position": [at.x, at.y, at.z]})
	var eid := int(r.value.get("entity_id", 0)) if r.ok and typeof(r.value) == TYPE_DICTIONARY else 0
	var crate := _node(eid) as RigidBody3D
	if not report.check("g10_crate_spawned", crate != null, str(r.error) if not r.ok else ""):
		report.mark("g10e_ready", {"g10_eid": 0})
		return
	report.value("g10_crate", {"name": crate.call("object_name") if crate.has_method("object_name") else str(crate.name),
		"mass": crate.mass})
	# long side toward the client: its local x is the client's forward
	var home := Transform3D(Basis(Vector3.UP, yaw + PI / 2.0), at)
	crate.global_transform = home
	await sleep_ms(1200)
	for phase in ["e", "d", "f"]:
		var tag: String = "g10" + phase
		var ducks: Array = []
		if phase != "e":
			crate.global_transform = home
			crate.linear_velocity = Vector3.ZERO
			crate.angular_velocity = Vector3.ZERO
			await sleep_ms(800)
			var layers: Array = [Crate.DUCK_OFFSETS]
			if phase == "f":
				layers = []
				for y in Crate.FULL_LAYERS:
					var layer: Array = []
					for x in Crate.FULL_X:
						for z in Crate.FULL_Z:
							layer.append(Vector3(x, y, z))
					layers.append(layer)
			for layer in layers:
				for off in layer:
					var dp: Vector3 = crate.global_transform * off
					var dr = await cmd("entity.spawn", {"pool_id": "duck", "position": [dp.x, dp.y, dp.z]})
					var dn = _node(int(dr.value.get("entity_id", 0))) if dr.ok and typeof(dr.value) == TYPE_DICTIONARY else null
					if dn != null:
						ducks.append(dn)
				await sleep_ms(400)
			await sleep_ms(1500)
			if phase == "f":
				# the ones that bounced out stay out of the checks; the crate must still be full
				var spilled := Crate.outside(crate, ducks)
				report.value("g10f_spilled", spilled.size())
				ducks = ducks.filter(func(dn): return is_instance_valid(dn) and Crate.inside(crate, (dn as Node3D).global_position))
				report.check("g10f_crate_full", ducks.size() >= Crate.FULL_MIN, "%d ducks inside" % ducks.size())
			_g10_ducks_inside(tag + "_before", crate, ducks)
		var y0 := crate.global_position.y
		var deids: Array = []
		for dn in ducks:
			deids.append(int(api.entities.id_of(dn)))
		report.mark(tag + "_ready", {"g10_eid": eid, "g10_ducks": deids, "g10_y0": y0})
		var held: Dictionary = await wait_peer_mark(tag + "_holding", 25.0)
		if report.check(tag + "_client_holding_mark", not held.is_empty(), ""):
			report.check(tag + "_host_table_owner", grab().owner_of(eid) == client_peer() and grab().hold_kind(eid) == "held",
				"owner %d kind %s, denies %s" % [grab().owner_of(eid), grab().hold_kind(eid),
				str(grab().counters().get("grab_deny_reasons", {}))])
			await sleep_ms(300)
			var cp := Crate.vec(held.get("g10_pos", []))
			var d := crate.global_position.distance_to(cp) if cp != Vector3.INF else 99.0
			report.value(tag + "_follow_err_m", d)
			report.value(tag + "_follow_diag", _follow_diag(eid, crate, cp))
			report.check(tag + "_host_copy_follows_15cm", d <= 0.15, "%.3f m" % d)
			report.check(tag + "_host_copy_lifted", crate.global_position.y - y0 >= Crate.LIFT_M, "dy %.3f m" % (
				crate.global_position.y - y0))
			if phase != "e":
				_g10_ducks_inside(tag + "_held", crate, ducks)
		report.mark(tag + "_follow_checked")
		var mv: Dictionary = await wait_peer_mark(tag + "_moved", 20.0)
		if not mv.is_empty() and phase != "e":
			await sleep_ms(300)
			_g10_ducks_inside(tag + "_moved", crate, ducks)
			await shot("mp2-g10%s-host-sees-client-carry-ducks" % phase)
		var rel: Dictionary = await wait_peer_mark(tag + "_released", 20.0)
		report.check(tag + "_client_released", not rel.is_empty(), "")
		var ok: bool = await wait_for(func(): return grab().owner_of(eid) == 1 and grab().hold_kind(eid) == "", 3.0)
		report.check(tag + "_back_to_host", ok, "owner %d kind %s" % [grab().owner_of(eid), grab().hold_kind(eid)])
		report.check(tag + "_host_body_dynamic", not crate.freeze, "")
		await sleep_ms(1500)
		# the rest poses are compared with the client's: wait until everything sleeps
		var bodies_all: Array = ducks.duplicate()
		bodies_all.append(crate)
		await wait_for(func(): return bodies_all.all(func(x): return not is_instance_valid(x) or (x as RigidBody3D).sleeping), 6.0)
		if phase != "e":
			_g10_ducks_inside(tag + "_rest", crate, ducks)
		var rest := {"crate": Crate.arr(crate.global_position)}
		for dn in ducks:
			rest[str(int(api.entities.id_of(dn)))] = Crate.arr(dn.global_position)
		report.mark(tag + "_rest", {"g10_rest": rest})
		await wait_peer_mark(tag + "_checked", 20.0)
		if phase != "e":
			# control: the host player carries the same crate (the game's own carry)
			var inside_now := ducks.filter(func(dn): return is_instance_valid(dn) and Crate.inside(crate, (dn as Node3D).global_position))
			# spilled ones lie around the crate (and in the host's interact ray): out of the way
			for dn in ducks:
				if is_instance_valid(dn) and not (dn in inside_now) and dn.visible:
					g("ObjectPoolManager").recycle(dn)
			await sleep_ms(300)
			await _g10_host_control(crate, inside_now, fwd, "g10h" if phase == "d" else "g10hf")
		for dn in tree().get_nodes_in_group("product"):
			if dn is RigidBody3D and dn.visible and (dn as Node3D).global_position.distance_to(crate.global_position) < 4.0:
				g("ObjectPoolManager").recycle(dn)
		await sleep_ms(500)
	if is_instance_valid(crate) and crate.visible:
		g("ObjectPoolManager").recycle(crate)
	report.mark("g10_end")


## Control: the host player grabs the same crate (ducks inside) through the same input path.
func _g10_host_control(crate: RigidBody3D, ducks: Array, fwd: Vector3, h: String) -> void:
	var eid := int(bodies().eid_of(crate))
	var p0 := player().global_position
	var spot := open_spot(Vector3(crate.global_position.x, p0.y, crate.global_position.z), fwd, [1.9, 2.2, 1.6])
	if not report.check(h + "_found_spot", spot != Vector3.INF, ""):
		report.mark(h + "_holding", {})
		report.mark(h + "_released")
		return
	await cmd("player.teleport", {"position": [spot.x, spot.y, spot.z]})
	await sleep_ms(600)
	var cam = tree().get_first_node_in_group("main_camera")
	var y0 := crate.global_position.y
	var picked: bool = await Crate.grab_by_input(self, crate, h)
	report.check(h + "_host_picked", picked, "")
	await Crate.lift(self)
	await sleep_ms(1200)
	report.check(h + "_host_still_holding", cam.picked_object == crate, "")
	report.check(h + "_host_lifted", crate.global_position.y - y0 >= Crate.LIFT_M, "dy %.3f m" % (crate.global_position.y - y0))
	report.check(h + "_owner_host_held", grab().owner_of(eid) == 1 and grab().hold_kind(eid) == "held", "")
	_g10_ducks_inside(h + "_held", crate, ducks)
	report.mark(h + "_holding", {"g10_pos": Crate.arr(crate.global_position)})
	await wait_peer_mark(h + "_checked", 20.0)
	if cam.picked_object == crate:
		await Crate.lift(self, -1.0)
		await sleep_ms(500)
		await Crate.press_lmb(self)
		await sleep_ms(300)
	report.check(h + "_host_dropped", cam.picked_object == null, "")
	report.mark(h + "_released")
	await sleep_ms(1500)
	await cmd("player.teleport", {"position": [p0.x, p0.y, p0.z]})
	await sleep_ms(400)
