extends Control
## Dev console panel: a log view plus a LineEdit on PittAPI's UI layer.
## While open it sets the player's golf_aim_mode meta (blocks movement) and shows
## the mouse. It never pauses the tree.

var registry: Object = null
var core: Object = null
var _out: RichTextLabel = null
var _line: LineEdit = null
var _history: Array[String] = []
var _hist_i := -1
var _prev_mouse := Input.MOUSE_MODE_VISIBLE


func _init() -> void:
	name = "Console"
	visible = false
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_preset(Control.PRESET_TOP_WIDE)
	offset_bottom = 360


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.82)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 8
	box.offset_right = -8
	box.offset_top = 8
	box.offset_bottom = -8
	add_child(box)
	_out = RichTextLabel.new()
	_out.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_out.scroll_following = true
	_out.selection_enabled = true
	box.add_child(_out)
	_line = LineEdit.new()
	_line.placeholder_text = "PittAPI console - type help"
	_line.text_submitted.connect(_on_submit)
	_line.gui_input.connect(_on_line_input)
	box.add_child(_line)
	print_line("PittAPI console. Type 'help'.")


func toggle() -> void:
	set_open(not visible)


func set_open(open: bool) -> void:
	if open == visible:
		return
	visible = open
	if open:
		_prev_mouse = Input.mouse_mode
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if core != null:
			core.set_movement_lock("PittAPI.console", true)
		_line.grab_focus()
	else:
		Input.mouse_mode = _prev_mouse
		if core != null:
			core.set_movement_lock("PittAPI.console", false)
		_line.release_focus()


func print_line(text: String) -> void:
	if _out != null:
		_out.add_text(text + "\n")


func _on_submit(text: String) -> void:
	_line.clear()
	if text.strip_edges().is_empty():
		return
	_history.append(text)
	_hist_i = _history.size()
	print_line("> " + text)
	if registry != null:
		print_line(registry.run(text))


func _on_line_input(ev: InputEvent) -> void:
	if ev is InputEventKey and ev.pressed and not _history.is_empty():
		if ev.keycode == KEY_UP:
			_hist_i = maxi(0, _hist_i - 1)
			_line.text = _history[_hist_i]
			accept_event()
		elif ev.keycode == KEY_DOWN:
			_hist_i = mini(_history.size(), _hist_i + 1)
			_line.text = _history[_hist_i] if _hist_i < _history.size() else ""
			accept_event()


func on_event(ev) -> void:
	if registry == null or not visible or not registry.tail_enabled:
		return
	if registry.tail_filter != "" and not ev.name.begins_with(registry.tail_filter):
		return
	print_line("#%d %s %s" % [ev.seq, ev.name, JSON.stringify(ev.payload)])
