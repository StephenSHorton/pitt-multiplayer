extends "res://scripts/vacuum.gd"
## Headless stand-in for res://scripts/vacuum_2.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/vacuum_2_ext.gd compile
## and be exercised headless.


func _ready() -> void:
	pass

func _suction_accepts(body: RigidBody3D) -> bool:
	_stub("_suction_accepts")
	return true   # no filter selected accepts everything

func _get_release_marker() -> Marker3D:
	_stub("_get_release_marker")
	return null

func remote_toggle(on: bool) -> void:
	_stub("remote_toggle")

func scroll_tune_up() -> void:
	_stub("scroll_tune_up")

func scroll_tune_down() -> void:
	_stub("scroll_tune_down")

func cycle_filter(direction: int) -> void:
	_stub("cycle_filter")

func on_pool_spawn() -> void:
	_stub("on_pool_spawn")

func object_name() -> String:
	_stub("object_name")
	return ""
