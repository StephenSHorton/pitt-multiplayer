extends "res://scripts/torch_light.gd"
## MP2 4.6: the torch is collected on the host (torch_unlocked mirrored); every
## client removes its copy and shows the notification.

const G = preload("../../gameplay/mp_gate.gd")


func interact() -> void:
	if G.input(self, "interact"):
		return
	var was := bool(G.gs("torch_unlocked", false))
	if G.is_host() and not was:
		G.fx("collect", self)
	super()
	if G.is_host() and not was and bool(G.gs("torch_unlocked", false)):
		G.fx("notify", null, {"key": "NOTIF_TORCH_FOUND"})
		pass


func collect_on_grab() -> void:
	if G.input(self, "collect_on_grab"):
		return
	super()
