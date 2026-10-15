extends RigidBody3D
## Headless stand-in for res://scripts/fan_3.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/fan_3_ext.gd compile
## and be exercised headless.


var pool_id = "tool_fan_3"
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


func _ready() -> void:
	pass

func _physics_process(delta: float) -> void:
	pass

func _process(delta: float) -> void:
	pass

func _apply_zero_g(rb: RigidBody3D) -> void:
	_stub("_apply_zero_g")

func _tick_zero_g(_delta: float) -> void:
	_stub("_tick_zero_g")

func _restore_gravity(body: RigidBody3D, original_gravity: float) -> void:
	_stub("_restore_gravity")

func _flush_all_zero_g() -> void:
	_stub("_flush_all_zero_g")

func toggle_fan() -> void:
	_stub("toggle_fan")

func interact() -> void:
	_stub("interact")

func update_fan_state() -> void:
	_stub("update_fan_state")

func remote_toggle(on: bool) -> void:
	_stub("remote_toggle")

func set_highlight(active: bool, _grabbed: bool = false) -> void:
	_stub("set_highlight")

func object_name() -> String:
	_stub("object_name")
	return ""

func get_reset_basis() -> Basis:
	_stub("get_reset_basis")
	return Basis.IDENTITY

func equip(camera: Camera3D) -> void:
	_stub("equip")

func unequip(world: Node3D, drop_pos: Vector3) -> void:
	_stub("unequip")

func place() -> void:
	_stub("place")

func unplace() -> void:
	_stub("unplace")

func _on_body_entered(_body) -> void:
	_stub("_on_body_entered")

func calculate_collision_volume(impact_force: float) -> float:
	_stub("calculate_collision_volume")
	return 0.0

func on_pool_spawn() -> void:
	_stub("on_pool_spawn")

func on_pool_recycle() -> void:
	_stub("on_pool_recycle")
