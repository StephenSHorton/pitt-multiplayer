extends "res://scripts/fan.gd"
## MP2 4.5: toggles go to the host; is_active is applied with remote_toggle. The
## blowing itself needs no gate (forces on puppets are inert; the local player is
## pushed by its own copy, D10).

const G = preload("../../gameplay/mp_gate.gd")


func toggle_fan():
	if G.input(self, "toggle_fan"):
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
