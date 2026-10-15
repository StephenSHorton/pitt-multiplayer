extends RigidBody3D
## Headless stand-in for res://scripts/piston.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/piston_ext.gd compile
## and be exercised headless.


var pool_id = "tool_piston"
var is_active: bool = false
var is_equipped: bool = false
var equipped_offset: Vector3 = Vector3.ZERO
var pusher_body: AnimatableBody3D = null
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

func _advance_phase() -> void:
	_stub("_advance_phase")

func _enter_phase(new_phase: int) -> void:
	_stub("_enter_phase")

func _process(delta: float) -> void:
	pass

func _play_audio(player: AudioStreamPlayer3D) -> void:
	_stub("_play_audio")

func _has_valid_placement_contact() -> bool:
	_stub("_has_valid_placement_contact")
	return false

func interact() -> void:
	_stub("interact")

func toggle_piston() -> void:
	_stub("toggle_piston")

func remote_toggle(on: bool) -> void:
	_stub("remote_toggle")

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

func _scan_for_riders() -> void:
	_stub("_scan_for_riders")

func _adopt_rider(body: RigidBody3D) -> void:
	_stub("_adopt_rider")

func _release_rider(index: int, restore_freeze: bool = true) -> void:
	_stub("_release_rider")

func release_all_riders(restore_freeze: bool = true) -> void:
	_stub("release_all_riders")

func release_rider_body(b: Node) -> void:
	_stub("release_rider_body")

func get_piston_save_data() -> Dictionary:
	_stub("get_piston_save_data")
	return {}

func apply_piston_save_data(data: Dictionary) -> void:
	_stub("apply_piston_save_data")
