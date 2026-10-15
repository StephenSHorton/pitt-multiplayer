extends RefCounted
## ModLoader: discover -> validate -> check versions -> dependency graph -> sort ->
## compile -> (extensions in _init) -> instantiate + _mod_init (in _ready).
## Every mod ends LOADED, FAILED, DISABLED or QUARANTINED, with a reason.

const Manifest = preload("manifest.gd")
const Semver = preload("semver.gd")

const LOADED := "LOADED"
const FAILED := "FAILED"
const DISABLED := "DISABLED"
const QUARANTINED := "QUARANTINED"
const PENDING := "PENDING"

var _core: Object = null
var mods: Dictionary = {}       # id -> record
var order: Array[String] = []   # resolved load order (ids that passed resolution)
var discovered_dirs: Array[String] = []


func _init(core: Object = null) -> void:
	_core = core


func _log() -> Object:
	return _core.log if _core != null else null


## Scans <mods_dir>/*/mod.json. Skips the core folder, "." folders, and "_"
## folders unless include_underscore (test runs). disabled_cfg: {id: false}.
func discover(mods_dir: String, include_underscore: bool, disabled_cfg: Dictionary) -> void:
	mods.clear()
	order.clear()
	discovered_dirs.clear()
	var da := DirAccess.open(mods_dir)
	if da == null:
		if _log():
			_log().warn("mods dir not found: %s" % mods_dir)
		return
	var folders: Array = []
	da.list_dir_begin()
	var f := da.get_next()
	while f != "":
		if da.current_is_dir() and f != "." and f != "..":
			folders.append(f)
		f = da.get_next()
	da.list_dir_end()
	folders.sort()
	for folder in folders:
		if folder == "PittAPI" or folder.begins_with("."):
			continue
		if folder.begins_with("_") and not include_underscore:
			continue
		var dir := mods_dir.path_join(folder)
		if not FileAccess.file_exists(dir.path_join("mod.json")):
			continue
		discovered_dirs.append(dir)
		var parsed := Manifest.load_dir(dir)
		var id: String = parsed.data.get("id", "") if parsed.ok else ""
		if id == "":
			id = folder
		var rec := _new_record(id, dir, parsed.data)
		for w in parsed.warnings:
			if _log():
				_log().warn("%s/mod.json: %s" % [folder, w])
		if mods.has(id):
			rec.id = "%s@%s" % [id, folder]
			_set_state(rec, FAILED, "duplicate mod id '%s'" % id)
			mods[rec.id] = rec
			continue
		mods[id] = rec
		if not parsed.ok:
			_set_state(rec, FAILED, "invalid mod.json: " + "; ".join(parsed.errors))
			continue
		if not bool(parsed.data.enabled):
			_set_state(rec, DISABLED, "disabled in mod.json")
		elif disabled_cfg.has(id) and not bool(disabled_cfg[id]):
			_set_state(rec, DISABLED, "disabled in mods.cfg")


func _new_record(id: String, dir: String, manifest: Dictionary) -> Dictionary:
	return {
		"id": id,
		"dir": dir,
		"manifest": manifest,
		"version": String(manifest.get("version", "")),
		"state": PENDING,
		"reason": "",
		"warnings": [],
		"node": null,
		"ctx": null,
		"entry_script": null,
		"ext_items": [],
		"errors_total": 0,
		"error_times": [],
		"load_index": -1,
	}


func _set_state(rec: Dictionary, state: String, reason: String = "") -> void:
	rec.state = state
	rec.reason = reason
	if _log():
		var msg := "mod %s -> %s%s" % [rec.id, state, (": " + reason) if reason != "" else ""]
		if state == FAILED or state == QUARANTINED:
			_log().warn(msg)
		else:
			_log().info(msg)


func fail(id: String, reason: String) -> void:
	if mods.has(id):
		_set_state(mods[id], FAILED, reason)


## Version checks, dependency graph, topological sort.
func resolve(api_version: String, game_version: String, strict_game_version: bool) -> void:
	for id in mods:
		var rec: Dictionary = mods[id]
		if rec.state != PENDING:
			continue
		var m: Dictionary = rec.manifest
		if not Semver.satisfies(api_version, m.api_version):
			_set_state(rec, FAILED, "needs PittAPI %s, this is %s" % [m.api_version, api_version])
			continue
		var gv: Array = m.game_versions
		if not gv.is_empty() and not (game_version in gv):
			var msg := "built for game %s, running %s" % [", ".join(gv), game_version]
			if strict_game_version:
				_set_state(rec, FAILED, msg)
				continue
			rec.warnings.append(msg)
			if _log():
				_log().warn("%s: %s" % [id, msg])
	# dependencies (iterate until stable so failures propagate)
	var changed := true
	while changed:
		changed = false
		for id in mods:
			var rec: Dictionary = mods[id]
			if rec.state != PENDING:
				continue
			var deps: Dictionary = rec.manifest.dependencies
			for dep in deps:
				var why := _dep_problem(dep, deps[dep])
				if why != "":
					_set_state(rec, FAILED, why)
					changed = true
					break
	# topological sort with (load_order, id) tie-break
	var candidates: Array = []
	for id in mods:
		if mods[id].state == PENDING:
			candidates.append(id)
	var edges: Dictionary = {}    # id -> Array of ids it must load after
	for id in candidates:
		var after: Array = []
		for dep in mods[id].manifest.dependencies:
			after.append(dep)
		for dep in mods[id].manifest.optional_dependencies:
			if mods.has(dep) and mods[dep].state == PENDING:
				if Semver.satisfies(mods[dep].version, mods[id].manifest.optional_dependencies[dep]):
					after.append(dep)
				elif _log():
					_log().warn("%s: optional dependency %s %s not satisfied by %s; ignoring" % [id, dep, mods[id].manifest.optional_dependencies[dep], mods[dep].version])
		edges[id] = after
	var placed: Dictionary = {}
	var remaining := candidates.duplicate()
	while not remaining.is_empty():
		var ready: Array = []
		for id in remaining:
			var ok := true
			for dep in edges[id]:
				if not placed.has(dep):
					ok = false
					break
			if ok:
				ready.append(id)
		if ready.is_empty():
			for id in remaining:
				_set_state(mods[id], FAILED, "dependency cycle among: %s" % ", ".join(remaining))
			break
		ready.sort_custom(func(a, b):
			var la: int = mods[a].manifest.load_order
			var lb: int = mods[b].manifest.load_order
			if la != lb:
				return la < lb
			return a < b)
		var pick: String = ready[0]
		placed[pick] = true
		order.append(pick)
		remaining.erase(pick)
	for i in order.size():
		mods[order[i]].load_index = i


func _dep_problem(dep: String, rng: String) -> String:
	if not mods.has(dep):
		return "missing dependency %s %s" % [dep, rng]
	var d: Dictionary = mods[dep]
	if d.state == FAILED or d.state == QUARANTINED:
		return "dependency %s failed" % dep
	if d.state == DISABLED:
		return "dependency %s is disabled" % dep
	if not Semver.satisfies(d.version, rng):
		return "dependency %s %s not satisfied by %s" % [dep, rng, d.version]
	return ""


## Compiles entry scripts and extensions; applies extensions mod by mod (all or
## nothing per mod). Runs in PittAPI._init.
func compile_and_apply(extensions: Object) -> void:
	for id in order:
		var rec: Dictionary = mods[id]
		if rec.state != PENDING:
			continue
		if _core != null and _core.guard != null:
			_core.guard.push_override(id)
		_compile_one(id, rec, extensions)
		if _core != null and _core.guard != null:
			_core.guard.pop_override()


func _compile_one(id: String, rec: Dictionary, extensions: Object) -> void:
	var why := _deps_not_ok(rec)
	if why != "":
		_set_state(rec, FAILED, why)
		return
	var entry_path: String = rec.dir.path_join(rec.manifest.entry)
	if not FileAccess.file_exists(entry_path):
		_set_state(rec, FAILED, "entry script %s not found" % rec.manifest.entry)
		return
	var s = ResourceLoader.load(entry_path, "GDScript", ResourceLoader.CACHE_MODE_REUSE)
	if s == null or not (s is GDScript) or not s.can_instantiate():
		_set_state(rec, FAILED, "entry script %s failed to compile" % rec.manifest.entry)
		return
	if not ClassDB.is_parent_class(s.get_instance_base_type(), "Node"):
		_set_state(rec, FAILED, "entry script must extend Node (extends %s)" % s.get_instance_base_type())
		return
	rec.entry_script = s
	var ext_paths: Array = []
	for e in rec.manifest.extensions:
		ext_paths.append(rec.dir.path_join(e))
	if not ext_paths.is_empty():
		if extensions == null:
			_set_state(rec, FAILED, "extensions are not available")
			return
		# one at a time (chains and subclass scripts see the earlier extensions),
		# rolled back as a whole on any failure
		var prep: Dictionary = extensions.prepare_and_apply(id, ext_paths)
		if not prep.ok:
			_set_state(rec, FAILED, prep.error)
			return
		rec.ext_items = prep.items


func _deps_not_ok(rec: Dictionary) -> String:
	for dep in rec.manifest.dependencies:
		if not mods.has(dep):
			return "missing dependency %s" % dep
		var st: String = mods[dep].state
		if st != PENDING and st != LOADED:
			return "dependency %s %s" % [dep, st.to_lower()]
	return ""


## Instantiates each entry node under parent and calls _mod_init(api) through the
## guard. Any error during _mod_init quarantines the mod. Runs in PittAPI._ready.
func init_mods(parent: Node) -> void:
	for id in order:
		var rec: Dictionary = mods[id]
		if rec.state != PENDING or rec.entry_script == null:
			continue
		var why := _deps_not_ok(rec)
		if why != "":
			_set_state(rec, FAILED, why)
			continue
		var node = rec.entry_script.new()
		if node == null or not (node is Node):
			_set_state(rec, FAILED, "entry script did not produce a Node")
			continue
		node.name = id
		var ctx = _core.make_context(rec)
		rec.ctx = ctx
		rec.node = node
		if "api" in node:
			node.set("api", ctx)
		rec.state = "INITIALIZING"
		var before: int = _core.guard.mod_errors(id)
		var total_before: int = _core.guard.total_errors()
		_core.guard.push_scope(id)
		parent.add_child(node)
		if node.has_method("_mod_init"):
			Callable(node, "_mod_init").callv([ctx])
		_core.guard.pop_scope()
		var errs: int = _core.guard.mod_errors(id) - before
		if errs > 0:
			quarantine(id, "%d error(s) during _mod_init" % errs)
			continue
		_set_state(rec, LOADED, "")
		if _log():
			_log().info("loaded %s %s" % [id, rec.version])


func is_active(id: String) -> bool:
	if not mods.has(id):
		return false
	var st: String = mods[id].state
	return st == LOADED or st == "INITIALIZING"


## Counts an attributed error; quarantines past the threshold.
func on_mod_error(id: String, entry: Dictionary, threshold: int, window_s: float) -> void:
	if not mods.has(id):
		return
	var rec: Dictionary = mods[id]
	rec.errors_total += 1
	if rec.state == "INITIALIZING":
		return   # handled by init_mods
	if rec.state != LOADED:
		return
	var now := Time.get_ticks_msec()
	rec.error_times.append(now)
	var cutoff := now - int(window_s * 1000.0)
	while not rec.error_times.is_empty() and rec.error_times[0] < cutoff:
		rec.error_times.remove_at(0)
	if rec.error_times.size() >= threshold:
		quarantine(id, "%d errors within %.0f s (last: %s)" % [rec.error_times.size(), window_s, entry.get("msg", "")])


func quarantine(id: String, reason: String) -> void:
	if not mods.has(id):
		return
	var rec: Dictionary = mods[id]
	if rec.state == QUARANTINED:
		return
	_set_state(rec, QUARANTINED, reason)
	_core.on_mod_quarantined(id, reason)


func status() -> Array:
	var out: Array = []
	var ids := mods.keys()
	ids.sort_custom(func(a, b):
		var ia: int = mods[a].load_index
		var ib: int = mods[b].load_index
		if ia != ib:
			if ia < 0:
				return false
			if ib < 0:
				return true
			return ia < ib
		return a < b)
	for id in ids:
		var r: Dictionary = mods[id]
		out.append({
			"id": r.id,
			"name": String(r.manifest.get("name", "")),
			"version": r.version,
			"state": r.state,
			"reason": r.reason,
			"warnings": r.warnings.duplicate(),
			"dir": r.dir,
			"load_index": r.load_index,
			"errors": r.errors_total,
			"extensions": r.manifest.get("extensions", []),
			"multiplayer": String(r.manifest.get("multiplayer", "local_only")),
		})
	return out


func get_state(id: String) -> String:
	return String(mods[id].state) if mods.has(id) else ""
