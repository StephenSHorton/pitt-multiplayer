extends "res://tests/test_case.gd"
## PittAPI 1.2 entity registry (MP2-DESIGN 3.2): L7 adopt / release on a
## non-authority peer, refused on the authority and for ids bound elsewhere;
## L8 full reconcile and same-frame reuse detection (recycle + respawn of one
## node -> despawn + spawn with a NEW id) vs the cannon's store / fire (hidden
## with in_cannon_barrel: no reuse); L9 the reused flag; P10 the gated full diff
## (same-frame swaps, freed nodes, the 1 s safety net, fewer diffs when idle).

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


# ------------------------------------------------------------------ P10 gated full diff

func _host(s: Array) -> Object:
	var reg = s[1]
	reg.set_reconcile_mode({"full_every_frame": true, "detect_reuse": true})
	return reg


## Runs `n` reconciles of one physics frame; the number of full diffs they ran.
func _ticks(reg, n: int) -> int:
	var before: int = reg.full_diffs
	for i in n:
		reg.reconcile(1.0 / 60.0)
	return reg.full_diffs - before


func test_gate_sees_a_cross_pool_swap_the_same_frame() -> void:
	var s := _setup(true)
	var api = s[0]
	var pools = s[2]
	var reg = _host(s)
	var a: Node3D = pools.spawn("duck", Vector3(0, 1, 0))
	_ticks(reg, 3)
	var ida: int = reg.id_of(a)
	assert_true(ida >= 1000, "tracked")
	var evs: Array = []
	api.events.on("entity.spawned", func(ev): evs.append(["sp", int(ev.payload.entity_id)]))
	api.events.on("entity.despawned", func(ev): evs.append(["dp", int(ev.payload.entity_id)]))
	# one pool loses a node and another gains one: the total does not change
	pools.recycle(a)
	var b: Node3D = pools.spawn("candy", Vector3(1, 1, 0))
	reg.reconcile(1.0 / 60.0)
	assert_eq(reg.id_of(a), 0, "the recycled duck is despawned in the same frame")
	var idb: int = reg.id_of(b)
	assert_true(idb >= 1000 and idb != ida, "the candy is spawned in the same frame")
	assert_eq(evs, [["sp", idb], ["dp", ida]], "one spawn, one despawn")


func test_gate_without_reuse_detection_still_sees_swaps() -> void:
	var s := _setup(true)
	var pools = s[2]
	var reg = s[1]
	reg.set_reconcile_mode({"full_every_frame": true, "detect_reuse": false})
	var a: Node3D = pools.spawn("duck")
	var c: Node3D = pools.spawn("candy")
	_ticks(reg, 3)
	var ida: int = reg.id_of(a)
	pools.recycle(c)
	pools.recycle(a)
	var b: Node3D = pools.spawn("candy")
	var d: Node3D = pools.spawn("duck_luck")
	assert_true(b == c, "the candy node came back")
	reg.reconcile(1.0 / 60.0)
	assert_eq(reg.id_of(a), 0, "duck despawned")
	assert_true(reg.id_of(d) >= 1000, "duck_luck spawned")
	assert_ne(ida, reg.id_of(d), "a new id")


func test_gate_sees_a_freed_node_the_next_frame() -> void:
	var s := _setup(true)
	var pools = s[2]
	var reg = _host(s)
	var a: Node3D = pools.spawn("duck")
	var b: Node3D = pools.spawn("duck")
	_ticks(reg, 3)
	var ida: int = reg.id_of(a)
	assert_true(ida >= 1000 and reg.id_of(b) >= 1000, "both tracked")
	# freed while still in active, and not the last node: only tree_exiting tells
	a.free()
	assert_eq(_ticks(reg, 1), 1, "a full diff the next frame")
	assert_eq(reg.get_node(ida), null, "freed node despawned")
	assert_eq(reg.kind_of(ida), "", "forgotten")
	assert_ne(reg.id_of(b), 0, "b kept")


func test_gate_safety_net_catches_an_unobserved_change() -> void:
	var s := _setup(true)
	var pools = s[2]
	var reg = _host(s)
	var a: Node3D = pools.spawn("duck")
	var b: Node3D = pools.spawn("duck")
	_ticks(reg, 3)
	var ida: int = reg.id_of(a)
	# a swap no hook sees: a hidden, untracked node replaces a (not the last) in place
	var x: Node3D = pools.spawn("candy")
	pools._pools["candy"].active.erase(x)
	x.visible = false
	_ticks(reg, 1)
	assert_eq(reg.id_of(x), 0, "x is not active")
	pools._pools["duck"].active[0] = x
	var hit := -1
	for i in 70:
		reg.reconcile(1.0 / 60.0)
		if reg.id_of(x) != 0:
			hit = i
			break
	assert_true(hit > 0 and hit <= 61, "found by the 1 s safety net (tick %d)" % hit)
	assert_eq(reg.id_of(a), 0, "the replaced node despawned")
	assert_ne(reg.id_of(b), 0, "b kept")
	assert_ne(ida, reg.id_of(x), "new id")
	pools._pools["duck"].active[0] = a


func test_gate_cuts_full_diffs_with_static_bodies() -> void:
	var s := _setup(true)
	var pools = s[2]
	var reg = _host(s)
	for i in 300:
		pools.spawn("duck", Vector3(i, 1, 0))
	var t0 := Time.get_ticks_usec()
	var gated := _ticks(reg, 120)
	var t_gated := Time.get_ticks_usec() - t0
	assert_eq(reg.count("pooled"), 300, "all registered")
	# the first diff, its follow-up (the registry changed), then the 1 s net
	assert_true(gated >= 2 and gated <= 4, "gated: %d full diffs in 120 frames" % gated)
	reg.set_reconcile_mode({"gate_full_diff": false})
	t0 = Time.get_ticks_usec()
	var every := _ticks(reg, 120)
	var t_every := Time.get_ticks_usec() - t0
	assert_eq(every, 120, "gate off: a full diff every frame (the old path)")
	assert_eq(reg.count("pooled"), 300, "no churn either way")
	print("    P10 bench: 300 static bodies, 120 frames: gated %d diffs %d us, ungated %d diffs %d us"
		% [gated, t_gated, every, t_every])
	reg.set_reconcile_mode({"gate_full_diff": true})
	assert_true(_ticks(reg, 60) <= 2, "back on")


func test_gate_does_not_touch_the_idle_path() -> void:
	var s := _setup(true)
	var pools = s[2]
	var reg = s[1]
	var a: Node3D = pools.spawn("duck")
	assert_eq(_ticks(reg, 1), 1, "first frame diffs (the total changed)")
	assert_eq(reg._vis.size(), 0, "nothing watched outside host mode")
	# a cross-pool swap keeps the total: the old path waits for full_interval
	pools.recycle(a)
	pools.spawn("candy")
	assert_eq(_ticks(reg, 1), 0, "count-only check as before")
	assert_eq(_ticks(reg, 15), 1, "full diff after full_interval (0.25 s)")
	assert_eq(reg.id_of(a), 0, "despawned")
