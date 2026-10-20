extends RefCounted
## PittEntities: stable integer ids for game objects.
##   - pooled objects: allocated by the authority from a per-session counter
##     (starts at 1000; 1..999 are reserved for peers/players). A pooled node that
##     is recycled and reused gets a NEW id.
##   - static fixtures: id = hash of a deterministic key, so every peer computes
##     the same id without negotiation:  (abs(hash(key)) % 2^31) | (1 << 31)
##   - mod-tracked nodes: allocated like pooled ones.
##   - players: id = player slot 1..999 (register_player). The local single-player
##     player is slot 1; a future session maps each peer to a slot.
## Only the authority allocates dynamic ids; a non-authority peer's reconciler and
## dynamic track() do nothing (ids will arrive from the host).
## Mods get a View (read access + track/untrack of their own nodes); the
## mutators below are internal to PittAPI.
## Game-side spawns are found by the pool reconciler (diff of
## ObjectPoolManager._pools[*].active). Visibility alone is NOT a despawn: the
## cannon hides stored bodies.
## PittAPI 1.2 (provider only, through api.net):
##   L7 adopt()/release(): a non-authority peer binds a node to a host id.
##   L8 set_reconcile_mode(): full diff every physics frame, and reuse detection
##      (a pooled node recycled and respawned between two reconciles, seen as a
##      hide -> show pair of visibility_changed, gets despawn + spawn, new id).
##   L9 entity.spawned carries reused: bool.
## P10 (host CPU, MP2-DESIGN 3.2 L8): with full_every_frame on, the full diff
## is gated. Every physics frame a cheap per-pool signature (active size plus the
## instance id of the last active node; spawn appends there) is compared, and the
## full diff runs only when it changed, when a watched pooled node changed
## visibility or left the tree, when the registry changed outside a diff, on a
## pending reuse, on force, or as a safety net every gated_full_interval (1 s).
## gate_full_diff = false (PittAPI setting entity_reconcile_gate) restores the
## literal full diff every frame.

const META := "pittapi_eid"
const FIRST_DYNAMIC_ID := 1000
const MAX_PLAYER_SLOT := 999
const STATIC_BIT := 1 << 31

var _core: Object = null
var _by_id: Dictionary = {}     # id -> {id, kind, ref: WeakRef, pool_id, key, owner, iid}
var _by_iid: Dictionary = {}    # instance id -> entity id
var _next_id := FIRST_DYNAMIC_ID
var _player_slots: Dictionary = {}   # peer id -> slot (1..999)
var _last_total := -1
var _since_full := 0.0
var full_interval := 0.25
var emit_events := true
## L8 (set_reconcile_mode)
var full_every_frame := false
var detect_reuse := false
var reuse_detected := 0
var _vis: Dictionary = {}       # pooled entity id -> {cb: Callable, hid: bool, reused: bool}
## P10 gate (see the header)
var gate_full_diff := true
var _gate_explicit := false     # a set_reconcile_mode call passed gate_full_diff
var gated_full_interval := 1.0
var full_diffs := 0             # full set diffs run (measurement)
var reconcile_calls := 0        # reconcile() calls that reached the pools
var _dirty := true
var _sig := PackedInt64Array()
var _reuse_pending := false
var _vis_touched: Dictionary = {}   # ids whose hid/reused flags were set since the last clear


func _init(core: Object = null) -> void:
	_core = core


static func static_id(key: String) -> int:
	return (absi(key.hash()) % 2147483648) | STATIC_BIT


func _alloc_id() -> int:
	var id := _next_id
	_next_id += 1
	return id


## Dynamic ids are handed out by the authority only.
func can_allocate() -> bool:
	if _core == null or not ("authority" in _core) or _core.authority == null:
		return true
	return bool(_core.authority.is_authority())


## Player slot for a peer: the local authority (peer 1) is slot 1; other peers
## get the next free slot. 0 when all 999 slots are taken.
func player_slot_for(peer_id: int) -> int:
	if _player_slots.has(peer_id):
		return int(_player_slots[peer_id])
	var used := {}
	for p in _player_slots:
		used[int(_player_slots[p])] = true
	var slot := 1 if peer_id == 1 and not used.has(1) else 0
	if slot == 0:
		for i in range(2 if peer_id != 1 else 1, MAX_PLAYER_SLOT + 1):
			if not used.has(i):
				slot = i
				break
	if slot == 0:
		return 0
	_player_slots[peer_id] = slot
	return slot


## Tracks a player node under the reserved id of its peer's slot (1..999).
func register_player(node: Node, peer_id: int = 1) -> int:
	if node == null or not is_instance_valid(node):
		return 0
	var slot := player_slot_for(peer_id)
	if slot == 0:
		return 0
	var existing := id_of(node)
	if existing == slot:
		return slot
	if existing != 0:
		_forget(existing)
	if _by_id.has(slot):
		_forget(slot)
	_put(slot, node, "player", "", "player:%d" % peer_id, "PittAPI")
	return slot


## L6: a remote player's puppet gets the player id of its peer's slot (2..999 on
## this machine; the local player keeps its own slot). 0 when the peer is the
## local one or no slot is free.
func register_remote_player(node: Node, peer_id: int) -> int:
	if node == null or not is_instance_valid(node) or peer_id <= 0:
		return 0
	var local := 1
	if _core != null and "authority" in _core and _core.authority != null:
		local = int(_core.authority.local_peer_id())
	if peer_id == local:
		return 0
	if not _player_slots.has(peer_id):
		# remote players never take slot 1 (the host / single-player id)
		var used := {1: true}
		for p in _player_slots:
			used[int(_player_slots[p])] = true
		for i in range(2, MAX_PLAYER_SLOT + 1):
			if not used.has(i):
				_player_slots[peer_id] = i
				break
		if not _player_slots.has(peer_id):
			return 0
	var slot := int(_player_slots[peer_id])
	var existing := id_of(node)
	if existing == slot:
		return slot
	if existing != 0:
		_forget(existing)
	if _by_id.has(slot):
		_forget(slot)
	_put(slot, node, "player", "", "player:%d" % peer_id, "PittAPI")
	return slot


func unregister_remote_player(peer_id: int) -> void:
	if not _player_slots.has(peer_id):
		return
	var slot := int(_player_slots[peer_id])
	_player_slots.erase(peer_id)
	if key_of(slot) == "player:%d" % peer_id:
		_forget(slot)


func id_of(node: Object) -> int:
	if node == null or not is_instance_valid(node):
		return 0
	var iid := node.get_instance_id()
	var id := int(_by_iid.get(iid, 0))
	if id == 0:
		return 0
	var e = _by_id.get(id, null)
	if e == null or e.ref.get_ref() != node:
		return 0
	return id


func get_node(entity_id: int) -> Node:
	var e = _by_id.get(entity_id, null)
	if e == null:
		return null
	var n = e.ref.get_ref()
	if n == null or not is_instance_valid(n):
		_forget(entity_id)
		return null
	return n


func key_of(entity_id: int) -> String:
	var e = _by_id.get(entity_id, null)
	return "" if e == null else String(e.key)


func kind_of(entity_id: int) -> String:
	var e = _by_id.get(entity_id, null)
	return "" if e == null else String(e.kind)


## Mods tracking their own nodes (kind "mod"), or fixtures with a static key.
func track(node: Node, static_key: String = "", owner: String = "") -> int:
	if node == null or not is_instance_valid(node):
		return 0
	var existing := id_of(node)
	if existing != 0:
		return existing
	if static_key == "" and not can_allocate():
		return 0
	var id := static_id(static_key) if static_key != "" else _alloc_id()
	if _by_id.has(id):
		var other = get_node(id)
		if other != null and other != node:
			# deterministic key collision: keep the first node, refuse the second
			return 0
	_put(id, node, "static" if static_key != "" else "mod", "", static_key, owner)
	return id


func untrack(entity_id: int) -> void:
	_forget(entity_id)


## Registers a pooled node (from an API spawn or the reconciler) and emits entity.spawned.
func register_pooled(node: Node, pool_id: String, source: String = "game", reused: bool = false) -> int:
	var existing := id_of(node)
	if existing != 0 and kind_of(existing) == "pooled":
		return existing
	if existing != 0:
		_forget(existing)
	if not can_allocate():
		return 0
	var id := _alloc_id()
	_put(id, node, "pooled", pool_id, "", "")
	_emit_spawned(id, node, pool_id, source, reused)
	return id


func _emit_spawned(id: int, node: Node, pool_id: String, source: String, reused: bool) -> void:
	if emit_events and _core != null and _core.events != null:
		var pos = node.global_position if node is Node3D and node.is_inside_tree() else Vector3.ZERO
		_core.events.emit_internal("entity.spawned", {"entity_id": id, "pool_id": pool_id, "position": pos,
			"loading": _is_loading(), "reused": reused}, source)


# ------------------------------------------------------------------ L7 adopt / release (non-authority)

## Binds `node` to an id the authority assigned (pooled id >= 1000, or a static
## id with STATIC_BIT). Pooled adoptions emit entity.spawned (source "net").
## Refused on the authority (ERR_UNAUTHORIZED) and for an id bound to another
## live node (ERR_ALREADY_EXISTS).
func adopt(node: Node, entity_id: int, pool_id_or_key: String, source: String = "net") -> Error:
	if node == null or not is_instance_valid(node) or entity_id <= MAX_PLAYER_SLOT:
		return ERR_INVALID_PARAMETER
	if can_allocate():
		return ERR_UNAUTHORIZED
	if _by_id.has(entity_id):
		var other = get_node(entity_id)
		if other != null and other != node:
			return ERR_ALREADY_EXISTS
	var existing := id_of(node)
	if existing == entity_id:
		return OK
	if existing != 0:
		_forget(existing)
	if (entity_id & STATIC_BIT) != 0:
		_put(entity_id, node, "static", "", pool_id_or_key, "net")
		return OK
	_put(entity_id, node, "pooled", pool_id_or_key, "", "net")
	# a later single-player allocation never reuses an adopted id
	_next_id = maxi(_next_id, entity_id + 1)
	_emit_spawned(entity_id, node, pool_id_or_key, source, false)
	return OK


## Drops an adopted id (pooled: emits entity.despawned, source "net").
func release(entity_id: int, source: String = "net") -> void:
	var e = _by_id.get(entity_id, null)
	if e == null:
		return
	if String(e.kind) == "pooled":
		despawned(entity_id, source)
	else:
		_forget(entity_id)


# ------------------------------------------------------------------ L8 reconcile mode

## {full_every_frame: bool, detect_reuse: bool, gate_full_diff: bool}; missing
## keys keep their value. gate_full_diff follows the PittAPI setting
## entity_reconcile_gate (P10, the durable switch, re-read on each call) until a
## call passes gate_full_diff explicitly; from then on the explicit value sticks
## for the life of this registry, so a later plain {full_every_frame,
## detect_reuse} call (bodies.gd host start and teardown) does not undo it.
func set_reconcile_mode(mode: Dictionary) -> void:
	var was := _watching()
	full_every_frame = bool(mode.get("full_every_frame", full_every_frame))
	detect_reuse = bool(mode.get("detect_reuse", detect_reuse))
	if mode.has("gate_full_diff"):
		gate_full_diff = bool(mode.gate_full_diff)
		_gate_explicit = true
	elif not _gate_explicit and _core != null and _core.has_method("setting"):
		gate_full_diff = bool(_core.setting("entity_reconcile_gate", true))
	_dirty = true
	var want := _watching()
	if want == was:
		return
	for id in _by_id.keys():
		if String(_by_id[id].kind) != "pooled":
			continue
		if want:
			_watch_vis(id)
		else:
			_unwatch_vis(id)


## P10: the full diff is gated on observed changes (host mode with the gate on).
func _gated() -> bool:
	return full_every_frame and gate_full_diff


## Pooled nodes are watched (visibility_changed, tree_exiting) for L8 reuse
## detection and for the P10 dirty flag.
func _watching() -> bool:
	return detect_reuse or _gated()


func _watch_vis(id: int) -> void:
	if _vis.has(id):
		return
	var n = get_node(id)
	if n == null or not n.has_signal("visibility_changed"):
		return
	var cb := _on_vis.bind(id)
	n.visibility_changed.connect(cb)
	if not n.tree_exiting.is_connected(_on_exit):
		n.tree_exiting.connect(_on_exit)
	_vis[id] = {"cb": cb, "hid": false, "reused": false}


func _unwatch_vis(id: int) -> void:
	var v = _vis.get(id, null)
	if v == null:
		return
	_vis.erase(id)
	var e = _by_id.get(id, null)
	var n = e.ref.get_ref() if e != null else null
	if n != null and is_instance_valid(n):
		if n.visibility_changed.is_connected(v.cb):
			n.visibility_changed.disconnect(v.cb)
		if n.tree_exiting.is_connected(_on_exit):
			n.tree_exiting.disconnect(_on_exit)


## A recycle hides the node and a spawn shows it (the pool's deactivate /
## activate), so any visibility change marks the set dirty (P10).
func _on_vis(id: int) -> void:
	_dirty = true
	if not detect_reuse:
		return
	var v = _vis.get(id, null)
	var n = get_node(id)
	if v == null or n == null:
		return
	if not bool(n.visible):
		v.hid = true
		_vis_touched[id] = true
	elif bool(v.hid):
		v.reused = true
		_reuse_pending = true
		_vis_touched[id] = true


## A tracked pooled node freed or moved out of the tree (P10 dirty flag).
func _on_exit() -> void:
	_dirty = true


## True when the pooled node of `id` went hidden then visible since the last
## reconcile and is not stored in a cannon or a vacuum bag.
func _was_reused(id: int, node: Node) -> bool:
	var v = _vis.get(id, null)
	if v == null or not bool(v.reused) or not bool(node.visible):
		return false
	return not (node.has_meta("in_cannon_barrel") or node.has_meta("in_vacuum_bag"))


## O(1): set by _on_vis when a flag turns reused (P10; was a scan of _vis).
func _any_reused() -> bool:
	return _reuse_pending


## Clears only the flags _on_vis set since the last clear (P10; was a scan of _vis).
func _clear_vis_flags() -> void:
	for id in _vis_touched:
		var v = _vis.get(id, null)
		if v != null:
			v.hid = false
			v.reused = false
	_vis_touched.clear()
	_reuse_pending = false


## Removes a pooled entity and emits entity.despawned.
func despawned(entity_id: int, source: String = "game") -> void:
	var e = _by_id.get(entity_id, null)
	if e == null:
		return
	var pool_id: String = e.pool_id
	_forget(entity_id)
	if emit_events and _core != null and _core.events != null:
		_core.events.emit_internal("entity.despawned", {"entity_id": entity_id, "pool_id": pool_id}, source)


func describe(entity_id: int) -> Dictionary:
	var e = _by_id.get(entity_id, null)
	if e == null:
		return {}
	var n = get_node(entity_id)
	if n == null:
		return {}
	var d := {"id": entity_id, "kind": e.kind, "pool_id": e.pool_id, "key": e.key, "owner": e.owner,
		"name": String(n.name), "class": n.get_class()}
	if n is Node3D and n.is_inside_tree():
		d["position"] = n.global_position
		d["rotation"] = n.global_rotation
	if "value" in n:
		var v = n.get("value")
		if typeof(v) in [TYPE_INT, TYPE_FLOAT]:
			d["value"] = v
	var metas := {}
	for m in ["gambled", "tint_color", "crude_source", "starter_crate", "consumed", "pending_maw_recycle", "in_cannon_barrel"]:
		if n.has_meta(m):
			metas[m] = n.get_meta(m)
	d["metas"] = metas
	return d


## filter: {pool_id, kind, within: {center: [x,y,z], radius}}
func list(filter: Dictionary = {}) -> Array[int]:
	var out: Array[int] = []
	var center = null
	var radius := 0.0
	if filter.has("within") and typeof(filter.within) == TYPE_DICTIONARY:
		var Serial = preload("serial.gd")
		center = Serial.vec3_from(filter.within.get("center", null))
		radius = float(filter.within.get("radius", 0.0))
	for id in _by_id.keys():
		var e = _by_id[id]
		if filter.has("pool_id") and e.pool_id != filter.pool_id:
			continue
		if filter.has("kind") and e.kind != filter.kind:
			continue
		var n = get_node(id)
		if n == null:
			continue
		if center != null:
			if not (n is Node3D) or not n.is_inside_tree() or n.global_position.distance_to(center) > radius:
				continue
		out.append(id)
	out.sort()
	return out


func count(kind: String = "") -> int:
	if kind == "":
		return _by_id.size()
	var n := 0
	for id in _by_id:
		if _by_id[id].kind == kind:
			n += 1
	return n


## Drops every entity (world exit). Pooled nodes get new ids when seen again.
func clear_all() -> void:
	for id in _by_id.keys():
		var n = _by_id[id].ref.get_ref()
		if n != null and is_instance_valid(n) and n.has_meta(META):
			n.remove_meta(META)
	for id in _vis.keys():
		_unwatch_vis(id)
	_by_id.clear()
	_by_iid.clear()
	_player_slots.clear()
	_vis_touched.clear()
	_reuse_pending = false
	_last_total = -1
	_sig = PackedInt64Array()
	_dirty = true


## Pool reconciler. Cheap total-count check every physics frame; full set diff
## when the total changed or every full_interval seconds. With full_every_frame
## on: the P10 gate (header), or a full diff every frame when gate_full_diff is off.
func reconcile(delta: float, force: bool = false) -> void:
	if not can_allocate():
		_clear_vis_flags()
		return
	var pm = _pool_manager()
	if pm == null:
		return
	if not bool(pm.get("_initialized")):
		return
	var pools = pm.get("_pools")
	if typeof(pools) != TYPE_DICTIONARY:
		return
	reconcile_calls += 1
	var gated := _gated()
	force = force or _any_reused() or (full_every_frame and not gated)
	_since_full += delta
	var total := 0
	var sig := PackedInt64Array()
	for pid in pools:
		var pool = pools[pid]
		if pool == null:
			continue
		var act = pool.active
		total += act.size()
		if gated:
			# spawn appends: a same-size swap moves the last node (or shows a watched one)
			var last = act[act.size() - 1] if act.size() > 0 else null
			sig.append(act.size())
			sig.append(last.get_instance_id() if is_instance_valid(last) else 0)
	if not force:
		if gated:
			if not _dirty and sig == _sig and _since_full < gated_full_interval:
				return
		elif total == _last_total and _since_full < full_interval:
			return
	_last_total = total
	_sig = sig
	_since_full = 0.0
	# cleared before the diff: a change made during it (an event handler) runs one more
	_dirty = false
	full_diffs += 1
	var seen: Dictionary = {}
	for pid in pools:
		var pool = pools[pid]
		if pool == null:
			continue
		for obj in pool.active:
			if obj == null or not is_instance_valid(obj):
				continue
			var iid: int = obj.get_instance_id()
			seen[iid] = true
			var id := id_of(obj)
			if id != 0 and detect_reuse and kind_of(id) == "pooled" and _was_reused(id, obj):
				# L8: recycled and respawned within one frame -> despawn + spawn, new id
				reuse_detected += 1
				despawned(id, "game")
				register_pooled(obj, String(pid), "game", true)
			elif id == 0 or kind_of(id) != "pooled":
				register_pooled(obj, String(pid), "game")
	_clear_vis_flags()
	for id in _by_id.keys():
		var e = _by_id.get(id, null)
		if e == null or e.kind != "pooled":
			continue
		var n = e.ref.get_ref()
		if n == null or not is_instance_valid(n) or not seen.has(e.iid):
			despawned(id, "game")


func _put(id: int, node: Node, kind: String, pool_id: String, key: String, owner: String) -> void:
	var iid := node.get_instance_id()
	_by_id[id] = {"id": id, "kind": kind, "ref": weakref(node), "pool_id": pool_id, "key": key,
		"owner": owner, "iid": iid}
	_by_iid[iid] = id
	node.set_meta(META, id)
	_dirty = true
	if kind == "pooled" and _watching():
		_watch_vis(id)


func _forget(entity_id: int) -> void:
	var e = _by_id.get(entity_id, null)
	if e == null:
		return
	_unwatch_vis(entity_id)
	_dirty = true
	_by_id.erase(entity_id)
	if int(_by_iid.get(e.iid, 0)) == entity_id:
		_by_iid.erase(e.iid)
	var n = e.ref.get_ref()
	if n != null and is_instance_valid(n) and n.has_meta(META) and int(n.get_meta(META)) == entity_id:
		n.remove_meta(META)


func _pool_manager() -> Object:
	if _core == null or not _core.has_method("g"):
		return null
	if _core.has_method("feature_ok") and not _core.feature_ok("spawn"):
		return null
	return _core.g("ObjectPoolManager")


func _is_loading() -> bool:
	if _core == null or not _core.has_method("g"):
		return false
	var sm = _core.g("SaveManager")
	return sm != null and "is_loading" in sm and bool(sm.is_loading)


func owner_of(entity_id: int) -> String:
	var e = _by_id.get(entity_id, null)
	return "" if e == null else String(e.owner)


## The per-mod view handed to mods as api.entities: lookups plus track/untrack
## of the mod's own nodes. clear_all, register_pooled, despawned and untrack of
## other owners' entities stay internal (use the entity.* commands to mutate).
class View extends RefCounted:
	var _reg = null
	var _mod := ""

	func _init(reg, mod_id: String) -> void:
		_reg = reg
		_mod = mod_id

	func id_of(node: Object) -> int:
		return _reg.id_of(node)

	func get_node(entity_id: int) -> Node:
		return _reg.get_node(entity_id)

	func key_of(entity_id: int) -> String:
		return _reg.key_of(entity_id)

	func kind_of(entity_id: int) -> String:
		return _reg.kind_of(entity_id)

	func owner_of(entity_id: int) -> String:
		return _reg.owner_of(entity_id)

	func describe(entity_id: int) -> Dictionary:
		return _reg.describe(entity_id)

	func list(filter: Dictionary = {}) -> Array[int]:
		return _reg.list(filter)

	func count(kind: String = "") -> int:
		return _reg.count(kind)

	func static_id(key: String) -> int:
		return _reg.static_id(key)

	## Tracks a node this mod created (kind "mod", owner = this mod). With
	## static_key the id is deterministic; keys are namespaced "mod:<mod>:<key>".
	func track(node: Node, static_key: String = "") -> int:
		var key := "" if static_key == "" else "mod:%s:%s" % [_mod, static_key]
		return _reg.track(node, key, _mod)

	## Only entities this mod tracked. Returns false otherwise.
	func untrack(entity_id: int) -> bool:
		if _reg.owner_of(entity_id) != _mod or _reg.kind_of(entity_id) == "pooled":
			return false
		_reg.untrack(entity_id)
		return true
