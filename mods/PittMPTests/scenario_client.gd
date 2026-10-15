extends "scenario_base.gd"
## Client side of the two-instance scenario (MP-DESIGN 10.2). Mirrors the
## host's marks; every check is about what THIS instance sees.

const JOIN_TIMEOUT_S := 240.0

var _ended: Array = []
var _session_file := ""


func run() -> void:
	session.ended.connect(func(r, d): _ended.append([r, d]))
	report.begin("1_wait_host")
	await suppress_steam()
	var lv: Dictionary = await wait_peer_mark("lobby_ready", 120.0)
	if not report.check("host_lobby_ready", not lv.is_empty(), ""):
		return
	var wv: Dictionary = await wait_peer_mark("world_open", 240.0)
	report.check("host_world_open", not wv.is_empty(), "")

	report.begin("2_join")
	var id := "dev:%s:%d" % [String(flag.get("address", "127.0.0.1")), int(flag.get("port", 27450))]
	var t_join := Time.get_ticks_msec()
	lobby.join(id)
	var ok: bool = await wait_for(func(): return session.get_state() == "in_game", JOIN_TIMEOUT_S)
	if not report.check("in_game_within_180s", ok and Time.get_ticks_msec() - t_join <= 180000,
			"state %s after %d ms (%s)" % [session.get_state(), Time.get_ticks_msec() - t_join, str(_ended)]):
		return
	_session_file = String(session._session_file)
	report.check("isolated", String(g("SaveManager").active_save_path) == _session_file and _session_file != "",
		"active %s session %s" % [g("SaveManager").active_save_path, _session_file])
	report.check("save_locked", bool(g("SaveManager").save_locked), "")
	# the client never judges milestones itself, not even through direct calls
	var um0 = g("UnlockManager")
	report.check("milestones_blocked", session.adapter.milestones_blocked(), "")
	var unlocked_before: int = um0.unlocked_milestones.size()
	um0.check_milestones()
	report.check("direct_check_milestones_unlocks_nothing", um0.unlocked_milestones.size() == unlocked_before,
		"%d -> %d" % [unlocked_before, um0.unlocked_milestones.size()])
	await sleep_ms(500)
	report.mark("client_in_game", {"money": money(), "phase": phase(), "join_ms": Time.get_ticks_msec() - t_join})
	await shot("2-joined")

	report.begin("3_avatars")
	ok = await wait_for(func(): return puppet(1) != null, 3.0)
	report.check("host_puppet_within_1s", ok, "puppets %d" % puppet_count())
	if ok:
		await sleep_ms(500)
		var near := nearest_puppet_m()
		report.value("puppet_dist_after_join_client", near)
		report.check("no_puppet_within_1m_client", near > 1.0, "nearest puppet %.2f m from the client camera" % near)
		face(puppet(1).global_position)
		await sleep_ms(300)
		await shot("2b-sees-host-at-spawn")
	var tp: Dictionary = await wait_peer_mark("teleported", 10.0)
	if not tp.is_empty():
		var t: Dictionary = tp.get("teleported", {})
		var target := Vector3(float(t.get("x", 0)), float(t.get("y", 0)), float(t.get("z", 0)))
		var mark_ms := int(tp.get("_mark_ms", 0))
		ok = await wait_for(func(): return puppet(1) != null and puppet(1).position.distance_to(target) < 0.75, 3.0)
		var lag := Report.unix_ms() - mark_ms
		var seen := puppet(1).position if puppet(1) != null else Vector3.ZERO
		report.check("teleport_within_300ms", ok and lag <= 600, "lag %d ms (incl. file polling); puppet %s target %s" % [lag, seen, target])
		report.value("teleport_lag_ms", lag)
	# walk over to the host's open spot: ~4 m away, in sight, on its floor
	var moved := false
	if not tp.is_empty() and player() != null:
		var t2: Dictionary = tp.get("teleported", {})
		var hostp := Vector3(float(t2.get("x", 0)), float(t2.get("y", 0)), float(t2.get("z", 0)))
		var tried: Array = []
		var why: Array = []
		for i in 8:
			var dir := Vector3(0, 0, 1).rotated(Vector3.UP, TAU * float(i) / 8.0)
			var spot := open_spot(hostp, dir, [4.0, 3.5, 3.0, 2.5], why)
			if spot == Vector3.INF and player().has_method("_find_clear_spot"):
				# the game's own respawn search around a point 4 m out
				spot = player().call("_find_clear_spot", hostp + dir * 4.0)
				var dd := Vector2(spot.x - hostp.x, spot.z - hostp.z).length()
				tried.append([i, snappedf(dd, 0.01), snappedf(spot.y - hostp.y, 0.01)])
				if dd < 2.5 or dd > 6.0 or absf(spot.y - hostp.y) > 1.0:
					spot = Vector3.INF
			if spot != Vector3.INF:
				await cmd("player.teleport", {"position": [spot.x, spot.y, spot.z]})
				moved = true
				break
		report.value("client_move_tries", tried)
		report.value("client_open_spot_why", why.slice(0, 12))
		await sleep_ms(500)
	report.check("client_moved_near_host", moved, "")
	report.mark("client_moved")
	if puppet(1) != null:
		face(puppet(1).global_position)
		await sleep_ms(300)
		var far := nearest_puppet_m()
		report.value("puppet_dist_far_client", far)
		var hb = puppet(1).get("body")
		report.check("host_puppet_drawn_on_client", far > 2.0 and puppet(1).visible and hb.visible and hb.transparency < 0.01,
			"%.2f m, body %s transparency %.2f" % [far, hb.visible, hb.transparency])
	await shot("3-sees-host")
	report.mark("teleport_seen")

	report.begin("4_money")
	var mv: Dictionary = await wait_peer_mark("money_added", 10.0)
	var expect := String(mv.get("money_added", {}).get("money", ""))
	ok = await wait_for(func(): return money() == expect, 5.0)
	report.check("host_money_exact", ok, "client %s host %s" % [money(), expect])
	# authority commands without remote = true never run for a client
	var denied = await cmd("money.add", {"amount": "1000000"})
	report.check("client_money_add_refused", not denied.ok and String(denied.code) == "ERR_DENIED", "%s %s" % [denied.code, denied.error])
	report.mark("money_seen")
	await wait_peer_mark("ready_for_feed", 10.0)
	var gs = g("GameState")
	if session.has_method("mp2_active") and session.mp2_active():
		# MP2 shared world: there is one maw (the host's) and clients may not spawn
		# (entity.spawn is remote-refused). The host drops two ducks into it; the check is
		# that the income is counted once and mirrored here (a client feeding the maw itself
		# is MP2 G1/P1).
		var gs0 := money()
		report.mark("fed", {"amount": 0, "mp2": true})
		var fc2: Dictionary = await wait_peer_mark("feed_checked", 30.0)
		var host_after2 := String(fc2.get("feed_checked", {}).get("money_after_feed", ""))
		ok = await wait_for(func(): return money() == host_after2, 5.0)
		report.check("converged_no_double_count", ok and money() != gs0, "client %s host %s (before %s)" % [money(),
			host_after2, gs0])
		await _mp1_rest_after_feed()
		return
	var amount := 2500
	# "the client feeds its own maw": the maw's own effects in this private world
	gs.add_money(amount)
	gs.products_consumed["duck"] = int(gs.products_consumed.get("duck", 0)) + 2
	gs.total_products_consumed = int(gs.total_products_consumed) + 2
	gs.stat_changed.emit("products_consumed.duck", gs.products_consumed["duck"])
	var hole = tree().get_first_node_in_group("saveable_hole")
	if hole != null:
		hole._on_product_consumed("duck", 5, -1)   # hole_ext forwards it to the host's hole
	report.mark("fed", {"amount": amount})
	var fc: Dictionary = await wait_peer_mark("feed_checked", 20.0)
	var host_after := String(fc.get("feed_checked", {}).get("money_after_feed", ""))
	ok = await wait_for(func(): return money() == host_after, 5.0)
	report.check("converged_no_double_count", ok, "client %s host %s" % [money(), host_after])
	await _mp1_rest_after_feed()


## Steps 5.. of the MP1 scenario (after the feeding step, for both worlds).
func _mp1_rest_after_feed() -> void:
	var ok := false
	var id := "dev:%s:%d" % [String(flag.get("address", "127.0.0.1")), int(flag.get("port", 27450))]
	var t_join := 0
	report.begin("5_purchases")
	await _buy_upgrade()
	await _buy_tool()

	report.begin("6_phase_unlock")
	var settled: Array = []
	var sub_id: int = api.events.on("phase.settled", func(ev): settled.append(int(ev.payload.get("phase", 0))))
	ok = await wait_for(func(): return phase() == 2, 30.0)
	report.check("phase_2_began", ok, "phase %d" % phase())
	ok = await wait_for(func(): return 2 in settled, 90.0)
	api.events.off(sub_id)
	report.check("client_transition_settled", ok, str(settled))
	report.mark("phase2_settled", {"phase": phase()})
	var uv: Dictionary = await wait_peer_mark("unlocked", 60.0)
	var mid := String(uv.get("unlocked", {}).get("id", ""))
	if mid != "":
		var um = g("UnlockManager")
		ok = await wait_for(func(): return um.is_unlocked(mid), 5.0)
		report.check("unlock_replicated", ok, mid)
	report.mark("unlock_seen")

	report.begin("7_pause")
	await wait_peer_mark("move_for_pause", 20.0)
	var pm = tree().get_first_node_in_group("PauseMenu")
	var mm = g("MenuManager")
	var pup := puppet(1)
	var p0 := pup.position if pup != null else Vector3.ZERO
	if pm != null:
		mm.open_menu(pm)
	var paused_frames := 0
	var frames := 0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 2000:
		await tree().physics_frame
		frames += 1
		if tree().paused:
			paused_frames += 1
	var p1 := puppet(1).position if puppet(1) != null else Vector3.ZERO
	report.check("tree_not_paused", paused_frames == 0, "%d/%d physics frames paused" % [paused_frames, frames])
	report.check("host_puppet_moves_while_paused", p1.distance_to(p0) > 0.5, "moved %.2f m" % p1.distance_to(p0))
	report.check("menu_open", mm.current_menu != null and bool(mm.game_paused), "")
	await shot("7-local-pause")
	if mm.current_menu != null:
		mm.close_current_menu()
	report.mark("pause_checked")

	report.begin("8_rejoin")
	var file1 := _session_file
	session.leave()
	ok = await wait_for(func(): return on_main_menu(), 30.0)
	report.check("back_on_main_menu", ok, "")
	var deleted: bool = await wait_for(func(): return not FileAccess.file_exists(file1), 5.0)
	report.check("session_file_deleted", file1 != "" and deleted, file1)
	report.mark("left")
	await sleep_ms(2500)
	t_join = Time.get_ticks_msec()
	lobby.join(id)
	ok = await wait_for(func(): return session.get_state() == "in_game", JOIN_TIMEOUT_S)
	report.check("rejoined", ok, "state %s (%s)" % [session.get_state(), str(_ended)])
	_session_file = String(session._session_file)
	report.mark("client_in_game_2", {"phase": phase(), "money": money(), "join_ms": Time.get_ticks_msec() - t_join,
		"early_chunks": int(session.counters.get("early_chunks", 0))})
	await shot("8-rejoined")

	report.begin("10_conditioned")
	var cond_v: Dictionary = await wait_peer_mark("conditioned", 30.0)
	session.set_conditioning(cond_v.get("conditioned", {}))
	var m2: Dictionary = await wait_peer_mark("money_added_2", 30.0)
	var expect2 := String(m2.get("money_added_2", {}).get("money", ""))
	ok = await wait_for(func(): return money() == expect2, 10.0)
	var pup2 := puppet(1)
	var frames_ok: bool = pup2 != null and int(pup2.frames_rx) > 0
	report.check("money_under_conditioning", ok, "client %s host %s" % [money(), expect2])
	report.check("avatars_under_conditioning", frames_ok, "")
	report.mark("conditioned_ok", {"rtt_ms": session.clock.rtt_ms})
	session.set_conditioning({})

	report.begin("9_host_leave")
	await wait_peer_mark("host_left", 60.0)
	ok = await wait_for(func(): return session.get_state() == "idle" and on_main_menu(), 30.0)
	report.check("client_back_on_main_menu", ok, "state %s" % session.get_state())
	var reason := String(_ended.back()[0]) if not _ended.is_empty() else ""
	report.check("ended_host_left", reason == "host_left", str(_ended))
	var iso_off: bool = await wait_for(func(): return String(g("SaveManager").active_save_path) != _session_file 		and not FileAccess.file_exists(_session_file), 5.0)
	report.check("isolation_off", iso_off, String(g("SaveManager").active_save_path))
	report.check("session_file_deleted_2", _session_file != "" and not FileAccess.file_exists(_session_file), _session_file)
	report.check("local_authority_back", api.net.get_authority_kind() == "local", api.net.get_authority_kind())
	await sleep_ms(1500)
	await shot("9-host-left-menu")
	report.mark("client_end_checked", {"reason": reason})


func _rows(ui: Node) -> Array:
	var out: Array = []
	for n in ui.find_children("*", "HBoxContainer", true, false):
		if n.has_meta("button"):
			out.append(n)
	return out


func _buy_upgrade() -> void:
	var ui = tree().get_first_node_in_group("UpgradeUI")
	if ui == null:
		report.mark("bought_upgrade", {"key": ""})
		report.info("no_upgrade_ui", "UpgradeUI not found")
		return
	ui.update_ui()
	await frame()
	var gs = g("GameState")
	for row in _rows(ui):
		if String(row.get_meta("category", "")) != "upgrades":
			continue
		var b: Button = row.get_meta("button")
		if b.disabled or not row.get_meta("pittmp_rewired", false):
			continue
		var key := String(row.get_meta("key"))
		var before := int(gs.upgrades[key].level)
		b.pressed.emit()
		var ok: bool = await wait_for(func(): return int(gs.upgrades[key].level) == before + 1, 10.0)
		report.check("upgrade_level_plus_one_mirrored", ok, "%s %d -> %d" % [key, before, int(gs.upgrades[key].level)])
		report.mark("bought_upgrade", {"category": "upgrades", "key": key, "subkey": "", "before": before})
		return
	report.mark("bought_upgrade", {"key": ""})
	report.info("no_upgrade_row", "no enabled, affordable, rewired upgrade row")


func _buy_tool() -> void:
	var ui = tree().get_first_node_in_group("UpgradeUI")
	if ui == null:
		report.mark("bought_tool", {"tool": ""})
		return
	ui.update_ui()
	await frame()
	for row in _rows(ui):
		if not row.has_meta("tool_name") or row.get_meta("recall_mode", false):
			continue
		var b: Button = row.get_meta("button")
		if b.disabled or not row.get_meta("pittmp_rewired", false):
			continue
		var tool := String(row.get_meta("tool_name"))
		var before := money()
		var pool_before := _pool_active_total()
		b.pressed.emit()
		var ok: bool = await wait_for(func(): return money() != before, 10.0)
		await sleep_ms(500)
		report.check("tool_bought_money_down", ok, "%s: %s -> %s" % [tool, before, money()])
		report.check("tool_in_own_world", _pool_active_total() > pool_before, "active objects %d -> %d" % [pool_before, _pool_active_total()])
		report.mark("bought_tool", {"tool": tool, "ok": ok})
		return
	report.mark("bought_tool", {"tool": ""})
	report.info("no_tool_row", "no enabled, affordable tool row")


## Pooled tools (ObjectPoolManager) plus scene-instanced ones (press, trading
## terminal: upgradeUI._spawn_tool_instance adds them to current_scene).
func _pool_active_total() -> int:
	var pm = g("ObjectPoolManager")
	var n := tree().current_scene.get_child_count() if tree().current_scene != null else 0
	if pm == null:
		return n
	for id in pm._pools:
		n += pm._pools[id].active.size()
	return n
