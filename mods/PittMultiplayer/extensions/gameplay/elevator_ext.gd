extends "res://scripts/elevator.gd"
## MP2 4.6 / D15: the escape ride replays on every client when the host's keypad
## succeeds (fx hack_success, apply scope).

const G = preload("../../gameplay/mp_gate.gd")


func on_hack_success() -> void:
	if G.replay(self):
		return
	await super()
