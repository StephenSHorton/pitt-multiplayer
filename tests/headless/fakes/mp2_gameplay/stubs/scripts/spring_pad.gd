extends RigidBody3D
## Headless stand-in for res://scripts/spring_pad.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/spring_pad_ext.gd compile
## and be exercised headless.


var pool_id = "tool_spring_pad"
var player_impulse: float = 0.0
var font = null
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

func place() -> void:
	_stub("place")

func unplace() -> void:
	_stub("unplace")

func set_highlight(active: bool, _grabbed: bool = false) -> void:
	_stub("set_highlight")

func object_name() -> String:
	_stub("object_name")
	return ""

func get_reset_basis() -> Basis:
	_stub("get_reset_basis")
	return Basis.IDENTITY

func _on_body_entered(_body) -> void:
	_stub("_on_body_entered")

func on_pool_spawn() -> void:
	_stub("on_pool_spawn")

func on_pool_recycle() -> void:
	_stub("on_pool_recycle")

func _register_bonus_ticket(body: RigidBody3D, mult: float, chain_index: int) -> void:
	_stub("_register_bonus_ticket")

func _on_product_consumed(_product_type: String, base_value: int, body_id: int = -1) -> void:
	_stub("_on_product_consumed")

func _award_launch_bonus(bonus: int, chain_count: int) -> void:
	_stub("_award_launch_bonus")
