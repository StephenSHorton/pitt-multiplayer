extends StaticBody3D
## Headless stand-in for res://scripts/automatic_duck_workbench.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/automatic_duck_workbench_ext.gd compile
## and be exercised headless.


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

func update_crafting_animations(delta: float, progress: float, craft_time: float):
	_stub("update_crafting_animations")

func reset_animations():
	_stub("reset_animations")

func reset_animations_smooth(delta: float):
	_stub("reset_animations_smooth")

func update_crafting_sound_pitch(progress: float):
	_stub("update_crafting_sound_pitch")

func craft_item():
	_stub("craft_item")

func calculate_launch_velocity(start: Vector3, target: Vector3, angle: float, speed: float) -> Vector3:
	_stub("calculate_launch_velocity")
	return Vector3.ZERO

func set_highlight(active: bool, _grabbed: bool = false) -> void:
	_stub("set_highlight")
