extends "res://scripts/gravity_inverter.gd"
## MP2 4.5: toggles go to the host; the field acts on puppets inertly and on the
## local player through its own copy (D10).

const G = preload("../../gameplay/mp_gate.gd")


func toggle_field() -> void:
	if G.input(self, "toggle_field"):
		return
	super()


func interact() -> void:
	if G.input(self, "interact"):
		return
	super()


func remote_toggle(on: bool) -> void:
	if G.replay(self):
		return
	super(on)
