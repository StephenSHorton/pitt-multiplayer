extends "res://tests/test_case.gd"
## Pause guard unpauses in the same physics frame and freezes the local player
## while a menu is open; InputMap erase / restore / re-erase on bindings_changed
## (R15, R16); pause_menu_ext restrictions; puppets have no groups, no body and
## are not named PlayerController (R1); avatar stream both ways and relayed;
## interpolation under loss and with time_scale = 0 (R5).

const MpRig = preload("res://tests/fakes/mp_net/mp_rig.gd")
const Puppet = preload("res://gamedir/mods/PittMultiplayer/world/puppet.gd")
const PauseMenuScript = preload("res://scripts/pause_menu.gd")

var rig = null
var _prev_meta = null


func before_all() -> void:
	rig = MpRig.new(tree, runner)
	_prev_meta = Engine.get_meta("pitt_mp", null)


func after_all() -> void:
	Engine.set_meta("pitt_mp", _prev_meta)
	Engine.time_scale = 1.0
	await rig.cleanup()


func _pair() -> Array:
	await rig.cleanup()
	var h = rig.add_host({}, 1)
	await rig.until(func(): return h.session.get_state() == "in_game")
	var c = rig.add_client()
	await rig.until(func(): return c.session.get_state() == "in_game", 5.0)
	return [h, c]


func test_pause_is_local() -> void:
	var pc = await _pair()
	var c = pc[1]
	c.adapter.paused = true          # MenuManager.open_menu paused the tree
	c.adapter.menu_is_open = true
	await tree.physics_frame
	assert_false(c.adapter.paused, "unpaused on the next physics_frame")
	await wait_frames(1)
	assert_true(c.adapter.movement_locked, "own player frozen while the menu is open")
	assert_true(c.adapter.camera_frozen, "camera script stopped (held object released)")
	c.adapter.menu_is_open = false
	await wait_frames(1)
	assert_false(c.adapter.movement_locked, "movement back")
	assert_false(c.adapter.camera_frozen, "camera back")
	c.adapter.fgp().ending_active = true
	c.adapter.paused = true
	await tree.physics_frame
	assert_true(c.adapter.paused, "the ending is exempt")
	c.adapter.fgp().ending_active = false
	c.session.leave()
	c.adapter.paused = true
	await tree.physics_frame
	assert_true(c.adapter.paused, "no guard after the session")


func test_input_guard() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	assert_false(h.adapter.action_has_events("quick_load"), "host: F9 erased")
	assert_true(h.adapter.action_has_events("quick_save"), "host keeps F5 (it saves)")
	assert_false(c.adapter.action_has_events("quick_load"), "client: F9 erased")
	assert_false(c.adapter.action_has_events("quick_save"), "client: F5 erased")
	c.adapter.erased.clear()          # the controls menu re-applied bindings...
	c.adapter.nodes.InputManager.bindings_changed.emit()
	assert_false(c.adapter.action_has_events("quick_save"), "...and they are erased again (R15)")
	var applies: int = c.adapter.nodes.InputManager.applies
	c.session.leave()
	assert_true(c.adapter.action_has_events("quick_save"), "restored")
	assert_eq(c.adapter.nodes.InputManager.applies, applies + 1, "through InputManager.apply_bindings")
	c.adapter.nodes.InputManager.bindings_changed.emit()
	assert_true(c.adapter.action_has_events("quick_save"), "no re-erase after the session")


func test_pause_menu_ext() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var pm = PauseMenuScript.new()
	runner.add_child(pm)
	Engine.set_meta("pitt_mp", c.session)
	pm._on_save_pressed()
	pm._on_load_pressed()
	pm._on_delete_save_pressed()
	assert_eq(pm.calls, [], "client: save/load/delete refused")
	Engine.set_meta("pitt_mp", h.session)
	pm._on_save_pressed()
	pm._on_load_pressed()
	assert_eq(pm.calls, ["save"], "host saves; load refused")
	pm._on_main_menu_pressed()
	assert_eq(pm.dialogs.back().built_body, "MP_CONFIRM_END_SESSION", "host confirm body says the session ends")
	Engine.set_meta("pitt_mp", null)
	pm._on_load_pressed()
	pm._on_main_menu_pressed()
	assert_has(pm.calls, "load", "single player: vanilla load")
	assert_eq(pm.dialogs.back().built_body, "MENU_CONFIRM_QUIT_BODY", "single player: vanilla body")
	Engine.set_meta("pitt_mp", c.session)
	pm._return_to_main_menu()
	assert_eq(c.session.get_state(), "idle", "_return_to_main_menu leaves the session first")
	assert_eq(pm.calls.back(), "return_to_main_menu", "then the game's reset (super)")
	assert_eq(c.adapter.returns_to_menu, 0, "no second menu return from the session")
	pm.queue_free()


func test_avatars_both_ways_and_puppets() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	h.adapter.avatar = {"pos": Vector3(1, 2, 3), "yaw": 0.5, "pitch": 0.1, "vel": Vector3.ZERO}
	c.adapter.avatar = {"pos": Vector3(-4, 1, 0), "yaw": -1.0, "pitch": 0.0, "vel": Vector3.ZERO}
	var ok: bool = await rig.until(func(): return h.session.avatars.puppet_count() == 1 and c.session.avatars.puppet_count() == 1, 2.0)
	assert_true(ok, "puppets both ways within 1-2 s")
	var hp = h.session.avatars.get_puppet(2)
	var cp = c.session.avatars.get_puppet(1)
	assert_true(hp != null and cp != null, "host sees slot 2, client sees slot 1")
	if hp == null or cp == null:
		return
	assert_eq(String(cp.name), "PittMP_Avatar_1", "named PittMP_Avatar_<slot>")
	assert_eq(String(cp.get_parent().name), "PittMP_Avatars", "under the avatars container")
	assert_true(cp.get_groups().is_empty(), "no groups (R1)")
	assert_false(cp is PhysicsBody3D, "no physics body")
	var bodies: Array = cp.find_children("*", "CollisionObject3D", true, false)
	assert_true(bodies.is_empty(), "no collision objects inside")
	assert_ne(String(cp.name), "PlayerController", "never PlayerController")
	assert_true(c.api.net.remote.has(1), "registered via api.net.register_remote_player")
	await rig.ms(250)
	assert_true(cp.position.distance_to(Vector3(1, 2, 3)) < 0.05, "client puppet at the host position: %s" % str(cp.position))
	# a 10 m teleport arrives within 300 ms (snap)
	h.adapter.avatar.pos = Vector3(11, 2, 3)
	var t0 := Time.get_ticks_msec()
	ok = await rig.until(func(): return cp.position.distance_to(Vector3(11, 2, 3)) < 0.1, 1.0)
	assert_true(ok and Time.get_ticks_msec() - t0 < 400, "teleport shown within 300 ms (%d ms)" % (Time.get_ticks_msec() - t0))
	assert_eq(String(cp.label.text), "host", "name label")


func test_relay_between_clients() -> void:
	await rig.cleanup()
	var h = rig.add_host({}, 1)
	await rig.until(func(): return h.session.get_state() == "in_game")
	var a = rig.add_client("a")
	var b = rig.add_client("b")
	await rig.until(func(): return a.session.get_state() == "in_game" and b.session.get_state() == "in_game", 5.0)
	a.adapter.avatar = {"pos": Vector3(5, 0, 5), "yaw": 0.0, "pitch": 0.0, "vel": Vector3.ZERO}
	var slot_a: int = a.session.roster.slot_of(a.session.my_peer)
	var ok: bool = await rig.until(func(): return b.session.avatars.get_puppet(slot_a) != null, 2.0)
	assert_true(ok, "client b sees client a through the host relay")
	assert_true(h.session.avatars.relayed > 0, "relayed by the host")
	a.session.leave()
	ok = await rig.until(func(): return b.session.avatars.get_puppet(slot_a) == null, 2.0)
	assert_true(ok, "puppet freed when a leaves")


func test_interpolation_unit() -> void:
	var p := Puppet.new()
	p.setup(2, 5, "x", false)
	runner.add_child(p)
	p.push({"t_ms": 1000, "pos": Vector3(0, 0, 0), "yaw": 0.0, "pitch": 0.0, "vel": Vector3(10, 0, 0), "seq": 1, "flags": 0}, 0)
	p.push({"t_ms": 1100, "pos": Vector3(1, 0, 0), "yaw": 1.0, "pitch": 0.0, "vel": Vector3(10, 0, 0), "seq": 2, "flags": 0}, 0)
	var mid: Dictionary = p.sample(1050)
	assert_true((mid.pos as Vector3).is_equal_approx(Vector3(0.5, 0, 0)), "lerped position: %s" % str(mid.pos))
	assert_true(is_equal_approx(float(mid.yaw), 0.5), "lerp_angle yaw")
	var ex: Dictionary = p.sample(1200)
	assert_true((ex.pos as Vector3).is_equal_approx(Vector3(2, 0, 0)), "extrapolated with velocity: %s" % str(ex.pos))
	var held: Dictionary = p.sample(5000)
	assert_true((held.pos as Vector3).is_equal_approx(Vector3(3.5, 0, 0)), "extrapolation capped at 250 ms: %s" % str(held.pos))
	p.push({"t_ms": 1050, "pos": Vector3(9, 9, 9), "yaw": 0.0, "pitch": 0.0, "vel": Vector3.ZERO, "seq": 1, "flags": 0}, 0)
	assert_eq(p.buffer_size(), 2, "old seq ignored (duplicates / reorder)")
	p.push({"t_ms": 1200, "pos": Vector3(50, 0, 0), "yaw": 0.0, "pitch": 0.0, "vel": Vector3.ZERO, "seq": 3, "flags": 0}, 0)
	assert_eq(p.buffer_size(), 1, "a jump over 5 m snaps (buffer reset)")
	# hidden after 3 s without frames; time_scale does not matter (wall clock)
	Engine.time_scale = 0.0
	p.update_pose(1300, 0)
	assert_true(p.visible, "visible while frames are fresh")
	p.update_pose(1300, 5000)
	assert_false(p.visible, "hidden after 3 s of silence")
	Engine.time_scale = 1.0
	p.queue_free()


func test_avatars_under_loss() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	rig.hub.latency_ms = 100
	rig.hub.jitter_ms = 30
	rig.hub.loss = 0.05
	h.adapter.avatar = {"pos": Vector3(0, 1, 0), "yaw": 0.0, "pitch": 0.0, "vel": Vector3(2, 0, 0)}
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 600:
		var t := float(Time.get_ticks_msec() - t0) / 1000.0
		h.adapter.avatar.pos = Vector3(2.0 * t, 1, 0)
		await tree.process_frame
	var cp = c.session.avatars.get_puppet(1)
	assert_true(cp != null and cp.frames_rx > 5, "frames arrive under 100 ms +- 30, 5 %% loss")
	if cp != null:
		assert_true(cp.position.x > 0.3 and cp.position.x < 1.5, "smooth, delayed position: %s" % str(cp.position))
	rig.hub.latency_ms = 0
	rig.hub.jitter_ms = 0
	rig.hub.loss = 0.0
