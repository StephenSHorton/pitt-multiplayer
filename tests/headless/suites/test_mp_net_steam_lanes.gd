extends "res://tests/test_case.gd"
## Steam lane limit (v0.2.1 fix). The bundled GodotSteam 4.19.1 SteamPacketPeer
## sends every channel >= max_channels - 1 on lane 0 (the game sets
## max_channels=4, so channel 3 = CH_WORLD lands on lane 0, where the
## validator drops ents / meta / interact / own_req as kind_not_allowed).
## Two ENet transports emulate that limit (lane_cap_emulation = 4); every
## logical channel must still arrive as itself, in both directions, and the
## Session must accept a ch3 message.

const Proto = preload("res://gamedir/mods/PittMultiplayer/net/proto.gd")
const Codec = preload("res://gamedir/mods/PittMultiplayer/net/codec.gd")
const TransportEnet = preload("res://gamedir/mods/PittMultiplayer/net/transport_enet.gd")
const TransportSteam = preload("res://gamedir/mods/PittMultiplayer/net/transport_steam.gd")


func _pair(cap: int) -> Array:
	var port := 27900 + (Time.get_ticks_msec() % 90)
	var h := TransportEnet.new()
	var c := TransportEnet.new()
	h.lane_cap_emulation = cap
	c.lane_cap_emulation = cap
	h.host({"kind": "enet", "role": "host", "address": "127.0.0.1", "port": port})
	c.join({"kind": "enet", "role": "client", "address": "127.0.0.1", "port": port})
	var conn: Array = []
	h.peer_connected.connect(func(p): conn.append(p))
	var t0 := Time.get_ticks_msec()
	while (conn.is_empty() or not c.is_open()) and Time.get_ticks_msec() - t0 < 3000:
		h.poll()
		c.poll()
		await tree.process_frame
	return [h, c, conn[0] if not conn.is_empty() else 0]


func _frame(ch: int) -> PackedByteArray:
	if ch == Proto.CH_BULK:
		return Codec.encode_chunk(1, 0, PackedByteArray([7, 7]))
	if ch == Proto.CH_AVATAR:
		return Codec.encode_avatar({"slot": 2, "pos": Vector3.ONE})
	return Codec.encode_json({"k": "ents" if ch == Proto.CH_WORLD else "ping", "q": 1})


func test_every_channel_survives_the_lane_limit() -> void:
	var pr: Array = await _pair(4)
	var h = pr[0]
	var c = pr[1]
	var cp: int = pr[2]
	assert_true(cp != 0 and c.is_open(), "connected")
	if cp == 0:
		h.close()
		c.close()
		return
	var got_h: Array = []
	var got_c: Array = []
	h.packet.connect(func(_p, ch, b): got_h.append([ch, b]))
	c.packet.connect(func(_p, ch, b): got_c.append([ch, b]))
	for ch in Proto.CHANNELS:
		h.send(cp, ch, _frame(ch))
		c.send(1, ch, _frame(ch))
	var t0 := Time.get_ticks_msec()
	while (got_h.size() < 4 or got_c.size() < 4) and Time.get_ticks_msec() - t0 < 3000:
		h.poll()
		c.poll()
		await tree.process_frame
	for side in [["client->host", got_h], ["host->client", got_c]]:
		var chans: Array = []
		for g in side[1]:
			chans.append(int(g[0]))
			assert_eq(g[1], _frame(int(g[0])), "%s ch%d payload unchanged" % [side[0], int(g[0])])
		chans.sort()
		assert_eq(chans, [0, 1, 2, 3], "%s logical channels preserved under the 4-lane limit" % side[0])
	h.close()
	c.close()


func test_steam_transport_uses_the_shared_lane() -> void:
	# the Steam transport always maps channels onto lanes 0-2 (CH_WORLD shares lane 1)
	var t := TransportSteam.new()
	assert_true(t.lane_map, "steam transport maps logical channels onto lanes")
	for ch in Proto.CHANNELS:
		assert_true(int(t.lane_of(ch)) <= 2, "ch%d on lane %d (< max_channels - 1 = 3)" % [ch, int(t.lane_of(ch))])
	assert_eq(int(t.lane_of(Proto.CH_AVATAR)), Proto.CH_AVATAR, "the unreliable channel keeps its own lane")
	assert_eq(int(t.lane_of(Proto.CH_CONTROL)), Proto.CH_CONTROL, "ch0 unchanged (hello / reject stay readable across versions)")


func test_shared_lane_rejects_a_bad_tag() -> void:
	var t := TransportEnet.new()
	t.lane_map = true
	var r: Dictionary = t.unmap_lane(1, PackedByteArray([9, 0, 1]))
	assert_eq(int(r.ch), -1, "unknown logical channel on the shared lane is refused")
	r = t.unmap_lane(1, PackedByteArray())
	assert_eq(int(r.ch), -1, "empty shared-lane packet is refused")
	r = t.unmap_lane(1, PackedByteArray([Proto.CH_WORLD, 5]))
	assert_true(int(r.ch) == Proto.CH_WORLD and r.bytes == PackedByteArray([5]), "tag stripped")
