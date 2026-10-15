extends RefCounted
## SafeFS: every file PittAPI writes goes through here. It refuses anything that
## looks like a game save (savegame*, sandbox.save*, profile.cfg) and anything
## outside the PittAPI user root. It records every path it touched so the tests
## can prove the API never opened a save file.

var root := "user://pittapi"
var touched: Array[String] = []
var refused: Array[String] = []


func _init(p_root: String = "user://pittapi") -> void:
	root = p_root.trim_suffix("/")


static func is_save_file(path: String) -> bool:
	var f := path.replace("\\", "/").get_file().to_lower()
	return f.begins_with("savegame") or f.begins_with("sandbox.save") or f == "profile.cfg" \
		or f == "keybindings.cfg" or f == "settings.cfg"


func is_allowed(path: String) -> bool:
	if is_save_file(path):
		return false
	if path.contains(".."):
		return false
	var p := path.replace("\\", "/")
	return p.begins_with(root + "/")


func _check(path: String) -> bool:
	touched.append(path)
	if not is_allowed(path):
		refused.append(path)
		push_warning("[PittAPI] refused to write %s (outside %s or a game save file)" % [path, root])
		return false
	return true


## Writes text via <path>.tmp then rename (atomic on the same volume).
func write_text_atomic(path: String, text: String) -> Error:
	if not _check(path):
		return ERR_FILE_NO_PERMISSION
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(text)
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	return DirAccess.rename_absolute(tmp, path)


func write_json(path: String, data: Variant) -> Error:
	return write_text_atomic(path, JSON.stringify(data, "  "))


func read_json(path: String) -> Variant:
	touched.append(path)
	if is_save_file(path) or not FileAccess.file_exists(path):
		return null
	var j := JSON.new()
	if j.parse(FileAccess.get_file_as_string(path)) != OK:
		return null
	return j.data


func save_config(cfg: ConfigFile, path: String) -> Error:
	if not _check(path):
		return ERR_FILE_NO_PERMISSION
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	return cfg.save(path)


func remove(path: String) -> Error:
	if not _check(path):
		return ERR_FILE_NO_PERMISSION
	if FileAccess.file_exists(path):
		return DirAccess.remove_absolute(path)
	return OK


func remove_dir_recursive(dir: String) -> Error:
	if not _check(dir.path_join("x")):
		return ERR_FILE_NO_PERMISSION
	var da := DirAccess.open(dir)
	if da == null:
		return OK
	for f in da.get_files():
		DirAccess.remove_absolute(dir.path_join(f))
	for d in da.get_directories():
		remove_dir_recursive(dir.path_join(d))
	return DirAccess.remove_absolute(dir)


func touched_save_files() -> Array[String]:
	var out: Array[String] = []
	for p in touched:
		if is_save_file(p):
			out.append(p)
	return out
