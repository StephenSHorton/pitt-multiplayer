extends RefCounted
## make(kind) -> an un-setup LobbyService node: "steam" | "dev" | "fake".
## The caller adds it to the tree and calls setup(api, version, config).

const SteamLobbyService = preload("steam_lobby_service.gd")
const DevLobbyService = preload("dev_lobby_service.gd")
const FakeLobbyService = preload("fake_lobby_service.gd")


static func make(kind: String) -> Node:
	var n: Node = null
	match kind:
		"steam":
			n = SteamLobbyService.new()
		"dev", "enet":
			n = DevLobbyService.new()
		"fake":
			n = FakeLobbyService.new()
		_:
			push_warning("PittMultiplayer: unknown lobby kind '%s', using dev" % kind)
			n = DevLobbyService.new()
	n.name = "LobbyService"
	return n
