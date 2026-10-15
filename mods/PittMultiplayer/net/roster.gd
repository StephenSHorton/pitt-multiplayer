extends RefCounted
## Session roster. The host assigns peer ids, slots and names (facts taken from
## the transport and the lobby, never from payloads). Slot 1 is the host;
## clients get the lowest free slot 2..max.
## Player = {peer:int, slot:int, name:String, platform_id:String,
##           state:"connected"|"loading"|"in_game", is_host:bool}

const STATES := ["connected", "loading", "in_game"]

var max_players := 10
var _players: Dictionary = {}   # peer -> Player


func clear() -> void:
	_players.clear()


func add(peer: int, player_name: String, platform_id: String, is_host: bool = false) -> Dictionary:
	if _players.has(peer):
		return _players[peer]
	var slot := 1 if is_host else _free_slot()
	if slot == 0:
		return {}
	var p := {"peer": peer, "slot": slot, "name": _clean_name(player_name, slot), "platform_id": platform_id,
		"state": "connected", "is_host": is_host}
	_players[peer] = p
	return p


func remove(peer: int) -> Dictionary:
	var p: Dictionary = _players.get(peer, {})
	_players.erase(peer)
	return p


func has(peer: int) -> bool:
	return _players.has(peer)


func get_player(peer: int) -> Dictionary:
	return _players.get(peer, {})


func slot_of(peer: int) -> int:
	return int(_players.get(peer, {}).get("slot", 0))


func peer_of_slot(slot: int) -> int:
	for p in _players:
		if int(_players[p].slot) == slot:
			return int(p)
	return 0


func name_of(peer: int) -> String:
	return String(_players.get(peer, {}).get("name", ""))


func set_state(peer: int, state: String) -> bool:
	if not _players.has(peer) or not (state in STATES):
		return false
	if _players[peer].state == state:
		return false
	_players[peer].state = state
	return true


func state_of(peer: int) -> String:
	return String(_players.get(peer, {}).get("state", ""))


func size() -> int:
	return _players.size()


func is_full() -> bool:
	return _players.size() >= max_players


func peers() -> Array[int]:
	var out: Array[int] = []
	for p in _players:
		out.append(int(p))
	out.sort()
	return out


func peers_in_state(state: String) -> Array[int]:
	var out: Array[int] = []
	for p in _players:
		if _players[p].state == state and not _players[p].is_host:
			out.append(int(p))
	out.sort()
	return out


## Sorted by slot, JSON-safe copies.
func to_array() -> Array:
	var out: Array = []
	for p in _players:
		out.append(_players[p].duplicate())
	out.sort_custom(func(a, b): return int(a.slot) < int(b.slot))
	return out


## Client side: replaces the roster with the host's list (validated).
func load_array(list: Array) -> void:
	_players.clear()
	for e in list:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var peer := int(e.get("peer", 0))
		if peer <= 0:
			continue
		var st := String(e.get("state", "connected"))
		_players[peer] = {"peer": peer, "slot": clampi(int(e.get("slot", 0)), 0, 255),
			"name": _clean_name(String(e.get("name", "")), int(e.get("slot", 0))),
			"platform_id": String(e.get("platform_id", "")),
			"state": st if st in STATES else "connected", "is_host": bool(e.get("is_host", false))}


## [MemberInfo] for LobbyService.set_external_members (dev/fake lobbies).
func to_members(local_peer: int) -> Array:
	var out: Array = []
	for p in to_array():
		out.append({"id": String(p.platform_id) if String(p.platform_id) != "" else "peer:%d" % int(p.peer),
			"name": p.name, "is_owner": bool(p.is_host), "is_self": int(p.peer) == local_peer,
			"state": p.state, "peer": p.peer, "slot": p.slot})
	return out


func _free_slot() -> int:
	var used := {}
	for p in _players:
		used[int(_players[p].slot)] = true
	for s in range(2, max_players + 1):
		if not used.has(s):
			return s
	return 0


static func _clean_name(n: String, slot: int) -> String:
	var s := n.strip_edges().replace("\n", " ").replace("\r", " ")
	if s.length() > 32:
		s = s.substr(0, 32)
	if s == "":
		s = "Player %d" % maxi(slot, 1)
	return s
