extends RigidBody3D
## Headless stand-in for res://scripts/cannon.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/cannon_ext.gd compile
## and be exercised headless.

var pool_id = "tool_cannon"
var is_equipped: bool = false
var equipped_offset: Vector3 = Vector3.ZERO
var equipped_rotation_deg: Vector3 = Vector3.ZERO
var muzzle: Marker3D = null
var placed: bool = false
var _queue: Array = []
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

func _on_intake_body_entered(body: Node3D) -> void:
	_stub("_on_intake_body_entered")

func _try_auto_load() -> void:
	_stub("_try_auto_load")

func _load_body(body: RigidBody3D) -> void:
	_stub("_load_body")

func fire() -> bool:
	_stub("fire")
	return false

func _trigger_muzzle_flash() -> void:
	_stub("_trigger_muzzle_flash")

func _emit_smoke() -> void:
	_stub("_emit_smoke")

func _play_audio(player: AudioStreamPlayer3D, pitch: float) -> void:
	_stub("_play_audio")

func interact() -> void:
	_stub("interact")

func remote_toggle(on: bool) -> void:
	_stub("remote_toggle")

func remote_pulse() -> void:
	_stub("remote_pulse")

func equip(camera: Camera3D) -> void:
	_stub("equip")

func unequip(world: Node3D, drop_pos: Vector3) -> void:
	_stub("unequip")

func place() -> void:
	_stub("place")

func unplace() -> void:
	_stub("unplace")

func object_name() -> String:
	_stub("object_name")
	return ""

func set_highlight(active: bool, _grabbed: bool = false) -> void:
	_stub("set_highlight")

func get_reset_basis() -> Basis:
	_stub("get_reset_basis")
	return Basis.IDENTITY

func _update_trajectory() -> void:
	_stub("_update_trajectory")

func _create_trajectory_renderer() -> void:
	_stub("_create_trajectory_renderer")

func _draw_trajectory_line(points: PackedVector3Array, first_bounce_idx: int) -> void:
	_stub("_draw_trajectory_line")

func _hide_trajectory() -> void:
	_stub("_hide_trajectory")

func _exit_tree() -> void:
	pass

func _on_body_entered(_body) -> void:
	_stub("_on_body_entered")

func on_pool_spawn() -> void:
	_stub("on_pool_spawn")

func on_pool_recycle() -> void:
	_stub("on_pool_recycle")

func _force_clear_queue() -> void:
	_stub("_force_clear_queue")

func get_queue_save_data() -> Array:
	_stub("get_queue_save_data")
	return []

func apply_loaded_queue(queue_data: Array) -> void:
	_stub("apply_loaded_queue")
