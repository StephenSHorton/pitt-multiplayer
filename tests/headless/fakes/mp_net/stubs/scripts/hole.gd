extends Node3D
## Headless stand-in for res://scripts/hole.gd (our own minimal code) so
## PittMultiplayer's hole_ext.gd compiles and can be exercised.

var current_radius: float = 1.0
var target_radius: float = 1.0
var phase_nutrition_total: float = 0.0
var current_phase: int = 1
var completions := 0
var endings := 0
var fed: Array = []


func _on_product_consumed(product_type: String, base_value: int, body_id: int = -1):
	fed.append([product_type, base_value, body_id])
	phase_nutrition_total += base_value
	target_radius = 1.0 + phase_nutrition_total / 1000.0
	if target_radius >= 2.0: _check_phase_completion()


func _check_phase_completion():
	completions += 1
	_trigger_ending()


func _trigger_ending():
	endings += 1


func get_phase_progress() -> float:
	return clampf(phase_nutrition_total / 1000.0, 0.0, 1.0)
