extends StaticBody3D
## Headless stand-in for res://scripts/gambling_terminal.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/gambling_terminal_ext.gd compile
## and be exercised headless.

var _rolling: bool = false
var _remaining: float = 0.0
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready() -> void:
	pass

func _do_roll_or_stop() -> void:
	_stub("_do_roll_or_stop")

func _process(delta: float) -> void:
	pass

func _resolve(mult: float) -> void:
	_stub("_resolve")

func _reset_roll_labels() -> void:
	_stub("_reset_roll_labels")

func _tick(delta: float) -> void:
	_stub("_tick")

func _sweep(groups: Array, require_unplaced: bool) -> void:
	_stub("_sweep")

func _on_collector_body_entered(body: Node) -> void:
	_stub("_on_collector_body_entered")

func _collect(groups: Array, require_unplaced: bool) -> Array:
	_stub("_collect")
	return []

func _arc_to_intake(body: Node, delay: float = 0.0) -> bool:
	_stub("_arc_to_intake")
	return false

func _bank_and_despawn(body: Node) -> void:
	_stub("_bank_and_despawn")

func _despawn(body: Node) -> void:
	_stub("_despawn")

func _is_placed_tool(body: Node) -> bool:
	_stub("_is_placed_tool")
	return false

func _is_held(body: Node) -> bool:
	_stub("_is_held")
	return false

func _update_button_label() -> void:
	_stub("_update_button_label")

func _burst(p: GPUParticles3D) -> void:
	_stub("_burst")

func _spawn_recycle_cube(payout: int) -> void:
	_stub("_spawn_recycle_cube")

func sweep_tools_all() -> void:
	_stub("sweep_tools_all")
