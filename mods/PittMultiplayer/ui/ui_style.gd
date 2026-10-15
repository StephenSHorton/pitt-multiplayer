extends RefCounted
## Builds our menu controls from the LIVE main-menu nodes, so they carry the
## game's own theme (res://assets/main_menu.tres, inherited from Background),
## fonts, sizes and overrides. Nothing is copied into the mod; fonts and the
## save-slot row scene are loaded from res:// when present.

const PIXEL_FONT_PATH := "res://assets/PublicPixel-rv0pA.ttf"
const TITLE_FONT_PATH := "res://addons/ridiculous_coding/GravityBold8.ttf"
const SLOT_ROW_PATH := "res://scenes/save_slot_row.tscn"
const TITLE_GOLD := Color(0.969, 0.729, 0.078)
## The game's slot-row tints (main_menu.gd SLOT_COLOR_*), used when the live menu lacks them.
const FALLBACK_NORMAL := Color(0.62, 0.62, 0.62)
const FALLBACK_EMPTY := Color(0.34, 0.34, 0.34)
const FALLBACK_SELECTED := Color(1.0, 0.82, 0.2)
## Duplicate flags for Play: no DUPLICATE_SIGNALS (Play's .tscn connection to
## _on_play_pressed must not be copied).
const DUP_FLAGS := Node.DUPLICATE_GROUPS | Node.DUPLICATE_SCRIPTS | Node.DUPLICATE_USE_INSTANTIATION
const SUB_BUTTON_SIZE := 52
const INFO_FONT_SIZE := 26


static func font(path: String) -> Font:
	if ResourceLoader.exists(path):
		var f = load(path)
		if f is Font:
			return f
	return null


## Copies anchors, offsets and grow directions (the MenuButtons / MenuLoad layout).
static func copy_layout(src: Control, dst: Control) -> void:
	dst.layout_mode = src.layout_mode
	for side in [SIDE_LEFT, SIDE_TOP, SIDE_RIGHT, SIDE_BOTTOM]:
		dst.set_anchor(side, src.get_anchor(side))
		dst.set_offset(side, src.get_offset(side))
	dst.grow_horizontal = src.grow_horizontal
	dst.grow_vertical = src.grow_vertical
	dst.size_flags_horizontal = src.size_flags_horizontal
	dst.size_flags_vertical = src.size_flags_vertical


## A sibling panel laid out like `like` (MenuLoad), hidden.
static func make_panel(panel_name: String, like: Control, script: Script = null) -> VBoxContainer:
	var p: VBoxContainer = VBoxContainer.new() if script == null else script.new()
	p.name = panel_name
	copy_layout(like, p)
	if like is BoxContainer:
		p.alignment = (like as BoxContainer).alignment
	p.visible = false
	return p


## Clones a game button (keeps font, size and colour overrides) without its signals.
static func clone_button(template: Button, node_name: String, text_key: String) -> Button:
	var b: Button = template.duplicate(DUP_FLAGS)
	b.name = node_name
	b.text = text_key
	b.disabled = false
	b.visible = true
	b.tooltip_text = ""
	b.button_pressed = false
	return b


## Plain label in the menu's pixel font (status lines, empty state).
static func info_label(node_name: String, text_key: String, color: Color = FALLBACK_NORMAL,
		size: int = INFO_FONT_SIZE) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = text_key
	var f := font(PIXEL_FONT_PATH)
	if f != null:
		l.add_theme_font_override("font", f)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return l


## Gold title in the game's title font.
static func title_label(node_name: String, text_key: String, size: int = 64) -> Label:
	var l := Label.new()
	l.name = node_name
	l.text = text_key
	var f := font(TITLE_FONT_PATH)
	if f != null:
		l.add_theme_font_override("font", f)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", TITLE_GOLD)
	return l


## A list area like MenuLoad/ScrollContainer (same min/max size), with a VBox inside.
static func make_list(node_name: String, like_scroll: Control) -> ScrollContainer:
	var s := ScrollContainer.new()
	s.name = node_name
	if like_scroll != null:
		s.custom_minimum_size = like_scroll.custom_minimum_size
		if "custom_maximum_size" in like_scroll and "custom_maximum_size" in s:
			s.set("custom_maximum_size", like_scroll.get("custom_maximum_size"))
		s.size_flags_horizontal = like_scroll.size_flags_horizontal
		s.size_flags_vertical = like_scroll.size_flags_vertical
	else:
		s.custom_minimum_size = Vector2(100, 200)
	s.follow_focus = true
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var box := VBoxContainer.new()
	box.name = "Rows"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.add_child(box)
	return s


## One row: the game's save_slot_row.tscn (Number / Name / Info labels), or an
## equivalent built here when the scene is missing (headless tests).
static func make_row() -> Button:
	if ResourceLoader.exists(SLOT_ROW_PATH):
		var ps = load(SLOT_ROW_PATH)
		if ps is PackedScene:
			var r = ps.instantiate()
			if r is Button:
				r.toggle_mode = false
				r.focus_mode = Control.FOCUS_ALL
				return r
			r.free()
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 64)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_ALL
	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(margin)
	var hb := HBoxContainer.new()
	hb.name = "HBox"
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(hb)
	var num := Label.new()
	num.name = "Number"
	hb.add_child(num)
	var vb := VBoxContainer.new()
	vb.name = "VBox"
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(vb)
	var nm := Label.new()
	nm.name = "Name"
	vb.add_child(nm)
	var info := Label.new()
	info.name = "Info"
	vb.add_child(info)
	return b


static func set_row(row: Node, number: String, row_name: String, info: String) -> void:
	_set_label(row, "Number", number)
	_set_label(row, "Name", row_name)
	_set_label(row, "Info", info)


## Same tint rule as main_menu._tint_row: Number/Name in colour, Info at 75 %.
static func tint_row(row: Node, color: Color) -> void:
	for n in ["Number", "Name"]:
		var l := row.find_child(n, true, false)
		if l is Label:
			l.add_theme_color_override("font_color", color)
	var info := row.find_child("Info", true, false)
	if info is Label:
		info.add_theme_color_override("font_color", color * 0.75)


static func row_label(row: Node, label_name: String) -> String:
	var l := row.find_child(label_name, true, false)
	return l.text if l is Label else ""


static func _set_label(row: Node, label_name: String, text: String) -> void:
	var l := row.find_child(label_name, true, false)
	if l is Label:
		l.text = text


## SLOT_COLOR_* read from the live menu instance (falls back to the known values).
static func slot_color(menu: Object, which: String) -> Color:
	var key := "SLOT_COLOR_" + which
	if menu != null:
		var s: Script = menu.get_script()
		while s != null:
			var consts := s.get_script_constant_map()
			if consts.has(key) and consts[key] is Color:
				return consts[key]
			s = s.get_base_script()
	match which:
		"EMPTY":
			return FALLBACK_EMPTY
		"SELECTED":
			return FALLBACK_SELECTED
	return FALLBACK_NORMAL


## The first visible, enabled button under node (depth first, skipping list areas
## the way main_menu._grab_first_button does).
static func first_button(node: Node, include_lists: bool = false) -> BaseButton:
	for c in node.get_children():
		if c is ScrollContainer and not include_lists:
			continue
		if c is BaseButton and c.visible and not c.disabled:
			return c
		if c is Control and c.visible:
			var f := first_button(c, include_lists)
			if f != null:
				return f
	return null


## Up/down focus neighbours for a vertical list of controls (wraps at the ends to itself).
static func chain_focus(controls: Array) -> void:
	var list: Array = []
	for c in controls:
		if c is Control and c.visible and not (c is BaseButton and c.disabled):
			list.append(c)
	for i in list.size():
		var c: Control = list[i]
		var up: Control = list[i - 1] if i > 0 else c
		var down: Control = list[i + 1] if i < list.size() - 1 else c
		c.focus_neighbor_top = c.get_path_to(up)
		c.focus_neighbor_bottom = c.get_path_to(down)
		c.focus_previous = c.get_path_to(up)
		c.focus_next = c.get_path_to(down)
		c.focus_neighbor_left = c.get_path_to(c)
		c.focus_neighbor_right = c.get_path_to(c)
