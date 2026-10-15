extends "res://tests/test_case.gd"
## MP2 3.8 econ: the money clamp reverts any local write within one physics
## frame (P5) and counts it; bank (+ bank_updated), mining bank and the
## statistics mirror (stat_changed once per change, D24); the mirror field
## registry (econ_host.register_field, 6.10) applied in apply scope;
## PittMultiplayer.contribute is gone; netq reports reach the host.

const Mp2Rig = preload("res://tests/fakes/mp2_bodies/mp2_rig.gd")

var rig = null
var _e0 := 0


func before_all() -> void:
	rig = Mp2Rig.new(tree, runner)
	_e0 = core.guard.total_errors()


func after_all() -> void:
	await rig.cleanup()


func test_money_clamp_within_one_physics_frame() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	h.adapter.fgs().set_money_int(500)
	await rig.until(func(): return c.adapter.get_money() == "500", 3.0)
	var w0: int = c.session.econ_client.local_money_writes
	c.adapter.fgs().add_money(77)
	await tree.physics_frame
	assert_eq(c.adapter.get_money(), "500", "reverted by the next physics frame")
	assert_eq(c.session.econ_client.local_money_writes, w0 + 1, "one local write counted")
	assert_true(h.api.commands.describe("PittMultiplayer.contribute").is_empty(), "contribute is an unknown command")


func test_bank_mining_bank_and_stats_mirrored() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	var hg = h.adapter.fgs()
	var cg = c.adapter.fgs()
	hg.bank = 1234.5
	hg.mining_bank = 42
	hg.total_combos = 3
	hg.safety_violations = 2
	hg.products_consumed.duck = 17
	hg.total_bonus_earned = BigInt.from_string("123456789012345678901234567890")
	var ok: bool = await rig.until(func(): return is_equal_approx(cg.bank, 1234.5) and cg.mining_bank == 42 \
		and cg.total_combos == 3 and int(cg.products_consumed.duck) == 17, 3.0)
	assert_true(ok, "bank, mining bank and statistics mirrored")
	assert_eq(cg.total_bonus_earned.to_plain_string(), "123456789012345678901234567890", "BigInt statistic")
	assert_has(c.adapter.bank_events, 1234.5, "bank_updated emitted (the terminal label listens)")
	var n_total_combos := 0
	for e in c.adapter.stat_events:
		if e[0] == "total_combos":
			n_total_combos += 1
	await rig.ms(2300)     # a full econ in between
	var n2 := 0
	for e in c.adapter.stat_events:
		if e[0] == "total_combos":
			n2 += 1
	assert_eq(n_total_combos, 1, "stat_changed once for the change")
	assert_eq(n2, 1, "and not again for an unchanged value in a full econ")
	assert_true(c.adapter.stat_events.any(func(e): return e[0] == "products_consumed.duck"), "table entries by path")


func test_mirror_field_registry() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	h.gameplay.field_value = 9
	var ok: bool = await rig.until(func(): return c.gameplay.field_value == 9, 3.0)
	assert_true(ok, "a GAMEPLAY mirror field reaches the client")
	assert_true(c.gameplay.scope_ok, "applied inside the apply scope")
	var n: int = c.gameplay.applied_field.size()
	await rig.ms(300)
	assert_eq(c.gameplay.applied_field.size(), n, "sent on change only (plus full econs)")


func test_netq_reaches_the_host() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	rig.spawn(h, "duck", Vector3(0, 2, 0), Vector3(1, 1, 0))
	var ok: bool = await rig.until(func(): return int(h.bodies.counters_extra.netq_rx) >= 1, 3.0)
	assert_true(ok, "netq every second")
	assert_true(int(c.bodies.counters_extra.netq_tx) >= 1, "client sent it")
	var stats: Dictionary = h.session.net_stats()
	assert_true(stats.has(c.session.my_peer_id()), "net_stats per peer: %s" % str(stats.keys()))


## Last: a script error aborts a test silently (it would look passed), so none may occur.
func test_zz_no_script_errors() -> void:
	assert_eq(core.guard.total_errors() - _e0, 0, "script errors during the suite (see headless-run.log)")
