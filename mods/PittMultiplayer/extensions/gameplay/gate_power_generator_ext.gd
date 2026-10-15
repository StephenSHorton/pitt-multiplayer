extends "res://scripts/gate_power_generator.gd"
## MP2 4.6: the generator consumes products and powers up on the host (meta ->
## apply_generator_saved_state on clients).

const G = preload("../../gameplay/mp_gate.gd")


func _physics_process(delta: float) -> void:
	if G.sink(self):
		return
	super(delta)


func _on_intake_body_entered(body: Node3D):
	if G.sink(self):
		return
	G.consumed(body, "generator")
	super(body)
	G.host_after(self)


func _trigger_power_up():
	if G.sink(self):
		return
	await super()
