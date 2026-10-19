extends "transport.gd"
## Steam transport: GodotSteam's SteamMultiplayerPeer (a MultiplayerPeerExtension)
## used through the same raw packet API as ENet. The only file that touches
## SteamMultiplayerPeer. Created through ClassDB so this script also compiles
## where GodotSteam is absent (headless tests); every call is guarded.
##
## Signatures pinned by spike S2 (GodotSteam bundled with v1.0.8):
##   create_host(virtual_port: int) -> int, create_client(steam_id: int, virtual_port: int) -> int,
##   host_with_lobby(lobby_id: int) -> int, connect_to_lobby(lobby_id: int) -> int,
##   get_steam_id_for_peer_id(peer_id: int) -> int
## target: {kind:"steam", role, lobby_id: String, host_steam_id: String}
## mode "socket" (default): create_host(0) / create_client(host, 0).
## mode "lobby": host_with_lobby(lobby) / connect_to_lobby(lobby).
## no_nagle = true on every peer (property present in the bundled GodotSteam).
## Lanes: the bundled GodotSteam 4.19.1 sends a channel >= max_channels - 1 on
## lane 0 (the game sets max_channels=4, so only lanes 0-2 work); the base
## transport's lane map (lane_map, on by default) puts CH_WORLD on lane 1 with a
## one-byte channel tag. v0.2.0 sent CH_WORLD on lane 3: it arrived on lane 0 and
## was dropped (kind_not_allowed), so clients saw no spawns and no grant/interact.
## Send rate: SteamNetworkingSockets paces every connection to its SendRateMin /
## SendRateMax clamp and queues (never drops) what is over it, so a body budget
## that probes above the clamp (budget.gd ceiling, up to 400 KB/s) would only
## grow Steam's queue. The bundled GodotSteam 4.19.1 exposes no per-connection
## handle on SteamMultiplayerPeer (its properties are no_delay, no_nagle,
## server_relay, debug_level), but the Steam singleton has
## setGlobalConfigValueInt32(NetworkingConfigValue, int) -> bool and the enum
## values NETWORKING_CONFIG_SEND_RATE_MIN / _MAX (both found in the bundled
## DLL's method binds and constant names). The global value is set before
## create_host / create_client, so every connection made after it inherits it.
## Min and max get the same value (the Steamworks header advises setting both
## to configure a send rate; we found no header in reach to confirm whether
## this build estimates bandwidth between them). Because a fixed rate also
## paces the reliable bursts outside the body budget (world-snapshot chunks),
## it is raised only as far as the host's physics_detail needs: the probe
## ceiling plus SEND_RATE_HEADROOM_BPS, and only when that is above the about
## 256 KB/s the Steamworks documentation gives as the default (in practice
## only "high", ceiling 288 KB/s). Below that Steam's own setting stays. The
## value is process-wide, so a later session with a lower need puts it back to
## STEAM_DEFAULT_SEND_RATE_BPS. budget.gd stays the congestion brake.

const VIRTUAL_PORT := 0
## avatars, control, econ and the world stream on top of the body probe ceiling
const SEND_RATE_HEADROOM_BPS := 64000
## the send rate the Steamworks documentation gives as SteamNetworkingSockets' default
const STEAM_DEFAULT_SEND_RATE_BPS := 262144
const Budget = preload("../world/bodies/budget.gd")

var mode := "socket"
## the host's physics_detail ("" on a client: its uplink carries little, Steam's rate stays)
var physics_detail := ""
var _relay_inited := false
## the send-rate clamp in effect when this transport opened (0: Steam's own)
var send_rate_bps := 0
## process-wide: the rate currently set through the global config (0: never touched)
static var _applied_rate := 0


func kind() -> String:
	return "steam"


static func available() -> bool:
	return ClassDB.class_exists("SteamMultiplayerPeer") and Engine.has_singleton("Steam")


func _steam_ready() -> bool:
	if not available():
		return false
	var tree := Engine.get_main_loop() as SceneTree
	var sw = tree.root.get_node_or_null("Steamworks") if tree != null else null
	return sw != null and bool(sw.get("is_steam_initialized"))


func _init_relay() -> void:
	if _relay_inited:
		return
	_relay_inited = true
	var steam = Engine.get_singleton("Steam")
	if steam != null and steam.has_method("initRelayNetworkAccess"):
		steam.initRelayNetworkAccess()
	var want := send_rate_target(physics_detail, _applied_rate)
	if want > 0 and want != _applied_rate and apply_send_rate(steam, steam_const("NETWORKING_CONFIG_SEND_RATE_MIN"),
			steam_const("NETWORKING_CONFIG_SEND_RATE_MAX"), want):
		_applied_rate = want
	# also when an earlier session in this process set it (still in force, logged again)
	send_rate_bps = _applied_rate
	stats["send_rate"] = send_rate_bps


## The rate to set for `detail` ("" = no need): the probe ceiling plus the
## headroom when that is above Steam's default; else 0 (leave Steam alone), or
## the default when an earlier session in this process raised it (`applied`).
static func send_rate_target(detail: String, applied: int) -> int:
	var need := 0
	if detail != "":
		need = Budget.ceiling_for(Budget.detail_bps(detail)) + SEND_RATE_HEADROOM_BPS
	if need > STEAM_DEFAULT_SEND_RATE_BPS:
		return need
	return STEAM_DEFAULT_SEND_RATE_BPS if applied > 0 else 0


## A Steam class constant through ClassDB (-1 when GodotSteam is absent), so this
## script parses and runs headless without the Steam class.
static func steam_const(const_name: String) -> int:
	if ClassDB.class_exists("Steam") and ClassDB.class_has_integer_constant("Steam", const_name):
		return ClassDB.class_get_integer_constant("Steam", const_name)
	return -1


## Sets the global SendRateMin and SendRateMax on `steam` (the Steam singleton,
## or a test double). True when both calls exist and both returned true.
static func apply_send_rate(steam: Object, key_min: int, key_max: int, rate: int) -> bool:
	if steam == null or key_min < 0 or key_max < 0 or not steam.has_method("setGlobalConfigValueInt32"):
		return false
	# max first: a min above the current max could be refused
	var ok_max := bool(steam.call("setGlobalConfigValueInt32", key_max, rate))
	var ok_min := bool(steam.call("setGlobalConfigValueInt32", key_min, rate))
	return ok_max and ok_min


func _make_peer() -> MultiplayerPeer:
	if not _steam_ready():
		return null
	var p = ClassDB.instantiate("SteamMultiplayerPeer")
	# avatars and body frames are latency-bound: no Nagle delay (about 5 ms) on any
	# send (GodotSteam: k_nSteamNetworkingSend_NoNagle). no_delay stays off: it would
	# drop a message rather than queue it.
	if p != null and "no_nagle" in p:
		p.set("no_nagle", true)
	return p as MultiplayerPeer


func _create_host(target: Dictionary) -> Error:
	var p := _make_peer()
	if p == null:
		return ERR_UNAVAILABLE
	_init_relay()
	var m := String(target.get("steam_mode", mode))
	var err := ERR_UNAVAILABLE
	if m == "lobby" and p.has_method("host_with_lobby") and String(target.get("lobby_id", "")).is_valid_int():
		err = int(p.call("host_with_lobby", String(target.lobby_id).to_int()))
	elif p.has_method("create_host"):
		err = int(p.call("create_host", VIRTUAL_PORT))
	if err != OK:
		return err
	_peer = p
	return OK


func _create_client(target: Dictionary) -> Error:
	var p := _make_peer()
	if p == null:
		return ERR_UNAVAILABLE
	_init_relay()
	var m := String(target.get("steam_mode", mode))
	var err := ERR_UNAVAILABLE
	if m == "lobby" and p.has_method("connect_to_lobby") and String(target.get("lobby_id", "")).is_valid_int():
		err = int(p.call("connect_to_lobby", String(target.lobby_id).to_int()))
	elif p.has_method("create_client") and String(target.get("host_steam_id", "")).is_valid_int():
		err = int(p.call("create_client", String(target.host_steam_id).to_int(), VIRTUAL_PORT))
	if err != OK:
		return err
	_peer = p
	return OK


func platform_id_of(peer_id: int) -> String:
	if _peer != null and _peer.has_method("get_steam_id_for_peer_id"):
		var sid = _peer.call("get_steam_id_for_peer_id", peer_id)
		if int(sid) != 0:
			return str(sid)
	return "steam:%d" % peer_id
