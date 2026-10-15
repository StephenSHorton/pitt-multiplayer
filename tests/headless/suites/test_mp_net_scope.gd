extends "res://tests/test_case.gd"
## Loader additions (MP-DESIGN 3.2) against the REAL PittAPI core:
## L1 scope "local" (builtins never reach the host, R18; remote local/internal
## refused; describe flags), L2 provider gate + install/uninstall restores the
## LocalAuthority, L3 tagging, L4 contract_check, L5 user root / isolate prefix,
## L6 remote player ids. Plus H-SP1: PittMultiplayer loads inert.

const Manifest = preload("res://gamedir/mods/PittAPI/core/manifest.gd")
const Entities = preload("res://gamedir/mods/PittAPI/core/entities.gd")
const MpAuthority = preload("res://gamedir/mods/PittMultiplayer/net/mp_authority.gd")

const LOCAL_BUILTINS := ["save.isolate", "perf.pin_physics", "achievements.suppress", "presence.suppress",
	"player.teleport", "player.impulse"]


func _mp_ctx():
	return core.loader.mods["PittMultiplayer"].ctx


func test_h_sp1_mod_loaded_inert() -> void:
	assert_eq(core.loader.get_state("PittMultiplayer"), "LOADED", "PittMultiplayer loads: %s" % core.loader.mods.get("PittMultiplayer", {}).get("reason", ""))
	assert_eq(core.net_provider, "PittMultiplayer", "it is the net provider")
	assert_true(core.net.is_authority() and not core.net.is_multiplayer(), "single player while no session")
	var node = core.loader.mods["PittMultiplayer"].node
	assert_true(node != null and node.session != null, "session exists")
	assert_eq(node.session.get_state(), "idle", "idle")
	assert_true(Engine.has_meta("pitt_mp"), "extension hook registered")


func test_l1_describe_and_remote_refusal() -> void:
	for n in LOCAL_BUILTINS:
		assert_eq(String(core.commands.describe(n).get("scope", "")), "local", "%s is scope local" % n)
	assert_eq(String(core.commands.describe("money.add").scope), "authority", "money.add authority")
	var env := {"v": 1, "id": 1, "name": "achievements.suppress", "args": {}, "mod": "x", "origin": 2, "t": 0}
	var r: Dictionary = core.commands.dispatch_remote(env, 2)
	assert_false(bool(r.ok), "remote local-scope command refused")
	assert_eq(String(r.code), "ERR_DENIED", "ERR_DENIED")
	assert_eq(core.commands.register("t.badscope", func(_a, _c): return 1, {"scope": "everywhere"}), ERR_INVALID_PARAMETER,
		"bad scope rejected")


func test_l1_client_keeps_local_commands_local() -> void:
	var a := MpAuthority.new(null, "client", 9)
	var prev = core.authority
	core._set_authority(a)
	var r = core.commands.execute("perf.pin_physics", {"hz": 60})
	assert_true(r.done and r.ok, "scope local runs on a non-authority immediately: %s" % r.error)
	var r2 = core.commands.execute("money.add", {"amount": 1})
	assert_true(r2.done and not r2.ok and r2.code == "ERR_UNAVAILABLE", "authority commands need the host (no session -> unavailable)")
	core._set_authority(prev)
	Engine.physics_ticks_per_second = 60


func test_l2_provider_gate() -> void:
	var other = core.loader.mods["ExampleMod"].ctx
	assert_eq(other.net.install_authority(MpAuthority.new(null, "host", 1)), ERR_UNAUTHORIZED, "non-provider refused")
	assert_false(other.net.is_provider(), "ExampleMod is not the provider")
	var ctx = _mp_ctx()
	assert_true(ctx.net.is_provider(), "PittMultiplayer is")
	assert_eq(ctx.net.install_authority(RefCounted.new()), ERR_INVALID_PARAMETER, "duck-type validated")
	var starts := [0]
	var cb := func(): starts[0] += 1
	other.net.session_started.connect(cb)
	var a := MpAuthority.new(null, "host", 1)
	assert_eq(ctx.net.install_authority(a), OK, "provider installs")
	assert_true(core.net.is_multiplayer(), "multiplayer now")
	assert_eq(core.net.get_authority_kind(), "pitt_mp", "kind")
	ctx.net.emit_session_started({"role": "host"})
	assert_eq(starts[0], 1, "session_started fans out to every mod's api.net")
	assert_eq(other.net.get_session_info().get("role", ""), "host", "session info")
	ctx.net.emit_peers_changed([{"peer": 1, "slot": 1, "name": "h"}, {"peer": 5, "slot": 2, "name": "c"}])
	assert_eq(other.net.get_players().size(), 2, "players")
	assert_eq(other.net.get_peer_info(5).get("name", ""), "c", "peer info")
	ctx.net.uninstall_authority()
	ctx.net.emit_session_ended("left")
	assert_false(core.net.is_multiplayer(), "LocalAuthority restored")
	assert_eq(core.net.get_authority_kind(), "local", "local")
	assert_true(other.net.get_players().is_empty(), "players cleared")
	other.net.session_started.disconnect(cb)


func test_l2_manifest_provides() -> void:
	var r := Manifest.parse_text('{"id":"NetMod","name":"x","version":"1.0.0","api_version":"^1.1","provides":["net"]}', "NetMod")
	assert_true(r.ok and r.data.provides == ["net"], "provides net")
	r = Manifest.parse_text('{"id":"NetMod","name":"x","version":"1.0.0","api_version":"^1.1","provides":["gpu"]}', "NetMod")
	assert_false(r.ok, "unknown provides value rejected")
	r = Manifest.parse_text('{"id":"NetMod","name":"x","version":"1.0.0","api_version":"^1.1","provides":"net"}', "NetMod")
	assert_false(r.ok, "provides must be an array")


func test_l2_only_one_provider() -> void:
	var root := "user://pittapi_t_prov"
	var mods := ProjectSettings.globalize_path(root.path_join("mods"))
	rm_rf(ProjectSettings.globalize_path(root))
	make_mod(mods, "NetA", {"provides": ["net"], "api_version": "^1.1"})
	make_mod(mods, "NetB", {"provides": ["net"], "api_version": "^1.1", "load_order": 200})
	var inst := spawn_instance(mods, root.path_join("user"))
	await wait_frames(1)
	assert_eq(inst.net_provider, "NetA", "first in load order provides")
	assert_eq(inst.loader.get_state("NetB"), "FAILED", "the second provider fails")
	assert_true(String(inst.loader.mods["NetB"].reason).contains("provide 'net'"), "with a reason")
	inst.queue_free()
	await wait_frames(1)
	rm_rf(ProjectSettings.globalize_path(root))


func test_l3_apply_tagging() -> void:
	var ctx = _mp_ctx()
	var bucket := capture("money.changed")
	var any := capture("mod.PittMultiplayer.t3")
	ctx.net.begin_apply(1)
	assert_true(core.net.is_applying(), "applying")
	core.events.emit_internal("mod.PittMultiplayer.t3", {}, "api")
	var gs = tree.root.get_node("GameState")
	gs.money.add_int(7)
	gs.money_updated.emit(gs.money)
	ctx.net.end_apply()
	assert_false(core.net.is_applying(), "done")
	assert_true(any.size() == 1 and any[0].source == "net" and any[0].origin == 1, "event tagged origin=1 source=net")
	assert_true(bucket.size() >= 1 and String(bucket.back().payload.reason) == "net", "money.changed reason net: %s" % str(bucket))
	var other = core.loader.mods["ExampleMod"].ctx
	other.net.begin_apply(1)
	assert_false(core.net.is_applying(), "non-provider cannot open an apply window")


func test_l4_contract_check() -> void:
	var ctx = _mp_ctx()
	var r: Dictionary = ctx.contract_check(["f1|GameState|prop|money", "f1|GameState|method|add_money",
		"f2|GameState|method|no_such_method", "f3|res://scripts/hole.gd|method|_on_product_consumed",
		"f4|res://scripts/hole.gd|prop|nope", "f5|res://scripts/missing_script.gd|method|x"])
	assert_false(bool(r.ok), "missing members -> not ok")
	assert_eq(r.features_off, ["f2", "f4", "f5"], "features off: %s" % str(r.features_off))
	assert_true(String(" ".join(r.missing)).contains("no_such_method"), "missing listed")
	var r2: Dictionary = ctx.contract_check(["a|GameState|signal|money_updated", "a|res://scripts/upgradeUI.gd|const|COLOR_DIM"])
	assert_true(bool(r2.ok), "present members ok (script introspection, consts too): %s" % str(r2))


func test_l5_isolate_prefix_follows_user_root() -> void:
	assert_eq(core.instance_name, "", "no --pittapi-instance in the test run")
	var root := "user://pittapi-t5"
	var inst := spawn_instance(ProjectSettings.globalize_path("user://pittapi_t5_mods_none"), root)
	await wait_frames(1)
	assert_eq(inst.builtins.isolate_prefix(), "user://pittapi-t5/", "prefix follows the user root")
	var bad = inst.commands.execute("save.isolate", {"enabled": true, "path": "user://pittapi/test/x.save"})
	assert_false(bad.ok, "the default root is refused for this instance")
	var ok = inst.commands.execute("save.isolate", {"enabled": true, "path": "user://pittapi-t5/test/x.save"})
	assert_true(ok.ok, "own root accepted: %s" % ok.error)
	inst.commands.execute("save.isolate", {"enabled": false})
	inst.queue_free()
	await wait_frames(1)
	rm_rf(ProjectSettings.globalize_path(root))


func test_l6_remote_player_ids() -> void:
	var e := Entities.new(null)
	var n1 := Node3D.new()
	var n2 := Node3D.new()
	var local := Node3D.new()
	assert_eq(e.register_player(local, 1), 1, "local player slot 1")
	var id1 := e.register_remote_player(n1, 77)
	var id2 := e.register_remote_player(n2, 88)
	assert_true(id1 >= 2 and id2 >= 2 and id1 != id2, "remote players get slots 2..999: %d %d" % [id1, id2])
	assert_eq(e.kind_of(id1), "player", "kind player")
	assert_eq(e.register_remote_player(n1, 77), id1, "stable")
	var n3 := Node3D.new()
	assert_eq(e.register_remote_player(n3, 1), 0, "the local peer is refused")
	e.unregister_remote_player(77)
	assert_eq(e.get_node(id1), null, "unregistered")
	assert_eq(e.get_node(id2), n2, "others kept")
	for n in [n1, n2, n3, local]:
		n.free()
