extends RigidBody3D
## Headless stand-in for res://scripts/qa_arm.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/qa_arm_ext.gd compile
## and be exercised headless.


var pool_id = "tool_qa_arm"
var is_active: bool = false
var player_bonk_impulse: float = 0.0
var player_bonk_lift: float = 0.0
var turret_pivot: Node3D = null
var _state: int = 0
var _yaw: float = 0.0
var _whacked: Dictionary = {}
var placed: bool = false
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

func _fire(intercept: Dictionary) -> void:
	_stub("_fire")

func _is_valid_target(b: Node) -> bool:
	_stub("_is_valid_target")
	return false

func _whack(body: Node) -> void:
	_stub("_whack")

func _play_whack_audio() -> void:
	_stub("_play_whack_audio")

func _drive_bat() -> void:
	_stub("_drive_bat")

func interact() -> void:
	_stub("interact")

func toggle_arm() -> void:
	_stub("toggle_arm")

func remote_toggle(on: bool) -> void:
	_stub("remote_toggle")

func object_name() -> String:
	_stub("object_name")
	return ""

func on_pool_spawn() -> void:
	_stub("on_pool_spawn")

func on_pool_recycle() -> void:
	_stub("on_pool_recycle")

func _has_valid_placement_contact() -> bool:
	_stub("_has_valid_placement_contact")
	return false

func set_highlight(active: bool, _grabbed: bool = false) -> void:
	_stub("set_highlight")

func get_reset_basis() -> Basis:
	_stub("get_reset_basis")
	return Basis.IDENTITY

func place() -> void:
	_stub("place")

func unplace() -> void:
	_stub("unplace")
