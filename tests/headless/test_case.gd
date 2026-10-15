extends RefCounted
## Base class for headless suites (tests/suites/test_*.gd). Methods named test_*
## run in source order; they may await. Use the assert_* helpers.

var core: Node = null          # the booted /root/PittAPI
var tree: SceneTree = null
var runner: Node = null
var failures: Array[String] = []
var checks := 0


func assert_true(cond: bool, msg: String = "") -> bool:
	checks += 1
	if not cond:
		failures.append("expected true: " + msg)
	return cond


func assert_false(cond: bool, msg: String = "") -> bool:
	return assert_true(not cond, "expected false: " + msg)


func assert_eq(actual: Variant, expected: Variant, msg: String = "") -> bool:
	checks += 1
	var same: bool = typeof(actual) == typeof(expected) and actual == expected
	if not same and (typeof(actual) in [TYPE_INT, TYPE_FLOAT]) and (typeof(expected) in [TYPE_INT, TYPE_FLOAT]):
		same = is_equal_approx(float(actual), float(expected))
	if not same:
		failures.append("%s: expected %s (%s), got %s (%s)" % [msg, var_to_str(expected), type_string(typeof(expected)),
			var_to_str(actual), type_string(typeof(actual))])
	return same


func assert_ne(actual: Variant, other: Variant, msg: String = "") -> bool:
	checks += 1
	if typeof(actual) == typeof(other) and actual == other:
		failures.append("%s: expected something other than %s" % [msg, var_to_str(other)])
		return false
	return true


func assert_has(container: Variant, item: Variant, msg: String = "") -> bool:
	checks += 1
	if not (item in container):
		failures.append("%s: %s not in %s" % [msg, var_to_str(item), var_to_str(container)])
		return false
	return true


## Runs f and asserts that at least one engine error was logged meanwhile.
func assert_error_logged(f: Callable, msg: String = "") -> Variant:
	var before: int = core.guard.total_errors()
	var r = f.call()
	assert_true(core.guard.total_errors() > before, "an error should be logged: " + msg)
	return r


func fail(msg: String) -> void:
	checks += 1
	failures.append(msg)


func wait_frames(n: int = 1) -> void:
	for i in n:
		await tree.process_frame


func wait_physics(n: int = 1) -> void:
	for i in n:
		await tree.physics_frame


## Collects events into an array for the duration of a test.
func capture(pattern: String) -> Array:
	var bucket: Array = []
	var id: int = core.events.on(pattern, func(ev): bucket.append(ev), 0, "")
	_captures.append(id)
	return bucket


var _captures: Array = []


func release_captures() -> void:
	for id in _captures:
		core.events.off(id)
	_captures.clear()


## Writes a mod folder (mod.json + optional main.gd source) under root.
static func make_mod(root: String, id: String, manifest: Dictionary = {}, main_src: String = "") -> String:
	var dir := root.path_join(id)
	DirAccess.make_dir_recursive_absolute(dir)
	var m := {"id": id, "name": id, "version": "1.0.0", "api_version": "^1.0"}
	for k in manifest:
		m[k] = manifest[k]
	var f := FileAccess.open(dir.path_join("mod.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(m, "  "))
	f.close()
	var src := main_src if main_src != "" else "extends Node\nvar api\nfunc _mod_init(p):\n\tapi = p\n"
	var g := FileAccess.open(dir.path_join("main.gd"), FileAccess.WRITE)
	g.store_string(src)
	g.close()
	return dir


static func rm_rf(dir: String) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for f in da.get_files():
		DirAccess.remove_absolute(dir.path_join(f))
	for d in da.get_directories():
		rm_rf(dir.path_join(d))
	DirAccess.remove_absolute(dir)


## A second, isolated PittAPI instance (own mods dir and user root).
func spawn_instance(mods_dir: String, user_root: String, settings: Dictionary = {}) -> Node:
	rm_rf(ProjectSettings.globalize_path(user_root))
	var inst: Node = core.get_script().new({"name": "PittAPI_test_%d" % Time.get_ticks_usec(), "mods_dir": mods_dir,
		"user_root": user_root, "settings": settings, "echo": false})
	runner.add_child(inst)
	return inst
