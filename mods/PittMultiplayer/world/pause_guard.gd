extends RefCounted
## Pause = local only (MP-DESIGN 8.2), both roles while in_game. The tree is
## never paused in a session: on SceneTree.physics_frame (emitted before physics
## dispatch, even while paused, so no tick is lost) and in the per-frame tick as
## a backstop, a paused tree is unpaused unless exempt (the ending, an
## end-of-game screen, session ending). MenuManager.game_paused / current_menu stay as the game set them, so
## Esc open/close keeps working; while a menu is open the LOCAL player is frozen
## (movement lock + held object released + camera script stopped).
## SaveManager.save_game pauses synchronously inside one call: unaffected.

var adapter = null
var session = null
var active := false
var unpauses := 0
var frozen := false
var _physics_cb: Callable = Callable()
var _sig: Signal = Signal()


func _init(p_session = null, p_adapter = null) -> void:
	session = p_session
	adapter = p_adapter


func install() -> void:
	if active:
		return
	active = true
	_physics_cb = Callable(self, "_on_physics_frame")
	_sig = adapter.physics_frame_signal()
	if not _sig.is_null() and not _sig.is_connected(_physics_cb):
		_sig.connect(_physics_cb)


func uninstall() -> void:
	if not active:
		return
	active = false
	if not _sig.is_null() and _physics_cb.is_valid() and _sig.is_connected(_physics_cb):
		_sig.disconnect(_physics_cb)
	_sig = Signal()
	_set_frozen(false)


func _exempt() -> bool:
	if adapter.ending_active():
		return true
	# the secret ending's end screen pauses without ending_active (end_of_game.gd:102)
	if adapter.has_method("end_screen_open") and adapter.end_screen_open():
		return true
	return session != null and session.has_method("get_state") and session.get_state() == "ending"


func _on_physics_frame() -> void:
	_unpause()


func _unpause() -> void:
	if active and adapter.tree_paused() and not _exempt():
		adapter.unpause_tree()
		unpauses += 1


## Per-frame backstop + the local freeze.
func tick() -> void:
	if not active:
		return
	_unpause()
	_set_frozen(adapter.menu_open())


func _set_frozen(on: bool) -> void:
	if on == frozen:
		return
	frozen = on
	adapter.set_movement_locked(on)
	adapter.set_camera_frozen(on)
