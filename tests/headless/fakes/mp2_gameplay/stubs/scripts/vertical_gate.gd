extends Node3D
## Headless stand-in for res://scripts/vertical_gate.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/vertical_gate_ext.gd compile
## and be exercised headless.

signal gate_opened(gate_id)

var gate_id: String = ""
var is_solved: bool = false
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready():
	pass

func solve():
	_stub("solve")

func get_save_data() -> Dictionary:
	_stub("get_save_data")
	return {}

func apply_saved_state(solved: bool):
	_stub("apply_saved_state")
