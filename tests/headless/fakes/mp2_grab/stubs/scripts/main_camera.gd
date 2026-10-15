extends Camera3D
## Headless stand-in for res://scripts/main_camera.gd (our own minimal code) so
## the MP2 main_camera extensions (GRAB main_camera_grab_ext.gd, GAMEPLAY
## main_camera_interact_ext.gd) compile and can be exercised. Signatures match
## the game's; bodies only move the carry slots (picked_object / equipped_item)
## and record calls.
## Shared by the MP2 streams: test-headless copies fakes/mp_*/stubs in name
## order, so this file (mp2_grab) wins over an mp2_gameplay copy. Keep every
## member either stream needs here.

var picked_object: RigidBody3D
var equipped_item: RigidBody3D = null
var max_grab_distance: float = 3.5
var interact_ray: RayCast3D = null
var hands: Marker3D = null
var calls: Array = []          # [name, args...]
var refuse_drop := false       # drop_object returns early (invalid snap spot)


func handle_input():
	calls.append(["handle_input"])


## Mouse wheel over a machine tunes it. Headless has no InputMap actions, so
## InputEventAction names are compared directly.
func _input(event: InputEvent) -> void:
	calls.append(["_input"])
	var act := event as InputEventAction
	var target = interact_ray.get("last_collider") if interact_ray != null else null
	if act == null or not act.pressed or picked_object or not is_instance_valid(target):
		return
	var verb: String = {"scroll_up": "scroll_tune_up", "scroll_down": "scroll_tune_down"}.get(act.action, "")
	if verb != "" and target.has_method(verb):
		target.call(verb)


func _handle_dpad_context(_delta: float) -> void:
	calls.append(["_handle_dpad_context"])


func _begin_carry(obj: RigidBody3D, keep_hands: bool = false) -> void:
	calls.append(["_begin_carry", obj, keep_hands])
	picked_object = obj
	obj.gravity_scale = 0.0


func drop_object(force: bool = false):
	calls.append(["drop_object", force])
	var held := picked_object
	if not held or (refuse_drop and not force):
		return
	picked_object = null
	held.gravity_scale = 1.0
	if held.has_method("place"):
		held.call_deferred("place")


func release_held_object() -> void:
	calls.append(["release_held_object"])
	if picked_object:
		drop_object(true)


## test helper: a throw of the held body (marks a product as player-thrown)
func stub_throw(impulse: Vector3) -> void:
	var held := picked_object
	if not held:
		return
	picked_object = null
	held.gravity_scale = 1.0
	if held.is_in_group("product"):
		held.set_meta("player_throw_time", Time.get_ticks_msec() * 0.001)
		held.set_meta("player_throw_position", global_position)
	held.apply_central_impulse(impulse)


## test helper: the held body becomes the equipped item
func stub_equip() -> void:
	var held := picked_object
	if not held:
		return
	equipped_item = held
	if held.has_method("equip"):
		held.equip(self)
	picked_object = null


## test helper: the equipped item goes back to the hands, dropped 1 m ahead
func stub_unequip() -> void:
	var item := equipped_item
	if not item:
		return
	var scene := get_tree().current_scene
	var world: Node = scene if scene is Node3D else get_parent()
	if item.has_method("unequip"):
		item.unequip(world, global_position - global_transform.basis.z)
	picked_object = item
	equipped_item = null


func _do_interact() -> bool:
	calls.append(["_do_interact"])
	return false


func _rack_panel(panel: RigidBody3D) -> bool:
	calls.append(["_rack_panel", panel])
	return false


func _release_carry_state() -> void:
	calls.append(["_release_carry_state"])
	picked_object = null


func _refill_from_panel_stack() -> void:
	calls.append(["_refill_from_panel_stack"])


func _carry_after_spawn(inst: RigidBody3D) -> void:
	calls.append(["_carry_after_spawn", inst])
	_begin_carry(inst, true)


func update_equipped_item_properties():
	pass
