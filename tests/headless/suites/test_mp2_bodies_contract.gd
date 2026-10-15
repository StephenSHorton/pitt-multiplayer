extends "res://tests/test_case.gd"
## MP2-DESIGN 10.8 conformance (BODIES): world/bodies/bodies.gd AND both other
## streams' doubles of it (tests/fakes/mp2_grab/fake_bodies.gd,
## tests/fakes/mp2_gameplay/fake_bodies.gd) have every 10.2 member; the
## Session has the 10.1 registry; BODIES' own doubles of GRAB and GAMEPLAY are
## modules. Drift fails here.

const BODIES := "res://gamedir/mods/PittMultiplayer/world/bodies/bodies.gd"
const SESSION := "res://gamedir/mods/PittMultiplayer/net/session.gd"
const DOUBLES := ["res://tests/fakes/mp2_grab/fake_bodies.gd", "res://tests/fakes/mp2_gameplay/fake_bodies.gd"]

const SIGNALS_10_2 := {"entity_added": 2, "entity_removed": 1}
const METHODS_10_2 := {"node_of": 1, "eid_of": 1, "is_replicated": 1, "kind_of": 1, "pool_id_of": 1, "flags_of": 1,
	"meta_of": 1, "set_owner_view": 4, "register_meta": 5, "register_fixture": 2, "unregister_fixture": 1,
	"host_follow": 2, "host_follow_push": 3, "host_release": 2, "boost": 2, "meta_dirty": 1, "mark_snap": 1,
	"freeze_world": 0, "set_local_sim": 3, "is_local_sim": 1, "host_state": 1}
const SIGNALS_10_1 := {"world_started": 1, "world_stopped": 1, "peer_world_ready": 1, "peer_left": 1}
const METHODS_10_1 := {"register_module": 1, "get_module": 1, "is_host": 0, "my_peer_id": 0, "send_world": 3,
	"send_unreliable": 2, "send_msg": 3, "host_now": 0, "in_game_peers": 0, "slot_of": 1, "peer_of_slot": 1,
	"avatar_pose": 1, "local_pose": 0, "net_stats": 0}
## the module duck type BODIES implements (10.1)
const MODULE_METHODS := ["mod_name", "msg_kinds", "on_session_start", "on_world_started", "on_world_stopped", "on_msg",
	"on_raw", "on_peer_world_ready", "on_peer_left", "wsnap_section", "apply_wsnap_section", "tick", "counters",
	"teardown"]


func _check(path: String, signals: Dictionary, methods: Dictionary, label: String) -> void:
	if not ResourceLoader.exists(path):
		fail("%s missing: %s" % [label, path])
		return
	var s: Script = load(path)
	assert_true(s != null and s.can_instantiate(), "%s compiles" % label)
	if s == null:
		return
	var sigs := {}
	for sg in s.get_script_signal_list():
		sigs[sg.name] = sg.args.size()
	for n in signals:
		assert_true(sigs.has(n), "%s: signal %s" % [label, n])
		if sigs.has(n):
			assert_eq(int(sigs[n]), int(signals[n]), "%s: %s arity" % [label, n])
	var meths := {}
	var base: Script = s
	while base != null:
		for m in base.get_script_method_list():
			if not meths.has(m.name):
				meths[m.name] = m
		base = base.get_base_script()
	for n in methods:
		assert_true(meths.has(n), "%s: method %s" % [label, n])
		if meths.has(n):
			var m: Dictionary = meths[n]
			var max_args: int = m.args.size()
			var min_args: int = max_args - m.default_args.size()
			var want: int = methods[n]
			assert_true(want >= min_args and want <= max_args, "%s: %s accepts %d arg(s) (%d..%d)" % [label, n, want,
				min_args, max_args])


func test_bodies_conforms() -> void:
	_check(BODIES, SIGNALS_10_2, METHODS_10_2, "bodies.gd")
	var mm := {}
	for n in MODULE_METHODS:
		mm[n] = -1
	var s: Script = load(BODIES)
	var have := {}
	for m in s.get_script_method_list():
		have[m.name] = true
	for n in MODULE_METHODS:
		assert_true(have.has(n), "bodies.gd: module method %s" % n)


func test_doubles_conform() -> void:
	for p in DOUBLES:
		_check(p, SIGNALS_10_2, METHODS_10_2, p.get_file() + " (" + p.get_base_dir().get_file() + ")")


func test_session_registry() -> void:
	_check(SESSION, SIGNALS_10_1, METHODS_10_1, "session.gd")


func test_bodies_doubles_are_modules() -> void:
	for p in ["res://tests/fakes/mp2_bodies/fake_grab.gd", "res://tests/fakes/mp2_bodies/fake_gameplay.gd"]:
		var s = load(p)
		assert_true(s != null, "%s loads" % p)
		if s == null:
			continue
		var m = s.new()
		assert_true(m.has_method("mod_name") and m.has_method("msg_kinds") and m.has_method("on_session_start"),
			"%s is a module" % p)
	var b = load(BODIES).new()
	var kinds: Dictionary = b.msg_kinds()
	assert_eq(kinds.get("ch3_h2c", []), ["ents", "meta"], "BODIES owns ents / meta")
	assert_eq(kinds.get("ch0_c2h", []), ["netq"], "and netq")
	assert_eq(String(b.mod_name()), "bodies", "mod_name")
	b.free()


func test_contract_file_format() -> void:
	var s = load("res://gamedir/mods/PittMultiplayer/world/bodies/contract_bodies.gd")
	var m: Dictionary = s.get_script_constant_map()
	assert_true(m.has("ENTRIES") and m.ENTRIES.size() > 40, "contract entries")
	var features := {}
	for e in m.ENTRIES:
		var p: PackedStringArray = String(e).split("|")
		assert_eq(p.size(), 4, "feature|target|kind|member: %s" % e)
		features[p[0]] = true
		assert_has(["method", "prop", "signal", "const"], p[2], "kind of %s" % e)
	assert_true(features.has("mp2.bodies") and features.has("mp2.wsnap"), "features mp2.bodies, mp2.wsnap")
