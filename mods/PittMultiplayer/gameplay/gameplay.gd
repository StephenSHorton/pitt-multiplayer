extends RefCounted
## GAMEPLAY module (MP2-DESIGN 4, 6, 10.4): host-only gameplay, forwarded player
## input, remote camera rigs and ghost colliders, player effects, penalties,
## shared combo, cosmetic effects, mirror fields, the per-player panel rack and
## host purchase spawning.
##
## main.gd creates one instance and calls session.register_module(it). Every
## extension in extensions/gameplay/ reaches it only through gameplay/mp_gate.gd
## (installed in MpGate.gp between on_session_start and teardown), so with no
## session, or with this file missing, every extension takes the vanilla path.
##
## BODIES is reached through get_module("bodies") (10.2), GRAB through
## get_module("grab") (10.3); both are optional at runtime (missing = the
## feature that needs them is skipped and counted).

const MpGate = preload("mp_gate.gd")
const GameplayAdapter = preload("../game/gameplay_adapter.gd")
const InteractClient = preload("interact_client.gd")
const InteractHost = preload("interact_host.gd")
const Rigs = preload("rigs.gd")
const Ghosts = preload("ghosts.gd")
const PlayerFx = preload("player_fx.gd")
const Penalties = preload("penalties.gd")
const ComboMirror = preload("combo_mirror.gd")
const Fx = preload("fx.gd")
const FixtureAdapters = preload("fixture_adapters.gd")
const MachineMeta = preload("machine_meta.gd")
const MirrorFields = preload("mirror_fields.gd")
const Rack = preload("rack.gd")

const MOD_NAME := "gameplay"
const CMD_PENALTY := "PittMultiplayer.penalty"
const CMD_RECALL := "PittMultiplayer.recall"
const CMD_RACK_STORE := "PittMultiplayer.rack_store"
const CMD_RACK_WITHDRAW := "PittMultiplayer.rack_withdraw"
## deny reasons for GRAB (10.4)
const BUSY_METAS := ["in_cannon_barrel", "in_vacuum_bag", "consumed", "pending_maw_recycle"]

var session = null
var api = null
var role := ""
## set before on_session_start to inject a fake (tests); else GameplayAdapter
var adapter = null
var live := false
var world_on := false

var interact_client = null
var interact_host = null
var rigs = null
var ghosts = null
var player_fx = null
var penalties = null
var combo = null
var fx = null
var fixtures = null
var machines = null
var mirror = null
var rack = null

var _holders: Dictionary = {}          # host: bench eid (or instance id key) -> {peer: true}
var _cmd_registry = null               # the api.commands our commands are registered on
var _driver: Node = null               # physics driver node in the world (rigs, ghosts, combo timer)
var _bodies_wired = null
var _grab_wired = null
var _ctr: Dictionary = {"interact_tx": 0, "tool_in_tx": 0, "interact_rx": 0, "interact_rejected": 0,
	"interact_unresolved": 0, "fx_tx": 0, "fx_rx": 0, "fx_dropped": 0, "pimp_tx": 0, "pimp_rx": 0,
	"penalties": 0, "penalties_ignored": 0, "revokes": 0, "fixture_spawns": 0, "no_bodies": 0}


func _init() -> void:
	interact_client = InteractClient.new(self)
	interact_host = InteractHost.new(self)
	rigs = Rigs.new(self)
	ghosts = Ghosts.new(self)
	player_fx = PlayerFx.new(self)
	penalties = Penalties.new(self)
	combo = ComboMirror.new(self)
	fx = Fx.new(self)
	fixtures = FixtureAdapters.new(self)
	machines = MachineMeta.new(self)
	mirror = MirrorFields.new(self)
	rack = Rack.new(self)


# ================================================================== module duck type (10.1)

func mod_name() -> String:
	return MOD_NAME


func msg_kinds() -> Dictionary:
	return {"ch3_c2h": ["interact", "tool_in"], "ch3_h2c": ["fx", "pimp", "fixture_spawn"],
		"ch0_c2h": [], "ch0_h2c": ["combo"], "raw_c2h": []}


func on_session_start(p_session: Object, p_role: String) -> void:
	session = p_session
	role = p_role
	api = session.api if session != null and "api" in session else null
	if adapter == null:
		adapter = GameplayAdapter.new()
		adapter.setup(api)
	live = true
	MpGate.gp = self
	MpGate.exec_peer = 0
	_register_commands()
	_wire_modules()
	fixtures.register_all()
	machines.register_all()
	mirror.register_all()


func on_world_started() -> void:
	world_on = true
	_wire_modules()
	_ensure_driver()
	combo.on_world_started()
	if role == "host":
		for p in _in_game():
			on_peer_world_ready(int(p))


func on_world_stopped(_reason: String) -> void:
	if role == "host":
		# remote players' equipped tools and racked panels belong to the host's world
		rigs.unequip_all()
		rack.return_all()
	world_on = false
	combo.on_world_stopped()


func on_msg(peer: int, k: String, msg: Dictionary) -> void:
	match k:
		"interact", "tool_in":
			if role == "host":
				_ctr.interact_rx += 1
				interact_host.on_msg(peer, k, msg)
		"fx":
			if role == "client":
				fx.client_apply(msg)
		"pimp":
			if role == "client":
				player_fx.client_on_pimp(msg)
		"fixture_spawn":
			if role == "client":
				_client_fixture_spawn(msg)
		"combo":
			if role == "client":
				combo.client_on_combo(msg)


func on_peer_world_ready(peer: int) -> void:
	if role != "host" or peer <= 1:
		return
	_ensure_driver()
	rigs.add_peer(peer)
	ghosts.add_peer(peer)
	penalties.on_peer_ready(peer)
	combo.send_full(peer)


func on_peer_left(peer: int) -> void:
	if role != "host":
		return
	rigs.remove_peer(peer)
	ghosts.remove_peer(peer)
	rack.on_peer_left(peer)
	penalties.on_peer_left(peer)
	interact_host.on_peer_left(peer)
	for key in _holders.keys():
		var hs: Dictionary = _holders[key]
		if hs.erase(peer) and hs.is_empty():
			var bench = _bench_of(key)
			if bench != null and bool(bench.get("is_crafting")) and bench.has_method("stop_crafting"):
				host_exec(0, func(): bench.stop_crafting())


func wsnap_section() -> Dictionary:
	return {"combo": combo.full_state()}


func apply_wsnap_section(d: Dictionary) -> void:
	if typeof(d.get("combo", null)) == TYPE_DICTIONARY:
		combo.client_on_combo(d.combo)


func tick(now_ms: int) -> void:
	if not live:
		return
	fx.flush()
	player_fx.tick(now_ms)
	combo.tick(now_ms)
	interact_host.tick(now_ms)


func counters() -> Dictionary:
	var out := _ctr.duplicate()
	out.merge(fx.counters(), true)
	out.merge(combo.counters(), true)
	out.merge(penalties.counters(), true)
	out.merge(rigs.counters(), true)
	out.merge(rack.counters(), true)
	out.merge(interact_host.counters(), true)
	out.merge(interact_client.counters(), true)
	return out


func teardown() -> void:
	fx.flush()
	combo.teardown()
	rigs.clear()
	ghosts.clear()
	rack.clear()
	penalties.clear()
	interact_host.clear()
	interact_client.clear()
	player_fx.clear()
	_holders.clear()
	if _driver != null and is_instance_valid(_driver):
		_driver.queue_free()
	_driver = null
	_unwire_modules()
	live = false
	world_on = false
	if MpGate.gp == self:
		MpGate.reset()


# ================================================================== 10.4 API (host)

func rig_of(peer: int) -> Camera3D:
	return rigs.rig_of(peer)


func ghost_of(peer: int) -> Node3D:
	return ghosts.ghost_of(peer)


## MpGate.exec_peer + PlayerEffectRedirect around c (MP2 6.6).
func host_exec(peer: int, c: Callable) -> Variant:
	return player_fx.host_exec(peer, c)


func player_impulse(peer: int, v: Vector3, src: String) -> void:
	player_fx.queue_impulse(peer, v, src)


## Bench holder set (tests).
func holders_of(eid: int) -> Array:
	var hs: Dictionary = _holders.get(eid, {})
	var out: Array = hs.keys()
	out.sort()
	return out


# ================================================================== gate callbacks (mp_gate.gd)

func gate_live() -> bool:
	if not live or session == null or not is_instance_valid(session):
		return false
	if session.has_method("ext_live"):
		return bool(session.ext_live())
	return true


func gate_role() -> String:
	return role


func gate_applying() -> bool:
	return api != null and "net" in api and api.net != null and bool(api.net.is_applying())


func forward_input(node: Object, verb: String, args: Array) -> void:
	interact_client.forward(node, verb, args)


func send_penalty(kind: String) -> void:
	penalties.client_send(kind)


func fx_emit(kind: String, node: Object, args: Dictionary) -> void:
	fx.emit(kind, node, args)


func host_after(node: Object) -> void:
	var b = get_bodies()
	if b == null:
		return
	var eid := eid_of(node)
	if eid > 0:
		b.meta_dirty(eid)
		b.boost(eid, 2.0)


func host_consumed(body: Object, reason: String) -> void:
	var g = get_grab()
	if g == null:
		return
	var eid := eid_of(body)
	if eid <= 0:
		return
	var owner := int(g.owner_of(eid))
	if owner > 1:
		g.revoke(eid, reason)
		_ctr.revokes += 1


func remote_owned(node: Object) -> bool:
	var g = get_grab()
	if g == null:
		return false
	var eid := eid_of(node)
	return eid > 0 and int(g.owner_of(eid)) > 1


func mark_snap(node: Object) -> void:
	var b = get_bodies()
	var eid := eid_of(node)
	if b != null and eid > 0:
		b.mark_snap(eid)


func bench_hold(node: Object, peer: int) -> void:
	if peer <= 0:
		return
	var key := _bench_key(node)
	if not _holders.has(key):
		_holders[key] = {}
	_holders[key][peer] = true


## false = keep crafting (another holder remains).
## peer 0 is the bench itself (a craft finished, workbench._process): it stops as in
## single player, and remote players still holding craft start the next item at once,
## as the host player's own interact_ray does every frame while LMB is held (0.2.2: a
## client got one item per press). The host player's hold is re-armed by its ray.
func bench_release(node: Object, peer: int) -> bool:
	var key := _bench_key(node)
	if peer <= 0:
		var held: Dictionary = _holders.get(key, {})
		held.erase(1)
		if held.is_empty():
			_holders.erase(key)
		else:
			Callable(self, "_rearm_bench").call_deferred(key)
		return true
	var hs: Dictionary = _holders.get(key, {})
	hs.erase(peer)
	if hs.is_empty():
		_holders.erase(key)
		return true
	return false


## Deferred after a finished craft: the next item for the first remote holder.
func _rearm_bench(key: int) -> void:
	if not live or role != "host":
		return
	var held: Dictionary = _holders.get(key, {})
	var bench = _bench_of(key)
	if held.is_empty() or bench == null or not is_instance_valid(bench) or bool(bench.get("is_crafting")) 			or not bench.has_method("start_crafting"):
		return
	var peers: Array = held.keys()
	peers.sort()
	host_exec(int(peers[0]), func(): bench.start_crafting())


func bench_held_by(node: Object, peer: int) -> bool:
	return bool((_holders.get(_bench_key(node), {}) as Dictionary).has(peer))


func _bench_key(node: Object) -> int:
	var eid := eid_of(node)
	return eid if eid > 0 else -int(node.get_instance_id())


func _bench_of(key: int) -> Object:
	if key > 0:
		var b = get_bodies()
		return b.node_of(key) if b != null else null
	var o = instance_from_id(-key)
	return o if o != null and is_instance_valid(o) else null


# ================================================================== helpers for the sub-objects

func get_bodies():
	return session.get_module("bodies") if session != null and session.has_method("get_module") else null


func get_grab():
	return session.get_module("grab") if session != null and session.has_method("get_module") else null


func eid_of(node: Object) -> int:
	if node == null or not is_instance_valid(node):
		return 0
	var b = get_bodies()
	return int(b.eid_of(node)) if b != null else 0


func node_of(eid: int) -> Node:
	var b = get_bodies()
	return b.node_of(eid) if b != null and eid > 0 else null


func send_world(peer: int, k: String, body: Dictionary) -> Error:
	if session == null or not session.has_method("send_world"):
		return ERR_UNCONFIGURED
	return session.send_world(peer, k, body)


func avatar_pose(peer: int) -> Dictionary:
	if session == null or not session.has_method("avatar_pose"):
		return {"ok": false}
	return session.avatar_pose(peer)


func host_now() -> int:
	return int(session.host_now()) if session != null and session.has_method("host_now") else Time.get_ticks_msec()


func begin_apply() -> void:
	if api != null and "net" in api and api.net != null:
		api.net.begin_apply(1)


func end_apply() -> void:
	if api != null and "net" in api and api.net != null:
		api.net.end_apply()


func log_info(msg: String) -> void:
	if session != null and session.has_method("log_info"):
		session.log_info("[gameplay] " + msg)


func log_warn(msg: String) -> void:
	if session != null and session.has_method("log_warn"):
		session.log_warn("[gameplay] " + msg)


func count(key: String, n: int = 1) -> void:
	_ctr[key] = int(_ctr.get(key, 0)) + n


func _in_game() -> Array:
	return session.in_game_peers() if session != null and session.has_method("in_game_peers") else []


## The node the gameplay driver lives under (the world scene, else the tree root).
func world_parent() -> Node:
	var w = adapter.world_root() if adapter != null else null
	if w != null:
		return w
	var t := Engine.get_main_loop() as SceneTree
	return t.root if t != null else null


func _ensure_driver() -> void:
	if _driver != null and is_instance_valid(_driver) and _driver.is_inside_tree():
		return
	var parent := world_parent()
	if parent == null:
		return
	_driver = Driver.new()
	_driver.gp = self
	_driver.name = "PittMP_Gameplay"
	parent.add_child(_driver)


func driver() -> Node:
	return _driver


func _wire_modules() -> void:
	var b = get_bodies()
	if b != null and b != _bodies_wired:
		_bodies_wired = b
		if b.has_signal("entity_removed") and not b.entity_removed.is_connected(_on_entity_removed):
			b.entity_removed.connect(_on_entity_removed)
		if b.has_signal("entity_added") and not b.entity_added.is_connected(_on_entity_added):
			b.entity_added.connect(_on_entity_added)
	var g = get_grab()
	if g != null and g != _grab_wired:
		_grab_wired = g
		if g.has_signal("owner_changed") and not g.owner_changed.is_connected(_on_owner_changed):
			g.owner_changed.connect(_on_owner_changed)
		if g.has_method("add_deny_rule") and role == "host":
			g.add_deny_rule(_deny_rule)


func _unwire_modules() -> void:
	if _bodies_wired != null and is_instance_valid(_bodies_wired):
		if _bodies_wired.has_signal("entity_removed") and _bodies_wired.entity_removed.is_connected(_on_entity_removed):
			_bodies_wired.entity_removed.disconnect(_on_entity_removed)
		if _bodies_wired.has_signal("entity_added") and _bodies_wired.entity_added.is_connected(_on_entity_added):
			_bodies_wired.entity_added.disconnect(_on_entity_added)
	if _grab_wired != null and is_instance_valid(_grab_wired):
		if _grab_wired.has_signal("owner_changed") and _grab_wired.owner_changed.is_connected(_on_owner_changed):
			_grab_wired.owner_changed.disconnect(_on_owner_changed)
	_bodies_wired = null
	_grab_wired = null


func _on_entity_added(eid: int, node: Node) -> void:
	rack.on_entity_added(eid, node)


func _on_entity_removed(eid: int) -> void:
	_holders.erase(eid)
	rigs.on_entity_removed(eid)


func _on_owner_changed(eid: int, owner_peer: int, kind: String, epoch: int) -> void:
	if role == "host":
		rigs.on_owner_changed(eid, owner_peer, kind, epoch)


## GRAB deny rule (10.4): bodies the host's own machines are busy with.
func _deny_rule(_eid: int, node: Node, _peer: int) -> String:
	if node == null or not is_instance_valid(node):
		return ""
	for m in BUSY_METAS:
		if bool(node.get_meta(m, false)):
			return "busy"
	if node.is_in_group("terminal_pull"):
		return "busy"
	if bool(node.get_meta("pitt_mp_press_stroke", false)):
		return "busy"
	if bool(node.get_meta("pitt_mp_ritual", false)):
		return "busy"
	return ""


# ================================================================== commands (host side handlers, 2.4)

func _register_commands() -> void:
	if api == null or not ("commands" in api) or api.commands == null:
		return
	if _cmd_registry == api.commands:
		return
	_cmd_registry = api.commands
	var c = api.commands
	c.register(CMD_PENALTY, penalties.cmd_penalty, {"schema": {"kind": TYPE_STRING}, "remote": true,
		"replicate": "none", "description": "A client's own player fell into the maw / a fail-safe (multiplayer)"})
	c.register(CMD_RECALL, _cmd_recall, {"schema": {"tool": TYPE_STRING}, "remote": true,
		"description": "Recall a tool to the tube on the host (multiplayer)"})
	c.register(CMD_RACK_STORE, rack.cmd_store, {"schema": {"eid": TYPE_INT}, "remote": true, "replicate": "none",
		"description": "Store a held panel in the sender's rack (multiplayer)"})
	c.register(CMD_RACK_WITHDRAW, rack.cmd_withdraw, {"schema": {}, "remote": true, "replicate": "none",
		"description": "Take a panel from the sender's rack (multiplayer)"})


func _cmd_recall(args: Dictionary, ctx) -> Variant:
	if role != "host" or not gate_live():
		return ctx.fail("recall needs the host's running world", "ERR_UNAVAILABLE")
	var ui = adapter.upgrade_ui()
	if ui == null or not ui.has_method("_recall_tool"):
		return ctx.fail("no terminal", "ERR_UNAVAILABLE")
	var tool := String(args.get("tool", ""))
	var n = host_exec(int(ctx.origin_peer) if ctx.is_remote else 1, func(): return ui._recall_tool(tool))
	return {"recalled": int(n) if n != null else 0}


# ================================================================== fixture_spawn (6.1)

## Host: a bought fixture (press / trading terminal / bowling set) was spawned
## by the host terminal; every client builds the same fixture on its own.
func host_fixture_spawned(key: String, level: int) -> void:
	if role != "host" or not gate_live():
		return
	send_world(0, "fixture_spawn", {"key": key, "level": level})
	_ctr.fixture_spawns += 1


func _client_fixture_spawn(msg: Dictionary) -> void:
	var ui = adapter.upgrade_ui()
	if ui == null:
		return
	var key := String(msg.get("key", ""))
	begin_apply()
	match key:
		"press", "trading":
			if ui.has_method("_spawn_tool_instance"):
				ui._spawn_tool_instance(key, int(msg.get("level", 0)))
		"bowling_pin_set":
			if ui.has_method("_spawn_toy_instance"):
				ui._spawn_toy_instance(key)
	end_apply()


# ================================================================== driver node

class Driver extends Node:
	var gp = null

	func _init() -> void:
		process_mode = Node.PROCESS_MODE_PAUSABLE
		process_physics_priority = 110

	func _physics_process(delta: float) -> void:
		if gp == null or not gp.live:
			return
		gp.rigs.physics(delta)
		gp.ghosts.physics(delta)

	func _process(delta: float) -> void:
		if gp == null or not gp.live:
			return
		gp.combo.process(delta)
