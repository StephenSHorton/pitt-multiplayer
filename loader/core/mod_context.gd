extends RefCounted
## PittAPIContext: the handle each mod receives in _mod_init(api). Bound to the
## mod: its id, logger, config, keybinds, save sidecar and paths. Everything a mod
## registers through it is removed again if the mod is quarantined.

var mod_id: String = ""
var mod_dir: String = ""
var version: String = ""
var api_version: String = ""
var game_version: String = ""

var log = null          # PittLogger
var config = null       # PittConfig
var events = null       # PittEvents (bound)
var commands = null     # PittCommands (bound)
var entities = null     # PittEntities
var state = null        # PittState
var spawn = null        # PittSpawn
var player = null       # PittPlayer
var hud = null          # PittHud
var input = null        # PittInput
var saves = null        # PittSaves
var console = null      # PittConsole
var net = null          # PittNet
var extensions = null   # read-only view of the extension registry

var _core: Object = null


func _init(core: Object = null, p_mod_id: String = "", p_dir: String = "", p_version: String = "") -> void:
	_core = core
	mod_id = p_mod_id
	mod_dir = p_dir
	version = p_version


func has_mod(id: String) -> bool:
	return _core != null and _core.loader.is_active(id)


## Another mod's exported object (its entry's get_public_api()), or null.
func get_mod_api(id: String) -> Object:
	if _core == null or not _core.loader.is_active(id):
		return null
	var node = _core.loader.mods[id].node
	if node == null or not is_instance_valid(node) or not node.has_method("get_public_api"):
		return null
	var v = _core.guard_call(id, Callable(node, "get_public_api"), [])
	return v if typeof(v) == TYPE_OBJECT else null


## Calls into another callable on behalf of this mod (errors are attributed to it).
func invoke(callable: Callable, args: Array = []) -> Variant:
	if _core == null:
		return null
	return _core.guard_call(mod_id, callable, args)


## The mod's state record as written to status.json.
func get_status(id: String = "") -> Dictionary:
	var want := id if id != "" else mod_id
	for s in _core.loader.status():
		if s.id == want:
			return s
	return {}


func list_mods() -> Array:
	return _core.loader.status()


## Absolute path of a file inside this mod's folder (read-only use).
func path(rel: String) -> String:
	return mod_dir.path_join(rel)


## Directory under user://pittapi/mods/<id>/ that this mod may write to.
func data_dir() -> String:
	var d: String = _core.user_path("mods/%s" % mod_id)
	DirAccess.make_dir_recursive_absolute(d)
	return d


## PittAPI's user folder (user://pittapi). Mods should write only under data_dir().
func pittapi_dir() -> String:
	return _core.user_root


## Recent engine errors seen by ErrorGuard ([{t_ms, mod, msg, file, line, type, frames}]).
func recent_errors(n: int = 50, mod_filter: String = "") -> Array:
	return _core.guard.recent(n, mod_filter)


## Checks a mod's own game contract with the core checker (same format as
## loader/core/contract.gd: "feature|target|kind|member"; target = autoload name
## or res:// script path). -> {ok: bool, missing: [String], features_off: [String]}
func contract_check(entries: Array) -> Dictionary:
	return _core.contract_check_entries(entries)


## True once the loader finished booting (all _mod_init calls done).
func is_booted() -> bool:
	return _core.booted
