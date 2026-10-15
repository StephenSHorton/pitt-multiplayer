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
	if G.bench_stop(self):
		return
	if not G.bench_release(self):
		return
	super()


func craft_item():
	if G.sink(self):
		return
	super()
