extends "res://scripts/magnet_2.gd"
## MP2 4.5: tuning and the attract/repel flip go to the host (is_repelling meta ->
## flip_mode). The toggles are magnet_ext's (the loader applies magnet_ext first,
## so this script's base is the extended magnet.gd).

const G = preload("../../gameplay/mp_gate.gd")


func scroll_tune_up() -> void:
	if G.input(self, "scroll_tune_up"):
		return
	super()


func scroll_tune_down() -> void:
	if G.input(self, "scroll_tune_down"):
		return
	super()


func flip_mode(direction: bool) -> void:
	if G.replay(self):
		return
	super(direction)
