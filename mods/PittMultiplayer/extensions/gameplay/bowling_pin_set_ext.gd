extends "res://scripts/bowling_pin_set.gd"
## MP2 4.6: knockdowns and the multiplier run on the host (the combo mirror carries
## bowling_multiplier). Pins are fixture bodies keyed bowling:pin:<gen>:<i>: the host
## starts a generation on every (re)spawn, clients replay the spawn for that
## generation (meta gp_bowling) and adopt the same keys. Bowling texts replay.

const G = preload("../../gameplay/mp_gate.gd")


func _spawn_pins() -> void:
	if G.replay(self):
		return
	super()
	G.pins_spawned(self)


func _despawn_pins() -> void:
	if G.replay(self):
		return
	G.pins_despawned(self)
	super()


func _check_pin_states() -> void:
	if G.sink(self):
		return
	super()


func _register_knockdown(pin: RigidBody3D) -> void:
	if G.sink(self):
		return
	super(pin)


func _update_multiplier() -> void:
	if G.sink(self):
		return
	super()


func _push_multiplier(value: float) -> void:
	if G.sink(self):
		return
	super(value)


func _spawn_bowling_label(value: float) -> void:
	super(value)
	G.fx("bowling_text", self, {"value": value})
