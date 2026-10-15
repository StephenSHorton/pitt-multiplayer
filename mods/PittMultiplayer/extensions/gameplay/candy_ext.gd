extends "res://scripts/candy.gd"
## MP2 4.3: candy expires on the host; the pop replays on clients.

const G = preload("../../gameplay/mp_gate.gd")


func _expire() -> void:
	if G.sink(self):
		return
	G.consumed(self, "expired")
	super()


func _spawn_expire_effects() -> void:
	super()
	G.fx("candy_expire", self)
