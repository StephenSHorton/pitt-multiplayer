extends "lobby_service.gd"
## SteamLobbyService: the ONLY caller of Steam lobby, friends, rich presence and
## overlay functions. Friends-only lobbies never show up in requestLobbyList, so
## discovery goes through friends: getFriendGamePlayed(friend).lobby, then
## requestLobbyData(lobby); the row fills on lobby_data_update.
##
## Steam is reached through `steam` (Engine singleton "Steam" by default; tests
## inject a fake object). Every call is has_method-guarded, signals go through
## steam_signals.gd. Steam.run_callbacks is pumped by the game's Steamworks only.

const Signals = preload("steam_signals.gd")
const LaunchArgs = preload("launch_args.gd")

# Steamworks enum values (checked against the bundled GodotSteam, ClassDB constants)
const LOBBY_TYPE_FRIENDS_ONLY := 1
const FRIEND_FLAG_IMMEDIATE := 4
const RESULT_OK := 1
const ENTER_SUCCESS := 1
const ENTER_DOESNT_EXIST := 2
const ENTER_FULL := 4
const CHAT_LEFT := 2
const CHAT_DISCONNECTED := 4
const CHAT_KICKED := 8
const CHAT_BANNED := 16
const PRESENCE_INTERVAL_MS := 1000

## Injectable Steam object (null: Engine.get_singleton("Steam") in setup).
var steam: Object = null
## Also require the game's Steamworks.is_steam_initialized (off in tests with a fake Steam).
var require_steamworks := true

var _signals = Signals.new()
var _host_id := ""                    # host_steam_id of the current lobby
var _max := MAX_MEMBERS
var _friend_of: Dictionary = {}       # lobby id -> friend id (Join list)
var _cancelled: Dictionary = {}       # lobby ids to leave when their callback arrives
var _cancel_create := false
var _presence_next_ms := 0
var _presence_set := false


func kind() -> String:
	return "steam"


func _setup() -> void:
	if steam == null and Engine.has_singleton("Steam"):
		steam = Engine.get_singleton("Steam")
	_signals.connect_all(steam, _on_steam)
	_launch_join = LaunchArgs.read(steam)


func available() -> Dictionary:
	if steam == null:
		return {"ok": false, "reason": "MP_ERR_NO_STEAM"}
	if require_steamworks:
		var sw := _steamworks()
		if sw == null or not bool(sw.get("is_steam_initialized")):
			return {"ok": false, "reason": "MP_ERR_NO_STEAM"}
	return {"ok": true, "reason": ""}


func get_local_name() -> String:
	var n = _call("getPersonaName")
	return str(n) if n != null and str(n) != "" else "Player"


func transport_target() -> Dictionary:
	if not is_in_lobby():
		return {}
	return Model.steam_target("host" if is_owner() else "client", str(_current.id), _host_id)


func self_id() -> String:
	var v = _call("getSteamID")
	return str(int(v)) if v != null else ""


# ------------------------------------------------------------------ ops

func _host(max_members: int) -> void:
	var av := available()
	if not av.ok:
		_emit_error(av.reason, "")
		_drop("error")
		return
	_max = max_members
	_cancel_create = false
	if not _has("createLobby"):
		_emit_error("MP_ERR_CREATE_FAILED", "createLobby missing")
		_drop("error")
		return
	_call("createLobby", [LOBBY_TYPE_FRIENDS_ONLY, max_members])


func _join(lobby_id: String) -> void:
	var av := available()
	if not av.ok:
		_emit_error(av.reason, "")
		_drop("join_failed")
		return
	if not lobby_id.is_valid_int():
		_emit_error("MP_ERR_JOIN_FAILED", lobby_id)
		_drop("join_failed")
		return
	_cancelled.erase(lobby_id)
	_call("joinLobby", [lobby_id.to_int()])


func _leave() -> void:
	if is_in_lobby():
		_call("leaveLobby", [str(_current.id).to_int()])
	elif _pending == "join" and _pending_id.is_valid_int():
		_cancelled[_pending_id] = true
		_call("leaveLobby", [_pending_id.to_int()])
	elif _pending == "host":
		_cancel_create = true
	_clear_presence()
	_host_id = ""


func _invite() -> void:
	_call("activateGameOverlayInviteDialog", [str(_current.id).to_int()])


func _write_data(key: String, value: String) -> void:
	_call("setLobbyData", [str(_current.id).to_int(), key, value])


func _write_state(state: String) -> void:
	var lid := str(_current.id).to_int()
	_call("setLobbyData", [lid, "state", state])
	_call("setLobbyJoinable", [lid, state != "ending"])


func _refresh() -> void:
	if not available().ok:
		_friend_of.clear()
		_set_rows({})
		return
	var seen: Dictionary = {}
	var count = _call("getFriendCount", [FRIEND_FLAG_IMMEDIATE])
	for i in int(count if count != null else 0):
		var f = _call("getFriendByIndex", [i, FRIEND_FLAG_IMMEDIATE])
		if f == null or int(f) == 0:
			continue
		var lob := _friend_lobby(int(f))
		if lob != "":
			seen[lob] = str(int(f))
	var rows: Dictionary = {}
	for lob in seen:
		_friend_of[lob] = seen[lob]
		if _rows.has(lob):
			rows[lob] = _rows[lob]
		_call("requestLobbyData", [lob.to_int()])
	for lob in _friend_of.keys():
		if not seen.has(lob):
			_friend_of.erase(lob)
	_set_rows(rows)


## The lobby a friend is in for this app, or "".
func _friend_lobby(friend: int) -> String:
	var d = _call("getFriendGamePlayed", [friend])
	if typeof(d) != TYPE_DICTIONARY or d.is_empty():
		return ""
	if int(str(d.get("id", 0))) != Model.APP_ID:
		return ""
	var lob := int(str(d.get("lobby", 0)))
	if lob == 0:
		return ""
	var id := str(lob)
	if is_in_lobby() and id == str(_current.id):
		return ""
	return id


# ------------------------------------------------------------------ Steam signals

func _on_steam(sig: String, args: Array) -> void:
	match sig:
		"lobby_created":
			_on_lobby_created(Signals.arg_int(args, 0), Signals.arg_int(args, 1))
		"lobby_joined":
			_on_lobby_joined(Signals.arg_int(args, 0), Signals.arg_int(args, 3))
		"lobby_chat_update":
			_on_chat_update(Signals.arg_int(args, 0), Signals.arg_int(args, 1), Signals.arg_int(args, 3))
		"lobby_data_update":
			_on_data_update(Signals.arg_int(args, 0), Signals.arg_int(args, 1), Signals.arg_int(args, 2))
		"persona_state_change":
			_on_persona(Signals.arg_int(args, 0))
		"join_requested":
			var lid := Signals.arg_int(args, 0)
			if lid != 0:
				join_requested.emit(str(lid))
		"join_game_requested":
			# "Join Game" on a friend while the game runs (GameRichPresenceJoinRequested_t):
			# the friend's rich presence "connect" string, "+connect_lobby <id>"
			var lid2 := Signals.connect_lobby_of(args)
			if lid2 != "":
				join_requested.emit(lid2)


func _on_lobby_created(result: int, lobby: int) -> void:
	if _pending != "host" or _cancel_create:
		_cancel_create = false
		if lobby != 0 and result == RESULT_OK:
			_call("leaveLobby", [lobby])
		return
	if result != RESULT_OK or lobby == 0:
		_emit_error("MP_ERR_CREATE_FAILED", str(result))
		_drop("error")
		return
	var id := str(lobby)
	_host_id = self_id()
	var data := Model.host_data(version, get_local_name(), _host_id, 1, _max, "waiting")
	for k in data:
		_call("setLobbyData", [lobby, k, data[k]])
	_call("setLobbyJoinable", [lobby, true])
	var info := Model.from_lobby_data(id, data, version)
	info.is_owner = true
	info.owner_id = _host_id
	var members := _read_members(id)
	if members.is_empty():
		members = [Model.member_info(_host_id, get_local_name(), true, true)]
	info.members = members.size()
	_assert_presence(id, members.size())
	_enter(info, members)


func _on_lobby_joined(lobby: int, response: int) -> void:
	var id := str(lobby)
	if is_in_lobby() and id == str(_current.id):
		_refresh_members()   # the creator also gets lobby_joined
		return
	if _pending != "join" or id != _pending_id:
		if _cancelled.has(id) and response == ENTER_SUCCESS:
			_call("leaveLobby", [lobby])
		_cancelled.erase(id)
		return
	if response != ENTER_SUCCESS:
		var code := "MP_ERR_JOIN_FAILED"
		if response == ENTER_FULL:
			code = Model.ERR_FULL
		elif response == ENTER_DOESNT_EXIST:
			code = "MP_ERR_LOBBY_GONE"
		_emit_error(code, str(response))
		_drop("join_failed")
		return
	var data := _lobby_data(id)
	var owner := _owner_of(id)
	var host := str(data.get("host_steam_id", ""))
	if host == "":
		host = owner
	var info := Model.from_lobby_data(id, data, version)
	if not info.compatible or str(info.state) == "ending":
		_call("leaveLobby", [lobby])
		_emit_error(info.reason if info.reason != "" else "MP_ERR_JOIN_FAILED", "")
		_drop("join_failed")
		return
	if owner != "" and owner != "0" and owner != host:
		_call("leaveLobby", [lobby])
		_drop("host_left")
		return
	info.is_owner = false
	info.owner_id = host
	_host_id = host
	var members := _read_members(id)
	info.members = maxi(members.size(), int(info.members))
	info = Model.evaluate(info, version)
	info.joinable = true      # we are in: "full" no longer applies to us
	info.reason = ""
	_assert_presence(id, members.size())
	_enter(info, members)


func _on_chat_update(lobby: int, changed: int, state: int) -> void:
	if not is_in_lobby() or str(lobby) != str(_current.id):
		return
	var gone := (state & (CHAT_LEFT | CHAT_DISCONNECTED | CHAT_KICKED | CHAT_BANNED)) != 0
	if not is_owner():
		if gone and str(changed) == _host_id:
			_host_gone("host_left")
			return
		if (state & (CHAT_KICKED | CHAT_BANNED)) != 0 and str(changed) == self_id():
			_host_gone("kicked")
			return
		if _owner_changed():
			_host_gone("host_left")
			return
	_refresh_members()


func _on_data_update(success: int, lobby: int, member: int) -> void:
	var id := str(lobby)
	if is_in_lobby() and id == str(_current.id):
		if member != 0 and member != lobby:
			return   # member data, not lobby data
		if not is_owner() and _owner_changed():
			_host_gone("host_left")
			return
		var data := _lobby_data(id)
		var keep_owner := is_owner()
		_current.state = Model.normalize_state(str(data.get("state", _current.state)))
		_current.max = int(str(data.get("max", str(_current.max))))
		_current.members = maxi(_members.size(), int(str(data.get("members", str(_current.members)))))
		_current.is_owner = keep_owner
		lobby_data_changed.emit(current())
		return
	if not _friend_of.has(id) and not _rows.has(id):
		return
	var rows := _rows.duplicate()
	if success == 0:
		rows.erase(id)
	else:
		var data2 := _lobby_data(id)
		if data2.is_empty():
			rows.erase(id)
		else:
			var row := Model.from_lobby_data(id, data2, version)
			if str(row.host_name) == "" and _friend_of.has(id):
				row.host_name = str(_call("getFriendPersonaName", [str(_friend_of[id]).to_int()]))
			rows[id] = row
	_set_rows(rows)


func _on_persona(steam_id: int) -> void:
	var sid := str(steam_id)
	if is_in_lobby():
		for m in _members:
			if str(m.id) == sid:
				_refresh_members()
				break
	if not _scan_active:
		return
	var lob := _friend_lobby(steam_id)
	var changed := false
	for k in _friend_of.keys():
		if str(_friend_of[k]) == sid and k != lob:
			_friend_of.erase(k)
			if _rows.has(k):
				_rows.erase(k)
				changed = true
	if lob != "":
		_friend_of[lob] = sid
		_call("requestLobbyData", [lob.to_int()])
	if changed:
		_set_rows(_rows)


# ------------------------------------------------------------------ helpers

func _host_gone(reason: String) -> void:
	if is_in_lobby():
		_call("leaveLobby", [str(_current.id).to_int()])
	_clear_presence()
	_host_id = ""
	_drop(reason)


func _owner_changed() -> bool:
	if _host_id == "" or not is_in_lobby():
		return false
	var owner := _owner_of(str(_current.id))
	return owner != "" and owner != "0" and owner != _host_id


func _owner_of(id: String) -> String:
	var o = _call("getLobbyOwner", [id.to_int()])
	return str(int(o)) if o != null else ""


func _lobby_data(id: String) -> Dictionary:
	var lid := id.to_int()
	var out: Dictionary = {}
	for k in Model.DATA_KEYS:
		var v = _call("getLobbyData", [lid, k])
		if v != null and str(v) != "":
			out[k] = str(v)
	return out


func _read_members(id: String) -> Array:
	var lid := id.to_int()
	var me := self_id()
	var out: Array = []
	var n = _call("getNumLobbyMembers", [lid])
	for i in int(n if n != null else 0):
		var m = _call("getLobbyMemberByIndex", [lid, i])
		if m == null or int(m) == 0:
			continue
		var mid := str(int(m))
		var nm := ""
		if mid == me:
			nm = get_local_name()
		else:
			nm = str(_call("getFriendPersonaName", [int(m)]))
			if nm == "" or nm == "[unknown]":
				_call("requestUserInformation", [int(m), true])
		out.append(Model.member_info(mid, nm if nm != "" else "...", mid == _host_id, mid == me))
	return out


func refresh_members() -> void:
	_refresh_members()


func _refresh_members() -> void:
	if not is_in_lobby():
		return
	var members := _read_members(str(_current.id))
	if members.is_empty():
		return
	_set_members(members)
	if is_owner():
		var lid := str(_current.id).to_int()
		_call("setLobbyData", [lid, "members", str(members.size())])
		_assert_presence(str(_current.id), members.size())
	lobby_data_changed.emit(current())


func _assert_presence(id: String, size: int) -> void:
	_call("setRichPresence", ["connect", "+connect_lobby " + id])
	_call("setRichPresence", ["steam_player_group", id])
	_call("setRichPresence", ["steam_player_group_size", str(size)])
	_presence_set = true
	_presence_next_ms = Time.get_ticks_msec() + PRESENCE_INTERVAL_MS


func _clear_presence() -> void:
	if not _presence_set:
		return
	for k in ["connect", "steam_player_group", "steam_player_group_size"]:
		_call("setRichPresence", [k, ""])
	_presence_set = false


func _tick(now_ms: int) -> void:
	if is_in_lobby() and now_ms >= _presence_next_ms:
		_assert_presence(str(_current.id), maxi(1, _members.size()))


func _steamworks() -> Object:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("Steamworks")


func _has(m: String) -> bool:
	return steam != null and steam.has_method(m)


func _call(m: String, args: Array = []) -> Variant:
	if steam == null or not is_instance_valid(steam) or not steam.has_method(m):
		return null
	return steam.callv(m, args)


func _exit_tree() -> void:
	if is_in_lobby():
		_call("leaveLobby", [str(_current.id).to_int()])
		_clear_presence()
		_reset_lobby_state()
	_signals.disconnect_all()
