extends RefCounted
## PittSaves: read-only save slot metadata plus per-mod data in sidecar files
## user://pittapi/saves/<save-key>/<mod_id>.json. The API never writes, renames or
## deletes savegame*, sandbox.save* or profile.cfg.

signal mod_data_loaded()

var _core: Object = null
var _mod := ""


func _init(core: Object, mod_id: String) -> void:
	_core = core
	_mod = mod_id


## Basename of SaveManager.active_save_path: "savegame", "savegame_3", "sandbox", ...
func get_active_save_key() -> String:
	return _core.sidecar.active_key


## Read-only re-implementation of SaveManager.get_all_slot_infos(): the game's own
## version caches into profile.cfg, so we read the files ourselves instead.
func get_slot_infos() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var sm = _core.g("SaveManager") if _core.feature_ok("saves") else null
	if sm == null:
		return out
	var n := int(sm.get_script().get_script_constant_map().get("MAX_SAVE_SLOTS", 10))
	var profile := ConfigFile.new()
	var profile_path := "user://profile.cfg"
	var has_profile := FileAccess.file_exists(profile_path) and profile.load(profile_path) == OK
	for i in n:
		var p := String(sm.slot_path(i))
		var info := {"slot": i, "occupied": FileAccess.file_exists(p) or FileAccess.file_exists(p + ".bak"),
			"name": "", "timestamp": 0, "phase": 0, "money": "0", "play_time": 0.0, "products": 0,
			"save_key": p.get_file().get_basename()}
		if info.occupied and has_profile:
			var cached = profile.get_value("slots", "slot_%d" % i, null)
			if cached is Dictionary:
				for k in cached:
					if k != "slot" and k != "occupied":
						info[k] = cached[k]
		out.append(info)
	return out


## In-memory value for the active save (flushed to the sidecar on save.saved).
func mod_data_get(key: String, default: Variant = null) -> Variant:
	return _core.sidecar.get_value(_mod, key, default)


## value must be JSON-safe. Returns ERR_INVALID_DATA otherwise.
func mod_data_set(key: String, value: Variant) -> Error:
	return _core.sidecar.set_value(_mod, key, value)


func mod_data_all() -> Dictionary:
	return _core.sidecar.get_all(_mod)


func is_cheated() -> bool:
	return _core.sidecar.is_cheated()


## Sidecar store shared by all mods.
class Sidecar extends RefCounted:
	const Serial = preload("../core/serial.gd")
	var _core: Object = null
	var root := ""
	var active_key := ""
	var _data: Dictionary = {}     # mod_id -> Dictionary
	var _dirty: Dictionary = {}    # mod_id -> true
	var _meta: Dictionary = {}     # PittAPI meta (cheated, ...)
	## Set by reset_key (a fresh run): the first flush replaces the key's whole
	## folder, so <mod>.json / _pittapi.json from the previous run never come back.
	var _wipe_pending := false

	func _init(core: Object, p_root: String) -> void:
		_core = core
		root = p_root

	func dir_for(key: String) -> String:
		return root.path_join(key)

	func set_active(key: String) -> void:
		active_key = key

	## Loads every <mod>.json for key (called on save.loaded / world.ready).
	func load_key(key: String) -> void:
		active_key = key
		_data.clear()
		_dirty.clear()
		_meta = {}
		_wipe_pending = false
		var dir := dir_for(key)
		var da := DirAccess.open(dir)
		if da == null:
			return
		for f in da.get_files():
			if not f.ends_with(".json"):
				continue
			var v = _core.safe_fs.read_json(dir.path_join(f))
			if typeof(v) != TYPE_DICTIONARY:
				continue
			if f == "_pittapi.json":
				_meta = v
			else:
				_data[f.get_basename()] = v

	## A fresh run (new game): empty data for the key. Nothing is deleted yet (the
	## old slot file may still exist if the player never saves the new run), but
	## the first flush for this key replaces the whole folder.
	func reset_key(key: String) -> void:
		active_key = key
		_data.clear()
		_dirty.clear()
		_meta = {}
		_wipe_pending = key != ""

	func is_wipe_pending() -> bool:
		return _wipe_pending

	func get_value(mod_id: String, key: String, default: Variant) -> Variant:
		var d: Dictionary = _data.get(mod_id, {})
		return d.get(key, default)

	func set_value(mod_id: String, key: String, value: Variant) -> Error:
		if Serial.check_json_safe(value) != "":
			return ERR_INVALID_DATA
		if not _data.has(mod_id):
			_data[mod_id] = {}
		_data[mod_id][key] = Serial.to_json_safe(value)
		_dirty[mod_id] = true
		return OK

	func get_all(mod_id: String) -> Dictionary:
		return (_data.get(mod_id, {}) as Dictionary).duplicate(true)

	func mark_cheated() -> void:
		_meta["cheated"] = true
		_dirty["_pittapi"] = true

	func is_cheated() -> bool:
		return bool(_meta.get("cheated", false))

	## Writes dirty mod data for the active key (on save.saved).
	func flush(key: String = "") -> int:
		if key == "":
			key = active_key
		if key == "":
			return 0
		var n := 0
		var dir := dir_for(key)
		if _wipe_pending and key == active_key:
			_wipe_pending = false
			_core.safe_fs.remove_dir_recursive(dir)
			for mod_id in _data:
				_dirty[mod_id] = true
			if not _meta.is_empty():
				_dirty["_pittapi"] = true
		for mod_id in _dirty.keys():
			var payload = _meta if mod_id == "_pittapi" else _data.get(mod_id, {})
			if _core.safe_fs.write_json(dir.path_join("%s.json" % mod_id), payload) == OK:
				n += 1
		_dirty.clear()
		return n

	func has_dirty() -> bool:
		return not _dirty.is_empty()

	## Removes sidecars whose slot file no longer exists (the game deleted the slot).
	## Runs at boot, on save.loaded and on world.ready. The active key is skipped.
	func cleanup_orphans() -> int:
		var da := DirAccess.open(root)
		if da == null:
			return 0
		var n := 0
		for key in da.get_directories():
			if key == active_key:
				continue
			var base := "user://%s.save" % key
			if key.begins_with("savegame") or key == "sandbox":
				if not FileAccess.file_exists(base) and not FileAccess.file_exists(base + ".bak"):
					_core.safe_fs.remove_dir_recursive(dir_for(key))
					n += 1
		return n
