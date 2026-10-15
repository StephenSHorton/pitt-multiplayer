extends "res://tests/test_case.gd"
## Owner report "a black bar (the face) blocks the view of the player":
## puppets fade out near the local camera and hide inside 1 m (label stays),
## the face plate is small and sits at eye height on the front, the body glows
## in the slot colour; joiners spawn beside the host (validated against the
## host's world), never on top of it, with the 0.3 m lift kept.

const Puppet = preload("res://gamedir/mods/PittMultiplayer/world/puppet.gd")
const Snapshot = preload("res://gamedir/mods/PittMultiplayer/sync/snapshot.gd")


## A fake world for ring_position: flat floor at floor_y, minus `blocked`
## predicates. Records every query.
class FakeProbe extends RefCounted:
	var floor_level := 0.0
	var walls: Callable = func(_p): return false        # body origin in a wall
	var pit: Callable = func(_p): return false          # no floor below
	var blocked_sight: Callable = func(_a, _b): return false
	var maw: Callable = func(_p): return false
	var fb := Vector3(100, 5, 100)
	var fallback_calls := 0

	func floor_y(p: Vector3) -> float:
		return NAN if bool(pit.call(p)) else floor_level

	func sight(a: Vector3, b: Vector3) -> bool:
		return not bool(blocked_sight.call(a, b))

	func clear(p: Vector3) -> bool:
		return not bool(walls.call(p))

	func over_maw(p: Vector3) -> bool:
		return bool(maw.call(p))

	func fallback(_c: Vector3) -> Vector3:
		fallback_calls += 1
		return fb


func _puppet() -> Node3D:
	var p := Puppet.new()
	p.setup(2, 5, "Client", false)
	runner.add_child(p)
	p.position = Vector3(0, 1, 0)
	return p


func test_near_alpha_curve() -> void:
	assert_eq(Puppet.near_alpha(0.0), 0.0, "inside the puppet: hidden")
	assert_eq(Puppet.near_alpha(0.85), 0.0, "within ~1 m: hidden")
	assert_true(Puppet.near_alpha(1.1) > 0.0 and Puppet.near_alpha(1.1) < 1.0, "fading between 0.9 and 1.25 m")
	assert_eq(Puppet.near_alpha(1.25), 1.0, "fully drawn from 1.25 m")
	assert_eq(Puppet.near_alpha(30.0), 1.0, "fully drawn far away")


func test_camera_inside_hides_body_and_visor_keeps_label() -> void:
	var p := _puppet()
	# the MP1 bug: the viewer's camera 0.3 m below the other player's eyes
	var a: float = p.apply_camera(p.global_position + Vector3(0, 0.35, 0.05))
	assert_eq(a, 0.0, "alpha 0 with the camera inside")
	assert_false(p.body.visible, "body hidden")
	assert_false(p.visor.visible, "face plate hidden")
	assert_true(p.label.visible, "name label stays")
	# touching shoulder to shoulder (0.6 m)
	p.apply_camera(p.global_position + Vector3(0.6, 0.65, 0))
	assert_false(p.body.visible, "hidden at 0.6 m")
	# fading
	a = p.apply_camera(p.global_position + Vector3(1.1, 0.65, 0))
	assert_true(p.body.visible and p.body.transparency > 0.0 and p.body.transparency < 1.0, "half faded at 1.1 m (%.2f)" % a)
	# normal distance
	a = p.apply_camera(p.global_position + Vector3(0, 0.65, -3.0))
	assert_eq(a, 1.0, "opaque at 3 m")
	assert_true(p.body.visible and p.visor.visible, "body and face plate visible at 3 m")
	assert_eq(p.body.transparency, 0.0, "no transparency at 3 m")
	# above / below the capsule: distance to the axis segment, not the centre
	assert_true(absf(p.axis_distance(p.global_position + Vector3(0, 3.0, 0)) - (3.0 - (Puppet.CAPSULE_HEIGHT * 0.5 - Puppet.CAPSULE_RADIUS))) < 0.001,
		"axis distance above the head")
	p.queue_free()


func test_face_plate_small_and_readable() -> void:
	var p := _puppet()
	var box: BoxMesh = p.visor.mesh
	assert_true(box.size.x <= 0.3 and box.size.y <= 0.1, "small face plate: %s" % str(box.size))
	assert_true(absf(p.visor.position.y - 0.65) < 0.01, "at eye height (CameraPivot +0.65)")
	assert_true(p.visor.position.z < 0.0 and absf(p.visor.position.z) <= Puppet.CAPSULE_RADIUS, "on the front surface (-Z = look direction)")
	var vm: StandardMaterial3D = p.visor.material_override
	assert_true(vm.albedo_color.get_luminance() > 0.5, "light, not a black bar")
	var bm: StandardMaterial3D = p.body.material_override
	assert_true(bm.emission_enabled and bm.emission_energy_multiplier > 0.0, "body self-glow in the dark")
	assert_eq(bm.emission, Puppet.PALETTE[1], "glow in the slot colour")
	assert_true(bm.rim_enabled, "rim light")
	assert_true(p.label.fixed_size and p.label.visibility_range_end >= 60.0, "label readable at distance")
	assert_eq((p.body.mesh as CapsuleMesh).height, 1.95, "capsule = the player's standing height (origin = capsule centre)")
	p.queue_free()


func test_spawn_beside_host_not_on_it() -> void:
	var host := Vector3(3, 0.975, 4)
	var pr := FakeProbe.new()
	var pos := Snapshot.ring_position(host, 2, pr)
	var flat := Vector2(pos.x - host.x, pos.z - host.z).length()
	assert_true(flat >= 2.0, "at least 2 m from the host: %.2f" % flat)
	assert_true(absf(pos.y - (0.0 + Snapshot.HALF_HEIGHT + Snapshot.SPAWN_LIFT)) < 0.001, "floor-snapped + 0.3 m lift: %s" % str(pos))
	assert_eq(pr.fallback_calls, 0, "no fallback on open floor")
	# the host's eye is well over 1 m from the joiner's capsule axis
	var cam := host + Snapshot.EYE
	var axis_y := clampf(cam.y, pos.y - 0.655, pos.y + 0.655)
	assert_true(cam.distance_to(Vector3(pos.x, axis_y, pos.z)) > Puppet.FADE_FAR, "host camera sees the joiner fully")
	# two joiners do not share a spot
	var pos3 := Snapshot.ring_position(host, 3, pr)
	assert_true(pos3.distance_to(pos) > 1.0, "slots spread out: %s vs %s" % [str(pos), str(pos3)])


func test_spawn_rejects_walls_pits_maw_and_hidden_points() -> void:
	var host := Vector3(0, 0.975, 0)
	var pr := FakeProbe.new()
	# only the +X direction on the 3 m ring is acceptable
	var good := func(p: Vector3) -> bool: return p.x > 2.5 and absf(p.z) < 0.5
	pr.walls = func(p): return not good.call(p) and p.x > 0.0         # walls on the +X side
	pr.pit = func(p): return p.x < 0.0 and p.z > 0.0                    # a pit at -X +Z
	pr.maw = func(p): return p.x < 0.0 and p.z <= 0.0                   # the maw at -X -Z
	pr.blocked_sight = func(_a, b): return absf(b.x) < 0.5              # pillars in front / behind
	var why: Array = []
	var pos := Snapshot.ring_position(host, 2, pr, why)
	assert_true(good.call(pos), "the only valid candidate: %s" % str(pos))
	assert_true(String(why.back()).ends_with(" ok") and why.size() > 3, "reasons recorded: %s" % str(why))
	# a ledge: every candidate floor 2 m below the host's floor
	var low := FakeProbe.new()
	low.floor_level = -2.0
	low.pit = func(p): return p.is_equal_approx(host)   # host's own floor unknown -> centre - half height
	var fp := Snapshot.ring_position(host, 2, low)
	assert_eq(low.fallback_calls, 1, "every candidate over a 2 m drop: fallback")
	assert_true(fp.is_equal_approx(low.fb + Vector3(0, Snapshot.SPAWN_LIFT, 0)), "fallback lifted 0.3 m: %s" % str(fp))


func test_spawn_fallbacks() -> void:
	var host := Vector3(1, 2, 3)
	assert_true(Snapshot.ring_position(host, 2).is_equal_approx(host + Vector3(0, 0.3, 0)), "no world: host spot + lift")
	assert_true(Snapshot.ring_position(Vector3.ZERO, 2).is_equal_approx(Snapshot.FALLBACK_POS + Vector3(0, 0.3, 0)), "no safe position: game anchor")
	var walled := FakeProbe.new()
	walled.walls = func(_p): return true
	var p := Snapshot.ring_position(host, 2, walled)
	assert_eq(walled.fallback_calls, 1, "boxed in: the game's own clear-spot search")
	assert_true(p.is_equal_approx(walled.fb + Vector3(0, 0.3, 0)), "fallback + lift")


## The real WorldProbe over Godot physics: floor slab + a wall on +X.
func test_world_probe_real_physics() -> void:
	var world := Node3D.new()
	runner.add_child(world)
	var floor_body := StaticBody3D.new()
	var fs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40, 1, 40)
	fs.shape = box
	floor_body.add_child(fs)
	floor_body.position = Vector3(0, -0.5, 0)
	world.add_child(floor_body)
	var wall := StaticBody3D.new()
	var ws := CollisionShape3D.new()
	var wb := BoxShape3D.new()
	wb.size = Vector3(0.5, 4, 40)
	ws.shape = wb
	wall.add_child(ws)
	wall.position = Vector3(1.2, 2, 0)
	world.add_child(wall)
	var player := CharacterBody3D.new()
	var ps := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.3
	cap.height = 1.95
	ps.shape = cap
	player.add_child(ps)
	player.position = Vector3(0, 0.975, 0)
	world.add_child(player)
	await wait_physics(3)
	var probe = Snapshot.WorldProbe.new(player)
	assert_true(absf(probe.floor_y(Vector3(0, 0.975, 0)) - 0.0) < 0.01, "floor found under the host")
	assert_false(probe.sight(Vector3(0, 1.6, 0), Vector3(3, 1.6, 0)), "the wall blocks the sight line")
	assert_false(probe.clear(Vector3(1.2, 0.975, 0)), "a capsule inside the wall is not clear")
	assert_true(probe.clear(Vector3(-2.2, 0.975, 0)), "open floor is clear")
	var pos := Snapshot.ring_position(player.position, 2, probe)
	assert_true(pos.x < 0.9, "never behind the wall: %s" % str(pos))
	assert_true(Vector2(pos.x, pos.z).length() >= 2.0, "beside the host, on the far ring first: %s" % str(pos))
	# a tight cabin (walls 1.5 m away on every side): the 1.3 m ring
	var box2 := StaticBody3D.new()
	for side in [Vector3(1.75, 2, 0), Vector3(-1.75, 2, 0), Vector3(0, 2, 1.75), Vector3(0, 2, -1.75)]:
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(0.5 if side.x != 0.0 else 4.0, 4, 0.5 if side.z != 0.0 else 4.0)
		cs.shape = bs
		cs.position = side + Vector3(-20, 0, 0)
		box2.add_child(cs)
	world.add_child(box2)
	await wait_physics(3)
	var cabin := Vector3(-20, 0.975, 0)
	var why: Array = []
	var cp := Snapshot.ring_position(cabin, 2, probe, why)
	var off := Vector2(cp.x - cabin.x, cp.z - cabin.z).length()
	assert_true(off > 1.2 and off < 1.7, "small cabin: a tight ring (%.2f m) %s" % [off, str(why.slice(-3))])
	assert_true(absf(pos.y - (0.975 + 0.3)) < 0.02, "floor + half height + lift: %s" % str(pos))
	world.queue_free()
