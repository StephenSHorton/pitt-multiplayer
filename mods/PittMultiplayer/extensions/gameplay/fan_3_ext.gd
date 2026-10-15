extends "res://scripts/fan_3.gd"
## MP2 4.5: the zero-g fan writes gravity_scale on bodies: host only. Toggles go to
## the host.

const G = preload("../../gameplay/mp_gate.gd")


func _apply_zero_g(rb: RigidBody3D) -> void:
	if G.sink(self):
		return
	super(rb)


func _tick_zero_g(_delta: float) -> void:
	if G.sink(self):
		return
	super(_delta)


func _restore_gravity(body: RigidBody3D, original_gravity: float) -> void:
	if G.sink(self):
		return
	super(body, original_gravity)


func _flush_all_zero_g() -> void:
	if G.sink(self):
		return
	super()


func toggle_fan() -> void:
	if G.input(self, "toggle_fan"):
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
