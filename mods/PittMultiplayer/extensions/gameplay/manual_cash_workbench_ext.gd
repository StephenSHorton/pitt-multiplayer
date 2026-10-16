extends "res://scripts/manual_cash_workbench.gd"
## MP2 4.4: the manual cash bench crafts on the host (holder set as the duck bench).
## The piston and weld animation run locally from the replayed start; only the
## register spawn is host-only.

const G = preload("../../gameplay/mp_gate.gd")


func interact():
	if G.input(self, "interact"):
		return
	super()


func start_crafting():
	if G.bench_start(self):
		return
	super()


func stop_crafting():
	if G.bench_stop(self) or not G.bench_release(self):
		# released here while it keeps crafting (another player still holds): our bar goes
		if not G.bench_operated_here(self):
			show_progress_bar(false)
		return
	super()


func _spawn_cash_register():
	if G.sink(self):
		return
	super()


## 0.2.2: the HUD progress bar is the operator's only (MP2 4.4, mp_gate.bench_bar_show).
func show_progress_bar(visible_: bool):
	if G.bench_bar_show(self, visible_):
		super(visible_)


func update_progress_bar(value: float):
	if G.bench_bar_value(self):
		super(value)


## The eject (animation on every peer) shakes only the operator's camera (0.2.2).
func _on_piston_reached_top():
	G.shake_mute = not G.bench_operated_here(self)
	super()
	G.shake_mute = false
