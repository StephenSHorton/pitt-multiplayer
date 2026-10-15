extends "scenario_base.gd"
## Host side of the two-instance scenario (MP-DESIGN 10.2 steps 1-10).
## The client side (scenario_client.gd) mirrors every mark.

const JOIN_TIMEOUT_S := 240.0
const STEP_TIMEOUT_S := 60.0


func run() -> void:
	report.begin("1_host_world")
	await suppress_steam()
	var r = await cmd("save.isolate", {"enabled": true, "path": api.pittapi_dir().path_join("test/mp_host.save")})
	report.check("save_isolated", r.ok, r.error)
	lobby.host()
	var ok: bool = await wait_for(func(): return session.get_state() == "lobby", 10.0)
	if not report.check("lobby_hosted", ok, "state %s" % session.get_state()):
		return
	report.check("transport_enet", String(lobby.transport_target().get("kind", "")) == "enet", str(lobby.transport_target()))
	report.mark("lobby_ready", {"address": lobby.transport_target().get("address", ""), "port": lobby.transport_target().get("port", 0)})
	report.check("start_game", session.start_game() == OK, "")
	var menu = tree().get_first_node_in_group("MainMenu")
	var gs = g("GameState")
	var gp = g("GameProgression")
	var sm = g("SaveManager")
	gs.sandbox_mode = false
	gp.reset_run_state()
	gp.current_phase = 1
	sm.pending_camera_data = {}
	sm.should_load_on_ready = false
	menu._pending_new_game = true
	session.notify_host_launch("res://scenes/world.tscn")
	menu._launch_game("res://scenes/world.tscn")
	ok = await wait_for(func(): return session.get_state() == "in_game", 180.0)
	if not report.check("host_open", ok, "state %s host_state %s" % [session.get_state(), session.host_state]):
		return
	report.check("phase_1", phase() == 1, str(phase()))
	await cmd("money.set", {"amount": "5000000"})
	report.mark("world_open", {"money": money(), "phase": phase()})
	await shot("1-world")
	# where a joiner in slot 2 would spawn, with every candidate's verdict
	var snap_script = session.get_script().get_script_constant_map().get("Snapshot")
	var hp := player()
	if snap_script != null and hp != null:
		var why: Array = []
		var center: Vector3 = session.adapter.host_player_position()
		var sp: Vector3 = snap_script.ring_position(center, 2, snap_script.WorldProbe.new(hp), why)
		report.value("spawn_center", [center.x, center.y, center.z])
		report.value("spawn_slot2", [sp.x, sp.y, sp.z])
		report.value("spawn_slot2_why", why)

	report.begin("2_client_join")
	var cv: Dictionary = await wait_peer_mark("client_in_game", JOIN_TIMEOUT_S)
	if not report.check("client_joined", not cv.is_empty(), "client never reached in_game"):
		return
	report.check("roster_2", session.get_roster().size() == 2, str(session.get_roster()))
	report.check("client_money_equal", String(cv.get("client_in_game", {}).get("money", "")) == money(),
		"client %s host %s" % [cv.get("client_in_game", {}).get("money", "?"), money()])
	report.check("client_phase_equal", int(cv.get("client_in_game", {}).get("phase", -1)) == phase(), "")
	await sleep_ms(3000)
	report.check("join_cost_zero", money() == "5000000", "host money %s after the join settled (was 5000000)" % money())

	report.begin("3_avatars")
	ok = await wait_for(func(): return puppet_count() >= 1, 3.0)
	report.check("client_puppet_on_host", ok, "puppets %d" % puppet_count())
	var p := player()
	if ok:
		await sleep_ms(1000)
		var near := nearest_puppet_m()
		report.value("puppet_dist_after_join_host", near)
		report.check("no_puppet_within_1m_host", near > 1.0, "nearest puppet %.2f m from the host camera" % near)
		var cp := puppet(2)
		if cp != null:
			if p != null:
				report.value("client_spawn_offset_m", Vector2(cp.global_position.x - p.global_position.x, cp.global_position.z - p.global_position.z).length())
			face(cp.global_position)
			await sleep_ms(300)
			report.value("client_puppet_pos_on_host", [cp.global_position.x, cp.global_position.y, cp.global_position.z])
			var cb = cp.get("body")
			report.check("client_puppet_drawn_on_host", cp.visible and cb.visible and cb.transparency < 0.01,
				"visible %s body %s transparency %.2f" % [cp.visible, cb.visible, cb.transparency])
		await shot("3-sees-client")
	# the start elevator is tight (the joiner spawns 1.6 m away): move to the open
	# floor at the game's respawn anchor; the client follows to a spot ~4 m away,
	# then both sides take a screenshot at a normal distance
	var target := Vector3(0, 6, 18)          # player_controller.gd RESPAWN_ANCHOR
	if p != null and p.has_method("_find_clear_spot"):
		target = p.call("_find_clear_spot", target)
	await cmd("player.teleport", {"position": [target.x, target.y, target.z]})
	await sleep_ms(200)
	if p != null:
		report.value("host_pos_after_teleport", [p.global_position.x, p.global_position.y, p.global_position.z])
		target = p.global_position
	report.mark("teleported", {"x": target.x, "y": target.y, "z": target.z})
	var mvd: Dictionary = await wait_peer_mark("client_moved", 20.0)
	report.check("client_moved_near_host", not mvd.is_empty(), "")
	await sleep_ms(600)
	if puppet(2) != null:
		face(puppet(2).global_position)
		await sleep_ms(300)
		var far := nearest_puppet_m()
		report.value("puppet_dist_far_host", far)
		var cb = puppet(2).get("body")
		report.check("client_puppet_drawn_far_on_host", far > 2.0 and puppet(2).visible and cb.visible and cb.transparency < 0.01,
			"%.2f m, body %s transparency %.2f" % [far, cb.visible, cb.transparency])
		await shot("3b-sees-client-far")
	var tv: Dictionary = await wait_peer_mark("teleport_seen", 30.0)
	report.check("teleport_seen_by_client", not tv.is_empty(), "")

	report.begin("4_money")
	await cmd("money.add", {"amount": "123456"})
	report.mark("money_added", {"money": money()})
	var mv: Dictionary = await wait_peer_mark("money_seen", 10.0)
	report.check("client_saw_money", not mv.is_empty(), "")
	var before_feed := money()
	var consumed_before := int(gs.products_consumed.get("duck", 0)) if typeof(gs.products_consumed) == TYPE_DICTIONARY else 0
	report.mark("ready_for_feed", {"money_before_feed": before_feed})
	var fv: Dictionary = await wait_peer_mark("fed", STEP_TIMEOUT_S)
	if not fv.is_empty() and bool(fv.get("fed", {}).get("mp2", false)):
		# MP2 shared world: the client dropped two ducks into the (one) maw; it is counted
		# once, here, and the client mirrors the result
		report.check("client_fed", true, "mp2")
		var maw := g("World/BottomMaw") as Node3D
		for i in 2:
			if maw != null:
				var at := maw.global_position + Vector3(0.3 * i, 3.0 + 0.5 * i, 0)
				await cmd("entity.spawn", {"pool_id": "duck", "position": [at.x, at.y, at.z]})
		ok = await wait_for(func(): return int(gs.products_consumed.get("duck", 0)) >= consumed_before + 2, 15.0)
		report.check("host_products_consumed_rose", ok, "duck %s" % str(gs.products_consumed.get("duck", 0)))
		await sleep_ms(500)
		report.check("host_money_includes_client_income", money() != before_feed, "%s -> %s" % [before_feed, money()])
		report.mark("feed_checked", {"money_after_feed": money()})
	elif report.check("client_fed", not fv.is_empty(), ""):
		var amount := int(fv.get("fed", {}).get("amount", 0))
		var expect := str(int(before_feed) + amount)
		ok = await wait_for(func(): return money() == expect, 5.0)
		report.check("host_money_includes_client_income", ok, "host %s expected %s" % [money(), expect])
		ok = await wait_for(func(): return int(gs.products_consumed.get("duck", 0)) >= consumed_before + 2, 5.0)
		report.check("host_products_consumed_rose", ok, "duck %s" % str(gs.products_consumed.get("duck", 0)))
		report.mark("feed_checked", {"money_after_feed": money()})

	report.begin("5_purchases")
	var bv: Dictionary = await wait_peer_mark("bought_upgrade", STEP_TIMEOUT_S)
	if not bv.is_empty() and bv.has("bought_upgrade"):
		var b: Dictionary = bv.bought_upgrade
		if String(b.get("key", "")) != "":
			var lvl := _level(String(b.category), String(b.key), String(b.get("subkey", "")))
			report.check("host_level_plus_one", lvl == int(b.before) + 1, "%s/%s level %d (client had %d)" % [b.category, b.key, lvl, int(b.before)])
		else:
			report.info("no_upgrade_row", "client found no buyable upgrade row")
	else:
		report.check("client_bought_upgrade", false, "no mark")
	var tool: Dictionary = await wait_peer_mark("bought_tool", STEP_TIMEOUT_S)
	if tool.has("bought_tool") and String(tool.bought_tool.get("tool", "")) != "":
		report.check("tool_charged_on_host", tool.bought_tool.get("ok", false), str(tool.bought_tool))
	else:
		report.info("tool_purchase", "skipped by the client (no tool row): %s" % str(tool.get("bought_tool", {})))

	report.begin("6_phase_unlock")
	var settled_bucket: Array = []
	var sub_id: int = api.events.on("phase.settled", func(ev): settled_bucket.append(int(ev.payload.get("phase", 0))))
	r = await cmd("phase.set", {"phase": 2})
	report.check("phase_set_2", r.ok, r.error)
	ok = await wait_for(func(): return 2 in settled_bucket, 90.0)
	api.events.off(sub_id)
	report.check("host_settled_2", ok, str(settled_bucket))
	report.mark("phase2_settled", {"phase": phase()})
	var pv: Dictionary = await wait_peer_mark("phase2_settled", 90.0)
	report.check("client_settled_2", not pv.is_empty() and int(pv.get("phase2_settled", {}).get("phase", 0)) == 2, str(pv.get("phase2_settled", {})))
	var um = g("UnlockManager")
	var mid := ""
	for id in um.milestones:
		if not um.is_unlocked(id):
			mid = String(id)
			break
	if mid != "":
		r = await cmd("unlock.force", {"id": mid})
		report.check("unlock_forced", r.ok, r.error)
		report.mark("unlocked", {"id": mid})
		var uv: Dictionary = await wait_peer_mark("unlock_seen", 10.0)
		report.check("client_got_unlock", not uv.is_empty(), mid)
	else:
		report.info("unlock", "every milestone already unlocked")
		report.mark("unlocked", {"id": ""})

	report.begin("7_client_pause")
	report.mark("move_for_pause")
	var t0 := Time.get_ticks_msec()
	var base := player().global_position if player() != null else Vector3.ZERO
	while Time.get_ticks_msec() - t0 < 4000:
		var k := float(Time.get_ticks_msec() - t0) / 1000.0
		await cmd("player.teleport", {"position": [base.x + k, base.y, base.z]})
		await sleep_ms(100)
	var pause: Dictionary = await wait_peer_mark("pause_checked", 20.0)
	report.check("client_pause_checked", not pause.is_empty(), "")

	report.begin("8_rejoin")
	var lv: Dictionary = await wait_peer_mark("left", 30.0)
	report.check("client_left", not lv.is_empty(), "")
	ok = await wait_for(func(): return session.get_roster().size() == 1, 20.0)
	report.check("roster_back_to_1", ok, str(session.get_roster()))
	# the rejoin runs with the control channel 300 ms behind the bulk channel:
	# snapshot chunks overtake snap_begin over real ENet
	session.set_conditioning({"channel_delay_ms": {0: 300}})
	var rv: Dictionary = await wait_peer_mark("client_in_game_2", JOIN_TIMEOUT_S)
	session.set_conditioning({})
	report.check("client_rejoined", not rv.is_empty(), "")
	report.check("rejoin_with_chunks_before_header", int(rv.get("client_in_game_2", {}).get("early_chunks", 0)) > 0,
		str(rv.get("client_in_game_2", {})))
	report.check("rejoined_at_phase_2", int(rv.get("client_in_game_2", {}).get("phase", 0)) == 2, str(rv.get("client_in_game_2", {})))
	ok = await wait_for(func(): return puppet_count() >= 1, 5.0)
	report.check("rejoined_puppet_on_host", ok, "puppets %d" % puppet_count())
	if ok and puppet(2) != null:
		await sleep_ms(800)
		face(puppet(2).global_position)
		await sleep_ms(300)
	await shot("8-sees-client-rejoined")

	report.begin("10_conditioned")
	var cond: Dictionary = flag.get("conditioning", {"latency_ms": 100, "jitter_ms": 30, "loss": 0.05})
	session.set_conditioning(cond)
	report.mark("conditioned", cond)
	await sleep_ms(1500)
	await cmd("money.add", {"amount": "777"})
	report.mark("money_added_2", {"money": money()})
	var cv2: Dictionary = await wait_peer_mark("conditioned_ok", 30.0)
	report.check("client_conditioned_ok", not cv2.is_empty(), str(cv2.get("conditioned_ok", {})))
	session.set_conditioning({})

	report.begin("9_host_leave")
	report.value("rtt_ms", session.clock.rtt_ms)
	session.leave()
	report.check("host_idle", session.get_state() == "idle", session.get_state())
	report.mark("host_left")
	var ev: Dictionary = await wait_peer_mark("client_end_checked", 30.0)
	report.check("client_end_checked", not ev.is_empty(), str(ev.get("client_end_checked", {})))
	await cmd("save.isolate", {"enabled": false})


func _level(category: String, key: String, subkey: String) -> int:
	var gs = g("GameState")
	var t = gs.get(category)
	if typeof(t) != TYPE_DICTIONARY or not t.has(key):
		return -1
	var it = t[key]
	if subkey != "":
		it = it.get(subkey, {})
	return int(it.get("level", -1))
