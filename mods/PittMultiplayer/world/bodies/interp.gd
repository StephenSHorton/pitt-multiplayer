extends RefCounted
## Puppet interpolation (MP2-DESIGN 3.4). Pure functions over a ring of host
## states sorted by host time: {t: host ms, p: Vector3, q: Quaternion,
## l: Vector3, a: Vector3, flags: int, epoch: int}.
##   - Hermite position when both neighbours carry LIN and lie at most
##     HERMITE_MAX_SPAN_MS apart, linear otherwise (a tangent scaled by a long
##     span swings far off the path); slerp
##   - a SNAP state is never interpolated into (the previous pose holds, then jumps)
##   - extrapolation with linear (LIN) and angular (ANG) velocity past the newest
##     state for about one update interval of the body (extrap_cap), then hold
##   - a SLEEP newest state is held exactly
##   - v is always the derivative of the returned p (zero in before / hold /
##     sleep): the client replicator compares poses frame to frame
## The release lead (replicator_client._check_release) samples ahead of rt and
## widens the extrapolation cap by the same amount (`lead_ms`).

const Codec = preload("../../net/codec.gd")

const RING := 6
const MAX_EXTRAP_MS := 250          # the cap while the update interval is unknown (one state)
const EXTRAP_MIN_MS := 100          # 30 Hz with a lost record or two
const EXTRAP_MAX_MS := 600          # a starved body (records 500 ms apart) keeps moving
const EXTRAP_MARGIN_MS := 50
const HERMITE_MAX_SPAN_MS := 100
const ANG_EPS := 0.0001             # rad/s below which a record does not rotate
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


## d/dt of hermite() (per second, not per unit u).
static func hermite_vel(p0: Vector3, v0: Vector3, p1: Vector3, v1: Vector3, dt_s: float, u: float) -> Vector3:
	var u2 := u * u
	var d00 := 6.0 * u2 - 6.0 * u
	var d10 := 3.0 * u2 - 4.0 * u + 1.0
	var d01 := -6.0 * u2 + 6.0 * u
	var d11 := 3.0 * u2 - 2.0 * u
	return (p0 * d00 + p1 * d01) / maxf(dt_s, 0.001) + v0 * d10 + v1 * d11


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


## The body's expected update interval (ms) from the ring: the smaller of the
## last two record spacings (a lost record or the wake after a long SLEEP
## widens only one of them); -1 with fewer than two states.
static func update_interval(ring: Array) -> int:
	var n := ring.size()
	if n < 2:
		return -1
	var d := int(ring[n - 1].t) - int(ring[n - 2].t)
	if n >= 3:
		d = mini(d, int(ring[n - 2].t) - int(ring[n - 3].t))
	return maxi(d, 1)


## How far past the newest state a body is extrapolated before it holds: about
## one update interval (P7). A body coming to rest is overshot by at most that
## much while its SLEEP record is on the way; a starved one keeps moving until
## its next record.
static func extrap_cap(ring: Array) -> int:
	var iv := update_interval(ring)
	if iv < 0:
		return MAX_EXTRAP_MS
	return clampi(iv + EXTRAP_MARGIN_MS, EXTRAP_MIN_MS, EXTRAP_MAX_MS)


## `q` turned by the world-frame angular velocity `a` (rad/s) for `ms`.
static func rotate(q: Quaternion, a: Vector3, ms: int) -> Quaternion:
	var w := a.length()
	if w <= ANG_EPS or ms <= 0:
		return q
	return (Quaternion(a / w, w * float(ms) / 1000.0) * q).normalized()


## -> {p, q, v, w, mode} at render time rt (v, w: linear / angular velocity of p, q) ({} for an empty ring). mode:
## "before" | "interp" | "snap_wait" | "extrap" | "hold" | "sleep"
## lead_ms: the caller samples this far ahead of its render time (release lead):
## the extrapolation cap grows by as much.
static func sample(ring: Array, rt: int, lead_ms: int = 0) -> Dictionary:
	if ring.is_empty():
		return {}
	var first: Dictionary = ring[0]
	if rt <= int(first.t):
		return {"p": first.p, "q": first.q, "v": Vector3.ZERO, "w": Vector3.ZERO, "mode": "before"}
	var last: Dictionary = ring[ring.size() - 1]
	if rt >= int(last.t):
		if int(last.flags) & Codec.RF_SLEEP:
			return {"p": last.p, "q": last.q, "v": Vector3.ZERO, "w": Vector3.ZERO, "mode": "sleep"}
		return _extrap(last, rt, extrap_cap(ring) + maxi(lead_ms, 0), "extrap")
	var i := 0
	while i < ring.size() - 1 and int(ring[i + 1].t) <= rt:
		i += 1
	var a: Dictionary = ring[i]
	var b: Dictionary = ring[i + 1]
	var span := int(b.t) - int(a.t)
	if int(b.flags) & Codec.RF_SNAP:
		# a teleport: keep moving with the old state, never streak across the jump
		var sw := _extrap(a, rt, extrap_cap(ring.slice(0, i + 1)) + maxi(lead_ms, 0), "snap_wait")
		sw["mode"] = "snap_wait"
		return sw
	var span_s := float(maxi(span, 1)) / 1000.0
	var u := clampf(float(rt - int(a.t)) / float(maxi(span, 1)), 0.0, 1.0)
	var p: Vector3
	var v: Vector3
	if (int(a.flags) & Codec.RF_LIN) and (int(b.flags) & Codec.RF_LIN) and span <= HERMITE_MAX_SPAN_MS:
		p = hermite(a.p, a.l, b.p, b.l, span_s, u)
		v = hermite_vel(a.p, a.l, b.p, b.l, span_s, u)
	else:
		p = (a.p as Vector3).lerp(b.p, u)
		v = ((b.p as Vector3) - (a.p as Vector3)) / span_s
	var qa: Quaternion = a.q
	var qb: Quaternion = b.q
	if qa.dot(qb) < 0.0:
		qb = -qb
	return {"p": p, "q": qa.slerp(qb, u).normalized(), "v": v, "w": rotvec(qb * qa.inverse()) / span_s, "mode": "interp"}


## Past state `s` by (rt - s.t), at most cap_ms: then the pose holds (v = 0).
static func _extrap(s: Dictionary, rt: int, cap_ms: int, mode: String) -> Dictionary:
	var past := rt - int(s.t)
	var e := mini(past, cap_ms)
	var flags := int(s.flags)
	var lin := (flags & Codec.RF_LIN) != 0
	var ang := (flags & Codec.RF_ANG) != 0 and (s.a as Vector3).length() > ANG_EPS
	var p: Vector3 = s.p
	var q: Quaternion = s.q
	if lin:
		p = p + (s.l as Vector3) * (float(e) / 1000.0)
	if ang:
		q = rotate(q, s.a, e)
	var moving := (lin or ang) and past <= cap_ms
	return {"p": p, "q": q, "v": (s.l as Vector3) if lin and moving else Vector3.ZERO,
		"w": (s.a as Vector3) if ang and moving else Vector3.ZERO,
		"mode": mode if moving else "hold"}


## A rotation as axis * angle (radians, world frame, the shortest way).
static func rotvec(q: Quaternion) -> Vector3:
	var n := q.normalized()
	if n.w < 0.0:
		n = -n
	var s := Vector3(n.x, n.y, n.z)
	var sl := s.length()
	if sl < 0.000001:
		return Vector3.ZERO
	return s / sl * (2.0 * atan2(sl, n.w))


static func from_rotvec(r: Vector3) -> Quaternion:
	var ang := r.length()
	if ang < 0.000001:
		return Quaternion.IDENTITY
	return Quaternion(r / ang, ang)


## Smallest angle between two rotations, degrees (tests).
static func angle_deg(a: Quaternion, b: Quaternion) -> float:
	var d := absf(a.normalized().dot(b.normalized()))
	return rad_to_deg(2.0 * acos(clampf(d, -1.0, 1.0)))
