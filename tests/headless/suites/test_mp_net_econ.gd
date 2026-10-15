extends "res://tests/test_case.gd"
## Economy: host money mirrored exactly (> int64 as strings, R9); MP2 (3.8,
## P5): clients earn nothing locally, any local write to the money is reverted
## (the money clamp) and counted; purchases still go through the host under
## random interleavings; a full econ heals injected drift; post-hooks.

const MpRig = preload("res://tests/fakes/mp_net/mp_rig.gd")
const EconHost = preload("res://gamedir/mods/PittMultiplayer/sync/econ_host.gd")
const EconClient = preload("res://gamedir/mods/PittMultiplayer/sync/econ_client.gd")

var rig = null


func before_all() -> void:
	rig = MpRig.new(tree, runner)


func after_all() -> void:
	await rig.cleanup()


func _pair(config: Dictionary = {}, n_clients: int = 1) -> Array:
	await rig.cleanup()
	var h = rig.add_host(config, 1)
	await rig.until(func(): return h.session.get_state() == "in_game")
	var out := [h]
	for i in n_clients:
		var c = rig.add_client("c%d" % i, config)
		await rig.until(func(): return c.session.get_state() == "in_game", 5.0)
		out.append(c)
	return out


func test_decimal_helpers() -> void:
	assert_true(EconClient.s_valid("-12"), "valid negative")
	assert_true(EconClient.s_valid("123456789012345678901234567890"), "valid huge")
	assert_false(EconClient.s_valid("12a"), "invalid")
	assert_false(EconClient.s_valid("-"), "invalid sign only")
	assert_eq(EconClient.s_norm("000"), "0", "zero")
	assert_eq(EconClient.s_norm("-0007"), "-7", "leading zeros")


func test_host_money_mirrored_exactly() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var huge := "123456789012345678901234567890"
	h.adapter.set_money(huge)
	var ok: bool = await rig.until(func(): return c.adapter.get_money() == huge, 3.0)
	assert_true(ok, "money above int64 mirrored as a decimal string: %s" % c.adapter.get_money())
	h.adapter.fgs().upgrades.sprint.level = 1
	h.adapter.fgs().toys.gambling_wodden_crate.buy_prices[0] = 77
	h.adapter.fgs().purchased_once["broom"] = true
	ok = await rig.until(func(): return int(c.adapter.fgs().upgrades.sprint.level) == 1 \
		and int(c.adapter.fgs().toys.gambling_wodden_crate.buy_prices[0]) == 77 \
		and c.adapter.fgs().purchased_once.get("broom", false), 3.0)
	assert_true(ok, "item level, toy price and purchased_once mirrored")
	assert_true(c.api.net.apply_calls > 0, "applied inside begin_apply/end_apply (events tagged net)")


func test_post_hooks() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	h.adapter.fgs().upgrades.remote_tier.level = 1
	h.adapter.fgs().products.duck.auto_machine.level = 1
	var ok: bool = await rig.until(func(): return c.adapter.fgs().remote_tier_applied > 0 \
		and c.adapter.nodes.WorkbenchSpawning.spawned.get("duck", false), 3.0)
	assert_true(ok, "remote tier applied and the auto bench appears in the client's world")
	assert_eq(c.adapter.nodes.WorkbenchSpawning.auto_calls.size(), 1, "auto_machine_purchased(duck, 0) once")


func test_client_local_money_is_reverted() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	h.adapter.fgs().set_money_int(1000)
	await rig.until(func(): return c.adapter.get_money() == "1000", 3.0)
	var before: int = c.session.econ_client.local_money_writes
	c.adapter.fgs().add_money(250)    # a payout in the client's copy of the world
	await rig.frames(2)
	assert_eq(c.adapter.get_money(), "1000", "reverted within a frame (money clamp)")
	assert_true(c.session.econ_client.local_money_writes > before, "counted in local_money_writes")
	c.adapter.fgs().spend(400)        # a local fine
	await rig.frames(2)
	assert_eq(c.adapter.get_money(), "1000", "a local fine is reverted too (the host charges penalties)")
	await rig.ms(300)
	assert_eq(h.adapter.get_money(), "1000", "the shared wallet never moved")


func test_random_interleavings_converge() -> void:
	var pc = await _pair({}, 2)
	var h = pc[0]
	var cs := [pc[1], pc[2]]
	rig.hub.latency_ms = 15
	rig.hub.jitter_ms = 10
	h.adapter.fgs().set_money_int(1000000)
	await rig.until(func(): return cs[0].adapter.get_money() == "1000000" and cs[1].adapter.get_money() == "1000000", 3.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 2024
	var expected := 1000000
	var pending: Array = []
	for step in 600:
		var op := rng.randi_range(0, 3)
		var c = cs[rng.randi_range(0, 1)]
		match op:
			0:
				c.adapter.fgs().add_money(rng.randi_range(1, 900))     # reverted by the clamp
			1:
				c.adapter.fgs().spend(rng.randi_range(1, 300))         # reverted by the clamp
			2:
				var v3 := rng.randi_range(1, 500)
				h.adapter.fgs().add_money(v3)
				expected += v3
			3:
				if step % 7 == 0:
					pending.append(c.api.commands.execute("PittMultiplayer.buy_toy", {"toy": "gambling_wodden_crate"}))
		if step % 25 == 0:
			await tree.process_frame
	for r in pending:
		if not r.done:
			await r.completed
	var bought := 0
	var cost_total := 0
	for r in pending:
		if r.ok:
			bought += 1
			cost_total += int(r.value.cost)
	expected -= cost_total
	var ok: bool = await rig.until(func():
		return h.adapter.get_money() == str(expected) and cs[0].adapter.get_money() == str(expected) \
			and cs[1].adapter.get_money() == str(expected), 8.0)
	assert_true(ok, "everyone converged on %d: host %s, c0 %s, c1 %s (bought %d)" % [expected, h.adapter.get_money(),
		cs[0].adapter.get_money(), cs[1].adapter.get_money(), bought])
	assert_true(bought > 0, "purchases happened")
	assert_eq(int(h.adapter.fgs().toys.gambling_wodden_crate.buy_prices[0]), 5 + bought, "crate price escalated once per purchase")
	assert_true(cs[0].session.econ_client.local_money_writes > 0, "client-local writes were reverted and counted")
	rig.hub.latency_ms = 0
	rig.hub.jitter_ms = 0


func test_full_econ_heals_drift() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	await rig.ms(100)
	c.adapter.fgs().upgrades.crouch.level = 9      # drift injected on the client
	c.adapter.fgs().upgrades.luck.enabled = true
	h.session.econ_host.send_full(0)
	var ok: bool = await rig.until(func(): return int(c.adapter.fgs().upgrades.crouch.level) == 0 \
		and not c.adapter.fgs().upgrades.luck.enabled, 3.0)
	assert_true(ok, "a full econ restores host values")
	assert_true(c.session.econ_client.drift_heals >= 1, "drift detected and logged")


func test_econ_diff() -> void:
	var a := {"money": "1", "items": {"upgrades/a/": {"level": 1}}, "po": {}}
	var b := {"money": "1", "items": {"upgrades/a/": {"level": 2}, "upgrades/b/": {"level": 0}}, "po": {"x": true}}
	var d := EconHost.diff(a, b)
	assert_eq(d.items.size(), 2, "changed + new items")
	assert_eq(d.purchased_once, {"x": true}, "purchased_once delta")
	assert_true(EconHost.diff(b, b).is_empty(), "no change -> empty")
	var s1 := {"money": "1", "stats": {"total_combos": 1}, "bank": 1.0, "mbank": 2, "f": {"x": 1}}
	var s2 := {"money": "1", "stats": {"total_combos": 2}, "bank": 1.5, "mbank": 2, "f": {"x": 1}}
	var d2 := EconHost.diff(s1, s2)
	assert_eq(d2.stats, {"total_combos": 2}, "stats delta")
	assert_eq(float(d2.bank), 1.5, "bank delta")
	assert_false(d2.has("mbank"), "unchanged mining bank omitted")
	assert_false(d2.has("f"), "unchanged fields omitted")
