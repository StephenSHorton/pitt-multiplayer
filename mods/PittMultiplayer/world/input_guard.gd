extends RefCounted
## Input guard (MP-DESIGN 8.3). player_controller._input polls
## Input.is_action_just_pressed("quick_save"/"quick_load"), so filtering input
## events cannot block F5/F9 (R16): their InputMap events are erased instead
## (quick_load on every peer, quick_save on clients), re-erased whenever
## InputManager.bindings_changed fires, and restored with
## InputManager.apply_bindings(). keybindings.cfg is never written.

const QUICK_SAVE := "quick_save"
const QUICK_LOAD := "quick_load"

var adapter = null
var active := false
var actions: Array = []
var _sig: Signal = Signal()
var _cb: Callable = Callable()
var reerased := 0


func _init(p_adapter = null) -> void:
	adapter = p_adapter


func install(role: String) -> void:
	if active:
		return
	active = true
	actions = [QUICK_LOAD] if role == "host" else [QUICK_LOAD, QUICK_SAVE]
	adapter.erase_action_events(actions)
	_cb = Callable(self, "_on_bindings_changed")
	_sig = adapter.bindings_changed_signal()
	if not _sig.is_null() and not _sig.is_connected(_cb):
		_sig.connect(_cb)


func _on_bindings_changed() -> void:
	if active:
		reerased += 1
		adapter.erase_action_events(actions)


func uninstall() -> void:
	if not active:
		return
	active = false
	# disconnect first: apply_bindings() emits bindings_changed itself
	if not _sig.is_null() and _cb.is_valid() and _sig.is_connected(_cb):
		_sig.disconnect(_cb)
	_sig = Signal()
	adapter.restore_bindings()
