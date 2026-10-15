extends RefCounted
## PittLogger bound to a tag (a mod id or "PittAPI"). All loggers share one Sink.
## Line format: 2026-10-14T18:51:54.123 [INFO ] [ExampleMod] msg {json}

const LEVELS := {"debug": 0, "info": 1, "warn": 2, "error": 3}
const LABELS := ["DEBUG", "INFO ", "WARN ", "ERROR"]

var tag: String
var _sink: Sink


func _init(sink: Sink = null, p_tag: String = "PittAPI") -> void:
	_sink = sink
	tag = p_tag


func debug(msg: String, data: Variant = null) -> void:
	_write(0, msg, data)


func info(msg: String, data: Variant = null) -> void:
	_write(1, msg, data)


func warn(msg: String, data: Variant = null) -> void:
	_write(2, msg, data)


## Logs at error level. This does NOT raise an engine error, so it never counts
## toward quarantine.
func error(msg: String, data: Variant = null) -> void:
	_write(3, msg, data)


func child(p_tag: String) -> RefCounted:
	return get_script().new(_sink, p_tag)


func _write(level: int, msg: String, data: Variant) -> void:
	if _sink != null:
		_sink.write(level, tag, msg, data)
	else:
		print("[%s] [%s] %s" % [LABELS[level], tag, msg])


static func make_sink(path: String, max_bytes: int = 2 * 1024 * 1024, keep: int = 3) -> Sink:
	var s := Sink.new()
	s.open(path, max_bytes, keep)
	return s


## The shared file sink. Rotates at max_bytes and keeps .1 .. .<keep>.
class Sink extends RefCounted:
	var path := ""
	var max_bytes := 2 * 1024 * 1024
	var keep := 3
	var level := 1
	var echo := true
	var recent: Array[String] = []
	var recent_cap := 400
	var _file: FileAccess = null
	var _mutex := Mutex.new()

	func open(p_path: String, p_max: int, p_keep: int) -> void:
		path = p_path
		max_bytes = p_max
		keep = p_keep
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		_reopen()

	func _reopen() -> void:
		if _file != null:
			_file.close()
			_file = null
		if FileAccess.file_exists(path):
			_file = FileAccess.open(path, FileAccess.READ_WRITE)
			if _file != null:
				_file.seek_end()
		else:
			_file = FileAccess.open(path, FileAccess.WRITE)

	func set_level_name(n: String) -> void:
		level = int(LEVELS.get(n.to_lower(), 1))

	func write(lvl: int, tag: String, msg: String, data: Variant) -> void:
		if lvl < level:
			return
		var line := "%s [%s] [%s] %s" % [_timestamp(), LABELS[clampi(lvl, 0, 3)], tag, msg]
		if data != null:
			line += " " + JSON.stringify(data)
		_mutex.lock()
		recent.append(line)
		if recent.size() > recent_cap:
			recent.remove_at(0)
		if _file != null:
			_file.store_line(line)
			_file.flush()
			if _file.get_length() > max_bytes:
				_rotate()
		_mutex.unlock()
		if echo:
			print(line)

	func _rotate() -> void:
		_file.close()
		_file = null
		for i in range(keep, 0, -1):
			var src := path if i == 1 else "%s.%d" % [path, i - 1]
			var dst := "%s.%d" % [path, i]
			if FileAccess.file_exists(dst):
				DirAccess.remove_absolute(dst)
			if FileAccess.file_exists(src):
				DirAccess.rename_absolute(src, dst)
		_file = FileAccess.open(path, FileAccess.WRITE)

	func tail(n: int) -> Array[String]:
		_mutex.lock()
		var out: Array[String] = recent.slice(maxi(0, recent.size() - n))
		_mutex.unlock()
		return out

	func close() -> void:
		_mutex.lock()
		if _file != null:
			_file.close()
			_file = null
		_mutex.unlock()

	static func _timestamp() -> String:
		var d := Time.get_datetime_dict_from_system()
		var ms := Time.get_ticks_msec() % 1000
		return "%04d-%02d-%02dT%02d:%02d:%02d.%03d" % [d.year, d.month, d.day, d.hour, d.minute, d.second, ms]
