extends "res://scripts/gambling_terminal.gd"
## MP2 4.2: sweeping, banking and rolling run on the host (the bank is mirrored;
## arcing bodies stream as normal entities). A remote owner loses a body the
## terminal claims.

const G = preload("../../gameplay/mp_gate.gd")


func _on_collector_body_entered(body: Node) -> void:
	if G.sink(self):
		return
	super(body)


func _collect(groups: Array, require_unplaced: bool) -> Array:
	if G.sink(self):
		return []
	return super(groups, require_unplaced)


func _sweep(groups: Array, require_unplaced: bool) -> void:
	if G.sink(self):
		return
	super(groups, require_unplaced)


func _arc_to_intake(body: Node, delay: float = 0.0) -> bool:
	if G.sink(self):
		return false
	G.consumed(body, "terminal")
	return super(body, delay)


func _bank_and_despawn(body: Node) -> void:
	if G.sink(self):
		return
	G.consumed(body, "terminal")
	super(body)


func _despawn(body: Node) -> void:
	if G.sink(self):
		return
	super(body)


func _do_roll_or_stop() -> void:
	if G.sink(self):
		return
	super()
	G.host_after(self)


func _resolve(mult: float) -> void:
	if G.sink(self):
		return
	super(mult)
	G.host_after(self)


func _spawn_recycle_cube(payout: int) -> void:
	if G.sink(self):
		return
	super(payout)


func sweep_tools_all() -> void:
	if G.sink(self):
		return
	super()
