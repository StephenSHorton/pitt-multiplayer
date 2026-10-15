extends Node
## PittMultiplayer composition root (MP-DESIGN 5.5).
##   version  -> LobbyService (Steam | Dev) -> Session (+ GameAdapter) -> UI
## Network nodes live under /root/PittAPI/Mods/PittMultiplayer with
## PROCESS_MODE_ALWAYS and survive scene changes. Extensions reach the Session
## through Engine meta "pitt_mp". Tolerates a missing UI stream (headless/dev):
## the Session still works and can be driven by PittMPTests.
## MP2 (MP2-DESIGN 2.6, 10.1): the BODIES / GAMEPLAY / GRAB modules are
## registered with the Session before it goes live, in that order. A missing
## module file disables the shared world (logged; the MP1 path still works).

const Session = preload("net/session.gd")
const GameAdapter = preload("game/game_adapter.gd")
const ContractNet = preload("net/contract_net.gd")
const ContractBodies = preload("world/bodies/contract_bodies.gd")
const SaveGuard = preload("world/save_guard.gd")
const MP_PROTO := 2
const META := "pitt_mp"
## module files in registration order (10.1)
const MODULES := ["world/bodies/bodies.gd", "gameplay/gameplay.gd", "grab/grab.gd"]
## stream contracts besides NET and BODIES (10.7)
const MODULE_CONTRACTS := ["gameplay/contract_gameplay.gd", "grab/contract_grab.gd", "ui/contract_ui.gd"]

var api = null
var session: Node = null
var lobby: Node = null
var adapter = null
var ui: Node = null
var version: Dictionary = {}
var mp_ok := true
var mp_reason := ""
var contract_report: Dictionary = {}
var cfg: Dictionary = {}
var modules: Array = []
var mp2_ok := false
var mp2_reason := ""


func _init() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _mod_init(p_api) -> void:
	api = p_api
	_define_config()
	cfg = _read_config()
	version = {"pitt_version": String(api.game_version), "pittapi_version": String(api.api_version),
		"mp_proto": MP_PROTO, "mods_hash": compute_mods_hash(api.list_mods())}
	_check_contract()
	var removed := SaveGuard.cleanup_orphans(api.data_dir())
	if removed > 0:
		api.log.info("removed %d orphaned session file(s)" % removed)
	adapter = GameAdapter.new()
	adapter.setup(api)
	var kind := "steam" if String(cfg.transport) == "steam" else "dev"
	lobby = _make_lobby(kind)
	if lobby != null:
		add_child(lobby)
		lobby.setup(api, version, cfg)
	var scfg := cfg.duplicate()
	scfg["version"] = version
	scfg["block_start"] = not mp_ok
	session = Session.new(api, lobby, adapter, scfg)
	add_child(session)
	_register_modules()
	Engine.set_meta(META, session)
	if lobby != null and lobby.has_method("kind") and String(lobby.kind()) != "steam":
		session.roster_changed.connect(func(_r):
			if is_instance_valid(lobby) and lobby.has_method("set_external_members"):
				lobby.set_external_members(session.roster.to_members(session.my_peer)))
	for sp in ["ui/strings.gd", "mp2/strings_mp2.gd"]:
		var strings_path: String = api.path(sp)
		if FileAccess.file_exists(strings_path):
			var strings = load(strings_path)
			if strings != null and strings.has_method("register"):
				strings.register()
	var ui_path: String = api.path("ui/mp_ui.gd")
	if FileAccess.file_exists(ui_path) and lobby != null:
		var s = load(ui_path)
		if s != null and s.can_instantiate():
			ui = s.new()
			ui.name = "MpUI"
			add_child(ui)
			if ui.has_method("setup"):
				ui.setup(api, lobby, session)
	api.console.register("mp", _console, "mp [status|dump|stats|leave]: multiplayer session state")
	api.log.info("PittMultiplayer ready (transport %s, mods_hash %s, shared world %s%s)" % [cfg.transport,
		version.mods_hash, "on" if mp2_ok else "OFF (%s)" % mp2_reason, "" if mp_ok else ", DISABLED: " + mp_reason])


## MP2: BODIES, GAMEPLAY, GRAB in that order. All three or none: a partial set
## would run a shared world without its gates (P3).
func _register_modules() -> void:
	var made: Array = []
	for rel in MODULES:
		var p: String = api.path(rel)
		if not FileAccess.file_exists(p):
			mp2_reason = "%s missing" % rel
			break
		var s = load(p)
		if s == null or not s.can_instantiate():
			mp2_reason = "%s does not compile" % rel
			break
		var m = s.new(api) if rel == MODULES[0] else s.new()
		if m == null or not m.has_method("mod_name"):
			mp2_reason = "%s is not a module" % rel
			break
		made.append(m)
	if made.size() != MODULES.size():
		api.log.warn("MP2 shared world disabled: %s (multiplayer runs the MP1 path)" % mp2_reason)
		for m in made:
			if m is Node:
				m.free()
		return
	for m in made:
		if m is Node:
			add_child(m)
		session.register_module(m)
	modules = made
	mp2_ok = true
	mp2_reason = ""


func _exit_tree() -> void:
	if Engine.has_meta(META) and Engine.get_meta(META) == session:
		Engine.remove_meta(META)


## For PittMPTests and other mods: api.get_mod_api("PittMultiplayer").
func get_public_api() -> Object:
	return self


func _define_config() -> void:
	var c = api.config
	c.define("transport", "steam", {"options": ["steam", "enet"],
		"description": "steam = real play; enet = localhost dev/tests (one Steam account cannot P2P to itself)"})
	c.define("dev_address", "127.0.0.1", {"description": "ENet host/connect address (dev lobby)"})
	c.define("dev_port", 27450, {"min": 1024, "max": 65535})
	c.define("dev_targets", "", {"description": "comma-separated address:port rows of the dev Join list"})
	c.define("dev_name", "", {"description": "player name in the dev lobby"})
	c.define("physics_detail", "normal", {"options": ["low", "normal", "high"],
		"description": "host: body-state budget per client (24 / 48 / 96 KB/s), MP2 D21"})
	c.define("achievements", "presence", {"options": ["presence", "none", "all"],
		"description": "presence: nothing for progress loaded on join, only crossings while connected (D4)"})
	c.define("allow_remote_cheats", false, {"description": "host accepts cheat commands from clients"})
	c.define("steam_peer_mode", "socket", {"options": ["socket", "lobby"],
		"description": "SteamMultiplayerPeer: create_host/create_client (socket) or host_with_lobby/connect_to_lobby"})
	c.define("rate_limits", true)
	c.define("dev_lane_cap", 0, {"min": 0, "max": 16,
		"description": "ENet tests only: emulate GodotSteam's lane limit (4 = the bundled 4.19.1 with max_channels=4); 0 = off"})


func _read_config() -> Dictionary:
	var c = api.config
	var out := {}
	for k in ["transport", "dev_address", "dev_port", "dev_targets", "dev_name", "physics_detail", "achievements",
			"allow_remote_cheats", "steam_peer_mode", "rate_limits", "dev_lane_cap"]:
		out[k] = c.get_value(k)
	out["data_dir"] = api.data_dir()
	return out


## sha256("id@version" of the sorted client_required mods).substr(0, 16)
static func compute_mods_hash(mods: Array) -> String:
	var ids: Array = []
	for m in mods:
		if typeof(m) != TYPE_DICTIONARY:
			continue
		if String(m.get("multiplayer", "")) != "client_required":
			continue
		var st := String(m.get("state", ""))
		if st != "LOADED" and st != "INITIALIZING":
			continue
		ids.append("%s@%s" % [m.get("id", ""), m.get("version", "")])
	ids.sort()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update("\n".join(ids).to_utf8_buffer())
	return ctx.finish().hex_encode().substr(0, 16)


func _check_contract() -> void:
	var entries: Array = ContractNet.ENTRIES.duplicate()
	entries.append_array(ContractBodies.ENTRIES)
	for rel in MODULE_CONTRACTS:
		var path: String = api.path(rel)
		if not FileAccess.file_exists(path):
			continue
		var s = load(path)
		if s != null:
			var m: Dictionary = s.get_script_constant_map()
			if m.has("ENTRIES"):
				entries.append_array(m.ENTRIES)
	if not api.has_method("contract_check"):
		mp_ok = false
		mp_reason = "PittAPI has no contract_check (needs 1.1)"
		return
	contract_report = api.contract_check(entries)
	mp_ok = bool(contract_report.get("ok", false))
	if not mp_ok:
		mp_reason = "MP_ERR_INCOMPATIBLE_BUILD"
		api.log.warn("multiplayer disabled: game members missing", contract_report.get("missing", []))


func _make_lobby(kind: String) -> Node:
	var path: String = api.path("lobby/lobby_factory.gd")
	if not FileAccess.file_exists(path):
		api.log.warn("lobby/lobby_factory.gd missing: multiplayer has no lobby service")
		return null
	var f = load(path)
	if f == null:
		return null
	return f.make(kind)


func _console(args: PackedStringArray) -> String:
	var what := String(args[0]) if not args.is_empty() else "status"
	match what:
		"dump":
			return JSON.stringify(session.dump(), "  ")
		"stats":
			var b = session.get_module("bodies")
			return JSON.stringify({"net": session.net_stats(), "counters": session.counters_all(),
				"bodies": b.host.stats() if b != null and b.host != null else {}}, "  ")
		"leave":
			session.leave()
			return "left"
	return "state=%s role=%s host_state=%s peers=%d mp_ok=%s %s" % [session.get_state(), session.get_role(),
		session.host_state, session.get_roster().size(), mp_ok, mp_reason]
