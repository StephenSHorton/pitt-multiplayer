extends "res://tests/test_case.gd"
## MP2 3.4 interpolation: Hermite / slerp, extrapolation cap, SNAP never
## interpolated into, SLEEP exact, ring order and capacity, delay formula.

const Codec = preload("res://gamedir/mods/PittMultiplayer/net/codec.gd")
const Interp = preload("res://gamedir/mods/PittMultiplayer/world/bodies/interp.gd")


func _s(t: int, p: Vector3, l: Vector3 = Vector3.ZERO, flags: int = 1, q: Quaternion = Quaternion.IDENTITY) -> Dictionary:
	return {"t": t, "p": p, "q": q, "l": l, "a": Vector3.ZERO, "flags": flags, "epoch": 0}


func test_hermite_matches_ballistic_motion() -> void:
	# a body under gravity: Hermite with exact end velocities reproduces a quadratic
	var g := Vector3(0, -9.81, 0)
	var v0 := Vector3(2, 5, 0)
	var ring: Array = []
	for i in 4:
		var t := i * 0.1
		ring.append(_s(i * 100, v0 * t + g * (0.5 * t * t), v0 + g * t))
	var worst := 0.0
	for ms in range(0, 301, 7):
		var t := ms / 1000.0
		var truth := v0 * t + g * (0.5 * t * t)
		var s := Interp.sample(ring, ms)
		worst = maxf(worst, (s.p as Vector3).distance_to(truth))
	assert_true(worst < 0.001, "Hermite error %.5f m on a parabola" % worst)


func test_linear_without_velocity_and_slerp() -> void:
	var qa := Quaternion.IDENTITY
	var qb := Quaternion(Vector3.UP, PI / 2)
	var ring := [_s(0, Vector3.ZERO, Vector3.ZERO, 0, qa), _s(100, Vector3(10, 0, 0), Vector3.ZERO, 0, qb)]
	var s := Interp.sample(ring, 50)
	assert_true((s.p as Vector3).distance_to(Vector3(5, 0, 0)) < 0.0001, "linear midpoint")
	assert_true(absf(Interp.angle_deg(s.q, Quaternion(Vector3.UP, PI / 4))) < 0.01, "slerp midpoint")
	assert_eq(String(s.mode), "interp", "mode interp")


func test_extrapolation_cap_and_hold() -> void:
	var ring := [_s(0, Vector3.ZERO, Vector3(10, 0, 0))]
	var s := Interp.sample(ring, 100)
	assert_true((s.p as Vector3).distance_to(Vector3(1, 0, 0)) < 0.0001, "extrapolated 100 ms")
	assert_eq(String(s.mode), "extrap", "extrap")
	s = Interp.sample(ring, 1000)
	assert_true((s.p as Vector3).distance_to(Vector3(2.5, 0, 0)) < 0.0001, "capped at 250 ms")
	assert_eq(String(s.mode), "hold", "then hold")
	var still := [_s(0, Vector3(1, 1, 1), Vector3.ZERO, 0)]
	assert_eq(Interp.sample(still, 500).p, Vector3(1, 1, 1), "no LIN: hold")


func test_snap_is_never_interpolated() -> void:
	var ring := [_s(0, Vector3.ZERO, Vector3.ZERO), _s(100, Vector3(50, 0, 0), Vector3.ZERO, Codec.RF_LIN | Codec.RF_SNAP)]
	var s := Interp.sample(ring, 99)
	assert_true((s.p as Vector3).length() < 0.001, "before the teleport the old pose holds (no streak)")
	assert_eq(String(s.mode), "snap_wait", "snap_wait")
	s = Interp.sample(ring, 100)
	assert_eq(s.p, Vector3(50, 0, 0), "at the teleport: the new pose")


func test_sleep_exact() -> void:
	var rest := Vector3(1.23456, 0.15, -9.87654)
	var ring := [_s(0, rest + Vector3(0, 1, 0), Vector3(0, -5, 0)), _s(100, rest, Vector3.ZERO, Codec.RF_SLEEP)]
	var s := Interp.sample(ring, 5000)
	assert_eq(s.p, rest, "sleeping state placed exactly")
	assert_eq(String(s.mode), "sleep", "mode sleep")


func test_ring_order_and_capacity() -> void:
	var ring: Array = []
	for t in [100, 300, 200, 200, 50, 400, 500, 600, 700]:
		Interp.ring_push(ring, _s(t, Vector3(t, 0, 0)))
	assert_eq(ring.size(), Interp.RING, "capacity 6")
	var ts: Array = []
	for s in ring:
		ts.append(int(s.t))
	assert_eq(ts, [200, 300, 400, 500, 600, 700], "sorted, duplicates dropped, oldest evicted")
	assert_false(Interp.ring_push(ring, _s(10, Vector3.ZERO)), "older than a full ring: dropped")
	assert_eq(Interp.delay_for(0.0), 66, "delay floor 66")
	assert_eq(Interp.delay_for(33.5), 100, "2 x 33.5 + 33 = 100")
	assert_eq(Interp.delay_for(500.0), 200, "delay cap 200")
	assert_eq(Interp.delay_for(15.0, 110.0), 173, "100 ms link: 110 late + 2 x 15 + 33 (render behind the newest frame)")
	assert_eq(Interp.delay_for(0.0, -5.0), 66, "negative lateness (clock noise) ignored")
