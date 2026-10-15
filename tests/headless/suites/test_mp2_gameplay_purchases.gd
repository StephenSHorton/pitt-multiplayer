extends "res://tests/test_case.gd"
## Purchases in the shared world (MP2-DESIGN 6.1) at the terminal extension: a
## bought fixture spawned by the host terminal reaches every client as
## fixture_spawn and is built by the client's own terminal in apply scope; a
## client's terminal never spawns pooled tools or toys on its own (only fixtures,
## e.g. from its save flags); recall on a client goes to the host as
## PittMultiplayer.recall and runs the host's _recall_tool; the host never recalls
## a unit a remote player owns. (Host spawning on buy: test_mp_net_purchase.gd.)

const GpRig = preload("res://tests/fakes/mp2_gameplay/gp_rig.gd")
const MpGate = preload("res://gamedir/mods/PittMultiplayer/gameplay/mp_gate.gd")
const Commands = preload("res://gamedir/mods/PittAPI/core/commands.gd")

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


func test_fixture_spawn_reaches_clients() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	rig.as_peer(h)
	h.adapter.ui_node._spawn_tool_instance("press", 0)
	assert_eq(h.adapter.ui_node.spawned_tools, [["press", 0]], "host terminal spawned the press")
	var fs: Array = h.session.sent_of("fixture_spawn")
	assert_eq(fs.size(), 1, "fixture_spawn broadcast")
	assert_eq(String(fs[0][2].key), "press", "key")
	assert_eq(c.adapter.ui_node.spawned_tools, [["press", 0]], "client terminal built the same fixture")
	h.adapter.ui_node._spawn_toy_instance("bowling_pin_set")
	assert_eq(c.adapter.ui_node.spawned_toys, ["bowling_pin_set"], "bowling set on the client")
	h.adapter.ui_node._spawn_tool_instance("broom", 0)
	assert_eq(h.session.sent_of("fixture_spawn").size(), 2, "pooled tools are not fixtures")


func test_client_terminal_spawns_only_fixtures() -> void:
	var pc = await _pair()
	var c = pc[1]
	rig.as_peer(c)
	var ui = c.adapter.ui_node
	ui._spawn_tool_instance("broom", 0)
	ui._spawn_toy_instance("gambling_wodden_crate")
	assert_eq(ui.spawned_tools, [], "no local pooled tool on a client")
	assert_eq(ui.spawned_toys, [], "no local toy on a client")
	ui._spawn_tool_instance("trading", 0)    # save-flag path (check_spawn_press)
	ui._spawn_toy_instance("bowling_pin_set")
	assert_eq(ui.spawned_tools, [["trading", 0]], "fixtures from the client's own load path")
	assert_eq(ui.spawned_toys, ["bowling_pin_set"], "bowling set from the save flag")
	assert_eq(c.session.sent_of("fixture_spawn").size(), 0, "clients never broadcast")


func test_recall_goes_to_the_host() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var asked: Array = []
	c.api.commands.register("PittMultiplayer.recall", func(a, _ctx):
		asked.append(a.tool)
		return {}, {"schema": {"tool": TYPE_STRING}})
	rig.as_peer(c)
	var n: int = c.adapter.ui_node._recall_tool("broom")
	assert_eq(n, 1, "the client's row shows recalled")
	assert_eq(asked, ["broom"], "PittMultiplayer.recall sent")
	assert_eq(c.adapter.ui_node.recalled_tools, [], "nothing recalled locally")
	# host side of the command
	rig.as_peer(h)
	var ctx = Commands.PittCommandCtx.new()
	ctx.origin_peer = 2
	ctx.is_remote = true
	var r = h.gp._cmd_recall({"tool": "broom"}, ctx)
	assert_eq(h.adapter.ui_node.recalled_tools, ["broom"], "host _recall_tool ran")
	assert_eq(int(r.recalled), 1, "count returned")


func test_host_never_recalls_a_remote_players_unit() -> void:
	var pc = await _pair()
	var h = pc[0]
	rig.as_peer(h)
	var unit := RigidBody3D.new()
	h.adapter.world.add_child(unit)
	var eid: int = h.bodies.add(unit, 2100, "pooled", "tool_broom")
	assert_false(h.adapter.ui_node._unit_owned_elsewhere(unit), "free unit: recallable")
	h.grab.set_owner(eid, 2, "held")
	assert_true(h.adapter.ui_node._unit_owned_elsewhere(unit), "held by a remote player: skipped")
	h.grab.set_owner(eid, 1, "held")
	assert_false(h.adapter.ui_node._unit_owned_elsewhere(unit), "the host's own carry: game rule (recall releases it)")
	unit.set_meta("stub_owned_elsewhere", true)
	assert_true(h.adapter.ui_node._unit_owned_elsewhere(unit), "the game's own metas still apply")
	unit.queue_free()
