extends "res://scripts/qa_arm.gd"
## MP2 4.5: the arm's state machine, aiming and whacks run on the host; clients pose
## the turret and bat from meta (15 Hz). A whack on a remote player's ghost goes to
## that player as an impulse (the game's own player branch values) and counts a
## safety violation on the host.

const G = preload("../../gameplay/mp_gate.gd")


func _physics_process(delta: float) -> void:
	if G.sink(self):
		return
	super(delta)
	# keep the turret pose streaming (BODIES polls a pooled entity's meta at the
	# adapter rate only while it is hot)
	if _state != 0 and Engine.get_physics_frames() % 30 == 0:
		G.host_after(self)


func _fire(intercept: Dictionary) -> void:
	if G.sink(self):
		return
	super(intercept)


func _whack(body: Node) -> void:
	if G.sink(self):
		return
	var peer := G.ghost_peer(body)
	if peer > 1 and G.is_host():
		var id: int = body.get_instance_id()
		if _whacked.has(id):
			return
		_whacked[id] = true
		var pdir: Vector3 = (body as Node3D).global_position - turret_pivot.global_position
		pdir.y = 0.0
		G.remote_impulse(peer, pdir.normalized() * player_bonk_impulse + Vector3.UP * player_bonk_lift, "qa_arm")
		G.safety_violation()
		_play_whack_audio()
		return
	super(body)


func interact() -> void:
	if G.input(self, "interact"):
		return
	super()


func toggle_arm() -> void:
	if G.input(self, "toggle_arm"):
		return
	super()


func remote_toggle(on: bool) -> void:
	if G.replay(self):
		return
	super(on)
