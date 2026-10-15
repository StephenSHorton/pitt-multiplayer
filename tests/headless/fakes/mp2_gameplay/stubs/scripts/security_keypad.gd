extends Node3D
## Headless stand-in for res://scripts/security_keypad.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/security_keypad_ext.gd compile
## and be exercised headless.

var entry: String = ""
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready() -> void:
	pass

func reveal() -> void:
	_stub("reveal")

func button_pressed(value: int) -> void:
	_stub("button_pressed")

func _on_success() -> void:
	_stub("_on_success")

func _on_fail() -> void:
	_stub("_on_fail")

func _refresh_label() -> void:
	_stub("_refresh_label")

func _on_save_loaded() -> void:
	_stub("_on_save_loaded")
