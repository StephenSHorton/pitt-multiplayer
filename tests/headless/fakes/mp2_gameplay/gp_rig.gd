extends RefCounted
## Host + clients of the GAMEPLAY module in one headless process: each peer has
## its own FakeApi (real Commands), FakeSession (routes ch3/ch0 to the other
## side as JSON), FakeBodies, FakeGrab and FakeGameplayAdapter (own test world).
##   var rig = GpRig.new(tree, runner)
##   var h = rig.add_host(); var c = rig.add_client(2); rig.start()
##   rig.as_peer(c)   # the static gate (MpGate.gp) now answers as the client

const Gameplay = preload("res://gamedir/mods/PittMultiplayer/gameplay/gameplay.gd")
const MpGate = preload("res://gamedir/mods/PittMultiplayer/gameplay/mp_gate.gd")
const FakeApi = preload("fake_api.gd")
const FakeSession = preload("fake_session.gd")
const FakeBodies = preload("fake_bodies.gd")
const FakeGrab = preload("fake_grab.gd")
const FakeAdapter = preload("fake_gameplay_adapter.gd")


class Peer extends RefCounted:
	var id := 1
	var role := "host"
	var api = null
	var session: Node = null
	var bodies = null
	var grab = null
	var adapter = null
	var gp = null


var tree: SceneTree = null
var parent: Node = null
var host: Peer = null
var clients: Dictionary = {}       # peer id -> Peer


func _init(p_tree: SceneTree, p_parent: Node) -> void:
	tree = p_tree
	parent = p_parent


func _make(role: String, id: int) -> Peer:
	var p := Peer.new()
	p.id = id
	p.role = role
	p.api = FakeApi.new("%s%d" % [role, id])
	p.session = FakeSession.new(p.api, role, id)
	parent.add_child(p.session)
	p.bodies = FakeBodies.new()
	p.bodies.api = p.api
	p.grab = FakeGrab.new()
	p.grab.bodies = p.bodies
	p.grab.my_peer = id
	p.adapter = FakeAdapter.new(tree, parent, "%s%d" % [role, id])
	p.adapter.api = p.api
	p.gp = Gameplay.new()
	p.gp.adapter = p.adapter
	p.session.modules = {"bodies": p.bodies, "grab": p.grab, "gameplay": p.gp}
	return p


func add_host() -> Peer:
	host = _make("host", 1)
	host.session.link = {}
	return host


func add_client(id: int = 2) -> Peer:
	var c := _make("client", id)
	clients[id] = c
	c.session.link = host.session if host != null else null
	if host != null:
		host.session.link[id] = c.session
		if not (id in host.session.in_game):
			host.session.in_game.append(id)
	return c


## on_session_start + on_world_started on every peer (host last, so the gate
## answers as the host afterwards), then each client is world-ready on the host.
func start() -> void:
	for id in clients:
		var c: Peer = clients[id]
		c.gp.on_session_start(c.session, "client")
		c.gp.on_world_started()
	if host != null:
		host.gp.on_session_start(host.session, "host")
		host.gp.on_world_started()


func as_peer(p: Peer) -> void:
	MpGate.gp = p.gp


func peers() -> Array:
	var out: Array = []
	if host != null:
		out.append(host)
	out.append_array(clients.values())
	return out


func cleanup() -> void:
	for p in peers():
		if p.gp != null and p.gp.live:
			p.gp.teardown()
		if p.adapter != null:
			p.adapter.free_all()
		if p.session != null and is_instance_valid(p.session):
			p.session.queue_free()
	host = null
	clients.clear()
	MpGate.reset()
	await tree.process_frame


## The script to instantiate for extensions/gameplay/<name>_ext.gd: the game path
## itself once PittMultiplayer took it over at boot (loading the extension file again
## would stack a second copy on top), else the extension file over the stub.
static func ext_script(name: String) -> Script:
	var path := "res://gamedir/mods/PittMultiplayer/extensions/gameplay/%s_ext.gd" % name
	var first := FileAccess.get_file_as_string(path).get_slice("\n", 0)
	var target := first.get_slice("\"", 1)
	var top: Script = load(target)
	var s := top
	while s != null:
		if s.get_script_constant_map().has("G"):
			return top        # taken over (maybe with another mod's extension stacked on top)
		s = s.get_base_script()
	return load(path)
