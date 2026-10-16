extends RigidBody3D
## Headless stand-in for res://scripts/golf_club.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/golf_club_ext.gd compile
## and be exercised headless.

var pool_id = "toy_golf_club"
var equipped_offset: Vector3 = Vector3.ZERO
var is_equipped: bool = false
var golf_ball: RigidBody3D = null
var power_ratio: float = 0.0
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready():
	pass

func _physics_process(_delta: float) -> void:
	pass

func _process(delta: float) -> void:
	pass

func _input(event: InputEvent) -> void:
	pass

func _fire_shot() -> void:
	_stub("_fire_shot")

func _exit_aim_mode() -> void:
	_stub("_exit_aim_mode")

func _update_trajectory() -> void:
	_stub("_update_trajectory")

func _create_trajectory_renderer() -> void:
	_stub("_create_trajectory_renderer")

func _draw_trajectory_line(points: PackedVector3Array, first_bounce_idx: int) -> void:
	_stub("_draw_trajectory_line")

func _hide_trajectory() -> void:
	_stub("_hide_trajectory")

func _play_swing_animation(strength: float) -> void:
	_stub("_play_swing_animation")

func _on_product_consumed(_product_type: String, _nutrition_value: int, body_id: int = -1) -> void:
	_stub("_on_product_consumed")

func _award_hole_in_one_delayed(bonus: int, maw_pos: Vector3) -> void:
	_stub("_award_hole_in_one_delayed")

func equip(camera: Camera3D):
	_stub("equip")

func unequip(world: Node3D, drop_pos: Vector3):
	_stub("unequip")

func set_highlight(active: bool, grabbed: bool = false) -> void:
	_stub("set_highlight")

func object_name() -> String:
	_stub("object_name")
	return ""

func get_reset_basis() -> Basis:
	_stub("get_reset_basis")
	return Basis.IDENTITY

func _on_body_entered(_body):
	_stub("_on_body_entered")

func _calculate_collision_volume(impact_force: float) -> float:
	_stub("_calculate_collision_volume")
	return 0.0

func on_pool_spawn():
	_stub("on_pool_spawn")

func on_pool_recycle():
	_stub("on_pool_recycle")

func _process_idle(_delta: float) -> void:
	_stub("_process_idle")

func _hide_ball_indicator() -> void:
	_stub("_hide_ball_indicator")
