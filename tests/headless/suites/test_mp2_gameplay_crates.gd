extends "res://tests/test_case.gd"
## Spike S-M3 (integration fix): metal/plush/anomaly crates extend wodd_crate.gd through
## class_name GamblingCrate. In the real game a crate subclass compiled AFTER wodd_crate.gd
## was taken over fails with 'Could not find class "GamblingCrate"', so each subclass has
## its own extension, listed before wodd_crate_ext.gd, with the same gates.

const EXT_DIR := "res://gamedir/mods/PittMultiplayer/extensions/gameplay/"
const MANIFEST := "res://gamedir/mods/PittMultiplayer/mod.json"
const SUBS := ["metal_crate", "plush_crate", "anomaly_crate"]


static func _body(src: String) -> String:
	# everything from the first const/func line on (the header comment differs)
	var i := src.find("\nconst G")
	return src.substr(i).strip_edges() if i >= 0 else ""


func test_subclass_exts_listed_before_the_base() -> void:
	var m = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	var exts: Array = m.extensions
	var base := exts.find("extensions/gameplay/wodd_crate_ext.gd")
	assert_true(base >= 0, "wodd_crate_ext listed")
	for s in SUBS:
		var i := exts.find("extensions/gameplay/%s_ext.gd" % s)
		assert_true(i >= 0, "%s_ext listed" % s)
		assert_true(i < base, "%s_ext before wodd_crate_ext (compiles against the original crate)" % s)


func test_subclass_exts_repeat_the_crate_gates() -> void:
	var base := _body(FileAccess.get_file_as_string(EXT_DIR + "wodd_crate_ext.gd"))
	assert_true(base.length() > 100, "base gates read")
	for s in SUBS:
		var src := FileAccess.get_file_as_string(EXT_DIR + "%s_ext.gd" % s)
		assert_true(src.begins_with("extends \"res://scripts/%s.gd\"" % s), "%s_ext extends its own script" % s)
		assert_eq(_body(src), base, "%s_ext has the same gates as wodd_crate_ext" % s)


func test_subclass_exts_are_applied() -> void:
	for s in SUBS:
		var sc: Script = load("res://scripts/%s.gd" % s)
		assert_true(sc != null and sc.get_script_constant_map().has("G"), "%s.gd is served by its extension" % s)
