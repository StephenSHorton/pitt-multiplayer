extends RigidBody3D
## Headless stand-in for res://scripts/portal.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/portal_ext.gd compile
## and be exercised headless.


var pool_id = "tool_portal"
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

func _is_placed_object(body: Object) -> bool:
	_stub("_is_placed_object")
	return false

func _do_teleport(body: Node) -> bool:
	_stub("_do_teleport")
	return false

func _update_visual_state() -> void:
	_stub("_update_visual_state")

func object_name() -> String:
	_stub("object_name")
	return ""

func set_highlight(active: bool, _grabbed: bool = false) -> void:
	_stub("set_highlight")

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

func _calc_collision_volume(impact_force: float) -> float:
	_stub("_calc_collision_volume")
	return 0.0

func on_pool_spawn() -> void:
	_stub("on_pool_spawn")

func on_pool_recycle() -> void:
	_stub("on_pool_recycle")

func _exit_tree() -> void:
	pass
