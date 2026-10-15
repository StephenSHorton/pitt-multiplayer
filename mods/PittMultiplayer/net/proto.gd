extends RefCounted
## Wire protocol constants and the inbound validator (MP-DESIGN 2.2-2.4,
## MP2-DESIGN 2). Every JSON message is {"k": kind, "sid": session id, "q": seq, ...body}.
## The validator drops (and counts) anything that is not whitelisted for the
## channel, direction and handshake state, carries a stale sid, repeats an old
## seq (per channel: ch0 and ch3 have their own sequence), is too large or
## exceeds the per-peer rate limits.

const PROTO := 2

# channels (2.2)
const CH_CONTROL := 0   # reliable ordered: control + the one ordered host->client state stream
const CH_BULK := 1      # reliable ordered: snapshot + world-snapshot chunks
const CH_AVATAR := 2    # unreliable: avatar frames (2), body frames (4, H->C), held frames (5, C->H)
const CH_WORLD := 3     # reliable ordered: MP2 world lifecycle (ents, meta, own*, fx, ...)
const CH_MP2 := CH_WORLD
const CHANNELS := 4

# frame kinds (byte 0)
const FRAME_JSON := 0
const FRAME_ZJSON := 1
const FRAME_AVATAR := 2
const FRAME_CHUNK := 3
const FRAME_BODIES := 4
const FRAME_HELD := 5

# caps (2.3, MP2 2.5)
const MAX_C2H_JSON := 16 * 1024
const MAX_H2C_JSON := 256 * 1024
const MAX_C2H_WORLD_JSON := 4 * 1024
const MAX_H2C_WORLD_JSON := 64 * 1024
const CHUNK_SIZE := 32 * 1024
const MAX_SNAPSHOT_RAW := 32 * 1024 * 1024
const ZSTD_THRESHOLD := 1024

# message kinds by direction (ch0)
const C2H := ["hello", "bye", "ping", "pong", "join_req", "ready", "cmd", "world_req", "netq"]
const H2C := ["welcome", "reject", "bye", "roster", "session", "ping", "pong", "snap_begin", "snap_end", "res",
	"econ", "phase", "unlock", "hole", "toast", "rules", "grant", "wsnap_begin", "wsnap_end", "combo"]
## ch3 (MP2 2.4): every kind of every stream, so a missing module only means its
## messages are dropped and counted
const C2H_WORLD := ["own_req", "own_rel", "own_equip", "own_unequip", "interact", "tool_in"]
const H2C_WORLD := ["ents", "meta", "own", "fx", "pimp", "fixture_spawn"]
## raw (non-JSON) frames on CH_AVATAR by direction
const RAW_C2H := [FRAME_AVATAR, FRAME_HELD]
const RAW_H2C := [FRAME_AVATAR, FRAME_BODIES]
## allowed before the handshake completed
const PRE_HANDSHAKE_C2H := ["hello", "bye", "ping", "pong"]
const PRE_HANDSHAKE_H2C := ["welcome", "reject", "bye", "ping", "pong"]

const REJECT_REASONS := ["version", "mods", "full", "ending", "protocol"]
const BYE_REASONS := ["left", "host_left", "kicked", "ending", "error"]

# rate limits per peer (per second, burst); MP2 2.5 adds interact, own, held
const RATE := {"cmd": [30.0, 60.0], "avatar": [40.0, 80.0], "control": [20.0, 40.0],
	"interact": [20.0, 40.0], "own": [10.0, 20.0], "held": [40.0, 80.0]}
const KICK_FACTOR := 3.0
const KICK_WINDOW_S := 5

const RING_CAP := 200
## first-drop warnings: at most WARN_BURST per WARN_WINDOW_MS (the rest are only counted)
const WARN_BURST := 8
const WARN_WINDOW_MS := 10000


## Per-peer inbound state: seq per channel, rate buckets, drop counters.
class PeerIn extends RefCounted:
	var last_q := -1
	var last_q3 := -1
	var tokens := {}
	var last_refill_ms := 0
	var window: Array = []     # per-second counts [{"t": sec, "cmd": n, ...}]
	var drops := 0

	func _init() -> void:
		for c in RATE:
			tokens[c] = RATE[c][1]
		last_refill_ms = Time.get_ticks_msec()


var role := ""          # "host" | "client": which side this validator runs on
var sid := ""           # the session id messages must carry ("" until known)
var peers: Dictionary = {}   # peer id -> PeerIn
var drop_counts: Dictionary = {}
## full reason ("kind_not_allowed:ents") -> count
var drop_reasons: Dictionary = {}
## Callable(text: String): called once per (reason, kind) the first time it is dropped
var on_first_drop: Callable = Callable()
var warn_suppressed := 0
var _warned: Dictionary = {}
var _warn_window_ms := 0
var _warn_n := 0
var ring: Array = []
var rate_limits_enabled := true
## module kinds (MP2 10.1), on top of the constants above
var extra_c2h: Array = []
var extra_h2c: Array = []
var extra_c2h_world: Array = []
var extra_h2c_world: Array = []
var extra_raw_c2h: Array = []


func _init(p_role: String = "") -> void:
	role = p_role


## Whitelists a module's msg_kinds() {"ch3_c2h", "ch3_h2c", "ch0_c2h", "ch0_h2c", "raw_c2h"}.
func add_kinds(kinds: Dictionary) -> void:
	_merge(extra_c2h, kinds.get("ch0_c2h", []))
	_merge(extra_h2c, kinds.get("ch0_h2c", []))
	_merge(extra_c2h_world, kinds.get("ch3_c2h", []))
	_merge(extra_h2c_world, kinds.get("ch3_h2c", []))
	_merge(extra_raw_c2h, kinds.get("raw_c2h", []))


static func _merge(into: Array, more) -> void:
	if typeof(more) != TYPE_ARRAY:
		return
	for k in more:
		if not (k in into):
			into.append(k)


func reset_peer(peer: int) -> void:
	peers[peer] = PeerIn.new()


func forget_peer(peer: int) -> void:
	peers.erase(peer)


func _peer(peer: int) -> PeerIn:
	if not peers.has(peer):
		peers[peer] = PeerIn.new()
	return peers[peer]


## Kinds this side may receive in the given handshake state (ch0).
func allowed_kinds(handshaken: bool) -> Array:
	if role == "host":
		return C2H + extra_c2h if handshaken else PRE_HANDSHAKE_C2H
	return H2C + extra_h2c if handshaken else PRE_HANDSHAKE_H2C


## Kinds this side may receive on CH_WORLD (always after the handshake).
func allowed_world_kinds() -> Array:
	if role == "host":
		return C2H_WORLD + extra_c2h_world
	return H2C_WORLD + extra_h2c_world


## Raw frame kinds this side may receive on CH_AVATAR.
func allowed_raw(kind: int) -> bool:
	if role == "host":
		return kind in RAW_C2H or kind in extra_raw_c2h
	return kind in RAW_H2C


func max_json() -> int:
	return MAX_C2H_JSON if role == "host" else MAX_H2C_JSON


## Rate class of an inbound JSON kind (host side).
static func rate_class(k: String) -> String:
	if k == "cmd":
		return "cmd"
	if k == "interact" or k == "tool_in":
		return "interact"
	if k.begins_with("own"):
		return "own"
	return "control"


## Returns "" when the JSON message may be handled, else the drop reason
## (also counted). handshaken: the sender completed hello/welcome.
## size: the encoded frame size (ch3 C->H messages are capped at 4 KB).
func check_json(peer: int, channel: int, msg: Dictionary, handshaken: bool, size: int = 0) -> String:
	var k = msg.get("k", null)
	if typeof(k) != TYPE_STRING:
		return _drop("no_kind", peer, msg)
	if channel == CH_WORLD:
		if not handshaken:
			return _drop("kind_not_allowed:%s" % k, peer, msg)
		if not (k in allowed_world_kinds()):
			return _drop("kind_not_allowed:%s" % k, peer, msg)
		if role == "host" and size > MAX_C2H_WORLD_JSON + 8:
			return _drop("too_large", peer, msg)
	elif channel != CH_CONTROL:
		return _drop("wrong_channel", peer, msg)
	elif not (k in allowed_kinds(handshaken)):
		return _drop("kind_not_allowed:%s" % k, peer, msg)
	# sid: checked once the sender is handshaken (the client learns it from
	# welcome; hello and the pre-handshake kinds carry none yet)
	var msid := String(msg.get("sid", ""))
	if handshaken:
		if sid == "" or msid != sid:
			return _drop("stale_sid", peer, msg)
	elif role == "client" and k == "welcome" and msid == "":
		return _drop("welcome_without_sid", peer, msg)
	# per-direction, per-channel sequence on the ordered channels
	var pi := _peer(peer)
	if msg.has("q"):
		var q := int(msg.q)
		if channel == CH_WORLD:
			if q <= pi.last_q3:
				return _drop("old_seq", peer, msg)
			pi.last_q3 = q
		else:
			if q <= pi.last_q:
				return _drop("old_seq", peer, msg)
			pi.last_q = q
	if role == "host" and rate_limits_enabled:
		var cls := rate_class(String(k))
		if not _take(pi, cls):
			return _drop("rate:%s" % cls, peer, msg)
	_log_ring("rx", peer, msg)
	return ""


## Rate limit for avatar frames (host side). "" or a drop reason.
func check_avatar(peer: int) -> String:
	if role != "host" or not rate_limits_enabled:
		return ""
	if not _take(_peer(peer), "avatar"):
		return _drop("rate:avatar", peer, {"k": "<avatar>"})
	return ""


## Raw MP2 frames (host side: held frames, 40/s burst 80). "" or a drop reason.
func check_raw(peer: int, kind: int) -> String:
	if not allowed_raw(kind):
		return _drop("raw_not_allowed:%d" % kind, peer, {"k": "<raw %d>" % kind})
	if role != "host" or not rate_limits_enabled:
		return ""
	if kind == FRAME_HELD and not _take(_peer(peer), "held"):
		return _drop("rate:held", peer, {"k": "<held>"})
	return ""


## True when the peer kept sending more than KICK_FACTOR x the allowed rate for
## KICK_WINDOW_S consecutive seconds.
func should_kick(peer: int) -> bool:
	if not peers.has(peer):
		return false
	var pi: PeerIn = peers[peer]
	var now_s := int(Time.get_ticks_msec() / 1000)
	var by_t := {}
	for b in pi.window:
		by_t[int(b.t)] = b
	# the last KICK_WINDOW_S complete seconds must all be over the limit
	for i in range(1, KICK_WINDOW_S + 1):
		var b = by_t.get(now_s - i, null)
		if b == null:
			return false
		var over := false
		for c in RATE:
			if float(b.get(c, 0)) >= float(RATE[c][0]) * KICK_FACTOR:
				over = true
		if not over:
			return false
	return true


func _take(pi: PeerIn, cls: String) -> bool:
	var now := Time.get_ticks_msec()
	var dt := float(now - pi.last_refill_ms) / 1000.0
	pi.last_refill_ms = now
	for c in RATE:
		pi.tokens[c] = minf(float(RATE[c][1]), float(pi.tokens[c]) + dt * float(RATE[c][0]))
	# per-second received counts (for should_kick)
	var sec := int(now / 1000)
	if pi.window.is_empty() or int(pi.window.back().t) != sec:
		pi.window.append({"t": sec})
		if pi.window.size() > KICK_WINDOW_S + 2:
			pi.window.pop_front()
	var b: Dictionary = pi.window.back()
	b[cls] = int(b.get(cls, 0)) + 1
	if float(pi.tokens[cls]) < 1.0:
		return false
	pi.tokens[cls] = float(pi.tokens[cls]) - 1.0
	return true


func _drop(reason: String, peer: int, msg: Dictionary) -> String:
	var key := reason.get_slice(":", 0)
	drop_counts[key] = int(drop_counts.get(key, 0)) + 1
	drop_reasons[reason] = int(drop_reasons.get(reason, 0)) + 1
	var wk := "%s|%s" % [reason, String(msg.get("k", "?"))]
	if not _warned.has(wk) and on_first_drop.is_valid():
		_warned[wk] = true
		var now := Time.get_ticks_msec()
		if now - _warn_window_ms >= WARN_WINDOW_MS:
			_warn_window_ms = now
			_warn_n = 0
		_warn_n += 1
		if _warn_n <= WARN_BURST:
			on_first_drop.call("protocol drop %s (kind %s, peer %d, role %s): first of its kind" % [reason,
				String(msg.get("k", "?")), peer, role])
		else:
			warn_suppressed += 1
	if peers.has(peer):
		peers[peer].drops += 1
	_log_ring("drop:" + reason, peer, msg)
	return reason


func _log_ring(dir: String, peer: int, msg: Dictionary) -> void:
	ring.append({"t": Time.get_ticks_msec(), "dir": dir, "peer": peer, "k": String(msg.get("k", "?")),
		"q": msg.get("q", null)})
	if ring.size() > RING_CAP:
		ring.pop_front()


func log_tx(peer: int, msg: Dictionary) -> void:
	_log_ring("tx", peer, msg)


static func new_sid() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return "%08x%08x" % [rng.randi(), rng.randi()]
