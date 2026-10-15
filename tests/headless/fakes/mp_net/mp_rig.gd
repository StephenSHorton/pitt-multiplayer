extends RefCounted
## Builds host + clients in one headless process over transport_loopback, each
## peer with its own FakeApi (real Commands), StubLobby and FakeGameAdapter.
##   var rig = MpRig.new(tree, parent)
##   var h = rig.add_host(); var c = rig.add_client()
##   await rig.until(func(): return c.session.get_state() == "in_game")

const Session = preload("res://gamedir/mods/PittMultiplayer/net/session.gd")
const Loopback = preload("res://gamedir/mods/PittMultiplayer/net/transport_loopback.gd")
const FakeApi = preload("fake_api.gd")
const StubLobby = preload("stub_lobby.gd")
const FakeAdapter = preload("fake_game_adapter.gd")

const VERSION := {"pitt_version": "1.0.8", "pittapi_version": "1.1.0", "mp_proto": 1, "mods_hash": "abcd1234abcd1234"}


class Peer extends RefCounted:
	var name := ""
	var api = null
	var lobby: Node = null
	var adapter = null
	var session: Node = null
	var ended: Array = []
	var states: Array = []


var tree: SceneTree = null
var parent: Node = null
var hub = null
var peers: Array = []
var _n := 0


func _init(p_tree: SceneTree, p_parent: Node, seed_value: int = 7) -> void:
	tree = p_tree
	parent = p_parent
	hub = Loopback.Hub.new(seed_value)


func make_peer(pname: String, config: Dictionary = {}) -> Peer:
	_n += 1
	var p := Peer.new()
	p.name = pname
	p.api = FakeApi.new(pname)
	p.lobby = StubLobby.new()
	p.lobby.name = "StubLobby_%s_%d" % [pname, _n]
	p.lobby.local_name = pname
	parent.add_child(p.lobby)
	p.adapter = FakeAdapter.new(pname, tree)
	p.adapter.api = p.api
	var cfg := {"version": VERSION.duplicate(), "data_dir": p.api.data_dir()}
	for k in config:
		cfg[k] = config[k]
	p.session = Session.new(p.api, p.lobby, p.adapter, cfg)
	p.session.name = "Session_%s_%d" % [pname, _n]
	parent.add_child(p.session)
	p.session.ended.connect(func(r, d): p.ended.append([r, d]))
	p.session.state_changed.connect(func(s, _i): p.states.append(s))
	peers.append(p)
	return p


## Hosts a loopback lobby; optionally enters a running world at `phase`.
func add_host(config: Dictionary = {}, world_phase: int = -1) -> Peer:
	var h := make_peer("host", config)
	h.lobby.enter({"id": "loop:1", "owner_id": "loop:1", "is_owner": true}, {"kind": "loopback", "role": "host", "hub": hub})
	if world_phase >= 0:
		start_host_world(h, world_phase)
	return h


func start_host_world(h: Peer, phase: int = 1) -> void:
	h.session.start_game()
	h.session.notify_host_launch("res://scenes/world.tscn")
	h.adapter.enter_world(phase, parent)


func add_client(pname: String = "", config: Dictionary = {}) -> Peer:
	var c := make_peer(pname if pname != "" else "client%d" % _n, config)
	c.lobby.enter({"id": "loop:1", "owner_id": "loop:1", "is_owner": false}, {"kind": "loopback", "role": "client", "hub": hub})
	return c


## Waits (frames) until cond() is true or timeout_s passes. Returns cond().
func until(cond: Callable, timeout_s: float = 5.0) -> bool:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - t0 > int(timeout_s * 1000.0):
			return false
		await tree.process_frame
	return true


func frames(n: int) -> void:
	for i in n:
		await tree.process_frame


func ms(t: int) -> void:
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < t:
		await tree.process_frame


func cleanup() -> void:
	for p in peers:
		if p.session != null and is_instance_valid(p.session):
			if p.session.is_live():
				p.session.leave()
	await frames(2)
	for p in peers:
		if p.session != null and is_instance_valid(p.session):
			p.session.queue_free()
		if p.lobby != null and is_instance_valid(p.lobby):
			p.lobby.queue_free()
		if p.adapter != null:
			p.adapter.free_all()
	peers.clear()
	await frames(2)
