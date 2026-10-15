extends "res://scripts/anomaly.gd"
## MP2 4.3: anomaly impact handling on the host (its impulses on puppets are inert).

const G = preload("../../gameplay/mp_gate.gd")


func _process_impact_deferred(body: Node, impact_force: float, is_tool: bool) -> void:
	if G.sink(self):
		return
	await super(body, impact_force, is_tool)
