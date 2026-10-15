extends StaticBody3D
## Headless stand-in for res://scripts/automatic_pinata_workbench.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/automatic_pinata_workbench_ext.gd compile
## and be exercised headless.


var body: Node3D = null
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

func get_suction_total_duration() -> float:
	_stub("get_suction_total_duration")
	return 0.0

func _raw_craft_time() -> float:
	_stub("_raw_craft_time")
	return 0.0

func get_build_phase_duration() -> float:
	_stub("get_build_phase_duration")
	return 0.0

func get_auto_craft_time() -> float:
	_stub("get_auto_craft_time")
	return 0.0

func start_crafting():
	_stub("start_crafting")

func stop_crafting():
	_stub("stop_crafting")

func _process(delta: float) -> void:
	pass

func _update_engine_animations(delta: float):
	_stub("_update_engine_animations")

func _reset_engine_animations():
	_stub("_reset_engine_animations")

func _update_lever(delta: float):
	_stub("_update_lever")

func _update_tube_rattle(delta: float):
	_stub("_update_tube_rattle")

func _trigger_tube_rattle(duration: float = -1.0, intensity: float = -1.0):
	_stub("_trigger_tube_rattle")

func _resolve_pinata_material():
	_stub("_resolve_pinata_material")

func _set_build_progress(value: float):
	_stub("_set_build_progress")

func _ensure_thread_mesh():
	_stub("_ensure_thread_mesh")

func _apply_thread_color(index: int):
	_stub("_apply_thread_color")

func _advance_thread_color():
	_stub("_advance_thread_color")

func _thread_start_global() -> Vector3:
	_stub("_thread_start_global")
	return Vector3.ZERO

func _thread_end_global() -> Vector3:
	_stub("_thread_end_global")
	return Vector3.ZERO

func _update_thread():
	_stub("_update_thread")

func _orient_thread_between(a: Vector3, b: Vector3):
	_stub("_orient_thread_between")

func _set_thread_visible(v: bool):
	_stub("_set_thread_visible")

func _retract_thread():
	_stub("_retract_thread")

func _do_suction_sequence():
	_stub("_do_suction_sequence")

func _on_suction_complete():
	_stub("_on_suction_complete")

func _spawn_pinata():
	_stub("_spawn_pinata")

func _calculate_launch_impulse(start: Vector3, target: Vector3) -> Vector3:
	_stub("_calculate_launch_impulse")
	return Vector3.ZERO

func update_crafting_sound_pitch(progress: float):
	_stub("update_crafting_sound_pitch")

func _update_sewing_pitch(build_progress_value: float):
	_stub("_update_sewing_pitch")

func set_highlight(active: bool, _grabbed: bool = false) -> void:
	_stub("set_highlight")

func _resolve_outlines():
	_stub("_resolve_outlines")

func _collect_outlines_recursive(node: Node):
	_stub("_collect_outlines_recursive")
