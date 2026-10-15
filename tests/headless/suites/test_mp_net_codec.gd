extends "res://tests/test_case.gd"
## Frames, caps, validator drops (unknown kind, stale sid, duplicate q: R21/R22),
## chunk + zstd + sha256, avatar frame round trip, ENet raw packet API (S1).

const Proto = preload("res://gamedir/mods/PittMultiplayer/net/proto.gd")
const Codec = preload("res://gamedir/mods/PittMultiplayer/net/codec.gd")
const TransportEnet = preload("res://gamedir/mods/PittMultiplayer/net/transport_enet.gd")
const Loopback = preload("res://gamedir/mods/PittMultiplayer/net/transport_loopback.gd")


func test_json_frames() -> void:
	var small := Codec.encode_json({"k": "ping", "t0": 12, "q": 3})
	assert_eq(int(small[0]), Proto.FRAME_JSON, "small JSON is frame 0")
	var d := Codec.decode(small, Proto.MAX_C2H_JSON)
	assert_eq(String(d.error), "", "decodes")
	assert_eq(d.msg.t0, 12, "integral numbers come back as int")
	assert_eq(typeof(d.msg.q), TYPE_INT, "q is an int")
	var big := {"k": "econ", "items": {}}
	for i in 200:
		big.items["upgrades/item_%d/" % i] = {"level": i, "enabled": true}
	var bb := Codec.encode_json(big)
	assert_eq(int(bb[0]), Proto.FRAME_ZJSON, "> 1 KB is zstd")
	var d2 := Codec.decode(bb, Proto.MAX_H2C_JSON)
	assert_eq(String(d2.error), "", "zstd decodes")
	assert_eq(d2.msg.items.size(), 200, "content survives")
	assert_eq(d2.msg.items["upgrades/item_7/"].level, 7, "nested ints")
	var huge := {"k": "cmd", "pad": "x".repeat(Proto.MAX_C2H_JSON + 10)}
	var hb := Codec.encode_json(huge)
	assert_eq(String(Codec.decode(hb, Proto.MAX_C2H_JSON).error), "too_large", "client->host cap 16 KB")
	assert_eq(String(Codec.decode(PackedByteArray([9, 1, 2]), 100).error), "unknown_kind", "unknown frame kind")
	assert_eq(String(Codec.decode(PackedByteArray([0, 123, 34]), 100).error), "bad_json", "garbage JSON")
	assert_eq(String(Codec.decode(PackedByteArray(), 100).error), "empty", "empty")


func test_avatar_round_trip() -> void:
	var f := {"slot": 3, "flags": Codec.F_CROUCH | Codec.F_TELEPORTED, "t_ms": 123456, "pos": Vector3(1.5, -2, 300),
		"yaw": 1.25, "pitch": -0.5, "vel": Vector3(0.1, 0.2, -9), "seq": 77}
	var b := Codec.encode_avatar(f)
	assert_eq(b.size(), 44, "44 bytes")
	var g := Codec.decode_avatar(b)
	assert_eq(g.slot, 3, "slot")
	assert_eq(g.flags, f.flags, "flags")
	assert_eq(g.t_ms, 123456, "t_ms")
	assert_true((g.pos as Vector3).is_equal_approx(f.pos), "pos")
	assert_true(is_equal_approx(g.yaw, 1.25) and is_equal_approx(g.pitch, -0.5), "yaw/pitch")
	assert_true((g.vel as Vector3).is_equal_approx(f.vel), "vel")
	assert_eq(g.seq, 77, "seq")
	var r := Codec.set_avatar_slot(b, 9)
	assert_eq(Codec.decode_avatar(r).slot, 9, "host rewrites the slot")
	var bad := b.duplicate()
	bad.encode_float(8, NAN)
	assert_true(Codec.decode_avatar(bad).is_empty(), "NaN rejected")
	assert_true(Codec.decode_avatar(b.slice(0, 40)).is_empty(), "short rejected")


func test_chunks_zstd_sha() -> void:
	var text := JSON.stringify({"payload": "abc".repeat(40000)})
	var raw := text.to_utf8_buffer()
	var z := Codec.zstd(raw)
	var parts := Codec.split(z, Proto.CHUNK_SIZE)
	assert_true(parts.size() >= 1, "split")
	var joined := PackedByteArray()
	for i in parts.size():
		var frame := Codec.encode_chunk(5, i, parts[i])
		var d := Codec.decode(frame, 0)
		assert_eq(String(d.error), "", "chunk decodes")
		assert_eq(d.chunk.xfer, 5, "xfer")
		assert_eq(d.chunk.index, i, "index")
		joined.append_array(d.chunk.data)
	var back := Codec.unzstd(joined, raw.size())
	assert_eq(Codec.sha256_hex(back), Codec.sha256_hex(raw), "sha256 matches after the round trip")
	assert_eq(back.get_string_from_utf8(), text, "text identical")
	var oversized := PackedByteArray()
	oversized.resize(Proto.CHUNK_SIZE + 20)
	assert_eq(String(Codec.decode(Codec.encode_chunk(1, 0, oversized), 0).error), "bad_chunk", "chunk cap 32 KB")


func test_validator_drops() -> void:
	var host := Proto.new("host")
	host.sid = "abc"
	# before the handshake only hello/bye/ping/pong
	assert_eq(host.check_json(5, 0, {"k": "hello", "q": 1}, false), "", "hello before handshake")
	assert_ne(host.check_json(5, 0, {"k": "cmd", "q": 2}, false), "", "cmd before handshake dropped")
	# after: sid and seq
	assert_eq(host.check_json(5, 0, {"k": "ping", "sid": "abc", "q": 3}, true), "", "ok")
	assert_eq(host.check_json(5, 0, {"k": "ping", "sid": "abc", "q": 3}, true), "old_seq", "duplicate q dropped")
	assert_eq(host.check_json(5, 0, {"k": "ping", "sid": "abc", "q": 2}, true), "old_seq", "older q dropped")
	assert_eq(host.check_json(5, 0, {"k": "ping", "sid": "zzz", "q": 9}, true), "stale_sid", "stale sid dropped")
	assert_true(String(host.check_json(5, 0, {"k": "welcome", "sid": "abc", "q": 10}, true)).begins_with("kind_not_allowed"),
		"host never accepts host->client kinds")
	assert_eq(host.check_json(5, 1, {"k": "ping", "sid": "abc", "q": 11}, true), "wrong_channel", "JSON only on channel 0")
	assert_eq(host.check_json(5, 0, {"sid": "abc", "q": 12}, true), "no_kind", "no k")
	assert_true(int(host.drop_counts.get("old_seq", 0)) == 2, "drops are counted: %s" % str(host.drop_counts))
	var client := Proto.new("client")
	assert_eq(client.check_json(1, 0, {"k": "welcome", "sid": "s1", "q": 1}, false), "", "welcome sets up the session")
	assert_eq(client.check_json(1, 0, {"k": "reject", "sid": "s1", "q": 2}, false), "", "reject before handshake")
	assert_eq(client.check_json(1, 0, {"k": "welcome", "q": 3}, false), "welcome_without_sid", "welcome needs a sid")
	assert_true(String(client.check_json(1, 0, {"k": "econ", "q": 4}, false)).begins_with("kind_not_allowed"),
		"econ before welcome dropped")


func test_rate_limits_and_kick() -> void:
	var host := Proto.new("host")
	host.sid = "s"
	var dropped := 0
	for i in 200:
		if host.check_json(9, 0, {"k": "cmd", "sid": "s", "q": i + 1}, true) != "":
			dropped += 1
	assert_true(dropped >= 200 - 61, "commands over 30/s (burst 60) are dropped: %d" % dropped)
	assert_false(host.should_kick(9), "a single burst does not kick")
	var av := 0
	for i in 200:
		if host.check_avatar(9) != "":
			av += 1
	assert_true(av > 100, "avatar frames are rate limited: %d" % av)


func test_enet_raw_packets() -> void:
	# S1: raw ENetMultiplayerPeer, polled manually, no SceneMultiplayer
	var port := 27600 + (Time.get_ticks_msec() % 300)
	var h := TransportEnet.new()
	var c := TransportEnet.new()
	assert_eq(h.host({"kind": "enet", "role": "host", "address": "127.0.0.1", "port": port}), OK, "server")
	assert_eq(c.join({"kind": "enet", "role": "client", "address": "127.0.0.1", "port": port}), OK, "client")
	var got_h: Array = []
	var got_c: Array = []
	var conn: Array = []
	h.packet.connect(func(p, ch, b): got_h.append([p, ch, b]))
	c.packet.connect(func(p, ch, b): got_c.append([p, ch, b]))
	h.peer_connected.connect(func(p): conn.append(p))
	var t0 := Time.get_ticks_msec()
	while (conn.is_empty() or not c.is_open()) and Time.get_ticks_msec() - t0 < 3000:
		h.poll()
		c.poll()
		await tree.process_frame
	assert_true(not conn.is_empty() and c.is_open(), "connected over localhost")
	if conn.is_empty() or not c.is_open():
		h.close()
		c.close()
		return
	assert_eq(c.send(1, Proto.CH_CONTROL, Codec.encode_json({"k": "hello"})), OK, "client send ch0")
	c.send(1, Proto.CH_AVATAR, Codec.encode_avatar({"slot": 2, "pos": Vector3.ONE}))
	h.send(conn[0], Proto.CH_BULK, Codec.encode_chunk(1, 0, PackedByteArray([1, 2, 3])))
	t0 = Time.get_ticks_msec()
	while (got_h.size() < 2 or got_c.size() < 1) and Time.get_ticks_msec() - t0 < 3000:
		h.poll()
		c.poll()
		await tree.process_frame
	assert_eq(got_h.size(), 2, "host received 2 packets")
	if got_h.size() == 2:
		var chans := [int(got_h[0][1]), int(got_h[1][1])]
		chans.sort()
		assert_eq(chans, [0, 2], "channels preserved (0 control, 2 avatar)")
		assert_eq(int(got_h[0][0]), c.local_peer_id(), "sender id from the transport")
	assert_true(got_c.size() == 1 and int(got_c[0][1]) == Proto.CH_BULK, "client got the bulk chunk on ch1")
	var closed: Array = []
	c.closed.connect(func(r): closed.append(r))
	h.close()
	t0 = Time.get_ticks_msec()
	while closed.is_empty() and Time.get_ticks_msec() - t0 < 3000:
		c.poll()
		await tree.process_frame
	assert_true(not closed.is_empty(), "client sees the host go: %s" % str(closed))
	c.close()


func test_loopback_conditioning() -> void:
	var hub = Loopback.Hub.new(42)
	hub.latency_ms = 30
	hub.loss = 0.5
	var h := Loopback.new()
	var c := Loopback.new()
	h.host({"hub": hub})
	c.join({"hub": hub})
	var rel: Array = []
	var unrel: Array = []
	h.packet.connect(func(_p, ch, b):
		if ch == 0:
			rel.append(b[1])
		else:
			unrel.append(b[1]))
	await wait_frames(1)
	var t0 := Time.get_ticks_msec()
	while not c.is_open() and Time.get_ticks_msec() - t0 < 1000:
		c.poll()
		h.poll()
		await tree.process_frame
	for i in 50:
		c.send(1, 0, PackedByteArray([0, i]))
		c.send(1, 2, PackedByteArray([2, i]))
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 300:
		h.poll()
		await tree.process_frame
	var expect: Array = []
	for i in 50:
		expect.append(i)
	assert_eq(rel, expect, "reliable channel: all, in order, despite loss")
	assert_true(unrel.size() > 5 and unrel.size() < 45, "unreliable channel loses ~50%%: %d" % unrel.size())
	h.close()
	c.close()
