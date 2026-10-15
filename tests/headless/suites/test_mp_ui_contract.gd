extends "res://tests/test_case.gd"
## MP-DESIGN 5.3 / 5.6: every LobbyService implementation (steam, dev, fake) and
## NET's stub_lobby.gd expose every LobbyService member; UI's fake_session.gd
## matches 5.4. Drift here fails the suite.

const LOBBY_SIGNALS := ["lobby_entered", "lobby_left", "members_changed", "lobby_data_changed",
	"friend_lobbies_changed", "join_requested", "error"]
const LOBBY_METHODS := ["setup", "kind", "host", "join", "leave", "invite_friends", "refresh_friend_lobbies",
	"set_scan_active", "current", "is_in_lobby", "is_owner", "get_members", "get_local_name", "transport_target",
	"set_state", "set_external_members"]
const SESSION_SIGNALS := ["state_changed", "roster_changed", "start_availability_changed", "ended"]
const SESSION_METHODS := ["get_state", "get_role", "is_live", "get_roster", "can_start", "consume_last_end",
	"start_game", "cancel_start", "notify_host_launch", "leave"]
const NET_STUB_LOBBY := "res://tests/fakes/mp_net/stub_lobby.gd"
const NET_SESSION := "PittMultiplayer/net/session.gd"


func _mod(rel: String) -> String:
	return String(core.mods_dir).path_join("PittMultiplayer").path_join(rel)


func _script_members(s: Script) -> Dictionary:
	var methods: Dictionary = {}
	var signals: Dictionary = {}
	var cur: Script = s
	while cur != null:
		for m in cur.get_script_method_list():
			methods[String(m.name)] = m
		for sg in cur.get_script_signal_list():
			signals[String(sg.name)] = sg
		cur = cur.get_base_script()
	return {"methods": methods, "signals": signals}


func _check(s: Script, sigs: Array, meths: Array, label: String) -> void:
	if not assert_true(s != null, label + " loads"):
		return
	var mem := _script_members(s)
	for sg in sigs:
		assert_true(mem.signals.has(sg), "%s has signal %s" % [label, sg])
	for m in meths:
		assert_true(mem.methods.has(m), "%s has method %s" % [label, m])


func test_lobby_services_conform() -> void:
	for rel in ["lobby/lobby_service.gd", "lobby/steam_lobby_service.gd", "lobby/dev_lobby_service.gd",
			"lobby/fake_lobby_service.gd"]:
		_check(load(_mod(rel)), LOBBY_SIGNALS, LOBBY_METHODS, rel)


func test_signal_arities() -> void:
	var mem := _script_members(load(_mod("lobby/lobby_service.gd")))
	var want := {"lobby_entered": 1, "lobby_left": 1, "members_changed": 1, "lobby_data_changed": 1,
		"friend_lobbies_changed": 1, "join_requested": 1, "error": 2}
	for sg in want:
		assert_eq(mem.signals[sg].args.size(), want[sg], "arity of " + sg)


func test_net_stub_lobby_conforms() -> void:
	if not ResourceLoader.exists(NET_STUB_LOBBY):
		# NET stream delivers it; conformance is enforced as soon as it exists
		assert_true(true, "stub_lobby.gd not delivered yet")
		return
	_check(load(NET_STUB_LOBBY), LOBBY_SIGNALS, LOBBY_METHODS, "stub_lobby.gd")


func test_fake_session_conforms() -> void:
	_check(load("res://tests/fakes/mp_ui/fake_session.gd"), SESSION_SIGNALS, SESSION_METHODS, "fake_session.gd")
	var p := String(core.mods_dir).path_join(NET_SESSION)
	if FileAccess.file_exists(p):
		var s = load(p)
		if s != null:
			_check(s, SESSION_SIGNALS, SESSION_METHODS, "net/session.gd")


func test_factory_kinds() -> void:
	var factory = load(_mod("lobby/lobby_factory.gd"))
	for k in ["steam", "dev", "fake"]:
		var n: Node = factory.make(k)
		assert_eq(n.kind(), k, "factory kind " + k)
		assert_eq(n.current(), {}, "un-setup service has no lobby")
		assert_false(n.is_in_lobby(), "not in lobby")
		assert_eq(n.transport_target(), {}, "no target")
		n.free()


func test_model_constants() -> void:
	var m = load(_mod("lobby/lobby_model.gd"))
	assert_eq(m.MAX_MEMBERS, 10, "MAX_MEMBERS")
	assert_eq(m.APP_ID, 4026250, "APP_ID")
	assert_eq(m.MP_PROTO, 2, "MP_PROTO (MP2 D8)")
	assert_eq(m.LOBBY_STATES, ["waiting", "starting", "in_game", "ending"], "LOBBY_STATES")
	var info: Dictionary = m.lobby_info({"id": 123, "members": "3"})
	for k in ["id", "owner_id", "host_name", "members", "max", "state", "pitt_version", "pittapi_version", "mp_proto",
			"mods_hash", "joinable", "compatible", "reason", "is_owner"]:
		assert_true(info.has(k), "LobbyInfo has " + k)
	assert_eq(info.id, "123", "ids are strings")
	assert_eq(info.members, 3, "members int")
	assert_eq(JSON.parse_string(JSON.stringify(info)).id, "123", "JSON-safe")


func test_model_evaluate() -> void:
	var m = load(_mod("lobby/lobby_model.gd"))
	var v := {"pitt_version": "1.0.8", "pittapi_version": "1.1.0", "mp_proto": 1, "mods_hash": "h"}
	var ok: Dictionary = m.evaluate(m.lobby_info({"members": 2, "max": 10, "pitt_version": "1.0.8",
		"pittapi_version": "1.1.0", "mp_proto": 1, "mods_hash": "h"}), v)
	assert_true(ok.joinable and ok.compatible and ok.reason == "", "matching lobby joinable")
	var ver: Dictionary = m.evaluate(m.lobby_info({"pitt_version": "1.0.7", "pittapi_version": "1.1.0", "mp_proto": 1,
		"mods_hash": "h"}), v)
	assert_eq([ver.compatible, ver.joinable, ver.reason], [false, false, "MP_ERR_VERSION"], "version mismatch")
	var api_ver: Dictionary = m.evaluate(m.lobby_info({"pitt_version": "1.0.8", "pittapi_version": "1.0.0",
		"mp_proto": 1, "mods_hash": "h"}), v)
	assert_eq(api_ver.reason, "MP_ERR_VERSION", "pittapi mismatch")
	var mods: Dictionary = m.evaluate(m.lobby_info({"pitt_version": "1.0.8", "pittapi_version": "1.1.0", "mp_proto": 1,
		"mods_hash": "x"}), v)
	assert_eq([mods.compatible, mods.reason], [false, "MP_ERR_MODS"], "mods mismatch")
	var full: Dictionary = m.evaluate(m.lobby_info({"members": 10, "max": 10, "pitt_version": "1.0.8",
		"pittapi_version": "1.1.0", "mp_proto": 1, "mods_hash": "h"}), v)
	assert_eq([full.compatible, full.joinable, full.reason], [true, false, "MP_ERR_FULL"], "full")
	var ending: Dictionary = m.evaluate(m.lobby_info({"state": "ending", "pitt_version": "1.0.8",
		"pittapi_version": "1.1.0", "mp_proto": 1, "mods_hash": "h"}), v)
	assert_eq([ending.joinable, ending.reason], [false, "MP_ERR_ENDING"], "ending not joinable")
	var in_game: Dictionary = m.evaluate(m.lobby_info({"state": "in_game", "pitt_version": "1.0.8",
		"pittapi_version": "1.1.0", "mp_proto": 1, "mods_hash": "h"}), v)
	assert_true(in_game.joinable, "in_game stays joinable (late join)")


func test_contract_entries_format() -> void:
	var c = load(_mod("ui/contract_ui.gd"))
	assert_true(c.ENTRIES.size() > 10, "entries present")
	for e in c.ENTRIES:
		var parts: PackedStringArray = String(e).split("|")
		assert_eq(parts.size(), 4, "entry format: " + e)
		assert_has(["method", "signal", "prop", "const"], parts[2], "kind of " + e)
