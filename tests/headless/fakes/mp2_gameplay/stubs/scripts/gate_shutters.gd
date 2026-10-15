extends Node3D
## Headless stand-in for res://scripts/gate_shutters.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/gate_shutters_ext.gd compile
## and be exercised headless.


var _slot_fuse_map: Dictionary = {}
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready():
	pass

func _on_fuse_slot_body_entered(body: Node3D, slot_index: int):
	_stub("_on_fuse_slot_body_entered")

func apply_shutters_saved_state(data: Dictionary):
	_stub("apply_shutters_saved_state")
