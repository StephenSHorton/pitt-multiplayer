extends Area3D
## Headless stand-in for res://scripts/bottom_maw.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/bottom_maw_ext.gd compile
## and be exercised headless.

signal product_consumed(product_type, nutrition_value, body_id)
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

func _on_body_entered(body):
	_stub("_on_body_entered")

func _handle_body_cleanup(body: Node3D, product_type: String, should_free: bool):
	_stub("_handle_body_cleanup")

func _recycle(body):
	_stub("_recycle")

func maw_effect(object_type: String, body_position: Vector3):
	_stub("maw_effect")

func _maw_fine() -> int:
	_stub("_maw_fine")
	return 0
