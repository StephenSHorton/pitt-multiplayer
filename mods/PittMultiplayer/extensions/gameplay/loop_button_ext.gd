extends "res://scripts/loop_button.gd"
## MP2 4.6: puzzle buttons act on the host; the press animation plays locally.

const G = preload("../../gameplay/mp_gate.gd")


func interact() -> void:
	if G.input_predict(self, "interact"):
		return
	super()
