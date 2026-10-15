extends "res://tests/test_case.gd"
## Interface contract 5.4 (Session) conformance: NET's net/session.gd AND the UI
## stream's double tests/fakes/mp_ui/fake_session.gd must both have every
## signal (with its arity) and method. Drift fails here and in test_mp_ui_contract.

const SESSION_PATH := "res://gamedir/mods/PittMultiplayer/net/session.gd"
const FAKE_SESSION_PATH := "res://tests/fakes/mp_ui/fake_session.gd"

const SIGNALS := {"state_changed": 2, "roster_changed": 1, "start_availability_changed": 2, "ended": 2}
const METHODS := {"get_state": 0, "get_role": 0, "is_live": 0, "get_roster": 0, "can_start": 0,
	"consume_last_end": 0, "start_game": 0, "cancel_start": 0, "notify_host_launch": 1, "leave": 1}
const STATES := ["idle", "lobby", "starting", "loading", "in_game", "ending", "closing"]
const END_REASONS := ["left", "host_left", "connection_lost", "version", "mods", "full", "kicked", "ending",
	"timeout", "protocol", "error"]


func _check(path: String, label: String) -> void:
	if not ResourceLoader.exists(path):
		fail("%s missing: %s" % [label, path])
		return
	var s: Script = load(path)
	assert_true(s != null and s.can_instantiate(), "%s compiles" % label)
	if s == null:
		return
	var sigs := {}
	for sg in s.get_script_signal_list():
		sigs[sg.name] = sg.args.size()
	for n in SIGNALS:
		assert_true(sigs.has(n), "%s: signal %s" % [label, n])
		if sigs.has(n):
			assert_eq(int(sigs[n]), int(SIGNALS[n]), "%s: %s arity" % [label, n])
	var meths := {}
	for m in s.get_script_method_list():
		meths[m.name] = m
	for n in METHODS:
		assert_true(meths.has(n), "%s: method %s" % [label, n])
		if meths.has(n):
			var m: Dictionary = meths[n]
			var max_args: int = m.args.size()
			var min_args: int = max_args - m.default_args.size()
			var want: int = METHODS[n]
			assert_true(want >= min_args and want <= max_args, "%s: %s accepts %d arg(s) (%d..%d)" % [label, n, want, min_args, max_args])


func test_session_conforms() -> void:
	_check(SESSION_PATH, "session.gd")
	var Session = load(SESSION_PATH)
	assert_eq(Session.STATES, STATES, "state names")
	assert_eq(Session.END_REASONS, END_REASONS, "ended reasons")


func test_fake_session_conforms() -> void:
	_check(FAKE_SESSION_PATH, "UI fake_session.gd")


func test_session_extension_hooks() -> void:
	var s: Script = load(SESSION_PATH)
	var meths := {}
	for m in s.get_script_method_list():
		meths[m.name] = true
	for n in ["ext_live", "ext_role", "ext_block_hole_progress", "ext_rewire_row", "ext_on_return_to_menu"]:
		assert_true(meths.has(n), "hook %s used by the NET extensions" % n)


func test_main_composition() -> void:
	var node = core.loader.mods["PittMultiplayer"].node
	assert_true(node != null, "mod node")
	if node == null:
		return
	assert_true(node.session != null and node.session.get_parent() == node, "Session under the mod node")
	assert_eq(node.session.process_mode, Node.PROCESS_MODE_ALWAYS, "PROCESS_MODE_ALWAYS")
	assert_eq(node.version.mp_proto, 2, "VersionInfo.mp_proto (MP2 D8)")
	assert_eq(String(node.version.pittapi_version), String(core.api_version), "pittapi_version")
	assert_eq(String(node.version.mods_hash).length(), 16, "mods_hash is 16 hex chars")
	assert_eq(node.compute_mods_hash([{"id": "B", "version": "1.0.0", "state": "LOADED", "multiplayer": "client_required"},
		{"id": "A", "version": "2.0.0", "state": "LOADED", "multiplayer": "client_required"},
		{"id": "C", "version": "1.0.0", "state": "LOADED", "multiplayer": "local_only"}]),
		node.compute_mods_hash([{"id": "A", "version": "2.0.0", "state": "LOADED", "multiplayer": "client_required"},
		{"id": "B", "version": "1.0.0", "state": "LOADED", "multiplayer": "client_required"}]),
		"order-independent, only client_required mods count")
	if node.lobby != null:
		assert_true(node.lobby.has_method("transport_target"), "lobby service wired")
