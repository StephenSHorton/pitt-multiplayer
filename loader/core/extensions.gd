extends RefCounted
## Script extensions via Resource.take_over_path. Applied in PittAPI._init, before
## the splash screen loads the main menu. Each extension must:
##   - start with  extends "res://scripts/<target>.gd"  (a path, not a class name)
##   - call super.<method>() unless it deliberately replaces a method
##   - have no class_name
## Later extensions of the same target stack on earlier ones (take_over_path chains).

var blocked: Dictionary = {}          # res path -> reason
var blocked_autoload_names: Array[String] = []
var _registry: Array = []            # {mod, target, path, chain_index}
var _owned_targets: Dictionary = {}  # target -> true (we took it over)
var _log: Object = null


func _init(p_log: Object = null) -> void:
	_log = p_log


## Builds the BLOCKED list from the [autoload] section of ProjectSettings, so new
## autoloads in a game update are covered automatically. own_paths (our own
## override.cfg autoloads) are skipped.
func build_blocked(own_paths: Array = []) -> void:
	blocked.clear()
	blocked_autoload_names.clear()
	var own_norm: Array = []
	for p in own_paths:
		own_norm.append(String(p).replace("\\", "/").to_lower())
	for prop in ProjectSettings.get_property_list():
		var key: String = prop.name
		if not key.begins_with("autoload/"):
			continue
		var name := key.trim_prefix("autoload/")
		var value := String(ProjectSettings.get_setting(key, "")).trim_prefix("*")
		var path := resolve_uid(value)
		if path.replace("\\", "/").to_lower() in own_norm:
			continue
		if not path.begins_with("res://") and not path.begins_with("uid://"):
			continue   # absolute paths are override.cfg autoloads (ours or other loaders)
		if not (name in blocked_autoload_names):
			blocked_autoload_names.append(name)
		if not path.begins_with("res://"):
			continue
		if path.ends_with(".gd"):
			blocked[path] = "autoload %s (instanced before PittAPI)" % name
		elif path.ends_with(".tscn") or path.ends_with(".scn"):
			blocked[path] = "autoload scene %s" % name
			var sp := _scene_root_script(path)
			if sp != "":
				blocked[sp] = "script of autoload scene %s" % name
	for always in ["res://scripts/big_int.gd"]:
		blocked[always] = "BigInt is loaded by the autoloads before PittAPI"


## In _ready the autoload nodes exist: block the scripts they actually run (and
## their base scripts), which also covers uid:// entries that did not resolve.
func augment_from_nodes(root: Node) -> void:
	if root == null:
		return
	for name in blocked_autoload_names:
		var n := root.get_node_or_null(NodePath(name))
		if n == null:
			continue
		var s: Script = n.get_script()
		while s != null:
			if s.resource_path.begins_with("res://") and not blocked.has(s.resource_path):
				blocked[s.resource_path] = "script of autoload %s" % name
			s = s.get_base_script()


static func resolve_uid(path: String) -> String:
	if path.begins_with("uid://"):
		var id := ResourceUID.text_to_id(path)
		if id != ResourceUID.INVALID_ID and ResourceUID.has_id(id):
			return ResourceUID.get_id_path(id)
	return path


static func _scene_root_script(scene_path: String) -> String:
	if not ResourceLoader.exists(scene_path):
		return ""
	var ps = load(scene_path)
	if not (ps is PackedScene):
		return ""
	var state: SceneState = ps.get_state()
	if state.get_node_count() == 0:
		return ""
	for i in state.get_node_property_count(0):
		if state.get_node_property_name(0, i) == "script":
			var sc = state.get_node_property_value(0, i)
			if sc is Script:
				return sc.resource_path
	return ""


## Reads the `extends "res://..."` target from the script source, without loading.
static func read_extends_target(abs_path: String) -> String:
	if not FileAccess.file_exists(abs_path):
		return ""
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if f == null:
		return ""
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#") or line.begins_with("@"):
			continue
		if line.begins_with("class_name"):
			return "!class_name"
		if line.begins_with("extends"):
			var rest := line.substr(7).strip_edges()
			if rest.length() >= 2 and (rest[0] == "\"" or rest[0] == "'"):
				var q := rest[0]
				var end := rest.find(q, 1)
				if end > 1:
					return rest.substr(1, end - 1)
			return "!" + rest
		return ""
	return ""


## Compiles every extension of one mod without applying anything.
## Returns {ok, error, items:[{path, target, script}]}.
## fresh_targets: targets that were not loaded yet when this mod's extensions started
## (prepare_and_apply); one of them may have been loaded since by an earlier extension of
## the same mod (a subclass that extends it by class_name, compiled first on purpose).
func prepare(mod_id: String, ext_paths: Array, fresh_targets: Dictionary = {}) -> Dictionary:
	var items: Array = []
	for p in ext_paths:
		var target := read_extends_target(p)
		if target == "" or target.begins_with("!"):
			if target == "!class_name":
				return {"ok": false, "error": "%s: extensions must not declare class_name" % p, "items": []}
			return {"ok": false, "error": "%s: an extension must start with extends \"res://...\" (got '%s')" % [p, target.trim_prefix("!")], "items": []}
		target = resolve_uid(target)
		if not target.begins_with("res://"):
			return {"ok": false, "error": "%s: extends target must be a res:// path" % p, "items": []}
		if blocked.has(target):
			return {"ok": false, "code": ERR_UNAVAILABLE, "error": "%s: %s cannot be extended: %s. Use signals, polling or a scene-script call site instead." % [p, target, blocked[target]], "items": []}
		if not _owned_targets.has(target) and ResourceLoader.has_cached(target) and not fresh_targets.has(target):
			return {"ok": false, "code": ERR_UNAVAILABLE, "error": "%s: %s was already loaded before PittAPI, so existing users keep the original script" % [p, target], "items": []}
		var s = ResourceLoader.load(p, "GDScript", ResourceLoader.CACHE_MODE_REUSE)
		if s == null or not (s is GDScript) or not s.can_instantiate():
			return {"ok": false, "error": "%s: failed to compile" % p, "items": []}
		var base = s.get_base_script()
		if base == null or base.resource_path != target:
			return {"ok": false, "error": "%s: base script resolved to '%s', expected %s" % [p, base.resource_path if base != null else "<none>", target], "items": []}
		items.append({"path": p, "target": target, "script": s})
	return {"ok": true, "error": "", "items": items}


## Prepares and applies one extension at a time in manifest order, so each
## compiles against the ones applied before it: two extensions of one target in
## one mod chain (the second extends the first), and a subclass script (e.g.
## vacuum_2.gd extends vacuum.gd by path) first loads after its base script was
## extended, so it inherits the extension. All or nothing: on a failure every
## target this call took over is handed back to the script it had before.
## Returns {ok, error, items}.
## A target that only this mod's own earlier extensions loaded (e.g. metal_crate_ext.gd
## compiles metal_crate.gd, which extends wodd_crate.gd through class_name) may still be
## extended: those earlier scripts keep the original base, which the mod chose by ordering.
func prepare_and_apply(mod_id: String, ext_paths: Array) -> Dictionary:
	var applied: Array = []
	var fresh: Dictionary = {}
	for p in ext_paths:
		var t := resolve_uid(read_extends_target(p))
		if t.begins_with("res://") and not _owned_targets.has(t) and not ResourceLoader.has_cached(t):
			fresh[t] = true
	for p in ext_paths:
		var r := prepare(mod_id, [p], fresh)
		if not r.ok:
			_rollback(mod_id, applied)
			return r
		apply_prepared(mod_id, r.items)
		applied.append_array(r.items)
	return {"ok": true, "error": "", "items": applied}


func _rollback(mod_id: String, items: Array) -> void:
	for i in range(items.size() - 1, -1, -1):
		var it: Dictionary = items[i]
		var base: Script = it.script.get_base_script()
		if base != null:
			base.take_over_path(it.target)
		for j in range(_registry.size() - 1, -1, -1):
			if _registry[j].mod == mod_id and _registry[j].path == it.path:
				_registry.remove_at(j)
				break
		var still := false
		for r in _registry:
			if r.target == it.target:
				still = true
		if not still:
			_owned_targets.erase(it.target)
	if _log != null and not items.is_empty():
		_log.warn("%s: %d extension(s) rolled back" % [mod_id, items.size()], {"mod": mod_id})


## Applies prepared items (all of one mod) in order.
func apply_prepared(mod_id: String, items: Array) -> void:
	for it in items:
		var chain_index := 0
		for r in _registry:
			if r.target == it.target:
				chain_index += 1
		it.script.take_over_path(it.target)
		_owned_targets[it.target] = true
		_registry.append({"mod": mod_id, "target": it.target, "path": it.path, "chain_index": chain_index, "script": it.script})
		if _log != null:
			_log.info("extension applied: %s -> %s (chain %d)" % [it.path, it.target, chain_index], {"mod": mod_id})


## Convenience for tests: prepare + apply one script. Returns OK or an Error.
func apply_extension(mod_id: String, ext_path: String) -> Error:
	var r := prepare(mod_id, [ext_path])
	if not r.ok:
		if _log != null:
			_log.warn(r.error)
		return r.get("code", ERR_COMPILATION_FAILED)
	apply_prepared(mod_id, r.items)
	return OK


func list() -> Array[Dictionary]:
	var by_target: Dictionary = {}
	for r in _registry:
		if not by_target.has(r.target):
			by_target[r.target] = []
		by_target[r.target].append({"mod": r.mod, "path": r.path})
	var out: Array[Dictionary] = []
	for t in by_target:
		out.append({"target": t, "chain": by_target[t]})
	return out


func is_extended(target: String) -> bool:
	return _owned_targets.has(target)


## The script currently serving target (the last extension applied), or null.
func applied_script(target: String) -> Script:
	var s: Script = null
	for r in _registry:
		if r.target == target:
			s = r.script
	return s


func by_mod(mod_id: String) -> Array:
	var out: Array = []
	for r in _registry:
		if r.mod == mod_id:
			var d: Dictionary = r.duplicate()
			d.erase("script")
			out.append(d)
	return out


## Read-only view for mods (api.extensions).
class View extends RefCounted:
	var _ext = null

	func _init(ext) -> void:
		_ext = ext

	func list() -> Array[Dictionary]:
		return _ext.list()

	func is_extended(target: String) -> bool:
		return _ext.is_extended(target)

	func applied_script(target: String) -> Script:
		return _ext.applied_script(target)

	func blocked() -> Array:
		return _ext.blocked.keys()

	func blocked_autoloads() -> Array[String]:
		return _ext.blocked_autoload_names.duplicate()
