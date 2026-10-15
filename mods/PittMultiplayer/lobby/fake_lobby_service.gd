extends "lobby_service.gd"
## FakeLobbyService: scripted LobbyService for headless UI tests and the
## render check. No Steam. Test code drives it:
##   world: Dictionary            lobbies that "exist" (id -> LobbyInfo fields);
##                                refresh_friend_lobbies() reads all of them
##   publish(info)                adds/updates a lobby AND fires the event path
##   publish_silent(info)         adds/updates without an event (a missed Steam event)
##   unpublish(id, silent)
##   join_result                  "" = joins succeed; else lobby_left(join_result)
##   join_error                   error code emitted when a join fails
##   set_remote_members(list)     members of the current lobby ([MemberInfo])
##   drop(reason)                 the remote side ends the lobby (host_left, kicked...)
##   request_join(id)             a Steam invite / "Join Game"
##   fail(code, detail)           non-fatal error signal
## Every public call is recorded in `calls` as [name, args].

var calls: Array = []
var world: Dictionary = {}
var join_result := ""
var join_error := ""
var host_result := ""
var local_name := "Player 1"
var launch_join := ""
var avail := {"ok": true, "reason": ""}
var refresh_count := 0


func kind() -> String:
	return "fake"


func _setup() -> void:
	_launch_join = launch_join
	calls.append(["setup", [version, config]])


func available() -> Dictionary:
	return avail.duplicate()


func get_local_name() -> String:
	return local_name


func transport_target() -> Dictionary:
	if not is_in_lobby():
		return {}
	return Model.enet_target("host" if is_owner() else "client", "127.0.0.1", 27450)


func host(max_members: int = MAX_MEMBERS) -> void:
	calls.append(["host", [max_members]])
	super(max_members)


func join(lobby_id: String) -> void:
	calls.append(["join", [lobby_id]])
	super(lobby_id)


func leave() -> void:
	calls.append(["leave", []])
	super()


func invite_friends() -> void:
	calls.append(["invite_friends", []])
	super()


func refresh_friend_lobbies() -> void:
	calls.append(["refresh_friend_lobbies", []])
	super()


func set_scan_active(on: bool) -> void:
	calls.append(["set_scan_active", [on]])
	super(on)


func set_state(state: String) -> void:
	calls.append(["set_state", [state]])
	super(state)


func set_external_members(list: Array) -> void:
	calls.append(["set_external_members", [list]])
	if is_in_lobby():
		_set_members(list)


func called(name: String) -> int:
	var n := 0
	for c in calls:
		if c[0] == name:
			n += 1
	return n


# ------------------------------------------------------------------ service hooks

func _host(max_members: int) -> void:
	if host_result != "":
		_emit_error(host_result, "")
		_drop.call_deferred("error")
		return
	var info := Model.lobby_info({"id": "fake:%d" % (1000 + calls.size()), "owner_id": "fake:self",
		"host_name": local_name, "members": 1, "max": max_members, "state": "waiting"})
	for k in version:
		info[k] = version[k]
	info = Model.evaluate(info, version)
	info.is_owner = true
	_enter_later.call_deferred(info, [Model.member_info("fake:self", local_name, true, true)])


func _join(lobby_id: String) -> void:
	if join_result != "":
		if join_error != "":
			_emit_error(join_error, "")
		_drop.call_deferred(join_result)
		return
	var src: Dictionary = world.get(lobby_id, {"id": lobby_id, "host_name": "Host", "members": 1})
	var info := Model.lobby_info(src)
	for k in version:
		if not src.has(k):
			info[k] = version[k]
	info = Model.evaluate(info, version)
	info.is_owner = false
	info.id = lobby_id
	var host_member := Model.member_info(str(src.get("owner_id", "fake:host")), str(info.host_name), true, false)
	_enter_later.call_deferred(info, [host_member, Model.member_info("fake:self", local_name, false, true)])


func _enter_later(info: Dictionary, members: Array) -> void:
	if _pending == "" or is_in_lobby():
		return
	_enter(info, members)


func _refresh() -> void:
	refresh_count += 1
	var rows: Dictionary = {}
	for id in world:
		rows[id] = _row(world[id])
	_set_rows(rows)


func _row(src: Dictionary) -> Dictionary:
	var info := Model.lobby_info(src)
	for k in ["pitt_version", "pittapi_version", "mp_proto", "mods_hash"]:
		if not src.has(k):
			info[k] = version.get(k, info[k])
	return Model.evaluate(info, version)


# ------------------------------------------------------------------ test drivers

func publish(src: Dictionary) -> void:
	world[str(src.id)] = src.duplicate()
	var rows := _rows.duplicate()
	rows[str(src.id)] = _row(src)
	_set_rows(rows)


func publish_silent(src: Dictionary) -> void:
	world[str(src.id)] = src.duplicate()


func unpublish(id: String, silent: bool = false) -> void:
	world.erase(id)
	if not silent:
		var rows := _rows.duplicate()
		rows.erase(id)
		_set_rows(rows)


func set_remote_members(list: Array) -> void:
	if is_in_lobby():
		_set_members(list)
		lobby_data_changed.emit(current())


func set_remote_state(state: String) -> void:
	if is_in_lobby():
		_current.state = Model.normalize_state(state)
		lobby_data_changed.emit(current())


func drop(reason: String) -> void:
	_drop(reason)


func request_join(id: String) -> void:
	join_requested.emit(id)


func fail(code: String, detail: String = "") -> void:
	_emit_error(code, detail)
