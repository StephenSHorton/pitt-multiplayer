extends Node
## PittAPI: mod loader and modding API for Project P.I.T.T.
## Installed as an autoload through override.cfg:
##   [autoload]
##   PittAPI="*<game>/mods/PittAPI/pittapi.gd"
## Runs after the game's 20 autoloads and before the splash screen.
##
## Boot:
##   _init  : log, ErrorGuard, settings, discover + resolve manifests, compile,
##            apply script extensions (before main_menu.tscn is loaded).
##   _ready : contract check, services + facades, instantiate mods and call
##            _mod_init(api), connect the game bridge, emit game.boot_complete.
## See docs/API-DESIGN.md.

const VERSION := "1.2.0"
const CORE_ID := "PittAPI"

const Log = preload("core/log.gd")
const ErrorGuard = preload("core/error_guard.gd")
const Semver = preload("core/semver.gd")
const ModLoader = preload("core/mod_loader.gd")
const ModContext = preload("core/mod_context.gd")
const Extensions = preload("core/extensions.gd")
const Contract = preload("core/contract.gd")
const Serial = preload("core/serial.gd")
const Events = preload("core/events.gd")
const Commands = preload("core/commands.gd")
const Authority = preload("core/authority.gd")
const BuiltinCommands = preload("core/builtin_commands.gd")
const GameBridge = preload("core/game_bridge.gd")
const Entities = preload("core/entities.gd")
const SafeFS = preload("core/safe_fs.gd")
const StateApi = preload("api/state.gd")
const SpawnApi = preload("api/spawn.gd")
const PlayerApi = preload("api/player.gd")
const HudApi = preload("api/hud.gd")
const InputApi = preload("api/input.gd")
const ConfigApi = preload("api/config.gd")
const SavesApi = preload("api/saves.gd")
const ConsoleApi = preload("api/console.gd")
const NetApi = preload("api/net.gd")
const ToastLayer = preload("ui/toast_layer.gd")
const ConsolePanel = preload("ui/console_panel.gd")

const DEFAULT_SETTINGS := {
	"log_level": "info",
	"dev_console": false,
	"console_key": KEY_QUOTELEFT,
	"cheats_allowed": true,
	"quarantine_threshold": 50,
	"quarantine_window_s": 10.0,
	"strict_game_version": false,
	# P10: false restores the host pool reconciler's full diff every physics frame
	"entity_reconcile_gate": true,
}

var api_version := VERSION
var game_version := ""
var opts: Dictionary = {}
var mods_dir := ""
var user_root := "user://pittapi"
var test_armed := false
var booted := false
var boot_ms := 0

# core services
var log_sink = null
var log = null
var guard = null
var contract = null
var loader = null
var extensions = null
var authority = null
var events = null
var commands = null
var entities = null
var bridge = null
var builtins = null
var safe_fs = null
var sidecar = null
var input_registry = null
var console_registry = null
var toast_layer = null
var console_panel = null
var mods_root: Node = null

# unbound facades (global PittAPI.* access; mods should prefer their api handle)
var state = null
var spawn = null
var player = null
var hud = null
var input = null
var config = null
var saves = null
var console = null
var net = null
var extensions_view = null

# session flags
var achievements_suppressed := false
var save_isolation := false
var save_isolation_path := ""
var _isolation_prev: Dictionary = {}   # active_save_path, save_locked, autosave_enabled before isolation
var presence_suppressed := false
# multiplayer (L2/L3): the mod whose manifest "provides" ["net"], the session
# info and roster it published, and the peer whose replicated state is being
# applied (events emitted meanwhile carry origin=peer, source="net")
var net_provider := ""
var net_session_info: Dictionary = {}
var net_players: Array = []
var _net_apply_origin := 0
var instance_name := ""
## A cheat ran since the last world exit / save load (stamped on the next save).
var _cheat_used := false
var _cheat_toast_shown := false
var _settings := ConfigFile.new()
var _settings_path := ""
var _configs: Dictionary = {}
var _movement_locks: Dictionary = {}
var _movement_meta_set := false
var _logger_installed := false


func _init(p_opts: Dictionary = {}) -> void:
	opts = p_opts
	process_mode = Node.PROCESS_MODE_ALWAYS
	if opts.has("name"):
		name = String(opts.name)
	var t0 := Time.get_ticks_msec()
	_boot_init()
	boot_ms = Time.get_ticks_msec() - t0


# ======================================================================= boot

func _boot_init() -> void:
	instance_name = "" if opts.has("user_root") else _instance_arg()
	var default_root := "user://pittapi"
	if instance_name != "":
		# two decomp editor instances share one custom user dir (dev/test only)
		default_root = "user://pittapi-%s" % instance_name
	user_root = String(opts.get("user_root", default_root)).trim_suffix("/")
	DirAccess.make_dir_recursive_absolute(user_root)
	safe_fs = SafeFS.new(user_root)
	log_sink = Log.make_sink(user_root.path_join("pittapi.log"))
	log_sink.echo = bool(opts.get("echo", true))
	log = Log.new(log_sink, CORE_ID)
	_load_settings()
	log_sink.set_level_name(String(setting("log_level")))
	mods_dir = _resolve_mods_dir()
	game_version = String(ProjectSettings.get_setting("application/config/version", ""))
	log.info("PittAPI %s booting (game %s, Godot %s)" % [VERSION, game_version, Engine.get_version_info().string],
		{"mods_dir": mods_dir, "user_dir": ProjectSettings.globalize_path(user_root)})

	guard = ErrorGuard.new(mods_dir)
	guard.register_mod(CORE_ID)
	if bool(opts.get("install_logger", true)):
		OS.add_logger(guard)
		_logger_installed = true

	extensions = Extensions.new(log)
	extensions.build_blocked([String(get_script().resource_path)])
	extensions_view = Extensions.View.new(extensions)

	loader = ModLoader.new(self)
	test_armed = bool(opts.get("include_underscore", false)) or FileAccess.file_exists(user_root.path_join("autotest.flag"))
	loader.discover(mods_dir, test_armed, _mods_cfg_enabled())
	for id in loader.mods:
		guard.register_mod(String(id).get_slice("@", 0))
	loader.resolve(VERSION, game_version, bool(setting("strict_game_version")))
	_resolve_providers()
	if bool(opts.get("compile", true)):
		loader.compile_and_apply(extensions)
	write_status()


func _ready() -> void:
	extensions.augment_from_nodes(get_tree().root)
	contract = Contract.new(opts.get("extra_contract", []))
	contract.check_autoloads(g)
	var disabled: Array = contract.disabled_features()
	if not disabled.is_empty():
		log.warn("game contract: features disabled: %s" % ", ".join(disabled), contract.missing())

	authority = Authority.new()
	events = Events.new(self)
	commands = Commands.new(self, authority)
	entities = Entities.new(self)
	bridge = GameBridge.new(self)
	sidecar = SavesApi.Sidecar.new(self, user_root.path_join("saves"))
	input_registry = InputApi.Registry.new(self, user_root.path_join("keybinds.cfg"))
	console_registry = ConsoleApi.Registry.new(self)
	builtins = BuiltinCommands.new(self)
	builtins.register_all(commands)

	state = StateApi.new(self, CORE_ID)
	spawn = SpawnApi.new(self, CORE_ID)
	player = PlayerApi.new(self, CORE_ID)
	hud = HudApi.new(self, CORE_ID)
	input = InputApi.new(self, CORE_ID)
	config = _config_for(CORE_ID)
	saves = SavesApi.new(self, CORE_ID)
	console = ConsoleApi.new(self, CORE_ID)
	net = NetApi.new(self, CORE_ID)

	toast_layer = ToastLayer.new()
	add_child(toast_layer)
	if bool(setting("dev_console")):
		console_panel = ConsolePanel.new()
		console_panel.registry = console_registry
		console_panel.core = self
		toast_layer.add_child(console_panel)
		events.emitted.connect(console_panel.on_event)

	mods_root = Node.new()
	mods_root.name = "Mods"
	mods_root.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(mods_root)

	var sm = g("SaveManager")
	if sm != null and feature_ok("saves"):
		sidecar.set_active(String(sm.active_save_path).get_file().get_basename())
	sidecar.cleanup_orphans()

	loader.init_mods(mods_root)
	_process_errors()
	bridge.connect_all()
	var im = g("InputManager")
	if im != null and feature_ok("input"):
		bridge._conn(im, "bindings_changed", input_registry.reassert)

	booted = true
	write_status()
	var mods_summary: Array = []
	for s in loader.status():
		mods_summary.append({"id": s.id, "version": s.version, "state": s.state, "multiplayer": s.multiplayer})
	events.emit_internal("game.boot_complete", {"api_version": VERSION, "game_version": game_version,
		"mods": mods_summary, "disabled_features": contract.disabled_features()}, "api")
	log.info("boot complete: %d mod(s) loaded" % _count_state(ModLoader.LOADED),
		{"init_ms": boot_ms, "disabled_features": contract.disabled_features()})


func _exit_tree() -> void:
	booted = false
	if bridge != null:
		bridge.disconnect_all()
	for c in _configs.values():
		c.flush()
	if _logger_installed:
		OS.remove_logger(guard)
		_logger_installed = false
	if log_sink != null:
		log_sink.close()


# ======================================================================= per frame

func _process(delta: float) -> void:
	if not booted:
		return
	_process_errors()
	bridge.process(delta)
	for c in _configs.values():
		c.tick()
	enforce_save_isolation()


func _physics_process(delta: float) -> void:
	if not booted:
		return
	entities.reconcile(delta)
	bridge.physics_process(delta)
	enforce_save_isolation()
	if not _movement_locks.is_empty():
		_apply_movement_lock()


func _input(event: InputEvent) -> void:
	if not booted:
		return
	if console_panel != null and event is InputEventKey and event.pressed and not event.echo \
			and event.physical_keycode == int(setting("console_key")):
		console_panel.toggle()
		get_viewport().set_input_as_handled()
		return
	if console_panel != null and console_panel.visible:
		return
	input_registry.handle_event(event)


func _process_errors() -> void:
	if guard == null:
		return
	var threshold := int(setting("quarantine_threshold"))
	var window := float(setting("quarantine_window_s"))
	for e in guard.drain():
		var who: String = e.mod if e.mod != "" else "game"
		if e.counted:
			log_sink.write(3, who, "%s (%s:%d)" % [e.msg, e.file, e.line], null)
		if e.mod != "" and e.mod != CORE_ID and e.counted and loader != null:
			loader.on_mod_error(e.mod, e, threshold, window)


# ======================================================================= services used by modules

## Autoload lookup by name (never a bare global, so a renamed autoload cannot
## break compilation of the loader).
func g(autoload_name: String) -> Object:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(NodePath(autoload_name))


func feature_ok(feature: String) -> bool:
	return contract == null or contract.is_available(feature)


func contract_check_node(node: Object) -> void:
	if contract == null:
		return
	var before: Array = contract.disabled_features()
	contract.check_node(node)
	var after: Array = contract.disabled_features()
	if after.size() != before.size():
		log.warn("game contract: features disabled: %s" % ", ".join(after), contract.missing())
		write_status()


## The single guarded entry point into mod code. Quarantined/failed mods are
## never called. A runtime error aborts only the callee, which returns null.
func guard_call(owner: String, callable: Callable, args: Array = []) -> Variant:
	if owner != "" and owner != CORE_ID and loader != null and loader.mods.has(owner) and not loader.is_active(owner):
		return null
	if not callable.is_valid():
		return null
	guard.push_scope(owner)
	var r = callable.callv(args)
	guard.pop_scope()
	return r


func setting(key: String, default: Variant = null) -> Variant:
	var ov: Dictionary = opts.get("settings", {})
	if ov.has(key):
		return ov[key]
	return _settings.get_value("pittapi", key, DEFAULT_SETTINGS.get(key, default))


func user_path(rel: String) -> String:
	return user_root.path_join(rel)


func make_context(rec: Dictionary) -> RefCounted:
	var id: String = rec.id
	var ctx := ModContext.new(self, id, rec.dir, rec.version)
	ctx.api_version = VERSION
	ctx.game_version = game_version
	ctx.log = log.child(id)
	ctx.config = _config_for(id)
	ctx.events = Events.Bound.new(events, id)
	ctx.commands = Commands.Bound.new(commands, id)
	ctx.entities = Entities.View.new(entities, id)
	ctx.state = StateApi.new(self, id)
	ctx.spawn = SpawnApi.new(self, id)
	ctx.player = PlayerApi.new(self, id)
	ctx.hud = HudApi.new(self, id)
	ctx.input = InputApi.new(self, id)
	ctx.saves = SavesApi.new(self, id)
	ctx.console = ConsoleApi.new(self, id)
	ctx.net = NetApi.new(self, id)
	ctx.extensions = extensions_view
	return ctx


func _config_for(mod_id: String) -> RefCounted:
	if not _configs.has(mod_id):
		# the global settings live in config/pittapi.cfg; Windows paths are case-insensitive
		var file := "_core" if mod_id == CORE_ID else mod_id
		_configs[mod_id] = ConfigApi.new(self, mod_id, user_root.path_join("config/%s.cfg" % file))
	return _configs[mod_id]


## Extension scripts call this (thin hooks): emits mod.<mod_id>.<hook>.
func ext_hook(mod_id: String, hook: String, payload: Dictionary = {}) -> void:
	if not booted or loader == null or not loader.is_active(mod_id):
		return
	events.emit_internal("mod.%s.%s" % [mod_id, hook], payload, "mod:%s" % mod_id)


## Replaces the command authority (future SteamAuthority).
func _set_authority(a: Object) -> void:
	if a == null:
		return
	authority = a
	commands.set_authority(a)
	events.emit_internal("net.authority_changed", {"kind": a.get_kind(), "is_authority": a.is_authority(),
		"local_peer_id": a.local_peer_id()}, "api")


# ======================================================================= multiplayer provider (L2, L3)

const AUTHORITY_METHODS := ["get_kind", "is_authority", "local_peer_id", "get_peers", "is_multiplayer",
	"submit", "complete"]


## Only one active mod may declare "provides": ["net"]; later ones FAIL.
func _resolve_providers() -> void:
	net_provider = ""
	for id in loader.order:
		var rec: Dictionary = loader.mods[id]
		if rec.state != ModLoader.PENDING:
			continue
		if not ("net" in rec.manifest.get("provides", [])):
			continue
		if net_provider == "":
			net_provider = id
		else:
			loader.fail(id, "only one mod may provide 'net' (already provided by %s)" % net_provider)


func is_net_provider(mod_id: String) -> bool:
	return mod_id != "" and mod_id == net_provider and loader != null and loader.is_active(mod_id)


## Validates a duck-typed authority and installs it (api.net.install_authority).
func net_install_authority(a: Object) -> Error:
	if a == null:
		return ERR_INVALID_PARAMETER
	for m in AUTHORITY_METHODS:
		if not a.has_method(m):
			log.warn("install_authority: the authority has no %s()" % m)
			return ERR_INVALID_PARAMETER
	if not ("commands" in a) or not a.has_signal("peers_changed"):
		log.warn("install_authority: the authority needs a 'commands' property and a peers_changed signal")
		return ERR_INVALID_PARAMETER
	if authority != null and authority.has_signal("peers_changed") and authority.peers_changed.is_connected(_on_authority_peers_changed):
		authority.peers_changed.disconnect(_on_authority_peers_changed)
	_set_authority(a)
	a.peers_changed.connect(_on_authority_peers_changed)
	return OK


## Back to the single-player LocalAuthority.
func net_uninstall_authority() -> void:
	if authority != null and authority.has_signal("peers_changed") and authority.peers_changed.is_connected(_on_authority_peers_changed):
		authority.peers_changed.disconnect(_on_authority_peers_changed)
	_net_apply_origin = 0
	if authority != null and authority.get_kind() == "local":
		return
	_set_authority(Authority.new())


func _on_authority_peers_changed() -> void:
	net_emit_peers_changed()


func net_emit_session_started(info: Dictionary) -> void:
	net_session_info = info.duplicate(true)
	_net_fanout("session_started")
	events.emit_internal("net.session_started", info, "api")


func net_emit_session_ended(reason: String) -> void:
	net_session_info = {}
	net_players = []
	_net_fanout("session_ended")
	events.emit_internal("net.session_ended", {"reason": reason}, "api")


## players: [{peer, slot, name, platform_id, state, is_host}] (optional update).
func net_emit_peers_changed(players: Variant = null) -> void:
	if typeof(players) == TYPE_ARRAY:
		net_players = Serial.to_json_safe(players)
	_net_fanout("peers_changed")
	events.emit_internal("net.peers_changed", {"players": net_players.duplicate(true)}, "api")


func _net_fanout(sig: String) -> void:
	if net != null:
		net.emit_signal(sig)
	if loader == null:
		return
	for c in _contexts_all():
		if c.net != null:
			c.net.emit_signal(sig)


## L3: events emitted between begin and end carry origin=peer, source="net".
func net_begin_apply(origin_peer: int) -> void:
	_net_apply_origin = maxi(origin_peer, 1)


func net_end_apply() -> void:
	if bridge != null and _net_apply_origin > 0:
		bridge.flush_for_apply()
	_net_apply_origin = 0


## L4: checks entries ("feature|target|kind|member") with the core checker.
## Autoload targets are checked on the live autoloads; res:// script targets by
## script introspection (no instance needed). -> {ok, missing, features_off}
func contract_check_entries(entries: Array) -> Dictionary:
	var c = Contract.new(entries, false)
	c.check_autoloads(g)
	c.check_script_targets()
	var missing: Array = []
	var m: Dictionary = c.missing()
	for f in m:
		for label in m[f]:
			missing.append("%s: %s" % [f, label])
	return {"ok": c.disabled_features().is_empty(), "missing": missing, "features_off": c.disabled_features()}


## --pittapi-instance=<name> (editor builds only): separate user root for a
## second dev instance. "" when absent or invalid.
func _instance_arg() -> String:
	if not OS.has_feature("editor"):
		return ""
	var args: Array = []
	args.append_array(OS.get_cmdline_user_args())
	args.append_array(OS.get_cmdline_args())
	var re := RegEx.new()
	re.compile("^[A-Za-z0-9_-]{1,32}$")
	for a in args:
		var s := String(a)
		if s.begins_with("--pittapi-instance="):
			var v := s.trim_prefix("--pittapi-instance=")
			if re.search(v) != null:
				return v
	return ""


# ======================================================================= callbacks from loader / bridge

func on_mod_quarantined(id: String, reason: String) -> void:
	var rec: Dictionary = loader.mods[id]
	if events != null:
		events.off_owner(id)
	if commands != null:
		commands.unregister_owner(id)
	if input_registry != null:
		input_registry.remove_owner(id)
	if console_registry != null:
		console_registry.remove_owner(id)
	if toast_layer != null:
		toast_layer.remove_owner(id)
	set_movement_lock(id, false)
	var node = rec.node
	if node != null and is_instance_valid(node):
		node.process_mode = Node.PROCESS_MODE_DISABLED
		node.set_process_input(false)
		node.set_process_unhandled_input(false)
	if not extensions.by_mod(id).is_empty():
		log.warn("%s: its script extensions stay active until restart (take_over_path cannot be undone)" % id)
	_set_mod_enabled_cfg(id, false)
	write_status()
	if toast_layer != null:
		toast_layer.toast("Mod %s was disabled: %s" % [id, reason], {"color": Color(1, 0.45, 0.35), "duration": 6.0})
	if events != null:
		events.emit_internal("mods.quarantined", {"id": id, "reason": reason}, "api")


func on_world_ready() -> void:
	var sm = g("SaveManager")
	var key := String(sm.active_save_path).get_file().get_basename() if sm != null and feature_ok("saves") else ""
	if not bridge._loaded_since_scene:
		# fresh run: old <mod>.json / _pittapi.json for this key are replaced on the
		# first save (SaveManager.clear_sandbox_slot / delete_slot may have run mid-session)
		sidecar.reset_key(key)
		for c in _contexts_all():
			c.saves.mod_data_loaded.emit()
	sidecar.cleanup_orphans()


func on_world_exited() -> void:
	entities.clear_all()
	_cheat_used = false
	for c in _configs.values():
		c.flush()


func on_save_loaded(key: String) -> void:
	_cheat_used = false
	sidecar.load_key(key)
	sidecar.cleanup_orphans()
	for c in _contexts_all():
		c.saves.mod_data_loaded.emit()


func on_save_saved(key: String) -> void:
	if _cheat_used:
		sidecar.mark_cheated()
	sidecar.flush(key)


func on_cheat_used() -> void:
	_cheat_used = true
	var key: String = sidecar.active_key
	var real_slot := key.begins_with("savegame") or key == "sandbox"
	if real_slot:
		sidecar.mark_cheated()
		if not _cheat_toast_shown and toast_layer != null:
			_cheat_toast_shown = true
			toast_layer.toast("Cheat command used: this save's mod data is marked as cheated.", {"color": Color(1, 0.8, 0.3), "duration": 5.0})


## Turns save isolation on or off. On: remembers the previous active_save_path,
## save_locked and autosave_enabled, then points SaveManager at a non-slot path
## under user://pittapi/ (re-asserted every frame, because the ending's
## SaveManager.save_game(true) ignores save_locked and main_menu.set_active_slot
## resets the path). Off: restores what was there before.
## Not covered: GameProgression's ending writes profile.cfg (mark_game_completed)
## directly, so phase.set refuses phase 5 while isolation is on.
func set_save_isolation(enabled: bool, path: String) -> void:
	var sm = g("SaveManager")
	if sm == null:
		return
	if enabled:
		if not save_isolation:
			_isolation_prev = {"active_save_path": String(sm.active_save_path),
				"save_locked": bool(sm.save_locked), "autosave_enabled": bool(sm.autosave_enabled)}
		save_isolation_path = path
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		save_isolation = true
		enforce_save_isolation()
	elif save_isolation:
		save_isolation = false
		save_isolation_path = ""
		if not _isolation_prev.is_empty():
			sm.set_active_save_path(String(_isolation_prev.active_save_path))
			sm.save_locked = bool(_isolation_prev.save_locked)
			sm.autosave_enabled = bool(_isolation_prev.autosave_enabled)
			if sidecar != null:
				sidecar.set_active(String(_isolation_prev.active_save_path).get_file().get_basename())
		_isolation_prev = {}


## Re-asserted every frame while save isolation is on (the elevator's _ready
## clears save_locked, MenuManager re-applies autosave from settings,
## main_menu.set_active_slot resets the path).
func enforce_save_isolation() -> void:
	if presence_suppressed:
		var st = g("Steamworks")
		if st != null and "_presence_accum" in st:
			st._presence_accum = -1.0e9
	if not save_isolation:
		return
	var sm = g("SaveManager")
	if sm == null:
		return
	sm.save_locked = true
	sm.autosave_enabled = false
	if save_isolation_path != "" and String(sm.active_save_path) != save_isolation_path:
		sm.set_active_save_path(save_isolation_path)


func set_movement_lock(owner: String, locked: bool) -> void:
	if locked:
		_movement_locks[owner] = true
	else:
		_movement_locks.erase(owner)
	_apply_movement_lock()


func _apply_movement_lock() -> void:
	var p = bridge.get_player() if bridge != null else null
	if p == null:
		return
	if not _movement_locks.is_empty():
		if not p.has_meta("golf_aim_mode"):
			p.set_meta("golf_aim_mode", true)
			_movement_meta_set = true
	elif _movement_meta_set:
		_movement_meta_set = false
		if p.has_meta("golf_aim_mode"):
			p.remove_meta("golf_aim_mode")


func _contexts_all() -> Array:
	var out: Array = []
	for id in loader.mods:
		var c = loader.mods[id].ctx
		if c != null and loader.is_active(id):
			out.append(c)
	return out


# ======================================================================= status / settings

func write_status() -> void:
	if loader == null or safe_fs == null:
		return
	var data := {
		"api_version": VERSION,
		"game_version": game_version,
		"godot_version": Engine.get_version_info().string,
		"booted": booted,
		"test_armed": test_armed,
		"mods_dir": mods_dir,
		"time": Time.get_datetime_string_from_system(),
		"mods": loader.status(),
		"contract": contract.report() if contract != null else {},
		"extensions": extensions.list(),
		"blocked_autoloads": extensions.blocked_autoload_names,
		"logger_installed": _logger_installed,
		"net_provider": net_provider,
		"instance": instance_name,
		"user_dir": ProjectSettings.globalize_path(user_root),
	}
	safe_fs.write_json(user_root.path_join("status.json"), data)


func _load_settings() -> void:
	_settings_path = user_root.path_join("config/pittapi.cfg")
	if FileAccess.file_exists(_settings_path):
		_settings.load(_settings_path)
	var changed := false
	for k in DEFAULT_SETTINGS:
		if not _settings.has_section_key("pittapi", k):
			_settings.set_value("pittapi", k, DEFAULT_SETTINGS[k])
			changed = true
	if changed:
		safe_fs.save_config(_settings, _settings_path)


func _mods_cfg_enabled() -> Dictionary:
	var out := {}
	var cfg := ConfigFile.new()
	var p := user_root.path_join("mods.cfg")
	if FileAccess.file_exists(p) and cfg.load(p) == OK and cfg.has_section("enabled"):
		for k in cfg.get_section_keys("enabled"):
			out[k] = bool(cfg.get_value("enabled", k, true))
	return out


func _set_mod_enabled_cfg(id: String, enabled: bool) -> void:
	var cfg := ConfigFile.new()
	var p := user_root.path_join("mods.cfg")
	if FileAccess.file_exists(p):
		cfg.load(p)
	cfg.set_value("enabled", id, enabled)
	safe_fs.save_config(cfg, p)


func _resolve_mods_dir() -> String:
	if opts.has("mods_dir"):
		return String(opts.mods_dir)
	var env := OS.get_environment("PITTAPI_MODS_DIR")
	if env != "":
		return env
	var gd := OS.get_environment("PITTAPI_GAME_DIR")
	if gd != "" and OS.has_feature("editor"):
		return gd.path_join("mods")
	# Our own folder is <game>/mods/PittAPI. The path may come back absolute or
	# localized to res:// (when the game dir is the resource dir), so try both forms
	# and keep the first that really contains our mod.json.
	var candidates: Array[String] = []
	var sp := String(get_script().resource_path)
	if sp != "":
		candidates.append(ProjectSettings.globalize_path(sp).get_base_dir().get_base_dir())
		if sp.begins_with("res://"):
			candidates.append(OS.get_executable_path().get_base_dir().path_join(sp.trim_prefix("res://")).get_base_dir().get_base_dir())
	candidates.append(OS.get_executable_path().get_base_dir().path_join("mods"))
	for c in candidates:
		if FileAccess.file_exists(c.path_join("PittAPI/mod.json")):
			return c
	return candidates[0]


func _count_state(st: String) -> int:
	var n := 0
	for id in loader.mods:
		if loader.mods[id].state == st:
			n += 1
	return n
