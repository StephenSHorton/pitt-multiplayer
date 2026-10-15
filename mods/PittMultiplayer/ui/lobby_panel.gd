extends VBoxContainer
## Lobby screen. Left (MenuLoad layout): a status line, then Start + Invite
## (host only) and Leave. Centre of the screen: the joined players as save-slot
## rows (gold for the host, a status suffix from the session roster). No chat.
## Dumb view: redraws from LobbyService (members_changed, lobby_data_changed,
## lobby_entered) and Session (state_changed, roster_changed,
## start_availability_changed). Leave and Esc open the game's ConfirmDialog.

const Style = preload("ui_style.gd")

var ui = null
var status_label: Label = null
var start_button: Button = null
var invite_button: Button = null
var leave_button: Button = null
var members_root: Control = null     # full-rect centred container (sibling under Background)
var members_title: Label = null
var members_list: ScrollContainer = null
var members_box: VBoxContainer = null
var _member_rows: Array = []
var _column: VBoxContainer = null
## The menu uses canvas_items stretch with keep_height (960 px virtual height),
## so 4:3 / 16:9 / 21:9 differ only in the free WIDTH right of the menu column
## (about 400 / 830 / 1410 virtual px): the list scales with that width.
const COLUMN_MAX := 820.0           # column width at scale 1.0
const COLUMN_MIN := 280.0
const SCALE_MIN := 0.5
const SCALE_MAX := 1.25
const VISIBLE_ROWS := 6             # more members scroll
## Pixel-font sizes at scale 1.0 (PublicPixel / the title font stay crisp on multiples of 8)
const TITLE_PX := 56
const NUMBER_PX := 32
const NAME_PX := 32
const INFO_PX := 24
const ROW_H := 88.0
var ui_scale := 1.0
var _lobby: Node = null
var _session: Node = null
var _start_ok := false
var _start_reason := ""


func build(p_ui, template: Button, like_scroll: Control, p_members_root: Control) -> void:
	ui = p_ui
	status_label = Style.info_label("Status", "", Style.slot_color(ui.menu, "NORMAL"))
	status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(status_label)
	start_button = Style.clone_button(template, "Start", "MP_START")
	invite_button = Style.clone_button(template, "Invite", "MP_INVITE")
	leave_button = Style.clone_button(template, "Leave", "MP_LEAVE")
	for b in [start_button, invite_button, leave_button]:
		add_child(b)
	# Start opens the game's own save panel, which plays its own click sound
	ui.router.wire(start_button, func(): ui.start_pressed(), false)
	ui.router.wire(invite_button, func(): ui.invite_pressed())
	ui.router.wire(leave_button, func(): ui.leave_pressed())

	members_root = p_members_root
	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	members_root.add_child(center)
	_column = VBoxContainer.new()
	_column.name = "Column"
	_column.custom_minimum_size = Vector2(COLUMN_MAX, 0)
	_column.add_theme_constant_override("separation", 16)
	center.add_child(_column)
	members_title = Style.title_label("Title", "", TITLE_PX)
	members_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_column.add_child(members_title)
	members_list = Style.make_list("Members", like_scroll)
	members_list.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	members_box = members_list.get_node("Rows")
	_column.add_child(members_list)
	members_root.resized.connect(_fit_column)
	_fit_column()


## Snaps a scale-1.0 pixel size to `scale`, on a multiple of 8.
static func px(base: int, scale: float) -> int:
	return maxi(8, int(roundf(float(base) * scale / 8.0)) * 8)


## Scale for a free area `w` virtual px wide (1.0 when the full column fits). Pure.
static func scale_for(w: float) -> float:
	return clampf((w - 32.0) / COLUMN_MAX, SCALE_MIN, SCALE_MAX) if w > 0.0 else 1.0


## The list sits in the free area right of the menu column, vertically centred
## (the CenterContainer + a list exactly as tall as its rows), scaled with the
## free width: larger on 21:9, smaller on 4:3 instead of running under the buttons.
func _fit_column() -> void:
	if members_root == null or _column == null:
		return
	ui_scale = scale_for(members_root.size.x)
	members_title.add_theme_font_size_override("font_size", px(TITLE_PX, ui_scale))
	var w := COLUMN_MAX * ui_scale
	if members_root.size.x > 0.0:
		w = clampf(members_root.size.x - 32.0, COLUMN_MIN, w)
	_column.custom_minimum_size.x = w
	for r in _member_rows:
		_style_row(r)
	_fit_list_height()


func _style_row(row: Control) -> void:
	row.custom_minimum_size.y = roundf(ROW_H * ui_scale)
	for pair in [["Number", NUMBER_PX], ["Name", NAME_PX], ["Info", INFO_PX]]:
		var l := row.find_child(pair[0], true, false)
		if l is Label:
			l.add_theme_font_size_override("font_size", px(pair[1], ui_scale))
			if pair[0] != "Number":
				l.clip_text = true
				l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			if pair[0] == "Number":
				l.custom_minimum_size.x = px(NUMBER_PX, ui_scale) * 3.0
				l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var vb := row.find_child("VBox", true, false)
	if vb is BoxContainer:
		vb.alignment = BoxContainer.ALIGNMENT_CENTER
	var m := row.find_child("Margin", false, false)
	if m is Control:
		# the game's row places Margin with offsets (40 x 40): stretch it so
		# number / name / info sit vertically centred in the taller row
		m.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var gap := int(roundf(12.0 * ui_scale))
		for side in ["left", "right", "top", "bottom"]:
			m.add_theme_constant_override("margin_" + side, gap)


## The list is exactly as tall as its rows (up to VISIBLE_ROWS, then it scrolls).
func _fit_list_height() -> void:
	if members_list == null:
		return
	var sep := float(members_box.get_theme_constant("separation"))
	var n := clampi(_member_rows.size(), 1, VISIBLE_ROWS)
	var h := roundf(ROW_H * ui_scale) * n + sep * (n - 1)
	members_list.custom_minimum_size = Vector2(0, h)
	if "custom_maximum_size" in members_list:
		# copied from the game's MenuLoad list: keep the cap at exactly the rows
		members_list.set("custom_maximum_size", Vector2(100000, h))
	members_list.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO if _member_rows.size() > VISIBLE_ROWS 		else ScrollContainer.SCROLL_MODE_DISABLED


func _enter_tree() -> void:
	if ui != null:
		_bind(ui.lobby, ui.session)


func _exit_tree() -> void:
	_bind(null, null)


func _bind(l: Node, s: Node) -> void:
	if _lobby != null and is_instance_valid(_lobby):
		for pair in [["members_changed", _on_members], ["lobby_data_changed", _on_lobby_data], ["lobby_entered", _on_lobby_data]]:
			if _lobby.is_connected(pair[0], pair[1]):
				_lobby.disconnect(pair[0], pair[1])
	if _session != null and is_instance_valid(_session):
		for pair in [["state_changed", _on_session_state], ["roster_changed", _on_roster],
				["start_availability_changed", _on_start_availability]]:
			if _session.has_signal(pair[0]) and _session.is_connected(pair[0], pair[1]):
				_session.disconnect(pair[0], pair[1])
	_lobby = l
	_session = s
	if _lobby != null:
		_lobby.members_changed.connect(_on_members)
		_lobby.lobby_data_changed.connect(_on_lobby_data)
		_lobby.lobby_entered.connect(_on_lobby_data)
	if _session != null:
		for pair in [["state_changed", _on_session_state], ["roster_changed", _on_roster],
				["start_availability_changed", _on_start_availability]]:
			if _session.has_signal(pair[0]):
				_session.connect(pair[0], pair[1])


func on_shown() -> void:
	if members_root != null:
		members_root.visible = true
	if _session != null and _session.has_method("can_start"):
		var cs: Dictionary = _session.can_start()
		_start_ok = bool(cs.get("ok", false))
		_start_reason = str(cs.get("reason", ""))
	redraw()


func on_hidden() -> void:
	if members_root != null:
		members_root.visible = false


func on_back() -> void:
	ui.router.play_click()
	ui.leave_pressed()


func first_focus() -> Control:
	return Style.first_button(self)


# ------------------------------------------------------------------ signal handlers

func _on_members(_m: Array) -> void:
	redraw()


func _on_lobby_data(_info: Dictionary) -> void:
	redraw()


func _on_session_state(_state: String, _info: Dictionary) -> void:
	if _session != null and _session.has_method("can_start"):
		var cs: Dictionary = _session.can_start()
		_start_ok = bool(cs.get("ok", false))
		_start_reason = str(cs.get("reason", ""))
	redraw()


func _on_roster(_players: Array) -> void:
	redraw()


func _on_start_availability(ok: bool, reason: String) -> void:
	_start_ok = ok
	_start_reason = reason
	redraw()


# ------------------------------------------------------------------ drawing

func redraw() -> void:
	if status_label == null or _lobby == null:
		return
	var in_lobby: bool = _lobby.is_in_lobby()
	var owner: bool = in_lobby and _lobby.is_owner()
	var pending := str(_lobby.is_pending()) if _lobby.has_method("is_pending") else ""
	if not in_lobby and pending == "":
		pending = ui.last_lobby_op if ui != null else ""
	start_button.visible = owner or (not in_lobby and pending == "host")
	invite_button.visible = start_button.visible
	start_button.disabled = not (owner and _start_ok)
	start_button.tooltip_text = tr(_start_reason) if (owner and not _start_ok and _start_reason != "") else ""
	invite_button.disabled = not owner
	status_label.text = tr(status_key())
	_draw_members()
	Style.chain_focus([start_button, invite_button, leave_button])
	if is_visible_in_tree() and _using_gamepad():
		var vp := get_viewport()
		var f: Control = vp.gui_get_focus_owner() if vp != null else null
		if f == null or not f.is_visible_in_tree() or (f is BaseButton and f.disabled):
			var b := first_focus()
			if b != null:
				b.grab_focus.call_deferred()


## The status line key for the current lobby / session state.
func status_key() -> String:
	var in_lobby: bool = _lobby.is_in_lobby()
	var pending := str(_lobby.is_pending()) if _lobby.has_method("is_pending") else ""
	if not in_lobby:
		if pending == "host" or (pending == "" and ui != null and ui.last_lobby_op == "host"):
			return "MP_CREATING_LOBBY"
		return "MP_JOINING_LOBBY"
	var st := ""
	var info: Dictionary = {}
	if _session != null and _session.has_method("get_state"):
		st = str(_session.get_state())
		info = ui.last_session_info if ui != null else {}
	if _lobby.is_owner():
		if st == "starting":
			return "MP_HOST_LOADING"
		if not _start_ok and _start_reason != "":
			return _start_reason
		return "MP_HOST_READY"
	if st == "loading" or st == "in_game":
		return "MP_JOINING"
	var sub := str(info.get("sub", ""))
	if st == "" or st == "idle" or sub == "connecting" or sub == "handshake":
		return "MP_CONNECTING"
	var host_state := str(info.get("host_state", ""))
	var lobby_state := str(_lobby.current().get("state", ""))
	if host_state == "starting" or lobby_state == "starting":
		return "MP_HOST_LOADING"
	if host_state in ["open", "in_game", "transition"] or lobby_state == "in_game":
		return "MP_JOINING"
	return "MP_WAITING_FOR_HOST"


func _draw_members() -> void:
	for r in _member_rows:
		members_box.remove_child(r)
		r.queue_free()
	_member_rows.clear()
	var members: Array = _lobby.get_members() if _lobby.is_in_lobby() else []
	var cur: Dictionary = _lobby.current()
	var max_n := int(cur.get("max", 10)) if not cur.is_empty() else 10
	members_title.text = tr("MP_PLAYERS").format({"n": members.size(), "max": max_n})
	var roster: Dictionary = {}
	if _session != null and _session.has_method("get_roster"):
		for p in _session.get_roster():
			roster[str(p.get("platform_id", ""))] = p
			roster["name:" + str(p.get("name", ""))] = p
	var i := 0
	for m in members:
		i += 1
		var row := Style.make_row()
		row.name = "Member%d" % i
		row.focus_mode = Control.FOCUS_NONE
		row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		members_box.add_child(row)
		var tags: Array = []
		if bool(m.get("is_owner", false)):
			tags.append(tr("MP_HOST_TAG"))
		if bool(m.get("is_self", false)):
			tags.append(tr("MP_YOU_TAG"))
		var p: Dictionary = roster.get(str(m.get("id", "")), roster.get("name:" + str(m.get("name", "")), {}))
		var pst := str(p.get("state", ""))
		if pst == "loading":
			tags.append(tr("MP_STATE_LOADING"))
		elif pst == "in_game":
			tags.append(tr("MP_STATE_IN_GAME"))
		Style.set_row(row, "%02d" % i, str(m.get("name", "")), " | ".join(tags))
		Style.tint_row(row, Style.slot_color(ui.menu, "SELECTED" if bool(m.get("is_owner", false)) else "NORMAL"))
		_style_row(row)
		_member_rows.append(row)
	_fit_list_height()


## Test/introspection: [{name, info}] of the member rows.
func member_snapshot() -> Array:
	var out: Array = []
	for r in _member_rows:
		out.append({"name": Style.row_label(r, "Name"), "info": Style.row_label(r, "Info")})
	return out


func _using_gamepad() -> bool:
	var im := get_tree().root.get_node_or_null("InputManager") if is_inside_tree() else null
	return im != null and im.get("using_gamepad") == true
