extends RefCounted
## World snapshot rows (MP2-DESIGN 3.7) and the ents/sp row codec (2.4).
##   wsnap ents:    [eid, pool_idx, x,y,z, qx,qy,qz,qw, lx,ly,lz, ax,ay,az, flags, owner, epoch, meta]
##   wsnap fbodies: [eid, key, x,y,z, qx,qy,qz,qw, flags, owner, epoch, meta]
##   ents.sp:       [eid, pool_idx, x,y,z, qx,qy,qz,qw, lx,ly,lz, flags, meta|null]
##   ents.fb:       [eid, key, x,y,z, qx,qy,qz,qw, lx,ly,lz, flags, meta|null]
## The client applies BATCH entities per physics frame behind the loading
## screen (SaveManager.is_loading held, as the game's own pool load does).

const BATCH := 150
## rows carry positions inside the frame codec range (net/codec.gd POS_LIMIT)
const RANGE := 7990.0


static func _r(v: float, step: float = 0.0001) -> float:
	return snappedf(v, step)


## A body far out of the world still gets a row (so its entity exists), clamped into range.
static func safe(p: Vector3) -> Vector3:
	if not p.is_finite():
		return Vector3.ZERO
	return p.clamp(Vector3(-RANGE, -RANGE, -RANGE), Vector3(RANGE, RANGE, RANGE))


static func wsnap_ent_row(eid: int, pool_idx: int, p: Vector3, q: Quaternion, l: Vector3, a: Vector3, flags: int,
		owner: int, epoch: int, meta: Dictionary) -> Array:
	p = safe(p)
	return [eid, pool_idx, _r(p.x), _r(p.y), _r(p.z), _r(q.x, 0.00001), _r(q.y, 0.00001), _r(q.z, 0.00001),
		_r(q.w, 0.00001), _r(l.x, 0.001), _r(l.y, 0.001), _r(l.z, 0.001), _r(a.x, 0.001), _r(a.y, 0.001),
		_r(a.z, 0.001), flags, owner, epoch, meta]


static func wsnap_fb_row(eid: int, key: String, p: Vector3, q: Quaternion, flags: int, owner: int, epoch: int,
		meta: Dictionary) -> Array:
	p = safe(p)
	return [eid, key, _r(p.x), _r(p.y), _r(p.z), _r(q.x, 0.00001), _r(q.y, 0.00001), _r(q.z, 0.00001),
		_r(q.w, 0.00001), flags, owner, epoch, meta]


## ents.sp (pool_or_key: int pool index) / ents.fb (pool_or_key: String key)
static func sp_row(eid: int, pool_or_key: Variant, p: Vector3, q: Quaternion, l: Vector3, flags: int, meta) -> Array:
	p = safe(p)
	return [eid, pool_or_key, _r(p.x), _r(p.y), _r(p.z), _r(q.x, 0.00001), _r(q.y, 0.00001), _r(q.z, 0.00001),
		_r(q.w, 0.00001), _r(l.x, 0.001), _r(l.y, 0.001), _r(l.z, 0.001), flags, meta]


static func _num(v) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


static func _vec(row: Array, i: int) -> Vector3:
	return Vector3(float(row[i]), float(row[i + 1]), float(row[i + 2]))


static func _quat(row: Array, i: int) -> Quaternion:
	var q := Quaternion(float(row[i]), float(row[i + 1]), float(row[i + 2]), float(row[i + 3]))
	return q.normalized() if q.length_squared() > 1.0e-8 else Quaternion.IDENTITY


static func _finite(v: Vector3) -> bool:
	return v.is_finite() and absf(v.x) < 8000.0 and absf(v.y) < 8000.0 and absf(v.z) < 8000.0


static func _meta(v) -> Dictionary:
	return v if typeof(v) == TYPE_DICTIONARY else {}


## -> {eid, pool_idx, p, q, l, a, flags, owner, epoch, meta} or {} when malformed
static func parse_wsnap_ent(row) -> Dictionary:
	if typeof(row) != TYPE_ARRAY or row.size() < 19:
		return {}
	for i in range(0, 18):
		if not _num(row[i]):
			return {}
	var p := _vec(row, 2)
	if not _finite(p):
		return {}
	return {"eid": int(row[0]), "pool_idx": int(row[1]), "p": p, "q": _quat(row, 5), "l": _vec(row, 9),
		"a": _vec(row, 12), "flags": int(row[15]), "owner": int(row[16]), "epoch": int(row[17]), "meta": _meta(row[18])}


static func parse_wsnap_fb(row) -> Dictionary:
	if typeof(row) != TYPE_ARRAY or row.size() < 13 or typeof(row[1]) != TYPE_STRING:
		return {}
	for i in [0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]:
		if not _num(row[i]):
			return {}
	var p := _vec(row, 2)
	if not _finite(p):
		return {}
	return {"eid": int(row[0]), "key": String(row[1]), "p": p, "q": _quat(row, 5), "l": Vector3.ZERO,
		"a": Vector3.ZERO, "flags": int(row[9]), "owner": int(row[10]), "epoch": int(row[11]), "meta": _meta(row[12])}


## ents.sp / ents.fb -> {eid, pool_idx | key, p, q, l, a, flags, meta}
static func parse_sp(row, is_fb: bool) -> Dictionary:
	if typeof(row) != TYPE_ARRAY or row.size() < 14:
		return {}
	if is_fb and typeof(row[1]) != TYPE_STRING:
		return {}
	if not is_fb and not _num(row[1]):
		return {}
	for i in [0, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]:
		if not _num(row[i]):
			return {}
	var p := _vec(row, 2)
	if not _finite(p):
		return {}
	var d := {"eid": int(row[0]), "p": p, "q": _quat(row, 5), "l": _vec(row, 9), "a": Vector3.ZERO,
		"flags": int(row[12]), "meta": _meta(row[13]), "owner": 1, "epoch": 0}
	if is_fb:
		d["key"] = String(row[1])
	else:
		d["pool_idx"] = int(row[1])
	return d


## sha256(sorted pool ids joined by "\n").substr(0, 16)
static func pools_hash(pool_ids: Array) -> String:
	var ids: Array = []
	for p in pool_ids:
		ids.append(String(p))
	ids.sort()
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update("\n".join(ids).to_utf8_buffer())
	return ctx.finish().hex_encode().substr(0, 16)
