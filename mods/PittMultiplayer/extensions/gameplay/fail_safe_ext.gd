extends "res://scripts/fail_safe.gd"
## MP2 4.2: fail-safes recover bodies on the host. On a client only the local
## player's own branch runs (respawn); its local fine is reverted by the money clamp
## and charged once by the host (penalty "fail_safe").

const G = preload("../../gameplay/mp_gate.gd")


func _on_body_entered(body: Node) -> void:
	if G.sink(self):
		if G.is_local_player(body):
			super(body)
			G.penalty("fail_safe")
		return
	if body is RigidBody3D:
		G.consumed(body, "fail_safe")
	super(body)
	if body is RigidBody3D:
		G.mark_snap(body)
