extends "res://scripts/golf_club.gd"
## MP2 4.2 / 6.4: a client's shot goes to the host as tool_in mp_golf_shot {ball,
## power}; the host fires from the rig (the club's parent camera). The swing and the
## aim-mode exit play locally. Hole-in-one bonuses on the host.

const G = preload("../../gameplay/mp_gate.gd")


func _input(event: InputEvent) -> void:
	G.begin_input_scope()
	super(event)
	G.end_input_scope()


func _fire_shot() -> void:
	if G.is_client() and not G.applying():
		if G.in_input_scope() and is_instance_valid(golf_ball):
			G.forward(self, "mp_golf_shot", [golf_ball, power_ratio])
		# the swing and leaving aim mode stay local
		var swing := power_ratio
		_play_swing_animation(swing)
		_exit_aim_mode()
		return
	super()


## Host (tool_in from the owner of this equipped club).
func mp_golf_shot(ball: Node, power: float) -> void:
	if not G.is_host() or not (ball is RigidBody3D):
		return
	golf_ball = ball
	power_ratio = clampf(power, 0.0, 1.0)
	_fire_shot()


func _on_product_consumed(_product_type: String, _nutrition_value: int, body_id: int = -1) -> void:
	if G.sink(self):
		return
	super(_product_type, _nutrition_value, body_id)


func _award_hole_in_one_delayed(bonus: int, maw_pos: Vector3) -> void:
	if G.sink(self):
		return
	await super(bonus, maw_pos)
