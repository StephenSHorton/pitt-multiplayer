extends "res://scripts/spring_pad.gd"
## MP2 4.2: launch bonuses on the host. Launching keeps running everywhere: puppets
## are inert, the local player is launched by its own copy (D10).

const G = preload("../../gameplay/mp_gate.gd")


func _register_bonus_ticket(body: RigidBody3D, mult: float, chain_index: int) -> void:
	if G.sink(self):
		return
	super(body, mult, chain_index)


func _on_product_consumed(_product_type: String, base_value: int, body_id: int = -1) -> void:
	if G.sink(self):
		return
	super(_product_type, base_value, body_id)


func _award_launch_bonus(bonus: int, chain_count: int) -> void:
	if G.sink(self):
		return
	await super(bonus, chain_count)
