extends "res://tests/test_case.gd"


func test_booted() -> void:
	assert_true(core.booted, "booted")
	var re := RegEx.new()
	re.compile("^\\d+\\.\\d+\\.\\d+$")
	assert_true(re.search(core.api_version) != null, "VERSION is semver")
	assert_eq(core.game_version, "1.0.8", "game version from ProjectSettings")
	assert_true(core.events.last("game.boot_complete") != null, "boot_complete emitted")


func test_mod_states() -> void:
	assert_eq(core.loader.get_state("ExampleMod"), "LOADED", "ExampleMod: %s" % core.loader.mods.get("ExampleMod", {}).get("reason", ""))
	assert_eq(core.loader.get_state("PittAPITests"), "LOADED", "PittAPITests (idle without the flag)")
	assert_false(core.loader.mods.has("_PittAPIBrokenFixture"), "underscore fixtures skipped without the test flag")
	var ctx = core.loader.mods["ExampleMod"].ctx
	assert_true(ctx.has_mod("PittAPITests"), "has_mod")
	assert_true(ctx.get_mod_api("ExampleMod") != null, "get_public_api")
	assert_eq(ctx.get_mod_api("Nope"), null, "unknown mod -> null")
	var order: Array = core.loader.order
	assert_true(order.find("ExampleMod") < order.find("PittAPITests"), "load_order respected")


func test_files() -> void:
	assert_true(FileAccess.file_exists("user://pittapi/status.json"), "status.json")
	assert_true(FileAccess.file_exists("user://pittapi/pittapi.log"), "pittapi.log")
	var st = JSON.parse_string(FileAccess.get_file_as_string("user://pittapi/status.json"))
	assert_true(st.booted, "status says booted")
	assert_true(st.logger_installed, "ErrorGuard installed")


func test_contract_all_fakes_ok() -> void:
	assert_eq(core.contract.disabled_features(), [], "fakes satisfy the autoload contract: %s" % str(core.contract.missing()))


func test_toast_layer() -> void:
	var t = core.hud.toast("hello from tests")
	await wait_frames(1)
	assert_true(t != null and t.is_inside_tree(), "toast node")
	assert_true(core.toast_layer.layer == 90 and core.toast_layer.process_mode == Node.PROCESS_MODE_ALWAYS, "layer 90, always")
	assert_false(core.hud.banner("x"), "banner is a no-op outside the world")


func test_console_run() -> void:
	assert_true(core.console.run("help").contains("mods"), "help")
	assert_true(core.console.run("mods").contains("ExampleMod"), "mods")
	assert_true(core.console.run("hello there").contains("hi there"), "mod console command")
	assert_true(core.console.run("cmd money.add {\"amount\": 1}").contains("\"ok\":true"), "cmd")
	assert_true(core.console.run("nope").contains("unknown"), "unknown")


func test_net_stub() -> void:
	assert_true(core.net.is_authority(), "authority")
	assert_eq(core.net.local_peer_id(), 1, "peer 1")
	assert_false(core.net.is_multiplayer(), "single player")
	assert_eq(core.net.get_peers(), [1], "peers")


func test_snapshot_json_safe() -> void:
	var snap: Dictionary = core.state.snapshot()
	assert_eq(Serial_check(snap), "", "snapshot is JSON-safe")
	assert_true(snap.has("money") and snap.has("items") and snap.items.has("upgrades"), "snapshot fields")


func Serial_check(v) -> String:
	return preload("res://gamedir/mods/PittAPI/core/serial.gd").check_json_safe(v)


func test_no_core_errors() -> void:
	assert_eq(core.guard.recent(200, "PittAPI").size(), 0, "no errors attributed to PittAPI: %s" % str(core.guard.recent(3, "PittAPI")))
