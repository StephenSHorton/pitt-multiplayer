extends "res://tests/test_case.gd"
## MP2 GRAB conformance (MP2-DESIGN 10.3, 10.8): grab.gd and every fake_grab.gd
## the other streams keep (BODIES fakes/mp2_bodies, GAMEPLAY fakes/mp2_gameplay)
## have every 10.3 member; GRAB's own fake_bodies.gd has every 10.2 member; the
## module duck type of 10.1; the game contract file is well formed.

const Grab = preload("res://gamedir/mods/PittMultiplayer/grab/grab.gd")
const ContractGrab = preload("res://gamedir/mods/PittMultiplayer/grab/contract_grab.gd")
const FakeBodies = preload("res://tests/fakes/mp2_grab/fake_bodies.gd")

const GRAB_SIGNALS := ["owner_changed"]
const GRAB_METHODS := ["owner_of", "hold_kind", "epoch_of", "is_mine", "can_take", "add_deny_rule", "revoke", "grant"]
const MODULE_METHODS := ["mod_name", "msg_kinds", "on_session_start", "on_world_started", "on_world_stopped", "on_msg",
	"on_raw", "on_peer_world_ready", "on_peer_left", "wsnap_section", "apply_wsnap_section", "tick", "counters", "teardown"]
const BODIES_SIGNALS := ["entity_added", "entity_removed"]
const BODIES_METHODS := ["node_of", "eid_of", "is_replicated", "kind_of", "pool_id_of", "flags_of", "meta_of",
	"set_owner_view", "register_meta", "register_fixture", "unregister_fixture", "host_follow", "host_follow_push",
	"host_release", "boost", "meta_dirty", "mark_snap", "freeze_world", "set_local_sim", "is_local_sim", "host_state"]
const OTHER_FAKE_GRABS := ["res://tests/fakes/mp2_bodies/fake_grab.gd", "res://tests/fakes/mp2_gameplay/fake_grab.gd"]


func _missing(s: Script, methods: Array, signals: Array) -> Array:
	var have := {}
	var sc := s
	while sc != null:
		for m in sc.get_script_method_list():
			have[String(m.name)] = true
		for g in sc.get_script_signal_list():
			have["signal:" + String(g.name)] = true
		sc = sc.get_base_script()
	var out: Array = []
	for m in methods:
		if not have.has(m):
			out.append(m)
	for g in signals:
		if not have.has("signal:" + g):
			out.append("signal " + g)
	return out


func test_grab_module_has_the_10_3_surface() -> void:
	assert_eq(_missing(Grab, GRAB_METHODS, GRAB_SIGNALS), [], "grab.gd 10.3 members")
	assert_eq(_missing(Grab, MODULE_METHODS, []), [], "grab.gd module duck type 10.1")
	var g = Grab.new()
	assert_eq(g.mod_name(), "grab", "mod_name")
	var k: Dictionary = g.msg_kinds()
	assert_eq(k.ch3_c2h, ["own_req", "own_rel", "own_equip", "own_unequip"], "c2h kinds (10.5 GRAB-owned)")
	assert_eq(k.ch3_h2c, ["own"], "h2c kinds")
	assert_eq(k.raw_c2h, [5], "frame kind 5")
	# 10.3 defaults before a session
	assert_eq(g.owner_of(5), 1, "owner 1 by default")
	assert_eq(g.hold_kind(5), "", "kind '' by default")
	assert_eq(g.epoch_of(5), 0, "epoch 0 by default")
	assert_false(g.ext_live(), "inert before a session")


func test_other_streams_fake_grab_conform() -> void:
	for path in OTHER_FAKE_GRABS:
		if not ResourceLoader.exists(path):
			print("    note: %s not present yet (owned by another stream)" % path)
			continue
		var s = load(path)
		assert_true(s is Script, path + " loads")
		if s is Script:
			assert_eq(_missing(s, GRAB_METHODS, GRAB_SIGNALS), [], path + " 10.3 members")


func test_fake_bodies_has_the_10_2_surface() -> void:
	assert_eq(_missing(FakeBodies, BODIES_METHODS, BODIES_SIGNALS), [], "fakes/mp2_grab/fake_bodies.gd 10.2 members")
	var real := "res://gamedir/mods/PittMultiplayer/world/bodies/bodies.gd"
	if ResourceLoader.exists(real):
		var s = load(real)
		if s is Script:
			var miss := _missing(s, BODIES_METHODS, BODIES_SIGNALS)
			if not miss.is_empty():
				print("    note: BODIES bodies.gd still lacks %s (their suite owns this)" % str(miss))


func test_contract_entries_well_formed() -> void:
	var seen := {}
	for e in ContractGrab.ENTRIES:
		var parts := String(e).split("|")
		assert_eq(parts.size(), 4, "4 fields: " + e)
		assert_eq(parts[0], "mp2.grab", "feature mp2.grab: " + e)
		assert_true(parts[2] in ["method", "prop", "signal", "const"], "kind: " + e)
		assert_false(seen.has(e), "unique: " + e)
		seen[e] = true
	for m in ["picked_object", "equipped_item", "max_grab_distance", "_begin_carry", "drop_object", "release_held_object", "handle_input"]:
		assert_true(ContractGrab.ENTRIES.any(func(x): return String(x).ends_with("main_camera.gd|method|" + m) or String(x).ends_with("main_camera.gd|prop|" + m)),
			"10.7 lists main_camera." + m)


func test_extension_overrides_only_the_three_methods() -> void:
	var ext: Script = load("res://gamedir/mods/PittMultiplayer/extensions/grab/main_camera_grab_ext.gd")
	var own: Array = []
	var rx := RegEx.create_from_string("(?m)^func\\s+(\\w+)")
	for m in rx.search_all(ext.source_code):
		own.append(m.get_string(1))
	var base_names := {}
	# compare with the game script itself (the bottom of the chain): once the loader took over
	# main_camera.gd at boot, the extension's base chain already contains this extension
	var game: Script = ext.get_base_script()
	while game.get_base_script() != null:
		game = game.get_base_script()
	for m in game.get_script_method_list():
		base_names[String(m.name)] = true
	var overrides: Array = []
	for n in own:
		if base_names.has(n):
			overrides.append(n)
	overrides.sort()
	assert_eq(overrides, ["_begin_carry", "drop_object", "release_held_object"], "overrides (10.3)")
