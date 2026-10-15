extends RigidBody3D
## Headless stand-in for res://scripts/proxy_intern.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/proxy_intern_ext.gd compile
## and be exercised headless.


var pool_id = "tool_auto_crafter"
var is_active: bool = false
var placed = false
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready():
	pass

func _process(delta):
	pass

func _physics_process(_delta):
	pass

func object_name() -> String:
	_stub("object_name")
	return ""

func _update_latch() -> void:
	_stub("_update_latch")

func _latch(bench: Node3D) -> void:
	_stub("_latch")

func _unlatch() -> void:
	_stub("_unlatch")

func _drive_target() -> void:
	_stub("_drive_target")

func interact():
	_stub("interact")

func remote_toggle(on: bool) -> void:
	_stub("remote_toggle")

func place():
	_stub("place")

func unplace():
	_stub("unplace")

func get_reset_basis() -> Basis:
	_stub("get_reset_basis")
	return Basis.IDENTITY

func _on_body_entered(_body):
	_stub("_on_body_entered")

func on_pool_spawn():
	_stub("on_pool_spawn")

func on_pool_recycle():
	_stub("on_pool_recycle")

func set_highlight(active: bool, grabbed: bool = false) -> void:
	_stub("set_highlight")
