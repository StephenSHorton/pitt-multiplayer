extends "transport.gd"
## In-process transport for headless tests: host + clients in one process share
## a Hub. Deterministic conditioning: latency_ms, jitter_ms, loss (unreliable
## channel only), duplicate (unreliable only), reorder (unreliable only) and
## stall(peer, ms), channel_delay_ms. Reliable channels stay ordered per
## (sender, channel) but not across channels.
## target: {kind:"loopback", role, hub: Hub}   (the hub is passed by reference)


class Hub extends RefCounted:
	var latency_ms := 0
	var jitter_ms := 0
	var loss := 0.0
	var duplicate := 0.0
	var reorder := 0.0
	var channel_delay_ms: Dictionary = {}   # channel -> extra ms (channels out of step)
	var rng := RandomNumberGenerator.new()
	var host_ep = null                 # the host endpoint (peer 1)
	var clients: Dictionary = {}       # peer id -> endpoint
	var next_peer := 2
	var stalls: Dictionary = {}        # peer id -> until ms
	var now_override := -1             # tests may drive time
	var delivered := 0
	var dropped := 0

	func _init(seed_value: int = 1234) -> void:
		rng.seed = seed_value

	func now() -> int:
		return now_override if now_override >= 0 else Time.get_ticks_msec()

	func stall(peer: int, ms: int) -> void:
		stalls[peer] = now() + ms

	func endpoint(peer: int):
		if peer == 1:
			return host_ep
		return clients.get(peer, null)

	## Queues a packet from -> to (to = 0: everyone else).
	func route(from: int, to: int, channel: int, bytes: PackedByteArray) -> void:
		var targets: Array = []
		if to == 0:
			if from != 1:
				targets = [1]
			else:
				targets = clients.keys()
		else:
			targets = [to]
		for t in targets:
			var ep = endpoint(t)
			if ep == null:
				continue
			var reliable := channel != 2
			if not reliable and loss > 0.0 and rng.randf() < loss:
				dropped += 1
				continue
			var delay := latency_ms + int(channel_delay_ms.get(channel, 0))
			if jitter_ms > 0:
				delay += rng.randi_range(-jitter_ms, jitter_ms)
			if not reliable and reorder > 0.0 and rng.randf() < reorder:
				delay += rng.randi_range(1, maxi(latency_ms, 20))
			var at := now() + maxi(delay, 0)
			if reliable:
				var key := "%d:%d" % [from, channel]
				at = maxi(at, int(ep.last_at.get(key, 0)))
				ep.last_at[key] = at
			ep.inbox.append({"at": at, "from": from, "ch": channel, "bytes": bytes.duplicate(), "seq": ep.next_seq})
			ep.next_seq += 1
			if not reliable and duplicate > 0.0 and rng.randf() < duplicate:
				ep.inbox.append({"at": at + 1, "from": from, "ch": channel, "bytes": bytes.duplicate(), "seq": ep.next_seq})
				ep.next_seq += 1


var hub: Hub = null
var my_peer := 0
var inbox: Array = []
var last_at: Dictionary = {}
var next_seq := 0
var _events: Array = []    # pending connect/disconnect notifications [{at, kind, peer}]


func kind() -> String:
	return "loopback"


func host(target: Dictionary) -> Error:
	role = "host"
	hub = target.get("hub", null)
	if hub == null:
		return ERR_INVALID_PARAMETER
	if hub.host_ep != null:
		return ERR_ALREADY_IN_USE
	hub.host_ep = self
	my_peer = 1
	_open = true
	opened.emit.call_deferred()
	return OK


func join(target: Dictionary) -> Error:
	role = "client"
	hub = target.get("hub", null)
	if hub == null:
		return ERR_INVALID_PARAMETER
	my_peer = hub.next_peer
	hub.next_peer += 1
	hub.clients[my_peer] = self
	_connecting = true
	_events.append({"at": hub.now() + hub.latency_ms, "kind": "self_connected"})
	if hub.host_ep != null:
		hub.host_ep._events.append({"at": hub.now() + hub.latency_ms, "kind": "connected", "peer": my_peer})
	else:
		_events.append({"at": hub.now() + hub.latency_ms, "kind": "self_failed"})
	return OK


func local_peer_id() -> int:
	return my_peer


func platform_id_of(peer_id: int) -> String:
	return "loop:%d" % peer_id


func poll() -> void:
	if hub == null or _closed:
		return
	var now := hub.now()
	# connection events
	var keep: Array = []
	for e in _events.duplicate():
		if int(e.at) > now:
			keep.append(e)
			continue
		match String(e.kind):
			"self_connected":
				if _connecting:
					_connecting = false
					_open = true
					opened.emit()
					peer_connected.emit(1)
			"self_failed":
				close("connect_failed")
				return
			"connected":
				peer_connected.emit(int(e.peer))
			"disconnected":
				peer_disconnected.emit(int(e.peer))
			"host_gone":
				close("host_gone")
				return
	_events = keep
	if _closed:
		return
	if int(hub.stalls.get(my_peer, 0)) > now:
		return
	if inbox.is_empty():
		return
	inbox.sort_custom(func(a, b): return int(a.at) < int(b.at) or (int(a.at) == int(b.at) and int(a.seq) < int(b.seq)))
	while not inbox.is_empty() and int(inbox[0].at) <= now and not _closed:
		var p: Dictionary = inbox.pop_front()
		stats.rx_bytes += p.bytes.size()
		stats.rx_packets += 1
		_count(int(p.ch), p.bytes.size(), false)
		meter(int(p.from), int(p.ch), p.bytes.size(), false)
		hub.delivered += 1
		packet.emit(int(p.from), int(p.ch), p.bytes)


func send(peer_id: int, channel: int, bytes: PackedByteArray) -> Error:
	if hub == null or _closed or not _open:
		return ERR_UNCONFIGURED
	if role == "client" and peer_id != 1 and peer_id != 0:
		return ERR_INVALID_PARAMETER
	hub.route(my_peer, peer_id if role == "host" else 1, channel, bytes)
	stats.tx_bytes += bytes.size()
	stats.tx_packets += 1
	_count(channel, bytes.size(), true)
	meter(peer_id if role == "host" else 1, channel, bytes.size(), true)
	return OK


func kick(peer_id: int) -> void:
	if role != "host" or hub == null:
		return
	var ep = hub.clients.get(peer_id, null)
	if ep != null:
		ep._events.append({"at": hub.now(), "kind": "host_gone"})
		hub.clients.erase(peer_id)
	_events.append({"at": hub.now(), "kind": "disconnected", "peer": peer_id})


func close(reason: String = "left") -> void:
	if _closed:
		return
	if hub != null:
		var at := hub.now() + hub.latency_ms
		if role == "host":
			if hub.host_ep == self:
				hub.host_ep = null
			for p in hub.clients:
				hub.clients[p]._events.append({"at": at, "kind": "host_gone"})
		else:
			hub.clients.erase(my_peer)
			if hub.host_ep != null:
				hub.host_ep._events.append({"at": at, "kind": "disconnected", "peer": my_peer})
	_closed = true
	_open = false
	_connecting = false
	closed.emit(reason)
