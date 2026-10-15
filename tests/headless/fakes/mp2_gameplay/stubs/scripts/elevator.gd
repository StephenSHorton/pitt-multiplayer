extends Node3D
## Headless stand-in for res://scripts/elevator.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/elevator_ext.gd compile
## and be exercised headless.


var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready():
	pass

func _on_body_entered(body: Node3D):
	_stub("_on_body_entered")

func _on_body_exited(body: Node3D):
	_stub("_on_body_exited")

func on_hack_success() -> void:
	_stub("on_hack_success")
