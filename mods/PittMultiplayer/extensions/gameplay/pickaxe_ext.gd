extends "res://scripts/pickaxe.gd"
## MP2 4.5: hits, tool breaking and tier upgrades on the host (the rig copy swings
## from the remote player's view); the local swing plays for feedback
## (input_predict). The tier visual follows the mirrored pickaxe_tier.

const G = preload("../../gameplay/mp_gate.gd")


var _mp_in_held := false


func _resolve_hit() -> void:
	if G.sink(self):
		return
	super()


func _break_tool(t: Node3D) -> void:
	if G.sink(self):
		return
	G.consumed(t, "pickaxe")
	super(t)


func upgrade_tier() -> bool:
	if G.sink(self):
		return false
	return super()


func equipped_lmb_pressed() -> void:
	if not _mp_in_held and G.input_predict(self, "equipped_lmb_pressed"):
		return
	super()


func equipped_lmb_held() -> void:
	if G.input_predict(self, "equipped_lmb_held"):
		return
	_mp_in_held = true
	super()
	_mp_in_held = false
