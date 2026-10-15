extends "res://scripts/portal.gd"
## MP2 4.5: portals teleport bodies on the host (SNAP on clients); the local player
## uses its own portal copies (D10).

const G = preload("../../gameplay/mp_gate.gd")


func _do_teleport(body: Node) -> bool:
	if G.sink(self) and not G.is_local_player(body):
		return false
	var ok: bool = super(body)
	if ok and G.is_host():
		G.mark_snap(body)
	return ok
