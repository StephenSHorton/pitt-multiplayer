extends CanvasLayer
## Headless stub standing in for res://scripts/hud.gd so ExampleMod's extension
## (extends "res://scripts/hud.gd") compiles in the test project. Our own minimal
## code, not the game's script.

var results: Array = []


func show_result(combo_level, total_bonus):
	results.append([combo_level, total_bonus])


func show_notification_message(message):
	pass


func _spawn_special_bonus_text(text: String, color: Color):
	pass
