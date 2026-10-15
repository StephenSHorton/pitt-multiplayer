extends "res://scripts/magnet.gd"
## MP2 4.5: toggles go to the host; attraction on puppets is inert.

const G = preload("../../gameplay/mp_gate.gd")


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
