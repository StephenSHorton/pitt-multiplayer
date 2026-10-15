extends Control
## Headless stand-in for res://scripts/upgradeUI.gd so PittMultiplayer's
## upgrade_ui_ext.gd compiles and can be exercised. Our own minimal code (not
## the game's): rows are an HBoxContainer with a Label and a Button stored in
## metas, and ONE pressed lambda per button, like the terminal.

const COLOR_RED := Color("#ff0000")
const COLOR_DIM := Color("#00cc00")

@export var buy_sound: AudioStream
@export var error_sound: AudioStream
@export var hover_sound: AudioStream
@export var upgrade_sound: AudioStream

## test hooks
var calls: Array = []
var local_buys: Array = []
var spawned_tools: Array = []
var spawned_toys: Array = []
var recalls := 0
var feedback: Array = []
var buy_func: Callable = Callable()   # (category, key, subkey) -> bool, the local "GameState.buy"


## a row carries its Label and Button (and the caller's extras) as metas
func _make_base_row(row_name: String, extra: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = row_name
	var metas := {"label": Label.new(), "button": Button.new()}
	for part in metas.values():
		row.add_child(part)
	metas.merge(extra)
	for k in metas:
		row.set_meta(k, metas[k])
	return row


func _create_upgrade_row(category: String, key: String, subkey: = "") -> HBoxContainer:
	var row := _make_base_row("%s__%s" % [key, subkey], {"category": category, "key": key, "subkey": subkey})
	var on_press := func():
		local_buys.append([category, key, subkey])
		if buy_func.is_valid():
			buy_func.call(category, key, subkey)
	(row.get_meta("button") as Button).pressed.connect(on_press)
	return row


func _create_tool_buy_row(tool_name: String, level: int, display_name: = "", display_level: = -1) -> HBoxContainer:
	var row := _make_base_row("%s_level_%d" % [tool_name, level], {"tool_name": tool_name, "level": level})
	var on_press := func():
		if row.has_meta("recall_mode") and row.get_meta("recall_mode"):
			recalls += 1
		else:
			local_buys.append(["tools", tool_name, level])
	(row.get_meta("button") as Button).pressed.connect(on_press)
	return row


func _create_toy_buy_row(toy_name: String) -> HBoxContainer:
	var row := _make_base_row("%s_buy" % toy_name, {"toy_name": toy_name})
	(row.get_meta("button") as Button).pressed.connect(func(): local_buys.append(["toys", toy_name, ""]))
	return row


func _refresh_tool_buy_row(_row: HBoxContainer):
	calls.append("refresh_tool")


func _refresh_toy_buy_row(_row: HBoxContainer):
	calls.append("refresh_toy")


func _spawn_tool_instance(tool_name: String, level: int) -> void:
	spawned_tools.append([tool_name, level])


func _spawn_toy_instance(toy_name: String) -> void:
	spawned_toys.append(toy_name)


func _acknowledge_row(_row: HBoxContainer) -> void:
	calls.append("ack")


func update_ui():
	calls.append("update_ui")


func update_credits():
	calls.append("update_credits")


func _play_sound(_stream: AudioStream, _pitch_variation: float = 0.1):
	calls.append("sound")


func _create_success_effect(_node: Control):
	calls.append("success")


func _create_error_effect(_node: Control):
	calls.append("error")


func _pulse_node(_node: Control, _color: Color, _duration: float):
	pass


func _screen_shake(_strength: float, _duration: float):
	pass


func _flash_label(_label: Label, _color: Color):
	pass


func _enhanced_shake_node(_node: Control):
	pass


func _spawn_floating_text(_origin_node: Control, text: String, _color: Color):
	feedback.append(text)

