extends RefCounted
## GAMEPLAY's test double of the BODIES module surface (MP2-DESIGN 10.2, 10.8).
## Tracks nodes under eids, records every call, keeps the registered meta
## adapters and fixtures, and drives entity_added / entity_removed.
## test_mp2_bodies_contract.gd (BODIES) checks this file against 10.2.

signal entity_added(eid: int, node: Node)
signal entity_removed(eid: int)

var nodes: Dictionary = {}        # eid -> Node
var kinds: Dictionary = {}        # eid -> "pooled" | "fixture_body" | "fixture"
var pools: Dictionary = {}        # eid -> pool id
var flags: Dictionary = {}        # eid -> int
var metas: Dictionary = {}        # eid -> Dictionary
var local_sim: Dictionary = {}    # eid -> true (client)
var host_states: Dictionary = {}  # eid -> Dictionary
var adapters: Dictionary = {}     # kind -> {matcher, read, apply, hz}
var fixtures: Dictionary = {}     # key -> eid
var calls: Array = []             # [method, args...]
var next_eid := 1000
var next_static := 900000
var api = null                    # FakeApi (begin_apply/end_apply around meta applies)


func mod_name() -> String:
	return "bodies"


# ------------------------------------------------------------------ test helpers

func add(node: Node, eid: int = 0, kind: String = "pooled", pool_id: String = "") -> int:
	if eid <= 0:
		next_eid += 1
		eid = next_eid
	nodes[eid] = node
	kinds[eid] = kind
	pools[eid] = pool_id
	flags[eid] = 0
	entity_added.emit(eid, node)
	return eid


func remove(eid: int) -> void:
	if not nodes.has(eid):
		return
	entity_removed.emit(eid)
	nodes.erase(eid)
	kinds.erase(eid)
	pools.erase(eid)
	flags.erase(eid)


func calls_of(method: String) -> Array:
	var out: Array = []
	for c in calls:
		if c[0] == method:
			out.append(c)
	return out


## Host side of a meta adapter: what register_meta's read returns for node.
func read_meta(kind: String, node: Object) -> Dictionary:
	var a: Dictionary = adapters.get(kind, {})
	if a.is_empty() or not bool(a.matcher.call(node)):
		return {}
	return a.read.call(node)


## Client side: apply d to node through the registered adapter, in apply scope.
func apply_meta(kind: String, node: Object, d: Dictionary) -> bool:
	var a: Dictionary = adapters.get(kind, {})
	if a.is_empty() or not bool(a.matcher.call(node)):
		return false
	if api != null:
		api.net.begin_apply(1)
	a.apply.call(node, d)
	if api != null:
		api.net.end_apply()
	return true


## The adapter kinds whose matcher accepts node.
func kinds_matching(node: Object) -> Array:
	var out: Array = []
	for k in adapters:
		if bool(adapters[k].matcher.call(node)):
			out.append(k)
	return out


# ------------------------------------------------------------------ 10.2, both roles

func node_of(eid: int) -> Node:
	var n = nodes.get(eid, null)
	return n if n != null and is_instance_valid(n) else null


func eid_of(node: Object) -> int:
	var n = node
	while n != null and is_instance_valid(n):
		for e in nodes:
			if nodes[e] == n:
				return int(e)
		n = n.get_parent() if n is Node else null
	return 0


func is_replicated(eid: int) -> bool:
	return nodes.has(eid)


func kind_of(eid: int) -> String:
	return String(kinds.get(eid, ""))


func pool_id_of(eid: int) -> String:
	return String(pools.get(eid, ""))


func flags_of(eid: int) -> int:
	return int(flags.get(eid, 0))


func meta_of(eid: int) -> Dictionary:
	return metas.get(eid, {})


func set_owner_view(eid: int, owner_peer: int, kind: String, epoch: int) -> void:
	calls.append(["set_owner_view", eid, owner_peer, kind, epoch])


func register_meta(kind: String, matcher: Callable, read: Callable, apply: Callable, rate_hz: float = 4.0) -> void:
	adapters[kind] = {"matcher": matcher, "read": read, "apply": apply, "hz": rate_hz}
	calls.append(["register_meta", kind, rate_hz])


func register_fixture(key: String, node: Node) -> int:
	var eid := int(fixtures.get(key, 0))
	if eid <= 0:
		next_static += 1
		eid = next_static
		fixtures[key] = eid
	nodes[eid] = node
	kinds[eid] = "fixture_body" if node is RigidBody3D else "fixture"
	calls.append(["register_fixture", key, eid])
	return eid


func unregister_fixture(key: String) -> void:
	var eid := int(fixtures.get(key, 0))
	fixtures.erase(key)
	if eid > 0:
		nodes.erase(eid)
		kinds.erase(eid)
	calls.append(["unregister_fixture", key])


# ------------------------------------------------------------------ 10.2, host

func host_follow(eid: int, peer: int) -> void:
	calls.append(["host_follow", eid, peer])


func host_follow_push(eid: int, state: Dictionary, t_ms: int) -> void:
	calls.append(["host_follow_push", eid, state, t_ms])


func host_release(eid: int, state: Dictionary) -> void:
	calls.append(["host_release", eid, state])


func boost(eid: int, seconds: float) -> void:
	calls.append(["boost", eid, seconds])


func meta_dirty(eid: int) -> void:
	calls.append(["meta_dirty", eid])


func mark_snap(eid: int) -> void:
	calls.append(["mark_snap", eid])


func freeze_world() -> void:
	calls.append(["freeze_world"])


# ------------------------------------------------------------------ 10.2, client

func set_local_sim(eid: int, on: bool, min_epoch: int = 0) -> void:
	if on:
		local_sim[eid] = true
	else:
		local_sim.erase(eid)
	calls.append(["set_local_sim", eid, on, min_epoch])


func is_local_sim(eid: int) -> bool:
	return local_sim.has(eid)


func host_state(eid: int) -> Dictionary:
	return host_states.get(eid, {})
