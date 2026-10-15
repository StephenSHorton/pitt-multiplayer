extends "res://scripts/vertical_gate.gd"
## MP2 4.6: gates open on the host; clients replay solve() from the solved meta
## (animated, with the game's own notification and Steam gate hook on every peer).
## apply_saved_state stays ungated (snapshot load path).

const G = preload("../../gameplay/mp_gate.gd")


func solve():
	if G.replay(self):
		return
	super()
	G.host_after(self)
