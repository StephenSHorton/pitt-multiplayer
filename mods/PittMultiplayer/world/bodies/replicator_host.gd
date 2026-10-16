extends RefCounted
## Host replicator (MP2-DESIGN 3.3). Tracks every pooled entity (PittAPI
## entity.spawned / despawned) and every fixture, batches the lifecycle on ch3
## (ents + meta, at most every 33 ms) and streams body state on ch2 (frame
## kind 4) to each in-game peer at 30 Hz through a per-peer priority
## accumulator and an adaptive byte budget.
##   - awake set from RigidBody3D.sleeping_state_changed (+ a round-robin scan
##     of resting bodies), so thousands of sleeping bodies cost almost nothing
##   - a body that comes to rest is sent with SLEEP, repeated at 250 ms, 1 s and
##     3 s, then only the rest refresh (one resting body per peer per tick)
##   - records of a body are never sent to the peer that owns it (GRAB)
##   - host_follow: a body held by a client follows the owner's held stream as a
##     frozen kinematic body 50 ms behind; host_release restores it exactly
##   - per send tick the work shared by every peer is done once (sampling, the
##     peer-independent weight, the encoded record bytes); per peer only the
##     distance weight, the accumulator and a native-sorted top-k remain
##   - a peer skipped by the per-tick CPU cap (or served every other tick under
##     overload) gets the bytes of the ticks it missed at its next serve, so its
##     byte rate stays at its budget; stats() reports the measured eff_bps
##   - the budget counts every packet's header plus a transport overhead
##     estimate, and HOST_UPLOAD_BPS caps the sum over all peers

const Codec = preload("../../net/codec.gd")
const Priority = preload("priority.gd")
const Budget = preload("budget.gd")
const WorldSnapshot = preload("world_snapshot.gd")
const EntityMeta = preload("entity_meta.gd")
const MetaSync = preload("meta_sync.gd")

const SEND_HZ := 30.0
const SEND_INTERVAL_MS := 33
const LIFECYCLE_MS := 33
const SLEEP_REPEATS_MS := [250, 1000, 3000]
const TOMBSTONE_MS := 5000
const SNAP_JUMP := 4.0
const BOOST_SPAWN_MS := 2000
const SEL_BUDGET_USEC := 3000
const REST_SCAN_PER_TICK := 40        # minimum; scaled so a lap of every tracked body takes about 1 s
const REST_SCAN_LAP_TICKS := 30
const REST_ROT_DOT := 0.99995         # |q.q0| below this (about 1.1 deg): rotated in place
const SLEEP_SHARE := 0.4              # SLEEP sends take at most this share of a tick while bodies are awake
const PKT_OVERHEAD := 40              # per packet: UDP/IP + transport framing (estimate)
const HOST_UPLOAD_BPS := 400000       # body frames to all peers together (about 3.2 Mbit/s)
const MAX_SLOTS := 32
const BANK_MAX_TICKS := 3
const META_REST_PER_TICK := 20
const FOLLOW_DELAY_MS := 50
const FOLLOW_KEEP := 12
## a follower frame's time is the sender's spacing (held frame t_ms) laid over its
## arrival, at most this far past it (frames that arrive in bursts still play evenly)
const FOLLOW_SPREAD_MS := 100
## the follower steers toward the interpolated pose with bounded acceleration, so a
## late burst of frames bends its path instead of jerking it (and what rests in it)
const FOLLOW_MAX_ACCEL := 40.0     # m/s^2 (a hard lift reaches about 25)
const FOLLOW_GAIN := 12.0          # 1/s, position error -> velocity
const FOLLOW_SNAP_M := 1.0
const ENTS_ROWS_PER_MSG := 200
const META_ROWS_PER_MSG := 300
const READY_RESEND_MS := 15000
const OVERLOAD_RATIO := 0.8
const OVERLOAD_HOLD_MS := 5000
const OVERLOAD_TOAST_MS := 60000


class Ent extends RefCounted:
	var eid := 0
	var ref: WeakRef = null
	var kind := "pooled"          # pooled | fixture_body | fixture
	var pool_id := ""
	var pool_idx := -1
	var key := ""
	var body := true               # streams a transform (pooled / fixture_body)
	var hidden := false
	var resting := false
	var moved_ms := 0
	var owner := 1
	var owner_kind := ""
	var epoch := 0
	var boost_until := 0
	var snap_peers: Dictionary = {}
	var p := Vector3.ZERO
	var q := Quaternion.IDENTITY
	var l := Vector3.ZERO
	var a := Vector3.ZERO
	var has_sample := false
	var meta_kinds: Array = []
	var meta_last: Dictionary = {}
	var meta_next: Dictionary = {}
	var meta_force := false
	var follow_peer := 0
	var follow: Array = []
	var follow_has := false
	var follow_out := Vector3.ZERO
	var follow_v := Vector3.ZERO
	var saved_freeze := false
	var saved_mode := 0
	var sleep_cb: Callable
	var vis_cb: Callable
	var kw := 1.0                  # kind weight as seen by a non-owner peer (Priority.kind_w)
	var ai := -1                   # awake index into every PeerState.accs (-1 = resting)

	func node() -> Node3D:
		var n = ref.get_ref() if ref != null else null
		return n if n != null and is_instance_valid(n) else null

	func flags_base() -> int:
		var f := 0
		if owner_kind != "":
			f |= Codec.RF_HELD
		if owner_kind == "equipped":
			f |= Codec.RF_NOCOLLIDE
		return f


class PeerState extends RefCounted:
	var peer := 0
	var slot := 0
	var sleep_sched: Dictionary = {}   # eid -> {t0, n}
	var sleep_next_ms := 0             # earliest due SLEEP send (0 = walk the schedule)
	var accs := PackedFloat32Array()   # send priority accumulator by Ent.ai
	var rest_keys: Array = []
	var rest_i := 0
	var seq := 0
	var budget = null
	var last_tick_ms := 0
	var ready_ms := 0
	var tx_records := 0
	var tx_bytes := 0
	var tx_packets := 0
	var served_ms := 0
	var win_start_ms := 0
	var win_bytes := 0
	var eff_bps := 0


var bodies = null                 # the module (session, api, adapter, meta_sync, signals)
var ents: Dictionary = {}         # eid -> Ent
var _fclock := 0.0                # follower clock (ms), see _follow_now
var tombs: Dictionary = {}        # eid -> until ms
var awake: Dictionary = {}        # eid -> true
var peers: Dictionary = {}        # peer -> PeerState
var pool_ids: Array = []
var pool_index: Dictionary = {}
var detail := "normal"
var frozen := false
var overload := 1.0
var _overload_since := -1
var _calm_since := -1
var _overload_toast_ms := -OVERLOAD_TOAST_MS
var _sp: Array = []
var _fb: Array = []
var _dp: Array = []
var _hid: Array = []
var _meta_out: Dictionary = {}    # eid -> {kind: changed}
var _meta_hot: Dictionary = {}    # eid -> until ms (recently spawned / boosted / dirty: polled every frame)
var _fixture_eids: Dictionary = {}   # state-only fixtures (always polled at their adapters' rates)
var _last_flush_ms := 0
var _last_send_ms := 0
var _rest_scan_keys: Array = []
var _rest_scan_i := 0
var _meta_rest_i := 0
var _meta_rr_keys: Array = []
var _peer_rr := 0
var _odd_tick := false
var _host_scale := 1.0
var _self_usec := 0.0              # EWMA of this replicator's physics_step time
# per-tick shared candidate cache (_send_tick)
var _c_ents: Array = []
var _c_ai := PackedInt32Array()
var _c_p := PackedVector3Array()
var _c_own := PackedInt32Array()      # the owning peer while held / equipped, else 0
var _c_snap := PackedByteArray()      # 1 = some peer still owes a SNAP record
var _ai_free: Array = []
var _ai_next := 0
var _c_w := PackedFloat32Array()
var _c_size := PackedInt32Array()
var _c_rec: Array = []
var _c_sleep: Dictionary = {}       # eid -> encoded SLEEP record of this tick
var counters := {"tracked": 0, "untracked": 0, "records_tx": 0, "bytes_tx": 0, "packets_tx": 0, "ents_msgs": 0,
	"meta_msgs": 0, "sel_overrun": 0, "snaps": 0, "overload_events": 0, "follow_pushes": 0, "releases": 0,
	"sleep_capped": 0, "rest_rot_moves": 0}


func _init(p_bodies = null, p_pool_ids: Array = [], p_detail: String = "normal") -> void:
	bodies = p_bodies
	detail = p_detail
	set_pools(p_pool_ids)


func set_pools(ids: Array) -> void:
	pool_ids = []
	for p in ids:
		pool_ids.append(String(p))
	pool_ids.sort()
	pool_index.clear()
	for i in pool_ids.size():
		pool_index[pool_ids[i]] = i


func _now() -> int:
	return Time.get_ticks_msec()


func _session():
	return bodies.session if bodies != null else null


# ================================================================== tracking

## kind: pooled | fixture_body | fixture; ident: pool id (pooled) or fixture key.
func track(eid: int, node: Node, kind: String, ident: String) -> void:
	if eid == 0 or node == null or not is_instance_valid(node) or ents.has(eid):
		return
	tombs.erase(eid)
	var e := Ent.new()
	e.eid = eid
	e.ref = weakref(node)
	e.kind = kind
	e.body = kind != "fixture" and node is Node3D
	if kind == "pooled":
		e.pool_id = ident
		e.pool_idx = int(pool_index.get(ident, -1))
	else:
		e.key = ident
	e.moved_ms = _now()
	e.boost_until = _now() + BOOST_SPAWN_MS
	e.kw = Priority.kind_w(e.pool_id, e.kind, e.owner, e.owner_kind, -1)
	ents[eid] = e
	counters.tracked += 1
	e.meta_kinds = bodies.meta_sync.kinds_for(node, kind)
	e.meta_last = bodies.meta_sync.read_all(node, e.meta_kinds)
	for k in e.meta_kinds:
		e.meta_next[k] = _now() + bodies.meta_sync.rate_ms(k)
	if e.body:
		_sample(e)
		e.hidden = _is_hidden(node)
		e.resting = _is_resting(node)
		if node is RigidBody3D:
			e.sleep_cb = _on_sleep_changed.bind(eid)
			node.sleeping_state_changed.connect(e.sleep_cb)
		if node.has_signal("visibility_changed"):
			e.vis_cb = _on_vis_changed.bind(eid)
			node.visibility_changed.connect(e.vis_cb)
		if not e.resting:
			awake[eid] = true
			_ai_alloc(e)
		var meta = e.meta_last if not e.meta_last.is_empty() else null
		var flags := e.flags_base() | (Codec.RF_SLEEP if e.resting else 0)
		if kind == "pooled":
			if e.pool_idx < 0:
				bodies.log_warn("pooled entity %d of unknown pool %s: not replicated" % [eid, ident])
			else:
				_sp.append(WorldSnapshot.sp_row(eid, e.pool_idx, e.p, e.q, e.l, flags, meta))
		else:
			_fb.append(WorldSnapshot.sp_row(eid, e.key, e.p, e.q, e.l, flags, meta))
		if e.hidden:
			_hid.append([eid, 1])
	else:
		_fixture_eids[eid] = true
		if not e.meta_last.is_empty():
			_meta_out[eid] = e.meta_last.duplicate(true)
	_meta_hot[eid] = e.boost_until
	bodies.emit_added(eid, node)


func untrack(eid: int) -> void:
	var e: Ent = ents.get(eid, null)
	if e == null:
		return
	var n := e.node()
	if n != null:
		if e.sleep_cb.is_valid() and n.has_signal("sleeping_state_changed") and n.sleeping_state_changed.is_connected(e.sleep_cb):
			n.sleeping_state_changed.disconnect(e.sleep_cb)
		if e.vis_cb.is_valid() and n.visibility_changed.is_connected(e.vis_cb):
			n.visibility_changed.disconnect(e.vis_cb)
		if e.follow_peer != 0 and n is RigidBody3D:
			n.freeze = e.saved_freeze
			n.freeze_mode = e.saved_mode
	ents.erase(eid)
	awake.erase(eid)
	_ai_release(e)
	_meta_out.erase(eid)
	_meta_hot.erase(eid)
	_fixture_eids.erase(eid)
	for p in peers:
		peers[p].sleep_sched.erase(eid)
	tombs[eid] = _now() + TOMBSTONE_MS
	if e.body:
		_dp.append(eid)
	counters.untracked += 1
	bodies.emit_removed(eid)


func clear() -> void:
	for eid in ents.keys():
		var e: Ent = ents[eid]
		var n := e.node()
		if n != null:
			if e.sleep_cb.is_valid() and n.has_signal("sleeping_state_changed") and n.sleeping_state_changed.is_connected(e.sleep_cb):
				n.sleeping_state_changed.disconnect(e.sleep_cb)
			if e.vis_cb.is_valid() and n.visibility_changed.is_connected(e.vis_cb):
				n.visibility_changed.disconnect(e.vis_cb)
			if e.follow_peer != 0 and n is RigidBody3D:
				n.freeze = e.saved_freeze
				n.freeze_mode = e.saved_mode
	ents.clear()
	awake.clear()
	_ai_free.clear()
	_ai_next = 0
	peers.clear()
	tombs.clear()
	_meta_hot.clear()
	_fixture_eids.clear()
	_sp.clear()
	_fb.clear()
	_dp.clear()
	_hid.clear()
	_meta_out.clear()


func _on_sleep_changed(eid: int) -> void:
	var e: Ent = ents.get(eid, null)
	if e == null:
		return
	var n := e.node()
	if n != null and not _is_resting(n):
		_wake(e)


func _on_vis_changed(eid: int) -> void:
	var e: Ent = ents.get(eid, null)
	if e != null:
		_update_hidden(e)


func _wake(e: Ent) -> void:
	if awake.has(e.eid):
		return
	awake[e.eid] = true
	_ai_alloc(e)
	e.resting = false
	e.moved_ms = _now()
	for p in peers:
		peers[p].sleep_sched.erase(e.eid)


## Frame records must stay inside the codec range: one record beyond +-8000 m
## (a body that fell out of the world) would make the client drop the packet.
static func _in_range(p: Vector3) -> bool:
	return absf(p.x) < WorldSnapshot.RANGE and absf(p.y) < WorldSnapshot.RANGE and absf(p.z) < WorldSnapshot.RANGE


static func _is_hidden(n: Node) -> bool:
	return not bool(n.visible) or n.has_meta("in_cannon_barrel") or n.has_meta("in_vacuum_bag")


static func _is_resting(n: Node) -> bool:
	if n is RigidBody3D:
		var rb := n as RigidBody3D
		if rb.freeze and rb.freeze_mode == RigidBody3D.FREEZE_MODE_STATIC:
			return true
		if rb.freeze:
			return false      # kinematic (carried, piston rider, follower): moving
		return rb.sleeping
	return true


func _update_hidden(e: Ent) -> void:
	var n := e.node()
	if n == null or not e.body:
		return
	var h := _is_hidden(n)
	if h == e.hidden:
		return
	e.hidden = h
	_hid.append([e.eid, 1 if h else 0])
	if not h:
		_mark_snap(e)
		_wake(e)


func _sample(e: Ent) -> void:
	var n := e.node()
	if n == null or not n.is_inside_tree():
		return
	var p: Vector3 = n.global_position
	var q: Quaternion = n.global_basis.get_rotation_quaternion()
	var l := Vector3.ZERO
	var av := Vector3.ZERO
	if n is RigidBody3D:
		l = n.linear_velocity
		av = n.angular_velocity
	if e.follow_peer != 0 and not e.follow.is_empty():
		l = e.follow.back().l
		av = e.follow.back().a
	if e.has_sample:
		var jump := p.distance_to(e.p)
		var dt := float(SEND_INTERVAL_MS) / 1000.0
		if jump > SNAP_JUMP and jump > l.length() * dt * 2.0 + 1.0:
			_mark_snap(e)
	e.p = p
	e.q = q
	e.l = l
	e.a = av
	e.has_sample = true


func _mark_snap(e: Ent) -> void:
	counters.snaps += 1
	for p in peers:
		e.snap_peers[p] = true
	e.boost_until = _now() + 2000


# ================================================================== GRAB / GAMEPLAY hooks

func set_owner(eid: int, owner_peer: int, kind: String, epoch: int) -> void:
	var e: Ent = ents.get(eid, null)
	if e == null:
		return
	e.owner = owner_peer if owner_peer > 0 else 1
	e.owner_kind = kind
	e.epoch = epoch
	e.kw = Priority.kind_w(e.pool_id, e.kind, e.owner, e.owner_kind, -1)
	if kind == "equipped":
		# GAMEPLAY's rig poses an equipped tool every physics frame (6.4): no follower drive
		e.follow.clear()
	e.boost_until = _now() + 2000
	var n := e.node()
	if n != null and not _is_resting(n):
		_wake(e)
	# ordering (3.3): the lifecycle of this eid goes out before its `own`
	flush_lifecycle()


func follow(eid: int, peer: int) -> void:
	var e: Ent = ents.get(eid, null)
	if e == null:
		return
	var n := e.node()
	if n == null:
		return
	if e.follow_peer == 0 and n is RigidBody3D:
		e.saved_freeze = n.freeze
		e.saved_mode = n.freeze_mode
		n.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		n.freeze = true
	e.follow_peer = peer
	e.follow.clear()
	e.follow_has = false
	_wake(e)


func follow_push(eid: int, state: Dictionary, t_ms: int) -> void:
	var e: Ent = ents.get(eid, null)
	if e == null or e.follow_peer == 0:
		return
	# 0.2.2: a kinematic follower that moves in uneven steps (frames arriving in bursts,
	# or two physics ticks on one wall-clock ms) shakes what rests in it: a full crate
	# spilled its ducks on the host. Frames play at the sender's spacing.
	var rx := _follow_now()
	if not e.follow.is_empty() and t_ms != 0:
		var last: Dictionary = e.follow.back()
		var dts := posmod(t_ms - int(last.get("t", 0)) + 0x80000000, 0x100000000) - 0x80000000
		if int(last.get("t", 0)) != 0 and dts > 0 and dts < 500:
			rx = clampi(int(last.rx) + dts, rx, rx + FOLLOW_SPREAD_MS)
	e.follow.append({"rx": rx, "t": t_ms, "p": state.get("p", e.p), "q": state.get("q", e.q),
		"l": state.get("l", Vector3.ZERO), "a": state.get("a", Vector3.ZERO)})
	while e.follow.size() > FOLLOW_KEEP:
		e.follow.pop_front()
	counters.follow_pushes += 1


func release(eid: int, state: Dictionary) -> void:
	var e: Ent = ents.get(eid, null)
	if e == null:
		return
	var n := e.node()
	var was_following := e.follow_peer != 0
	e.follow_peer = 0
	e.follow.clear()
	if n == null:
		return
	if state.is_empty():
		# GRAB capture revokes (consumed, cannon, vacuum...): stop following only and leave
		# the body as the game set it. Our follow freeze is undone only while it is still
		# ours (frozen KINEMATIC) and the game did not capture the body (hidden / stored).
		if was_following and n is RigidBody3D and n.freeze and n.freeze_mode == RigidBody3D.FREEZE_MODE_KINEMATIC 				and n.visible and not n.has_meta("in_cannon_barrel") and not n.has_meta("in_vacuum_bag"):
			n.freeze_mode = e.saved_mode
			n.freeze = e.saved_freeze
		e.boost_until = _now() + 2000
		_wake(e)
		counters.releases += 1
		return
	var p: Vector3 = state.get("p", n.global_position)
	var q: Quaternion = state.get("q", n.global_basis.get_rotation_quaternion())
	n.global_transform = Transform3D(Basis(q).scaled(n.global_basis.get_scale()), p)
	if n is RigidBody3D:
		if was_following:
			n.freeze_mode = e.saved_mode
			n.freeze = e.saved_freeze
		n.linear_velocity = state.get("l", Vector3.ZERO)
		n.angular_velocity = state.get("a", Vector3.ZERO)
		n.sleeping = false
	e.boost_until = _now() + 2000
	_wake(e)
	counters.releases += 1


func boost(eid: int, seconds: float) -> void:
	var e: Ent = ents.get(eid, null)
	if e != null:
		e.boost_until = maxi(e.boost_until, _now() + int(seconds * 1000.0))
		_meta_hot[eid] = e.boost_until


func meta_dirty(eid: int) -> void:
	var e: Ent = ents.get(eid, null)
	if e != null:
		e.meta_force = true
		_meta_hot[eid] = maxi(int(_meta_hot.get(eid, 0)), _now() + 100)


func mark_snap(eid: int) -> void:
	var e: Ent = ents.get(eid, null)
	if e != null:
		_mark_snap(e)
		_wake(e)


## Phase 5 (D16): no more body frames; clients turn puppets into local bodies.
func freeze_world() -> void:
	if frozen:
		return
	frozen = true
	flush_lifecycle()
	var s = _session()
	if s != null:
		s.send_world(0, "ents", {"t": _now(), "freeze_world": true})


# ================================================================== peers

func peer_ready(peer: int) -> void:
	var ps := _peer(peer)
	ps.ready_ms = _now()
	# bodies that came to rest after (or just before) the peer's world-snapshot
	# cut get their SLEEP sends; everything awake starts with a full accumulator
	for eid in ents:
		var e: Ent = ents[eid]
		if not e.body:
			continue
		if e.resting and e.moved_ms >= _now() - READY_RESEND_MS:
			ps.sleep_sched[eid] = {"t0": _now(), "n": 0}
		elif not e.resting and e.ai >= 0:
			if ps.accs.size() < _ai_next:
				ps.accs.resize(_ai_next)
			ps.accs[e.ai] = 100.0
	ps.sleep_next_ms = 0


func peer_left(peer: int) -> void:
	peers.erase(peer)
	for eid in ents:
		ents[eid].snap_peers.erase(peer)


func on_netq(peer: int, msg: Dictionary) -> void:
	var ps := _peer(peer)
	var rx := maxi(0, int(msg.get("rx_pkts", 0)))
	var gaps := maxi(0, int(msg.get("gaps", 0)))
	var loss := float(gaps) / float(rx + gaps) if rx + gaps > 0 else 0.0
	ps.budget.report(_now(), loss, int(msg.get("rtt_ms", -1)))


func _peer(peer: int) -> PeerState:
	var ps: PeerState = peers.get(peer, null)
	if ps == null:
		ps = PeerState.new()
		ps.peer = peer
		ps.slot = _free_slot()
		ps.budget = Budget.new(detail)
		ps.last_tick_ms = _now()
		ps.served_ms = _now() - SEND_INTERVAL_MS
		ps.win_start_ms = _now()
		peers[peer] = ps
		ps.accs.resize(_ai_next)
		ps.accs.fill(0.0)
	return ps


## A stable index for an awake body into every peer's accumulator array.
func _ai_alloc(e: Ent) -> void:
	if e.ai >= 0:
		return
	if not _ai_free.is_empty():
		e.ai = int(_ai_free.pop_back())
	else:
		e.ai = _ai_next
		_ai_next += 1
	for p in peers:
		var ps: PeerState = peers[p]
		if ps.accs.size() < _ai_next:
			ps.accs.resize(_ai_next)
		ps.accs[e.ai] = 0.0


func _ai_release(e: Ent) -> void:
	if e.ai < 0:
		return
	_ai_free.append(e.ai)
	e.ai = -1


func _free_slot() -> int:
	var used := {}
	for p in peers:
		used[peers[p].slot] = true
	for i in MAX_SLOTS:
		if not used.has(i):
			return i
	return MAX_SLOTS - 1


func budget_bps(peer: int) -> int:
	var ps: PeerState = peers.get(peer, null)
	return int(ps.budget.bps) if ps != null else Budget.detail_bps(detail)


# ================================================================== per physics frame

func physics_step() -> void:
	var t0 := Time.get_ticks_usec()
	_physics_step()
	_self_usec += (float(Time.get_ticks_usec() - t0) - _self_usec) * 0.1


func _physics_step() -> void:
	var now := _now()
	_fclock = (_fclock + 1000.0 / float(maxi(1, Engine.physics_ticks_per_second))) if _fclock > 0.0 else float(now)
	if absf(_fclock - float(now)) > 100.0:
		_fclock = float(now)
	_drive_followers(int(_fclock))
	_poll_meta(now)
	if now - _last_flush_ms >= LIFECYCLE_MS:
		_last_flush_ms = now
		flush_lifecycle()
	if not frozen and now - _last_send_ms >= SEND_INTERVAL_MS:
		_last_send_ms = now
		_sample_awake()
		_scan_resting()
		_send_tick(now)
	if not tombs.is_empty() and Engine.get_physics_frames() % 60 == 0:
		for eid in tombs.keys():
			if int(tombs[eid]) < now:
				tombs.erase(eid)


## Follower clock (ms): exactly one physics tick per step, kept within 100 ms of the
## wall clock, so a follower moves the same distance every tick (0.2.2).
func _follow_now() -> int:
	return int(_fclock) if _fclock > 0.0 else _now()


func _drive_followers(now: int) -> void:
	for eid in awake:
		var e: Ent = ents.get(eid, null)
		if e == null or e.follow_peer == 0 or e.follow.is_empty() or e.owner_kind == "equipped":
			continue
		var n := e.node()
		if n == null:
			continue
		var rt := now - FOLLOW_DELAY_MS
		var s0: Dictionary = e.follow[0]
		var s1: Dictionary = s0
		for s in e.follow:
			if int(s.rx) <= rt:
				s0 = s
			else:
				s1 = s
				break
		var p: Vector3 = s0.p
		var q: Quaternion = s0.q
		var v: Vector3 = s0.get("l", Vector3.ZERO)
		if s1 != s0 and int(s1.rx) > int(s0.rx):
			var u := clampf(float(rt - int(s0.rx)) / float(int(s1.rx) - int(s0.rx)), 0.0, 1.0)
			p = (s0.p as Vector3).lerp(s1.p, u)
			q = (s0.q as Quaternion).slerp(s1.q, u)
			v = (s1.p - s0.p) / (float(int(s1.rx) - int(s0.rx)) / 1000.0)
		elif int(e.follow.back().rx) <= rt:
			var last: Dictionary = e.follow.back()
			p = last.p + last.l * (float(mini(rt - int(last.rx), 250)) / 1000.0)
			q = last.q
			v = last.l if rt - int(last.rx) < 250 else Vector3.ZERO
		# 0.2.2: bounded acceleration toward the interpolated pose (see FOLLOW_MAX_ACCEL)
		var dt := 1.0 / float(maxi(1, Engine.physics_ticks_per_second))
		if not e.follow_has or e.follow_out.distance_to(p) > FOLLOW_SNAP_M:
			e.follow_has = true
			e.follow_out = p
			e.follow_v = v
		else:
			var dv := v + (p - e.follow_out) * FOLLOW_GAIN - e.follow_v
			var lim := FOLLOW_MAX_ACCEL * dt
			if dv.length() > lim:
				dv = dv.normalized() * lim
			e.follow_v += dv
			e.follow_out += e.follow_v * dt
		n.global_transform = Transform3D(Basis(q).scaled(n.global_basis.get_scale()), e.follow_out)


func _sample_awake() -> void:
	var gone: Array = []
	var rest: Array = []
	var now := _now()
	for eid in awake:
		var e: Ent = ents.get(eid, null)
		if e == null:
			gone.append(eid)
			continue
		var n := e.node()
		if n == null:
			continue
		_update_hidden(e)
		_sample(e)
		if e.follow_peer == 0 and _is_resting(n):
			rest.append(e)
		else:
			e.moved_ms = now
	for eid in gone:
		awake.erase(eid)
	for e in rest:
		_to_rest(e)


func _to_rest(e: Ent) -> void:
	awake.erase(e.eid)
	e.resting = true
	_ai_release(e)
	for p in peers:
		var ps: PeerState = peers[p]
		ps.sleep_sched[e.eid] = {"t0": _now(), "n": 0}
		ps.sleep_next_ms = 0


## Resting bodies, round-robin: woken without a signal (unfrozen, moved by code)?
func _scan_resting() -> void:
	if _rest_scan_i >= _rest_scan_keys.size():
		_rest_scan_keys = ents.keys()
		_rest_scan_i = 0
	var n_done := 0
	var per_tick := maxi(REST_SCAN_PER_TICK, ceili(float(_rest_scan_keys.size()) / REST_SCAN_LAP_TICKS))
	while _rest_scan_i < _rest_scan_keys.size() and n_done < per_tick:
		var eid = _rest_scan_keys[_rest_scan_i]
		_rest_scan_i += 1
		var e: Ent = ents.get(eid, null)
		if e == null or not e.body or awake.has(eid):
			continue
		n_done += 1
		var n := e.node()
		if n == null:
			continue
		_update_hidden(e)
		if not _is_resting(n):
			_wake(e)
		elif n.global_position.distance_to(e.p) > 0.01 \
				or absf(n.global_basis.get_rotation_quaternion().dot(e.q)) < REST_ROT_DOT:
			# moved (or turned in place) by game code while resting (a teleport, a placement)
			var jumped := n.global_position.distance_to(e.p) > 1.0
			if n.global_position.distance_to(e.p) <= 0.01:
				counters.rest_rot_moves += 1
			_sample(e)
			if jumped:
				_mark_snap(e)
			e.moved_ms = _now()
			for p in peers:
				peers[p].sleep_sched[eid] = {"t0": _now(), "n": 0}
				peers[p].sleep_next_ms = 0


func _send_tick(now: int) -> void:
	var s = _session()
	if s == null:
		return
	var in_game: Array = s.in_game_peers()
	for p in peers.keys():
		if not (p in in_game):
			peers.erase(p)
	if in_game.is_empty():
		return
	_overload_check(now)
	_odd_tick = not _odd_tick
	var t0 := Time.get_ticks_usec()
	_build_shared(now)
	_update_host_scale()
	var n := in_game.size()
	for i in n:
		var peer: int = in_game[(_peer_rr + i) % n]
		var ps := _peer(peer)
		# overloaded: every peer every other tick (its banked budget keeps its byte rate)
		if overload < 1.0 and n > 1 and ((ps.slot % 2 == 0) == _odd_tick) and now - ps.served_ms < 2 * SEND_INTERVAL_MS:
			continue
		_send_peer(ps, now)
		if Time.get_ticks_usec() - t0 > SEL_BUDGET_USEC and i < n - 1:
			counters.sel_overrun += 1
			_peer_rr = (_peer_rr + i + 1) % n
			_c_rec.clear()
			_c_sleep.clear()
			return
	_peer_rr = 0
	_c_rec.clear()
	_c_sleep.clear()


## Once per tick: the awake candidates with their peer-independent weight and size.
func _build_shared(now: int) -> void:
	_c_ents.clear()
	_c_rec.clear()
	_c_sleep.clear()
	var n := 0
	var m := awake.size()
	_c_w.resize(m)
	_c_size.resize(m)
	_c_ai.resize(m)
	_c_p.resize(m)
	_c_own.resize(m)
	_c_snap.resize(m)
	for eid in awake:
		var e: Ent = ents.get(eid, null)
		if e == null or e.hidden or not e.body or not e.has_sample or not _in_range(e.p):
			continue
		if e.ai < 0:
			_ai_alloc(e)
		var w := e.kw * Priority.motion_w(e.l.length())
		var boosted := e.boost_until > now
		if boosted:
			w *= Priority.BOOST
		_c_ents.append(e)
		_c_w[n] = w
		_c_size[n] = Codec.body_record_size(_motion_flags(e))
		_c_ai[n] = e.ai
		_c_p[n] = e.p
		_c_own[n] = e.owner if e.owner_kind != "" else 0
		_c_snap[n] = 1 if (not boosted and not e.snap_peers.is_empty()) else 0
		n += 1
	_c_w.resize(n)
	_c_size.resize(n)
	_c_ai.resize(n)
	_c_p.resize(n)
	_c_own.resize(n)
	_c_snap.resize(n)
	_c_rec.resize(n)


## HOST_UPLOAD_BPS over the sum of the peers' budgets (1.0 = no cap).
func _update_host_scale() -> void:
	var sum := 0
	for p in peers:
		sum += int(peers[p].budget.bps)
	_host_scale = clampf(float(HOST_UPLOAD_BPS) / float(sum), 0.0, 1.0) if sum > 0 else 1.0


func _rec_bytes(i: int, peer: int) -> PackedByteArray:
	var b = _c_rec[i]
	if b == null:
		var e: Ent = _c_ents[i]
		b = Codec.encode_body_record(_record(e, 0, false))
		_c_rec[i] = b
	return _snap_patch(b, _c_ents[i], peer)


func _sleep_bytes(e: Ent, peer: int) -> PackedByteArray:
	var b = _c_sleep.get(e.eid, null)
	if b == null:
		if e.node() != null:
			_sample(e)
		b = Codec.encode_body_record(_record(e, 0, true))
		_c_sleep[e.eid] = b
	return _snap_patch(b, e, peer)


## RF_SNAP is per peer: patched into the shared record's flag byte.
func _snap_patch(b: PackedByteArray, e: Ent, peer: int) -> PackedByteArray:
	if e.snap_peers.is_empty() or not e.snap_peers.has(peer):
		return b
	e.snap_peers.erase(peer)
	var c := b.duplicate()
	c[4] = int(c[4]) | Codec.RF_SNAP
	return c


func _send_peer(ps: PeerState, now: int) -> void:
	var s = _session()
	var elapsed_ms := clampi(now - ps.served_ms, SEND_INTERVAL_MS, SEND_INTERVAL_MS * BANK_MAX_TICKS)
	ps.served_ms = now
	var dt := clampf(float(now - ps.last_tick_ms) / 1000.0, 0.0, 0.25)
	ps.last_tick_ms = now
	ps.budget.tick(now)
	var budget: int = ps.budget.bytes_for(float(elapsed_ms) / 1000.0, overload, _host_scale)
	# every packet's header and transport overhead come out of the budget
	var per_pkt := Codec.BODIES_HEADER + PKT_OVERHEAD
	var n_pkts := maxi(1, ceili(float(budget) / float(Codec.PACK_TARGET)))
	var room := budget - n_pkts * per_pkt
	var pose: Dictionary = s.avatar_pose(ps.peer)
	var has_pose := bool(pose.get("ok", false))
	var a_c: Vector3 = pose.get("pos", Vector3.ZERO)
	var recs: Array = []
	var used := 0
	var peer := ps.peer
	var n_c := _c_ents.size()
	# 1. due SLEEP sends (first send and its 3 repeats), at most SLEEP_SHARE of the tick
	#    while bodies are awake
	if not ps.sleep_sched.is_empty() and now >= ps.sleep_next_ms:
		var cap := room if n_c == 0 else int(room * SLEEP_SHARE)
		var next_due := now + 1000000
		var capped := false
		for eid in ps.sleep_sched.keys():
			var sc: Dictionary = ps.sleep_sched[eid]
			var due := int(sc.t0) + (0 if int(sc.n) == 0 else int(SLEEP_REPEATS_MS[int(sc.n) - 1]))
			if now < due or capped:
				next_due = mini(next_due, due)
				continue
			var e: Ent = ents.get(eid, null)
			if e == null or e.hidden or not _in_range(e.p) or (e.owner == peer and e.owner_kind != ""):
				ps.sleep_sched.erase(eid)
				continue
			if used + Codec.BODY_BASE > cap and not recs.is_empty():
				capped = true
				counters.sleep_capped += 1
				next_due = now
				continue
			recs.append(_sleep_bytes(e, peer))
			used += Codec.BODY_BASE
			sc.n = int(sc.n) + 1
			if int(sc.n) > SLEEP_REPEATS_MS.size():
				ps.sleep_sched.erase(eid)
			else:
				next_due = mini(next_due, int(sc.t0) + int(SLEEP_REPEATS_MS[int(sc.n) - 1]))
		ps.sleep_next_ms = next_due
	# 2. awake bodies by accumulated priority (shared weight x this peer's distance weight)
	if n_c > 0:
		var accs := PackedFloat32Array()
		accs.resize(n_c)
		var idx := PackedInt32Array()
		idx.resize(n_c)
		var k := 0
		var inv := 1.0 / (Priority.DIST_SCALE * Priority.DIST_SCALE)
		var store := ps.accs
		if store.size() < _ai_next:
			store.resize(_ai_next)
		var floor_w := Priority.DIST_FLOOR
		for i in n_c:
			if _c_own[i] == peer:
				continue
			var w: float = _c_w[i]
			if has_pose:
				w *= maxf(floor_w, 1.0 / (1.0 + _c_p[i].distance_squared_to(a_c) * inv))
			if _c_snap[i] != 0 and (_c_ents[i] as Ent).snap_peers.has(peer):
				w *= Priority.BOOST
			var ai := _c_ai[i]
			var acc: float = store[ai] + w * dt
			store[ai] = acc
			accs[k] = acc
			idx[k] = i
			k += 1
		accs.resize(k)
		idx.resize(k)
		for j in Priority.select_top(accs, idx, _c_size, room - used):
			recs.append(_rec_bytes(j, peer))
			used += _c_size[j]
			store[_c_ai[j]] = 0.0
		ps.accs = store
	# 3. rest refresh: one resting body per tick heals any lost SLEEP record
	if ps.rest_i >= ps.rest_keys.size():
		ps.rest_keys = ents.keys()
		ps.rest_i = 0
	while ps.rest_i < ps.rest_keys.size():
		var eid = ps.rest_keys[ps.rest_i]
		ps.rest_i += 1
		var e: Ent = ents.get(eid, null)
		if e == null or not e.body or not e.resting or e.hidden or ps.sleep_sched.has(eid) or not _in_range(e.p):
			continue
		if e.owner == peer and e.owner_kind != "":
			continue
		recs.append(_sleep_bytes(e, peer))
		break
	if recs.is_empty():
		return
	var pkts := Codec.pack_records(s.host_now(), ps.seq, recs)
	ps.seq = (ps.seq + pkts.size()) & 0xFFFF
	var bytes := 0
	for pkt in pkts:
		s.send_unreliable(peer, pkt)
		bytes += pkt.size()
	ps.tx_bytes += bytes
	ps.tx_packets += pkts.size()
	counters.bytes_tx += bytes
	counters.packets_tx += pkts.size()
	ps.tx_records += recs.size()
	counters.records_tx += recs.size()
	ps.win_bytes += bytes + pkts.size() * PKT_OVERHEAD
	if now - ps.win_start_ms >= 1000:
		ps.eff_bps = int(float(ps.win_bytes) * 1000.0 / float(now - ps.win_start_ms))
		ps.win_bytes = 0
		ps.win_start_ms = now


func _motion_flags(e: Ent) -> int:
	var f := Codec.RF_LIN
	if e.a.length_squared() > 0.0025:
		f |= Codec.RF_ANG
	return f


func _record(e: Ent, peer: int, rest: bool) -> Dictionary:
	var flags := e.flags_base()
	if rest:
		flags |= Codec.RF_SLEEP
	else:
		flags |= _motion_flags(e)
	if peer != 0 and e.snap_peers.has(peer):
		flags |= Codec.RF_SNAP
		e.snap_peers.erase(peer)
	return {"eid": e.eid, "flags": flags, "epoch": e.epoch & 0xFF, "p": e.p, "q": e.q,
		"l": Vector3.ZERO if rest else e.l, "a": Vector3.ZERO if rest else e.a}


func _overload_check(now: int) -> void:
	var ratio: float = bodies.adapter.physics_load() if bodies.adapter != null and bodies.adapter.has_method("physics_load") else 0.0
	# the replicator's own time is inside TIME_PHYSICS_PROCESS: leave it out
	ratio = maxf(0.0, ratio - _self_usec / 1000000.0 * float(maxi(1, Engine.physics_ticks_per_second)))
	if ratio > OVERLOAD_RATIO:
		_calm_since = -1
		if _overload_since < 0:
			_overload_since = now
		if overload >= 1.0 and now - _overload_since >= OVERLOAD_HOLD_MS:
			overload = 0.5
			counters.overload_events += 1
			if now - _overload_toast_ms >= OVERLOAD_TOAST_MS:
				_overload_toast_ms = now
				bodies.toast("MP_PHYSICS_OVERLOADED")
	else:
		_overload_since = -1
		if _calm_since < 0:
			_calm_since = now
		if overload < 1.0 and now - _calm_since >= OVERLOAD_HOLD_MS:
			overload = 1.0


# ================================================================== meta

func _poll_meta(now: int) -> void:
	var ms = bodies.meta_sync
	for eid in awake:
		_poll_meta_one(eid, now, ms)
	for eid in _fixture_eids:
		_poll_meta_one(eid, now, ms)
	var cold: Array = []
	for eid in _meta_hot:
		if int(_meta_hot[eid]) < now:
			cold.append(eid)
		if not awake.has(eid):
			_poll_meta_one(eid, now, ms)
	for eid in cold:
		_meta_hot.erase(eid)
	# resting bodies, round-robin (the key list is refreshed once per lap)
	for i in META_REST_PER_TICK:
		if _meta_rest_i >= _meta_rr_keys.size():
			_meta_rr_keys = ents.keys()
			_meta_rest_i = 0
			if _meta_rr_keys.is_empty():
				break
		_poll_meta_one(_meta_rr_keys[_meta_rest_i], now, ms)
		_meta_rest_i += 1


func _poll_meta_one(eid, now: int, ms) -> void:
	var e: Ent = ents.get(eid, null)
	if e == null or e.meta_kinds.is_empty():
		return
	var n := e.node()
	if n == null:
		return
	var force := e.meta_force
	e.meta_force = false
	for k in e.meta_kinds:
		if not force and now < int(e.meta_next.get(k, 0)):
			continue
		e.meta_next[k] = now + ms.rate_ms(k)
		var cur: Dictionary = ms.read_kind(n, String(k))
		var last: Dictionary = e.meta_last.get(k, {})
		var ch := EntityMeta.diff(last, cur)
		if ch.is_empty():
			continue
		for f in ch:
			last[f] = ch[f]
		e.meta_last[k] = last
		if not _meta_out.has(eid):
			_meta_out[eid] = {}
		if not _meta_out[eid].has(k):
			_meta_out[eid][k] = {}
		for f in ch:
			_meta_out[eid][k][f] = ch[f]


# ================================================================== lifecycle (ch3)

func flush_lifecycle() -> void:
	var s = _session()
	if s == null:
		return
	if _sp.is_empty() and _fb.is_empty() and _dp.is_empty() and _hid.is_empty() and _meta_out.is_empty():
		return
	var t: int = s.host_now()
	var sp := _sp
	var fb := _fb
	var dp := _dp
	var hid := _hid
	_sp = []
	_fb = []
	_dp = []
	_hid = []
	var first := true
	while first or not sp.is_empty() or not fb.is_empty():
		first = false
		var msg := {"t": t}
		var room := ENTS_ROWS_PER_MSG
		if not fb.is_empty():
			var take := mini(room, fb.size())
			msg["fb"] = fb.slice(0, take)
			fb = fb.slice(take)
			room -= take
		if not sp.is_empty() and room > 0:
			var take2 := mini(room, sp.size())
			msg["sp"] = sp.slice(0, take2)
			sp = sp.slice(take2)
		if sp.is_empty() and fb.is_empty():
			if not dp.is_empty():
				msg["dp"] = dp
			if not hid.is_empty():
				msg["hid"] = hid
		if msg.size() > 1:
			s.send_world(0, "ents", msg)
			counters.ents_msgs += 1
	if not _meta_out.is_empty():
		var rows: Array = []
		for eid in _meta_out:
			if ents.has(eid):
				rows.append([eid, _meta_out[eid]])
		_meta_out.clear()
		while not rows.is_empty():
			var take3 := mini(META_ROWS_PER_MSG, rows.size())
			s.send_world(0, "meta", {"m": rows.slice(0, take3)})
			rows = rows.slice(take3)
			counters.meta_msgs += 1


# ================================================================== world snapshot (3.7)

func build_wsnap() -> Dictionary:
	var out_ents: Array = []
	var out_fb: Array = []
	var fixtures := {}
	for eid in ents:
		var e: Ent = ents[eid]
		var n := e.node()
		if n == null:
			continue
		var meta: Dictionary = bodies.meta_sync.read_all(n, e.meta_kinds)
		# a change _poll_meta has not diffed yet: the joiner gets it in its row, the
		# peers already in the world get it as a meta row (queued before meta_last moves)
		for k in meta:
			var ch := EntityMeta.diff(e.meta_last.get(k, {}), meta[k])
			if ch.is_empty():
				continue
			if not _meta_out.has(eid):
				_meta_out[eid] = {}
			if not _meta_out[eid].has(k):
				_meta_out[eid][k] = {}
			for f in ch:
				_meta_out[eid][k][f] = ch[f]
		e.meta_last = meta.duplicate(true)
		if not e.body:
			if not meta.is_empty():
				fixtures[str(eid)] = meta
			continue
		_sample(e)
		var flags := e.flags_base()
		if e.resting:
			flags |= Codec.RF_SLEEP
		if e.hidden:
			flags |= Codec.RF_HIDDEN
		if e.kind == "pooled":
			if e.pool_idx >= 0:
				out_ents.append(WorldSnapshot.wsnap_ent_row(eid, e.pool_idx, e.p, e.q, e.l, e.a, flags, e.owner,
					e.epoch, meta))
		else:
			out_fb.append(WorldSnapshot.wsnap_fb_row(eid, e.key, e.p, e.q, flags, e.owner, e.epoch, meta))
	var s = _session()
	return {"host_ms": s.host_now() if s != null else _now(), "pools_hash": WorldSnapshot.pools_hash(pool_ids),
		"ents": out_ents, "fbodies": out_fb, "fixtures": fixtures, "frozen": frozen}


# ================================================================== queries

func flags_of(eid: int) -> int:
	var e: Ent = ents.get(eid, null)
	if e == null:
		return 0
	var f := e.flags_base()
	if e.resting:
		f |= Codec.RF_SLEEP
	if e.hidden:
		f |= Codec.RF_HIDDEN
	return f


func stats() -> Dictionary:
	var per := {}
	for p in peers:
		var ps: PeerState = peers[p]
		per[p] = {"budget_bps": ps.budget.bps, "eff_bps": ps.eff_bps, "records": ps.tx_records, "bytes": ps.tx_bytes,
			"packets": ps.tx_packets}
	return {"tracked": ents.size(), "awake": awake.size(), "peers": per, "overload": overload,
		"host_scale": _host_scale, "self_us": int(_self_usec)}
