extends RigidBody3D
## Headless stand-in for res://scripts/stat_sign.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/stat_sign_ext.gd compile
## and be exercised headless.

var pool_id = "toy_stat_sign"
var placed: bool = false
var stat_index: int = 0
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready() -> void:
	pass

func _physics_process(_delta: float) -> void:
	pass

func _process(delta: float) -> void:
	pass

func _on_phase_changed(_new_phase: int) -> void:
	_stub("_on_phase_changed")

func _refresh() -> void:
	_stub("_refresh")

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
