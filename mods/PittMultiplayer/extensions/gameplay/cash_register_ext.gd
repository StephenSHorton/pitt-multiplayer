extends "res://scripts/cash_register.gd"
## MP2 4.3: draining and depletion on the host (value meta); the destroy effect
## replays on clients.

const G = preload("../../gameplay/mp_gate.gd")


func _drain_value():
	if G.sink(self):
		return
	super()


func _on_depleted():
	if G.sink(self):
		return
	G.consumed(self, "depleted")
	super()


func on_whacked(force: float) -> void:
	if G.sink(self):
		return
	super(force)


func _spawn_destroy_effect():
	super()
	G.fx("register_depleted", self)
