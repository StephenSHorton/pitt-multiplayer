extends RefCounted
## PittConfig: per-mod settings in user://pittapi/config/<mod_id>.cfg
## (ConfigFile, one section per group). set_value validates, then saves with a
## 0.5 s debounce (flush() forces it).

signal changed(section: String, key: String, value: Variant)

var _core: Object = null
var _mod := ""
var path := ""
var _cfg := ConfigFile.new()
var _defs: Dictionary = {}     # "section/key" -> {default, type, min, max, options, description}
var _dirty := false
var _dirty_at := 0


func _init(core: Object, mod_id: String, p_path: String) -> void:
	_core = core
	_mod = mod_id
	path = p_path
	if FileAccess.file_exists(path):
		_cfg.load(path)


## opts: {section = "general", type = TYPE_*, min, max, options: [], description}
func define(key: String, default: Variant, opts: Dictionary = {}) -> void:
	var section := String(opts.get("section", "general"))
	var t := int(opts.get("type", typeof(default)))
	_defs["%s/%s" % [section, key]] = {"default": default, "type": t, "min": opts.get("min", null),
		"max": opts.get("max", null), "options": opts.get("options", []),
		"description": String(opts.get("description", ""))}
	if _cfg.has_section_key(section, key):
		var cur = _cfg.get_value(section, key)
		if validate(key, cur, section) != "":
			_cfg.set_value(section, key, default)
			_mark_dirty()


func get_value(key: String, section: String = "general") -> Variant:
	var def = _defs.get("%s/%s" % [section, key], null)
	var fallback = def.default if def != null else null
	return _cfg.get_value(section, key, fallback)


## Returns "" when valid, otherwise the reason.
func validate(key: String, value: Variant, section: String = "general") -> String:
	var def = _defs.get("%s/%s" % [section, key], null)
	if def == null:
		return ""
	var t: int = def.type
	if t != TYPE_NIL and typeof(value) != t:
		if not (t == TYPE_FLOAT and typeof(value) == TYPE_INT):
			return "%s must be %s" % [key, type_string(t)]
	if def.min != null and (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and value < def.min:
		return "%s must be >= %s" % [key, str(def.min)]
	if def.max != null and (typeof(value) == TYPE_INT or typeof(value) == TYPE_FLOAT) and value > def.max:
		return "%s must be <= %s" % [key, str(def.max)]
	if not def.options.is_empty() and not (value in def.options):
		return "%s must be one of %s" % [key, str(def.options)]
	return ""


func set_value(key: String, value: Variant, section: String = "general") -> Error:
	var why := validate(key, value, section)
	if why != "":
		if _core != null and _core.log != null:
			_core.log.warn("config %s: %s" % [_mod, why])
		return ERR_INVALID_PARAMETER
	var def = _defs.get("%s/%s" % [section, key], null)
	if def != null and def.type == TYPE_FLOAT and typeof(value) == TYPE_INT:
		value = float(value)
	_cfg.set_value(section, key, value)
	_mark_dirty()
	changed.emit(section, key, value)
	return OK


func has_key(key: String, section: String = "general") -> bool:
	return _cfg.has_section_key(section, key) or _defs.has("%s/%s" % [section, key])


func describe() -> Array:
	var out: Array = []
	for k in _defs:
		var p: PackedStringArray = k.split("/")
		var d: Dictionary = _defs[k]
		out.append({"section": p[0], "key": p[1], "value": get_value(p[1], p[0]), "default": d.default,
			"description": d.description, "options": d.options, "min": d.min, "max": d.max})
	return out


func _mark_dirty() -> void:
	_dirty = true
	_dirty_at = Time.get_ticks_msec()


## Called every frame by PittAPI; saves 0.5 s after the last change.
func tick() -> void:
	if _dirty and Time.get_ticks_msec() - _dirty_at >= 500:
		flush()


func flush() -> Error:
	if not _dirty:
		return OK
	_dirty = false
	if _core != null and _core.safe_fs != null:
		return _core.safe_fs.save_config(_cfg, path)
	return _cfg.save(path)
