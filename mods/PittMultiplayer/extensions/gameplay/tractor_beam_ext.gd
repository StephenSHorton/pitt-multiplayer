extends "res://scripts/tractor_beam.gd"
## MP2 4.5 / 6.4: equipped input goes to the host as tool_in (the rig copy pulls)
## while the local copy shows the beam (input_predict); toggles go to the host.

const G = preload("../../gameplay/mp_gate.gd")


func equipped_lmb_pressed() -> void:
	if G.input_predict(self, "equipped_lmb_pressed"):
		return
	super()


func equipped_lmb_released() -> void:
	if G.input_predict(self, "equipped_lmb_released"):
		return
	super()


func equipped_rmb_pressed() -> void:
	if G.input_predict(self, "equipped_rmb_pressed"):
		return
	super()


func toggle_beam() -> void:
	if G.input(self, "toggle_beam"):
		return
	super()


func interact() -> void:
	if G.input(self, "interact"):
		return
	super()


func remote_toggle(on: bool) -> void:
	if G.replay(self):
		return
	super(on)
