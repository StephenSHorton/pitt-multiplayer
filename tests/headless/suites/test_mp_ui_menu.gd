extends "res://tests/test_case.gd"
## Main-menu injection against a stub MainMenu with the real node paths:
## the Multiplayer button is a Play duplicate right after Play without Play's
## _on_play_pressed connection (R27), injection is idempotent and re-runs on a
## new menu instance, panels swap like MenuLoad, Esc is handled before MainMenu
## (R28), and the host-picking overrides of main_menu_ext (R41).

const Harness = preload("res://tests/fakes/mp_ui/ui_harness.gd")

var h = null


func _open() -> void:
	h = Harness.new(core, runner, tree)
	await h.open()


func _close() -> void:
	if h != null:
		h.close()
	h = null
	await wait_frames(1)


func test_button_is_play_duplicate() -> void:
	await _open()
	var buttons: Control = h.menu.get_node("Background/MenuButtons")
	var play: Button = buttons.get_node("Play")
	var mp: Button = buttons.get_node_or_null("MPMultiplayer")
	if assert_true(mp != null, "button injected"):
		assert_eq(mp.get_index(), play.get_index() + 1, "right after Play")
		assert_eq(mp.text, "MP_MULTIPLAYER", "translation key")
		assert_eq(mp.get_theme_font_size("font_size"), play.get_theme_font_size("font_size"), "Play's font size")
		assert_eq(mp.get_meta("base_font_size", -1), play.get_meta("base_font_size", -2), "scale base kept")
		var to_play := false
		for c in mp.pressed.get_connections():
			if c.callable.get_method() == "_on_play_pressed":
				to_play = true
		assert_false(to_play, "no copied _on_play_pressed connection")
		var hovers := 0
		for c in mp.mouse_entered.get_connections():
			if c.callable.get_method() == "_on_mouse_entered":
				hovers += 1
		assert_eq(hovers, 1, "hover sound wired once")
		h.press(mp)
		assert_false("play" in h.menu.log, "Play's handler did not run")
		assert_eq(h.top(), "MPHostJoin", "Host/Join opened")
		assert_false(buttons.visible, "MenuButtons hidden")
		assert_true(h.panel("MPHostJoin").visible, "panel visible")
		assert_true(h.menu.ignore_input, "_temporarily_ignore_input like the game")
		assert_true(h.menu.sounds >= 1, "click sound")
	await _close()


func test_label_fits_the_menu_column() -> void:
	await _open()
	var buttons: Control = h.menu.get_node("Background/MenuButtons")
	var play: Button = buttons.get_node("Play")
	var mp: Button = buttons.get_node_or_null("MPMultiplayer")
	var fit = mp.get_node_or_null("MPFitWidth") if mp != null else null
	if assert_true(fit != null, "width fitter attached"):
		var want: int = play.get_theme_font_size("font_size")
		fit.column_width = 120.0          # a column narrower than the label
		var size: int = fit.fit()
		assert_true(size < want, "smaller font when the label does not fit (%d < %d)" % [size, want])
		assert_true(mp.get_combined_minimum_size().x <= 121.0, "button no wider than the column: %s" % str(mp.get_combined_minimum_size()))
		fit.column_width = 100000.0
		assert_eq(fit.fit(), want, "Play's size whenever it fits")
		assert_eq(mp.get_meta("base_font_size", -1), play.get_meta("base_font_size", -2), "scale base untouched")
	await _close()


func test_injection_idempotent_and_reinjected() -> void:
	await _open()
	assert_true(h.ui.inject(h.menu), "second inject ok")
	var count := 0
	for c in h.menu.get_node("Background/MenuButtons").get_children():
		if c.name.begins_with("MPMultiplayer"):
			count += 1
	assert_eq(count, 1, "one button after re-inject")
	var panels := 0
	for c in h.menu.get_node("Background").get_children():
		if String(c.name).begins_with("MPHostJoin"):
			panels += 1
	assert_eq(panels, 1, "one panel after re-inject")
	var old_menu: Node = h.menu
	h.new_menu()
	await wait_frames(1)
	assert_false(is_instance_valid(old_menu) and old_menu.is_inside_tree(), "old menu gone")
	assert_true(h.menu.get_node_or_null("Background/MenuButtons/MPMultiplayer") != null, "new menu injected")
	assert_eq(h.ui.menu, h.menu, "ui follows the new menu")
	await _close()


func test_panels_laid_out_like_menu_load() -> void:
	await _open()
	var load_panel: Control = h.menu.get_node("Background/MenuLoad")
	var new_btn: Button = load_panel.get_node("New")
	for p in ["MPHostJoin", "MPLobby", "MPJoin"]:
		var c: Control = h.panel(p)
		if not assert_true(c != null, p + " exists"):
			continue
		assert_eq(c.get_parent(), load_panel.get_parent(), p + " sibling of MenuLoad")
		assert_eq([c.offset_left, c.offset_top, c.offset_right, c.offset_bottom],
			[load_panel.offset_left, load_panel.offset_top, load_panel.offset_right, load_panel.offset_bottom], p + " offsets")
		assert_eq([c.anchor_top, c.anchor_bottom, c.grow_vertical], [load_panel.anchor_top, load_panel.anchor_bottom,
			load_panel.grow_vertical], p + " anchors")
		assert_false(c.visible, p + " hidden at start")
		for b in c.get_children():
			if b is Button:
				assert_eq(b.get_theme_font_size("font_size"), new_btn.get_theme_font_size("font_size"), p + "/" + b.name + " size 52")
	await _close()


func test_esc_is_back_not_quit() -> void:
	await _open()
	h.press(h.button("MenuButtons/MPMultiplayer"))
	h.press(h.panel("MPHostJoin").join_button)
	assert_eq(h.top(), "MPJoin", "join panel")
	h.esc()
	await wait_frames(1)
	assert_eq(h.top(), "MPHostJoin", "Esc goes back one panel")
	h.esc()
	await wait_frames(1)
	assert_eq(h.top(), "", "Esc back to MenuButtons")
	assert_true(h.menu.get_node("Background/MenuButtons").visible, "MenuButtons visible again")
	assert_eq(h.menu.quit_dialogs, 0, "the game's quit dialog never opened")
	h.esc()
	await wait_frames(1)
	assert_eq(h.menu.quit_dialogs, 1, "on MenuButtons Esc is the game's again")
	await _close()


func test_back_buttons() -> void:
	await _open()
	h.press(h.button("MenuButtons/MPMultiplayer"))
	h.press(h.panel("MPHostJoin").back_button)
	assert_eq(h.top(), "", "Back on Host/Join")
	h.press(h.button("MenuButtons/MPMultiplayer"))
	h.press(h.panel("MPHostJoin").join_button)
	h.press(h.panel("MPJoin").back_button)
	assert_eq(h.top(), "MPHostJoin", "Back on Join")
	await _close()


func test_focus_current_panel() -> void:
	await _open()
	h.press(h.button("MenuButtons/MPMultiplayer"))
	h.menu.log.clear()
	h.menu._focus_current_panel()
	assert_false("focus_current_panel" in h.menu.log, "ours handled it, no super")
	var f: Control = runner.get_viewport().gui_get_focus_owner()
	assert_eq(f, h.panel("MPHostJoin").host_button, "first enabled button focused")
	h.press(h.panel("MPHostJoin").back_button)
	h.menu._focus_current_panel()
	assert_true("focus_current_panel" in h.menu.log, "game's panels: super")
	await _close()


func test_disabled_when_unavailable() -> void:
	h = Harness.new(core, runner, tree)
	await h.open("fake", func(l): l.avail = {"ok": false, "reason": "MP_ERR_NO_STEAM"})
	var mp: Button = h.button("MenuButtons/MPMultiplayer")
	assert_true(mp.disabled, "disabled without Steam")
	assert_eq(mp.tooltip_text, "Steam is not running", "reason tooltip")
	# the sub-panel guards too (e.g. Steam went away after the menu was built)
	h.ui.router.push("MPHostJoin")
	assert_true(h.panel("MPHostJoin").host_button.disabled, "Host disabled without Steam")
	assert_true(h.panel("MPHostJoin").join_button.disabled, "Join disabled without Steam")
	await _close()


func test_contract_failure_disables_button() -> void:
	h = Harness.new(core, runner, tree)
	await h.open()
	h.api.contract_result = {"ok": false, "missing": ["mp.menu|x|method|y"], "features_off": ["mp.menu"]}
	h.ui._check_contract()
	h.new_menu()
	var mp: Button = h.button("MenuButtons/MPMultiplayer")
	assert_true(mp.disabled, "disabled when the contract fails")
	assert_eq(mp.tooltip_text, "Multiplayer does not support this game version", "reason")
	await _close()


func test_host_picking_flow() -> void:
	await _open()
	h.press(h.button("MenuButtons/MPMultiplayer"))
	h.press(h.panel("MPHostJoin").host_button)
	assert_eq(h.top(), "MPLobby", "lobby panel while creating")
	await wait_frames(1)
	assert_true(h.lobby.is_owner(), "fake lobby entered as host")
	var lp = h.panel("MPLobby")
	assert_true(lp.start_button.visible and not lp.start_button.disabled, "Start enabled for the host")
	var sounds_before: int = h.menu.sounds
	h.press(lp.start_button)
	assert_eq(h.session.called("start_game"), 1, "start_game called")
	assert_true(h.ui.is_host_picking(), "picking")
	assert_true(h.menu.get_node("Background/MenuLoad").visible, "the game's save panel is open")
	assert_false(lp.visible, "our panel hidden")
	assert_eq(h.menu.sounds - sounds_before, 1, "one click sound (the game's)")
	assert_eq(h.lobby.current().state, "starting", "lobby state starting")

	# Back from the save panel -> cancel_start, our lobby again
	h.menu.ignore_input = false
	h.menu._on_return_save_load()
	assert_eq(h.session.called("cancel_start"), 1, "cancel_start")
	assert_false(h.ui.is_host_picking(), "not picking")
	assert_false(h.menu.get_node("Background/MenuLoad").visible, "save panel closed")
	assert_true(lp.visible, "lobby panel back")
	assert_false(h.menu.get_node("Background/MenuButtons").visible, "MenuButtons stay hidden")
	assert_false("return_save_load" in h.menu.log, "vanilla Back not run while picking")

	# sandbox is blocked while picking
	h.press(lp.start_button)
	h.menu.ignore_input = false
	h.menu._on_sandbox_pressed()
	assert_false(h.menu.get_node("Background/MenuSandbox").visible, "sandbox panel not opened")
	assert_has(h.api.toasts, "Sandbox is not available in multiplayer", "toast")

	# New Game launches: notify_host_launch BEFORE super
	h.menu.ignore_input = false
	h.menu._on_new_game()
	var idx_notify := -1
	for i in h.session.calls.size():
		if h.session.calls[i][0] == "notify_host_launch":
			idx_notify = i
	assert_true(idx_notify >= 0, "notify_host_launch called")
	assert_eq(h.session.calls[idx_notify][1], ["res://scenes/world.tscn"], "scene path")
	assert_eq(h.menu.launched, ["res://scenes/world.tscn"], "super ran (always)")
	assert_false(h.ui.is_host_picking(), "picking ends on launch")
	await _close()


func test_launch_without_picking_is_vanilla() -> void:
	await _open()
	h.menu._on_new_game()
	assert_eq(h.session.called("notify_host_launch"), 0, "no session call")
	assert_eq(h.menu.launched, ["res://scenes/world.tscn"], "vanilla launch")
	h.menu.ignore_input = false
	h.menu.get_node("Background/MenuLoad").visible = true
	h.menu._on_return_save_load()
	assert_true("return_save_load" in h.menu.log, "vanilla Back")
	await _close()


func test_menu_scale_applies_once() -> void:
	await _open()
	var mp: Button = h.button("MenuButtons/MPMultiplayer")
	var size1: int = mp.get_theme_font_size("font_size")
	h.ui.inject(h.menu)
	assert_eq(mp.get_theme_font_size("font_size"), size1, "re-inject does not shrink the font")
	await _close()
