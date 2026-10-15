extends RefCounted
## Fixtures registry (MP2-DESIGN 3.6). At world ready, on both roles, resolves
## the world fixtures by group and gives each a static id that every peer
## computes alike: the loader's own key when PittAPI already tracks the node
## (static:/root/World/BottomMaw, workbench:auto:<k>, gate:<id>, ...), a short
## key for the unique fixtures (press, trading_terminal, bowling_set, cauldron,
## ...), else static:<node path>. Late fixtures (bought press / terminal /
## bowling set, benches from WorkbenchSpawning) are picked up from
## SceneTree.node_added (checked one frame later: groups are joined in _ready).
## RigidBody3D fixtures are "fixture bodies" (streamed like pooled bodies);
## everything else is a state-only "fixture".

const GROUPS := ["saveable_hole", "BottomMaw", "press", "trading_terminal", "workbench", "automated_workbench",
	"cauldron", "ore_processor", "saveable_block", "vertical_gate", "gate_shutters", "security_keypad",
	"security_elevator", "loop_puzzle", "saveable_camera", "fuse", "pickaxe", "uv_lamp", "torch_light",
	"bowling_pin_set", "erasable_text"]
## unique fixtures: group -> key
const UNIQUE_KEYS := {"press": "press", "trading_terminal": "trading_terminal", "bowling_pin_set": "bowling_set",
	"cauldron": "cauldron", "ore_processor": "ore_processor", "loop_puzzle": "loop_puzzle",
	"security_keypad": "keypad", "security_elevator": "elevator"}

var api = null
var adapter = null
var by_key: Dictionary = {}       # key -> {eid, ref: WeakRef, body: bool}
var by_eid: Dictionary = {}       # eid -> key
var on_added: Callable            # (key, eid, node, is_body)
var on_removed: Callable          # (key, eid)
var mismatches := 0
var collisions := 0
var _tree: SceneTree = null
var _pending: Array = []          # nodes added this frame, checked next frame


func _init(p_api = null, p_adapter = null) -> void:
	api = p_api
	adapter = p_adapter


## Resolves every fixture currently in the world and starts watching node_added.
func scan() -> int:
	var tree: SceneTree = adapter.tree() if adapter != null else null
	if tree == null:
		return 0
	var n := 0
	for g in GROUPS:
		for node in adapter.nodes_in_group(g):
			if consider(node) != 0:
				n += 1
	if _tree == null:
		_tree = tree
		_tree.node_added.connect(_on_node_added)
	return n


func stop() -> void:
	if _tree != null and _tree.node_added.is_connected(_on_node_added):
		_tree.node_added.disconnect(_on_node_added)
	_tree = null
	_pending.clear()


func _on_node_added(node: Node) -> void:
	if node is Node3D and _pending.size() < 4096 and (adapter == null or adapter.owns(node)):
		_pending.append(weakref(node))


## Every frame: late fixtures added last frame (their _ready joined the groups).
func poll() -> void:
	if _pending.is_empty():
		return
	var batch := _pending
	_pending = []
	for w in batch:
		var node = w.get_ref()
		if node == null or not is_instance_valid(node) or not node.is_inside_tree():
			continue
		for g in GROUPS:
			if node.is_in_group(g):
				consider(node)
				break


static func is_pooled(node: Node) -> bool:
	var p := node.get_parent()
	return (p != null and String(p.name) == "ObjectPools") or node.has_meta("pitt_mp_puppet")


func key_for(node: Node) -> String:
	if api != null and "entities" in api and api.entities != null:
		var id: int = api.entities.id_of(node)
		if id != 0 and String(api.entities.kind_of(id)) == "static":
			var k := String(api.entities.key_of(id))
			if k != "":
				return k
	for g in UNIQUE_KEYS:
		if node.is_in_group(g):
			return String(UNIQUE_KEYS[g])
	return "static:%s" % (adapter.fixture_path(node) if adapter != null else String(node.get_path()))


func consider(node: Node) -> int:
	if node == null or not is_instance_valid(node) or is_pooled(node):
		return 0
	return register(key_for(node), node)


## Static id of key bound to node (0 on a collision). Idempotent.
func register(key: String, node: Node) -> int:
	if key == "" or node == null or not is_instance_valid(node):
		return 0
	var cur = by_key.get(key, null)
	if cur != null:
		var n = cur.ref.get_ref()
		if n == node:
			return int(cur.eid)
		if n != null and is_instance_valid(n):
			collisions += 1
			return 0
		_drop(key)
	var eid := 0
	if api != null and "entities" in api and api.entities != null:
		var existing: int = api.entities.id_of(node)
		if existing != 0 and String(api.entities.kind_of(existing)) == "static":
			eid = existing
	if eid == 0 and api != null and "net" in api and api.net != null and api.net.has_method("track_fixture"):
		eid = int(api.net.track_fixture(node, key))
	if eid == 0:
		collisions += 1
		return 0
	var body := node is RigidBody3D
	by_key[key] = {"eid": eid, "ref": weakref(node), "body": body}
	by_eid[eid] = key
	if on_added.is_valid():
		on_added.call(key, eid, node, body)
	return eid


func unregister(key: String) -> void:
	if not by_key.has(key):
		return
	var eid := int(by_key[key].eid)
	_drop(key)
	if on_removed.is_valid():
		on_removed.call(key, eid)


func _drop(key: String) -> void:
	var e = by_key.get(key, null)
	if e == null:
		return
	by_key.erase(key)
	by_eid.erase(int(e.eid))


func node_of_key(key: String) -> Node:
	var e = by_key.get(key, null)
	if e == null:
		return null
	var n = e.ref.get_ref()
	return n if n != null and is_instance_valid(n) else null


func eid_of_key(key: String) -> int:
	var e = by_key.get(key, null)
	return int(e.eid) if e != null else 0


func key_of_eid(eid: int) -> String:
	return String(by_eid.get(eid, ""))


func clear() -> void:
	stop()
	by_key.clear()
	by_eid.clear()
