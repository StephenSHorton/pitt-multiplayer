extends "res://scripts/proxy_intern.gd"
## MP2 4.4: the proxy intern drives benches on the host; clients toggle it through
## the host and apply is_active with remote_toggle.

const G = preload("../../gameplay/mp_gate.gd")


func _latch(bench: Node3D) -> void:
	if G.sink(self):
		return
	super(bench)


func _unlatch() -> void:
	if G.sink(self):
		return
	super()


func _drive_target() -> void:
	if G.sink(self):
		return
	super()


func interact():
	if G.input(self, "interact"):
		return
	super()


func remote_toggle(on: bool) -> void:
	if G.replay(self):
		return
	super(on)
