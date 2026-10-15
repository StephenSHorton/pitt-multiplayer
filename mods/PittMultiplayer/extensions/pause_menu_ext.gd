extends "res://scripts/pause_menu.gd"
## PittMultiplayer: pause menu during a session (MP-DESIGN 8.3, 4.4). Inert
## unless a session is live.
##   Load / Delete: refused for everyone (MP_HOST_ONLY)
##   Clear items: refused on clients (MP_HOST_ONLY); the host purges the shared world
##   Save: refused on clients (MP_HOST_SAVES); the host saves normally
##   Main Menu / Quit on the host: the confirm body says the session ends
##   _return_to_main_menu: leave the session first, then the game's full reset


func _mp() -> Object:
	return Engine.get_meta("pitt_mp", null) if Engine.has_meta("pitt_mp") else null


func _mp_role() -> String:
	var mp := _mp()
	return String(mp.ext_role()) if mp != null and mp.has_method("ext_role") else ""


func _mp_restrict(key: String) -> void:
	_play_ui_sound(click_sound, 0.05)
	var hud = get_tree().get_first_node_in_group("HUD")
	if hud:
		hud.show_restrict_message(tr(key))


func _on_save_pressed():
	if _mp_role() == "client":
		_mp_restrict("MP_HOST_SAVES")
		return
	super()


## Clear items recycles every loose product of the shared world: the host's
## world on the host (BODIES despawns them everywhere); refused on clients,
## whose pooled products are puppets of host entities.
func _on_clear_items_pressed() -> void:
	if _mp_role() == "client":
		_mp_restrict("MP_HOST_ONLY")
		return
	super()


func _do_clear_items() -> void:
	if _mp_role() == "client":
		return
	super()


func _on_load_pressed():
	if _mp_role() != "":
		_mp_restrict("MP_HOST_ONLY")
		return
	super()


func _on_delete_save_pressed():
	if _mp_role() != "":
		_mp_restrict("MP_HOST_ONLY")
		return
	super()


## The game builds the dialog body in ConfirmDialog._ready (during add_child);
## child_entered_tree fires before that, so only the body key is swapped.
func _confirm_exit(title_key: String, confirm_key: String, on_exit: Callable, focus_node: Control) -> void:
	if _mp_role() != "host":
		super(title_key, confirm_key, on_exit, focus_node)
		return
	var swap := func(node: Node):
		if "_body_key" in node:
			node._body_key = "MP_CONFIRM_END_SESSION"
	child_entered_tree.connect(swap)
	super(title_key, confirm_key, on_exit, focus_node)
	if child_entered_tree.is_connected(swap):
		child_entered_tree.disconnect(swap)


func _return_to_main_menu():
	var mp := _mp()
	if mp != null and mp.has_method("ext_on_return_to_menu"):
		mp.ext_on_return_to_menu()
	super()
