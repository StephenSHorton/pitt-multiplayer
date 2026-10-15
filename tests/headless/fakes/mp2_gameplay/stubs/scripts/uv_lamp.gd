extends RigidBody3D
## Headless stand-in for res://scripts/uv_lamp.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/uv_lamp_ext.gd compile
## and be exercised headless.


var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready() -> void:
	pass

func recover_to_home() -> void:
	_stub("recover_to_home")

func object_name() -> String:
	_stub("object_name")
	return ""

func interact() -> void:
	_stub("interact")

func set_highlight(active: bool, _grabbed: bool = false) -> void:
	_stub("set_highlight")

func on_loading() -> void:
	_stub("on_loading")

func collect_on_grab() -> void:
	_stub("collect_on_grab")
