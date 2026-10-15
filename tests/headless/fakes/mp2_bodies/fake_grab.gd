extends RefCounted
## BODIES' double of the GRAB module (MP2-DESIGN 10.8): a registered module
## with the 10.3 surface that calls bodies.set_owner_view like GRAB does on
## every ownership change, and records entity_added / entity_removed.

signal owner_changed(eid: int, owner_peer: int, kind: String, epoch: int)

var session = null
var role := ""
var added: Array = []
var removed: Array = []
var owners: Dictionary = {}    # eid -> [peer, kind, epoch]
var deny_rules: Array = []
var revoked: Array = []


func mod_name() -> String:
	return "grab"


func msg_kinds() -> Dictionary:
	return {"ch3_c2h": [], "ch3_h2c": [], "ch0_c2h": [], "ch0_h2c": [], "raw_c2h": []}


func on_session_start(p_session: Object, p_role: String) -> void:
	session = p_session
	role = p_role
	var b = _bodies()
	if b != null:
		if not b.entity_added.is_connected(_on_added):
			b.entity_added.connect(_on_added)
		if not b.entity_removed.is_connected(_on_removed):
			b.entity_removed.connect(_on_removed)


func _bodies():
	return session.get_module("bodies") if session != null else null


func _on_added(eid: int, _node: Node) -> void:
	added.append(eid)


func _on_removed(eid: int) -> void:
	removed.append(eid)
	owners.erase(eid)


## Like GRAB on every change: owner 1 = host, kind "" | "held" | "equipped".
func set_owner(eid: int, peer: int, kind: String, epoch: int) -> void:
	owners[eid] = [peer, kind, epoch]
	var b = _bodies()
	if b != null:
		b.set_owner_view(eid, peer, kind, epoch)
	owner_changed.emit(eid, peer, kind, epoch)


# ------------------------------------------------------------------ 10.3 surface

func owner_of(eid: int) -> int:
	return int(owners.get(eid, [1, "", 0])[0])


func hold_kind(eid: int) -> String:
	return String(owners.get(eid, [1, "", 0])[1])


func epoch_of(eid: int) -> int:
	return int(owners.get(eid, [1, "", 0])[2])


func is_mine(eid: int) -> bool:
	return session != null and owner_of(eid) == int(session.my_peer_id())


func can_take(eid: int, peer: int) -> String:
	if hold_kind(eid) != "" and owner_of(eid) != peer:
		return "owned"
	for r in deny_rules:
		var why = r.call(eid, null, peer)
		if typeof(why) == TYPE_STRING and why != "":
			return why
	return ""


func add_deny_rule(rule: Callable) -> void:
	deny_rules.append(rule)


func revoke(eid: int, reason: String) -> void:
	revoked.append([eid, reason])
	set_owner(eid, 1, "", epoch_of(eid) + 1)


func grant(eid: int, peer: int, kind: String = "held", _carry: bool = true) -> void:
	set_owner(eid, peer, kind, epoch_of(eid) + 1)


func teardown() -> void:
	var b = _bodies()
	if b != null:
		if b.entity_added.is_connected(_on_added):
			b.entity_added.disconnect(_on_added)
		if b.entity_removed.is_connected(_on_removed):
			b.entity_removed.disconnect(_on_removed)
	session = null
