extends "res://tests/test_case.gd"

const Entities = preload("res://gamedir/mods/PittAPI/core/entities.gd")

var pm: Node = null


func before_all() -> void:
	pm = tree.root.get_node("ObjectPoolManager")
	if not pm._initialized:
		pm.initialize_fake({"duck": 5, "crate": 3})


func test_static_ids_stable() -> void:
	var a := Entities.static_id("static:/root/World/BottomMaw")
	assert_eq(a, Entities.static_id("static:/root/World/BottomMaw"), "deterministic")
	assert_true(a >= (1 << 31) and a < (1 << 32), "static ids live above 2^31")
	assert_ne(a, Entities.static_id("static:/root/World/Floor"), "different keys differ")
	# djb2 (String.hash) computed independently in Python: same value on every peer/run
	assert_eq(Entities.static_id("gate:gate_shutters"), 3931640642, "known value")


func test_api_spawn_and_despawn() -> void:
	var spawned := capture("entity.spawned")
	var gone := capture("entity.despawned")
	var r = core.spawn.spawn("duck", Vector3(1, 2, 3), Vector3.ZERO, {"velocity": Vector3(0, 1, 0), "meta": {"tag": "x"}})
	assert_true(r.ok, "spawn ok: %s" % r.error)
	if not r.ok:
		return
	var id: int = r.value.entity_id
	assert_true(id >= 1000, "dynamic ids start at 1000")
	assert_true(spawned.size() == 1 and spawned[0].payload.entity_id == id and spawned[0].source == "api", "entity.spawned")
	var n = core.entities.get_node(id)
	assert_true(n != null and n.get_meta("tag") == "x", "meta applied")
	assert_true(n is RigidBody3D and n.linear_velocity.is_equal_approx(Vector3(0, 1, 0)), "velocity set after spawn")
	assert_eq(core.entities.describe(id).get("pool_id", ""), "duck", "describe")
	assert_has(core.entities.list({"pool_id": "duck"}), id, "list by pool")
	assert_has(core.entities.list({"within": {"center": [1, 2, 3], "radius": 0.5}}), id, "list within radius")
	r = core.spawn.despawn(id)
	assert_true(r.ok and gone.size() == 1 and gone[0].payload.entity_id == id, "despawn")
	assert_eq(core.entities.get_node(id), null, "id is gone")
	assert_eq(core.spawn.spawn("nope", Vector3.ZERO).code, "ERR_INVALID", "unknown pool")


func test_reconciler_new_id_on_reuse() -> void:
	var spawned := capture("entity.spawned")
	var gone := capture("entity.despawned")
	var obj = pm.spawn("crate", Vector3.ZERO)
	await wait_physics(2)
	var id1: int = core.entities.id_of(obj)
	assert_true(id1 >= 1000, "game-side spawn picked up by the reconciler")
	assert_true(spawned.size() >= 1 and spawned.back().source == "game", "source game")
	pm.recycle(obj)
	await wait_physics(2)
	assert_eq(core.entities.id_of(obj), 0, "recycled -> untracked")
	assert_true(gone.size() >= 1 and gone.back().payload.entity_id == id1, "entity.despawned")
	var again = pm.spawn("crate", Vector3.ZERO)
	assert_eq(again, obj, "the pool reused the same node")
	await wait_physics(2)
	var id2: int = core.entities.id_of(again)
	assert_true(id2 != 0 and id2 != id1, "reused node gets a NEW id (%d vs %d)" % [id1, id2])
	pm.recycle(again)
	await wait_physics(2)


func test_exhausted_pool() -> void:
	var ids: Array = []
	for i in 3:
		var r = core.spawn.spawn("crate", Vector3.ZERO)
		if r.ok:
			ids.append(r.value.entity_id)
	var r = core.spawn.spawn("crate", Vector3.ZERO)
	assert_eq(r.code, "ERR_FAILED", "exhausted pool fails cleanly")
	for id in ids:
		core.spawn.despawn(id)


func test_track_mod_nodes() -> void:
	var n := Node3D.new()
	runner.add_child(n)
	var id: int = core.entities.track(n)
	assert_true(id >= 1000 and core.entities.kind_of(id) == "mod", "mod tracked")
	var s := Node3D.new()
	runner.add_child(s)
	var sid: int = core.entities.track(s, "fixture:test")
	assert_eq(sid, Entities.static_id("fixture:test"), "static key id")
	var r = core.commands.execute("entity.despawn", {"entity_id": sid})
	assert_eq(r.code, "ERR_DENIED", "static entities cannot be despawned")
	core.entities.untrack(id)
	core.entities.untrack(sid)
	n.queue_free()
	s.queue_free()


func test_mod_view_is_restricted() -> void:
	var ex = core.loader.mods["ExampleMod"].ctx
	var tests_ctx = core.loader.mods["PittAPITests"].ctx
	assert_false(ex.entities.has_method("clear_all"), "no clear_all on the mod view")
	assert_false(ex.entities.has_method("register_pooled"), "no register_pooled on the mod view")
	assert_false(ex.entities.has_method("despawned"), "no despawned on the mod view")
	var n := Node3D.new()
	runner.add_child(n)
	var id: int = ex.entities.track(n)
	assert_true(id >= 1000 and ex.entities.owner_of(id) == "ExampleMod", "tracked with owner")
	assert_false(tests_ctx.entities.untrack(id), "another mod cannot untrack it")
	assert_true(ex.entities.get_node(id) == n, "still tracked")
	var sid: int = ex.entities.track(n)
	assert_eq(sid, id, "re-track returns the same id")
	assert_true(ex.entities.untrack(id), "owner untracks")
	n.queue_free()


func test_player_ids_reserved_range() -> void:
	var p := Node3D.new()
	runner.add_child(p)
	var id: int = core.entities.register_player(p, 1)
	assert_eq(id, 1, "local peer 1 -> player id 1")
	assert_eq(core.entities.kind_of(id), "player", "kind player")
	var q := Node3D.new()
	runner.add_child(q)
	var id2: int = core.entities.register_player(q, 123456789)
	assert_true(id2 >= 2 and id2 <= 999, "other peers get a slot in 2..999: %d" % id2)
	core.entities.untrack(id)
	core.entities.untrack(id2)
	core.entities._player_slots.clear()
	p.queue_free()
	q.queue_free()
