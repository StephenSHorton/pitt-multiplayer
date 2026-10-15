extends "res://scripts/mining_ore.gd"
## MP2 4.2: a fail-safe recovery credits the mining bank on the host only.

const G = preload("../../gameplay/mp_gate.gd")


func recover_to_home() -> void:
	if G.sink(self):
		return
	super()
