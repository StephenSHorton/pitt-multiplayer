extends "res://tests/test_case.gd"
## MP2 GRAB (MP2-DESIGN 5.1, 5.2, 5.6, 11.1 test_mp2_grab_protocol): grant /
## deny / epoch, races (host vs client, two clients), host-player refusal,
## wsnap section, held-frame validation, frame kind 5 codec.

const Rig = preload("res://tests/fakes/mp2_grab/grab_rig.gd")
const HeldStream = preload("res://gamedir/mods/PittMultiplayer/grab/held_stream.gd")
const OwnershipHost = preload("res://gamedir/mods/PittMultiplayer/grab/ownership_host.gd")

const DUCK := 1001


func _rig(n: int = 1) -> Rig:
	var r := Rig.new(runner, n)
	r.body(DUCK)
	return r


func test_client_grab_is_predicted_and_granted() -> void:
	var r := _rig(2)
	var c = r.c(0)
	r.grab_body(c, DUCK)
	assert_eq(c.cam.picked_object, c.nodes[DUCK], "the game's carry ran at once (prediction)")
	assert_true(c.bodies.is_local_sim(DUCK), "the client copy is local_sim")
	assert_false(c.nodes[DUCK].freeze, "local_sim unfroze the puppet")
	r.deliver()
	var grants: Array = r.own_msgs(c.id, "grant")
	assert_eq(grants.size(), 1, "one grant")
	assert_eq(int(grants[0].epoch), 1, "epoch 1")
	assert_eq(int(grants[0].peer), c.id, "owner = requester")
	assert_eq(r.host.grab.owner_of(DUCK), c.id, "host table: owner")
	assert_eq(r.host.grab.hold_kind(DUCK), "held", "host table: kind")
	assert_eq(r.host.bodies.following.get(DUCK, 0), c.id, "host body follows the owner")
	assert_eq(r.host.bodies.owner_views[DUCK], [c.id, "held", 1], "host BODIES view")
	assert_eq(r.host.changes.back(), [DUCK, c.id, "held", 1], "host owner_changed")
	r.deliver()
	assert_true(c.grab.is_mine(DUCK), "client: mine")
	assert_eq(c.changes.back(), [DUCK, c.id, "held", 1], "client owner_changed")
	var other = r.c(1)
	var sets: Array = r.own_msgs(other.id, "set")
	assert_eq(sets.size(), 1, "the other client got set")
	assert_eq(other.grab.owner_of(DUCK), c.id, "the other client knows the owner")
	assert_eq(other.bodies.owner_views[DUCK], [c.id, "held", 1], "the other client's BODIES view")
	assert_eq(r.own_msgs(c.id, "set").size(), 0, "the owner gets grant, not set")
	r.cleanup()


func test_second_client_denied_and_undone() -> void:
	var r := _rig(2)
	var a = r.c(0)
	var b = r.c(1)
	r.grab_body(a, DUCK)
	r.grab_body(b, DUCK)          # same pump: b does not know yet
	assert_eq(b.cam.picked_object, b.nodes[DUCK], "b predicted too")
	r.deliver()
	r.deliver()
	assert_eq(r.host.grab.owner_of(DUCK), a.id, "first come wins")
	var denies: Array = r.own_msgs(b.id, "deny")
	assert_eq(denies.size(), 1, "b denied")
	assert_eq(String(denies[0].reason), "owned", "reason owned")
	assert_eq(int(denies[0].peer), a.id, "deny carries the current owner")
	assert_true(b.cam.picked_object == null, "b's carry undone")
	assert_has(b.cam.calls.map(func(x): return x[0]), "release_held_object", "undone with the game's safe drop")
	assert_false(b.bodies.is_local_sim(DUCK), "b's copy is a puppet again")
	assert_eq(b.bodies.unsim_epoch.get(DUCK, -1), 1, "blends back at the host epoch")
	r.steps(3)
	assert_eq(r.net.sent("own_rel").size(), 0, "the undo sent no own_rel")
	assert_eq(a.cam.picked_object, a.nodes[DUCK], "a still carries")
	assert_eq(r.host.grab.epoch_of(DUCK), 1, "deny did not bump the epoch")
	r.cleanup()


func test_host_player_and_client_race() -> void:
	var r := _rig(1)
	var c = r.c(0)
	# host grabs first; the client's request crosses the set on the wire
	r.grab_body(r.host, DUCK)
	assert_eq(r.host.cam.picked_object, r.host.nodes[DUCK], "host carries")
	assert_eq(r.host.grab.owner_of(DUCK), 1, "host row owner 1")
	assert_eq(r.host.grab.hold_kind(DUCK), "held", "host row held (clients see HELD)")
	r.grab_body(c, DUCK)
	r.deliver()
	r.deliver()
	assert_eq(String(r.own_msgs(c.id, "deny")[0].reason), "owned", "client denied")
	assert_true(c.cam.picked_object == null, "client carry undone")
	assert_eq(r.host.grab.owner_of(DUCK), 1, "host keeps it")
	# now the client knows: a second try is refused locally, no request
	var reqs := r.net.sent("own_req").size()
	r.grab_body(c, DUCK)
	r.deliver()
	assert_true(c.cam.picked_object == null, "local refusal: the pick does not happen")
	assert_eq(r.net.sent("own_req").size(), reqs, "no request for a body someone holds")
	assert_eq(int(c.grab.counters().get("grab_refused_local", 0)), 1, "counted")
	r.cleanup()


func test_host_player_cannot_take_client_body() -> void:
	var r := _rig(1)
	var c = r.c(0)
	r.grab_body(c, DUCK)
	r.deliver()
	r.grab_body(r.host, DUCK)
	assert_true(r.host.cam.picked_object == null, "host refused: super not called")
	assert_false(r.host.cam.calls.any(func(x): return x[0] == "_begin_carry"), "the game's carry never ran")
	assert_eq(r.host.grab.owner_of(DUCK), c.id, "the client keeps it")
	assert_eq(int(r.host.grab.counters().get("grab_host_refused", 0)), 1, "counted")
	r.cleanup()


func test_deny_reasons() -> void:
	var r := _rig(1)
	var c = r.c(0)
	var h = r.host
	# unknown eid
	h.grab.on_msg(c.id, "own_req", {"eid": 4242, "seen_epoch": 0})
	# busy: a machine owns the host body
	r.body(1002)
	h.nodes[1002].set_meta("in_cannon_barrel", true)
	h.grab.on_msg(c.id, "own_req", {"eid": 1002, "seen_epoch": 0})
	# far: the body is 20 m from the requester
	r.body(1003, Vector3(0, 0.6, -20))
	h.grab.on_msg(c.id, "own_req", {"eid": 1003, "seen_epoch": 0})
	# GAMEPLAY deny rule
	r.body(1004)
	h.grab.add_deny_rule(func(eid, _node, _peer): return "press" if eid == 1004 else "")
	h.grab.on_msg(c.id, "own_req", {"eid": 1004, "seen_epoch": 0})
	# not in game
	h.session.in_game.clear()
	h.grab.on_msg(c.id, "own_req", {"eid": DUCK, "seen_epoch": 0})
	r.deliver()
	var reasons: Array = r.own_msgs(c.id, "deny").map(func(m): return String(m.reason))
	assert_eq(reasons, ["unknown", "busy", "far", "press", "not_in_game"], "deny reasons in order")
	assert_eq(h.grab.can_take(1003, 1), "", "the host player has no distance check")
	assert_eq(r.host.grab.counters().get("grab_grants", -1), 0, "nothing granted")
	r.cleanup()


func test_repeated_request_is_idempotent() -> void:
	var r := _rig(1)
	var c = r.c(0)
	r.grab_body(c, DUCK)
	r.deliver()
	r.host.grab.on_msg(c.id, "own_req", {"eid": DUCK, "seen_epoch": 0})
	r.deliver()
	var grants: Array = r.own_msgs(c.id, "grant")
	assert_eq(grants.size(), 2, "answered again")
	assert_eq(int(grants[1].epoch), 1, "with the same epoch")
	assert_eq(r.host.grab.epoch_of(DUCK), 1, "no bump")
	r.cleanup()


func test_epoch_wraps_and_skips_zero() -> void:
	var r := _rig(1)
	var row = r.host.grab.host.row(DUCK)
	row.epoch = 0xFFFF
	r.host.grab.host.host_begin_carry(DUCK)
	assert_eq(r.host.grab.epoch_of(DUCK), 1, "u16 wrap skips 0 (0 = no grant seen)")
	r.cleanup()


func test_wsnap_section_round_trip() -> void:
	var r := _rig(1)
	var c = r.c(0)
	r.body(1002)
	r.grab_body(r.host, DUCK)
	r.host.grab.host.host_player_set(DUCK, "equipped")
	r.host.grab.host.row(1002).epoch = 7
	var sec: Dictionary = r.host.grab.wsnap_section()
	assert_eq(sec.rows, [[DUCK, 1, "equipped", 2], [1002, 1, "", 7]], "rows with an owner or an epoch")
	# a late joiner applies it before the ch3 replay
	var fresh = c.grab
	fresh.client.rows.clear()
	fresh.apply_wsnap_section(JSON.parse_string(JSON.stringify(sec)))
	assert_eq(fresh.owner_of(DUCK), 1, "owner")
	assert_eq(fresh.hold_kind(DUCK), "equipped", "kind")
	assert_eq(fresh.epoch_of(1002), 7, "epoch")
	assert_eq(c.bodies.owner_views[DUCK], [1, "equipped", 2], "BODIES view set from the section")
	r.grab_body(c, DUCK)
	assert_true(c.cam.picked_object == null, "refused locally from the wsnap row")
	r.cleanup()


func test_held_frame_validation() -> void:
	var r := _rig(2)
	var c = r.c(0)
	var o = r.c(1)
	r.grab_body(c, DUCK)
	r.deliver()
	var h = r.host.grab
	var p := Vector3(0.3, 0.7, -1.4)
	var ok_rec := {"eid": DUCK, "epoch": 1, "p": p, "q": Quaternion.IDENTITY, "l": Vector3.ZERO, "a": Vector3.ZERO}
	h.on_raw(c.id, 5, HeldStream.encode(r.net.clock_ms, [ok_rec]))
	assert_eq(r.host.bodies.pushes.get(DUCK, []).size(), 1, "valid frame pushed")
	assert_true((r.host.bodies.pushes[DUCK][0][0].p as Vector3).distance_to(p) < 0.002, "pose within quantisation")
	assert_eq(int(r.host.bodies.pushes[DUCK][0][1]), r.net.clock_ms, "t_ms = sender's host_now")
	var bad_epoch := ok_rec.duplicate()
	bad_epoch.epoch = 3
	h.on_raw(c.id, 5, HeldStream.encode(r.net.clock_ms, [bad_epoch]))
	h.on_raw(o.id, 5, HeldStream.encode(r.net.clock_ms, [ok_rec]))          # not the owner
	var far := ok_rec.duplicate()
	far.p = Vector3(0, 0.6, -9.0)
	h.on_raw(c.id, 5, HeldStream.encode(r.net.clock_ms, [far]))
	h.on_raw(c.id, 5, PackedByteArray([5, 0, 9, 0]))                         # malformed
	assert_eq(r.host.bodies.pushes[DUCK].size(), 1, "nothing else pushed")
	assert_eq(int(h.counters().held_rejected), 4, "4 rejected")
	r.cleanup()


func test_epoch_zero_frames_before_ack() -> void:
	var r := _rig(1)
	var c = r.c(0)
	r.grab_body(c, DUCK)
	# the client streams before its grant arrived: epoch 0
	r.step(40)
	assert_eq(int(r.host.grab.counters().get("grab_held_early", 0)), 1, "epoch-0 frame counted, not pushed")
	assert_eq(r.host.bodies.pushes.get(DUCK, []).size(), 0, "nothing pushed yet")
	r.steps(4, 40)
	assert_true(r.host.bodies.pushes.get(DUCK, []).size() >= 2, "granted epoch frames pushed")
	assert_eq(int(r.host.grab.counters().held_rejected), 0, "no rejections")
	r.cleanup()


func test_codec_fallback_round_trip() -> void:
	HeldStream.use_fallback(true)
	var q := Quaternion(Vector3(0.3, 1, -0.2).normalized(), 2.1)
	var rec := {"eid": 123456, "epoch": 65535, "p": Vector3(-812.25, 3.5, 7999.0), "q": q,
		"l": Vector3(1.5, -400, 0.01), "a": Vector3(0, 2.5, -3)}
	var bytes := HeldStream.encode(0xFFFFFFF0, [rec, rec])
	assert_eq(bytes.size(), 8 + 31 * 2, "8 B header + 31 B records")
	assert_eq(int(bytes[0]), 5, "frame kind 5")
	var d := HeldStream.decode(bytes)
	assert_eq(int(d.t_ms), 0xFFFFFFF0, "t_ms")
	assert_eq(d.records.size(), 2, "2 records")
	var out: Dictionary = d.records[0]
	assert_eq(int(out.eid), 123456, "eid")
	assert_eq(int(out.epoch), 65535, "16-bit epoch")
	assert_true((out.p as Vector3).distance_to(rec.p) <= 0.0009, "pos within 1/1024 m")
	assert_true(rad_to_deg((out.q as Quaternion).angle_to(q)) < 0.25, "rot within 0.25 deg")
	assert_true(absf(out.l.y - -327.0) < 0.01, "velocity clamped at 327")
	assert_true((out.a as Vector3).distance_to(rec.a) < 0.006, "angular velocity")
	assert_true(HeldStream.decode(bytes.slice(0, 20)).is_empty(), "short buffer rejected")
	var three := HeldStream.encode_fallback(0, [rec, rec, rec])
	assert_eq(three.size(), 8 + 31 * 2, "at most 2 records")
	var bad := bytes.duplicate()
	bad.encode_u16(2, 7)
	assert_true(HeldStream.decode(bad).is_empty(), "count overrunning the buffer rejected")
	HeldStream.use_fallback(false)
	# whatever codec is active (BODIES' when present) must round-trip the same record
	var d2 := HeldStream.decode(HeldStream.encode(77, [rec]))
	assert_false(d2.is_empty(), "active codec round trip")
	if not d2.is_empty():
		assert_eq(int(d2.records[0].eid), 123456, "active codec eid")
		assert_true((d2.records[0].p as Vector3).distance_to(rec.p) < 0.002, "active codec pos")


func test_state_json_validation() -> void:
	var s := {"p": Vector3(1, 2, 3), "q": Quaternion.IDENTITY, "l": Vector3(4, 5, 6), "a": Vector3.ZERO}
	var back := HeldStream.state_from_json(JSON.parse_string(JSON.stringify(HeldStream.state_to_json(s))))
	assert_eq(back.p, Vector3(1, 2, 3), "p")
	assert_eq(back.l, Vector3(4, 5, 6), "l")
	assert_true(HeldStream.state_from_json({"p": [0, 0, 9000], "q": [0, 0, 0, 1]}).is_empty(), "out of range")
	assert_true(HeldStream.state_from_json({"p": [0, "x", 0], "q": [0, 0, 0, 1]}).is_empty(), "malformed")
	assert_true(HeldStream.state_from_json({"p": [0, 0, 0], "q": [0, 0, 0, 0]}).is_empty(), "zero quaternion")
	assert_true(HeldStream.state_from_json("nope").is_empty(), "not a dictionary")
