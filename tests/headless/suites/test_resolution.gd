extends "res://tests/test_case.gd"

var inst: Node = null


func before_all() -> void:
	var root := ProjectSettings.globalize_path("user://t_resolve/mods")
	rm_rf(root)
	make_mod(root, "Lib", {"version": "1.2.0", "load_order": 500})
	make_mod(root, "UsesLib", {"dependencies": {"Lib": ">=1.0.0"}, "load_order": 1})
	make_mod(root, "WantsNewLib", {"dependencies": {"Lib": ">=2.0.0"}})
	make_mod(root, "NeedsGhost", {"dependencies": {"Ghost": "*"}})
	make_mod(root, "ChainOnFailed", {"dependencies": {"NeedsGhost": "*"}})
	make_mod(root, "CycA", {"dependencies": {"CycB": "*"}})
	make_mod(root, "CycB", {"dependencies": {"CycA": "*"}})
	make_mod(root, "FutureApi", {"api_version": "^2.0"})
	make_mod(root, "OldGame", {"game_versions": ["0.9.0"]})
	make_mod(root, "TieB", {"load_order": 50})
	make_mod(root, "TieA", {"load_order": 50})
	make_mod(root, "Early", {"load_order": 10})
	make_mod(root, "OptUser", {"optional_dependencies": {"Lib": "*", "NotInstalled": "*"}, "load_order": 0})
	inst = spawn_instance(root, "user://t_resolve/pittapi")
	await wait_frames(1)


func after_all() -> void:
	if inst != null:
		inst.queue_free()
	await wait_frames(1)


func test_dependencies() -> void:
	assert_eq(inst.loader.get_state("Lib"), "LOADED", "Lib")
	assert_eq(inst.loader.get_state("UsesLib"), "LOADED", "UsesLib")
	var order: Array = inst.loader.order
	assert_true(order.find("Lib") < order.find("UsesLib"), "dependency loads first despite load_order: %s" % str(order))


func test_version_mismatch() -> void:
	assert_eq(inst.loader.get_state("WantsNewLib"), "FAILED", "dependency range not satisfied")
	assert_true(String(inst.loader.mods["WantsNewLib"].reason).contains("not satisfied"), "reason")
	assert_eq(inst.loader.get_state("FutureApi"), "FAILED", "api_version ^2.0 fails on 1.0.0")
	assert_eq(inst.loader.get_state("OldGame"), "LOADED", "game version mismatch is only a warning")
	assert_false(inst.loader.mods["OldGame"].warnings.is_empty(), "warning recorded")


func test_missing_and_propagation() -> void:
	assert_eq(inst.loader.get_state("NeedsGhost"), "FAILED", "missing dependency")
	assert_eq(inst.loader.get_state("ChainOnFailed"), "FAILED", "failure propagates to dependents")


func test_cycles() -> void:
	assert_eq(inst.loader.get_state("CycA"), "FAILED", "cycle A")
	assert_eq(inst.loader.get_state("CycB"), "FAILED", "cycle B")
	assert_true(String(inst.loader.mods["CycA"].reason).contains("cycle"), "reason mentions cycle")


func test_load_order_ties() -> void:
	var order: Array = inst.loader.order
	assert_true(order.find("Early") < order.find("TieA"), "lower load_order first")
	assert_true(order.find("TieA") < order.find("TieB"), "ties broken by id")
	assert_true(order.find("Lib") < order.find("OptUser"), "optional dependency present -> loads first")
	assert_eq(inst.loader.get_state("OptUser"), "LOADED", "missing optional dependency is fine")


func test_status_json() -> void:
	var p := ProjectSettings.globalize_path("user://t_resolve/pittapi/status.json")
	assert_true(FileAccess.file_exists(p), "status.json written")
	var data = JSON.parse_string(FileAccess.get_file_as_string(p))
	assert_true(typeof(data) == TYPE_DICTIONARY and data.mods.size() == 13, "13 mods in status")
