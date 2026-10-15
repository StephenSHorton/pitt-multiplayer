extends MeshInstance3D
## Headless stand-in for res://scripts/erasable_text.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/erasable_text_ext.gd compile
## and be exercised headless.

var shader = null
var font_size: int = 0
var _fully_erased: bool = false
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready() -> void:
	pass

func _process(_dt: float) -> void:
	pass

func _notification(what: int) -> void:
	pass

func _apply_fully_erased() -> void:
	_stub("_apply_fully_erased")

func _award_clean() -> void:
	_stub("_award_clean")

func get_save_data() -> Dictionary:
	_stub("get_save_data")
	return {}

func apply_saved_state(erased: bool) -> void:
	_stub("apply_saved_state")
