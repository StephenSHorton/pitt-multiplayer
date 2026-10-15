extends RigidBody3D
## Headless stand-in for res://scripts/candy.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/candy_ext.gd compile
## and be exercised headless.


var pool_id = "candy"
var value = 2
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _physics_process(_delta: float) -> void:
	pass

func _process(delta):
	pass

func _on_body_entered(_body):
	_stub("_on_body_entered")

func calculate_collision_volume(impact_force: float) -> float:
	_stub("calculate_collision_volume")
	return 0.0

func set_highlight(active: bool, grabbed: bool = false) -> void:
	_stub("set_highlight")

func object_name():
	_stub("object_name")

func on_pool_spawn():
	_stub("on_pool_spawn")

func _apply_tint() -> void:
	_stub("_apply_tint")

func on_pool_recycle() -> void:
	_stub("on_pool_recycle")

func _expire() -> void:
	_stub("_expire")

func _spawn_expire_effects() -> void:
	_stub("_spawn_expire_effects")
