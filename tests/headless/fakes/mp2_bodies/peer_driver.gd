extends Node
## Runs this peer's loader reconciler every physics frame before the game
## scripts and BODIES (PittAPI._physics_process does it in the game).

var api = null


func _init(p_api = null) -> void:
	api = p_api
	process_physics_priority = -50


func _physics_process(delta: float) -> void:
	if api != null and api.entities_reg != null:
		api.entities_reg.reconcile(delta)
