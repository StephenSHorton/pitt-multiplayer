extends RigidBody3D
## Headless stand-in for res://scripts/orbit_tool.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/orbit_tool_ext.gd compile
## and be exercised headless.


var pool_id = "tool_orbit"
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

func _try_capture(body: Node) -> bool:
	_stub("_try_capture")
	return false

func _capture_sweep() -> void:
	_stub("_capture_sweep")

func _capture_body(body: RigidBody3D) -> void:
	_stub("_capture_body")

func _write_orbit_position(idx: int) -> void:
	_stub("_write_orbit_position")

func _check_for_releases() -> void:
	_stub("_check_for_releases")

func _release_at_index(idx: int, velocity_override: Variant = null) -> void:
	_stub("_release_at_index")

func _release_all() -> void:
	_stub("_release_all")

func interact() -> void:
	_stub("interact")

func toggle_orbit() -> void:
	_stub("toggle_orbit")

func remote_toggle(on: bool) -> void:
	_stub("remote_toggle")

func _update_visual_state() -> void:
	_stub("_update_visual_state")

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

func _drop_maw_claimed_body(idx: int) -> void:
	_stub("_drop_maw_claimed_body")
