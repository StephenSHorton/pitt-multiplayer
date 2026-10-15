extends RefCounted
## A per-peer stand-in for a mod's PittAPIContext, so a host and several clients
## can run in ONE headless process (PittAPI itself is a process singleton).
## commands is a REAL loader Commands instance (own registry, own authority),
## so MpAuthority, scope "local" and dispatch_remote run the production code.

const Commands = preload("res://gamedir/mods/PittAPI/core/commands.gd")
const Authority = preload("res://gamedir/mods/PittAPI/core/authority.gd")


class FakeLog extends RefCounted:
	var lines: Array = []

	func info(m: String, _d = null) -> void:
		lines.append("I " + m)

	func warn(m: String, _d = null) -> void:
		lines.append("W " + m)

	func debug(m: String, _d = null) -> void:
		pass

	func error(m: String, _d = null) -> void:
		lines.append("E " + m)


class FakeEv extends RefCounted:
	var name := ""
	var payload: Dictionary = {}
	var origin := 1
	var source := "game"


class FakeEvents extends RefCounted:
	var subs: Dictionary = {}
	var next_id := 1
	var emitted: Array = []

	func on(name: String, handler: Callable, _priority: int = 0) -> int:
		var id := next_id
		next_id += 1
		subs[id] = [name, handler]
		return id

	func off(id: int) -> bool:
		return subs.erase(id)

	func emit(name: String, payload: Dictionary = {}) -> Error:
		fire(name, payload)
		return OK

	func fire(name: String, payload: Dictionary, origin: int = 1, source: String = "game") -> void:
		var ev := FakeEv.new()
		ev.name = name
		ev.payload = payload
		ev.origin = origin
		ev.source = source
		emitted.append(ev)
		for id in subs.keys():
			if not subs.has(id):
				continue
			var s: Array = subs[id]
			if s[0] == name or s[0] == "*":
				s[1].call(ev)


class FakeNet extends RefCounted:
	var api = null
	var installs := 0
	var uninstalls := 0
	var started: Array = []
	var ended_reasons: Array = []
	var peers_changes := 0
	var players: Array = []
	var remote: Dictionary = {}       # peer -> node
	var applying := 0
	var apply_calls := 0

	func install_authority(a: Object) -> Error:
		installs += 1
		api.commands.set_authority(a)
		return OK

	func uninstall_authority() -> void:
		uninstalls += 1
		api.commands.set_authority(Authority.new())

	func emit_session_started(info: Dictionary = {}) -> void:
		started.append(info)

	func emit_session_ended(reason: String = "") -> void:
		ended_reasons.append(reason)

	func emit_peers_changed(p = null) -> void:
		peers_changes += 1
		if typeof(p) == TYPE_ARRAY:
			players = p

	func register_remote_player(node: Node, peer: int) -> int:
		remote[peer] = node
		return 1 + remote.size()

	func unregister_remote_player(peer: int) -> void:
		remote.erase(peer)

	func begin_apply(origin: int = 1) -> void:
		applying = origin
		apply_calls += 1

	func end_apply() -> void:
		applying = 0

	func is_authority() -> bool:
		return api.commands.authority == null or api.commands.authority.is_authority()


class FakeHud extends RefCounted:
	var toasts: Array = []

	func toast(text: String, _opts: Dictionary = {}) -> Object:
		toasts.append(text)
		return null


var name := ""
var commands = null
var events := FakeEvents.new()
var net := FakeNet.new()
var log := FakeLog.new()
var hud := FakeHud.new()
var game_version := "1.0.8"
var api_version := "1.1.0"
var _data_dir := ""
## records of the local-scope utility commands
var isolate_calls: Array = []
var suppress_calls := 0
var isolated := false
var isolate_path := ""


func _init(p_name: String = "peer") -> void:
	name = p_name
	commands = Commands.new(null, Authority.new())
	net.api = self
	_data_dir = "user://pittapi/test_mp/%s_%d" % [p_name, Time.get_ticks_usec()]
	# the scope-local utilities PittMultiplayer runs on clients (real ones live in builtin_commands.gd)
	commands.register("save.isolate", _save_isolate, {"scope": "local", "replicate": "none",
		"schema": {"enabled": TYPE_BOOL, "path?": TYPE_STRING}})
	commands.register("achievements.suppress", func(_a, _c):
		suppress_calls += 1
		return {"suppressed": 1}, {"scope": "local", "replicate": "none", "schema": {}})
	# stands in for a command a mod registered with remote = true (the host runs it for clients)
	commands.register("money.add", _money_add_stub, {"schema": {"amount": [TYPE_STRING, TYPE_INT]}, "remote": true})
	# an ordinary authority command: host-only, refused from clients
	commands.register("t.plain", func(_a, _c): return {"ran": true}, {"schema": {}})
	commands.register("t.cheat", func(_a, _c): return {"cheated": true}, {"cheat": true, "schema": {}})


var money_adds: Array = []
## set by tests: money.add then really adds through this (Fake)GameAdapter
var adapter = null


func _money_add_stub(args: Dictionary, ctx) -> Variant:
	money_adds.append([args.amount, ctx.origin_peer, ctx.is_remote])
	if adapter != null:
		adapter.add_money_digits(str(args.amount))
	return {"ok": true}


func _save_isolate(args: Dictionary, ctx) -> Variant:
	isolate_calls.append(args.duplicate())
	if bool(args.enabled):
		var p := String(args.get("path", ""))
		if not p.begins_with("user://pittapi/") or not p.ends_with(".save") or p.get_file().begins_with("savegame"):
			return ctx.fail("bad isolate path", "ERR_DENIED")
		isolated = true
		isolate_path = p
	else:
		isolated = false
		isolate_path = ""
	return {"enabled": isolated}


func data_dir() -> String:
	DirAccess.make_dir_recursive_absolute(_data_dir)
	return _data_dir


func path(rel: String) -> String:
	return "res://gamedir/mods/PittMultiplayer".path_join(rel)


func list_mods() -> Array:
	return [{"id": "PittMultiplayer", "version": "0.1.0", "state": "LOADED", "multiplayer": "client_required"}]


func has_method_contract() -> bool:
	return false
