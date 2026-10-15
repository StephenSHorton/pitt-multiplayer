extends CharacterBody3D
## Headless fake of the in-world PlayerController (group "player").

var teleports: Array = []
var impulses: Array = []


func teleport_to(pos: Vector3) -> void:
	teleports.append(pos)
	global_position = pos


func teleport_to_transform(xform: Transform3D) -> void:
	teleports.append(xform)
	global_transform = xform


func apply_external_impulse(impulse: Vector3) -> void:
	impulses.append(impulse)
