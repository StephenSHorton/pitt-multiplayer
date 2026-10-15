extends "res://scripts/hole.gd"
## PittMultiplayer: the maw/hole on clients (MP-DESIGN 6.4, MP2-DESIGN 3.8).
## Inert unless a session is live and this peer is a client. In MP2 only the
## host's maw consumes (clients' copies are gated by GAMEPLAY), so feeding needs
## no forwarding: _on_product_consumed keeps the vanilla path. A client never
## completes a phase or triggers the ending itself; the host's hole state and
## phase arrive through the session.


func _mp() -> Object:
	return Engine.get_meta("pitt_mp", null) if Engine.has_meta("pitt_mp") else null


func _check_phase_completion():
	var mp := _mp()
	if mp != null and mp.has_method("ext_block_hole_progress") and mp.ext_block_hole_progress():
		return
	super()


func _trigger_ending():
	var mp := _mp()
	if mp != null and mp.has_method("ext_block_hole_progress") and mp.ext_block_hole_progress():
		return
	super()
