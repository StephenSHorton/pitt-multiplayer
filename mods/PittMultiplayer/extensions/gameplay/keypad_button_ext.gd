extends "res://scripts/keypad_button.gd"
## MP2 4.6: a key press goes to the host; the press animation plays locally.

const G = preload("../../gameplay/mp_gate.gd")


func interact() -> void:
	if G.input_predict(self, "interact"):
		return
	super()
