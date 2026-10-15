extends "res://scripts/piston_2.gd"
## MP2 4.5: tuning and presets go to the host (preset meta -> set_preset). Riders
## and toggles are piston_ext's (applied first; piston_3 extends this one).

const G = preload("../../gameplay/mp_gate.gd")


func scroll_tune_up() -> void:
	if G.input(self, "scroll_tune_up"):
		return
	super()


func scroll_tune_down() -> void:
	if G.input(self, "scroll_tune_down"):
		return
	super()


func cycle_preset(direction: int) -> void:
	if G.input(self, "cycle_preset", [direction]):
		return
	super(direction)


func set_preset(index: int, play_feedback: bool) -> void:
	if G.replay(self):
		return
	super(index, play_feedback)
