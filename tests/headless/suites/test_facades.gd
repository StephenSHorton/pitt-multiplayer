extends "res://tests/test_case.gd"
## Smaller facade paths not covered elsewhere: console panel, HUD panels, player
## outside the world, state reads, sidecar orphan cleanup, quarantine cleanup of panels.


func test_console_panel() -> void:
	var root := ProjectSettings.globalize_path("user://t_console/mods")
	rm_rf(root)
	DirAccess.make_dir_recursive_absolute(root)
	var inst := spawn_instance(root, "user://t_console/pittapi", {"dev_console": true})
	await wait_frames(1)
	assert_true(inst.console_panel != null and inst.console_panel.is_inside_tree(), "panel created when dev_console=true")
	inst.console_panel.set_open(true)
	assert_true(inst.console_panel.visible, "opens")
	inst.console_panel._on_submit("help")
	assert_true(inst.console_panel._out.get_parsed_text().contains("mods"), "help output shown")
	inst.console_panel._on_submit("events money.")
	inst.events.emit_internal("money.changed", {"money": "1"})
	assert_true(inst.console_panel._out.get_parsed_text().contains("money.changed"), "event tail")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_QUOTELEFT
	key.pressed = true
	inst._input(key)
	assert_false(inst.console_panel.visible, "console key toggles")
	inst.queue_free()
	await wait_frames(1)


func test_hud_panels() -> void:
	var ctx = core.loader.mods["ExampleMod"].ctx
	var c := Label.new()
	c.text = "panel"
	assert_eq(ctx.hud.add_panel("info", c), OK, "add_panel")
	assert_true(ctx.hud.has_panel("info") and c.is_inside_tree(), "panel in tree")
	ctx.hud.remove_panel("info")
	assert_false(ctx.hud.has_panel("info"), "removed")
	assert_false(ctx.hud.floating_text("x"), "floating_text no-op outside the world")


func test_player_outside_world() -> void:
	assert_eq(core.player.get_local(), null, "no player")
	assert_eq(core.player.get_held(), 0, "held 0")
	assert_eq(core.player.get_position(), Vector3.ZERO, "position zero")
	assert_eq(core.player.teleport(Vector3.ONE).code, "ERR_UNAVAILABLE", "teleport unavailable")
	core.player.set_movement_locked(true)
	core.player.set_movement_locked(false)


func test_state_reads() -> void:
	assert_eq(core.state.get_phase(), 0, "phase")
	assert_eq(core.state.get_phase_name(1), "duck", "phase name")
	assert_eq(core.state.get_phase_progress(), -1.0, "no hole outside world")
	assert_eq(core.state.get_item("upgrades", "sprint").get("prices", []), [50], "item copy")
	assert_eq(core.state.get_item("upgrades", "nope"), {}, "unknown item")
	assert_eq(core.state.get_stat("products_crafted.duck"), 0, "stat path")
	assert_eq(core.state.get_stat("nope.x"), null, "unknown stat")
	var b = core.state.bigint_from("123")
	assert_true(b != null and b.to_plain_string() == "123", "bigint_from")
	var it: Dictionary = core.state.get_item("upgrades", "sprint")
	it["level"] = 99
	assert_eq(tree.root.get_node("GameState").upgrades.sprint.level, 0, "get_item returns a copy")


func test_sidecar_orphans() -> void:
	var d := "user://pittapi/saves/savegame_7"
	DirAccess.make_dir_recursive_absolute(d)
	var f := FileAccess.open(d.path_join("X.json"), FileAccess.WRITE)
	f.store_string("{}")
	f.close()
	var n: int = core.sidecar.cleanup_orphans()
	assert_true(n >= 1 and not DirAccess.dir_exists_absolute(d), "sidecar of a deleted slot removed")


func test_spawn_facade_reads() -> void:
	assert_eq(core.spawn.headroom("nope"), 0, "unknown pool headroom")
	assert_true(core.spawn.pools() is Array, "pools() array")
