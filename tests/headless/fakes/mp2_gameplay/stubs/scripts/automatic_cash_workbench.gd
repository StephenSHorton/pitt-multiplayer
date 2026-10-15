extends StaticBody3D
## Headless stand-in for res://scripts/automatic_cash_workbench.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/automatic_cash_workbench_ext.gd compile
## and be exercised headless.

var piston: MeshInstance3D = null
var is_crafting = false
var craft_progress = 0.0
var is_turned_on = false
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready():
	pass

func object_name() -> String:
	_stub("object_name")
	return ""

func turn_on():
	_stub("turn_on")

func turn_off():
	_stub("turn_off")

func start_crafting():
	_stub("start_crafting")

func stop_crafting():
	_stub("stop_crafting")

func _process(delta: float) -> void:
	pass

func get_auto_craft_time() -> float:
	_stub("get_auto_craft_time")
	return 0.0

func _update_engine_animations(delta: float):
	_stub("_update_engine_animations")

func _reset_engine_animations():
	_stub("_reset_engine_animations")

func _update_servo_pitch(delta: float):
	_stub("_update_servo_pitch")

func _update_animation(progress: float, craft_time: float):
	_stub("_update_animation")

func _enter_phase(phase_id: String, action: Callable):
	_stub("_enter_phase")

func _tween_ik_to_global(world_pos: Vector3, duration: float):
	_stub("_tween_ik_to_global")

func _set_ik_target_global(world_pos: Vector3):
	_stub("_set_ik_target_global")

func _update_lever(progress: float):
	_stub("_update_lever")

func _show_stage(idx: int):
	_stub("_show_stage")

func _hide_all_stages():
	_stub("_hide_all_stages")

func _play_weld_effect():
	_stub("_play_weld_effect")

func _do_full_piston_sequence():
	_stub("_do_full_piston_sequence")

func _on_piston_reached_top():
	_stub("_on_piston_reached_top")

func _spawn_cash_register():
	_stub("_spawn_cash_register")

func _calculate_launch_impulse(start: Vector3, target: Vector3) -> Vector3:
	_stub("_calculate_launch_impulse")
	return Vector3.ZERO

func set_highlight(active: bool, _grabbed: bool = false) -> void:
	_stub("set_highlight")
