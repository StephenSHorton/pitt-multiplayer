extends RigidBody3D
## Headless stand-in for res://scripts/feed_screen.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/feed_screen_ext.gd compile
## and be exercised headless.

var pool_id = "tool_feed_screen"
var watched_camera_id: String = ""
var placed: bool = false
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready() -> void:
	pass

func _process(delta: float) -> void:
	pass

func _physics_process(_delta: float) -> void:
	pass

func interact() -> void:
	_stub("interact")

func place() -> void:
	_stub("place")

func force_place() -> void:
	_stub("force_place")

func unplace() -> void:
	_stub("unplace")

func apply_placed_state(p: bool) -> void:
	_stub("apply_placed_state")

func _freeze_in_place() -> void:
	_stub("_freeze_in_place")

func _unfreeze() -> void:
	_stub("_unfreeze")

func object_name() -> String:
	_stub("object_name")
	return ""

func get_reset_basis() -> Basis:
	_stub("get_reset_basis")
	return Basis.IDENTITY

func set_highlight(active: bool, _grabbed: bool = false) -> void:
	_stub("set_highlight")

func on_pool_spawn() -> void:
	_stub("on_pool_spawn")

func on_pool_recycle() -> void:
	_stub("on_pool_recycle")

func _on_body_entered(_body) -> void:
	_stub("_on_body_entered")

func _calculate_collision_volume(impact_force: float) -> float:
	_stub("_calculate_collision_volume")
	return 0.0
