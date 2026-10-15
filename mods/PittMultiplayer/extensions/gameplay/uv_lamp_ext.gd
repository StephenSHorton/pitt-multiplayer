extends "res://scripts/uv_lamp.gd"
## MP2 4.6: the lamp is collected on the host (uv_unlocked mirrored); every client
## removes its copy and shows the notification; INVISIBLE for everyone present.

const G = preload("../../gameplay/mp_gate.gd")


func interact() -> void:
	if G.input(self, "interact"):
		return
	var was := bool(G.gs("uv_unlocked", false))
	if G.is_host() and not was:
		G.fx("collect", self)
	super()
	if G.is_host() and not was and bool(G.gs("uv_unlocked", false)):
		G.fx("notify", null, {"key": "NOTIF_UV_FOUND"})
		G.ach("INVISIBLE")


func collect_on_grab() -> void:
	if G.input(self, "collect_on_grab"):
		return
	super()
