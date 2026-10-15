extends "res://tests/fakes/mp_net/mp_rig.gd"
## MpRig with the MP2 shared world: every peer gets its own physics world (a
## SubViewport with its own World3D), its own fake ObjectPoolManager, a real
## loader entity registry (L7-L9) driven every physics frame, the REAL BODIES
## module and BODIES' doubles of GAMEPLAY and GRAB, registered in 10.1 order.
##   var rig = Mp2Rig.new(tree, runner)
##   var h = rig.add_host({}, 1); var c = rig.add_client()
##   var duck = rig.spawn(h, "duck", Vector3(0, 1, 0))

const FakeApi2 = preload("fake_api2.gd")
const Mp2Adapter = preload("mp2_game_adapter.gd")
const FakeBodiesAdapter = preload("fake_bodies_adapter.gd")
const FakePools = preload("fake_pools.gd")
const PeerDriver = preload("peer_driver.gd")
const FakeGrab = preload("fake_grab.gd")
const FakeGameplay = preload("fake_gameplay.gd")
const Bodies = preload("res://gamedir/mods/PittMultiplayer/world/bodies/bodies.gd")


class Peer2 extends Peer:
	var bodies = null
	var badapter = null
	var pools = null
	var viewport: SubViewport = null
	var world: Node3D = null
	var player: CharacterBody3D = null
	var grab = null
	var gameplay = null
	var driver: Node = null


var with_modules := true
var gravity := true


func make_peer(pname: String, config: Dictionary = {}) -> Peer:
	_n += 1
	var p := Peer2.new()
	p.name = pname
	p.api = FakeApi2.new(pname)
	p.lobby = StubLobby.new()
	p.lobby.name = "StubLobby_%s_%d" % [pname, _n]
	p.lobby.local_name = pname
	parent.add_child(p.lobby)
	p.adapter = Mp2Adapter.new(pname, tree)
	p.adapter.api = p.api
	_build_world(p)
	p.api.attach_pools(p.pools)
	p.badapter = FakeBodiesAdapter.new()
	p.badapter.setup(p.api)
	p.badapter.pm = p.pools
	p.badapter.world = p.world
	p.badapter.player = p.player
	p.driver = PeerDriver.new(p.api)
	p.driver.name = "PeerDriver_%s_%d" % [pname, _n]
	parent.add_child(p.driver)
	var cfg := {"version": VERSION.duplicate(), "data_dir": p.api.data_dir()}
	for k in config:
		cfg[k] = config[k]
	p.session = Session.new(p.api, p.lobby, p.adapter, cfg)
	p.session.name = "Session_%s_%d" % [pname, _n]
	parent.add_child(p.session)
	if with_modules:
		p.bodies = Bodies.new(p.api, p.badapter)
		p.bodies.name = "Bodies_%s_%d" % [pname, _n]
		parent.add_child(p.bodies)
		p.gameplay = FakeGameplay.new()
		p.grab = FakeGrab.new()
		p.session.register_module(p.bodies)
		p.session.register_module(p.gameplay)
		p.session.register_module(p.grab)
	p.session.ended.connect(func(r, d): p.ended.append([r, d]))
	p.session.state_changed.connect(func(s, _i): p.states.append(s))
	peers.append(p)
	return p


func _build_world(p: Peer2) -> void:
	p.viewport = SubViewport.new()
	p.viewport.own_world_3d = true
	p.viewport.name = "BodiesWorld_%s_%d" % [p.name, _n]
	p.viewport.size = Vector2i(8, 8)
	p.viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	parent.add_child(p.viewport)
	p.world = Node3D.new()
	p.world.name = "World"
	p.viewport.add_child(p.world)
	var floor := StaticBody3D.new()
	floor.name = "Floor"
	var fcs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(400, 1, 400)
	fcs.shape = box
	floor.add_child(fcs)
	floor.position = Vector3(0, -0.5, 0)
	p.world.add_child(floor)
	var container := Node3D.new()
	container.name = "ObjectPools"
	p.world.add_child(container)
	p.pools = FakePools.new()
	p.pools.name = "FakePools"
	p.pools.gravity = gravity
	p.world.add_child(p.pools)
	p.pools.setup(container)
	p.player = CharacterBody3D.new()
	p.player.name = "Player"
	var pcs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.35
	cap.height = 1.8
	pcs.shape = cap
	p.player.add_child(pcs)
	p.player.position = Vector3(0, 50, 0)
	p.world.add_child(p.player)


## Spawns a pooled body in a peer's world (the game's own spawn path).
func spawn(p: Peer2, pool_id: String, pos: Vector3, vel: Vector3 = Vector3.ZERO) -> RigidBody3D:
	var n: RigidBody3D = p.pools.spawn(pool_id, pos)
	if n != null and vel != Vector3.ZERO:
		n.linear_velocity = vel
	return n


## Host + one client in the world; returns [h, c].
func pair(config: Dictionary = {}, client_config: Dictionary = {}) -> Array:
	await cleanup()
	var h = add_host(config, 1)
	await until(func(): return h.session.get_state() == "in_game")
	var c = add_client("c", client_config)
	await until(func(): return c.session.get_state() == "in_game", 8.0)
	return [h, c]


func physics(n: int) -> void:
	for i in n:
		await tree.physics_frame


func cleanup() -> void:
	for p in peers:
		if p.session != null and is_instance_valid(p.session) and p.session.is_live():
			p.session.leave()
	await frames(2)
	for p in peers:
		for n in [p.session, p.lobby, p.get("bodies"), p.get("driver"), p.get("viewport")]:
			if n != null and n is Node and is_instance_valid(n):
				n.queue_free()
		if p.adapter != null:
			p.adapter.free_all()
	peers.clear()
	await frames(2)
