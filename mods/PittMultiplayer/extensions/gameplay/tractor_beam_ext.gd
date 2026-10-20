extends "res://scripts/tractor_beam.gd"
## MP2 4.5 / 6.4: equipped input goes to the host as tool_in (the rig copy pulls)
## while the local copy shows the beam (input_predict); toggles go to the host.

const G = preload("../../gameplay/mp_gate.gd")


## P12 force guard (all modes, single-player too): the beam picks and pulls in one
## game method, so a body in the beam's overlaps without a physics space (parked by
## the pool with process_mode DISABLED) is marked static-frozen, which the game's
## pick already skips, for the length of the call, then restored. It has no space,
## so the round trip changes nothing in the simulation. Bodies in a space, and
## every tick without a parked body, run the game's pull untouched.
func _update_pull(delta: float) -> void:
	var parked: Array = []
	if beam_area != null:
		for b in beam_area.get_overlapping_bodies():
			if not (b is RigidBody3D) or PhysicsServer3D.body_get_space(b.get_rid()).is_valid():
				continue
			if b.freeze and b.freeze_mode == RigidBody3D.FREEZE_MODE_STATIC:
				continue
			parked.append([b, b.freeze, b.freeze_mode])
			b.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
			b.freeze = true
	super(delta)
	for p in parked:
		var rb: RigidBody3D = p[0]
		if is_instance_valid(rb):
			rb.freeze = p[1]
			rb.freeze_mode = p[2]


func equipped_lmb_pressed() -> void:
	if G.input_predict(self, "equipped_lmb_pressed"):
		return
	super()


func equipped_lmb_released() -> void:
	if G.input_predict(self, "equipped_lmb_released"):
		return
	super()


func equipped_rmb_pressed() -> void:
	if G.input_predict(self, "equipped_rmb_pressed"):
		return
	super()


func toggle_beam() -> void:
	if G.input(self, "toggle_beam"):
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
