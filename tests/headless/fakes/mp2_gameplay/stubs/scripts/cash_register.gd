extends RigidBody3D
## Headless stand-in for res://scripts/cash_register.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/cash_register_ext.gd compile
## and be exercised headless.


var pool_id = "cash_register"
var base_value = 50
var rack: Node3D = null
var value: int = 0
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

func _process(delta: float) -> void:
	pass

func _on_body_entered(_body: Node) -> void:
	_stub("_on_body_entered")

func _drain_value():
	_stub("_drain_value")

func _on_depleted():
	_stub("_on_depleted")

func _spawn_destroy_effect():
	_stub("_spawn_destroy_effect")

func _update_value_label():
	_stub("_update_value_label")

func _calculate_collision_volume(impact_force: float) -> float:
	_stub("_calculate_collision_volume")
	return 0.0

func set_highlight(active: bool, grabbed: bool = false) -> void:
	_stub("set_highlight")

func object_name() -> String:
	_stub("object_name")
	return ""

func on_pool_spawn():
	_stub("on_pool_spawn")

func on_pool_recycle():
	_stub("on_pool_recycle")

func _is_on_cushion() -> bool:
	_stub("_is_on_cushion")
	return false

func get_reset_basis() -> Basis:
	_stub("get_reset_basis")
	return Basis.IDENTITY

func on_whacked(force: float) -> void:
	_stub("on_whacked")

func _is_cushioned_contact(body: Node) -> bool:
	_stub("_is_cushioned_contact")
	return false
