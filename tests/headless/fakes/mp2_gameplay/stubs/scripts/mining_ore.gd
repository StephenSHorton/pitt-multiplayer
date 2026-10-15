extends RigidBody3D
## Headless stand-in for res://scripts/mining_ore.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/mining_ore_ext.gd compile
## and be exercised headless.


var pool_id = "ore_duck"
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _physics_process(_delta: float) -> void:
	pass

func _process(delta: float) -> void:
	pass

func on_pool_spawn() -> void:
	_stub("on_pool_spawn")

func on_pool_recycle() -> void:
	_stub("on_pool_recycle")

func set_highlight(active: bool, grabbed: bool = false) -> void:
	_stub("set_highlight")

func object_name() -> String:
	_stub("object_name")
	return ""

func _on_body_entered(_body) -> void:
	_stub("_on_body_entered")

func recover_to_home() -> void:
	_stub("recover_to_home")
