extends "res://tests/test_case.gd"
## Simulated world: a fake World (scene_file_path = res://scenes/world.tscn) with a
## player, camera, HUD (ExampleMod-extended stub) and BottomMaw. Exercises the
## in-world bridge paths: world.ready / player.ready / held / product.sold /
## phase / ext hooks / static fixture ids / world.exited.

const Entities = preload("res://gamedir/mods/PittAPI/core/entities.gd")

var world: Node3D
var player: Node
var cam: Node
var hud: Node
var maw: Node
var gs: Node
var gp: Node
var ready_ev = null


func before_all() -> void:
	gs = tree.root.get_node("GameState")
	gp = tree.root.get_node("GameProgression")
	var pm = tree.root.get_node("ObjectPoolManager")
	if not pm._initialized:
		pm.initialize_fake({"duck": 5, "crate": 3})
	world = Node3D.new()
	world.name = "World"
	world.scene_file_path = "res://scenes/world.tscn"
	maw = Area3D.new()
	maw.set_script(load("res://tests/fakes/world_maw.gd"))
	maw.name = "BottomMaw"
	maw.add_to_group("BottomMaw", true)
	hud = load("res://scripts/hud.gd").new()
	hud.name = "HUD"
	hud.add_to_group("HUD", true)
	player = CharacterBody3D.new()
	player.set_script(load("res://tests/fakes/world_player.gd"))
	player.name = "PlayerController"
	player.add_to_group("player", true)
	cam = Camera3D.new()
	cam.set_script(load("res://tests/fakes/world_camera.gd"))
	cam.name = "MainCamera"
	cam.add_to_group("main_camera", true)
	player.add_child(cam)
	world.add_child(maw)
	world.add_child(hud)
	world.add_child(player)
	tree.root.add_child(world)
	tree.current_scene = world
	core.bridge._on_scene_changed()
	gs.is_game_started = true
	ready_ev = await core.events.wait("world.ready", 2.0)


func after_all() -> void:
	gs.is_game_started = false
	await wait_frames(2)
	tree.current_scene = runner
	world.queue_free()
	gp.current_phase = 0
	await wait_frames(1)


func test_world_ready() -> void:
	assert_true(ready_ev != null, "world.ready fired")
	if ready_ev == null:
		return
	assert_eq(ready_ev.payload.new_game, true, "new game")
	assert_eq(ready_ev.payload.save_key, "savegame", "save key")
	assert_true(core.state.is_in_world(), "in world")
	assert_eq(core.events.last("scene.changed").payload.kind, "world", "scene kind")


func test_player() -> void:
	assert_true(core.events.last("player.ready") != null, "player.ready")
	assert_eq(core.player.get_local(), player, "get_local")
	assert_eq(core.player.get_local_id(), 1, "player entity id is the local peer's slot (1)")
	var r = core.player.teleport(Vector3(1, 2, 3))
	assert_true(r.ok and player.teleports.size() == 1, "teleport: %s" % r.error)
	r = core.player.impulse(Vector3(0, 5, 0))
	assert_true(r.ok and player.impulses.size() == 1, "impulse")
	r = core.commands.execute("player.teleport", {"transform": [1, 0, 0, 0, 1, 0, 0, 0, 1, 4, 5, 6]})
	assert_true(r.ok and player.global_position.is_equal_approx(Vector3(4, 5, 6)), "teleport_to_transform")
	core.player.set_movement_locked(true)
	assert_true(player.has_meta("golf_aim_mode"), "movement lock meta")
	core.player.set_movement_locked(false)
	assert_false(player.has_meta("golf_aim_mode"), "movement unlocked")


func test_held_and_sold() -> void:
	var r = core.spawn.spawn("duck", Vector3(0, 1, 0))
	assert_true(r.ok, "spawn")
	if not r.ok:
		return
	var eid: int = r.value.entity_id
	var node = core.entities.get_node(eid)
	var held := capture("player.held_changed")
	cam.picked_object = node
	await wait_physics(2)
	assert_true(held.size() == 1 and held[0].payload.entity_id == eid, "held_changed: %s" % str(held))
	assert_eq(core.player.get_held(), eid, "get_held")
	cam.picked_object = null
	await wait_physics(2)
	assert_true(held.size() == 2 and held[1].payload.entity_id == null and held[1].payload.prev == eid, "released")
	var sold := capture("product.sold")
	maw.product_consumed.emit("lucky_duck", 50, node.get_instance_id())
	assert_true(sold.size() == 1 and sold[0].payload.entity_id == eid and sold[0].payload.lucky and sold[0].payload.value == 50,
		"product.sold resolves the body to its entity id: %s" % str(sold))
	var cube := Node3D.new()
	cube.set_meta("recycle_value", 25)
	runner.add_child(cube)
	var recycled := capture("product.recycled")
	maw.product_consumed.emit("recycle", 0, cube.get_instance_id())
	assert_eq(sold.size(), 1, "recycle is not a sale")
	assert_true(recycled.size() == 1 and int(recycled[0].payload.value) == 25, "product.recycled carries recycle_value: %s" % str(recycled))
	cube.queue_free()
	core.spawn.despawn(eid)


func test_hud_and_extension_hook() -> void:
	assert_true(core.hud.banner("hello"), "banner in world")
	assert_true(core.hud.floating_text("hi", Color.RED), "floating text in world")
	var hook := capture("mod.ExampleMod.hud_result")
	hud.show_result(4, 120.0)
	assert_eq(hud.results.size(), 1, "super.show_result ran (game behaviour kept)")
	assert_true(hook.size() == 1 and hook[0].payload.level == 4, "extension forwarded the hook")


func test_phase_in_world() -> void:
	var changed := capture("phase.changed")
	var settled := capture("phase.settled")
	var r = core.state.set_phase(2)
	assert_true(r.ok, "phase.set in world: %s" % r.error)
	await wait_frames(1)
	assert_true(changed.size() >= 1 and changed.back().payload.to == 2, "phase.changed")
	assert_true(settled.size() == 1 and settled[0].payload.phase == 2, "phase.settled")


func test_static_fixture_ids() -> void:
	assert_eq(core.entities.id_of(maw), Entities.static_id("static:/root/World/BottomMaw"), "maw has its deterministic id")
	assert_eq(core.entities.key_of(core.entities.id_of(maw)), "static:/root/World/BottomMaw", "key")


func test_world_exit_clears() -> void:
	var exited := capture("world.exited")
	gs.is_game_started = false
	await wait_frames(2)
	assert_eq(exited.size(), 1, "world.exited")
	assert_false(core.state.is_in_world(), "not in world")
	assert_eq(core.entities.count("static"), 0, "entities cleared")
