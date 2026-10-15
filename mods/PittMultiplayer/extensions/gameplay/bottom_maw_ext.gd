extends "res://scripts/bottom_maw.gd"
## MP2 4.2: the maw consumes on the host only. On a client only the local player's
## own branch runs (respawn, death screen, tube wobble); its local fine is reverted
## by the money clamp and charged once by the host (penalty "maw"). Host: maw effects
## go to every client; a remote owner loses a consumed body.

const G = preload("../../gameplay/mp_gate.gd")


func _on_body_entered(body):
	if G.sink(self):
		if G.is_local_player(body):
			var ending := G.ending_active()
			super(body)
			if not ending:
				G.penalty("maw")    # in the ending the maw takes the player without a fine
		return
	super(body)
	if G.is_host() and is_instance_valid(body) and body is Node \
			and (body.get_meta("consumed", false) or body.get_meta("pending_maw_recycle", false)):
		G.consumed(body, "maw")


func _handle_body_cleanup(body: Node3D, product_type: String, should_free: bool):
	if G.sink(self) and product_type != "player":
		return
	await super(body, product_type, should_free)


func _recycle(body):
	if G.sink(self):
		return
	super(body)


func maw_effect(object_type: String, body_position: Vector3):
	super(object_type, body_position)
	G.fx("maw", self, {"type": object_type, "p": [body_position.x, body_position.y, body_position.z]})
