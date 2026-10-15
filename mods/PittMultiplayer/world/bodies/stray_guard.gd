extends RefCounted
## Stray guard (MP2-DESIGN 3.4, P6). On a client every active pooled object must
## be a puppet of a host entity (or a body GRAB simulates locally). Anything
## else (debris from the client's own GameProgression, panels from
## GameState.dump_panel_stack, a gate GAMEPLAY missed) is recycled in the same
## frame. Cheap path: compare the total active count with the puppet count;
## only a mismatch diffs the active sets.
## Expected, silent sources: the debris pools and the panel pools. Anything
## else is counted in stray_spawns and logged with its pool id (the loopback
## tests fail on it). A node carrying meta "pitt_mp_local" is left alone (an
## escape hatch for deliberate client-only pooled objects).

const PUPPET_META := "pitt_mp_puppet"
const LOCAL_META := "pitt_mp_local"
const EXPECTED_PREFIXES := ["debris_chunk", "tool_panel"]

var adapter = null
var log_cb: Callable
var stray_spawns := 0
var stray_expected := 0
var by_pool: Dictionary = {}
var checks := 0
var diffs := 0


func _init(p_adapter = null) -> void:
	adapter = p_adapter


static func is_expected(pool_id: String) -> bool:
	for p in EXPECTED_PREFIXES:
		if pool_id.begins_with(p):
			return true
	return false


## known_active: how many active pooled objects the replicator accounts for.
## recycle: Callable(node) that recycles in apply scope. Returns the strays recycled.
func check(known_active: int, recycle: Callable) -> int:
	checks += 1
	if adapter == null:
		return 0
	var pools: Dictionary = adapter.pools()
	if pools.is_empty():
		return 0
	var total := 0
	for pid in pools:
		var pool = pools[pid]
		if pool != null:
			total += pool.active.size()
	if total == known_active:
		return 0
	diffs += 1
	var strays: Array = []
	for pid in pools:
		var pool = pools[pid]
		if pool == null:
			continue
		for obj in pool.active:
			if obj == null or not is_instance_valid(obj):
				continue
			if obj.has_meta(PUPPET_META) or obj.has_meta(LOCAL_META):
				continue
			strays.append([String(pid), obj])
	for s in strays:
		var pid: String = s[0]
		if is_expected(pid):
			stray_expected += 1
		else:
			stray_spawns += 1
			by_pool[pid] = int(by_pool.get(pid, 0)) + 1
			if log_cb.is_valid():
				log_cb.call("stray pooled object recycled on the client (pool %s): a missed gate?" % pid)
		recycle.call(s[1])
	return strays.size()
