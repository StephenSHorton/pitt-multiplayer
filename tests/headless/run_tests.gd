extends Node
## Headless xUnit runner. Main scene of dist/headless-project.
## Runs every res://tests/suites/test_*.gd, writes the JSON report
## (env PITTAPI_HEADLESS_REPORT, default <project>/../headless-report.json) and
## quits with exit code 0 (all passed) or 1.

const SUITES_DIR := "res://tests/suites"
const WATCHDOG_S := 120.0

var _report := {"finished": false, "suites": [], "summary": {"passed": 0, "failed": 0}}
var _done := false


func _ready() -> void:
	var t := Timer.new()
	t.one_shot = true
	t.wait_time = WATCHDOG_S
	t.process_mode = Node.PROCESS_MODE_ALWAYS
	t.timeout.connect(_on_watchdog)
	add_child(t)
	t.start()
	_run.call_deferred()


func _run() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	var core := get_node_or_null("/root/PittAPI")
	if core == null or not core.booted:
		_report["fatal"] = "PittAPI autoload missing or not booted"
		_finish(1)
		return
	var only := OS.get_environment("PITTAPI_TEST_FILTER")
	var files: Array = []
	var da := DirAccess.open(SUITES_DIR)
	for f in da.get_files():
		if f.begins_with("test_") and f.ends_with(".gd"):
			files.append(f)
	files.sort()
	for f in files:
		if only != "" and not f.contains(only):
			continue
		var script = load(SUITES_DIR.path_join(f))
		if script == null or not script.can_instantiate():
			_report.suites.append({"name": f, "tests": [{"name": "<compile>", "ok": false, "ms": 0, "msg": "suite failed to compile"}]})
			_report.summary.failed += 1
			continue
		var suite = script.new()
		suite.core = core
		suite.tree = get_tree()
		suite.runner = self
		var srep := {"name": f.get_basename(), "tests": []}
		var methods: Array = []
		for m in script.get_script_method_list():
			if String(m.name).begins_with("test_") and not (m.name in methods):
				methods.append(m.name)
		if suite.has_method("before_all"):
			await suite.before_all()
		for m in methods:
			suite.failures.clear()
			var t0 := Time.get_ticks_msec()
			await suite.call(m)
			if suite.has_method("release_captures"):
				suite.release_captures()
			var ok: bool = suite.failures.is_empty()
			var msg := "; ".join(suite.failures)
			srep.tests.append({"name": m, "ok": ok, "ms": Time.get_ticks_msec() - t0, "msg": msg})
			if ok:
				_report.summary.passed += 1
				print("  PASS %s.%s" % [srep.name, m])
			else:
				_report.summary.failed += 1
				print("  FAIL %s.%s: %s" % [srep.name, m, msg])
		if suite.has_method("after_all"):
			await suite.after_all()
		_report.suites.append(srep)
	# global check: no error may be attributed to PittAPI except the deliberate
	# ones raised by test code (files under res://tests/)
	if only == "":
		var unexpected: Array = []
		for e in core.guard.recent(200, "PittAPI"):
			var inner := String(e.frames[0]) if not e.frames.is_empty() else String(e.file)
			# (a second test instance's loader compiling a fixture also shows up here)
			var deliberate := String(e.file).contains("/tests/") or inner.begins_with("res://tests/") \
				or String(e.msg).contains("res://tests/fixtures/")
			if not deliberate:
				unexpected.append("%s (%s:%d)" % [e.msg, e.file, e.line])
		var ok := unexpected.is_empty()
		_report.suites.append({"name": "global", "tests": [{"name": "no_unexpected_core_errors", "ok": ok, "ms": 0,
			"msg": "; ".join(unexpected)}]})
		if ok:
			_report.summary.passed += 1
			print("  PASS global.no_unexpected_core_errors")
		else:
			_report.summary.failed += 1
			print("  FAIL global.no_unexpected_core_errors: %s" % "; ".join(unexpected))
	_finish(0 if _report.summary.failed == 0 else 1)


func _finish(code: int) -> void:
	if _done:
		return
	_done = true
	_report.finished = true
	var core := get_node_or_null("/root/PittAPI")
	if core != null and core.guard != null:
		_report["errors_captured"] = core.guard.recent(50)
	var path := OS.get_environment("PITTAPI_HEADLESS_REPORT")
	if path == "":
		path = ProjectSettings.globalize_path("res://").path_join("../headless-report.json")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_report, "  "))
		f.close()
	print("HEADLESS RESULT: %d passed, %d failed -> %s" % [_report.summary.passed, _report.summary.failed, path])
	get_tree().quit(code)


func _on_watchdog() -> void:
	_report["fatal"] = "watchdog: tests did not finish within %d s" % int(WATCHDOG_S)
	_finish(2)
