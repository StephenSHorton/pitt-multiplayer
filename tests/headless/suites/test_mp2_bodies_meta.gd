extends "res://tests/test_case.gd"
## MP2 3.5: the generic save-schema meta read field by field from a live node
## and applied with the game's own setters (as _load_object_pools does),
## never apply_loaded_bag / apply_loaded_queue on clients; diffing; adapter
## registry kinds, matcher, merge.

const EntityMeta = preload("res://gamedir/mods/PittMultiplayer/world/bodies/entity_meta.gd")
const MetaSync = preload("res://gamedir/mods/PittMultiplayer/world/bodies/meta_sync.gd")
const FakeMetaBody = preload("res://tests/fakes/mp2_bodies/fake_meta_body.gd")


func _body() -> Node:
	var b = FakeMetaBody.new()
	runner.add_child(b)
	return b


func test_read_every_field() -> void:
	var b = _body()
	b.placed = true
	b.is_active = true
	b.value = 8
	b.current_variant = "rusty"
	b.scheduler_mode = 2
	b.stat_index = 3
	b.camera_id = "cam7"
	b.watched_camera_id = "cam2"
	b.current_channel = 1
	b._repel = true
	b._current_preset_index = 2
	b._bag_items = [1, 2, 3]
	b._queue = [1]
	b.grade = 4
	b.set_meta("tint_color", Color(0.1, 0.2, 0.3, 1.0))
	b.set_meta("gambled", true)
	b.set_meta("crude_source", 2)
	b.set_meta("starter_crate", true)
	var d := EntityMeta.read(b)
	assert_eq(d.is_placed, true, "is_placed")
	assert_eq(d.is_active, true, "is_active")
	assert_eq(d.value, 8, "value")
	assert_eq(d.current_variant, "rusty", "current_variant")
	assert_eq(d.scheduler_mode, 2, "scheduler fields")
	assert_eq(d.stat_index, 3, "stat_index")
	assert_eq(d.camera_id, "cam7", "camera_id")
	assert_eq(d.watched_camera_id, "cam2", "watched_camera_id")
	assert_eq(d.current_channel, 1, "current_channel")
	assert_eq(d.is_repelling, true, "is_repelling")
	assert_eq(d.preset, 2, "preset (piston_2)")
	assert_eq(d.bag_count, 3, "bag_count")
	assert_eq(d.queue_count, 1, "queue_count")
	assert_eq(d.grade, 4, "grade")
	assert_eq(d.tint_color.size(), 4, "tint as a JSON array")
	for i in 4:
		assert_true(is_equal_approx(float(d.tint_color[i]), [0.1, 0.2, 0.3, 1.0][i]), "tint component %d" % i)
	assert_eq(d.gambled, true, "gambled")
	assert_eq(d.crude_source, 2, "crude_source")
	assert_eq(d.starter_crate, true, "starter_crate")
	assert_eq(d.piston, {"offset": 0.25, "phase": 1, "timer": 0.5}, "piston")
	assert_eq(JSON.parse_string(JSON.stringify(d)).size(), d.size(), "JSON-safe")
	b.queue_free()


func test_apply_with_game_setters() -> void:
	var b = _body()
	var d := {"is_placed": true, "is_active": true, "value": 99, "current_variant": "gold", "tint_color": [1, 0, 0, 1],
		"gambled": true, "crude_source": 1, "grade": 3, "piston": {"offset": 1.0}, "preset": 1, "stat_index": 4,
		"scheduler_mode": 1, "scheduler_interval": 2.5, "scheduler_duration": 0.5, "camera_id": "c1",
		"current_channel": 2, "is_repelling": true, "is_flattened": true, "bag_count": 5, "queue_count": 2}
	EntityMeta.apply(b, d, "meta_thing")
	assert_true(b.placed, "placed")
	assert_eq(b.called("apply_placed_state"), 1, "apply_placed_state")
	assert_eq(b.called("remote_toggle"), 1, "is_active through remote_toggle")
	assert_eq(b.value, 10, "value clamped to base_value (load path)")
	assert_eq(b.called("_update_value_label"), 1, "_update_value_label")
	assert_eq(b.called("_apply_variant"), 1, "_apply_variant")
	assert_eq(b.called("_apply_tint"), 1, "_apply_tint")
	assert_eq(b.get_meta("tint_color"), Color(1, 0, 0, 1), "tint meta")
	assert_true(b.get_meta("gambled"), "gambled meta")
	assert_eq(b.called("set_crude_source"), 1, "set_crude_source")
	assert_eq(b.called("set_grade"), 1, "set_grade")
	assert_eq(b.called("apply_piston_save_data"), 1, "apply_piston_save_data")
	assert_eq(b.called("set_preset"), 1, "set_preset")
	assert_true(b.called("_update_screen") >= 2, "_update_screen (scheduler + channel)")
	assert_true(b.called("_refresh") >= 1, "_refresh")
	assert_eq(b.camera_id, "c1", "camera id")
	assert_eq(b.current_channel, 2, "channel")
	assert_eq(b.called("flip_mode"), 1, "flip_mode")
	assert_eq(b.called("flatten_mesh_world_y"), 1, "flatten_mesh_world_y")
	assert_eq(b.called("apply_loaded_bag"), 0, "never apply_loaded_bag on clients (it spawns)")
	assert_eq(b.called("apply_loaded_queue"), 0, "never apply_loaded_queue on clients")
	EntityMeta.apply(b, {"is_active": true}, "meta_thing")
	assert_eq(b.called("remote_toggle"), 1, "no toggle when the state already matches")
	EntityMeta.apply(b, {"is_active": false}, "tool_remote")
	assert_true(b.is_active, "the remote tool's is_active is never applied (load path)")
	EntityMeta.apply(b, {"is_flattened": false}, "")
	assert_eq(b.called("restore_mesh"), 1, "unflatten")
	b.queue_free()


func test_diff() -> void:
	assert_eq(EntityMeta.diff({"a": 1, "b": 2}, {"a": 1, "b": 3, "c": 4}), {"b": 3, "c": 4}, "changed + new")
	assert_eq(EntityMeta.diff({"a": 1}, {"a": 1.0}), {"a": 1.0}, "a type change is a change")
	assert_true(EntityMeta.diff({"a": [1, 2]}, {"a": [1, 2]}).is_empty(), "arrays compare by value")


func test_registry_kinds_and_merge() -> void:
	var ms := MetaSync.new()
	ms.register("speaker", func(n): return n.has_meta("spk"), func(n): return {"vol": n.get_meta("spk")},
		func(n, d): n.set_meta("spk", d.vol), 10.0)
	var b = _body()
	assert_eq(ms.kinds_for(b, "pooled"), ["g"], "generic only")
	assert_eq(ms.kinds_for(b, "fixture"), [], "state-only fixtures skip the save schema")
	b.set_meta("spk", 3)
	assert_eq(ms.kinds_for(b, "pooled"), ["g", "speaker"], "adapter matched")
	assert_eq(ms.rate_ms("speaker"), 100, "10 Hz")
	assert_eq(ms.read_all(b, ["speaker"]), {"speaker": {"vol": 3}}, "read")
	ms.apply(b, {"speaker": {"vol": 9}}, "")
	assert_eq(int(b.get_meta("spk")), 9, "apply")
	var base := {"g": {"a": 1}}
	MetaSync.merge_into(base, {"g": {"b": 2}, "speaker": {"vol": 1}})
	assert_eq(base, {"g": {"a": 1, "b": 2}, "speaker": {"vol": 1}}, "merge")
	ms.register("g", Callable(), Callable(), Callable())
	assert_eq(ms.adapters.size(), 2, "the built-in kind cannot be replaced")
	b.queue_free()
