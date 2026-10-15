extends "res://scripts/disco_ball.gd"
## MP2 4.5: the toggle goes to the host.

const G = preload("../../gameplay/mp_gate.gd")


func interact() -> void:
	if G.input(self, "interact"):
		return
	super()
