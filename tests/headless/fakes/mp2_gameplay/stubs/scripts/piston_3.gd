extends "res://scripts/piston_2.gd"
## Headless stand-in for res://scripts/piston_3.gd (the weight piston; our own
## minimal code: every function only records its call, stub_calls / stub_hook,
## except the weight preset cycle / setter, which keep a wrapped, clamped index). Lets extensions/gameplay/piston_3_ext.gd compile and be exercised.

var weight_thresholds: Array = [1.0, 2.0, 4.0]
var detection_area: Area3D = null
var _current_weight_preset_index: int = 1


func _advance_phase() -> void:
	_stub("_advance_phase")


func _compute_front_mass() -> float:
	_stub("_compute_front_mass")
	return 0.0


func scroll_tune_up() -> void:
	cycle_weight_preset(1)


func scroll_tune_down() -> void:
	cycle_weight_preset(-1)


func cycle_weight_preset(direction: int) -> void:
	_stub("cycle_weight_preset")
	set_weight_preset(posmod(_current_weight_preset_index + direction, weight_thresholds.size()), true)


func set_weight_preset(index: int, play_feedback: bool) -> void:
	_stub("set_weight_preset")
	_current_weight_preset_index = mini(maxi(index, 0), weight_thresholds.size() - 1)
