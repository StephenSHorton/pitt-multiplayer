extends RefCounted
## PittHud: toasts on PittAPI's own layer (works everywhere), plus passthroughs to
## the World HUD (banner, floating text) that are no-ops outside the world.
## Toasts are local; multiplayer will add a replicated toast event.

var _core: Object = null
var _mod := ""


func _init(core: Object, mod_id: String) -> void:
	_core = core
	_mod = mod_id


## opts: {duration = 3.0, color = Color, font_size = 12}
func toast(text: String, opts: Dictionary = {}) -> Control:
	if _core.toast_layer == null:
		return null
	var o := opts.duplicate()
	o["owner"] = _mod
	return _core.toast_layer.toast(text, o)


func _world_hud() -> Node:
	if not _core.bridge.in_world or not _core.feature_ok("hud"):
		return null
	var tree: SceneTree = _core.get_tree()
	# every HUD method assumes main_camera exists (it screen-shakes without a null check)
	if tree.get_first_node_in_group("main_camera") == null:
		return null
	return tree.get_first_node_in_group("HUD")


## Big centred notification (HUD.show_notification_message). Shakes the screen and
## plays a sound, like the game's own notifications. Returns false outside the world.
func banner(text: String) -> bool:
	var hud = _world_hud()
	if hud == null or not hud.has_method("show_notification_message"):
		return false
	hud.show_notification_message(text)
	return true


## Floating text that rises and fades (HUD._spawn_special_bonus_text).
func floating_text(text: String, color: Color = Color.WHITE) -> bool:
	var hud = _world_hud()
	if hud == null or not hud.has_method("_spawn_special_bonus_text"):
		return false
	hud._spawn_special_bonus_text(text, color)
	return true


## Adds a mod overlay Control on PittAPI's layer. Removed on quarantine.
func add_panel(id: String, control: Control) -> Error:
	if _core.toast_layer == null:
		return ERR_UNCONFIGURED
	return _core.toast_layer.add_panel("%s.%s" % [_mod, id], control, _mod)


func remove_panel(id: String) -> void:
	if _core.toast_layer != null:
		_core.toast_layer.remove_panel("%s.%s" % [_mod, id])


func has_panel(id: String) -> bool:
	return _core.toast_layer != null and _core.toast_layer.has_panel("%s.%s" % [_mod, id])
