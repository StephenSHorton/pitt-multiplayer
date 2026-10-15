extends "res://tests/test_case.gd"
## Shared combo (D9, MP2-DESIGN 6.9): the host's ComboSystem events and state go
## to clients as `combo`; clients write the fields, re-emit the game's own signals
## (the HUD reacts as in single player), run a local timer between updates, play
## the hit sound when the combo grows, unlock MORE at 100; the client's own
## ComboSystem physics is off for the session and restored after; the joiner gets
## the combo in its world-snapshot section.

const GpRig = preload("res://tests/fakes/mp2_gameplay/gp_rig.gd")

var rig = null


func before_all() -> void:
	rig = GpRig.new(tree, runner)


func after_all() -> void:
	await rig.cleanup()


func _pair() -> Array:
	await rig.cleanup()
	var h = rig.add_host()
	var c = rig.add_client(2)
	rig.start()
	return [h, c]


func test_events_and_state_mirror() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var hc = h.adapter.combo
	var cc = c.adapter.combo
	assert_false(cc.is_physics_processing(), "client ComboSystem physics off")
	var got: Array = []
	cc.combo_started.connect(func(l): got.append(["started", l]))
	cc.combo_ended.connect(func(l, t): got.append(["ended", l, t]))
	cc.chain_combo_triggered.connect(func(l, b): got.append(["chain", l, b]))
	cc.combo_broken.connect(func(): got.append(["broken"]))
	# host: a combo starts and grows
	hc.is_combo_active = true
	hc.current_combo = 1
	hc.combo_timer = 3.0
	hc.combo_started.emit(1)
	h.gp.combo.tick(1000)
	assert_eq(got, [["started", 1]], "started re-emitted on the client")
	assert_true(cc.is_combo_active and cc.current_combo == 1, "fields mirrored")
	hc.current_combo = 5
	hc.total_bonus = 120.0
	h.gp.combo.tick(1050)
	assert_eq(cc.current_combo, 1, "throttled to 10 Hz without events")
	h.gp.combo.tick(1200)
	assert_eq(cc.current_combo, 5, "combo 5 on the client HUD")
	assert_eq(cc.hits, 1, "hit sound when the mirrored combo grows")
	hc.chain_combo_triggered.emit(2, 30.0)
	hc.is_combo_active = false
	hc.combo_ended.emit(5, 150.0)
	hc.current_combo = 0
	h.gp.combo.tick(1210)
	assert_eq(got.slice(1), [["chain", 2, 30], ["ended", 5, 150.0]], "chain + ended in order")
	assert_false(cc.is_combo_active, "inactive")
	# 100+ unlocks MORE on the client (crossing while connected)
	hc.is_combo_active = true
	hc.current_combo = 101
	hc.combo_started.emit(1)
	h.gp.combo.tick(2000)
	assert_has(c.adapter.achievements, "MORE", "MORE at 100")
	assert_false("EXTRA" in c.adapter.achievements, "not EXTRA")


func test_client_local_timer() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var cc = c.adapter.combo
	var updates: Array = []
	cc.combo_updated.connect(func(l, p): updates.append([l, p]))
	h.adapter.combo.is_combo_active = true
	h.adapter.combo.current_combo = 3
	h.adapter.combo.combo_timer = 1.5
	h.adapter.combo.combo_started.emit(3)
	h.gp.combo.tick(5000)
	c.gp.combo.process(0.5)
	assert_eq(cc.combo_timer, 1.0, "timer decremented locally")
	assert_eq(updates[-1][0], 3, "combo_updated level")
	assert_true(absf(float(updates[-1][1]) - 1.0 / 3.0) < 0.001, "progress = timer / window")
	c.gp.teardown()
	assert_true(cc.is_physics_processing(), "physics restored on teardown")


func test_world_snapshot_section() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	h.adapter.combo.is_combo_active = true
	h.adapter.combo.current_combo = 7
	h.adapter.combo.bowling_multiplier = 1.4
	var sec: Dictionary = h.gp.wsnap_section()
	var wire = JSON.parse_string(JSON.stringify(sec))
	c.gp.apply_wsnap_section(wire)
	assert_eq(c.adapter.combo.current_combo, 7, "joiner sees the running combo")
	assert_eq(c.adapter.combo.bowling_multiplier, 1.4, "bowling multiplier")
	var before: int = h.session.sent_of("combo").size()
	assert_true(before >= 1, "full combo sent when the peer became world-ready")
	h.gp.combo.send_full(2)
	assert_eq(h.session.sent_of("combo").size(), before + 1, "full combo to a ready peer")
