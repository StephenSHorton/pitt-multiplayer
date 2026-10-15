extends RigidBody3D
## Headless stand-in for res://scripts/speed_radar.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/speed_radar_ext.gd compile
## and be exercised headless.


var pool_id = "toy_speed_radar"
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

func _physics_process(_delta: float) -> void:
	pass

func _process(delta: float) -> void:
	pass

func _on_detection_body_entered(body: Node3D) -> void:
	_stub("_on_detection_body_entered")

func _on_product_consumed(_product_type: String, base_value: int, body_id: int = -1) -> void:
	_stub("_on_product_consumed")

func _award_speeding_bonus(bonus: int, speed: float) -> void:
	_stub("_award_speeding_bonus")

func _play_audio(player: AudioStreamPlayer3D) -> void:
	_stub("_play_audio")

func _trigger_flash(intensity: float = 1.0) -> void:
	_stub("_trigger_flash")

func object_name() -> String:
	_stub("object_name")
	return ""

func set_highlight(active: bool, grabbed: bool = false) -> void:
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

func on_pool_spawn() -> void:
	_stub("on_pool_spawn")

func on_pool_recycle() -> void:
	_stub("on_pool_recycle")
