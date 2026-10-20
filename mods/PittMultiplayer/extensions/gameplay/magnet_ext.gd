extends "res://scripts/magnet.gd"
## MP2 4.5: toggles go to the host; attraction on puppets is inert.

const G = preload("../../gameplay/mp_gate.gd")


## P12 force guard (all modes, single-player too): the pick runs as before, then a
## target whose body has no physics space (parked by the pool with process_mode
## DISABLED, or out of the tree) is dropped, so the pull never reaches it (an
## engine error otherwise). magnet_2 inherits this (its base is this extended
## magnet.gd and it keeps magnet.gd's pick).
func _update_active_targets():
	super()
	for i in range(active_targets.size() - 1, -1, -1):
		var b = active_targets[i]
		if is_instance_valid(b) and not PhysicsServer3D.body_get_space(b.get_rid()).is_valid():
			active_targets.remove_at(i)


func toggle_magnet():
	if G.input(self, "toggle_magnet"):
		return
	super()


func interact():
	if G.input(self, "interact"):
		return
	super()


func remote_toggle(on: bool):
	if G.replay(self):
		return
	super(on)
