extends "res://scripts/debris.gd"
## MP2 4.3: debris destroys tools on the host; client debris from the client's own
## GameProgression is recycled by the stray guard. Destruction and landing effects
## replay on clients.

const G = preload("../../gameplay/mp_gate.gd")


func _on_body_entered(body: Node3D) -> void:
	if G.sink(self):
		return
	super(body)


func _destroy_tool(tool: Node3D) -> void:
	if G.sink(self):
		return
	G.consumed(tool, "debris")
	super(tool)


func _respawn_tool_via_tube(tool_pool_id: String) -> void:
	if G.sink(self):
		return
	super(tool_pool_id)


func _spawn_destruction_effect(at_transform: Transform3D) -> void:
	super(at_transform)
	var o := at_transform.origin
	G.fx("debris_hit", self, {"at": [o.x, o.y, o.z]})


func _apply_landing_shake(force: float) -> void:
	super(force)
	G.fx("debris_hit", self, {"force": force})
