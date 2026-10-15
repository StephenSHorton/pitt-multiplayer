extends RefCounted
## PittNet: authority and session info. Single player unless a mod that
## "provides": ["net"] in its mod.json (the multiplayer layer) installs an
## authority. Everyone reads; only the provider mod may call the provider
## section below (other mods get ERR_UNAUTHORIZED / no-ops).
##
## Signals fire on every mod's api.net (and on the global PittAPI.net):
##   session_started  a session began (get_session_info() has the details)
##   session_ended    the session is over (back to single player)
##   peers_changed    the roster changed (get_players())
## The same moments are also events: net.session_started {...},
## net.session_ended {reason}, net.peers_changed {players}.

signal session_started()
signal session_ended()
signal peers_changed()

var _core: Object = null
var _mod := ""


func _init(core: Object, mod_id: String) -> void:
	_core = core
	_mod = mod_id


func is_authority() -> bool:
	return _core.authority.is_authority()


func local_peer_id() -> int:
	return _core.authority.local_peer_id()


func is_multiplayer() -> bool:
	return _core.authority.is_multiplayer()


func get_peers() -> Array[int]:
	return _core.authority.get_peers()


func get_authority_kind() -> String:
	return _core.authority.get_kind()


## [{peer, slot, name, platform_id, state, is_host}] of the current session ([] in single player).
func get_players() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p in _core.net_players:
		if typeof(p) == TYPE_DICTIONARY:
			out.append(p.duplicate(true))
	return out


func get_peer_info(peer: int) -> Dictionary:
	for p in _core.net_players:
		if typeof(p) == TYPE_DICTIONARY and int(p.get("peer", 0)) == peer:
			return p.duplicate(true)
	return {}


## {role, sid, transport, ...} of the running session, {} in single player.
func get_session_info() -> Dictionary:
	return _core.net_session_info.duplicate(true)


## True while replicated state from a peer is being applied (see begin_apply).
func is_applying() -> bool:
	return _core._net_apply_origin > 0


# ------------------------------------------------------------------ provider only

func is_provider() -> bool:
	return _core.is_net_provider(_mod)


## Replaces the command authority. The object must have get_kind, is_authority,
## local_peer_id, get_peers, is_multiplayer, submit(envelope), complete(envelope,
## result), a `commands` property and a peers_changed signal.
func install_authority(a: Object) -> Error:
	if not is_provider():
		return ERR_UNAUTHORIZED
	return _core.net_install_authority(a)


## Restores the single-player LocalAuthority.
func uninstall_authority() -> void:
	if is_provider():
		_core.net_uninstall_authority()


func emit_session_started(info: Dictionary = {}) -> void:
	if is_provider():
		_core.net_emit_session_started(info)


func emit_session_ended(reason: String = "") -> void:
	if is_provider():
		_core.net_emit_session_ended(reason)


## players (optional): the new roster [{peer, slot, name, platform_id, state, is_host}].
func emit_peers_changed(players: Variant = null) -> void:
	if is_provider():
		_core.net_emit_peers_changed(players)


## Gives a remote player's puppet node a player entity id (slots 2..999).
func register_remote_player(node: Node, peer: int) -> int:
	if not is_provider():
		return 0
	return _core.entities.register_remote_player(node, peer)


func unregister_remote_player(peer: int) -> void:
	if is_provider():
		_core.entities.unregister_remote_player(peer)


## L7 (PittAPI 1.2): on a non-authority peer, binds `node` to the id the host
## assigned (pooled id >= 1000 with its pool id, or a static id with its key).
## Pooled adoptions emit entity.spawned with source "net". Refused on the
## authority (ERR_UNAUTHORIZED) and for an id bound to another node.
func adopt_entity(node: Node, entity_id: int, pool_id_or_key: String) -> Error:
	if not is_provider():
		return ERR_UNAUTHORIZED
	return _core.entities.adopt(node, entity_id, pool_id_or_key)


## L7: drops an adopted id (pooled: entity.despawned, source "net").
func release_entity(entity_id: int) -> void:
	if is_provider():
		_core.entities.release(entity_id)


## L8: {full_every_frame: bool, detect_reuse: bool} for the pool reconciler.
func set_reconcile_mode(mode: Dictionary) -> void:
	if is_provider():
		_core.entities.set_reconcile_mode(mode)


## Tracks a world fixture under the static id of an unprefixed key (the same
## id on every peer, like the loader's own fixture keys). 0 on a collision.
func track_fixture(node: Node, key: String) -> int:
	if not is_provider() or key == "":
		return 0
	return _core.entities.track(node, key, _mod)


## Events emitted until end_apply() carry origin=origin_peer, source="net", and
## money.changed gets reason "net": "the host changed it", not "my world did".
func begin_apply(origin_peer: int = 1) -> void:
	if is_provider():
		_core.net_begin_apply(origin_peer)


func end_apply() -> void:
	if is_provider():
		_core.net_end_apply()
