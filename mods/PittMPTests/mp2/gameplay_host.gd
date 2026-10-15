extends "../scenario_base.gd"
## MP2 GAMEPLAY loopback scenarios, host side (MP2-DESIGN 11.2, a first set of the
## P-scenarios that a decomp world can drive without placing machines by hand).
## Driven by the MP2 harness (scenario_mp2.gd, BODIES) once both peers are in the
## shared world: `await run_gameplay(ids)`. Paired with gameplay_client.gd through
## report marks ("p<n>_*"); every check is about what THIS instance sees.
##   P2   the client buys a tool: charged once on the host, exactly one new entity
##   P8   ghost + rig of the client follow its avatar
##   P10  shared combo: the host's combo reaches the client's ComboSystem, paid once
##   P11  penalty: a client maw accident charges the host once (dedupe, grace)
##   P1   the host's maw consumes ducks: money and stats once, the client mirrors
##   P3   the client switches an automatic bench on through the game's own LMB
##        dispatcher (interact_ray._input), the host's copy runs it
##   P12  the client's mouse wheel (main_camera._input) tunes a magnet_2 and a
##        weight piston (piston_3) on the host; both replay on the client

const ORDER := ["P8", "P2", "P3", "P12", "P10", "P11", "P1"]
const CLIENT_SLOT := 2


func gameplay() -> Object:
	return session.get_module("gameplay") if session.has_method("get_module") else null


func bodies() -> Object:
	return session.get_module("bodies") if session.has_method("get_module") else null


func client_peer() -> int:
	return int(session.peer_of_slot(CLIENT_SLOT)) if session.has_method("peer_of_slot") else 2


func run_gameplay(ids: Array = ORDER) -> void:
	if not report.check("gameplay_module_present", gameplay() != null and bodies() != null, ""):
		return
	for id in ORDER:
		if id in ids:
			await call("_" + String(id).to_lower())
	report.value("gameplay_host_counters", gameplay().counters())
	report.mark("gameplay_host_done")


func _active_of(pool_id: String) -> int:
	var opm = g("ObjectPoolManager")
	if opm == null or not opm.has_method("get_active_units"):
		return -1
	return opm.get_active_units(pool_id).size()


# ---------------------------------------------------------------- P8 ghost and rig follow the client

func _p8() -> void:
	report.begin("P8_ghost_rig")
	await sleep_ms(500)
	var pose: Dictionary = session.avatar_pose(client_peer())
	if not report.check("p8_client_pose", bool(pose.get("ok", false)), ""):
		return
	var ghost: Node3D = gameplay().ghost_of(client_peer())
	var rig: Camera3D = gameplay().rig_of(client_peer())
	report.check("p8_ghost_exists", ghost != null, "")
	report.check("p8_rig_exists", rig != null and not rig.current, "")
	if ghost != null:
		var d := ghost.global_position.distance_to(Vector3(pose.pos))
		report.value("p8_ghost_err_m", d)
		report.check("p8_ghost_at_avatar", d <= 0.6, "%.3f m" % d)
		report.check("p8_ghost_not_player", not ghost.is_in_group("player"), "")
	if rig != null:
		var de := rig.global_position.distance_to(Vector3(pose.eye))
		report.check("p8_rig_at_eye", de <= 0.6, "%.3f m" % de)


# ---------------------------------------------------------------- P2 the client buys a tool

## The client buys a broom (pooled tool) and the press (fixture) through the terminal
## commands: charged once on the host, one new broom entity (same eid on both), one press
## on both, nothing only on the client; then the client grabs the broom (it is usable).
func _p2() -> void:
	report.begin("P2_client_buys_tool")
	var gs = g("GameState")
	if gs == null:
		report.check("p2_game_state", false, "")
		return
	# phase 1 has no tools unlocked yet: unlock the two on the HOST (it re-validates there)
	gs.tools["broom"]["enabled"] = true
	gs.tools["press"]["enabled"] = true
	for t in ["broom", "press"]:
		var el = gs.tools[t].get("enabled_levels", null)
		if typeof(el) == TYPE_ARRAY and not el.is_empty():
			el[0] = true
	gs.add_money(10000)
	await sleep_ms(2500)            # econ mirror reaches the client (full econ every 2 s)
	var before := money()
	var units0 := _active_ids("tool_broom")
	var press0 := tree().get_nodes_in_group("press").size()
	report.mark("p2_ready", {"p2_money": before, "p2_units": units0.size(), "p2_press": press0})
	var done: Dictionary = await wait_peer_mark("p2_bought", 30.0)
	report.check("p2_client_bought", not done.is_empty() and bool(done.get("p2_ok", false)), str(done.get("p2_bought", {})))
	await sleep_ms(1500)
	var units1 := _active_ids("tool_broom")
	var fresh: Array = units1.filter(func(e): return not (e in units0))
	report.check("p2_one_new_broom", units1.size() == units0.size() + 1 and fresh.size() == 1, "%d -> %d" % [units0.size(), units1.size()])
	var press1 := tree().get_nodes_in_group("press").size()
	report.check("p2_one_new_press", press1 == press0 + 1, "%d -> %d" % [press0, press1])
	var spent := _num(before) - _num(money())
	report.value("p2_spent", spent)
	report.check("p2_charged_once", spent == 50 + 5000, "spent %d (broom 50 + press 5000)" % spent)
	var broom := int(fresh[0]) if fresh.size() == 1 else 0
	report.mark("p2_host_checked", {"p2_units_host": units1.size(), "p2_broom_eid": broom, "p2_press_host": press1,
		"p2_money_after": money()})
	# usable: the client picks the broom up (shared grab)
	var gr: Dictionary = await wait_peer_mark("p2_grabbed", 30.0)
	var grab = session.get_module("grab")
	report.check("p2_client_holds_broom", not gr.is_empty() and grab != null and grab.owner_of(broom) == client_peer(),
		"owner %s" % (str(grab.owner_of(broom)) if grab != null else "?"))
	report.mark("p2_owner_checked")
	await wait_peer_mark("p2_released", 20.0)
	await sleep_ms(500)
	report.check("p2_broom_back_to_host", grab != null and grab.owner_of(broom) == 1 and grab.hold_kind(broom) == "", "")


## eids of the active units of a pool (host ids).
func _active_ids(pool_id: String) -> Array:
	var out: Array = []
	var opm = g("ObjectPoolManager")
	if opm == null or not opm.has_method("get_active_units"):
		return out
	for n in opm.get_active_units(pool_id):
		var id := int(api.entities.id_of(n))
		if id > 0:          # a unit spawned this frame gets its id at the next reconcile
			out.append(id)
	return out


## A stat that may be a BigInt.
static func _s(v) -> String:
	if v is Object and v.has_method("to_plain_string"):
		return String(v.to_plain_string())
	return str(v)


static func _num(s: String) -> int:
	return int(s) if s.is_valid_int() else -1


# ---------------------------------------------------------------- P3 automatic workbench output

## The host buys the automatic duck machine; the client turns it on through the host;
## the ducks it makes are host entities that appear on the client with the same eids.
func _p3() -> void:
	report.begin("P3_auto_workbench")
	var gs = g("GameState")
	var ws = g("WorkbenchSpawning")
	if not report.check("p3_autoloads", gs != null and ws != null, ""):
		report.mark("p3_ready", {})
		return
	var before_benches := tree().get_nodes_in_group("automated_workbench")
	gs.products["duck"]["enabled"] = true
	gs.products["duck"]["auto_machine"]["enabled"] = true
	gs.add_money(5000)
	var bought: bool = session.adapter.buy("products", "duck", "auto_machine")
	report.check("p3_host_bought", bought and int(gs.products["duck"]["auto_machine"]["level"]) == 1, "")
	var bench: Node3D = null
	var ok: bool = await wait_for(func():
		for b in tree().get_nodes_in_group("automated_workbench"):
			if not (b in before_benches) and b.has_method("turn_on") and "is_turned_on" in b:
				return true
		return false, 10.0)
	for b in tree().get_nodes_in_group("automated_workbench"):
		if not (b in before_benches) and b.has_method("turn_on"):
			bench = b
	if not report.check("p3_bench_spawned", ok and bench != null, ""):
		report.mark("p3_ready", {})
		return
	await sleep_ms(2500)             # econ + level mirror; the client's own copy spawns
	var duck0 := _active_ids("duck")
	var bp := bench.global_position
	report.mark("p3_ready", {"p3_bench": [bp.x, bp.y, bp.z]})
	var on: Dictionary = await wait_peer_mark("p3_on_sent", 30.0)
	ok = await wait_for(func(): return bool(bench.is_turned_on), 3.0)
	report.check("p3_turned_on_by_client", not on.is_empty() and ok, "")
	var crafted0 := _s(gs.get("products_autocrafted")) if "products_autocrafted" in gs else ""
	ok = await wait_for(func(): return _active_ids("duck").filter(func(e): return not (e in duck0)).size() >= 3, 40.0)
	var made: Array = _active_ids("duck").filter(func(e): return not (e in duck0))
	report.value("p3_made", made.size())
	report.check("p3_bench_made_ducks", ok, "%d new ducks" % made.size())
	bench.turn_off()
	# compare resting poses (the bench launches its ducks; they roll for a while)
	await wait_for(func():
		for e in _active_ids("duck").filter(func(x): return not (x in duck0)):
			var nn = bodies().node_of(int(e))
			if nn is RigidBody3D and not nn.sleeping:
				return false
		return true, 8.0)
	made = _active_ids("duck").filter(func(e): return not (e in duck0))
	var poses := {}
	for e in made:
		var n = bodies().node_of(int(e))
		if n is RigidBody3D and n.sleeping:
			poses[str(e)] = [n.global_position.x, n.global_position.y, n.global_position.z]
	if crafted0 != "":
		report.value("p3_host_autocrafted", [crafted0, _s(gs.get("products_autocrafted"))])
	report.mark("p3_made", {"p3_eids": made, "p3_poses": poses})
	await wait_peer_mark("p3_client_checked", 30.0)
	report.value("p3_gameplay_counters", gameplay().counters())


# ---------------------------------------------------------------- P12 wheel tune

func _p12() -> void:
	report.begin("P12_wheel_tune")
	var opm = g("ObjectPoolManager")
	var p := player()
	if not report.check("p12_pool_and_player", opm != null and p != null, ""):
		report.mark("p12_ready", {})
		return
	var at := p.global_position
	var spots: Array = []
	for dir in [Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1), Vector3(0, 0, -1)]:
		var sp := open_spot(at, dir, [2.2, 2.6, 3.0])
		if sp != Vector3.INF:
			spots.append(sp)
		if spots.size() >= 2:
			break
	if not report.check("p12_two_open_spots", spots.size() >= 2, "%d" % spots.size()):
		report.mark("p12_ready", {})
		return
	var mag: RigidBody3D = opm.spawn("tool_magnet_2", spots[0] + Vector3(0, 0.4, 0))
	var pis: RigidBody3D = opm.spawn("tool_piston_3", spots[1] + Vector3(0, 0.4, 0))
	var ok: bool = await wait_for(func(): return mag != null and pis != null and bodies().eid_of(mag) > 0 and bodies().eid_of(pis) > 0, 5.0)
	if not report.check("p12_tools_tracked", ok, ""):
		report.mark("p12_ready", {})
		return
	await wait_for(func(): return mag.sleeping and pis.sleeping, 8.0)
	if mag.has_method("flip_mode"):
		mag.flip_mode(false)
	var wp0 := int(pis.get("_current_weight_preset_index"))
	await sleep_ms(1500)          # spawn, rest and meta on the client
	var mp: Vector3 = mag.global_position
	var pp: Vector3 = pis.global_position
	report.mark("p12_ready", {"p12_mag": bodies().eid_of(mag), "p12_mag_pos": [mp.x, mp.y, mp.z],
		"p12_pis": bodies().eid_of(pis), "p12_pis_pos": [pp.x, pp.y, pp.z], "p12_wp0": wp0, "p12_stand": [at.x, at.y, at.z]})
	await wait_peer_mark("p12_mag_sent", 60.0)
	ok = await wait_for(func(): return bool(mag._is_repell()), 4.0)
	report.check("p12_magnet_flipped_on_host", ok, "is_repelling %s" % str(mag._is_repell()))
	report.mark("p12_mag_host", {"p12_repel": bool(mag._is_repell())})
	await wait_peer_mark("p12_pis_sent", 60.0)
	ok = await wait_for(func(): return int(pis.get("_current_weight_preset_index")) != wp0, 4.0)
	report.check("p12_weight_preset_on_host", ok, "preset %d -> %d" % [wp0, int(pis.get("_current_weight_preset_index"))])
	report.mark("p12_pis_host", {"p12_wp": int(pis.get("_current_weight_preset_index"))})
	await wait_peer_mark("p12_client_checked", 40.0)
	await shot("mp2-p12-host-tuned-tools")
	opm.recycle(mag)
	opm.recycle(pis)
	await sleep_ms(500)


# ---------------------------------------------------------------- P10 shared combo

func _p10() -> void:
	report.begin("P10_shared_combo")
	var cs = g("ComboSystem")
	if cs == null:
		report.check("p10_combo_system", false, "")
		return
	report.mark("p10_ready")
	await wait_peer_mark("p10_listening", 20.0)
	for i in 5:
		cs.add_to_combo("duck", 1.0)
		await sleep_ms(120)
	report.check("p10_host_combo_5", int(cs.current_combo) >= 5, str(cs.current_combo))
	report.mark("p10_fed", {"p10_combo": int(cs.current_combo)})
	var seen: Dictionary = await wait_peer_mark("p10_seen", 20.0)
	report.check("p10_client_saw_5", int(seen.get("p10_client_combo", 0)) >= 5, str(seen))
	await wait_for(func(): return not bool(cs.is_combo_active), 15.0)
	await sleep_ms(1500)
	report.mark("p10_over", {"p10_money": money()})


# ---------------------------------------------------------------- P11 penalty

func _p11() -> void:
	report.begin("P11_penalty")
	var before := money()
	report.mark("p11_ready", {"p11_money": before})
	var sent: Dictionary = await wait_peer_mark("p11_sent", 20.0)
	report.check("p11_client_sent", not sent.is_empty(), "")
	await sleep_ms(800)
	var c: Dictionary = gameplay().counters()
	report.value("p11_counters", {"applied": c.get("penalties_applied", 0), "dedup": c.get("penalties_dedup", 0),
		"grace": c.get("penalties_grace", 0)})
	report.check("p11_applied_once", int(c.get("penalties_applied", 0)) == 1, str(c))
	report.check("p11_second_deduped", int(c.get("penalties_dedup", 0)) >= 1, str(c))
	report.check("p11_money_charged", money() != before, "%s -> %s" % [before, money()])
	report.mark("p11_host_checked", {"p11_money_after": money()})


# ---------------------------------------------------------------- P1 the maw feeds once

func _p1() -> void:
	report.begin("P1_maw_once")
	var maw := g("World/BottomMaw") as Node3D
	if not report.check("p1_maw", maw != null, ""):
		return
	var gs = g("GameState")
	var consumed0 := int(gs.total_products_consumed) if gs != null else 0
	var before := money()
	for i in 5:
		var at := maw.global_position + Vector3(randf_range(-0.5, 0.5), 3.0 + i * 0.4, randf_range(-0.5, 0.5))
		await cmd("entity.spawn", {"pool_id": "duck", "position": [at.x, at.y, at.z]})
	var ok: bool = await wait_for(func(): return int(gs.total_products_consumed) >= consumed0 + 5, 15.0)
	report.check("p1_five_consumed_once", ok and int(gs.total_products_consumed) == consumed0 + 5,
		"%d -> %d" % [consumed0, int(gs.total_products_consumed)])
	report.check("p1_money_rose", money() != before, "%s -> %s" % [before, money()])
	await sleep_ms(4000)           # maw cleanup (3 s) + mirror
	report.mark("p1_fed", {"p1_money": money(), "p1_consumed": int(gs.total_products_consumed)})
	await wait_peer_mark("p1_money_checked", 20.0)
	# phase progresses exactly once: the maw is one tick short of phase 2, one more duck
	var hole = tree().get_first_node_in_group("saveable_hole")
	var gpr = g("GameProgression")
	if not report.check("p1_hole", hole != null and "phase_nutrition_total" in hole and gpr != null, ""):
		report.mark("p1_done", {"p1_money": money()})
		return
	var changes: Array = []
	var on_change := func(p): changes.append(int(p))
	gpr.phase_changed.connect(on_change)
	var phase0 := phase()
	hole.phase_nutrition_total = 7499.5   # phase 1: (2.0 - 1.0) / 0.1 * 750
	var at2 := maw.global_position + Vector3(0, 3.0, 0)
	await cmd("entity.spawn", {"pool_id": "duck", "position": [at2.x, at2.y, at2.z]})
	ok = await wait_for(func(): return phase() == phase0 + 1, 20.0)
	# phase_changed fires at the end of the transition cinematic (game_progression.gd:250)
	await wait_for(func(): return not changes.is_empty(), 60.0)
	await sleep_ms(3000)
	gpr.phase_changed.disconnect(on_change)
	report.value("p1_phase_changes", changes)
	report.check("p1_phase_progressed_once", ok and changes == [phase0 + 1], "phase %d -> %d, signals %s" % [phase0, phase(),
		str(changes)])
	ok = await wait_for(func(): return session.host_state == "open", 90.0)
	report.check("p1_transition_settled", ok, "host_state %s" % session.host_state)
	report.mark("p1_done", {"p1_money": money(), "p1_consumed": int(gs.total_products_consumed), "p1_phase": phase()})
	await wait_peer_mark("p1_client_checked", 60.0)
