extends Node3D
## Headless stand-in for res://scripts/loop_puzzle.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/loop_puzzle_ext.gd compile
## and be exercised headless.

var player_run_energy: float = 0.0
var energy: float = 0.0
var clone_count: int = 0
var speed_level: int = 0
var energy_level: int = 0
var best_time: float = 0.0
var best_path: PackedVector3Array = PackedVector3Array()
var is_solved: bool = false
var _recording: bool = false
var _run_clock: float = 0.0
var _current_path: PackedVector3Array = PackedVector3Array()
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready() -> void:
	pass

func _on_end_entered(body: Node3D) -> void:
	_stub("_on_end_entered")

func _reset_object(body: Node3D) -> void:
	_stub("_reset_object")

func _is_placed_object(body: Object) -> bool:
	_stub("_is_placed_object")
	return false

func _physics_process(delta: float) -> void:
	pass

func _set_new_best(t: float, path: PackedVector3Array) -> void:
	_stub("_set_new_best")

func _process(delta: float) -> void:
	pass

func on_button(action: String) -> void:
	_stub("on_button")

func _check_win() -> void:
	_stub("_check_win")

func _solve() -> void:
	_stub("_solve")

func _refresh_labels() -> void:
	_stub("_refresh_labels")

func get_save_state() -> Dictionary:
	_stub("get_save_state")
	return {}

func apply_save_state(d: Dictionary) -> void:
	_stub("apply_save_state")
