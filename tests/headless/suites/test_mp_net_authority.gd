extends "res://tests/test_case.gd"
## MpAuthority: cmd -> dispatch_remote with the transport sender (a forged
## origin is ignored); res completes; timeout and session end -> ERR_UNAVAILABLE
## (R42); remote cheats refused (R19); state flushed before res under jitter (R20).

const MpRig = preload("res://tests/fakes/mp_net/mp_rig.gd")
const MpAuthority = preload("res://gamedir/mods/PittMultiplayer/net/mp_authority.gd")

var rig = null


func before_all() -> void:
	rig = MpRig.new(tree, runner)


func after_all() -> void:
	await rig.cleanup()


func _pair():
	await rig.cleanup()
	var h = rig.add_host({}, 1)
	await rig.until(func(): return h.session.get_state() == "in_game")
	var c = rig.add_client()
	await rig.until(func(): return c.session.get_state() == "in_game", 5.0)
	return [h, c]


func test_remote_command_uses_transport_sender() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var r = c.api.commands.execute("money.add", {"amount": 5})
	assert_false(r.done, "a client command waits for the host")
	await r.completed
	assert_true(r.ok, "completed ok: %s" % r.error)
	assert_eq(h.api.money_adds.size(), 1, "ran on the host")
	assert_eq(h.api.money_adds[0][1], c.session.my_peer, "origin = the transport's sender id")
	assert_true(h.api.money_adds[0][2], "ctx.is_remote")
	# a forged origin in the envelope is ignored
	var env := {"v": 1, "id": 999, "name": "money.add", "args": {"amount": 1}, "mod": "Evil", "origin": 1, "t": 0}
	var res: Dictionary = h.session.authority.handle_remote(env, c.session.my_peer)
	assert_true(bool(res.ok), "dispatched")
	assert_eq(h.api.money_adds.back()[1], c.session.my_peer, "forged origin 1 ignored")
	# malformed envelopes
	assert_eq(String(h.session.authority.handle_remote({"v": 1, "id": "x"}, 5).code), "ERR_INVALID", "bad id")
	assert_eq(String(h.session.authority.handle_remote([1, 2], 5).code), "ERR_INVALID", "not a dict")


func test_local_scope_never_reaches_host() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var before: int = h.api.suppress_calls
	var r = c.api.commands.execute("achievements.suppress", {})
	assert_true(r.done and r.ok, "scope local runs on the client immediately")
	assert_eq(h.api.suppress_calls, before, "host not involved (R18)")
	# the host refuses a local-scope command sent remotely
	var env := {"v": 1, "id": 77, "name": "save.isolate", "args": {"enabled": false}, "mod": "x", "origin": 2, "t": 0}
	var res: Dictionary = h.session.authority.handle_remote(env, c.session.my_peer)
	assert_false(bool(res.ok), "remote local-scope refused")
	assert_eq(String(res.code), "ERR_DENIED", "ERR_DENIED")


func test_remote_cheat_refused() -> void:
	var pc = await _pair()
	var c = pc[1]
	var r = await c.api.commands.execute_async("t.cheat", {})
	assert_false(r.ok, "cheat from a client refused")
	assert_eq(r.code, "ERR_DENIED", "ERR_DENIED (R19)")


func test_non_remote_commands_refused() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var r = await c.api.commands.execute_async("t.plain", {})
	assert_false(r.ok, "an authority command without remote = true is refused from a client")
	assert_eq(r.code, "ERR_DENIED", "ERR_DENIED")
	var env := {"v": 1, "id": 4242, "name": "t.plain", "args": {}, "mod": "x", "origin": 2, "t": 0}
	assert_eq(String(h.session.authority.handle_remote(env, c.session.my_peer).code), "ERR_DENIED", "handle_remote refuses it too")
	assert_true(h.api.commands.describe("PittMultiplayer.contribute").is_empty(), "contribute is gone (MP2 3.8)")
	assert_true(bool(h.api.commands.describe("PittMultiplayer.buy_item").get("remote", false)), "buy_item is remote")
	assert_false(bool(h.api.commands.describe("t.plain").get("remote", true)), "remote defaults to false")


func test_cmd_refused_before_in_game() -> void:
	await rig.cleanup()
	var h = rig.add_host({}, 1)
	await rig.until(func(): return h.session.get_state() == "in_game")
	var c = rig.add_client()
	await rig.until(func(): return c.session.my_peer > 0 and h.session.roster.has(c.session.my_peer), 5.0)
	# a handshaken peer that is not in the world yet
	h.session.roster.set_state(c.session.my_peer, "connected")
	var before: int = h.api.money_adds.size()
	h.session._host_on_msg(c.session.my_peer, {"k": "cmd", "env": {"v": 1, "id": 31, "name": "money.add",
		"args": {"amount": 1}, "mod": "x", "origin": 2, "t": 0}})
	assert_eq(h.api.money_adds.size(), before, "no command runs for a peer without a world")
	# a non-int id gives a result with id 0 instead of a script error
	h.session._host_on_msg(c.session.my_peer, {"k": "cmd", "env": {"v": 1, "id": [1], "name": "money.add", "args": {}}})
	assert_true(true, "non-int envelope id handled")


func test_timeout_and_session_end() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	c.session.authority.timeout_ms = 200
	rig.hub.stall(1, 1000)   # the host stops reading
	var r = c.api.commands.execute("money.add", {"amount": 1})
	await r.completed
	assert_false(r.ok, "no answer")
	assert_eq(r.code, "ERR_UNAVAILABLE", "timeout -> ERR_UNAVAILABLE")
	rig.hub.stalls.clear()
	c.session.authority.timeout_ms = 10000
	rig.hub.stall(1, 5000)
	var r2 = c.api.commands.execute("money.add", {"amount": 1})
	assert_false(r2.done, "pending")
	c.session.leave()
	assert_true(r2.done and not r2.ok and r2.code == "ERR_UNAVAILABLE", "session end fails pending commands (R42)")
	rig.hub.stalls.clear()


func test_unknown_and_not_connected() -> void:
	var a := MpAuthority.new(null, "client", 5)
	var Commands = load("res://gamedir/mods/PittAPI/core/commands.gd")
	var cmds = Commands.new(null, null)
	cmds.register("x.y", func(_a, _c): return 1, {})
	cmds.set_authority(a)
	var r = cmds.execute("x.y", {})
	assert_true(r.done and not r.ok and r.code == "ERR_UNAVAILABLE", "no session -> ERR_UNAVAILABLE at once")
	assert_eq(cmds.execute("nope.z", {}).code, "ERR_UNKNOWN", "unknown stays ERR_UNKNOWN locally")


func test_state_flushed_before_result() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	rig.hub.latency_ms = 40
	rig.hub.jitter_ms = 30
	# a purchase on the host changes money and the level; the client must see
	# the new state BEFORE the result completes (R20)
	h.adapter.fgs().set_money_int(10000)
	await rig.until(func(): return c.adapter.get_money() == "10000", 3.0)
	var seen := {}
	var r = c.api.commands.execute("PittMultiplayer.buy_item", {"category": "upgrades", "key": "sprint"})
	r.completed.connect(func(_res):
		seen["level"] = int(c.adapter.fgs().upgrades.sprint.level)
		seen["money"] = c.adapter.get_money())
	await r.completed
	assert_true(r.ok, "bought: %s" % r.error)
	assert_eq(seen.get("level", -1), 1, "level already mirrored when the result completed")
	assert_eq(seen.get("money", ""), "9950", "money already mirrored when the result completed")
	rig.hub.latency_ms = 0
	rig.hub.jitter_ms = 0
