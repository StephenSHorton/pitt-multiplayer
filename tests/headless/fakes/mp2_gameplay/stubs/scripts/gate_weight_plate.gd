extends Node3D
## Headless stand-in for res://scripts/gate_weight_plate.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/gate_weight_plate_ext.gd compile
## and be exercised headless.

const PLAYER_MASS = 8.0
var pressure_area: Area3D = null
var current_mass: float = 0.0
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

func _physics_process(_delta):
	pass

func _on_body_entered(body: Node3D):
	_stub("_on_body_entered")

func _on_body_exited(body: Node3D):
	_stub("_on_body_exited")

func _recalculate_mass():
	_stub("_recalculate_mass")

func _update_gauge():
	_stub("_update_gauge")
