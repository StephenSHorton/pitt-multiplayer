extends Node
## Headless fake of InputManager: owns only its own actions, like the game.

signal bindings_changed

var default_bindings := {"up": KEY_W, "down": KEY_S, "quick_save": KEY_F5}
var current_bindings := {}


func _ready() -> void:
	current_bindings.merge(default_bindings)
	apply_bindings()


## one physical key per action
func apply_bindings() -> void:
	for name in current_bindings:
		if not InputMap.has_action(name):
			InputMap.add_action(name)
		InputMap.action_erase_events(name)
		var key_ev := InputEventKey.new()
		key_ev.physical_keycode = current_bindings[name]
		InputMap.action_add_event(name, key_ev)
	bindings_changed.emit()


func save_bindings() -> void:
	var cfg := ConfigFile.new()
	for k in current_bindings:
		cfg.set_value("keybindings", k, current_bindings[k])
	cfg.save("user://keybindings.cfg")


func get_action_for_key(code: int) -> String:
	var found = current_bindings.find_key(code)
	return "" if found == null else String(found)


func get_key_name(code: int) -> String:
	return "Unbound" if code == 0 else OS.get_keycode_string(code)
