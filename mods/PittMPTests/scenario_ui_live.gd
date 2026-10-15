extends "scenario_base.gd"
## Live UI scenario (role "ui_live"): the real game on the main menu, Steam
## transport. Opens every multiplayer screen programmatically, hosts a real
## friends-only Steam lobby, checks the lobby screen lists the local player and
## the Join screen's empty state, leaves, and screenshots each screen to
## <screens_dir>/live-*.png. Never enters a world, so no save is touched.

func _ui() -> Node:
	return mp.get("ui")


func _shot_live(name: String) -> void:
	var dir := String(flag.get("screens_dir", ""))
	if dir == "":
		return
	await RenderingServer.frame_post_draw
	var img := tree().root.get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(dir)
	var p := dir.path_join("live-%s.png" % name)
	var err := img.save_png(p)
	report.value("shot_" + name, p if err == OK else "error %d" % err)


## The member column sits inside the free area right of the menu column,
## centred both ways, and its rows use the enlarged pixel font.
func _check_members_layout(lp, tag: String) -> void:
	var root: Control = lp.members_root
	var col: Control = lp.get("_column")
	if root == null or col == null:
		report.check("members_layout_" + tag, false, "no column")
		return
	var rr := root.get_global_rect()
	var cr := col.get_global_rect()
	var name_fs := 0
	if not lp._member_rows.is_empty():
		var l = lp._member_rows[0].find_child("Name", true, false)
		if l is Label:
			name_fs = l.get_theme_font_size("font_size")
	report.value("members_layout_" + tag, {"free": [rr.position.x, rr.size.x, rr.size.y], "column": [cr.position.x, cr.position.y, cr.size.x, cr.size.y], "name_px": name_fs})
	var inside := cr.position.x >= rr.position.x - 1.0 and cr.end.x <= rr.end.x + 1.0
	var vcent := absf(cr.get_center().y - rr.get_center().y) <= 4.0
	var list_h: float = lp.members_list.size.y
	var rows_ok: bool = list_h >= lp.members_list.custom_minimum_size.y - 0.5 and list_h >= 40.0 		and (lp._member_rows.is_empty() or lp._member_rows[0].is_visible_in_tree())
	report.check("members_layout_" + tag, inside and vcent and rows_ok and name_fs >= 16,
		"free %s column %s list %.0f name %d px" % [str(rr), str(cr), list_h, name_fs])


func run() -> void:
	var ui := _ui()
	report.begin("1_main_menu")
	if not report.check("mp_ui_present", ui != null, ""):
		return
	var ok: bool = await wait_for(func(): return ui.router != null and ui.nodes.get("button") != null, 10.0)
	if not report.check("injected", ok, ""):
		return
	var menu: Node = ui.menu
	var buttons: Control = menu.get_node("Background/MenuButtons")
	var play: Control = menu.get_node("Background/MenuButtons/Play")
	var mpb: Button = ui.nodes.button
	report.check("button_directly_below_play", mpb.get_index() == play.get_index() + 1,
		"play %d mp %d" % [play.get_index(), mpb.get_index()])
	report.check("button_same_parent", mpb.get_parent() == buttons, "")
	report.check("button_same_theme_font", mpb.get_theme_font("font") == play.get_theme_font("font"), "")
	# Play's size when the label fits the 736 px column, else the largest size that fits
	var fit = mpb.get_node_or_null("MPFitWidth")
	var design_w: float = fit.column_width if fit != null else 736.0
	report.value("font_sizes", {"play": play.get_theme_font_size("font_size"), "mp": mpb.get_theme_font_size("font_size"),
		"column_design_w": design_w, "column_w": buttons.size.x, "mp_min_w": mpb.get_combined_minimum_size().x})
	report.check("button_font_size_play_or_fitted", mpb.get_theme_font_size("font_size") == play.get_theme_font_size("font_size")
		or (fit != null and mpb.get_theme_font_size("font_size") == fit.fitted_size and fit.fitted_size < play.get_theme_font_size("font_size")),
		"mp %d play %d" % [mpb.get_theme_font_size("font_size"), play.get_theme_font_size("font_size")])
	report.check("column_keeps_its_width", buttons.size.x <= design_w + 1.0 and mpb.get_combined_minimum_size().x <= design_w + 1.0,
		"column %.0f (design %.0f), mp min %.0f" % [buttons.size.x, design_w, mpb.get_combined_minimum_size().x])
	var play_cx: float = play.global_position.x + play.size.x * 0.5
	var col_cx: float = buttons.global_position.x + design_w * 0.5 * buttons.get_global_transform().get_scale().x
	report.check("play_centred_in_column", absf(play_cx - col_cx) <= 2.0, "play centre %.0f column centre %.0f" % [play_cx, col_cx])
	report.check("button_text", mpb.text == tr("MP_MULTIPLAYER") or mpb.text != "", mpb.text)
	report.check("button_visible", mpb.is_visible_in_tree(), "")
	report.check("button_below_play_on_screen", mpb.global_position.y > play.global_position.y,
		"play y %.0f mp y %.0f" % [play.global_position.y, mpb.global_position.y])
	report.check("button_enabled_steam_ok", not mpb.disabled, mpb.tooltip_text)
	report.check("lobby_kind_steam", String(lobby.kind()) == "steam", String(lobby.kind()))
	report.value("lobby_available", lobby.available())
	await sleep_ms(500)
	await _shot_live("01-main-menu")

	report.begin("2_host_join")
	mpb.pressed.emit()
	await sleep_ms(400)
	report.check("host_join_open", ui.router.top() == "MPHostJoin", ui.router.top())
	report.check("menu_buttons_hidden", not buttons.visible, "")
	await _shot_live("02-host-join")

	report.begin("3_join_empty")
	var hj = ui.nodes.panels.MPHostJoin
	hj.join_button.pressed.emit()
	await sleep_ms(300)
	report.check("join_open", ui.router.top() == "MPJoin", ui.router.top())
	report.check("scan_active", lobby.is_scan_active(), "")
	await sleep_ms(5000)
	var jp = ui.nodes.panels.MPJoin
	var rows: Array = jp.row_snapshot()
	report.value("join_rows", rows.map(func(r): return {"id": r.id, "name": r.name, "info": r.info}))
	report.check("join_empty_state", rows.is_empty() and jp.empty_row != null and jp.empty_row.visible,
		"%d rows; empty label '%s'" % [rows.size(), jp.empty_label.text if jp.empty_label else ""])
	await _shot_live("03-join-empty")
	jp.back_button.pressed.emit()
	await sleep_ms(300)
	report.check("join_back", ui.router.top() == "MPHostJoin", ui.router.top())
	report.check("scan_stopped", not lobby.is_scan_active(), "")

	report.begin("4_host_lobby")
	var entered: Array = []
	lobby.lobby_entered.connect(func(info): entered.append(info), CONNECT_ONE_SHOT)
	hj.host_button.pressed.emit()
	await sleep_ms(200)
	report.check("lobby_screen_open", ui.router.top() == "MPLobby", ui.router.top())
	await _shot_live("04a-lobby-creating")
	ok = await wait_for(func(): return not entered.is_empty(), 20.0)
	if not report.check("steam_lobby_created", ok, "pending %s" % lobby.is_pending()):
		return
	var info: Dictionary = lobby.current()
	report.value("lobby_info", info)
	report.check("is_owner", lobby.is_owner(), "")
	var steam = Engine.get_singleton("Steam") if Engine.has_singleton("Steam") else null
	var lid := int(str(info.get("id", "0")))
	if steam != null:
		report.check("steam_owner_is_me", int(steam.getLobbyOwner(lid)) == int(steam.getSteamID()),
			"%s vs %s" % [steam.getLobbyOwner(lid), steam.getSteamID()])
		report.check("steam_members_1", int(steam.getNumLobbyMembers(lid)) == 1, str(steam.getNumLobbyMembers(lid)))
		report.check("lobby_data_pitt_version", String(steam.getLobbyData(lid, "pitt_version")) == String(api.game_version),
			String(steam.getLobbyData(lid, "pitt_version")))
		var data := {}
		for k in ["host_name", "host_steam_id", "pitt_version", "pittapi_version", "mp_proto", "mods_hash", "state", "members", "max"]:
			data[k] = String(steam.getLobbyData(lid, k))
		report.value("steam_lobby_data", data)
		if steam.has_method("getLobbyMemberLimit"):
			report.check("lobby_member_limit_10", int(steam.getLobbyMemberLimit(lid)) == 10, str(steam.getLobbyMemberLimit(lid)))
		report.value("lobby_type_requested", "createLobby(LOBBY_TYPE_FRIENDS_ONLY=1, 10) in steam_lobby_service.gd")
	ok = await wait_for(func(): return session.get_state() == "lobby", 10.0)
	report.check("session_lobby", ok, "state %s" % session.get_state())
	report.value("transport_target", lobby.transport_target())
	await sleep_ms(800)
	var lp = ui.nodes.panels.MPLobby
	var members: Array = lp.member_snapshot()
	report.value("member_rows", members)
	var me := String(lobby.get_local_name())
	report.check("lobby_lists_local_player", members.size() == 1 and String(members[0].name).contains(me),
		"rows %s local '%s'" % [str(members), me])
	report.check("start_visible_for_host", lp.start_button.visible, "")
	report.check("invite_visible_for_host", lp.invite_button.visible, "")
	report.check("start_enabled", not lp.start_button.disabled, "")
	report.check("members_list_visible", lp.members_root.is_visible_in_tree(), "")
	_check_members_layout(lp, "native")
	await _shot_live("04-lobby-host")
	# the same lobby at 16:9, 4:3 and 21:9 (windowed), then the original mode back
	var mode := DisplayServer.window_get_mode()
	var wsize := DisplayServer.window_get_size()
	for pair in [["16x9", Vector2i(1600, 900)], ["4x3", Vector2i(1200, 900)], ["21x9", Vector2i(2520, 1080)]]:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(pair[1])
		await sleep_ms(900)
		report.value("window_" + String(pair[0]), [DisplayServer.window_get_size().x, DisplayServer.window_get_size().y])
		_check_members_layout(lp, String(pair[0]))
		await _shot_live("04-lobby-host-" + String(pair[0]))
	DisplayServer.window_set_mode(mode)
	if mode == DisplayServer.WINDOW_MODE_WINDOWED:
		DisplayServer.window_set_size(wsize)
	await sleep_ms(600)

	report.begin("5_leave")
	ui.leave_pressed()
	await sleep_ms(400)
	report.check("leave_confirm_dialog", ui.dialogs.is_open(), "")
	await _shot_live("05-leave-confirm")
	ui.dialogs.accept_last()
	ok = await wait_for(func(): return not lobby.is_in_lobby() and session.get_state() == "idle", 10.0)
	report.check("left_lobby", ok, "in_lobby %s state %s" % [lobby.is_in_lobby(), session.get_state()])
	await sleep_ms(500)
	report.check("back_on_host_join", ui.router.top() == "MPHostJoin", ui.router.top())
	if steam != null:
		# Steam keeps a stale member count for a lobby the user is no longer in,
		# so the member count is only recorded; the rich-presence join string
		# (cleared together with leaveLobby) is the check.
		await sleep_ms(2000)
		report.value("steam_members_after_leave", int(steam.getNumLobbyMembers(lid)))
		if steam.has_method("getFriendRichPresence"):
			var conn := String(steam.getFriendRichPresence(steam.getSteamID(), "connect"))
			report.check("presence_connect_cleared", conn == "", conn)
	await _shot_live("06-after-leave")
	hj.back_button.pressed.emit()
	await sleep_ms(400)
	report.check("back_to_main_menu", ui.router.top() == "" and buttons.visible, ui.router.top())
	await _shot_live("07-main-menu-again")
