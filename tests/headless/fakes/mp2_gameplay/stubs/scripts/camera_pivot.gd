extends RigidBody3D
## Headless stand-in for res://scripts/camera_pivot.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/camera_pivot_ext.gd compile
## and be exercised headless.


var camera_id: String = ""
var is_destroyed: bool = false
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready():
	pass

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	pass

func _physics_process(delta: float) -> void:
	pass

func destroy_camera():
	_stub("destroy_camera")

func get_save_data() -> Dictionary:
	_stub("get_save_data")
	return {}

func apply_saved_state(state: bool):
	_stub("apply_saved_state")
