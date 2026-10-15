extends RefCounted
## Adaptive per-peer byte budget for body frames (MP2-DESIGN 3.3, D21).
## Starts at the physics_detail value; congestion for 2 s -> x0.7 (floor 12 KB/s).
## Congestion = RTT > 2 x the session minimum, or loss > 15 %, or loss > 5 % while
## the RTT rose 20 ms over its minimum (queueing): random loss on an idle link is
## not cured by sending less, so it alone does not cut the budget below 15 %.
## clean for 5 s -> +15 % of the configured value per
## second up to it (floor to normal in about 10 s). The host-wide overload guard halves every budget.

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

var configured := 48000
var bps := 48000
var min_rtt := -1
var _bad_since := -1
var _clean_since := -1
var _last_up_ms := 0
var _last_down_ms := 0
var downs := 0
var ups := 0


func _init(detail: String = "normal") -> void:
	configured = int(DETAIL.get(detail, DETAIL.normal))
	bps = configured


static func detail_bps(detail: String) -> int:
	return int(DETAIL.get(detail, DETAIL.normal))


## One quality report (netq, about 1 s): loss in 0..1, rtt in ms (-1 unknown).
func report(now_ms: int, loss: float, rtt_ms: int) -> void:
	if rtt_ms > 0 and (min_rtt < 0 or rtt_ms < min_rtt):
		min_rtt = rtt_ms
	# RTT: over 2x the session minimum AND at least RTT_SLACK_MS above it (a 1 ms LAN
	# minimum must not turn every 25 ms frame-paced ping into "congested")
	var rtt_bad := rtt_ms > 0 and min_rtt > 0 and rtt_ms > 2 * maxi(min_rtt, 10) and rtt_ms > min_rtt + RTT_SLACK_MS
	var queueing := rtt_ms > 0 and min_rtt > 0 and rtt_ms > min_rtt + RTT_RISE_MS
	var bad := rtt_bad or loss > HIGH_LOSS or (loss > BAD_LOSS and queueing)
	if bad:
		_clean_since = -1
		if _bad_since < 0:
			_bad_since = now_ms
		if now_ms - _bad_since >= BAD_HOLD_MS and now_ms - _last_down_ms >= BAD_HOLD_MS:
			bps = maxi(FLOOR_BPS, int(bps * DOWN))
			_last_down_ms = now_ms
			downs += 1
	else:
		_bad_since = -1
		if _clean_since < 0:
			_clean_since = now_ms
	_step_up(now_ms)


## +10 % per second once clean for 5 s (also called from the sender tick).
func _step_up(now_ms: int) -> void:
	if _clean_since < 0 or bps >= configured:
		return
	if now_ms - _clean_since < CLEAN_HOLD_MS or now_ms - _last_up_ms < 1000:
		return
	# +15 % of the configured value per second: floor back to normal in 5 s hold + 5 steps
	bps = mini(configured, bps + roundi(configured * UP))
	_last_up_ms = now_ms
	ups += 1


func tick(now_ms: int) -> void:
	_step_up(now_ms)


## Bytes for one send tick at tick_hz, with the overload factor (1.0 or 0.5).
func bytes_per_tick(tick_hz: float, overload: float = 1.0) -> int:
	return bytes_for(1.0 / tick_hz, overload)


## Bytes for `seconds` of sending (a serve that covers skipped ticks gets their
## bytes too), with the overload factor and the host-wide upload share.
func bytes_for(seconds: float, overload: float = 1.0, host_scale: float = 1.0) -> int:
	# the overload halving / upload share never goes below the floor (a floor-budget link
	# under an overloaded host would otherwise get 6 KB/s: puppets visibly stale)
	var eff := maxf(float(bps) * overload * host_scale, float(mini(bps, FLOOR_BPS)))
	return maxi(64, int(eff * seconds))
