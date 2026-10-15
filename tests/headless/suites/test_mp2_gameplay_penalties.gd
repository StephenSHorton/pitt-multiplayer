extends "res://tests/test_case.gd"
## Penalties (MP2-DESIGN 6.8): the host charges a client's maw / fail-safe accident
## once (maw: violation then the fine, combo reset; fail-safe: 1 and combo reset),
## dedupes per peer within 2 s, ignores the first 5 s after the peer's world is
## ready, refuses unknown kinds and host-originated calls.

const GpRig = preload("res://tests/fakes/mp2_gameplay/gp_rig.gd")
const Commands = preload("res://gamedir/mods/PittAPI/core/commands.gd")

var rig = null
var now := 100000


func before_all() -> void:
	rig = GpRig.new(tree, runner)


func after_all() -> void:
	await rig.cleanup()


func _pair() -> Array:
	await rig.cleanup()
	var h = rig.add_host()
	var c = rig.add_client(2)
	h.gp.penalties.now_fn = func(): return now
	rig.start()
	return [h, c]


func _ctx(peer: int, remote: bool = true):
	var ctx = Commands.PittCommandCtx.new()
	ctx.origin_peer = peer
	ctx.is_remote = remote
	return ctx


func test_maw_and_fail_safe_charges() -> void:
	var pc = await _pair()
	var h = pc[0]
	var gs = h.adapter.gs
	now += 6000                       # past the join grace
	var r = h.gp.penalties.cmd_penalty({"kind": "maw"}, _ctx(2))
	assert_true(bool(r.applied), "maw applied")
	assert_eq(gs.safety_violations, 1, "safety violation recorded")
	assert_eq(gs.spent, [7], "the maw fine (host _maw_fine) charged once")
	assert_eq(h.adapter.combo.resets, 1, "combo reset (D9)")
	now += 2500
	var r2 = h.gp.penalties.cmd_penalty({"kind": "fail_safe"}, _ctx(2))
	assert_true(bool(r2.applied), "fail-safe applied")
	assert_eq(gs.spent, [7, 1], "fail-safe charges 1")
	assert_eq(h.adapter.combo.resets, 2, "combo reset")


func test_dedupe_and_join_grace() -> void:
	var pc = await _pair()
	var h = pc[0]
	var gs = h.adapter.gs
	var r0 = h.gp.penalties.cmd_penalty({"kind": "maw"}, _ctx(2))
	assert_false(bool(r0.applied), "within 5 s of ready: ignored")
	assert_eq(String(r0.reason), "join_grace", "reason")
	now += 5100
	assert_true(bool(h.gp.penalties.cmd_penalty({"kind": "maw"}, _ctx(2)).applied), "after the grace")
	now += 1000
	var r1 = h.gp.penalties.cmd_penalty({"kind": "fail_safe"}, _ctx(2))
	assert_false(bool(r1.applied), "second within 2 s: deduped")
	assert_eq(String(r1.reason), "dedupe", "reason")
	assert_eq(gs.spent.size(), 1, "charged once")
	assert_eq(int(h.gp.counters().penalties_ignored), 2, "ignored counted")


func test_refusals() -> void:
	var pc = await _pair()
	var h = pc[0]
	now += 10000
	var ctx = _ctx(2)
	assert_eq(h.gp.penalties.cmd_penalty({"kind": "lava"}, ctx), null, "unknown kind")
	assert_eq(ctx.code, "ERR_INVALID", "ERR_INVALID")
	var ctx2 = _ctx(1, false)
	assert_eq(h.gp.penalties.cmd_penalty({"kind": "maw"}, ctx2), null, "host-originated refused")
	assert_eq(ctx2.code, "ERR_DENIED", "ERR_DENIED")
	assert_eq(h.adapter.gs.spent, [], "nothing charged")
	# the client's own handler refuses (penalties are host-side)
	var c = pc[1]
	var ctx3 = _ctx(2)
	assert_eq(c.gp.penalties.cmd_penalty({"kind": "maw"}, ctx3), null, "client handler")
	assert_eq(ctx3.code, "ERR_UNAVAILABLE", "ERR_UNAVAILABLE on a client")


func test_registered_command() -> void:
	var pc = await _pair()
	var h = pc[0]
	assert_true(h.api.commands.has("PittMultiplayer.penalty"), "penalty registered")
	assert_true(h.api.commands.has("PittMultiplayer.recall"), "recall registered")
	assert_true(h.api.commands.has("PittMultiplayer.rack_store"), "rack_store registered")
	assert_true(h.api.commands.has("PittMultiplayer.rack_withdraw"), "rack_withdraw registered")
	var d: Dictionary = h.api.commands.describe("PittMultiplayer.penalty")
	assert_true(bool(d.get("remote", false)), "remote: true")
