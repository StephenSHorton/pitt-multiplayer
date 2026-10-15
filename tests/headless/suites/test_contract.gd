extends "res://tests/test_case.gd"

const Contract = preload("res://gamedir/mods/PittAPI/core/contract.gd")


class Dummy extends Node:
	signal ping
	var present := 1

	func do_it() -> void:
		pass


func test_missing_member_disables_feature() -> void:
	var c := Contract.new(["feat_a|Dummy|method|do_it", "feat_a|Dummy|prop|present", "feat_b|Dummy|method|missing_one", "feat_c|Dummy|signal|ping"])
	var d := Dummy.new()
	c.check_autoloads(func(n): return d if n == "Dummy" else null)
	assert_true(c.is_available("feat_a"), "complete feature stays on")
	assert_true(c.is_available("feat_c"), "signal found")
	assert_false(c.is_available("feat_b"), "missing method disables the feature")
	assert_has(c.disabled_features(), "feat_b", "listed")
	assert_false(c.is_available("economy"), "GameState missing in this lookup -> economy off")
	d.free()


func test_disabled_feature_blocks_commands() -> void:
	core.contract.features["bank"] = false
	var r = core.commands.execute("bank.set", {"amount": 1.0})
	assert_eq(r.code, "ERR_UNAVAILABLE", "feature off -> ERR_UNAVAILABLE")
	core.contract.features["bank"] = true
	assert_true(core.commands.execute("bank.set", {"amount": 0.0}).ok, "back on")


func test_scene_node_check() -> void:
	var c := Contract.new()
	var hud = load("res://scripts/hud.gd").new()
	c.check_node(hud)
	assert_true(c.is_target_checked("res://scripts/hud.gd"), "scene script entries checked on a live node")
	assert_true(c.is_available("hud"), "stub hud has the members")
	hud.free()
