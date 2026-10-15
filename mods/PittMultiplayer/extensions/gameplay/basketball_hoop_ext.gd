extends "res://scripts/basketball_hoop.gd"
## MP2 4.2: dunk tickets and bonuses on the host (its text reaches clients through
## the HUD bonus text).

const G = preload("../../gameplay/mp_gate.gd")


func _on_rim_body_entered(body: Node3D) -> void:
	if G.sink(self):
		return
	super(body)


func _on_product_consumed(_product_type: String, base_value: int, body_id: int = -1) -> void:
	if G.sink(self):
		return
	super(_product_type, base_value, body_id)


func _award_dunk_bonus(bonus: int) -> void:
	if G.sink(self):
		return
	await super(bonus)
