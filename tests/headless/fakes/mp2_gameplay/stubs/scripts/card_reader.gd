extends Node3D
## Headless stand-in for res://scripts/card_reader.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/card_reader_ext.gd compile
## and be exercised headless.


var status_label: Label3D = null
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

func _refresh_label() -> void:
	_stub("_refresh_label")
