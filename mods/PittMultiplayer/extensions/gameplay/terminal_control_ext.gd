extends "res://scripts/terminal_control.gd"
## MP2 4.2: the terminal's buttons and levers act on the host (sweep products /
## tools, roll, hold-to-sweep-all). The hold bar stays local.

const G = preload("../../gameplay/mp_gate.gd")


func interact() -> void:
	if G.input(self, "interact"):
		return
	super()


func hold_complete() -> void:
	if G.input(self, "hold_complete"):
		return
	super()
