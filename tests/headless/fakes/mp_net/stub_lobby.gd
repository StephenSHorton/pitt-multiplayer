extends Node
## NET's test double of the LobbyService (MP-DESIGN 5.3, 5.6). Implements every
## 5.3 member; driven by test code: enter(info, target) / drop(reason).
## test_mp_ui_contract.gd (UI) checks it has every 5.3 member.

const MAX_MEMBERS := 10

signal lobby_entered(info: Dictionary)
signal lobby_left(reason: String)
signal members_changed(members: Array)
signal lobby_data_changed(info: Dictionary)
signal friend_lobbies_changed(list: Array)
signal join_requested(lobby_id: String)
signal error(code: String, detail: String)

var api = null
var version: Dictionary = {}
var config: Dictionary = {}
var local_name := "Player"
var _kind := "fake"
var _current: Dictionary = {}
var _target: Dictionary = {}
var _members: Array = []
var states: Array = []          # every set_state() value
var remote_states: Array = []   # client side set_remote_state()
var external: Array = []        # last set_external_members()
var leaves := 0
var hosts := 0
var joins: Array = []
var scan_active := false


func setup(p_api: Object, p_version: Dictionary, p_config: Dictionary) -> void:
	api = p_api
	version = p_version
	config = p_config


func kind() -> String:
	return _kind


func set_kind(k: String) -> void:
	_kind = k


func host(_max_members: int = MAX_MEMBERS) -> void:
	hosts += 1


func join(lobby_id: String) -> void:
	joins.append(lobby_id)


func leave() -> void:
	leaves += 1
	if _current.is_empty():
		return
	_current = {}
	_target = {}
	lobby_left.emit("left")


func invite_friends() -> void:
	pass


func refresh_friend_lobbies() -> void:
	pass


func set_scan_active(on: bool) -> void:
	scan_active = on


func current() -> Dictionary:
	return _current.duplicate()


func is_in_lobby() -> bool:
	return not _current.is_empty()


func is_owner() -> bool:
	return bool(_current.get("is_owner", false))


func get_members() -> Array:
	return _members.duplicate(true)


func get_local_name() -> String:
	return local_name


func transport_target() -> Dictionary:
	return _target if is_in_lobby() else {}


func set_state(state: String) -> void:
	states.append(state)
	if is_in_lobby():
		_current.state = state


func set_external_members(members: Array) -> void:
	external = members.duplicate(true)


func set_remote_state(state: String) -> void:
	remote_states.append(state)


# ------------------------------------------------------------------ test drivers

## Enters a lobby: transport_target() is valid before lobby_entered fires.
func enter(info: Dictionary, target: Dictionary) -> void:
	_current = info.duplicate()
	if not _current.has("id"):
		_current["id"] = "stub:1"
	_target = target
	lobby_entered.emit(current())


## The remote side ends the lobby ("host_left", "kicked", "error", ...).
func drop(reason: String) -> void:
	if _current.is_empty():
		return
	_current = {}
	_target = {}
	lobby_left.emit(reason)
