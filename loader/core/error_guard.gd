extends Logger
## ErrorGuard: an engine Logger (OS.add_logger) that attributes every engine and
## script error to a mod. Attribution order:
##   1. the reporting file, then each GDScript backtrace frame (innermost first),
##      matched by path prefix <mods_dir>/<ModId>/ (works for absolute and res:// paths);
##   2. otherwise the innermost "current mod" scope pushed by guarded calls (main thread only).
##   PittAPI's own frames/scopes are skipped in both steps when a mod is further out
##   (see attribute()). Release templates do not report GDScript VM runtime errors
##   (null calls, bad property access) to loggers at all and do not abort the
##   function; only engine (C++) errors and parse/load errors reach this Logger there.
## _log_error can run on any thread, so it only records under a mutex. The main
## thread drains the queue each frame (PittAPI._process) to log and quarantine.

var mods_root := ""          # normalized, lower-case, ends with "/"
var known_ids: Dictionary = {}   # lower-case folder -> mod id
var capture_warnings := false
var core_id := "PittAPI"

var _mutex := Mutex.new()
var _queue: Array = []
var _recent: Array = []
var _recent_cap := 200
var _total := 0
var _per_mod: Dictionary = {}
var _scope: Array[String] = []
var _override: Array[String] = []
var _main_thread := 0
var _suspended := 0


func _init(p_mods_dir: String = "") -> void:
	_main_thread = OS.get_main_thread_id()
	set_mods_dir(p_mods_dir)


var _roots: Array[String] = []   # every spelling of the mods dir (absolute, res://)


func set_mods_dir(dir: String) -> void:
	_roots.clear()
	var n := normalize_path(dir)
	if n != "" and not n.ends_with("/"):
		n += "/"
	mods_root = n
	if n != "":
		_roots.append(n)
		var loc := ProjectSettings.localize_path(dir).replace("\\", "/").to_lower()
		if loc.begins_with("res://"):
			if not loc.ends_with("/"):
				loc += "/"
			_roots.append(loc)


func register_mod(id: String) -> void:
	_mutex.lock()
	known_ids[id.to_lower()] = id
	_mutex.unlock()


static func normalize_path(p: String) -> String:
	if p.is_empty():
		return ""
	if p.begins_with("res://") or p.begins_with("user://"):
		p = ProjectSettings.globalize_path(p)
	return p.replace("\\", "/").to_lower()


## Maps one file path to a mod id, or "" when it is not inside the mods dir.
func attribute_path(file: String) -> String:
	if _roots.is_empty() or file.is_empty():
		return ""
	var raw := file.replace("\\", "/").to_lower()
	var n := normalize_path(file)
	var rest := ""
	for r in _roots:
		if raw.begins_with(r):
			rest = raw.substr(r.length())
			break
		if n.begins_with(r):
			rest = n.substr(r.length())
			break
	if rest.is_empty():
		return ""
	var slash := rest.find("/")
	if slash <= 0:
		return ""
	var folder := rest.substr(0, slash)
	return String(known_ids.get(folder, folder))


## PittAPI's own frames are skipped: an error inside a facade (or in game code a
## facade called) belongs to the innermost mod frame that called it, then to the
## guard scope. PittAPI is blamed only when no mod frame and no mod scope exist.
func attribute(file: String, backtraces: Array) -> String:
	if not _override.is_empty() and OS.get_thread_caller_id() == _main_thread:
		return _override[_override.size() - 1]
	var saw_core := false
	var id := attribute_path(file)
	if id != "" and id != core_id:
		return id
	saw_core = id == core_id
	for bt in backtraces:
		if bt == null:
			continue
		for i in bt.get_frame_count():
			id = attribute_path(bt.get_frame_file(i))
			if id == core_id:
				saw_core = true
			elif id != "":
				return id
	if OS.get_thread_caller_id() == _main_thread and not _scope.is_empty():
		# innermost mod scope; a PittAPI scope (core command handler) inside a
		# mod's guarded call is skipped the same way as PittAPI frames
		for i in range(_scope.size() - 1, -1, -1):
			var sc: String = _scope[i]
			if sc == core_id:
				saw_core = true
			elif sc != "":
				return sc
	return core_id if saw_core else ""


func _log_error(function: String, file: String, line: int, code: String, rationale: String,
		editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
	if error_type == ERROR_TYPE_WARNING and not capture_warnings:
		return
	var msg := rationale if not rationale.is_empty() else code
	var frames: Array = []
	for bt in script_backtraces:
		if bt == null:
			continue
		for i in mini(bt.get_frame_count(), 8):
			frames.append("%s:%d %s" % [bt.get_frame_file(i), bt.get_frame_line(i), bt.get_frame_function(i)])
	_mutex.lock()
	if _suspended > 0:
		_mutex.unlock()
		return
	var mod := attribute(file, script_backtraces)
	var counted := error_type != ERROR_TYPE_WARNING
	var entry := {
		"t_ms": Time.get_ticks_msec(),
		"mod": mod,
		"msg": msg,
		"file": file,
		"line": line,
		"function": function,
		"type": ["error", "warning", "script", "shader"][clampi(error_type, 0, 3)],
		"frames": frames,
		"counted": counted,
	}
	if counted:
		_total += 1
		if mod != "":
			_per_mod[mod] = int(_per_mod.get(mod, 0)) + 1
	_queue.append(entry)
	_recent.append(entry)
	if _recent.size() > _recent_cap:
		_recent.remove_at(0)
	_mutex.unlock()


func _log_message(message: String, error: bool) -> void:
	pass


## Main thread: takes every queued error.
func drain() -> Array:
	_mutex.lock()
	var q := _queue
	_queue = []
	_mutex.unlock()
	return q


func total_errors() -> int:
	_mutex.lock()
	var t := _total
	_mutex.unlock()
	return t


func mod_errors(id: String) -> int:
	_mutex.lock()
	var t := int(_per_mod.get(id, 0))
	_mutex.unlock()
	return t


func recent(n: int = 200, mod_filter: String = "") -> Array:
	_mutex.lock()
	var out: Array = []
	for e in _recent:
		if mod_filter == "" or e.mod == mod_filter:
			out.append(e.duplicate())
	_mutex.unlock()
	return out.slice(maxi(0, out.size() - n))


func push_scope(mod_id: String) -> void:
	_scope.append(mod_id)


func pop_scope() -> void:
	if not _scope.is_empty():
		_scope.pop_back()


## While set, every main-thread error is attributed to mod_id regardless of file
## paths (used while the loader compiles a mod's scripts on its behalf).
func push_override(mod_id: String) -> void:
	_override.append(mod_id)


func pop_override() -> void:
	if not _override.is_empty():
		_override.pop_back()


func current_scope() -> String:
	return "" if _scope.is_empty() else _scope[_scope.size() - 1]


## Temporarily ignore errors (used while we deliberately probe things).
func suspend() -> void:
	_mutex.lock()
	_suspended += 1
	_mutex.unlock()


func resume() -> void:
	_mutex.lock()
	_suspended = maxi(0, _suspended - 1)
	_mutex.unlock()
