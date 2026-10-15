extends "res://scripts/broom.gd"
## MP2 4.5: sweeps run on the host (for a remote holder through tool_in on the rig
## copy); impulses on puppets are inert, the trajectory preview stays local.

const G = preload("../../gameplay/mp_gate.gd")


func interact():
	if G.input(self, "interact"):
		return
	await super()
