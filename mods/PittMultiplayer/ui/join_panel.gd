extends VBoxContainer
## Join screen: friends' open lobbies (host name, members / max, state), laid out
## like MenuLoad (the same ScrollContainer size and save-slot rows), then
## Refresh and Back. Incompatible / full lobbies show disabled with the reason.
## Dumb view: it redraws from LobbyService.friend_lobbies_changed. While it is
## visible the service scans (events + 10 s fallback); hidden, it stops.

const Style = preload("ui_style.gd")

var ui = null
var list: ScrollContainer = null
var rows_box: VBoxContainer = null
var empty_label: Label = null     # the Name label of the empty-state row
var empty_row: Button = null
var refresh_button: Button = null
var back_button: Button = null
var _rows: Array = []        # [{row: Button, info: Dictionary}]
var _lobby: Node = null


func build(p_ui, template: Button, like_scroll: Control) -> void:
	ui = p_ui
	list = Style.make_list("ScrollContainer", like_scroll)
	rows_box = list.get_node("Rows")
	add_child(list)
	# empty state: a save-slot row like the game's "- EMPTY -" slots, not focusable
	empty_row = Style.make_row()
	empty_row.name = "Empty"
	empty_row.focus_mode = Control.FOCUS_NONE
	empty_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Style.set_row(empty_row, "    ", "MP_NO_FRIENDS_HOSTING", "")
	Style.tint_row(empty_row, Style.slot_color(ui.menu, "EMPTY"))
	rows_box.add_child(empty_row)
	empty_label = empty_row.find_child("Name", true, false)
	refresh_button = Style.clone_button(template, "Refresh", "MP_REFRESH")
	back_button = Style.clone_button(template, "Return", "MENU_BACK")
	add_child(refresh_button)
	add_child(back_button)
	ui.router.wire(refresh_button, func(): _refresh())
	ui.router.wire(back_button, func(): ui.router.pop())


func _enter_tree() -> void:
	_bind(ui.lobby if ui != null else null)


func _exit_tree() -> void:
	_set_scan(false)
	_bind(null)


func _bind(l: Node) -> void:
	if _lobby != null and is_instance_valid(_lobby) and _lobby.friend_lobbies_changed.is_connected(redraw):
		_lobby.friend_lobbies_changed.disconnect(redraw)
	_lobby = l
	if _lobby != null:
		_lobby.friend_lobbies_changed.connect(redraw)


func on_shown() -> void:
	if _lobby == null and ui != null:
		_bind(ui.lobby)
	if _lobby != null and _lobby.has_method("friend_lobbies"):
		redraw(_lobby.friend_lobbies())
	_set_scan(true)
	_refresh()


func on_hidden() -> void:
	_set_scan(false)


func on_back() -> void:
	ui.router.play_click()
	ui.router.pop()


func first_focus() -> Control:
	for r in _rows:
		if not r.row.disabled:
			return r.row
	return refresh_button


func _refresh() -> void:
	if _lobby != null:
		_lobby.refresh_friend_lobbies()


func _set_scan(on: bool) -> void:
	if _lobby != null and is_instance_valid(_lobby):
		_lobby.set_scan_active(on)


## [LobbyInfo] -> rows. Focus is kept on the same lobby id when possible.
func redraw(lobbies: Array) -> void:
	if rows_box == null:
		return
	var focused_id := ""
	var vp := get_viewport()
	var owner_ctl: Control = vp.gui_get_focus_owner() if vp != null else null
	for r in _rows:
		if r.row == owner_ctl:
			focused_id = str(r.info.id)
		rows_box.remove_child(r.row)
		r.row.queue_free()
	_rows.clear()
	var i := 0
	for info in lobbies:
		i += 1
		var row := Style.make_row()
		row.name = "Lobby%d" % i
		rows_box.add_child(row)
		_fill(row, info, i)
		_rows.append({"row": row, "info": info})
		if bool(info.get("joinable", false)):
			var id := str(info.id)
			ui.router.wire(row, func(): ui.join_lobby(id))
		row.focus_entered.connect(_on_row_focus.bind(row, i, true))
		row.focus_exited.connect(_on_row_focus.bind(row, i, false))
	empty_row.visible = _rows.is_empty()
	var chain: Array = []
	for r in _rows:
		chain.append(r.row)
	chain.append_array([refresh_button, back_button])
	Style.chain_focus(chain)
	if focused_id != "" and visible:
		var refocused := false
		for r in _rows:
			if str(r.info.id) == focused_id and not r.row.disabled:
				r.row.grab_focus.call_deferred()
				refocused = true
		if not refocused and is_visible_in_tree() and _using_gamepad():
			# the focused lobby is gone or no longer joinable: never leave a
			# controller user without focus (the lobby panel does the same)
			var b := first_focus()
			if b != null:
				b.grab_focus.call_deferred()


func _using_gamepad() -> bool:
	var im := get_tree().root.get_node_or_null("InputManager") if is_inside_tree() else null
	return im != null and im.get("using_gamepad") == true


func _fill(row: Button, info: Dictionary, index: int) -> void:
	var joinable := bool(info.get("joinable", false))
	var state_key := "MP_STATE_" + str(info.get("state", "waiting")).to_upper()
	var line := ""
	if not joinable and str(info.get("reason", "")) != "":
		line = tr(str(info.reason))
	elif bool(info.get("dev", false)):
		line = tr("MP_DEV_TARGET")
	else:
		line = tr("MP_LOBBY_ROW_INFO").format({"n": int(info.get("members", 0)), "max": int(info.get("max", 0)),
			"state": tr(state_key)})
	Style.set_row(row, "  %02d" % index, str(info.get("host_name", "")), line)
	row.disabled = not joinable
	row.tooltip_text = line if not joinable else ""
	Style.tint_row(row, Style.slot_color(ui.menu, "NORMAL" if joinable else "EMPTY"))
	row.set_meta("lobby_id", str(info.get("id", "")))


func _on_row_focus(row: Button, index: int, focused: bool) -> void:
	if is_instance_valid(row):
		Style.set_row(row, ("> %02d" if focused else "  %02d") % index, Style.row_label(row, "Name"),
			Style.row_label(row, "Info"))
		if not row.disabled:
			Style.tint_row(row, Style.slot_color(ui.menu, "SELECTED" if focused else "NORMAL"))


## Test/introspection: [{id, name, info, disabled}] of the visible rows.
func row_snapshot() -> Array:
	var out: Array = []
	for r in _rows:
		out.append({"id": str(r.info.id), "name": Style.row_label(r.row, "Name"), "info": Style.row_label(r.row, "Info"),
			"disabled": r.row.disabled, "node": r.row})
	return out
