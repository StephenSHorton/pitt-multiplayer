extends "res://scripts/vacuum_2.gd"
## MP2 4.5: tuning and the filter go to the host. Intake, bag and equipped input
## are vacuum_ext's (applied first, so this script's base is the extended vacuum.gd).

const G = preload("../../gameplay/mp_gate.gd")


func scroll_tune_up() -> void:
	if G.input(self, "scroll_tune_up"):
		return
	super()


func scroll_tune_down() -> void:
	if G.input(self, "scroll_tune_down"):
		return
	super()


func cycle_filter(direction: int) -> void:
	if G.input(self, "cycle_filter", [direction]):
		return
	super(direction)


func remote_toggle(on: bool) -> void:
	if G.replay(self):
		return
	super(on)
