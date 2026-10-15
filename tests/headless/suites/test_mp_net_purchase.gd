extends "res://tests/test_case.gd"
## Purchases: rewire on the stub terminal rows; fail-closed rewire (R12); recall
## keeps the original; host re-validation rejects locked / missing
## enabled_level / max / unaffordable (R11); crate escalation; double press
## sends once; tools/toys spawn only in the buyer's world; host terminal untouched.
## MP2 (MP2-DESIGN 6.1, GAMEPLAY): with the shared world on (session.mp2_active())
## the host's own terminal spawns the bought tool/toy once, the pool is checked on
## the host before charging, the buyer spawns nothing and "grant" is a no-op.

const MpRig = preload("res://tests/fakes/mp_net/mp_rig.gd")
const FakeAdapter = preload("res://tests/fakes/mp_net/fake_game_adapter.gd")
const Purchases = preload("res://gamedir/mods/PittMultiplayer/sync/purchases.gd")


## The two Session members Purchases uses in MP2 (the shared-world flag and the
## command path of a client press, answered at once).
class MP2Session extends RefCounted:
	var mp2 := true
	var commands: Array = []

	func mp2_active() -> bool:
		return mp2

	func execute_command(name: String, args: Dictionary) -> Object:
		commands.append([name, args])
		var r := Done.new()
		r.id = commands.size()
		return r


class Done extends RefCounted:
	signal completed(r)
	var done := true
	var ok := true
	var id := 1
	var code := ""

var rig = null
var _prev_meta = null


func before_all() -> void:
	rig = MpRig.new(tree, runner)
	_prev_meta = Engine.get_meta("pitt_mp", null)


func after_all() -> void:
	Engine.set_meta("pitt_mp", _prev_meta)
	await rig.cleanup()


func _pair() -> Array:
	await rig.cleanup()
	var h = rig.add_host({}, 1)
	await rig.until(func(): return h.session.get_state() == "in_game")
	var c = rig.add_client()
	await rig.until(func(): return c.session.get_state() == "in_game", 5.0)
	h.adapter.fgs().set_money_int(10000)
	await rig.until(func(): return c.adapter.get_money() == "10000", 3.0)
	return [h, c]


func _press(row) -> void:
	(row.get_meta("button") as Button).pressed.emit()


func test_client_upgrade_goes_through_host() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	Engine.set_meta("pitt_mp", c.session)
	var ui = c.adapter.ui()
	var row = ui._create_upgrade_row("upgrades", "sprint")
	assert_true(row.get_meta("pittmp_rewired", false), "row rewired")
	assert_eq((row.get_meta("button") as Button).pressed.get_connections().size(), 1, "exactly our connection")
	_press(row)
	_press(row)   # double press while pending
	assert_eq(ui.local_buys.size(), 0, "the client never buys locally")
	var ok: bool = await rig.until(func(): return int(h.adapter.fgs().upgrades.sprint.level) == 1, 3.0)
	assert_true(ok, "host level +1")
	await rig.until(func(): return int(c.adapter.fgs().upgrades.sprint.level) == 1, 3.0)
	assert_eq(int(c.adapter.fgs().upgrades.sprint.level), 1, "client +1 (mirror)")
	await rig.ms(200)
	assert_eq(int(h.adapter.fgs().upgrades.sprint.level), 1, "double press sent once")
	assert_eq(h.adapter.get_money(), "9950", "charged once")
	assert_has(ui.calls, "update_ui", "feedback ran (update_ui)")
	assert_has(ui.feedback, "UI_UPGRADED", "floating text UI_UPGRADED")


func test_host_terminal_untouched_and_single_player_inert() -> void:
	var pc = await _pair()
	var h = pc[0]
	Engine.set_meta("pitt_mp", h.session)
	var hui = h.adapter.ui()
	var row = hui._create_upgrade_row("upgrades", "sprint")
	assert_false(row.get_meta("pittmp_rewired", false), "host rows keep the game's wiring")
	_press(row)
	assert_eq(hui.local_buys.size(), 1, "host buys through its own terminal")
	Engine.set_meta("pitt_mp", null)
	var row2 = hui._create_tool_buy_row("broom", 0)
	assert_false(row2.get_meta("pittmp_rewired", false), "no session: vanilla")


func test_fail_closed() -> void:
	var pc = await _pair()
	var c = pc[1]
	var ui = c.adapter.ui()
	var row = ui._make_base_row("odd")
	var b: Button = row.get_meta("button")
	b.pressed.connect(func(): pass)
	b.pressed.connect(func(): pass)   # unexpected wiring: two connections
	var ok: bool = c.session.purchases.rewire(ui, row, "item", {"category": "upgrades", "key": "sprint"})
	assert_false(ok, "not rewired")
	assert_true(b.disabled, "button disabled (fail closed, R12)")
	assert_eq(b.pressed.get_connections().size(), 0, "nothing can buy locally")
	assert_eq(b.text, ui.tr("MP_SHOP_UNAVAILABLE"), "MP_SHOP_UNAVAILABLE")
	row.free()


func test_recall_keeps_original() -> void:
	var pc = await _pair()
	var c = pc[1]
	Engine.set_meta("pitt_mp", c.session)
	var ui = c.adapter.ui()
	var tool_row = ui._create_tool_buy_row("broom", 0)
	tool_row.set_meta("recall_mode", true)
	_press(tool_row)
	assert_eq(ui.recalls, 1, "recall runs the original callable locally")
	assert_eq(c.session.purchases.sent, 0, "nothing sent")


func test_tool_and_toy_spawn_in_buyer_world() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	Engine.set_meta("pitt_mp", c.session)
	var ui = c.adapter.ui()
	_press(ui._create_tool_buy_row("broom", 0))
	var ok: bool = await rig.until(func(): return ui.spawned_tools.size() == 1, 3.0)
	assert_true(ok, "tool spawned in the client's world")
	assert_eq(h.adapter.ui().spawned_tools.size(), 0, "not in the host's world (MP1)")
	assert_eq(h.adapter.get_money(), "9500", "host charged the tool price")
	assert_true(h.adapter.fgs().purchased_once.get("broom", false), "purchased_once on the host")
	_press(ui._create_toy_buy_row("gambling_wodden_crate"))
	ok = await rig.until(func(): return ui.spawned_toys.size() == 1, 3.0)
	assert_true(ok, "toy spawned in the client's world")
	assert_eq(int(h.adapter.fgs().toys.gambling_wodden_crate.buy_prices[0]), 6, "crate price escalated (+1 wooden)")
	await rig.until(func(): return int(c.adapter.fgs().toys.gambling_wodden_crate.buy_prices[0]) == 6, 3.0)
	assert_eq(int(c.adapter.fgs().toys.gambling_wodden_crate.buy_prices[0]), 6, "escalated price mirrored")
	# pool full in the client's own world: refused locally, nothing sent
	c.adapter.nodes.ObjectPoolManager.full["tool_broom"] = true
	var sent: int = c.session.purchases.sent
	_press(ui._create_tool_buy_row("broom", 0))
	assert_eq(c.session.purchases.sent, sent, "pool full: not sent")


func test_host_revalidation() -> void:
	var pc = await _pair()
	var c = pc[1]
	var cases := [
		["PittMultiplayer.buy_item", {"category": "upgrades", "key": "luck"}, "ERR_DENIED", "locked upgrade"],
		["PittMultiplayer.buy_item", {"category": "upgrades", "key": "nope"}, "ERR_INVALID", "unknown"],
		["PittMultiplayer.buy_item", {"category": "products", "key": "crown", "subkey": "craft_speed"}, "ERR_DENIED", "locked product"],
		["PittMultiplayer.buy_tool", {"tool": "fan", "level": 0}, "ERR_DENIED", "locked tool"],
		["PittMultiplayer.buy_tool", {"tool": "broom", "level": 1}, "ERR_DENIED", "missing enabled_level"],
		["PittMultiplayer.buy_tool", {"tool": "broom", "level": 5}, "ERR_FAILED", "past max"],
		["PittMultiplayer.buy_toy", {"toy": "bumper"}, "ERR_DENIED", "locked toy"],
	]
	for t in cases:
		var r = await c.api.commands.execute_async(t[0], t[1])
		assert_false(r.ok, "%s refused" % t[3])
		assert_eq(r.code, t[2], "%s code (%s)" % [t[3], r.error])
	# gated: level 0 ok, level 1 locked by enabled_levels
	var r1 = await c.api.commands.execute_async("PittMultiplayer.buy_item", {"category": "upgrades", "key": "gated"})
	assert_true(r1.ok, "enabled level buys")
	var r2 = await c.api.commands.execute_async("PittMultiplayer.buy_item", {"category": "upgrades", "key": "gated"})
	assert_false(r2.ok, "next level locked by enabled_levels (R11)")
	# max level
	var r3 = await c.api.commands.execute_async("PittMultiplayer.buy_item", {"category": "upgrades", "key": "crouch"})
	assert_true(r3.ok, "crouch 1/1")
	var r4 = await c.api.commands.execute_async("PittMultiplayer.buy_item", {"category": "upgrades", "key": "crouch"})
	assert_eq(r4.code, "ERR_FAILED", "already max")
	# unaffordable: the auto workbench must not appear (GameState.buy calls it before its own check)
	var h = pc[0]
	h.adapter.fgs().set_money_int(3)
	await rig.until(func(): return c.adapter.get_money() == "3", 3.0)
	var r5 = await c.api.commands.execute_async("PittMultiplayer.buy_item", {"category": "products", "key": "duck", "subkey": "auto_machine"})
	assert_eq(r5.code, "ERR_FAILED", "unaffordable")
	assert_true(h.adapter.nodes.WorkbenchSpawning.auto_calls.is_empty(), "no auto bench before the price check")
	# a toy with levels (prices) goes through GameState.buy("toys", ...)
	h.adapter.fgs().set_money_int(1000)
	await rig.until(func(): return c.adapter.get_money() == "1000", 3.0)
	var r6 = await c.api.commands.execute_async("PittMultiplayer.buy_item", {"category": "toys", "key": "spinner"})
	assert_true(r6.ok, "leveled toy: %s" % r6.error)
	assert_eq(int(h.adapter.fgs().toys.spinner.level), 1, "toy level on the host")


func test_bowling_set_disabled_after_purchase() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var r = await c.api.commands.execute_async("PittMultiplayer.buy_toy", {"toy": "bowling_pin_set"})
	assert_true(r.ok, "bought")
	assert_false(bool(h.adapter.fgs().toys.bowling_pin_set.enabled), "disabled after one purchase, like the game")


# ================================================================== MP2 shared world (GAMEPLAY)

func _host_adapter(money: int = 10000):
	var a = FakeAdapter.new("mp2host", tree)
	a.enter_world(1, runner)
	a.fgs().set_money_int(money)
	return a


func test_mp2_host_terminal_spawns_the_bought_tool_once() -> void:
	var a = _host_adapter()
	var s := MP2Session.new()
	var p = Purchases.new(s, a)
	var r: Dictionary = p.host_buy_tool({"tool": "broom", "level": 0})
	assert_true(bool(r.ok), "bought: %s" % r.get("error", ""))
	assert_eq(a.ui().spawned_tools, [["broom", 0]], "spawned once by the host's terminal")
	assert_eq(a.get_money(), "9500", "charged once")
	assert_eq(p.host_spawns, 1, "counted")
	var t: Dictionary = p.host_buy_toy({"toy": "gambling_wodden_crate"})
	assert_true(bool(t.ok), "toy bought")
	assert_eq(a.ui().spawned_toys, ["gambling_wodden_crate"], "toy spawned by the host")
	assert_false(p.on_grant({"id": 1, "tool": "broom"}), "grant is a no-op in MP2")
	a.free_all()


func test_mp2_pool_full_refused_before_charging() -> void:
	var a = _host_adapter()
	var p = Purchases.new(MP2Session.new(), a)
	a.nodes.ObjectPoolManager.full["tool_broom"] = true
	var r: Dictionary = p.host_buy_tool({"tool": "broom", "level": 0})
	assert_false(bool(r.ok), "refused")
	assert_eq(String(r.code), "ERR_FAILED", "ERR_FAILED")
	assert_eq(a.get_money(), "10000", "not charged")
	assert_eq(a.ui().spawned_tools, [], "nothing spawned")
	assert_eq(Purchases.tool_pool_id("broom", 1), "tool_broom_2", "level pool id")
	assert_eq(Purchases.tool_pool_id("remote", 2), "tool_remote", "remote pool id")
	a.free_all()


func test_mp1_host_still_does_not_spawn() -> void:
	var a = _host_adapter()
	var s := MP2Session.new()
	s.mp2 = false
	var p = Purchases.new(s, a)
	assert_true(bool(p.host_buy_tool({"tool": "broom", "level": 0}).ok), "bought")
	assert_eq(a.ui().spawned_tools, [], "MP1: the buyer's world spawns it, not the host")
	a.free_all()


func test_mp2_client_press_spawns_nothing_locally() -> void:
	var a = FakeAdapter.new("mp2client", tree)
	a.enter_world(1, runner)
	var s := MP2Session.new()
	var p = Purchases.new(s, a)
	var ui = a.ui()
	var row = ui._create_tool_buy_row("broom", 0)
	assert_true(p.rewire(ui, row, "tool", {"tool": "broom", "level": 0}), "rewired")
	_press(row)
	await wait_frames(1)
	assert_eq(s.commands.size(), 1, "sent to the host")
	assert_eq(ui.spawned_tools, [], "MP2: nothing spawned in the buyer's world")
	assert_false(bool(row.get_meta("pittmp_pending", false)), "request finished")
	a.free_all()
