extends "res://tests/test_case.gd"
## SteamLobbyService against FakeSteam (same names / arities as the bundled
## GodotSteam): friends-only create with lobby data + presence, member list from
## lobby_chat_update, host_left on owner loss / migration (R8), friend discovery
## via getFriendGamePlayed + requestLobbyData + lobby_data_update, join errors,
## join_requested, launch args and the signal-arity adapters.

const FakeSteam = preload("res://tests/fakes/mp_ui/fake_steam.gd")
const VERSION := {"pitt_version": "1.0.8", "pittapi_version": "1.1.0", "mp_proto": 1, "mods_hash": "abcd"}
const APP := 4026250
const LOBBY := 109775240000000555
const HOST := 76561190000000099
const FRIEND := 76561190000000077

var fs = null
var svc: Node = null
var ev: Dictionary = {}


func _mod(rel: String) -> String:
	return String(core.mods_dir).path_join("PittMultiplayer").path_join(rel)


func _open() -> void:
	fs = FakeSteam.new()
	svc = load(_mod("lobby/steam_lobby_service.gd")).new()
	svc.steam = fs
	svc.require_steamworks = false
	runner.add_child(svc)
	svc.setup(null, VERSION, {})
	ev = {"entered": [], "left": [], "members": [], "data": [], "friends": [], "join": [], "error": []}
	svc.lobby_entered.connect(func(i): ev.entered.append(i))
	svc.lobby_left.connect(func(r): ev.left.append(r))
	svc.members_changed.connect(func(m): ev.members.append(m))
	svc.lobby_data_changed.connect(func(i): ev.data.append(i))
	svc.friend_lobbies_changed.connect(func(l): ev.friends.append(l))
	svc.join_requested.connect(func(id): ev.join.append(id))
	svc.error.connect(func(c, d): ev.error.append(c))


func _close() -> void:
	if svc != null and is_instance_valid(svc):
		svc.queue_free()
	svc = null
	await wait_frames(1)


func _host_data(extra: Dictionary = {}) -> Dictionary:
	var d := {"host_name": "Hosty", "host_steam_id": str(HOST), "pitt_version": "1.0.8", "pittapi_version": "1.1.0",
		"mp_proto": "1", "mods_hash": "abcd", "members": "2", "max": "10", "state": "waiting"}
	for k in extra:
		d[k] = extra[k]
	return d


func test_host_creates_friends_only_lobby() -> void:
	_open()
	svc.host()
	assert_eq(fs.called("createLobby"), [[1, 10]], "friends-only, max 10")
	assert_eq(svc.transport_target(), {}, "no target before lobby_created")
	fs.lobby_members[LOBBY] = [fs.me]
	fs.lobby_owner[LOBBY] = fs.me
	fs.lobby_created.emit(1, LOBBY)
	var data: Dictionary = fs.lobby_data.get(LOBBY, {})
	for k in ["host_name", "host_steam_id", "pitt_version", "pittapi_version", "mp_proto", "mods_hash", "members", "max", "state"]:
		assert_true(data.has(k), "lobby data " + k)
	assert_eq(data.get("state"), "waiting", "state waiting")
	assert_eq(data.get("host_name"), "Me", "persona name")
	assert_eq(data.get("host_steam_id"), str(fs.me), "host id")
	assert_eq(data.get("members"), "1", "members")
	assert_eq(fs.called("setLobbyJoinable"), [[LOBBY, true]], "joinable")
	assert_eq(fs.presence.get("connect", ""), "+connect_lobby %d" % LOBBY, "rich presence connect")
	assert_eq(fs.presence.get("steam_player_group", ""), str(LOBBY), "player group")
	assert_eq(ev.entered.size(), 1, "lobby_entered once")
	assert_true(ev.entered[0].is_owner, "owner")
	assert_eq(ev.entered[0].id, str(LOBBY), "string id")
	assert_eq(svc.transport_target(), {"kind": "steam", "role": "host", "lobby_id": str(LOBBY), "host_steam_id": str(fs.me)}, "target")
	fs.lobby_joined.emit(LOBBY, 0, false, 1)
	assert_eq(ev.entered.size(), 1, "creator's own lobby_joined does not re-enter")

	# a friend joins: member list + lobby data members
	fs.lobby_members[LOBBY] = [fs.me, FRIEND]
	fs.names[FRIEND] = "Fred"
	fs.lobby_chat_update.emit(LOBBY, FRIEND, FRIEND, 1)
	assert_eq(svc.get_members().size(), 2, "two members")
	assert_eq(svc.get_members()[1].name, "Fred", "persona")
	assert_eq(fs.lobby_data[LOBBY]["members"], "2", "host rewrites members")
	assert_eq(fs.presence.get("steam_player_group_size", ""), "2", "group size")

	# extra lobby data (NET's cheats tag, MP-DESIGN 8.4); "state" is reserved for set_state
	svc.set_lobby_data("cheats", "1")
	assert_eq(fs.lobby_data[LOBBY].get("cheats", ""), "1", "set_lobby_data writes through")
	svc.set_lobby_data("state", "bogus")
	assert_eq(fs.lobby_data[LOBBY]["state"], "waiting", "set_lobby_data cannot change state")

	# state + joinable rule
	svc.set_state("in_game")
	assert_eq(fs.lobby_data[LOBBY]["state"], "in_game", "in_game")
	assert_eq(fs.called("setLobbyJoinable").back(), [LOBBY, true], "in_game stays joinable")
	svc.set_state("ending")
	assert_eq(fs.called("setLobbyJoinable").back(), [LOBBY, false], "ending not joinable")

	# presence re-asserted at 1 Hz (clear_presence() of the game wipes it)
	fs.presence.clear()
	svc._tick(Time.get_ticks_msec() + 1500)
	assert_eq(fs.presence.get("connect", ""), "+connect_lobby %d" % LOBBY, "re-asserted")

	svc.invite_friends()
	assert_eq(fs.called("activateGameOverlayInviteDialog"), [[LOBBY]], "invite overlay")

	svc.leave()
	assert_eq(fs.called("leaveLobby"), [[LOBBY]], "leaveLobby")
	assert_eq(ev.left, ["left"], "lobby_left(left)")
	assert_eq(svc.current(), {}, "current cleared")
	assert_false(fs.presence.has("connect"), "presence cleared on leave")
	svc.leave()
	assert_eq(ev.left.size(), 1, "leave idempotent")
	var n_members: int = ev.members.size()
	var n_data: int = ev.data.size()
	fs.lobby_chat_update.emit(LOBBY, FRIEND, FRIEND, 2)
	fs.lobby_data_update.emit(1, LOBBY, LOBBY)
	assert_eq([ev.members.size(), ev.data.size()], [n_members, n_data], "no signals for a left lobby")
	await _close()


func test_create_failure() -> void:
	_open()
	svc.host()
	fs.lobby_created.emit(2, 0)
	assert_eq(ev.error, ["MP_ERR_CREATE_FAILED"], "error")
	assert_eq(ev.left, ["error"], "lobby_left(error)")
	assert_false(svc.is_in_lobby(), "not in a lobby")
	await _close()


func test_cancelled_create_is_left() -> void:
	_open()
	svc.host()
	svc.leave()
	assert_eq(ev.left, ["left"], "left while creating")
	fs.lobby_created.emit(1, LOBBY)
	assert_eq(ev.entered.size(), 0, "no enter after cancel")
	assert_eq(fs.called("leaveLobby"), [[LOBBY]], "late lobby left immediately (no ghost)")
	await _close()


func test_client_join() -> void:
	_open()
	fs.lobby_data[LOBBY] = _host_data()
	fs.lobby_owner[LOBBY] = HOST
	fs.lobby_members[LOBBY] = [HOST, fs.me]
	fs.names[HOST] = "Hosty"
	svc.join(str(LOBBY))
	assert_eq(fs.called("joinLobby"), [[LOBBY]], "joinLobby(int)")
	fs.lobby_joined.emit(LOBBY, 0, false, 1)
	assert_eq(ev.entered.size(), 1, "entered")
	assert_false(ev.entered[0].is_owner, "member")
	assert_eq(svc.transport_target(), {"kind": "steam", "role": "client", "lobby_id": str(LOBBY), "host_steam_id": str(HOST)}, "client target")
	assert_true(svc.get_members()[0].is_owner, "host flagged")
	assert_true(svc.get_members()[1].is_self, "self flagged")
	assert_eq(fs.called("setLobbyData"), [], "members never write lobby data")
	# lobby data update -> lobby_data_changed with the host state
	fs.lobby_data[LOBBY]["state"] = "starting"
	fs.lobby_data_update.emit(1, LOBBY, LOBBY)
	assert_eq(ev.data.back().state, "starting", "state follows lobby data")
	# the host leaves
	fs.lobby_chat_update.emit(LOBBY, HOST, HOST, 2)
	assert_eq(ev.left, ["host_left"], "host_left")
	assert_eq(svc.current(), {}, "cleared")
	assert_true([LOBBY] in fs.called("leaveLobby"), "left the Steam lobby too")
	await _close()


func test_owner_migration_is_host_left() -> void:
	_open()
	fs.lobby_data[LOBBY] = _host_data()
	fs.lobby_owner[LOBBY] = HOST
	fs.lobby_members[LOBBY] = [HOST, fs.me, FRIEND]
	svc.join(str(LOBBY))
	fs.lobby_joined.emit(LOBBY, 0, false, 1)
	fs.lobby_owner[LOBBY] = fs.me    # Steam handed ownership to us
	fs.lobby_data_update.emit(1, LOBBY, LOBBY)
	assert_eq(ev.left, ["host_left"], "migration counts as host left")
	await _close()


func test_join_errors() -> void:
	_open()
	svc.join(str(LOBBY))
	fs.lobby_joined.emit(LOBBY, 0, false, 4)
	assert_eq(ev.error, ["MP_ERR_FULL"], "full")
	assert_eq(ev.left, ["join_failed"], "join_failed")
	fs.lobby_data[LOBBY] = _host_data({"pitt_version": "1.0.7"})
	fs.lobby_owner[LOBBY] = HOST
	svc.join(str(LOBBY))
	fs.lobby_joined.emit(LOBBY, 0, false, 1)
	assert_eq(ev.error.back(), "MP_ERR_VERSION", "version mismatch refused")
	assert_eq(ev.left.back(), "join_failed", "join_failed")
	assert_true([LOBBY] in fs.called("leaveLobby"), "left the mismatched lobby")
	assert_eq(ev.entered.size(), 0, "never entered")
	svc.join("not-a-number")
	assert_eq(ev.left.back(), "join_failed", "bad id")
	await _close()


func test_friend_discovery() -> void:
	_open()
	var f2 := FRIEND + 1
	var f3 := FRIEND + 2
	var l2 := LOBBY + 2
	var l3 := LOBBY + 3
	fs.friends = [FRIEND, f2, f3]
	fs.names[FRIEND] = "Fred"
	fs.playing[FRIEND] = {"id": APP, "lobby": LOBBY}
	fs.playing[f2] = {"id": 999, "lobby": l2}           # another game
	fs.playing[f3] = {"id": APP, "lobby": l3}
	svc.set_scan_active(true)
	svc.refresh_friend_lobbies()
	var req: Array = fs.called("requestLobbyData")
	assert_true([LOBBY] in req and [l3] in req, "requestLobbyData for this app's lobbies")
	assert_false([l2] in req, "other games ignored")
	assert_eq(svc.friend_lobbies().size(), 0, "rows fill on lobby_data_update")
	fs.lobby_data[LOBBY] = _host_data({"host_name": "", "members": "3"})
	fs.lobby_data_update.emit(1, LOBBY, LOBBY)
	var rows: Array = svc.friend_lobbies()
	assert_eq(rows.size(), 1, "row added")
	assert_eq(rows[0].host_name, "Fred", "falls back to the friend's persona")
	assert_eq([rows[0].members, rows[0].max, rows[0].joinable], [3, 10, true], "count and joinable")
	fs.lobby_data[l3] = _host_data({"members": "10"})
	fs.lobby_data_update.emit(1, l3, l3)
	rows = svc.friend_lobbies()
	assert_eq(rows.size(), 2, "two rows")
	assert_eq(rows[1].reason, "MP_ERR_FULL", "full row disabled (sorted last)")
	# the friend stops playing: persona_state_change re-checks only that friend
	fs.playing.erase(FRIEND)
	fs.persona_state_change.emit(FRIEND, 16)
	assert_eq(svc.friend_lobbies().size(), 1, "row removed on persona change")
	# a lobby whose data request fails disappears
	fs.lobby_data_update.emit(0, l3, l3)
	assert_eq(svc.friend_lobbies().size(), 0, "failed data removes the row")
	# persona changes while the Join panel is hidden do not scan
	svc.set_scan_active(false)
	fs.playing[FRIEND] = {"id": APP, "lobby": LOBBY}
	var n: int = fs.called("requestLobbyData").size()
	fs.persona_state_change.emit(FRIEND, 16)
	assert_eq(fs.called("requestLobbyData").size(), n, "no scan while hidden")
	await _close()


func test_join_requested_and_launch_args() -> void:
	_open()
	fs.join_requested.emit(LOBBY, FRIEND)
	assert_eq(ev.join, [str(LOBBY)], "join_requested as String")
	var la = load(_mod("lobby/launch_args.gd"))
	assert_eq(la.find_connect_lobby(["game.exe", "+connect_lobby", "12345"]), "12345", "two args")
	assert_eq(la.find_connect_lobby(["+connect_lobby=777"]), "777", "joined form")
	assert_eq(la.find_connect_lobby(["+connect_lobby", "abc"]), "", "not a number")
	assert_eq(la.find_connect_lobby(["-x"]), "", "absent")
	assert_eq(la.split_command_line("+connect_lobby 109775240000000555"), ["+connect_lobby", "109775240000000555"], "split")
	fs.launch_line = "+connect_lobby 4242"
	assert_eq(la.read(fs), "4242", "Steam.getLaunchCommandLine")
	await _close()
	fs = FakeSteam.new()
	fs.launch_line = "+connect_lobby 999"
	svc = load(_mod("lobby/steam_lobby_service.gd")).new()
	svc.steam = fs
	svc.require_steamworks = false
	runner.add_child(svc)
	svc.setup(null, VERSION, {})
	assert_eq(svc.take_launch_join(), "999", "read at setup")
	assert_eq(svc.take_launch_join(), "", "once")
	await _close()


func test_signal_adapter_arity() -> void:
	var Signals = load(_mod("lobby/steam_signals.gd"))
	var got: Array = []
	var cb: Callable = Signals._adapter("x", func(sig, args): got.append([sig, args]))
	cb.call(1)
	cb.call(1, 2, 3)
	cb.call()
	assert_eq(got, [["x", [1]], ["x", [1, 2, 3]], ["x", []]], "any arity reaches the handler")
	assert_eq(Signals.arg_int([5, "7"], 1), 7, "string ids")
	assert_eq(Signals.arg_int([5], 3), 0, "missing arg")
	var fs2 = FakeSteam.new()
	var s = Signals.new()
	assert_eq(s.connect_all(fs2, func(_a, _b): pass), 6, "all six signals connected")
	s.disconnect_all()
	assert_eq(fs2.get_signal_connection_list("lobby_created").size(), 0, "disconnected")


func test_no_steam() -> void:
	svc = load(_mod("lobby/steam_lobby_service.gd")).new()
	runner.add_child(svc)
	svc.setup(null, VERSION, {})
	var errors: Array = []
	var left: Array = []
	svc.error.connect(func(c, _d): errors.append(c))
	svc.lobby_left.connect(func(r): left.append(r))
	if Engine.has_singleton("Steam"):
		assert_true(true, "Steam present in this build; skipped")
	else:
		assert_eq(svc.available(), {"ok": false, "reason": "MP_ERR_NO_STEAM"}, "unavailable")
		svc.host()
		assert_eq(errors, ["MP_ERR_NO_STEAM"], "error")
		assert_eq(left, ["error"], "lobby_left(error)")
		svc.refresh_friend_lobbies()
		assert_eq(svc.friend_lobbies(), [], "empty list")
	await _close()
