extends "res://tests/test_case.gd"

const SafeFS = preload("res://gamedir/mods/PittAPI/core/safe_fs.gd")

var sm: Node = null


func before_all() -> void:
	sm = tree.root.get_node("SaveManager")


func test_sidecar_written_on_save() -> void:
	var ctx = core.loader.mods["ExampleMod"].ctx
	core.sidecar.load_key("savegame")
	assert_eq(ctx.saves.get_active_save_key(), "savegame", "active key")
	assert_eq(ctx.saves.mod_data_set("coins", 42), OK, "set")
	assert_eq(ctx.saves.mod_data_set("bad", RefCounted.new()), ERR_INVALID_DATA, "non JSON-safe refused")
	assert_eq(ctx.saves.mod_data_get("coins"), 42, "in memory")
	var saved := capture("save.saved")
	sm.fake_save()
	core.bridge.process(0.0)
	assert_eq(saved.size(), 1, "save.saved from _last_save_tick change")
	var p := "user://pittapi/saves/savegame/ExampleMod.json"
	assert_true(FileAccess.file_exists(p), "sidecar written")
	assert_false(FileAccess.file_exists(p + ".tmp"), "atomic: no .tmp left")
	var data = JSON.parse_string(FileAccess.get_file_as_string(p)) if FileAccess.file_exists(p) else {}
	assert_eq(data.get("coins", null), 42.0, "content")
	core.sidecar.reset_key("savegame")
	assert_eq(ctx.saves.mod_data_get("coins", -1), -1, "reset")
	var loaded := [false]
	ctx.saves.mod_data_loaded.connect(func(): loaded[0] = true, CONNECT_ONE_SHOT)
	sm.fake_load()
	assert_true(loaded[0], "mod_data_loaded on save.loaded")
	assert_eq(ctx.saves.mod_data_get("coins"), 42.0, "read back on save.loaded")


func test_never_touches_save_files() -> void:
	var touched: Array = core.safe_fs.touched_save_files()
	assert_eq(touched.size(), 0, "SafeFS never opened a save file: %s" % str(touched))
	var fs := SafeFS.new("user://pittapi")
	assert_eq(fs.write_text_atomic("user://savegame.save", "x"), ERR_FILE_NO_PERMISSION, "savegame refused")
	assert_eq(fs.write_text_atomic("user://pittapi/sandbox.save", "x"), ERR_FILE_NO_PERMISSION, "sandbox.save refused even inside our root")
	assert_eq(fs.write_text_atomic("user://profile.cfg", "x"), ERR_FILE_NO_PERMISSION, "profile.cfg refused")
	assert_eq(fs.write_text_atomic("user://elsewhere.txt", "x"), ERR_FILE_NO_PERMISSION, "outside root refused")
	for f in ["user://savegame.save", "user://pittapi/sandbox.save", "user://profile.cfg", "user://elsewhere.txt"]:
		assert_false(FileAccess.file_exists(f), "%s not created" % f)


func test_slot_infos_read_only() -> void:
	var infos: Array = core.saves.get_slot_infos()
	assert_eq(infos.size(), 10, "10 slots")
	if infos.size() > 1:
		assert_eq(infos[1].save_key, "savegame_2", "slot 1 -> savegame_2")
		assert_false(infos[0].occupied, "no saves in the test project")
	assert_false(FileAccess.file_exists("user://profile.cfg"), "profile.cfg not created")


func test_new_run_replaces_old_sidecars() -> void:
	var ex = core.loader.mods["ExampleMod"].ctx
	core.sidecar.load_key("sandbox")
	ex.saves.mod_data_set("old", 1)
	core.sidecar.mark_cheated()
	core.sidecar.flush("sandbox")
	var d := "user://pittapi/saves/sandbox/"
	assert_true(FileAccess.file_exists(d + "ExampleMod.json") and FileAccess.file_exists(d + "_pittapi.json"), "old run written")
	# SaveManager.clear_sandbox_slot() + a fresh sandbox run
	core.sidecar.reset_key("sandbox")
	assert_false(ex.saves.is_cheated(), "fresh run is not cheated")
	core.sidecar.flush("sandbox")
	assert_false(FileAccess.file_exists(d + "ExampleMod.json"), "old mod data removed on the first save of the new run")
	assert_false(FileAccess.file_exists(d + "_pittapi.json"), "old cheated flag removed")
	core.sidecar.load_key("sandbox")
	assert_eq(ex.saves.mod_data_get("old", -1), -1, "nothing comes back on load")
	ex.saves.mod_data_set("new", 2)
	core.sidecar.flush("sandbox")
	core.sidecar.load_key("sandbox")
	assert_eq(ex.saves.mod_data_get("new", -1), 2.0, "later saves still write")
	core.safe_fs.remove_dir_recursive("user://pittapi/saves/sandbox")
	core.sidecar.load_key("savegame")
