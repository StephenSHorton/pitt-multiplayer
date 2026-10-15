extends RefCounted
## Gameplay suite: starts an ISOLATED new game and tests spawning, entity ids,
## money and items through the API.
## Isolation (docs/API-DESIGN.md 9.3):
##   1. achievements.suppress  -> every achievement id marked granted for the session
##   2. save.isolate {enabled, path:"user://pittapi/test/run.save"}
##      -> save_locked + autosave off, re-asserted every frame (the elevator's
##         _ready clears save_locked), and a non-slot active path, so
##         _write_slot_index() never touches profile.cfg
##   2b. presence.suppress -> Steam rich presence cleared and not pushed again
##   3. reset run state like _start_sandbox_fresh, without clear_sandbox_slot()
##   4. main_menu._pending_new_game = true; _launch_game(world.tscn)

const Serial = preload("../../PittAPI/core/serial.gd")
const TEST_SAVE := "user://pittapi/test/run.save"


func run(t, api, host: Node) -> void:
	var tree: SceneTree = host.get_tree()
	var root := tree.root
	var r = api.commands.execute("achievements.suppress", {})
	t.check("isolation.achievements_suppressed", r.ok, r.error)
	# friends must not see the test world's fake money in rich presence
	r = api.commands.execute("presence.suppress", {"enabled": true})
	t.check("isolation.presence_suppressed", r.ok, r.error)
	r = api.commands.execute("save.isolate", {"enabled": true, "path": TEST_SAVE})
	t.check("isolation.save_isolated", r.ok, r.error)
	var sm = root.get_node("SaveManager")
	var gs = root.get_node("GameState")
	var gp = root.get_node("GameProgression")
	t.check("isolation.save_locked", bool(sm.save_locked) and not bool(sm.autosave_enabled), "")
	t.eq("isolation.active_path", String(sm.active_save_path), TEST_SAVE)
	t.eq("isolation.not_a_slot", int(sm.slot_from_path(sm.active_save_path)), -1)

	var menu = tree.get_first_node_in_group("MainMenu")
	if menu == null or not menu.has_method("_launch_game") or not ("_pending_new_game" in menu):
		t.fatal("main menu not found or its contract changed")
		return
	gs.sandbox_mode = false
	gp.reset_run_state()
	gp.current_phase = 1   # PHASE_1: skips the 17 s elevator intro
	sm.pending_camera_data = {}
	sm.should_load_on_ready = false
	menu._pending_new_game = true
	menu._launch_game("res://scenes/world.tscn")

	var ev = await api.events.wait("world.ready", 150.0)
	if ev == null:
		t.fatal("world.ready did not arrive within 150 s")
		return
	t.check("world.ready_new_game", ev.payload.new_game == true, JSON.stringify(ev.payload))
	t.eq("world.ready_save_key", String(ev.payload.save_key), "run")
	# let the world settle (pools, starter crates)
	for i in 30:
		await tree.physics_frame
	t.check("isolation.still_locked_after_elevator", bool(sm.save_locked), "")

	var player = api.player.get_local()
	t.check("player.local_exists", player != null, "")
	t.check("player.ready_event", api.events.last("player.ready") != null, "")
	t.check("spawn.ready", api.spawn.is_ready(), "")
	var pools: Array = api.spawn.pools()
	t.check("spawn.pools_nonempty", pools.size() > 10, "%d pools" % pools.size())
	t.check("spawn.has_duck_pool", "duck" in pools, "")

	# S1: does take_over_path work in the release build? The HUD must run ExampleMod's extension.
	var hud = tree.get_first_node_in_group("HUD")
	var ext_script = api.extensions.applied_script("res://scripts/hud.gd")
	t.check("S1.extension_active_on_hud", hud != null and ext_script != null and hud.get_script() == ext_script,
		"hud script=%s" % (str(hud.get_script()) if hud != null else "no HUD"))

	# --- spawn / despawn / ids
	var spawned: Array = []
	var despawned: Array = []
	var s1 = api.events.on("entity.spawned", func(e): spawned.append(e))
	var s2 = api.events.on("entity.despawned", func(e): despawned.append(e))
	var at: Vector3 = api.player.get_look_point(2.0) + Vector3(0, 1.0, 0)
	r = api.spawn.spawn("duck", at)
	t.check("spawn.duck_ok", r.done and r.ok, "%s %s" % [r.code, r.error])
	var eid := int(r.value.entity_id) if r.ok else 0
	t.check("spawn.entity_id_assigned", eid >= 1000, str(eid))
	var ev_ids: Array = []
	for e in spawned:
		ev_ids.append(int(e.payload.entity_id))
	t.check("spawn.entity_spawned_event", eid in ev_ids, str(ev_ids))
	t.eq("spawn.describe_pool", String(api.entities.describe(eid).get("pool_id", "")), "duck")
	var node = api.entities.get_node(eid)
	t.check("spawn.node_resolves", node != null and node.is_inside_tree(), "")
	r = api.spawn.despawn(eid)
	t.check("spawn.despawn_ok", r.ok, r.error)
	var dids: Array = []
	for e in despawned:
		dids.append(int(e.payload.entity_id))
	t.check("spawn.entity_despawned_event", eid in dids, str(dids))
	t.check("spawn.id_gone", api.entities.get_node(eid) == null, "")
	r = api.spawn.spawn("duck", at)
	var eid2 := int(r.value.entity_id) if r.ok else 0
	t.check("spawn.respawn_new_id", r.ok and eid2 != eid and eid2 > 0, "%d vs %d" % [eid, eid2])
	if r.ok:
		api.spawn.despawn(eid2)

	# --- reconciler: a game-side spawn gets an id within 0.3 s
	var pm = root.get_node("ObjectPoolManager")
	var game_node = pm.spawn("duck", at + Vector3(0.5, 0, 0), Vector3.ZERO)
	if game_node == null:
		t.check("reconciler.game_spawn", false, "ObjectPoolManager.spawn returned null")
	else:
		var t0 := Time.get_ticks_msec()
		var found: bool = await t.wait_until(tree, func(): return api.entities.id_of(game_node) != 0, 0.3)
		t.check("reconciler.game_spawn_tracked", found, "after %d ms" % (Time.get_ticks_msec() - t0))
		var gid: int = api.entities.id_of(game_node)
		var by_game := false
		for e in spawned:
			if int(e.payload.entity_id) == gid and e.source == "game":
				by_game = true
		t.check("reconciler.spawned_event_source_game", by_game, "")
		pm.recycle(game_node)
		var gone: bool = await t.wait_until(tree, func(): return api.entities.get_node(gid) == null, 0.5)
		t.check("reconciler.game_recycle_detected", gone, "")
	api.events.off(s1)
	api.events.off(s2)

	# --- money
	var money_events: Array = []
	var s3 = api.events.on("money.changed", func(e): money_events.append(e))
	var old: String = api.state.get_money()
	r = api.state.add_money(100)
	t.check("money.add_ok", r.ok, r.error)
	t.eq("money.add_result", api.state.get_money(), Serial.digits_add(old, "100"))
	var last = money_events.back() if not money_events.is_empty() else null
	t.check("money.changed_event", last != null and last.payload.delta == "100" and int(last.payload.sign) == 1,
		JSON.stringify(last.payload) if last != null else "no event")
	var too_much := Serial.digits_add(api.state.get_money(), "1")
	r = api.state.spend(too_much)
	t.check("money.spend_above_balance_fails", r.done and not r.ok, r.error)
	var big := "1000000000000000000000"
	r = api.state.set_money(big)
	t.check("money.set_big_ok", r.ok, r.error)
	t.eq("money.set_big_roundtrip", api.state.get_money(), big)
	api.events.off(s3)

	# --- combo subscription (feeding is not simulated)
	var cid: int = api.events.on("combo.*", func(_e): pass)
	t.check("combo.subscribe", cid > 0, "")
	api.events.off(cid)

	# --- item purchase -> item.level_changed
	var level_events: Array = []
	var s4 = api.events.on("item.level_changed", func(e): level_events.append(e))
	var bought_key := ""
	for key in api.state.get_item_keys("upgrades"):
		var it: Dictionary = api.state.get_item("upgrades", key)
		if it.get("enabled", false) and int(it.get("level", 0)) < it.get("prices", []).size() and key != "remote_tier":
			bought_key = key
			break
	if bought_key == "":
		t.skip("items.buy_upgrade", "no enabled upgrade with a next level")
	else:
		var lvl_before := int(api.state.get_item("upgrades", bought_key).level)
		r = api.state.buy("upgrades", bought_key)
		t.check("items.buy_ok", r.ok, "%s: %s" % [bought_key, r.error])
		t.eq("items.level_incremented", int(api.state.get_item("upgrades", bought_key).level), lvl_before + 1)
		await tree.process_frame
		await tree.process_frame
		var seen := false
		for e in level_events:
			if e.payload.category == "upgrades" and e.payload.key == bought_key:
				seen = true
		t.check("items.level_changed_event", seen, "%d events" % level_events.size())
	api.events.off(s4)

	# --- hud passthroughs
	var errs_before: int = api.recent_errors(500).size()
	t.check("hud.banner_in_world", api.hud.banner("PittAPI test"), "")
	t.check("hud.floating_text_in_world", api.hud.floating_text("PittAPI", Color.GOLD), "")
	t.eq("hud.no_new_errors", api.recent_errors(500).size(), errs_before)

	# --- physics pin
	r = api.commands.execute("perf.pin_physics", {"hz": 60})
	t.check("perf.pin_ok", r.ok, r.error)
	t.eq("perf.ticks_60", Engine.physics_ticks_per_second, 60)

	# --- player
	var pos_before: Vector3 = api.player.get_position()
	r = api.player.teleport(pos_before + Vector3(0, 0.5, 0))
	t.check("player.teleport_ok", r.ok, r.error)
	t.check("player.held_is_int", typeof(api.player.get_held()) == TYPE_INT, "")

	# --- safety
	var st = root.get_node("Steamworks")
	var all_granted := true
	for id in st._probe_ids:
		if not st._granted.get(id, false):
			all_granted = false
	t.check("isolation.achievements_all_granted", all_granted, "")
	t.check("isolation.no_test_save_written", not FileAccess.file_exists(TEST_SAVE) and not FileAccess.file_exists(TEST_SAVE + ".tmp"), "")
	t.check("isolation.save_still_locked", bool(sm.save_locked), "")
	t.check("errors.none_from_pittapi", api.recent_errors(500, "PittAPI").is_empty(),
		JSON.stringify(api.recent_errors(5, "PittAPI")))
