extends "res://scripts/broom.gd"
## MP2 4.5: sweeps run on the host (for a remote holder through tool_in on the rig
## copy); impulses on puppets are inert, the trajectory preview stays local.

const G = preload("../../gameplay/mp_gate.gd")


func interact():
	if G.input(self, "interact"):
		return
	await super()


## Host: the outlines and trajectory of a broom on a remote player's rig are that
## player's own feedback (their copy draws them); the host draws nothing (0.2.2).
func _update_preview() -> void:
	if G.remote_owned(self):
		_clear_preview()
		return
	super()
