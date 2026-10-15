extends RigidBody3D
## Headless stand-in for res://scripts/fan.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/fan_ext.gd compile
## and be exercised headless.


var pool_id = "tool_fan"
var is_active: bool = false
var is_equipped: bool = false
var equipped_offset: Vector3 = Vector3.ZERO
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

func _physics_process(delta):
	pass

func _process(delta):
	pass

func toggle_fan():
	_stub("toggle_fan")

func interact():
	_stub("interact")

func update_fan_state():
	_stub("update_fan_state")

func set_highlight(active: bool, _grabbed: bool = false) -> void:
	_stub("set_highlight")

func object_name():
	_stub("object_name")

func equip(camera: Camera3D):
	_stub("equip")

func unequip(world: Node3D, drop_pos: Vector3):
	_stub("unequip")

func _on_body_entered(_body):
	_stub("_on_body_entered")

func calculate_collision_volume(impact_force: float) -> float:
	_stub("calculate_collision_volume")
	return 0.0

func place():
	_stub("place")

func unplace():
	_stub("unplace")

func get_reset_basis() -> Basis:
	_stub("get_reset_basis")
	return Basis.IDENTITY

func remote_toggle(on: bool):
	_stub("remote_toggle")

func on_pool_spawn():
	_stub("on_pool_spawn")

func on_pool_recycle():
	_stub("on_pool_recycle")
