extends "res://tests/test_case.gd"
## MP2 GRAB disconnect and lifecycle (MP2-DESIGN 5.4; G5): the owner leaves
## while holding or with a tool equipped, despawns on both roles, world stop.

const Rig = preload("res://tests/fakes/mp2_grab/grab_rig.gd")
const FakeTool = preload("res://tests/fakes/mp2_grab/fake_tool.gd")

const DUCK := 1001
const TOOL := 1200


func test_owner_leaves_while_holding() -> void:
	var r := Rig.new(runner, 2)
	r.body(DUCK)
	var c = r.c(0)
	r.grab_body(c, DUCK)
	r.steps(6, 20)
	var last: Dictionary = r.host.bodies.pushes[DUCK].back()[0]
	r.host.session.in_game.erase(c.id)
	r.host.grab.on_peer_left(c.id)
	assert_eq(r.host.grab.owner_of(DUCK), 1, "host owns it")
	assert_eq(r.host.grab.counters().grab_revoke_reasons, {"left": 1}, "reason left")
	var hr: Array = r.host.bodies.last("host_release")
	assert_true((hr[2].p as Vector3).is_equal_approx(last.p), "released at the last state: it falls on the host")
	assert_false(r.host.nodes[DUCK].freeze, "dynamic again")
	r.deliver()
	assert_eq(r.c(1).grab.owner_of(DUCK), 1, "the other client got set")
	r.cleanup()


func test_owner_leaves_with_tool_equipped() -> void:
	var r := Rig.new(runner, 1)
	r.body(TOOL, Vector3(0, 0.65, -1.5), false, FakeTool)
	var c = r.c(0)
	r.grab_body(c, TOOL)
	r.steps(2)
	r.as_peer(c)
	c.cam.stub_equip()
	r.steps(2)
	assert_eq(r.host.grab.hold_kind(TOOL), "equipped", "equipped")
	var order: Array = []
	r.host.grab.owner_changed.connect(func(eid, _o, k, _e): order.append(["changed", eid, k]))
	var calls_before: int = r.host.bodies.count("host_release")
	r.host.grab.on_peer_left(c.id)
	assert_eq(order, [["changed", TOOL, ""]], "GAMEPLAY hears owner_changed (takes it off the rig)")
	assert_eq(r.host.bodies.count("host_release"), calls_before + 1, "then the body is dynamic again")
	assert_eq(r.host.grab.hold_kind(TOOL), "", "unowned")
	r.cleanup()


func test_despawn_on_host_and_client() -> void:
	var r := Rig.new(runner, 1)
	r.body(DUCK)
	var c = r.c(0)
	r.grab_body(c, DUCK)
	r.steps(2)
	# host: the body is consumed and despawns
	r.host.bodies.remove(DUCK)
	assert_false(r.host.grab.host.rows.has(DUCK), "host row deleted")
	# client: BODIES fires entity_removed before recycling
	c.bodies.remove(DUCK)
	assert_true(c.cam.picked_object == null, "carry dropped")
	assert_false(c.grab.is_mine(DUCK), "forgotten")
	r.steps(3)
	assert_eq(r.net.sent("own_rel").size(), 0, "nothing sent for a despawned body")
	r.cleanup()


func test_world_stopped_releases_and_goes_inert() -> void:
	var r := Rig.new(runner, 1)
	r.body(DUCK)
	var c = r.c(0)
	r.grab_body(c, DUCK)
	r.steps(4, 20)
	var before: int = r.host.bodies.count("host_release")
	r.host.grab.on_world_stopped("ending")
	assert_eq(r.host.bodies.count("host_release"), before + 1, "host: remote-held body released locally")
	assert_true(r.host.grab.host.rows.is_empty(), "host table cleared")
	assert_false(r.host.grab.ext_live(), "host extension inert")
	c.grab.on_world_stopped("ending")
	assert_false(c.grab.ext_live(), "client extension inert")
	var q_before: int = r.net.q.size()
	r.steps(3)
	assert_eq(r.net.q.size(), q_before, "nothing sent after the stop")
	# messages after the stop are ignored
	r.host.grab.on_msg(c.id, "own_req", {"eid": DUCK, "seen_epoch": 0})
	assert_eq(r.host.grab.owner_of(DUCK), 1, "ignored")
	r.cleanup()


func test_teardown_is_idempotent() -> void:
	var r := Rig.new(runner, 1)
	r.body(DUCK)
	r.host.grab.teardown()
	r.host.grab.teardown()
	assert_eq(r.host.grab.owner_of(DUCK), 1, "defaults after teardown")
	assert_eq(r.host.grab.can_take(DUCK, 2), "not_host", "no table")
	r.cleanup()
