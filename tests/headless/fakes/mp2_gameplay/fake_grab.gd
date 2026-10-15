extends RefCounted
## GAMEPLAY's test double of the GRAB module surface (MP2-DESIGN 10.3, 10.8).
## An ownership table the tests set directly (set_owner emits owner_changed like
## GRAB does), deny rules collected from GAMEPLAY, revoke/grant recorded.
## test_mp2_grab_contract.gd (GRAB) checks this file against 10.3.

signal owner_changed(eid: int, owner_peer: int, kind: String, epoch: int)

var owners: Dictionary = {}       # eid -> {peer, kind, epoch}
var deny_rules: Array = []
var revoked: Array = []           # [eid, reason]
var granted: Array = []           # [eid, peer, kind, carry]
var my_peer := 1
var bodies = null                 # for can_take (node lookup)


func mod_name() -> String:
	return "grab"


## Test helper: changes the owner like GRAB (epoch + 1, signal).
func set_owner(eid: int, peer: int, kind: String) -> void:
	var e: Dictionary = owners.get(eid, {"peer": 1, "kind": "", "epoch": 0})
	e = {"peer": peer, "kind": kind, "epoch": int(e.epoch) + 1}
	owners[eid] = e
	owner_changed.emit(eid, peer, kind, int(e.epoch))


func owner_of(eid: int) -> int:
	return int(owners.get(eid, {}).get("peer", 1))


func hold_kind(eid: int) -> String:
	return String(owners.get(eid, {}).get("kind", ""))


func epoch_of(eid: int) -> int:
	return int(owners.get(eid, {}).get("epoch", 0))


func is_mine(eid: int) -> bool:
	return owner_of(eid) == my_peer and hold_kind(eid) != ""


func can_take(eid: int, peer: int) -> String:
	if hold_kind(eid) != "" and owner_of(eid) != peer:
		return "owned"
	var node = bodies.node_of(eid) if bodies != null else null
	for r in deny_rules:
		var why := String(r.call(eid, node, peer))
		if why != "":
			return why
	return ""


func add_deny_rule(rule: Callable) -> void:
	deny_rules.append(rule)


func revoke(eid: int, reason: String) -> void:
	revoked.append([eid, reason])
	set_owner(eid, 1, "")


func grant(eid: int, peer: int, kind: String = "held", carry: bool = true) -> void:
	granted.append([eid, peer, kind, carry])
	set_owner(eid, peer, kind)
