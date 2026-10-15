extends "fake_body.gd"
## Carries every field of the game's save schema the generic meta reads, with
## the game setters recording their calls (test_mp2_bodies_meta).

var placed := false
var is_active := false
var value := 5
var base_value := 10
var current_variant := ""
var scheduler_mode := 0
var scheduler_interval := 4.0
var scheduler_duration := 1.0
var stat_index := 0
var camera_id := ""
var watched_camera_id := ""
var current_channel := 0
var is_flattened := false
var grade := 0
var _repel := false
var _current_preset_index := 0
var _bag_items: Array = []
var _queue: Array = []
var calls: Array = []


func remote_toggle(on: bool) -> void:
	calls.append(["remote_toggle", on])
	is_active = on


func _apply_tint() -> void:
	calls.append(["_apply_tint", get_meta("tint_color")])


func set_crude_source(src: int) -> void:
	calls.append(["set_crude_source", src])
	set_meta("crude_source", src)


func set_grade(g: int) -> void:
	calls.append(["set_grade", g])
	grade = g


func _apply_variant(v: String) -> void:
	calls.append(["_apply_variant", v])
	current_variant = v


func apply_placed_state(p: bool) -> void:
	calls.append(["apply_placed_state", p])


func get_piston_save_data() -> Dictionary:
	return {"offset": 0.25, "phase": 1, "timer": 0.5}


func apply_piston_save_data(d: Dictionary) -> void:
	calls.append(["apply_piston_save_data", d])


func set_preset(i: int, fb: bool) -> void:
	calls.append(["set_preset", i, fb])
	_current_preset_index = i


func _update_value_label() -> void:
	calls.append(["_update_value_label", value])


func _update_screen() -> void:
	calls.append(["_update_screen"])


func _refresh() -> void:
	calls.append(["_refresh"])


func _is_repell() -> bool:
	return _repel


func flip_mode(d: bool) -> void:
	calls.append(["flip_mode", d])
	_repel = d


func flatten_mesh_world_y() -> void:
	calls.append(["flatten_mesh_world_y"])
	is_flattened = true


func restore_mesh() -> void:
	calls.append(["restore_mesh"])
	is_flattened = false


func get_bag_save_data() -> Array:
	return []


func apply_loaded_bag(_d) -> void:
	calls.append(["apply_loaded_bag"])


func get_queue_save_data() -> Array:
	return []


func apply_loaded_queue(_d) -> void:
	calls.append(["apply_loaded_queue"])


func called(name: String) -> int:
	var n := 0
	for c in calls:
		if c[0] == name:
			n += 1
	return n
