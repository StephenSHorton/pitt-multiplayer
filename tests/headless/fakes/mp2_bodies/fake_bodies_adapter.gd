extends "res://gamedir/mods/PittMultiplayer/game/bodies_adapter.gd"
## Per-peer BodiesAdapter for the headless tests: the production adapter with
## the game swapped for this peer's own world (a SubViewport with its own
## World3D, so the host's and the client's bodies never touch), its own fake
## pools, player and SaveManager.is_loading flag. Physics pinning is recorded,
## not applied (several peers share one engine).

var pm = null
var world: Node3D = null
var player: Node3D = null
var loading := false
var loading_log: Array = []
var load_ratio := 0.0
var pins := 0
var unpins := 0
var step_limits: Array = []


func pool_manager() -> Object:
	return pm


func is_loading() -> bool:
	return loading


func set_loading(on: bool) -> void:
	loading = on
	loading_log.append(on)


func local_player() -> Node3D:
	return player


func eye_offset() -> Vector3:
	return DEFAULT_EYE


func world_root() -> Node:
	return world


func nodes_in_group(group: String) -> Array:
	var out: Array = []
	for n in tree().get_nodes_in_group(group):
		if world != null and world.is_ancestor_of(n):
			out.append(n)
	return out


func owns(node: Node) -> bool:
	return world != null and is_instance_valid(world) and world.is_ancestor_of(node)


func fixture_path(node: Node) -> String:
	return "/root/World/%s" % String(world.get_path_to(node))


func physics_load() -> float:
	return load_ratio


func pin_physics(_hz: int = 60) -> void:
	pins += 1
	_pinned = true


func unpin_physics() -> void:
	if _pinned:
		unpins += 1
	_pinned = false


## Recorded, never applied (several peers share one engine).
func limit_physics_steps(on: bool) -> void:
	if on != _steps_limited:
		step_limits.append(on)
	_steps_limited = on
