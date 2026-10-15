extends RefCounted
## PittSerial: the single gate for anything that crosses the API boundary.
## Payloads, command args and command results are JSON-safe so they can go over
## the network unchanged later (null, bool, int, float, String, Array, Dictionary).
## Also holds decimal-string arithmetic so money diffs never depend on the
## game's BigInt class layout.


## Converts v into a JSON-safe value. Unsupported values become null.
## entities (optional) is the PittEntities registry used to turn Nodes into ids.
static func to_json_safe(v: Variant, entities: Object = null, depth: int = 0) -> Variant:
	if depth > 32:
		return null
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return v
		TYPE_FLOAT:
			if is_nan(v) or is_inf(v):
				return null
			return v
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return String(v)
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return [v.x, v.y]
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return [v.x, v.y, v.z]
		TYPE_VECTOR4, TYPE_VECTOR4I:
			return [v.x, v.y, v.z, v.w]
		TYPE_QUATERNION:
			return [v.x, v.y, v.z, v.w]
		TYPE_COLOR:
			return [v.r, v.g, v.b, v.a]
		TYPE_BASIS:
			return basis_to_array(v)
		TYPE_TRANSFORM3D:
			return transform_to_array(v)
		TYPE_ARRAY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, \
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, \
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			var out: Array = []
			for item in v:
				out.append(to_json_safe(item, entities, depth + 1))
			return out
		TYPE_DICTIONARY:
			var d: Dictionary = {}
			for k in v:
				d[str(k)] = to_json_safe(v[k], entities, depth + 1)
			return d
		TYPE_OBJECT:
			if v == null or not is_instance_valid(v):
				return null
			if is_bigint(v):
				return v.to_plain_string()
			if v is Node and entities != null and entities.has_method("id_of"):
				var eid: int = entities.id_of(v)
				return eid if eid != 0 else null
			return null
	return null


## Returns "" if v is JSON-safe as given (after the allowed conversions), or a
## description of the first offending value. Objects other than Nodes and BigInts,
## Callables, Signals, RIDs and NaN/INF floats are rejected.
static func check_json_safe(v: Variant, path: String = "$", depth: int = 0) -> String:
	if depth > 32:
		return "%s: nested too deep" % path
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH, \
		TYPE_VECTOR2, TYPE_VECTOR2I, TYPE_VECTOR3, TYPE_VECTOR3I, TYPE_VECTOR4, TYPE_VECTOR4I, \
		TYPE_QUATERNION, TYPE_COLOR, TYPE_BASIS, TYPE_TRANSFORM3D:
			return ""
		TYPE_FLOAT:
			if is_nan(v) or is_inf(v):
				return "%s: NaN/INF is not JSON-safe" % path
			return ""
		TYPE_ARRAY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, \
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, \
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			var i := 0
			for item in v:
				var e := check_json_safe(item, "%s[%d]" % [path, i], depth + 1)
				if e != "":
					return e
				i += 1
			return ""
		TYPE_DICTIONARY:
			for k in v:
				var kt := typeof(k)
				if kt != TYPE_STRING and kt != TYPE_STRING_NAME and kt != TYPE_INT:
					return "%s: dictionary key %s is not a string" % [path, str(k)]
				var e := check_json_safe(v[k], "%s.%s" % [path, str(k)], depth + 1)
				if e != "":
					return e
			return ""
		TYPE_OBJECT:
			if v == null:
				return ""
			if not is_instance_valid(v):
				return "%s: freed object" % path
			if is_bigint(v) or v is Node:
				return ""
			return "%s: object of class %s is not JSON-safe" % [path, v.get_class()]
	return "%s: value of type %s is not JSON-safe" % [path, type_string(typeof(v))]


## Duck-typed BigInt check (the game's class_name BigInt is not referenced by name,
## so a renamed or missing class cannot break compilation of the loader).
static func is_bigint(v: Variant) -> bool:
	return typeof(v) == TYPE_OBJECT and v != null and is_instance_valid(v) \
		and v.has_method("to_plain_string") and v.has_method("add_big") and ("limbs" in v)


static func transform_to_array(t: Transform3D) -> Array:
	return [t.basis.x.x, t.basis.x.y, t.basis.x.z,
		t.basis.y.x, t.basis.y.y, t.basis.y.z,
		t.basis.z.x, t.basis.z.y, t.basis.z.z,
		t.origin.x, t.origin.y, t.origin.z]


static func basis_to_array(b: Basis) -> Array:
	return [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z]


## Array of 12 numbers (as produced by transform_to_array) -> Transform3D, or null.
static func transform_from(v: Variant) -> Variant:
	if typeof(v) == TYPE_TRANSFORM3D:
		return v
	if typeof(v) != TYPE_ARRAY or v.size() != 12:
		return null
	for x in v:
		if typeof(x) != TYPE_INT and typeof(x) != TYPE_FLOAT:
			return null
	var b := Basis(Vector3(v[0], v[1], v[2]), Vector3(v[3], v[4], v[5]), Vector3(v[6], v[7], v[8]))
	return Transform3D(b, Vector3(v[9], v[10], v[11]))


## [x,y,z] or Vector3 -> Vector3, or null when malformed.
static func vec3_from(v: Variant) -> Variant:
	if typeof(v) == TYPE_VECTOR3:
		return v
	if typeof(v) == TYPE_VECTOR3I:
		return Vector3(v)
	if typeof(v) != TYPE_ARRAY or v.size() != 3:
		return null
	for x in v:
		if typeof(x) != TYPE_INT and typeof(x) != TYPE_FLOAT:
			return null
		if is_nan(float(x)) or is_inf(float(x)):
			return null
	return Vector3(float(v[0]), float(v[1]), float(v[2]))


# ---------------------------------------------------------------- decimal strings

## Normalizes an amount (int, integral float, digit string or BigInt) to a
## non-negative decimal digit string. Returns "" when invalid or negative.
static func to_digits(v: Variant) -> String:
	match typeof(v):
		TYPE_INT:
			return str(v) if v >= 0 else ""
		TYPE_FLOAT:
			if is_nan(v) or is_inf(v) or v < 0.0 or v != floor(v) or v > 9.0e18:
				return ""
			return str(int(v))
		TYPE_STRING, TYPE_STRING_NAME:
			var s := String(v).strip_edges()
			if s.is_empty():
				return ""
			for c in s:
				if c < "0" or c > "9":
					return ""
			s = s.lstrip("0")
			return "0" if s.is_empty() else s
		TYPE_OBJECT:
			if is_bigint(v):
				return v.to_plain_string()
	return ""


## Compares two non-negative decimal digit strings: -1, 0, 1.
static func digits_compare(a: String, b: String) -> int:
	a = a.lstrip("0")
	b = b.lstrip("0")
	if a.length() != b.length():
		return 1 if a.length() > b.length() else -1
	if a == b:
		return 0
	return 1 if a > b else -1


## a + b for non-negative decimal digit strings.
static func digits_add(a: String, b: String) -> String:
	var out := ""
	var i := a.length() - 1
	var j := b.length() - 1
	var carry := 0
	while i >= 0 or j >= 0 or carry > 0:
		var s := carry
		if i >= 0:
			s += a.unicode_at(i) - 48
		if j >= 0:
			s += b.unicode_at(j) - 48
		out = str(s % 10) + out
		carry = s / 10
		i -= 1
		j -= 1
	out = out.lstrip("0")
	return "0" if out.is_empty() else out


## |a - b| and its sign (1 when a > b, -1 when a < b, 0 when equal).
static func digits_diff(a: String, b: String) -> Dictionary:
	var c := digits_compare(a, b)
	if c == 0:
		return {"delta": "0", "sign": 0}
	var big := a if c > 0 else b
	var small := b if c > 0 else a
	var out := ""
	var i := big.length() - 1
	var j := small.length() - 1
	var borrow := 0
	while i >= 0:
		var d := big.unicode_at(i) - 48 - borrow
		if j >= 0:
			d -= small.unicode_at(j) - 48
		if d < 0:
			d += 10
			borrow = 1
		else:
			borrow = 0
		out = str(d) + out
		i -= 1
		j -= 1
	out = out.lstrip("0")
	return {"delta": "0" if out.is_empty() else out, "sign": c}


## True when the digit string fits in a signed int64 without overflow.
static func digits_fit_int64(s: String) -> bool:
	return digits_compare(s, "9223372036854775807") <= 0
