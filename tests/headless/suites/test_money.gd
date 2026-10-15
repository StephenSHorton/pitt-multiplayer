extends "res://tests/test_case.gd"

var gs: Node = null


func before_all() -> void:
	gs = tree.root.get_node("GameState")
	core.commands.execute("money.set", {"amount": "1000"})


func test_add_delta_sign() -> void:
	var ev := capture("money.changed")
	var r = core.state.add_money(100)
	assert_true(r.ok, "money.add")
	assert_eq(core.state.get_money(), "1100", "money string")
	assert_eq(ev.size(), 1, "one event")
	if ev.is_empty():
		return
	assert_eq(ev[0].payload.delta, "100", "delta")
	assert_eq(ev[0].payload.sign, 1, "sign +")
	assert_eq(ev[0].payload.reason, "add", "reason")
	core.state.add_money(5, "bonus")
	assert_eq(ev.back().payload.reason, "bonus", "bonus reason")


func test_spend() -> void:
	var ev := capture("money.changed")
	var r = core.state.spend(105)
	assert_true(r.ok, "spend ok")
	assert_eq(core.state.get_money(), "1000", "after spend")
	assert_true(not ev.is_empty() and ev.back().payload.sign == -1 and ev.back().payload.delta == "105", "sign - and delta")
	r = core.state.spend("99999999999999999999999")
	assert_true(r.done and not r.ok, "spending more than you have fails instead of flooring")
	assert_eq(core.state.get_money(), "1000", "unchanged")


func test_big_amounts() -> void:
	var r = core.state.set_money("1000000000000000000000")
	assert_true(r.ok, "set above int64")
	assert_eq(core.state.get_money(), "1000000000000000000000", "round trip")
	core.state.add_money("9000000000000000000000")
	assert_eq(core.state.get_money(), "10000000000000000000000", "big add")
	assert_eq(core.state.money_compare("10000000000000000000000"), 0, "compare equal")
	assert_true(core.state.can_afford("9999999999999999999999"), "can_afford big")
	assert_eq(core.state.add_money(-5).code, "ERR_INVALID", "negative refused")
	core.state.set_money("1000")


func test_statue_bypass_and_poll() -> void:
	var ev := capture("money.changed")
	gs.fake_statue_bless(7)
	assert_true(ev.size() == 1 and ev[0].payload.delta == "7" and ev[0].payload.reason == "direct", "stat_changed('money') path: %s" % str(ev))
	gs.fake_silent_add(3)
	assert_eq(ev.size(), 1, "silent write not seen yet")
	core.bridge._poll_money()
	assert_true(ev.size() == 2 and ev[1].payload.delta == "3" and ev[1].payload.reason == "direct", "0.5 s poll catches silent writes")
	core.state.set_money("1000")


func test_item_buy_and_level_event() -> void:
	core.state.set_money("100000")
	var ev := capture("item.level_changed")
	var r = core.state.buy("upgrades", "luck")
	assert_true(r.ok and r.value.level == 1, "bought luck: %s" % r.error)
	core.bridge.process(0.0)
	var hit := false
	for e in ev:
		if e.payload.key == "luck" and e.payload.level == 1:
			hit = true
	assert_true(hit, "item.level_changed fired")
	r = core.state.buy("tools", "broom")
	assert_eq(r.code, "ERR_INVALID", "tools are not bought through item.buy")
	core.state.set_money("0")
	var calls_before: int = gs.buy_calls.size()
	r = core.state.buy("products", "duck", "auto_machine")
	assert_eq(r.code, "ERR_FAILED", "unaffordable item refused")
	assert_eq(gs.buy_calls.size(), calls_before, "GameState.buy not called (avoids the auto-machine bug)")
	core.state.set_money("1000")


func test_bank() -> void:
	var ev := capture("bank.changed")
	var r = core.state.set_bank(12.5)
	assert_true(r.ok and core.state.get_bank() == 12.5, "bank.set")
	assert_true(ev.size() == 1 and ev[0].payload.bank == 12.5, "bank.changed")
