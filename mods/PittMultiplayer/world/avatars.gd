extends RefCounted
## Remote player avatars (MP-DESIGN 8.1). Each peer simulates its own player
## and sends its transform (44-byte frames, unreliable channel 2) at 20 Hz on
## change plus a 1 Hz keepalive; t_ms is in HOST time (clock offset from
## ping/pong). The host overwrites the slot with the sender's real slot and
## relays to every other in-game client. Puppets live under
## /root/World/PittMP_Avatars and get player entity ids through
## api.net.register_remote_player.

const Codec = preload("../net/codec.gd")
const Proto = preload("../net/proto.gd")
const Puppet = preload("puppet.gd")

const SEND_INTERVAL_MS := 50
const KEEPALIVE_MS := 1000
const TELEPORT_JUMP := 4.0
const CONTAINER := "PittMP_Avatars"

var session = null
var adapter = null
var active := false
var my_slot := 0
var _seq := 0
var _last_send_ms := 0
var _last_sent: Dictionary = {}
var _puppets: Dictionary = {}    # slot -> Puppet
var _container: WeakRef = null
var frames_tx := 0
var frames_rx := 0
var relayed := 0


func _init(p_session = null, p_adapter = null) -> void:
	session = p_session
	adapter = p_adapter


func start(slot: int) -> void:
	my_slot = slot
	active = true
	_last_sent = {}


func stop() -> void:
	active = false
	for s in _puppets.keys():
		_free_puppet(s)
	_puppets.clear()
	var c = _container.get_ref() if _container != null else null
	if c != null and is_instance_valid(c):
		c.queue_free()
	_container = null


func puppet_count() -> int:
	return _puppets.size()


func get_puppet(slot: int) -> Node3D:
	return _puppets.get(slot, null)


## Smallest distance from `cam_pos` to any visible puppet's capsule axis (INF
## when none). Tests / diagnostics: a puppet closer than Puppet.NEAR_HIDE is
## drawn hidden, so it can never block the local view.
func nearest_puppet_distance(cam_pos: Vector3) -> float:
	var best := INF
	for s in _puppets:
		var pup = _puppets[s]
		if pup != null and is_instance_valid(pup) and pup.visible:
			best = minf(best, pup.axis_distance(cam_pos))
	return best


## Local send (wall clock). Returns true when a frame went out.
func tick(now_ms: int) -> bool:
	if not active or session == null:
		return false
	if now_ms - _last_send_ms < SEND_INTERVAL_MS:
		return false
	var st: Dictionary = adapter.local_avatar_state()
	if st.is_empty():
		return false
	var flags := 0
	if bool(st.get("crouch", false)):
		flags |= Codec.F_CROUCH
	if bool(st.get("sprint", false)):
		flags |= Codec.F_SPRINT
	if bool(st.get("airborne", false)):
		flags |= Codec.F_AIRBORNE
	if bool(st.get("torch", false)):
		flags |= Codec.F_TORCH
	if adapter.menu_open():
		flags |= Codec.F_MENU_OPEN
	var pos: Vector3 = st.get("pos", Vector3.ZERO)
	var changed := _last_sent.is_empty() or (_last_sent.pos as Vector3).distance_to(pos) > 0.005 \
		or absf(angle_difference(float(_last_sent.yaw), float(st.yaw))) > 0.003 \
		or absf(float(_last_sent.pitch) - float(st.pitch)) > 0.003 or int(_last_sent.flags) != flags
	if not changed and now_ms - _last_send_ms < KEEPALIVE_MS:
		return false
	if not _last_sent.is_empty() and (_last_sent.pos as Vector3).distance_to(pos) > TELEPORT_JUMP:
		flags |= Codec.F_TELEPORTED
	_seq += 1
	var f := {"slot": my_slot, "flags": flags, "t_ms": session.host_now(), "pos": pos, "yaw": float(st.yaw),
		"pitch": float(st.pitch), "vel": st.get("vel", Vector3.ZERO), "seq": _seq}
	_last_sent = {"pos": pos, "yaw": float(st.yaw), "pitch": float(st.pitch), "flags": flags & ~Codec.F_TELEPORTED}
	_last_send_ms = now_ms
	session.send_avatar(Codec.encode_avatar(f))
	frames_tx += 1
	return true


## An avatar frame arrived from transport peer `from_peer`.
func on_frame(from_peer: int, frame: Dictionary, raw: PackedByteArray) -> void:
	if session == null:
		return
	frames_rx += 1
	var slot := int(frame.slot)
	if session.role == "host":
		slot = session.slot_of(from_peer)
		if slot <= 0:
			return
		frame.slot = slot
		var out := Codec.set_avatar_slot(raw, slot)
		for p in session.in_game_peers():
			if p != from_peer:
				session.send_raw(p, Proto.CH_AVATAR, out)
				relayed += 1
	if not active or slot == my_slot or slot <= 0:
		return
	# an unreliable frame can trail the roster update that removed its slot:
	# never (re)create a puppet for a slot nobody holds
	if session.player_by_slot(slot).is_empty():
		return
	var pup := _ensure_puppet(slot)
	if pup != null:
		pup.push(frame, Time.get_ticks_msec())


## Roster changed: names, and puppets of peers that left.
func on_roster(players: Array) -> void:
	var slots := {}
	for p in players:
		var s := int(p.get("slot", 0))
		slots[s] = p
	for s in _puppets.keys():
		var pup = _puppets[s]
		if not slots.has(s) or not is_instance_valid(pup) or int(pup.peer) != int(slots[s].get("peer", 0)):
			# gone, or the slot now belongs to another peer: the next frame recreates it
			_free_puppet(s)
		else:
			pup.set_player_name(String(slots[s].get("name", "")))


func remove_slot(slot: int) -> void:
	_free_puppet(slot)


func _ensure_puppet(slot: int) -> Node3D:
	if _puppets.has(slot):
		var existing = _puppets[slot]
		if is_instance_valid(existing):
			return existing
		_puppets.erase(slot)
	var c := _get_container()
	if c == null:
		return null
	var info: Dictionary = session.player_by_slot(slot)
	var pup = Puppet.new()
	pup.setup(slot, int(info.get("peer", 0)), String(info.get("name", "Player %d" % slot)), bool(info.get("is_host", false)))
	pup.clock = Callable(session, "host_now")
	c.add_child(pup)
	_puppets[slot] = pup
	session.register_puppet(pup, int(info.get("peer", 0)))
	return pup


func _free_puppet(slot: int) -> void:
	var pup = _puppets.get(slot, null)
	_puppets.erase(slot)
	if pup != null and is_instance_valid(pup):
		if session != null:
			session.unregister_puppet(pup.peer)
		pup.queue_free()


func _get_container() -> Node3D:
	var c = _container.get_ref() if _container != null else null
	if c != null and is_instance_valid(c) and c.is_inside_tree():
		return c
	var root: Node = adapter.world_root()
	if root == null:
		return null
	c = root.get_node_or_null(CONTAINER)
	if c == null:
		c = Node3D.new()
		c.name = CONTAINER
		root.add_child(c)
	_container = weakref(c)
	return c
