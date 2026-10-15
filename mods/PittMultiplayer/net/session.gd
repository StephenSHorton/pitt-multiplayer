extends Node
## Session (MP-DESIGN 4, interface contract 5.4). One state machine for both
## roles; it reacts to LobbyService signals, owns the Transport, the MpAuthority
## and every sync/world module, and is the only thing the UI talks to.
##
## Host:   idle -> lobby -> starting (Start; game's save picker) -> loading
##         (world launching) -> in_game (host_state open/transition) -> ending -> idle
## Client: idle -> lobby (connecting -> handshake -> waiting) -> loading
##         (snapshot + world load) -> in_game -> ending -> idle
## Clients ALWAYS enter through the late-join path once the host's world is
## OPEN, so Start and late join are one code path (4.1).
##
## MP2 (MP2-DESIGN 2.6, 10.1): a module registry. main.gd registers the
## BODIES / GAMEPLAY / GRAB modules before the session goes live; the Session
## routes their message kinds (ch0, ch3) and raw frames (4, 5) to them, ticks
## them, runs the world-snapshot handshake (3.7: world_req -> wsnap -> ready)
## and emits world_started / world_stopped / peer_world_ready / peer_left.
## Without a "bodies" module the session runs the MP1 path unchanged.

const Proto = preload("proto.gd")
const Codec = preload("codec.gd")
const Roster = preload("roster.gd")
const Clock = preload("clock.gd")
const MpAuthority = preload("mp_authority.gd")
const TransportEnet = preload("transport_enet.gd")
const TransportSteam = preload("transport_steam.gd")
const TransportLoopback = preload("transport_loopback.gd")
const EconHost = preload("../sync/econ_host.gd")
const EconClient = preload("../sync/econ_client.gd")
const Purchases = preload("../sync/purchases.gd")
const Progression = preload("../sync/progression.gd")
const Snapshot = preload("../sync/snapshot.gd")
const Avatars = preload("../world/avatars.gd")
const PauseGuard = preload("../world/pause_guard.gd")
const InputGuard = preload("../world/input_guard.gd")
const SaveGuard = preload("../world/save_guard.gd")
const Achievements = preload("../policy/achievements.gd")

signal state_changed(state: String, info: Dictionary)
signal roster_changed(players: Array)
signal start_availability_changed(ok: bool, reason: String)
signal ended(reason: String, detail: String)
# MP2 10.1
signal world_started(role: String)
signal world_stopped(reason: String)
signal peer_world_ready(peer: int)
signal peer_left(peer: int)

const STATES := ["idle", "lobby", "starting", "loading", "in_game", "ending", "closing"]
const END_REASONS := ["left", "host_left", "connection_lost", "version", "mods", "full", "kicked", "ending",
	"timeout", "protocol", "error"]
const SILENT_END_REASONS := ["left", "ending"]

const HANDSHAKE_TIMEOUT_MS := 10000
const SNAPSHOT_TIMEOUT_MS := 60000
const LOAD_TIMEOUT_MS := 180000
const SILENCE_TIMEOUT_MS := 15000
const SILENCE_LOADING_MS := 60000
const HELLO_TIMEOUT_MS := 10000
const PING_INTERVAL_MS := 500
const JOIN_WAIT_MS := 60000
const BYE_FLUSH_MS := 250
## Steam: a connecting peer must be a member of our lobby; lobby_chat_update
## can trail the P2P connection, so the hello waits this long for it.
const MEMBER_WAIT_MS := 5000
## Client: snapshot chunks (CH_BULK) that overtake snap_begin (CH_CONTROL).
const EARLY_CHUNKS_MAX := 4096
## Client: save isolation outlives the session until the world is really gone.
const SAVE_HOLD_MAX_MS := 240000
const SAVE_HOLD_MENU_RETRY_MS := 2000

## MP2 world snapshot (3.7): xfer ids distinct from the MP1 snapshot's
const WSNAP_XFER_BASE := 1000000
const WSNAP_TIMEOUT_MS := 60000
const WSNAP_APPLY_TIMEOUT_MS := 60000
## client: ch3 messages buffered while the world snapshot is fetched / applied
const WORLD_BUFFER_MAX := 20000
const DEFAULT_EYE := Vector3(0, 0.65, 0)

const CMD_BUY_ITEM := "PittMultiplayer.buy_item"
const CMD_BUY_TOOL := "PittMultiplayer.buy_tool"
const CMD_BUY_TOY := "PittMultiplayer.buy_toy"

var api = null
var lobby: Node = null
var adapter = null
var config: Dictionary = {}
var version: Dictionary = {}

var transport = null
var role := ""
var state := "idle"
var sub := ""
var host_state := ""
var sid := ""
var my_peer := 0
var rules := {"achievements": "presence", "cheats": false}

var proto = null
var roster = null
var clock = null
var authority = null
var econ_host = null
var econ_client = null
var purchases = null
var progression = null
var snapshot = null
var avatars = null
var pause_guard = null
var input_guard = null
var save_guard = null
var achievements = null

var _out_q: Dictionary = {}
var _last_rx: Dictionary = {}
var _hello_wait: Dictionary = {}      # host: transport peer -> connected ms
var _member_wait: Dictionary = {}     # host (steam): peer -> {msg, until}
var member_wait_ms := MEMBER_WAIT_MS
var _early_chunks: Array = []         # client: chunks that arrived before snap_begin
var _save_hold: Dictionary = {}       # client after a session: {until, world_seen, next_try}
var _last_ping_ms := 0
var _deadline_ms := 0
var _deadline_reason := ""
var _join_queue: Array = []           # host: [{peer, at}]
var _serving: Dictionary = {}         # host: peer -> {xfer, at}
var _join_requested := false
var _rx = null                         # client: Snapshot.Receive
var _snap_data: Dictionary = {}
var _session_file := ""
var _launched := false
var _world_ready_seen := false
var _save_applied_seen := false
var _pending_abort := ""
var _pending_abort_detail := ""
var _last_end: Dictionary = {}
var _tearing_down := false
var _start_ok_prev = null
var _host_launch_path := ""
var _closing_transport = null
var _closing_at := 0
var _event_subs: Array = []
var _adapter_wired := false
var _ended_emitted := false
var _commands_registered := false
var log_lines: Array = []
var counters := {"kicked_rate": 0, "rejected": 0, "joins_served": 0, "early_chunks": 0, "world_req_refused": 0,
	"world_buffered": 0, "world_dropped": 0, "wsnaps_served": 0,
	"world_too_large": 0, "wsnap_send_failed": 0}

# ---- MP2 module registry (10.1)
var _modules: Array = []
var _mod_by_name: Dictionary = {}
var _module_kinds: Array = []          # every registered msg_kinds() (re-applied to each new validator)
var _route0: Dictionary = {}           # ch0 kind -> module
var _route3: Dictionary = {}           # ch3 kind -> module
var _route_raw: Dictionary = {}        # raw frame kind -> module
var _modules_started := false
var _world_live := false
## the local CameraPivot offset (eye = avatar pos + this); BODIES sets it from the game
var eye_offset := DEFAULT_EYE
var _avatar_frames: Dictionary = {}    # peer -> newest decoded MP1 avatar frame (+ rx_ms)
var _out_q3: Dictionary = {}           # ch3 per-direction sequence
# host
var _world_cut: Dictionary = {}        # peer -> true once its world snapshot was cut (ch3 flows)
var _world_req_seen: Dictionary = {}   # peer -> true (one world_req per join)
## world snapshot measurements (tests, `mp stats`): host {build_us, raw, zstd, chunks, peer},
## client {req_ms, rx_ms (request -> last chunk), apply_ms, raw}
var wsnap_stats: Dictionary = {}
var _wxfer := 0
# client
var _world_flow := ""                  # "" | "requested" | "applying" | "done"
var _wrx = null                        # Snapshot.Receive of the world snapshot
var _wcut_q := 0
var _world_buffer: Array = []          # [msg] ch3 messages received before the world went live
var _wapply_started_ms := 0


func _init(p_api = null, p_lobby: Node = null, p_adapter = null, p_config: Dictionary = {}) -> void:
	name = "Session"
	process_mode = Node.PROCESS_MODE_ALWAYS
	api = p_api
	lobby = p_lobby
	adapter = p_adapter
	config = p_config.duplicate() if p_config != null else {}
	version = config.get("version", {})
	rules.achievements = String(config.get("achievements", "presence"))
	clock = Clock.new()
	roster = Roster.new()
	roster.max_players = int(config.get("max_players", 10))
	proto = Proto.new("")
	_make_modules()
	_wire_lobby()
	_wire_adapter()
	_register_commands()


func _make_modules() -> void:
	econ_host = EconHost.new(self, adapter)
	econ_client = EconClient.new(self, adapter)
	purchases = Purchases.new(self, adapter)
	progression = Progression.new(self, adapter)
	snapshot = Snapshot.new(adapter)
	avatars = Avatars.new(self, adapter)
	pause_guard = PauseGuard.new(self, adapter)
	input_guard = InputGuard.new(adapter)
	save_guard = SaveGuard.new(self, adapter)
	achievements = Achievements.new(self, adapter, rules.achievements)


func _wire_lobby() -> void:
	if lobby == null:
		return
	if lobby.has_signal("lobby_entered"):
		lobby.lobby_entered.connect(_on_lobby_entered)
	if lobby.has_signal("lobby_left"):
		lobby.lobby_left.connect(_on_lobby_left)
	if lobby.has_signal("members_changed"):
		lobby.members_changed.connect(_on_members_changed)


func _wire_adapter() -> void:
	if adapter == null or _adapter_wired:
		return
	_adapter_wired = true
	adapter.world_ready.connect(_on_world_ready)
	adapter.world_exited.connect(_on_world_exited)
	adapter.save_applied.connect(_on_save_applied)
	adapter.phase_settled.connect(_on_phase_settled)


func _register_commands() -> void:
	if api == null or not ("commands" in api) or api.commands == null or _commands_registered:
		return
	_commands_registered = true
	var c = api.commands
	c.register(CMD_BUY_ITEM, _cmd_buy_item, {"schema": {"category": TYPE_STRING, "key": TYPE_STRING,
		"subkey?": TYPE_STRING}, "remote": true, "description": "Buy an upgrade/product/combo/toy level on the host (multiplayer)"})
	c.register(CMD_BUY_TOOL, _cmd_buy_tool, {"schema": {"tool": TYPE_STRING, "level": TYPE_INT}, "remote": true,
		"description": "Buy a tool on the host; it spawns once in the shared world (multiplayer)"})
	c.register(CMD_BUY_TOY, _cmd_buy_toy, {"schema": {"toy": TYPE_STRING}, "remote": true,
		"description": "Buy a toy on the host; it spawns once in the shared world (multiplayer)"})
	if "events" in api and api.events != null:
		_event_subs.append(api.events.on("command.executed", _on_command_executed))


# ================================================================== 5.4 queries

func get_state() -> String:
	return state


func get_role() -> String:
	return role


## A transport session exists (lobby .. ending).
func is_live() -> bool:
	return state in ["lobby", "starting", "loading", "in_game", "ending"]


func get_roster() -> Array:
	return roster.to_array()


func can_start() -> Dictionary:
	if role != "host":
		return {"ok": false, "reason": "MP_START_NOT_HOST"}
	if state in ["starting", "loading"]:
		return {"ok": false, "reason": "MP_START_BUSY"}
	if state != "lobby":
		return {"ok": false, "reason": "MP_START_NOT_READY"}
	if bool(config.get("block_start", false)):
		return {"ok": false, "reason": "MP_ERR_INCOMPATIBLE_BUILD"}
	return {"ok": true, "reason": ""}


func consume_last_end() -> Dictionary:
	var d := _last_end
	_last_end = {}
	return d


func get_info() -> Dictionary:
	return {"role": role, "sub": sub, "host_state": host_state}


# ================================================================== MP2 module registry (10.1)

## main.gd, before the session goes live; registration order = call order.
func register_module(m: Object) -> void:
	if m == null or not m.has_method("mod_name") or _modules.has(m):
		return
	var n := String(m.mod_name())
	if _mod_by_name.has(n):
		_log("warn", "module %s registered twice: ignored" % n)
		return
	_modules.append(m)
	_mod_by_name[n] = m
	if m.has_method("msg_kinds"):
		var kinds = m.msg_kinds()
		if typeof(kinds) == TYPE_DICTIONARY:
			_module_kinds.append(kinds)
			proto.add_kinds(kinds)
			for k in kinds.get("ch0_c2h", []) + kinds.get("ch0_h2c", []):
				_route0[String(k)] = m
			for k in kinds.get("ch3_c2h", []) + kinds.get("ch3_h2c", []):
				_route3[String(k)] = m
			for fk in kinds.get("raw_c2h", []) + kinds.get("raw_h2c", []):
				_route_raw[int(fk)] = m
	_log("info", "MP2 module %s registered" % n)
	if _modules_started and m.has_method("on_session_start"):
		m.on_session_start(self, role)


## "bodies" | "gameplay" | "grab" | null
func get_module(mod_name: String) -> Object:
	return _mod_by_name.get(mod_name, null)


## MP2 shared world on: a bodies module is registered (else the MP1 path).
func mp2_active() -> bool:
	return _mod_by_name.has("bodies")


func is_host() -> bool:
	return role == "host"


func my_peer_id() -> int:
	return my_peer


func peer_of_slot(slot: int) -> int:
	return roster.peer_of_slot(slot)


## Host: peers that receive ch3 world messages (in game, or loading past their
## world-snapshot cut). Client: [1] once its world is live or being fetched.
func world_peers() -> Array:
	if role != "host":
		return [1] if _world_flow != "" else []
	var out: Array = []
	for p in roster.peers():
		if p == 1:
			continue
		if roster.state_of(p) == "in_game" or _world_cut.has(p):
			out.append(p)
	return out


## The world (ch3) is live on this peer (host OPEN / client after its wsnap apply).
func world_live() -> bool:
	return _world_live


func _module_call(method: String, args: Array = []) -> void:
	for m in _modules.duplicate():
		if m != null and m.has_method(method):
			m.callv(method, args)


func _modules_session_start() -> void:
	if _modules_started:
		return
	_modules_started = true
	_module_call("on_session_start", [self, role])


func _modules_teardown() -> void:
	if not _modules_started:
		return
	_modules_started = false
	var rev := _modules.duplicate()
	rev.reverse()
	for m in rev:
		if m != null and m.has_method("teardown"):
			m.teardown()


func _start_world() -> void:
	if _world_live:
		return
	_world_live = true
	world_started.emit(role)
	_module_call("on_world_started")


func _stop_world(reason: String) -> void:
	if not _world_live:
		return
	_world_live = false
	world_stopped.emit(reason)
	_module_call("on_world_stopped", [reason])


## JSON on ch3 (MP2 2.2). peer 0 = every world peer (host only).
func send_world(peer: int, k: String, body: Dictionary) -> Error:
	if transport == null:
		return ERR_UNCONFIGURED
	var targets: Array = []
	if role == "host":
		var wp := world_peers()
		if peer == 0:
			targets = wp
		elif peer in wp:
			targets = [peer]
		else:
			return ERR_UNAVAILABLE    # nothing on ch3 before the peer's world-snapshot cut
	else:
		if peer != 1 or my_peer <= 0:
			return ERR_INVALID_PARAMETER
		targets = [1]
	var err: Error = OK
	# the body is stringified once; only the per-peer stream counter q differs
	var msg := body.duplicate()
	msg["k"] = k
	msg["sid"] = sid
	var head := JSON.stringify(msg)
	head = head.substr(0, head.length() - 1) + ",\"q\":"
	# both caps: the encoded frame (the sender's ch3 cap) and the raw JSON the
	# receiver accepts after decompression (Codec.decode max_json)
	var cap := Proto.MAX_H2C_WORLD_JSON if role == "host" else Proto.MAX_C2H_WORLD_JSON
	var raw_cap := Proto.MAX_H2C_JSON if role == "host" else Proto.MAX_C2H_JSON
	for p in targets:
		var q := int(_out_q3.get(p, 0)) + 1
		var raw := (head + str(q) + "}").to_utf8_buffer()
		var bytes := Codec.encode_raw_json(raw)
		if bytes.size() > cap + 8 or raw.size() > raw_cap:
			_log("warn", "world message %s too large (%d bytes, %d raw): not sent" % [k, bytes.size(), raw.size()])
			counters.world_too_large += 1
			err = ERR_OUT_OF_MEMORY
			continue
		_out_q3[p] = q
		msg["q"] = q
		proto.log_tx(p, msg)
		var e: Error = transport.send(p, Proto.CH_WORLD, bytes)
		if e != OK:
			err = e
	return err


## ch2 frames 4/5. Host: peer 0 = every in-game peer; client: peer 1.
func send_unreliable(peer: int, bytes: PackedByteArray) -> Error:
	if transport == null:
		return ERR_UNCONFIGURED
	if role == "host":
		if peer == 0:
			for p in in_game_peers():
				transport.send(p, Proto.CH_AVATAR, bytes)
			return OK
		if roster.state_of(peer) != "in_game":
			return ERR_UNAVAILABLE
		return transport.send(peer, Proto.CH_AVATAR, bytes)
	if peer != 1:
		return ERR_INVALID_PARAMETER
	return transport.send(1, Proto.CH_AVATAR, bytes)


## {ok, pos, yaw, pitch, vel, t_ms, eye}: the newest MP1 avatar frame of a peer
## (host: any remote peer; client: any peer including the host). Never reads
## puppet nodes.
func avatar_pose(peer: int) -> Dictionary:
	var f = _avatar_frames.get(peer, null)
	if f == null:
		return {"ok": false, "pos": Vector3.ZERO, "yaw": 0.0, "pitch": 0.0, "vel": Vector3.ZERO, "t_ms": 0,
			"eye": Vector3.ZERO}
	var pos: Vector3 = f.get("pos", Vector3.ZERO)
	return {"ok": true, "pos": pos, "yaw": float(f.get("yaw", 0.0)), "pitch": float(f.get("pitch", 0.0)),
		"vel": f.get("vel", Vector3.ZERO), "t_ms": int(f.get("t_ms", 0)), "eye": pos + eye_offset}


## The local player in the same shape (t_ms = host time now).
func local_pose() -> Dictionary:
	var st: Dictionary = adapter.local_avatar_state() if adapter != null else {}
	if st.is_empty():
		return {"ok": false, "pos": Vector3.ZERO, "yaw": 0.0, "pitch": 0.0, "vel": Vector3.ZERO, "t_ms": host_now(),
			"eye": Vector3.ZERO}
	var pos: Vector3 = st.get("pos", Vector3.ZERO)
	return {"ok": true, "pos": pos, "yaw": float(st.get("yaw", 0.0)), "pitch": float(st.get("pitch", 0.0)),
		"vel": st.get("vel", Vector3.ZERO), "t_ms": host_now(), "eye": pos + eye_offset}


## {peer: {ch: {tx_bps, rx_bps, tx_pps}}} of the last complete second (MP2 8).
func net_stats() -> Dictionary:
	if transport == null or not transport.has_method("window_stats"):
		return {}
	return transport.window_stats()


## Merged module counters (each module's counters()), plus the session's own.
func counters_all() -> Dictionary:
	var out := counters.duplicate()
	for m in _modules:
		if m != null and m.has_method("counters"):
			var c = m.counters()
			if typeof(c) == TYPE_DICTIONARY:
				for k in c:
					out[k] = c[k]
	return out


# ================================================================== 5.4 commands

## Host pressed Start: state "starting", lobby state "starting"; the UI opens the game's MenuLoad.
func start_game() -> Error:
	if not bool(can_start().ok):
		return ERR_UNAVAILABLE
	host_state = "starting"
	_lobby_state("starting")
	_set_state("starting")
	_broadcast_session()
	return OK


## Host backed out of MenuLoad.
func cancel_start() -> void:
	if role != "host" or state != "starting":
		return
	host_state = "lobby"
	_lobby_state("waiting")
	_set_state("lobby")
	_broadcast_session()


## main_menu_ext._launch_game while host-picking, called BEFORE super().
func notify_host_launch(scene_path: String) -> void:
	if role != "host" or state != "starting":
		return
	_host_launch_path = scene_path
	_set_state("loading")


## Idempotent, any state; always ends with lobby.leave().
func leave(reason: String = "left") -> void:
	_leave(reason, "", true)


# ================================================================== lobby events

func _on_lobby_entered(info: Dictionary) -> void:
	if state != "idle" or _tearing_down:
		return
	var target: Dictionary = lobby.transport_target() if lobby != null and lobby.has_method("transport_target") else {}
	if target.is_empty():
		_log("warn", "lobby entered without a transport target")
		_leave("error", "no transport target", false)
		return
	role = "host" if bool(info.get("is_owner", false)) else "client"
	proto = Proto.new(role)
	proto.rate_limits_enabled = bool(config.get("rate_limits", true))
	for kinds in _module_kinds:
		proto.add_kinds(kinds)
	transport = _make_transport(String(target.get("kind", "")))
	if transport == null:
		_leave("error", "unknown transport %s" % target.get("kind", ""), false)
		return
	if typeof(config.get("conditioning", null)) == TYPE_DICTIONARY and not config.conditioning.is_empty() \
			and transport.has_method("set_conditioning"):
		transport.set_conditioning(config.conditioning)
	transport.peer_connected.connect(_on_peer_connected)
	transport.peer_disconnected.connect(_on_peer_disconnected)
	transport.packet.connect(_on_packet)
	transport.opened.connect(_on_opened)
	transport.closed.connect(_on_transport_closed)
	_ended_emitted = false
	_last_end = {}
	_out_q.clear()
	_last_rx.clear()
	roster.clear()
	clock.reset()
	if role == "host":
		sid = Proto.new_sid()
		proto.sid = sid
		my_peer = 1
		var err: Error = transport.host(target)
		if err != OK:
			_log("warn", "transport host failed: %s" % error_string(err))
			_leave("error", "could not open the host transport (%s)" % error_string(err), false)
			return
		roster.add(1, lobby.get_local_name() if lobby.has_method("get_local_name") else "Host",
			String(info.get("owner_id", "")), true)
		authority = MpAuthority.new(self, "host", 1)
		authority.allow_remote_cheats = bool(config.get("allow_remote_cheats", false))
		_install_authority()
		host_state = "lobby"
		econ_host.reset()
		_lobby_state("waiting")
		_set_state("lobby")
		_emit_roster()
		_net_session_started()
	else:
		sid = ""
		my_peer = 0
		_join_requested = false
		var err2: Error = transport.join(target)
		if err2 != OK:
			_leave("error", "could not connect (%s)" % error_string(err2), false)
			return
		sub = "connecting"
		_set_deadline(HANDSHAKE_TIMEOUT_MS + 2000, "timeout")
		_set_state("lobby")


func _on_lobby_left(reason: String) -> void:
	if state == "idle" or _tearing_down:
		return
	match reason:
		"left":
			_leave("left", "", true)
		"host_left":
			# lobby owner change or the owner left = the host left (no migration, R8)
			_abort("host_left" if role == "client" else "error", "")
		"kicked":
			_abort("kicked", "")
		_:
			_abort("error", reason)


func _make_transport(kind: String):
	if config.has("transport_factory") and config.transport_factory is Callable and config.transport_factory.is_valid():
		return config.transport_factory.call(kind)
	match kind:
		"enet":
			var t = TransportEnet.new()
			t.bind_ip = String(config.get("enet_bind_ip", "127.0.0.1"))
			return t
		"steam":
			var s = TransportSteam.new()
			s.mode = String(config.get("steam_peer_mode", "socket"))
			return s
		"loopback":
			return TransportLoopback.new()
	return null


# ================================================================== transport events

func _on_opened() -> void:
	if role == "client" and state == "lobby" and sub == "connecting":
		sub = "handshake"
		_set_deadline(HANDSHAKE_TIMEOUT_MS, "timeout")
		var local_name: String = lobby.get_local_name() if lobby != null and lobby.has_method("get_local_name") else "Player"
		_send(1, "hello", {"proto": Proto.PROTO, "pitt_version": String(version.get("pitt_version", "")),
			"pittapi_version": String(version.get("pittapi_version", "")), "mods_hash": String(version.get("mods_hash", "")),
			"mp_proto": int(version.get("mp_proto", Proto.PROTO)), "name": local_name, "platform_id": ""})
		_emit_state()


func _on_peer_connected(peer: int) -> void:
	_last_rx[peer] = clock.now()
	if role == "host":
		proto.reset_peer(peer)
		_hello_wait[peer] = clock.now()


func _on_peer_disconnected(peer: int) -> void:
	if role == "host":
		_drop_peer(peer, "left", false)


func _on_transport_closed(reason: String) -> void:
	if _tearing_down or state == "idle":
		return
	if role == "client":
		if reason == "connect_failed":
			_abort("connection_lost", "could not reach the host")
		else:
			_abort("connection_lost", reason)
	else:
		_abort("error", "transport closed: %s" % reason)


func _on_packet(peer: int, channel: int, bytes: PackedByteArray) -> void:
	if _tearing_down or state == "idle":
		return
	if role == "client" and peer != 1:
		return
	_last_rx[peer] = clock.now()
	var d: Dictionary = Codec.decode(bytes, proto.max_json())
	if String(d.get("error", "")) != "":
		proto._drop("decode:%s" % d.error, peer, {"k": "<frame>"})
		return
	match int(d.kind):
		Proto.FRAME_JSON, Proto.FRAME_ZJSON:
			var msg: Dictionary = d.msg
			var handshaken: bool = roster.has(peer) if role == "host" else my_peer > 0
			if proto.check_json(peer, channel, msg, handshaken, bytes.size()) != "":
				if role == "host" and proto.should_kick(peer):
					_kick(peer, "protocol", "rate limit")
				return
			if channel == Proto.CH_WORLD:
				_on_world_msg(peer, msg)
			elif role == "host":
				_host_on_msg(peer, msg)
			else:
				_client_on_msg(msg)
		Proto.FRAME_AVATAR:
			if channel != Proto.CH_AVATAR:
				return
			if role == "host":
				if roster.state_of(peer) != "in_game":
					return
				if proto.check_avatar(peer) != "":
					if proto.should_kick(peer):
						_kick(peer, "protocol", "rate limit")
					return
			elif state != "in_game":
				return
			_cache_avatar(peer, d.frame)
			avatars.on_frame(peer, d.frame, bytes)
		Proto.FRAME_BODIES, Proto.FRAME_HELD:
			if channel != Proto.CH_AVATAR:
				return
			if proto.check_raw(peer, int(d.kind)) != "":
				if role == "host" and proto.should_kick(peer):
					_kick(peer, "protocol", "rate limit")
				return
			if role == "host" and roster.state_of(peer) != "in_game":
				return
			if role == "client" and state != "in_game":
				return
			var m = _route_raw.get(int(d.kind), null)
			if m == null:
				counters.world_dropped += 1
				return
			if m.has_method("on_raw"):
				m.on_raw(peer if role == "host" else 1, int(d.kind), bytes)
		Proto.FRAME_CHUNK:
			if role == "client" and channel == Proto.CH_BULK:
				_client_on_chunk(d.chunk)


## The newest avatar frame per peer, for avatar_pose (host: the sender; client:
## the peer holding the frame's slot).
func _cache_avatar(peer: int, frame: Dictionary) -> void:
	var p := peer
	if role == "client":
		p = roster.peer_of_slot(int(frame.get("slot", 0)))
	if p <= 0 or p == my_peer:
		return
	var f := frame.duplicate()
	f["rx_ms"] = clock.now()
	_avatar_frames[p] = f


## A ch3 JSON message (MP2 2.2). Host: from an in-game peer, to its module.
## Client: buffered until the world snapshot is applied, then to its module.
func _on_world_msg(peer: int, msg: Dictionary) -> void:
	var k := String(msg.k)
	if role == "host":
		if roster.state_of(peer) != "in_game":
			counters.world_dropped += 1
			return
		_route_world(peer, k, msg)
		return
	if state in ["in_game", "ending"] and _world_flow == "done":
		_route_world(1, k, msg)
	elif state in ["loading", "in_game"] and _world_flow in ["requested", "applying"]:
		if _world_buffer.size() >= WORLD_BUFFER_MAX:
			_abort("protocol", "world message buffer overflow")
			return
		_world_buffer.append(msg)
		counters.world_buffered += 1
	else:
		counters.world_dropped += 1


func _route_world(peer: int, k: String, msg: Dictionary) -> void:
	var m = _route3.get(k, null)
	if m == null or not m.has_method("on_msg"):
		counters.world_dropped += 1
		return
	m.on_msg(peer, k, msg)


## ch0 module kinds (world_req / wsnap_* are the Session's own).
func _route_ch0(peer: int, k: String, msg: Dictionary) -> bool:
	var m = _route0.get(k, null)
	if m == null:
		return false
	var ok_state := state in ["in_game", "ending"]
	if role == "host":
		ok_state = roster.state_of(peer) == "in_game"
	if not ok_state:
		counters.world_dropped += 1
		return true
	if m.has_method("on_msg"):
		m.on_msg(peer, k, msg)
	return true


# ================================================================== host

func _host_on_msg(peer: int, msg: Dictionary) -> void:
	match String(msg.k):
		"hello":
			_host_on_hello(peer, msg)
		"bye":
			_drop_peer(peer, "left", true)
		"ping":
			_send(peer, "pong", {"t0": int(msg.get("t0", 0)), "host_ms": clock.now()})
		"pong":
			pass
		"join_req":
			_host_on_join_req(peer)
		"ready":
			_host_on_ready(peer, int(msg.get("xfer", 0)))
		"world_req":
			_host_on_world_req(peer)
		"cmd":
			var env = msg.get("env", null)
			var result: Dictionary
			if authority == null:
				result = {"ok": false, "value": null, "error": "no authority", "code": "ERR_UNAVAILABLE"}
			elif roster.state_of(peer) != "in_game":
				# lobby / loading peers have no world yet: no purchases
				result = {"ok": false, "value": null, "error": "commands need a loaded world", "code": "ERR_UNAVAILABLE"}
			else:
				result = authority.handle_remote(env, peer)
			flush_state()
			var id := 0
			if typeof(env) == TYPE_DICTIONARY and typeof(env.get("id", null)) == TYPE_INT:
				id = int(env.id)
			_send(peer, "res", {"id": id, "result": result})
			if authority != null and authority.remote_cheat_used and not bool(rules.cheats):
				_on_cheats_used()
		_:
			_route_ch0(peer, String(msg.k), msg)


func _host_on_hello(peer: int, msg: Dictionary) -> void:
	if roster.has(peer):
		return
	_hello_wait.erase(peer)
	var reason := ""
	var detail := ""
	if int(msg.get("proto", 0)) != Proto.PROTO or int(msg.get("mp_proto", Proto.PROTO)) != int(version.get("mp_proto", Proto.PROTO)):
		reason = "version"
		detail = "protocol %s, host %d" % [str(msg.get("proto", "?")), Proto.PROTO]
	elif String(msg.get("pitt_version", "")) != String(version.get("pitt_version", "")):
		reason = "version"
		detail = "game %s, host %s" % [msg.get("pitt_version", "?"), version.get("pitt_version", "?")]
	elif String(msg.get("pittapi_version", "")) != String(version.get("pittapi_version", "")):
		reason = "version"
		detail = "PittAPI %s, host %s" % [msg.get("pittapi_version", "?"), version.get("pittapi_version", "?")]
	elif String(msg.get("mods_hash", "")) != String(version.get("mods_hash", "")):
		reason = "mods"
		detail = "mods %s, host %s" % [msg.get("mods_hash", "?"), version.get("mods_hash", "?")]
	elif roster.is_full():
		reason = "full"
	elif host_state == "ending":
		reason = "ending"
	var platform: String = transport.platform_id_of(peer)
	if reason == "" and _needs_membership() and not _is_lobby_member(platform):
		# friends-only means lobby members only: anyone else who knows our SteamID
		# is refused (after a short wait, lobby_chat_update can trail the connect)
		if lobby.has_method("refresh_members"):
			lobby.refresh_members()
		if not _is_lobby_member(platform):
			if not _member_wait.has(peer):
				_member_wait[peer] = {"msg": msg, "until": clock.now() + member_wait_ms}
				return
			if clock.now() < int(_member_wait[peer].until):
				return
			reason = "protocol"
			detail = "not a member of the lobby"
	_member_wait.erase(peer)
	if reason != "":
		counters.rejected += 1
		_send(peer, "reject", {"reason": reason, "detail": detail})
		_flush_and_kick(peer)
		return
	var p: Dictionary = roster.add(peer, _peer_name(platform, String(msg.get("name", ""))), platform, false)
	if p.is_empty():
		_send(peer, "reject", {"reason": "full", "detail": ""})
		_flush_and_kick(peer)
		return
	_send(peer, "welcome", {"sid": sid, "peer": peer, "slot": int(p.slot), "roster": roster.to_array(),
		"host_state": host_state, "rules": rules.duplicate()})
	_emit_roster()
	_toast_all("MP_PEER_JOINED", {"name": p.name}, peer)
	_mod_event("peer_joined", {"peer": peer, "slot": int(p.slot), "name": String(p.name)})
	_log("info", "peer %d joined as slot %d (%s)" % [peer, int(p.slot), p.name])


## Names are facts the host takes from the lobby (Steam persona); the hello name
## is only used by lobbies without member names (dev / fake), never on Steam.
func _peer_name(platform_id: String, hello_name: String) -> String:
	if lobby != null and lobby.has_method("get_members"):
		for m in lobby.get_members():
			if typeof(m) == TYPE_DICTIONARY and String(m.get("id", "")) == platform_id and String(m.get("name", "")) != "":
				return String(m.name)
	if _needs_membership():
		return ""   # Roster names it "Player N"
	return hello_name


## Steam transport: peers are admitted only while they are in our Steam lobby.
func _needs_membership() -> bool:
	return transport != null and transport.has_method("kind") and String(transport.kind()) == "steam" \
		and lobby != null and lobby.has_method("get_members")


func _is_lobby_member(platform_id: String) -> bool:
	if not platform_id.is_valid_int():
		return false
	for m in lobby.get_members():
		if typeof(m) == TYPE_DICTIONARY and String(m.get("id", "")) == platform_id:
			return true
	return false


## Host: a peer whose SteamID left the lobby is removed from the session too.
func _on_members_changed(members: Array) -> void:
	if role != "host" or not _needs_membership() or _tearing_down or members.is_empty():
		return
	for p in roster.peers():
		if p == 1:
			continue
		var platform: String = String(roster.get_player(p).get("platform_id", ""))
		if platform == "":
			platform = transport.platform_id_of(p)
		if not _is_lobby_member(platform):
			_log("info", "peer %d left the Steam lobby: removed" % p)
			_kick(p, "kicked", "left the lobby")


func _host_on_join_req(peer: int) -> void:
	if not roster.has(peer) or roster.state_of(peer) != "connected":
		return
	if host_state == "ending":
		_send(peer, "bye", {"reason": "ending", "detail": ""})
		return
	for e in _join_queue:
		if int(e.peer) == peer:
			return
	_join_queue.append({"peer": peer, "at": clock.now()})


func _host_serve_joins(now: int) -> void:
	# waiting joins time out after 60 s while the host is starting / in a transition
	for i in range(_join_queue.size() - 1, -1, -1):
		var e: Dictionary = _join_queue[i]
		if now - int(e.at) > JOIN_WAIT_MS:
			_join_queue.remove_at(i)
			_send(int(e.peer), "bye", {"reason": "error", "detail": "join_timeout"})
	if host_state != "open" or not _serving.is_empty() or _join_queue.is_empty():
		return
	if not adapter.in_world() or adapter.get_phase() < 1 or adapter.get_phase() > 4:
		return
	var e2: Dictionary = _join_queue.pop_front()
	var peer := int(e2.peer)
	if not roster.has(peer):
		return
	var snap: Dictionary = snapshot.build(roster.slot_of(peer), sid, int(_out_q.get(peer, 0)))
	roster.set_state(peer, "loading")
	_serving[peer] = {"xfer": int(snap.xfer), "at": now}
	_send(peer, "snap_begin", {"xfer": int(snap.xfer), "bytes": snap.zbytes.size(), "raw": int(snap.raw_size),
		"chunks": snap.chunks.size(), "sha256": String(snap.sha256), "phase": int(snap.phase)})
	var i2 := 0
	for c in snap.chunks:
		transport.send(peer, Proto.CH_BULK, Codec.encode_chunk(int(snap.xfer), i2, c))
		i2 += 1
	_send(peer, "snap_end", {"xfer": int(snap.xfer)})
	counters.joins_served += 1
	_emit_roster()


func _host_on_ready(peer: int, xfer: int) -> void:
	if not roster.has(peer):
		return
	# only a peer we are serving a snapshot to, for THAT snapshot, enters the world
	if not _serving.has(peer) or int(_serving[peer].xfer) != xfer:
		_log("warn", "peer %d sent ready for xfer %d without being served it: ignored" % [peer, xfer])
		return
	if mp2_active() and not _world_cut.has(peer):
		_log("warn", "peer %d sent ready without a world snapshot: ignored" % peer)
		return
	_serving.erase(peer)
	_world_cut.erase(peer)
	roster.set_state(peer, "in_game")
	_refresh_peers()
	econ_host.send_full(peer)
	progression.host_send_all(peer)
	_send(peer, "rules", rules.duplicate())
	_emit_roster()
	_log("info", "peer %d is in the world (xfer %d)" % [peer, xfer])
	peer_world_ready.emit(peer)
	_module_call("on_peer_world_ready", [peer])


## MP2 3.7: the joiner's game world is loaded (no objects). Cut its ch3 stream
## here, build the world snapshot in this frame and send it on ch1; ch3
## messages after the cut flow to the peer from now on (it replays them after
## its apply).
func _host_on_world_req(peer: int) -> void:
	if not mp2_active() or not roster.has(peer) or roster.state_of(peer) != "loading" or not _serving.has(peer) \
			or _world_req_seen.has(peer):
		counters.world_req_refused += 1
		return
	_world_req_seen[peer] = true
	var t_build := Time.get_ticks_usec()
	var cut_q := int(_out_q3.get(peer, 0))
	var data := {"cut_q": cut_q, "host_ms": clock.now(), "sections": {}}
	for m in _modules:
		if m == null or not m.has_method("wsnap_section"):
			continue
		var s = m.wsnap_section()
		if typeof(s) != TYPE_DICTIONARY:
			continue
		if String(m.mod_name()) == "bodies":
			for k in s:
				data[k] = s[k]
		else:
			data.sections[String(m.mod_name())] = s
	var raw := JSON.stringify(data).to_utf8_buffer()
	if raw.size() > Proto.MAX_SNAPSHOT_RAW:
		_log("warn", "world snapshot for peer %d is %d bytes: join refused" % [peer, raw.size()])
		_send(peer, "bye", {"reason": "error", "detail": "MP_ERR_WORLD_TOO_BIG"})
		_drop_peer(peer, "world_too_big", false)
		_flush_and_kick(peer)
		return
	var z := Codec.zstd(raw)
	var chunks := Codec.split(z, Proto.CHUNK_SIZE)
	wsnap_stats = {"build_us": Time.get_ticks_usec() - t_build, "raw": raw.size(), "zstd": z.size(),
		"chunks": chunks.size(), "peer": peer}
	_wxfer += 1
	var xfer := WSNAP_XFER_BASE + _wxfer
	_world_cut[peer] = true
	_send(peer, "wsnap_begin", {"xfer": xfer, "bytes": z.size(), "raw": raw.size(), "chunks": chunks.size(),
		"sha256": Codec.sha256_hex(raw), "cut_q": cut_q})
	var i := 0
	for c in chunks:
		var se: Error = transport.send(peer, Proto.CH_BULK, Codec.encode_chunk(xfer, i, c))
		if se != OK:
			# a refused chunk (a full send buffer) would leave the joiner waiting out its
			# WSNAP timeout: fail the join now, with a reason
			counters.wsnap_send_failed += 1
			_log("warn", "world snapshot chunk %d/%d for peer %d refused (%s): join aborted" % [i, chunks.size(), peer,
				error_string(se)])
			_send(peer, "bye", {"reason": "error", "detail": "MP_ERR_WORLD_SEND"})
			_drop_peer(peer, "wsnap_send_failed", false)
			_flush_and_kick(peer)
			return
		i += 1
	_send(peer, "wsnap_end", {"xfer": xfer})
	counters.wsnaps_served += 1
	_log("info", "world snapshot for peer %d: %d bytes raw, %d zstd, cut_q %d" % [peer, raw.size(), z.size(), cut_q])


## World open for joins: phase >= 1, elevator done, no transition (R40, R4, R7).
func _host_check_open() -> void:
	if not (state in ["starting", "loading"]):
		return
	if not adapter.in_world() or adapter.get_phase() < 1 or not adapter.elevator_exited():
		return
	if adapter.get_phase() >= 5:
		return
	if not progression.host_phase_settled():
		return
	host_state = "open"
	roster.set_state(1, "in_game")
	_lobby_state("in_game")
	_set_state("in_game")
	_install_world_guards()
	avatars.start(1)
	_broadcast_session()
	_emit_roster()
	if mp2_active():
		_start_world()


## From progression: the host's phase began changing / settled.
func on_host_phase(kind: String, p: int) -> void:
	if role != "host":
		return
	if kind == "begin":
		if p >= 5:
			_stop_world("ending")
			if host_state != "ending":
				host_state = "ending"
				_lobby_state("ending")
				_set_state("ending")
				_broadcast_session()
				for e in _join_queue:
					_send(int(e.peer), "bye", {"reason": "ending", "detail": ""})
				_join_queue.clear()
		elif p >= 2 and host_state == "open":
			host_state = "transition"
			_broadcast_session()
	elif kind == "settled":
		if host_state == "transition" and adapter.get_phase() < 5:
			host_state = "open"
			_broadcast_session()


func _drop_peer(peer: int, why: String, graceful: bool) -> void:
	_hello_wait.erase(peer)
	_member_wait.erase(peer)
	_join_queue = _join_queue.filter(func(e): return int(e.peer) != peer)
	_serving.erase(peer)
	_world_cut.erase(peer)
	_world_req_seen.erase(peer)
	_avatar_frames.erase(peer)
	proto.forget_peer(peer)
	_out_q.erase(peer)
	_out_q3.erase(peer)
	_last_rx.erase(peer)
	if not roster.has(peer):
		return
	var p: Dictionary = roster.remove(peer)
	econ_host.forget_peer(peer)
	avatars.remove_slot(int(p.get("slot", 0)))
	_refresh_peers()
	_emit_roster()
	peer_left.emit(peer)
	_module_call("on_peer_left", [peer])
	_toast_all("MP_PEER_LEFT", {"name": String(p.get("name", ""))}, 0)
	_mod_event("peer_left", {"peer": peer, "slot": int(p.get("slot", 0)), "name": String(p.get("name", ""))})
	_log("info", "peer %d left (%s%s)" % [peer, why, "" if graceful else ", dropped"])


func _kick(peer: int, reason: String, detail: String) -> void:
	counters.kicked_rate += 1
	_send(peer, "bye", {"reason": "kicked" if reason != "protocol" else "error", "detail": detail})
	_drop_peer(peer, reason, false)
	_flush_and_kick(peer)


func _flush_and_kick(peer: int) -> void:
	if transport == null:
		return
	transport.poll()
	var t = transport
	get_tree().create_timer(float(BYE_FLUSH_MS) / 1000.0, true, false, true).timeout.connect(func():
		if t != null and t.is_open():
			t.kick(peer))


# ================================================================== client

func _client_on_msg(msg: Dictionary) -> void:
	match String(msg.k):
		"welcome":
			_client_on_welcome(msg)
		"reject":
			var r := String(msg.get("reason", "error"))
			_abort(r if r in END_REASONS else "error", String(msg.get("detail", "")))
		"bye":
			var r2 := String(msg.get("reason", "host_left"))
			var detail := String(msg.get("detail", ""))
			if detail == "join_timeout":
				_abort("timeout", detail)
			elif r2 in ["kicked", "ending"]:
				_abort(r2, detail)
			elif r2 == "error":
				_abort("protocol" if detail == "rate limit" else "error", detail)
			else:
				_abort("host_left", detail)
		"roster":
			roster.load_array(msg.get("roster", []))
			_emit_roster()
		"session":
			_client_on_host_state(String(msg.get("host_state", "")))
		"ping":
			_send(1, "pong", {"t0": int(msg.get("t0", 0)), "host_ms": clock.now()})
		"pong":
			clock.on_pong(int(msg.get("t0", 0)), int(msg.get("host_ms", 0)))
		"snap_begin":
			_rx = Snapshot.begin_receive(msg)
			if _rx == null:
				_abort("protocol", "bad snapshot header")
			else:
				# chunks travel on CH_BULK and may overtake this header (CH_CONTROL)
				var early := _early_chunks
				_early_chunks = []
				for c in early:
					_client_on_chunk(c)
		"snap_end":
			if _rx != null and int(msg.get("xfer", -1)) == _rx.xfer:
				_rx.ended = true
				_client_try_snapshot()
		"res":
			if authority != null:
				var res = msg.get("result", {})
				authority.on_result(int(msg.get("id", 0)), res if typeof(res) == TYPE_DICTIONARY else {})
		"grant":
			if state in ["in_game", "ending"]:
				purchases.on_grant(msg)
		"econ":
			if state in ["in_game", "ending"]:
				econ_client.on_econ(msg)
		"phase":
			if state in ["in_game", "ending"]:
				var p := int(msg.get("phase", 0))
				if p >= 5:
					_stop_world("ending")    # D16: replication stops, the local ending acts on local bodies
				progression.client_on_phase(String(msg.get("kind", "")), p)
				if p >= 5 and state == "in_game":
					_set_state("ending")
		"unlock":
			if state in ["in_game", "ending"]:
				progression.client_on_unlock(msg.get("ids", []))
		"hole":
			if state in ["in_game", "ending"]:
				progression.client_on_hole(msg)
		"toast":
			_show_toast(String(msg.get("key", "")), msg.get("args", {}))
		"rules":
			_client_on_rules(msg)
		"wsnap_begin":
			_client_on_wsnap_begin(msg)
		"wsnap_end":
			if _wrx != null and int(msg.get("xfer", -1)) == _wrx.xfer:
				_wrx.ended = true
				_client_try_wsnap()
		_:
			_route_ch0(1, String(msg.k), msg)


func _client_on_welcome(msg: Dictionary) -> void:
	if my_peer > 0:
		return
	my_peer = int(msg.get("peer", 0))
	sid = String(msg.get("sid", ""))
	proto.sid = sid
	if my_peer <= 1 or sid == "":
		_abort("protocol", "bad welcome")
		return
	roster.load_array(msg.get("roster", []))
	authority = MpAuthority.new(self, "client", my_peer)
	_install_authority()
	econ_client.my_peer = my_peer
	_client_on_rules(msg.get("rules", {}))
	# MP2 2.1: both sides must run the shared world with the same pool table
	var host_shared := String(rules.get("world", "")) == "shared"
	if host_shared != mp2_active():
		_abort("version", "shared world on the host: %s, here: %s" % [host_shared, mp2_active()])
		return
	if host_shared:
		var b = get_module("bodies")
		if b.has_method("check_welcome_rules"):
			var why := String(b.check_welcome_rules(rules))
			if why != "":
				_abort("version", why)
				return
	sub = "waiting"
	_clear_deadline()
	_emit_roster()
	_net_session_started()
	_client_on_host_state(String(msg.get("host_state", "lobby")))
	_emit_state()


func _client_on_rules(r: Variant) -> void:
	if typeof(r) != TYPE_DICTIONARY:
		return
	for k in r:
		if String(k) in ["k", "sid", "q", "client_earnings"]:
			continue
		rules[k] = r[k]
	if bool(rules.get("cheats", false)):
		achievements.on_cheats()


func _client_on_host_state(hs: String) -> void:
	if hs == "":
		return
	host_state = hs
	if lobby != null and lobby.has_method("set_remote_state"):
		lobby.set_remote_state({"lobby": "waiting", "starting": "starting", "open": "in_game",
			"transition": "in_game", "ending": "ending"}.get(hs, "waiting"))
	if state == "lobby" and sub == "waiting":
		if hs == "open" and not _join_requested:
			_join_requested = true
			_send(1, "join_req", {})
			_set_state("loading")
			_set_deadline(SNAPSHOT_TIMEOUT_MS + JOIN_WAIT_MS, "timeout")
		elif hs == "ending":
			_abort("ending", "")
			return
	_emit_state()


func _client_on_chunk(chunk: Dictionary) -> void:
	if int(chunk.xfer) >= WSNAP_XFER_BASE:
		_client_on_wchunk(chunk)
		return
	if _rx == null:
		if state == "loading" and not _launched and _early_chunks.size() < EARLY_CHUNKS_MAX:
			_early_chunks.append(chunk)
			counters.early_chunks += 1
		return
	if int(chunk.xfer) != _rx.xfer:
		return
	var i := int(chunk.index)
	if i < 0 or i >= _rx.chunks_total:
		return
	_rx.parts[i] = chunk.data
	_client_try_snapshot()


func _client_try_snapshot() -> void:
	if _rx == null or not _rx.complete():
		return
	var r: Dictionary = _rx.assemble()
	var xfer: int = _rx.xfer
	_rx = null
	if not bool(r.ok):
		_abort("protocol", "snapshot: %s" % r.error)
		return
	var bad: String = Snapshot.validate(r.data)
	if bad != "":
		_abort("protocol", "snapshot: %s" % bad)
		return
	_snap_data = r.data
	_snap_data["_xfer"] = xfer
	_client_launch(String(r.text), r.data)


## 9.2: isolate saves, write the encrypted session file, achievements step 1,
## detach UnlockManager, then the game's own load path.
func _client_launch(text: String, data: Dictionary) -> void:
	_session_file = Snapshot.session_path(_data_dir(), sid)
	var err: String = save_guard.enable(_session_file)
	if err != "":
		_abort("error", err)
		return
	if adapter.write_session_file(_session_file, text) != OK:
		_abort("error", "could not write the session file")
		return
	achievements.before_join_load()
	progression.detach_unlock_manager()
	_world_ready_seen = false
	_save_applied_seen = false
	var e: Error = adapter.launch_snapshot_world(int(data.get("phase", 1)))
	if e != OK:
		_abort("error", "could not launch the world (%s)" % error_string(e))
		return
	_launched = true
	_set_deadline(LOAD_TIMEOUT_MS, "timeout")
	_set_state("loading")


func _client_check_loaded() -> void:
	if role != "client" or state != "loading" or not _launched:
		return
	if not (_world_ready_seen and _save_applied_seen and adapter.in_world()):
		return
	if _pending_abort != "":
		return
	if mp2_active():
		# MP2 3.7: fetch the world snapshot first; ready goes out after its apply
		if _world_flow == "":
			_world_flow = "requested"
			_world_buffer = []
			_set_deadline(WSNAP_TIMEOUT_MS, "timeout")
			wsnap_stats = {"req_ms": Time.get_ticks_msec()}
			_send(1, "world_req", {})
		return
	_clear_deadline()
	_client_enter_world()


func _client_enter_world() -> void:
	achievements.after_join_load()
	_install_world_guards()
	avatars.start(roster.slot_of(my_peer))
	_set_state("in_game")
	_send(1, "ready", {"xfer": int(_snap_data.get("_xfer", 0))})
	if mp2_active():
		_start_world()


var _early_wchunks: Array = []


func _client_on_wsnap_begin(msg: Dictionary) -> void:
	if _world_flow != "requested" or _wrx != null:
		return
	_wrx = Snapshot.begin_receive(msg)
	if _wrx == null:
		_abort("protocol", "bad world snapshot header")
		return
	_wcut_q = int(msg.get("cut_q", 0))
	var early := _early_wchunks
	_early_wchunks = []
	for c in early:
		_client_on_wchunk(c)


func _client_on_wchunk(chunk: Dictionary) -> void:
	if _world_flow != "requested":
		return
	if _wrx == null:
		if _early_wchunks.size() < EARLY_CHUNKS_MAX:
			_early_wchunks.append(chunk)
			counters.early_chunks += 1
		return
	if int(chunk.xfer) != _wrx.xfer:
		return
	var i := int(chunk.index)
	if i < 0 or i >= _wrx.chunks_total:
		return
	_wrx.parts[i] = chunk.data
	_client_try_wsnap()


func _client_try_wsnap() -> void:
	if _wrx == null or not _wrx.complete():
		return
	var r: Dictionary = _wrx.assemble()
	_wrx = null
	if not bool(r.ok):
		_abort("protocol", "world snapshot: %s" % r.error)
		return
	var data: Dictionary = Codec.normalize_wsnap(r.data)
	wsnap_stats["rx_ms"] = Time.get_ticks_msec() - int(wsnap_stats.get("req_ms", Time.get_ticks_msec()))
	_world_flow = "applying"
	_wapply_started_ms = clock.now()
	_set_deadline(WSNAP_APPLY_TIMEOUT_MS, "timeout")
	var sections: Dictionary = data.get("sections", {}) if typeof(data.get("sections", {})) == TYPE_DICTIONARY else {}
	for m in _modules:
		if m == null or not m.has_method("apply_wsnap_section"):
			continue
		var n := String(m.mod_name())
		if n == "bodies":
			m.apply_wsnap_section(data)
		else:
			var s = sections.get(n, {})
			m.apply_wsnap_section(s if typeof(s) == TYPE_DICTIONARY else {})
	_client_poll_wsnap_apply()


## Every module finished its (batched) apply: replay the buffered ch3 messages
## after the cut in order, then enter the world and send ready.
func _client_poll_wsnap_apply() -> void:
	if _world_flow != "applying":
		return
	for m in _modules:
		if m != null and m.has_method("wsnap_apply_done") and not bool(m.wsnap_apply_done()):
			return
	_clear_deadline()
	_world_flow = "done"
	var buf := _world_buffer
	_world_buffer = []
	buf.sort_custom(func(a, b): return int(a.get("q", 0)) < int(b.get("q", 0)))
	for msg in buf:
		if int(msg.get("q", 0)) <= _wcut_q:
			continue
		_route_world(1, String(msg.k), msg)
	wsnap_stats["apply_ms"] = clock.now() - _wapply_started_ms
	wsnap_stats["total_ms"] = Time.get_ticks_msec() - int(wsnap_stats.get("req_ms", Time.get_ticks_msec()))
	_log("info", "world snapshot applied in %d ms (%d buffered message(s) replayed)" % [clock.now() - _wapply_started_ms,
		buf.size()])
	_client_enter_world()


# ================================================================== world events

func _on_world_ready(_info: Dictionary) -> void:
	if role == "host":
		progression.host_reset()
		if state == "starting":
			_set_state("loading")
	elif state == "loading":
		_world_ready_seen = true


func _on_save_applied() -> void:
	if role == "client" and state == "loading":
		_save_applied_seen = true


func _on_phase_settled(p: int) -> void:
	if role == "host" and state in ["loading", "in_game", "ending"]:
		progression.host_on_settled(p)


func _on_world_exited() -> void:
	if state == "idle" or _tearing_down:
		return
	if role == "host" and state in ["loading", "in_game", "ending"]:
		# D7: the host leaving the world ends the session and the lobby
		var why := "ending" if state == "ending" or adapter.get_phase() >= 5 else "left"
		_leave(why, "", false)
	elif role == "client" and state in ["in_game", "ending"]:
		_leave("ending" if state == "ending" else "left", "", false)


# ================================================================== per frame

func _process(_delta: float) -> void:
	var now: int = clock.now()
	if not _save_hold.is_empty():
		_tick_save_hold(now)
	if _closing_transport != null and now >= _closing_at:
		_closing_transport.close("left")
		_closing_transport = null
	if _closing_transport != null:
		_closing_transport.poll()
	if transport == null or state == "idle":
		return
	transport.poll()
	if transport == null or state == "idle":
		return
	if _pending_abort != "":
		_try_pending_abort(now)
		return
	if _deadline_ms > 0 and now >= _deadline_ms:
		var why := _deadline_reason
		_clear_deadline()
		_abort(why, "deadline")
		return
	if authority != null:
		authority.tick(now)
	if now - _last_ping_ms >= PING_INTERVAL_MS:
		_last_ping_ms = now
		_ping_and_check_silence(now)
		if state == "idle":
			return
	if role == "host":
		_host_tick(now)
	else:
		_client_tick(now)
	_check_start_availability()


## Client after a session: isolation stays on while the host's world copy can
## still autosave; once the world is gone (or never appeared) it is released.
func _tick_save_hold(now: int) -> void:
	if adapter == null:
		_release_save_hold()
		return
	if adapter.in_world():
		_save_hold.world_seen = true
		if state == "idle" and now >= int(_save_hold.next_try):
			_save_hold.next_try = now + SAVE_HOLD_MENU_RETRY_MS
			_log("info", "left the session while in the host's world: returning to the main menu")
			if not adapter.return_to_main_menu() and adapter.has_method("force_main_menu"):
				adapter.force_main_menu()
		return
	var on_menu: bool = adapter.on_main_menu()
	if (bool(_save_hold.world_seen) and on_menu) or now >= int(_save_hold.until):
		_release_save_hold()


func _release_save_hold() -> void:
	_save_hold = {}
	save_guard.disable()


func save_hold_active() -> bool:
	return not _save_hold.is_empty()


func _host_tick(now: int) -> void:
	for p in _member_wait.keys():
		if not _member_wait.has(p):
			continue
		var w: Dictionary = _member_wait[p]
		if roster.has(p):
			_member_wait.erase(p)
		elif _is_lobby_member(transport.platform_id_of(p)) or now >= int(w.until):
			_host_on_hello(p, w.msg)
	for p in _hello_wait.keys():
		if now - int(_hello_wait[p]) > HELLO_TIMEOUT_MS:
			_hello_wait.erase(p)
			transport.kick(p)
	if state in ["loading", "in_game", "ending"]:
		progression.host_tick(now)
	_host_check_open()
	if state in ["in_game", "ending"]:
		_host_serve_joins(now)
		econ_host.tick(now)
		avatars.tick(now)
		pause_guard.tick()
	for p in _serving.keys():
		if now - int(_serving[p].at) > SNAPSHOT_TIMEOUT_MS + LOAD_TIMEOUT_MS + WSNAP_APPLY_TIMEOUT_MS:
			_kick(p, "timeout", "join took too long")
	_module_call("tick", [now])


func _client_tick(now: int) -> void:
	_client_check_loaded()
	_client_poll_wsnap_apply()
	if state in ["in_game", "ending"]:
		econ_client.tick(now)
		avatars.tick(now)
		pause_guard.tick()
	_module_call("tick", [now])


func _ping_and_check_silence(now: int) -> void:
	if role == "host":
		for p in roster.peers():
			if p == 1:
				continue
			_send(p, "ping", {"t0": now})
			var limit := SILENCE_LOADING_MS if roster.state_of(p) == "loading" else SILENCE_TIMEOUT_MS
			if now - int(_last_rx.get(p, now)) > limit:
				_log("warn", "peer %d silent for %d ms: dropped" % [p, now - int(_last_rx.get(p, now))])
				_drop_peer(p, "silence", false)
				transport.kick(p)
	elif my_peer > 0 or sub == "handshake":
		_send(1, "ping", {"t0": now})
		var limit2 := SILENCE_LOADING_MS if state == "loading" else SILENCE_TIMEOUT_MS
		if now - int(_last_rx.get(1, now)) > limit2:
			_abort("connection_lost", "host silent")


# ================================================================== leave / abort / teardown

## A remote failure. During LOADING (world launched, not ready) the teardown
## waits for a safe point: world ready, the load failed, or the deadline (R23).
func _abort(reason: String, detail: String) -> void:
	if state == "idle" or _tearing_down:
		return
	if role == "client" and state == "loading" and _launched and not (_world_ready_seen and _save_applied_seen):
		if _pending_abort == "":
			_pending_abort = reason
			_pending_abort_detail = detail
			if _deadline_ms == 0:
				_set_deadline(LOAD_TIMEOUT_MS, "timeout")
		return
	_leave(reason, detail, true)


func _try_pending_abort(now: int) -> void:
	# (the main menu stays the current scene while LoadingScreen works, so "on
	# the main menu" is not a safe point; a failed load ends at the deadline)
	var safe: bool = (_world_ready_seen and _save_applied_seen) or (_deadline_ms > 0 and now >= _deadline_ms)
	if safe:
		var r := _pending_abort
		var d := _pending_abort_detail
		_pending_abort = ""
		_pending_abort_detail = ""
		_leave(r, d, true)


## 4.6, one idempotent function.
func _leave(reason: String, detail: String, return_to_menu: bool) -> void:
	if _tearing_down:
		return
	if state == "idle" and transport == null:
		if lobby != null and lobby.has_method("is_in_lobby") and lobby.is_in_lobby():
			_tearing_down = true
			lobby.leave()
			_tearing_down = false
		return
	_tearing_down = true
	var was_role := role
	var was_in_world: bool = adapter != null and adapter.in_world()
	if not (reason in END_REASONS):
		reason = "error"
	# 1. not live: extensions go inert
	_set_state("closing")
	# 2. pending commands fail
	if authority != null:
		authority.fail_all("the session ended")
	# 3. bye (best effort), close after a short flush (the MP2 world stops first,
	# so modules can still send their last ch3 messages)
	_stop_world(reason)
	if transport != null:
		if was_role == "host":
			var bye_reason := "ending" if reason == "ending" else "host_left"
			for p in roster.peers():
				if p != 1:
					_send(p, "bye", {"reason": bye_reason, "detail": ""})
		elif my_peer > 0 and not (reason in ["host_left", "connection_lost", "kicked"]):
			_send(1, "bye", {"reason": "left", "detail": ""})
		transport.poll()
		for s in transport.closed.get_connections():
			transport.closed.disconnect(s.callable)
		_closing_transport = transport
		_closing_at = clock.now() + BYE_FLUSH_MS
		if not is_inside_tree():
			_closing_transport.close("left")
			_closing_transport = null
		transport = null
	# 3b. MP2 modules, reverse registration order (10.1)
	_modules_teardown()
	# 4. restore the game: UnlockManager, InputMap, camera, movement lock
	pause_guard.uninstall()
	input_guard.uninstall()
	if adapter != null:
		adapter.session_teardown()
	# 5. back to LocalAuthority
	if api != null and "net" in api and api.net != null:
		api.net.uninstall_authority()
		api.net.emit_session_ended(reason)
	authority = null
	# 6. saves back, session file deleted - but a client whose world is (or may
	# still become) the host's copy keeps isolation until that world is gone
	var hold_saves: bool = was_role == "client" and save_guard.active and (was_in_world or _launched)
	if hold_saves:
		_save_hold = {"until": clock.now() + SAVE_HOLD_MAX_MS, "world_seen": was_in_world, "next_try": 0}
	else:
		save_guard.disable()
	achievements.reset()
	# 7. no slow motion / pause left behind
	if was_role == "client" or not was_in_world:
		Engine.time_scale = 1.0
		if is_inside_tree() and (was_role == "client" or not was_in_world):
			get_tree().paused = false
	# 8. puppets
	avatars.stop()
	# 9. lobby (the host marks it ending first: not joinable, no stale row while
	# Steam hands ownership to a remaining member)
	if was_role == "host":
		_lobby_state("ending")
	if lobby != null and lobby.has_method("leave"):
		lobby.leave()
	_last_end = {"reason": reason, "detail": detail}
	var r := reason
	_reset_vars()
	_set_state("idle")
	_tearing_down = false
	_emit_roster()
	_mod_event("ended", {"reason": r, "detail": detail})
	ended.emit(r, detail)
	# 10. clients in a world go back through the game's full reset
	if return_to_menu and was_role == "client" and was_in_world and adapter != null:
		if not adapter.return_to_main_menu() and adapter.has_method("force_main_menu"):
			adapter.force_main_menu()
	# a client that left without returning to the menu (world exit already under
	# way, or the world still loading) is handled by the save hold


func _reset_vars() -> void:
	role = ""
	sub = ""
	host_state = ""
	sid = ""
	my_peer = 0
	roster.clear()
	_out_q.clear()
	_last_rx.clear()
	_hello_wait.clear()
	_member_wait.clear()
	_join_queue.clear()
	_serving.clear()
	_join_requested = false
	_rx = null
	_early_chunks = []
	_snap_data = {}
	_session_file = ""
	_launched = false
	_world_ready_seen = false
	_save_applied_seen = false
	_pending_abort = ""
	_clear_deadline()
	rules = {"achievements": String(rules.get("achievements", "presence")), "cheats": false}
	econ_host.reset()
	econ_client.reset()
	snapshot.invalidate()
	_world_live = false
	_avatar_frames.clear()
	_out_q3.clear()
	_world_cut.clear()
	_world_req_seen.clear()
	_world_flow = ""
	_wrx = null
	_wcut_q = 0
	_world_buffer = []
	_early_wchunks = []


func _exit_tree() -> void:
	if is_live():
		_leave("left", "", false)
	if _closing_transport != null:
		_closing_transport.close("left")
		_closing_transport = null


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and is_live():
		_leave("left", "", false)
		if _closing_transport != null:
			_closing_transport.poll()
			_closing_transport.close("left")
			_closing_transport = null


# ================================================================== helpers used by modules

func send_msg(peer: int, k: String, body: Dictionary = {}) -> Error:
	return _send(peer, k, body)


func _send(peer: int, k: String, body: Dictionary) -> Error:
	if transport == null:
		return ERR_UNCONFIGURED
	var msg := body.duplicate()
	msg["k"] = k
	msg["sid"] = sid
	var q := int(_out_q.get(peer, 0)) + 1
	_out_q[peer] = q
	msg["q"] = q
	var bytes := Codec.encode_json(msg)
	var cap := Proto.MAX_H2C_JSON if role == "host" else Proto.MAX_C2H_JSON
	if bytes.size() > cap + 8:
		_log("warn", "message %s too large (%d bytes): not sent" % [k, bytes.size()])
		return ERR_OUT_OF_MEMORY
	proto.log_tx(peer, msg)
	return transport.send(peer, Proto.CH_CONTROL, bytes)


func send_raw(peer: int, channel: int, bytes: PackedByteArray) -> Error:
	if transport == null:
		return ERR_UNCONFIGURED
	return transport.send(peer, channel, bytes)


## The local player's frame: host -> every in-game client; client -> host.
func send_avatar(bytes: PackedByteArray) -> void:
	if transport == null:
		return
	if role == "host":
		for p in in_game_peers():
			transport.send(p, Proto.CH_AVATAR, bytes)
	else:
		transport.send(1, Proto.CH_AVATAR, bytes)


## Client: forwards a command envelope to the host (MpAuthority).
func send_cmd(envelope: Dictionary) -> bool:
	if role != "client" or my_peer <= 0 or transport == null:
		return false
	return _send(1, "cmd", {"env": envelope}) == OK


func in_game_peers() -> Array:
	if role != "host":
		return []
	return roster.peers_in_state("in_game")


func slot_of(peer: int) -> int:
	return roster.slot_of(peer)


func player_by_slot(slot: int) -> Dictionary:
	var p: int = roster.peer_of_slot(slot)
	return roster.get_player(p) if p != 0 else {}


func host_now() -> int:
	return clock.host_now()


func register_puppet(node: Node, peer: int) -> void:
	if api != null and "net" in api and api.net != null and peer > 0:
		api.net.register_remote_player(node, peer)


func unregister_puppet(peer: int) -> void:
	if api != null and "net" in api and api.net != null and peer > 0:
		api.net.unregister_remote_player(peer)


func begin_apply() -> void:
	if api != null and "net" in api and api.net != null:
		api.net.begin_apply(1)


func end_apply() -> void:
	if api != null and "net" in api and api.net != null:
		api.net.end_apply()


func execute_command(name: String, args: Dictionary) -> Object:
	if api == null or not ("commands" in api) or api.commands == null:
		return null
	return api.commands.execute(name, args)


## Host: before every command result, pending state goes out first (R20).
func flush_state() -> void:
	if role == "host" and state in ["in_game", "ending"]:
		progression.host_tick(clock.now())
		econ_host.flush()


func log_info(msg: String) -> void:
	_log("info", msg)


func log_warn(msg: String) -> void:
	_log("warn", msg)


func _log(level: String, msg: String) -> void:
	log_lines.append("%d %s %s" % [Time.get_ticks_msec(), level, msg])
	if log_lines.size() > 200:
		log_lines.pop_front()
	if api != null and "log" in api and api.log != null:
		if level == "warn":
			api.log.warn(msg)
		else:
			api.log.info(msg)


func _data_dir() -> String:
	if config.has("data_dir"):
		return String(config.data_dir)
	if api != null and api.has_method("data_dir"):
		return api.data_dir()
	return "user://pittapi/mods/PittMultiplayer"


func _install_authority() -> void:
	if api != null and "net" in api and api.net != null and authority != null:
		var err: Error = api.net.install_authority(authority)
		if err != OK:
			_log("warn", "install_authority failed: %s" % error_string(err))
	_refresh_peers()


func _refresh_peers() -> void:
	if authority != null:
		authority.set_peers(roster.peers())


func _net_session_started() -> void:
	if api != null and "net" in api and api.net != null:
		api.net.emit_session_started({"role": role, "sid": sid, "transport": transport.kind() if transport != null else "",
			"local_peer": my_peer})
	_modules_session_start()
	if role == "host" and mp2_active():
		# MP2 2.1: welcome.rules gains the shared-world rules (pools, budget, tick)
		rules["world"] = "shared"
		var b = get_module("bodies")
		if b.has_method("welcome_rules"):
			var wr = b.welcome_rules()
			if typeof(wr) == TYPE_DICTIONARY:
				for k in wr:
					rules[k] = wr[k]


func _install_world_guards() -> void:
	pause_guard.install()
	input_guard.install(role)


func _lobby_state(s: String) -> void:
	if role == "host" and lobby != null and lobby.has_method("set_state"):
		lobby.set_state(s)


func _broadcast_session() -> void:
	if role != "host":
		return
	for p in roster.peers():
		if p != 1:
			_send(p, "session", {"host_state": host_state})
	_emit_state()


func _toast_all(key: String, args: Dictionary, except_peer: int) -> void:
	if role != "host":
		return
	for p in roster.peers_in_state("in_game"):
		if p != except_peer:
			_send(p, "toast", {"key": key, "args": args})
	_show_toast(key, args)


func _show_toast(key: String, args: Variant) -> void:
	if key == "" or not key.begins_with("MP_"):
		return
	if api == null or not ("hud" in api) or api.hud == null:
		return
	var text := tr(key)
	if typeof(args) == TYPE_DICTIONARY:
		text = text.format(args)
	api.hud.toast(text)


func _on_command_executed(ev) -> void:
	if role != "host" or not is_live() or bool(rules.cheats):
		return
	var p: Dictionary = ev.payload
	if not bool(p.get("ok", false)):
		return
	var d: Dictionary = api.commands.describe(String(p.get("name", "")))
	if bool(d.get("cheat", false)):
		_on_cheats_used()


## A cheat succeeded on the host: every peer suppresses achievements (8.4).
func _on_cheats_used() -> void:
	rules.cheats = true
	achievements.on_cheats()
	# lobby data cheats=1 tags the Join row (needs the UI stream's optional setter)
	if lobby != null and lobby.has_method("set_lobby_data"):
		lobby.set_lobby_data("cheats", "1")
	for p in roster.peers():
		if p != 1:
			_send(p, "rules", {"cheats": true})


func _set_deadline(ms: int, reason: String) -> void:
	_deadline_ms = clock.now() + ms
	_deadline_reason = reason


func _clear_deadline() -> void:
	_deadline_ms = 0
	_deadline_reason = ""


func _set_state(s: String) -> void:
	if state == s:
		_emit_state()
		return
	state = s
	_emit_state()
	_mod_event("session", {"state": state, "role": role})
	_check_start_availability()


## mod.PittMultiplayer.<name> events for other mods (3.3).
func _mod_event(ev_name: String, payload: Dictionary) -> void:
	if api != null and "events" in api and api.events != null and api.events.has_method("emit"):
		api.events.emit("mod.PittMultiplayer." + ev_name, payload)


func _emit_state() -> void:
	state_changed.emit(state, get_info())


func _emit_roster() -> void:
	var r: Array = roster.to_array()
	avatars.on_roster(r)
	roster_changed.emit(r)
	if role == "host" and transport != null:
		for p in roster.peers():
			if p != 1:
				_send(p, "roster", {"roster": r})
	if api != null and "net" in api and api.net != null:
		api.net.emit_peers_changed(r)


func _check_start_availability() -> void:
	var c := can_start()
	var key := "%s|%s" % [c.ok, c.reason]
	if key != _start_ok_prev:
		_start_ok_prev = key
		start_availability_changed.emit(bool(c.ok), String(c.reason))


# ================================================================== command handlers (host)

func _host_buy(ctx, f: Callable, args: Dictionary) -> Variant:
	if role != "host" or not (state in ["in_game", "ending"]) or not adapter.in_world():
		return ctx.fail("purchases need the host's running world", "ERR_UNAVAILABLE")
	var r: Dictionary = f.call(args)
	if not bool(r.get("ok", false)):
		return ctx.fail(String(r.get("error", "refused")), String(r.get("code", "ERR_FAILED")))
	var value = r.get("value", {})
	# MP1 (private worlds) told the buyer to spawn the item with a "grant". MP2
	# (3.8, D11): the item spawns once on the host and replicates as an entity.
	if not mp2_active() and ctx.is_remote and ctx.origin_peer != 1 and typeof(value) == TYPE_DICTIONARY \
			and (value.has("tool") or value.has("toy")):
		var g := {"id": int(ctx.cmd_id)}
		if value.has("tool"):
			g["tool"] = String(value.tool)
			g["level"] = int(value.get("level", 0))
		else:
			g["toy"] = String(value.toy)
		_send(ctx.origin_peer, "grant", g)
	return value


func _cmd_buy_item(args: Dictionary, ctx) -> Variant:
	return _host_buy(ctx, purchases.host_buy_item, args)


func _cmd_buy_tool(args: Dictionary, ctx) -> Variant:
	return _host_buy(ctx, purchases.host_buy_tool, args)


func _cmd_buy_toy(args: Dictionary, ctx) -> Variant:
	return _host_buy(ctx, purchases.host_buy_toy, args)


# ================================================================== extension hooks (via Engine meta "pitt_mp")

func ext_live() -> bool:
	return is_live() and not _tearing_down


func ext_role() -> String:
	return role if ext_live() else ""


## Clients never complete phases or trigger the ending from their own hole.
func ext_block_hole_progress() -> bool:
	return role == "client" and ext_live()


func ext_rewire_row(ui: Object, row: Object, kind: String, args: Dictionary) -> bool:
	if role != "client" or not ext_live():
		return false
	return purchases.rewire(ui, row, kind, args)


## pause_menu_ext._return_to_main_menu: leave first; the game resets after.
func ext_on_return_to_menu() -> void:
	if ext_live():
		_leave("left", "", false)


# ================================================================== debug

## Dev/tests: send-side conditioning on the live transport ({} turns it off).
func set_conditioning(cond: Dictionary) -> void:
	config["conditioning"] = cond
	if transport != null and transport.has_method("set_conditioning"):
		transport.set_conditioning(cond)


func dump() -> Dictionary:
	return {"state": state, "role": role, "sub": sub, "host_state": host_state, "sid": sid, "my_peer": my_peer,
		"roster": roster.to_array(), "rtt_ms": clock.rtt_ms, "offset_ms": clock.offset_ms,
		"drops": proto.drop_counts.duplicate(), "ring": proto.ring.slice(-40),
		"transport": transport.stats.duplicate() if transport != null else {},
		"pending_cmds": authority.pending_count() if authority != null else 0,
		"econ": {"deltas": econ_host.sent_deltas, "fulls": econ_host.sent_fulls, "applied": econ_client.applied,
			"local_money_writes": econ_client.local_money_writes},
		"avatars": {"tx": avatars.frames_tx, "rx": avatars.frames_rx, "relayed": avatars.relayed,
			"puppets": avatars.puppet_count()},
		"mp2": {"modules": _mod_by_name.keys(), "world_live": _world_live, "world_flow": _world_flow,
			"world_peers": world_peers() if role != "" else []},
		"counters": counters_all(), "net": net_stats(), "log": log_lines.slice(-30)}
