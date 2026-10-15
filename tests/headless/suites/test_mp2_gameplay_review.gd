extends "res://tests/test_case.gd"
## MP2 review fixes (docs/mp/MP2-TEST-REPORT.md, review round 2), GAMEPLAY side:
## the camera's wheel dispatcher (_input) and the interact ray's LMB toggle run in
## the input scope; the weight piston (piston_3) tunes through the host and
## replays its preset; hold-to-craft never restarts the host's craft and a
## release before the replay still stops it; a host-held panel cannot be racked
## by a client; a leaving player's rack comes back as panels; remote players'
## equipped tools are unequipped before the rigs go; Clear items is host-only.

const GpRig = preload("res://tests/fakes/mp2_gameplay/gp_rig.gd")
const FakeAdapter = preload("res://tests/fakes/mp2_gameplay/fake_gameplay_adapter.gd")
const MpGate = preload("res://gamedir/mods/PittMultiplayer/gameplay/mp_gate.gd")
const EntityMeta = preload("res://gamedir/mods/PittMultiplayer/world/bodies/entity_meta.gd")
const CAM_EXT := "res://gamedir/mods/PittMultiplayer/extensions/gameplay/main_camera_interact_ext.gd"
const PAUSE_EXT := "res://gamedir/mods/PittMultiplayer/extensions/pause_menu_ext.gd"

var rig = null


func before_all() -> void:
	rig = GpRig.new(tree, runner)


func after_all() -> void:
	await rig.cleanup()


func _pair() -> Array:
	await rig.cleanup()
	var h = rig.add_host()
	var c = rig.add_client(2)
	h.session.set_pose(2, Vector3(1, 0, 0))
	rig.start()
	return [h, c]


func _ext(name: String, parent: Node) -> Node:
	var n: Node = GpRig.ext_script(name).new()
	parent.add_child(n)
	return n


func _verbs(session) -> Array:
	var out: Array = []
	for s in session.sent_of("interact"):
		out.append(String(s[2].get("verb", "")))
	return out


static func _action(name: String, pressed: bool) -> InputEventAction:
	var ev := InputEventAction.new()
	ev.action = name
	ev.pressed = pressed
	return ev


func test_wheel_tune_from_camera_input_is_forwarded() -> void:
	var pc = await _pair()
	var c = pc[1]
	rig.as_peer(c)
	var ray: Node = _ext("interact_ray", c.adapter.world)
	var cam: Node = load(CAM_EXT).new()
	c.adapter.world.add_child(cam)
	cam.interact_ray = ray
	var mag: Node = _ext("magnet_2", c.adapter.world)
	c.bodies.add(mag, 4100, "pooled", "tool_magnet_2")
	ray.last_collider = mag
	cam._input(_action("scroll_up", true))
	assert_eq(_verbs(c.session), ["scroll_tune_up"], "the wheel on a magnet_2 reaches the host")
	assert_false("scroll_tune_up" in mag.stub_calls, "not tuned locally first")
	assert_false(MpGate.in_input_scope(), "scope closed after _input")
	cam._handle_dpad_context(0.016)
	assert_false(MpGate.in_input_scope(), "scope closed after the D-pad dispatcher")
	cam.free()


func test_lmb_toggle_of_auto_bench_is_forwarded() -> void:
	var pc = await _pair()
	var c = pc[1]
	rig.as_peer(c)
	var ray: Node = _ext("interact_ray", c.adapter.world)
	var bench: Node = _ext("automatic_duck_workbench", c.adapter.world)
	bench.add_to_group("automated_workbench")
	c.bodies.add(bench, 900200, "fixture")
	ray.last_collider = bench
	ray._input(_action("lMouse", true))
	ray._input(_action("lMouse", false))
	assert_eq(_verbs(c.session), ["turn_on"], "LMB on an automatic bench reaches the host")
	assert_false("turn_on" in bench.stub_calls, "not toggled locally")
	assert_false(MpGate.in_input_scope(), "scope closed")


func test_weight_piston_tunes_on_host_and_replays() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	rig.as_peer(c)
	var cp: Node = _ext("piston_3", c.adapter.world)
	c.bodies.add(cp, 4200, "pooled", "tool_piston_3")
	MpGate.begin_input_scope()
	cp.scroll_tune_up()
	MpGate.end_input_scope()
	assert_eq(_verbs(c.session), ["scroll_tune_up"], "the weight preset tune goes to the host")
	assert_eq(int(cp._current_weight_preset_index), 1, "unchanged locally")
	cp.cycle_weight_preset(1)
	cp.set_weight_preset(0, true)
	assert_eq(int(cp._current_weight_preset_index), 1, "client machine code never changes the preset")
	# host: the same verb tunes, meta carries it
	rig.as_peer(h)
	var hp: Node = _ext("piston_3", h.adapter.world)
	h.bodies.add(hp, 4200, "pooled", "tool_piston_3")
	hp.scroll_tune_up()
	assert_eq(int(hp._current_weight_preset_index), 2, "host tuned")
	var m := EntityMeta.read(hp)
	assert_eq(int(m.get("wpreset", -1)), 2, "wpreset in the entity meta")
	# client replay (apply scope)
	rig.as_peer(c)
	c.api.net.begin_apply(1)
	EntityMeta.apply(cp, {"wpreset": 2})
	c.api.net.end_apply()
	assert_eq(int(cp._current_weight_preset_index), 2, "replayed on the client")


func test_hold_to_craft_once_and_release_before_replay() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	rig.as_peer(c)
	var ray: Node = _ext("interact_ray", c.adapter.world)
	var bench: Node = _ext("workbench", c.adapter.world)
	c.bodies.add(bench, 900300, "fixture")
	MpGate.begin_input_scope()
	for i in 10:
		bench.start_crafting()     # interact_ray: every frame until is_crafting replays
	MpGate.end_input_scope()
	assert_eq(_verbs(c.session), ["start_crafting"], "one start per hold")
	assert_false(bench.is_crafting, "no replay yet")
	ray._stop_crafting_if_manual(bench)
	assert_eq(_verbs(c.session), ["start_crafting", "stop_crafting"], "released before the replay: the stop still goes")
	ray._stop_crafting_if_manual(bench)
	assert_eq(_verbs(c.session).size(), 2, "only once")
	# host: a second holder's start does not restart the craft
	rig.as_peer(h)
	var hb: Node = _ext("workbench", h.adapter.world)
	h.bodies.add(hb, 900301, "fixture")
	hb.start_crafting()
	hb.is_crafting = true
	hb.stub_calls.clear()
	MpGate.exec_peer = 2
	hb.start_crafting()
	MpGate.exec_peer = 0
	assert_false("start_crafting" in hb.stub_calls, "already crafting: the game's start (progress = 0) is skipped")
	assert_true(2 in h.gp.holders_of(900301), "the remote holder is recorded")


func test_rack_refuses_host_held_panel_and_returns_stack() -> void:
	var pc = await _pair()
	var h = pc[0]
	var panel := FakeAdapter.FPooled.new()
	panel.pool_id = "panel"
	panel.add_to_group("panel")
	h.adapter.world.add_child(panel)
	h.bodies.add(panel, 2400, "pooled", "panel")
	h.grab.set_owner(2400, 1, "held")
	assert_eq(h.gp.rack.store(2, 2400), "held by another player", "the host player's held panel")
	h.grab.set_owner(2400, 1, "")
	panel.set_meta("pending_maw_recycle", true)
	assert_eq(h.gp.rack.store(2, 2400), "busy", "a panel the maw is taking")
	panel.remove_meta("pending_maw_recycle")
	assert_eq(h.gp.rack.store(2, 2400), "", "stored")
	assert_eq(h.gp.rack.stack_of(2), ["panel"], "on the peer's stack")
	var n0: int = h.adapter.pools.spawned.size()
	h.session.set_pose(2, Vector3(5, 0, 5))
	h.gp.on_peer_left(2)
	assert_eq(h.adapter.pools.spawned.size(), n0 + 1, "the leaving player's panel comes back")
	assert_eq(String(h.adapter.pools.spawned[-1][0]), "panel", "same pool")
	var back: Node3D = h.adapter.pools.spawned[-1][1]
	assert_true(back.global_position.distance_to(Vector3(5, 0.6, 5)) < 1.5, "at its last pose (%s)" % back.global_position)
	assert_eq(h.gp.rack.stack_of(2), [], "stack gone")
	assert_eq(int(h.gp.rack.counters().rack_returned), 1, "counted")


func test_rig_tools_unequipped_before_rigs_go() -> void:
	var pc = await _pair()
	var h = pc[0]
	var vac: Node = GpRig.ext_script("vacuum").new()
	h.adapter.world.add_child(vac)
	h.bodies.add(vac, 1700, "pooled", "tool_vacuum")
	var during: Array = []
	vac.stub_hook = func(n): during.append(n)
	rig.as_peer(h)
	h.grab.set_owner(1700, 2, "equipped")
	assert_eq(h.gp.rigs.equipped_on(2), [1700], "on the rig")
	vac.is_equipped = true
	h.gp.on_world_stopped("teardown")
	assert_has(during, "unequip", "unequip() before the rig cameras are freed")
	assert_eq(h.gp.rigs.equipped_on(2), [], "untracked")
	vac.is_equipped = true
	h.grab.set_owner(1700, 2, "equipped")
	during.clear()
	h.gp.rigs.clear()
	assert_has(during, "unequip", "rigs.clear() unequips too")


func test_clear_items_host_only() -> void:
	var pc = await _pair()
	var c = pc[1]
	rig.as_peer(c)
	var pm: Node = load(PAUSE_EXT).new()
	c.adapter.world.add_child(pm)
	var prev = Engine.get_meta("pitt_mp", null) if Engine.has_meta("pitt_mp") else null
	Engine.set_meta("pitt_mp", _RoleStub.new("client"))
	pm._on_clear_items_pressed()
	pm._do_clear_items()
	assert_false("clear_items" in pm.calls, "refused on a client")
	assert_false("do_clear_items" in pm.calls, "the purge never runs on a client")
	Engine.set_meta("pitt_mp", _RoleStub.new("host"))
	pm._on_clear_items_pressed()
	assert_has(pm.calls, "clear_items", "the host purges the shared world")
	if prev != null:
		Engine.set_meta("pitt_mp", prev)
	else:
		Engine.remove_meta("pitt_mp")
	pm.free()


class _RoleStub extends RefCounted:
	var r := ""

	func _init(p: String) -> void:
		r = p

	func ext_role() -> String:
		return r
