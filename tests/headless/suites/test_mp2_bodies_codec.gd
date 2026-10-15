extends "res://tests/test_case.gd"
## MP2 2.3: frame kinds 4 (body state) and 5 (held body): round trip,
## quantisation error bounds (pos <= 0.5 mm, rot <= 0.1 deg typical / 0.15 max),
## NaN / overrun / range rejection, packing into <= 1200 B packets; the MP2
## whitelist and rate classes of proto.gd (2.4, 2.5).

const Codec = preload("res://gamedir/mods/PittMultiplayer/net/codec.gd")
const Proto = preload("res://gamedir/mods/PittMultiplayer/net/proto.gd")
const Interp = preload("res://gamedir/mods/PittMultiplayer/world/bodies/interp.gd")


func _rand_q(rng: RandomNumberGenerator) -> Quaternion:
	var q := Quaternion(rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1), rng.randf_range(-1, 1))
	return q.normalized()


func test_quantisation_bounds() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var worst_p := 0.0
	var worst_a := 0.0
	var sum_a := 0.0
	for i in 2000:
		var v := rng.randf_range(-8000.0, 8000.0)
		worst_p = maxf(worst_p, absf(Codec.dq_pos(Codec.q_pos(v)) - v))
		var q := _rand_q(rng)
		var a := Interp.angle_deg(q, Codec.dq_rot(Codec.q_rot(q)))
		worst_a = maxf(worst_a, a)
		sum_a += a
	assert_true(worst_p <= 0.0005, "position error %.6f m <= 0.5 mm" % worst_p)
	# 32-bit smallest-three (3 x 10 bits): mean well under 0.1 deg, worst about 0.2 deg
	assert_true(sum_a / 2000.0 <= 0.1, "mean rotation error %.4f deg <= 0.1" % (sum_a / 2000.0))
	assert_true(worst_a <= 0.25, "worst rotation error %.4f deg <= 0.25" % worst_a)
	var qi := Codec.dq_rot(Codec.q_rot(Quaternion.IDENTITY))
	assert_true(absf(qi.w - 1.0) < 1.0e-6 and absf(qi.x) < 1.0e-6, "identity is exact")
	assert_eq(Codec.dq_vel(Codec.q_vel(1000.0)), 327.0, "velocity clamped")


func test_bodies_round_trip() -> void:
	var recs := [
		{"eid": 1001, "flags": Codec.RF_LIN | Codec.RF_ANG, "epoch": 3, "p": Vector3(1.5, -2.25, 100.125),
			"q": Quaternion(Vector3.UP, 0.7), "l": Vector3(1, -2, 3.5), "a": Vector3(0.5, 0, -1)},
		{"eid": 0x80001234, "flags": Codec.RF_SLEEP | Codec.RF_HELD, "epoch": 255, "p": Vector3(-7999, 0, 7999),
			"q": Quaternion.IDENTITY},
		{"eid": 5000, "flags": Codec.RF_LIN | Codec.RF_SNAP | Codec.RF_NOCOLLIDE, "epoch": 0, "p": Vector3.ZERO,
			"q": Quaternion(Vector3.RIGHT, -2.0), "l": Vector3(0, 9.81, 0)},
	]
	var b := Codec.encode_bodies(123456, 65535, recs)
	assert_eq(b.size(), Codec.BODIES_HEADER + 31 + 19 + 25, "record sizes 31 / 19 / 25")
	assert_eq(int(b[0]), Proto.FRAME_BODIES, "kind 4")
	var d := Codec.decode_bodies(b)
	assert_false(d.is_empty(), "decodes")
	if d.is_empty():
		return
	assert_eq(int(d.host_ms), 123456, "host_ms")
	assert_eq(int(d.seq), 65535, "seq")
	assert_eq(d.records.size(), 3, "3 records")
	for i in 3:
		var r: Dictionary = d.records[i]
		assert_eq(int(r.eid), int(recs[i].eid), "eid %d" % i)
		assert_eq(int(r.flags), int(recs[i].flags), "flags %d" % i)
		assert_eq(int(r.epoch), int(recs[i].epoch), "epoch %d" % i)
		assert_true((r.p as Vector3).distance_to(recs[i].p) < 0.001, "position %d" % i)
		assert_true(Interp.angle_deg(r.q, recs[i].q) < 0.2, "rotation %d" % i)
	assert_true((d.records[0].l as Vector3).distance_to(Vector3(1, -2, 3.5)) < 0.006, "linear velocity")
	assert_true((d.records[0].a as Vector3).distance_to(Vector3(0.5, 0, -1)) < 0.006, "angular velocity")
	assert_eq(d.records[1].l, Vector3.ZERO, "no LIN -> zero velocity")
	var dec := Codec.decode(b, 1024)
	assert_eq(String(dec.error), "", "Codec.decode passes kind 4 through")
	assert_true(bool(dec.get("raw", false)), "undecoded for the module")


func test_bodies_rejects_bad_input() -> void:
	var b := Codec.encode_bodies(1, 1, [{"eid": 7, "flags": Codec.RF_LIN, "p": Vector3(1, 2, 3), "q": Quaternion.IDENTITY}])
	assert_true(Codec.decode_bodies(b.slice(0, b.size() - 1)).is_empty(), "truncated record")
	var over := b.duplicate()
	over.encode_u16(2, 2)
	assert_true(Codec.decode_bodies(over).is_empty(), "count overruns the buffer")
	var extra := b.duplicate()
	extra.append(0)
	assert_true(Codec.decode_bodies(extra).is_empty(), "trailing bytes")
	var far := Codec.encode_bodies(1, 1, [{"eid": 7, "flags": 0, "p": Vector3(8100, 0, 0), "q": Quaternion.IDENTITY}])
	assert_true(Codec.decode_bodies(far).is_empty(), "position beyond 8000 m")
	var big := PackedByteArray()
	big.resize(1300)
	big[0] = Proto.FRAME_BODIES
	assert_true(Codec.decode_bodies(big).is_empty(), "packet over 1200 B")
	var nan_rec := Codec.encode_bodies(1, 1, [{"eid": 9, "flags": Codec.RF_LIN, "p": Vector3(NAN, 0, 0),
		"q": Quaternion(NAN, 0, 0, 1), "l": Vector3(INF, 0, 0)}])
	var dn := Codec.decode_bodies(nan_rec)
	if not dn.is_empty():
		var r: Dictionary = dn.records[0]
		assert_true((r.p as Vector3).is_finite() and (r.l as Vector3).is_finite(), "NaN never survives quantisation")
		assert_true(is_equal_approx((r.q as Quaternion).length(), 1.0), "rotation normalised")


func test_pack_bodies_1200() -> void:
	var recs: Array = []
	for i in 300:
		recs.append({"eid": 1000 + i, "flags": Codec.RF_LIN | (Codec.RF_ANG if i % 3 == 0 else 0), "epoch": 0,
			"p": Vector3(i, 1, -i), "q": Quaternion.IDENTITY, "l": Vector3(1, 0, 0), "a": Vector3(0, 1, 0)})
	var pkts := Codec.pack_bodies(77, 10, recs)
	var total := 0
	var seqs: Array = []
	for p in pkts:
		assert_true(p.size() <= Codec.PACK_TARGET, "packet %d B <= 1100 (PACK_TARGET)" % p.size())
		var d := Codec.decode_bodies(p)
		total += d.records.size()
		seqs.append(int(d.seq))
	assert_eq(total, 300, "every record packed once")
	assert_eq(seqs[0], 10, "first seq")
	assert_eq(seqs[1], 11, "consecutive seqs")
	var only25: Array = []
	for i in 43:
		only25.append({"eid": i + 1, "flags": Codec.RF_LIN, "p": Vector3.ZERO, "q": Quaternion.IDENTITY})
	assert_eq(Codec.pack_bodies(0, 0, only25).size(), 1, "43 moving records fit one 1100 B packet")
	only25.append({"eid": 99, "flags": Codec.RF_LIN, "p": Vector3.ZERO, "q": Quaternion.IDENTITY})
	assert_eq(Codec.pack_bodies(0, 0, only25).size(), 2, "the 44th does not")
	assert_eq(Codec.pack_bodies(0, 0, only25, Codec.MAX_PACKET).size(), 1, "a 1200 B target still fits 44")


## Pre-encoded records (the host's shared per-tick cache) pack to the same bytes
## as pack_bodies, and the SNAP patch of the flag byte decodes.
func test_pack_records_matches_pack_bodies() -> void:
	var recs: Array = []
	var bytes: Array = []
	for i in 120:
		var r := {"eid": 5000 + i, "flags": (Codec.RF_LIN if i % 2 == 0 else Codec.RF_SLEEP) | (Codec.RF_ANG if i % 5 == 0 else 0),
			"epoch": i & 0xFF, "p": Vector3(i * 0.5, 2, -i), "q": Quaternion(Vector3.UP, i * 0.1), "l": Vector3(1, -2, 3),
			"a": Vector3(0, 1, 0)}
		recs.append(r)
		bytes.append(Codec.encode_body_record(r))
	var a := Codec.pack_bodies(1234, 7, recs)
	var b := Codec.pack_records(1234, 7, bytes)
	assert_eq(a.size(), b.size(), "same packet count")
	for i in a.size():
		assert_eq(a[i], b[i], "packet %d identical" % i)
		assert_true((b[i] as PackedByteArray).size() <= Codec.PACK_TARGET, "packet %d within PACK_TARGET" % i)
	var one: PackedByteArray = bytes[3].duplicate()
	one[4] = int(one[4]) | Codec.RF_SNAP
	var d := Codec.decode_bodies(Codec.pack_records(0, 0, [one])[0])
	assert_eq(int(d.records[0].flags) & Codec.RF_SNAP, Codec.RF_SNAP, "patched SNAP flag decodes")
	assert_eq(int(d.records[0].eid), 5003, "eid intact")


func test_held_round_trip() -> void:
	var recs := [{"eid": 1234, "epoch": 65000, "p": Vector3(3, 4, 5), "q": Quaternion(Vector3.FORWARD, 1.0),
		"l": Vector3(0.5, 6, -1), "a": Vector3(1, 2, 3)}]
	var b := Codec.encode_held(999, recs)
	assert_eq(b.size(), Codec.HELD_HEADER + Codec.HELD_RECORD, "8 + 31 B")
	assert_eq(int(b[0]), Proto.FRAME_HELD, "kind 5")
	var d := Codec.decode_held(b)
	assert_eq(int(d.client_ms), 999, "client_ms")
	assert_eq(int(d.records[0].epoch), 65000, "u16 epoch")
	assert_true((d.records[0].p as Vector3).distance_to(Vector3(3, 4, 5)) < 0.001, "position")
	assert_true((d.records[0].a as Vector3).distance_to(Vector3(1, 2, 3)) < 0.006, "angular")
	var three := Codec.encode_held(1, [recs[0], recs[0], recs[0]])
	assert_eq(int(three.decode_u16(2)), 2, "at most 2 records")
	assert_true(Codec.decode_held(b.slice(0, 20)).is_empty(), "truncated held frame")
	var bad := b.duplicate()
	bad.encode_u16(2, 3)
	assert_true(Codec.decode_held(bad).is_empty(), "count over 2")


func test_proto_mp2_whitelist() -> void:
	var host := Proto.new("host")
	host.sid = "abc"
	host.rate_limits_enabled = false
	assert_eq(Proto.PROTO, 2, "MP_PROTO 2 (D8)")
	assert_eq(host.check_json(5, Proto.CH_WORLD, {"k": "own_req", "sid": "abc", "q": 1}, true), "", "own_req on ch3")
	assert_eq(host.check_json(5, Proto.CH_WORLD, {"k": "own_req", "sid": "abc", "q": 1}, true), "old_seq", "ch3 seq")
	assert_eq(host.check_json(5, Proto.CH_CONTROL, {"k": "ping", "sid": "abc", "q": 1}, true), "",
		"ch0 has its own sequence")
	assert_eq(host.check_json(5, Proto.CH_WORLD, {"k": "ents", "sid": "abc", "q": 2}, true).get_slice(":", 0),
		"kind_not_allowed", "ents is host -> client")
	assert_eq(host.check_json(5, Proto.CH_WORLD, {"k": "interact", "sid": "abc", "q": 3}, false).get_slice(":", 0),
		"kind_not_allowed", "nothing on ch3 before the handshake")
	assert_eq(host.check_json(5, Proto.CH_WORLD, {"k": "interact", "sid": "abc", "q": 4}, true, 5000), "too_large",
		"ch3 C->H capped at 4 KB")
	assert_eq(host.check_json(5, Proto.CH_CONTROL, {"k": "world_req", "sid": "abc", "q": 5}, true), "", "world_req ch0")
	assert_eq(host.check_raw(5, Proto.FRAME_HELD), "", "held frames from clients")
	assert_ne(host.check_raw(5, Proto.FRAME_BODIES), "", "body frames are host -> client only")
	var client := Proto.new("client")
	client.sid = "abc"
	for k in ["ents", "meta", "own", "fx", "pimp", "fixture_spawn"]:
		assert_eq(client.check_json(1, Proto.CH_WORLD, {"k": k, "sid": "abc"}, true), "", "%s accepted" % k)
	for k in ["wsnap_begin", "wsnap_end", "combo"]:
		assert_eq(client.check_json(1, Proto.CH_CONTROL, {"k": k, "sid": "abc"}, true), "", "%s on ch0" % k)
	assert_eq(client.check_raw(1, Proto.FRAME_BODIES), "", "kind 4 to clients")
	var extra := Proto.new("host")
	extra.add_kinds({"ch3_c2h": ["custom_verb"]})
	extra.sid = "abc"
	assert_eq(extra.check_json(5, Proto.CH_WORLD, {"k": "custom_verb", "sid": "abc"}, true), "", "module kinds whitelisted")
	assert_eq(Proto.rate_class("tool_in"), "interact", "rate class interact")
	assert_eq(Proto.rate_class("own_rel"), "own", "rate class own")


func test_held_rate_limit() -> void:
	var host := Proto.new("host")
	var drops := 0
	for i in 120:
		if host.check_raw(5, Proto.FRAME_HELD) != "":
			drops += 1
	assert_true(drops >= 30 and drops <= 45, "burst 80, then limited (%d dropped of 120)" % drops)
