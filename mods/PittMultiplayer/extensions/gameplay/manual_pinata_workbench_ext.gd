extends "res://scripts/manual_pinata_workbench.gd"
## MP2 4.4: the manual pinata bench crafts on the host (holder set as the duck
## bench); the sewing animation runs locally, the pinata spawn is host-only.

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


func _spawn_pinata():
	if G.sink(self):
		return
	super()
