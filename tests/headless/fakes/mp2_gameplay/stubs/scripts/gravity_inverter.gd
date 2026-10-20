extends RigidBody3D
## Headless stand-in for res://scripts/gravity_inverter.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/gravity_inverter_ext.gd compile
## and be exercised headless.
## P12 (force guards): a minimal own-code target flow (stub_* inputs, stub_pushed
## records every apply_central_force) so the field-tool guards can be exercised.


var pool_id = "tool_gravity_inverter"
var value = 1
var is_active: bool = false
var is_equipped: bool = false
var equipped_offset: Vector3 = Vector3.ZERO
var placed = false
var _outer_targets: Array[RigidBody3D] = []
var _inner_targets: Array[RigidBody3D] = []
## tests: stand-ins for the outer / inner field overlaps
var stub_outer: Array = []
var stub_inner: Array = []
var stub_pushed: Array = []
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
	_outer_targets = _filter_and_cap(stub_outer)
	_inner_targets = _filter_and_cap(stub_inner)

func _filter_and_cap(raw_bodies: Array) -> Array[RigidBody3D]:
	var out: Array[RigidBody3D] = []
	for b in raw_bodies:
		if b is RigidBody3D and b != self:
			out.append(b)
	return out

func _apply_field_forces() -> void:
	for b in _outer_targets + _inner_targets:
		b.apply_central_force(Vector3.UP)
		stub_pushed.append(b)

func toggle_field() -> void:
	_stub("toggle_field")

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
