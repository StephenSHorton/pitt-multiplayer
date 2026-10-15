extends "res://scripts/cannon.gd"
## MP2 4.5: intake, loading and firing on the host (loaded bodies are HIDDEN
## entities, fired ones reappear with SNAP); the muzzle flash and smoke replay on
## clients. A client's fire goes to the host; recoil of a cannon fired for a remote
## owner reaches that owner through the PlayerEffectRedirect.

const G = preload("../../gameplay/mp_gate.gd")


func _on_intake_body_entered(body: Node3D) -> void:
	if G.sink(self):
		return
	super(body)


func _try_auto_load() -> void:
	if G.sink(self):
		return
	super()


func _load_body(body: RigidBody3D) -> void:
	if G.sink(self):
		return
	G.consumed(body, "cannon")
	super(body)


func fire() -> bool:
	if G.sink(self):
		return false
	return super()


func _force_clear_queue() -> void:
	if G.sink(self):
		return
	super()


func interact() -> void:
	if G.input(self, "interact"):
		return
	super()


func remote_toggle(on: bool) -> void:
	if G.replay(self):
		return
	super(on)


func remote_pulse() -> void:
	if G.replay(self):
		return
	super()


func _trigger_muzzle_flash() -> void:
	super()
	G.fx("cannon_fire", self)
