extends StaticBody3D
## Headless stand-in for res://scripts/minable_block.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/minable_block_ext.gd compile
## and be exercised headless.


var damage: float = 0.0
var broken: bool = false
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready() -> void:
	pass

func _process(delta: float) -> void:
	pass

func take_hit(amount: float) -> void:
	_stub("take_hit")

func _on_impact_area_body_entered(body: Node3D) -> void:
	_stub("_on_impact_area_body_entered")

func _play_hit() -> void:
	_stub("_play_hit")

func _update_crack_visuals() -> void:
	_stub("_update_crack_visuals")

func _break_block() -> void:
	_stub("_break_block")

func _spawn_ore() -> void:
	_stub("_spawn_ore")

func get_save_data() -> Dictionary:
	_stub("get_save_data")
	return {}

func apply_saved_state(was_broken: bool) -> void:
	_stub("apply_saved_state")

func object_name() -> String:
	_stub("object_name")
	return ""
