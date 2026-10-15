extends Node
## Headless fake of SaveManager. It NEVER writes files: fake_save() only moves
## _last_save_tick like a successful save would.

signal save_loaded

const SAVE_FILE_PATH = "user://savegame.save"
const MAX_SAVE_SLOTS := 10

var _last_save_tick := -1000000
var should_load_on_ready = false
var pending_camera_data = {}
var autosave_enabled = true
var save_locked: bool = false
var is_loading := false
var pending_pool_data := {}
var active_save_path: String = SAVE_FILE_PATH


func set_active_save_path(path: String) -> void:
	active_save_path = path


## slot 0 is the base file, slot n > 0 is "savegame_<n + 1>"
func slot_path(slot: int) -> String:
	return SAVE_FILE_PATH if slot <= 0 else "user://savegame_%d.save" % [slot + 1]


func slot_from_path(path: String) -> int:
	for slot in MAX_SAVE_SLOTS:
		if slot_path(slot) == path:
			return slot
	return -1


func fake_save() -> void:
	_last_save_tick = int(Time.get_ticks_msec())


func fake_load() -> void:
	save_loaded.emit()
