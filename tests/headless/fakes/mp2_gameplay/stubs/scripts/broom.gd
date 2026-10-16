extends RigidBody3D
## Headless stand-in for res://scripts/broom.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/broom_ext.gd compile
## and be exercised headless.

var pool_id = "tool_broom"
var is_equipped: bool = false
var equipped_offset: Vector3 = Vector3.ZERO
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready():
	pass

func _physics_process(delta: float) -> void:
	pass

func _process(delta):
	pass

func interact():
	_stub("interact")

func equip(camera: Camera3D):
	_stub("equip")

func unequip(world: Node3D, drop_pos: Vector3):
	_stub("unequip")

func get_equipped_controls_text(ctrl_func: Callable, _looking_at_toggle: bool, _looking_at_linked: bool) -> String:
	_stub("get_equipped_controls_text")
	return ""

func _is_placed_tool(body: Object) -> bool:
	_stub("_is_placed_tool")
	return false

func _hide_trajectory() -> void:
	_stub("_hide_trajectory")

func _exit_tree() -> void:
	pass

func on_pool_spawn() -> void:
	_stub("on_pool_spawn")

func on_pool_recycle() -> void:
	_stub("on_pool_recycle")

func set_highlight(active: bool, grabbed: bool = false) -> void:
	_stub("set_highlight")

func object_name():
	_stub("object_name")

func _on_body_entered(_body):
	_stub("_on_body_entered")

func calculate_collision_volume(impact_force: float) -> float:
	_stub("calculate_collision_volume")
	return 0.0

func get_reset_basis() -> Basis:
	_stub("get_reset_basis")
	return Basis.IDENTITY

func _update_preview() -> void:
	_stub("_update_preview")

func _clear_preview() -> void:
	_stub("_clear_preview")
