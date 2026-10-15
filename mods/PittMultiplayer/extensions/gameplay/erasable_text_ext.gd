extends "res://scripts/erasable_text.gd"
## MP2 4.2: the cleaning reward is paid on the host; scrubbing stays local.

const G = preload("../../gameplay/mp_gate.gd")


func _award_clean() -> void:
	if G.sink(self):
		return
	super()


func _apply_fully_erased() -> void:
	super()
	G.host_after(self)
