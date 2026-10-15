extends "res://scripts/minable_block.gd"
## MP2 4.2: hits, breaking and ore drops run on the host (damage/broken meta);
## hit sounds replay on clients.

const G = preload("../../gameplay/mp_gate.gd")


func take_hit(amount: float) -> void:
	if G.sink(self):
		return
	super(amount)
	G.host_after(self)


func _on_impact_area_body_entered(body: Node3D) -> void:
	if G.sink(self):
		return
	super(body)


func _break_block() -> void:
	if G.sink(self):
		return
	super()
	G.host_after(self)


func _spawn_ore() -> void:
	if G.sink(self):
		return
	super()


func _play_hit() -> void:
	super()
	G.fx("block_hit", self)
