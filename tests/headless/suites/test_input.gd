extends "res://tests/test_case.gd"

var im: Node = null
var ctx = null


func before_all() -> void:
	im = tree.root.get_node("InputManager")
	ctx = core.loader.mods["ExampleMod"].ctx


func test_example_action_exists() -> void:
	assert_true(InputMap.has_action("mod_ExampleMod_print_money"), "ExampleMod registered its action")
	assert_eq(ctx.input.get_key("print_money"), KEY_F7, "default key")


func test_register_survives_apply_bindings() -> void:
	var a: String = ctx.input.register_action("t_act", KEY_F9, "Test")
	assert_eq(a, "mod_ExampleMod_t_act", "action name")
	assert_true(InputMap.has_action(a), "in InputMap")
	im.apply_bindings()
	assert_true(InputMap.has_action(a) and not InputMap.action_get_events(a).is_empty(), "survives InputManager.apply_bindings")
	assert_false(im.current_bindings.has(a), "not added to the game's bindings")


func test_conflicts_and_rebind() -> void:
	ctx.input.register_action("t_conf", KEY_W, "Conflicting")
	assert_has(ctx.input.conflicts("t_conf"), "up", "conflict with a game action")
	assert_eq(ctx.input.rebind("t_conf", KEY_F12), OK, "rebind")
	assert_eq(ctx.input.conflicts("t_conf").size(), 0, "no conflict after rebind")
	var cfg := ConfigFile.new()
	assert_eq(cfg.load("user://pittapi/keybinds.cfg"), OK, "keybinds.cfg written")
	assert_eq(cfg.get_value("ExampleMod", "t_conf", 0), KEY_F12, "persisted")
	assert_false(FileAccess.file_exists("user://keybindings.cfg"), "the game's keybindings.cfg is never written by the API")


func test_input_event_dispatch() -> void:
	var got := capture("input.action")
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_F7
	ev.pressed = true
	core._input(ev)
	assert_true(got.size() == 1 and got[0].payload.name == "print_money" and got[0].payload.pressed, "input.action emitted: %s" % str(got))
	var up := InputEventKey.new()
	up.physical_keycode = KEY_F7
	up.pressed = false
	core._input(up)
	assert_true(got.size() == 2 and not got[1].payload.pressed, "release emitted")
