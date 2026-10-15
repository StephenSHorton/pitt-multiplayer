extends CanvasLayer
## Headless stand-in for res://scripts/pause_menu.gd (our own minimal code) so
## PittMultiplayer's pause_menu_ext.gd compiles and can be exercised.

@export var hover_sound: AudioStream
@export var click_sound: AudioStream

var calls: Array = []
var dialogs: Array = []


class StubDialog extends Node:
	var _title_key := ""
	var _body_key := ""
	var built_body := ""

	func _ready() -> void:
		built_body = _body_key


func _play_ui_sound(_stream: AudioStream, _pitch_variation: float = 0.05):
	pass


func _on_save_pressed():
	calls.append("save")


func _on_load_pressed():
	calls.append("load")


func _on_delete_save_pressed():
	calls.append("delete")


func _on_main_menu_pressed():
	calls.append("main_menu")
	_confirm_exit("MENU_CONFIRM_MAIN_MENU_TITLE", "PAUSE_MAIN_MENU", func(): _return_to_main_menu(), null)


func _on_quit_pressed():
	calls.append("quit")
	_confirm_exit("MENU_CONFIRM_QUIT_TITLE", "MENU_QUIT", func(): pass, null)


func _confirm_exit(title_key: String, confirm_key: String, on_exit: Callable, focus_node: Control) -> void:
	var d := StubDialog.new()
	d._title_key = title_key
	d._body_key = "MENU_CONFIRM_QUIT_BODY"
	add_child(d)
	dialogs.append(d)


func _return_to_main_menu():
	calls.append("return_to_main_menu")


func _on_clear_items_pressed() -> void:
	calls.append("clear_items")


func _do_clear_items() -> void:
	calls.append("do_clear_items")
