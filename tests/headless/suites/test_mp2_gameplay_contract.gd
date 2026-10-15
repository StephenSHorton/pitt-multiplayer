extends "res://tests/test_case.gd"
## 10.8 conformance for the GAMEPLAY side: gameplay.gd has the module duck type
## and the 10.4 host API, mp_gate.gd has the 10.4 statics, BODIES' fake_gameplay.gd
## agrees with the real module on name and message kinds; the GAMEPLAY doubles of
## the other streams (fake_bodies, fake_grab) still carry the 10.2 / 10.3 surface
## GAMEPLAY calls; the contract file parses and lists every feature.

const GAMEPLAY := "res://gamedir/mods/PittMultiplayer/gameplay/gameplay.gd"
const GATE := "res://gamedir/mods/PittMultiplayer/gameplay/mp_gate.gd"
const CONTRACT := "res://gamedir/mods/PittMultiplayer/gameplay/contract_gameplay.gd"
const BODIES_FAKE_GAMEPLAY := "res://tests/fakes/mp2_bodies/fake_gameplay.gd"
const MY_FAKE_BODIES := "res://tests/fakes/mp2_gameplay/fake_bodies.gd"
const MY_FAKE_GRAB := "res://tests/fakes/mp2_gameplay/fake_grab.gd"

const MODULE := ["mod_name", "msg_kinds", "on_session_start", "on_world_started", "on_world_stopped", "on_msg",
	"on_peer_world_ready", "on_peer_left", "wsnap_section", "apply_wsnap_section", "tick", "counters", "teardown"]
const API_10_4 := ["rig_of", "ghost_of", "host_exec", "player_impulse", "holders_of"]
const GATE_10_4 := ["live", "is_client", "sink", "replay", "input", "input_predict", "begin_input_scope",
	"end_input_scope"]
## the 10.2 members GAMEPLAY calls
const BODIES_USED := ["node_of", "eid_of", "register_meta", "register_fixture", "unregister_fixture", "boost",
	"meta_dirty", "mark_snap"]
const GRAB_USED := ["owner_of", "hold_kind", "revoke", "grant", "add_deny_rule"]


static func _methods(path: String) -> Array:
	var out: Array = []
	var s: Script = load(path)
	while s != null:
		for m in s.get_script_method_list():
			out.append(String(m.name))
		s = s.get_base_script()
	return out


func test_gameplay_module_surface() -> void:
	var ms := _methods(GAMEPLAY)
	for m in MODULE + API_10_4:
		assert_has(ms, m, "gameplay.gd has %s" % m)
	var gp = load(GAMEPLAY).new()
	assert_eq(gp.mod_name(), "gameplay", "mod_name")
	var k: Dictionary = gp.msg_kinds()
	assert_eq(k.ch3_c2h, ["interact", "tool_in"], "C->H world kinds (2.4)")
	assert_eq(k.ch3_h2c, ["fx", "pimp", "fixture_spawn"], "H->C world kinds (2.4)")
	assert_eq(k.ch0_h2c, ["combo"], "combo on ch0")


func test_gate_statics() -> void:
	var ms := _methods(GATE)
	for m in GATE_10_4:
		assert_has(ms, m, "mp_gate.gd has %s" % m)
	var g = load(GATE)
	assert_eq(typeof(g.exec_peer), TYPE_INT, "static var exec_peer")


func test_bodies_fake_gameplay_agrees() -> void:
	if not ResourceLoader.exists(BODIES_FAKE_GAMEPLAY):
		fail("BODIES' fake_gameplay.gd missing (10.8)")
		return
	var f = load(BODIES_FAKE_GAMEPLAY).new()
	assert_eq(f.mod_name(), "gameplay", "fake mod_name")
	if f.has_method("msg_kinds"):
		var real: Dictionary = load(GAMEPLAY).new().msg_kinds()
		var fk: Dictionary = f.msg_kinds()
		for ch in fk:
			for kind in fk[ch]:
				assert_has(real.get(ch, []), kind, "fake kind %s/%s is a real GAMEPLAY kind" % [ch, kind])


func test_my_doubles_carry_what_gameplay_calls() -> void:
	var bm := _methods(MY_FAKE_BODIES)
	for m in BODIES_USED:
		assert_has(bm, m, "fake_bodies has %s" % m)
	var gm := _methods(MY_FAKE_GRAB)
	for m in GRAB_USED:
		assert_has(gm, m, "fake_grab has %s" % m)


func test_contract_file() -> void:
	var entries: Array = load(CONTRACT).get_script_constant_map().ENTRIES
	assert_true(entries.size() > 400, "contract lists every overridden and used member (%d)" % entries.size())
	var feats := {}
	for e in entries:
		var p: PackedStringArray = String(e).split("|")
		assert_eq(p.size(), 4, "format feature|target|kind|member: %s" % e)
		feats[p[0]] = true
	for f in ["mp2.sinks", "mp2.machines", "mp2.interact", "mp2.combo"]:
		assert_true(feats.has(f), "feature %s" % f)
