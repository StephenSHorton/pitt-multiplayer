extends "transport.gd"
## ENet transport for development and the two-instance tests (one Steam account
## cannot P2P to itself). Binds 127.0.0.1 by default. Peer timeouts are long
## because a joiner's LoadingScreen can stall its main thread.
## target: {kind:"enet", role, address, port}

const MAX_CLIENTS := 9
const TIMEOUT_LIMIT := 5000
const TIMEOUT_MIN_MS := 30000
const TIMEOUT_MAX_MS := 60000

var bind_ip := "127.0.0.1"


func kind() -> String:
	return "enet"


func _create_host(target: Dictionary) -> Error:
	var p := ENetMultiplayerPeer.new()
	var ip := String(target.get("bind_ip", bind_ip))
	if ip != "" and ip != "*":
		p.set_bind_ip(ip)
	var err := p.create_server(int(target.get("port", 27450)), int(target.get("max_clients", MAX_CLIENTS)),
		Proto.CHANNELS)
	if err != OK:
		return err
	_peer = p
	return OK


func _create_client(target: Dictionary) -> Error:
	var p := ENetMultiplayerPeer.new()
	var err := p.create_client(String(target.get("address", "127.0.0.1")), int(target.get("port", 27450)),
		Proto.CHANNELS)
	if err != OK:
		return err
	_peer = p
	return OK


func _on_peer_connected(id: int) -> void:
	var ep = _peer.get_peer(id) if _peer is ENetMultiplayerPeer else null
	if ep != null and ep.has_method("set_timeout"):
		ep.set_timeout(TIMEOUT_LIMIT, TIMEOUT_MIN_MS, TIMEOUT_MAX_MS)
	super(id)


func platform_id_of(peer_id: int) -> String:
	return "enet:%d" % peer_id
