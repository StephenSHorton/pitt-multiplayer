extends RefCounted
## Machine-readable report of one instance, rewritten after every step so a
## crash still leaves partial results. Marks (name -> unix ms) and values are
## how the two instances synchronize: each side polls the other's report file
## (both paths come from the flag; the files may live in different user dirs).

var path := ""
var data := {"run_id": "", "role": "", "started": "", "finished": false, "steps": [],
	"summary": {"passed": 0, "failed": 0, "info": 0}, "marks": {}, "values": {}, "fatal": ""}
var _step := ""
var _t0 := 0


func _init(p_path: String, run_id: String, role: String) -> void:
	path = p_path
	data.run_id = run_id
	data.role = role
	data.started = Time.get_datetime_string_from_system()
	write()


static func unix_ms() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0)


func begin(step: String) -> void:
	_step = step
	_t0 = Time.get_ticks_msec()


func check(name: String, ok: bool, msg: String = "") -> bool:
	data.steps.append({"step": _step, "name": name, "ok": ok, "ms": Time.get_ticks_msec() - _t0, "msg": msg})
	if ok:
		data.summary.passed += 1
	else:
		data.summary.failed += 1
	print("  %s %s.%s %s" % ["PASS" if ok else "FAIL", _step, name, msg])
	write()
	return ok


func info(name: String, msg: String) -> void:
	data.steps.append({"step": _step, "name": name, "ok": true, "info": true, "ms": Time.get_ticks_msec() - _t0, "msg": msg})
	data.summary.info += 1
	print("  INFO %s.%s %s" % [_step, name, msg])
	write()


func mark(name: String, value: Variant = null) -> void:
	data.marks[name] = unix_ms()
	if value != null:
		data.values[name] = value
	write()


func value(name: String, v: Variant) -> void:
	data.values[name] = v
	write()


func fatal(msg: String) -> void:
	data.fatal = msg
	print("  FATAL %s" % msg)
	write()


func finish() -> void:
	data.finished = true
	write()


func write() -> void:
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(data, "  "))
	f.close()
	# the peer polls this file every 100 ms: on Windows a remove/rename while it
	# has the file open fails, and a mark written right before a long wait was
	# then never seen (the host's client_got_unlock / client_conditioned_ok
	# timeouts). Retry until the rename lands.
	for i in 50:
		DirAccess.remove_absolute(path)
		if DirAccess.rename_absolute(tmp, path) == OK:
			return
		OS.delay_msec(10)
	push_warning("PittMPTests: could not replace %s" % path)


## The other instance's report, or {} if not readable yet.
static func read(p: String) -> Dictionary:
	if p == "" or not FileAccess.file_exists(p):
		return {}
	var d = JSON.parse_string(FileAccess.get_file_as_string(p))
	return d if typeof(d) == TYPE_DICTIONARY else {}
