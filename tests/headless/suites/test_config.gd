extends "res://tests/test_case.gd"

const ConfigApi = preload("res://gamedir/mods/PittAPI/api/config.gd")


func test_defaults_validation_persistence() -> void:
	var path := "user://pittapi/config/TestCfg.cfg"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var c = ConfigApi.new(core, "TestCfg", path)
	var changes: Array = []
	c.changed.connect(func(s, k, v): changes.append([s, k, v]))
	c.define("speed", 1.5, {"min": 0.0, "max": 10.0})
	c.define("mode", "a", {"options": ["a", "b"], "section": "ui"})
	assert_eq(c.get_value("speed"), 1.5, "default")
	assert_eq(c.set_value("speed", 50.0), ERR_INVALID_PARAMETER, "max enforced")
	assert_eq(c.set_value("speed", "fast"), ERR_INVALID_PARAMETER, "type enforced")
	assert_eq(c.set_value("speed", 3), OK, "int accepted for float")
	assert_eq(c.get_value("speed"), 3.0, "stored as float")
	assert_eq(c.set_value("mode", "c", "ui"), ERR_INVALID_PARAMETER, "options enforced")
	assert_eq(c.set_value("mode", "b", "ui"), OK, "section")
	assert_eq(changes.size(), 2, "changed signal")
	assert_false(FileAccess.file_exists(path), "debounced: not written yet")
	await tree.create_timer(0.7).timeout
	c.tick()
	assert_true(FileAccess.file_exists(path), "written after debounce")
	var c2 = ConfigApi.new(core, "TestCfg", path)
	c2.define("speed", 1.5)
	assert_eq(c2.get_value("speed"), 3.0, "persisted")
	assert_eq(c2.get_value("mode", "ui"), "b", "persisted section")


func test_global_settings_file() -> void:
	assert_true(FileAccess.file_exists("user://pittapi/config/pittapi.cfg"), "pittapi.cfg created with defaults")
	assert_eq(core.setting("cheats_allowed"), true, "default cheats_allowed")
	assert_eq(core.setting("quarantine_threshold"), 50, "default threshold")


func test_mod_config_bound() -> void:
	var ctx = core.loader.mods["ExampleMod"].ctx
	assert_eq(ctx.config.get_value("money_key_toast"), true, "ExampleMod default")
	assert_eq(ctx.config.path, "user://pittapi/config/ExampleMod.cfg", "per-mod file")
