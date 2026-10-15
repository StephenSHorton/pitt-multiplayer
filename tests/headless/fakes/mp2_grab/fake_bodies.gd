extends RefCounted
## GRAB's double of the BODIES module (MP2-DESIGN 10.2, 10.8): the full 10.2
## surface, recording every call; tests drive entity_added/removed with add()
## and remove(). test_mp2_bodies_contract (BODIES) asserts this file has every
## 10.2 member.

signal entity_added(eid: int, node: Node)
signal entity_removed(eid: int)

const FLAG_HELD := 16
const FLAG_NOCOLLIDE := 64

var nodes: Dictionary = {}        # eid -> Node
var kinds: Dictionary = {}        # eid -> "pooled" | "fixture_body" | "fixture"
var pools: Dictionary = {}
var flags: Dictionary = {}
var metas: Dictionary = {}
var owner_views: Dictionary = {}  # eid -> [owner, kind, epoch]
var local_sim: Dictionary = {}    # eid -> true
var unsim_epoch: Dictionary = {}  # eid -> min_epoch of the last set_local_sim(false)
var following: Dictionary = {}    # eid -> peer (host_follow)
var pushes: Dictionary = {}       # eid -> [[state, t_ms], ...]
var releases: Dictionary = {}     # eid -> [state, ...]
var boosts: Dictionary = {}
var dirty: Array = []
var snaps: Array = []
var fixtures: Dictionary = {}
var meta_kinds: Dictionary = {}
var frozen_world := false
var host_states: Dictionary = {}
var calls: Array = []
var apply_follow := true          # host_follow_push / host_release move the node


func mod_name() -> String:
	return "bodies"


func add(eid: int, node: Node, kind: String = "pooled", pool_id: String = "duck") -> void:
	nodes[eid] = node
	kinds[eid] = kind
	pools[eid] = pool_id
	flags[eid] = 0
	entity_added.emit(eid, node)


func remove(eid: int) -> void:
	entity_removed.emit(eid)
	nodes.erase(eid)
	kinds.erase(eid)
	local_sim.erase(eid)
	following.erase(eid)


# ---------------------------------------------------------------- both roles

func node_of(eid: int) -> Node:
	var n = nodes.get(eid, null)
	return n if n != null and is_instance_valid(n) else null


func eid_of(node: Object) -> int:
	var n := node as Node
	while n != null:
		for eid in nodes:
			if nodes[eid] == n:
				return int(eid)
		n = n.get_parent()
	return 0


func is_replicated(eid: int) -> bool:
	return node_of(eid) != null


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
	owner_views[eid] = [owner_peer, kind, epoch]


func register_meta(kind: String, matcher: Callable, read: Callable, apply: Callable, rate_hz: float = 4.0) -> void:
	meta_kinds[kind] = [matcher, read, apply, rate_hz]


func register_fixture(key: String, node: Node) -> int:
	var id := 900000 + fixtures.size()
	fixtures[key] = id
	nodes[id] = node
	kinds[id] = "fixture"
	return id


func unregister_fixture(key: String) -> void:
	if fixtures.has(key):
		nodes.erase(fixtures[key])
		fixtures.erase(key)


# ---------------------------------------------------------------- host only

func host_follow(eid: int, peer: int) -> void:
	calls.append(["host_follow", eid, peer])
	following[eid] = peer
	var b := node_of(eid) as RigidBody3D
	if b != null:
		b.set_freeze_mode(RigidBody3D.FREEZE_MODE_KINEMATIC)
		b.freeze = true


func host_follow_push(eid: int, state: Dictionary, t_ms: int) -> void:
	if not pushes.has(eid):
		pushes[eid] = []
	pushes[eid].append([state, t_ms])
	var n := node_of(eid) as Node3D
	if apply_follow and n != null and state.has("p"):
		n.global_position = state.p


func host_release(eid: int, state: Dictionary) -> void:
	calls.append(["host_release", eid, state])
	if not releases.has(eid):
		releases[eid] = []
	releases[eid].append(state)
	following.erase(eid)
	var b := node_of(eid) as RigidBody3D
	if b == null:
		return
	if state.is_empty():
		return
	b.freeze = false
	if apply_follow:
		b.global_position = state.p
		b.quaternion = state.q
		b.linear_velocity = state.l
		b.angular_velocity = state.a
	b.sleeping = false


func boost(eid: int, seconds: float) -> void:
	boosts[eid] = seconds


func meta_dirty(eid: int) -> void:
	dirty.append(eid)


func mark_snap(eid: int) -> void:
	snaps.append(eid)


func freeze_world() -> void:
	frozen_world = true


# ---------------------------------------------------------------- client only

func set_local_sim(eid: int, on: bool, min_epoch: int = 0) -> void:
	calls.append(["set_local_sim", eid, on, min_epoch])
	var b := node_of(eid) as RigidBody3D
	if on:
		local_sim[eid] = true
		if b != null:
			b.freeze = false
	else:
		local_sim.erase(eid)
		unsim_epoch[eid] = min_epoch
		if b != null:
			b.set_freeze_mode(RigidBody3D.FREEZE_MODE_KINEMATIC)
			b.freeze = true


func is_local_sim(eid: int) -> bool:
	return local_sim.has(eid)


func host_state(eid: int) -> Dictionary:
	return host_states.get(eid, {})


# ---------------------------------------------------------------- test helpers

func count(name: String) -> int:
	var n := 0
	for c in calls:
		if c[0] == name:
			n += 1
	return n


func last(name: String) -> Array:
	for i in range(calls.size() - 1, -1, -1):
		if calls[i][0] == name:
			return calls[i]
	return []
