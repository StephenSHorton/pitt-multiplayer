extends RigidBody3D
## Headless stand-in for res://scripts/pickaxe.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/pickaxe_ext.gd compile
## and be exercised headless.


var is_equipped: bool = false
var equipped_offset: Vector3 = Vector3.ZERO
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready() -> void:
	pass

func _physics_process(_delta: float) -> void:
	pass

func _process(delta: float) -> void:
	pass

func equipped_lmb_pressed() -> void:
	_stub("equipped_lmb_pressed")

func equipped_lmb_held() -> void:
	_stub("equipped_lmb_held")

func _resolve_hit() -> void:
	_stub("_resolve_hit")

func _break_tool(t: Node3D) -> void:
	_stub("_break_tool")

func _play_swing_animation() -> void:
	_stub("_play_swing_animation")

func upgrade_tier() -> bool:
	_stub("upgrade_tier")
	return false

func _apply_tier_visual() -> void:
	_stub("_apply_tier_visual")

func equip(camera: Camera3D) -> void:
	_stub("equip")

func unequip(world: Node3D, drop_pos: Vector3) -> void:
	_stub("unequip")

func _on_save_loaded() -> void:
	_stub("_on_save_loaded")

func get_equipped_controls_text(ctrl_func: Callable, _looking_at_toggle: bool, _looking_at_linked: bool) -> String:
	_stub("get_equipped_controls_text")
	return ""

func set_highlight(active: bool, grabbed: bool = false) -> void:
	_stub("set_highlight")

func object_name() -> String:
	_stub("object_name")
	return ""

func _on_body_entered(_body) -> void:
	_stub("_on_body_entered")

func recover_to_home() -> void:
	_stub("recover_to_home")
