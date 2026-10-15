extends CanvasLayer
## Headless stand-in for res://scripts/hud.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/hud_ext.gd compile
## and be exercised headless.

var results: Array = []
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready():
	pass

func _process(_delta):
	pass

func _on_chain_combo_triggered(chain_level: int, bonus: int):
	_stub("_on_chain_combo_triggered")

func _on_diversity_bonus_triggered(product_types: Array, bonus: int):
	_stub("_on_diversity_bonus_triggered")

func _on_rhythm_bonus_triggered(consistency: float, bonus: int):
	_stub("_on_rhythm_bonus_triggered")

func _spawn_special_bonus_text(text: String, color: Color):
	_stub("_spawn_special_bonus_text")

func show_result(combo_level, total_bonus):
	_stub("show_result")
	results.append([combo_level, total_bonus])

func show_restrict_message(message):
	_stub("show_restrict_message")

func show_notification_message(message):
	_stub("show_notification_message")

func on_loading():
	_stub("on_loading")
