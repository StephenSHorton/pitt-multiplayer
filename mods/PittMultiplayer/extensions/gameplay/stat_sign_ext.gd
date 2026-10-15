extends "res://scripts/stat_sign.gd"
## MP2 4.5: paging goes to the host (stat_index meta; the pages read mirrored stats).

const G = preload("../../gameplay/mp_gate.gd")


func interact() -> void:
	if G.input(self, "interact"):
		return
	super()
