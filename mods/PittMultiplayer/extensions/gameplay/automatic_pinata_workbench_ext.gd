extends "res://scripts/automatic_pinata_workbench.gd"
## MP2 4.4: the automatic pinata bench runs on the host (toggle through the host);
## the pinata spawn is host-only.

const G = preload("../../gameplay/mp_gate.gd")


func turn_on():
	if G.input(self, "turn_on"):
		return
	super()


func turn_off():
	if G.input(self, "turn_off"):
		return
	super()


## Its own timer (_process) starts a cycle: machine-originated, host only; clients
## replay the start from meta. stop_crafting stays local (end of the animation).
func start_crafting():
	if G.input(self, "start_crafting"):
		return
	super()


func _spawn_pinata():
	if G.sink(self):
		return
	super()
