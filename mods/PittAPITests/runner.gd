extends RefCounted
## Assertions and the JSON report for the live test mod.
## Report: user://pittapi/test_report.json, written after every suite with
## finished:false until the end, so a crash still leaves partial results.

var api = null
var report_path := ""
var report: Dictionary = {}
var _suite: Dictionary = {}
var _t0 := 0


func _init(p_api, run_id: String) -> void:
	api = p_api
	report_path = api.pittapi_dir().path_join("test_report.json")
	report = {
		"run_id": run_id,
		"api_version": api.api_version,
		"game_version": api.game_version,
		"finished": false,
		"started": Time.get_datetime_string_from_system(),
		"summary": {"passed": 0, "failed": 0, "skipped": 0, "info": 0},
		"suites": [],
		"errors_captured": [],
	}


func begin_suite(name: String) -> void:
	_suite = {"name": name, "tests": [], "started_ms": Time.get_ticks_msec()}
	report.suites.append(_suite)
	_t0 = Time.get_ticks_msec()
	api.log.info("suite %s started" % name)


func end_suite() -> void:
	if not _suite.is_empty():
		_suite["ms"] = Time.get_ticks_msec() - int(_suite.started_ms)
	write(false)


## Records one test. info=true: informational (never counts as a failure).
func check(name: String, ok: bool, msg: String = "", info: bool = false) -> bool:
	var now := Time.get_ticks_msec()
	var t := {"name": name, "ok": ok, "ms": now - _t0, "msg": msg}
	_t0 = now
	if info:
		t["info"] = true
		report.summary.info += 1
	elif ok:
		report.summary.passed += 1
	else:
		report.summary.failed += 1
	if _suite.is_empty():
		begin_suite("misc")
	_suite.tests.append(t)
	var tag := "INFO" if info else ("PASS" if ok else "FAIL")
	print("[PittAPITests] %s %s %s" % [tag, name, msg])
	if not ok and not info:
		api.log.warn("FAIL %s: %s" % [name, msg])
	return ok


func eq(name: String, actual: Variant, expected: Variant, msg: String = "") -> bool:
	var same: bool = typeof(actual) == typeof(expected) and actual == expected
	return check(name, same, "%s expected=%s actual=%s" % [msg, var_to_str(expected), var_to_str(actual)] if not same else msg)


func skip(name: String, why: String) -> void:
	report.summary.skipped += 1
	if _suite.is_empty():
		begin_suite("misc")
	_suite.tests.append({"name": name, "ok": true, "skipped": true, "ms": 0, "msg": why})
	print("[PittAPITests] SKIP %s %s" % [name, why])


func fatal(msg: String) -> void:
	report["fatal"] = msg
	check("fatal", false, msg)


func write(finished: bool) -> void:
	report.finished = finished
	report.errors_captured = api.recent_errors(100)
	if finished:
		report["ended"] = Time.get_datetime_string_from_system()
	DirAccess.make_dir_recursive_absolute(report_path.get_base_dir())
	var tmp := report_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(report, "  "))
	f.close()
	if FileAccess.file_exists(report_path):
		DirAccess.remove_absolute(report_path)
	DirAccess.rename_absolute(tmp, report_path)


func failed_count() -> int:
	return int(report.summary.failed)


## Await helper: waits up to timeout_s for cond() to be true (polled per frame).
func wait_until(tree: SceneTree, cond: Callable, timeout_s: float) -> bool:
	var end := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await tree.process_frame
	return bool(cond.call())
