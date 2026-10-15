extends "res://tests/test_case.gd"
## Lobby and Join screens against FakeLobbyService + FakeSession: member redraw,
## friend list via events, missed events recovered by Refresh / the 10 s scan
## (only while visible), disabled mismatch / full rows, empty state,
## join_requested on the menu / in a lobby / in a world (R34), session.leave()
## on every exit path and never lobby.leave() from the UI (R35), end dialogs.

const Harness = preload("res://tests/fakes/mp_ui/ui_harness.gd")

var h = null


func _open(setup: Callable = Callable()) -> void:
	h = Harness.new(core, runner, tree)
	await h.open("fake", setup)


func _close() -> void:
	if h != null:
		h.close()
	h = null
	await wait_frames(1)


func _host() -> void:
	h.press(h.button("MenuButtons/MPMultiplayer"))
	h.press(h.panel("MPHostJoin").host_button)
	await wait_frames(1)


func _row(id: String, extra: Dictionary = {}) -> Dictionary:
	var d := {"id": id, "host_name": "Friend " + id, "members": 2, "max": 10, "state": "waiting"}
	for k in extra:
		d[k] = extra[k]
	return d


func test_host_lobby_members() -> void:
	await _open()
	var lp = h.panel("MPLobby")
	h.press(h.button("MenuButtons/MPMultiplayer"))
	h.press(h.panel("MPHostJoin").host_button)
	assert_eq(lp.status_label.text, "Creating lobby...", "status while creating")
	assert_true(lp.start_button.visible and lp.start_button.disabled, "Start shown but disabled while creating")
	await wait_frames(1)
	assert_true(h.lobby.is_owner(), "host")
	assert_eq(lp.status_label.text, "Press Start when everyone is here", "host ready status")
	assert_true(lp.start_button.visible and lp.invite_button.visible, "host buttons")
	assert_true(h.panel("MPLobbyMembers").visible, "centred member list shown with the panel")
	var rows: Array = lp.member_snapshot()
	assert_eq(rows.size(), 1, "one member")
	assert_eq(rows[0].name, "Player 1", "own name")
	assert_true(rows[0].info.contains("Host") and rows[0].info.contains("You"), "host + you tags")
	assert_eq(lp.members_title.text, "Players 1/10", "count")
	h.lobby.set_remote_members([
		{"id": "a", "name": "Player 1", "is_owner": true, "is_self": true},
		{"id": "b", "name": "Bob", "is_owner": false, "is_self": false},
		{"id": "c", "name": "Cy", "is_owner": false, "is_self": false}])
	rows = lp.member_snapshot()
	assert_eq(rows.size(), 3, "redraw on members_changed")
	assert_eq(rows[1].name, "Bob", "order kept")
	assert_eq(lp.members_title.text, "Players 3/10", "count updated")
	h.session.set_roster([{"peer": 2, "slot": 2, "name": "Bob", "platform_id": "b", "state": "loading", "is_host": false}])
	rows = lp.member_snapshot()
	assert_eq(rows[1].info, "Loading", "roster status suffix")
	h.press(lp.invite_button)
	assert_eq(h.lobby.called("invite_friends"), 1, "invite")
	h.session.set_start(false, "MP_START_NOT_READY")
	assert_true(lp.start_button.disabled, "Start follows start_availability_changed")
	assert_eq(lp.status_label.text, "The session is not ready yet", "reason shown")
	h.session.set_start(true, "")
	assert_false(lp.start_button.disabled, "Start enabled again")
	await _close()


func test_client_join_from_list() -> void:
	await _open()
	h.lobby.world = {"111": _row("111"), "222": _row("222", {"pitt_version": "0.9"}),
		"333": _row("333", {"members": 10}), "444": _row("444", {"mods_hash": "zzz"}),
		"555": _row("555", {"state": "in_game"})}
	h.press(h.button("MenuButtons/MPMultiplayer"))
	h.press(h.panel("MPHostJoin").join_button)
	var jp = h.panel("MPJoin")
	assert_true(h.lobby.is_scan_active(), "scan active while the Join panel is visible")
	assert_true(h.lobby.refresh_count >= 1, "initial fill on show")
	var snap: Array = jp.row_snapshot()
	assert_eq(snap.size(), 5, "five rows")
	var by_id := {}
	for r in snap:
		by_id[r.id] = r
	assert_false(by_id["111"].disabled, "matching lobby enabled")
	assert_eq(by_id["111"].info, "2/10 players | Waiting", "row info")
	assert_true(by_id["222"].disabled, "version mismatch disabled")
	assert_eq(by_id["222"].info, "Different game or PittAPI version", "reason shown")
	assert_true(by_id["333"].disabled, "full disabled")
	assert_eq(by_id["333"].info, "The lobby is full", "full reason")
	assert_true(by_id["444"].disabled, "mods mismatch disabled")
	assert_false(by_id["555"].disabled, "in-game lobby joinable (late join)")
	assert_eq(by_id["555"].info, "2/10 players | In game", "in game state")
	assert_false(jp.empty_row.visible, "no empty state")
	h.press(by_id["111"].node)
	assert_eq(h.lobby.called("join"), 1, "join called")
	assert_eq(h.top(), "MPLobby", "lobby panel")
	assert_false(h.lobby.is_scan_active(), "scan stops when the Join panel hides")
	var lp = h.panel("MPLobby")
	assert_eq(lp.status_label.text, "Joining lobby...", "joining status")
	assert_false(lp.start_button.visible, "no Start for clients")
	await wait_frames(1)
	assert_true(h.lobby.is_in_lobby() and not h.lobby.is_owner(), "joined as member")
	assert_eq(lp.status_label.text, "Connecting to the host...", "connecting")
	h.session.set_state("lobby", {"role": "client", "sub": "waiting", "host_state": "lobby"})
	assert_eq(lp.status_label.text, "Waiting for the host to start", "waiting")
	h.session.set_state("lobby", {"role": "client", "sub": "waiting", "host_state": "starting"})
	assert_eq(lp.status_label.text, "The host is loading the world...", "host loading")
	h.session.set_state("loading", {"role": "client", "sub": "", "host_state": "open"})
	assert_eq(lp.status_label.text, "Joining the game...", "joining")
	assert_eq(lp.member_snapshot().size(), 2, "host + me")
	await _close()


func test_events_and_fallback_scan() -> void:
	await _open()
	h.press(h.button("MenuButtons/MPMultiplayer"))
	h.press(h.panel("MPHostJoin").join_button)
	var jp = h.panel("MPJoin")
	assert_true(jp.empty_row.visible, "empty state")
	assert_eq(jp.empty_label.text, "MP_NO_FRIENDS_HOSTING", "empty-state key")
	h.lobby.publish(_row("900"))
	assert_eq(jp.row_snapshot().size(), 1, "event path adds the row without Refresh")
	assert_false(jp.empty_row.visible, "empty state hidden")
	h.lobby.publish_silent(_row("901"))
	assert_eq(jp.row_snapshot().size(), 1, "missed event: not shown yet")
	h.press(jp.refresh_button)
	assert_eq(jp.row_snapshot().size(), 2, "Refresh recovers it")
	h.lobby.unpublish("900", true)
	h.lobby.scan_interval_s = 0.05
	h.lobby.set_scan_active(false)
	h.lobby.set_scan_active(true)
	var before: int = h.lobby.refresh_count
	await tree.create_timer(0.15).timeout
	assert_true(h.lobby.refresh_count > before, "fallback scan runs while visible")
	assert_eq(jp.row_snapshot().size(), 1, "scan dropped the vanished lobby")
	h.press(jp.back_button)
	assert_false(h.lobby.is_scan_active(), "hidden: scan off")
	var after: int = h.lobby.refresh_count
	await tree.create_timer(0.15).timeout
	assert_eq(h.lobby.refresh_count, after, "no scan while hidden")
	await _close()


func test_leave_paths_use_session() -> void:
	await _open()
	await _host()
	var lp = h.panel("MPLobby")
	h.press(lp.leave_button)
	var d: Dictionary = h.ui.dialogs.last()
	assert_eq(d.get("title", ""), "MP_CONFIRM_LEAVE_TITLE", "Leave asks first")
	assert_eq(d.get("body", ""), "MP_CONFIRM_CLOSE_LOBBY_BODY", "host body")
	assert_eq(h.session.called("leave"), 0, "nothing left before confirming")
	h.ui.dialogs.accept_last()
	assert_eq(h.session.called("leave"), 1, "session.leave()")
	assert_eq(h.lobby.called("leave"), 1, "lobby left through the session")
	assert_false(h.lobby.is_in_lobby(), "out")
	assert_eq(h.top(), "MPHostJoin", "back to Host/Join")
	# Esc in the lobby = Leave (confirm)
	h.press(h.panel("MPHostJoin").host_button)
	await wait_frames(1)
	h.esc()
	await wait_frames(1)
	assert_eq(h.ui.dialogs.last().get("title", ""), "MP_CONFIRM_LEAVE_TITLE", "Esc asks to leave")
	assert_eq(h.top(), "MPLobby", "still in the lobby until confirmed")
	h.ui.dialogs.accept_last()
	assert_eq(h.session.called("leave"), 2, "session.leave() again")
	# leaving while the lobby is still being created
	h.press(h.panel("MPHostJoin").host_button)
	h.press(h.panel("MPLobby").leave_button)
	h.ui.dialogs.accept_last()
	assert_eq(h.session.called("leave"), 3, "leave while creating")
	await wait_frames(1)
	assert_false(h.lobby.is_in_lobby(), "the deferred create was dropped")
	assert_eq(h.top(), "MPHostJoin", "popped")
	assert_eq(h.lobby.called("leave"), h.session.called("leave"), "the UI never calls lobby.leave() itself")
	await _close()


func test_host_left_single_dialog() -> void:
	await _open()
	h.lobby.world = {"7": _row("7")}
	h.press(h.button("MenuButtons/MPMultiplayer"))
	h.press(h.panel("MPHostJoin").join_button)
	h.ui.join_lobby("7")
	await wait_frames(1)
	h.session.set_state("lobby", {"role": "client", "sub": "waiting", "host_state": "lobby"})
	var n0: int = h.ui.dialogs.history.size()
	h.lobby.drop("host_left")
	await wait_frames(2)
	assert_eq(h.top(), "MPJoin", "lobby panel popped back to the list")
	assert_eq(h.ui.dialogs.history.size() - n0, 1, "one dialog")
	var d: Dictionary = h.ui.dialogs.last()
	assert_eq(d.get("title", ""), "MP_END_TITLE", "end title")
	assert_true(String(d.get("body", "")).begins_with("The host ended the session"), "host_left text")
	assert_eq(h.session.consume_last_end(), {}, "consumed so the next menu does not repeat it")
	await _close()


func test_join_failure_dialog() -> void:
	await _open(func(l):
		l.join_result = "join_failed"
		l.join_error = "MP_ERR_FULL")
	h.press(h.button("MenuButtons/MPMultiplayer"))
	h.press(h.panel("MPHostJoin").join_button)
	var n0: int = h.ui.dialogs.history.size()
	h.ui.join_lobby("42")
	await wait_frames(2)
	assert_eq(h.top(), "MPJoin", "back to the list")
	assert_eq(h.ui.dialogs.history.size() - n0, 1, "one dialog (error, no duplicate lobby_left one)")
	assert_eq(h.ui.dialogs.last().get("body", ""), "MP_ERR_FULL", "full")
	await _close()


func test_end_dialog_on_menu_reinstance() -> void:
	await _open()
	h.session.last_end = {"reason": "connection_lost", "detail": ""}
	h.new_menu()
	await wait_frames(1)
	var d: Dictionary = h.ui.dialogs.last()
	assert_true(String(d.get("body", "")).begins_with("Connection to the host was lost"), "dialog after re-instance")
	assert_eq(h.session.last_end, {}, "consumed")
	var n: int = h.ui.dialogs.history.size()
	h.session.last_end = {"reason": "left", "detail": ""}
	h.new_menu()
	await wait_frames(1)
	assert_eq(h.ui.dialogs.history.size(), n, "no dialog for a plain leave")
	await _close()


func test_no_ghost_lobby_on_menu() -> void:
	await _open()
	await _host()
	h.session.state = "idle"   # session gone, lobby still open (must not happen)
	h.new_menu()
	await wait_frames(1)
	assert_true(h.session.called("leave") >= 1, "session.leave() on menu injection")
	assert_false(h.lobby.is_in_lobby(), "no ghost lobby")
	await _close()


func test_join_requested_routing() -> void:
	await _open()
	# on the menu, not in a session -> join straight away
	h.lobby.request_join("500")
	assert_eq(h.lobby.called("join"), 1, "joined")
	assert_eq(h.top(), "MPLobby", "lobby panel")
	assert_true(h.ui.router.has("MPHostJoin"), "Host/Join below it")
	await wait_frames(1)
	h.session.set_state("lobby", {"role": "client", "sub": "waiting", "host_state": "lobby"})
	# in a lobby -> confirm, then leave + join
	h.lobby.request_join("600")
	assert_eq(h.ui.dialogs.last().get("title", ""), "MP_CONFIRM_SWITCH_TITLE", "confirm switch")
	assert_eq(h.lobby.called("join"), 1, "not yet")
	h.ui.dialogs.accept_last()
	assert_eq(h.session.called("leave"), 1, "left via the session")
	await wait_frames(2)
	assert_eq(h.lobby.called("join"), 2, "joined the new lobby")
	assert_eq(h.lobby.calls[-1], ["join", ["600"]], "the requested id")
	await wait_frames(1)
	# same lobby again -> just show it
	h.lobby.request_join("600")
	assert_eq(h.lobby.called("join"), 2, "no rejoin of the current lobby")
	# in a world (loading / in_game) -> queued + toast, confirmed on the next menu
	h.session.set_state("in_game", {"role": "client", "sub": "", "host_state": "open"})
	h.lobby.request_join("700")
	assert_eq(h.ui.pending_join_id, "700", "queued")
	assert_has(h.api.toasts, "Return to the main menu to join your friend's game", "toast")
	h.session.leave("left")
	h.menu.queue_free()
	await wait_frames(1)
	h.new_menu()
	await wait_frames(2)
	assert_eq(h.ui.dialogs.last().get("title", ""), "MP_JOIN_PENDING_TITLE", "offered on the next menu")
	h.ui.dialogs.accept_last()
	assert_eq(h.lobby.calls.filter(func(c): return c[0] == "join").back(), ["join", ["700"]], "joined after confirm")
	await _close()


func test_launch_arg_join() -> void:
	await _open(func(l): l.launch_join = "123456")
	await wait_frames(2)
	assert_eq(h.lobby.called("join"), 1, "+connect_lobby joins on the first menu")
	assert_eq(h.lobby.calls.filter(func(c): return c[0] == "join")[0], ["join", ["123456"]], "id")
	h.new_menu()
	await wait_frames(2)
	assert_eq(h.lobby.called("join"), 1, "only once")
	await _close()


func test_launch_arg_join_waits_for_steam() -> void:
	# Steamworks not initialised yet at the first menu: the join is kept, not lost
	await _open(func(l):
		l.launch_join = "424242"
		l.avail = {"ok": false, "reason": "MP_ERR_NO_STEAM"})
	await wait_frames(2)
	assert_eq(h.lobby.called("join"), 0, "not joined while Steam is unavailable")
	assert_eq(h.ui.dialogs.last().get("body", "") if h.ui.dialogs.last() != null else "", "", "no error dialog yet")
	h.lobby.avail = {"ok": true, "reason": ""}
	var t0 := Time.get_ticks_msec()
	while h.lobby.called("join") == 0 and Time.get_ticks_msec() - t0 < 3000:
		await wait_frames(1)
	assert_eq(h.lobby.called("join"), 1, "joined once Steam is up")
	assert_eq(h.lobby.calls.filter(func(c): return c[0] == "join")[0], ["join", ["424242"]], "id")
	await _close()


func test_start_failure() -> void:
	await _open()
	await _host()
	h.session.start_result = ERR_BUSY
	h.press(h.panel("MPLobby").start_button)
	assert_false(h.ui.is_host_picking(), "no picker")
	assert_eq(h.ui.dialogs.last().get("body", ""), "MP_ERR_START_FAILED", "error dialog")
	await _close()


func test_dev_lobby_service() -> void:
	var factory = load(String(core.mods_dir).path_join("PittMultiplayer/lobby/lobby_factory.gd"))
	var dev: Node = factory.make("dev")
	runner.add_child(dev)
	dev.setup(null, Harness.VERSION, {"dev_targets": ["127.0.0.1:27450", "10.0.0.2:30000", "bad"], "dev_name": "Dev A"})
	var entered: Array = []
	dev.lobby_entered.connect(func(i): entered.append(i))
	dev.refresh_friend_lobbies()
	var rows: Array = dev.friend_lobbies()
	assert_eq(rows.size(), 2, "one row per valid target")
	assert_eq(rows[0].id, "dev:10.0.0.2:30000" if rows[0].host_name.begins_with("10.") else "dev:127.0.0.1:27450", "ids")
	dev.host()
	assert_eq(dev.transport_target(), {}, "not entered yet (deferred)")
	await wait_frames(1)
	assert_eq(entered.size(), 1, "entered once")
	assert_eq(dev.transport_target(), {"kind": "enet", "role": "host", "address": "127.0.0.1", "port": 27450}, "host target")
	assert_eq(dev.current().id, "dev:127.0.0.1:27450", "lobby id")
	assert_eq(dev.get_local_name(), "Dev A", "name")
	dev.set_external_members([{"id": "enet:1", "name": "Dev A", "is_owner": true, "is_self": true},
		{"id": "enet:2", "name": "Dev B", "is_owner": false, "is_self": false}])
	assert_eq(dev.get_members().size(), 2, "external members")
	assert_eq(dev.current().members, 2, "count")
	dev.set_state("ending")
	assert_false(dev.current().joinable, "ending not joinable")
	dev.leave()
	assert_eq(dev.current(), {}, "left")
	dev.join("dev:10.0.0.2:30000")
	await wait_frames(1)
	assert_eq(dev.transport_target(), {"kind": "enet", "role": "client", "address": "10.0.0.2", "port": 30000}, "client target")
	dev.leave()
	var left: Array = []
	dev.lobby_left.connect(func(r): left.append(r))
	dev.join("dev:nope")
	await wait_frames(1)
	assert_eq(left, ["join_failed"], "malformed id fails")
	assert_eq(dev.parse_id("dev:::1:8080"), {"address": "::1", "port": 8080}, "IPv6 address")
	dev.queue_free()


## Owner polish: the member list is larger, vertically centred in the free area
## right of the menu column, and scales with that area's width (keep_height
## stretch: 4:3 / 16:9 / 21:9 = about 400 / 830 / 1410 virtual px free).
func test_member_list_layout_responsive() -> void:
	await _open()
	var lp = h.panel("MPLobby")
	await _host()
	h.lobby.set_remote_members([
		{"id": "a", "name": "Player 1", "is_owner": true, "is_self": true},
		{"id": "b", "name": "Bob", "is_owner": false, "is_self": false}])
	var root: Control = lp.members_root
	var sizes := {}
	for w in [400.0, 830.0, 1410.0]:
		root.size = Vector2(w, 960)
		lp._fit_column()
		await wait_frames(2)
		var col: Control = lp._column
		var col_rect := Rect2(col.global_position - root.global_position, col.size)
		assert_true(col_rect.position.x >= -0.5 and col_rect.end.x <= w + 0.5, "column inside the free area at %d: %s" % [w, str(col_rect)])
		assert_true(absf(col_rect.get_center().y - 480.0) <= 2.0, "vertically centred at %d: centre %.1f" % [w, col_rect.get_center().y])
		assert_true(absf(col_rect.get_center().x - w * 0.5) <= 2.0, "horizontally centred at %d" % w)
		var name_l: Label = lp._member_rows[0].find_child("Name", true, false)
		var fs := name_l.get_theme_font_size("font_size")
		assert_eq(fs % 8, 0, "pixel font on a multiple of 8 (%d)" % fs)
		assert_true(lp.members_list.custom_minimum_size.y >= 2 * 44.0, "list as tall as its two rows")
		assert_true(lp.members_list.size.y >= lp.members_list.custom_minimum_size.y - 0.5,
			"list laid out at its rows' height (%.0f / %.0f)" % [lp.members_list.size.y, lp.members_list.custom_minimum_size.y])
		assert_true(col.size.y >= lp.members_list.custom_minimum_size.y + 40.0, "column holds the title and the rows (%.0f)" % col.size.y)
		sizes[w] = fs
	assert_true(sizes[400.0] < sizes[830.0] and sizes[830.0] < sizes[1410.0], "scales with the free width: %s" % str(sizes))
	assert_true(sizes[830.0] >= 32, "16:9 names at 32 px (were the theme's small size)")
	await _close()
