extends RigidBody3D
## Headless stand-in for res://scripts/tractor_beam.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/tractor_beam_ext.gd compile
## and be exercised headless.


var pool_id = "tool_tractor_beam"
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

func equipped_lmb_pressed() -> void:
	_stub("equipped_lmb_pressed")

func equipped_lmb_released() -> void:
	_stub("equipped_lmb_released")

func equipped_rmb_pressed() -> void:
	_stub("equipped_rmb_pressed")

func toggle_beam() -> void:
	_stub("toggle_beam")

func interact() -> void:
	_stub("interact")

func remote_toggle(on: bool) -> void:
	_stub("remote_toggle")

func _spool_audio_up() -> void:
	_stub("_spool_audio_up")

func _spool_audio_down() -> void:
	_stub("_spool_audio_down")

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
