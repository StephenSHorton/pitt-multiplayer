extends RefCounted
## Semantic versions and ranges (our own small implementation).
## Versions: MAJOR[.MINOR[.PATCH]][-pre]. Ranges: "*", "", exact "1.2.3",
## "^1.2", "~1.2.3", ">=1.0.0 <2.0.0" (space = AND), "a || b" (OR).


## Returns {major, minor, patch, pre} or {} when invalid.
static func parse(v: String) -> Dictionary:
	v = v.strip_edges()
	if v.begins_with("v"):
		v = v.substr(1)
	if v.is_empty():
		return {}
	var pre := ""
	var dash := v.find("-")
	if dash >= 0:
		pre = v.substr(dash + 1)
		v = v.substr(0, dash)
		if pre.is_empty():
			return {}
	var plus := v.find("+")
	if plus >= 0:
		v = v.substr(0, plus)
	var parts := v.split(".")
	if parts.size() < 1 or parts.size() > 3:
		return {}
	var nums: Array[int] = [0, 0, 0]
	for i in parts.size():
		if not parts[i].is_valid_int() or parts[i].begins_with("-") or parts[i].begins_with("+"):
			return {}
		nums[i] = int(parts[i])
	return {"major": nums[0], "minor": nums[1], "patch": nums[2], "pre": pre, "parts": parts.size()}


static func is_valid(v: String) -> bool:
	var p := parse(v)
	return not p.is_empty() and p.parts == 3


## -1, 0, 1. Invalid versions compare as lowest.
static func compare(a: String, b: String) -> int:
	return _cmp(parse(a), parse(b))


static func _cmp(pa: Dictionary, pb: Dictionary) -> int:
	if pa.is_empty() or pb.is_empty():
		if pa.is_empty() and pb.is_empty():
			return 0
		return -1 if pa.is_empty() else 1
	for k in ["major", "minor", "patch"]:
		if pa[k] != pb[k]:
			return 1 if pa[k] > pb[k] else -1
	# a pre-release sorts before the release
	if pa.pre == pb.pre:
		return 0
	if pa.pre == "":
		return 1
	if pb.pre == "":
		return -1
	return 1 if pa.pre > pb.pre else -1


## True when version satisfies the range.
static func satisfies(version: String, range_str: String) -> bool:
	var pv := parse(version)
	if pv.is_empty():
		return false
	var r := range_str.strip_edges()
	if r == "" or r == "*" or r == "x":
		return true
	for alt in r.split("||"):
		var comps := _comparators(alt.strip_edges())
		if comps.is_empty():
			continue
		var ok := true
		for c in comps:
			var d := _cmp(pv, c.v)
			match c.op:
				">=": ok = d >= 0
				">": ok = d > 0
				"<=": ok = d <= 0
				"<": ok = d < 0
				"=": ok = d == 0
			if not ok:
				break
		if ok:
			return true
	return false


static func is_valid_range(range_str: String) -> bool:
	var r := range_str.strip_edges()
	if r == "" or r == "*" or r == "x":
		return true
	for alt in r.split("||"):
		if _comparators(alt.strip_edges()).is_empty():
			return false
	return true


## Expands one AND-set into a list of {op, v}. Empty list = invalid.
static func _comparators(s: String) -> Array:
	var out: Array = []
	if s == "*" or s == "":
		out.append({"op": ">=", "v": parse("0.0.0")})
		return out
	for tok in s.split(" ", false):
		var op := ""
		for candidate in [">=", "<=", ">", "<", "=", "^", "~"]:
			if tok.begins_with(candidate):
				op = candidate
				tok = tok.substr(candidate.length())
				break
		var p := parse(tok)
		if p.is_empty():
			return []
		match op:
			"", "=":
				if p.parts == 3:
					out.append({"op": "=", "v": p})
				else:
					# "1.2" means 1.2.x, "1" means 1.x
					out.append({"op": ">=", "v": p})
					out.append({"op": "<", "v": _bump(p, p.parts - 1)})
			"^":
				out.append({"op": ">=", "v": p})
				if p.major > 0 or p.parts == 1:
					out.append({"op": "<", "v": _bump(p, 0)})
				elif p.minor > 0 or p.parts == 2:
					out.append({"op": "<", "v": _bump(p, 1)})
				else:
					out.append({"op": "<", "v": _bump(p, 2)})
			"~":
				out.append({"op": ">=", "v": p})
				out.append({"op": "<", "v": _bump(p, 0 if p.parts == 1 else 1)})
			_:
				out.append({"op": op, "v": p})
	return out


static func _bump(p: Dictionary, index: int) -> Dictionary:
	var n := {"major": p.major, "minor": p.minor, "patch": p.patch, "pre": "", "parts": 3}
	match index:
		0:
			n.major += 1
			n.minor = 0
			n.patch = 0
		1:
			n.minor += 1
			n.patch = 0
		_:
			n.patch += 1
	return n
