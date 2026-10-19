extends RefCounted
## Adaptive per-peer byte budget for body frames (MP2-DESIGN 3.3, D21).
## Starts at the physics_detail value (`configured`) and moves between a floor and
## a probe ceiling from the client's netq reports (loss, RTT; about 1 s apart).
##
## Signals (min_rtt is the minimum RTT of the last MIN_WINDOW_MS of reports, so a
## route change or a steadily slower relay becomes the new baseline instead of
## reading as congestion for the rest of the session):
##   - loss evidence: loss > 15 %, or loss > 5 % while the RTT rose 20 ms over the
##     minimum (queueing). Random loss on an idle link is not cured by sending
##     less, so 5-15 % loss at a steady RTT alone does not cut.
##   - RTT alone: over 2x the minimum AND RTT_SLACK_MS above it. Ignored while the
##     host is overloaded (its own frame stalls inflate the frame-paced ping).
## Congestion for 2 s -> x0.7 every 2 s. Loss evidence may cut to FLOOR_BPS
## (12 KB/s); RTT alone stops at RTT_FLOOR_SHARE x configured (the 2026-10-18
## session sat at 12 KB/s for about 80 minutes on RTT alone).
## Clean for 5 s -> +15 % of the configured value per second up to it (floor to
## normal in about 10 s). Probe-up: once at the configured value and quiet (no
## queueing, loss <= 5 %) for PROBE_HOLD_MS, +5 % of configured per second up to
## `ceiling`; any queueing or loss signal above configured drops straight back to
## configured (no cut below it) and holds the probe off for PROBE_BACKOFF_MS, so a
## probe that builds a queue never becomes the window's new RTT baseline.
## The host-wide overload guard halves the bytes of every budget, except when one
## peer is in game (bytes_for n_peers == 1: halving the only client's bytes saves
## no host CPU, it only starves that client).

const DETAIL := {"low": 24000, "normal": 48000, "high": 96000}
const FLOOR_BPS := 12000
const BAD_LOSS := 0.05
const HIGH_LOSS := 0.15
const RTT_RISE_MS := 20
const BAD_HOLD_MS := 2000
const CLEAN_HOLD_MS := 5000
const DOWN := 0.7
const UP := 0.15
const RTT_SLACK_MS := 50
## min_rtt is the minimum over this much report history (about 30 reports)
const MIN_WINDOW_MS := 30000
## RTT-only congestion never cuts below this share of the configured value
const RTT_FLOOR_SHARE := 0.5
## probe ceiling: configured x this, at most PROBE_CAP_BPS (the host-wide body
## upload cap, replicator_host.gd HOST_UPLOAD_BPS; not preloaded: it preloads us)
const PROBE_FACTOR := 3
const PROBE_CAP_BPS := 400000
const PROBE_HOLD_MS := 10000
const PROBE_STEP_MS := 1000
const PROBE_UP := 0.05
const PROBE_BACKOFF_MS := 30000

var configured := 48000
var bps := 48000
var ceiling := 144000
## windowed minimum RTT (-1 until the first RTT sample)
var min_rtt := -1
var downs := 0
var ups := 0
## steps above configured (also counted in ups), and drops back to configured
var probe_ups := 0
var probe_backs := 0
var last_loss := 0.0
var last_rtt := -1
var _rtts: Array = []            # [[t_ms, rtt_ms]] of the last MIN_WINDOW_MS
var _bad_since := -1
var _clean_since := -1
var _quiet_since := -1
var _probe_from := -1            # when bps last reached (or fell back to) configured
var _probe_block_until := -1
var _last_up_ms := 0
var _last_down_ms := 0


func _init(detail: String = "normal") -> void:
	configured = int(DETAIL.get(detail, DETAIL.normal))
	bps = configured
	ceiling = ceiling_for(configured)


static func detail_bps(detail: String) -> int:
	return int(DETAIL.get(detail, DETAIL.normal))


static func ceiling_for(cfg: int) -> int:
	return maxi(cfg, mini(cfg * PROBE_FACTOR, PROBE_CAP_BPS))


## The floor a cut may reach: FLOOR_BPS with loss evidence, else RTT_FLOOR_SHARE x configured.
func rtt_floor() -> int:
	return maxi(FLOOR_BPS, roundi(configured * RTT_FLOOR_SHARE))


## One quality report (netq, about 1 s): loss in 0..1, rtt in ms (-1 unknown).
## overload: the host's overload factor (below 1.0 the RTT-only signal is ignored).
func report(now_ms: int, loss: float, rtt_ms: int, overload: float = 1.0) -> void:
	last_loss = loss
	last_rtt = rtt_ms
	_window_rtt(now_ms, rtt_ms)
	# RTT: over 2x the windowed minimum AND at least RTT_SLACK_MS above it (a 1 ms LAN
	# minimum must not turn every 25 ms frame-paced ping into "congested")
	var rtt_bad := rtt_ms > 0 and min_rtt > 0 and rtt_ms > 2 * maxi(min_rtt, 10) and rtt_ms > min_rtt + RTT_SLACK_MS
	if overload < 1.0:
		rtt_bad = false
	var queueing := rtt_ms > 0 and min_rtt > 0 and rtt_ms > min_rtt + RTT_RISE_MS
	var loss_bad := loss > HIGH_LOSS or (loss > BAD_LOSS and queueing)
	var bad := rtt_bad or loss_bad
	if queueing or loss > BAD_LOSS:
		_quiet_since = -1
		if bps > configured:
			# a probe that queues or loses: straight back to configured, no cut below it
			bps = configured
			probe_backs += 1
			_probe_from = now_ms
			_probe_block_until = now_ms + PROBE_BACKOFF_MS
	elif not bad and _quiet_since < 0:
		_quiet_since = now_ms
	if bad:
		_clean_since = -1
		if _bad_since < 0:
			_bad_since = now_ms
		if now_ms - _bad_since >= BAD_HOLD_MS and now_ms - _last_down_ms >= BAD_HOLD_MS:
			var floor_bps := FLOOR_BPS if loss_bad else rtt_floor()
			# never raises: a loss cut may already sit below the RTT-only floor
			if bps > floor_bps:
				bps = maxi(floor_bps, int(bps * DOWN))
				_last_down_ms = now_ms
				downs += 1
	else:
		_bad_since = -1
		if _clean_since < 0:
			_clean_since = now_ms
	_step_up(now_ms)


## min_rtt = the minimum of the reports of the last MIN_WINDOW_MS.
func _window_rtt(now_ms: int, rtt_ms: int) -> void:
	if rtt_ms > 0:
		_rtts.append([now_ms, rtt_ms])
	while not _rtts.is_empty() and now_ms - int(_rtts[0][0]) > MIN_WINDOW_MS:
		_rtts.pop_front()
	if _rtts.is_empty():
		return    # keep the last minimum while no RTT arrives
	var m := int(_rtts[0][1])
	for s in _rtts:
		m = mini(m, int(s[1]))
	min_rtt = m


## Up to configured: +15 % of it per second once clean for 5 s. Above it: the
## probe (also called from the sender tick).
func _step_up(now_ms: int) -> void:
	if _clean_since < 0:
		return
	if bps < configured:
		if now_ms - _clean_since < CLEAN_HOLD_MS or now_ms - _last_up_ms < 1000:
			return
		# +15 % of the configured value per second: floor back to normal in 5 s hold + 5 steps
		bps = mini(configured, bps + roundi(configured * UP))
		_last_up_ms = now_ms
		ups += 1
		if bps >= configured:
			_probe_from = now_ms
		return
	if bps >= ceiling or _quiet_since < 0 or now_ms < _probe_block_until:
		return
	if now_ms - maxi(_quiet_since, _probe_from) < PROBE_HOLD_MS or now_ms - _last_up_ms < PROBE_STEP_MS:
		return
	bps = mini(ceiling, bps + roundi(configured * PROBE_UP))
	_last_up_ms = now_ms
	ups += 1
	probe_ups += 1


func tick(now_ms: int) -> void:
	_step_up(now_ms)


## Getters for stats / peer_budget_info: {bps, configured, ceiling, floor,
## downs, ups, probe_ups, probe_backs, min_rtt, loss, rtt}.
func info() -> Dictionary:
	return {"bps": bps, "configured": configured, "ceiling": ceiling, "floor": rtt_floor(), "downs": downs,
		"ups": ups, "probe_ups": probe_ups, "probe_backs": probe_backs, "min_rtt": min_rtt,
		"loss": last_loss, "rtt": last_rtt}


func get_bps() -> int:
	return bps


func get_configured() -> int:
	return configured


func get_ceiling() -> int:
	return ceiling


func get_downs() -> int:
	return downs


func get_ups() -> int:
	return ups


func get_min_rtt() -> int:
	return min_rtt


## Bytes for one send tick at tick_hz, with the overload factor (1.0 or 0.5).
## n_peers: in-game peers (-1 unknown: the overload factor applies; 1: it does not).
func bytes_per_tick(tick_hz: float, overload: float = 1.0, n_peers: int = -1) -> int:
	return bytes_for(1.0 / tick_hz, overload, 1.0, n_peers)


## Bytes for `seconds` of sending (a serve that covers skipped ticks gets their
## bytes too), with the overload factor and the host-wide upload share.
## n_peers == 1: the overload factor is ignored (the host upload share still applies).
func bytes_for(seconds: float, overload: float = 1.0, host_scale: float = 1.0, n_peers: int = -1) -> int:
	if n_peers == 1:
		overload = 1.0
	# the overload halving / upload share never goes below the floor (a floor-budget link
	# under an overloaded host would otherwise get 6 KB/s: puppets visibly stale)
	var eff := maxf(float(bps) * overload * host_scale, float(mini(bps, FLOOR_BPS)))
	return maxi(64, int(eff * seconds))
