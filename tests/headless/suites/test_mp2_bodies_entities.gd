extends "res://tests/test_case.gd"
## PittAPI 1.2 entity registry (MP2-DESIGN 3.2): L7 adopt / release on a
## non-authority peer, refused on the authority and for ids bound elsewhere;
## L8 full reconcile and same-frame reuse detection (recycle + respawn of one
## node -> despawn + spawn with a NEW id) vs the cannon's store / fire (hidden
## with in_cannon_barrel: no reuse); L9 the reused flag.

const Entities = preload("res://gamedir/mods/PittAPI/core/entities.gd")
const FakeEntityCore = preload("res://tests/fakes/mp2_bodies/fake_entity_core.gd")
const FakeApi2 = preload("res://tests/fakes/mp2_bodies/fake_api2.gd")
const FakePools = preload("res://tests/fakes/mp2_bodies/fake_pools.gd")


class FixedAuth extends RefCounted:
	var auth := true

	func is_authority() -> bool:
		return auth

	func local_peer_id() -> int:
		return 1 if auth else 2


var _made: Array = []


func _setup(authority: bool) -> Array:
	var api = FakeApi2.new("ent")
	var container := Node3D.new()
	container.name = "ObjectPools"
	runner.add_child(container)
	var pools = FakePools.new()
	pools.gravity = false
	runner.add_child(pools)
	pools.setup(container)
	var core = FakeEntityCore.new(api, pools)
	var a := FixedAuth.new()
	a.auth = authority
	core.authority = a
	var reg = Entities.new(core)
	_made.append(container)
	_made.append(pools)
	return [api, reg, pools]


func after_all() -> void:
	for n in _made:
		if is_instance_valid(n):
			n.queue_free()


func test_adopt_and_release_on_a_client() -> void:
	var s := _setup(false)
	var api = s[0]
	var reg = s[1]
	var pools = s[2]
	var evs: Array = []
	api.events.on("entity.spawned", func(ev): evs.append(["sp", ev.payload, ev.source]))
	api.events.on("entity.despawned", func(ev): evs.append(["dp", ev.payload, ev.source]))
	var n: Node3D = pools.spawn("duck", Vector3(1, 2, 3))
	reg.reconcile(0.016, true)
	assert_eq(reg.id_of(n), 0, "a non-authority reconciler allocates nothing")
	assert_eq(reg.adopt(n, 4242, "duck"), OK, "adopt")
	assert_eq(reg.id_of(n), 4242, "id_of returns the host id")
	assert_eq(reg.kind_of(4242), "pooled", "pooled")
	assert_eq(evs.size(), 1, "entity.spawned once")
	assert_eq(String(evs[0][2]), "net", "source net")
	assert_false(bool(evs[0][1].reused), "reused false")
	var other: Node3D = pools.spawn("duck", Vector3.ZERO)
	assert_eq(reg.adopt(other, 4242, "duck"), ERR_ALREADY_EXISTS, "an id bound to another node")
	assert_eq(reg.adopt(n, 500, "duck"), ERR_INVALID_PARAMETER, "player range refused")
	var sid: int = Entities.static_id("static:/root/World/Fuse")
	var fuse := Node3D.new()
	runner.add_child(fuse)
	assert_eq(reg.adopt(fuse, sid, "static:/root/World/Fuse"), OK, "static adopt")
	assert_eq(reg.kind_of(sid), "static", "static kind")
	assert_eq(reg.key_of(sid), "static:/root/World/Fuse", "static key")
	reg.release(4242)
	assert_eq(reg.id_of(n), 0, "released")
	assert_eq(String(evs.back()[0]), "dp", "entity.despawned")
	assert_eq(String(evs.back()[2]), "net", "source net")
	reg.release(sid)
	assert_eq(reg.id_of(fuse), 0, "static released silently")
	fuse.queue_free()


func test_adopt_refused_on_the_authority() -> void:
	var s := _setup(true)
	var reg = s[1]
	var n: Node3D = s[2].spawn("duck", Vector3.ZERO)
	assert_eq(reg.adopt(n, 9999, "duck"), ERR_UNAUTHORIZED, "the authority allocates its own ids")


func test_reuse_detection() -> void:
	var s := _setup(true)
	var api = s[0]
	var reg = s[1]
	var pools = s[2]
	var evs: Array = []
	api.events.on("entity.spawned", func(ev): evs.append(["sp", int(ev.payload.entity_id), bool(ev.payload.reused)]))
	api.events.on("entity.despawned", func(ev): evs.append(["dp", int(ev.payload.entity_id)]))
	reg.set_reconcile_mode({"full_every_frame": true, "detect_reuse": true})
	var d: Node3D = pools.spawn("duck", Vector3(0, 1, 0))
	reg.reconcile(0.016)
	var id1: int = reg.id_of(d)
	assert_true(id1 >= 1000, "spawned")
	evs.clear()
	# the press: recycle + spawn in one frame, the same node comes back
	pools.recycle(d)
	var d2: Node3D = pools.spawn("duck", Vector3(2, 1, 0))
	assert_true(d2 == d, "same node")
	reg.reconcile(0.016)
	var id2: int = reg.id_of(d)
	assert_ne(id2, id1, "a new id")
	assert_eq(evs, [["dp", id1], ["sp", id2, true]], "despawn + spawn, reused = true (L9)")
	assert_eq(reg.reuse_detected, 1, "counted")
	evs.clear()
	# the cannon: hidden with in_cannon_barrel, shown again later = no reuse
	d.set_meta("in_cannon_barrel", true)
	d.visible = false
	d.visible = true
	d.remove_meta("in_cannon_barrel")
	d.set_meta("in_cannon_barrel", true)
	d.visible = false
	reg.reconcile(0.016)
	assert_eq(reg.id_of(d), id2, "stored in a cannon: same id")
	d.remove_meta("in_cannon_barrel")
	d.visible = true
	reg.reconcile(0.016)
	assert_eq(reg.id_of(d), id2, "fired a frame later: same id")
	assert_true(evs.is_empty(), "no lifecycle events for the cannon")
	# hidden in one frame, shown in a later one, without metas: not a reuse either
	d.visible = false
	reg.reconcile(0.016)
	d.visible = true
	reg.reconcile(0.016)
	assert_eq(reg.id_of(d), id2, "a hide and a show in different frames is no reuse")
	reg.set_reconcile_mode({"full_every_frame": false, "detect_reuse": false})
	pools.recycle(d)
	pools.spawn("duck")
	reg.reconcile(0.016, true)
	assert_eq(reg.id_of(d), id2, "detection off: the MP1 behaviour")
