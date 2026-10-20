extends RefCounted
## Held-body stream, frame kind 5 (client -> host, ch2 unreliable;
## MP2-DESIGN 2.3, 5.2 step 4). The owner sends the exact local state of the
## body it carries at 30 Hz; the host validates each record (sender = owner,
## kind held, epoch = current or 0 before the grant was seen, within the held
## reach of the sender's avatar) in ownership_host.gd.
##
## Wire layout (little endian):
##   header 8 B : u8 kind=5 | u8 seq | u16 count | u32 t_ms
##                (seq: the sender's frame counter mod 256, one per frame sent)
##   record 31 B: u32 eid | u16 epoch | i24 x,y,z (1/1024 m) | u32 rot (smallest three)
##                | i16 vx,vy,vz (1/100 m/s) | i16 wx,wy,wz (1/100 rad/s)
## t_ms is the sender's Session.host_now() (the MP1 clock estimate of the host
## wall clock), so the host feeds it to bodies.host_follow_push unchanged.
##
## BODIES owns the codec (net/codec.gd encode_held/decode_held). This file uses
## it when present and keeps an identical-layout fallback so GRAB builds and
## tests on its own; both peers of a session run the same build, so they always
## agree on the encoder.

const KIND := 5
const HEADER := 8
const RECORD := 31
const MAX_RECORDS := 2
const POS_SCALE := 1024.0
const POS_LIMIT := 8000.0
const VEL_SCALE := 100.0
const VEL_CLAMP := 327.0
const SEND_INTERVAL_MS := 30     # every 2nd physics tick at 60 Hz (30 Hz), under the 40/s class limit
const CodecScript = preload("../net/codec.gd")

static var _codec: Variant = null      # false = checked, absent


## BODIES' codec script when it has encode_held/decode_held, else null.
static func codec() -> Object:
	if _codec == null:
		_codec = false
		var names := {}
		for m in (CodecScript as Script).get_script_method_list():
			names[String(m.name)] = true
		if names.has("encode_held") and names.has("decode_held"):
			_codec = CodecScript
	return _codec if _codec is Object else null


## Tests: force the built-in encoder (true) or re-detect (false).
static func use_fallback(on: bool) -> void:
	_codec = false if on else null


## records: [{eid, epoch, p: Vector3, q: Quaternion, l: Vector3, a: Vector3}]
static func encode(t_ms: int, records: Array, seq: int = 0) -> PackedByteArray:
	var c := codec()
	if c != null:
		return c.call("encode_held", t_ms, records, seq)
	return encode_fallback(t_ms, records, seq)


## -> {t_ms, seq, records:[{eid, epoch, p, q, l, a}]}, {} on any error
static func decode(bytes: PackedByteArray) -> Dictionary:
	var c := codec()
	if c != null:
		var d: Dictionary = c.call("decode_held", bytes)
		if d.is_empty():
			return {}
		if not d.has("t_ms"):
			d["t_ms"] = int(d.get("client_ms", d.get("host_ms", 0)))
		if not d.has("seq"):
			d["seq"] = int(bytes[1])
		return d
	return decode_fallback(bytes)


static func encode_fallback(t_ms: int, records: Array, seq: int = 0) -> PackedByteArray:
	var n := mini(records.size(), MAX_RECORDS)
	var out := PackedByteArray()
	out.resize(HEADER + RECORD * n)
	out[0] = KIND
	out[1] = seq & 0xFF
	out.encode_u16(2, n)
	out.encode_u32(4, t_ms & 0xFFFFFFFF)
	var o := HEADER
	for i in n:
		var r: Dictionary = records[i]
		out.encode_u32(o, int(r.get("eid", 0)) & 0xFFFFFFFF)
		out.encode_u16(o + 4, int(r.get("epoch", 0)) & 0xFFFF)
		var p: Vector3 = r.get("p", Vector3.ZERO)
		_put_i24(out, o + 6, q_pos(p.x))
		_put_i24(out, o + 9, q_pos(p.y))
		_put_i24(out, o + 12, q_pos(p.z))
		out.encode_u32(o + 15, q_rot(r.get("q", Quaternion.IDENTITY)))
		var l: Vector3 = r.get("l", Vector3.ZERO)
		var a: Vector3 = r.get("a", Vector3.ZERO)
		out.encode_s16(o + 19, q_vel(l.x))
		out.encode_s16(o + 21, q_vel(l.y))
		out.encode_s16(o + 23, q_vel(l.z))
		out.encode_s16(o + 25, q_vel(a.x))
		out.encode_s16(o + 27, q_vel(a.y))
		out.encode_s16(o + 29, q_vel(a.z))
		o += RECORD
	return out


static func decode_fallback(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < HEADER or int(bytes[0]) != KIND:
		return {}
	var n := int(bytes.decode_u16(2))
	if n < 1 or n > MAX_RECORDS or bytes.size() != HEADER + RECORD * n:
		return {}
	var recs: Array = []
	var o := HEADER
	for i in n:
		var p := Vector3(_get_i24(bytes, o + 6), _get_i24(bytes, o + 9), _get_i24(bytes, o + 12)) / POS_SCALE
		if absf(p.x) > POS_LIMIT or absf(p.y) > POS_LIMIT or absf(p.z) > POS_LIMIT:
			return {}
		var q := dq_rot(int(bytes.decode_u32(o + 15)))
		if not q.is_finite():
			return {}
		recs.append({"eid": int(bytes.decode_u32(o)), "epoch": int(bytes.decode_u16(o + 4)), "p": p, "q": q,
			"l": Vector3(bytes.decode_s16(o + 19), bytes.decode_s16(o + 21), bytes.decode_s16(o + 23)) / VEL_SCALE,
			"a": Vector3(bytes.decode_s16(o + 25), bytes.decode_s16(o + 27), bytes.decode_s16(o + 29)) / VEL_SCALE})
		o += RECORD
	return {"t_ms": int(bytes.decode_u32(4)), "seq": int(bytes[1]), "records": recs}


static func q_pos(v: float) -> int:
	if not is_finite(v):
		return 0
	return clampi(int(roundf(v * POS_SCALE)), -8388608, 8388607)


static func q_vel(v: float) -> int:
	if not is_finite(v):
		return 0
	return clampi(int(roundf(clampf(v, -VEL_CLAMP, VEL_CLAMP) * VEL_SCALE)), -32768, 32767)


## smallest three: bits 30-31 index of the dropped (largest) component, then
## three 10-bit fields (bits 20-29, 10-19, 0-9) in [-1/sqrt2, 1/sqrt2].
static func q_rot(q: Quaternion) -> int:
	if not q.is_finite() or q.length_squared() < 0.000001:
		q = Quaternion.IDENTITY
	q = q.normalized()
	var c := [q.x, q.y, q.z, q.w]
	var big := 0
	for i in range(1, 4):
		if absf(c[i]) > absf(c[big]):
			big = i
	var sgn := -1.0 if c[big] < 0.0 else 1.0
	var out := big << 30
	var shift := 20
	var lim := 1.0 / sqrt(2.0)
	for i in 4:
		if i == big:
			continue
		var v: float = clampf(c[i] * sgn, -lim, lim)
		var u := clampi(int(roundf((v + lim) / (2.0 * lim) * 1023.0)), 0, 1023)
		out |= u << shift
		shift -= 10
	return out & 0xFFFFFFFF


static func dq_rot(bits: int) -> Quaternion:
	var big := (bits >> 30) & 3
	var lim := 1.0 / sqrt(2.0)
	var c := [0.0, 0.0, 0.0, 0.0]
	var shift := 20
	var sum := 0.0
	for i in 4:
		if i == big:
			continue
		var u := (bits >> shift) & 1023
		var v := float(u) / 1023.0 * 2.0 * lim - lim
		c[i] = v
		sum += v * v
		shift -= 10
	c[big] = sqrt(maxf(1.0 - sum, 0.0))
	return Quaternion(c[0], c[1], c[2], c[3]).normalized()


static func _put_i24(b: PackedByteArray, o: int, v: int) -> void:
	var u := v & 0xFFFFFF
	b[o] = u & 0xFF
	b[o + 1] = (u >> 8) & 0xFF
	b[o + 2] = (u >> 16) & 0xFF


static func _get_i24(b: PackedByteArray, o: int) -> int:
	var u := int(b[o]) | (int(b[o + 1]) << 8) | (int(b[o + 2]) << 16)
	return u - 0x1000000 if u & 0x800000 else u


# ------------------------------------------------------------------ JSON state (own_rel / own_unequip / own)

## {p: Vector3, q: Quaternion, l, a} -> {p:[x,y,z], q:[x,y,z,w], l:[...], a:[...]}
static func state_to_json(s: Dictionary) -> Dictionary:
	if s.is_empty():
		return {}
	var p: Vector3 = s.get("p", Vector3.ZERO)
	var q: Quaternion = s.get("q", Quaternion.IDENTITY)
	var l: Vector3 = s.get("l", Vector3.ZERO)
	var a: Vector3 = s.get("a", Vector3.ZERO)
	return {"p": [p.x, p.y, p.z], "q": [q.x, q.y, q.z, q.w], "l": [l.x, l.y, l.z], "a": [a.x, a.y, a.z]}


## Validating inverse of state_to_json; {} on anything malformed, non-finite or out of range.
static func state_from_json(d: Variant) -> Dictionary:
	if typeof(d) != TYPE_DICTIONARY:
		return {}
	var p := vec3(d.get("p"))
	var l := vec3(d.get("l", [0, 0, 0]))
	var a := vec3(d.get("a", [0, 0, 0]))
	var qa = d.get("q")
	if not p.is_finite() or not l.is_finite() or not a.is_finite():
		return {}
	if absf(p.x) > POS_LIMIT or absf(p.y) > POS_LIMIT or absf(p.z) > POS_LIMIT:
		return {}
	if typeof(qa) != TYPE_ARRAY or qa.size() != 4:
		return {}
	for v in qa:
		if not (typeof(v) in [TYPE_FLOAT, TYPE_INT]) or not is_finite(float(v)):
			return {}
	var q := Quaternion(float(qa[0]), float(qa[1]), float(qa[2]), float(qa[3]))
	if q.length_squared() < 0.000001:
		return {}
	l = l.limit_length(VEL_CLAMP * 1.8)
	a = a.limit_length(VEL_CLAMP * 1.8)
	return {"p": p, "q": q.normalized(), "l": l, "a": a}


## The motion a held body shows between two accepted held states (0.2.3). A held
## frame's l is the owner's carry pull toward its hands (a full crate hanging still
## reads about 4 m/s), so a state the host keeps for a release it decides itself
## (revoke, teardown, a malformed own_rel) carries this instead: the position step
## over the sender's spacing (t, else arrival rx), never faster than the sender's l;
## no previous state (or no usable spacing) holds still. An owner's own release
## state (own_rel / own_unequip) keeps its velocity: that is the real throw.
## prev / cur: {p: Vector3, l: Vector3, t: sender ms, rx: arrival ms}
static func observed_l(prev: Dictionary, cur: Dictionary) -> Vector3:
	if prev.is_empty() or not prev.has("p"):
		return Vector3.ZERO
	var dt_ms := 0
	var ta := int(prev.get("t", 0))
	var tb := int(cur.get("t", 0))
	if ta != 0 and tb != 0:
		dt_ms = posmod(tb - ta + 0x80000000, 0x100000000) - 0x80000000
	if (dt_ms <= 0 or dt_ms >= 500) and prev.has("rx") and cur.has("rx"):
		dt_ms = int(cur.rx) - int(prev.rx)
	if dt_ms <= 0 or dt_ms >= 1000:
		return Vector3.ZERO
	var obs: Vector3 = ((cur.get("p", Vector3.ZERO) as Vector3) - (prev.p as Vector3)) / (float(dt_ms) / 1000.0)
	var cap := (cur.get("l", Vector3.ZERO) as Vector3).length()
	return obs.limit_length(cap)


## [x,y,z] -> Vector3; Vector3(NAN, ...) when malformed.
static func vec3(v: Variant) -> Vector3:
	if typeof(v) != TYPE_ARRAY or v.size() != 3:
		return Vector3(NAN, NAN, NAN)
	for e in v:
		if not (typeof(e) in [TYPE_FLOAT, TYPE_INT]):
			return Vector3(NAN, NAN, NAN)
	return Vector3(float(v[0]), float(v[1]), float(v[2]))


static func vec3_json(v: Vector3) -> Array:
	return [v.x, v.y, v.z]


# ------------------------------------------------------------------ client sender

var paused := false            # test hook (G4): stop sending held frames
var sent := 0
var seq := 0                   # u8 header sequence of the next frame
var _last_send_ms := -100000


## Client, every physics tick while carrying: one record per held body, at most
## every SEND_INTERVAL_MS. Returns the bytes sent (empty when nothing was due).
func maybe_send(session: Object, now_ms: int, records: Array) -> PackedByteArray:
	if paused or records.is_empty() or session == null:
		return PackedByteArray()
	if now_ms - _last_send_ms < SEND_INTERVAL_MS:
		return PackedByteArray()
	_last_send_ms = now_ms
	var t := int(session.host_now()) if session.has_method("host_now") else now_ms
	var bytes := encode(t, records, seq)
	seq = (seq + 1) & 0xFF
	if session.has_method("send_unreliable"):
		session.send_unreliable(1, bytes)
	sent += 1
	return bytes


func reset() -> void:
	_last_send_ms = -100000
