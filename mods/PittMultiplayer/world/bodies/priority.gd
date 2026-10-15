extends RefCounted
## Per-peer send priority (MP2-DESIGN 3.3):
##   w = kind_w(e) * dist_w(|p_e - a_c|) * motion_w(|v_e|) * boost_w(e);  acc[c][e] += w * dt
## Each send tick takes entities in descending acc until the tick's byte budget
## is used, then zeroes their acc. Starvation-free: every awake body's acc keeps
## growing until it is sent.

const W_HELD_OTHER := 4.0
const W_HELD_HOST := 3.0
const W_TOOL := 1.5
const W_PRODUCT := 1.0
const W_CANDY := 0.6
const DIST_SCALE := 8.0
const DIST_FLOOR := 0.05
const BOOST := 3.0
const MIN_RECORD := 19          # Codec.BODY_BASE


## owner: owning peer (1 = host); owner_kind "" | "held" | "equipped"; peer: the receiver.
static func kind_w(pool_id: String, kind: String, owner: int, owner_kind: String, peer: int) -> float:
	if owner_kind != "":
		if owner != 1 and owner != peer:
			return W_HELD_OTHER
		if owner == 1:
			return W_HELD_HOST
	if kind == "fixture_body" or pool_id.begins_with("tool_") or pool_id.begins_with("toy_"):
		return W_TOOL
	if pool_id.begins_with("candy"):
		return W_CANDY
	return W_PRODUCT


static func dist_w(d: float) -> float:
	var x := d / DIST_SCALE
	return maxf(DIST_FLOOR, 1.0 / (1.0 + x * x))


static func motion_w(speed: float) -> float:
	return 1.0 + clampf(speed / 4.0, 0.0, 3.0)


static func boost_w(boosted: bool) -> float:
	return BOOST if boosted else 1.0


## cands: [[acc: float, eid: int, size: int]]; returns the eids that fit in
## budget_bytes, highest acc first (at least one when any candidate exists and
## the budget is positive, so a tiny budget never starves everything).
static func select(cands: Array, budget_bytes: int) -> Array:
	var sorted := cands.duplicate()
	sorted.sort_custom(func(x, y): return float(x[0]) > float(y[0]))
	var out: Array = []
	var used := 0
	for c in sorted:
		var sz := int(c[2])
		if used + sz > budget_bytes and not out.is_empty():
			break
		if budget_bytes <= 0:
			break
		out.append(int(c[1]))
		used += sz
	return out


## accs[k] / idx[k]: accumulator and candidate index of each eligible body;
## sizes[idx[k]]: its record size. Returns the candidate indices that fit in
## budget_bytes, highest acc first (at least one, as select). Only the top
## budget/BODY_BASE candidates are sorted in script: a native sort of a copy of
## the accumulators gives the cut-off value first.
static func select_top(accs: PackedFloat32Array, idx: PackedInt32Array, sizes: PackedInt32Array, budget_bytes: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	var n := accs.size()
	if n == 0 or budget_bytes <= 0:
		return out
	var kmax := maxi(1, int(float(budget_bytes) / float(MIN_RECORD)) + 1)
	var top: Array = []
	if n > kmax:
		var sorted := accs.duplicate()
		sorted.sort()
		var thr: float = sorted[n - kmax]
		for k in n:
			if accs[k] >= thr:
				top.append([accs[k], idx[k]])
	else:
		for k in n:
			top.append([accs[k], idx[k]])
	top.sort_custom(func(x, y): return float(x[0]) > float(y[0]))
	var used := 0
	for c in top:
		var sz := int(sizes[int(c[1])])
		if used + sz > budget_bytes and not out.is_empty():
			break
		out.append(int(c[1]))
		used += sz
	return out
