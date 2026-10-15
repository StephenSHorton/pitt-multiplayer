extends RigidBody3D
## Headless stand-in for res://scripts/vacuum.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/vacuum_ext.gd compile
## and be exercised headless.


var pool_id = "tool_vacuum"
var is_active: bool = false
var is_equipped: bool = false
var equipped_offset: Vector3 = Vector3.ZERO
var equipped_rotation_deg: Vector3 = Vector3.ZERO
var placed = false
var _bag_items: Array = []
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

func _update_active_targets() -> void:
	_stub("_update_active_targets")

func _check_ingestion() -> void:
	_stub("_check_ingestion")

func _suction_accepts(_body: RigidBody3D) -> bool:
	_stub("_suction_accepts")
	return false

func _get_release_marker() -> Marker3D:
	_stub("_get_release_marker")
	return null

func _ingest(body: RigidBody3D) -> void:
	_stub("_ingest")

func _release_one() -> void:
	_stub("_release_one")

func _release_all() -> void:
	_stub("_release_all")

func _spool_audio_up() -> void:
	_stub("_spool_audio_up")

func _spool_audio_down() -> void:
	_stub("_spool_audio_down")

func toggle_vacuum() -> void:
	_stub("toggle_vacuum")

func interact() -> void:
	_stub("interact")

func remote_toggle(on: bool) -> void:
	_stub("remote_toggle")

func equipped_lmb_pressed() -> void:
	_stub("equipped_lmb_pressed")

func equipped_lmb_released() -> void:
	_stub("equipped_lmb_released")

func equipped_rmb_pressed() -> void:
	_stub("equipped_rmb_pressed")

func get_equipped_controls_text(ctrl_func: Callable, _looking_at_toggle: bool, _looking_at_linked: bool) -> String:
	_stub("get_equipped_controls_text")
	return ""

func equip(camera: Camera3D) -> void:
	_stub("equip")

func unequip(world: Node3D, drop_pos: Vector3) -> void:
	_stub("unequip")

func object_name() -> String:
	_stub("object_name")
	return ""

func set_highlight(active: bool, _grabbed: bool = false) -> void:
	_stub("set_highlight")

func get_reset_basis() -> Basis:
	_stub("get_reset_basis")
	return Basis.IDENTITY

func place() -> void:
	_stub("place")

func unplace() -> void:
	_stub("unplace")

func _on_body_entered(_body) -> void:
	_stub("_on_body_entered")

func on_pool_spawn() -> void:
	_stub("on_pool_spawn")

func on_pool_recycle() -> void:
	_stub("on_pool_recycle")

func _force_clear_bag() -> void:
	_stub("_force_clear_bag")

func get_bag_save_data() -> Array:
	_stub("get_bag_save_data")
	return []

func apply_loaded_bag(bag_data: Array) -> void:
	_stub("apply_loaded_bag")
