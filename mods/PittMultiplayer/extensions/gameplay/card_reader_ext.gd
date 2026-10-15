extends "res://scripts/card_reader.gd"
## MP2 4.6: keycards are consumed and the keypad revealed on the host; clients get
## the reveal, the notification and SECRET as effects (keypad_revealed is mirrored).

const G = preload("../../gameplay/mp_gate.gd")


func _on_intake_body_entered(body: Node3D) -> void:
	if G.sink(self):
		return
	var was := bool(G.gs("keypad_revealed", false))
	if body is RigidBody3D and body.is_in_group("keycard"):
		G.consumed(body, "card_reader")
	super(body)
	if not was and bool(G.gs("keypad_revealed", false)):
		G.fx("keypad_reveal")
		G.fx("notify", null, {"key": "NOTIF_KEYPAD_REVEALED"})
		G.ach("SECRET")
