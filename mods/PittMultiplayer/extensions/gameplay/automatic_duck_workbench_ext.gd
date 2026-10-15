extends "res://scripts/automatic_duck_workbench.gd"
## MP2 4.4: the automatic duck bench runs on the host; a client toggles it through
## the host. Products appear as entities with the host's launch velocity.

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


func craft_item():
	if G.sink(self):
		return
	super()
