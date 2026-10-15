extends RigidBody3D
## Headless stand-in for res://scripts/golden_duck_statue.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/golden_duck_statue_ext.gd compile
## and be exercised headless.


var pool_id: String = ""
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

func _physics_process(_delta: float) -> void:
	pass

func _process(delta: float) -> void:
	pass

func _on_bless_body_entered(body: Node3D) -> void:
	_stub("_on_bless_body_entered")

func _spawn_bless_text(body: Node3D, amount: float) -> void:
	_stub("_spawn_bless_text")

func _play_sparkle_burst() -> void:
	_stub("_play_sparkle_burst")

func _triumphant_quack() -> void:
	_stub("_triumphant_quack")

func interact() -> void:
	_stub("interact")

func _spawn_pet_text(amount: float) -> void:
	_stub("_spawn_pet_text")

func get_controls() -> Array:
	_stub("get_controls")
	return []

func place() -> void:
	_stub("place")

func unplace() -> void:
	_stub("unplace")

func set_highlight(active: bool, grabbed: bool = false) -> void:
	_stub("set_highlight")

func get_reset_basis() -> Basis:
	_stub("get_reset_basis")
	return Basis.IDENTITY

func _on_body_entered(_body) -> void:
	_stub("_on_body_entered")

func on_pool_spawn() -> void:
	_stub("on_pool_spawn")

func on_pool_recycle() -> void:
	_stub("on_pool_recycle")

func object_name() -> String:
	_stub("object_name")
	return ""
