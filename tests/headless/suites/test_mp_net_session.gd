extends "res://tests/test_case.gd"
## Session state machines over transport_loopback (host + clients in one
## process, each with its own FakeApi / StubLobby / FakeGameAdapter): start,
## late join, phase 0 / STARTING waits (R40), TRANSITION deferred (R4, R7),
## ENDING refused, leave, host_left via bye / transport / lobby_left (R8),
## abort during LOADING deferred (R23), teardown order and idempotence.

const MpRig = preload("res://tests/fakes/mp_net/mp_rig.gd")

var rig = null


func _new_rig() -> void:
	if rig != null:
		await rig.cleanup()
	rig = MpRig.new(tree, runner)


func after_all() -> void:
	if rig != null:
		await rig.cleanup()


func _in_game(p) -> Callable:
	return func(): return p.session.get_state() == "in_game"


func test_handshake_and_roster() -> void:
	await _new_rig()
	var h = rig.add_host()
	assert_eq(h.session.get_state(), "lobby", "host in lobby")
	assert_eq(h.session.get_role(), "host", "role host")
	assert_has(h.lobby.states, "waiting", "lobby state waiting")
	assert_eq(h.api.net.installs, 1, "MpAuthority installed on the host")
	assert_true(h.api.commands.authority.is_authority(), "host is the authority")
	assert_true(bool(h.session.can_start().ok), "can start")
	var c = rig.add_client("alice")
	assert_eq(c.session.get_state(), "lobby", "client in lobby")
	var ok: bool = await rig.until(func(): return c.session.sub == "waiting")
	assert_true(ok, "client handshaken (sub waiting), states: %s" % str(c.states))
	assert_eq(h.session.get_roster().size(), 2, "host roster has 2")
	assert_eq(c.session.get_roster().size(), 2, "client got the roster")
	assert_eq(int(c.session.get_roster()[1].slot), 2, "client is slot 2")
	assert_eq(String(c.session.get_roster()[1].name), "alice", "dev name from hello (no lobby member names)")
	assert_false(c.api.commands.authority.is_authority(), "client is not the authority")
	assert_true(c.api.commands.authority.local_peer_id() > 1, "client peer id from welcome")
	assert_false(bool(c.session.can_start().ok), "clients cannot start")


func test_start_and_join_one_path() -> void:
	await _new_rig()
	var h = rig.add_host()
	var c = rig.add_client("bob")
	await rig.until(func(): return c.session.sub == "waiting")
	assert_eq(h.session.start_game(), OK, "start")
	assert_eq(h.session.get_state(), "starting", "host starting")
	assert_has(h.lobby.states, "starting", "lobby starting")
	await rig.until(func(): return c.session.host_state == "starting")
	assert_eq(c.session.get_state(), "lobby", "client waits in the lobby while the host loads")
	h.session.notify_host_launch("res://scenes/world.tscn")
	assert_eq(h.session.get_state(), "loading", "host loading")
	h.adapter.fgs().set_money_int(4242)
	h.adapter.fum().force_unlock("unlock_luck")
	h.adapter.enter_world(1, runner)
	await rig.until(_in_game(h))
	assert_eq(h.session.get_state(), "in_game", "host OPEN -> in_game")
	assert_eq(h.session.host_state, "open", "host_state open")
	assert_has(h.lobby.states, "in_game", "lobby in_game (listed, joinable)")
	var ok: bool = await rig.until(_in_game(c), 5.0)
	assert_true(ok, "client joined through the late-join path: %s" % str(c.states))
	assert_has(c.states, "loading", "client passed through loading")
	assert_eq(c.adapter.launches.size(), 1, "the client world was launched once")
	assert_true(c.api.isolate_calls.size() >= 1 and bool(c.api.isolate_calls[0].enabled), "save.isolate on before the world load")
	assert_true(String(c.api.isolate_calls[0].path).ends_with(".save") and not String(c.api.isolate_calls[0].path).get_file().begins_with("savegame"),
		"isolation path is not slot-like (R14): %s" % c.api.isolate_calls[0].path)
	assert_eq(c.adapter.get_money(), "4242", "money from the snapshot")
	assert_has(c.adapter.fum().unlocked_milestones, "unlock_luck", "unlocks from the snapshot")
	assert_true(c.adapter.unlock_manager_detached(), "client UnlockManager detached")
	await rig.until(func(): return h.session.roster.state_of(c.session.my_peer) == "in_game")
	assert_eq(h.session.roster.state_of(c.session.my_peer), "in_game", "host marks the client in_game on ready")
	assert_true(h.api.hud.toasts.size() >= 1, "host toast on join")


func test_phase0_and_starting_wait() -> void:
	await _new_rig()
	var h = rig.add_host()
	var c = rig.add_client()
	await rig.until(func(): return c.session.sub == "waiting")
	h.session.start_game()
	h.session.notify_host_launch("res://scenes/world.tscn")
	h.adapter.enter_world(0, runner)   # elevator intro: phase 0, not exited
	h.adapter.fgp().elevator_exited = false
	await rig.ms(200)
	assert_ne(h.session.host_state, "open", "phase 0 is never served (R40)")
	assert_eq(c.session.get_state(), "lobby", "client still waiting")
	h.adapter.fgp().change_phase(1)
	h.adapter.fgp().elevator_exited = true
	var ok: bool = await rig.until(_in_game(c), 5.0)
	assert_true(ok, "joins after the elevator")
	assert_eq(c.adapter.get_phase(), 1, "joiner skipped the elevator (phase >= 1)")


func test_transition_defers_join() -> void:
	await _new_rig()
	var h = rig.add_host({}, -1)
	h.adapter.fgp().async_transitions = true
	rig.start_host_world(h, 1)
	await rig.until(_in_game(h))
	h.adapter.fgp().change_phase(2)    # transition begins (cinematic running)
	await rig.until(func(): return h.session.host_state == "transition")
	assert_eq(h.session.host_state, "transition", "host_state transition (R4/R7)")
	var c = rig.add_client()
	await rig.ms(300)
	assert_ne(c.session.get_state(), "in_game", "join waits during the transition")
	assert_eq(c.adapter.launches.size(), 0, "no snapshot during a transition")
	h.adapter.fgp().settle()
	var ok: bool = await rig.until(_in_game(c), 5.0)
	assert_true(ok, "served after the phase settled")
	assert_eq(c.adapter.get_phase(), 2, "joiner lands in phase 2")


func test_ending_refuses_and_ends() -> void:
	await _new_rig()
	var h = rig.add_host({}, 1)
	await rig.until(_in_game(h))
	var c = rig.add_client()
	await rig.until(_in_game(c), 5.0)
	h.adapter.fgp().change_phase(5)
	await rig.until(func(): return h.session.get_state() == "ending")
	assert_eq(h.session.get_state(), "ending", "host ending")
	assert_has(h.lobby.states, "ending", "lobby ending (not joinable)")
	var ok: bool = await rig.until(func(): return c.adapter.get_phase() == 5)
	assert_true(ok, "client runs its own ending (phase 5 replicated)")
	assert_eq(c.session.get_state(), "ending", "client state ending")
	var late = rig.add_client("late")
	await rig.until(func(): return not late.ended.is_empty(), 3.0)
	assert_true(not late.ended.is_empty() and late.ended[0][0] == "ending", "late joiner refused with ending: %s" % str(late.ended))
	# the host's world exits through the ending: the session ends silently
	h.adapter.leave_world()
	await rig.until(func(): return h.session.get_state() == "idle")
	assert_eq(h.ended.back()[0], "ending", "host ended with reason ending")
	await rig.until(func(): return c.session.get_state() == "idle", 3.0)
	assert_eq(c.ended.back()[0], "ending", "client ended with reason ending (bye ending)")


func test_reject_version_mods_full() -> void:
	await _new_rig()
	var h = rig.add_host({"max_players": 2})
	var bad = rig.make_peer("badmods", {"version": {"pitt_version": "1.0.8", "pittapi_version": "1.1.0", "mp_proto": 1, "mods_hash": "ffff"}})
	bad.lobby.enter({"is_owner": false}, {"kind": "loopback", "hub": rig.hub})
	var old = rig.make_peer("oldgame", {"version": {"pitt_version": "1.0.7", "pittapi_version": "1.1.0", "mp_proto": 1, "mods_hash": "abcd1234abcd1234"}})
	old.lobby.enter({"is_owner": false}, {"kind": "loopback", "hub": rig.hub})
	await rig.until(func(): return not bad.ended.is_empty() and not old.ended.is_empty(), 3.0)
	assert_true(not bad.ended.is_empty() and bad.ended[0][0] == "mods", "mods mismatch rejected: %s" % str(bad.ended))
	assert_true(not old.ended.is_empty() and old.ended[0][0] == "version", "version mismatch rejected: %s" % str(old.ended))
	assert_eq(bad.session.get_state(), "idle", "rejected client idle")
	assert_true(bad.lobby.leaves >= 1, "rejected client left the lobby")
	var c1 = rig.add_client("one")
	await rig.until(func(): return c1.session.sub == "waiting")
	var c2 = rig.add_client("two")
	await rig.until(func(): return not c2.ended.is_empty(), 3.0)
	assert_true(not c2.ended.is_empty() and c2.ended[0][0] == "full", "full lobby rejected: %s" % str(c2.ended))
	assert_eq(h.session.get_roster().size(), 2, "roster unchanged")


func test_client_leave() -> void:
	await _new_rig()
	var h = rig.add_host({}, 1)
	await rig.until(_in_game(h))
	var c = rig.add_client("carol")
	await rig.until(_in_game(c), 5.0)
	var file: String = c.api.isolate_path
	assert_true(file != "" and FileAccess.file_exists(file), "session file exists while in game")
	c.session.leave()
	assert_eq(c.session.get_state(), "idle", "client idle at once")
	assert_eq(c.ended.back()[0], "left", "ended(left)")
	# isolation outlives the session until the host's world copy is gone
	assert_true(c.api.isolated, "isolation still on while the world exits")
	assert_true(c.session.save_hold_active(), "save hold active")
	var released: bool = await rig.until(func(): return not c.api.isolated, 3.0)
	assert_true(released, "isolation off once the client is back on the main menu")
	assert_false(FileAccess.file_exists(file), "session file deleted")
	assert_true(c.lobby.leaves >= 1, "lobby.leave() called")
	assert_eq(c.api.net.uninstalls, 1, "LocalAuthority back")
	assert_false(c.adapter.unlock_manager_detached(), "UnlockManager restored")
	assert_eq(c.adapter.returns_to_menu, 1, "client in a world goes back to the main menu")
	var ok: bool = await rig.until(func(): return h.session.get_roster().size() == 1)
	assert_true(ok, "host roster drops the client")
	assert_true(h.api.hud.toasts.size() >= 2 and String(h.api.hud.toasts.back()).contains("carol"), "host toast MP_PEER_LEFT: %s" % str(h.api.hud.toasts))
	assert_eq(h.session.get_state(), "in_game", "host keeps playing")


func test_host_leave_ends_for_clients() -> void:
	await _new_rig()
	var h = rig.add_host({}, 1)
	await rig.until(_in_game(h))
	var c = rig.add_client()
	await rig.until(_in_game(c), 5.0)
	h.session.leave()
	assert_eq(h.session.get_state(), "idle", "host idle")
	assert_eq(h.ended.back()[0], "left", "host ended(left)")
	var ok: bool = await rig.until(func(): return c.session.get_state() == "idle", 3.0)
	assert_true(ok, "client torn down")
	assert_eq(c.ended.back()[0], "host_left", "client reason host_left (bye)")
	assert_eq(c.adapter.returns_to_menu, 1, "client back to the main menu")
	var last: Dictionary = c.session.consume_last_end()
	assert_eq(String(last.get("reason", "")), "host_left", "consume_last_end for the main-menu dialog")
	assert_true(c.session.consume_last_end().is_empty(), "consumed once")


func test_host_world_exit_ends_session() -> void:
	await _new_rig()
	var h = rig.add_host({}, 1)
	await rig.until(_in_game(h))
	var c = rig.add_client()
	await rig.until(_in_game(c), 5.0)
	h.adapter.leave_world()      # pause > Main Menu on the host (D7)
	await rig.until(func(): return c.session.get_state() == "idle", 3.0)
	assert_eq(h.session.get_state(), "idle", "host session ended with its world")
	assert_true(h.lobby.leaves >= 1, "host lobby closed")
	assert_eq(c.ended.back()[0], "host_left", "clients: host_left")


func test_lobby_owner_change_is_host_left() -> void:
	await _new_rig()
	var h = rig.add_host()
	var c = rig.add_client()
	await rig.until(func(): return c.session.sub == "waiting")
	c.lobby.drop("host_left")     # Steam migrated ownership / the owner left (R8)
	assert_eq(c.session.get_state(), "idle", "client idle")
	assert_eq(c.ended.back()[0], "host_left", "reason host_left")


func test_connection_lost() -> void:
	await _new_rig()
	var h = rig.add_host({}, 1)
	await rig.until(_in_game(h))
	var c = rig.add_client()
	await rig.until(_in_game(c), 5.0)
	# the host vanishes without a bye (crash / Alt-F4)
	c.session.transport._events.append({"at": 0, "kind": "host_gone"})
	await rig.until(func(): return c.session.get_state() == "idle", 3.0)
	assert_eq(c.ended.back()[0], "connection_lost", "connection_lost")
	assert_eq(c.adapter.returns_to_menu, 1, "back to the main menu")


func test_abort_during_loading_waits_for_safe_point() -> void:
	await _new_rig()
	var h = rig.add_host({}, 1)
	await rig.until(_in_game(h))
	var c = rig.make_peer("slow")
	c.adapter.load_delay_frames = 40
	c.lobby.enter({"is_owner": false}, {"kind": "loopback", "hub": rig.hub})
	await rig.until(func(): return c.adapter.launches.size() == 1, 5.0)
	assert_eq(c.session.get_state(), "loading", "world launched, loading")
	h.session.leave()
	await rig.frames(5)
	assert_eq(c.session.get_state(), "loading", "abort deferred while the world loads (R23)")
	assert_eq(c.adapter.returns_to_menu, 0, "no menu return mid-load")
	var ok: bool = await rig.until(func(): return c.session.get_state() == "idle", 5.0)
	assert_true(ok, "aborted at the safe point")
	assert_eq(c.ended.back()[0], "host_left", "reason kept")
	assert_eq(c.adapter.returns_to_menu, 1, "then back to the main menu")


func test_teardown_idempotent() -> void:
	await _new_rig()
	var h = rig.add_host({}, 1)
	await rig.until(_in_game(h))
	var c = rig.add_client()
	await rig.until(_in_game(c), 5.0)
	c.session.leave()
	c.session.leave()
	c.session.leave("error")
	assert_eq(c.ended.size(), 1, "ended fires once")
	assert_eq(c.api.net.uninstalls, 1, "uninstall once")
	assert_eq(c.api.net.ended_reasons.size(), 1, "session_ended once")
	assert_false(c.session.is_live(), "not live")
	h.session.leave()
	h.session.leave()
	assert_eq(h.ended.size(), 1, "host ended once")


func test_cancel_start() -> void:
	await _new_rig()
	var h = rig.add_host()
	h.session.start_game()
	h.session.cancel_start()
	assert_eq(h.session.get_state(), "lobby", "back to lobby")
	assert_eq(h.lobby.states.back(), "waiting", "lobby waiting again")
	assert_true(bool(h.session.can_start().ok), "can start again")
	assert_eq(h.session.start_game(), OK, "start again")
	assert_ne(h.session.start_game(), OK, "start twice refused")
