extends Node3D
## Headless stand-in for res://scripts/gate_power_generator.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/gate_power_generator_ext.gd compile
## and be exercised headless.


var accumulated_value: float = 0.0
var _activated: bool = false
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready():
	pass

func _physics_process(delta: float) -> void:
	pass

func _on_intake_body_entered(body: Node3D):
	_stub("_on_intake_body_entered")

func _trigger_power_up():
	_stub("_trigger_power_up")

func apply_generator_saved_state(data: Dictionary):
	_stub("apply_generator_saved_state")
