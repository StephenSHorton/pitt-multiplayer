extends "res://tests/test_case.gd"
## Session diagnostics (2026-10-18 fix plan P1, session half): the host keeps a
## per-peer RTT from the pongs to its pings, the stats line keeps its original
## fields and appends the host replicator's totals and each peer's RTT and
## budget row, dump() carries them, and a leaving peer's numbers are kept
## before on_peer_left clears the replicator's per-peer state.

const Mp2Rig = preload("res://tests/fakes/mp2_bodies/mp2_rig.gd")
const Session = preload("res://gamedir/mods/PittMultiplayer/net/session.gd")

var rig = null
var _e0 := 0


func before_all() -> void:
	rig = Mp2Rig.new(tree, runner)
	_e0 = core.guard.total_errors()


func after_all() -> void:
	await rig.cleanup()


func test_host_rtt_stats_line_and_dump() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	var cp: int = c.session.my_peer_id()
	var ok: bool = await rig.until(func(): return h.session.peer_rtt_ms(cp) >= 0, 3.0)
	assert_true(ok, "the host measured an RTT from the client's pongs")
	assert_eq(h.session.peer_rtt_ms(424242), -1, "unknown peer: -1")
	var line: String = h.session.stats_line()
	assert_true(line.begins_with("mp stats: host in_game/"), "original prefix kept: %s" % line)
	assert_true(line.contains(" | avatars "), "original fields kept")
	assert_true(line.contains("| peer %d rtt %d" % [cp, h.session.peer_rtt_ms(cp)]), "per-peer RTT appended: %s" % line)
	assert_true(line.contains("eff_bps "), "the replicator's budget row is consumed: %s" % line)
	assert_true(line.contains("| host ") and line.contains("overload "), "host replicator totals: %s" % line)
	var cl: String = c.session.stats_line()
	assert_true(cl.begins_with("mp stats: client"), "client line")
	assert_true(cl.contains("rtt %d ms" % int(c.session.clock.rtt_ms)), "the client prints its own clock RTT: %s" % cl)
	var d: Dictionary = h.session.dump()
	for k in ["peer_rtt_ms", "left_peers", "bodies_host", "net", "counters"]:
		assert_true(d.has(k), "dump has %s" % k)
	assert_true(d.peer_rtt_ms.has(cp), "dump peer_rtt_ms per peer")
	assert_true(d.bodies_host.has("peers"), "dump carries the replicator stats()")
	assert_true(JSON.stringify(d) != "", "dump stays JSON-serialisable")


func test_left_peer_snapshot() -> void:
	var pc = await rig.pair()
	var h = pc[0]
	var c = pc[1]
	var cp: int = c.session.my_peer_id()
	await rig.until(func(): return h.session.peer_rtt_ms(cp) >= 0, 3.0)
	await rig.ms(1100)    # one full meter window
	c.session.leave()
	var ok: bool = await rig.until(func(): return not h.session.roster.has(cp), 3.0)
	assert_true(ok, "the host dropped the client")
	var left: Dictionary = h.session.dump().left_peers
	assert_true(left.has(cp), "left peer kept: %s" % str(left.keys()))
	if left.has(cp):
		var snap: Dictionary = left[cp]
		assert_eq(String(snap.why), "left", "reason")
		assert_true(int(snap.rtt_ms) >= 0, "its RTT")
		assert_true(snap.budget.has("eff_bps"), "its budget row from before on_peer_left: %s" % str(snap.budget))
		assert_true(snap.meter.size() > 0 and snap.meter.any(func(w): return int(w.tx) > 0), "its last seconds of traffic")
	assert_eq(h.session.peer_rtt_ms(cp), -1, "live RTT forgotten")
	var leaving := func() -> int: return h.session.log_lines.filter(func(l): return String(l).contains("peer %d leaving" % cp)).size()
	assert_eq(leaving.call(), 1, "logged once")
	# a disconnect after the bye drops the same peer again: no second snapshot or line
	h.session._drop_peer(cp, "dropped", false)
	assert_eq(leaving.call(), 1, "still logged once after a second drop")
	assert_eq(String(h.session.dump().left_peers[cp].why), "left", "the first snapshot is kept")


func test_fmt_kv_consumes_any_keys() -> void:
	var s: String = Session._fmt_kv({"bps": 48000, "overload": 0.5, "netq": {"loss": 0.25, "rtt_ms": 50}, "ok": true,
		"arr": [1, 2]}, ["skip"])
	assert_eq(s, "bps 48000 netq.loss 0.25 netq.rtt_ms 50 ok 1 overload 0.50", "sorted scalars, one nested level")
	assert_eq(Session._fmt_kv({"skip": 1}, ["skip"]), "", "skipped keys")


## Last: a script error aborts a test silently (it would look passed), so none may occur.
func test_zz_no_script_errors() -> void:
	assert_eq(core.guard.total_errors() - _e0, 0, "script errors during the suite (see headless-run.log)")
