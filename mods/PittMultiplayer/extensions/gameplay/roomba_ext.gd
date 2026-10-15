extends "res://scripts/roomba.gd"
## MP2 4.5: the roomba drives on the host (a puppet elsewhere); toggles go to the host.

const G = preload("../../gameplay/mp_gate.gd")


func interact() -> void:
	if G.input(self, "interact"):
		return
	super()


func remote_toggle(on: bool) -> void:
	if G.replay(self):
		return
	super(on)
