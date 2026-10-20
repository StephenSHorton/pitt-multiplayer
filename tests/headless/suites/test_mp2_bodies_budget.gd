extends "res://tests/test_case.gd"
## MP2 3.3 adaptive budget (budget.gd), the 2026-10-18 fixes: the RTT minimum is
## windowed and RTT alone never cuts below half the configured value (P3), real
## loss still cuts to the 12 KB/s floor, a clean link probes above the
## configured value up to the ceiling and drops back on queueing (P5), and the
## overload factor leaves a single in-game peer's bytes alone (P11). Also the
## Steam transport's send-rate setter against a recording double.

const Budget = preload("res://gamedir/mods/PittMultiplayer/world/bodies/budget.gd")
const TransportSteam = preload("res://gamedir/mods/PittMultiplayer/net/transport_steam.gd")

var _e0 := 0


class SteamDouble extends RefCounted:
	var calls: Array = []
	var result := true

	func setGlobalConfigValueInt32(key: int, value: int) -> bool:
		calls.append([key, value])
		return result


func before_all() -> void:
	_e0 = core.guard.total_errors()


## Feeds one report per second from t0 (inclusive) to t1 (exclusive); returns
## [min bps, max bps] seen after each report.
func _feed(b, t0: int, t1: int, loss: float, rtt: int, overload: float = 1.0) -> Array:
	var lo: int = b.bps
	var hi: int = b.bps
	for t in range(t0, t1, 1000):
		b.report(t, loss, rtt, overload)
		lo = mini(lo, b.bps)
		hi = maxi(hi, b.bps)
	return [lo, hi]


func test_clean_then_steady_slower_link_recovers() -> void:
	# regime A of the 2026-10-18 session: a clean 50 ms link, then a steady 120 ms
	# one (route change / slower relay). The old session-lifetime minimum read
	# 120 ms as congestion for good and walked the budget down to 12 KB/s.
	var b := Budget.new("normal")
	_feed(b, 0, 20000, 0.0, 50)
	assert_true(b.bps >= 48000, "clean 50 ms: at least configured (it may already probe)")
	assert_eq(b.min_rtt, 50, "minimum 50 ms")
	var r := _feed(b, 20000, 200000, 0.0, 120)
	assert_true(int(r[0]) >= b.rtt_floor(), "RTT alone never cuts below half the configured value (lowest %d)" % int(r[0]))
	assert_true(int(r[0]) > Budget.FLOOR_BPS, "never pinned at the 12 KB/s floor")
	assert_true(b.downs > 0, "the RTT rise did cut at first")
	assert_eq(b.min_rtt, 120, "the windowed minimum follows the new link")
	assert_true(b.bps >= b.configured, "recovered to the configured value (%d)" % b.bps)


func test_rtt_only_floor_and_window() -> void:
	var b := Budget.new("normal")
	_feed(b, 0, 5000, 0.0, 40)
	var r := _feed(b, 5000, 25000, 0.0, 400)
	assert_eq(int(r[0]), 24000, "RTT-only congestion stops at configured x 0.5")
	assert_eq(b.bps, 24000, "and stays there while the RTT stays high inside the window")
	var o := Budget.new("normal")
	_feed(o, 0, 5000, 0.0, 40)
	_feed(o, 5000, 15000, 0.0, 400, 0.5)
	assert_eq(o.bps, 48000, "while the host is overloaded the RTT-only signal is ignored (host stalls inflate the ping)")
	var w := Budget.new("normal")
	w.report(0, 0.0, 30)
	for t in range(1000, 40000, 1000):
		w.report(t, 0.0, 60)
	assert_eq(w.min_rtt, 60, "a sample older than the window no longer sets the minimum")
	# "low": half of 24 KB/s would be the 12 KB/s loss floor itself
	var lo := Budget.new("low")
	assert_eq(lo.rtt_floor(), Budget.RTT_FLOOR_MIN_BPS, "low: the RTT-only floor is 18 KB/s")
	_feed(lo, 0, 5000, 0.0, 40)
	var rl := _feed(lo, 5000, 25000, 0.0, 400)
	assert_eq(int(rl[0]), 18000, "low: RTT-only congestion stops at 18 KB/s, above the loss floor")
	assert_eq(Budget.new("high").rtt_floor(), 48000, "high: half of 96 KB/s")


func test_real_loss_still_cuts() -> void:
	var b := Budget.new("normal")
	_feed(b, 0, 5000, 0.0, 50)
	_feed(b, 5000, 60000, 0.20, 50)
	assert_eq(b.bps, Budget.FLOOR_BPS, "20 % loss cuts to the 12 KB/s floor")
	_feed(b, 60000, 150000, 0.20, 50)
	assert_eq(b.bps, Budget.FLOOR_BPS, "and stays there while the loss lasts (no window lets it go)")
	var q := Budget.new("normal")
	_feed(q, 0, 5000, 0.0, 50)
	var rq := _feed(q, 5000, 30000, 0.10, 90)
	assert_eq(q.bps, Budget.FLOOR_BPS, "10 % loss while queueing (RTT +40 ms) also reaches the floor")
	assert_eq(q.min_rtt, 50, "lossy reports do not become the RTT baseline inside the window")
	assert_true(int(rq[1]) <= 48000, "no recovery inside the window")
	var rnd := Budget.new("normal")
	var r := _feed(rnd, 0, 60000, 0.10, 50)
	assert_eq(int(r[0]), 48000, "10 % loss at a steady RTT: no cut")
	assert_eq(int(r[1]), 48000, "and no probe above configured either")


func test_lasting_loss_with_slower_route_recovers() -> void:
	# Wi-Fi-like lasting 8 % loss plus a route change 50 -> 120 ms: no report of the
	# new route is clean, so without the lossy fallback the minimum stayed 50, every
	# report read as queueing + loss, and the budget sat at 12 KB/s for good.
	var b := Budget.new("normal")
	_feed(b, 0, 20000, 0.0, 50)
	var cut := _feed(b, 20000, 50000, 0.08, 120)
	assert_eq(int(cut[0]), Budget.FLOOR_BPS, "the loss cut works for a window first")
	assert_eq(b.min_rtt, 50, "the old minimum holds inside the window")
	var rec := _feed(b, 50000, 120000, 0.08, 120)
	assert_eq(b.min_rtt, 120, "after a whole window of lossy reports their lowest is the minimum")
	assert_eq(b.bps, b.configured, "recovered to the configured value (%d)" % b.bps)
	assert_true(int(rec[1]) <= b.configured, "no probe above configured while the loss is over 5 %")
	# a real bottleneck given the bytes back: the RTT rises over the new minimum again -> cut again
	var downs: int = b.downs
	_feed(b, 120000, 130000, 0.08, 170)
	assert_true(b.downs > downs and b.bps < b.configured, "a renewed queue + loss cuts again (%d)" % b.bps)


func test_probe_up_capped_and_backs_off() -> void:
	var b := Budget.new("normal")
	assert_eq(b.ceiling, 144000, "ceiling = 3 x configured")
	assert_eq(Budget.ceiling_for(24000), 72000, "low: 72 KB/s")
	assert_eq(Budget.ceiling_for(96000), 288000, "high: 288 KB/s")
	assert_eq(Budget.ceiling_for(200000), Budget.PROBE_CAP_BPS, "never above the host-wide upload cap")
	_feed(b, 0, 9000, 0.0, 50)
	assert_eq(b.bps, 48000, "no probe before PROBE_HOLD_MS of quiet")
	var r := _feed(b, 9000, 120000, 0.0, 50)
	assert_true(b.bps > b.configured, "a clean link probes above configured (%d)" % b.bps)
	assert_true(int(r[1]) <= b.ceiling, "never above the ceiling (max %d)" % int(r[1]))
	assert_eq(b.bps, b.ceiling, "and reaches it on a long clean stretch")
	assert_true(b.probe_ups > 0, "probe steps counted")
	var downs: int = b.downs
	b.report(120000, 0.0, 80)
	assert_eq(b.bps, b.configured, "queueing while probing: straight back to configured")
	assert_eq(b.downs, downs, "a probe retreat is not a cut")
	assert_eq(b.probe_backs, 1, "counted as a probe retreat")
	var r2 := _feed(b, 121000, 150000, 0.0, 50)
	assert_eq(int(r2[1]), b.configured, "no new probe during the back-off")
	_feed(b, 150000, 175000, 0.0, 50)
	assert_true(b.bps > b.configured, "probing resumes after the back-off")
	var info: Dictionary = b.info()
	for k in ["bps", "configured", "ceiling", "downs", "ups", "min_rtt"]:
		assert_true(info.has(k), "info() has %s" % k)
	assert_eq(b.get_ceiling(), b.ceiling, "getter")


func test_no_probe_without_reports() -> void:
	var b := Budget.new("normal")
	_feed(b, 0, 15000, 0.0, 50)
	var at: int = b.bps
	assert_true(at > b.configured, "probing while reports arrive (%d)" % at)
	# reports stop (relay stall, client hitch, loading): only the sender tick runs
	for t in range(15000, 75000, 33):
		b.tick(t)
	assert_true(b.bps <= at + roundi(b.configured * Budget.PROBE_UP) * 2,
		"no probe climb without link feedback (%d -> %d)" % [at, b.bps])
	b.report(75000, 0.0, 50)
	b.tick(76000)
	assert_true(b.bps > at, "probing resumes with fresh reports")


func test_single_peer_overload_keeps_bytes() -> void:
	var b := Budget.new("normal")
	assert_eq(b.bytes_per_tick(30.0, 0.5, 1), b.bytes_per_tick(30.0), "one in-game peer: the overload factor does not cut its bytes")
	assert_eq(b.bytes_for(1.0, 0.5, 1.0, 1), 48000, "bytes_for with one peer")
	assert_eq(b.bytes_for(1.0, 0.5, 1.0, 2), 24000, "two peers: overload still halves")
	assert_eq(b.bytes_per_tick(30.0, 0.5), 800, "peer count unknown: as before")
	assert_eq(b.bytes_for(1.0, 0.5, 0.5, 1), 24000, "the host-wide upload share still applies with one peer")


func test_steam_send_rate_setter() -> void:
	var s := SteamDouble.new()
	assert_true(TransportSteam.apply_send_rate(s, 10, 11, 512000), "set through setGlobalConfigValueInt32")
	assert_eq(s.calls, [[11, 512000], [10, 512000]], "max first, then min, same value")
	var bad := SteamDouble.new()
	bad.result = false
	assert_false(TransportSteam.apply_send_rate(bad, 10, 11, 512000), "a refused value reports false")
	assert_false(TransportSteam.apply_send_rate(null, 10, 11, 512000), "no Steam singleton")
	assert_false(TransportSteam.apply_send_rate(s, -1, 11, 512000), "constant missing (GodotSteam absent)")
	assert_eq(TransportSteam.steam_const("NETWORKING_CONFIG_SEND_RATE_MAX"), -1 if not ClassDB.class_exists("Steam") else
		ClassDB.class_get_integer_constant("Steam", "NETWORKING_CONFIG_SEND_RATE_MAX"), "constants through ClassDB")
	# the rate follows the host's tier and stays off Steam's default unless the tier needs more
	assert_eq(TransportSteam.send_rate_target("normal", 0), 0, "normal (ceiling 144 KB/s): Steam's own rate stays")
	assert_eq(TransportSteam.send_rate_target("low", 0), 0, "low: Steam's own rate stays")
	assert_eq(TransportSteam.send_rate_target("", 0), 0, "client: Steam's own rate stays")
	var hi := TransportSteam.send_rate_target("high", 0)
	assert_eq(hi, Budget.ceiling_for(96000) + TransportSteam.SEND_RATE_HEADROOM_BPS, "high: the probe ceiling plus headroom")
	assert_true(hi > TransportSteam.STEAM_DEFAULT_SEND_RATE_BPS and hi < 512000, "above the default, well under the old fixed 512 KB/s")
	assert_eq(TransportSteam.send_rate_target("normal", hi), TransportSteam.STEAM_DEFAULT_SEND_RATE_BPS,
		"after a raised session the process-wide value goes back to the default")


## Last: a script error aborts a test silently (it would look passed), so none may occur.
func test_zz_no_script_errors() -> void:
	assert_eq(core.guard.total_errors() - _e0, 0, "script errors during the suite (see headless-run.log)")
