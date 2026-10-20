extends "res://tests/test_case.gd"
## P12 field-tool force guards: the gravity inverter, magnet, magnet_2, tractor
## beam, vacuum and vacuum_2 never apply a force to a body without a physics space
## (parked by the pool with process_mode DISABLED, or out of the tree), and still
## push a body that is in a space. No session: the guards hold in single-player.
## The stubs (fakes/mp2_gameplay/stubs/scripts) run a minimal pick-and-push flow and
## record every apply_central_force in stub_pushed.

const GpRig = preload("res://tests/fakes/mp2_gameplay/gp_rig.gd")
const MpGate = preload("res://gamedir/mods/PittMultiplayer/gameplay/mp_gate.gd")

var _world: Node3D = null


## Stand-in for the beam's Area3D: hands back whatever the test put in it, like an
## overlap list that still holds a body the pool just parked.
class FakeArea extends RefCounted:
	var bodies: Array = []

	func get_overlapping_bodies() -> Array:
		return bodies


func before_all() -> void:
	MpGate.reset()
	_world = Node3D.new()
	_world.name = "ForceGuardWorld"
	runner.add_child(_world)


func after_all() -> void:
	if is_instance_valid(_world):
		_world.queue_free()
	await tree.process_frame


func _tool(name: String) -> Node:
	var n: Node = GpRig.ext_script(name).new()
	_world.add_child(n)
	return n


## [in space, parked (in the tree, process_mode DISABLED), out of the tree]
func _bodies() -> Array:
	var live := RigidBody3D.new()
	live.add_child(_shape())
	_world.add_child(live)
	var parked := RigidBody3D.new()
	parked.add_child(_shape())
	_world.add_child(parked)
	parked.disable_mode = CollisionObject3D.DISABLE_MODE_REMOVE
	parked.process_mode = Node.PROCESS_MODE_DISABLED
	var loose := RigidBody3D.new()
	loose.add_child(_shape())
	for b in [live, parked, loose]:
		b.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC   # as ObjectPoolManager._activate leaves it
	return [live, parked, loose]


static func _shape() -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	cs.shape = SphereShape3D.new()
	return cs


static func _has_space(b: RigidBody3D) -> bool:
	return PhysicsServer3D.body_get_space(b.get_rid()).is_valid()


func _free(nodes: Array) -> void:
	for n in nodes:
		if is_instance_valid(n):
			n.free()


func _check_pushes(tool: Node, bodies: Array, before: int, label: String) -> void:
	assert_eq(core.guard.total_errors(), before, "%s: no engine error" % label)
	assert_eq(tool.stub_pushed, [bodies[0]], "%s: only the in-space body is pushed" % label)


func test_setup_bodies_have_the_expected_spaces() -> void:
	var b := _bodies()
	assert_true(_has_space(b[0]), "the live body is in a space")
	assert_false(_has_space(b[1]), "a DISABLED body (DISABLE_MODE_REMOVE) has left the space")
	assert_false(_has_space(b[2]), "a body out of the tree has no space")
	_free(b)


func test_force_on_a_spaceless_body_is_what_the_guard_stops() -> void:
	# control: the raw call the guards prevent. Jolt (the game) logs it; the headless
	# project runs the default Godot physics server, which ignores it silently, so the
	# "no engine error" checks below only bite under Jolt. The proof here is that the
	# stubs' apply_central_force never sees a spaceless body (stub_pushed).
	var b := _bodies()
	var before: int = core.guard.total_errors()
	b[2].apply_central_force(Vector3.UP)
	var logged: bool = core.guard.total_errors() > before
	print("    force-guard control: unguarded force on a spaceless body logged an error: %s (engine %s)" % [
		logged, ProjectSettings.get_setting("physics/3d/physics_engine", "DEFAULT")])
	before = core.guard.total_errors()
	b[0].apply_central_force(Vector3.UP)
	assert_eq(core.guard.total_errors(), before, "a force on an in-space body is fine")
	_free(b)


func test_gravity_inverter_skips_spaceless_bodies() -> void:
	var gi := _tool("gravity_inverter")
	var b := _bodies()
	gi.stub_outer = b.duplicate()
	gi.stub_inner = [b[1], b[2]]
	var before: int = core.guard.total_errors()
	gi._update_active_targets()
	gi._apply_field_forces()
	_check_pushes(gi, b, before, "gravity inverter")
	assert_eq(gi._outer_targets.size(), 1, "outer targets: only the live body")
	assert_eq(gi._inner_targets.size(), 0, "inner targets: none")
	# a body back in a space is a target again (behaviour unchanged for it)
	b[1].process_mode = Node.PROCESS_MODE_INHERIT
	gi.stub_pushed.clear()
	gi._update_active_targets()
	gi._apply_field_forces()
	assert_eq(gi.stub_pushed, [b[0], b[1], b[1]], "re-enabled body is pushed by both fields again")
	_free(b + [gi])


func test_magnet_skips_spaceless_bodies() -> void:
	var mag := _tool("magnet")
	var b := _bodies()
	mag.stub_overlaps = b.duplicate()
	var before: int = core.guard.total_errors()
	mag.stub_tick()
	_check_pushes(mag, b, before, "magnet")
	assert_eq(mag.active_targets.size(), 1, "one active target")
	_free(b + [mag])


func test_magnet_2_inherits_the_guard() -> void:
	var mag := _tool("magnet_2")
	var b := _bodies()
	mag.stub_overlaps = b.duplicate()
	var before: int = core.guard.total_errors()
	mag.stub_tick()
	_check_pushes(mag, b, before, "magnet_2")
	_free(b + [mag])


func test_tractor_beam_skips_spaceless_bodies_and_restores_them() -> void:
	var tb := _tool("tractor_beam")
	var b := _bodies()
	var area := FakeArea.new()
	area.bodies = b.duplicate()
	tb.beam_area = area
	var seen: Array = []
	tb.stub_hook = func(n):
		if n == "_update_pull":
			seen.append_array([b[1].freeze, b[2].freeze, b[0].freeze])
	var before: int = core.guard.total_errors()
	tb._update_pull(0.016)
	_check_pushes(tb, b, before, "tractor beam")
	assert_eq(seen, [true, true, false], "spaceless bodies static-frozen during the pull only")
	for i in 3:
		assert_false(b[i].freeze, "body %d unfrozen afterwards" % i)
		assert_eq(b[i].freeze_mode, RigidBody3D.FREEZE_MODE_KINEMATIC, "body %d freeze_mode restored" % i)
	# a parked body that was frozen kinematic keeps exactly that state
	b[1].freeze = true
	tb.stub_pushed.clear()
	tb._update_pull(0.016)
	assert_true(b[1].freeze, "frozen stays frozen")
	assert_eq(b[1].freeze_mode, RigidBody3D.FREEZE_MODE_KINEMATIC, "kinematic stays kinematic")
	assert_eq(tb.stub_pushed, [b[0]], "still only the live body")
	# no beam area: the game's path runs untouched
	tb.beam_area = null
	tb._update_pull(0.016)
	assert_eq(core.guard.total_errors(), before, "no errors overall")
	_free(b + [tb])


func test_vacuum_skips_spaceless_bodies() -> void:
	var vac := _tool("vacuum")
	var b := _bodies()
	vac.stub_overlaps = b.duplicate()
	var before: int = core.guard.total_errors()
	vac._update_active_targets()
	vac._apply_suction_forces(0.016)
	_check_pushes(vac, b, before, "vacuum")
	assert_eq(vac.stub_calls.count("_suction_accepts"), 1, "the game filter only sees the in-space body")
	_free(b + [vac])


func test_vacuum_2_repeats_the_guard() -> void:
	var vac := _tool("vacuum_2")
	var b := _bodies()
	vac.stub_overlaps = b.duplicate()
	var before: int = core.guard.total_errors()
	vac._update_active_targets()
	vac._apply_suction_forces(0.016)
	_check_pushes(vac, b, before, "vacuum_2")
	assert_eq(vac.stub_calls.count("_suction_accepts"), 1, "vacuum_2's filter only sees the in-space body")
	_free(b + [vac])
