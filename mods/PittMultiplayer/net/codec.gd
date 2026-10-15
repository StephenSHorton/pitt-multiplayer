extends RefCounted
## Frame codec (MP-DESIGN 2.3). Byte 0 is the frame kind:
##   0 JSON              [0][utf8 json]
##   1 zstd(JSON)        [1][u32 raw size][zstd bytes]          (used above 1 KB)
##   2 avatar (44 bytes) [2][u8 slot][u16 flags][u32 t_ms][f32 x y z yaw pitch vx vy vz][u32 seq]
##   3 snapshot chunk    [3][u32 xfer][u32 index][payload]
##   4 body state H->C   MP2-DESIGN 2.3 (encode_bodies / decode_bodies)
##   5 held body C->H    MP2-DESIGN 2.3 (encode_held / decode_held)
## All integers little endian.

const Proto = preload("proto.gd")

const AVATAR_SIZE := 44
const CHUNK_HEADER := 9

# MP2 frames (2.3)
const MAX_PACKET := 1200          # decoders accept up to this
const PACK_TARGET := 1100          # senders fill packets up to this (below Steam's ~1200 B fragmentation point, S-M11)
const BODIES_HEADER := 10
const BODY_BASE := 19
const HELD_HEADER := 8
const HELD_RECORD := 31
const HELD_MAX := 2
const POS_SCALE := 1024.0          # i24 at 1/1024 m
const POS_LIMIT := 8000.0          # decoders reject |p| beyond this
const VEL_SCALE := 100.0           # i16 at 1/100 m/s (rad/s)
const VEL_LIMIT := 327.0
const ROT_BITS := 10
const ROT_MAX := 1022            # 1023 levels: zero is exact
const ROT_MASK := 1023
const ROT_RANGE := 0.70710678118   # 1/sqrt(2)
# record flags (kind 4)
const RF_LIN := 1
const RF_ANG := 2
const RF_SLEEP := 4
const RF_SNAP := 8
const RF_HELD := 16
const RF_HIDDEN := 32
const RF_NOCOLLIDE := 64

# avatar flags
const F_CROUCH := 1
const F_SPRINT := 2
const F_AIRBORNE := 4
const F_MENU_OPEN := 8
const F_TORCH := 16
const F_TELEPORTED := 32


static func encode_json(msg: Dictionary) -> PackedByteArray:
	return encode_raw_json(JSON.stringify(msg).to_utf8_buffer())


## A frame from already-stringified JSON (utf8).
static func encode_raw_json(raw: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	if raw.size() > Proto.ZSTD_THRESHOLD:
		var z := raw.compress(FileAccess.COMPRESSION_ZSTD)
		out.resize(5)
		out[0] = Proto.FRAME_ZJSON
		out.encode_u32(1, raw.size())
		out.append_array(z)
		return out
	out.append(Proto.FRAME_JSON)
	out.append_array(raw)
	return out


## -> {"kind": int, "msg"|"frame"|"chunk": ..., "error": String}
## max_json caps the (decompressed) JSON size.
static func decode(bytes: PackedByteArray, max_json: int) -> Dictionary:
	if bytes.is_empty():
		return {"kind": -1, "error": "empty"}
	var kind := int(bytes[0])
	match kind:
		Proto.FRAME_JSON:
			if bytes.size() - 1 > max_json:
				return {"kind": kind, "error": "too_large"}
			return _parse_json(bytes.slice(1), kind)
		Proto.FRAME_ZJSON:
			if bytes.size() < 5:
				return {"kind": kind, "error": "short"}
			var raw_size := int(bytes.decode_u32(1))
			if raw_size <= 0 or raw_size > max_json:
				return {"kind": kind, "error": "too_large"}
			var raw := bytes.slice(5).decompress(raw_size, FileAccess.COMPRESSION_ZSTD)
			if raw.size() != raw_size:
				return {"kind": kind, "error": "bad_zstd"}
			return _parse_json(raw, kind)
		Proto.FRAME_AVATAR:
			var f := decode_avatar(bytes)
			if f.is_empty():
				return {"kind": kind, "error": "bad_avatar"}
			return {"kind": kind, "frame": f, "error": ""}
		Proto.FRAME_CHUNK:
			if bytes.size() < CHUNK_HEADER or bytes.size() - CHUNK_HEADER > Proto.CHUNK_SIZE:
				return {"kind": kind, "error": "bad_chunk"}
			return {"kind": kind, "chunk": {"xfer": int(bytes.decode_u32(1)), "index": int(bytes.decode_u32(5)),
				"data": bytes.slice(CHUNK_HEADER)}, "error": ""}
		Proto.FRAME_BODIES, Proto.FRAME_HELD:
			# MP2 frames go to their module undecoded (decode_bodies / decode_held)
			if bytes.size() > MAX_PACKET:
				return {"kind": kind, "error": "too_large"}
			return {"kind": kind, "raw": true, "error": ""}
	return {"kind": kind, "error": "unknown_kind"}


static func _parse_json(raw: PackedByteArray, kind: int) -> Dictionary:
	var json := JSON.new()
	if json.parse(raw.get_string_from_utf8()) != OK or typeof(json.data) != TYPE_DICTIONARY:
		return {"kind": kind, "error": "bad_json"}
	return {"kind": kind, "msg": normalize_numbers(json.data), "error": ""}


## JSON numbers come back as floats; integral values (|v| < 2^53) become ints so
## ids, seqs and levels compare as ints.
static func normalize_numbers(v: Variant) -> Variant:
	match typeof(v):
		TYPE_FLOAT:
			if v == floor(v) and absf(v) < 9.0e15:
				return int(v)
			return v
		TYPE_ARRAY:
			var a: Array = []
			for x in v:
				a.append(normalize_numbers(x))
			return a
		TYPE_DICTIONARY:
			var d := {}
			for k in v:
				d[k] = normalize_numbers(v[k])
			return d
	return v


## A parsed world snapshot: the entity rows ("ents", "fbodies") are parsed with
## int() / float() casts (world_snapshot.gd), so only each row's trailing meta
## dictionary is normalized (in place); everything else as normalize_numbers.
## At 3000 rows this skips about 80 % of the copy.
static func normalize_wsnap(data: Dictionary) -> Dictionary:
	var out := {}
	for k in data:
		var v = data[k]
		if (k == "ents" or k == "fbodies") and typeof(v) == TYPE_ARRAY:
			for row in v:
				if typeof(row) == TYPE_ARRAY and not row.is_empty() and typeof(row[row.size() - 1]) == TYPE_DICTIONARY:
					row[row.size() - 1] = normalize_numbers(row[row.size() - 1])
			out[k] = v
		else:
			out[k] = normalize_numbers(v)
	return out


# ------------------------------------------------------------------ avatar

## f: {slot, flags, t_ms, pos: Vector3, yaw, pitch, vel: Vector3, seq}
static func encode_avatar(f: Dictionary) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(AVATAR_SIZE)
	b[0] = Proto.FRAME_AVATAR
	b[1] = clampi(int(f.get("slot", 0)), 0, 255)
	b.encode_u16(2, int(f.get("flags", 0)) & 0xFFFF)
	b.encode_u32(4, int(f.get("t_ms", 0)) & 0xFFFFFFFF)
	var p: Vector3 = f.get("pos", Vector3.ZERO)
	var v: Vector3 = f.get("vel", Vector3.ZERO)
	b.encode_float(8, p.x)
	b.encode_float(12, p.y)
	b.encode_float(16, p.z)
	b.encode_float(20, float(f.get("yaw", 0.0)))
	b.encode_float(24, float(f.get("pitch", 0.0)))
	b.encode_float(28, v.x)
	b.encode_float(32, v.y)
	b.encode_float(36, v.z)
	b.encode_u32(40, int(f.get("seq", 0)) & 0xFFFFFFFF)
	return b


static func decode_avatar(b: PackedByteArray) -> Dictionary:
	if b.size() != AVATAR_SIZE or int(b[0]) != Proto.FRAME_AVATAR:
		return {}
	var vals: Array = []
	for off in [8, 12, 16, 20, 24, 28, 32, 36]:
		var x := b.decode_float(off)
		if is_nan(x) or is_inf(x) or absf(x) > 1.0e6:
			return {}
		vals.append(x)
	return {"slot": int(b[1]), "flags": int(b.decode_u16(2)), "t_ms": int(b.decode_u32(4)),
		"pos": Vector3(vals[0], vals[1], vals[2]), "yaw": vals[3], "pitch": vals[4],
		"vel": Vector3(vals[5], vals[6], vals[7]), "seq": int(b.decode_u32(40))}


## Rewrites the slot byte (the host relays frames with the sender's real slot).
static func set_avatar_slot(b: PackedByteArray, slot: int) -> PackedByteArray:
	var out := b.duplicate()
	if out.size() == AVATAR_SIZE:
		out[1] = clampi(slot, 0, 255)
	return out


# ------------------------------------------------------------------ snapshot chunks

static func encode_chunk(xfer: int, index: int, payload: PackedByteArray) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(CHUNK_HEADER)
	b[0] = Proto.FRAME_CHUNK
	b.encode_u32(1, xfer & 0xFFFFFFFF)
	b.encode_u32(5, index & 0xFFFFFFFF)
	b.append_array(payload)
	return b


static func split(data: PackedByteArray, size: int = Proto.CHUNK_SIZE) -> Array:
	var out: Array = []
	var i := 0
	while i < data.size():
		out.append(data.slice(i, mini(i + size, data.size())))
		i += size
	if out.is_empty():
		out.append(PackedByteArray())
	return out


static func sha256_hex(data: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return ctx.finish().hex_encode()


static func sha256_text(text: String) -> String:
	return sha256_hex(text.to_utf8_buffer())


static func zstd(data: PackedByteArray) -> PackedByteArray:
	return data.compress(FileAccess.COMPRESSION_ZSTD)


static func unzstd(data: PackedByteArray, raw_size: int) -> PackedByteArray:
	if raw_size <= 0 or raw_size > Proto.MAX_SNAPSHOT_RAW:
		return PackedByteArray()
	return data.decompress(raw_size, FileAccess.COMPRESSION_ZSTD)


# ------------------------------------------------------------------ MP2 quantisation (2.3)

## i24 at 1/1024 m, clamped to the i24 range.
static func q_pos(v: float) -> int:
	return clampi(roundi(v * POS_SCALE), -8388608, 8388607)


static func dq_pos(i: int) -> float:
	return float(i) / POS_SCALE


static func q_vel(v: float) -> int:
	return clampi(roundi(clampf(v, -VEL_LIMIT, VEL_LIMIT) * VEL_SCALE), -32768, 32767)


static func dq_vel(i: int) -> float:
	return float(i) / VEL_SCALE


## Smallest-three: 2 bits index of the dropped (largest) component, 3 x 10 bits.
static func q_rot(q: Quaternion) -> int:
	var n := q.normalized() if q.length_squared() > 1.0e-12 else Quaternion.IDENTITY
	var c := [n.x, n.y, n.z, n.w]
	var big := 0
	for i in range(1, 4):
		if absf(c[i]) > absf(c[big]):
			big = i
	var sgn := -1.0 if c[big] < 0.0 else 1.0
	var out := big << 30
	var shift := 20
	for i in 4:
		if i == big:
			continue
		var v := clampf(c[i] * sgn, -ROT_RANGE, ROT_RANGE)
		var u := clampi(roundi((v + ROT_RANGE) / (2.0 * ROT_RANGE) * ROT_MAX), 0, ROT_MAX)
		out |= u << shift
		shift -= 10
	return out


static func dq_rot(bits: int) -> Quaternion:
	var big := (bits >> 30) & 3
	var c := [0.0, 0.0, 0.0, 0.0]
	var shift := 20
	var sum := 0.0
	for i in 4:
		if i == big:
			continue
		var u := mini((bits >> shift) & ROT_MASK, ROT_MAX)
		var v := float(u) / ROT_MAX * 2.0 * ROT_RANGE - ROT_RANGE
		c[i] = v
		sum += v * v
		shift -= 10
	c[big] = sqrt(maxf(0.0, 1.0 - sum))
	return Quaternion(c[0], c[1], c[2], c[3]).normalized()


static func _put_i24(b: PackedByteArray, off: int, v: int) -> void:
	var u := v & 0xFFFFFF
	b[off] = u & 0xFF
	b[off + 1] = (u >> 8) & 0xFF
	b[off + 2] = (u >> 16) & 0xFF


static func _get_i24(b: PackedByteArray, off: int) -> int:
	var u := int(b[off]) | (int(b[off + 1]) << 8) | (int(b[off + 2]) << 16)
	if u & 0x800000:
		u -= 0x1000000
	return u


static func body_record_size(flags: int) -> int:
	return BODY_BASE + (6 if flags & RF_LIN else 0) + (6 if flags & RF_ANG else 0)


# ------------------------------------------------------------------ frame kind 4: body state (H->C)

## records: [{eid, flags, epoch, p: Vector3, q: Quaternion, l: Vector3, a: Vector3}]; velocities are
## written only when flags carry RF_LIN / RF_ANG. One packet; callers keep it <= MAX_PACKET (pack_bodies).
static func encode_bodies(host_ms: int, seq: int, records: Array) -> PackedByteArray:
	var size := BODIES_HEADER
	for r in records:
		size += body_record_size(int(r.get("flags", 0)))
	var b := PackedByteArray()
	b.resize(size)
	b[0] = Proto.FRAME_BODIES
	b[1] = 0
	b.encode_u16(2, records.size() & 0xFFFF)
	b.encode_u32(4, host_ms & 0xFFFFFFFF)
	b.encode_u16(8, seq & 0xFFFF)
	var o := BODIES_HEADER
	for r in records:
		var flags := int(r.get("flags", 0)) & 0xFF
		b.encode_u32(o, int(r.get("eid", 0)) & 0xFFFFFFFF)
		b[o + 4] = flags
		b[o + 5] = int(r.get("epoch", 0)) & 0xFF
		var p: Vector3 = r.get("p", Vector3.ZERO)
		_put_i24(b, o + 6, q_pos(p.x))
		_put_i24(b, o + 9, q_pos(p.y))
		_put_i24(b, o + 12, q_pos(p.z))
		b.encode_u32(o + 15, q_rot(r.get("q", Quaternion.IDENTITY)))
		o += BODY_BASE
		if flags & RF_LIN:
			var l: Vector3 = r.get("l", Vector3.ZERO)
			b.encode_s16(o, q_vel(l.x))
			b.encode_s16(o + 2, q_vel(l.y))
			b.encode_s16(o + 4, q_vel(l.z))
			o += 6
		if flags & RF_ANG:
			var a: Vector3 = r.get("a", Vector3.ZERO)
			b.encode_s16(o, q_vel(a.x))
			b.encode_s16(o + 2, q_vel(a.y))
			b.encode_s16(o + 4, q_vel(a.z))
			o += 6
	return b


## One record of frame kind 4 (19 / 25 / 31 bytes), as encode_bodies writes it.
## Byte 4 is the flags byte (senders patch RF_SNAP per peer).
static func encode_body_record(r: Dictionary) -> PackedByteArray:
	var flags := int(r.get("flags", 0)) & 0xFF
	var b := PackedByteArray()
	b.resize(body_record_size(flags))
	b.encode_u32(0, int(r.get("eid", 0)) & 0xFFFFFFFF)
	b[4] = flags
	b[5] = int(r.get("epoch", 0)) & 0xFF
	var p: Vector3 = r.get("p", Vector3.ZERO)
	_put_i24(b, 6, q_pos(p.x))
	_put_i24(b, 9, q_pos(p.y))
	_put_i24(b, 12, q_pos(p.z))
	b.encode_u32(15, q_rot(r.get("q", Quaternion.IDENTITY)))
	var o := BODY_BASE
	if flags & RF_LIN:
		var l: Vector3 = r.get("l", Vector3.ZERO)
		b.encode_s16(o, q_vel(l.x))
		b.encode_s16(o + 2, q_vel(l.y))
		b.encode_s16(o + 4, q_vel(l.z))
		o += 6
	if flags & RF_ANG:
		var a: Vector3 = r.get("a", Vector3.ZERO)
		b.encode_s16(o, q_vel(a.x))
		b.encode_s16(o + 2, q_vel(a.y))
		b.encode_s16(o + 4, q_vel(a.z))
	return b


static func _bodies_header(host_ms: int, seq: int, count: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(BODIES_HEADER)
	b[0] = Proto.FRAME_BODIES
	b[1] = 0
	b.encode_u16(2, count & 0xFFFF)
	b.encode_u32(4, host_ms & 0xFFFFFFFF)
	b.encode_u16(8, seq & 0xFFFF)
	return b


## Pre-encoded records (encode_body_record) into packets of at most `target`
## bytes (consecutive seqs from seq).
static func pack_records(host_ms: int, seq: int, recs: Array, target: int = PACK_TARGET) -> Array:
	var out: Array = []
	var body := PackedByteArray()
	var count := 0
	for rb in recs:
		if count > 0 and BODIES_HEADER + body.size() + (rb as PackedByteArray).size() > target:
			var h := _bodies_header(host_ms, seq + out.size(), count)
			h.append_array(body)
			out.append(h)
			body = PackedByteArray()
			count = 0
		body.append_array(rb)
		count += 1
	if count > 0:
		var h2 := _bodies_header(host_ms, seq + out.size(), count)
		h2.append_array(body)
		out.append(h2)
	return out


## Splits records into packets of at most `target` bytes (consecutive seqs from seq).
static func pack_bodies(host_ms: int, seq: int, records: Array, target: int = PACK_TARGET) -> Array:
	var out: Array = []
	var cur: Array = []
	var size := BODIES_HEADER
	for r in records:
		var rs := body_record_size(int(r.get("flags", 0)))
		if not cur.is_empty() and size + rs > target:
			out.append(encode_bodies(host_ms, seq + out.size(), cur))
			cur = []
			size = BODIES_HEADER
		cur.append(r)
		size += rs
	if not cur.is_empty():
		out.append(encode_bodies(host_ms, seq + out.size(), cur))
	return out


## -> {host_ms, seq, records: [{eid, flags, epoch, p, q, l, a}]}; {} on any error.
static func decode_bodies(b: PackedByteArray) -> Dictionary:
	if b.size() < BODIES_HEADER or b.size() > MAX_PACKET or int(b[0]) != Proto.FRAME_BODIES:
		return {}
	var count := int(b.decode_u16(2))
	var o := BODIES_HEADER
	var recs: Array = []
	for i in count:
		if o + BODY_BASE > b.size():
			return {}
		var flags := int(b[o + 4])
		if o + body_record_size(flags) > b.size():
			return {}
		var p := Vector3(dq_pos(_get_i24(b, o + 6)), dq_pos(_get_i24(b, o + 9)), dq_pos(_get_i24(b, o + 12)))
		if absf(p.x) > POS_LIMIT or absf(p.y) > POS_LIMIT or absf(p.z) > POS_LIMIT:
			return {}
		var r := {"eid": int(b.decode_u32(o)), "flags": flags, "epoch": int(b[o + 5]), "p": p,
			"q": dq_rot(int(b.decode_u32(o + 15))), "l": Vector3.ZERO, "a": Vector3.ZERO}
		o += BODY_BASE
		if flags & RF_LIN:
			r.l = Vector3(dq_vel(b.decode_s16(o)), dq_vel(b.decode_s16(o + 2)), dq_vel(b.decode_s16(o + 4)))
			o += 6
		if flags & RF_ANG:
			r.a = Vector3(dq_vel(b.decode_s16(o)), dq_vel(b.decode_s16(o + 2)), dq_vel(b.decode_s16(o + 4)))
			o += 6
		recs.append(r)
	if o != b.size():
		return {}
	return {"host_ms": int(b.decode_u32(4)), "seq": int(b.decode_u16(8)), "records": recs}


# ------------------------------------------------------------------ frame kind 5: held body (C->H)

## records (<= 2): [{eid, epoch (u16), p, q, l, a}]
static func encode_held(client_ms: int, records: Array) -> PackedByteArray:
	var n := mini(records.size(), HELD_MAX)
	var b := PackedByteArray()
	b.resize(HELD_HEADER + n * HELD_RECORD)
	b[0] = Proto.FRAME_HELD
	b[1] = 0
	b.encode_u16(2, n)
	b.encode_u32(4, client_ms & 0xFFFFFFFF)
	var o := HELD_HEADER
	for i in n:
		var r: Dictionary = records[i]
		b.encode_u32(o, int(r.get("eid", 0)) & 0xFFFFFFFF)
		b.encode_u16(o + 4, int(r.get("epoch", 0)) & 0xFFFF)
		var p: Vector3 = r.get("p", Vector3.ZERO)
		_put_i24(b, o + 6, q_pos(p.x))
		_put_i24(b, o + 9, q_pos(p.y))
		_put_i24(b, o + 12, q_pos(p.z))
		b.encode_u32(o + 15, q_rot(r.get("q", Quaternion.IDENTITY)))
		var l: Vector3 = r.get("l", Vector3.ZERO)
		var a: Vector3 = r.get("a", Vector3.ZERO)
		b.encode_s16(o + 19, q_vel(l.x))
		b.encode_s16(o + 21, q_vel(l.y))
		b.encode_s16(o + 23, q_vel(l.z))
		b.encode_s16(o + 25, q_vel(a.x))
		b.encode_s16(o + 27, q_vel(a.y))
		b.encode_s16(o + 29, q_vel(a.z))
		o += HELD_RECORD
	return b


## -> {client_ms, records: [{eid, epoch, p, q, l, a}]}; {} on any error.
static func decode_held(b: PackedByteArray) -> Dictionary:
	if b.size() < HELD_HEADER or int(b[0]) != Proto.FRAME_HELD:
		return {}
	var count := int(b.decode_u16(2))
	if count > HELD_MAX or b.size() != HELD_HEADER + count * HELD_RECORD:
		return {}
	var recs: Array = []
	var o := HELD_HEADER
	for i in count:
		var p := Vector3(dq_pos(_get_i24(b, o + 6)), dq_pos(_get_i24(b, o + 9)), dq_pos(_get_i24(b, o + 12)))
		if absf(p.x) > POS_LIMIT or absf(p.y) > POS_LIMIT or absf(p.z) > POS_LIMIT:
			return {}
		recs.append({"eid": int(b.decode_u32(o)), "epoch": int(b.decode_u16(o + 4)), "p": p,
			"q": dq_rot(int(b.decode_u32(o + 15))),
			"l": Vector3(dq_vel(b.decode_s16(o + 19)), dq_vel(b.decode_s16(o + 21)), dq_vel(b.decode_s16(o + 23))),
			"a": Vector3(dq_vel(b.decode_s16(o + 25)), dq_vel(b.decode_s16(o + 27)), dq_vel(b.decode_s16(o + 29)))})
		o += HELD_RECORD
	return {"client_ms": int(b.decode_u32(4)), "records": recs}
