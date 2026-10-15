extends "res://tests/test_case.gd"

const Manifest = preload("res://gamedir/mods/PittAPI/core/manifest.gd")


func test_valid() -> void:
	var r := Manifest.parse_text('{"id":"MyMod","name":"My","version":"1.0.0","api_version":"^1.0","load_order":5,"extensions":["ext/a.gd"],"multiplayer":"host_only"}', "MyMod")
	assert_true(r.ok, "valid manifest: %s" % str(r.errors))
	assert_eq(r.data.load_order, 5, "load_order")
	assert_eq(r.data.entry, "main.gd", "default entry")
	assert_eq(r.data.multiplayer, "host_only", "multiplayer")


func test_invalid_id() -> void:
	var r := Manifest.parse_text('{"id":"9bad id","name":"x","version":"1.0.0","api_version":"^1.0"}', "9bad id")
	assert_false(r.ok, "invalid id rejected")
	r = Manifest.parse_text('{"id":"Good","name":"x","version":"1.0.0","api_version":"^1.0"}', "Other")
	assert_false(r.ok, "id must equal folder")


func test_missing_fields_and_types() -> void:
	var r := Manifest.parse_text('{"id":"Mod1","name":"x"}', "Mod1")
	assert_false(r.ok, "missing version/api_version")
	r = Manifest.parse_text('{"id":"Mod1","name":"x","version":"1.0.0","api_version":"^1.0","entry":"../../evil.gd"}', "Mod1")
	assert_false(r.ok, "entry outside the folder rejected")
	r = Manifest.parse_text('{"id":"Mod1","name":"x","version":"1.0.0","api_version":"^1.0","multiplayer":"sometimes"}', "Mod1")
	assert_false(r.ok, "bad multiplayer value")
	r = Manifest.parse_text('not json', "Mod1")
	assert_false(r.ok, "not json")


func test_missing_entry_file() -> void:
	var root := ProjectSettings.globalize_path("user://t_manifest/mods")
	rm_rf(root)
	make_mod(root, "NoEntry", {"entry": "nothere.gd"})
	var inst := spawn_instance(root, "user://t_manifest/pittapi")
	await wait_frames(1)
	assert_eq(inst.loader.get_state("NoEntry"), "FAILED", "missing entry -> FAILED")
	assert_true(String(inst.loader.mods["NoEntry"].reason).contains("not found"), "reason mentions not found")
	inst.queue_free()
	await wait_frames(1)


func test_shipped_manifests_valid() -> void:
	for id in ["ExampleMod", "PittAPITests", "_PittAPIBrokenFixture"]:
		var dir := ProjectSettings.globalize_path("res://gamedir/mods").path_join(id)
		var r := Manifest.load_dir(dir)
		assert_true(r.ok, "%s mod.json valid: %s" % [id, str(r.errors)])
