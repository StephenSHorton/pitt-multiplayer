extends StaticBody3D
## Headless stand-in for res://scripts/bowling_pin_set.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/bowling_pin_set_ext.gd compile
## and be exercised headless.


var _pins: Array = []
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready() -> void:
	pass

func _exit_tree() -> void:
	pass

func _process(delta: float) -> void:
	pass

func _spawn_pins() -> void:
	_stub("_spawn_pins")

func _despawn_pins() -> void:
	_stub("_despawn_pins")

func _check_pin_states() -> void:
	_stub("_check_pin_states")

func _register_knockdown(pin: RigidBody3D) -> void:
	_stub("_register_knockdown")

func _update_multiplier() -> void:
	_stub("_update_multiplier")

func _push_multiplier(value: float) -> void:
	_stub("_push_multiplier")

func _spawn_bowling_label(value: float) -> void:
	_stub("_spawn_bowling_label")

func _play_audio(player: AudioStreamPlayer3D) -> void:
	_stub("_play_audio")

func object_name() -> String:
	_stub("object_name")
	return ""
