extends RigidBody3D
## Headless stand-in for res://scripts/remote.gd, generated from the decompiled
## signatures by the GAMEPLAY stream (our own minimal code: every function only
## records its call, stub_calls / stub_hook). Lets extensions/gameplay/remote_ext.gd compile
## and be exercised headless.


var pool_id = "tool_remote"
var is_equipped: bool = false
var equipped_offset: Vector3 = Vector3.ZERO
var status_label: Label = null
var is_active: bool = false
var current_channel: int = 0
var placed = false
var stub_calls: Array = []
## tests: called with the method name inside every recorded stub call
var stub_hook: Callable = Callable()


func _stub(n: String) -> void:
	stub_calls.append(n)
	if stub_hook.is_valid():
		stub_hook.call(n)


func _ready():
	pass

func _process(delta):
	pass

func _physics_process(_delta):
	pass

func remote_lmb_pressed():
	_stub("remote_lmb_pressed")

func cycle_channel(direction: int = 1):
	_stub("cycle_channel")

func try_interact_with_target(target: Node3D) -> bool:
	_stub("try_interact_with_target")
	return false

func _toggle_channel(channel_idx: int):
	_stub("_toggle_channel")

func _toggle_all_channels():
	_stub("_toggle_all_channels")

func try_link_tool(tool_node: Node3D) -> bool:
	_stub("try_link_tool")
	return false

func unlink_tool(tool_node: Node3D):
	_stub("unlink_tool")

func unlink_all():
	_stub("unlink_all")

func _update_screen():
	_stub("_update_screen")

func get_equipped_controls_text(ctrl_func: Callable, looking_at_toggle: bool, looking_at_linked: bool) -> String:
	_stub("get_equipped_controls_text")
	return ""

func remote_toggle(on: bool) -> void:
	_stub("remote_toggle")

func object_name():
	_stub("object_name")

func interact():
	_stub("interact")

func set_highlight(active: bool, _grabbed: bool = false) -> void:
	_stub("set_highlight")

func equip(camera: Camera3D):
	_stub("equip")

func unequip(world: Node3D, drop_pos: Vector3):
	_stub("unequip")

func place():
	_stub("place")

func unplace():
	_stub("unplace")

func get_reset_basis() -> Basis:
	_stub("get_reset_basis")
	return Basis.IDENTITY

func _on_body_entered(_body):
	_stub("_on_body_entered")

func _play_audio(player: AudioStreamPlayer3D):
	_stub("_play_audio")

func on_pool_spawn():
	_stub("on_pool_spawn")

func on_pool_recycle():
	_stub("on_pool_recycle")
