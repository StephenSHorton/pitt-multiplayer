extends CanvasLayer
## Headless stub standing in for res://scripts/main_menu.gd so PittMultiplayer's
## extension (extends "res://scripts/main_menu.gd") compiles in the test project
## and the UI suites can drive a menu with the real node paths. Our own minimal
## code with the members the UI contract names, not the game's script. The node
## tree is built by tests/fakes/mp_ui/menu_stub.gd.

var hover_sound: AudioStream = null
var click_sound: AudioStream = null
var ignore_input: bool = false
var _pending_new_game: bool = false

## What happened, for assertions.
var log: Array = []
var launched: Array = []
var sounds := 0
var quit_dialogs := 0


const WORLD_SCENE := "res://scenes/world.tscn"
const DEBOUNCE_SEC := 0.15


func _ready() -> void:
	add_to_group("MainMenu")


func _panel(panel_name: String) -> Control:
	return get_node("Background/" + panel_name)


## hides `from` and shows `to` (menu panels under Background)
func _swap(from: String, to: String) -> void:
	_panel(from).visible = false
	_panel(to).visible = true


func _click() -> void:
	_play_ui_sound(click_sound, 0.05)


## Esc backs out of the open panel (sandbox, save list, else the quit dialog)
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed(&"ui_cancel"):
		return
	for step in [["MenuSandbox", _on_return_sandbox], ["MenuLoad", _on_return_save_load],
			["MenuButtons", _on_quit_pressed]]:
		if _panel(step[0]).visible:
			step[1].call()
			break
	get_viewport().set_input_as_handled()


func _on_play_pressed():
	if ignore_input:
		return
	log.append("play")
	_click()
	_swap("MenuButtons", "MenuLoad")
	_debounce()


func _on_quit_pressed():
	if ignore_input:
		return
	log.append("quit")
	quit_dialogs += 1


func _on_return_save_load():
	if ignore_input:
		return
	log.append("return_save_load")
	_click()
	_swap("MenuLoad", "MenuButtons")
	_debounce()


func _on_sandbox_pressed():
	if ignore_input:
		return
	log.append("sandbox")
	_swap("MenuLoad", "MenuSandbox")
	_debounce()


func _on_return_sandbox():
	log.append("return_sandbox")
	_swap("MenuSandbox", "MenuLoad")


func _on_new_game():
	if ignore_input:
		return
	log.append("new_game")
	_pending_new_game = true
	_launch_game(WORLD_SCENE)


func _launch_game(scene_path: String):
	log.append("launch:" + scene_path)
	launched.append(scene_path)
	hide()


func _focus_current_panel():
	log.append("focus_current_panel")
	if _panel("MenuButtons").visible:
		_grab_first_button(_panel("MenuButtons"))


func _grab_first_button(container: Node):
	var usable := container.get_children().filter(func(c): return c is BaseButton and c.visible and not c.disabled)
	if not usable.is_empty():
		usable[0].grab_focus()


func _play_ui_sound(_stream: AudioStream, _pitch_variation: float = 0.05):
	sounds += 1


func _on_mouse_entered() -> void:
	_play_ui_sound(hover_sound, 0.05)


## ignores menu input for a moment after a panel change
func _debounce():
	ignore_input = true
	get_tree().create_timer(DEBOUNCE_SEC).timeout.connect(func(): ignore_input = false)


## the game's name for it (mp_router calls it)
func _temporarily_ignore_input():
	_debounce()
