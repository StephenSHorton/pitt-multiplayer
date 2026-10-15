extends "res://scripts/feed_camera.gd"
## MP2 4.5: camera ids are assigned on the host only (camera_id meta on clients).

const G = preload("../../gameplay/mp_gate.gd")


func _ensure_id() -> void:
	if G.sink(self):
		return
	super()
