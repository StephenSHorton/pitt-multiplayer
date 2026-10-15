extends Node
## Headless fake of ObjectPoolManager: pools of plain nodes under /root/ObjectPools.

class Pool:
	var scene: PackedScene
	var max_size: int
	var available: Array[Node3D] = []
	var active: Array[Node3D] = []

var _pools: Dictionary = {}
var _container: Node
var _initialized := false


func _ready() -> void:
	var holder := Node.new()
	holder.name = &"ObjectPools"
	_container = holder
	get_tree().root.call_deferred("add_child", holder)


## test helper: creates pools {id: max}. "duck*" bodies are RigidBody3D.
func initialize_fake(config: Dictionary) -> void:
	for id in config:
		var p := Pool.new()
		p.max_size = int(config[id])
		_pools[id] = p
	_initialized = true


## a new pooled node under the container ("duck*" ones are weightless bodies)
func _new_body(pool_id: String) -> Node3D:
	var body: Node3D
	if pool_id.begins_with("duck"):
		body = RigidBody3D.new()
		body.gravity_scale = 0.0
	else:
		body = Node3D.new()
	_container.add_child(body)
	return body


## reuses a parked node, else builds one while under max_size; null when full
func spawn(pool_id: String, position := Vector3.ZERO, rotation := Vector3.ZERO) -> Node3D:
	var pool: Pool = _pools.get(pool_id)
	if pool == null:
		return null
	var obj: Node3D
	if pool.available.size() > 0:
		obj = pool.available.pop_back()
	elif pool.available.size() + pool.active.size() < pool.max_size:
		obj = _new_body(pool_id)
	else:
		return null
	obj.visible = true
	obj.process_mode = PROCESS_MODE_PAUSABLE
	# the container is a plain Node, so local == global
	obj.position = position
	obj.rotation = rotation
	pool.active.push_back(obj)
	return obj


func recycle(obj: Node3D) -> void:
	for pool in _pools.values():
		var at: int = pool.active.find(obj)
		if at == -1:
			continue
		pool.active.remove_at(at)
		pool.available.push_back(obj)
		obj.visible = false
		obj.process_mode = PROCESS_MODE_DISABLED
		return


func pool_headroom(pool_id: String) -> int:
	var p: Pool = _pools.get(pool_id)
	return 0 if p == null else p.max_size - p.active.size()
