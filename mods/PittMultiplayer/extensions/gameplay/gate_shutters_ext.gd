extends "res://scripts/gate_shutters.gd"
## MP2 4.6: fuses are slotted on the host (slots meta -> apply_shutters_saved_state
## on clients; the fuses are fixture bodies).

const G = preload("../../gameplay/mp_gate.gd")


func _on_fuse_slot_body_entered(body: Node3D, slot_index: int):
	if G.sink(self):
		return
	G.consumed(body, "fuse_slot")
	super(body, slot_index)
	G.host_after(self)
