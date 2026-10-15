extends "res://tests/test_case.gd"
## Unlock replay via force_unlock once per id (unknown skipped); UnlockManager
## detach / restore; hole feed -> host hole, client completion no-op (hole_ext);
## phase forward-only; phase 5 -> ending; hole state mirrored.

const MpRig = preload("res://tests/fakes/mp_net/mp_rig.gd")
const Progression = preload("res://gamedir/mods/PittMultiplayer/sync/progression.gd")
const FakeAdapter = preload("res://tests/fakes/mp_net/fake_game_adapter.gd")

var rig = null


func before_all() -> void:
	rig = MpRig.new(tree, runner)


func after_all() -> void:
	await rig.cleanup()


func _pair() -> Array:
	await rig.cleanup()
	var h = rig.add_host({}, 1)
	await rig.until(func(): return h.session.get_state() == "in_game")
	var c = rig.add_client()
	await rig.until(func(): return c.session.get_state() == "in_game", 5.0)
	return [h, c]


func test_unlock_replay_once() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	h.adapter.fum().force_unlock("unlock_fan")
	var ok: bool = await rig.until(func(): return "unlock_fan" in c.adapter.fum().unlocked_milestones, 3.0)
	assert_true(ok, "host unlock replayed on the client")
	assert_true(bool(c.adapter.fgs().tools.fan.enabled), "the game's action ran (tool visible)")
	assert_eq(c.adapter.fum().forced.count("unlock_fan"), 1, "force_unlock once")
	c.session.progression.client_on_unlock(["unlock_fan", "no_such_milestone"])
	assert_eq(c.adapter.fum().forced.count("unlock_fan"), 1, "already unlocked: not replayed")
	assert_eq(c.session.progression.skipped_unlocks, 1, "unknown id skipped")
	assert_true(c.adapter.ui_refreshes > 0, "terminal refreshed")


func test_client_judges_no_milestones() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	assert_true(c.adapter.unlock_manager_detached(), "detached")
	var checks_before: int = c.adapter.fum().checks
	h.adapter.fgs().add_money(5000)   # crosses unlock_luck's threshold (MP2: only the host earns)
	await rig.until(func(): return c.adapter.get_money() == h.adapter.get_money(), 3.0)
	await rig.ms(150)
	assert_eq(c.adapter.fum().checks, checks_before, "the client's UnlockManager never ran")
	var ok: bool = await rig.until(func(): return "unlock_luck" in h.adapter.fum().unlocked_milestones, 3.0)
	assert_true(ok, "the host judged it")
	ok = await rig.until(func(): return "unlock_luck" in c.adapter.fum().unlocked_milestones, 3.0)
	assert_true(ok, "and replicated it back")
	c.session.leave()
	assert_false(c.adapter.unlock_manager_detached(), "restored at teardown")
	var gs = c.adapter.fgs()
	assert_true(gs.stat_changed.is_connected(Callable(c.adapter.fum(), "_on_stat_changed")), "stat_changed reconnected")


func test_detach_restore_unit() -> void:
	var a = FakeAdapter.new("unit")
	var gs = a.fgs()
	var um = a.fum()
	assert_true(gs.stat_changed.is_connected(Callable(um, "_on_stat_changed")), "connected like the game")
	a.detach_unlock_manager()
	assert_false(gs.stat_changed.is_connected(Callable(um, "_on_stat_changed")), "stat_changed off")
	assert_false(a.fgp().phase_changed.is_connected(Callable(um, "_on_phase_changed")), "phase_changed off")
	assert_false(um.is_processing(), "process off")
	a.detach_unlock_manager()
	a.restore_unlock_manager()
	assert_true(gs.stat_changed.is_connected(Callable(um, "_on_stat_changed")), "back on")
	assert_true(a.fgp().phase_changed.is_connected(Callable(um, "_on_phase_changed")), "phase back on")
	a.restore_unlock_manager()
	a.free_all()


func test_phase_forward_only_and_ending() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	h.adapter.fgp().change_phase(3)
	var ok: bool = await rig.until(func(): return c.adapter.get_phase() == 3, 3.0)
	assert_true(ok, "phase replicated through the game's change_phase")
	assert_eq(c.session.progression.client_on_phase("begin", 2), -1, "never backwards")
	assert_eq(c.adapter.get_phase(), 3, "still 3")
	h.adapter.fgp().change_phase(5)
	ok = await rig.until(func(): return c.session.get_state() == "ending", 3.0)
	assert_true(ok, "phase 5 -> client state ending")


func test_hole_mirrored_and_client_completion_blocked() -> void:
	var pc = await _pair()
	var h = pc[0]
	var c = pc[1]
	h.adapter.hole().target_radius = 1.7
	h.adapter.hole().phase_nutrition_total = 555.0
	var ok: bool = await rig.until(func(): return is_equal_approx(c.adapter.hole().target_radius, 1.7), 3.0)
	assert_true(ok, "hole radius mirrored")
	assert_true(is_equal_approx(c.adapter.hole().phase_nutrition_total, 555.0), "nutrition mirrored")
	# hole_ext on a client: MP2 3.8 keeps the vanilla feeding path (only the
	# host's maw consumes, GAMEPLAY gates the client's); completion is a no-op
	var prev = Engine.get_meta("pitt_mp", null)
	Engine.set_meta("pitt_mp", c.session)
	var hole = c.adapter.hole()
	var fed_before: int = hole.fed.size()
	hole._on_product_consumed("duck", 5000, 3)
	assert_eq(hole.fed.size(), fed_before + 1, "client hole: vanilla path (nothing forwarded any more)")
	hole._check_phase_completion()
	hole._trigger_ending()
	assert_eq(hole.completions, 0, "client never completes a phase")
	assert_eq(hole.endings, 0, "client never triggers the ending")
	Engine.set_meta("pitt_mp", h.session)
	var hh = h.adapter.hole()
	hh._on_product_consumed("duck", 10, -1)
	assert_eq(hh.fed.size(), 1, "host hole: vanilla path")
	Engine.set_meta("pitt_mp", prev)
	await rig.ms(300)
	assert_eq(h.adapter.hole().fed.size(), 1, "nothing a client feeds locally reaches the host's hole (MP2 3.8)")
