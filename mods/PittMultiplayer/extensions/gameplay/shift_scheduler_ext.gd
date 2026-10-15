extends "res://scripts/shift_scheduler.gd"
## MP2 4.4: schedules tick and press their targets on the host; a client's
## interact/tuning goes to the host, the screen follows the scheduler meta.

const G = preload("../../gameplay/mp_gate.gd")


func _tick_schedule(delta: float) -> void:
	if G.sink(self):
		return
	super(delta)


func _press_target() -> void:
	if G.sink(self):
		return
	super()


func _apply_state(on: bool) -> void:
	if G.sink(self):
		return
	super(on)


func interact():
	if G.input(self, "interact"):
		return
	super()


func scroll_tune_up():
	if G.input(self, "scroll_tune_up"):
		return
	super()


func scroll_tune_down():
	if G.input(self, "scroll_tune_down"):
		return
	super()


func scroll_tune_cycle():
	if G.input(self, "scroll_tune_cycle"):
		return
	super()


func remote_toggle(on: bool) -> void:
	if G.replay(self):
		return
	super(on)
