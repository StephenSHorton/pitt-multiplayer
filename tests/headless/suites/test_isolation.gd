extends "res://tests/test_case.gd"

var inst: Node = null


func before_all() -> void:
	inst = spawn_instance(ProjectSettings.globalize_path("res://tests/fixtures/mods_isolation"), "user://t_iso/pittapi",
		{"quarantine_threshold": 3, "quarantine_window_s": 10.0})
	await wait_frames(2)


func after_all() -> void:
	if inst != null:
		inst.queue_free()
	await wait_frames(1)


func test_parse_error_fails_others_load() -> void:
	assert_eq(inst.loader.get_state("BrokenParseMod"), "FAILED", "parse error -> FAILED")
	assert_true(String(inst.loader.mods["BrokenParseMod"].reason).contains("compile"), "reason")
	assert_eq(inst.loader.get_state("NeedsBrokenMod"), "FAILED", "dependent of a broken mod fails")
	assert_eq(inst.loader.get_state("GoodMod"), "LOADED", "good mod still loads")
	assert_eq(inst.loader.get_state("DisabledMod"), "DISABLED", "enabled:false")


func test_init_error_quarantines() -> void:
	assert_eq(inst.loader.get_state("InitErrorMod"), "QUARANTINED", "error in _mod_init")
	assert_eq(inst.events.subscription_count("InitErrorMod"), 0, "its subscriptions were removed")


func test_throwing_handler_quarantined_at_threshold() -> void:
	var thrower: Node = inst.loader.mods["ThrowerMod"].node
	var good: Node = inst.loader.mods["GoodMod"].node
	assert_eq(inst.loader.get_state("ThrowerMod"), "LOADED", "loads fine at first")
	assert_true(inst.commands.has("ThrowerMod.noop"), "command registered")
	for i in 2:
		inst.events.emit_internal("test.boom", {"i": i})
	inst._process_errors()
	assert_eq(thrower.calls, 2, "still called after errors")
	assert_eq(good.calls, 2, "good handler keeps running")
	assert_eq(inst.loader.get_state("ThrowerMod"), "LOADED", "below threshold")
	inst.events.emit_internal("test.boom", {"i": 3})
	inst._process_errors()
	assert_eq(inst.loader.get_state("ThrowerMod"), "QUARANTINED", "quarantined at 3 errors")
	inst.events.emit_internal("test.boom", {"i": 4})
	assert_eq(thrower.calls, 3, "not called after quarantine")
	assert_eq(good.calls, 4, "good mod unaffected")
	assert_false(inst.commands.has("ThrowerMod.noop"), "its commands were removed")
	assert_false("throw" in inst.console_registry.names(), "its console commands were removed")
	assert_eq(thrower.process_mode, Node.PROCESS_MODE_DISABLED, "node disabled")
	var cfg := ConfigFile.new()
	cfg.load("user://t_iso/pittapi/mods.cfg")
	assert_eq(cfg.get_value("enabled", "ThrowerMod", true), false, "disabled for the next boot in mods.cfg")


func test_errors_attributed_by_path() -> void:
	var mine: Array = inst.guard.recent(200, "ThrowerMod")
	assert_true(mine.size() >= 3, "errors attributed to ThrowerMod: %d" % mine.size())
	if not mine.is_empty():
		assert_true(String(mine[0].file).to_lower().contains("throwermod"), "attributed by file path: %s" % mine[0].file)


func test_core_frames_blame_the_calling_mod() -> void:
	var g = core.guard
	var core_file: String = core.mods_dir.path_join("PittAPI/api/hud.gd")
	assert_eq(g.attribute_path(core_file), "PittAPI", "facade file maps to PittAPI")
	assert_eq(g.attribute(core_file, []), "PittAPI", "no mod scope: PittAPI")
	g.push_scope("ExampleMod")
	g.push_scope("PittAPI")   # a core command handler running inside the mod's call
	assert_eq(g.attribute(core_file, []), "ExampleMod", "PittAPI file + mod scope -> the mod")
	assert_eq(g.attribute("res://scripts/hud.gd", []), "ExampleMod", "game file + mod scope -> the mod")
	g.pop_scope()
	g.pop_scope()
	assert_eq(g.attribute(core.mods_dir.path_join("ExampleMod/main.gd"), []), "ExampleMod", "mod file wins")
