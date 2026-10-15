extends Node
## LobbyService base class (MP-DESIGN 5.3). One node, no UI. The Steam, dev
## (ENet) and fake services extend it; screens only see these signals and the
## plain-data models of lobby_model.gd.
##
## Guarantees: lobby_entered fires once per lobby, after transport_target() is
## valid. After leave(), current() is {} and no further signals fire for that
## lobby. Handlers may call back into the service (state is updated before any
## signal is emitted).

const Model = preload("lobby_model.gd")
const MAX_MEMBERS := Model.MAX_MEMBERS

signal lobby_entered(info: Dictionary)          # LobbyInfo; info.is_owner tells host vs member
signal lobby_left(reason: String)               # "left"|"host_left"|"kicked"|"join_failed"|"error"
signal members_changed(members: Array)          # [MemberInfo]
signal lobby_data_changed(info: Dictionary)     # LobbyInfo of the current lobby
signal friend_lobbies_changed(list: Array)      # [LobbyInfo]
signal join_requested(lobby_id: String)         # invite / "Join Game" / +connect_lobby
signal error(code: String, detail: String)      # non-fatal, the UI shows a dialog

## Fallback rescan of the Join list while it is visible (events are the primary path).
var scan_interval_s := 10.0

var api = null
var version: Dictionary = {}
var config: Dictionary = {}

var _current: Dictionary = {}       # LobbyInfo or {}
var _members: Array = []            # [MemberInfo]
var _pending := ""                  # "" | "host" | "join"
var _pending_id := ""
var _scan_active := false
var _scan_next_ms := 0
var _rows: Dictionary = {}          # lobby id -> LobbyInfo (Join list)
var _launch_join := ""              # +connect_lobby id waiting for the first main menu


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


# ------------------------------------------------------------------ lifecycle

func setup(p_api: Object, p_version: Dictionary, p_config: Dictionary) -> void:
	api = p_api
	version = Model.version_info(p_version)
	config = p_config.duplicate() if p_config != null else {}
	if config.has("scan_interval_s"):
		scan_interval_s = float(config.scan_interval_s)
	_setup()


func kind() -> String:
	return "base"


## {ok, reason}: whether hosting / joining can work right now (e.g. Steam running).
## Extra member (not in 5.3); callers check has_method first.
func available() -> Dictionary:
	return {"ok": true, "reason": ""}


## The +connect_lobby id read at launch, once; "" if none. Extra member.
func take_launch_join() -> String:
	var id := _launch_join
	_launch_join = ""
	return id


# ------------------------------------------------------------------ lobby ops

func host(max_members: int = MAX_MEMBERS) -> void:
	if is_in_lobby() or _pending != "":
		_emit_error("MP_ERR_ALREADY_IN_LOBBY", "")
		return
	_pending = "host"
	_pending_id = ""
	_host(clampi(max_members, 2, 250))


func join(lobby_id: String) -> void:
	if lobby_id == "":
		return
	if is_in_lobby() or _pending != "":
		_emit_error("MP_ERR_ALREADY_IN_LOBBY", "")
		return
	_pending = "join"
	_pending_id = lobby_id
	_join(lobby_id)


## Idempotent. Emits lobby_left("left") if it was in a lobby (or creating / joining one).
func leave() -> void:
	var was := is_in_lobby() or _pending != ""
	if not was:
		return
	_leave()
	_reset_lobby_state()
	lobby_left.emit("left")


func invite_friends() -> void:
	if is_in_lobby():
		_invite()


func refresh_friend_lobbies() -> void:
	_refresh()


## Join panel visible: event updates plus a slow fallback rescan.
func set_scan_active(on: bool) -> void:
	if on == _scan_active:
		return
	_scan_active = on
	_scan_next_ms = Time.get_ticks_msec() + int(scan_interval_s * 1000.0)


func is_scan_active() -> bool:
	return _scan_active


func friend_lobbies() -> Array:
	return Model.sort_rows(_rows.values())


# ------------------------------------------------------------------ state

func current() -> Dictionary:
	return _current.duplicate()


func is_in_lobby() -> bool:
	return not _current.is_empty()


## True while host() / join() wait for Steam. Extra member.
func is_pending() -> String:
	return _pending


func is_owner() -> bool:
	return is_in_lobby() and bool(_current.get("is_owner", false))


func get_members() -> Array:
	return _members.duplicate(true)


## Re-reads the member list from the backend now (Steam: getLobbyMemberByIndex).
func refresh_members() -> void:
	pass


func get_local_name() -> String:
	return "Player"


func transport_target() -> Dictionary:
	return {}


## Host only: lobby data "state" plus the joinable rule ("ending" is not joinable).
func set_state(state: String) -> void:
	if not is_owner():
		return
	var s := Model.normalize_state(state)
	_current.state = s
	_current = Model.evaluate(_current, version)
	_current.is_owner = true
	_write_state(s)
	lobby_data_changed.emit(current())


## Host only: an extra lobby data key (e.g. "cheats" = "1", MP-DESIGN 8.4).
## "state" goes through set_state() so the joinable rule stays in one place.
func set_lobby_data(key: String, value: String) -> void:
	if not is_owner() or key == "" or key == "state":
		return
	_current[key] = value
	_write_data(key, value)
	lobby_data_changed.emit(current())


func set_external_members(_list: Array) -> void:
	pass


# ------------------------------------------------------------------ for subclasses

func _setup() -> void:
	pass


func _host(_max_members: int) -> void:
	pass


func _join(_lobby_id: String) -> void:
	pass


func _leave() -> void:
	pass


func _invite() -> void:
	pass


func _refresh() -> void:
	pass


func _write_data(_key: String, _value: String) -> void:
	pass


func _write_state(_state: String) -> void:
	pass


## Enter a lobby: state first, then the signal (transport_target() is valid now).
func _enter(info: Dictionary, members: Array) -> void:
	_pending = ""
	_pending_id = ""
	_current = info.duplicate()
	_members = members.duplicate(true)
	lobby_entered.emit(current())
	members_changed.emit(get_members())


## Leave because of the remote side (host left, kicked, join failed, error).
func _drop(reason: String) -> void:
	var was := is_in_lobby() or _pending != ""
	_reset_lobby_state()
	if was:
		lobby_left.emit(reason)


func _reset_lobby_state() -> void:
	_current = {}
	_members = []
	_pending = ""
	_pending_id = ""


func _set_members(members: Array) -> void:
	_members = members.duplicate(true)
	if is_in_lobby():
		_current.members = _members.size()
	members_changed.emit(get_members())


func _set_rows(rows: Dictionary) -> void:
	_rows = rows
	friend_lobbies_changed.emit(friend_lobbies())


func _emit_error(code: String, detail: String) -> void:
	error.emit(code, detail)


## Wall clock (Engine.time_scale changes in phase 3).
func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _scan_active and scan_interval_s > 0.0 and now >= _scan_next_ms:
		_scan_next_ms = now + int(scan_interval_s * 1000.0)
		_refresh()
	_tick(now)


func _tick(_now_ms: int) -> void:
	pass
