extends RefCounted
## Menu suite: runs on the first main menu. Read-only with respect to the game:
## it only writes PittAPI's own files (keybinds.cfg, config/PittAPITests.cfg).


func run(t, api, host: Node) -> void:
	var tree: SceneTree = host.get_tree()
	var sc = api.events.last("scene.changed")
	t.check("bridge.scene_changed_main_menu", sc != null and sc.payload.kind == "main_menu",
		JSON.stringify(sc.payload) if sc != null else "no scene.changed event")
	t.check("state.phase_is_int", typeof(api.state.get_phase()) == TYPE_INT and api.state.get_phase() >= 0, str(api.state.get_phase()))
	var money: String = api.state.get_money()
	t.check("state.money_is_digits", money.is_valid_int() and not money.begins_with("-"), money)
	t.check("state.not_in_world", not api.state.is_in_world(), "")
	t.eq("saves.slot_infos_10", api.saves.get_slot_infos().size(), 10)
	t.check("spawn.not_ready_on_menu", not api.spawn.is_ready(), "")
	var r = api.spawn.spawn("duck", Vector3(0, 5, 0))
	t.check("spawn.unavailable_on_menu", r.done and not r.ok and r.code == "ERR_UNAVAILABLE", "%s %s" % [r.code, r.error])

	# input round trip, and the game's keybindings.cfg must not change
	var kb_path := "user://keybindings.cfg"
	var kb_before := FileAccess.get_file_as_bytes(kb_path) if FileAccess.file_exists(kb_path) else PackedByteArray()
	var action: String = api.input.register_action("test_key", KEY_F10, "Test key")
	t.check("input.action_created", action != "" and InputMap.has_action(action), action)
	t.eq("input.rebind_ok", api.input.rebind("test_key", KEY_F11), OK)
	var cfg := ConfigFile.new()
	var kp: String = api.pittapi_dir().path_join("keybinds.cfg")
	var loaded := cfg.load(kp) == OK
	t.check("input.persisted", loaded and int(cfg.get_value("PittAPITests", "test_key", 0)) == KEY_F11, kp)
	var im = tree.root.get_node_or_null("InputManager")
	t.check("input.not_in_game_bindings", im != null and not im.current_bindings.has(action), "")
	var kb_after := FileAccess.get_file_as_bytes(kb_path) if FileAccess.file_exists(kb_path) else PackedByteArray()
	t.check("input.keybindings_cfg_unchanged", kb_before == kb_after, "%d -> %d bytes" % [kb_before.size(), kb_after.size()])

	# config round trip
	api.config.define("probe", 3, {"min": 0, "max": 10})
	t.eq("config.default", api.config.get_value("probe"), 3)
	t.eq("config.reject_out_of_range", api.config.set_value("probe", 99), ERR_INVALID_PARAMETER)
	t.eq("config.set", api.config.set_value("probe", 7), OK)
	api.config.flush()
	var c2 := ConfigFile.new()
	c2.load(api.pittapi_dir().path_join("config/PittAPITests.cfg"))
	t.eq("config.persisted", c2.get_value("general", "probe", -1), 7)
	# restore the default so the next run starts clean (config.default would read 7)
	api.config.set_value("probe", 3)
	api.config.flush()

	# commands
	var names: Array = []
	for d in api.commands.list():
		names.append(d.name)
	var core_cmds := ["money.add", "money.spend", "money.set", "bank.set", "item.buy", "phase.set", "unlock.force",
		"unlock.register_milestone", "entity.spawn", "entity.despawn", "entity.set_transform", "entity.impulse",
		"player.teleport", "player.impulse", "achievements.suppress", "perf.pin_physics", "save.isolate"]
	var missing: Array = []
	for n in core_cmds:
		if not (n in names):
			missing.append(n)
	t.check("commands.core_registered", missing.is_empty(), "missing=%s" % str(missing))
	t.check("commands.example_registered", "ExampleMod.double_money" in names, "")

	# toast renders on the main menu
	var toast: Control = api.hud.toast("PittAPITests: menu suite running")
	await tree.process_frame
	t.check("hud.toast_renders", toast != null and toast.is_inside_tree() and toast.is_visible_in_tree(), "")
	t.check("hud.banner_noop_outside_world", api.hud.banner("x") == false, "")

	# event bus round trip
	var got: Array = []
	var id: int = api.events.on("mod.PittAPITests.ping", func(ev): got.append(ev))
	t.eq("events.emit_ok", api.events.emit("mod.PittAPITests.ping", {"n": 1}), OK)
	t.check("events.ping_received", got.size() == 1 and got[0].payload.n == 1 and got[0].source == "mod:PittAPITests", str(got))
	t.eq("events.foreign_namespace_refused", api.events.emit("mod.ExampleMod.fake", {}), ERR_UNAUTHORIZED)
	api.events.off(id)

	# net stub
	t.check("net.single_player", api.net.is_authority() and api.net.local_peer_id() == 1 and not api.net.is_multiplayer(), "")
	var snap: Dictionary = api.state.snapshot()
	t.check("state.snapshot_json_safe", JSON.parse_string(JSON.stringify(snap)) != null and snap.has("money"), "")
	t.check("errors.none_from_pittapi", api.recent_errors(200, "PittAPI").is_empty(),
		JSON.stringify(api.recent_errors(5, "PittAPI")))
