extends RefCounted
## The slice of /root/PittAPI that loader/core/entities.gd uses (authority,
## events, g, feature_ok), per peer, so each peer of a one-process test has its
## own REAL entity registry (L7-L9 production code). The authority follows the
## peer's api.commands authority (LocalAuthority, then MpAuthority host/client).

class AuthView extends RefCounted:
	var api = null

	func is_authority() -> bool:
		var a = api.commands.authority if api != null else null
		return a == null or bool(a.is_authority())

	func local_peer_id() -> int:
		var a = api.commands.authority if api != null else null
		return int(a.local_peer_id()) if a != null and a.has_method("local_peer_id") else 1


class EventsView extends RefCounted:
	var api = null

	func emit_internal(name: String, payload: Dictionary = {}, source: String = "game") -> RefCounted:
		api.events.fire(name, payload, 1, source)
		return null


var api = null
var pm = null
var authority = AuthView.new()
var events = EventsView.new()


func _init(p_api = null, p_pm = null) -> void:
	api = p_api
	pm = p_pm
	authority.api = p_api
	events.api = p_api


func g(n: String) -> Object:
	return pm if n == "ObjectPoolManager" else null


func feature_ok(_f: String) -> bool:
	return true
