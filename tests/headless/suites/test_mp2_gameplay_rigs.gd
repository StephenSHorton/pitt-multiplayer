extends "res://tests/test_case.gd"
## Remote camera rigs and ghost colliders (MP2-DESIGN 6.3-6.5): one rig and one
## ghost per world-ready peer, posed from the avatar frame (extrapolated, capped),
## an aim snap holds the rig, tools a remote peer equips go onto its rig with the
## game's equip() inside host_exec and come back with unequip(); ghosts are on the
## player layer, never in group "player", maw-inert, and pass through the host
## player; leaving removes both. The weight plate counts a ghost (D18).

const GpRig = preload("res://tests/fakes/mp2_gameplay/gp_rig.gd")
const MpGate = preload("res://gamedir/mods/PittMultiplayer/gameplay/mp_gate.gd")
const EXT := "res://gamedir/mods/PittMultiplayer/extensions/gameplay/"

var rig = null


func before_all() -> void:
	rig = GpRig.new(tree, runner)


func after_all() -> void:
	await rig.cleanup()


func _pair() -> Array:
	await rig.cleanup()
	var h = rig.add_host()
	var c = rig.add_client(2)
	h.session.now_ms = 10000
	h.session.set_pose(2, Vector3(3, 1, -2), 0.5, -0.2, Vector3(2, 0, 0))
	rig.start()
	return [h, c]


func test_rig_and_ghost_follow_the_avatar() -> void:
	var pc = await _pair()
	var h = pc[0]
	var cam: Camera3D = h.gp.rig_of(2)
	var ghost: Node3D = h.gp.ghost_of(2)
	assert_true(cam != null and ghost != null, "rig and ghost exist after world ready")
	assert_false(cam.current, "the rig is never the current camera")
	h.session.now_ms = 10100     # frame is 100 ms old: extrapolate 0.1 s
	h.gp.rigs.physics(0.016)
	h.gp.ghosts.physics(0.016)
	var eye := Vector3(3, 1.65, -2) + Vector3(0.2, 0, 0)
	assert_true(cam.global_position.is_equal_approx(eye), "rig at eye + vel*age (%s)" % cam.global_position)
	var fwd := -cam.global_transform.basis.z
	var want := -Basis.from_euler(Vector3(-0.2, 0.5, 0)).z
	assert_true(fwd.is_equal_approx(want), "rig yaw/pitch from the frame")
	await wait_physics(3)        # sync_to_physics: the ghost moves on the physics step
	assert_true(ghost.global_position.is_equal_approx(Vector3(3.2, 1, -2)), "ghost at the capsule centre + vel*age (%s)" % ghost.global_position)
	h.session.now_ms = 12000     # 2 s old: capped at 0.15 s
	h.gp.rigs.physics(0.016)
	assert_true(cam.global_position.is_equal_approx(Vector3(3, 1.65, -2) + Vector3(0.3, 0, 0)), "extrapolation capped")
	# an interact with aim snaps the rig and holds it
	h.gp.rigs.snap_aim(2, Vector3(0, 2, 0), Vector3(0, 0, -1))
	h.gp.rigs.physics(0.016)
	assert_true(cam.global_position.is_equal_approx(Vector3(0, 2, 0)), "aim held")


func test_ghost_collision_setup() -> void:
	var pc = await _pair()
	var h = pc[0]
	var ghost = h.gp.ghost_of(2)
	assert_true(ghost is AnimatableBody3D, "AnimatableBody3D")
	assert_eq(ghost.collision_layer, 2, "player layer")
	assert_eq(ghost.collision_mask, 0, "mask 0")
	assert_true(ghost.is_in_group("pitt_mp_ghost") and ghost.is_in_group("maw_inert"), "groups")
	assert_false(ghost.is_in_group("player"), "never in group player (R1)")
	assert_eq(int(ghost.get_meta("pitt_mp_ghost_peer")), 2, "peer meta")
	assert_eq(MpGate.ghost_peer(ghost), 2, "MpGate.ghost_peer")
	assert_true(h.adapter.player in ghost.get_collision_exceptions(), "passes through the host player (D22)")
	h.gp.on_peer_left(2)
	await wait_frames(1)
	assert_true(h.gp.ghost_of(2) == null and h.gp.rig_of(2) == null, "removed when the peer leaves")


func test_equip_on_rig_and_unequip() -> void:
	var pc = await _pair()
	var h = pc[0]
	var vac: Node = GpRig.ext_script("vacuum").new()
	h.adapter.world.add_child(vac)
	h.bodies.add(vac, 1600, "pooled", "tool_vacuum")
	vac.equipped_offset = Vector3(0.3, -0.2, -0.5)
	var during: Array = []
	vac.stub_hook = func(n): during.append([n, MpGate.exec_peer])
	rig.as_peer(h)
	h.grab.set_owner(1600, 2, "equipped")
	assert_eq(during, [["equip", 2]], "equip() on the rig inside host_exec(2)")
	h.gp.rigs.physics(0.016)
	assert_true(vac.position.is_equal_approx(Vector3(0.3, -0.2, -0.5)), "hand pose from equipped_offset")
	assert_eq(h.gp.rigs.equipped_on(2), [1600], "tracked")
	vac.is_equipped = true
	h.grab.set_owner(1600, 2, "held")
	assert_eq(during[-1], ["unequip", 2], "unequip() when the owner unequips")
	assert_eq(h.gp.rigs.equipped_on(2), [], "untracked")


func test_weight_plate_counts_ghosts() -> void:
	var pc = await _pair()
	var h = pc[0]
	rig.as_peer(h)
	var plate: Node = GpRig.ext_script("gate_weight_plate").new()
	h.adapter.world.add_child(plate)
	var area := Area3D.new()
	area.collision_mask = 2
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 4, 4)
	shape.shape = box
	area.add_child(shape)
	h.adapter.world.add_child(area)
	plate.pressure_area = area
	h.session.set_pose(2, Vector3(0, 0, 0))
	h.gp.ghosts.physics(0.016)
	area.global_position = h.gp.ghost_of(2).global_position
	for i in 6:
		await wait_physics(1)
		h.gp.ghosts.physics(0.016)
	plate.current_mass = 0.0
	plate._recalculate_mass()
	if area.get_overlapping_bodies().is_empty():
		fail("headless physics reported no overlap (plate counting not exercised)")
		return
	assert_eq(plate.current_mass, 8.0, "a remote player on the plate weighs PLAYER_MASS (D18)")
	area.queue_free()
