extends Node
## Keeps a duplicated main-menu button inside the game's menu column.
##
## MenuButtons is a 736 px VBoxContainer (main_menu.tscn, offset_left 49 ..
## offset_right 785) and the game's own labels (Play, Options, Credits, Quit)
## fit it at size 104 x menu_scale. "Multiplayer" (and most translations) does
## not: the column would grow to the right and every centred button would move
## off the title / sub-panel axis. This helper gives the button the reference
## button's font size when the text fits, and the largest size that does fit
## otherwise. It re-runs when the locale changes or MenuManager.apply_menu_scales
## sets new sizes (both emit theme_changed / TRANSLATION_CHANGED). base_font_size
## meta is left alone, so the game's scaling still starts from the real base.

var button: Button = null
var reference: Control = null       # the Play button: the size we want
var column: Control = null
var column_width := 0.0             # the column's designed width
var fitted_size := 0
var _queued := false


func setup(p_button: Button, p_reference: Control, p_column: Control, p_width: float) -> void:
	button = p_button
	reference = p_reference
	column = p_column
	column_width = p_width
	name = "MPFitWidth"
	if button != null and not button.theme_changed.is_connected(_queue):
		button.theme_changed.connect(_queue)
	if reference != null and not reference.theme_changed.is_connected(_queue):
		reference.theme_changed.connect(_queue)


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSLATION_CHANGED:
		_queue()


func _queue() -> void:
	if _queued:
		return
	_queued = true
	fit.call_deferred()


## Applies the size now. Returns the font size in use.
func fit() -> int:
	_queued = false
	if button == null or not is_instance_valid(button) or column_width <= 0.0:
		return 0
	var font: Font = button.get_theme_font("font")
	var want: int = reference.get_theme_font_size("font_size") if reference != null and is_instance_valid(reference) \
		else button.get_theme_font_size("font_size")
	if font == null or want <= 0:
		return want
	var size := best_size(font, button.tr(button.text), want, column_width - _margins())
	fitted_size = size
	if button.get_theme_font_size("font_size") != size:
		button.add_theme_font_size_override("font_size", size)
	# the column grew while the label was too wide: give it back its width
	if column != null and is_instance_valid(column) and column.size.x > column_width + 0.5:
		column.size = Vector2(column_width, column.size.y)
	return size


func _margins() -> float:
	var m := 0.0
	var sb: StyleBox = button.get_theme_stylebox("normal")
	if sb != null:
		m += sb.get_minimum_size().x
	return m + 2.0


## Largest size <= want whose text width fits into avail.
static func best_size(font: Font, text: String, want: int, avail: float) -> int:
	if text == "" or avail <= 0.0:
		return want
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, want).x
	if w <= avail:
		return want
	var size := maxi(1, int(floor(float(want) * avail / w)))
	while size > 1 and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > avail:
		size -= 1
	return size
