extends RefCounted
## BodiesAdapter (MP2-DESIGN 3, file ownership 10.9): the ONLY BODIES file that
## reads or writes game autoloads and world nodes for the shared world: the
## object pools, SaveManager.is_loading, the local player, physics pinning and
## the physics load. Every game member used here is listed in
## world/bodies/contract_bodies.gd. Tests swap g() / tree() for fakes
## (tests/headless/fakes/mp2_bodies/fake_bodies_adapter.gd).

const DEFAULT_EYE := Vector3(0, 0.65, 0)
const MAX_PHYSICS_STEPS := 8   # catch-up cap while physics is pinned

var api = null
var _pinned := false
var _saved_ticks := 60
var _saved_steps := 8


func setup(p_api) -> void:
	api = p_api


func tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


func g(n: String) -> Object:
	var t := tree()
	return t.root.get_node_or_null(NodePath(n)) if t != null else null


func pool_manager() -> Object:
	return g("ObjectPoolManager")


func pools_ready() -> bool:
	var pm = pool_manager()
	return pm != null and bool(pm.get("_initialized"))


## ObjectPoolManager._pools (pool id -> Pool{active, available}); {} until initialized.
func pools() -> Dictionary:
	var pm = pool_manager()
	if pm == null or not bool(pm.get("_initialized")):
		return {}
	var p = pm.get("_pools")
	return p if typeof(p) == TYPE_DICTIONARY else {}


## Sorted pool ids of the game's pool table (POOL_CONFIG), available before the
## pools are built; falls back to the built pools.
func pool_ids() -> Array:
	var pm = pool_manager()
	var ids: Array = []
	if pm != null:
		var sc = pm.get_script()
		var cfg = sc.get_script_constant_map().get("POOL_CONFIG", null) if sc != null else null
		if typeof(cfg) == TYPE_DICTIONARY:
			ids = cfg.keys()
		elif typeof(pm.get("_pools")) == TYPE_DICTIONARY:
			ids = pm.get("_pools").keys()
	var out: Array = []
	for i in ids:
		out.append(String(i))
	out.sort()
	return out


func spawn(pool_id: String, pos: Vector3, rot: Vector3 = Vector3.ZERO) -> Node3D:
	var pm = pool_manager()
	if pm == null or not pools_ready():
		return null
	return pm.spawn(pool_id, pos, rot)


func recycle(node: Node3D) -> void:
	var pm = pool_manager()
	if pm != null and node != null and is_instance_valid(node):
		pm.recycle(node)


func is_loading() -> bool:
	var sm = g("SaveManager")
	return sm != null and bool(sm.get("is_loading"))


## The game's own pool load holds SaveManager.is_loading (spawn audio muted).
func set_loading(on: bool) -> void:
	var sm = g("SaveManager")
	if sm != null and "is_loading" in sm:
		sm.is_loading = on


func local_player() -> Node3D:
	var t := tree()
	if t == null:
		return null
	var p = t.get_first_node_in_group("player")
	return p if p is Node3D else null


## The player's CameraPivot offset (player_controller.tscn: CameraPivot).
func eye_offset() -> Vector3:
	var p := local_player()
	if p != null:
		var pivot = p.get_node_or_null("CameraPivot")
		if pivot is Node3D:
			return pivot.position
	return DEFAULT_EYE


func world_root() -> Node:
	var t := tree()
	return t.current_scene if t != null else null


## The fixtures of this peer's world in a group (the real game has one world).
func nodes_in_group(group: String) -> Array:
	var t := tree()
	return t.get_nodes_in_group(group) if t != null else []


## Whether a node belongs to this peer's world (tests run several worlds).
func owns(_node: Node) -> bool:
	return true


## The node path used in fixture keys (the same on every peer: one world scene).
func fixture_path(node: Node) -> String:
	return String(node.get_path())


## Physics time / tick budget (1.0 = the whole 1/hz tick).
func physics_load() -> float:
	var tps := float(maxi(1, Engine.physics_ticks_per_second))
	return float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * tps


## D23: 60 Hz on every peer for the whole session (PittAPI's perf.pin_physics:
## stops PerformanceMonitor, pins the tick, max 8 steps per frame).
func pin_physics(hz: int = 60) -> void:
	if not _pinned:
		_saved_ticks = Engine.physics_ticks_per_second
		_saved_steps = Engine.max_physics_steps_per_frame
	_pinned = true
	var used_cmd := false
	if api != null and "commands" in api and api.commands != null and api.commands.has_method("describe") \
			and not api.commands.describe("perf.pin_physics").is_empty():
		api.commands.execute("perf.pin_physics", {"hz": hz})
		used_cmd = true
	if not used_cmd or Engine.physics_ticks_per_second != hz:
		var pm = g("PerformanceMonitor")
		if pm != null:
			pm.set_process(false)
		Engine.physics_ticks_per_second = hz
		Engine.max_physics_steps_per_frame = MAX_PHYSICS_STEPS


func unpin_physics() -> void:
	if not _pinned:
		return
	_pinned = false
	var pm = g("PerformanceMonitor")
	if pm != null:
		pm.set_process(true)
	Engine.physics_ticks_per_second = _saved_ticks
	Engine.max_physics_steps_per_frame = _saved_steps


func physics_pinned() -> bool:
	return _pinned
