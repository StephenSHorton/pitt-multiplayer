extends "res://scripts/orbit_tool.gd"
## MP2 4.5: captures, orbit transforms and releases run on the host (orbiting bodies
## stream as entities); toggles go to the host.

const G = preload("../../gameplay/mp_gate.gd")


func _try_capture(body: Node) -> bool:
	if G.sink(self):
		return false
	return super(body)


func _capture_sweep() -> void:
	if G.sink(self):
		return
	super()


func _capture_body(body: RigidBody3D) -> void:
	if G.sink(self):
		return
	G.consumed(body, "orbit")
	super(body)


func _write_orbit_position(idx: int) -> void:
	if G.sink(self):
		return
	super(idx)


func _check_for_releases() -> void:
	if G.sink(self):
		return
	super()


func _release_at_index(idx: int, velocity_override: Variant = null) -> void:
	if G.sink(self):
		return
	super(idx, velocity_override)


func _release_all() -> void:
	if G.sink(self):
		return
	super()


func _drop_maw_claimed_body(idx: int) -> void:
	if G.sink(self):
		return
	super(idx)


func interact() -> void:
	if G.input(self, "interact"):
		return
	super()


func toggle_orbit() -> void:
	if G.input(self, "toggle_orbit"):
		return
	super()


func remote_toggle(on: bool) -> void:
	if G.replay(self):
		return
	super(on)
