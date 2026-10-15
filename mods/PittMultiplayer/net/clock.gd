extends RefCounted
## Wall-clock helper (Engine.time_scale changes in phase 3, so network timing
## never uses the scaled process delta). Clients estimate the host clock from
## ping/pong: offset = host_ms + rtt/2 - local_ms (smoothed, best of recent RTTs).

var offset_ms := 0.0
var rtt_ms := 0.0
var samples := 0
var _best_rtt := INF
var now_override := -1     # tests


func now() -> int:
	return now_override if now_override >= 0 else Time.get_ticks_msec()


## The host's clock as seen from here (0 offset on the host).
func host_now() -> int:
	return now() + int(round(offset_ms))


## A pong arrived: t0 = our send time, host_ms = the host's clock when it answered.
func on_pong(t0: int, host_ms: int) -> void:
	var t1 := now()
	var rtt := float(maxi(t1 - t0, 0))
	var est := float(host_ms) + rtt * 0.5 - float(t1)
	samples += 1
	rtt_ms = rtt if samples == 1 else lerpf(rtt_ms, rtt, 0.2)
	if samples == 1:
		offset_ms = est
		_best_rtt = rtt
		return
	# trust low-RTT samples more (less queueing error)
	var w := 0.5 if rtt <= _best_rtt * 1.5 else 0.1
	_best_rtt = minf(_best_rtt * 1.02, rtt)
	offset_ms = lerpf(offset_ms, est, w)


func reset() -> void:
	offset_ms = 0.0
	rtt_ms = 0.0
	samples = 0
	_best_rtt = INF
