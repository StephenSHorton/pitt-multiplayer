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

const VIRTUAL_PORT := 0

var mode := "socket"
var _relay_inited := false


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
