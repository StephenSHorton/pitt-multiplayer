extends "res://scripts/piston.gd"
## MP2 4.5: riders are adopted and released on the host; the pusher advances its
## phase locally (deterministic, corrected by the piston meta) and pushes the local
## player (D10). Toggles go to the host. apply_piston_save_data stays ungated (load
## path and BODIES meta apply).

const G = preload("../../gameplay/mp_gate.gd")


func _scan_for_riders() -> void:
	if G.sink(self):
		return
	super()


func _adopt_rider(body: RigidBody3D) -> void:
	if G.sink(self):
		return
	super(body)


func _release_rider(index: int, restore_freeze: bool = true) -> void:
	if G.sink(self):
		return
	super(index, restore_freeze)


func release_all_riders(restore_freeze: bool = true) -> void:
	if G.sink(self):
		return
	super(restore_freeze)


func release_rider_body(b: Node) -> void:
	if G.sink(self):
		return
	super(b)


func interact() -> void:
	if G.input(self, "interact"):
		return
	super()


func toggle_piston() -> void:
	if G.input(self, "toggle_piston"):
		return
	super()


func remote_toggle(on: bool) -> void:
	if G.replay(self):
		return
	super(on)
