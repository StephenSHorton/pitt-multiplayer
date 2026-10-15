extends "res://tests/test_case.gd"
## world.interact (MP2-DESIGN 6.2, 6.4): client forward (eid, descendant path,
## tool_in for the equipped tool, collapsing, hold-to-craft as one start + one
## stop), host validation (in game, known eid, whitelist + argument shapes, reach,
## rate, tool ownership), host exec (exec_peer during the call, meta pushed after),
## the bench holder set and the custom host verbs (loop run, golf shot, remote).

const GpRig = preload("res://tests/fakes/mp2_gameplay/gp_rig.gd")
const MpGate = preload("res://gamedir/mods/PittMultiplayer/gameplay/mp_gate.gd")
const EXT := "res://gamedir/mods/PittMultiplayer/extensions/gameplay/"

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
	h.session.set_pose(2, Vector3(1, 0, 0))
	return [h, c]


## The same scripted node on both peers under one eid.
func _both(pc: Array, ext: String, eid: int, kind: String = "fixture") -> Array:
	var hn: Node = GpRig.ext_script(ext).new()
	pc[0].adapter.world.add_child(hn)
	pc[0].bodies.add(hn, eid, kind)
	var cn: Node = GpRig.ext_script(ext).new()
	pc[1].adapter.world.add_child(cn)
	pc[1].bodies.add(cn, eid, kind)
	return [hn, cn]


func _client_input(c, f: Callable) -> void:
	rig.as_peer(c)
	MpGate.begin_input_scope()
	f.call()
	MpGate.end_input_scope()


func test_forward_reaches_host_and_runs_there() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var fans := _both(pc, "fan", 1500, "pooled")
	var seen_peer: Array = []
	fans[0].stub_hook = func(n): seen_peer.append([n, MpGate.exec_peer, MpGate.is_host()])
	_client_input(c, func(): fans[1].toggle_fan())
	assert_eq(fans[1].stub_calls, [], "not run on the client")
	assert_eq(fans[0].stub_calls, ["toggle_fan"], "run on the host's copy")
	assert_eq(seen_peer, [["toggle_fan", 2, true]], "inside host_exec for peer 2")
	assert_eq(MpGate.exec_peer, 0, "exec_peer reset after the call")
	assert_eq(h.bodies.calls_of("meta_dirty").size(), 1, "meta pushed at once")
	assert_eq(h.bodies.calls_of("boost").size(), 1, "boosted")
	assert_eq(int(h.gp.interact_host.counters().interact_ok), 1, "counted ok")


func test_descendant_path_and_tool_in() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	# a terminal control (child) under the tracked terminal
	var term_h := Node3D.new()
	h.adapter.world.add_child(term_h)
	h.bodies.add(term_h, 900020, "fixture")
	var ctl_h: Node = GpRig.ext_script("terminal_control").new()
	ctl_h.name = "Roll"
	term_h.add_child(ctl_h)
	var term_c := Node3D.new()
	c.adapter.world.add_child(term_c)
	c.bodies.add(term_c, 900020, "fixture")
	var ctl_c: Node = GpRig.ext_script("terminal_control").new()
	ctl_c.name = "Roll"
	term_c.add_child(ctl_c)
	_client_input(c, func(): ctl_c.interact())
	var sent: Array = c.session.sent_of("interact")
	assert_eq(sent.size(), 1, "sent")
	assert_eq(String(sent[0][2].p), "Roll", "path from the tracked ancestor")
	assert_eq(ctl_h.stub_calls, ["interact"], "host ran the child's method")
	# equipped tool -> tool_in, accepted only when the sender owns it as equipped
	var vacs := _both(pc, "vacuum", 1600, "pooled")
	c.adapter.camera.equipped_item = vacs[1]
	_client_input(c, func(): vacs[1].equipped_lmb_pressed())
	assert_eq(c.session.sent_of("tool_in").size(), 1, "tool_in for the equipped tool")
	assert_true("equipped_lmb_pressed" in vacs[1].stub_calls, "input_predict: local feedback ran")
	assert_eq(vacs[0].stub_calls, [], "host refused: not the owner")
	assert_eq(h.gp.interact_host.last_reject, "not_owner", "reason not_owner")
	h.grab.set_owner(1600, 2, "equipped")
	c.gp.interact_client.clear()    # the repeat window would collapse the same press
	_client_input(c, func(): vacs[1].equipped_lmb_pressed())
	assert_true("equipped_lmb_pressed" in vacs[0].stub_calls, "owner's tool_in runs on the host copy")


func test_host_rejections() -> void:
	var pc = await _pair()
	var h = pc[0]
	var fans := _both(pc, "fan", 1500, "pooled")
	var ih = h.gp.interact_host
	rig.as_peer(h)
	assert_eq(ih.handle(3, "interact", {"eid": 1500, "verb": "toggle_fan"}), "not_in_game", "peer not in game")
	assert_eq(ih.handle(2, "interact", {"eid": 4242, "verb": "toggle_fan"}), "unknown", "unknown eid")
	assert_eq(ih.handle(2, "interact", {"eid": 1500, "verb": "queue_free"}), "bad_verb", "not whitelisted")
	assert_eq(ih.handle(2, "interact", {"eid": 1500, "verb": "equipped_lmb_pressed"}), "bad_verb", "tool verb on interact")
	assert_eq(ih.handle(2, "interact", {"eid": 1500, "verb": "toggle_fan", "p": "../x"}), "bad_path", "escaping path")
	assert_eq(ih.handle(2, "interact", {"eid": 1500, "verb": "cycle_preset", "arg": ["x"]}), "bad_verb", "fan has no cycle_preset")
	var pis := _both(pc, "piston_2", 1700, "pooled")
	assert_eq(ih.handle(2, "interact", {"eid": 1700, "verb": "cycle_preset", "arg": ["x"]}), "bad_args", "int expected")
	assert_eq(ih.handle(2, "interact", {"eid": 1700, "verb": "cycle_preset", "arg": [1]}), "", "int accepted")
	assert_eq(pis[0].stub_calls[-1], "cycle_preset", "ran")
	h.session.set_pose(2, Vector3(30, 0, 0))
	assert_eq(ih.handle(2, "interact", {"eid": 1500, "verb": "toggle_fan"}), "far", "out of reach")
	h.session.set_pose(2, Vector3(1, 0, 0))
	var rejected := 0
	for i in 60:
		if ih.handle(2, "interact", {"eid": 1500, "verb": "toggle_fan"}) == "rate":
			rejected += 1
	assert_true(rejected >= 15, "rate limit 20/s burst 40 (rejected %d of 60)" % rejected)
	assert_true(fans[0].stub_calls.size() <= 45, "at most the burst ran")


func test_bench_holder_set() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var benches := _both(pc, "workbench", 2000)
	# host player holds craft
	rig.as_peer(h)
	MpGate.begin_input_scope()
	benches[0].start_crafting()
	MpGate.end_input_scope()
	# the client holds too (forwarded once even if the dispatcher repeats it)
	_client_input(c, func():
		benches[1].start_crafting()
		benches[1].start_crafting())
	assert_eq(h.gp.holders_of(2000), [1, 2], "holders host + client")
	assert_eq(c.session.sent_of("interact").size(), 1, "one start per hold")
	# the host releases: crafting continues for the client
	rig.as_peer(h)
	MpGate.begin_input_scope()
	benches[0].stop_crafting()
	MpGate.end_input_scope()
	assert_false("stop_crafting" in benches[0].stub_calls, "still crafting while the client holds")
	assert_eq(h.gp.holders_of(2000), [2], "client remains")
	# the client releases (twice: only one stop goes out)
	_client_input(c, func():
		benches[1].stop_crafting()
		benches[1].stop_crafting())
	assert_true("stop_crafting" in benches[0].stub_calls, "last holder released: stop")
	assert_eq(h.gp.holders_of(2000), [], "no holders")
	assert_eq(c.session.sent_of("interact").size(), 2, "one stop per hold")
	# a stop from a peer that never held is ignored by the client side
	_client_input(c, func(): benches[1].stop_crafting())
	assert_eq(c.session.sent_of("interact").size(), 2, "no stop without a start")
	# disconnect of the last holder stops the bench
	_client_input(c, func(): benches[1].start_crafting())
	benches[0].stub_calls.clear()
	benches[0].is_crafting = true
	rig.as_peer(h)
	h.gp.on_peer_left(2)
	assert_true("stop_crafting" in benches[0].stub_calls, "holder left: stop")


func test_custom_host_verbs() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	# loop puzzle: the run ends on the runner's machine
	var loops := _both(pc, "loop_puzzle", 900030)
	loops[0].best_time = 20.0
	loops[0].player_run_energy = 15.0
	loops[1]._recording = true
	loops[1]._run_clock = 12.5
	loops[1]._current_path = PackedVector3Array([Vector3.ZERO, Vector3(1, 0, 0), Vector3(2, 0, 1)])
	c.adapter.player.add_to_group("player")
	rig.as_peer(c)
	loops[1]._on_end_entered(c.adapter.player)
	assert_false(loops[1]._recording, "client stopped recording")
	assert_false("_on_end_entered" in loops[1].stub_calls, "no local energy/best")
	assert_eq(loops[0].energy, 15.0, "host credited the run energy")
	assert_true("_set_new_best" in loops[0].stub_calls, "host checked and set the best")
	# implausible run (faster than half the best) gets energy but no best
	loops[0].stub_calls.clear()
	loops[1]._recording = true
	loops[1]._run_clock = 3.0
	c.gp.interact_client.clear()
	rig.as_peer(c)
	loops[1]._on_end_entered(c.adapter.player)
	assert_false("_set_new_best" in loops[0].stub_calls, "too fast: refused")
	assert_eq(loops[0].energy, 30.0, "energy still credited")
	# remote: the client's toggle-all state, not the host's Input
	var rems := _both(pc, "remote", 1800, "pooled")
	c.adapter.camera.equipped_item = rems[1]
	h.grab.set_owner(1800, 2, "equipped")
	_client_input(c, func(): rems[1].remote_lmb_pressed())
	assert_eq(rems[1].stub_calls, [], "nothing local")
	assert_true("_toggle_channel" in rems[0].stub_calls, "host toggled the current channel")
	var sent: Array = c.session.sent_of("tool_in")
	assert_eq(String(sent[-1][2].verb), "mp_remote_lmb", "custom verb")


func test_long_run_fits_the_world_message_cap() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var loops := _both(pc, "loop_puzzle", 900031)
	loops[0].best_time = 60.0
	var seen: Array = []
	loops[0].stub_hook = func(n): seen.append(n)
	var path := PackedVector3Array()
	for i in 900:                  # a 30 s run sampled at 30 Hz
		path.append(Vector3(i * 0.0123456, 1.234567, -i * 0.0098765))
	loops[1]._recording = true
	loops[1]._run_clock = 31.0
	loops[1]._current_path = path
	c.adapter.player.add_to_group("player")
	rig.as_peer(c)
	loops[1]._on_end_entered(c.adapter.player)
	var sent: Array = c.session.sent_of("interact")
	assert_eq(sent.size(), 1, "sent")
	var size := JSON.stringify(sent[0][2]).length()
	assert_true(size < 4096, "under the 4 KB C->H cap (%d B)" % size)
	assert_eq(int(sent[0][2].arg[1].pv3.size()), 120 * 3, "downsampled to 120 points")
	assert_true("_set_new_best" in seen, "the host took the run")
