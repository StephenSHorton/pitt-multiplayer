extends "res://scripts/main_menu.gd"
## Thin extension of the main menu (applied by PittAPI with take_over_path). Inert
## unless mp_ui is in host-picking mode (the host pressed Start and the game's own
## save panel is open) or one of our panels is visible. No copied game code: every
## override calls super for the vanilla path. Logic lives in ui/mp_ui.gd.


func _pittmp_ui() -> Object:
	if has_meta("pittmp_ui"):
		var u = get_meta("pittmp_ui")
		if u != null and is_instance_valid(u):
			return u
	if is_inside_tree():
		return get_tree().get_first_node_in_group("pittmp_ui")
	return null


func _pittmp_picking() -> bool:
	var ui = _pittmp_ui()
	return ui != null and ui.has_method("is_host_picking") and ui.is_host_picking()


## Always calls super; tells the session first while the host is picking a save.
func _launch_game(scene_path: String):
	if _pittmp_picking():
		_pittmp_ui().on_host_launch(scene_path)
	super(scene_path)


## While picking, a menu button runs mp_ui's handler instead (with the menu's
## click, and only when the menu takes input).
func _pittmp_take_over(handler: StringName) -> void:
	if not ignore_input:
		_play_ui_sound(click_sound, 0.05)
		_pittmp_ui().call(handler)


## Back from the save panel while picking: back to our lobby (and cancel_start).
func _on_return_save_load():
	if not _pittmp_picking():
		return super()
	_pittmp_take_over(&"on_host_pick_cancelled")


## Sandbox sessions are not supported in MP1.
func _on_sandbox_pressed():
	if not _pittmp_picking():
		return super()
	_pittmp_take_over(&"on_sandbox_blocked")


## Focus our visible panel first (gamepad), else the game's panels.
func _focus_current_panel():
	var ui = _pittmp_ui()
	if ui != null and ui.has_method("focus_current_panel") and ui.focus_current_panel():
		return
	super()
