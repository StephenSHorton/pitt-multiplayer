extends "res://scripts/camera_pivot.gd"
## MP2 4.2: security cameras break on the host (fine, BAD); clients apply the
## destroyed state from meta.

const G = preload("../../gameplay/mp_gate.gd")


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if G.sink(self):
		return
	super(state)


func destroy_camera():
	if G.sink(self):
		return
	var was: bool = is_destroyed
	super()
	if not was and is_destroyed:
		G.ach("BAD")
		G.host_after(self)
