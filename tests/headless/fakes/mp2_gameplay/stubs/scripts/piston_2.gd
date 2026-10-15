extends "res://scripts/piston.gd"
## Headless stand-in for res://scripts/piston_2.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/piston_2_ext.gd compile
## and be exercised headless.


var _current_preset_index: int = 0


func _ready() -> void:
	pass

func scroll_tune_up() -> void:
	_stub("scroll_tune_up")

func scroll_tune_down() -> void:
	_stub("scroll_tune_down")

func cycle_preset(direction: int) -> void:
	_stub("cycle_preset")

func set_preset(index: int, play_feedback: bool) -> void:
	_stub("set_preset")

func on_pool_spawn() -> void:
	_stub("on_pool_spawn")

func on_pool_recycle() -> void:
	_stub("on_pool_recycle")

func object_name() -> String:
	_stub("object_name")
	return ""
