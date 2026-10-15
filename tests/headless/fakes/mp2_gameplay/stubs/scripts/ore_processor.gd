extends Node3D
## Headless stand-in for res://scripts/ore_processor.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/ore_processor_ext.gd compile
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

func _physics_process(delta: float) -> void:
	pass

func _on_intake_body_entered(body: Node3D) -> void:
	_stub("_on_intake_body_entered")

func _process_ore(ore: RigidBody3D) -> void:
	_stub("_process_ore")

func _process_pickaxe(pickaxe: RigidBody3D) -> void:
	_stub("_process_pickaxe")

func _drop_at_output(body: RigidBody3D) -> void:
	_stub("_drop_at_output")

func place_lamp_at_output(announce: bool = false) -> void:
	_stub("place_lamp_at_output")

func _update_labels() -> void:
	_stub("_update_labels")

func _on_save_loaded() -> void:
	_stub("_on_save_loaded")

func reconcile_lost_ore() -> void:
	_stub("reconcile_lost_ore")
