extends "res://tests/test_case.gd"


## Pretends to be a remote host: completes envelopes one frame later, after a
## JSON round trip (the future wire format).
class FakeRemoteAuthority extends "res://gamedir/mods/PittAPI/core/authority.gd":
	var tree: SceneTree
	var sent: Array = []
	var hosting := false   # true while the fake runs the envelope "on the host"

	func get_kind() -> String:
		return "fake_remote"

	func is_authority() -> bool:
		return hosting

	func local_peer_id() -> int:
		return 7

	func submit(envelope: Dictionary) -> void:
		sent.append(envelope.duplicate(true))
		_later(envelope)

	func _later(envelope: Dictionary) -> void:
		await tree.process_frame
		var back: Dictionary = JSON.parse_string(JSON.stringify(envelope))
		back["id"] = int(back.id)
		back["origin"] = 999   # a lying client: the host must use the transport's sender id
		hosting = true
		var res: Dictionary = commands.dispatch_remote(back, 7)
		hosting = false
		complete(back, res)


func before_all() -> void:
	core.commands.register("t.echo", func(args, ctx): return {"x": args.x, "peer": ctx.origin_peer},
		{"schema": {"x": TYPE_INT, "y?": TYPE_STRING}})
	core.commands.register("t.cheat", func(_a, _c): return 1, {"cheat": true, "schema": {}})
	core.commands.register("t.failing", func(_a, ctx): return ctx.fail("nope", "ERR_FAILED"), {})
	core.commands.register("t.erroring", _erroring, {})


func _erroring(_a, _c):
	var n = null
	n.boom()
	return 1


func after_all() -> void:
	for n in ["t.echo", "t.cheat", "t.failing", "t.erroring"]:
		core.commands.unregister(n)


func test_schema_validation() -> void:
	var r = core.commands.execute("t.echo", {"x": 3})
	assert_true(r.done and r.ok, "valid args")
	assert_eq(r.value.x, 3, "value")
	r = core.commands.execute("t.echo", {})
	assert_true(r.done and not r.ok and r.code == "ERR_INVALID", "missing arg: %s" % r.error)
	r = core.commands.execute("t.echo", {"x": "three"})
	assert_eq(r.code, "ERR_INVALID", "wrong type")
	r = core.commands.execute("t.echo", {"x": 1, "zzz": 2})
	assert_eq(r.code, "ERR_INVALID", "unknown arg")
	r = core.commands.execute("t.echo", {"x": 2.0})
	assert_true(r.ok, "integral float accepted as int (JSON numbers)")
	r = core.commands.execute("t.echo", {"x": 1, "y": Callable()})
	assert_eq(r.code, "ERR_INVALID", "non JSON-safe args rejected")
	r = core.commands.execute("no.such", {})
	assert_eq(r.code, "ERR_UNKNOWN", "unknown command")


func test_handler_failures() -> void:
	var r = core.commands.execute("t.failing", {})
	assert_true(not r.ok and r.error == "nope", "ctx.fail")
	r = assert_error_logged(func(): return core.commands.execute("t.erroring", {}), "handler error")
	assert_true(r.done and not r.ok and r.code == "ERR_FAILED", "runtime error -> ok=false")


func test_cheat_gating() -> void:
	var saved = core.opts.get("settings", {})
	core.opts["settings"] = {"cheats_allowed": false}
	var r = core.commands.execute("t.cheat", {})
	assert_eq(r.code, "ERR_DENIED", "cheats disabled")
	core.opts["settings"] = saved
	r = core.commands.execute("t.cheat", {})
	assert_true(r.ok, "cheats allowed by default")


func test_local_authority_sync() -> void:
	var executed := capture("command.executed")
	var r = core.commands.execute("t.echo", {"x": 5})
	assert_true(r.done, "local: done on return")
	assert_eq(r.value.peer, 1, "origin peer 1")
	assert_true(executed.size() == 1 and executed[0].payload.name == "t.echo" and executed[0].payload.ok, "command.executed emitted")


func test_mod_namespace() -> void:
	var ctx = core.loader.mods["ExampleMod"].ctx
	assert_eq(ctx.commands.register("other.thing", func(_a, _c): return 1), ERR_UNAUTHORIZED, "mods only register <id>.*")
	assert_eq(ctx.commands.register("ExampleMod.thing", func(_a, _c): return 1), OK, "own prefix ok")
	assert_eq(ctx.commands.register("money.add", func(_a, _c): return 1), ERR_UNAUTHORIZED, "cannot hijack core")
	ctx.commands.unregister("ExampleMod.thing")


func test_remote_authority_async() -> void:
	var fake := FakeRemoteAuthority.new()
	fake.tree = tree
	var local = core.authority
	core._set_authority(fake)
	var r = core.commands.execute("t.echo", {"x": 9})
	assert_false(r.done, "remote: not done on return")
	assert_eq(fake.sent.size(), 1, "envelope submitted")
	if not fake.sent.is_empty():
		assert_eq(fake.sent[0].v, 1, "envelope version")
		assert_eq(fake.sent[0].origin, 7, "origin = local peer")
	await r.completed
	assert_true(r.done and r.ok and r.value.x == 9, "completed next frame")
	assert_eq(r.value.peer, 7, "origin comes from the transport sender, not envelope.origin")
	var r2 = await core.commands.execute_async("t.echo", {"x": 11})
	assert_true(r2.done and r2.value.x == 11, "execute_async awaits completion")
	var r3 = await core.commands.execute("t.echo", {"x": 12}).wait()
	assert_true(r3.ok, "result.wait()")
	core._set_authority(local)
	assert_true(core.commands.execute("t.echo", {"x": 1}).done, "local authority restored")


func test_core_commands_listed() -> void:
	var names: Array = []
	for d in core.commands.list():
		names.append(d.name)
	for n in ["money.add", "money.spend", "money.set", "bank.set", "item.buy", "phase.set", "unlock.force",
			"unlock.register_milestone", "entity.spawn", "entity.despawn", "entity.set_transform", "entity.impulse",
			"player.teleport", "player.impulse", "achievements.suppress", "perf.pin_physics", "save.isolate"]:
		assert_has(names, n, "core command")
	assert_true(core.commands.describe("money.set").cheat, "money.set is a cheat")


func test_achievements_suppress() -> void:
	var st = tree.root.get_node("Steamworks")
	var r = core.commands.execute("achievements.suppress", {})
	assert_true(r.ok and r.value.suppressed == 3, "suppressed all probe ids")
	st.unlock_achievement("ACH_A")
	assert_eq(st.unlock_calls.size(), 0, "no real unlock goes through")


func test_phase_and_unlock_commands() -> void:
	var r = core.commands.execute("phase.set", {"phase": 5})
	assert_eq(r.code, "ERR_DENIED", "ending refused without allow_ending")
	r = core.commands.execute("phase.set", {"phase": 2})
	assert_eq(r.code, "ERR_UNAVAILABLE", "needs a world")
	r = core.commands.execute("unlock.force", {"id": "nope"})
	assert_eq(r.code, "ERR_INVALID", "unknown milestone")
	r = core.commands.execute("unlock.force", {"id": "unlock_luck"})
	assert_true(r.ok and core.state.is_unlocked("unlock_luck"), "force unlock")
	var ctx = core.loader.mods["ExampleMod"].ctx
	r = ctx.state.register_milestone("my_goal", {"type": "stat_threshold", "stat": "total_money_gained", "threshold": 5, "action": {}})
	assert_true(r.ok and r.value.id == "mod.ExampleMod.my_goal", "namespaced milestone: %s" % r.error)
	assert_true(tree.root.get_node("UnlockManager").milestones.has("mod.ExampleMod.my_goal"), "inserted")
	r = ctx.state.register_milestone("bad", {"type": "nonsense", "action": {}})
	assert_eq(r.code, "ERR_INVALID", "bad milestone type")


func test_save_isolate() -> void:
	var sm = tree.root.get_node("SaveManager")
	var r = core.commands.execute("save.isolate", {"enabled": true, "path": "user://savegame.save"})
	assert_eq(r.code, "ERR_DENIED", "slot paths refused")
	r = core.commands.execute("save.isolate", {"enabled": true, "path": "user://pittapi/test/run.save"})
	assert_true(r.ok, "isolate")
	sm.save_locked = false     # what the elevator's _ready does
	sm.autosave_enabled = true
	await tree.process_frame
	await tree.process_frame
	assert_true(sm.save_locked and not sm.autosave_enabled, "re-asserted every frame")
	core.commands.execute("save.isolate", {"enabled": false})
	sm.save_locked = false
	sm.autosave_enabled = true
	sm.set_active_save_path("user://savegame.save")
	assert_false(FileAccess.file_exists("user://pittapi/test/run.save"), "nothing written")


func test_dispatch_gates_for_remote_envelopes() -> void:
	var env := {"v": 1, "id": 0, "name": "t.cheat", "args": {}, "mod": "ExampleMod", "origin": 1, "t": 0}
	var saved = core.opts.get("settings", {})
	core.opts["settings"] = {"cheats_allowed": false}
	var res: Dictionary = core.commands.dispatch_remote(env, 5)
	assert_eq(res.code, "ERR_DENIED", "cheat gate applies to remote envelopes")
	core.opts["settings"] = saved
	core.contract.features["bank"] = false
	res = core.commands.dispatch_remote({"name": "bank.set", "args": {"amount": 1.0}}, 5)
	assert_eq(res.code, "ERR_UNAVAILABLE", "feature gate applies to remote envelopes")
	core.contract.features["bank"] = true
	res = core.commands.dispatch_remote({"name": "t.echo", "args": {"x": 1, "y": Callable()}}, 5)
	assert_eq(res.code, "ERR_INVALID", "JSON-safety applies to remote envelopes")
	res = core.commands.dispatch_remote({"name": "t.echo", "args": {"x": 1}, "origin": 1}, 5)
	assert_true(res.ok and res.value.peer == 5, "remote origin = sender: %s" % str(res))
	res = core.commands.dispatch_remote({"name": "t.echo", "args": {"x": 1}}, 0)
	assert_eq(res.code, "ERR_DENIED", "sender id required")
	res = core.commands.dispatch_remote({"name": "unlock.register_milestone", "args": {"id": "x",
		"def": {"type": "phase_reached", "phase": 1, "action": {}}}, "mod": "ExampleMod"}, 5)
	assert_false(res.ok, "remote peers cannot register milestones under a mod's name")
	assert_false(tree.root.get_node("UnlockManager").milestones.has("mod.ExampleMod.x"), "nothing inserted")


func test_authority_only_refused_on_client() -> void:
	var fake := FakeRemoteAuthority.new()
	fake.tree = tree
	var local = core.authority
	core._set_authority(fake)
	var res: Dictionary = core.commands.dispatch_envelope({"name": "t.echo", "args": {"x": 1}, "origin": 7})
	assert_eq(res.code, "ERR_DENIED", "authority_only command refused on a non-authority peer")
	core._set_authority(local)


func test_cheat_commands_stamp_the_save() -> void:
	core._cheat_used = false
	var ctx = core.loader.mods["ExampleMod"].ctx
	assert_eq(ctx.commands.register("ExampleMod.t_cheat", func(_a, _c): return 1, {"cheat": true, "schema": {}}), OK, "mod cheat registered")
	var r = ctx.commands.execute("ExampleMod.t_cheat", {})
	assert_true(r.ok and core._cheat_used, "a mod's cheat command stamps the session")
	ctx.commands.unregister("ExampleMod.t_cheat")
	core.on_world_exited()
	assert_false(core._cheat_used, "reset on world exit")
	core._cheat_used = true
	core.on_save_loaded("savegame_9")
	assert_false(core._cheat_used, "reset on save load")
	core.sidecar.load_key("savegame")


func test_milestone_def_validation() -> void:
	var ctx = core.loader.mods["ExampleMod"].ctx
	var bad := [
		{"type": "stat_threshold", "stat": "total_money_gained", "action": {}},
		{"type": "stat_threshold", "threshold": 5, "action": {}},
		{"type": "combined_stat_threshold", "threshold": 5, "stats": [{"weight": 1}], "action": {}},
		{"type": "phase_reached", "action": {}},
		{"type": "group_all_flagged", "action": {}},
		{"type": "group_flagged_count", "group": "g", "action": {}},
		{"type": "floor_product_count", "threshold": "x", "action": {}},
		{"type": "state_flag", "action": {}},
		{"type": "phase_reached", "phase": 2, "requires": "nope", "action": {}},
	]
	var i := 0
	for d in bad:
		var r = ctx.state.register_milestone("bad_%d" % i, d)
		assert_eq(r.code, "ERR_INVALID", "invalid def %s: %s" % [str(d), r.error])
		i += 1
	var r = ctx.state.register_milestone("combo_ok", {"type": "combined_stat_threshold", "threshold": 3,
		"stats": [{"stat": "a"}, {"stat": "b", "weight": 2}], "action": {}})
	assert_true(r.ok, "valid combined def: %s" % r.error)


func test_save_isolate_restores_and_guards_ending() -> void:
	var sm = tree.root.get_node("SaveManager")
	sm.set_active_save_path("user://savegame_3.save")
	sm.save_locked = false
	sm.autosave_enabled = true
	var r = core.commands.execute("save.isolate", {"enabled": true})
	assert_true(r.ok and String(r.value.path).begins_with("user://pittapi/"), "default isolated path: %s" % str(r.value))
	sm.set_active_save_path("user://savegame.save")   # what main_menu.set_active_slot does
	await tree.process_frame
	assert_true(String(sm.active_save_path).begins_with("user://pittapi/"), "path re-asserted every frame")
	core.bridge.in_world = true
	r = core.commands.execute("phase.set", {"phase": 5, "allow_ending": true})
	assert_eq(r.code, "ERR_DENIED", "ending refused while isolated")
	core.bridge.in_world = false
	r = core.commands.execute("save.isolate", {"enabled": false})
	assert_true(r.ok, "disable")
	assert_eq(String(sm.active_save_path), "user://savegame_3.save", "previous path restored")
	assert_true(not sm.save_locked and sm.autosave_enabled, "previous flags restored")
	sm.set_active_save_path("user://savegame.save")
	r = core.commands.execute("save.isolate", {"enabled": true, "path": "user://pittapi/sandbox.save"})
	assert_eq(r.code, "ERR_DENIED", "slot-like names refused")


func test_presence_suppress() -> void:
	var st = tree.root.get_node("Steamworks")
	var r = core.commands.execute("presence.suppress", {"enabled": true})
	assert_true(r.ok and st.presence_clears == 1, "presence cleared")
	st._presence_accum = 0.0
	await tree.process_frame
	assert_true(st._presence_accum < 0.0, "presence timer held back every frame")
	core.commands.execute("presence.suppress", {"enabled": false})
	assert_eq(st._presence_accum, 0.0, "restored")
