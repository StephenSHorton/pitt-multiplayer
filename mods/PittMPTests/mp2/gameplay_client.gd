extends "../scenario_base.gd"
## MP2 GAMEPLAY loopback scenarios, client side (see gameplay_host.gd), paired
## through report marks. Driven by the MP2 harness (scenario_mp2.gd, BODIES):
## `await run_gameplay(ids)` once in the shared world.

const ORDER := ["P8", "P2", "P3", "P12", "P10", "P11", "P1"]


func gameplay() -> Object:
	return session.get_module("gameplay") if session.has_method("get_module") else null


func bodies() -> Object:
	return session.get_module("bodies") if session.has_method("get_module") else null


func run_gameplay(ids: Array = ORDER) -> void:
	if not report.check("gameplay_module_present", gameplay() != null and bodies() != null, ""):
		return
	for id in ORDER:
		if id in ids:
			await call("_" + String(id).to_lower())
	report.value("gameplay_client_counters", gameplay().counters())
	report.mark("gameplay_client_done")


func _active_of(pool_id: String) -> int:
	var opm = g("ObjectPoolManager")
	if opm == null or not opm.has_method("get_active_units"):
		return -1
	return opm.get_active_units(pool_id).size()


func _p8() -> void:
	report.begin("P8_ghost_rig")
	# nothing to do here: the host checks its ghost/rig against our avatar frames
	await sleep_ms(500)


func _p2() -> void:
	report.begin("P2_client_buys_tool")
	var m: Dictionary = await wait_peer_mark("p2_ready", 60.0)
	if not report.check("p2_host_ready", not m.is_empty(), ""):
		return
	var ok_money: bool = await wait_for(func(): return money() == String(m.get("p2_money", "")), 5.0)
	report.check("p2_money_mirrored", ok_money, "%s vs %s" % [money(), m.get("p2_money", "")])
	var units0 := _active_of("tool_broom")
	var press0 := tree().get_nodes_in_group("press").size()
	var r = await cmd("PittMultiplayer.buy_tool", {"tool": "broom", "level": 0})
	report.check("p2_buy_broom_ok", r.ok, "%s %s" % [r.code, r.error])
	var r2 = await cmd("PittMultiplayer.buy_tool", {"tool": "press", "level": 0})
	report.check("p2_buy_press_ok", r2.ok, "%s %s" % [r2.code, r2.error])
	report.mark("p2_bought", {"p2_ok": r.ok and r2.ok})
	var h: Dictionary = await wait_peer_mark("p2_host_checked", 30.0)
	var ok_units: bool = await wait_for(func(): return _active_of("tool_broom") == int(h.get("p2_units_host", -9)), 5.0)
	report.check("p2_same_broom_count", ok_units, "client %d host %s (before %d)" % [_active_of("tool_broom"),
		h.get("p2_units_host", "?"), units0])
	var eid := int(h.get("p2_broom_eid", 0))
	var ok_eid: bool = await wait_for(func(): return eid > 0 and bodies().node_of(eid) != null, 5.0)
	report.check("p2_broom_same_eid", ok_eid, "eid %d" % eid)
	var ok_press: bool = await wait_for(func(): return tree().get_nodes_in_group("press").size() == int(h.get("p2_press_host", -9)), 8.0)
	report.check("p2_press_on_both", ok_press, "client %d host %s (before %d)" % [tree().get_nodes_in_group("press").size(),
		h.get("p2_press_host", "?"), press0])
	var ok_m: bool = await wait_for(func(): return money() == String(h.get("p2_money_after", "")), 5.0)
	report.check("p2_money_equals_host", ok_m, "%s vs %s" % [money(), h.get("p2_money_after", "")])
	var strays := int(bodies().counters().get("stray_spawns", 0))
	report.check("p2_nothing_only_on_client", strays == 0, "stray_spawns %d" % strays)
	# usable: pick it up through the shared grab
	var broom := bodies().node_of(eid) as RigidBody3D
	var grab = session.get_module("grab")
	var cam := tree().get_first_node_in_group("main_camera") as Camera3D
	if broom == null or grab == null or cam == null:
		report.check("p2_broom_grabbable", false, "")
		report.mark("p2_grabbed")
		report.mark("p2_released")
		return
	var p := player()
	var to := broom.global_position + (p.global_position - broom.global_position).normalized() * 1.5 if p != null else broom.global_position
	await cmd("player.teleport", {"position": [to.x, broom.global_position.y + 1.0, to.z]})
	await sleep_ms(400)
	face(broom.global_position)
	await sleep_ms(200)
	cam._begin_carry(broom)
	var held: bool = await wait_for(func(): return grab.is_mine(eid), 3.0)
	report.check("p2_broom_grabbed", held, "picked %s equipped %s dist %.2f m local_sim %s counters %s" % [
		cam.picked_object == broom, cam.get("equipped_item") == broom, cam.global_position.distance_to(broom.global_position),
		bodies().is_local_sim(eid), str(grab.counters())])
	await shot("mp2-p2-client-holds-bought-broom")
	report.mark("p2_grabbed")
	await wait_peer_mark("p2_owner_checked", 20.0)
	if cam.picked_object == broom:
		cam.drop_object(true)
	elif cam.get("equipped_item") == broom and cam.has_method("release_held_object"):
		cam.call("release_held_object")
	report.mark("p2_released")
	await sleep_ms(800)


func _p3() -> void:
	report.begin("P3_auto_workbench")
	var m: Dictionary = await wait_peer_mark("p3_ready", 60.0)
	var bpa: Array = m.get("p3_bench", [])
	if not report.check("p3_host_ready", bpa.size() == 3, ""):
		return
	var bp := Vector3(float(bpa[0]), float(bpa[1]), float(bpa[2]))
	var found: Array = []
	var ok: bool = await wait_for(func():
		for b in tree().get_nodes_in_group("automated_workbench"):
			if (b as Node3D).global_position.distance_to(bp) < 1.0:
				found.append(b)
				return true
		return false, 10.0)
	var bench: Node3D = found[0] if not found.is_empty() else null
	if not report.check("p3_bench_on_client", ok and bench != null, ""):
		report.mark("p3_on_sent")
		return
	# stand next to it, look at it, and press it (the forwarded input path of the gate)
	var spot := Vector3.INF
	for dir in [Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 0, -1), Vector3(-1, 0, 0)]:
		spot = open_spot(bp + Vector3(0, 0.975, 0), dir, [2.5, 3.0, 3.5])
		if spot != Vector3.INF:
			break
	if spot != Vector3.INF:
		await cmd("player.teleport", {"position": [spot.x, spot.y, spot.z]})
	await sleep_ms(500)
	face(bp + Vector3(0, 0.5, 0))
	await sleep_ms(300)
	var strays0 := int(bodies().counters().get("stray_spawns", 0))
	var local_before := bool(bench.is_turned_on)
	# the game's own LMB dispatcher (interact_ray._input), as a mouse click would run it
	var cam := tree().get_first_node_in_group("main_camera")
	var ray = cam.get("interact_ray") if cam != null else null
	var on_bench: bool = await wait_for(func(): return ray != null and _ray_on_group(ray, "automated_workbench"), 4.0)
	report.check("p3_ray_on_bench", on_bench, "last_collider %s" % (str(ray.get("last_collider")) if ray != null else "no ray"))
	if on_bench:
		ray._input(_action("lMouse", true))
		ray._input(_action("lMouse", false))
	else:
		gameplay().forward_input(bench, "turn_on", [])
	report.check("p3_toggled_through_game_input", on_bench, "")
	report.check("p3_not_toggled_locally_first", not local_before, "")
	report.mark("p3_on_sent")
	await sleep_ms(1500)
	await shot("mp2-p3-client-auto-bench")
	var mv: Dictionary = await wait_peer_mark("p3_made", 90.0)
	var eids: Array = mv.get("p3_eids", [])
	var poses: Dictionary = mv.get("p3_poses", {})
	ok = await wait_for(func():
		for e in eids:
			if not bodies().is_replicated(int(e)):
				return false
		return true, 3.0)
	report.check("p3_ducks_with_host_eids", ok and eids.size() >= 3, "%d ducks" % eids.size())
	await sleep_ms(1500)
	var worst := 0.0
	for k in poses:
		var n = bodies().node_of(int(String(k)))
		if n != null:
			var hp := Vector3(float(poses[k][0]), float(poses[k][1]), float(poses[k][2]))
			worst = maxf(worst, (n.global_position as Vector3).distance_to(hp))
	report.value("p3_pose_worst_m", worst)
	report.check("p3_resting_poses_match_1cm", worst <= 0.01 and not poses.is_empty(), "worst %.4f m over %d resting ducks" % [worst, poses.size()])
	var strays := int(bodies().counters().get("stray_spawns", 0)) - strays0
	report.check("p3_zero_client_strays", strays == 0, "%d" % strays)
	await shot("mp2-p3-client-auto-bench-ducks")
	report.mark("p3_client_checked")


static func _action(name: String, pressed: bool) -> InputEventAction:
	var ev := InputEventAction.new()
	ev.action = name
	ev.pressed = pressed
	return ev


static func _ray_on_group(ray, group: String) -> bool:
	var lc = ray.get("last_collider")
	return lc != null and is_instance_valid(lc) and lc.is_in_group(group)


func _gate():
	var gp = gameplay()
	return gp.get_script().get_script_constant_map().get("MpGate", null) if gp != null else null


## Stand at `stand` (open floor the host picked, about 2.5 m from the tool), look at
## the tool and wait until the interact ray reports `node`.
func _look_at_tool(node: Node3D, pos: Vector3, stand: Vector3) -> bool:
	await cmd("player.teleport", {"position": [stand.x, stand.y, stand.z]})
	await sleep_ms(500)
	face(pos)
	var cam := tree().get_first_node_in_group("main_camera")
	var ray = cam.get("interact_ray") if cam != null else null
	return await wait_for(func():
		face(pos)
		return ray != null and ray.get("last_collider") == node, 4.0)


func _p12() -> void:
	report.begin("P12_wheel_tune")
	var m: Dictionary = await wait_peer_mark("p12_ready", 90.0)
	if not report.check("p12_host_ready", m.has("p12_mag"), ""):
		report.mark("p12_mag_sent")
		report.mark("p12_pis_sent")
		report.mark("p12_client_checked")
		return
	var cam := tree().get_first_node_in_group("main_camera")
	var meid := int(m.p12_mag)
	var peid := int(m.p12_pis)
	var ok: bool = await wait_for(func(): return bodies().node_of(meid) != null and bodies().node_of(peid) != null, 5.0)
	report.check("p12_tools_on_client", ok, "")
	var mag: Node3D = bodies().node_of(meid)
	var pis: Node3D = bodies().node_of(peid)
	var sa: Array = m.get("p12_stand", [0, 0, 0])
	var stand := Vector3(float(sa[0]), float(sa[1]), float(sa[2]))
	# 1. magnet_2: the real wheel dispatcher (main_camera._input -> scroll_tune_up -> flip on the host)
	var mpos := Vector3(float(m.p12_mag_pos[0]), float(m.p12_mag_pos[1]), float(m.p12_mag_pos[2]))
	var seen: bool = false
	if mag != null:
		seen = await _look_at_tool(mag, mpos, stand)
	var lc = cam.get("interact_ray").get("last_collider") if cam != null and cam.get("interact_ray") != null else null
	report.check("p12_ray_on_magnet", seen, "last_collider %s" % str(lc))
	var before := bool(mag._is_repell()) if mag != null else true
	if seen:
		cam._input(_action("scroll_up", true))
		report.check("p12_magnet_not_flipped_locally_first", bool(mag._is_repell()) == before, "")
	report.mark("p12_mag_sent")
	var hm: Dictionary = await wait_peer_mark("p12_mag_host", 30.0)
	ok = await wait_for(func(): return mag != null and bool(mag._is_repell()) == bool(hm.get("p12_repel", false)), 4.0)
	report.check("p12_magnet_replayed", ok and bool(hm.get("p12_repel", false)), "client %s host %s" % [
		str(mag._is_repell()) if mag != null else "?", str(hm.get("p12_repel", "?"))])
	# 2. weight piston: the wheel when the ray resolves the piston itself, else the gated call
	var ppos := Vector3(float(m.p12_pis_pos[0]), float(m.p12_pis_pos[1]), float(m.p12_pis_pos[2]))
	var seen2: bool = false
	if pis != null:
		seen2 = await _look_at_tool(pis, ppos, stand)
	report.value("p12_ray_on_piston", seen2)
	var wp0 := int(pis.get("_current_weight_preset_index")) if pis != null else -1
	if seen2:
		cam._input(_action("scroll_up", true))
	elif pis != null and _gate() != null:
		_gate().begin_input_scope()
		pis.scroll_tune_up()
		_gate().end_input_scope()
	report.check("p12_piston_not_tuned_locally_first", pis != null and int(pis.get("_current_weight_preset_index")) == wp0, "")
	report.mark("p12_pis_sent")
	var hp: Dictionary = await wait_peer_mark("p12_pis_host", 30.0)
	ok = await wait_for(func(): return pis != null and int(pis.get("_current_weight_preset_index")) == int(hp.get("p12_wp", -9)), 4.0)
	report.check("p12_weight_preset_replayed", ok and int(hp.get("p12_wp", wp0)) != wp0, "client %d host %s (was %d)" % [
		int(pis.get("_current_weight_preset_index")) if pis != null else -1, str(hp.get("p12_wp", "?")), wp0])
	await shot("mp2-p12-client-tuned-tools")
	report.mark("p12_client_checked")


func _p10() -> void:
	report.begin("P10_shared_combo")
	var cs = g("ComboSystem")
	await wait_peer_mark("p10_ready", 30.0)
	report.check("p10_local_combo_physics_off", cs != null and not cs.is_physics_processing(), "")
	var best := [0]
	var watch := func(level, _p = null, _n = null): best[0] = maxi(best[0], int(level))
	if cs != null:
		cs.combo_updated.connect(watch)
	report.mark("p10_listening")
	await wait_peer_mark("p10_fed", 20.0)
	await wait_for(func(): return best[0] >= 5, 5.0)
	report.check("p10_hud_combo_5", best[0] >= 5, "best %d" % best[0])
	report.mark("p10_seen", {"p10_client_combo": best[0]})
	var over: Dictionary = await wait_peer_mark("p10_over", 30.0)
	var ok: bool = await wait_for(func(): return money() == String(over.get("p10_money", "")), 5.0)
	report.check("p10_money_equals_host", ok, "%s vs %s" % [money(), over.get("p10_money", "")])
	if cs != null and cs.combo_updated.is_connected(watch):
		cs.combo_updated.disconnect(watch)


func _p11() -> void:
	report.begin("P11_penalty")
	await wait_peer_mark("p11_ready", 30.0)
	await sleep_ms(5200)            # past the host's join grace
	await cmd("PittMultiplayer.penalty", {"kind": "maw"})
	await cmd("PittMultiplayer.penalty", {"kind": "maw"})   # within 2 s: deduped on the host
	report.mark("p11_sent")
	var h: Dictionary = await wait_peer_mark("p11_host_checked", 20.0)
	var ok: bool = await wait_for(func(): return money() == String(h.get("p11_money_after", "")), 5.0)
	report.check("p11_money_mirrored", ok, "%s vs %s" % [money(), h.get("p11_money_after", "")])


func _p1() -> void:
	report.begin("P1_maw_once")
	var gpr = g("GameProgression")
	var changes: Array = []
	var on_change := func(p): changes.append(int(p))
	if gpr != null:
		gpr.phase_changed.connect(on_change)
	var phase0 := phase()
	var d: Dictionary = await wait_peer_mark("p1_fed", 60.0)
	if not report.check("p1_host_fed", not d.is_empty(), ""):
		return
	var ok: bool = await wait_for(func(): return money() == String(d.get("p1_money", "")), 5.0)
	report.check("p1_money_equals_host", ok, "%s vs %s" % [money(), d.get("p1_money", "")])
	report.mark("p1_money_checked")
	var dn: Dictionary = await wait_peer_mark("p1_done", 150.0)
	ok = await wait_for(func(): return phase() == int(dn.get("p1_phase", -1)), 10.0)
	await wait_for(func(): return not changes.is_empty(), 60.0)
	await sleep_ms(3000)
	if gpr != null:
		gpr.phase_changed.disconnect(on_change)
	report.value("p1_client_phase_changes", changes)
	report.check("p1_client_phase_once", ok and changes.size() == 1 and phase() == phase0 + 1, "phase %d -> %d, signals %s" % [
		phase0, phase(), str(changes)])
	ok = await wait_for(func(): return money() == String(dn.get("p1_money", "")), 5.0)
	report.check("p1_money_equals_host_after_phase", ok, "%s vs %s" % [money(), dn.get("p1_money", "")])
	var gs = g("GameState")
	report.value("p1_client_consumed", int(gs.total_products_consumed) if gs != null else -1)
	report.mark("p1_client_checked")
