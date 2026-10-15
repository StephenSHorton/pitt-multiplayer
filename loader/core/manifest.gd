extends RefCounted
## mod.json parsing and validation. Mirrors loader/schema/mod.schema.json.

const Semver = preload("semver.gd")

const ID_REGEX := "^_?[A-Za-z][A-Za-z0-9_]{1,63}$"  # a leading "_" marks test-only fixture mods
const MULTIPLAYER_VALUES := ["client_required", "host_only", "local_only"]
## Core services a mod may provide. "net": the multiplayer layer (installs the
## command authority); only one active mod may provide it.
const PROVIDES_VALUES := ["net"]
const KNOWN_FIELDS := ["id", "name", "version", "api_version", "entry", "dependencies",
	"optional_dependencies", "load_order", "extensions", "game_versions", "multiplayer",
	"enabled", "description", "author", "core", "provides", "$schema"]


## Reads and validates <dir>/mod.json. Returns
## {ok: bool, errors: Array[String], warnings: Array[String], data: Dictionary}.
static func load_dir(dir: String) -> Dictionary:
	var path := dir.path_join("mod.json")
	if not FileAccess.file_exists(path):
		return {"ok": false, "errors": ["mod.json not found"], "warnings": [], "data": {}}
	var text := FileAccess.get_file_as_string(path)
	return parse_text(text, dir.get_file())


static func parse_text(text: String, folder_name: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(text) != OK:
		return {"ok": false, "errors": ["mod.json is not valid JSON (line %d: %s)" % [json.get_error_line(), json.get_error_message()]], "warnings": [], "data": {}}
	if not (json.data is Dictionary):
		return {"ok": false, "errors": ["mod.json must be a JSON object"], "warnings": [], "data": {}}
	return validate(json.data, folder_name)


static func validate(raw: Dictionary, folder_name: String) -> Dictionary:
	var errors: Array[String] = []
	var warnings: Array[String] = []
	var d := {
		"id": "",
		"name": "",
		"version": "",
		"api_version": "",
		"entry": "main.gd",
		"dependencies": {},
		"optional_dependencies": {},
		"load_order": 100,
		"extensions": [],
		"game_versions": [],
		"multiplayer": "local_only",
		"enabled": true,
		"description": "",
		"author": "",
		"core": false,
		"provides": [],
	}
	for k in raw:
		if not (str(k) in KNOWN_FIELDS):
			warnings.append("unknown field '%s'" % str(k))

	# id
	var re := RegEx.new()
	re.compile(ID_REGEX)
	var id = raw.get("id", null)
	if typeof(id) != TYPE_STRING or re.search(id) == null:
		errors.append("id must match %s" % ID_REGEX)
	else:
		d.id = id
		if folder_name != "" and id != folder_name:
			errors.append("id '%s' must match its folder name '%s'" % [id, folder_name])

	# strings
	for k in ["name", "version", "api_version"]:
		var v = raw.get(k, null)
		if typeof(v) != TYPE_STRING or String(v).strip_edges().is_empty():
			errors.append("%s is required and must be a non-empty string" % k)
		else:
			d[k] = v
	if d.version != "" and not Semver.is_valid(d.version):
		errors.append("version '%s' is not semver (MAJOR.MINOR.PATCH)" % d.version)
	if d.api_version != "" and not Semver.is_valid_range(d.api_version):
		errors.append("api_version '%s' is not a valid semver range" % d.api_version)
	for k in ["description", "author"]:
		if raw.has(k):
			if typeof(raw[k]) != TYPE_STRING:
				errors.append("%s must be a string" % k)
			else:
				d[k] = raw[k]

	# entry
	if raw.has("entry"):
		var e = raw.entry
		if typeof(e) != TYPE_STRING or not _is_safe_rel_path(e) or not String(e).ends_with(".gd"):
			errors.append("entry must be a relative .gd path inside the mod folder")
		else:
			d.entry = e

	# dependency maps
	for k in ["dependencies", "optional_dependencies"]:
		if raw.has(k):
			var deps = raw[k]
			if typeof(deps) != TYPE_DICTIONARY:
				errors.append("%s must be an object of {ModId: range}" % k)
			else:
				var clean := {}
				for dep_id in deps:
					var rng = deps[dep_id]
					if re.search(str(dep_id)) == null:
						errors.append("%s: invalid mod id '%s'" % [k, str(dep_id)])
					elif typeof(rng) != TYPE_STRING or not Semver.is_valid_range(rng):
						errors.append("%s: '%s' has an invalid version range" % [k, str(dep_id)])
					else:
						clean[str(dep_id)] = rng
				d[k] = clean

	# load_order
	if raw.has("load_order"):
		var lo = raw.load_order
		if typeof(lo) == TYPE_FLOAT and lo == floor(lo):
			lo = int(lo)
		if typeof(lo) != TYPE_INT:
			errors.append("load_order must be an integer")
		else:
			d.load_order = lo

	# extensions
	if raw.has("extensions"):
		var ex = raw.extensions
		if typeof(ex) != TYPE_ARRAY:
			errors.append("extensions must be an array of relative .gd paths")
		else:
			var clean_ex: Array = []
			for p in ex:
				if typeof(p) != TYPE_STRING or not _is_safe_rel_path(p) or not String(p).ends_with(".gd"):
					errors.append("extensions: '%s' is not a relative .gd path" % str(p))
				else:
					clean_ex.append(p)
			d.extensions = clean_ex

	# game_versions
	if raw.has("game_versions"):
		var gv = raw.game_versions
		if typeof(gv) != TYPE_ARRAY:
			errors.append("game_versions must be an array of strings")
		else:
			var clean_gv: Array = []
			for v in gv:
				if typeof(v) != TYPE_STRING:
					errors.append("game_versions entries must be strings")
				else:
					clean_gv.append(v)
			d.game_versions = clean_gv

	# multiplayer
	if raw.has("multiplayer"):
		if typeof(raw["multiplayer"]) != TYPE_STRING or not (raw["multiplayer"] in MULTIPLAYER_VALUES):
			errors.append("multiplayer must be one of %s" % str(MULTIPLAYER_VALUES))
		else:
			d.multiplayer = raw["multiplayer"]

	# provides
	if raw.has("provides"):
		var pv = raw.provides
		if typeof(pv) != TYPE_ARRAY:
			errors.append("provides must be an array of strings")
		else:
			var clean_pv: Array = []
			for v in pv:
				if typeof(v) != TYPE_STRING or not (v in PROVIDES_VALUES):
					errors.append("provides: '%s' is not one of %s" % [str(v), str(PROVIDES_VALUES)])
				elif not (v in clean_pv):
					clean_pv.append(v)
			d.provides = clean_pv

	for k in ["enabled", "core"]:
		if raw.has(k):
			if typeof(raw[k]) != TYPE_BOOL:
				errors.append("%s must be true or false" % k)
			else:
				d[k] = raw[k]

	return {"ok": errors.is_empty(), "errors": errors, "warnings": warnings, "data": d}


static func _is_safe_rel_path(p: String) -> bool:
	if p.is_empty() or p.is_absolute_path() or p.begins_with("/") or p.begins_with("\\"):
		return false
	if p.contains(":") or p.contains(".."):
		return false
	return true
