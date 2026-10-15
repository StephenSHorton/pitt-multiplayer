extends "res://scripts/speed_radar.gd"
## MP2 4.2: speeding tickets and bonuses on the host; flashes replay on clients. The
## local player running past a client's radar still sees its own speed (cosmetic).

const G = preload("../../gameplay/mp_gate.gd")


func _on_detection_body_entered(body: Node3D) -> void:
	if G.sink(self):
		if G.is_local_player(body):
			super(body)
		return
	super(body)


func _on_product_consumed(_product_type: String, base_value: int, body_id: int = -1) -> void:
	if G.sink(self):
		return
	super(_product_type, base_value, body_id)


func _award_speeding_bonus(bonus: int, speed: float) -> void:
	if G.sink(self):
		return
	await super(bonus, speed)


func _trigger_flash(intensity: float = 1.0) -> void:
	super(intensity)
	G.fx("radar_flash", self, {"intensity": intensity})
