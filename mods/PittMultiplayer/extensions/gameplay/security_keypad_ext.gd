extends "res://scripts/security_keypad.gd"
## MP2 4.6 / D15: code entry and the hack run on the host (entry meta); a successful
## hack sends every peer through its own escape ride (fx hack_success).

const G = preload("../../gameplay/mp_gate.gd")


func button_pressed(value: int) -> void:
	if G.sink(self):
		return
	super(value)
	G.host_after(self)


func _on_success() -> void:
	if G.sink(self):
		return
	super()
	G.fx("notify", null, {"key": "NOTIF_ELEVATOR_HACKED"})
	G.fx("hack_success")
	G.host_after(self)


func _on_fail() -> void:
	if G.sink(self):
		return
	G.host_after(self)
	await super()
	G.host_after(self)
