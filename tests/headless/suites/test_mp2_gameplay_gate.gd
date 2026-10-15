extends "res://tests/test_case.gd"
## MP2 gate (MP2-DESIGN 1.1): the four gate kinds x no session / host / client
## (normal, apply scope, input scope); the input scope is set only by the
## dispatcher extensions; extensions take the vanilla path outside a session;
## player branches of the maw, fail-safe and press on a client; a doubled forward
## (subclass extension + base extension) collapses; every override is in the
## GAMEPLAY contract.

const GpRig = preload("res://tests/fakes/mp2_gameplay/gp_rig.gd")
const MpGate = preload("res://gamedir/mods/PittMultiplayer/gameplay/mp_gate.gd")
const EXT := "res://gamedir/mods/PittMultiplayer/extensions/gameplay/"
const CONTRACT := "res://gamedir/mods/PittMultiplayer/gameplay/contract_gameplay.gd"

var rig = null
var _nodes: Array = []


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


func _ext(name: String, parent: Node = null) -> Node:
	var n: Node = GpRig.ext_script(name).new()
	if parent != null:
		parent.add_child(n)
	return n


func _gates(node: Object) -> Array:
	return [MpGate.sink(node), MpGate.replay(node), MpGate.input(node, "v"), MpGate.input_predict(node, "v")]


func test_no_session_everything_passes() -> void:
	await rig.cleanup()
	MpGate.reset()
	var fan := _ext("fan")
	assert_eq(_gates(fan), [false, false, false, false], "no session: all gates pass")
	fan.toggle_fan()
	fan.remote_toggle(true)
	assert_eq(fan.stub_calls, ["toggle_fan", "remote_toggle"], "vanilla path (super) ran")
	assert_false(MpGate.live(), "not live")
	fan.free()


func test_host_everything_passes() -> void:
	var pc = await _pair()
	rig.as_peer(pc[0])
	var fan := _ext("fan", pc[0].adapter.world)
	assert_true(MpGate.is_host(), "host")
	assert_eq(_gates(fan), [false, false, false, false], "host: all gates pass")
	MpGate.begin_input_scope()
	assert_eq(_gates(fan), [false, false, false, false], "host in input scope: all pass, nothing forwarded")
	MpGate.end_input_scope()
	assert_eq(pc[0].session.sent3.size(), 0, "host never forwards")
	fan.toggle_fan()
	assert_has(fan.stub_calls, "toggle_fan", "super ran")


func test_client_normal_apply_input_scopes() -> void:
	var pc = await _pair()
	var c = pc[1]
	rig.as_peer(c)
	var fan := _ext("fan", c.adapter.world)
	var eid: int = c.bodies.add(fan, 1500, "pooled", "tool_fan")
	# normal: machine-originated on a client copy
	assert_eq(_gates(fan), [true, true, true, true], "client normal: everything blocks")
	assert_eq(c.session.sent3.size(), 0, "nothing forwarded outside the input scope")
	# apply scope (BODIES/GAMEPLAY applying host state)
	c.api.net.begin_apply(1)
	assert_eq(_gates(fan), [true, false, false, false], "apply scope: sink blocks, replay/input pass")
	c.api.net.end_apply()
	# input scope (the local player's dispatchers)
	MpGate.begin_input_scope()
	assert_true(MpGate.input(fan, "toggle_fan"), "input blocks in the input scope")
	assert_false(MpGate.input_predict(fan, "interact"), "input_predict passes after forwarding")
	assert_true(MpGate.sink(fan), "sink still blocks")
	assert_true(MpGate.replay(fan), "replay still blocks")
	MpGate.end_input_scope()
	var sent: Array = c.session.sent_of("interact")
	assert_eq(sent.size(), 2, "both input calls forwarded")
	assert_eq(int(sent[0][2].eid), eid, "eid")
	assert_eq(String(sent[0][2].verb), "toggle_fan", "verb")
	assert_eq(String(sent[1][2].verb), "interact", "predict verb")
	assert_true(sent[0][2].has("aim"), "aim attached")
	# the gated extension method
	fan.stub_calls.clear()
	MpGate.begin_input_scope()
	fan.toggle_fan()
	MpGate.end_input_scope()
	assert_eq(fan.stub_calls, [], "client: the toggle is not run locally")
	c.api.net.begin_apply(1)
	fan.remote_toggle(true)
	c.api.net.end_apply()
	assert_eq(fan.stub_calls, ["remote_toggle"], "apply scope: replay setter runs")


func test_input_scope_only_from_dispatchers() -> void:
	var pc = await _pair()
	rig.as_peer(pc[1])
	var ray := _ext("interact_ray", pc[1].adapter.world)
	var seen: Array = []
	ray.stub_hook = func(n): seen.append([n, MpGate.in_input_scope()])
	assert_false(MpGate.in_input_scope(), "no scope before")
	ray.handle_workbench_interaction()
	ray._stop_crafting_if_manual(ray)
	ray.handle_automated_workbench_interaction()
	ray.handle_terminal_interaction(0.016)
	ray.handle_button_interaction()
	assert_eq(seen.size(), 5, "five dispatchers ran")
	for s in seen:
		assert_true(s[1], "%s ran inside the input scope" % s[0])
	assert_false(MpGate.in_input_scope(), "scope closed after each dispatcher")
	ray.refresh_controls()
	assert_eq(seen[-1], ["refresh_controls", false], "a non-dispatcher method is outside the scope")


func test_maw_and_fail_safe_player_branch_on_client() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	rig.as_peer(c)
	var maw := _ext("bottom_maw", c.adapter.world)
	c.bodies.add(maw, 900001, "fixture")
	var duck := RigidBody3D.new()
	c.adapter.world.add_child(duck)
	c.adapter.player.add_to_group("player")
	maw._on_body_entered(duck)
	assert_eq(maw.stub_calls, [], "client: a duck is not consumed locally")
	maw._on_body_entered(c.adapter.player)
	assert_eq(maw.stub_calls, ["_on_body_entered"], "client: the local player's branch runs")
	assert_eq(int(c.gp.penalties.counters().penalties_sent), 1, "penalty maw sent")
	maw._handle_body_cleanup(duck, "duck", true)
	assert_eq(maw.stub_calls.size(), 1, "cleanup of a non-player body blocked")
	maw._handle_body_cleanup(c.adapter.player, "player", false)
	assert_eq(maw.stub_calls.size(), 2, "cleanup of the player runs (respawn)")
	var fs := _ext("fail_safe", c.adapter.world)
	fs._on_body_entered(duck)
	assert_eq(fs.stub_calls, [], "client: fail-safe ignores bodies")
	fs._on_body_entered(c.adapter.player)
	assert_eq(fs.stub_calls, ["_on_body_entered"], "client: local player respawns")
	assert_eq(int(c.gp.penalties.counters().penalties_sent), 2, "penalty fail_safe sent")
	# host: super runs; a consumed body owned by a remote peer is revoked
	rig.as_peer(h)
	var hmaw := _ext("bottom_maw", h.adapter.world)
	var hduck := RigidBody3D.new()
	h.adapter.world.add_child(hduck)
	var deid: int = h.bodies.add(hduck, 1777)
	h.grab.set_owner(deid, 2, "held")
	hduck.set_meta("consumed", true)
	hmaw._on_body_entered(hduck)
	assert_eq(hmaw.stub_calls, ["_on_body_entered"], "host consumes")
	assert_eq(h.grab.revoked, [[deid, "maw"]], "remote owner revoked")
	duck.queue_free()
	hduck.queue_free()


func test_press_client_branch_and_forward() -> void:
	var pc = await _pair()
	var c = pc[1]
	rig.as_peer(c)
	var press := _ext("press", c.adapter.world)
	c.bodies.add(press, 900010, "fixture")
	press.is_player_in = true
	press.player = c.adapter.player
	var junk := RigidBody3D.new()
	press.items_to_crush = [junk]
	press.process_crushed_items()
	junk.free()
	assert_eq(c.adapter.player.respawns, 1, "the local player is respawned by its own press copy (P7)")
	assert_eq(press.items_to_crush.size(), 0, "crush list cleared")
	assert_false("process_crushed_items" in press.stub_calls, "no local crushing")
	MpGate.begin_input_scope()
	press.interact()
	MpGate.end_input_scope()
	assert_eq(c.session.sent_of("interact").size(), 1, "interact forwarded")
	assert_false("interact" in press.stub_calls, "not run locally")


func test_double_gate_collapses() -> void:
	var pc = await _pair()
	var c = pc[1]
	rig.as_peer(c)
	var vac := _ext("vacuum", c.adapter.world)
	c.bodies.add(vac, 1600, "pooled", "tool_vacuum")
	MpGate.begin_input_scope()
	vac.toggle_vacuum()
	MpGate.input(vac, "toggle_vacuum")   # what an intact base extension would add
	MpGate.end_input_scope()
	assert_eq(c.session.sent_of("interact").size(), 1, "one forward for one player action")
	assert_eq(c.gp.interact_client.counters().interact_collapsed, 1, "the second was collapsed")


const CRATE_SUBCLASS_EXTS := ["metal_crate_ext.gd", "plush_crate_ext.gd", "anomaly_crate_ext.gd"]


func test_every_override_is_in_the_contract() -> void:
	var entries: Array = load(CONTRACT).get_script_constant_map().ENTRIES
	var listed := {}
	for e in entries:
		var p: PackedStringArray = String(e).split("|")
		listed["%s|%s" % [p[1], p[3]]] = true
	var own := ["mp_golf_shot", "mp_remote_run", "mp_remote_lmb", "_mp_clear_ritual", "_mp_rack_on_host",
		"_mp_weighs_on_front", "_mp_drop_and_respawn"]
	var da := DirAccess.open(EXT)
	var missing: Array = []
	var files := 0
	for f in da.get_files():
		if not f.ends_with("_ext.gd"):
			continue
		files += 1
		var src := FileAccess.get_file_as_string(EXT + f)
		var target := src.get_slice("\"", 1)
		# metal/plush/anomaly crates inherit every gated method from wodd_crate.gd through
		# class_name GamblingCrate (S-M3): their entries are wodd_crate.gd's
		if f in CRATE_SUBCLASS_EXTS:
			target = "res://scripts/wodd_crate.gd"
		var re := RegEx.new()
		re.compile("(?m)^func (\\w+)\\(")
		for m in re.search_all(src):
			var fn := m.get_string(1)
			if fn in own:
				continue
			if not listed.has("%s|%s" % [target, fn]):
				missing.append("%s:%s" % [f, fn])
	assert_eq(files, 69 + CRATE_SUBCLASS_EXTS.size(), "69 GAMEPLAY extension files (MP2 10.9, piston_3_ext.gd added) + the S-M3 crate subclasses")
	assert_eq(missing, [], "every overridden game method is in contract_gameplay.gd")
