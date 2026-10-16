extends "res://scripts/workbench.gd"
## MP2 4.4: the manual duck bench crafts on the host. Hold-to-craft from a client
## goes to the host, which keeps a holder set: crafting stops only when the last
## holder releases (the host's own player included). Clients replay start/stop from
## meta and advance the bar locally between updates.

const G = preload("../../gameplay/mp_gate.gd")


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


func craft_item():
	if G.sink(self):
		return
	# the eject shake is the operator's; a remote operator gets it with the fx (0.2.2)
	G.shake_mute = not G.bench_operated_here(self)
	super()
	G.shake_mute = false
	G.fx("bench_eject", self)


## 0.2.2: the HUD progress bar is the operator's only (MP2 4.4, mp_gate.bench_bar_show).
func show_progress_bar(visible_: bool):
	if G.bench_bar_show(self, visible_):
		super(visible_)


func update_progress_bar(value: float):
	if G.bench_bar_value(self):
		super(value)
