extends "res://tests/test_case.gd"
## MP2 GRAB prediction (MP2-DESIGN 5.2, 11.1 test_mp2_grab_prediction): local
## refusal rules, deny undo, release racing the grant, unsolicited grant with
## carry (rack withdraw), non-replicated bodies and the vanilla path.

const Rig = preload("res://tests/fakes/mp2_grab/grab_rig.gd")

const DUCK := 1001


func _rig(n: int = 1) -> Rig:
	var r := Rig.new(runner, n)
	r.body(DUCK)
	return r


func _refused(r: Rig, c, why: String) -> void:
	var reqs := r.net.sent("own_req").size()
	r.grab_body(c, DUCK)
	r.deliver()
	assert_true(c.cam.picked_object == null, why + ": the pick does not happen")
	assert_false(c.cam.calls.any(func(x): return x[0] == "_begin_carry"), why + ": super not called")
	assert_false(c.bodies.is_local_sim(DUCK), why + ": stays a puppet")
	assert_eq(r.net.sent("own_req").size(), reqs, why + ": no request")
	c.cam.calls.clear()


func test_local_refusal_rules() -> void:
	var r := _rig(1)
	var c = r.c(0)
	var n: RigidBody3D = c.nodes[DUCK]
	c.bodies.flags[DUCK] = 16
	_refused(r, c, "HELD flag")
	c.bodies.flags[DUCK] = 0
	for m in ["in_cannon_barrel", "in_vacuum_bag", "consumed", "pending_maw_recycle"]:
		n.set_meta(m, true)
		_refused(r, c, "meta " + m)
		n.remove_meta(m)
	n.add_to_group("terminal_pull")
	_refused(r, c, "group terminal_pull")
	n.remove_from_group("terminal_pull")
	c.bodies.metas[DUCK] = {"in_vacuum_bag": true}
	_refused(r, c, "replicated meta in_vacuum_bag")
	c.bodies.metas.erase(DUCK)
	c.grab.client.rows[DUCK] = {"owner": 3, "kind": "held", "epoch": 4}
	_refused(r, c, "another peer owns it")
	assert_eq(c.grab.counters().grab_refusals, {"held": 1, "busy": 6, "owned": 1}, "refusals by reason")
	# the host released it meanwhile (set owner 1, kind ""): allowed again
	c.grab.client.rows[DUCK] = {"owner": 1, "kind": "", "epoch": 5}
	r.grab_body(c, DUCK)
	assert_eq(c.cam.picked_object, n, "free body: carried")
	r.deliver()
	assert_eq(int(r.net.sent("own_req")[0].seen_epoch), 5, "own_req carries the epoch the client saw")
	r.cleanup()


func test_prediction_unfreezes_before_super() -> void:
	var r := _rig(1)
	var c = r.c(0)
	c.bodies.calls.clear()
	r.grab_body(c, DUCK)
	assert_eq(c.bodies.calls[0][0], "set_local_sim", "set_local_sim first")
	assert_eq(c.bodies.calls[0][2], true, "local_sim on")
	assert_eq(c.cam.calls[0][0], "_begin_carry", "then the game's carry")
	assert_eq(r.net.q.size(), 1, "and one queued own_req")
	r.cleanup()


func test_deny_undo_blends_back() -> void:
	var r := _rig(1)
	var c = r.c(0)
	r.host.nodes[DUCK].set_meta("consumed", true)   # only the host knows
	r.grab_body(c, DUCK)
	r.deliver()
	assert_eq(String(r.own_msgs(c.id, "deny")[0].reason), "busy", "host deny busy")
	assert_true(c.cam.picked_object == null, "carry undone")
	assert_false(c.bodies.is_local_sim(DUCK), "puppet again")
	assert_true(c.nodes[DUCK].freeze, "frozen again")
	r.steps(3)
	assert_eq(r.net.sent("own_rel").size(), 0, "no own_rel for the undo")
	assert_eq(int(c.grab.counters().grab_denied), 1, "counted")
	r.cleanup()


func test_release_before_grant() -> void:
	var r := _rig(1)
	var c = r.c(0)
	r.net.latency_ms = 50
	r.grab_body(c, DUCK)
	r.step(16)                  # own_req in flight
	as_drop(r, c)
	r.step(16)                  # release seen
	r.step(16)                  # captured -> own_rel (epoch 0)
	var rels: Array = r.net.q.filter(func(m): return m.get("k", "") == "own_rel")
	assert_eq(rels.size(), 1, "own_rel queued behind own_req")
	assert_eq(int(rels[0].msg.epoch), 0, "epoch 0: the client never saw a grant")
	assert_true(c.bodies.is_local_sim(DUCK), "still local until the host answers")
	r.steps(10, 16)
	assert_eq(r.host.grab.owner_of(DUCK), 1, "host: back to the host")
	assert_eq(r.host.grab.epoch_of(DUCK), 2, "grant + release = epoch +2")
	assert_eq(r.host.bodies.count("host_release"), 1, "host restored the body once")
	assert_false(c.bodies.is_local_sim(DUCK), "client puppet again")
	assert_eq(c.bodies.unsim_epoch[DUCK], 2, "waits for a host record of epoch 2")
	assert_eq(c.grab.owner_of(DUCK), 1, "client row: host")
	assert_eq(c.grab.epoch_of(DUCK), 2, "client row: epoch 2")
	r.cleanup()


func as_drop(r: Rig, c) -> void:
	r.as_peer(c)
	c.cam.drop_object()


func _panel(r: Rig) -> RigidBody3D:
	var panel := RigidBody3D.new()
	panel.add_to_group("draggable")
	panel.gravity_scale = 0.0
	r.parent.add_child(panel)
	panel.global_position = Vector3(0, 0.65, -1.0)
	return panel


## The real path (no hand-made _carry_after_spawn): GRAB itself starts the
## game's carry with the hands kept, after the settle frames, and never runs
## the game's _carry_after_spawn (its busy branch recycles a host puppet).
func _assert_granted_carry(r: Rig, c, panel: RigidBody3D, label: String) -> void:
	assert_eq(c.cam.picked_object, panel, label + ": the game's carry ran")
	assert_true(c.cam.calls.any(func(x): return x[0] == "_begin_carry" and x[1] == panel and x[2] == true),
		label + ": _begin_carry(panel, keep_hands)")
	assert_false(c.cam.calls.any(func(x): return x[0] == "_carry_after_spawn"), label + ": never _carry_after_spawn")
	assert_true(c.bodies.is_local_sim(1500), label + ": local sim")
	assert_false(c.grab.client.want_carry.has(1500), label + ": want_carry consumed")
	assert_eq(int(c.grab.counters().grab_carry_started), 1, label + ": counted once")
	r.deliver()
	assert_eq(r.net.sent("own_req").size(), 0, label + ": no own_req for a granted body")
	assert_eq(r.host.grab.hold_kind(1500), "held", label + ": host: held by the client")


func test_unsolicited_grant_with_carry() -> void:
	var r := _rig(1)
	var c = r.c(0)
	# GAMEPLAY rack_withdraw: the host spawned panel 1500 and grants it before the client adopted it
	r.host.bodies.nodes[1500] = r.host.nodes[DUCK]   # any host node stands in
	r.host.grab.grant(1500, c.id, "held", true)
	r.deliver()
	var g: Array = r.own_msgs(c.id, "grant")
	assert_eq(g.size(), 1, "grant sent")
	assert_true(bool(g[0].carry), "carry flag")
	assert_true(c.grab.is_mine(1500), "client: mine before the puppet exists")
	var panel := _panel(r)
	c.bodies.add(1500, panel)
	assert_true(c.bodies.is_local_sim(1500), "adopted puppet goes local at once")
	assert_true(c.cam.picked_object == null, "the carry waits for the settle frames")
	r.as_peer(c)
	await wait_physics(3)
	_assert_granted_carry(r, c, panel, "grant first")
	# the held stream then carries the granted epoch
	r.step(40)
	assert_true(r.host.bodies.pushes.get(1500, []).size() >= 1, "held frames pushed on the host")
	r.cleanup()


## The usual order on the wire: flush_lifecycle sends the spawn before the grant.
func test_spawn_then_grant_with_carry() -> void:
	var r := _rig(1)
	var c = r.c(0)
	var panel := _panel(r)
	c.bodies.add(1500, panel)
	assert_false(c.bodies.is_local_sim(1500), "a plain puppet before the grant")
	r.host.bodies.nodes[1500] = r.host.nodes[DUCK]
	r.host.grab.grant(1500, c.id, "held", true)
	r.deliver()
	assert_true(c.bodies.is_local_sim(1500), "grant with carry: local at once")
	r.as_peer(c)
	await wait_physics(3)
	_assert_granted_carry(r, c, panel, "spawn first")
	r.cleanup()


## Hands full when the panel settled (the player grabbed something within the
## RTT): no carry; without GAMEPLAY the panel is released where it is (own_rel).
func test_busy_player_releases_the_granted_panel() -> void:
	var r := _rig(1)
	var c = r.c(0)
	var panel := _panel(r)
	c.bodies.add(1500, panel)
	r.host.bodies.nodes[1500] = r.host.nodes[DUCK]
	r.host.grab.grant(1500, c.id, "held", true)
	r.deliver()
	r.grab_body(c, DUCK)                       # the hands are full now
	r.as_peer(c)
	await wait_physics(3)
	assert_eq(c.cam.picked_object, c.nodes[DUCK], "still carrying the duck")
	assert_false(c.cam.calls.any(func(x): return x[0] == "_begin_carry" and x[1] == panel), "no carry of the panel")
	var rels: Array = r.net.q.filter(func(m): return m.get("k", "") == "own_rel" and int(m.msg.eid) == 1500)
	assert_eq(rels.size(), 1, "own_rel for the panel")
	assert_eq(int(c.grab.counters().grab_carry_busy), 1, "counted busy")
	assert_false(c.grab.is_mine(1500), "no longer mine")
	r.deliver()
	assert_eq(r.host.grab.hold_kind(1500), "", "host: the panel is free again")
	r.cleanup()


class FakeRack extends RefCounted:
	var stored: Array = []

	func client_store(panel: Object) -> bool:
		stored.append(panel)
		return true


class FakeGameplay extends RefCounted:
	var rack = FakeRack.new()

	func mod_name() -> String:
		return "gameplay"


## Busy with GAMEPLAY present: rack_store puts the panel back on the rack (the
## vanilla busy case) instead of dropping it.
func test_busy_player_rack_stores_the_granted_panel() -> void:
	var r := _rig(1)
	var c = r.c(0)
	var gp := FakeGameplay.new()
	c.session.register_module(gp)
	var panel := _panel(r)
	c.bodies.add(1500, panel)
	r.host.bodies.nodes[1500] = r.host.nodes[DUCK]
	r.host.grab.grant(1500, c.id, "held", true)
	r.deliver()
	r.grab_body(c, DUCK)
	r.as_peer(c)
	await wait_physics(3)
	assert_eq(gp.rack.stored, [panel], "rack_store for the panel")
	assert_eq(int(c.grab.counters().grab_carry_racked), 1, "counted racked")
	var rels: Array = r.net.q.filter(func(m): return m.get("k", "") == "own_rel" and int(m.msg.eid) == 1500)
	assert_eq(rels.size(), 0, "no own_rel: the host's store revokes it")
	r.cleanup()


## A grant revoked during the settle frames starts no carry.
func test_granted_carry_dropped_when_revoked_meanwhile() -> void:
	var r := _rig(1)
	var c = r.c(0)
	var panel := _panel(r)
	c.bodies.add(1500, panel)
	r.host.bodies.nodes[1500] = r.host.nodes[DUCK]
	r.host.grab.grant(1500, c.id, "held", true)
	r.deliver()
	r.host.grab.revoke(1500, "rack")
	r.deliver()
	r.as_peer(c)
	await wait_physics(3)
	assert_true(c.cam.picked_object == null, "no carry after the revoke")
	assert_eq(int(c.grab.counters().grab_carry_started), 0, "nothing started")
	r.cleanup()


func test_non_replicated_body_is_vanilla() -> void:
	var r := _rig(1)
	var c = r.c(0)
	var local := RigidBody3D.new()
	local.add_to_group("draggable")
	r.parent.add_child(local)
	r.as_peer(c)
	c.cam._begin_carry(local)
	assert_eq(c.cam.picked_object, local, "carried")
	c.cam.drop_object()
	r.steps(3)
	assert_eq(r.net.q.size() + r.net.log.size(), 0, "nothing sent for a local-only body")
	r.cleanup()


func test_outside_a_session_the_extension_is_vanilla() -> void:
	var had := Engine.has_meta("pitt_mp")
	var prev = Engine.get_meta("pitt_mp", null) if had else null
	if had:
		Engine.remove_meta("pitt_mp")
	var vanilla_cam = Rig.cam_script().new()
	runner.add_child(vanilla_cam)
	var b := RigidBody3D.new()
	runner.add_child(b)
	vanilla_cam._begin_carry(b)
	assert_eq(vanilla_cam.picked_object, b, "vanilla carry")
	vanilla_cam.release_held_object()
	assert_true(vanilla_cam.picked_object == null, "vanilla release")
	assert_eq(vanilla_cam.calls.map(func(x): return x[0]), ["_begin_carry", "release_held_object", "drop_object"], "only the game's code ran")
	vanilla_cam.queue_free()
	b.queue_free()
	if had:
		Engine.set_meta("pitt_mp", prev)


func test_session_without_live_world_is_vanilla() -> void:
	var r := _rig(1)
	var c = r.c(0)
	c.grab.on_world_stopped("ending")
	r.grab_body(c, DUCK)
	assert_eq(c.cam.picked_object, c.nodes[DUCK], "carried by the game")
	assert_false(c.bodies.is_local_sim(DUCK), "no prediction after world_stopped")
	r.deliver()
	assert_eq(r.net.sent("own_req").size(), 0, "no request")
	r.cleanup()


## Review fix: a re-grab inside one RTT of a release-before-grant waits for that
## request's answer (the next grant / set belongs to it), so the host's set for
## the first own_rel never force-drops the second carry.
func test_regrab_waits_for_the_released_request() -> void:
	var r := _rig(1)
	var c = r.c(0)
	r.net.latency_ms = 50
	r.grab_body(c, DUCK)
	r.step(16)
	as_drop(r, c)
	r.step(16)
	r.step(16)                  # own_rel (epoch 0) queued behind own_req
	var reqs := r.net.sent("own_req").size()
	r.grab_body(c, DUCK)        # re-grab while the first request is unanswered
	assert_eq(r.net.sent("own_req").size(), reqs, "no second request yet")
	assert_eq(int(c.grab.client.refusals.get("pending", 0)), 1, "refused as pending")
	assert_true(c.cam.picked_object == null, "the game's carry did not start")
	r.steps(10, 16)             # both answers arrive
	assert_eq(r.host.grab.owner_of(DUCK), 1, "host owns it after grant + release")
	r.grab_body(c, DUCK)        # now a normal grab
	r.steps(10, 16)
	assert_true(c.grab.is_mine(DUCK), "the re-grab is granted")
	assert_true(c.cam.picked_object != null, "and still carried (not force-dropped)")
	r.cleanup()
