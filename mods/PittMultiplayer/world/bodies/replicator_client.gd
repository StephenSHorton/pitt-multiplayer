extends RefCounted
## Client replicator (MP2-DESIGN 3.4). Every replicated body is the game's own
## pooled object (spawned through ObjectPoolManager.spawn in apply scope and
## adopted under the host eid, L7) or the scene's fixture body, frozen
## KINEMATIC and driven from host frames:
##   render time rt = host_now - interp_delay (clamp(mean lateness + 2 x jitter + 33, 66, 200) ms),
##   Hermite / slerp between ring states, extrapolation <= 250 ms, SNAP / > 5 m /
##   epoch change teleport, other corrections blend over 150 ms, SLEEP exact.
## Frames for an unknown eid wait 500 ms for the spawn (orphan_frames after);
## despawned eids are tombstoned for 5 s. A full pool keeps the eid pending and
## retries every 0.5 s (client_pool_full). D22: small products (mass <= 2 kg)
## get a collision exception with the local player.
## Per frame only the ACTIVE puppets are driven (moving, blending, waiting for
## a release); idle / hidden / sleeping ones cost nothing until their next
## record. A round-robin pass (VERIFY_PER_FRAME) re-asserts the freeze of the
## others and detects a puppet whose node client game code recycled (or the
## pool handed to another eid): the puppet is dropped and respawned from its
## newest host state, so two eids never drive one node.
## Riders (0.2.2): puppets in or on a body the local player carries (ducks in a
## crate) simulate locally with it until the carry ends (_carry_riders).

const Codec = preload("../../net/codec.gd")
const Interp = preload("interp.gd")
const PuppetBody = preload("puppet_body.gd")
const WorldSnapshot = preload("world_snapshot.gd")

const PUPPET_META := "pitt_mp_puppet"
const ORPHAN_MS := 500
const TOMBSTONE_MS := 5000
const PENDING_RETRY_MS := 500
const DRIVE_IDLE_MS := 2000
const BLEND_MS := 150.0
const SNAP_ERR := 5.0
const JUMP_EPS := 0.02
const RELEASE_WAIT_MS := 1000
const D22_MASS := 2.0
const NETQ_MS := 1000
const VERIFY_PER_FRAME := 64
const RIDER_SCAN_FRAMES := 4      # the in/on scan of a carried body runs every 4th frame
const RIDER_MARGIN_M := 0.05      # around the carried body's shapes
const RIDER_HEAD_M := 0.6         # room above them (a pile in a crate, ducks on a panel)

var bodies = null
var puppets: Dictionary = {}      # eid -> PuppetBody
var tombs: Dictionary = {}        # eid -> until ms
var orphans: Dictionary = {}      # eid -> [{rx, state}]
var pending: Dictionary = {}      # eid -> {d, fb, next, t}
var active: Dictionary = {}       # eid -> true: driven this frame (see header)
var carriers: Dictionary = {}     # eid -> true: local_sim bodies GRAB carries (_carry_riders)
var _rider_k := 0
var _by_node: Dictionary = {}     # node instance id -> eid (pooled puppets)
var _pooled_n := 0
var _rr_keys: Array = []
var _rr_i := 0
var pool_ids: Array = []
var interp_delay := Interp.DELAY_DEFAULT_MS
var jitter_ms := 0.0
var _off_mean := 0.0
var _off_init := false
var frozen := false
var applying := false
var _apply_rows: Array = []        # [[row, is_fb]]
var _apply_t := 0
var _loading_prev := false
var _last_seq := -1
var _last_netq_ms := 0
var _last_drive_ms := 0
var q_rx_pkts := 0
var q_gaps := 0
var q_late := 0
var counters := {"puppets_spawned": 0, "puppets_despawned": 0, "frames_rx": 0, "records_rx": 0,
	"orphan_frames": 0, "orphans_adopted": 0, "late_frames": 0, "client_pool_full": 0, "puppet_unfreeze": 0,
	"fixture_mismatch": 0, "snaps": 0, "blends": 0, "decode_errors": 0, "wsnap_rows": 0, "wsnap_rejected": 0,
	"frames_gaps": 0, "puppet_lost": 0, "riders_on": 0, "riders_off": 0}


func _init(p_bodies = null, p_pool_ids: Array = []) -> void:
	bodies = p_bodies
	set_pools(p_pool_ids)


func set_pools(ids: Array) -> void:
	pool_ids = []
	for p in ids:
		pool_ids.append(String(p))
	pool_ids.sort()


func _now() -> int:
	return Time.get_ticks_msec()


func _session():
	return bodies.session if bodies != null else null


func _host_now() -> int:
	var s = _session()
	return s.host_now() if s != null else _now()


## Active pooled objects the replicator accounts for (kept incrementally; the
## verify pass drops puppets whose node left the pool's active set).
func pooled_count() -> int:
	return _pooled_n


# ================================================================== lifecycle (ch3)

func on_ents(msg: Dictionary) -> void:
	var t := int(msg.get("t", _host_now()))
	if bool(msg.get("freeze_world", false)):
		freeze_world()
		return
	bodies.begin_apply()
	for row in _arr(msg.get("fb", [])):
		var d := WorldSnapshot.parse_sp(row, true)
		if not d.is_empty():
			_spawn(d, true, t)
	for row in _arr(msg.get("sp", [])):
		var d2 := WorldSnapshot.parse_sp(row, false)
		if not d2.is_empty():
			_spawn(d2, false, t)
	for eid in _arr(msg.get("dp", [])):
		if typeof(eid) == TYPE_INT:
			despawn(int(eid))
	for h in _arr(msg.get("hid", [])):
		if typeof(h) == TYPE_ARRAY and h.size() >= 2:
			var pb: PuppetBody = puppets.get(int(h[0]), null)
			if pb != null:
				_set_hidden(pb, int(h[1]) != 0)
	bodies.end_apply()


func on_meta(msg: Dictionary) -> void:
	bodies.begin_apply()
	for row in _arr(msg.get("m", [])):
		if typeof(row) != TYPE_ARRAY or row.size() < 2 or typeof(row[1]) != TYPE_DICTIONARY:
			continue
		var eid := int(row[0])
		var changed: Dictionary = row[1]
		var pb: PuppetBody = puppets.get(eid, null)
		if pb != null:
			var n := pb.node()
			bodies.meta_sync.merge_into(pb.meta, changed)
			if n != null:
				bodies.apply_meta(n, changed, pb.pool_id)
			continue
		if pending.has(eid):
			bodies.meta_sync.merge_into(pending[eid].d.meta, changed)
			continue
		# a state-only fixture (static id)
		bodies.apply_fixture_meta(eid, changed)
	bodies.end_apply()


static func _arr(v) -> Array:
	return v if typeof(v) == TYPE_ARRAY else []


## d: parsed row {eid, pool_idx | key, p, q, l, a, flags, meta, owner, epoch}
func _spawn(d: Dictionary, is_fb: bool, host_ms: int) -> void:
	var eid := int(d.eid)
	if tombs.has(eid):
		return
	var state := {"t": host_ms, "p": d.p, "q": d.q, "l": d.l, "a": d.a,
		"flags": int(d.flags) | Codec.RF_SNAP, "epoch": int(d.get("epoch", 0)) & 0xFF}
	var existing: PuppetBody = puppets.get(eid, null)
	if existing != null:
		# a duplicate (a spawn batched before a world-snapshot cut): update it
		existing.push(state)
		active[eid] = true
		if not d.meta.is_empty():
			bodies.meta_sync.merge_into(existing.meta, d.meta)
			var n0 := existing.node()
			if n0 != null:
				bodies.apply_meta(n0, d.meta, existing.pool_id)
		return
	var node: Node3D = null
	var pid := ""
	if is_fb:
		node = bodies.fixture_node(String(d.key))
		if node == null or bodies.fixture_eid(String(d.key)) != eid:
			counters.fixture_mismatch += 1
			bodies.log_warn("fixture %s (%d) does not resolve here: ignored" % [d.key, eid])
			return
	else:
		var idx := int(d.pool_idx)
		if idx < 0 or idx >= pool_ids.size():
			counters.wsnap_rejected += 1
			return
		pid = String(pool_ids[idx])
		node = bodies.adapter.spawn(pid, d.p, Vector3.ZERO)
		if node == null:
			counters.client_pool_full += 1
			pending[eid] = {"d": d, "fb": false, "next": _now() + PENDING_RETRY_MS, "t": host_ms}
			return
		# the pool handed out a node another puppet still drives: client code recycled it
		var other := int(_by_node.get(node.get_instance_id(), 0))
		if other != 0 and other != eid and puppets.has(other):
			_on_lost(puppets[other], true)
	pending.erase(eid)
	var pb := PuppetBody.new()
	pb.eid = eid
	pb.ref = weakref(node)
	pb.kind = "fixture_body" if is_fb else "pooled"
	pb.pool_id = pid
	pb.key = String(d.get("key", ""))
	pb.owner = int(d.get("owner", 1))
	pb.last_epoch = int(d.get("epoch", 0)) & 0xFF
	puppets[eid] = pb
	if not is_fb:
		_pooled_n += 1
		_by_node[node.get_instance_id()] = eid
	node.global_transform = Transform3D(Basis(d.q as Quaternion).scaled(node.global_basis.get_scale()), d.p)
	puppetize(pb)
	if not is_fb:
		bodies.adopt(node, eid, pid)
	pb.push(state)
	active[eid] = true
	pb.last_rx_ms = _now()
	pb.has_out = false
	if not d.meta.is_empty():
		pb.meta = d.meta.duplicate(true)
		bodies.apply_meta(node, d.meta, pid)
	if int(d.flags) & Codec.RF_HIDDEN:
		_set_hidden(pb, true)
	_apply_collide_flags(pb, int(d.flags))
	# frames that overtook the spawn
	var orph: Array = orphans.get(eid, [])
	orphans.erase(eid)
	for o in orph:
		pb.push(o.state)
		counters.orphans_adopted += 1
	counters.puppets_spawned += 1
	bodies.emit_added(eid, node)


func puppetize(pb: PuppetBody) -> void:
	var node := pb.node()
	if node == null:
		return
	node.set_meta(PUPPET_META, pb.eid)
	if node is RigidBody3D:
		node.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		node.freeze = true
		node.linear_velocity = Vector3.ZERO
		node.angular_velocity = Vector3.ZERO
	_add_exception(pb)


func _add_exception(pb: PuppetBody) -> void:
	var node := pb.node()
	if pb.exception or node == null or pb.kind != "pooled":
		return
	if not node.is_in_group("product"):
		return
	if node is RigidBody3D and float(node.mass) > D22_MASS:
		return
	var player = bodies.adapter.local_player()
	if player != null and player is PhysicsBody3D and node is PhysicsBody3D:
		player.add_collision_exception_with(node)
		pb.exception = true


func _remove_exception(pb: PuppetBody) -> void:
	if not pb.exception:
		return
	pb.exception = false
	var node := pb.node()
	var player = bodies.adapter.local_player()
	if node != null and player != null and player is PhysicsBody3D and node is PhysicsBody3D:
		player.remove_collision_exception_with(node)


func despawn(eid: int) -> void:
	pending.erase(eid)
	orphans.erase(eid)
	tombs[eid] = _now() + TOMBSTONE_MS
	var pb: PuppetBody = puppets.get(eid, null)
	if pb == null:
		return
	# GRAB hears this first and drops a carry (a despawn wins over local_sim)
	bodies.emit_removed(eid)
	_forget_puppet(pb)
	var node := pb.node()
	_remove_exception(pb)
	if node != null:
		_restore_layers(pb)
		if pb.hidden:
			node.visible = true
		node.remove_meta(PUPPET_META)
		if pb.kind == "pooled":
			bodies.begin_apply()
			bodies.adapter.recycle(node)
			bodies.end_apply()
			bodies.release(eid)
		elif node is RigidBody3D:
			node.freeze = false
	counters.puppets_despawned += 1


func _forget_puppet(pb: PuppetBody) -> void:
	_end_carry(pb.eid)
	if pb.rider_of != 0:
		var cb: PuppetBody = puppets.get(pb.rider_of, null)
		if cb != null:
			cb.riders.erase(pb.eid)
		pb.rider_of = 0
	puppets.erase(pb.eid)
	active.erase(pb.eid)
	if pb.kind == "pooled":
		_pooled_n = maxi(0, _pooled_n - 1)
		var n := pb.node()
		if n != null and int(_by_node.get(n.get_instance_id(), 0)) == pb.eid:
			_by_node.erase(n.get_instance_id())
		elif n == null:
			for iid in _by_node.keys():
				if int(_by_node[iid]) == pb.eid:
					_by_node.erase(iid)
					break


## A pooled puppet whose node is no longer ours (recycled by client game code,
## or already handed to another eid): drop it without recycling the node and
## respawn the eid from its newest host state.
func _on_lost(pb: PuppetBody, node_still_ours: bool) -> void:
	var eid := pb.eid
	counters.puppet_lost += 1
	bodies.log_warn("puppet %d (pool %s) lost its node to client game code: respawned from host state" % [eid, pb.pool_id])
	bodies.emit_removed(eid)
	var node := pb.node()
	var reused := node != null and int(node.get_meta(PUPPET_META, eid)) != eid
	if reused:
		pb.ref = null              # never touch a node another puppet drives
	_forget_puppet(pb)
	_remove_exception(pb)
	if node_still_ours and node != null and not reused:
		_restore_layers(pb)
		node.remove_meta(PUPPET_META)
	if not reused:
		bodies.release(eid)
	var s := pb.newest()
	var idx := pool_ids.find(pb.pool_id)
	if s.is_empty() or idx < 0:
		return
	var flags := int(s.get("flags", 0)) & ~Codec.RF_SNAP
	if pb.hidden:
		flags |= Codec.RF_HIDDEN
	var d := {"eid": eid, "pool_idx": idx, "p": s.p, "q": s.q, "l": s.l, "a": s.a, "flags": flags,
		"meta": pb.meta.duplicate(true), "owner": pb.owner, "epoch": pb.last_epoch}
	pending[eid] = {"d": d, "fb": false, "next": 0, "t": int(s.get("t", _host_now()))}


func clear() -> void:
	for eid in puppets.keys():
		var pb: PuppetBody = puppets[eid]
		_remove_exception(pb)
		var n := pb.node()
		if n != null:
			_restore_layers(pb)
			n.remove_meta(PUPPET_META)
	puppets.clear()
	active.clear()
	carriers.clear()
	_by_node.clear()
	_pooled_n = 0
	_rr_keys.clear()
	_rr_i = 0
	tombs.clear()
	orphans.clear()
	pending.clear()
	_apply_rows.clear()
	applying = false


# ================================================================== frames (ch2, kind 4)

func on_frame(bytes: PackedByteArray) -> void:
	var f := Codec.decode_bodies(bytes)
	if f.is_empty():
		counters.decode_errors += 1
		return
	counters.frames_rx += 1
	q_rx_pkts += 1
	var seq := int(f.seq)
	if _last_seq >= 0:
		var gap := (seq - _last_seq - 1) & 0xFFFF
		if gap > 0 and gap < 1000:
			q_gaps += gap
			counters.frames_gaps += gap
		elif gap >= 1000:
			q_late += 1   # an old packet (reordered)
	if _last_seq < 0 or ((seq - _last_seq) & 0xFFFF) < 32768:
		_last_seq = seq
	var host_ms := int(f.host_ms)
	_update_jitter(host_ms)
	var now := _now()
	for r in f.records:
		counters.records_rx += 1
		var eid := int(r.eid)
		var state := {"t": host_ms, "p": r.p, "q": r.q, "l": r.l, "a": r.a, "flags": int(r.flags),
			"epoch": int(r.epoch)}
		var pb: PuppetBody = puppets.get(eid, null)
		if pb != null:
			if not pb.push(state):
				counters.late_frames += 1
			else:
				active[eid] = true
			pb.last_rx_ms = now
			_apply_collide_flags(pb, int(r.flags))
			continue
		if tombs.has(eid):
			counters.late_frames += 1
			continue
		var lst: Array = orphans.get(eid, [])
		if lst.size() < 8:
			lst.append({"rx": now, "state": state})
		orphans[eid] = lst


func _update_jitter(host_ms: int) -> void:
	var off := float(_host_now() - host_ms)
	if not _off_init:
		_off_init = true
		_off_mean = off
		return
	_off_mean += (off - _off_mean) * 0.05
	jitter_ms += (absf(off - _off_mean) - jitter_ms) * 0.1
	interp_delay = Interp.delay_for(jitter_ms, _off_mean)


func _apply_collide_flags(pb: PuppetBody, flags: int) -> void:
	var nc := (flags & Codec.RF_NOCOLLIDE) != 0
	if nc == pb.nocollide:
		return
	pb.nocollide = nc
	_sync_layers(pb)


func _set_hidden(pb: PuppetBody, on: bool) -> void:
	if pb.hidden == on:
		return
	pb.hidden = on
	var n := pb.node()
	if n != null:
		n.visible = not on
	if not on:
		pb.force_snap = true
		pb.idle = false
		active[pb.eid] = true
	_sync_layers(pb)


func _sync_layers(pb: PuppetBody) -> void:
	var n := pb.node()
	if n == null or not (n is CollisionObject3D):
		return
	var want_off := pb.hidden or pb.nocollide
	if want_off and not pb.layers_saved:
		pb.saved_layer = n.collision_layer
		pb.saved_mask = n.collision_mask
		pb.layers_saved = true
		n.collision_layer = 0
		n.collision_mask = 0
	elif not want_off and pb.layers_saved:
		_restore_layers(pb)


func _restore_layers(pb: PuppetBody) -> void:
	var n := pb.node()
	if pb.layers_saved and n != null and n is CollisionObject3D:
		n.collision_layer = pb.saved_layer
		n.collision_mask = pb.saved_mask
	pb.layers_saved = false


# ================================================================== driving (physics priority 100)

func physics_step() -> void:
	var now := _now()
	var dt := clampf(float(now - _last_drive_ms) / 1000.0, 0.0, 0.1) if _last_drive_ms > 0 else 1.0 / 60.0
	_last_drive_ms = now
	_expire(now)
	if applying:
		_apply_batch()
	if frozen:
		return
	if not carriers.is_empty():
		_carry_riders()
	var rt := _host_now() - interp_delay
	var done: Array = []
	for eid in active:
		var pb: PuppetBody = puppets.get(eid, null)
		var node: Node3D = pb.node() if pb != null else null
		if node == null:
			done.append(eid)
			continue
		if pb.local_sim:
			if pb.release_wait:
				_check_release(pb, now)
			else:
				done.append(eid)      # GRAB simulates it; back at set_local_sim(false)
			continue
		_assert_frozen(node)
		if pb.hidden or pb.idle or pb.ring.is_empty():
			done.append(eid)
			continue
		if now - pb.last_rx_ms > DRIVE_IDLE_MS and pb.has_out and pb.corr0 == Vector3.ZERO:
			done.append(eid)
			continue
		_drive(pb, node, rt, dt, now)
		if pb.idle:
			done.append(eid)
	for eid in done:
		active.erase(eid)
	_verify_some()


## Round-robin over every puppet: re-assert the freeze of the inactive ones and
## detect pooled puppets whose node client code recycled (see header).
func _verify_some() -> void:
	if puppets.is_empty():
		return
	var n := 0
	while n < VERIFY_PER_FRAME:
		if _rr_i >= _rr_keys.size():
			if n > 0:
				break                  # at most one lap per frame
			_rr_keys = puppets.keys()
			_rr_i = 0
			if _rr_keys.is_empty():
				break
		var eid = _rr_keys[_rr_i]
		_rr_i += 1
		n += 1
		var pb: PuppetBody = puppets.get(eid, null)
		if pb == null:
			continue
		var node := pb.node()
		if pb.kind == "pooled":
			if node == null or int(node.get_meta(PUPPET_META, -1)) != pb.eid:
				_on_lost(pb, false)     # freed, or the node now belongs to another eid
				continue
			if node.process_mode == Node.PROCESS_MODE_DISABLED:
				_on_lost(pb, true)      # recycled into the pool, not reused yet
				continue
		if node != null and not pb.local_sim and not active.has(eid):
			_assert_frozen(node)


func _assert_frozen(node: Node) -> void:
	if not (node is RigidBody3D):
		return
	if not node.freeze or node.freeze_mode != RigidBody3D.FREEZE_MODE_KINEMATIC:
		# game code (place(), _unfreeze()) flipped it: a puppet never simulates
		counters.puppet_unfreeze += 1
		node.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		node.freeze = true


func _drive(pb: PuppetBody, node: Node3D, rt: int, dt: float, now: int) -> void:
	var s := Interp.sample(pb.ring, rt)
	if s.is_empty():
		return
	var target: Vector3 = s.p
	var mode := String(s.mode)
	var newest := pb.newest()
	var snap := pb.force_snap or not pb.has_out
	if pb.was_snap_wait and mode != "snap_wait":
		snap = true            # the teleport record became current
	pb.was_snap_wait = mode == "snap_wait"
	var ep := int(newest.get("epoch", 0))
	if pb.last_epoch >= 0 and ep != pb.last_epoch and mode != "before":
		snap = true            # ownership changed: no blend across owners
	pb.last_epoch = ep
	if not snap and pb.out_p.distance_to(target) > SNAP_ERR:
		snap = true
	if snap:
		pb.corr0 = Vector3.ZERO
		pb.force_snap = false
		counters.snaps += 1
	else:
		var predicted := pb.prev_target + pb.prev_vel * dt
		if (target - predicted).length() > JUMP_EPS:
			# new data bent the curve: blend from where the puppet is drawn now
			pb.corr0 = pb.out_p - target
			pb.corr_start_ms = now
			counters.blends += 1
	var corr := Vector3.ZERO
	if pb.corr0 != Vector3.ZERO:
		var k := 1.0 - float(now - pb.corr_start_ms) / BLEND_MS
		if k <= 0.0:
			pb.corr0 = Vector3.ZERO
		else:
			corr = pb.corr0 * k
	var out := target + corr
	pb.prev_target = target
	pb.prev_vel = s.v
	pb.out_p = out
	pb.has_out = true
	node.global_transform = Transform3D(Basis(s.q as Quaternion).scaled(node.global_basis.get_scale()), out)
	if snap:
		# a teleport: no interpolated streak from the old pose (physics interpolation is on)
		node.reset_physics_interpolation()
	if mode == "sleep" and pb.corr0 == Vector3.ZERO:
		pb.idle = true         # exact rest pose; nothing to do until the next record


# ================================================================== local simulation (GRAB)

func set_local_sim(eid: int, on: bool, min_epoch: int) -> void:
	var pb: PuppetBody = puppets.get(eid, null)
	if pb == null:
		return
	var node := pb.node()
	active[eid] = true
	if on:
		if pb.rider_of != 0:
			# GRAB takes a rider: it is carried itself now
			var cb: PuppetBody = puppets.get(pb.rider_of, null)
			if cb != null:
				cb.riders.erase(eid)
			pb.rider_of = 0
		pb.local_sim = true
		pb.release_wait = false
		_remove_exception(pb)
		if node is RigidBody3D:
			node.freeze = false
		if not frozen:
			carriers[eid] = true
			pb.has_box = false
		return
	if not pb.local_sim:
		return
	pb.release_wait = true
	pb.min_epoch = min_epoch
	pb.release_until_ms = _now() + RELEASE_WAIT_MS
	_check_release(pb, _now())


func _check_release(pb: PuppetBody, now: int) -> void:
	var reached := pb.has_epoch_at_least(pb.min_epoch)
	if not reached and now < pb.release_until_ms:
		return
	pb.local_sim = false
	pb.release_wait = false
	var node := pb.node()
	if node == null:
		return
	var local_p: Vector3 = node.global_position
	puppetize(pb)
	pb.idle = false
	if reached:
		# blend from the local pose over 150 ms
		var s := Interp.sample(pb.ring, _host_now() - interp_delay)
		if not s.is_empty():
			pb.prev_target = s.p
			pb.prev_vel = s.v
			pb.out_p = local_p
			pb.corr0 = local_p - (s.p as Vector3)
			pb.corr_start_ms = now
			pb.has_out = true
			pb.last_epoch = int(pb.newest().get("epoch", 0))
			if pb.corr0.length() > SNAP_ERR:
				pb.corr0 = Vector3.ZERO
	else:
		pb.force_snap = true     # no record of the new epoch in time: the host state wins


# ================================================================== riders (0.2.2)

## The local player carries a body (GRAB local_sim) with puppets in or on it: a
## crate with ducks inside. A frozen KINEMATIC puppet never yields, so the
## carried body could not rise through the ducks resting in it (the second
## two-PC Steam test: the client could not pick up a crate with ducks in it).
## Every puppet the carried body touches, or that lies inside its shapes' box
## (plus room above), rides: it simulates locally like the carried body and
## moves with it, while the host's copies ride the host's follower. When the
## carry ends (the carried body is a puppet again), or the host reports a
## rider held or hidden, the rider becomes a puppet again and blends to the
## host pose.
func _carry_riders() -> void:
	_rider_k += 1
	var scan := _rider_k % RIDER_SCAN_FRAMES == 0
	for ceid in carriers.keys():
		var cb: PuppetBody = puppets.get(ceid, null)
		var cn: Node3D = cb.node() if cb != null else null
		if cb == null or cn == null or not cb.local_sim:
			_end_carry(ceid)
			continue
		for e in cb.riders.keys():
			var rb: PuppetBody = puppets.get(e, null)
			if rb == null or rb.node() == null:
				cb.riders.erase(e)
			elif not _can_ride(rb):
				_unride(rb, cb)
		if cb.owner_kind == "equipped" or cb.hidden or cb.nocollide:
			continue
		if cn is RigidBody3D and (cn as RigidBody3D).contact_monitor:
			for b in (cn as RigidBody3D).get_colliding_bodies():
				var e := int(_by_node.get(b.get_instance_id(), 0))
				if e > 0 and e != ceid:
					_ride(puppets.get(e, null), cb)
		if not scan:
			continue
		var box := _carry_box(cb, cn)
		var inv := cn.global_transform.affine_inverse()
		var at := cn.global_position
		var reach := box.get_longest_axis_size() + box.position.length() + 0.5
		for e in puppets:
			var pb: PuppetBody = puppets[e]
			if pb.local_sim or pb.kind != "pooled":
				continue
			var n := pb.node()
			if n != null and n.global_position.distance_squared_to(at) <= reach * reach \
					and box.has_point(inv * n.global_position):
				_ride(pb, cb)


func _can_ride(pb: PuppetBody) -> bool:
	return pb.kind == "pooled" and not pb.hidden and not pb.nocollide and pb.owner_kind == "" \
		and (pb.last_flags & Codec.RF_HELD) == 0 and pb.node() is RigidBody3D


func _ride(pb: PuppetBody, cb: PuppetBody) -> void:
	if pb == null or pb.local_sim or not _can_ride(pb):
		return
	var n := pb.node() as RigidBody3D
	pb.rider_of = cb.eid
	cb.riders[pb.eid] = true
	pb.local_sim = true
	pb.release_wait = false
	active[pb.eid] = true
	_remove_exception(pb)
	n.freeze = false
	var cn := cb.node() as RigidBody3D
	n.linear_velocity = cn.linear_velocity if cn != null else Vector3.ZERO
	n.angular_velocity = Vector3.ZERO
	n.sleeping = false
	counters.riders_on += 1


## Back to puppet mode, blending from the local pose to the host's (set_local_sim off).
func _unride(pb: PuppetBody, cb: PuppetBody) -> void:
	if cb != null:
		cb.riders.erase(pb.eid)
	if pb.rider_of == 0:
		return
	pb.rider_of = 0
	counters.riders_off += 1
	set_local_sim(pb.eid, false, int(pb.newest().get("epoch", 0)))


func _end_carry(ceid: int) -> void:
	if not carriers.has(ceid):
		return
	carriers.erase(ceid)
	var cb: PuppetBody = puppets.get(ceid, null)
	if cb == null:
		return
	for e in cb.riders.keys():
		var rb: PuppetBody = puppets.get(e, null)
		if rb != null:
			_unride(rb, cb)
	cb.riders.clear()


## The carried body's collision shapes as one box in its own frame, grown by
## RIDER_MARGIN_M and by RIDER_HEAD_M upward (once per carry).
func _carry_box(cb: PuppetBody, cn: Node3D) -> AABB:
	if cb.has_box:
		return cb.box
	var inv := cn.global_transform.affine_inverse()
	var box := AABB()
	var first := true
	for c in cn.find_children("*", "CollisionShape3D", true, false):
		var cs := c as CollisionShape3D
		if cs.shape == null or cs.disabled or _shape_owner(cs) != cn:
			continue
		var a: AABB = (inv * cs.global_transform) * cs.shape.get_debug_mesh().get_aabb()
		box = a if first else box.merge(a)
		first = false
	if first:
		box = AABB(Vector3(-0.3, -0.3, -0.3), Vector3(0.6, 0.6, 0.6))
	box = box.grow(RIDER_MARGIN_M)
	box.size.y += RIDER_HEAD_M
	cb.box = box
	cb.has_box = true
	return box


## The collision object a shape belongs to (an Area3D child's shapes are the area's).
static func _shape_owner(cs: Node) -> Node:
	var n := cs.get_parent()
	while n != null and not (n is CollisionObject3D):
		n = n.get_parent()
	return n


func is_local_sim(eid: int) -> bool:
	var pb: PuppetBody = puppets.get(eid, null)
	return pb != null and pb.local_sim


func host_state(eid: int) -> Dictionary:
	var pb: PuppetBody = puppets.get(eid, null)
	if pb == null or pb.ring.is_empty():
		return {}
	var s: Dictionary = pb.newest()
	return {"p": s.p, "q": s.q, "l": s.l, "a": s.a, "flags": int(s.flags), "epoch": int(s.epoch), "host_ms": int(s.t)}


## Phase 5 (D16) or ents.freeze_world: every puppet becomes a local dynamic body.
func freeze_world() -> void:
	if frozen:
		return
	frozen = true
	carriers.clear()
	for eid in puppets:
		var pb: PuppetBody = puppets[eid]
		pb.local_sim = true
		pb.release_wait = false
		_remove_exception(pb)
		_restore_layers(pb)
		pb.rider_of = 0
		pb.riders.clear()
		var n := pb.node()
		if n is RigidBody3D:
			n.freeze = false
			n.sleeping = false


# ================================================================== world snapshot apply (3.7)

func begin_wsnap(d: Dictionary) -> void:
	_apply_rows.clear()
	for row in _arr(d.get("fbodies", [])):
		_apply_rows.append([row, true])
	for row in _arr(d.get("ents", [])):
		_apply_rows.append([row, false])
	_apply_t = int(d.get("host_ms", _host_now()))
	applying = true
	_loading_prev = bodies.adapter.is_loading()
	if bool(d.get("frozen", false)):
		frozen = true


func _apply_batch() -> void:
	bodies.adapter.set_loading(true)    # spawn audio muted, as the game's own pool load does
	bodies.begin_apply()
	var n := 0
	while not _apply_rows.is_empty() and n < WorldSnapshot.BATCH:
		var item: Array = _apply_rows.pop_front()
		var is_fb: bool = item[1]
		var d := WorldSnapshot.parse_wsnap_fb(item[0]) if is_fb else WorldSnapshot.parse_wsnap_ent(item[0])
		n += 1
		if d.is_empty():
			counters.wsnap_rejected += 1
			continue
		counters.wsnap_rows += 1
		_spawn(d, is_fb, _apply_t)
	bodies.end_apply()
	if _apply_rows.is_empty():
		applying = false
		bodies.adapter.set_loading(_loading_prev)


func apply_done() -> bool:
	return not applying


# ================================================================== housekeeping

func _expire(now: int) -> void:
	if not orphans.is_empty():
		for eid in orphans.keys():
			var lst: Array = orphans[eid]
			while not lst.is_empty() and now - int(lst[0].rx) > ORPHAN_MS:
				lst.pop_front()
				counters.orphan_frames += 1
			if lst.is_empty():
				orphans.erase(eid)
	if not pending.is_empty():
		bodies.begin_apply()
		for eid in pending.keys():
			var p: Dictionary = pending[eid]
			if now >= int(p.next):
				p.next = now + PENDING_RETRY_MS
				pending.erase(eid)
				_spawn(p.d, false, int(p.t))
		bodies.end_apply()
	if not tombs.is_empty() and Engine.get_physics_frames() % 60 == 0:
		for eid in tombs.keys():
			if int(tombs[eid]) < now:
				tombs.erase(eid)


## netq (MP2 2.4), every second, ch0
func netq_due(now: int) -> bool:
	if now - _last_netq_ms < NETQ_MS:
		return false
	_last_netq_ms = now
	return true


func take_netq() -> Dictionary:
	# a reordered packet first counted as a gap (5, 7, 6: the 7 adds 1) arrives late: not lost
	var d := {"rx_pkts": q_rx_pkts, "gaps": maxi(0, q_gaps - q_late), "late": q_late, "interp_ms": interp_delay,
		"puppets": puppets.size(), "active": active.size()}
	q_rx_pkts = 0
	q_gaps = 0
	q_late = 0
	return d
