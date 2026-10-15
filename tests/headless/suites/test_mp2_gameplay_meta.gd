extends "res://tests/test_case.gd"
## GAMEPLAY meta adapters (MP2-DESIGN 3.5 / 4.4-4.6) through the BODIES registry
## double: the host reads small JSON-safe states, the client applies them with the
## game's own setters/replays in apply scope; edges are taken against the last
## applied state (a client copy may finish an animation itself); the loop puzzle's
## large path is only re-applied when the best changes; bowling pins get one key
## per generation on both peers.

const GpRig = preload("res://tests/fakes/mp2_gameplay/gp_rig.gd")
const MpGate = preload("res://gamedir/mods/PittMultiplayer/gameplay/mp_gate.gd")

var rig = null


func before_all() -> void:
	rig = GpRig.new(tree, runner)


func after_all() -> void:
	await rig.cleanup()


func _pair() -> Array:
	await rig.cleanup()
	var h = rig.add_host()
	var c = rig.add_client(2)
	rig.start()
	return [h, c]


func _node(p, ext: String) -> Node:
	var n: Node = GpRig.ext_script(ext).new()
	p.adapter.world.add_child(n)
	return n


## host read -> JSON -> client apply
func _sync(h, c, kind: String, hn: Node, cn: Node) -> Dictionary:
	var d: Dictionary = h.bodies.read_meta(kind, hn)
	var wire = JSON.parse_string(JSON.stringify(d))
	rig.as_peer(c)
	assert_true(c.bodies.apply_meta(kind, cn, wire), "%s applied" % kind)
	return d


func test_registered_kinds() -> void:
	var pc = await _pair()
	var kinds: Array = pc[1].bodies.adapters.keys()
	for k in ["gp_bench_manual", "gp_bench_auto", "gp_cauldron", "gp_terminal", "gp_block", "gp_erasable",
			"gp_camera", "gp_gate", "gp_shutters", "gp_generator", "gp_plate", "gp_keypad", "gp_loop", "gp_bowling",
			"gp_qa_arm", "gp_ore", "gp_pickaxe"]:
		assert_has(kinds, k, "adapter %s" % k)
	var bench := _node(pc[1], "workbench")
	assert_eq(pc[1].bodies.kinds_matching(bench), ["gp_bench_manual"], "matcher by game script")
	var auto := _node(pc[1], "automatic_duck_workbench")
	assert_eq(pc[1].bodies.kinds_matching(auto), ["gp_bench_auto"], "auto bench")


func test_manual_bench_edges() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var hb := _node(h, "workbench")
	var cb := _node(c, "workbench")
	hb.is_crafting = true
	hb.craft_progress = 1.2
	_sync(h, c, "gp_bench_manual", hb, cb)
	assert_has(cb.stub_calls, "start_crafting", "rising edge: the game's start_crafting replayed")
	cb.is_crafting = true       # what the real start does
	cb.craft_progress = 0.0
	hb.craft_progress = 1.5
	_sync(h, c, "gp_bench_manual", hb, cb)
	assert_eq(cb.craft_progress, 1.5, "progress corrected when off by > 0.25 s")
	assert_eq(cb.stub_calls.count("start_crafting"), 1, "no second start without an edge")
	# the client's copy stopped on its own (end of its animation): no restart
	cb.is_crafting = false
	_sync(h, c, "gp_bench_manual", hb, cb)
	assert_eq(cb.stub_calls.count("start_crafting"), 1, "edges against the last applied state")
	hb.is_crafting = false
	_sync(h, c, "gp_bench_manual", hb, cb)
	assert_has(cb.stub_calls, "stop_crafting", "falling edge: stop replayed")


func test_auto_bench_toggle_and_cycle() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var hb := _node(h, "automatic_duck_workbench")
	var cb := _node(c, "automatic_duck_workbench")
	hb.is_turned_on = true
	_sync(h, c, "gp_bench_auto", hb, cb)
	assert_has(cb.stub_calls, "turn_on", "turn_on replayed (input gate passes in apply scope)")
	hb.is_crafting = true
	_sync(h, c, "gp_bench_auto", hb, cb)
	assert_has(cb.stub_calls, "start_crafting", "cycle start replayed")
	# outside apply scope the client's own timer cannot start a cycle
	cb.stub_calls.clear()
	rig.as_peer(c)
	cb.start_crafting()
	assert_eq(cb.stub_calls, [], "machine-originated start blocked on the client")


func test_fixtures_states() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var hg := _node(h, "vertical_gate")
	var cg := _node(c, "vertical_gate")
	hg.is_solved = true
	_sync(h, c, "gp_gate", hg, cg)
	assert_has(cg.stub_calls, "solve", "gate solve() replayed (animated)")
	var hblk := _node(h, "minable_block")
	var cblk := _node(c, "minable_block")
	hblk.damage = 4.0
	_sync(h, c, "gp_block", hblk, cblk)
	assert_eq(cblk.damage, 4.0, "damage mirrored")
	assert_has(cblk.stub_calls, "_update_crack_visuals", "cracks redrawn")
	hblk.broken = true
	_sync(h, c, "gp_block", hblk, cblk)
	assert_has(cblk.stub_calls, "apply_saved_state", "broken -> apply_saved_state")
	var hk := _node(h, "security_keypad")
	var ck := _node(c, "security_keypad")
	hk.entry = "42"
	_sync(h, c, "gp_keypad", hk, ck)
	assert_eq(ck.entry, "42", "entry mirrored")
	var hs := _node(h, "gate_shutters")
	var cs := _node(c, "gate_shutters")
	hs._slot_fuse_map = {0: "fuse_a", 2: "fuse_b"}
	_sync(h, c, "gp_shutters", hs, cs)
	assert_has(cs.stub_calls, "apply_shutters_saved_state", "slots through the save-state setter")
	var ht := _node(h, "gambling_terminal")
	var ct := _node(c, "gambling_terminal")
	ht._rolling = true
	ht._remaining = 2.5
	_sync(h, c, "gp_terminal", ht, ct)
	assert_true(ct._rolling and is_equal_approx(ct._remaining, 2.5), "roll countdown mirrored")
	assert_has(ct.stub_calls, "_update_button_label", "button label refreshed")


func test_loop_puzzle_path_only_on_new_best() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var hl := _node(h, "loop_puzzle")
	var cl := _node(c, "loop_puzzle")
	var state := {"energy": 3.0, "clone_count": 1, "speed_level": 0, "energy_level": 0, "best_time": 12.0,
		"best_path": [[0, 0, 0], [1, 0, 0]], "is_solved": false}
	hl.set_meta("t_state", state)
	# the stub's get_save_state returns {}: feed the reader the game's shape
	var d := {"en": 3.0, "cc": 1, "sl": 0, "el": 0, "bt": 12.0, "bp": [[0, 0, 0], [1, 0, 0]], "so": false}
	rig.as_peer(c)
	c.bodies.apply_meta("gp_loop", cl, d)
	assert_eq(cl.stub_calls.count("apply_save_state"), 1, "first state: full apply")
	d.en = 9.0
	c.bodies.apply_meta("gp_loop", cl, {"en": 9.0})
	assert_eq(cl.stub_calls.count("apply_save_state"), 1, "energy only: no clone-train restart")
	assert_eq(cl.energy, 9.0, "energy set")
	assert_has(cl.stub_calls, "_refresh_labels", "labels refreshed")
	c.bodies.apply_meta("gp_loop", cl, {"bt": 10.5, "bp": [[0, 0, 0], [2, 0, 0]]})
	assert_eq(cl.stub_calls.count("apply_save_state"), 2, "new best: full apply")


func test_bowling_pin_generations() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var hs := _node(h, "bowling_pin_set")
	var cs := _node(c, "bowling_pin_set")
	var hpins: Array = [RigidBody3D.new(), RigidBody3D.new()]
	var cpins: Array = [RigidBody3D.new(), RigidBody3D.new()]
	for p in hpins:
		h.adapter.world.add_child(p)
	for p in cpins:
		c.adapter.world.add_child(p)
	hs._pins = hpins
	rig.as_peer(h)
	hs._spawn_pins()
	assert_eq(int(hs.get_meta("pitt_mp_pin_gen")), 1, "host generation 1")
	assert_eq(hs.get_meta("pitt_mp_pin_keys"), ["bowling:pin:1:0", "bowling:pin:1:1"], "keys")
	# client: its own _ready spawn is blocked; the meta replays it for generation 1
	rig.as_peer(c)
	cs._spawn_pins()
	assert_false("_spawn_pins" in cs.stub_calls, "client spawn outside apply scope blocked")
	cs._pins = cpins
	_sync(h, c, "gp_bowling", hs, cs)
	assert_has(cs.stub_calls, "_spawn_pins", "replayed in apply scope")
	assert_eq(cs.get_meta("pitt_mp_pin_keys"), ["bowling:pin:1:0", "bowling:pin:1:1"], "same keys on the client")
	assert_eq(c.bodies.fixtures.get("bowling:pin:1:0"), h.bodies.fixtures.get("bowling:pin:1:0"),
		"same static id (both fakes count from the same base)")
	# a reset: generation 2, old keys unregistered
	rig.as_peer(h)
	hs._spawn_pins()
	assert_eq(int(hs.get_meta("pitt_mp_pin_gen")), 2, "generation 2")
	assert_false(h.bodies.fixtures.has("bowling:pin:1:0"), "old keys released")
	for p in hpins + cpins:
		p.queue_free()


func test_qa_arm_pose() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var ha := _node(h, "qa_arm")
	var ca := _node(c, "qa_arm")
	var piv := Node3D.new()
	ca.add_child(piv)
	ca.turret_pivot = piv
	ha._state = 2
	ha._yaw = 0.75
	_sync(h, c, "gp_qa_arm", ha, ca)
	assert_eq(ca._state, 2, "state")
	assert_true(is_equal_approx(piv.rotation.y, 0.75), "turret yaw")
	assert_has(ca.stub_calls, "_drive_bat", "bat posed")
