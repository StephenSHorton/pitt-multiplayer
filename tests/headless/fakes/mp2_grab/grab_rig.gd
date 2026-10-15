extends RefCounted
## One host and N clients of the GRAB module in one headless process:
## FakeSession + FakeNet (fake_session.gd), FakeBodies per peer, the real
## main_camera_grab_ext on the stub camera per peer, and one RigidBody3D copy
## of every test body per peer (same eid everywhere). The clock is the
## FakeNet clock; physics_tick() is driven by the rig (no Ticker node).

const Grab = preload("res://gamedir/mods/PittMultiplayer/grab/grab.gd")
const FakeSession = preload("fake_session.gd")
const FakeBodies = preload("fake_bodies.gd")
const CAM_EXT_PATH := "res://gamedir/mods/PittMultiplayer/extensions/grab/main_camera_grab_ext.gd"


## The camera script: res://scripts/main_camera.gd itself once PittMultiplayer took it over at
## boot (the grab extension is already in its chain; loading the extension file again would
## stack a second copy and count every step twice), else the extension over the stub.
static func cam_script() -> Script:
	var top: Script = load("res://scripts/main_camera.gd")
	var s := top
	while s != null:
		if s.get_script_method_list().any(func(m): return String(m.name) == "_mp_grab"):
			return top
		s = s.get_base_script()
	return load(CAM_EXT_PATH)


class Peer extends RefCounted:
	var id := 1
	var session = null
	var grab = null
	var bodies = null
	var cam: Camera3D = null
	var nodes: Dictionary = {}       # eid -> RigidBody3D
	var changes: Array = []          # owner_changed emissions [eid, owner, kind, epoch]


var net = FakeSession.FakeNet.new()
var parent: Node = null
var host: Peer = null
var clients: Array = []
var peers: Dictionary = {}           # id -> Peer
var _had_meta := false
var _prev_meta = null


func _init(p_parent: Node, n_clients: int = 1) -> void:
	_had_meta = Engine.has_meta("pitt_mp")
	_prev_meta = Engine.get_meta("pitt_mp", null) if _had_meta else null
	parent = Node3D.new()
	parent.name = "GrabRig"
	p_parent.add_child(parent)
	host = _make(1, "host")
	for i in n_clients:
		clients.append(_make(2 + i, "client"))
	for cl in clients:
		host.session.in_game.append(cl.id)
	for p in peers.values():
		p.grab.on_session_start(p.session, p.session.role)
		p.grab.on_world_started()
	# everyone stands at the origin by default
	for p in peers.values():
		pose(p.id, Vector3.ZERO)


func _make(id: int, role: String) -> Peer:
	var p := Peer.new()
	p.id = id
	p.session = FakeSession.new(role, id)
	net.add(p.session)
	p.bodies = FakeBodies.new()
	p.grab = Grab.new()
	p.grab.auto_ticker = false
	p.grab.now_fn = net.now
	p.session.register_module(p.bodies)
	p.session.register_module(p.grab)
	p.cam = cam_script().new()
	p.cam.name = "Cam%d" % id
	parent.add_child(p.cam)
	p.grab.adapter.camera_override = p.cam
	p.grab.owner_changed.connect(func(eid, o, k, e): p.changes.append([eid, o, k, e]))
	peers[id] = p
	return p


func c(i: int = 0) -> Peer:
	return clients[i]


## Avatar pose of peer `id` as every peer sees it (camera follows on its own peer).
func pose(id: int, pos: Vector3) -> void:
	for p in peers.values():
		p.session.set_pose(id, pos)
	var me: Peer = peers[id]
	me.cam.global_position = pos + Vector3(0, 0.65, 0)


## A body with eid on every peer (host: dynamic, clients: puppet = frozen kinematic).
func body(eid: int, pos: Vector3 = Vector3(0, 0.65, -1.5), product: bool = true, script: Script = null) -> void:
	for p in peers.values():
		var b: RigidBody3D = script.new() if script != null else RigidBody3D.new()
		b.name = "B%d_%d" % [eid, p.id]
		b.gravity_scale = 0.0
		b.add_to_group("draggable")
		if product:
			b.add_to_group("product")
		if p.session.role == "client":
			b.set_freeze_mode(RigidBody3D.FREEZE_MODE_KINEMATIC)
			b.freeze = true
			b.set_meta("pitt_mp_puppet", eid)
		parent.add_child(b)
		b.global_position = pos
		p.nodes[eid] = b
		p.bodies.add(eid, b)


## Make peer `p` the one the extension sees (Engine meta "pitt_mp").
func as_peer(p: Peer) -> void:
	Engine.set_meta("pitt_mp", p.session)


func grab_body(p: Peer, eid: int) -> void:
	as_peer(p)
	p.cam._begin_carry(p.nodes[eid])


## One step: clock + ms, physics frame on every peer, deliver, tick.
func step(ms: int = 16) -> void:
	net.advance(ms)
	for p in peers.values():
		as_peer(p)
		p.grab.physics_tick()
	net.pump()
	for p in peers.values():
		p.grab.tick(net.clock_ms)


func steps(n: int, ms: int = 16) -> void:
	for i in n:
		step(ms)


func deliver() -> void:
	net.pump()


func own_msgs(to: int, ev: String = "") -> Array:
	var out: Array = []
	for m in net.sent("own", to):
		if ev == "" or String(m.ev) == ev:
			out.append(m)
	return out


func cleanup() -> void:
	for p in peers.values():
		p.grab.teardown()
	if _had_meta:
		Engine.set_meta("pitt_mp", _prev_meta)
	elif Engine.has_meta("pitt_mp"):
		Engine.remove_meta("pitt_mp")
	if is_instance_valid(parent):
		parent.queue_free()
