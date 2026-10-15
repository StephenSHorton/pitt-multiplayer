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
	if G.bench_stop(self):
		return
	if not G.bench_release(self):
		return
	super()


func _spawn_cash_register():
	if G.sink(self):
		return
	super()
