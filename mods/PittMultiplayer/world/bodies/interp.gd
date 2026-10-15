extends RefCounted
## Puppet interpolation (MP2-DESIGN 3.4). Pure functions over a ring of host
## states sorted by host time: {t: host ms, p: Vector3, q: Quaternion,
## l: Vector3, a: Vector3, flags: int, epoch: int}.
##   - Hermite position when both neighbours carry LIN, linear otherwise; slerp
##   - a SNAP state is never interpolated into (the previous pose holds, then jumps)
##   - extrapolation with velocity up to MAX_EXTRAP_MS past the newest state, then hold
##   - a SLEEP newest state is held exactly

const Codec = preload("../../net/codec.gd")

const RING := 6
const MAX_EXTRAP_MS := 250
const DELAY_MIN_MS := 66
const DELAY_MAX_MS := 200
const DELAY_DEFAULT_MS := 100


static func hermite(p0: Vector3, v0: Vector3, p1: Vector3, v1: Vector3, dt_s: float, u: float) -> Vector3:
	var u2 := u * u
	var u3 := u2 * u
	var h00 := 2.0 * u3 - 3.0 * u2 + 1.0
	var h10 := u3 - 2.0 * u2 + u
	var h01 := -2.0 * u3 + 3.0 * u2
	var h11 := u3 - u2
	return p0 * h00 + v0 * (h10 * dt_s) + p1 * h01 + v1 * (h11 * dt_s)


## interp_delay = clamp(2 x jitter + 33 ms, 66, 200)
## mean_late_ms: the mean of (host_now on arrival - host_ms of the frame), i.e. one-way
## latency plus the send-tick wait. The render time must stay behind the newest frame
## by that much, or a link with latency interpolates nothing and always extrapolates.
static func delay_for(jitter_ms: float, mean_late_ms: float = 0.0) -> int:
	return clampi(roundi(maxf(mean_late_ms, 0.0) + 2.0 * jitter_ms + 33.0), DELAY_MIN_MS, DELAY_MAX_MS)


## Inserts a state keeping host-time order; drops duplicates and anything older
## than the oldest kept state once the ring is full. Returns false when dropped.
static func ring_push(ring: Array, s: Dictionary) -> bool:
	var t := int(s.t)
	var i := ring.size()
	while i > 0 and int(ring[i - 1].t) > t:
		i -= 1
	if i > 0 and int(ring[i - 1].t) == t:
		return false
	if ring.size() >= RING and i == 0:
		return false
	ring.insert(i, s)
	while ring.size() > RING:
		ring.pop_front()
	return true


## -> {p, q, v, mode} at render time rt ({} for an empty ring). mode:
## "before" | "interp" | "snap_wait" | "extrap" | "hold" | "sleep"
static func sample(ring: Array, rt: int) -> Dictionary:
	if ring.is_empty():
		return {}
	var first: Dictionary = ring[0]
	if rt <= int(first.t):
		return {"p": first.p, "q": first.q, "v": first.l, "mode": "before"}
	var last: Dictionary = ring[ring.size() - 1]
	if rt >= int(last.t):
		if int(last.flags) & Codec.RF_SLEEP:
			return {"p": last.p, "q": last.q, "v": Vector3.ZERO, "mode": "sleep"}
		var e := mini(rt - int(last.t), MAX_EXTRAP_MS)
		if int(last.flags) & Codec.RF_LIN:
			return {"p": last.p + last.l * (float(e) / 1000.0), "q": last.q, "v": last.l,
				"mode": "extrap" if rt - int(last.t) <= MAX_EXTRAP_MS else "hold"}
		return {"p": last.p, "q": last.q, "v": Vector3.ZERO, "mode": "hold"}
	var i := 0
	while i < ring.size() - 1 and int(ring[i + 1].t) <= rt:
		i += 1
	var a: Dictionary = ring[i]
	var b: Dictionary = ring[i + 1]
	var span := int(b.t) - int(a.t)
	if int(b.flags) & Codec.RF_SNAP:
		# a teleport: keep moving with the old state, never streak across the jump
		var pa: Vector3 = a.p
		if int(a.flags) & Codec.RF_LIN:
			pa = a.p + a.l * (float(mini(rt - int(a.t), MAX_EXTRAP_MS)) / 1000.0)
		return {"p": pa, "q": a.q, "v": a.l, "mode": "snap_wait"}
	var u := clampf(float(rt - int(a.t)) / float(maxi(span, 1)), 0.0, 1.0)
	var p: Vector3
	if (int(a.flags) & Codec.RF_LIN) and (int(b.flags) & Codec.RF_LIN):
		p = hermite(a.p, a.l, b.p, b.l, float(span) / 1000.0, u)
	else:
		p = (a.p as Vector3).lerp(b.p, u)
	var qa: Quaternion = a.q
	var qb: Quaternion = b.q
	if qa.dot(qb) < 0.0:
		qb = -qb
	return {"p": p, "q": qa.slerp(qb, u).normalized(), "v": (a.l as Vector3).lerp(b.l, u), "mode": "interp"}


## Smallest angle between two rotations, degrees (tests).
static func angle_deg(a: Quaternion, b: Quaternion) -> float:
	var d := absf(a.normalized().dot(b.normalized()))
	return rad_to_deg(2.0 * acos(clampf(d, -1.0, 1.0)))
