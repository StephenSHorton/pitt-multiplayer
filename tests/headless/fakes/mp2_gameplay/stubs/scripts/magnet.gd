extends RigidBody3D
## Headless stand-in for res://scripts/magnet.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/magnet_ext.gd compile
## and be exercised headless.


var pool_id = "tool_magnet"
var value = 1
var is_active: bool = false
var placed = false
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready():
	pass

func _physics_process(_delta: float) -> void:
	pass

func _update_active_targets():
	_stub("_update_active_targets")

func toggle_magnet():
	_stub("toggle_magnet")

func _process(delta):
	pass

func set_highlight(active: bool, _grabbed: bool = false) -> void:
	_stub("set_highlight")

func object_name():
	_stub("object_name")

func _on_body_entered(_body):
	_stub("_on_body_entered")

func calculate_collision_volume(impact_force: float) -> float:
	_stub("calculate_collision_volume")
	return 0.0

func interact():
	_stub("interact")

func place():
	_stub("place")

func unplace():
	_stub("unplace")

func remote_toggle(on: bool):
	_stub("remote_toggle")

func on_pool_spawn():
	_stub("on_pool_spawn")

func on_pool_recycle():
	_stub("on_pool_recycle")

func _is_repell() -> bool:
	_stub("_is_repell")
	return false
