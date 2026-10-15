extends RefCounted
## PittInput: mod keybinds. Actions are named mod_<id>_<name>, added straight to
## the InputMap and persisted in user://pittapi/keybinds.cfg. They are NOT added to
## InputManager.current_bindings, because the game's save_bindings() would write
## them into keybindings.cfg. apply_bindings() only touches its own actions, but we
## re-assert ours on bindings_changed anyway.

var _core: Object = null
var _mod := ""


func _init(core: Object, mod_id: String) -> void:
	_core = core
	_mod = mod_id


func _reg() -> Object:
	return _core.input_registry


## Returns the InputMap action name, or "" on error. default_pad < 0 = no pad button.
func register_action(name: String, default_key: Key, label: String = "", default_pad: int = -1) -> String:
	return _reg().register(_mod, name, int(default_key), label, default_pad)


func rebind(name: String, key: Key) -> Error:
	return _reg().rebind(_mod, name, int(key))


func get_key(name: String) -> int:
	return _reg().get_key(_mod, name)


func get_key_name(name: String) -> String:
	return _reg().key_name(_reg().get_key(_mod, name))


func action_name(name: String) -> String:
	return Registry.action_for(_mod, name)


func is_pressed(name: String) -> bool:
	var a := Registry.action_for(_mod, name)
	return InputMap.has_action(a) and Input.is_action_pressed(a)


## Game actions and other mod actions bound to the same key.
func conflicts(name: String) -> Array[String]:
	return _reg().conflicts(_mod, name)


func list() -> Array:
	return _reg().list(_mod)


class Registry extends RefCounted:
	var _core: Object = null
	var cfg_path := ""
	var _cfg := ConfigFile.new()
	var actions: Dictionary = {}   # action -> {owner, name, key, pad, label}

	func _init(core: Object, path: String) -> void:
		_core = core
		cfg_path = path
		if FileAccess.file_exists(cfg_path):
			_cfg.load(cfg_path)

	static func action_for(mod_id: String, name: String) -> String:
		return "mod_%s_%s" % [mod_id, name]

	func register(owner: String, name: String, default_key: int, label: String, pad: int) -> String:
		var re := RegEx.new()
		re.compile("^[A-Za-z0-9_]{1,48}$")
		if re.search(name) == null:
			_warn("input: invalid action name '%s'" % name)
			return ""
		var action := action_for(owner, name)
		var key := int(_cfg.get_value(owner, name, default_key))
		var pad_btn := int(_cfg.get_value(owner, name + ".pad", pad))
		actions[action] = {"owner": owner, "name": name, "key": key, "pad": pad_btn,
			"default": default_key, "label": label if label != "" else name}
		_apply(action)
		return action

	func rebind(owner: String, name: String, key: int) -> Error:
		var action := action_for(owner, name)
		if not actions.has(action):
			return ERR_DOES_NOT_EXIST
		actions[action].key = key
		_apply(action)
		_cfg.set_value(owner, name, key)
		return _save()

	func get_key(owner: String, name: String) -> int:
		var a := action_for(owner, name)
		return int(actions[a].key) if actions.has(a) else 0

	## The events an action of ours maps to: key 1..9 is a mouse button, a larger
	## key a physical keycode, pad >= 0 a joypad button.
	static func _events_for(a: Dictionary) -> Array[InputEvent]:
		var out: Array[InputEvent] = []
		if a.key >= 1 and a.key <= 9:
			var mb := InputEventMouseButton.new()
			mb.button_index = a.key
			out.append(mb)
		elif a.key > 9:
			var kb := InputEventKey.new()
			kb.physical_keycode = a.key
			out.append(kb)
		if a.pad >= 0:
			var jb := InputEventJoypadButton.new()
			jb.button_index = a.pad
			out.append(jb)
		return out

	func _apply(action: String) -> void:
		var wanted := _events_for(actions[action])
		if not InputMap.has_action(action):
			InputMap.add_action(action)
		InputMap.action_erase_events(action)
		for e in wanted:
			InputMap.action_add_event(action, e)

	## Re-adds our actions if anything erased them (InputManager.bindings_changed).
	func reassert() -> void:
		for action in actions:
			if not InputMap.has_action(action) or InputMap.action_get_events(action).is_empty():
				_apply(action)

	func remove_owner(owner: String) -> void:
		for action in actions.keys():
			if actions[action].owner != owner:
				continue
			if InputMap.has_action(action):
				InputMap.erase_action(action)
			actions.erase(action)

	func key_name(code: int) -> String:
		if code == 0:
			return "Unbound"
		var im = _core.g("InputManager") if _core.feature_ok("input") else null
		return String(im.get_key_name(code)) if im != null else OS.get_keycode_string(code)

	func conflicts(owner: String, name: String) -> Array[String]:
		var out: Array[String] = []
		var action := action_for(owner, name)
		if not actions.has(action):
			return out
		var key: int = actions[action].key
		if key == 0:
			return out
		var im = _core.g("InputManager") if _core.feature_ok("input") else null
		if im != null:
			var game_action := String(im.get_action_for_key(key))
			if game_action != "":
				out.append(game_action)
		for other in actions:
			if other != action and actions[other].key == key:
				out.append(other)
		return out

	func list(owner: String = "") -> Array:
		var out: Array = []
		for action in actions:
			var a: Dictionary = actions[action]
			if owner == "" or a.owner == owner:
				out.append({"action": action, "owner": a.owner, "name": a.name, "key": a.key,
					"key_name": key_name(a.key), "label": a.label, "pad": a.pad})
		return out

	## Called from PittAPI._input. Emits input.action for our actions.
	func handle_event(event: InputEvent) -> void:
		if event is InputEventKey and event.echo:
			return
		for action in actions:
			if not InputMap.has_action(action):
				continue
			if event.is_action_pressed(action, false, true):
				_core.events.emit_internal("input.action", {"action": action, "name": actions[action].name,
					"mod": actions[action].owner, "pressed": true}, "api")
			elif event.is_action_released(action, true):
				_core.events.emit_internal("input.action", {"action": action, "name": actions[action].name,
					"mod": actions[action].owner, "pressed": false}, "api")

	func _save() -> Error:
		DirAccess.make_dir_recursive_absolute(cfg_path.get_base_dir())
		return _core.safe_fs.save_config(_cfg, cfg_path)

	func _warn(msg: String) -> void:
		if _core.log != null:
			_core.log.warn(msg)
