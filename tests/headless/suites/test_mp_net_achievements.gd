extends "res://tests/test_case.gd"
## Achievements "presence" (D4): a progressed join grants nothing; a crossing
## after the join grants once; "none" keeps everything suppressed; a host cheat
## broadcast suppresses every peer (R17); the cache is restored after the session.

const MpRig = preload("res://tests/fakes/mp_net/mp_rig.gd")
const Achievements = preload("res://gamedir/mods/PittMultiplayer/policy/achievements.gd")
const FakeAdapter = preload("res://tests/fakes/mp_net/fake_game_adapter.gd")
const FakeApi = preload("res://tests/fakes/mp_net/fake_api.gd")

var rig = null


func before_all() -> void:
	rig = MpRig.new(tree, runner)


func after_all() -> void:
	await rig.cleanup()


class SessionShim extends RefCounted:
	var adapter = null
	var suppressions := 0

	func execute_command(name: String, _args: Dictionary) -> Object:
		if name == "achievements.suppress":
			suppressions += 1
			var st = adapter.fst()
			for id in st._probe_ids:
				st._granted[id] = true
		return null


func _policy(mode: String):
	var a = FakeAdapter.new("ach")
	var s := SessionShim.new()
	s.adapter = a
	return [a, s, Achievements.new(s, a, mode)]


func test_presence_baseline() -> void:
	var t = _policy("presence")
	var a = t[0]
	var pol = t[2]
	a.fst()._granted = {"OLD": true}
	pol.before_join_load()
	# the loaded (host) state already meets RICH and PHASE_2
	a.fgs().total_money_gained = BigInt.from_int(5000)
	a.fgp().current_phase = 2
	pol.after_join_load()
	var g: Dictionary = a.fst()._granted
	assert_true(g.get("OLD", false), "previously granted kept")
	assert_true(g.get("RICH", false) and g.get("PHASE_2", false), "met-at-load marked granted (never fired)")
	assert_eq(a.fst().unlock_calls, [], "nothing granted for progress loaded on join")
	assert_false(g.get("FEEDER", false), "not met: still open")
	assert_false(g.get("PHASE_3", false), "phase 3 still open")
	# a real crossing after the join fires once
	a.fgs().total_products_consumed = 12
	a.fgs().stat_changed.emit("total_products_consumed", 12)
	a.fgs().stat_changed.emit("total_products_consumed", 13)
	assert_eq(a.fst().unlock_calls, ["FEEDER"], "the crossing fired once")
	pol.reset()
	assert_eq(a.fst()._granted, {"OLD": true}, "cache back to the pre-session state")
	a.free_all()


func test_none_mode() -> void:
	var t = _policy("none")
	var a = t[0]
	var pol = t[2]
	pol.before_join_load()
	pol.after_join_load()
	a.fgs().total_products_consumed = 50
	a.fgs().stat_changed.emit("total_products_consumed", 50)
	assert_eq(a.fst().unlock_calls, [], "none: everything stays suppressed")
	a.free_all()


func test_all_mode() -> void:
	var t = _policy("all")
	var s = t[1]
	var pol = t[2]
	pol.before_join_load()
	assert_eq(s.suppressions, 0, "all: single-player behaviour")
	t[0].free_all()


func test_join_suppresses_and_cheat_broadcast() -> void:
	await rig.cleanup()
	var h = rig.add_host({}, 1)
	await rig.until(func(): return h.session.get_state() == "in_game")
	var c = rig.add_client()
	await rig.until(func(): return c.session.get_state() == "in_game", 5.0)
	assert_true(c.api.suppress_calls >= 1, "the joiner suppressed before loading")
	var before: int = c.api.suppress_calls
	# a cheat succeeded on the host (event from PittAPI's command.executed)
	h.api.events.fire("command.executed", {"name": "t.cheat", "ok": true})
	assert_true(bool(h.session.rules.cheats), "host flags cheats")
	var ok: bool = await rig.until(func(): return c.api.suppress_calls > before, 2.0)
	assert_true(ok, "clients suppress for the rest of the session (R17)")
	assert_true(bool(c.session.rules.cheats), "rules.cheats replicated")
