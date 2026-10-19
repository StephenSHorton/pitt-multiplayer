extends "res://tests/test_case.gd"
## MP2 3.3 priority and budget: weights, selection within the byte budget,
## starvation (every awake body sent within 3 s at 200 bodies), adaptive
## budget x0.7 / +10 % per second, floor 12 KB/s, overload halving.

const Priority = preload("res://gamedir/mods/PittMultiplayer/world/bodies/priority.gd")
const Budget = preload("res://gamedir/mods/PittMultiplayer/world/bodies/budget.gd")


func test_weights() -> void:
	assert_eq(Priority.kind_w("duck", "pooled", 3, "held", 2), 4.0, "held by another peer")
	assert_eq(Priority.kind_w("duck", "pooled", 1, "held", 2), 3.0, "held by the host player")
	assert_eq(Priority.kind_w("tool_fan", "pooled", 1, "", 2), 1.5, "tool")
	assert_eq(Priority.kind_w("toy_bumper", "pooled", 1, "", 2), 1.5, "toy")
	assert_eq(Priority.kind_w("", "fixture_body", 1, "", 2), 1.5, "fixture body")
	assert_eq(Priority.kind_w("duck", "pooled", 1, "", 2), 1.0, "product")
	assert_eq(Priority.kind_w("candy_luck", "pooled", 1, "", 2), 0.6, "candy")
	assert_eq(Priority.dist_w(0.0), 1.0, "at the avatar")
	assert_eq(Priority.dist_w(8.0), 0.5, "8 m -> 0.5")
	assert_eq(Priority.dist_w(1000.0), 0.05, "floor 0.05")
	assert_eq(Priority.motion_w(0.0), 1.0, "resting 1")
	assert_eq(Priority.motion_w(100.0), 4.0, "cap 4")
	assert_eq(Priority.boost_w(true), 3.0, "boost")


func test_select_respects_budget() -> void:
	var cands: Array = []
	for i in 100:
		cands.append([float(i), 1000 + i, 25])
	var picked := Priority.select(cands, 250)
	assert_eq(picked.size(), 10, "10 x 25 B")
	assert_eq(picked[0], 1099, "highest accumulator first")
	assert_eq(Priority.select(cands, 1).size(), 1, "never starves completely")
	assert_eq(Priority.select([], 1000).size(), 0, "empty")


func test_no_starvation_at_200_bodies() -> void:
	# 200 awake bodies at 0..200 m, 30 Hz ticks, the budget of a 24 KB/s peer
	var acc := {}
	var last_sent := {}
	var budget := int(24000 / 30.0)
	var worst := 0
	for t in 300:
		var cands: Array = []
		for i in 200:
			var w := Priority.kind_w("duck", "pooled", 1, "", 2) * Priority.dist_w(float(i)) * Priority.motion_w(3.0)
			acc[i] = float(acc.get(i, 0.0)) + w / 30.0
			cands.append([acc[i], i, 25])
		for e in Priority.select(cands, budget):
			acc[e] = 0.0
			if last_sent.has(e):
				worst = maxi(worst, t - int(last_sent[e]))
			last_sent[e] = t
	for i in 200:
		assert_true(last_sent.has(i), "body %d sent at least once" % i)
	assert_true(worst <= 90, "every awake body within 3 s (worst gap %d ticks)" % worst)


func test_budget_adapts() -> void:
	var b := Budget.new("normal")
	assert_eq(b.bps, 48000, "normal 48 KB/s")
	assert_eq(Budget.detail_bps("low"), 24000, "low")
	assert_eq(Budget.detail_bps("high"), 96000, "high")
	var rnd := Budget.new("normal")
	for t in range(0, 20000, 1000):
		rnd.report(t, 0.10, 40)
	assert_eq(rnd.bps, 48000, "10 % random loss at a steady RTT: no cut (sending less does not fix it)")
	var q := Budget.new("normal")
	q.report(0, 0.0, 40)
	for t in range(1000, 4000, 1000):
		q.report(t, 0.10, 70)
	assert_eq(q.bps, 33600, "10 % loss while the RTT rose 30 ms (queueing): x0.7 after 2 s")
	b.report(0, 0.0, 40)
	b.report(1000, 0.20, 40)
	assert_eq(b.bps, 48000, "loss must last 2 s")
	b.report(3000, 0.20, 40)
	assert_eq(b.bps, 33600, "x0.7 after 2 s of heavy loss (> 15 %)")
	for t in range(4000, 40000, 1000):
		b.report(t, 0.20, 40)
	assert_eq(b.bps, 12000, "floor 12 KB/s")
	b.report(41000, 0.0, 40)
	b.report(45000, 0.0, 40)
	assert_eq(b.bps, 12000, "no recovery before 5 s clean")
	b.report(46000, 0.0, 40)
	assert_eq(b.bps, 19200, "+15 % of the configured value per second once clean for 5 s")
	for t in range(47000, 54000, 1000):
		b.report(t, 0.0, 40)
	assert_eq(b.bps, 48000, "floor to normal within 15 s of a clean link (5 s hold + 5 steps)")
	for t in range(54000, 80000, 1000):
		b.report(t, 0.0, 40)
	# probe-up (P5): a quiet link at the configured value probes above it, never past the ceiling
	assert_true(b.bps > 48000 and b.bps <= b.ceiling, "a clean link probes above configured, up to the ceiling (%d)" % b.bps)
	var r := Budget.new("normal")
	r.report(0, 0.0, 30)
	r.report(1000, 0.0, 200)
	r.report(3500, 0.0, 200)
	assert_true(r.bps < 48000, "RTT over 2x the minimum for 2 s also adapts down")
	var lan := Budget.new("normal")
	lan.report(0, 0.0, 1)
	for t in range(1000, 8000, 1000):
		lan.report(t, 0.0, 30)
	assert_eq(lan.bps, 48000, "1 ms minimum, 30 ms pings: within the 50 ms slack, no cut")
	var nb := Budget.new("normal")
	assert_eq(nb.bytes_per_tick(30.0), 1600, "48000 / 30")
	assert_eq(nb.bytes_per_tick(30.0, 0.5), 800, "overload halves")
	var fl := Budget.new("normal")
	fl.bps = 12000
	assert_eq(fl.bytes_per_tick(30.0, 0.5), 400, "overload never below the 12 KB/s floor")
