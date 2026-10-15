extends RigidBody3D
## A pooled body for the BODIES headless tests: what ObjectPoolManager.spawn
## needs (pool_id) plus counters of the pool hooks.

var pool_id := ""
var spawns := 0
var recycles := 0


func on_pool_spawn() -> void:
	spawns += 1


func on_pool_recycle() -> void:
	recycles += 1
