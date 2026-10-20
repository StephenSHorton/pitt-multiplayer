extends "res://scripts/gravity_inverter.gd"
## MP2 4.5: toggles go to the host; the field acts on puppets inertly and on the
## local player through its own copy (D10).

const G = preload("../../gameplay/mp_gate.gd")


## P12 force guard (all modes, single-player too): ObjectPoolManager parks a body
## with process_mode DISABLED, which takes it out of the physics space while the
## field areas may still list it, and a force on it is an engine error ("without a
## physics space"). Such bodies are dropped before the game filters and caps its
## targets, so they neither take a target slot nor get woken; bodies in a space
## pass through unchanged.
func _filter_and_cap(raw_bodies: Array) -> Array[RigidBody3D]:
	var spaced: Array = []
	for b in raw_bodies:
		if b is RigidBody3D and not PhysicsServer3D.body_get_space(b.get_rid()).is_valid():
			continue
		spaced.append(b)
	return super(spaced)


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
