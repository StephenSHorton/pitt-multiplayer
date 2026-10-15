extends "res://tests/test_case.gd"

const Extensions = preload("res://gamedir/mods/PittAPI/core/extensions.gd")
const FIX := "res://tests/fixtures/ext/"


func _abs(f: String) -> String:
	return ProjectSettings.globalize_path(FIX + f)


func test_chain_two_mods() -> void:
	var ext := Extensions.new()
	ext.build_blocked()
	assert_eq(ext.apply_extension("ModA", _abs("ext_a.gd")), OK, "apply A")
	assert_eq(ext.apply_extension("ModB", _abs("ext_b.gd")), OK, "apply B (stacks on A)")
	var thing = load("res://scenes_fake/thing.gd").new()
	assert_eq(thing.describe(), "b>a>base", "take_over_path chained")
	thing.free()
	assert_true(ext.is_extended("res://scenes_fake/thing.gd"), "registry")
	assert_eq(ext.list()[0].chain.size(), 2, "chain of 2")


func test_autoload_target_refused() -> void:
	var ext := Extensions.new()
	ext.build_blocked()
	assert_true(ext.blocked.has("res://tests/fakes/game_state.gd"), "autoload scripts are BLOCKED")
	assert_true("GameState" in ext.blocked_autoload_names, "autoload names listed")
	assert_eq(ext.apply_extension("ModC", _abs("ext_autoload.gd")), ERR_UNAVAILABLE, "autoload target -> ERR_UNAVAILABLE")


func test_bad_shapes_refused() -> void:
	var ext := Extensions.new()
	ext.build_blocked()
	assert_ne(ext.apply_extension("ModD", _abs("ext_class_name.gd")), OK, "class_name refused")
	assert_ne(ext.apply_extension("ModE", _abs("ext_not_path.gd")), OK, "extends by class refused")
	assert_true(ext.blocked.has("res://scripts/big_int.gd"), "big_int blocked")


func test_example_mod_extension_applied_at_boot() -> void:
	assert_true(core.extensions.is_extended("res://scripts/hud.gd"), "ExampleMod's hud.gd extension applied in _init")
	var hud = load("res://scripts/hud.gd").new()
	assert_eq(hud.get_script(), core.extensions.applied_script("res://scripts/hud.gd"), "new HUD instances use it")
	hud.free()
	assert_false("PittAPI" in core.extensions.blocked_autoload_names, "our own autoload is not in BLOCKED")


## S-M3 shape: a mod extends a subclass first (which loads its base), then the base. The
## base was only loaded by this mod's own earlier extension, so it may still be extended;
## the subclass keeps the original base (chosen by the manifest order).
func test_base_loaded_by_own_earlier_extension_may_be_extended() -> void:
	var ext := Extensions.new()
	ext.build_blocked()
	assert_false(ResourceLoader.has_cached("res://scenes_fake/crate_base.gd"), "base not loaded yet")
	var r: Dictionary = ext.prepare_and_apply("ModS", [_abs("ext_crate_sub.gd"), _abs("ext_crate_base.gd")])
	assert_true(r.ok, "both applied: %s" % r.error)
	var base = load("res://scenes_fake/crate_base.gd").new()
	assert_eq(base.describe(), "base_ext>crate", "base extended")
	var sub = load("res://scenes_fake/crate_sub.gd").new()
	assert_eq(sub.describe(), "sub_ext>crate", "subclass extended, on the original base")
	base.free()
	sub.free()
	# a script loaded before the mod started is still refused
	var other := Extensions.new()
	other.build_blocked()
	load("res://scenes_fake/crate_base2.gd")
	var r2: Dictionary = other.prepare_and_apply("ModT", [_abs("ext_crate_base2.gd")])
	assert_false(r2.ok, "already loaded before the mod: refused")
