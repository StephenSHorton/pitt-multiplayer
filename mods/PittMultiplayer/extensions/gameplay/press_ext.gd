extends "res://scripts/press.gd"
## MP2 4.2: the press crushes on the host. A client's interact goes to the host; the
## stroke animation replays on every client (fx press_start). On a client only the
## local player's own branch of the crush runs (drop what it holds + respawn, P7).

const G = preload("../../gameplay/mp_gate.gd")


var _mp_stroke: Array = []


func interact():
	if G.input(self, "interact"):
		return
	super()


func start_pressing():
	super()
	if G.is_host():
		_mp_stroke.clear()
		for item in items_to_crush:
			if is_instance_valid(item):
				item.set_meta("pitt_mp_press_stroke", true)
				_mp_stroke.append(item)
				G.consumed(item, "press")
		G.fx("press_start", self)


func process_crushed_items():
	if G.sink(self):
		# client: only the local player's part of the crush (drop + respawn)
		if is_instance_valid(player) and is_player_in:
			_mp_drop_and_respawn()
		items_to_crush.clear()
		return
	super()


func _mp_drop_and_respawn() -> void:
	var camera = get_tree().get_first_node_in_group("main_camera")
	if camera != null and camera.has_method("release_held_object"):
		camera.release_held_object()
	player.respawn_safe()


func _spawn_pending_anomalies() -> void:
	if G.sink(self):
		return
	for item in _mp_stroke:
		if is_instance_valid(item):
			item.remove_meta("pitt_mp_press_stroke")
	_mp_stroke.clear()
	super()


func replace_with_flat_product(product: RigidBody3D):
	if G.sink(self):
		return
	await super(product)
