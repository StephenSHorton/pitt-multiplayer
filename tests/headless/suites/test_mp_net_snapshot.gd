extends "res://tests/test_case.gd"
## Snapshot: keys = what the game restores; strip table (9.1); client steps in
## order (isolate -> write -> achievements -> detach -> launch); isolation path
## never slot-like (R14); joins within 2 s share one build; encrypted file.

const MpRig = preload("res://tests/fakes/mp_net/mp_rig.gd")
const Snapshot = preload("res://gamedir/mods/PittMultiplayer/sync/snapshot.gd")
const FakeAdapter = preload("res://tests/fakes/mp_net/fake_game_adapter.gd")

var rig = null


func before_all() -> void:
	rig = MpRig.new(tree, runner)


func after_all() -> void:
	await rig.cleanup()


func test_build_and_strip() -> void:
	var a = FakeAdapter.new("snap")
	a.enter_world(2, runner)
	a.fgs().set_money_int(999)
	a.fum().force_unlock("unlock_fan")
	var s := Snapshot.new(a)
	var b: Dictionary = s.build(3, "00ff", 12)
	var d = JSON.parse_string(b.text)
	for k in Snapshot.KEYS:
		assert_true(d.has(k), "snapshot has %s" % k)
	assert_eq(Snapshot.validate(d), "", "valid")
	# MP2 strip table (MP2-DESIGN 3.8)
	assert_eq(d.object_pools, {}, "object_pools empty (objects come in the world snapshot)")
	assert_eq(d.press_spawned, false, "press flag from the host's collectors (the fake has no press)")
	assert_eq(d.trading_terminal_spawned, false, "terminal flag from the host")
	assert_eq(d.bowling_set_spawned, false, "bowling set flag from the host")
	assert_eq(d.pickaxe, {}, "pickaxe state from the host (the fake has none)")
	assert_eq(float(d.game_state.bank), 123.0, "bank kept (shared, D14)")
	assert_eq(int(d.game_state.mining_bank), 7, "mining bank kept (shared, D14)")
	assert_eq(d.game_state.panel_stack, [], "panel stack per player (D13)")
	var kept := Snapshot.strip({"press_spawned": true, "trading_terminal_spawned": true, "bowling_set_spawned": true,
		"pickaxe": {"tier": 3}, "object_pools": {"duck": {}}, "game_state": {"bank": 5.0, "panel_stack": ["x"]}})
	assert_true(kept.press_spawned and kept.trading_terminal_spawned and kept.bowling_set_spawned,
		"the host's fixtures are kept (the joiner's load path builds them)")
	assert_eq(int(kept.pickaxe.tier), 3, "pickaxe kept")
	assert_eq(kept.object_pools, {}, "pools stripped")
	assert_eq(float(kept.game_state.bank), 5.0, "bank kept")
	assert_eq(kept.game_state.panel_stack, [], "rack stripped")
	assert_eq(String(d.game_state.money), "999", "money kept")
	assert_true(d.has("workbenches"), "workbenches KEPT (benches restore from it)")
	assert_has(d.unlocked_milestones, "unlock_fan", "unlocks")
	assert_eq(int(d.phase), 2, "phase")
	assert_false(d.has("music"), "music omitted")
	assert_eq(int(d.pitt_mp.slot), 3, "pitt_mp tag (unknown keys are ignored by the game)")
	var pos := Vector3(d.player_position.x, d.player_position.y, d.player_position.z)
	# the fake world has no floor: no candidate validates, the fallback is the
	# host's last safe position, lifted 0.3 m (validated spawns: test_mp_world_avatar_view)
	assert_true(pos.is_equal_approx(Vector3(3, 1.3, 4)),
		"no world to validate against: the host's safe position + 0.3 m: %s" % str(pos))
	var b2: Dictionary = s.build(4, "00ff", 13)
	assert_eq(s.builds, 1, "joins within 2 s share one collector run")
	assert_ne(int(b2.xfer), int(b.xfer), "each transfer has its own id")
	a.free_all()


func test_reassembly_rejects_tampering() -> void:
	var a = FakeAdapter.new("snap2")
	a.enter_world(1, runner)
	var s := Snapshot.new(a)
	var b: Dictionary = s.build(2, "ab", 1)
	var rx = Snapshot.begin_receive({"xfer": b.xfer, "bytes": b.zbytes.size(), "raw": b.raw_size, "chunks": b.chunks.size(),
		"sha256": b.sha256})
	for i in b.chunks.size():
		rx.parts[i] = b.chunks[i]
	rx.ended = true
	var r: Dictionary = rx.assemble()
	assert_true(bool(r.ok), "assembles: %s" % r.get("error", ""))
	var rx2 = Snapshot.begin_receive({"xfer": 1, "bytes": b.zbytes.size(), "raw": b.raw_size, "chunks": b.chunks.size(),
		"sha256": "00" + String(b.sha256).substr(2)})
	for i in b.chunks.size():
		rx2.parts[i] = b.chunks[i]
	rx2.ended = true
	assert_false(bool(rx2.assemble().ok), "sha256 mismatch rejected")
	assert_eq(Snapshot.begin_receive({"chunks": 0, "raw": 10}), null, "bad header rejected")
	assert_ne(Snapshot.validate({"phase": 0}), "", "missing keys / phase 0 rejected")
	a.free_all()


func test_session_path_never_slot_like() -> void:
	var p := Snapshot.session_path("user://pittapi/mods/PittMultiplayer", "deadBEEF..//x")
	assert_true(p.begins_with("user://pittapi/mods/PittMultiplayer/session/"), "under the mod data dir")
	assert_true(p.get_file().begins_with("mp_") and p.ends_with(".save"), "mp_<sid>.save: %s" % p)
	assert_false(p.contains(".."), "no traversal")
	assert_false(p.get_file().begins_with("savegame") or p.get_file().begins_with("sandbox"), "not slot-like (R14)")


func test_client_steps_in_order() -> void:
	await rig.cleanup()
	var h = rig.add_host({}, 1)
	await rig.until(func(): return h.session.get_state() == "in_game")
	var c = rig.make_peer("ordered")
	var order: Array = []
	c.api.commands.register("achievements.suppress", func(_a, _ctx):
		order.append("suppress")
		return {}, {"scope": "local", "schema": {}})
	c.adapter.simulate_load = true
	c.session.state_changed.connect(func(s, _i):
		if s == "loading" and c.adapter.launches.size() == 1 and not ("launch" in order):
			order.append("launch"))
	c.lobby.enter({"is_owner": false}, {"kind": "loopback", "hub": rig.hub})
	await rig.until(func(): return c.session.get_state() == "in_game", 5.0)
	assert_true(c.api.isolate_calls.size() >= 1, "isolated")
	var path: String = c.api.isolate_calls[0].path
	assert_true(path.contains("/session/mp_"), "session file path: %s" % path)
	assert_true(FileAccess.file_exists(path), "written")
	var raw := FileAccess.get_file_as_string(path)
	assert_false(raw.begins_with("{"), "stored encrypted (not plain JSON)")
	var f := FileAccess.open_encrypted_with_pass(path, FileAccess.READ, c.adapter.save_password())
	assert_true(f != null and f.get_as_text().begins_with("{"), "readable with the game's password")
	if f != null:
		f.close()
	assert_eq(order.front() if not order.is_empty() else "", "suppress", "achievements suppressed before the load: %s" % str(order))
	assert_eq(c.adapter.launches.size(), 1, "launched once")
	assert_eq(c.adapter.world_nodes.MainMenu._pending_new_game, false, "_pending_new_game = false (load path)")
	assert_eq(c.adapter.nodes.SaveManager.should_load_on_ready, true, "should_load_on_ready")
	c.session.leave()
	var gone: bool = await rig.until(func(): return not FileAccess.file_exists(path), 5.0)
	assert_true(gone, "session file deleted at the end (after the save hold)")
