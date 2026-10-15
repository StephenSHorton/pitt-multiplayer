extends RefCounted
## Transport interface (MP-DESIGN 2.1) plus the shared implementation over a
## Godot MultiplayerPeer used with the RAW packet API (set_target_peer,
## transfer_channel, transfer_mode, put_packet / get_packet). The peer is never
## assigned to the SceneTree's multiplayer: no RPCs, no synchronizers, every
## inbound byte goes through our validator. Star topology: clients talk only to
## the host (peer 1).
##
## Subclasses: transport_enet.gd (dev/tests), transport_steam.gd (real play),
## transport_loopback.gd (in-process, headless tests; overrides everything).

const Proto = preload("proto.gd")

signal peer_connected(peer_id: int)
signal peer_disconnected(peer_id: int)
signal packet(peer_id: int, channel: int, bytes: PackedByteArray)
signal opened()
signal closed(reason: String)

var role := ""                 # "host" | "client"
var stats := {"tx_bytes": 0, "rx_bytes": 0, "tx_packets": 0, "rx_packets": 0, "bad_lane": 0}
## Cumulative per logical channel: ch -> [tx_packets, tx_bytes, rx_packets, rx_bytes].
var ch_stats: Dictionary = {}
var _peer: MultiplayerPeer = null
var _open := false
var _closed := false
var _connecting := false
var _connect_started_ms := 0
var connect_timeout_ms := 10000
## Dev / tests (ENet): emulates the bundled GodotSteam 4.19.1 lane limit. Its
## SteamPacketPeer.send() moves every channel >= max_channels - 1 to lane 0
## (an off-by-one: with steam/multiplayer_peer/max_channels=4 only lanes 0-2
## keep their channel). 0 = off.
var lane_cap_emulation := 0
## Logical channel -> wire lane (v0.2.1). GodotSteam only keeps lanes 0-2 (see
## lane_cap_emulation), so CH_WORLD shares lane 1 with CH_BULK; every packet on
## the shared lane starts with one byte, its logical channel. ch0 and ch2 are
## unchanged on the wire (a 0.2.0 peer still reads hello / reject).
const SHARED_LANE := 1
const LANES := [0, 1, 2, 1]
var lane_map := true


func kind() -> String:
	return "base"


## target: LobbyService.transport_target(). OK or an Error.
func host(target: Dictionary) -> Error:
	role = "host"
	var err := _create_host(target)
	if err != OK:
		_peer = null
		return err
	_wire_peer()
	_open = true
	opened.emit.call_deferred()
	return OK


func join(target: Dictionary) -> Error:
	role = "client"
	var err := _create_client(target)
	if err != OK:
		_peer = null
		return err
	_wire_peer()
	_connecting = true
	_connect_started_ms = Time.get_ticks_msec()
	return OK


func is_open() -> bool:
	return _open and not _closed


func local_peer_id() -> int:
	if _peer == null:
		return 0
	return _peer.get_unique_id()


func platform_id_of(peer_id: int) -> String:
	return "%s:%d" % [kind(), peer_id]


## Called every frame by the Session (PROCESS_MODE_ALWAYS, wall clock).
func poll() -> void:
	if _peer == null or _closed:
		return
	_flush_conditioned()
	_peer.poll()
	if _peer == null or _closed:
		return
	var st := _peer.get_connection_status()
	if role == "client":
		if _connecting and st == MultiplayerPeer.CONNECTION_CONNECTED:
			_connecting = false
			_open = true
			opened.emit()
		elif _connecting and (st == MultiplayerPeer.CONNECTION_DISCONNECTED \
				or Time.get_ticks_msec() - _connect_started_ms > connect_timeout_ms):
			close("connect_failed")
			return
		elif _open and st == MultiplayerPeer.CONNECTION_DISCONNECTED:
			close("host_gone")
			return
	while _peer != null and not _closed and _peer.get_available_packet_count() > 0:
		var from := _peer.get_packet_peer()
		var ch := _peer.get_packet_channel()
		var bytes := _peer.get_packet()
		stats.rx_bytes += bytes.size()
		stats.rx_packets += 1
		var u := unmap_lane(ch, bytes)
		if int(u.ch) < 0:
			stats.bad_lane += 1
			continue
		ch = int(u.ch)
		bytes = u.bytes
		_count(ch, bytes.size(), false)
		meter(from, ch, bytes.size(), false)
		packet.emit(from, ch, bytes)


## Optional send-side conditioning (dev / two-instance tests over real ENet):
## {latency_ms, jitter_ms, loss, channel_delay_ms: {channel: ms}} - loss applies
## to the unreliable channel only, reliable channels keep their order per
## channel; channel_delay_ms delays one channel against the others (a reliable
## packet that had to be retransmitted), so channels arrive out of step.
func set_conditioning(cond: Dictionary) -> void:
	_cond = cond.duplicate()
	_cond_rng.seed = int(cond.get("seed", 99))


var _cond: Dictionary = {}
var _cond_rng := RandomNumberGenerator.new()
var _cond_queue: Array = []    # [{at, peer, ch, bytes}]
var _cond_last: Dictionary = {}
var _cond_n := 0


## peer_id 0 = every connected peer. The transfer mode follows the channel.
func send(peer_id: int, channel: int, bytes: PackedByteArray) -> Error:
	if _peer == null or _closed or not _open:
		return ERR_UNCONFIGURED
	# while conditioned packets are still queued, later ones queue behind them
	# (conditioning switched off mid-flight must not reorder a reliable channel)
	if not _cond.is_empty() or not _cond_queue.is_empty():
		if channel == Proto.CH_AVATAR and float(_cond.get("loss", 0.0)) > 0.0 and _cond_rng.randf() < float(_cond.loss):
			return OK
		var delay := int(_cond.get("latency_ms", 0))
		var cd = _cond.get("channel_delay_ms", {})
		if typeof(cd) == TYPE_DICTIONARY:
			delay += int(cd.get(channel, cd.get(str(channel), 0)))
		var j := int(_cond.get("jitter_ms", 0))
		if j > 0:
			delay += _cond_rng.randi_range(-j, j)
		var at := Time.get_ticks_msec() + maxi(delay, 0)
		if channel != Proto.CH_AVATAR:
			var key := "%d:%d" % [peer_id, channel]
			at = maxi(at, int(_cond_last.get(key, 0)))
			_cond_last[key] = at
		_cond_n += 1
		_cond_queue.append({"at": at, "n": _cond_n, "peer": peer_id, "ch": channel, "bytes": bytes})
		return OK
	return _put(peer_id, channel, bytes)


func _flush_conditioned() -> void:
	if _cond_queue.is_empty():
		return
	var now := Time.get_ticks_msec()
	var keep: Array = []
	# sort_custom is not stable: equal times keep their send order through n
	_cond_queue.sort_custom(func(a, b): return int(a.at) < int(b.at) or (int(a.at) == int(b.at) and int(a.n) < int(b.n)))
	for e in _cond_queue:
		if int(e.at) <= now:
			_put(int(e.peer), int(e.ch), e.bytes)
		else:
			keep.append(e)
	_cond_queue = keep


func _put(peer_id: int, channel: int, bytes: PackedByteArray) -> Error:
	if _peer == null or _closed:
		return ERR_UNCONFIGURED
	var lane := lane_of(channel)
	var out := bytes
	if lane_map and lane == SHARED_LANE:
		out = PackedByteArray([channel])
		out.append_array(bytes)
	if lane_cap_emulation > 0 and lane >= lane_cap_emulation - 1:
		lane = 0
	_peer.set_target_peer(peer_id)
	_peer.transfer_channel = lane
	_peer.transfer_mode = mode_for(channel)
	var err := _peer.put_packet(out)
	if err == OK:
		stats.tx_bytes += out.size()
		stats.tx_packets += 1
		_count(channel, bytes.size(), true)
		meter(peer_id, channel, bytes.size(), true)
	return err


func lane_of(channel: int) -> int:
	if not lane_map or channel < 0 or channel >= LANES.size():
		return channel
	return LANES[channel]


## Inbound lane + bytes -> {ch: logical channel (-1 = refused), bytes}.
func unmap_lane(lane: int, bytes: PackedByteArray) -> Dictionary:
	if not lane_map or lane != SHARED_LANE:
		return {"ch": lane, "bytes": bytes}
	if bytes.size() < 2:
		return {"ch": -1, "bytes": bytes}
	var ch := int(bytes[0])
	if ch < LANES.size() and LANES[ch] == SHARED_LANE:
		return {"ch": ch, "bytes": bytes.slice(1)}
	return {"ch": -1, "bytes": bytes}


func _count(channel: int, n: int, tx: bool) -> void:
	var c: Array = ch_stats.get(channel, [0, 0, 0, 0])
	if tx:
		c[0] += 1
		c[1] += n
	else:
		c[2] += 1
		c[3] += n
	ch_stats[channel] = c


static func mode_for(channel: int) -> int:
	if channel == Proto.CH_AVATAR:
		return MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
	return MultiplayerPeer.TRANSFER_MODE_RELIABLE


# ------------------------------------------------------------------ byte meters (MP2 8)

const METER_RING := 60
## peer -> {sec, cur: {ch: [tx_bytes, rx_bytes, tx_pkts]}, last: {...}, ring: [{t, tx, rx}]}
var _meter: Dictionary = {}


func meter(peer_id: int, channel: int, n: int, tx: bool) -> void:
	var sec := int(Time.get_ticks_msec() / 1000)
	var m = _meter.get(peer_id, null)
	if m == null:
		m = {"sec": sec, "cur": {}, "last": {}, "ring": []}
		_meter[peer_id] = m
	if int(m.sec) != sec:
		_meter_roll(m, sec)
	var c: Array = m.cur.get(channel, [0, 0, 0])
	if tx:
		c[0] += n
		c[2] += 1
	else:
		c[1] += n
	m.cur[channel] = c


func _meter_roll(m: Dictionary, sec: int) -> void:
	var tx := 0
	var rx := 0
	for ch in m.cur:
		tx += int(m.cur[ch][0])
		rx += int(m.cur[ch][1])
	m.ring.append({"t": int(m.sec), "tx": tx, "rx": rx, "ch": m.cur.duplicate(true)})
	# seconds without traffic count as zero windows
	for s in range(int(m.sec) + 1, mini(sec, int(m.sec) + METER_RING)):
		m.ring.append({"t": s, "tx": 0, "rx": 0, "ch": {}})
	while m.ring.size() > METER_RING:
		m.ring.pop_front()
	m.last = m.cur if sec == int(m.sec) + 1 else {}
	m.cur = {}
	m.sec = sec


## {peer: {ch: {tx_bps, rx_bps, tx_pps}}} of the last complete 1 s window.
func window_stats() -> Dictionary:
	var sec := int(Time.get_ticks_msec() / 1000)
	var out := {}
	for p in _meter:
		var m: Dictionary = _meter[p]
		if int(m.sec) != sec:
			_meter_roll(m, sec)
		var d := {}
		for ch in m.last:
			var c: Array = m.last[ch]
			d[ch] = {"tx_bps": int(c[0]), "rx_bps": int(c[1]), "tx_pps": int(c[2])}
		out[p] = d
	return out


## Per-second totals of the last complete windows for one peer: [{t, tx, rx, ch}].
func meter_history(peer_id: int) -> Array:
	var m = _meter.get(peer_id, null)
	if m == null:
		return []
	var sec := int(Time.get_ticks_msec() / 1000)
	if int(m.sec) != sec:
		_meter_roll(m, sec)
	return m.ring.duplicate(true)


## Host: drops one client.
func kick(peer_id: int) -> void:
	if _peer != null and not _closed and role == "host":
		_peer.disconnect_peer(peer_id)


## Idempotent. Emits closed(reason) once.
func close(reason: String = "left") -> void:
	if _closed:
		return
	_closed = true
	_open = false
	_connecting = false
	if _peer != null:
		_peer.close()
	_peer = null
	closed.emit(reason)


func _wire_peer() -> void:
	_peer.peer_connected.connect(func(id: int): _on_peer_connected(id))
	_peer.peer_disconnected.connect(func(id: int): peer_disconnected.emit(id))


func _on_peer_connected(id: int) -> void:
	peer_connected.emit(id)


# ------------------------------------------------------------------ subclass hooks

func _create_host(_target: Dictionary) -> Error:
	return ERR_UNAVAILABLE


func _create_client(_target: Dictionary) -> Error:
	return ERR_UNAVAILABLE
