extends "res://tests/test_case.gd"
## Client rack_store waits for the host's answer (MP2-DESIGN 6.11, 0.2.3 P12):
## racking a held panel keeps it in the hands (hidden) until the host's result;
## "stored" ends the carry, a refusal or no answer within the wait leaves it
## carried and shown again, and the mirrored panel_stack only ever comes from the
## host's fx rack. The client's commands go through a held authority here, so the
## test decides when (and whether) the host's answer arrives.

const GpRig = preload("res://tests/fakes/mp2_gameplay/gp_rig.gd")
const FakeAdapter = preload("res://tests/fakes/mp2_gameplay/fake_gameplay_adapter.gd")
const CAM_EXT := "res://gamedir/mods/PittMultiplayer/extensions/gameplay/main_camera_interact_ext.gd"
const EID := 2600


## A client-side command authority that keeps every envelope until the test
## relays it to the host (dispatch_remote as the transport's peer) or drops it.
class HeldAuthority extends RefCounted:
	var commands = null
	var peer := 2
	var sent: Array = []

	func is_authority() -> bool:
		return false

	func local_peer_id() -> int:
		return peer

	func submit(env: Dictionary) -> void:
		sent.append(env)

	## Run envelope i on the host, then hand its result back to the client.
	func relay(i: int, host_commands) -> Dictionary:
		var r: Dictionary = host_commands.dispatch_remote(JSON.parse_string(JSON.stringify(sent[i])), peer)
		commands.complete_envelope(sent[i], r)
		return r


var rig = null


func before_all() -> void:
	rig = GpRig.new(tree, runner)


func after_all() -> void:
	await rig.cleanup()


## Host + client 2 with the same panel tracked as EID on both, held by the
## client (host row and the client camera's carry).
func _setup() -> Dictionary:
	await rig.cleanup()
	var h = rig.add_host()
	var c = rig.add_client(2)
	h.session.set_pose(2, Vector3(1, 0, 0))
	rig.start()
	var auth := HeldAuthority.new()
	c.api.commands.set_authority(auth)
	var hp := FakeAdapter.FPooled.new()
	hp.pool_id = "panel"
	hp.add_to_group("panel")
	h.adapter.world.add_child(hp)
	h.bodies.add(hp, EID, "pooled", "panel")
	h.grab.set_owner(EID, 2, "held")
	var cp := FakeAdapter.FPooled.new()
	cp.pool_id = "panel"
	cp.add_to_group("panel")
	c.adapter.world.add_child(cp)
	c.bodies.add(cp, EID, "pooled", "panel")
	var cam: Node = load(CAM_EXT).new()
	c.adapter.world.add_child(cam)
	cam.picked_object = cp
	rig.as_peer(c)
	return {"h": h, "c": c, "auth": auth, "hp": hp, "cp": cp, "cam": cam}


func _released(cam: Node) -> bool:
	return cam.calls.any(func(x): return x[0] == "_release_carry_state")


func _relay(s: Dictionary, i: int) -> Dictionary:
	var r: Dictionary = s.auth.relay(i, s.h.api.commands)
	rig.as_peer(s.c)
	return r


func test_store_waits_for_the_host_then_ends_the_carry() -> void:
	var s := await _setup()
	var c = s.c
	var cam: Node = s.cam
	var cp: Node3D = s.cp
	assert_true(cam._rack_panel(cp), "the request went out (the shared key does not also interact)")
	assert_eq(s.auth.sent.size(), 1, "one rack_store")
	assert_eq(String(s.auth.sent[0].name), "PittMultiplayer.rack_store", "rack_store")
	assert_eq(int(s.auth.sent[0].args.eid), EID, "for the held panel")
	assert_eq(cam.picked_object, cp, "still in the hands while the host decides")
	assert_false(_released(cam), "the carry did not end yet")
	assert_false(cp.visible, "hidden while pending")
	assert_true(c.gp.rack.client_store_pending(EID), "pending")
	assert_eq(c.adapter.gs.panel_stack, [], "no local push: the mirror is the host's")
	# a second press before the answer: no second request, no duplicate
	assert_true(cam._rack_panel(cp), "second press")
	assert_eq(s.auth.sent.size(), 1, "still one rack_store")
	var r := _relay(s, 0)
	assert_true(bool(r.ok), "host stored it")
	assert_eq(s.h.adapter.pools.recycled, [s.hp], "recycled once on the host")
	assert_true(_released(cam), "the carry ended on the answer")
	assert_true(cam.picked_object == null, "hands free")
	assert_false(cp.visible, "stays hidden until its despawn")
	assert_false(c.gp.rack.client_store_pending(EID), "settled")
	assert_eq(c.adapter.gs.panel_stack, ["panel"], "mirror from the host's fx")
	assert_eq(c.adapter.gs.panel_stack, s.h.gp.rack.stack_of(2), "client mirror equals the host's stack")
	assert_eq(int(c.gp.rack.counters().client_store_ok), 1, "counted")
	cam.free()


func test_refused_store_keeps_the_panel_in_the_hands() -> void:
	var s := await _setup()
	var c = s.c
	var cam: Node = s.cam
	var cp: Node3D = s.cp
	s.h.adapter.gs.rack_capacity = 0          # the host's rack is full (the client's mirror lagged)
	assert_true(cam._rack_panel(cp), "sent")
	var r := _relay(s, 0)
	assert_false(bool(r.ok), "host refused")
	assert_eq(String(r.error), "rack full", "rack full")
	assert_eq(cam.picked_object, cp, "still carried")
	assert_false(_released(cam), "the carry never ended")
	assert_true(cp.visible, "shown again")
	assert_eq(s.h.adapter.pools.recycled, [], "nothing recycled")
	assert_eq(c.adapter.gs.panel_stack, [], "mirror unchanged")
	assert_eq(c.adapter.gs.panel_stack, s.h.gp.rack.stack_of(2), "equal to the host's stack")
	assert_eq(int(c.gp.rack.counters().client_store_refused), 1, "counted")
	assert_false(c.gp.rack.client_store_pending(EID), "settled")
	# the player can try again
	assert_true(cam._rack_panel(cp), "a new request after the refusal")
	assert_eq(s.auth.sent.size(), 2, "sent again")
	cam.free()


func test_no_answer_keeps_holding_and_a_late_store_still_ends_it() -> void:
	var s := await _setup()
	var c = s.c
	var cam: Node = s.cam
	var cp: Node3D = s.cp
	c.gp.rack.store_wait_ms = 40
	assert_true(cam._rack_panel(cp), "sent")
	await tree.create_timer(0.2).timeout
	assert_eq(cam.picked_object, cp, "still carried after the wait")
	assert_false(_released(cam), "the carry never ended")
	assert_true(cp.visible, "shown again")
	assert_false(c.gp.rack.client_store_pending(EID), "no longer pending")
	assert_eq(int(c.gp.rack.counters().client_store_timeout), 1, "counted")
	# the host's answer was only slow: it stored the panel, so the carry ends now
	var r := _relay(s, 0)
	assert_true(bool(r.ok), "stored late")
	assert_true(_released(cam), "a late stored still ends the carry")
	assert_eq(c.adapter.gs.panel_stack, s.h.gp.rack.stack_of(2), "mirror equals the host's stack")
	cam.free()


func test_late_refusal_after_the_timeout_changes_nothing() -> void:
	var s := await _setup()
	var c = s.c
	var cam: Node = s.cam
	var cp: Node3D = s.cp
	c.gp.rack.store_wait_ms = 40
	s.h.adapter.gs.rack_capacity = 0
	assert_true(cam._rack_panel(cp), "sent")
	await tree.create_timer(0.2).timeout
	_relay(s, 0)
	assert_eq(cam.picked_object, cp, "still carried")
	assert_true(cp.visible, "visible")
	assert_eq(int(c.gp.rack.counters().client_store_refused), 0, "the timeout already answered")
	cam.free()


func test_full_mirror_and_pending_stores_refuse_locally() -> void:
	var s := await _setup()
	var c = s.c
	var cam: Node = s.cam
	var cp: Node3D = s.cp
	c.adapter.gs.rack_capacity = 1
	# a second panel, looked at while the first is pending
	var cp2 := FakeAdapter.FPooled.new()
	cp2.pool_id = "panel"
	cp2.add_to_group("panel")
	c.adapter.world.add_child(cp2)
	c.bodies.add(cp2, EID + 1, "pooled", "panel")
	assert_true(cam._rack_panel(cp), "first sent")
	assert_false(cam._rack_panel(cp2), "the pending one fills the last slot")
	assert_eq(s.auth.sent.size(), 1, "nothing more sent")
	assert_true(cp2.visible, "the second panel untouched")
	cam.free()
	# a looked-at panel another player holds: refused locally, never hidden
	var s3 := await _setup()
	s3.c.grab.set_owner(EID, 3, "held")
	s3.cam.picked_object = null
	assert_false(s3.cam._rack_panel(s3.cp), "held by another player")
	assert_eq(s3.auth.sent.size(), 0, "nothing sent")
	assert_true(s3.cp.visible, "not hidden in their hands")
	s3.c.grab.set_owner(EID, 2, "held")          # our own hold: allowed
	s3.cam.picked_object = s3.cp
	assert_true(s3.cam._rack_panel(s3.cp), "own panel sent")
	s3.cam.free()
	# a full mirror: the vanilla full rack, nothing sent
	var s2 := await _setup()
	s2.c.adapter.gs.rack_capacity = 1
	s2.c.adapter.gs.panel_stack.append("panel")
	assert_false(s2.cam._rack_panel(s2.cp), "rack full on the mirror")
	assert_eq(s2.auth.sent.size(), 0, "nothing sent")
	assert_eq(s2.cam.picked_object, s2.cp, "still carried")
	assert_true(s2.cp.visible, "visible")
	s2.cam.free()


## GRAB's busy branch of a granted carry (6.11): the callback gets the answer.
func test_client_store_answers_the_busy_branch() -> void:
	var s := await _setup()
	var c = s.c
	var cp: Node3D = s.cp
	s.cam.picked_object = null
	var got: Array = []
	assert_true(c.gp.rack.client_store(cp, func(res: String): got.append(res)), "sent")
	assert_false(cp.visible, "hidden while pending")
	s.h.adapter.gs.rack_capacity = 0
	_relay(s, 0)
	assert_eq(got, ["refused"], "refused")
	assert_true(cp.visible, "shown again")
	s.h.adapter.gs.rack_capacity = 4
	assert_true(c.gp.rack.client_store(cp, func(res: String): got.append(res)), "sent again")
	_relay(s, 1)
	assert_eq(got, ["refused", "stored"], "stored")
	s.cam.free()
