extends "res://scripts/interact_ray.gd"
## MP2 1.1: the interact ray's dispatchers set the input scope, so a gated method
## reached from them is known to come from the local player.

const G = preload("../../gameplay/mp_gate.gd")


func handle_workbench_interaction():
	G.begin_input_scope()
	super()
	G.end_input_scope()


func _stop_crafting_if_manual(bench: Node) -> void:
	G.begin_input_scope()
	var proxy := bench.has_meta("auto_crafter") and is_instance_valid(bench.get_meta("auto_crafter"))
	if not proxy and G.bench_requested(bench) and bench.get("is_crafting") != true and bench.has_method("stop_crafting"):
		# released before the host's start came back: the game skips a bench that is
		# not crafting, so the forwarded start gets its stop here
		bench.stop_crafting()
	else:
		super(bench)
	G.end_input_scope()


## LMB toggle of automatic workbenches (turn_on / turn_off) runs here, before
## handle_automated_workbench_interaction: inside the input scope it is forwarded.
func _input(event: InputEvent) -> void:
	G.begin_input_scope()
	super(event)
	G.end_input_scope()


func handle_automated_workbench_interaction():
	G.begin_input_scope()
	super()
	G.end_input_scope()


func handle_terminal_interaction(delta: float) -> void:
	G.begin_input_scope()
	super(delta)
	G.end_input_scope()


func handle_button_interaction():
	G.begin_input_scope()
	super()
	G.end_input_scope()
