extends Node
## Per-peer stand-in for ObjectPoolManager (object_pool_manager.gd): the same
## members BODIES uses (_pools with active/available, _initialized,
## POOL_CONFIG, spawn, recycle) and the same _activate / _deactivate effects
## (visible, position, freeze, velocities, on_pool_spawn / on_pool_recycle).

const FakeBody = preload("fake_body.gd")
const FakeMetaBody = preload("fake_meta_body.gd")

const POOL_CONFIG := {"duck": {"max": 3200}, "duck_luck": {"max": 200}, "candy": {"max": 200},
	"tool_fan": {"max": 16}, "tool_cannon": {"max": 8}, "toy_gambling_wodden_crate": {"max": 64},
	"debris_chunk": {"max": 64}, "tool_panel": {"max": 32}, "meta_thing": {"max": 32}, "tiny": {"max": 2}}


class Pool:
	var max_size := 0
	var available: Array[Node3D] = []
	var active: Array[Node3D] = []


var _pools: Dictionary = {}
var _initialized := false
var _container: Node3D = null
var gravity := true
var spawn_calls := 0
var recycle_calls := 0


func setup(container: Node3D) -> void:
	_container = container
	for id in POOL_CONFIG:
		var p := Pool.new()
		p.max_size = int(POOL_CONFIG[id].max)
		_pools[id] = p
	_initialized = true


func _make(pool_id: String) -> Node3D:
	var b: RigidBody3D = FakeMetaBody.new() if pool_id == "meta_thing" else FakeBody.new()
	var cs := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = Vector3(0.3, 0.3, 0.3)
	cs.shape = sh
	b.add_child(cs)
	b.mass = 1.0
	b.gravity_scale = 1.0 if gravity else 0.0
	b.can_sleep = true
	b.angular_damp = 1.0
	b.linear_damp = 0.1
	if pool_id.begins_with("duck"):
		b.add_to_group("product")
	_container.add_child(b)
	return b


## parked bodies sit far below the map (as the real pools do)
const PARK_AT := Vector3(0, -10000, 0)


func _pool_of(pool_id: String) -> Pool:
	return _pools.get(pool_id)


## spawn effects: placed, shown, processing, unfrozen and at rest, then on_pool_spawn
func _wake(obj: Node3D, at: Vector3, rot: Vector3) -> void:
	obj.global_transform = Transform3D(Basis.from_euler(rot), at)
	obj.show()
	obj.process_mode = PROCESS_MODE_PAUSABLE
	obj.set_meta("consumed", null)
	var rb := obj as RigidBody3D
	if rb != null:
		rb.freeze = false
		rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		rb.sleeping = false
		rb.linear_velocity = Vector3()
		rb.angular_velocity = Vector3()
	obj.on_pool_spawn()


## recycle effects: hidden, not processing, parked and asleep, then on_pool_recycle
func _park(obj: Node3D) -> void:
	obj.hide()
	obj.process_mode = PROCESS_MODE_DISABLED
	obj.position = PARK_AT
	var rb := obj as RigidBody3D
	if rb != null:
		rb.sleeping = true
		rb.linear_velocity = Vector3()
		rb.angular_velocity = Vector3()
	obj.on_pool_recycle()


func spawn(pool_id: String, position := Vector3.ZERO, rotation := Vector3.ZERO) -> Node3D:
	var pool := _pool_of(pool_id)
	if pool == null:
		return null
	spawn_calls += 1
	var obj: Node3D
	if pool.available.size() > 0:
		obj = pool.available.pop_back()
	elif pool.available.size() + pool.active.size() < pool.max_size:
		obj = _make(pool_id)
	else:
		return null
	obj.pool_id = pool_id
	_wake(obj, position, rotation)
	pool.active.push_back(obj)
	return obj


func recycle(obj: Node3D) -> void:
	if not is_instance_valid(obj):
		return
	for pool in _pools.values():
		var at: int = pool.active.find(obj)
		if at == -1:
			continue
		recycle_calls += 1
		pool.active.remove_at(at)
		pool.available.push_back(obj)
		_park(obj)
		return


func active_total() -> int:
	var n := 0
	for id in _pools:
		n += _pools[id].active.size()
	return n
