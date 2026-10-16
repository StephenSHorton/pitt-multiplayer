extends RefCounted
## G10 helpers shared by grab_host.gd and grab_client.gd (0.2.2): the game's CRATE
## tool (pool tool_box, "OBJ_CRATE") with ducks inside, grabbed through the real
## input path (interact ray + an LMB click read by main_camera.handle_input).
## `sc` is the calling scenario (scenario_base.gd).

const POOL := "tool_box"
## where the host drops the ducks, in the crate's frame (inner 0.62 x 1.29 m)
const DUCK_OFFSETS := [Vector3(0, 0.25, -0.38), Vector3(0, 0.25, 0.0), Vector3(0, 0.25, 0.38)]
## "f": the crate filled up (the live report: it failed when "like full of ducks"),
## 3 layers of 2 x 4, dropped layer by layer
const FULL_LAYERS := [0.2, 0.5, 0.8]
const FULL_X := [-0.14, 0.14]
const FULL_Z := [-0.45, -0.15, 0.15, 0.45]
## at least this many ducks must lie in the full crate before the grab
const FULL_MIN := 18
## the full crate's top layer sits above the walls: swinging it spills some, on the
## host's physics and the client's alike (counted, not checked); the drop's convergence
## check still compares every duck with the host
const SPILL_OK := ["g10f_moved", "g10f_rest", "g10hf_held"]
## lifting the full crate may drop a few of the top layer over the rim, on the host's
## physics and the client's alike: at most this many per peer. The host player's own
## carry of it (g10hf, the game alone) spills too (up to 6 of 16 seen): counted only.
const SPILL_SOME := ["g10f_held"]
const FULL_SPILL_MAX := 4
## the crate must rise at least this far when the carrier looks up
const LIFT_M := 0.3


## p (world) lies inside the crate's walls (crate.tscn: walls at x +-0.35 / z +-0.68, 0.64 m high).
static func inside(crate: Node3D, p: Vector3) -> bool:
	var l := crate.global_transform.affine_inverse() * p
	return absf(l.x) <= 0.4 and absf(l.z) <= 0.75 and l.y >= -0.15 and l.y <= 1.3


## The bodies of `nodes` outside `crate`, as crate-frame positions ("gone" for freed ones).
static func outside(crate: Node3D, nodes: Array) -> Array:
	var out: Array = []
	for d in nodes:
		var n := d as Node3D
		if n == null or not is_instance_valid(n):
			out.append("gone")
		elif not inside(crate, n.global_position):
			out.append(crate.global_transform.affine_inverse() * n.global_position)
	return out


static func arr(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


static func vec(a) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2])) if typeof(a) == TYPE_ARRAY and a.size() == 3 else Vector3.INF


## One LMB click as the game reads it (Input.is_action_just_pressed in handle_input).
static func press_lmb(sc) -> void:
	await sc.tree().physics_frame
	Input.action_press("lMouse")
	await sc.tree().physics_frame
	await sc.tree().physics_frame
	Input.action_release("lMouse")
	await sc.tree().physics_frame


## Aims at the crate's near long wall until the interact ray reports the crate, then
## clicks LMB (the game's pick_object -> _begin_carry). true = the camera holds it.
static func grab_by_input(sc, crate: Node3D, tag: String) -> bool:
	var cam = sc.tree().get_first_node_in_group("main_camera")
	if cam == null:
		return false
	var ray: RayCast3D = cam.get("interact_ray")
	var side := 0.35 if (crate.global_transform.affine_inverse() * cam.global_position).x > 0.0 else -0.35
	var seen: Array = []
	var ok := false
	# a duck leaning over the rim can sit in front of one spot of the wall: try a few
	for spot in [Vector3(side, 0.3, 0), Vector3(side, 0.15, -0.35), Vector3(side, 0.15, 0.35), Vector3(side, 0.1, 0)]:
		var aim: Vector3 = crate.global_transform * spot
		ok = await sc.wait_for(func():
			sc.face(aim - Vector3(0, 0.2, 0))
			ray.force_raycast_update()
			var c = ray.get_collider()
			seen.append(str(c.name) if c != null else "none")
			return c == crate, 1.0)
		if ok:
			break
	if not sc.report.check(tag + "_ray_on_crate", ok, str(seen.slice(maxi(0, seen.size() - 3)))):
		return false
	await press_lmb(sc)
	return cam.picked_object == crate


## Looks up 0.45 rad over 0.5 s (dir -1: back down): the game's hands marker (a camera
## child) rises and the carry pulls the crate after it.
static func lift(sc, dir := 1.0) -> void:
	var cam = sc.tree().get_first_node_in_group("main_camera")
	if cam == null:
		return
	for i in 30:
		cam.rotation.x = clampf(cam.rotation.x + 0.015 * dir, -0.6, 0.6)
		await sc.tree().physics_frame


## Turns the carrier 0.8 rad over 1 s: the crate swings sideways through the air.
static func swing(sc, dir := 1.0) -> void:
	var p: Node3D = sc.player()
	if p == null:
		return
	for i in 60:
		p.rotation.y += 0.8 * dir / 60.0
		await sc.tree().physics_frame
