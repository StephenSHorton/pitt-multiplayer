extends "res://scripts/magnet.gd"
## Headless stand-in for res://scripts/magnet_2.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/magnet_2_ext.gd compile
## and be exercised headless.


func _ready() -> void:
	pass

func _physics_process(_delta: float) -> void:
	pass

func scroll_tune_up() -> void:
	_stub("scroll_tune_up")

func scroll_tune_down() -> void:
	_stub("scroll_tune_down")

func flip_mode(direction: bool) -> void:
	_stub("flip_mode")

func on_pool_spawn() -> void:
	_stub("on_pool_spawn")

func on_pool_recycle() -> void:
	_stub("on_pool_recycle")

func object_name() -> String:
	_stub("object_name")
	return ""

func _is_repell() -> bool:
	_stub("_is_repell")
	return false
