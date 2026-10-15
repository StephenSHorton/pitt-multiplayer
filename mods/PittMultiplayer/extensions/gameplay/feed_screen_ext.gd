extends "res://scripts/feed_screen.gd"
## MP2 4.5: cycling the watched camera goes to the host (watched_camera_id meta).

const G = preload("../../gameplay/mp_gate.gd")


func interact() -> void:
	if G.input(self, "interact"):
		return
	super()
