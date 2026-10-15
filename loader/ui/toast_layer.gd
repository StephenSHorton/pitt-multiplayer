extends CanvasLayer
## PittAPI's own UI layer (layer 90, PROCESS_MODE_ALWAYS) under /root/PittAPI/UI.
## Lives outside the World, so toasts also work on the main menu.

const FONT_PATH := "res://assets/PublicPixel-rv0pA.ttf"
const MAX_TOASTS := 6

var _stack: VBoxContainer = null
var _panels: Control = null
var _font: Font = null
var _panel_owner: Dictionary = {}   # id -> owner mod


func _init() -> void:
	name = "UI"
	layer = 90
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	if ResourceLoader.exists(FONT_PATH):
		var f = load(FONT_PATH)
		if f is Font:
			_font = f
	_panels = Control.new()
	_panels.name = "Panels"
	_panels.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panels.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panels)
	_stack = VBoxContainer.new()
	_stack.name = "Toasts"
	_stack.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_stack.anchor_left = 1.0
	_stack.anchor_right = 1.0
	_stack.offset_left = -440
	_stack.offset_right = -16
	_stack.offset_top = 16
	_stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stack.alignment = BoxContainer.ALIGNMENT_BEGIN
	add_child(_stack)


## opts: {duration = 3.0, color = Color.WHITE, owner = ""}. Returns the toast node.
func toast(text: String, opts: Dictionary = {}) -> Control:
	if _stack == null:
		return null
	while _stack.get_child_count() >= MAX_TOASTS:
		var old := _stack.get_child(0)
		_stack.remove_child(old)
		old.queue_free()
	var panel := PanelContainer.new()
	panel.name = "Toast"
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.72)
	sb.border_color = opts.get("color", Color(1, 0.85, 0.2))
	sb.set_border_width_all(2)
	sb.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", sb)
	var label := Label.new()
	label.name = "Text"
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size = Vector2(400, 0)
	label.add_theme_color_override("font_color", opts.get("color", Color.WHITE))
	if _font != null:
		label.add_theme_font_override("font", _font)
	label.add_theme_font_size_override("font_size", int(opts.get("font_size", 12)))
	panel.add_child(label)
	panel.set_meta("pittapi_owner", String(opts.get("owner", "")))
	_stack.add_child(panel)
	var duration := float(opts.get("duration", 3.0))
	var tw := panel.create_tween()
	tw.tween_interval(maxf(0.1, duration))
	tw.tween_property(panel, "modulate:a", 0.0, 0.4)
	tw.tween_callback(panel.queue_free)
	return panel


func toasts() -> Array:
	return _stack.get_children() if _stack != null else []


func add_panel(id: String, control: Control, owner: String) -> Error:
	if _panels == null or control == null:
		return ERR_UNCONFIGURED
	remove_panel(id)
	control.name = id.validate_node_name()
	control.set_meta("pittapi_panel_id", id)
	_panels.add_child(control)
	_panel_owner[id] = owner
	return OK


func remove_panel(id: String) -> void:
	if _panels == null:
		return
	for c in _panels.get_children():
		if c.get_meta("pittapi_panel_id", "") == id:
			_panels.remove_child(c)
			c.queue_free()
	_panel_owner.erase(id)


func remove_owner(owner: String) -> void:
	for id in _panel_owner.keys():
		if _panel_owner[id] == owner:
			remove_panel(id)
	if _stack != null:
		for t in _stack.get_children():
			if t.get_meta("pittapi_owner", "") == owner:
				t.queue_free()


func has_panel(id: String) -> bool:
	return _panel_owner.has(id)
