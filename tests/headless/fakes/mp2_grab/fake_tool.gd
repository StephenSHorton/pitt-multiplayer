extends RigidBody3D
## Stand-in for an equipable, placeable tool (decomp fan.gd shape: placed,
## place / unplace, equip(camera) / unequip(world, drop_pos)). Records calls.

var placed := false
var is_equipped := false
var place_result := true
var calls: Array = []


func place():
	calls.append("place")
	placed = place_result
	if placed:
		freeze_mode = FREEZE_MODE_STATIC
		freeze = true


func unplace():
	calls.append("unplace")
	placed = false
	freeze = false


func equip(camera: Camera3D):
	calls.append("equip")
	is_equipped = true
	var old := get_parent()
	if old:
		old.remove_child(self)
	camera.add_child(self)
	transform = Transform3D()


func unequip(world: Node3D, drop_pos: Vector3):
	calls.append("unequip")
	is_equipped = false
	var old := get_parent()
	if old:
		old.remove_child(self)
	world.add_child(self)
	global_position = drop_pos
