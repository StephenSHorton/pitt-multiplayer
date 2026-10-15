extends "res://scripts/ore_processor.gd"
## MP2 4.2: ore and pickaxe intake, the mining bank and the UV lamp run on the host;
## clients only refresh the labels from the mirrored bank.

const G = preload("../../gameplay/mp_gate.gd")


func _on_intake_body_entered(body: Node3D) -> void:
	if G.sink(self):
		return
	if body is RigidBody3D and (body.is_in_group("mining_ore") or body.is_in_group("pickaxe")):
		G.consumed(body, "ore_processor")
	super(body)
	G.host_after(self)


func _process_ore(ore: RigidBody3D) -> void:
	if G.sink(self):
		return
	super(ore)


func _process_pickaxe(pickaxe: RigidBody3D) -> void:
	if G.sink(self):
		return
	super(pickaxe)


func _drop_at_output(body: RigidBody3D) -> void:
	if G.sink(self):
		return
	super(body)


func place_lamp_at_output(announce: bool = false) -> void:
	if G.sink(self):
		return
	super(announce)


func reconcile_lost_ore() -> void:
	if G.sink(self):
		return
	super()


func _on_save_loaded() -> void:
	if G.sink(self):
		_update_labels()
		return
	super()
