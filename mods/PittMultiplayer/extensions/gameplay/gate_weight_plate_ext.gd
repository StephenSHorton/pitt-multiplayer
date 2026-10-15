extends "res://scripts/gate_weight_plate.gd"
## MP2 4.6 / D18: the plate solves on the host, where remote players count with the
## player's mass through their ghost colliders. Clients show the mirrored mass.

const G = preload("../../gameplay/mp_gate.gd")


func _physics_process(_delta):
	if G.sink(self):
		return
	super(_delta)


func _recalculate_mass():
	super()
	if G.is_host() and pressure_area != null:
		var ghosts := pressure_area.get_overlapping_bodies().filter(func(b): return G.ghost_peer(b) > 1)
		current_mass += PLAYER_MASS * ghosts.size()
