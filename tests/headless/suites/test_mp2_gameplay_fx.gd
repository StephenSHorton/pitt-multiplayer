extends "res://tests/test_case.gd"
## Effects (MP2-DESIGN 6.12): host extensions emit fx where the game ran a
## host-only branch; each goes out at once on ch3 (so it precedes the BODIES
## despawn batch); clients replay the game's cosmetic helper on their copy in apply
## scope; bonus texts, notifications, achievements and the keypad reveal need no
## node; an effect for an unknown entity is dropped and counted; combo texts are not
## forwarded (clients make them from the mirrored combo).

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
	return [h, c]


func _both(pc: Array, ext: String, eid: int) -> Array:
	var out: Array = []
	for p in pc:
		var n: Node = GpRig.ext_script(ext).new()
		p.adapter.world.add_child(n)
		p.bodies.add(n, eid)
		out.append(n)
	return out


func test_burst_effect_replays_on_the_client_before_the_despawn() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var pins := _both(pc, "pinata", 1900)
	var applied_scope: Array = []
	pins[1].stub_hook = func(n): applied_scope.append([n, c.api.net.is_applying()])
	rig.as_peer(h)
	pins[0]._spawn_burst_effects({})
	h.session.send_world(2, "ents", {"dp": [1900]})     # BODIES' later despawn batch
	var order: Array = []
	for s in h.session.sent3:
		order.append(s[1])
	assert_eq(order, ["fx", "ents"], "the effect precedes the despawn on ch3")
	assert_true(["_detach_audio_players", true] in applied_scope, "client detached its audio (apply scope)")
	assert_true(["_spawn_burst_effects", true] in applied_scope, "client replayed the burst (apply scope)")
	assert_eq(c.gp.fx.applied_kinds, ["pinata_burst"], "applied")
	# the client's own call emits nothing
	rig.as_peer(c)
	pins[1]._spawn_burst_effects({})
	assert_eq(c.session.sent_of("fx").size(), 0, "clients never emit fx")


func test_nodeless_effects() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	rig.as_peer(h)
	MpGate.fx("bonus_text", null, {"text": "DUNK +5", "color": Color(1, 0.5, 0.1).to_html()})
	MpGate.fx("notify", null, {"key": "NOTIF_UV_FOUND"})
	MpGate.ach("INVISIBLE")
	assert_eq(c.adapter.hud_node.texts.size(), 1, "bonus text on the client HUD")
	assert_eq(String(c.adapter.hud_node.texts[0][0]), "DUNK +5", "text")
	assert_has(c.adapter.hud_node.notes, "NOTIF_UV_FOUND", "notification")
	assert_has(c.adapter.achievements, "INVISIBLE", "achievement for everyone present")
	c.gp.on_msg(1, "fx", {"list": [{"kind": "candy_expire", "eid": 4242}]})
	assert_eq(int(c.gp.fx.counters().fx_dropped), 1, "unknown eid dropped")


func test_hud_forwards_bonus_texts_but_not_combo_texts() -> void:
	var pc = await _pair()
	var h = pc[0]
	rig.as_peer(h)
	var hud: Node = GpRig.ext_script("hud").new()
	h.adapter.world.add_child(hud)
	hud._spawn_special_bonus_text("GOLF +9", Color.YELLOW)
	assert_eq(h.session.sent_of("fx").size(), 1, "bonus text forwarded")
	hud._on_chain_combo_triggered(3, 50)
	hud._on_diversity_bonus_triggered(["duck"], 5)
	hud._on_rhythm_bonus_triggered(0.9, 4)
	# the stub handlers do not call _spawn_special_bonus_text; call it as the game's would
	hud._mp_combo_text += 1
	hud._spawn_special_bonus_text("CHAIN x3: +$50", Color.GOLD)
	hud._mp_combo_text -= 1
	assert_eq(h.session.sent_of("fx").size(), 1, "combo text not forwarded")
	assert_eq(hud._mp_combo_text, 0, "handler depth balanced")


func test_crate_and_press_effects() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	var crates := _both(pc, "wodd_crate", 1950)
	rig.as_peer(h)
	crates[0]._spawn_break_effects(Color.GOLD, "legendary", {})
	assert_true("_spawn_break_effects" in crates[1].stub_calls, "client break effects")
	assert_true("_spawn_floating_rarity_text" in crates[1].stub_calls, "client rarity text")
	var presses := _both(pc, "press", 900040)
	rig.as_peer(h)
	presses[0].start_pressing()
	assert_true("start_pressing" in presses[1].stub_calls, "the press stroke replays on the client")
	# a duck in the press is marked (GRAB deny rule) and its remote owner revoked
	var duck := RigidBody3D.new()
	h.adapter.world.add_child(duck)
	var deid: int = h.bodies.add(duck, 1960)
	h.grab.set_owner(deid, 2, "held")
	presses[0].items_to_crush = [duck]
	presses[0].start_pressing()
	assert_true(bool(duck.get_meta("pitt_mp_press_stroke", false)), "stroke meta")
	assert_eq(h.grab.revoked[-1], [deid, "press"], "owner revoked")
	assert_eq(h.gp._deny_rule(deid, duck, 2), "busy", "deny rule refuses a grab mid-stroke")
	presses[0]._spawn_pending_anomalies()
	assert_false(duck.has_meta("pitt_mp_press_stroke"), "cleared after the stroke")
